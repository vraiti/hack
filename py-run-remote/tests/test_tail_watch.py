"""Covers the manual verification that tail_watch.py resumes from a byte
offset instead of replaying the whole log on reconnect (the fix for
run-remote's `tail -n +1 -f` full-replay bug).
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import tail_watch


def test_resume_from_offset_does_not_replay(tmp_path: Path) -> None:
    log_file = tmp_path / "job.log"
    exit_file = tmp_path / "job.exit"
    log_file.write_text("line1\nline2\n", encoding="utf-8")

    with subprocess.Popen(
        [sys.executable, tail_watch.__file__, str(log_file), str(exit_file), "--from-offset", "0"],
        stdout=subprocess.PIPE,
        text=True,
    ) as first:
        time.sleep(0.3)
        first.terminate()
        first.wait(timeout=5)
        first_output = first.stdout.read() if first.stdout else ""
    assert first_output == "line1\nline2\n"

    offset = log_file.stat().st_size
    with log_file.open("a", encoding="utf-8") as f:
        f.write("line3\n")
    exit_file.write_text("0", encoding="utf-8")

    second = subprocess.run(
        [sys.executable, tail_watch.__file__, str(log_file), str(exit_file), "--from-offset", str(offset)],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    assert second.stdout == "line3\n"
