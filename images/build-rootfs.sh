#!/usr/bin/env bash
# M1.1 + M1.2: Build the guest base rootfs as an ext4 image.
#
# Steps:
#   1. Build Docker image (Ubuntu + dev tools + Docker CE)
#   2. Export container filesystem to a tar
#   3. Create a sparse ext4 image and populate it
#   4. Copy in guestinit, guest-agent, and systemd units
#
# Output: /tmp/rootfs.ext4
# Requires: docker, dd, mkfs.ext4, root (for mount)
# Run from repo root: ./images/build-rootfs.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="${ROOTFS:-/tmp/rootfs.ext4}"
IMG_NAME="firecracker-guest:latest"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-4096}"  # 4 GB base image

BIN_DIR="$REPO_ROOT/bin"
SYSTEMD_DIR="$REPO_ROOT/systemd"

echo "==> Building Docker image..."
docker build -t "$IMG_NAME" "$REPO_ROOT/images"

echo "==> Creating ${ROOTFS_SIZE_MB}MB sparse ext4 at $ROOTFS..."
rm -f "$ROOTFS"
dd if=/dev/zero of="$ROOTFS" bs=1M count=0 seek="$ROOTFS_SIZE_MB" 2>/dev/null
mkfs.ext4 -F -L rootfs "$ROOTFS"

echo "==> Mounting rootfs..."
MOUNT=$(mktemp -d)
sudo mount -o loop "$ROOTFS" "$MOUNT"
cleanup() { sudo umount "$MOUNT" 2>/dev/null; rmdir "$MOUNT" 2>/dev/null; }
trap cleanup EXIT

echo "==> Exporting container filesystem..."
CID=$(docker create "$IMG_NAME")
docker export "$CID" | sudo tar -xC "$MOUNT" \
    --exclude='dev/*' \
    --exclude='proc/*' \
    --exclude='sys/*'
docker rm "$CID"

echo "==> Installing guest binaries..."
sudo install -m 0755 "$BIN_DIR/guestinit"    "$MOUNT/usr/local/bin/guestinit"
sudo install -m 0755 "$BIN_DIR/guest-agent"  "$MOUNT/usr/local/bin/guest-agent"

echo "==> Installing systemd units..."
sudo install -m 0644 "$SYSTEMD_DIR/guestinit.service"   "$MOUNT/etc/systemd/system/guestinit.service"
sudo install -m 0644 "$SYSTEMD_DIR/guest-agent.service" "$MOUNT/etc/systemd/system/guest-agent.service"

# Enable units
sudo mkdir -p "$MOUNT/etc/systemd/system/network.target.wants"
sudo mkdir -p "$MOUNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/guestinit.service \
    "$MOUNT/etc/systemd/system/network.target.wants/guestinit.service"
sudo ln -sf /etc/systemd/system/guest-agent.service \
    "$MOUNT/etc/systemd/system/multi-user.target.wants/guest-agent.service"

echo "==> Rootfs ready: $ROOTFS"
echo "    $(du -sh "$ROOTFS" | cut -f1) on disk"
