"""Hand-rolled wrapper around the `uv` binary.

Must stay external -- see UTILS.md: it's the tool actually being
orchestrated (venv creation, package installs), not glue. There's no
official Python API for its internals; it's a CLI (Rust binary) by design,
the same way pip would stay external from a script that calls `pip install`.
"""
from __future__ import annotations

import os

from . import _proc

DEFAULT_PYTHON = "3.14"


def _venv_python(venv_dir: str) -> str:
    return os.path.join(venv_dir, "bin", "python3")


def create_venv(venv_dir: str, python_version: str = DEFAULT_PYTHON) -> None:
    """uv venv <venv_dir> --python <python_version>"""
    _proc.run(["uv", "venv", venv_dir, "--python", python_version])


def pip_install(venv_dir: str, packages: list[str], *, extra_args: list[str] | None = None) -> None:
    """uv pip install --python <venv_dir>/bin/python3 [extra_args...] <packages...>

    Targets the venv's own interpreter directly via --python instead of
    relying on `source bin/activate` having already run in this process --
    a plain Python wrapper has no notion of "the currently active venv" the
    way a sourced bash script does, so every call names its venv explicitly.
    """
    argv = ["uv", "pip", "install", "--python", _venv_python(venv_dir), *(extra_args or []), *packages]
    _proc.run(argv, capture=False)


def pip_install_requirements(venv_dir: str, requirements_file: str) -> None:
    """uv pip install --python <venv_dir>/bin/python3 -r <requirements_file>"""
    _proc.run(["uv", "pip", "install", "--python", _venv_python(venv_dir), "-r", requirements_file], capture=False)


def pip_show(venv_dir: str, package: str) -> dict[str, str]:
    """uv pip show --python <venv_dir>/bin/python3 <package>, parsed into a
    {field: value} dict (e.g. pip_show(venv, "flashinfer-python")["Version"])."""
    result = _proc.run(["uv", "pip", "show", "--python", _venv_python(venv_dir), package])
    fields: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            fields[key.strip()] = value.strip()
    return fields
