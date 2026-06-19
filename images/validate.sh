#!/usr/bin/env bash
# M1.8: Validate the guest image.
#
# Boot strategy: single r/w rootfs, no initramfs, init=/usr/local/bin/guestinit.
# guestinit configures networking from kernel cmdline then execs /sbin/init (systemd).
# systemd starts guest-agent.service which binds vsock port 52.
# Overlayfs (M1.4) is tested separately — validate needs to stay simple.
#
# Checks:
#   1. rootfs pre-flight: guest-agent binary + service present
#   2. VM boots and guest-agent responds on vsock (ping)
#   3. Docker becomes ready inside the guest
#   4. exec: uname -r
#   5. docker run hello-world
#   6. egress: curl icanhazip.com
#   7. file upload + download round-trip
#
# Run: sudo ./images/validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/versions.env"

FIRECRACKER="${FIRECRACKER:-/usr/local/bin/firecracker}"
KERNEL="${KERNEL:-/tmp/vmlinux}"
ROOTFS="${ROOTFS:-/tmp/rootfs.ext4}"
VSOCK_CLIENT="$REPO_ROOT/bin/vsock-client"

VM_CID=99
VM_MEM_MIB=2048
VM_VCPUS=2
VM_IP="10.99.0.2/24"
VM_GW="10.99.0.1"
VM_DNS="8.8.8.8"

API_SOCK="/tmp/fc-validate-api.sock"
VSOCK_SOCK="/tmp/fc-validate-vsock.sock"
TAP_DEV="fc-validate"
HOST_BRIDGE="fcbr0"
FC_LOG="/tmp/fc-validate.log"

# ---- helpers -----------------------------------------------------------
cleanup() {
    echo ""
    echo "==> Cleanup..."
    [ -n "${FC_PID:-}" ] && kill "$FC_PID" 2>/dev/null || true
    ip link del "$TAP_DEV" 2>/dev/null || true
    rm -f "$API_SOCK" "$VSOCK_SOCK" /tmp/validate-upload.txt /tmp/validate-download.txt
}
trap cleanup EXIT

fail() {
    echo ""
    echo "FAIL: $*" >&2
    echo ""
    if [ -f "$FC_LOG" ]; then
        echo "---- last 40 lines of $FC_LOG ----" >&2
        tail -40 "$FC_LOG" >&2
    fi
    exit 1
}
ok() { echo "  OK: $*"; }

# ---- preflight: host binaries ------------------------------------------
[ -f "$FIRECRACKER" ]   || fail "firecracker not found (run: sudo make setup-host)"
[ -f "$KERNEL" ]        || fail "kernel not found at $KERNEL (run: make build-kernel)"
[ -f "$ROOTFS" ]        || fail "rootfs not found at $ROOTFS (run: sudo make bake-image)"
[ -f "$VSOCK_CLIENT" ]  || fail "vsock-client not found (run: make build-vsock-client)"

# ---- preflight: inspect rootfs -----------------------------------------
echo "==> Verifying rootfs contents..."
ROOTFS_MNT=$(mktemp -d)
sudo mount -o loop,ro "$ROOTFS" "$ROOTFS_MNT"
rootfs_cleanup() { sudo umount "$ROOTFS_MNT" 2>/dev/null; rmdir "$ROOTFS_MNT" 2>/dev/null; }
trap 'rootfs_cleanup; cleanup' EXIT

check_rootfs() {
    local path="$1" desc="$2"
    [ -e "$ROOTFS_MNT/$path" ] || fail "rootfs missing $desc ($path) — rebuild with: sudo make bake-image"
}
check_rootfs "usr/local/bin/guest-agent"           "guest-agent binary"
check_rootfs "usr/local/bin/guestinit"             "guestinit binary"
check_rootfs "etc/systemd/system/guest-agent.service"  "guest-agent.service unit"
check_rootfs "etc/systemd/system/guestinit.service"    "guestinit.service unit"

# Check service is enabled (symlink in wants directory)
WANTS="$ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/guest-agent.service"
[ -e "$WANTS" ] || fail "guest-agent.service not enabled in rootfs — rebuild with: sudo make bake-image"
ok "rootfs has guest-agent binary + service enabled"

sudo umount "$ROOTFS_MNT" && rmdir "$ROOTFS_MNT"
trap cleanup EXIT  # restore normal cleanup

# ---- host networking ---------------------------------------------------
echo "==> Setting up host networking..."

if ! ip link show "$HOST_BRIDGE" &>/dev/null; then
    ip link add "$HOST_BRIDGE" type bridge
    ip addr add "${VM_GW}/24" dev "$HOST_BRIDGE"
    ip link set "$HOST_BRIDGE" up
fi

sysctl -qw net.ipv4.ip_forward=1

HOST_IF=$(ip route show default | awk '/default/ {print $5; exit}')
[ -n "$HOST_IF" ] || fail "cannot determine host default interface"

iptables -t nat -C POSTROUTING -o "$HOST_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$HOST_IF" -j MASQUERADE

iptables -C FORWARD -i "$HOST_BRIDGE" -o "$HOST_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$HOST_BRIDGE" -o "$HOST_IF" -j ACCEPT

iptables -C FORWARD -i "$HOST_IF" -o "$HOST_BRIDGE" -m state \
    --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$HOST_IF" -o "$HOST_BRIDGE" -m state \
    --state RELATED,ESTABLISHED -j ACCEPT

ip link del "$TAP_DEV" 2>/dev/null || true
ip tuntap add dev "$TAP_DEV" mode tap
ip link set "$TAP_DEV" master "$HOST_BRIDGE"
ip link set "$TAP_DEV" up
ok "host networking ready (bridge=$HOST_BRIDGE, tap=$TAP_DEV)"

# ---- boot VM -----------------------------------------------------------
echo "==> Booting VM (CID=$VM_CID, ${VM_VCPUS}vCPU, ${VM_MEM_MIB}MB)..."
echo "    console → $FC_LOG   (tail -f $FC_LOG to watch boot)"
rm -f "$API_SOCK"

"$FIRECRACKER" --api-sock "$API_SOCK" > "$FC_LOG" 2>&1 &
FC_PID=$!

# Wait for Firecracker to create its API socket
for i in $(seq 1 50); do [ -S "$API_SOCK" ] && break; sleep 0.1; done
[ -S "$API_SOCK" ] || fail "Firecracker did not create API socket — is firecracker installed?"

fc_api() {
    local ep="$1" body="$2"
    local out
    out=$(curl -sf --unix-socket "$API_SOCK" -X PUT \
        -H "Content-Type: application/json" \
        "http://localhost/$ep" -d "$body" 2>&1) || true
    if echo "$out" | grep -q '"fault_message"'; then
        fail "Firecracker API error on $ep: $out"
    fi
}

# Single r/w drive — no initramfs, no overlay for validation.
# guestinit is PID 1: configures networking then execs /sbin/init (systemd).
fc_api "boot-source" "{
  \"kernel_image_path\": \"$KERNEL\",
  \"boot_args\": \"console=ttyS0 reboot=k panic=1 root=/dev/vda rw init=/usr/local/bin/guestinit fc.ip=$VM_IP fc.gw=$VM_GW fc.dns=$VM_DNS\"
}"

fc_api "drives/rootfs" "{
  \"drive_id\": \"rootfs\",
  \"path_on_host\": \"$ROOTFS\",
  \"is_root_device\": true,
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

curl -sf --unix-socket "$API_SOCK" -X PUT \
    -H "Content-Type: application/json" \
    "http://localhost/actions" \
    -d '{"action_type":"InstanceStart"}' > /dev/null

# ---- phase 1: vsock ping -----------------------------------------------
echo ""
echo "==> Phase 1: waiting for guest-agent vsock ping (90s timeout)..."
READY=false
for i in $(seq 1 180); do
    kill -0 "$FC_PID" 2>/dev/null || fail "Firecracker exited unexpectedly (see $FC_LOG)"

    # tr removes whitespace so json.MarshalIndent output matches compact pattern
    if "$VSOCK_CLIENT" -sock "$VSOCK_SOCK" ping 2>/dev/null \
            | tr -d ' \n' | grep -q '"ok":true'; then
        READY=true
        break
    fi
    [ $((i % 20)) -eq 0 ] && echo "    ... $((i/2))s elapsed — still waiting"
    sleep 0.5
done
$READY || fail "guest-agent did not respond to ping in 90s
Possible causes:
  1. vsock device not in kernel: check 'grep VIRTIO_VSOCK $FC_LOG'
  2. guest-agent failed to start: check journald via serial console
  3. vsock port not reachable: try 'printf CONNECT\\\\x20 52\\\\x0a | nc -U $VSOCK_SOCK'"
ok "guest-agent ping"

# ---- phase 2: docker ready ---------------------------------------------
echo ""
echo "==> Phase 2: waiting for Docker to be ready inside guest (90s timeout)..."
DOCKER_READY=false
for i in $(seq 1 180); do
    kill -0 "$FC_PID" 2>/dev/null || fail "Firecracker exited unexpectedly"
    PING=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" ping 2>/dev/null || true)
    if echo "$PING" | tr -d ' \n' | grep -q '"docker_ready":true'; then
        DOCKER_READY=true
        break
    fi
    [ $((i % 20)) -eq 0 ] && echo "    ... $((i/2))s elapsed — Docker not ready yet"
    sleep 0.5
done
$DOCKER_READY || fail "Docker did not become ready within 90s
If Docker is failing, check daemon.json storage driver in the rootfs."
ok "Docker ready inside guest"

# ---- functional checks -------------------------------------------------
echo ""
echo "==> Functional checks..."

OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- uname -r 2>&1)
[ -n "$OUT" ] || fail "exec uname -r returned empty output"
ok "exec: uname -r → $(echo "$OUT" | tr -d '\n')"

echo "    Pulling hello-world (first pull may be slow with vfs driver)..."
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" stream -- \
    docker run --rm hello-world 2>&1 | tee /tmp/validate-hello.log \
    | grep -q "Hello from Docker" \
    || fail "docker run hello-world failed — see /tmp/validate-hello.log"
ok "docker run hello-world"

OUT=$("$VSOCK_CLIENT" -sock "$VSOCK_SOCK" exec -- \
    curl -sf --max-time 15 https://icanhazip.com 2>&1)
echo "$OUT" | grep -qE "^[0-9]{1,3}\." || fail "egress failed: $OUT"
ok "egress: public IP = $(echo "$OUT" | tr -d '\n')"

echo "hello from host $(date)" > /tmp/validate-upload.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" upload /tmp/validate-upload.txt /tmp/validate-test.txt
"$VSOCK_CLIENT" -sock "$VSOCK_SOCK" download /tmp/validate-test.txt /tmp/validate-download.txt
diff /tmp/validate-upload.txt /tmp/validate-download.txt \
    || fail "file upload/download round-trip mismatch"
ok "file transfer: upload/download round-trip"

echo ""
echo "================================================"
echo " ALL M1 CHECKS PASSED"
echo "================================================"
