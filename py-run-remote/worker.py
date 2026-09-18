#!/usr/bin/env python3
"""run-remote-worker.py: runs on the remote host, invoked as
`python3 worker.py <job.json path>`. Ensures the job's venv exists,
garbage-collects orphaned ones, daemonizes (detaching from the ssh session
that launched it), then spawns the target command and records its exit
code.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import venvspec
from models import JobSpec


def venv_spec_hash(spec_json: str) -> str:
    return hashlib.sha256(spec_json.encode()).hexdigest()


def ensure_venv(job: JobSpec) -> str:
    spec_json = json.dumps([e.model_dump() for e in job.venv], separators=(",", ":"))
    digest = venv_spec_hash(spec_json)
    real_venv_dir = os.path.join(job.venvs_root, "venvs", f"venv-{digest}")
    profile_venv_dir = os.path.join(job.venvs_root, job.profile_name)

    if not os.path.isdir(real_venv_dir):
        print(f"venv not found at {real_venv_dir}, creating from spec...")
        venvspec.build_venv_from_spec(job.venv, real_venv_dir, job.project_root)

    Path(profile_venv_dir).parent.mkdir(parents=True, exist_ok=True)
    tmp_link = f"{profile_venv_dir}.tmp-{os.getpid()}"
    os.symlink(real_venv_dir, tmp_link)
    os.replace(tmp_link, profile_venv_dir)  # atomic re-point, same as ln -sfn

    return real_venv_dir


def gc_orphaned_venvs(venvs_root: str) -> None:
    """Removes any ~/.venvs/venvs/venv-* not referenced by any symlink under
    ~/.venvs/ (recursively -- a profile name can contain "/"), skipping the
    venvs/ storage dir itself so a venv's own internal symlinks (e.g.
    bin/python -> python3) are never mistaken for profile references."""
    venvs_root_path = Path(venvs_root)
    storage_dir = venvs_root_path / "venvs"
    if not storage_dir.is_dir():
        return

    referenced: set[str] = set()
    for path in venvs_root_path.rglob("*"):
        if storage_dir in path.parents or path == storage_dir:
            continue
        if path.is_symlink():
            referenced.add(str(path.resolve()))

    for candidate in storage_dir.iterdir():
        if candidate.is_dir() and str(candidate.resolve()) not in referenced:
            print(f"Removing orphaned venv: {candidate}")
            shutil.rmtree(candidate)


def daemonize(log_file: str) -> None:
    """Double-fork + setsid so this process is fully detached from the ssh
    session's controlling terminal -- the parent (still attached to ssh)
    exits once the child has forked, so the ssh invocation that launched
    this returns deterministically rather than relying on shell job-control
    (`nohup`/`disown`) semantics.

    Flushes stdio and uses os._exit (not sys.exit) for both fork-away
    parents: fork() duplicates the process's buffered-but-unflushed stdio,
    and sys.exit() runs normal interpreter shutdown (which flushes that
    buffer) in each exiting parent -- without the explicit flush before
    forking and os._exit after, any output already printed (e.g. venv
    creation progress) would land in the buffer at fork time and then get
    flushed twice, once by each intermediate parent exiting.
    """
    sys.stdout.flush()
    sys.stderr.flush()
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)

    Path(os.path.dirname(log_file) or ".").mkdir(parents=True, exist_ok=True)
    devnull = os.open(os.devnull, os.O_RDONLY)
    log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(devnull, 0)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    if devnull > 2:
        os.close(devnull)
    if log_fd > 2:
        os.close(log_fd)


def run_job(job: JobSpec, venv_dir: str) -> int:
    env = dict(os.environ)
    env["VIRTUAL_ENV"] = venv_dir
    env["PATH"] = f"{os.path.join(venv_dir, 'bin')}:{env.get('PATH', '')}"
    env.update(job.env)

    if job.initializer:
        # Kept as a real shell snippet on purpose -- documented as relying
        # on `&&`-chaining, unlike the main command below.
        subprocess.run(["bash", "-c", job.initializer], cwd=job.project_root, env=env, check=True)

    # Deliberately not check=True -- the whole point is to capture the job's
    # real exit code ourselves, success or failure, not raise on nonzero.
    result = subprocess.run(job.command, cwd=job.project_root, env=env, check=False)
    return result.returncode


def main() -> None:
    job_path = sys.argv[1]
    job = JobSpec.model_validate_json(Path(job_path).read_text(encoding="utf-8"))

    venv_dir = ensure_venv(job)
    gc_orphaned_venvs(job.venvs_root)

    daemonize(job.log_file)
    try:
        exit_code = run_job(job, venv_dir)
    except Exception as e:  # pylint: disable=broad-exception-caught
        # Deliberately catches anything: this runs after daemonize(), so the
        # local watch loop is already blocked waiting on job.exit_file --
        # any unhandled exception here would leave it waiting forever
        # instead of getting a (failure) exit code back.
        print(f"ERROR: {e}", file=sys.stderr)
        exit_code = 1
    Path(job.exit_file).write_text(str(exit_code), encoding="utf-8")


if __name__ == "__main__":
    main()
