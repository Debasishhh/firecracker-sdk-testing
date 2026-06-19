// guest-agent runs as the Linux init process inside each Firecracker microVM.
// It reads its vsock CID from the kernel command line, dials the host on
// vsock CID 2 port 52, sends a hello message, and exits.
// When init exits the kernel panics; combined with "reboot=k panic=1" in the
// kernel args, this causes Firecracker to halt the VM cleanly.
//
// Build with: GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/guest-agent
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/mdlayher/vsock"
)

func readCID() (uint32, error) {
	data, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return 0, fmt.Errorf("read /proc/cmdline: %w", err)
	}
	for _, field := range strings.Fields(string(data)) {
		var cid uint32
		if _, err := fmt.Sscanf(field, "cid=%d", &cid); err == nil {
			return cid, nil
		}
	}
	return 0, fmt.Errorf("cid= not found in /proc/cmdline: %q", string(data))
}

func main() {
	// Small delay to let the virtio-vsock driver finish initialising before we dial.
	time.Sleep(100 * time.Millisecond)

	cid, err := readCID()
	if err != nil {
		fmt.Fprintln(os.Stderr, "guest-agent:", err)
		os.Exit(1)
	}

	// CID 2 is always the host in Firecracker's vsock model.
	// (Standard Linux uses CID 1 for the hypervisor; Firecracker uses 2 for the
	// host-side vsock proxy process.)
	conn, err := vsock.Dial(2, vsockPort, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "guest-agent: vsock.Dial: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	if _, err := fmt.Fprintf(conn, "hello from CID %d\n", cid); err != nil {
		fmt.Fprintf(os.Stderr, "guest-agent: write: %v\n", err)
		os.Exit(1)
	}

	// Exit triggers kernel panic → reboot=k/panic=1 → VM halts.
}

const vsockPort = 52
