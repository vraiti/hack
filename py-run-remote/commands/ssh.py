"""Hand-rolled wrapper around the `ssh` binary.

Kept external rather than replaced with paramiko/asyncssh/Fabric -- see
UTILS.md: none of those reliably cover this setup's ~/.ssh/config features
(aws-manage's `awsm` Host aliases, ProxyJump, ControlMaster/ControlPersist)
or give PTY-passthrough streaming as simply as the real client does for the
reconnecting watch-loop use case below.
"""
from __future__ import annotations

import base64
import shlex
import subprocess

from . import _proc

# Python's equivalent of run-remote.sh's `printf '%q'` -- use this to quote
# any interpolated value before building a remote_command string below.
quote = shlex.quote


def run(alias: str, remote_command: str, *, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    """ssh <alias> <remote_command> -- remote_command is shell text executed
    by the remote's login shell, exactly like `ssh alias 'cmd'` on the
    command line. Build it with quote() for any interpolated values."""
    return _proc.run(["ssh", alias, remote_command], check=check, capture=capture)


def run_tty(alias: str, remote_command: str) -> int:
    """ssh -tt <alias> <remote_command>, inheriting this process's own
    stdin/stdout/stderr so a real PTY is allocated and output streams live.
    Used for the reconnecting watch loop, where the remote job's output has
    to appear in the user's terminal as it happens, not after the fact --
    something a captured/buffered subprocess call can't give you."""
    return subprocess.call(["ssh", "-tt", alias, remote_command])


def run_script(alias: str, script: str, *, background: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """Run a multi-line script on the remote (the GC scan, an ad hoc setup
    step). base64-encodes it first so it survives ssh's flatten-and-reparse
    of all trailing arguments into one string -- a raw multi-line or
    quote-heavy script would otherwise need its own quoting pass for every
    layer of wrapping (nohup, bash -c, ssh itself), and getting one wrong
    silently breaks things (an earlier `&` vs `&&` precedence bug
    backgrounded a whole command chain instead of just the intended job).
    Base64's alphabet has no shell metacharacters, so it survives any
    number of reparses unmodified."""
    b64 = base64.b64encode(script.encode()).decode()
    remote_cmd = f'bash -c "$(echo {b64} | base64 -d)"'
    if background:
        remote_cmd = f"nohup {remote_cmd} < /dev/null > /dev/null 2>&1 & disown"
    return run(alias, remote_cmd, check=check)


def test_path(alias: str, path: str, kind: str = "d") -> bool:
    """True if `test -<kind> path` succeeds on the remote (kind: d/f/e/...)."""
    return run(alias, f"test -{kind} {quote(path)}", check=False).returncode == 0


def read_remote_file(alias: str, path: str, default: str | None = None) -> str | None:
    result = run(alias, f"cat {quote(path)} 2>/dev/null", check=False)
    return result.stdout if result.returncode == 0 else default


def echo_env(alias: str, var: str) -> str:
    """Resolve a remote-side shell expansion (e.g. $HOME) once, so callers
    get back a plain concrete string instead of having to track whether a
    later string is raw shell text (which a remote shell would still
    expand) or quote()-escaped text (which wouldn't)."""
    return run(alias, f"echo ${var}").stdout.strip()


def spawn_background(alias: str, remote_command: str, *, log_file: str) -> None:
    """nohup bash -c <remote_command> < /dev/null > log_file 2>&1 & disown

    Survives a dropped network connection: nohup ignores the SIGHUP the
    shell would otherwise send on disconnect, and disown drops the job from
    the shell's own job table so the shell exiting doesn't touch it either.
    Watching it back is a separate concern (see run_tty) -- a reconnect
    just re-attaches, it never touches the already-running job.
    """
    inner = f"bash -c {quote(remote_command)}"
    launcher = f"nohup {inner} < /dev/null > {quote(log_file)} 2>&1 & disown"
    run(alias, launcher)
