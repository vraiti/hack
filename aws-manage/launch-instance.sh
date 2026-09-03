#!/usr/bin/env bash
set -euo pipefail

RAW=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--raw" ]]; then
        RAW=1
    else
        ARGS+=("$arg")
    fi
done

INSTANCE_TYPE="${ARGS[0]:?Usage: $0 <instance-type> [alias] [--raw]}"
SSH_ALIAS="${ARGS[1]:-aws}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/aws-retry.sh"
source "$SCRIPT_DIR/aws-config.sh"

TAG_NAME="vraiti-$(date +%Y%m%d)-vllm_omni-${SSH_ALIAS}"

echo "Looking up AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners self \
    --filters "Name=tag:Name,Values=$AMI_NAME" \
    --query 'Images[0].ImageId' \
    --output text)

if [[ "$AMI_ID" == "None" || -z "$AMI_ID" ]]; then
    echo "ERROR: AMI '$AMI_NAME' not found" >&2
    exit 1
fi
echo "AMI: $AMI_ID"

echo "Launching $INSTANCE_TYPE instance..."
INSTANCE_ID=$(aws_retry_on_capacity aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_SIZE,VolumeType=gp3}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=ssh-alias,Value=$SSH_ALIAS}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance: $INSTANCE_ID"
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Public IP: $PUBLIC_IP"
ssh-keygen -R "$PUBLIC_IP" 2>/dev/null || true
ssh_alias_write "$SSH_ALIAS" "$PUBLIC_IP"

bash "$SCRIPT_DIR/poll-ssh.sh" "$SSH_ALIAS"

if [[ "$RAW" -eq 1 ]]; then
    echo "Skipping repo sync/install-shutdown-hook.sh/create-venv.sh (--raw)"
else
    # Single-quoted so the literal text ($HOME, unexpanded) survives until
    # it's sent to the remote shell below -- it must expand against the
    # remote user's home, not whatever $HOME happens to be on this machine.
    REMOTE_ROOT='$HOME/vraiti'
    REMOTE_ROOT="$(ssh "$SSH_ALIAS" "echo $REMOTE_ROOT")"

    echo "Syncing repos to $SSH_ALIAS..."
    bash "$SCRIPT_DIR/../sync-remote.sh" "$SSH_ALIAS" "$REMOTE_ROOT"

    scp "$SCRIPT_DIR/../install-shutdown-hook.sh" "$SCRIPT_DIR/../create-venv.sh" "$SSH_ALIAS:/tmp/"

    echo "Running install-shutdown-hook.sh on $SSH_ALIAS..."
    ssh "$SSH_ALIAS" bash /tmp/install-shutdown-hook.sh

    echo "Running create-venv.sh on $SSH_ALIAS..."
    ssh "$SSH_ALIAS" bash /tmp/create-venv.sh
fi

echo ""
echo "Instance: $INSTANCE_ID"
echo "IP:       $PUBLIC_IP"
echo "SSH:      ssh $SSH_ALIAS"
