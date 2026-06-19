#!/usr/bin/env bash
# M1.8: Validate the guest image by booting a VM and asserting core capabilities.
#
# Checks:
#   1. VM boots and guest-agent is reachable (ping)
#   2. Docker becomes ready inside the guest
#   3. exec works (basic shell command)
#   4. docker run hello-world succeeds
#   5. Outbound egress works (curl icanhazip.com)
#   6. File upload + download round-trip
#
# Requires:
#   - /usr/local/bin/firecracker  (setup-host.sh)
#   - /tmp/vmlinux, /tmp/rootfs.ext4, /tmp/initramfs.cpio.gz
#   - bin/vsock-client  (make build-vsock-client)
#   - root (for tap device + iptables)
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
FC_LOG="/tmp/fc-validate.log"

# ---- cleanup -----------------------------------------------------------
cleanup() {
    echo ""
    echo "==> Cleanup..."
    [ -n "${FC_PID:-}" ] && kill "$FC_PID" 2>/dev/null || true
    ip link del "$TAP_DEV" 2>/dev/null || true
    rm -f "$API_SOCK" "$VSOCK_SOCK" "${VSOCK_SOCK}_${VM_CID}" "$OVERLAY"
    rm -f /tmp/validate-upload.txt /tmp/validate-download.txt
}
trap cleanup EXIT

fail() {
    echo ""
    echo "FAIL: $*" >&2
    echo ""
    echo "---- Firecracker console log ($FC_LOG) ----" >&2
    tail -50 "$FC_LOG" 2>/dev/null || echo "(no log)" >&2
    exit 1
}
ok() { echo "  OK: $*"; }

# ---- preflight ---------------------------------------------------------
[ -f "$FIRECRACKER" ] || fail "firecracker not found at $FIRECRACKER (run: sudo make setup-host)"
[ -f "$KERNEL" ]      || fail "kernel not found at $KERNEL (run: make build-kernel)"
[ -f "$ROOTFS" ]      || fail "rootfs not found at $ROOTFS (run: make bake-image)"
[ -f "$INITRAMFS" ]   || fail "initramfs not found at $INITRAMFS (run: make build-initramfs)"
[ -f "$VSOCK_CLIENT" ] || fail "vsock-client not found (run: make build-vsock-client)"

# ---- host networking ---------------------------------------------------
echo "==> Setting up host networking..."

# Bridge
if ! ip link show "$HOST_BRIDGE" &>/dev/null; then
    ip link add "$HOST_BRIDGE" type bridge
    ip addr add "${VM_GW}/24" dev "$HOST_BRIDGE"
    ip link set "$HOST_BRIDGE" up
fi

# IP forwarding
sysctl -qw net.ipv4.ip_forward=1

# Find the host's default egress interface
HOST_IF=$(ip route show default | awk '/default/ {print $5; exit}')
[ -n "$HOST_IF" ] || fail "could not determine host default interface"

# NAT + forwarding rules (idempotent)
iptables -t nat -C POSTROUTING -o "$HOST_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$HOST_IF" -j MASQUERADE

iptables -C FORWARD -i "$HOST_BRIDGE" -o "$HOST_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$HOST_BRIDGE" -o "$HOST_IF" -j ACCEPT

iptables -C FORWARD -i "$HOST_IF" -o "$HOST_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$HOST_IF" -o "$HOST_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT

# TAP device for this VM
ip link del "$TAP_DEV" 2>/dev/null || true
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

# Redirect VM console to log — keeps terminal clean and lets us diagnose failures.
"$FIRECRACKER" --api-sock "$API_SOCK" > "$FC_LOG" 2>&1 &
FC_PID=$!

echo "    Firecracker PID=$FC_PID, console → $FC_LOG"
echo "    (tail -f $FC_LOG in another terminal to watch boot)"

# Wait for API socket
for i in $(seq 1 40); do
    [ -S "$API_SOCK" ] && break
    sleep 0.1
done
[ -S "$API_SOCK" ] || fail "Firecracker did not create API socket (log: $FC_LOG)"

fc_api() {
    local endpoint="$1" body="$2"
    local resp
    resp=$(curl -s --unix-socket "$API_SOCK" -X PUT \
        -H "Content-Type: application/json" \
        "http://localhost/$endpoint" -d "$body")
    # Firecracker returns empty body on success, JSON fault on error
    if echo "$resp" | grep -q '"fault_message"'; then
        fail "Firecracker API error on $endpoint: $resp"
    fi
}

fc_api "boot-source" "{
  \"kernel_image_path\": \"$KERNEL\",
  \"initrd_path\": \"$INITRAMFS\",
  \"boot_args\": \"console=ttyS0 reboot=k panic=1 fc.ip=$VM_IP fc.gw=$VM_GW fc.dns=$VM_DNS\"
}"

fc_api "drives/rootfs" "{
  \"drive_id\": \"rootfs\",
  \"path_on_host\": \"$ROOTFS\",
  \"is_root_device\": true,
  \"is_read_only\": true
}"

fc_api "drives/overlay" "{
  \"drive_id\": \"overlay\",
  \"path_on_host\": \"$OVERLAY\",
  \"is_root_device\": false,
  \"is_read_only\": false
}"

fc_api "network-interfaces/eth0" "{
  \"iface_id\": \"eth0\",
  \"guest_mac\": \"AA:FC:00:00:00:01\",
  \"host_dev_name\": \"$TAP_DEV\"
}"

fc_api "vsock" "{
  \"guest_cid\": $VM_CID,
  \"uds_path\": \"$VSOCK_SOCK\"
}"

fc_api "machine-config" "{
  \"vcpu_count\": $VM_VCPUS,
  \"mem_size_mib\": $VM_MEM_MIB
}"

# Start the VM
curl -s --unix-socket "$API_SOCK" -X PUT \
    -H "Content-Type: application/json" \
    "http://localhost/actions" \
    -d '{"action_type":"InstanceStart"}' >/dev/null

# ---- phase 1: wait for guest-agent to bind on vsock --------------------
echo ""
echo "==> Phase 1: waiting for guest-agent vsock ping (up to 90s)..."
READY=false
for i in $(seq 1 180); do
    # Bail early if Firecracker crashed
    kill -0 "$FC_PID" 2>/dev/null || fail "Firecracker process exited unexpectedly"

    if "$VSOCK_CLIENT" -sock "$VSOCK_SOCK" ping 2>/dev/null | grep -q '"ok":true'; then
        READY=true
        break
    fi
    [ $((i % 20)) -eq 0 ] && echo "    ... still waiting (${i}×0.5s = $((i/2))s elapsed)"
    sleep 0.5
done
$READY || fail "guest-agent did not respond to ping in 90s"
ok "guest-agent: ping succeeded"

# ---- phase 2: wait for Docker to be ready inside the guest -------------
echo ""
echo "==> Phase 2: waiting for Docker to be ready inside guest (up to 90s)..."
DOCKER_READY=false
for i in $(seq 1 180); do
    kill -0 "$FC_PID" 2>/dev/null || fail "Firecracker process exited unexpectedly"

    PING=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" ping 2>/dev/null || true)
    if echo "$PING" | grep -q '"docker_ready":true'; then
        DOCKER_READY=true
        break
    fi
    [ $((i % 20)) -eq 0 ] && echo "    ... Docker not ready yet ($((i/2))s elapsed)"
    sleep 0.5
done
$DOCKER_READY || fail "Docker did not become ready in guest within 90s"
ok "Docker is ready inside guest"

# ---- functional checks -------------------------------------------------
echo ""
echo "==> Running checks..."

# 1. Basic exec
OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- uname -r 2>&1)
echo "$OUT" | grep -qE "^[0-9]" || fail "exec uname -r returned unexpected: $OUT"
ok "exec: uname -r → $(echo "$OUT" | tr -d '\n')"

# 2. Docker hello-world
echo "    (pulling hello-world, may take a moment...)"
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" stream -- \
    docker run --rm hello-world 2>&1 | tee /tmp/validate-hello.log | grep -q "Hello from Docker" \
    || fail "docker run hello-world failed (see /tmp/validate-hello.log)"
ok "docker: hello-world ran successfully"

# 3. Egress
OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- \
    curl -sf --max-time 15 https://icanhazip.com 2>&1)
echo "$OUT" | grep -qE "^[0-9]{1,3}\." || fail "egress check failed: $OUT"
ok "egress: public IP = $(echo "$OUT" | tr -d '\n')"

# 4. File upload + download round-trip
echo "hello from host $(date)" > /tmp/validate-upload.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" upload /tmp/validate-upload.txt /tmp/validate-test.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" download /tmp/validate-test.txt /tmp/validate-download.txt
diff /tmp/validate-upload.txt /tmp/validate-download.txt \
    || fail "file upload/download round-trip content mismatch"
ok "file transfer: upload/download round-trip"

echo ""
echo "================================================"
echo " ALL M1 CHECKS PASSED"
echo "================================================"
