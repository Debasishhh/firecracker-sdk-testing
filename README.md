# firecracker-sdk

Self-hosted [Firecracker](https://firecracker-microvm.github.io/) microVM sandbox daemon for headless agents. Each agent runs in an isolated VM with a full Ubuntu environment and Docker, communicating with the host via vsock.

## Status

### Done

**M0 — Host bootstrap**
- [x] `scripts/setup-host.sh` — installs Firecracker 1.10.1, jailer, Docker, downloads guest kernel
- [x] `versions.env` — all component versions pinned in one place
- [x] `Makefile` — full build/validate/clean target set

**M1 — Guest image**
- [x] `images/Dockerfile` — Ubuntu 22.04 base with Docker CE, dev tools, masked unnecessary services
- [x] `images/build-rootfs.sh` — exports Docker image to a 4 GB ext4 rootfs, installs binaries and systemd units
- [x] `images/build-kernel.sh` — downloads pre-built Firecracker kernel (5.10.225)
- [x] `images/initramfs/` — overlayfs initramfs for per-VM r/w layers (exists; separate validation pending)
- [x] `cmd/guestinit` — reads `fc.*` kernel cmdline params, configures networking, execs systemd as PID 1
- [x] `cmd/guest-agent` — vsock server on port 52: ping, exec, exec_stream, upload, download
- [x] `cmd/vsock-client` — host-side CLI for manual testing and scripted checks
- [x] `images/validate.sh` — end-to-end validation: boots a real VM, checks vsock ping, Docker readiness, exec, egress, file transfer
- [ ] **Validation passing** — guest-agent starts inside the VM; vsock host→guest connection is being debugged (see below)

### Next up

**Finish M1 validation**

The VM boots and guest-agent starts (confirmed in FC console log). The current blocker is the host-side vsock connection. Diagnostics added in the last revision will print the exact Firecracker response to `CONNECT 52` so the failure mode is clear on the next run.

**M2 — `controld` daemon**

The core runtime. Planned work in `cmd/controld/`:
- [ ] firecracker-go-sdk integration — drive Firecracker via its REST API programmatically
- [ ] CID / TAP / IP allocators — track which resources are in use per VM
- [ ] Host networking — bridge setup, per-VM TAP, iptables rules
- [ ] Boot / destroy lifecycle — `StartVM(cfg)` → wait for vsock ping → ready; `DestroyVM(id)` → cleanup
- [ ] Per-VM overlayfs layers — ro base rootfs + rw scratch layer, using the initramfs in `images/initramfs/`
- [ ] Readiness wait — poll vsock ping, surface docker_ready before handing VM to caller
- [ ] Rollback on failure — tear down TAP, unmap overlay, kill FC process if boot fails

**M3 — SDK surface**

- [ ] Go client package wrapping controld's gRPC/HTTP API
- [ ] Python bindings (`python/` directory, currently a placeholder)
- [ ] Sub-agent runner — launch N VMs in parallel, distribute work, collect results

---

## Architecture

```
Host
├── controld          ← control-plane daemon (M2, not yet implemented)
│   ├── manages VM lifecycle via firecracker-go-sdk
│   ├── allocates TAP devices, IP addresses, vsock CIDs
│   └── per-VM overlayfs layer (ephemeral r/w over shared base rootfs)
└── vsock-client      ← CLI test tool (connects to any running VM)

Guest (each Firecracker microVM)
├── guestinit         ← PID 1 replacement: configures network, execs systemd
└── guest-agent       ← vsock server on port 52
    ├── ping          → liveness + docker_ready status
    ├── exec          → run command, buffer output
    ├── exec_stream   → run command, stream stdout/stderr chunks
    ├── upload        → copy file host→guest
    └── download      → copy file guest→host
```

**Wire protocol:** every message is a 4-byte big-endian `uint32` length prefix followed by a JSON payload. For `upload` the raw file bytes follow the JSON header directly; for `download` the JSON header includes `size` and raw bytes follow.

## Pinned versions

| Component | Version |
|---|---|
| Firecracker | 1.10.1 |
| Guest kernel | 5.10.225 (Firecracker quickstart) |
| firecracker-go-sdk | 1.0.0 |
| Guest OS | Ubuntu 22.04 |

## Requirements

- **Ubuntu 22.04 x86_64** host with KVM (`/dev/kvm` must exist)  
  Use an AWS bare-metal instance (`*.metal`) or any instance type with nested virtualization.
- **Go 1.21+** for building host and guest binaries
- **Docker** on the host for building the guest rootfs (installed by `setup-host.sh`)

## Quick start (fresh EC2 instance)

```bash
# 1. Clone and enter repo
git clone <repo-url> firecracker-sdk && cd firecracker-sdk

# 2. Bootstrap host: installs Firecracker, jailer, Docker, downloads kernel
sudo make setup-host

# 3. Fetch Go dependencies
go mod tidy

# 4. Build + validate (compiles all binaries, builds rootfs, boots a test VM)
sudo make validate
```

`validate` boots a microVM, waits for the guest-agent to respond on vsock, confirms Docker comes up inside the guest, and runs exec/egress/file-transfer checks.

## Makefile targets

| Target | What it does |
|---|---|
| `make build-guest` | Cross-compile `guestinit` and `guest-agent` for Linux/amd64 (static, no CGO) |
| `make build-vsock-client` | Build the host-side `vsock-client` CLI |
| `make bake-image` | Build the guest rootfs ext4 image via Docker |
| `make build-kernel` | Download the pre-built Firecracker guest kernel to `/tmp/vmlinux` |
| `sudo make validate` | Build everything and run M1 validation (boots a real VM) |
| `make debug-rootfs` | Mount rootfs and inspect binaries + service files |
| `make distclean` | Remove all build artifacts, kernel, rootfs, tap/bridge, FC processes |

## Repository layout

```
cmd/
  controld/       control-plane daemon (M2)
  guestinit/      network init + systemd handoff (runs as PID 1 in guest)
  guest-agent/    vsock server (runs inside guest via systemd)
  vsock-client/   host CLI for manual testing

images/
  Dockerfile      Ubuntu 22.04 guest base with Docker CE
  build-rootfs.sh exports Docker image → ext4 rootfs, installs binaries + units
  build-kernel.sh downloads pre-built Firecracker kernel
  initramfs/      overlayfs initramfs for per-VM r/w layers (production path)
  validate.sh     M1 end-to-end validation script

scripts/
  setup-host.sh   one-shot EC2 bootstrap

systemd/
  guestinit.service   runs guestinit before network.target
  guest-agent.service starts guest-agent after network.target

versions.env      pinned component versions (sourced by all shell scripts)
```

## Guest networking

The validation script creates a bridge `fcbr0` (`10.99.0.1/24`) and a TAP device `fc-validate`. The VM gets `10.99.0.2/24` via kernel cmdline parameters (`fc.ip`, `fc.gw`, `fc.dns`) which `guestinit` reads from `/proc/cmdline` and applies with `ip(8)` before handing off to systemd.

Egress works via NAT on the host's default interface (`iptables MASQUERADE`).

## Docker inside the VM

Docker CE is installed in the rootfs. Because the Firecracker quickstart kernel is 5.10 (overlay2-on-overlayfs requires ≥5.11), the guest is configured with the `vfs` storage driver (`/etc/docker/daemon.json`). Switch to `overlay2` when using a 5.11+ kernel.

## vsock CID and port

| | Value |
|---|---|
| Guest CID | 3 (one VM; `controld` will allocate dynamically at M2) |
| Agent port | 52 |

The Firecracker vsock proxy UDS is at `/tmp/fc-validate-vsock.sock` during validation. Connect with the host-side Firecracker protocol: send `CONNECT 52\n`, expect `OK 52\n`, then use the wire protocol above.

```bash
# Manual ping (requires vsock-client built)
./bin/vsock-client -sock /tmp/fc-validate-vsock.sock ping

# Run a command inside the VM
./bin/vsock-client -sock /tmp/fc-validate-vsock.sock exec -- uname -r
```
