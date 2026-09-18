"""Covers the manual end-to-end verification of venvspec.py: full spec
ordering with a fake uv, and the package-script fd-3 mechanism's success,
failure, and empty-output cases.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from models import VenvSpecEntry
from venvspec import build_venv_from_spec, _run_package_script


def test_full_spec_applies_in_order_with_fake_uv(tmp_path: Path, fake_uv: Path) -> None:
    spec = [
        VenvSpecEntry(type="envvar", content="MAX_JOBS=4"),
        VenvSpecEntry(type="python", content="3.12"),
        VenvSpecEntry(type="package", content="vllm==0.29.0"),
        VenvSpecEntry(type="package-script", content='printf "%s\\n" pkg-from-script >&3'),
        VenvSpecEntry(type="script", content="echo ran-setup-script"),
        # argv-style content with flags -- must reach uv as separate args,
        # not one literal string (the bug found and fixed this session).
        VenvSpecEntry(type="package", content="-e vllm-omni --no-build-isolation"),
    ]
    venv_dir = tmp_path / "myvenv"
    build_venv_from_spec(spec, str(venv_dir), str(tmp_path))

    activate_contents = (venv_dir / "bin" / "activate").read_text(encoding="utf-8")
    assert "export MAX_JOBS=4" in activate_contents

    calls = fake_uv.read_text(encoding="utf-8").splitlines()
    assert calls == [
        f"venv {venv_dir} --python 3.12",
        f"pip install --python {venv_dir}/bin/python3 vllm==0.29.0",
        f"pip install --python {venv_dir}/bin/python3 pkg-from-script",
        f"pip install --python {venv_dir}/bin/python3 -e vllm-omni --no-build-isolation",
    ]


def test_package_script_fd3_captures_multiple_packages(tmp_path: Path, fake_uv: Path) -> None:
    content = 'echo starting >&2; printf "%s\\n" pkgA pkgB --flag >&3; echo done >&2'
    _run_package_script(content, str(tmp_path / "v"), str(tmp_path), {})
    calls = fake_uv.read_text(encoding="utf-8").splitlines()
    assert calls == [f"pip install --python {tmp_path / 'v' / 'bin' / 'python3'} pkgA pkgB --flag"]


def test_package_script_nonzero_exit_raises(tmp_path: Path) -> None:
    with pytest.raises(subprocess.CalledProcessError):
        _run_package_script("exit 7", str(tmp_path / "v"), str(tmp_path), {})


def test_package_script_empty_output_raises(tmp_path: Path) -> None:
    with pytest.raises(RuntimeError, match="wrote no packages"):
        _run_package_script("true", str(tmp_path / "v"), str(tmp_path), {})
