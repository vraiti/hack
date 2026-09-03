#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/aws-retry.sh"
source "$SCRIPT_DIR/aws-config.sh"

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  create <instance-type> [alias] [--raw]
                                    Launch a new instance (alias defaults to 'aws').
                                    --raw skips running install-shutdown-hook.sh.
  create-raw <instance-type> [alias]
                                    Launch straight from Red Hat's official RHEL 10
                                    AMI and provision it (NVIDIA driver, CUDA
                                    toolkit, DLAMI NVMe/cache setup)
                                    to match the $AMI_NAME base state via
                                    create-from-rhel10-ami.sh. Run 'snapshot'
                                    afterward to publish it as $AMI_NAME.
  start [alias]                    Start the stopped instance and poll for SSH
  stop [alias]                     Stop the running instance
  delete [alias]                   Terminate the instance and remove SSH config
  mv <old-alias> <new-alias>       Re-alias the instance locally
  ls                               List tagged instances (alias, state, id) live from AWS
  refresh                          Reconcile $SSH_CONFIG_FILE against live AWS state:
                                    update HostName for any alias whose public IP
                                    changed, backfill GSSAPIAuthentication no on any
                                    alias missing it, and remove aliases whose
                                    instance no longer exists in AWS (e.g. deleted
                                    out-of-band)
  snapshot <alias>                 Snapshot the instance's root and cache EBS
                                    volumes and republish them as the
                                    $AMI_NAME AMI
  snapshot-cache <alias>           Like snapshot, but only re-snapshots the
                                    cache EBS volume; the AMI's existing root
                                    snapshot is carried over unchanged
EOF
    exit 1
}

INSTANCE_ALIAS="aws"
SSH_ALIAS="$INSTANCE_ALIAS"

set_alias() {
    INSTANCE_ALIAS="${1:-aws}"
    SSH_ALIAS="$INSTANCE_ALIAS"
}

get_instance_id() {
    local id
    id=$(aws ec2 describe-instances \
        --filters "Name=tag:ssh-alias,Values=$INSTANCE_ALIAS" \
                  "Name=instance-state-name,Values=running,stopped,pending" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)

    if [[ "$id" == "None" || -z "$id" ]]; then
        echo "ERROR: could not find instance tagged ssh-alias=$INSTANCE_ALIAS" >&2
        exit 1
    fi
    echo "$id"
}

alias_exists_in_aws() {
    local id
    id=$(aws ec2 describe-instances \
        --filters "Name=tag:ssh-alias,Values=$INSTANCE_ALIAS" \
                  "Name=instance-state-name,Values=running,stopped,pending,stopping" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)
    [[ "$id" != "None" && -n "$id" ]]
}

# The shared SSH config file is not a source of truth -- if the instance
# was deleted out-of-band (console, another machine, `aws ec2
# terminate-instances` directly), its block goes stale. Reconcile against
# AWS before treating an existing block as "alias in use".
check_alias_available() {
    if ! ssh_alias_exists "$INSTANCE_ALIAS"; then
        return
    fi
    if alias_exists_in_aws; then
        echo "ERROR: alias '$INSTANCE_ALIAS' already exists" >&2
        exit 1
    fi
    echo "Alias '$INSTANCE_ALIAS' has no matching AWS instance (deleted out-of-band); removing stale entry from $SSH_CONFIG_FILE"
    ssh_alias_remove "$INSTANCE_ALIAS"
    fusermount -u "/tmp/logs/$INSTANCE_ALIAS" 2>/dev/null || true
}

setup_sshfs() {
    mkdir -p /tmp/logs
    local mount_point="/tmp/logs/$INSTANCE_ALIAS"
    fusermount -u "$mount_point" 2>/dev/null || true
    mkdir -p "$mount_point"
    ssh "$SSH_ALIAS" "mkdir -p /tmp/logs"
    sshfs "$SSH_ALIAS:/tmp/logs" "$mount_point" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
    echo "SSHFS:    $SSH_ALIAS:/tmp/logs -> $mount_point"
}

cmd_create() {
    local raw=0
    local positional=()
    for arg in "$@"; do
        if [[ "$arg" == "--raw" ]]; then
            raw=1
        else
            positional+=("$arg")
        fi
    done

    local instance_type="${positional[0]:?Usage: $0 create <instance-type> [alias] [--raw]}"
    set_alias "${positional[1]:-}"

    local project_dir="$PWD"
    while [[ "$project_dir" != "$HOME/omni" && "$project_dir" != "/" ]]; do
        if [[ "$(dirname "$project_dir")" == "$HOME/omni" ]]; then
            break
        fi
        project_dir="$(dirname "$project_dir")"
    done
    pushd "$project_dir" > /dev/null
    trap 'popd > /dev/null' EXIT

    check_alias_available
    if [[ "$raw" -eq 1 ]]; then
        bash "$SCRIPT_DIR/launch-instance.sh" "$instance_type" "$INSTANCE_ALIAS" --raw
    else
        bash "$SCRIPT_DIR/launch-instance.sh" "$instance_type" "$INSTANCE_ALIAS"
    fi
    setup_sshfs
}

cmd_create_raw() {
    local instance_type="${1:?Usage: $0 create-raw <instance-type> [alias]}"
    set_alias "${2:-}"

    check_alias_available

    echo "Looking up Red Hat's official RHEL 10 AMI..."
    local ami_info
    ami_info=$(aws ec2 describe-images \
        --owners "$RHEL10_AMI_OWNER" \
        --filters "Name=name,Values=RHEL-10*x86_64*" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].[ImageId,RootDeviceName]' \
        --output text)
    local ami_id root_device_name
    read -r ami_id root_device_name <<< "$ami_info"
    if [[ "$ami_id" == "None" || -z "$ami_id" ]]; then
        echo "ERROR: could not find a RHEL 10 AMI owned by $RHEL10_AMI_OWNER" >&2
        exit 1
    fi
    echo "AMI: $ami_id (root device: $root_device_name)"

    local tag_name="vraiti-$(date +%Y%m%d)-vllm_omni-${INSTANCE_ALIAS}"

    echo "Launching $instance_type instance..."
    local id
    id=$(aws_retry_on_capacity aws ec2 run-instances \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP" \
        --block-device-mappings \
            "DeviceName=$root_device_name,Ebs={VolumeSize=$ROOT_VOLUME_SIZE,VolumeType=gp3}" \
            "DeviceName=$CACHE_DEVICE_NAME,Ebs={VolumeSize=$CACHE_VOLUME_SIZE,VolumeType=gp3}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$tag_name},{Key=Project,Value=$PROJECT_TAG},{Key=ssh-alias,Value=$INSTANCE_ALIAS}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    echo "Instance: $id"
    echo "Waiting for instance to reach running state..."
    aws ec2 wait instance-running --instance-ids "$id"

    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    if [[ "$public_ip" == "None" || -z "$public_ip" ]]; then
        echo "ERROR: instance has no public IP" >&2
        exit 1
    fi
    echo "Public IP: $public_ip"
    ssh-keygen -R "$public_ip" 2>/dev/null || true

    local bootstrap_ssh_opts=(
        -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=2
        -i ~/.ssh/vraiti-ed25519.pem
    )
    local bootstrap_host="ec2-user@$public_ip"

    echo "Polling SSH readiness..."
    local ready=0
    for ((i = 1; i <= 60; i++)); do
        if ssh -o ConnectTimeout=5 "${bootstrap_ssh_opts[@]}" "$bootstrap_host" true 2>/dev/null; then
            ready=1
            break
        fi
        echo "Attempt $i/60 — SSH not ready, retrying in 5s..."
        sleep 5
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "ERROR: SSH did not become ready after 300s" >&2
        exit 1
    fi

    echo "Uploading create-from-rhel10-ami.sh..."
    scp "${bootstrap_ssh_opts[@]}" "$SCRIPT_DIR/create-from-rhel10-ami.sh" "$bootstrap_host:/tmp/"

    echo "Running phase 1 (driver install + reboot)..."
    ssh "${bootstrap_ssh_opts[@]}" "$bootstrap_host" "sudo bash /tmp/create-from-rhel10-ami.sh" || true

    echo "Waiting for reboot..."
    sleep 15
    ready=0
    for ((i = 1; i <= 60; i++)); do
        if ssh -o ConnectTimeout=5 "${bootstrap_ssh_opts[@]}" "$bootstrap_host" true 2>/dev/null; then
            ready=1
            break
        fi
        echo "Attempt $i/60 — SSH not ready, retrying in 5s..."
        sleep 5
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "ERROR: SSH did not come back after reboot after 300s" >&2
        exit 1
    fi

    echo "Waiting for provisioning to complete (phase 2 runs automatically on boot)..."
    local complete=0
    for ((i = 1; i <= 60; i++)); do
        if ssh "${bootstrap_ssh_opts[@]}" "$bootstrap_host" "test -f /var/lib/vllm-omni-rhel10-provision-complete" 2>/dev/null; then
            complete=1
            break
        fi
        echo "Attempt $i/60 — still provisioning, retrying in 10s..."
        sleep 10
    done
    if [[ "$complete" -ne 1 ]]; then
        echo "ERROR: provisioning did not complete after 600s; check ec2-user@$public_ip manually" >&2
        exit 1
    fi

    ssh_alias_write "$SSH_ALIAS" "$public_ip"

    echo ""
    echo "Instance: $id"
    echo "SSH:      ssh $SSH_ALIAS"
    echo "Provisioning complete. Run '$0 snapshot $INSTANCE_ALIAS' to publish it as $AMI_NAME."
}

cmd_mv() {
    local old_alias="${1:?Usage: $0 mv <old-alias> <new-alias>}"
    local new_alias="${2:?Usage: $0 mv <old-alias> <new-alias>}"

    if ! ssh_alias_exists "$old_alias"; then
        echo "ERROR: no SSH config entry for '$old_alias' in $SSH_CONFIG_FILE" >&2
        exit 1
    fi
    if ssh_alias_exists "$new_alias"; then
        echo "ERROR: alias '$new_alias' already exists" >&2
        exit 1
    fi

    local id
    id=$(aws ec2 describe-instances \
        --filters "Name=tag:ssh-alias,Values=$old_alias" \
                  "Name=instance-state-name,Values=running,stopped,pending" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)

    if [[ "$id" != "None" && -n "$id" ]]; then
        local old_name
        old_name=$(aws ec2 describe-tags \
            --filters "Name=resource-id,Values=$id" "Name=key,Values=Name" \
            --query 'Tags[0].Value' --output text 2>/dev/null)
        local new_name="${old_name%-*}-${new_alias}"
        aws ec2 create-tags --resources "$id" \
            --tags "Key=Name,Value=$new_name" "Key=ssh-alias,Value=$new_alias"
        echo "AWS Name: '$old_name' -> '$new_name'"
        echo "AWS Tag ssh-alias: '$old_alias' -> '$new_alias'"
    else
        echo "WARNING: could not find AWS instance to rename tag" >&2
    fi

    ssh_alias_rename "$old_alias" "$new_alias"
    echo "Renamed alias '$old_alias' -> '$new_alias'"

    local old_mount="/tmp/$old_alias"
    local new_mount="/tmp/$new_alias"
    if mountpoint -q "$old_mount" 2>/dev/null; then
        fusermount -u "$old_mount"
        rmdir "$old_mount" 2>/dev/null || true
        mkdir -p "$new_mount"
        sshfs "$new_alias:/tmp/logs" "$new_mount" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
        echo "SSHFS:    $old_mount -> $new_mount"
    fi
}

cmd_ls() {
    aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                  "Name=instance-state-name,Values=running,stopped,pending,stopping" \
        --query 'Reservations[].Instances[].[Tags[?Key==`ssh-alias`]|[0].Value,State.Name,InstanceId]' \
        --output text | while read -r alias state id; do
        printf "%-20s %-10s %s\n" "$alias" "$state" "$id"
    done
}

cmd_refresh() {
    echo "Fetching live instance state from AWS..."
    local seen_aliases=()
    while IFS=$'\t' read -r alias state id public_ip; do
        [[ -z "$alias" || "$alias" == "None" ]] && continue
        seen_aliases+=("$alias")

        if [[ "$state" != "running" || -z "$public_ip" || "$public_ip" == "None" ]]; then
            echo "SKIP $alias ($state, no public IP to sync)"
            continue
        fi

        local current_ip="" has_gssapi=0
        if ssh_alias_exists "$alias"; then
            current_ip=$(awk -v alias="$alias" '
                /^Host / { active = ($2 == alias) }
                active && /^[[:space:]]*HostName / { print $2 }
            ' "$SSH_CONFIG_FILE")
            awk -v alias="$alias" '
                /^Host / { active = ($2 == alias) }
                active && /^[[:space:]]*GSSAPIAuthentication[[:space:]]+no[[:space:]]*$/ { found = 1 }
                END { exit !found }
            ' "$SSH_CONFIG_FILE" && has_gssapi=1
        fi

        if [[ "$current_ip" == "$public_ip" && "$has_gssapi" -eq 1 ]]; then
            echo "OK   $alias ($public_ip)"
            continue
        fi

        if [[ "$current_ip" != "$public_ip" ]]; then
            echo "SYNC $alias: ${current_ip:-<none>} -> $public_ip"
            [[ -n "$current_ip" ]] && ssh-keygen -R "$current_ip" 2>/dev/null || true
            ssh-keygen -R "$public_ip" 2>/dev/null || true
        else
            echo "SYNC $alias: adding GSSAPIAuthentication no"
        fi
        ssh_alias_write "$alias" "$public_ip"
    done < <(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                  "Name=instance-state-name,Values=running,stopped,pending,stopping" \
        --query 'Reservations[].Instances[].[Tags[?Key==`ssh-alias`]|[0].Value,State.Name,InstanceId,PublicIpAddress]' \
        --output text)

    [[ -f "$SSH_CONFIG_FILE" ]] || return 0
    local configured_aliases
    configured_aliases=$(grep -oE '^Host .+' "$SSH_CONFIG_FILE" | awk '{print $2}')
    while IFS= read -r alias; do
        [[ -z "$alias" ]] && continue
        local found=0
        for seen in "${seen_aliases[@]}"; do
            [[ "$seen" == "$alias" ]] && { found=1; break; }
        done
        if [[ "$found" -eq 0 ]]; then
            echo "STALE $alias: no matching AWS instance, removing from $SSH_CONFIG_FILE"
            ssh_alias_remove "$alias"
            fusermount -u "/tmp/logs/$alias" 2>/dev/null || true
        fi
    done <<< "$configured_aliases"
}

cmd_stop() {
    set_alias "${1:-}"
    local id
    id=$(get_instance_id)
    echo "Stopping $id..."
    aws ec2 stop-instances --instance-ids "$id" --output text

    echo "Waiting for stopped state..."
    aws ec2 wait instance-stopped --instance-ids "$id"

    echo "Instance stopped."
}

cmd_start() {
    set_alias "${1:-}"
    local id
    id=$(get_instance_id)
    echo "Starting $id..."
    aws_retry_on_capacity aws ec2 start-instances --instance-ids "$id" --output text

    echo "Waiting for running state..."
    aws ec2 wait instance-running --instance-ids "$id"

    local new_ip
    new_ip=$(aws ec2 describe-instances \
        --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    echo "Public IP: $new_ip"

    ssh-keygen -R "$new_ip" 2>/dev/null || true
    # write, not update_hostname: self-healing if the alias's block is
    # somehow missing (e.g. migrating from an older config scheme) rather
    # than silently no-op-ing.
    ssh_alias_write "$SSH_ALIAS" "$new_ip"

    bash "$SCRIPT_DIR/poll-ssh.sh" "$SSH_ALIAS"

    setup_sshfs

    echo ""
    echo "Instance: $id"
    echo "IP:       $new_ip"
    echo "SSH:      ssh $SSH_ALIAS"
}

cmd_delete() {
    set_alias "${1:-}"
    local id
    id=$(get_instance_id)

    echo "Terminating $id..."
    aws ec2 terminate-instances --instance-ids "$id" --output text

    ssh_alias_remove "$INSTANCE_ALIAS"
    echo "Removed '$INSTANCE_ALIAS' from $SSH_CONFIG_FILE"

    echo "Instance $id terminated, SSH alias '$SSH_ALIAS' removed."
}

cmd_snapshot() {
    set_alias "${1:?Usage: $0 snapshot <alias>}"
    local id
    id=$(get_instance_id)
    python3 "$SCRIPT_DIR/aws-snapshot.py" \
        --instance-id "$id" \
        --alias "$INSTANCE_ALIAS" \
        --ami-name "$AMI_NAME" \
        --cache-device "$CACHE_DEVICE_NAME"
}

cmd_snapshot_cache() {
    set_alias "${1:?Usage: $0 snapshot-cache <alias>}"
    local id
    id=$(get_instance_id)
    python3 "$SCRIPT_DIR/aws-snapshot.py" \
        --instance-id "$id" \
        --alias "$INSTANCE_ALIAS" \
        --ami-name "$AMI_NAME" \
        --cache-device "$CACHE_DEVICE_NAME" \
        --cache-only
}

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    create)         cmd_create "$@" ;;
    create-raw)     cmd_create_raw "$@" ;;
    start)          cmd_start "$@" ;;
    stop)           cmd_stop "$@" ;;
    delete)         cmd_delete "$@" ;;
    mv)             cmd_mv "$@" ;;
    ls)             cmd_ls ;;
    refresh)        cmd_refresh ;;
    snapshot)       cmd_snapshot "$@" ;;
    snapshot-cache) cmd_snapshot_cache "$@" ;;
    *)              usage ;;
esac
