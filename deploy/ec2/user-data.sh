#!/bin/bash
# EC2 user data — Amazon Linux 2023 (x86_64 or arm64/Graviton). Scenarios 20, 21, 42, 43.
# Installs Docker Engine + Compose v2 + Buildx plugins, git, jq, adds 2G swap
# (composer/npm builds on t3.micro/t4g.small otherwise OOM) and prepares /opt/student-app.
# Logs: /var/log/cloud-init-output.log
set -euxo pipefail

COMPOSE_VERSION="${COMPOSE_VERSION:-v2.39.4}"

dnf -y install docker git jq
systemctl enable --now docker
usermod -aG docker ec2-user

case "$(uname -m)" in
    x86_64)  COMPOSE_ARCH=x86_64;  BUILDX_ARCH=amd64 ;;
    aarch64) COMPOSE_ARCH=aarch64; BUILDX_ARCH=arm64 ;;
    *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

PLUGINS=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGINS"
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
    -o "$PLUGINS/docker-compose"
BUILDX_VERSION="${BUILDX_VERSION:-$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r .tag_name)}"
curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
    -o "$PLUGINS/docker-buildx"
chmod +x "$PLUGINS"/*

if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /opt/student-app
chown ec2-user:ec2-user /opt/student-app

docker version
docker compose version
docker buildx version
echo "user-data finished: $(date -Iseconds)" > /opt/student-app/.bootstrapped
