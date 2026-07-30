#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

if ! command -v nvidia-smi >/dev/null 2>&1; then
	error "nvidia-smi not found. Use an NVIDIA-enabled AMI with drivers preinstalled."
	exit 1
fi

distribution="amzn2023"

log "Configuring NVIDIA runtime"
if ! command -v nvidia-ctk >/dev/null 2>&1; then
	curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.repo" \
		-o /etc/yum.repos.d/nvidia-container-toolkit.repo
	retry 5 10 dnf install -y nvidia-container-toolkit
fi

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

nvidia-smi >/dev/null
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null
log "NVIDIA runtime is ready for Docker"
