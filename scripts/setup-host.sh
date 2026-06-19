#!/usr/bin/env bash
# M0.1 / M0.2: Bootstrap a fresh Ubuntu 22.04 EC2 instance to run Firecracker.
#
# What this does:
#   1. Verifies KVM is available
#   2. Installs Firecracker + jailer (pinned version from versions.env)
#   3. Installs host tools: iproute2, iptables, Docker (for building rootfs)
#   4. Downloads a pre-built guest kernel
#   5. Sets /dev/kvm permissions for the current user
#
# Run: sudo ./scripts/setup-host.sh
# Tested on: Ubuntu 22.04 x86_64 (c5.metal, m5.metal, or any instance with KVM)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/versions.env"

ARCH="$(uname -m)"

step() { echo; echo "==> $*"; }
ok()   { echo "  OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- KVM check ---------------------------------------------------------
step "Checking KVM support..."
if [ ! -e /dev/kvm ]; then
    fail "/dev/kvm not found.
This instance type may not support KVM.
Use a bare-metal (*.metal) or nested-virt-enabled instance type.
Check: https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md"
fi
stat /dev/kvm
ok "/dev/kvm is present"

# Allow the current user (and the 'firecracker' group) to use KVM
if ! id -nG | grep -q kvm; then
    groupadd -f kvm
    usermod -aG kvm "$SUDO_USER"
fi
chmod 660 /dev/kvm
chown root:kvm /dev/kvm
ok "KVM permissions set"

# ---- System dependencies -----------------------------------------------
step "Installing system dependencies..."
apt-get update -q
apt-get install -y --no-install-recommends \
    curl wget jq \
    iproute2 iptables \
    ca-certificates \
    make

# ---- Firecracker -------------------------------------------------------
step "Installing Firecracker v${FIRECRACKER_VERSION}..."
FC_RELEASE="https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

curl -fsSL "${FC_RELEASE}/firecracker-v${FIRECRACKER_VERSION}-${ARCH}.tgz" \
    | tar -xz -C "$TMP"

FC_DIR="$TMP/release-v${FIRECRACKER_VERSION}-${ARCH}"
install -m 0755 "${FC_DIR}/firecracker-v${FIRECRACKER_VERSION}-${ARCH}" /usr/local/bin/firecracker
install -m 0755 "${FC_DIR}/jailer-v${FIRECRACKER_VERSION}-${ARCH}"     /usr/local/bin/jailer
ok "Firecracker: $(firecracker --version 2>&1 | head -1)"
ok "Jailer:      $(jailer --version 2>&1 | head -1)"

# ---- Docker (for building the guest rootfs image) ----------------------
step "Installing Docker (for rootfs builds)..."
if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y docker-ce docker-ce-cli containerd.io
    usermod -aG docker "${SUDO_USER:-$USER}"
    systemctl enable --now docker
fi
ok "Docker: $(docker --version)"

# ---- Guest kernel ------------------------------------------------------
step "Downloading guest kernel (vmlinux)..."
if [ ! -f /tmp/vmlinux ]; then
    ./images/build-kernel.sh
fi
ok "Kernel: /tmp/vmlinux ($(du -sh /tmp/vmlinux | cut -f1))"

# ---- Go (for building the SDK) -----------------------------------------
step "Checking Go toolchain..."
if ! command -v go &>/dev/null; then
    echo "Go not found. Install from https://go.dev/dl/ then re-run."
    echo "Quick install:"
    echo "  wget https://go.dev/dl/go1.22.4.linux-amd64.tar.gz"
    echo "  tar -C /usr/local -xzf go1.22.4.linux-amd64.tar.gz"
    echo "  echo 'export PATH=\$PATH:/usr/local/go/bin' >> ~/.profile"
else
    ok "Go: $(go version)"
fi

echo ""
echo "========================================"
echo " Host setup complete."
echo "  firecracker: $(which firecracker)"
echo "  jailer:      $(which jailer)"
echo "  kernel:      /tmp/vmlinux"
echo ""
echo " Next steps:"
echo "  1. go mod tidy                   # fetch Go deps"
echo "  2. make build-guest              # compile guestinit + guest-agent"
echo "  3. make bake-image               # build rootfs.ext4"
echo "  4. make build-initramfs          # build initramfs.cpio.gz"
echo "  5. sudo make validate            # boot a test VM and run checks"
echo "========================================"
