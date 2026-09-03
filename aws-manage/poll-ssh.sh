#!/usr/bin/env bash
set -euo pipefail

HOST="${1:?Usage: $0 <host>}"

echo "Polling SSH readiness..."
for ((i = 1; i <= 60; i++)); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$HOST" true 2>/dev/null; then
        echo "SSH is ready."
        exit 0
    fi
    echo "Attempt $i/60 — SSH not ready, retrying in 5s..."
    sleep 5
done
echo "ERROR: SSH did not become ready after 300s" >&2
exit 1
