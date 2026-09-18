"""Covers the manual verification of worker.py: the GC symlink-recursion
fix, the venv-spec hash's byte-compatibility with `jq -c`, ensure_venv's
build-once/cache-reuse/symlink behavior, and a full subprocess-level
end-to-end run (daemonize, initializer, env, exit code, log content).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from unittest import mock

import pytest

import venvspec
import worker
from models import JobSpec, VenvSpecEntry


def test_venv_spec_hash_matches_jq_c_format() -> None:
    if shutil.which("jq") is None:
        pytest.skip("jq not installed")
    spec = [{"python": "3.12"}, {"package": "vllm==0.29.0"}]
    py_json = json.dumps(spec, separators=(",", ":"))
    jq_json = subprocess.run(
        ["jq", "-c", "."], input=json.dumps(spec), capture_output=True, text=True, check=True
    ).stdout.strip()
    assert py_json == jq_json


def test_gc_orphaned_venvs_respects_nested_symlinks_and_ignores_internal_ones(tmp_path: Path) -> None:
    venvs_root = tmp_path
    storage = venvs_root / "venvs"
    storage.mkdir()

    referenced_real = storage / "venv-aaa"
    referenced_real.mkdir()
    (referenced_real / "bin").mkdir()
    os.symlink("python3", referenced_real / "bin" / "python")  # internal symlink -- must be ignored

    orphan_real = storage / "venv-bbb"
    orphan_real.mkdir()

    nested_link_dir = venvs_root / "team"
    nested_link_dir.mkdir()
    os.symlink(referenced_real, nested_link_dir / "svc")  # nested profile name, e.g. "team/svc"

    worker.gc_orphaned_venvs(str(venvs_root))

    assert referenced_real.is_dir()
    assert not orphan_real.exists()
    assert (referenced_real / "bin" / "python").is_symlink()


def test_ensure_venv_builds_once_and_reuses(tmp_path: Path) -> None:
    job = JobSpec(
        profile_name="myprofile",
        venv=[VenvSpecEntry(type="python", content="3.12")],
        env={},
        project_root=str(tmp_path),
        initializer=None,
        command=["true"],
        venvs_root=str(tmp_path),
        log_file="/tmp/x.log",
        exit_file="/tmp/x.exit",
    )

    built: list[str] = []

    def fake_build(_spec: object, venv_dir: str, _project_root: str) -> None:
        built.append(venv_dir)
        Path(venv_dir).mkdir(parents=True)

    with mock.patch.object(venvspec, "build_venv_from_spec", fake_build):
        real_dir = worker.ensure_venv(job)
        link = Path(tmp_path) / "myprofile"
        assert os.readlink(link) == real_dir

        real_dir_again = worker.ensure_venv(job)
        assert built == [real_dir]  # not rebuilt the second time
        assert real_dir_again == real_dir


def test_worker_end_to_end_daemonizes_and_records_exit_code(tmp_path: Path, fake_uv: Path) -> None:
    job_path = tmp_path / "job.json"
    log_file = tmp_path / "job.log"
    exit_file = tmp_path / "job.exit"
    job_path.write_text(
        json.dumps(
            {
                "profile_name": "testprofile",
                "venv": [{"type": "python", "content": "3.12"}],
                "env": {"MY_VAR": "hello"},
                "project_root": str(tmp_path),
                "initializer": "echo initializer-ran",
                "command": ["bash", "-c", "echo command-ran $MY_VAR; sleep 0.3; exit 5"],
                "venvs_root": str(tmp_path / "venvs"),
                "log_file": str(log_file),
                "exit_file": str(exit_file),
            }
        ),
        encoding="utf-8",
    )

    worker_script = Path(worker.__file__)
    started = time.monotonic()
    subprocess.run([sys.executable, str(worker_script), str(job_path)], check=True, timeout=10)
    elapsed = time.monotonic() - started

    # Daemonized: the launcher returns long before the job's 0.3s sleep
    # finishes, instead of blocking for it.
    assert elapsed < 0.3

    for _ in range(50):
        if exit_file.exists():
            break
        time.sleep(0.1)

    assert log_file.read_text(encoding="utf-8") == "initializer-ran\ncommand-ran hello\n"
    assert exit_file.read_text(encoding="utf-8") == "5"
    link = tmp_path / "venvs" / "testprofile"
    assert link.is_symlink()
    assert "venv" in fake_uv.read_text(encoding="utf-8")  # confirms the fake uv actually built the venv
