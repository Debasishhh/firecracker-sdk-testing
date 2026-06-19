#!/usr/bin/env bash
# M1.3: Obtain a guest kernel for Firecracker.
#
# Option A (default): Download a pre-built kernel from Firecracker's CI bucket.
#   Fast, no toolchain needed. Works for most use cases.
#
# Option B: Build from source (uncomment the BUILD section below).
#   Use this if you need custom configs (e.g. additional modules).
#
# Output: /tmp/vmlinux
# Run from repo root: ./images/build-kernel.sh

set -euo pipefail

source "$(dirname "$0")/../versions.env"

KERNEL_OUT="${KERNEL_OUT:-/tmp/vmlinux}"
ARCH="$(uname -m)"

# --------------------------------------------------------------------------
# Option A: Pre-built kernel from Firecracker's S3 CI bucket
# --------------------------------------------------------------------------
echo "==> Downloading pre-built Firecracker kernel (${ARCH})..."
# Firecracker provides 5.10 and 6.1 kernels. 5.10 is the stable choice with
# all Docker-required configs (overlay, cgroups v2, netfilter, vsock).
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/${ARCH}/kernels/vmlinux.bin"

curl -fsSL "$KERNEL_URL" -o "$KERNEL_OUT"
echo "==> Kernel ready: $KERNEL_OUT"

# --------------------------------------------------------------------------
# Option B: Build from source (disabled by default)
# Required kernel configs for our stack (Docker + overlayfs + vsock):
#
#   CONFIG_OVERLAY_FS=y        # Docker overlay2 storage driver
#   CONFIG_VSOCK=y             # vsock transport
#   CONFIG_VIRTIO_VSOCK=y      # virtio-vsock (Firecracker's vsock backend)
#   CONFIG_NAMESPACES=y
#   CONFIG_NET_NS=y            # Docker network namespaces
#   CONFIG_PID_NS=y
#   CONFIG_USER_NS=y
#   CONFIG_CGROUPS=y
#   CONFIG_CGROUP_NS=y
#   CONFIG_MEMCG=y
#   CONFIG_BLK_CGROUP=y
#   CONFIG_NETFILTER=y
#   CONFIG_NF_NAT=y
#   CONFIG_IP_NF_TARGET_MASQUERADE=y   # NAT/egress
#   CONFIG_BRIDGE=y
#   CONFIG_BRIDGE_NETFILTER=y
#   CONFIG_VETH=y
# --------------------------------------------------------------------------
# BUILD=false
# if [ "${BUILD:-false}" = "true" ]; then
#   apt-get install -y build-essential libncurses-dev bison flex libssl-dev libelf-dev bc
#   KVER="5.10.225"
#   wget "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$KVER.tar.xz"
#   tar xf "linux-$KVER.tar.xz"
#   cd "linux-$KVER"
#   # Start from Firecracker's minimal defconfig
#   curl -fsSL "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-5.10.config" -o .config
#   # Apply any local overrides
#   # echo "CONFIG_OVERLAY_FS=y" >> .config
#   make olddefconfig
#   make -j$(nproc) vmlinux
#   cp vmlinux "$KERNEL_OUT"
# fi
