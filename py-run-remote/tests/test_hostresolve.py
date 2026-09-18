"""Covers the manual verification run against hostresolve.py: zero, one, and
multiple aws-manage Host aliases.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from hostresolve import AmbiguousDefaultHostError, NoDefaultHostError, resolve_default_host


def test_no_hosts_raises(tmp_path: Path) -> None:
    config = tmp_path / "awsm"
    config.write_text("", encoding="utf-8")
    with pytest.raises(NoDefaultHostError):
        resolve_default_host(config)


def test_missing_file_raises_no_default_host(tmp_path: Path) -> None:
    with pytest.raises(NoDefaultHostError):
        resolve_default_host(tmp_path / "does-not-exist")


def test_one_host_resolves(tmp_path: Path) -> None:
    config = tmp_path / "awsm"
    config.write_text("Host gpu-box\n  HostName 1.2.3.4\n  User ec2-user\n", encoding="utf-8")
    assert resolve_default_host(config) == "gpu-box"


def test_multiple_hosts_raises_ambiguous(tmp_path: Path) -> None:
    config = tmp_path / "awsm"
    config.write_text("Host gpu-box\nHostName 1.2.3.4\nHost gpu-box-2\nHostName 5.6.7.8\n", encoding="utf-8")
    with pytest.raises(AmbiguousDefaultHostError) as exc_info:
        resolve_default_host(config)
    assert exc_info.value.hosts == ["gpu-box", "gpu-box-2"]
