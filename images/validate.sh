#!/usr/bin/env bash
# M1.8: Validate the guest image by booting a VM and asserting core capabilities.
#
# Checks:
#   1. VM boots and guest-agent becomes reachable (ping)
#   2. exec works (basic shell command)
#   3. Docker is running inside the guest
#   4. Outbound egress works (curl icanhazip.com)
#   5. File upload + download round-trip
#
# Requires:
#   - /usr/local/bin/firecracker
#   - /tmp/vmlinux, /tmp/rootfs.ext4, /tmp/initramfs.cpio.gz
#   - bin/vsock-client (built by: make build-vsock-client)
#   - root (for tap device)
#
# Run: sudo ./images/validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/versions.env"

FIRECRACKER="${FIRECRACKER:-/usr/local/bin/firecracker}"
KERNEL="${KERNEL:-/tmp/vmlinux}"
ROOTFS="${ROOTFS:-/tmp/rootfs.ext4}"
INITRAMFS="${INITRAMFS:-/tmp/initramfs.cpio.gz}"
VSOCK_CLIENT="$REPO_ROOT/bin/vsock-client"

# VM resources
VM_CID=99
VM_MEM_MIB=2048
VM_VCPUS=2
VM_IP="10.99.0.2/24"
VM_GW="10.99.0.1"
VM_DNS="8.8.8.8"

# Host paths
API_SOCK="/tmp/fc-validate-api.sock"
VSOCK_SOCK="/tmp/fc-validate-vsock.sock"
OVERLAY="/tmp/fc-validate-overlay.ext4"
TAP_DEV="fc-validate"
HOST_BRIDGE="fcbr0"
OVERLAY_SIZE_MB=2048

# ---- cleanup -----------------------------------------------------------
cleanup() {
    echo "==> Cleanup..."
    # Kill firecracker
    [ -n "${FC_PID:-}" ] && kill "$FC_PID" 2>/dev/null || true
    # Remove tap
    ip link del "$TAP_DEV" 2>/dev/null || true
    # Remove artifacts
    rm -f "$API_SOCK" "$VSOCK_SOCK" "${VSOCK_SOCK}_${VM_CID}" "$OVERLAY"
    # Remove temp file
    rm -f /tmp/validate-upload.txt /tmp/validate-download.txt
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  OK: $*"; }

# ---- host networking ---------------------------------------------------
echo "==> Setting up host networking..."
# Create bridge if absent
if ! ip link show "$HOST_BRIDGE" &>/dev/null; then
    ip link add "$HOST_BRIDGE" type bridge
    ip addr add "${VM_GW}/24" dev "$HOST_BRIDGE"
    ip link set "$HOST_BRIDGE" up
fi
# Enable IP forwarding + NAT
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Create TAP for this VM
ip tuntap add dev "$TAP_DEV" mode tap
ip link set "$TAP_DEV" master "$HOST_BRIDGE"
ip link set "$TAP_DEV" up

# ---- per-VM overlay disk -----------------------------------------------
echo "==> Creating overlay disk (${OVERLAY_SIZE_MB}MB)..."
dd if=/dev/zero of="$OVERLAY" bs=1M count=0 seek="$OVERLAY_SIZE_MB" 2>/dev/null
mkfs.ext4 -F "$OVERLAY" >/dev/null

# ---- boot VM -----------------------------------------------------------
echo "==> Booting VM (CID=$VM_CID)..."
rm -f "$API_SOCK"

"$FIRECRACKER" --api-sock "$API_SOCK" &
FC_PID=$!

# Wait for API socket
for i in $(seq 1 20); do
    [ -S "$API_SOCK" ] && break
    sleep 0.1
done
[ -S "$API_SOCK" ] || fail "Firecracker did not create API socket"

fc_api() {
    curl -s --unix-socket "$API_SOCK" -X PUT \
        -H "Content-Type: application/json" \
        "http://localhost/$1" -d "$2"
}

# Boot source
fc_api "boot-source" "{
  \"kernel_image_path\": \"$KERNEL\",
  \"initrd_path\": \"$INITRAMFS\",
  \"boot_args\": \"console=ttyS0 reboot=k panic=1 fc.ip=$VM_IP fc.gw=$VM_GW fc.dns=$VM_DNS\"
}" >/dev/null

# Drives
fc_api "drives/rootfs" "{
  \"drive_id\": \"rootfs\",
  \"path_on_host\": \"$ROOTFS\",
  \"is_root_device\": true,
  \"is_read_only\": true
}" >/dev/null

fc_api "drives/overlay" "{
  \"drive_id\": \"overlay\",
  \"path_on_host\": \"$OVERLAY\",
  \"is_root_device\": false,
  \"is_read_only\": false
}" >/dev/null

# Network
fc_api "network-interfaces/eth0" "{
  \"iface_id\": \"eth0\",
  \"guest_mac\": \"AA:FC:00:00:00:01\",
  \"host_dev_name\": \"$TAP_DEV\"
}" >/dev/null

# Vsock
fc_api "vsock" "{
  \"guest_cid\": $VM_CID,
  \"uds_path\": \"$VSOCK_SOCK\"
}" >/dev/null

# Machine config
fc_api "machine-config" "{
  \"vcpu_count\": $VM_VCPUS,
  \"mem_size_mib\": $VM_MEM_MIB
}" >/dev/null

# Start!
curl -s --unix-socket "$API_SOCK" -X PUT \
    -H "Content-Type: application/json" \
    "http://localhost/actions" \
    -d '{"action_type":"InstanceStart"}' >/dev/null

echo "==> Waiting for guest-agent to become ready (up to 60s)..."
READY=false
for i in $(seq 1 120); do
    if "$VSOCK_CLIENT" -sock "$VSOCK_SOCK" ping 2>/dev/null | grep -q '"ok": true'; then
        READY=true
        break
    fi
    sleep 0.5
done
$READY || fail "guest-agent did not become ready in 60s"
ok "guest-agent ping"

# ---- checks ------------------------------------------------------------
echo "==> Running checks..."

# 1. Basic exec
OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- uname -r 2>&1)
echo "$OUT" | grep -q "." || fail "exec uname -r returned nothing"
ok "exec: uname -r → $OUT"

# 2. Docker running
OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- docker info 2>&1 | head -1)
echo "$OUT" | grep -qi "client\|server\|docker" || fail "docker info failed: $OUT"
ok "docker: docker info succeeded"

# 3. Docker hello-world
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" stream -- \
    docker run --rm hello-world 2>&1 | grep -q "Hello from Docker" \
    || fail "docker run hello-world failed"
ok "docker: hello-world container ran"

# 4. Egress (curl)
OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- \
    curl -sf --max-time 10 https://icanhazip.com 2>&1)
echo "$OUT" | grep -qE "^[0-9]" || fail "egress check failed: $OUT"
ok "egress: public IP = $OUT"

# 5. Upload + download round-trip
echo "hello from host $(date)" > /tmp/validate-upload.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" upload /tmp/validate-upload.txt /tmp/validate-test.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" download /tmp/validate-test.txt /tmp/validate-download.txt
diff /tmp/validate-upload.txt /tmp/validate-download.txt \
    || fail "upload/download round-trip mismatch"
ok "file transfer: upload/download round-trip"

echo ""
echo "=============================="
echo " ALL CHECKS PASSED"
echo "=============================="
