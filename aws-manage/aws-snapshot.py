#!/usr/bin/env python3
"""Snapshot an instance's root and cache EBS volumes and republish them as
a new version of a named AMI. With --cache-only, only the cache volume is
re-snapshotted -- the AMI's existing root snapshot is carried over as-is.

Invoked by aws-manage's `snapshot`/`snapshot-cache` subcommands, which have
already resolved the alias to an instance id. Not meant to be run standalone
against an arbitrary instance without checking what AMI it's about to
replace.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time


def aws(*args: str) -> str:
    result = subprocess.run(
        ["aws", *args, "--output", "json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"aws {' '.join(args)} failed")
    return result.stdout


def aws_json(*args: str) -> dict:
    out = aws(*args)
    if not out.strip():
        raise RuntimeError(f"aws {' '.join(args)} produced no output")
    return json.loads(out)


def find_volume(instance: dict, device_name: str) -> str:
    for mapping in instance["BlockDeviceMappings"]:
        if mapping["DeviceName"] == device_name:
            return mapping["Ebs"]["VolumeId"]
    raise RuntimeError(f"no volume attached at {device_name}")


def create_snapshot(volume_id: str, name: str, description: str) -> str:
    print(f"Snapshotting {volume_id} ({name})...")
    out = aws_json(
        "ec2", "create-snapshot",
        "--volume-id", volume_id,
        "--description", description,
        "--tag-specifications",
        f"ResourceType=snapshot,Tags=[{{Key=Name,Value={name}}}]",
    )
    return out["SnapshotId"]


def wait_for_snapshots(snapshot_ids: list[str], poll_seconds: int = 15,
                        timeout_seconds: int = 3600) -> None:
    # The AWS CLI's own `wait snapshot-completed` gives up after 40 attempts
    # at 15s each (10 minutes total), which a fresh multi-hundred-GB root
    # volume's first (non-incremental) snapshot can easily exceed. Poll
    # directly instead, with a much longer ceiling.
    deadline = time.monotonic() + timeout_seconds
    pending = set(snapshot_ids)
    while pending:
        if time.monotonic() > deadline:
            raise RuntimeError(
                f"snapshots did not complete within {timeout_seconds}s: {sorted(pending)}")
        snapshots = aws_json(
            "ec2", "describe-snapshots", "--snapshot-ids", *pending,
        )["Snapshots"]
        progress = {}
        for snap in snapshots:
            state = snap["State"]
            if state == "completed":
                pending.discard(snap["SnapshotId"])
            elif state == "error":
                raise RuntimeError(f"snapshot {snap['SnapshotId']} failed: {snap}")
            else:
                progress[snap["SnapshotId"]] = snap.get("Progress", "?")
        if pending:
            status = ", ".join(f"{sid}: {progress.get(sid, '?')}" for sid in sorted(pending))
            print(f"  still pending: {status} ({poll_seconds}s)...")
            time.sleep(poll_seconds)


def gc_orphaned_snapshots(ami_name: str) -> None:
    # Every snapshot/register-image cycle leaves the *previous* generation's
    # root+cache snapshots behind on purpose (register-image needs them to
    # exist until the new AMI is confirmed working) -- but once a new AMI is
    # successfully tagged, anything with this AMI's naming scheme that isn't
    # referenced by *any* current self-owned AMI is just accumulating
    # storage cost. Scoped to this ami_name's tag prefix specifically so a
    # shared account's other snapshots are never touched.
    print("Garbage-collecting orphaned snapshots...")
    candidates = aws_json(
        "ec2", "describe-snapshots", "--owner-ids", "self",
        "--filters", f"Name=tag:Name,Values={ami_name}-*",
    )["Snapshots"]
    if not candidates:
        print("  none found.")
        return

    images = aws_json("ec2", "describe-images", "--owners", "self")["Images"]
    referenced = {
        mapping["Ebs"]["SnapshotId"]
        for image in images
        for mapping in image.get("BlockDeviceMappings", [])
        if "Ebs" in mapping and "SnapshotId" in mapping["Ebs"]
    }

    orphaned = [s["SnapshotId"] for s in candidates if s["SnapshotId"] not in referenced]
    if not orphaned:
        print("  none found.")
        return

    for snapshot_id in orphaned:
        try:
            aws("ec2", "delete-snapshot", "--snapshot-id", snapshot_id)
            print(f"  deleted {snapshot_id}")
        except RuntimeError as exc:
            print(f"  WARNING: could not delete {snapshot_id}: {exc}", file=sys.stderr)


def ebs_mapping_from_image(image: dict, device_name: str) -> dict:
    for mapping in image["BlockDeviceMappings"]:
        if mapping["DeviceName"] == device_name:
            return mapping
    raise RuntimeError(f"AMI has no block device mapping for {device_name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--ami-name", default="vraiti-rhel10-cuda")
    parser.add_argument("--cache-device", default="/dev/sdf")
    parser.add_argument("--cache-only", action="store_true",
                         help="Only re-snapshot the cache volume; carry the "
                              "AMI's existing root snapshot over unchanged.")
    args = parser.parse_args()

    instance = aws_json(
        "ec2", "describe-instances", "--instance-ids", args.instance_id,
    )["Reservations"][0]["Instances"][0]

    root_device_name = instance["RootDeviceName"]
    cache_volume_id = find_volume(instance, args.cache_device)
    root_volume_id = None if args.cache_only else find_volume(instance, root_device_name)

    print(f"Instance:     {args.instance_id}")
    print(f"Cache volume: {cache_volume_id} ({args.cache_device})")
    if root_volume_id is not None:
        print(f"Root volume:  {root_volume_id} ({root_device_name})")

    old_images = aws_json(
        "ec2", "describe-images", "--owners", "self",
        "--filters", f"Name=tag:Name,Values={args.ami_name}",
    )["Images"]
    if not old_images:
        print(f"ERROR: AMI '{args.ami_name}' not found", file=sys.stderr)
        return 1
    old_image = old_images[0]
    old_ami_id = old_image["ImageId"]
    print(f"Current AMI:  {old_ami_id}")

    ts = time.strftime("%Y%m%d-%H%M%S")

    snapshot_ids_to_await = []
    cache_snapshot_id = create_snapshot(
        cache_volume_id, f"{args.ami_name}-cache-{ts}",
        f"{args.ami_name} cache snapshot from {args.alias} ({ts})",
    )
    snapshot_ids_to_await.append(cache_snapshot_id)

    root_snapshot_id = None
    if root_volume_id is not None:
        root_snapshot_id = create_snapshot(
            root_volume_id, f"{args.ami_name}-root-{ts}",
            f"{args.ami_name} root snapshot from {args.alias} ({ts})",
        )
        snapshot_ids_to_await.append(root_snapshot_id)

    print("Waiting for snapshots to complete (this can take a while)...")
    wait_for_snapshots(snapshot_ids_to_await)

    old_cache_mapping = ebs_mapping_from_image(old_image, args.cache_device)

    def replace_snapshot(mapping: dict, snapshot_id: str) -> dict:
        ebs = dict(mapping["Ebs"])
        ebs["SnapshotId"] = snapshot_id
        ebs.pop("Encrypted", None)
        return {"DeviceName": mapping["DeviceName"], "Ebs": ebs}

    old_root_mapping = ebs_mapping_from_image(old_image, root_device_name)
    if root_snapshot_id is not None:
        new_root_mapping = replace_snapshot(old_root_mapping, root_snapshot_id)
    else:
        # Reused as-is (its SnapshotId is unchanged), but the API still
        # rejects Encrypted alongside any SnapshotId, same as in
        # replace_snapshot above.
        new_root_mapping = replace_snapshot(
            old_root_mapping, old_root_mapping["Ebs"]["SnapshotId"])
    new_block_device_mappings = [
        new_root_mapping,
        replace_snapshot(old_cache_mapping, cache_snapshot_id),
    ]

    register_args = [
        "ec2", "register-image",
        "--name", old_image["Name"],
        "--architecture", old_image["Architecture"],
        "--root-device-name", root_device_name,
        "--virtualization-type", old_image["VirtualizationType"],
        "--block-device-mappings", json.dumps(new_block_device_mappings),
    ]
    if old_image.get("EnaSupport"):
        register_args += ["--ena-support"]
    if old_image.get("BootMode"):
        register_args += ["--boot-mode", old_image["BootMode"]]

    print(f"Deregistering old AMI {old_ami_id}...")
    aws("ec2", "deregister-image", "--image-id", old_ami_id)

    print("Registering new AMI...")
    new_ami_id = aws_json(*register_args)["ImageId"]

    aws("ec2", "create-tags", "--resources", new_ami_id,
        "--tags", f"Key=Name,Value={args.ami_name}")

    gc_orphaned_snapshots(args.ami_name)

    print()
    print(f"New AMI:      {new_ami_id}")
    if root_snapshot_id is not None:
        print(f"Root snapshot:  {root_snapshot_id}")
    print(f"Cache snapshot: {cache_snapshot_id}")
    print(f"Old AMI {old_ami_id} deregistered; its now-orphaned snapshots were garbage-collected above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
