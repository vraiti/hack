"""Hand-rolled wrapper around the `rsync` binary.

Must stay external -- see UTILS.md: no Python package replicates rsync's
delta-transfer protocol or its --delete semantics at production quality.
"""
from __future__ import annotations

from . import _proc


def sync(src_dir: str, alias: str, dst_dir: str, *, delete: bool = True, exclude: list[str] | None = None) -> None:
    """rsync -az [--delete] [--exclude=X ...] <src_dir>/ <alias>:<dst_dir>/

    src_dir/dst_dir are always synced as directory *contents* (trailing
    slash added if missing), matching sync-remote.sh's own convention --
    omitting the slash would nest src_dir's basename inside dst_dir instead
    of replacing dst_dir's contents with src_dir's.
    """
    argv = ["rsync", "-az"]
    if delete:
        argv.append("--delete")
    for pattern in exclude or []:
        argv.append(f"--exclude={pattern}")
    src = src_dir if src_dir.endswith("/") else src_dir + "/"
    dst = dst_dir if dst_dir.endswith("/") else dst_dir + "/"
    argv += [src, f"{alias}:{dst}"]
    _proc.run(argv, capture=False)
