"""Shared subprocess helper for the command wrappers in this package.

Every wrapper here builds argv as a list, never a shell string, so
arguments never need shell-quoting for the *local* subprocess call. The
only place a value still has to be shell-quoted is inside a remote command
string handed to `ssh`/`bash -c` -- see ssh.quote() for that.
"""
from __future__ import annotations

import subprocess


class CommandError(RuntimeError):
    def __init__(self, argv, returncode, stdout, stderr):
        self.argv = argv
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        super().__init__(f"command failed ({returncode}): {' '.join(argv)}\n{stderr or ''}")


def run(argv: list[str], *, check: bool = True, capture: bool = True, input: str | None = None, cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run argv and return the CompletedProcess.

    capture=True (default) captures stdout/stderr as text for the caller to
    inspect; capture=False lets them pass through live to this process's
    own stdout/stderr -- for anything the user should see as it happens
    (an interactive ssh -tt session, a long rsync/push).
    """
    result = subprocess.run(
        argv,
        text=True,
        cwd=cwd,
        input=input,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        raise CommandError(argv, result.returncode, result.stdout, result.stderr)
    return result
