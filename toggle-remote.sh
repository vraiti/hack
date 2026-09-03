#!/usr/bin/env bash
set -euo pipefail

# Toggles a git remote's URL between https and ssh form.
#   https://HOST/OWNER/REPO(.git)   <->   git@HOST:OWNER/REPO(.git)
PATH_ARG="${1:?Usage: $0 <path> <remote>}"
REMOTE="${2:?Usage: $0 <path> <remote>}"

URL="$(git -C "$PATH_ARG" remote get-url "$REMOTE")"

if [[ "$URL" =~ ^https://([^/]+)/(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
    NEW_URL="git@${HOST}:${REPO_PATH}"
elif [[ "$URL" =~ ^git@([^:]+):(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
    NEW_URL="https://${HOST}/${REPO_PATH}"
elif [[ "$URL" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
    NEW_URL="https://${HOST}/${REPO_PATH}"
else
    echo "ERROR: unrecognized remote URL form: $URL" >&2
    exit 1
fi

git -C "$PATH_ARG" remote set-url "$REMOTE" "$NEW_URL"
echo "$REMOTE: $URL -> $NEW_URL"
