"""Hand-rolled wrapper around the `scp` binary.

Kept external for the same reason as ssh.py -- see UTILS.md. Used only for
one-off file pushes needed before a venv (and therefore any Python-native
remote helper) exists yet on a fresh remote host.
"""
from __future__ import annotations

from . import _proc


def copy_to(alias: str, local_path: str, remote_path: str) -> None:
    """scp <local_path> <alias>:<remote_path>"""
    _proc.run(["scp", local_path, f"{alias}:{remote_path}"])


def copy_from(alias: str, remote_path: str, local_path: str) -> None:
    """scp <alias>:<remote_path> <local_path>"""
    _proc.run(["scp", f"{alias}:{remote_path}", local_path])
