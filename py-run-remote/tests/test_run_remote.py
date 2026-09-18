"""Covers the manual verification of run_remote.py: CLI arg parsing (the
append-args-after-not-instead-of-the-profile-command bug found and fixed
this session), and a fully mocked end-to-end orchestration run.
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import pytest

import recipes
import run_remote


def test_parse_args_quiet_and_profile_only() -> None:
    assert run_remote.parse_args(["-q", "myprofile"]) == (True, "myprofile", [])


def test_parse_args_extra_args_after_dashdash() -> None:
    assert run_remote.parse_args(["myprofile", "--", "python", "foo.py", "--flag"]) == (
        False,
        "myprofile",
        ["python", "foo.py", "--flag"],
    )


def test_parse_args_requires_exactly_one_profile() -> None:
    with pytest.raises(SystemExit):
        run_remote.parse_args([])


@pytest.fixture
def hack_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "hackhome"
    (home / ".local" / "hack" / "profiles").mkdir(parents=True)
    monkeypatch.setattr(recipes, "PROFILE_DIR", home / ".local" / "hack" / "profiles")
    monkeypatch.setattr(recipes, "SECRETS_DIR", home / ".local" / "hack" / "profiles" / "secrets")
    return home


def _write_profile(home: Path, name: str, content: str) -> None:
    (home / ".local" / "hack" / "profiles" / f"{name}.yaml").write_text(content, encoding="utf-8")


def test_main_appends_extra_args_after_profile_command(
    hack_home: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Regression test for a real bug: `--` args must be appended after the
    profile's own command, not replace it."""
    _write_profile(
        hack_home,
        "testprof",
        "venv:\n- python: '3.12'\nenv:\n  FOO: bar\ncommand:\n- echo\n- hello\n",
    )
    monkeypatch.chdir(tmp_path)

    log: dict[str, str] = {}

    # alias/check/capture aren't read by this fake, but their names have to
    # match sshw.run's real signature since some call sites pass check=/
    # capture=/input= by keyword.
    # pylint: disable-next=unused-argument,redefined-builtin
    def fake_run(alias: str, cmd: str, check: bool = True, capture: bool = True, input: str | None = None) -> mock.Mock:
        if "echo $HOME/vraiti" in cmd:
            return mock.Mock(returncode=0, stdout="/home/remoteuser/vraiti")
        if cmd.startswith("cat > "):
            assert input is not None
            log["job_json"] = input
            return mock.Mock(returncode=0, stdout="")
        if cmd.startswith("python3 ") and "worker.py" in cmd:
            log["worker_cmd"] = cmd
            return mock.Mock(returncode=0, stdout="")
        return mock.Mock(returncode=0, stdout="")

    with mock.patch.object(run_remote.sshw, "run", fake_run), \
            mock.patch.object(run_remote.sshw, "echo_env", lambda alias, var: "/home/remoteuser"), \
            mock.patch.object(run_remote.sshw, "test_path", lambda alias, path, kind="d": True), \
            mock.patch.object(run_remote.sshw, "read_remote_file", lambda alias, path, default=None: "3"), \
            mock.patch.object(run_remote.sshw, "run_tty", lambda alias, cmd: 0), \
            mock.patch.object(run_remote.sync, "sync_all", lambda *a, **k: None), \
            mock.patch.object(run_remote.sync, "sync_toolset", lambda alias: "/tmp/py-run-remote"), \
            mock.patch.object(run_remote.hostresolve, "resolve_default_host", lambda: "fake-alias"), \
            mock.patch("sys.argv", ["run-remote", "-q", "testprof", "--", "--extra-flag"]):
        exit_code = run_remote.main()

    assert exit_code == 3
    job = json.loads(log["job_json"])  # str, guaranteed by the assert inside fake_run above
    assert job["command"] == ["echo", "hello", "--extra-flag"]
    assert job["env"] == {"FOO": "bar"}
    assert log["worker_cmd"] == "python3 /tmp/py-run-remote/worker.py /tmp/py-run-remote/job.json"
