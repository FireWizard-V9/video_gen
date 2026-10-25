#!/usr/bin/env bash
set -eo pipefail
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "=================================================="
echo "=== 1. System Updates & Kernel Headers Setup ==="
echo "=================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y linux-headers-$(uname -r) build-essential dkms git wget curl cloud-guest-utils

echo "=================================================="
echo "=== 2. NVIDIA Driver & Toolkit Installation ==="
echo "=================================================="
# Clean up any partial driver conflicts
apt-get purge -y "*nvidia*" "*cuda*" || true

# Install non-conflicting Open Server Driver (works cleanly on AWS hypervisors)
apt-get install -y nvidia-driver-550-server-open nvidia-utils-550-server

# Install NVIDIA Container Toolkit for Docker
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/experimental/ubuntu22.04/libnvidia-container.list | \
  sed 's#deb [^ ]* #&[signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] #' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y docker.io nvidia-container-toolkit

echo "=================================================="
echo "=== 3. Expand Root Disk Partition (EBS Volume) ==="
echo "=================================================="
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(echo "$ROOT_DEV" | sed -E 's/p[0-9]+$//; s/[0-9]+$//')
ROOT_PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')

if [[ "$ROOT_DEV" != "$ROOT_DISK" ]]; then
    echo "Expanding partition $ROOT_PART_NUM on $ROOT_DISK..."
    growpart "$ROOT_DISK" "$ROOT_PART_NUM" || true
    resize2fs "$ROOT_DEV" || xfs_growfs / || true
fi

echo "=================================================="
echo "=== 4. Ephemeral Storage Mount & Formatting ==="
echo "=================================================="
EPHEMERAL_DISK=""
for disk in /dev/nvme*n1; do
    if [ -b "$disk" ] && ! lsblk -n -o MOUNTPOINT "$disk" | grep -q "/"; then
        if [[ "$disk" != *"$ROOT_DISK"* ]]; then
            EPHEMERAL_DISK="$disk"
            break
        fi
    fi
done

MOUNT_DIR="/mnt/fast-storage"

if [ -n "$EPHEMERAL_DISK" ]; then
    echo "Found ephemeral NVMe drive: $EPHEMERAL_DISK"
    if ! blkid "$EPHEMERAL_DISK" > /dev/null 2>&1; then
        echo "Formatting $EPHEMERAL_DISK with ext4..."
        mkfs.ext4 -F "$EPHEMERAL_DISK"
    fi
    mkdir -p "$MOUNT_DIR"
    mount "$EPHEMERAL_DISK" "$MOUNT_DIR"
    chown -R ubuntu:ubuntu "$MOUNT_DIR"
    echo "Mounted $EPHEMERAL_DISK at $MOUNT_DIR"
else
    echo "No unmounted NVMe instance storage detected. Using fallback directory..."
    mkdir -p "$MOUNT_DIR"
    chown -R ubuntu:ubuntu "$MOUNT_DIR"
fi

echo "=================================================="
echo "=== 5. Configure Docker & Hugging Face Storage ==="
echo "=================================================="
# Configure Docker Root Directory
systemctl stop docker || true
mkdir -p "$MOUNT_DIR/docker-data"

cat <<DOCKER_EOF > /etc/docker/daemon.json
{
  "data-root": "$MOUNT_DIR/docker-data"
}
DOCKER_EOF

# Enable GPU runtime inside Docker
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Configure Hugging Face Cache Path for Ubuntu User
mkdir -p "$MOUNT_DIR/huggingface"
chown -R ubuntu:ubuntu "$MOUNT_DIR/huggingface"

if ! grep -q "HF_HOME" /home/ubuntu/.bashrc; then
    echo "export HF_HOME=\"$MOUNT_DIR/huggingface\"" >> /home/ubuntu/.bashrc
    chown ubuntu:ubuntu /home/ubuntu/.bashrc
fi

echo "=================================================="
echo "=== Setup Complete! Log saved to /var/log/user-data.log ==="
echo "=================================================="