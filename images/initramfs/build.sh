#!/usr/bin/env bash
# M1.4: Build the overlayfs initramfs as a gzip'd cpio archive.
#
# Output: /tmp/initramfs.cpio.gz
# Requires: busybox-static (apt-get install busybox-static)
# Run from repo root: ./images/initramfs/build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${INITRAMFS:-/tmp/initramfs.cpio.gz}"

echo "==> Building initramfs..."

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Create minimal directory structure
mkdir -p "$WORK"/{bin,dev,proc,sys,base,rw,newroot}

# Busybox provides sh, mount, umount, switch_root, mkdir, echo
if [ ! -f /usr/bin/busybox ]; then
    echo "==> Installing busybox-static..."
    sudo apt-get install -y busybox-static
fi

cp /usr/bin/busybox "$WORK/bin/busybox"
chmod +x "$WORK/bin/busybox"
# Create symlinks for the tools the init script uses
for tool in sh mount umount switch_root mkdir echo; do
    ln -sf busybox "$WORK/bin/$tool"
done

# Install our init script
install -m 0755 "$SCRIPT_DIR/init" "$WORK/init"

# Pack into cpio + gzip
echo "==> Packing cpio..."
(cd "$WORK" && find . | cpio -o -H newc --quiet | gzip -9 > "$OUT")

echo "==> Initramfs ready: $OUT ($(du -sh "$OUT" | cut -f1))"
