#!/usr/bin/env bash
# Prints the sole SSH alias managed by aws-manage (a `Host` block in
# $SSH_CONFIG_FILE, i.e. ~/.ssh/config.d/awsm -- see aws-config.sh) so
# callers that take an optional alias/host can fall back to "the one
# instance that exists" instead of requiring it spelled out every time.
# Deliberately does NOT look at other files under ~/.ssh/config.d/ --
# only aws-manage's own aliases count as a default host.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/aws-config.sh"

hosts=$(grep -hoE '^Host[[:space:]]+\S+' "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' | sort -u)
count=0
[[ -n "$hosts" ]] && count=$(wc -l <<< "$hosts")

if [[ "$count" -eq 1 ]]; then
    echo "$hosts"
    exit 0
fi

if [[ "$count" -eq 0 ]]; then
    echo "ERROR: no aws-manage SSH alias found in $SSH_CONFIG_FILE" >&2
else
    echo "ERROR: multiple aws-manage SSH aliases exist, host must be specified explicitly:" >&2
    sed 's/^/  /' <<< "$hosts" >&2
fi
exit 1
