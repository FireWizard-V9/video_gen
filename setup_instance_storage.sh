cat << 'EOF' > setup_instance_storage.sh
#!/usr/bin/env bash
set -eo pipefail

echo "=== 1. Expanding Root Disk Partition (if needed) ==="
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(echo "$ROOT_DEV" | sed -E 's/p[0-9]+$//; s/[0-9]+$//')
ROOT_PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')

if [[ "$ROOT_DEV" != "$ROOT_DISK" ]]; then
    echo "Expanding partition $ROOT_PART_NUM on $ROOT_DISK..."
    sudo growpart "$ROOT_DISK" "$ROOT_PART_NUM" || true
    sudo resize2fs "$ROOT_DEV" || sudo xfs_growfs / || true
fi

echo "=== 2. Auto-Detecting Ephemeral Instance Storage ==="
# Find unformatted/unmounted NVMe instance store drives
EPHEMERAL_DISK=""
for disk in /dev/nvme*n1; do
    if [ -b "$disk" ] && ! lsblk -n -o MOUNTPOINT "$disk" | grep -q "/"; then
        # Check if it's not the root disk drive
        if [[ "$disk" != *"$ROOT_DISK"* ]]; then
            EPHEMERAL_DISK="$disk"
            break
        fi
    fi
done

MOUNT_DIR="/mnt/fast-storage"

if [ -n "$EPHEMERAL_DISK" ]; then
    echo "Found ephemeral NVMe drive: $EPHEMERAL_DISK"
    
    # Format if no filesystem exists
    if ! sudo blkid "$EPHEMERAL_DISK" > /dev/null 2>&1; then
        echo "Formatting $EPHEMERAL_DISK with ext4..."
        sudo mkfs.ext4 -F "$EPHEMERAL_DISK"
    fi

    # Mount disk
    sudo mkdir -p "$MOUNT_DIR"
    sudo mount "$EPHEMERAL_DISK" "$MOUNT_DIR"
    sudo chown -R $USER:$USER "$MOUNT_DIR"
    echo "Mounted $EPHEMERAL_DISK at $MOUNT_DIR"
else
    echo "No unmounted NVMe instance storage detected. Creating local fallback directory on root volume..."
    sudo mkdir -p "$MOUNT_DIR"
    sudo chown -R $USER:$USER "$MOUNT_DIR"
fi

echo "=== 3. Configuring Hugging Face Cache Path ==="
export HF_HOME="$MOUNT_DIR/huggingface"
mkdir -p "$HF_HOME"

if ! grep -q "HF_HOME" ~/.bashrc; then
    echo "export HF_HOME=\"$MOUNT_DIR/huggingface\"" >> ~/.bashrc
    echo "Added HF_HOME to ~/.bashrc"
fi

echo "=== 4. Redirecting Docker Storage to Fast NVMe ==="
if command -v docker >/dev/null 2>&1 || systemctl is-active --quiet docker; then
    sudo systemctl stop docker || true
    sudo mkdir -p "$MOUNT_DIR/docker-data"
    
    sudo bash -c "cat <<DOCKER_EOF > /etc/docker/daemon.json
{
  \"data-root\": \"$MOUNT_DIR/docker-data\"
}
DOCKER_EOF"

    sudo systemctl start docker
    echo "Docker root directory successfully re-pointed to $MOUNT_DIR/docker-data"
else
    echo "Docker not installed yet. Creating preset directory at $MOUNT_DIR/docker-data..."
    sudo mkdir -p "$MOUNT_DIR/docker-data"
    sudo bash -c "mkdir -p /etc/docker && cat <<DOCKER_EOF > /etc/docker/daemon.json
{
  \"data-root\": \"$MOUNT_DIR/docker-data\"
}
DOCKER_EOF"
fi

echo "=== Setup Complete! ==="
df -h "$MOUNT_DIR"
EOF

chmod +x setup_instance_storage.sh
./setup_instance_storage.sh
