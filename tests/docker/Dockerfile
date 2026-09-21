# Test image: Ubuntu + systemd as PID 1 + the tools the integration suite needs.
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus openssh-server openssh-client sudo iproute2 iptables ufw nftables \
      curl ca-certificates python3 procps sshpass tar gzip git kmod libpam0g openssl passwd util-linux \
    && rm -rf /var/lib/apt/lists/*
# Test-environment adaptation: the Docker Desktop/WSL2 kernel lacks the legacy ip6tables
# modules that Ubuntu 20.04's default "legacy" iptables needs; use the nf_tables variant.
RUN (update-alternatives --set iptables /usr/sbin/iptables-nft; update-alternatives --set ip6tables /usr/sbin/ip6tables-nft) >/dev/null 2>&1 || true
RUN systemctl mask nftables.service ufw.service getty.target console-getty.service 2>/dev/null || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
