"""Shared fixtures for py-run-remote's test suite."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Callable

import pytest


@pytest.fixture
def fake_uv(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Puts a fake `uv` on PATH that appends its argv to uv_calls.log (in
    tmp_path) and creates a minimal bin/{activate,python3} layout for
    `uv venv`, matching real uv's on-disk shape closely enough for
    venvspec.build_venv_from_spec to proceed without a real network/venv."""
    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()
    log_file = tmp_path / "uv_calls.log"
    script = fakebin / "uv"
    script.write_text(
        "#!/usr/bin/env bash\n"
        f'echo "$@" >> {log_file}\n'
        'if [[ "$1" == "venv" ]]; then mkdir -p "$2/bin"; touch "$2/bin/activate" "$2/bin/python3"; fi\n'
        "exit 0\n",
        encoding="utf-8",
    )
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{fakebin}{os.pathsep}{os.environ.get('PATH', '')}")
    log_file.touch()
    return log_file


def _run_git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)


@pytest.fixture
def make_git_repo(tmp_path: Path) -> Callable[..., Path]:
    """Factory for a real, minimally-configured git repo under tmp_path,
    used wherever a test needs actual git plumbing behavior (auto-commit,
    archive, submodule status) rather than a mock."""

    def _make(name: str = "repo") -> Path:
        repo = tmp_path / name
        repo.mkdir(parents=True, exist_ok=True)
        _run_git(repo, "init", "-q")
        _run_git(repo, "config", "user.email", "vance.raiti@gmail.com")
        _run_git(repo, "config", "user.name", "Test User")
        return repo

    return _make


@pytest.fixture
def commit_all() -> Callable[[Path, str], str]:
    """Stages and commits everything in repo_dir, returning the new commit sha."""

    def _commit(repo_dir: Path, message: str) -> str:
        _run_git(repo_dir, "add", "-A")
        _run_git(repo_dir, "commit", "-q", "-m", message)
        return _run_git(repo_dir, "rev-parse", "HEAD").stdout.strip()

    return _commit
