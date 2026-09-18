#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Mirror everything this script prints (including the remote job's output,
# streamed live through the ssh -tt watch loop below) to a local log file,
# in addition to the terminal -- so a run can be inspected after the fact
# even though the terminal itself is the primary, interactive output.
LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run-remote.log") 2>&1

resolve_alias() {
    # Delegates to aws-manage's own default-host resolution (the sole
    # `Host` block in its consolidated config.d/awsm) rather than scanning
    # every file under ~/.ssh/config.d/ -- only aws-manage aliases count
    # as an implicit default here.
    "$SCRIPT_DIR/aws-manage/default-host.sh"
}

# -q suppresses the profile dump/venv-creation/reconnect chatter. A literal
# `--` (as in git/kubectl) marks the start of extra args to append to the
# profile's `command`; everything before it besides -q must be exactly the
# required <profile> positional.
QUIET=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q)
            QUIET=1
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

MAIN_ARGS=()
APPEND_ARGS=()
found_dash=0
for a in "${ARGS[@]}"; do
    if [[ "$found_dash" -eq 0 && "$a" == "--" ]]; then
        found_dash=1
        continue
    fi
    if [[ "$found_dash" -eq 1 ]]; then
        APPEND_ARGS+=("$a")
    else
        MAIN_ARGS+=("$a")
    fi
done
set -- "${MAIN_ARGS[@]}"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [-q] <profile> [-- args...]" >&2
    exit 1
fi
PROFILE_NAME="$1"

# ~/.local/hack/profiles/<name>.yaml (written by profile.py) supplies venv,
# env, host/home, and the command to run -- run-remote no longer takes any
# of those on the CLI, only which profile to use.
PROFILE_PATH="$HOME/.local/hack/profiles/$PROFILE_NAME.yaml"
if [[ ! -f "$PROFILE_PATH" ]]; then
    echo "ERROR: profile '$PROFILE_NAME' not found at $PROFILE_PATH" >&2
    exit 1
fi
# Secrets live outside the (git-tracked) profile YAML, in a gitignored
# sibling file written by `profile.py ... secret=KEY=VALUE` -- one KEY=VALUE
# per line.
SECRETS_PATH="$HOME/.local/hack/profiles/secrets/$PROFILE_NAME.txt"
if [[ "$QUIET" -ne 1 ]]; then
    echo "Using profile '$PROFILE_NAME':"
    cat "$PROFILE_PATH"
    if [[ -f "$SECRETS_PATH" ]]; then
        echo "Using secrets:"
        cut -d= -f1 "$SECRETS_PATH"
    fi
fi

# jq needs JSON, but profiles are authored as YAML (profile.py) -- convert
# once up front and query this derived JSON everywhere below instead of
# PROFILE_PATH itself.
PROFILE_JSON="$(python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(sys.stdin) or {}, sys.stdout)' < "$PROFILE_PATH")"

# A profile's `venv` is a list of single-key entries, {TYPE: CONTENT} with
# TYPE one of "python"/"package"/"requirements"/"script"/"package-script"/
# "envvar",
# in the order they should be applied -- see create-venv-from-spec.sh. There's no more
# "plain name pointing at an existing/default venv directory" mode: every
# profile must spell out how to build its venv. The real venv is
# content-addressed (SHA256 of its canonical JSON, not an order-independent
# hash -- installs can be order-dependent) at
# ~/.venvs/venvs/venv-<hash>, shared across any profile that happens to
# specify the identical spec; ~/.venvs/<profile-name> is kept as a symlink
# to it purely for debugability (a readable name in `ps`/paths instead of a
# hash), see below.
VENV_TYPE="$(jq -r '.venv | type' <<< "$PROFILE_JSON")"
if [[ "$VENV_TYPE" != "array" ]]; then
    echo "ERROR: profile '$PROFILE_NAME' has no venv spec -- \"venv\" must be a list of" \
         "{python|package|requirements|script|package-script|envvar: ...} entries (see profile.py's venv=TYPE:CONTENT)" >&2
    exit 1
fi
VENV_SPEC_JSON="$(jq -c '.venv' <<< "$PROFILE_JSON")"
VENV_SPEC_HASH="$(printf '%s' "$VENV_SPEC_JSON" | sha256sum | cut -d' ' -f1)"

EXTRA_ENV=()
while IFS= read -r kv; do
    EXTRA_ENV+=("$kv")
done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<< "$PROFILE_JSON")

# Appended after the JSON env so a secret wins on a key collision.
if [[ -f "$SECRETS_PATH" ]]; then
    while IFS= read -r kv; do
        [[ -n "$kv" ]] && EXTRA_ENV+=("$kv")
    done < "$SECRETS_PATH"
fi

PROFILE_HOST="$(jq -r '.host // empty' <<< "$PROFILE_JSON")"
PROFILE_HOME="$(jq -r '.home // empty' <<< "$PROFILE_JSON")"
PROFILE_LOCAL_HOME="$(jq -r '.["local-home"] // empty' <<< "$PROFILE_JSON")"
PROFILE_INITIALIZER="$(jq -r '.initializer // empty' <<< "$PROFILE_JSON")"

PROFILE_COMMAND=()
while IFS= read -r arg; do
    PROFILE_COMMAND+=("$arg")
done < <(jq -r '.command // [] | .[]' <<< "$PROFILE_JSON")
if [[ ${#PROFILE_COMMAND[@]} -eq 0 ]]; then
    echo "ERROR: profile '$PROFILE_NAME' has no \"command\"" >&2
    exit 1
fi
set -- "${PROFILE_COMMAND[@]}"

# Single-quoted so the literal text ($HOME, unexpanded) survives until it's
# sent to the remote shell below -- it must expand against the remote
# user's home, not whatever $HOME happens to be on this machine. A profile's
# `home` supplies a non-default value here.
REMOTE_ROOT="${PROFILE_HOME:-\$HOME/vraiti}"
if [[ -n "${PROFILE_HOST:-}" ]]; then
    SSH_ALIAS="$PROFILE_HOST"
elif SSH_ALIAS=$(resolve_alias); then
    :
else
    echo "ERROR: could not resolve a default host, set \"host\" in the profile" >&2
    exit 1
fi

# Resolve any remote-side expansion (e.g. $HOME) once, up front, so every
# other use of REMOTE_ROOT below is a plain, already-concrete path -- it
# doesn't need to know whether it's embedded in a raw ssh command string
# (which a remote shell would expand) or a printf %q-escaped one (which
# would escape the literal '$' and never expand it).
REMOTE_ROOT="$(ssh "$SSH_ALIAS" "echo $REMOTE_ROOT")"
ssh "$SSH_ALIAS" "mkdir -p $(printf '%q' "$REMOTE_ROOT")"

REMOTE_HOME="$(ssh "$SSH_ALIAS" 'echo $HOME')"

# REAL_VENV_DIR is the actual, content-addressed venv (reused across any
# profile with the identical spec); REMOTE_VENV_DIR -- what everything below
# actually activates -- is a per-profile symlink to it, so a stack trace,
# `ps`, or a manual `ssh host source ~/.venvs/<profile>/bin/activate` shows
# this profile's name instead of a hash. The symlink is (re)pointed at
# REAL_VENV_DIR every run (see below), so it always tracks the profile's
# current spec even if that spec changes between runs.
REAL_VENV_DIR="$REMOTE_HOME/.venvs/venvs/venv-$VENV_SPEC_HASH"
REMOTE_VENV_DIR="$REMOTE_HOME/.venvs/$PROFILE_NAME"

# A profile's `local-home` (see profile.py) pins the project directory on
# this machine explicitly; without one, use CWD.
PROJECT_DIR="${PROFILE_LOCAL_HOME:-$PWD}"

# ~/.local/hack (this toolset) is always treated as a push-only repo,
# regardless of whether any profile's `sync` map mentions it -- remote-side
# scripts that live under a checkout of this repo are expected to `git pull`
# their own copy, and that pull is only safe once origin actually has
# whatever's committed locally. sync-remote.sh's --extra handles the
# auto-commit-then-push itself, same as any other push-only entry.
SYNC_QUIET_FLAG=()
[[ "$QUIET" -eq 1 ]] && SYNC_QUIET_FLAG=(--quiet)
bash "$SCRIPT_DIR/sync-remote.sh" "$SSH_ALIAS" "$REMOTE_ROOT" "$PROJECT_DIR" --profile "$PROFILE_NAME" --extra "$HOME/.local/hack:push-only" "${SYNC_QUIET_FLAG[@]}"

if ! ssh "$SSH_ALIAS" "test -d $(printf '%q' "$REAL_VENV_DIR")"; then
    [[ "$QUIET" -ne 1 ]] && echo "venv not found at $SSH_ALIAS:$REAL_VENV_DIR, creating from spec..."
    SPEC_TMP="$(mktemp)"
    printf '%s' "$VENV_SPEC_JSON" > "$SPEC_TMP"
    REMOTE_SPEC_FILE="/tmp/venv-spec-$VENV_SPEC_HASH.json"
    scp "$SCRIPT_DIR/create-venv-from-spec.sh" "$SSH_ALIAS:/tmp/"
    scp "$SPEC_TMP" "$SSH_ALIAS:$REMOTE_SPEC_FILE"
    rm -f "$SPEC_TMP"
    ssh "$SSH_ALIAS" "bash /tmp/create-venv-from-spec.sh $(printf '%q' "$REAL_VENV_DIR") $(printf '%q' "$REMOTE_SPEC_FILE") $(printf '%q' "$REMOTE_ROOT")"
fi

# (Re)point this profile's debug symlink at the current spec's real venv --
# ln -sfn overwrites any previous target atomically rather than erroring or
# nesting inside a stale symlink, so this is safe to run unconditionally
# every time, including when the spec changed since the last run.
ssh "$SSH_ALIAS" "mkdir -p $(printf '%q' "$(dirname "$REMOTE_VENV_DIR")") && ln -sfn $(printf '%q' "$REAL_VENV_DIR") $(printf '%q' "$REMOTE_VENV_DIR")"

# Garbage-collect any content-addressed venv under ~/.venvs/venvs that no
# ~/.venvs/<profile-name> symlink points at any more -- e.g. left behind by
# a profile whose spec has since changed, or a profile that no longer
# exists. Run after the symlink above is confirmed/repointed, so this run's
# own venv is never the thing getting swept. Base64-encoded like the
# launcher/watch commands below -- this is a multi-line script, not a
# single flat command, and needs to survive ssh's flatten-and-reparse.
GC_SCRIPT='
venvs_dir="$HOME/.venvs/venvs"
[ -d "$venvs_dir" ] || exit 0
referenced=$(find "$HOME/.venvs" -maxdepth 1 -type l -exec readlink -f {} \; | sort -u)
for d in "$venvs_dir"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    if ! grep -qxF "$d" <<< "$referenced"; then
        echo "Removing orphaned venv: $d"
        rm -rf "$d"
    fi
done
'
gc_b64="$(printf '%s' "$GC_SCRIPT" | base64 -w0)"
ssh "$SSH_ALIAS" "bash -c \"\$(echo $gc_b64 | base64 -d)\""

REMOTE_CMD="$1"
shift

EXTRA_EXPORTS=""
for kv in "${EXTRA_ENV[@]}"; do
    EXTRA_EXPORTS+="$(printf 'export %s=%q; ' "${kv%%=*}" "${kv#*=}")"
done

# ssh flattens all trailing arguments into a single string and reparses it
# remotely, so build one shell-safe command string (with printf %q) rather
# than passing activate/exec/env as separate ssh arguments -- an env-var
# prefix (VAR=val cmd1 && cmd2) only applies to cmd1, not cmd2, so a
# profile's env vars must be `export`ed inside the string, not passed as a
# leading ssh arg.
#
# A profile's `initializer` is inserted here, after activation and before
# the main command, as raw shell text (%s, not %q) -- it's meant to be
# interpreted by the remote shell (e.g. `&&`-chained sub-commands), not
# passed as a single literal argument.
INIT_SEGMENT=""
[[ -n "$PROFILE_INITIALIZER" ]] && INIT_SEGMENT="$PROFILE_INITIALIZER && "
REMOTE_SHELL_CMD="$(printf '%scd %q && source %q/bin/activate && %s%q' "$EXTRA_EXPORTS" "$REMOTE_ROOT" "$REMOTE_VENV_DIR" "$INIT_SEGMENT" "$REMOTE_CMD")"
for arg in "$@" "${APPEND_ARGS[@]}"; do
    REMOTE_SHELL_CMD+="$(printf ' %q' "$arg")"
done

# Run the job with `nohup ... &` so it survives a dropped network connection
# (nohup ignores the SIGHUP the shell would otherwise send it on disconnect;
# `disown` also drops it from the shell's job table so the shell exiting
# doesn't touch it either), redirected to a remote log file. Watching it is a
# separate, plain `ssh -tt ... tail -f` -- a reconnect just re-runs the
# watcher, it doesn't touch the already-running job.
EXIT_FILE="/tmp/.rrr_exit_$$_$(date +%s)"
REMOTE_LOG="/tmp/logs/rrr-$(date +%Y%m%d-%H%M%S).log"

REMOTE_SHELL_CMD+="$(printf '; echo $? > %q' "$EXIT_FILE")"
LAUNCHER_CMD="$(printf 'mkdir -p %q; : > %q; ( %s ) > %q 2>&1 < /dev/null' \
    "$(dirname "$REMOTE_LOG")" "$REMOTE_LOG" "$REMOTE_SHELL_CMD" "$REMOTE_LOG")"

# Send commands to the remote shell base64-encoded rather than via nested
# printf %q layers: ssh flattens all trailing arguments into one string and
# reparses it remotely, so every extra layer of wrapping (nohup, bash -c,
# ssh itself) needs its own %q pass, and getting one wrong silently breaks
# things (confirmed: an earlier `&` vs `&&` precedence bug backgrounded a
# whole `mkdir && truncate && job` chain instead of just the job). Base64's
# alphabet has no shell metacharacters, so it survives any number of
# reparses unmodified -- decode into a `bash -c` argument (not piped to
# bash's stdin) so `ps` still shows the real decoded command, not "bash"
# with no argv or the base64 blob itself.
launcher_b64="$(printf '%s' "$LAUNCHER_CMD" | base64 -w0)"
ssh "$SSH_ALIAS" "nohup bash -c \"\$(echo $launcher_b64 | base64 -d)\" < /dev/null > /dev/null 2>&1 & disown"

WATCH_CMD_PLAIN="$(printf 'tail -n +1 -f %q & TPID=$!; while [ ! -f %q ]; do sleep 0.5; done; sleep 0.2; kill $TPID 2>/dev/null; wait $TPID 2>/dev/null' \
    "$REMOTE_LOG" "$EXIT_FILE")"
watch_b64="$(printf '%s' "$WATCH_CMD_PLAIN" | base64 -w0)"

while true; do
    ssh -tt "$SSH_ALIAS" "exec bash -c \"\$(echo $watch_b64 | base64 -d)\""
    if ssh "$SSH_ALIAS" "test -f $(printf '%q' "$EXIT_FILE")" 2>/dev/null; then
        break
    fi
    [[ "$QUIET" -ne 1 ]] && echo "Connection to $SSH_ALIAS dropped, reconnecting in 5s..." >&2
    sleep 5
done

EXIT_CODE="$(ssh "$SSH_ALIAS" "cat $(printf '%q' "$EXIT_FILE") 2>/dev/null")"
ssh "$SSH_ALIAS" "rm -f $(printf '%q' "$EXIT_FILE")" 2>/dev/null
exit "${EXIT_CODE:-1}"
