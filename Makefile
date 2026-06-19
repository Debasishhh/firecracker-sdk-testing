BINARY_DIR   := bin
ROOTFS       := /tmp/rootfs.ext4
KERNEL       := /tmp/vmlinux
INITRAMFS    := /tmp/initramfs.cpio.gz

.PHONY: all build-host build-guest bake-image build-initramfs build-kernel \
        build-vsock-client setup-host validate chmod-scripts clean

all: build-host build-guest

# ── Go binaries ──────────────────────────────────────────────────────────────

# Host-side binaries (native OS/arch)
build-host:
	mkdir -p $(BINARY_DIR)
	go build -o $(BINARY_DIR)/controld ./cmd/controld
	go build -o $(BINARY_DIR)/vsock-client ./cmd/vsock-client

build-vsock-client:
	mkdir -p $(BINARY_DIR)
	go build -o $(BINARY_DIR)/vsock-client ./cmd/vsock-client

# Guest binaries (Linux/amd64, fully static — no CGO)
build-guest:
	mkdir -p $(BINARY_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	  go build -ldflags="-s -w" -o $(BINARY_DIR)/guestinit ./cmd/guestinit
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	  go build -ldflags="-s -w" -o $(BINARY_DIR)/guest-agent ./cmd/guest-agent

# ── Guest image ──────────────────────────────────────────────────────────────

# Build the ext4 base rootfs (requires Docker + root for loop mount)
bake-image: build-guest
	./images/build-rootfs.sh

# Build the overlayfs initramfs cpio
build-initramfs:
	./images/initramfs/build.sh

# Download or build the guest kernel
build-kernel:
	./images/build-kernel.sh

# Full guest image: kernel + initramfs + rootfs
guest-image: bake-image build-initramfs build-kernel

# ── Host setup & validation ───────────────────────────────────────────────────

setup-host: chmod-scripts
	sudo ./scripts/setup-host.sh

validate: build-vsock-client bake-image build-initramfs build-kernel
	sudo ./images/validate.sh

# Ensure shell scripts are executable after git clone on Linux
chmod-scripts:
	chmod +x scripts/setup-host.sh \
	         images/build-rootfs.sh \
	         images/build-kernel.sh \
	         images/initramfs/build.sh \
	         images/validate.sh

# ── Housekeeping ─────────────────────────────────────────────────────────────

clean:
	rm -rf $(BINARY_DIR)
	rm -f /tmp/rootfs-vm*.ext4 /tmp/fc-*.sock* /tmp/fc-validate-*.ext4
