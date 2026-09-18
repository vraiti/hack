"""Hand-rolled wrapper around the `git` binary.

pygit2 was considered for the local commit-plumbing half, but push needs to
stay on real `git` for SSH-agent/credential-helper compatibility (pygit2's
own SSH transport, via libssh2, has historically weaker support for modern
key types/agent setups than plain OpenSSH gives for free) -- see UTILS.md.
Since git stays external either way, this wraps the CLI entirely rather
than splitting the implementation across two libraries.
"""
from __future__ import annotations

import os
import subprocess

from . import _proc


def _git(repo_dir: str, *args: str, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return _proc.run(["git", "-C", repo_dir, *args], check=check, capture=capture)


def is_dirty(repo_dir: str) -> bool:
    return bool(_git(repo_dir, "status", "--porcelain").stdout.strip())


def current_branch(repo_dir: str) -> str | None:
    """None means detached HEAD (mirrors `git branch --show-current`, which
    prints nothing in that case)."""
    branch = _git(repo_dir, "branch", "--show-current").stdout.strip()
    return branch or None


def rev_parse(repo_dir: str, rev: str, *, short: bool = False) -> str:
    args = ["rev-parse"]
    if short:
        args.append("--short")
    args.append(rev)
    return _git(repo_dir, *args).stdout.strip()


def ref_exists(repo_dir: str, ref: str) -> bool:
    return _git(repo_dir, "show-ref", "--verify", "--quiet", ref, check=False).returncode == 0


def add_all(repo_dir: str) -> None:
    _git(repo_dir, "add", "-A")


def write_tree(repo_dir: str) -> str:
    return _git(repo_dir, "write-tree").stdout.strip()


def committer_ident(repo_dir: str) -> str:
    return _git(repo_dir, "var", "GIT_COMMITTER_IDENT").stdout.strip()


def commit_tree(repo_dir: str, tree: str, parents: list[str], message: str) -> str:
    args = ["commit-tree", tree]
    for parent in parents:
        args += ["-p", parent]
    args += ["-m", message]
    return _git(repo_dir, *args).stdout.strip()


def update_ref(repo_dir: str, ref: str, sha: str) -> None:
    _git(repo_dir, "update-ref", ref, sha)


def checkout(repo_dir: str, branch: str) -> None:
    _git(repo_dir, "checkout", branch)


def symbolic_ref_exists(repo_dir: str, ref: str = "HEAD") -> bool:
    """True unless repo_dir is in detached-HEAD state."""
    return _git(repo_dir, "symbolic-ref", "-q", ref, check=False).returncode == 0


def config_get(repo_dir: str, key: str) -> str | None:
    result = _git(repo_dir, "config", "--get", key, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def push(repo_dir: str, remote: str, branch: str, *, set_upstream: bool = True) -> None:
    args = ["push"]
    if set_upstream:
        args.append("-u")
    args += [remote, branch]
    _git(repo_dir, *args, capture=False)


def submodule_status(repo_dir: str) -> list[tuple[str, str, bool]]:
    """[(sha, path, initialized), ...] -- mirrors `git submodule status`
    lines ("[-+U ]<sha><path> [(<describe>)]"); a leading '-' means not
    initialized (nothing to sync/commit/push for it)."""
    result = _git(repo_dir, "submodule", "status", check=False)
    entries = []
    for line in result.stdout.splitlines():
        if not line:
            continue
        flag, rest = line[0], line[1:]
        sha, path = rest.split()[:2]
        entries.append((sha, path, flag != "-"))
    return entries


def signed_off_trailer(repo_dir: str) -> str:
    """Same trailer `git commit -s` would add -- commit-tree has no -s of
    its own, so it's built by hand from GIT_COMMITTER_IDENT with the
    trailing "<timestamp> <tz>" stripped."""
    ident = committer_ident(repo_dir)
    name_email = ident.rsplit(" ", 2)[0]
    return f"Signed-off-by: {name_email}"


def archive_to(repo_dir: str, commit: str, dest_dir: str) -> None:
    """git archive <commit> | tar -x -C <dest_dir> -- exports exactly the
    committed tree, not the working directory (this is what keeps an
    untracked-but-not-gitignored stray file from ever reaching a synced
    remote). Streams the archive through an OS pipe between the two
    subprocesses rather than buffering it in this process as text -- a git
    archive is a binary tar stream and can be large, so reading it via
    _proc.run's text=True capture would both risk a UnicodeDecodeError on
    binary file content and hold the whole archive in memory at once.
    """
    with subprocess.Popen(["git", "-C", repo_dir, "archive", commit], stdout=subprocess.PIPE) as git_proc:
        assert git_proc.stdout is not None  # guaranteed by stdout=PIPE above
        with subprocess.Popen(["tar", "-x", "-C", dest_dir], stdin=git_proc.stdout) as tar_proc:
            git_proc.stdout.close()  # let tar_proc see EOF/SIGPIPE correctly if it exits first
            tar_proc.wait()
        git_proc.wait()

    if git_proc.returncode != 0:
        raise _proc.CommandError(["git", "-C", repo_dir, "archive", commit], git_proc.returncode, None, None)
    if tar_proc.returncode != 0:
        raise _proc.CommandError(["tar", "-x", "-C", dest_dir], tar_proc.returncode, None, None)


def archive_repo_tree(repo_dir: str, commit: str, dest_dir: str) -> None:
    """Recursive version of archive_to: also archives each initialized
    submodule's own committed tree into the corresponding subdirectory --
    `git archive` on the parent alone only emits an empty directory for a
    submodule path (a gitlink, not real content), so that directory (already
    created by the parent's own extraction) needs its contents filled in
    separately, recursing for submodules-of-submodules."""
    archive_to(repo_dir, commit, dest_dir)
    for sha, path, initialized in submodule_status(repo_dir):
        if initialized:
            archive_repo_tree(os.path.join(repo_dir, path), sha, os.path.join(dest_dir, path))


def auto_commit_tree(repo_dir: str) -> None:
    """Commit any uncommitted changes (and initialized submodules,
    recursively) onto AUTOCOMMIT/<branch> via plumbing rather than
    checkout-then-commit. Across enough runs, AUTOCOMMIT/<branch>'s last
    snapshot and the current dirty tree inevitably disagree on some file
    (the real branch moved, or was edited again since), and checking out a
    branch whose committed content differs from an uncommitted local change
    is exactly what `git checkout` correctly refuses to do ("would be
    overwritten by checkout"). write-tree snapshots the current index
    (right after add -A, that's exactly the working tree), so the new
    commit's tree already equals the working tree by construction --
    update-ref moves the branch onto it without touching the working tree
    at all, making the final checkout always a genuine no-op.
    """
    if is_dirty(repo_dir):
        branch = current_branch(repo_dir)
        if branch is None:
            branch = f"detached-{rev_parse(repo_dir, 'HEAD', short=True)}"
        auto_branch = branch if branch.startswith("AUTOCOMMIT/") else f"AUTOCOMMIT/{branch}"

        add_all(repo_dir)
        tree = write_tree(repo_dir)
        ref = f"refs/heads/{auto_branch}"
        parent = rev_parse(repo_dir, ref) if ref_exists(repo_dir, ref) else rev_parse(repo_dir, "HEAD")
        message = f"run-remote auto-commit\n\n{signed_off_trailer(repo_dir)}"
        commit_sha = commit_tree(repo_dir, tree, [parent], message)
        update_ref(repo_dir, ref, commit_sha)
        checkout(repo_dir, auto_branch)

    for _sha, path, initialized in submodule_status(repo_dir):
        if initialized:
            auto_commit_tree(os.path.join(repo_dir, path))
