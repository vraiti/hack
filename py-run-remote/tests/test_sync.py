"""Covers the manual verification of sync.py's orchestration against a real
git repo, with rsync/ssh mocked out (no real network calls).
"""
from __future__ import annotations

from pathlib import Path
from typing import Callable
from unittest import mock

import pytest

import sync
from models import Profile


def test_sync_all_archives_and_writes_marker(
    tmp_path: Path, make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    project_dir = tmp_path / "proj"
    project_dir.mkdir()
    repo = make_git_repo("proj/myrepo")
    (repo / "f.txt").write_text("one", encoding="utf-8")
    commit_all(repo, "init")

    profile = Profile(sync={"myrepo": "default"})

    calls: dict[str, list] = {"rsync": [], "ssh_run": []}

    def fake_rsync_sync(src: str, _alias: str, dst: str, **_kw: object) -> None:
        calls["rsync"].append((src, dst))

    def fake_ssh_run(_alias: str, cmd: str, **_kw: object) -> mock.Mock:
        calls["ssh_run"].append(cmd)
        return mock.Mock(returncode=0, stdout="")

    def fake_read_remote_file(_alias: str, _path: str, default: object = None) -> object:
        return default

    def fake_push_fails(*_a: object, **_k: object) -> None:
        raise RuntimeError("no remote configured for source branch master")

    with mock.patch.object(sync.rsyncw, "sync", fake_rsync_sync), \
            mock.patch.object(sync.sshw, "run", fake_ssh_run), \
            mock.patch.object(sync.sshw, "read_remote_file", fake_read_remote_file), \
            mock.patch.object(sync, "push_repo_and_submodules", fake_push_fails):
        sync.sync_all("fake-alias", "/remote/root", str(project_dir), profile, quiet=True)

    assert len(calls["rsync"]) == 1
    _src, dst = calls["rsync"][0]
    assert dst == "/remote/root/myrepo"
    assert any(c.startswith("echo") and "myrepo/.rrr-synced-commit" in c for c in calls["ssh_run"])


def test_sync_all_skips_unchanged_repo(
    tmp_path: Path, make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    project_dir = tmp_path / "proj"
    project_dir.mkdir()
    repo = make_git_repo("proj/myrepo")
    (repo / "f.txt").write_text("one", encoding="utf-8")
    head = commit_all(repo, "init")

    profile = Profile(sync={"myrepo": "default"})

    rsync_calls: list[object] = []

    with mock.patch.object(sync.rsyncw, "sync", lambda *a, **k: rsync_calls.append(a)), \
            mock.patch.object(sync.sshw, "read_remote_file", lambda *a, **k: head), \
            mock.patch.object(sync, "push_repo_and_submodules", lambda *a, **k: None):
        sync.sync_all("fake-alias", "/remote/root", str(project_dir), profile, quiet=True)

    assert not rsync_calls


def test_sync_all_raises_on_missing_local_directory(tmp_path: Path) -> None:
    project_dir = tmp_path / "proj"
    project_dir.mkdir()
    profile = Profile(sync={"does-not-exist": "default"})

    with pytest.raises(RuntimeError, match="does not exist"):
        sync.sync_all("fake-alias", "/remote/root", str(project_dir), profile, quiet=True)


def test_push_repo_and_submodules_raises_without_remote(
    make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    repo = make_git_repo()
    (repo / "f.txt").write_text("one", encoding="utf-8")
    commit_all(repo, "init")

    with pytest.raises(RuntimeError, match="no remote configured"):
        sync.push_repo_and_submodules(str(repo))
