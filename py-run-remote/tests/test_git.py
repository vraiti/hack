"""Covers the manual verification of commands/git.py's plumbing-based
auto_commit_tree (the fix for the "autocommitting seems broken" checkout
race) and the submodule-aware archive/status helpers.
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable

from commands import git as gitw


def test_auto_commit_tree_first_run(
    make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    repo = make_git_repo()
    (repo / "file.txt").write_text("one", encoding="utf-8")
    commit_all(repo, "initial")
    (repo / "file.txt").write_text("two", encoding="utf-8")

    assert gitw.is_dirty(repo_dir := str(repo))
    gitw.auto_commit_tree(repo_dir)

    assert not gitw.is_dirty(repo_dir)
    assert gitw.current_branch(repo_dir) == "AUTOCOMMIT/master"
    assert (repo / "file.txt").read_text(encoding="utf-8") == "two"


def test_auto_commit_tree_chains_across_repeated_dirty_edits(
    make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    """Reproduces the originally-broken scenario: repeated dirty edits while
    already on an AUTOCOMMIT/* branch. The old checkout-then-commit
    implementation failed here with "would be overwritten by checkout" once
    the branch's last snapshot and a new dirty edit disagreed; the plumbing
    version must chain commits without ever needing a conflicting checkout.
    """
    repo = make_git_repo()
    (repo / "file.txt").write_text("one", encoding="utf-8")
    commit_all(repo, "initial")

    (repo / "file.txt").write_text("two", encoding="utf-8")
    gitw.auto_commit_tree(str(repo))
    (repo / "file.txt").write_text("three", encoding="utf-8")
    gitw.auto_commit_tree(str(repo))
    (repo / "file.txt").write_text("four", encoding="utf-8")
    gitw.auto_commit_tree(str(repo))

    assert not gitw.is_dirty(str(repo))
    assert (repo / "file.txt").read_text(encoding="utf-8") == "four"
    log = subprocess.run(
        ["git", "-C", str(repo), "log", "--oneline"], check=True, capture_output=True, text=True
    ).stdout
    assert log.count("run-remote auto-commit") == 3
    assert "initial" in log


def test_auto_commit_tree_recurses_into_submodules(
    make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str]
) -> None:
    sub = make_git_repo("sub")
    (sub / "subfile.txt").write_text("subcontent", encoding="utf-8")
    commit_all(sub, "sub initial")

    parent = make_git_repo("parent")
    subprocess.run(
        ["git", "-c", "protocol.file.allow=always", "-C", str(parent), "submodule", "add", "-q", str(sub), "subdir"],
        check=True,
    )
    commit_all(parent, "add submodule")

    (parent / "subdir" / "subfile.txt").write_text("sub edit", encoding="utf-8")
    assert gitw.submodule_status(str(parent)) == [
        (gitw.rev_parse(str(parent / "subdir"), "HEAD"), "subdir", True)
    ]

    gitw.auto_commit_tree(str(parent))

    assert not gitw.is_dirty(str(parent / "subdir"))
    assert gitw.current_branch(str(parent / "subdir")) == "AUTOCOMMIT/master"


def test_archive_repo_tree_includes_submodule_content(
    make_git_repo: Callable[..., Path], commit_all: Callable[[Path, str], str], tmp_path: Path
) -> None:
    sub = make_git_repo("sub")
    (sub / "subfile.txt").write_text("subcontent", encoding="utf-8")
    commit_all(sub, "sub initial")

    parent = make_git_repo("parent")
    (parent / "top.txt").write_text("top", encoding="utf-8")
    subprocess.run(
        ["git", "-c", "protocol.file.allow=always", "-C", str(parent), "submodule", "add", "-q", str(sub), "subdir"],
        check=True,
    )
    head = commit_all(parent, "add submodule and top file")

    dest = tmp_path / "archive-out"
    dest.mkdir()
    gitw.archive_repo_tree(str(parent), head, str(dest))

    assert (dest / "top.txt").read_text(encoding="utf-8") == "top"
    assert (dest / "subdir" / "subfile.txt").read_text(encoding="utf-8") == "subcontent"
