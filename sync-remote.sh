#!/usr/bin/env bash
set -euo pipefail

# Syncs every repo named in a run-remote.sh profile's `sync` map (see
# profile.py -- an object of <relative path>: <label>, label one of
# default/site-package/push-only) to <remote-root> on <ssh-alias> via rsync.
# Meant to be invoked by run-remote.sh (which has already resolved the alias
# and any remote-side path expansion), but is self-contained enough to run
# standalone too. Falls back to <project-dir>/repos.txt (the same
# name[:label] format, one per line) when no --profile is given, for use
# without a profile.
ARGS=()
PROFILE_NAME=""
EXTRA_ENTRIES=()
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE_NAME="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE_NAME="${1#--profile=}"
            shift
            ;;
        --extra)
            EXTRA_ENTRIES+=("$2")
            shift 2
            ;;
        --extra=*)
            EXTRA_ENTRIES+=("${1#--extra=}")
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${ARGS[@]}"

# Informational, "everything's fine" progress messages only -- WARNING/ERROR
# (real problems) always print regardless of --quiet.
log() {
    [[ "$QUIET" -eq 1 ]] || echo "$@"
}

SSH_ALIAS="${1:?Usage: $0 <ssh-alias> <remote-root> [project-dir] [--profile NAME]}"
REMOTE_ROOT="${2:?Usage: $0 <ssh-alias> <remote-root> [project-dir] [--profile NAME]}"
PROJECT_DIR="${3:-}"

if [[ -n "$PROFILE_NAME" ]]; then
    PROFILE_PATH="$HOME/.local/hack/profiles/$PROFILE_NAME.json"
    if [[ ! -f "$PROFILE_PATH" ]]; then
        echo "ERROR: profile '$PROFILE_NAME' not found at $PROFILE_PATH" >&2
        exit 1
    fi
fi

# A profile's `local-home` (see profile.py) pins the project directory on
# this machine explicitly; an explicit [project-dir] argument still wins
# over it. Without either, use CWD.
if [[ -z "$PROJECT_DIR" && -n "$PROFILE_NAME" ]]; then
    PROJECT_DIR="$(jq -r '.["local-home"] // empty' "$PROFILE_PATH")"
fi
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

HAVE_PROFILE_SYNC=0
if [[ -n "$PROFILE_NAME" ]]; then
    # A profile without a `sync` key falls back to repos.txt below -- only a
    # profile that actually defines `sync` (even as `{}`) uses it as-is.
    if [[ "$(jq 'has("sync")' "$PROFILE_PATH")" == "true" ]]; then
        HAVE_PROFILE_SYNC=1
        mapfile -t ENTRIES < <(jq -r '.sync | to_entries[] | "\(.key):\(.value)"' "$PROFILE_PATH")
    fi
fi

if [[ "$HAVE_PROFILE_SYNC" -eq 0 ]]; then
    REPOS_FILE="$PROJECT_DIR/repos.txt"
    if [[ ! -f "$REPOS_FILE" ]]; then
        echo "ERROR: $REPOS_FILE not found" >&2
        exit 1
    fi
    mapfile -t ENTRIES < "$REPOS_FILE"
fi

# --extra NAME[:LABEL] (repeatable) appends entries on top of whatever the
# profile/repos.txt resolved, for repos a caller wants synced unconditionally
# regardless of what's in either -- e.g. run-remote.sh always adds its own
# toolset this way. NAME may be an absolute path (see resolve_repo_dir
# below); it doesn't have to live under PROJECT_DIR like profile/repos.txt
# entries do.
ENTRIES+=("${EXTRA_ENTRIES[@]}")

# A plain entry name is relative to PROJECT_DIR, same as always; an absolute
# NAME (as --extra can supply) is used as-is.
resolve_repo_dir() {
    local repo_name="$1"
    if [[ "$repo_name" == /* ]]; then
        echo "$repo_name"
    else
        echo "$PROJECT_DIR/$repo_name"
    fi
}

# Auto-commit any uncommitted changes in a repo (and its initialized
# submodules, recursively) rather than refusing to proceed -- run-remote's
# workflow is edit-locally-then-sync, so a dirty tree just means "not
# committed yet," not a hazard to route around.
auto_commit_tree() {
    local repo_dir="$1"
    if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
        log "Auto-committing uncommitted changes in $repo_dir..."
        git -C "$repo_dir" add -A
        git -C "$repo_dir" commit -q -s -m "run-remote auto-commit"
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "-" ]] && continue  # not initialized, nothing to commit
        local sub_path
        sub_path="$(awk '{print $2}' <<< "$line")"
        auto_commit_tree "$repo_dir/$sub_path"
    done < <(git -C "$repo_dir" submodule status 2>/dev/null)
}

# Do this upfront -- before any dependency rebuild, push, or sync happens,
# and entirely synchronously -- for every top-level sync directory
# (including push-only ones). Two reasons this has to happen here rather
# than lazily where each repo is later encountered: (1) discovering a dirty
# repo mid-run, after a background push already started, used to mean a
# silently-logged failure while everything else proceeded anyway; (2) the
# background push path (push_repo_and_submodules) and the foreground
# archive/rsync path below both touch the same repos, including the same
# submodules -- committing lazily in both places would race two concurrent
# `git commit`s against the same working tree/index.
for entry in "${ENTRIES[@]}"; do
    entry="${entry%%#*}"
    entry="${entry// /}"
    [[ -z "$entry" ]] && continue
    repo_name="${entry%%:*}"
    repo_dir="$(resolve_repo_dir "$repo_name")"
    [[ -e "$repo_dir/.git" ]] || continue
    auto_commit_tree "$repo_dir"
done

# A profile's `dependencies` key (see profile.py) is
# {<sync-directory>: {<upstream-sync-directory>: <rebuild-hook>}} -- before
# syncing anything, rebuild a directory whose upstream has moved since the
# last rebuild, so what gets synced below is never stale. A per-upstream
# marker file (".COMMIT_<upstream-sync-directory>", inside <sync-directory>)
# records the upstream commit the last rebuild was run against.
check_dependency() {
    local sync_dir="$1" upstream_dir="$2" hook="$3"
    local sync_path="$PROJECT_DIR/$sync_dir"
    local upstream_path="$PROJECT_DIR/$upstream_dir"
    local marker="$sync_path/.COMMIT_$upstream_dir"

    if [[ ! -e "$upstream_path/.git" ]]; then
        echo "WARNING: $upstream_path is not a git repo, skipping dependency check for $sync_dir" >&2
        return
    fi
    local upstream_head
    upstream_head="$(git -C "$upstream_path" rev-parse HEAD)"

    if [[ -f "$marker" && "$(cat "$marker")" == "$upstream_head" ]]; then
        return
    fi

    log "Rebuilding $sync_dir ($upstream_dir changed since last rebuild)..."
    ( cd "$PROJECT_DIR" && bash -c "$hook" )
    mkdir -p "$sync_path"
    echo "$upstream_head" > "$marker"
}

if [[ -n "$PROFILE_NAME" ]] && [[ "$(jq 'has("dependencies")' "$PROFILE_PATH")" == "true" ]]; then
    while IFS=$'\t' read -r sync_dir upstream_dir hook; do
        [[ -z "$sync_dir" ]] && continue
        check_dependency "$sync_dir" "$upstream_dir" "$hook"
    done < <(jq -r '.dependencies // {} | to_entries[] | .key as $dir | .value | to_entries[] | [$dir, .key, .value] | @tsv' "$PROFILE_PATH")
fi

# `git archive` only emits an empty directory for a submodule path (it's a
# gitlink, not real content) -- without this, a repo with an initialized
# submodule (e.g. python-tracer's cpython) would silently sync an empty
# directory instead of the submodule's actual files. Recurses to handle
# submodules-of-submodules too.
archive_repo_tree() {
    local repo_dir="$1" commit="$2" dest_dir="$3"
    git -C "$repo_dir" archive "$commit" | tar -x -C "$dest_dir"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # `git submodule status` lines: "[-+ ]<sha> <path> [(<describe>)]"
        [[ "${line:0:1}" == "-" ]] && continue  # not initialized, nothing to sync
        local sub_path sub_commit
        sub_path="$(awk '{print $2}' <<< "$line")"
        # Already committed by auto_commit_tree above, so this status line's
        # sha is already the final one -- no need to re-check or re-read it.
        sub_commit="$(awk '{print $1}' <<< "$line" | tr -d '+-')"
        archive_repo_tree "$repo_dir/$sub_path" "$sub_commit" "$dest_dir/$sub_path"
    done < <(git -C "$repo_dir" submodule status 2>/dev/null)
}

# For a `:push-only` repo, the remote is expected to `git pull` its own
# copy rather than receive one via rsync (see CLAUDE.md's remote-file-editing
# protocol). Recurses into submodules so each gets pushed too.
push_repo_and_submodules() {
    local repo_dir="$1"
    # Already committed by auto_commit_tree above -- just push.
    git -C "$repo_dir" push

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "-" ]] && continue  # not initialized, nothing to push
        local sub_path
        sub_path="$(awk '{print $2}' <<< "$line")"
        push_repo_and_submodules "$repo_dir/$sub_path"
    done < <(git -C "$repo_dir" submodule status 2>/dev/null)
}

background_pids=()
background_repo_names=()
PUSH_LOG_DIR="$(mktemp -d)"

# Iterating a bash array (rather than reading lines from the source file via
# a while-read loop) sidesteps the classic gotcha where ssh/rsync inside the
# loop body would otherwise inherit the loop's stdin redirect and drain the
# rest of the input as if it were their own -- no redirect here, so no
# draining is possible.
for entry in "${ENTRIES[@]}"; do
    entry="${entry%%#*}"
    entry="${entry// /}"
    [[ -z "$entry" ]] && continue

    repo_name="${entry%%:*}"
    label=""
    [[ "$entry" == *:* ]] && label="${entry#*:}"
    repo_dir="$(resolve_repo_dir "$repo_name")"
    # An absolute repo_name (e.g. from --extra) would otherwise put literal
    # "/" in the log filename below, which mkdir/redirect can't create as a
    # single path component.
    log_name="${repo_name//\//_}"

    if [[ ! -d "$repo_dir" ]]; then
        echo "WARNING: $repo_dir does not exist, skipping"
        continue
    fi

    if [[ "$label" == "push-only" ]]; then
        push_repo_and_submodules "$repo_dir" > "$PUSH_LOG_DIR/$log_name.log" 2>&1 &
        background_pids+=("$!")
        background_repo_names+=("$repo_name")
        continue
    fi

    # Every git repo (default/site-package alike) also gets pushed to its own
    # remote in the background, alongside whatever rsync-to-remote-host sync
    # happens below -- this is the same background-push behavior run-remote.sh
    # used to do itself via repos.txt, now folded in here so all syncing
    # logic lives in one place. A detached-HEAD repo (e.g. vllm, pinned to a
    # specific upstream commit as a site-package) has nothing to push and
    # `git push` there is a hard error, not a real failure -- skip it.
    if [[ -e "$repo_dir/.git" ]] && git -C "$repo_dir" symbolic-ref -q HEAD >/dev/null 2>&1; then
        push_repo_and_submodules "$repo_dir" > "$PUSH_LOG_DIR/$repo_name.log" 2>&1 &
        background_pids+=("$!")
        background_repo_names+=("$repo_name")
    fi

    # A marker file (excluded from rsync's own transfer/delete) records what
    # was last synced to this remote path. Nothing but this script modifies
    # remote source trees, so a local tree whose identity matches the marker
    # is guaranteed identical to what's already there -- skip the rsync scan
    # entirely. For a git repo that identity is HEAD's commit (and the tree
    # must be clean, so HEAD fully determines the content); for a plain
    # directory there's no commit to key off of, so a hash of every file's
    # path/mtime/size stands in for it instead.
    marker_path="$REMOTE_ROOT/$repo_name/.rrr-synced-commit"
    if [[ -e "$repo_dir/.git" ]]; then
        # Already committed by auto_commit_tree above -- just read HEAD.
        local_id="$(git -C "$repo_dir" rev-parse HEAD)"
    else
        local_id="$(find "$repo_dir" -type f -printf '%P %T@ %s\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')"
    fi
    remote_id="$(ssh "$SSH_ALIAS" "cat $(printf '%q' "$marker_path") 2>/dev/null" || true)"
    if [[ -n "$remote_id" && "$remote_id" == "$local_id" ]]; then
        log "Skipping $repo_name (unchanged since last sync)"
        continue
    fi

    log "Syncing $repo_name..."
    if [[ -e "$repo_dir/.git" ]]; then
        # Export exactly the committed tree at HEAD (via `git archive`) and
        # rsync --delete *that*, rather than the working directory --
        # gitignore-filtering the working directory still lets any
        # untracked-but-not-ignored file through, which is how a stray
        # `npm install` (e.g. agent-starter-react's 1GB+ node_modules,
        # already gitignored, but this closes the gap for anything that
        # ISN'T) could still end up on the remote. The archive only ever
        # contains what's actually committed.
        archive_dir="$(mktemp -d)"
        archive_repo_tree "$repo_dir" "$local_id" "$archive_dir"
        rsync -az --delete --exclude=.rrr-synced-commit \
            "$archive_dir/" "$SSH_ALIAS:$REMOTE_ROOT/$repo_name/"
        rm -rf "$archive_dir"
    else
        # No commit to export from -- fall back to syncing the working
        # directory directly.
        rsync -az --delete --exclude=.rrr-synced-commit \
            "$repo_dir/" "$SSH_ALIAS:$REMOTE_ROOT/$repo_name/"
    fi
    ssh "$SSH_ALIAS" "echo $(printf '%q' "$local_id") > $(printf '%q' "$marker_path")"
done

# Quiet on success; a failed push's log is the only thing printed, so a
# clean sync-remote.sh run stays silent about pushes entirely.
for i in "${!background_pids[@]}"; do
    if ! wait "${background_pids[$i]}"; then
        echo "git push (${background_repo_names[$i]}) FAILED:" >&2
        cat "$PUSH_LOG_DIR/${background_repo_names[$i]}.log" >&2
    fi
done
rm -rf "$PUSH_LOG_DIR"
