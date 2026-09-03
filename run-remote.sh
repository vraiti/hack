#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

resolve_alias() {
    # Aliases live as `Host` lines inside files under ~/.ssh/config.d/ (e.g.
    # aws-manage's consolidated config.d/awsm, which holds one block per
    # managed instance) -- not one alias per file, so this must enumerate
    # actual Host lines, not filenames.
    local hosts
    hosts=$(grep -hoE '^Host[[:space:]]+\S+' ~/.ssh/config.d/* 2>/dev/null | awk '{print $2}' | sort -u)
    local count=0
    [[ -n "$hosts" ]] && count=$(wc -l <<< "$hosts")
    if [[ "$count" -eq 1 ]]; then
        echo "$hosts"
        return 0
    fi
    return 1
}

# An alias doesn't have to live in ~/.ssh/config.d/ -- it may just be a plain
# `Host` entry in ~/.ssh/config (e.g. non-AWS boxes like a DGX Spark). Without
# this check, an unrecognized-but-real alias falls through to resolve_alias()'s
# "exactly one instance" convenience path and silently targets the WRONG host
# instead of erroring -- confirmed causing a hang against a stopped EC2 instance
# when the intended target ("spark") was only in ~/.ssh/config.
is_known_host() {
    local host="$1"
    grep -qE "^Host[[:space:]]+(\S+[[:space:]]+)*${host}([[:space:]]|\$)" ~/.ssh/config.d/* 2>/dev/null && return 0
    [[ -f "$HOME/.ssh/config" ]] && grep -qE "^[[:space:]]*Host[[:space:]]+(\S+[[:space:]]+)*${host}([[:space:]]|$)" "$HOME/.ssh/config" && return 0
    return 1
}

# --venv NAME can appear anywhere in the argument list; it selects the venv
# directory to activate remotely (relative to REMOTE_ROOT), defaulting to
# "venv" for hosts provisioned the standard way. --env VAR=value (repeatable)
# exports additional environment variables for the remote command, alongside
# the always-exported HF_TOKEN.
VENV_NAME="venv"
VENV_SPECIFIED=0
EXTRA_ENV=()
PROFILE_NAME=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --venv)
            VENV_NAME="$2"
            VENV_SPECIFIED=1
            shift 2
            ;;
        --venv=*)
            VENV_NAME="${1#--venv=}"
            VENV_SPECIFIED=1
            shift
            ;;
        --env)
            EXTRA_ENV+=("$2")
            shift 2
            ;;
        --env=*)
            EXTRA_ENV+=("${1#--env=}")
            shift
            ;;
        --profile)
            PROFILE_NAME="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE_NAME="${1#--profile=}"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# A literal `--` (as in git/kubectl) marks extra args to append to whatever
# the remote command ends up being -- explicit CLI command or, if none was
# given, the profile's default `command`. Split out here so both cases share
# the same appending logic below, instead of only working for one of them.
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

# A profile (~/.local/run-remote/<name>.json, written by profile.py)
# supplies default `venv`/`env` values -- applied here, before --venv/--env
# parsing above has a chance to matter, so an explicit CLI flag still wins
# over whatever the profile set.
if [[ -n "$PROFILE_NAME" ]]; then
    PROFILE_PATH="$HOME/.local/run-remote/$PROFILE_NAME.json"
    if [[ ! -f "$PROFILE_PATH" ]]; then
        echo "ERROR: profile '$PROFILE_NAME' not found at $PROFILE_PATH" >&2
        exit 1
    fi
    echo "Using profile '$PROFILE_NAME':"
    cat "$PROFILE_PATH"
    if [[ "$VENV_SPECIFIED" -eq 0 ]]; then
        PROFILE_VENV="$(jq -r '.venv' "$PROFILE_PATH")"
        if [[ -n "$PROFILE_VENV" && "$PROFILE_VENV" != "null" ]]; then
            VENV_NAME="$PROFILE_VENV"
            VENV_SPECIFIED=1
        fi
    fi
    PROFILE_ENV=()
    while IFS= read -r kv; do
        PROFILE_ENV+=("$kv")
    done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "$PROFILE_PATH")
    EXTRA_ENV=("${PROFILE_ENV[@]}" "${EXTRA_ENV[@]}")

    PROFILE_HOST="$(jq -r '.host // empty' "$PROFILE_PATH")"
    PROFILE_HOME="$(jq -r '.home // empty' "$PROFILE_PATH")"
    PROFILE_LOCAL_HOME="$(jq -r '.["local-home"] // empty' "$PROFILE_PATH")"

    # A profile's `command` is only a default -- an explicit <command>
    # [args...] on the CLI (i.e. $# still nonzero after flag parsing above)
    # overrides it entirely rather than merging with it.
    if [[ $# -eq 0 ]]; then
        PROFILE_COMMAND=()
        while IFS= read -r arg; do
            PROFILE_COMMAND+=("$arg")
        done < <(jq -r '.command // [] | .[]' "$PROFILE_PATH")
        if [[ ${#PROFILE_COMMAND[@]} -gt 0 ]]; then
            set -- "${PROFILE_COMMAND[@]}"
        fi
    fi
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [alias[:remote_path]] [--venv NAME] [--env VAR=value ...] [--profile NAME] <command> [args...]" >&2
    exit 1
fi

# Single-quoted so the literal text ($HOME, unexpanded) survives until it's
# sent to the remote shell below -- it must expand against the remote
# user's home, not whatever $HOME happens to be on this machine. A profile's
# `home`/`host` (see profile.py) supply non-default values here, but
# an explicit [alias[:remote_path]] argument still wins over either.
REMOTE_ROOT="${PROFILE_HOME:-\$HOME/vraiti}"
ALIAS_CANDIDATE="${1%%:*}"
if is_known_host "$ALIAS_CANDIDATE"; then
    SSH_ALIAS="$ALIAS_CANDIDATE"
    if [[ "$1" == *:* ]]; then
        PATH_CANDIDATE="${1#*:}"
        [[ -n "$PATH_CANDIDATE" ]] && REMOTE_ROOT="$PATH_CANDIDATE"
    fi
    shift
elif [[ -n "${PROFILE_HOST:-}" ]]; then
    SSH_ALIAS="$PROFILE_HOST"
elif SSH_ALIAS=$(resolve_alias); then
    :
else
    echo "ERROR: multiple instances exist, specify an alias" >&2
    ls ~/.ssh/config.d/ >&2
    exit 1
fi

# Resolve any remote-side expansion (e.g. $HOME) once, up front, so every
# other use of REMOTE_ROOT below is a plain, already-concrete path -- it
# doesn't need to know whether it's embedded in a raw ssh command string
# (which a remote shell would expand) or a printf %q-escaped one (which
# would escape the literal '$' and never expand it).
REMOTE_ROOT="$(ssh "$SSH_ALIAS" "echo $REMOTE_ROOT")"
ssh "$SSH_ALIAS" "mkdir -p $(printf '%q' "$REMOTE_ROOT")"

# A profile's `local-home` (see profile.py) pins the project directory on
# this machine explicitly; without one, use CWD.
PROJECT_DIR="${PROFILE_LOCAL_HOME:-$PWD}"

# ~/.local/hack (this toolset) is always treated as a push-only repo (see
# sync-remote.sh's push_repo_and_submodules), regardless of whether any
# profile's `sync` map mentions it -- remote-side scripts that live under a
# checkout of this repo are expected to `git pull` their own copy, and that
# pull is only safe once origin actually has whatever's committed locally.
HACK_DIR="$HOME/.local/hack"
if [[ -e "$HACK_DIR/.git" ]]; then
    if [[ -n "$(git -C "$HACK_DIR" status --porcelain)" ]]; then
        echo "ERROR: $HACK_DIR has uncommitted changes" >&2
        exit 1
    fi
    git -C "$HACK_DIR" push
fi

if [[ -n "$PROFILE_NAME" ]]; then
    bash "$SCRIPT_DIR/sync-remote.sh" "$SSH_ALIAS" "$REMOTE_ROOT" "$PROJECT_DIR" --profile "$PROFILE_NAME"
else
    bash "$SCRIPT_DIR/sync-remote.sh" "$SSH_ALIAS" "$REMOTE_ROOT" "$PROJECT_DIR"
fi

REMOTE_VENV_DIR="$REMOTE_ROOT/$VENV_NAME"
if ! ssh "$SSH_ALIAS" "test -d $(printf '%q' "$REMOTE_VENV_DIR")"; then
    if [[ "$VENV_SPECIFIED" -eq 1 ]]; then
        echo "ERROR: venv '$VENV_NAME' not found at $SSH_ALIAS:$REMOTE_VENV_DIR" >&2
        exit 1
    fi
    echo "venv not found at $SSH_ALIAS:$REMOTE_VENV_DIR, creating..."
    scp "$SCRIPT_DIR/create-venv.sh" "$SSH_ALIAS:/tmp/"
    ssh "$SSH_ALIAS" "bash /tmp/create-venv.sh $(printf '%q' "$REMOTE_VENV_DIR")"
fi

AUX_DIR="$PROJECT_DIR/vllm-omni-aux"

REMOTE_CMD="$1"
shift

HF_TOKEN=$(cat ~/.secret/hf)

EXTRA_EXPORTS=""
for kv in "${EXTRA_ENV[@]}"; do
    EXTRA_EXPORTS+="$(printf 'export %s=%q; ' "${kv%%=*}" "${kv#*=}")"
done

# ssh flattens all trailing arguments into a single string and reparses it
# remotely, so build one shell-safe command string (with printf %q) rather
# than passing activate/exec/env as separate ssh arguments -- an env-var
# prefix (VAR=val cmd1 && cmd2) only applies to cmd1, not cmd2, so HF_TOKEN
# (and any --env vars) must be `export`ed inside the string, not passed as a
# leading ssh arg.
REMOTE_SHELL_CMD="$(printf 'export HF_TOKEN=%q; %scd %q && source %q/bin/activate && %q' "$HF_TOKEN" "$EXTRA_EXPORTS" "$REMOTE_ROOT" "$VENV_NAME" "$REMOTE_CMD")"
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
    echo "Connection to $SSH_ALIAS dropped, reconnecting in 5s..." >&2
    sleep 5
done

EXIT_CODE="$(ssh "$SSH_ALIAS" "cat $(printf '%q' "$EXIT_FILE") 2>/dev/null")"
ssh "$SSH_ALIAS" "rm -f $(printf '%q' "$EXIT_FILE")" 2>/dev/null
exit "${EXIT_CODE:-1}"
