"""Builds a venv from a profile's `venv` list spec (see
models.VenvSpecEntry): entries applied in order, since installs can be
order-dependent. Called in-process by worker.py on the remote.
"""
from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

from commands import uv
from models import VenvSpecEntry

DEFAULT_PYTHON = uv.DEFAULT_PYTHON


def _cuda_env() -> dict[str, str]:
    # cuda-toolkit's rpm doesn't add itself to PATH, and this runs as part of
    # a non-interactive, non-login ssh session (or, now, an already-detached
    # worker process) -- /etc/profile.d/cuda.sh (which does add it) is never
    # sourced in that mode. Add it explicitly rather than depending on shell
    # startup files this invocation path skips.
    env = dict(os.environ)
    cuda_bin = Path("/usr/local/cuda/bin")
    if cuda_bin.is_dir():
        env["PATH"] = f"{cuda_bin}:{env.get('PATH', '')}"
        cuda_lib = "/usr/local/cuda/lib64"
        env["LD_LIBRARY_PATH"] = f"{cuda_lib}:{env['LD_LIBRARY_PATH']}" if env.get("LD_LIBRARY_PATH") else cuda_lib
    return env


def build_venv_from_spec(spec: list[VenvSpecEntry], venv_dir: str, project_root: str) -> None:
    # Model validation (models.Profile) already enforces the single-key
    # shape and the envvar-before-everything-else ordering at profile-load
    # time -- nothing left to re-check here.
    python_entries = [e for e in spec if e.type == "python"]
    if len(python_entries) > 1:
        raise ValueError('venv spec has more than one "python" entry')
    python_version = python_entries[0].content if python_entries else DEFAULT_PYTHON

    print(f"Creating venv at {venv_dir} (python {python_version})...")
    venv_path = Path(venv_dir)
    if venv_path.exists():
        import shutil

        shutil.rmtree(venv_path)
    venv_path.parent.mkdir(parents=True, exist_ok=True)
    env = _cuda_env()
    uv.create_venv(venv_dir, python_version)

    # Append each "envvar" entry's export to bin/activate *before* it's ever
    # sourced -- this file is still a real bash activate script, kept
    # sourceable by a future interactive `ssh host && source .../activate`,
    # even though worker.py itself builds the job's env directly rather than
    # sourcing this.
    activate_path = venv_path / "bin" / "activate"
    with activate_path.open("a") as f:
        for entry in spec:
            if entry.type != "envvar":
                continue
            if "=" not in entry.content:
                raise ValueError(f"envvar entry must be KEY=VALUE, got {entry.content!r}")
            key, _, value = entry.content.partition("=")
            f.write(f"export {key}={shlex.quote(value)}\n")

    for entry in spec:
        if entry.type in ("python", "envvar"):
            continue  # already applied above, before the venv was even created
        elif entry.type == "package":
            # CONTENT can be an argv-style string with flags (e.g. "-e
            # vllm-omni --no-build-isolation"); shlex.split (not a bare
            # str.split) matches shell word-splitting, including quoted
            # tokens.
            print(f"Installing package: {entry.content}")
            uv.pip_install(venv_dir, shlex.split(entry.content))
        elif entry.type == "requirements":
            print(f"Installing requirements from {entry.content}")
            uv.pip_install_requirements(venv_dir, os.path.join(project_root, entry.content))
        elif entry.type == "script":
            print(f"Running setup script: {entry.content}")
            subprocess.run(["bash", "-c", entry.content], cwd=project_root, env=env, check=True)
        elif entry.type == "package-script":
            _run_package_script(entry.content, venv_dir, project_root, env)
        else:
            raise ValueError(f"unknown venv spec type {entry.type!r}")

    print("Done.")


def _run_package_script(content: str, venv_dir: str, project_root: str, env: dict[str, str]) -> None:
    # content computes the package args itself (e.g. picking a wheel URL
    # based on the installed CUDA/torch version) rather than having them
    # hardcoded in the profile. It writes them to fd 3, one per line -- not
    # stdout -- since stdout/stderr stay free for normal progress output.
    #
    # os.pipe()'s write end can land on any fd number; pass_fds alone would
    # preserve *that* number through exec, not remap it to the literal "3"
    # the script writes to. preexec_fn (runs in the child, after fork,
    # before exec) dup2's it onto fd 3 specifically; pass_fds=(3,) then
    # keeps that dup alive through the exec's close-all-other-fds step
    # (the now-redundant original fd number is closed along with everything
    # else).
    print(f"Running package script: {content}")
    read_fd, write_fd = os.pipe()
    returncode = None
    try:
        proc = subprocess.Popen(
            ["bash", "-c", content],
            cwd=project_root,
            env=env,
            pass_fds=(3,),
            preexec_fn=lambda: os.dup2(write_fd, 3),
        )
        os.close(write_fd)
        write_fd = -1
        with os.fdopen(read_fd, "r") as pkg_output:
            read_fd = -1
            pkg_args = [line.strip() for line in pkg_output if line.strip()]
        returncode = proc.wait()
    finally:
        if write_fd != -1:
            os.close(write_fd)
        if read_fd != -1:
            os.close(read_fd)

    if returncode != 0:
        raise subprocess.CalledProcessError(returncode, ["bash", "-c", content])
    if not pkg_args:
        raise RuntimeError("package-script wrote no packages to fd 3")
    print(f"Installing packages from script: {' '.join(pkg_args)}")
    uv.pip_install(venv_dir, pkg_args)
