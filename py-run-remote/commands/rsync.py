"""Hand-rolled wrapper around the `rsync` binary.

Must stay external -- see UTILS.md: no Python package replicates rsync's
delta-transfer protocol or its --delete semantics at production quality.
"""
from __future__ import annotations

import os
import tempfile

from . import _proc


def sync(
    src_dir: str,
    alias: str,
    dst_dir: str,
    *,
    delete: bool = True,
    exclude: list[str] | None = None,
    files_from: list[str] | None = None,
) -> None:
    """rsync -az [--delete] [--exclude=X ...] [--files-from=F] <src_dir>/ <alias>:<dst_dir>/

    src_dir/dst_dir are always synced as directory *contents* (trailing
    slash added if missing) -- omitting the slash would nest src_dir's
    basename inside dst_dir instead of replacing dst_dir's contents with
    src_dir's.

    files_from, when given, restricts the transfer to exactly those paths
    (relative to src_dir; directories are recursed into under -a) instead
    of everything under src_dir -- for shipping a specific set of files out
    of a directory that also holds things that shouldn't go along (e.g.
    this toolset's own source files living alongside profiles/, secrets/,
    and .git/ in the same repo).
    """
    argv = ["rsync", "-az"]
    if delete:
        argv.append("--delete")
    for pattern in exclude or []:
        argv.append(f"--exclude={pattern}")

    files_from_path = None
    if files_from is not None:
        fd, files_from_path = tempfile.mkstemp(text=True)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(files_from) + "\n")
        argv.append(f"--files-from={files_from_path}")

    src = src_dir if src_dir.endswith("/") else src_dir + "/"
    dst = dst_dir if dst_dir.endswith("/") else dst_dir + "/"
    argv += [src, f"{alias}:{dst}"]
    try:
        _proc.run(argv, capture=False)
    finally:
        if files_from_path is not None:
            os.unlink(files_from_path)
