#!/usr/bin/env bash
# Sourced by launch-instance.sh and aws-manage.sh. Capacity shortages
# (InsufficientInstanceCapacity / InsufficientHostCapacity) are transient --
# on-demand capacity routinely frees up within minutes -- so retry those
# instead of failing the whole command outright. Any other error is not
# retried.

aws_retry_on_capacity() {
    local interval=1
    local timeout=300
    local deadline=$(( $(date +%s) + timeout ))
    local output

    while true; do
        if output=$("$@" 2>&1); then
            printf '%s\n' "$output"
            return 0
        fi

        if printf '%s\n' "$output" | grep -qE 'InsufficientInstanceCapacity|InsufficientHostCapacity|InsufficientCapacity'; then
            if [[ $(date +%s) -ge $deadline ]]; then
                echo "No capacity available after ${timeout}s, giving up." >&2
                printf '%s\n' "$output" >&2
                return 1
            fi
            echo "No capacity available, retrying in ${interval}s..." >&2
            sleep "$interval"
            continue
        fi

        printf '%s\n' "$output" >&2
        return 1
    done
}
