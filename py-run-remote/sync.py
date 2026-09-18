"""Syncs every repo named in a profile's `sync` map to <remote-root> on
<ssh-alias> via rsync, plus this toolset's own working tree to an auxiliary
remote tmpdir for worker.py to run from.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from typing import Callable

from commands import git as gitw
from commands import rsync as rsyncw
from commands import ssh as sshw
from models import Profile

TOOLSET_REMOTE_DIR = "/tmp/py-run-remote"


def toolset_local_dir() -> Path:
    return Path(__file__).resolve().parent


def sync_toolset(alias: str) -> str:
    """rsyncs py-run-remote/ itself to an auxiliary remote tmpdir, so
    worker.py exists there as a real file before it's ever invoked --
    directly, not via a committed/pushed git checkout, so it works
    regardless of whether the local working tree is even committed."""
    rsyncw.sync(str(toolset_local_dir()), alias, TOOLSET_REMOTE_DIR)
    return TOOLSET_REMOTE_DIR


def resolve_repo_dir(repo_name: str, project_dir: str) -> str:
    if repo_name.startswith("/"):
        return repo_name
    return os.path.join(project_dir, repo_name)


def check_dependency(
    project_dir: str, sync_dir: str, upstream_dir: str, hook: str, *, log: Callable[..., None]
) -> None:
    """A profile's `dependencies` key is {<sync-dir>: {<upstream-dir>:
    <rebuild-hook>}} -- before syncing anything, rebuild sync_dir if
    upstream_dir's HEAD has moved since the last rebuild. A per-upstream
    marker file (inside sync_dir) records the upstream commit the last
    rebuild ran against."""
    sync_path = os.path.join(project_dir, sync_dir)
    upstream_path = os.path.join(project_dir, upstream_dir)
    marker = os.path.join(sync_path, f".COMMIT_{upstream_dir}")

    if not os.path.exists(os.path.join(upstream_path, ".git")):
        print(f"WARNING: {upstream_path} is not a git repo, skipping dependency check for {sync_dir}")
        return
    upstream_head = gitw.rev_parse(upstream_path, "HEAD")

    if os.path.isfile(marker) and Path(marker).read_text(encoding="utf-8").strip() == upstream_head:
        return

    log(f"Rebuilding {sync_dir} ({upstream_dir} changed since last rebuild)...")
    subprocess.run(["bash", "-c", hook], cwd=project_dir, check=True)
    Path(sync_path).mkdir(parents=True, exist_ok=True)
    Path(marker).write_text(upstream_head + "\n", encoding="utf-8")


def push_repo_and_submodules(repo_dir: str) -> None:
    """For a `:push-only` repo, the remote is expected to `git pull` its own
    copy rather than receive one via rsync. Recurses into submodules so each
    gets pushed too. An auto-commit branch has no upstream yet -- resolve
    its remote from the branch it was based on, then establish tracking."""
    branch = gitw.current_branch(repo_dir)
    if branch is None:
        raise RuntimeError(f"cannot push {repo_dir} with detached HEAD")
    source_branch = branch.removeprefix("AUTOCOMMIT/")
    remote = gitw.config_get(repo_dir, f"branch.{source_branch}.remote")
    if not remote:
        raise RuntimeError(f"no remote configured for source branch {source_branch} in {repo_dir}")

    gitw.push(repo_dir, remote, branch)

    for _sha, path, initialized in gitw.submodule_status(repo_dir):
        if initialized:
            push_repo_and_submodules(os.path.join(repo_dir, path))


def _local_identity(repo_dir: str) -> str:
    """A git repo's identity is HEAD's commit (already committed and clean
    by the time this runs); a plain directory hashes every file's
    path/mtime/size instead, since there's no commit to key off of."""
    if os.path.exists(os.path.join(repo_dir, ".git")):
        return gitw.rev_parse(repo_dir, "HEAD")
    digest = hashlib.sha256()
    entries = []
    for root, _dirs, files in os.walk(repo_dir):
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, repo_dir)
            stat = os.stat(path)
            entries.append(f"{rel} {stat.st_mtime} {stat.st_size}")
    for line in sorted(entries):
        digest.update(line.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def _sync_one_repo(alias: str, remote_root: str, repo_name: str, repo_dir: str, *, log: Callable[..., None]) -> None:
    marker_path = f"{remote_root}/{repo_name}/.rrr-synced-commit"
    local_id = _local_identity(repo_dir)
    remote_id = sshw.read_remote_file(alias, marker_path, default="")
    if remote_id and remote_id.strip() == local_id:
        log(f"Skipping {repo_name} (unchanged since last sync)")
        return

    log(f"Syncing {repo_name}...")
    if os.path.exists(os.path.join(repo_dir, ".git")):
        # Export exactly the committed tree at HEAD, not the working
        # directory -- gitignore-filtering the working directory still lets
        # an untracked-but-not-ignored file through; the archive only ever
        # contains what's actually committed.
        with tempfile.TemporaryDirectory() as archive_dir:
            gitw.archive_repo_tree(repo_dir, local_id, archive_dir)
            rsyncw.sync(archive_dir, alias, f"{remote_root}/{repo_name}", exclude=[".rrr-synced-commit"])
    else:
        rsyncw.sync(repo_dir, alias, f"{remote_root}/{repo_name}", exclude=[".rrr-synced-commit"])

    sshw.run(alias, f"echo {sshw.quote(local_id)} > {sshw.quote(marker_path)}")


# pylint: disable-next=too-many-arguments,too-many-locals,too-many-branches
def sync_all(
    alias: str,
    remote_root: str,
    project_dir: str,
    profile: Profile | None,
    *,
    extra_entries: list[tuple[str, str]] | None = None,
    quiet: bool = False,
) -> None:
    """entries: list of (repo_name, label) pairs, label one of
    default/site-package/push-only. extra_entries are appended unconditionally
    (e.g. the toolset itself)."""

    def log(*args: object) -> None:
        if not quiet:
            print(*args)

    entries: list[tuple[str, str]] = []
    if profile is not None and profile.sync:
        entries = list(profile.sync.items())
    else:
        repos_file = Path(project_dir) / "repos.txt"
        if not repos_file.is_file():
            raise RuntimeError(f"{repos_file} not found")
        for line in repos_file.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].replace(" ", "")
            if not line:
                continue
            name, _, label = line.partition(":")
            entries.append((name, label or "default"))
    entries += extra_entries or []

    # Auto-commit any uncommitted changes upfront, synchronously, for every
    # entry (including push-only ones) before any background push or
    # foreground rsync starts -- both touch the same repos (including
    # submodules), so committing lazily in either place would race two
    # concurrent commits against the same working tree/index.
    for repo_name, _label in entries:
        repo_dir = resolve_repo_dir(repo_name, project_dir)
        if os.path.exists(os.path.join(repo_dir, ".git")):
            gitw.auto_commit_tree(repo_dir)

    if profile is not None:
        for sync_dir, upstream_map in profile.dependencies.items():
            for upstream_dir, hook in upstream_map.items():
                check_dependency(project_dir, sync_dir, upstream_dir, hook, log=log)

    futures: list[tuple[Future, str]] = []
    with ThreadPoolExecutor() as executor:
        for repo_name, label in entries:
            repo_dir = resolve_repo_dir(repo_name, project_dir)
            if not os.path.isdir(repo_dir):
                print(f"WARNING: {repo_dir} does not exist, skipping")
                continue

            has_head = os.path.exists(os.path.join(repo_dir, ".git")) and gitw.symbolic_ref_exists(repo_dir)
            if label == "push-only":
                futures.append((executor.submit(push_repo_and_submodules, repo_dir), repo_name))
                continue
            if has_head:
                # Every non-push-only git repo also gets pushed to its own
                # remote in the background, alongside the foreground rsync
                # below. A detached-HEAD repo (e.g. a site-package pinned to
                # a specific upstream commit) has nothing to push.
                futures.append((executor.submit(push_repo_and_submodules, repo_dir), repo_name))

            _sync_one_repo(alias, remote_root, repo_name, repo_dir, log=log)

        for future, repo_name in futures:
            try:
                future.result()
            except Exception as e:  # pylint: disable=broad-exception-caught
                # One repo's push failing shouldn't crash the whole sync or
                # hide the other repos' results -- report and move on, same
                # as a background job's own failure would just log.
                print(f"git push ({repo_name}) FAILED: {e}")
