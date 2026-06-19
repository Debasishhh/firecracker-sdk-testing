BINARY_DIR := bin
POC_BIN    := $(BINARY_DIR)/poc
GUEST_BIN  := $(BINARY_DIR)/guest-agent
ROOTFS     := /tmp/rootfs.ext4
MOUNT_DIR  := /mnt/rootfs-bake

.PHONY: build-all build-poc build-guest bake-rootfs run clean

build-all: build-poc build-guest

build-poc:
	mkdir -p $(BINARY_DIR)
	go build -o $(POC_BIN) ./cmd/poc

build-guest:
	mkdir -p $(BINARY_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o $(GUEST_BIN) ./cmd/guest-agent

bake-rootfs: build-guest
	sudo mkdir -p $(MOUNT_DIR)
	sudo mount -o loop $(ROOTFS) $(MOUNT_DIR)
	sudo cp $(GUEST_BIN) $(MOUNT_DIR)/usr/local/bin/guest-agent
	sudo chmod +x $(MOUNT_DIR)/usr/local/bin/guest-agent
	sudo umount $(MOUNT_DIR)
	sudo rmdir $(MOUNT_DIR)

run:
	sudo $(POC_BIN)

clean:
	rm -rf $(BINARY_DIR)
	rm -f /tmp/rootfs-vm*.ext4 /tmp/fc-*.sock*
