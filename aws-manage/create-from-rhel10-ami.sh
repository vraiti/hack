#!/usr/bin/env bash
# Provisions a bare Red Hat RHEL 10 AMI instance into exactly the state
# launch-instance.sh expects from the "vraiti-rhel10-cuda" AMI: NVIDIA
# driver + CUDA toolkit and the DLAMI ephemeral-NVMe mount/cache-symlink
# setup.
#
# Self-contained: scp this to the instance and run it once. It resumes
# itself across the reboot the driver install requires (via a temporary
# systemd oneshot unit) and cleans up after itself. Safe to run manually
# on any bare RHEL 10 instance with a second ~10GB EBS volume attached
# (e.g. after re-launching a snapshot for further changes).
set -euo pipefail

MARKER=/var/lib/vllm-omni-rhel10-provision-phase1-done
COMPLETE_MARKER=/var/lib/vllm-omni-rhel10-provision-complete
RESUME_SCRIPT=/usr/local/sbin/vllm-omni-provision-resume.sh
RESUME_UNIT=/etc/systemd/system/vllm-omni-provision-resume.service
EBS_CACHE_DIR=/opt/home-cache-ebs
CACHE_VOLUME_SIZE_GB=10

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$(readlink -f "$0")" "$@"
fi

if [[ -f "$COMPLETE_MARKER" ]]; then
    echo "Already provisioned (found $COMPLETE_MARKER); nothing to do."
    exit 0
fi

if [[ ! -f "$MARKER" ]]; then
    echo "=== Phase 1: EPEL, NVIDIA repo, driver ==="
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

    tee /etc/yum.repos.d/cuda-rhel10.repo > /dev/null <<'REPO'
[cuda-rhel10-x86_64]
name=cuda-rhel10-x86_64
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64
enabled=1
gpgcheck=1
gpgkey=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/CDF6BA43.pub
REPO

    dnf install -y dkms kmod-nvidia-open-dkms nvidia-driver-cuda

    touch "$MARKER"

    echo "Installing resume service for after reboot..."
    cp "$(readlink -f "$0")" "$RESUME_SCRIPT"
    chmod +x "$RESUME_SCRIPT"

    tee "$RESUME_UNIT" > /dev/null <<UNIT
[Unit]
Description=Resume vllm_omni RHEL10 AMI provisioning after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESUME_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable vllm-omni-provision-resume.service

    echo "Rebooting to load NVIDIA kernel module..."
    reboot
    exit 0
fi

echo "=== Phase 2: toolkit, cache volume, dlami-nvme ==="
# mesa-libGL provides libGL.so.1, an import-time dependency of opencv-python
# (pulled in by vllm-omni for its multimodal/video pipeline) that RHEL 10
# minimal doesn't ship by default. sqlite-devel provides sqlite3.h, needed
# to build CPython (e.g. python-tracer's cpython submodule) with sqlite
# support.
dnf install -y python3-pip python3-devel cuda-toolkit git lvm2 mesa-libGL sqlite-devel

# cuda-toolkit's rpm doesn't add itself to PATH (that's expected NVIDIA
# behavior, not something the package handles) -- without this, nvcc and
# friends are only reachable via the full /usr/local/cuda-*/bin path, which
# broke create-venv.sh's CUDA_VERSION detection.
echo "Adding CUDA toolkit to PATH..."
tee /etc/profile.d/cuda.sh > /dev/null <<'PROFILE'
export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
PROFILE
chmod +x /etc/profile.d/cuda.sh
source /etc/profile.d/cuda.sh

echo "Verifying NVIDIA driver..."
nvidia-smi

# ec2-user's default non-interactive-shell PATH already includes
# ~/.local/bin (confirmed via `ssh host env`), so installing here needs no
# separate PATH/profile.d fix, unlike cuda-toolkit above.
echo "Installing uv..."
sudo -u ec2-user bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

echo "Setting up persistent cache EBS volume..."
# Match by size (not just "first non-root disk") -- larger instance types
# also have local ephemeral NVMe instance-store disks (handled separately
# by dlami-nvme.service below), which must not be mistaken for the ~10GB
# EBS cache volume.
ROOT_DISK=$(lsblk -ndo pkname "$(findmnt -no SOURCE /)")
CACHE_SIZE_BYTES=$((CACHE_VOLUME_SIZE_GB * 1024 * 1024 * 1024))
CACHE_DISK=$(lsblk -ndbo NAME,TYPE,SIZE | awk -v root="$ROOT_DISK" -v target="$CACHE_SIZE_BYTES" \
    '$2=="disk" && $1!=root {diff=$3-target; if (diff<0) diff=-diff; if (diff < target*0.05) {print $1; exit}}')
if [[ -z "$CACHE_DISK" ]]; then
    echo "ERROR: could not find a ~${CACHE_VOLUME_SIZE_GB}GB disk for the cache volume" >&2
    exit 1
fi
CACHE_DEV="/dev/${CACHE_DISK}"

mkdir -p "$EBS_CACHE_DIR"
if ! blkid "$CACHE_DEV" &>/dev/null; then
    echo "Formatting $CACHE_DEV as xfs..."
    mkfs.xfs "$CACHE_DEV"
fi
if ! grep -q "$EBS_CACHE_DIR" /etc/fstab; then
    CACHE_UUID=$(blkid -s UUID -o value "$CACHE_DEV")
    echo "UUID=$CACHE_UUID $EBS_CACHE_DIR xfs defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q "$EBS_CACHE_DIR" || mount "$EBS_CACHE_DIR"
chown ec2-user:ec2-user "$EBS_CACHE_DIR"

echo "Installing DLAMI ephemeral NVMe mount service..."
mkdir -p /opt/aws/dlami/bin
tee /opt/aws/dlami/bin/nvme_ephemeral_drives.sh > /dev/null <<'NVME'
#!/bin/bash
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# https://github.com/aws/aws-parallelcluster-cookbook/blob/release-3.6/cookbooks/aws-parallelcluster-install/files/default/base/setup-ephemeral-drives.sh

LVM_VG_NAME="vg.01"
LVM_NAME="lv_ephemeral"
LVM_PATH="/dev/${LVM_VG_NAME}/${LVM_NAME}"
LVM_ACTIVE_STATE="a"
FS_TYPE="ext4"
MOUNT_OPTIONS="noatime,nodiratime"
INPUT_MOUNTPOINT="/opt/dlami/nvme"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>>/dev/null)
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/instance-type 2>>/dev/null)

function log {
  SCRIPT=$(basename "$0")
  MESSAGE="$1"
  echo "${MESSAGE}"
}

function error_exit {
  log "[ERROR] $1"
  log "[ERROR] Please validate that the instance is supported for NVME"
  exit 0
}

function exit_noop {
  log "[INFO] $1"
  exit 0
}


function set_imds_token {
  if [[ -z "${IMDS_TOKEN}" ]];then
    IMDS_TOKEN=$(curl --retry 3 --retry-delay 0 --fail -s -f -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 900" http://169.254.169.254/latest/api/token)
    if [[ "$?" -gt 0 ]] || [[ -z "${IMDS_TOKEN}" ]]; then
      error_exit "Could not get IMDSv2 token. Instance Metadata might have been disabled or this is not an EC2 instance"
    fi
  fi
}

function get_metadata {
    QUERY=$1
    local IMDS_OUTPUT
    IMDS_OUTPUT=$(curl --retry 3 --retry-delay 0 --fail -s -q -H "X-aws-ec2-metadata-token:${IMDS_TOKEN}" -f "http://169.254.169.254/latest/${QUERY}")
    echo -n "${IMDS_OUTPUT}"
}

function print_block_device_mapping {
  echo 'block-device-mapping: '
  DEVICE_MAPPING_LIST=$(get_metadata meta-data/block-device-mapping/)
  if [[ -n "${DEVICE_MAPPING_LIST}" ]]; then
    for DEVICE_MAPPING in ${DEVICE_MAPPING_LIST}; do
      echo -e '\t' "${DEVICE_MAPPING}: $(get_metadata meta-data/block-device-mapping/"${DEVICE_MAPPING}")"
    done
  else
    echo "NOT AVAILABLE"
  fi
}

function check_instance_store {
  if ls /dev/nvme* >& /dev/null; then
    IS_NVME=1
    MAPPINGS=$(realpath --relative-to=/dev/ -P /dev/disk/by-id/nvme*Instance_Storage* | grep -v "*Instance_Storage*" | uniq)
  else
    IS_NVME=0
    set_imds_token
    MAPPINGS=$(print_block_device_mapping | grep ephemeral | awk '{print $2}' | sed 's/sd/xvd/')
  fi

  NUM_DEVICES=0
  for MAPPING in ${MAPPINGS}; do
    umount "/dev/${MAPPING}" &>/dev/null
    STAT_COMMAND="stat -t /dev/${MAPPING}"
    if ${STAT_COMMAND} &>/dev/null; then
      DEVICES+=("/dev/${MAPPING}")
      NUM_DEVICES=$((NUM_DEVICES + 1))
    fi
  done

  if [[ "${NUM_DEVICES}" -gt 0 ]]; then
    log "This instance type has (${NUM_DEVICES}) device(s) for instance store: (${DEVICES[*]})"
  else
    exit_noop "This instance type doesn't have instance store"
  fi

  if [[ "${IS_NVME}" -eq 0 ]]; then
    log "This instance store may suffer first-write penalty unless initialized: please have a look at https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/disk-performance.html"
    # Initialization can take long time, even hours
    # for DEVICE in "${DEVICES[@]}"; do
    #  dd if=/dev/zero of="${DEVICE}" bs=1M
    # done
  fi
}

function create_lvm {
  log "Creating LVM (${LVM_PATH})"
  pvcreate -y "${DEVICES[@]}"
  vgcreate -y "${LVM_VG_NAME}" "${DEVICES[@]}"
  LVM_CREATE_COMMAND="lvcreate -y -i ${NUM_DEVICES} -I 64 -l 100%FREE -n ${LVM_NAME} ${LVM_VG_NAME}"
  if ! ${LVM_CREATE_COMMAND}; then
    error_exit "Failed to create LVM"
  else
    log "LVM (${LVM_PATH}) created successfully"
  fi
}

function check_lvm_exist {
  LVM_EXIST_COMMAND="lvs ${LVM_PATH} --nosuffix --noheadings -q"

  if ! ${LVM_EXIST_COMMAND} &>/dev/null; then
    log "LVM (${LVM_PATH}) does not exist"
    create_lvm
  else
    log "LVM (${LVM_PATH}) already exists"
  fi
}

function activate_lvm {
  LVM_STATE=$(lvs "${LVM_PATH}" --nosuffix --noheadings -o lv_attr | xargs | cut -c5)
  log "Found LVM (${LVM_PATH}) in state (${LVM_STATE})"

  if [[ "${LVM_STATE}" != "${LVM_ACTIVE_STATE}" ]]; then
    log "Activating LVM (${LVM_PATH})"
    LVM_ACTIVATE_COMMAND="lvchange -ay ${LVM_PATH}"
    if ! ${LVM_ACTIVATE_COMMAND}; then
      error_exit "Failed to activate LVM"
    else
      log "LVM (${LVM_PATH}) activated successfully"
    fi
  fi
}

function format_lvm {
  LVM_FS_TYPE=$(lsblk "${LVM_PATH}" --noheadings -o FSTYPE | xargs)
  log "Found LVM (${LVM_PATH}) FS type (${LVM_FS_TYPE})"

  if [[ "${LVM_FS_TYPE}" != "${FS_TYPE}" ]]; then
    log "Formatting LVM (${LVM_PATH}) with FS type (${FS_TYPE})"
    LVM_FORMAT_COMMAND="mkfs -t ${FS_TYPE} ${LVM_PATH}"
    if ! ${LVM_FORMAT_COMMAND}; then
      error_exit "Failed to format LVM"
    else
      log "LVM (${LVM_PATH}) formatted successfully"
    fi
    sync
    sleep 1
  else
    log "LVM (${LVM_PATH}) already formatted with FS type (${LVM_FS_TYPE})"
  fi
}

function mount_lvm {
  LVM_MOUNTPOINT=$(lsblk "${LVM_PATH}" -o MOUNTPOINT --noheadings | xargs)

  if [[ -z ${LVM_MOUNTPOINT} ]]; then
    log "LVM (${LVM_PATH}) not mounted, mounting on (${INPUT_MOUNTPOINT})"
    # create mount
    mkdir -p "${INPUT_MOUNTPOINT}"
    LVM_MOUNT_COMMAND="mount -v -t ${FS_TYPE} -o ${MOUNT_OPTIONS} ${LVM_PATH} ${INPUT_MOUNTPOINT}"
    if ! ${LVM_MOUNT_COMMAND}; then
      error_exit "Failed to mount LVM"
    else
      log "LVM (${LVM_PATH}) mounted successfully"
    fi
    # set mount permission
    chmod 1777 "${INPUT_MOUNTPOINT}"
  else
    log "LVM (${LVM_PATH}) already mounted on (${LVM_MOUNTPOINT})"
  fi
}

function link_home_cache {
  CACHE_DIR="${INPUT_MOUNTPOINT}/home-cache"
  HOME_CACHE="/home/ec2-user/.cache"
  EBS_CACHE_DIR="/opt/home-cache-ebs"
  mkdir -p "${CACHE_DIR}"
  chown ec2-user:ec2-user "${CACHE_DIR}"
  # EBS_CACHE_DIR is a persistent EBS volume; symlinking these names under
  # the ephemeral NVMe home-cache means anything under ~/.cache/{name} is
  # actually durable across a stop/start, not wiped with the instance store.
  for NAME in flashinfer nv-compute vllm; do
    mkdir -p "${EBS_CACHE_DIR}/${NAME}"
    chown ec2-user:ec2-user "${EBS_CACHE_DIR}/${NAME}"
    ln -sfn "${EBS_CACHE_DIR}/${NAME}" "${CACHE_DIR}/${NAME}"
    chown -h ec2-user:ec2-user "${CACHE_DIR}/${NAME}"
  done
  rm -rf "${HOME_CACHE}"
  ln -sfn "${CACHE_DIR}" "${HOME_CACHE}"
  chown -h ec2-user:ec2-user "${HOME_CACHE}"
  log "Linked ${HOME_CACHE} -> ${CACHE_DIR}"

  # Runtime kernel-compiler caches (~/.nv, ~/.triton, ~/.humming) live
  # directly under $HOME, not under ~/.cache -- confirmed populated after
  # actually running vllm serve (NVIDIA compute cache, Triton JIT cache,
  # and an NVRTC-compile cache respectively). EBS-back them the same way so
  # a stop/start (or a fresh instance built from a snapshot) doesn't force
  # re-JIT-compiling every kernel from scratch.
  HOME_DIR="/home/ec2-user"
  for NAME in .nv .triton .humming; do
    mkdir -p "${EBS_CACHE_DIR}/${NAME}"
    chown ec2-user:ec2-user "${EBS_CACHE_DIR}/${NAME}"
    rm -rf "${HOME_DIR}/${NAME}"
    ln -sfn "${EBS_CACHE_DIR}/${NAME}" "${HOME_DIR}/${NAME}"
    chown -h ec2-user:ec2-user "${HOME_DIR}/${NAME}"
  done
}

function setup_scratch_dirs {
  mkdir -p "${INPUT_MOUNTPOINT}/huggingface" "${INPUT_MOUNTPOINT}/uv"
  chown ec2-user:ec2-user "${INPUT_MOUNTPOINT}/huggingface" "${INPUT_MOUNTPOINT}/uv"
}

function main {
  check_instance_store
  check_lvm_exist
  activate_lvm
  format_lvm
  mount_lvm
  link_home_cache
  setup_scratch_dirs
}

main
NVME
chmod +x /opt/aws/dlami/bin/nvme_ephemeral_drives.sh

tee /etc/systemd/system/dlami-nvme.service > /dev/null <<'UNIT'
[Unit]
Description=Mount Ephemeral NVME Storage to DLAMI
After=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/aws/dlami/bin/nvme_ephemeral_drives.sh
TimeoutStartSec=300
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now dlami-nvme.service

echo "Cleaning up resume service..."
systemctl disable vllm-omni-provision-resume.service || true
rm -f "$RESUME_UNIT" "$RESUME_SCRIPT" "$MARKER"
systemctl daemon-reload

touch "$COMPLETE_MARKER"
echo "Provisioning complete. Instance now matches vraiti-rhel10-cuda base state."
