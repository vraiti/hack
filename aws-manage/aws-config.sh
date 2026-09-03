#!/usr/bin/env bash
# Shared AWS constants for aws-manage.sh, launch-instance.sh, and friends.
# Not meant to be run directly -- source it.

AMI_NAME="vraiti-rhel10-cuda"
CACHE_DEVICE_NAME="/dev/sdf"
CACHE_VOLUME_SIZE=10
ROOT_VOLUME_SIZE=200
PROJECT_TAG="aws_manage_managed"
KEY_NAME="vraiti-ed25519"
SECURITY_GROUP="sg-04371316571a0bf71"
RHEL10_AMI_OWNER="309956199498"

# All aws-manage-created aliases live as separate `Host` blocks inside one
# shared file, rather than one file per alias -- this is a generated
# artifact (every write here is an add/remove/rename of a whole block, never
# a hand-edit), not something to maintain by hand.
SSH_CONFIG_FILE="$HOME/.ssh/config.d/awsm"

ssh_alias_exists() {
    local alias="$1"
    [[ -f "$SSH_CONFIG_FILE" ]] && grep -qE "^Host ${alias}\$" "$SSH_CONFIG_FILE"
}

# Removes the `Host <alias>` block (that Host line through the line before
# the next `Host ` line, or EOF) if present. A no-op if the alias isn't
# there -- safe to call unconditionally.
ssh_alias_remove() {
    local alias="$1"
    [[ -f "$SSH_CONFIG_FILE" ]] || return 0
    awk -v alias="$alias" '
        /^Host / { skip = ($2 == alias) }
        !skip { print }
    ' "$SSH_CONFIG_FILE" > "$SSH_CONFIG_FILE.tmp"
    mv "$SSH_CONFIG_FILE.tmp" "$SSH_CONFIG_FILE"
}

# Writes (or overwrites, if already present) the `Host <alias>` block.
ssh_alias_write() {
    local alias="$1" hostname="$2"
    mkdir -p "$(dirname "$SSH_CONFIG_FILE")"
    touch "$SSH_CONFIG_FILE"
    ssh_alias_remove "$alias"
    {
        echo "Host $alias"
        echo "    HostName $hostname"
        echo "    User ec2-user"
        echo "    IdentityFile ~/.ssh/vraiti-ed25519.pem"
        echo "    StrictHostKeyChecking accept-new"
        echo "    GSSAPIAuthentication no"
        echo ""
    } >> "$SSH_CONFIG_FILE"
}

ssh_alias_rename() {
    local old="$1" new="$2"
    awk -v old="$old" -v new="$new" '
        /^Host / {
            if ($2 == old) { print "Host " new; next }
        }
        { print }
    ' "$SSH_CONFIG_FILE" > "$SSH_CONFIG_FILE.tmp"
    mv "$SSH_CONFIG_FILE.tmp" "$SSH_CONFIG_FILE"
}
