# Guest rootfs image (M1.1 + M1.2)
# Builds an Ubuntu 22.04 base with:
#   - dev toolchain: gcc, python3, nodejs, make, cmake, git
#   - Docker CE + containerd
#   - networking: iproute2, iptables
# This image is exported to an ext4 filesystem — it never runs as a Docker container.

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Base tools + dev environment
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core system
    systemd systemd-sysv udev dbus \
    # Dev toolchain
    git curl wget \
    gcc g++ make cmake ninja-build \
    python3 python3-pip python3-venv \
    nodejs npm \
    # Package managers
    apt-transport-https ca-certificates software-properties-common \
    # Networking (egress + Docker bridge)
    iproute2 iptables iputils-ping dnsutils \
    # Utilities
    vim nano less procps htop lsof file \
    # Docker requirements
    gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Docker CE (installed but not started — daemon starts inside the VM)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# Mask services that do not make sense inside a Firecracker VM
RUN systemctl mask \
      systemd-udev-trigger.service \
      systemd-udevd.service \
      multipathd.service \
      apt-daily.service apt-daily-upgrade.service \
      apt-daily.timer apt-daily-upgrade.timer \
      unattended-upgrades.service \
 || true

# Enable Docker at boot
RUN systemctl enable docker.service containerd.service || true

# Placeholder directories for our binaries (populated by build-rootfs.sh)
RUN mkdir -p /usr/local/bin

# Default root shell for debugging
CMD ["/bin/bash"]
