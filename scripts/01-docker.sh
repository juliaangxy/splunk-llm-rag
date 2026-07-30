#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

DOCKER_PORT="2375"

log "Updating package metadata"
retry 5 10 dnf makecache

log "Installing Docker and Docker Compose"
ensure_dnf_package docker
ensure_dnf_package jq
ensure_dnf_package unzip
ensure_dnf_package awscli

# Amazon Linux 2023 often ships curl-minimal; installing curl can conflict.
if ! command -v curl >/dev/null 2>&1; then
	if dnf list --available curl-minimal >/dev/null 2>&1; then
		ensure_dnf_package curl-minimal
	else
		ensure_dnf_package curl
	fi
fi

install_compose() {
	if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
		return 0
	fi

	if dnf list --available docker-compose-plugin >/dev/null 2>&1; then
		retry 5 10 dnf install -y docker-compose-plugin
	elif dnf list --available docker-compose >/dev/null 2>&1; then
		retry 5 10 dnf install -y docker-compose
	else
		local arch
		local compose_arch
		local compose_version

		arch="$(uname -m)"
		case "${arch}" in
			x86_64) compose_arch="x86_64" ;;
			aarch64|arm64) compose_arch="aarch64" ;;
			*)
				error "Unsupported architecture for manual docker compose install: ${arch}"
				exit 1
				;;
		esac

		compose_version="v2.29.7"
		mkdir -p /usr/local/lib/docker/cli-plugins
		retry 5 10 curl -fL "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${compose_arch}" \
			-o /usr/local/lib/docker/cli-plugins/docker-compose
		chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
	fi
}

install_compose

log "Configuring Docker daemon for DSDL remote API and NVIDIA runtime"
mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --host=fd:// --host=tcp://0.0.0.0:${DOCKER_PORT}
EOF

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
	"default-runtime": "nvidia",
	"runtimes": {
		"nvidia": {
			"path": "nvidia-container-runtime",
			"runtimeArgs": []
		}
	},
	"live-restore": true,
	"iptables": true
}
EOF

systemctl daemon-reload

log "Enabling and starting Docker service"
systemctl enable docker
systemctl restart docker

if ! id -nG ec2-user | tr ' ' '\n' | grep -qx docker; then
	usermod -aG docker ec2-user
fi

docker version >/dev/null
if docker compose version >/dev/null 2>&1; then
	docker compose version >/dev/null
elif command -v docker-compose >/dev/null 2>&1; then
	docker-compose --version >/dev/null
else
	error "Docker Compose is not installed correctly"
	exit 1
fi
log "Docker and Docker Compose are ready"
