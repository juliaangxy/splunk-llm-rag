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

# Image used only to smoke-test the NVIDIA Docker runtime. In airgapped mode
# set this to a pre-seeded ECR URI (deploy.sh seeds it); otherwise the public
# image is used.
NVIDIA_TEST_IMAGE="${NVIDIA_TEST_IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"

log "Configuring NVIDIA runtime"
if ! command -v nvidia-ctk >/dev/null 2>&1; then
	if is_airgapped; then
		error "nvidia-ctk not found and AIRGAPPED=true forbids fetching the NVIDIA container-toolkit repo. Use an NVIDIA DLAMI that ships nvidia-container-toolkit for the airgapped environment."
		exit 1
	fi
	curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.repo" \
		-o /etc/yum.repos.d/nvidia-container-toolkit.repo
	retry 5 10 dnf install -y nvidia-container-toolkit
fi

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

nvidia-smi >/dev/null

# GPU-in-Docker smoke test. Skip only if airgapped and no test image is reachable.
if is_airgapped && ! ecr_registry_from_image "${NVIDIA_TEST_IMAGE}" >/dev/null 2>&1; then
	warn "AIRGAPPED=true and NVIDIA_TEST_IMAGE (${NVIDIA_TEST_IMAGE}) is not an ECR image; skipping the GPU-in-Docker smoke test (host nvidia-smi already verified)"
else
	ensure_image "${NVIDIA_TEST_IMAGE}"
	docker run --rm --gpus all "${NVIDIA_TEST_IMAGE}" nvidia-smi >/dev/null
fi
log "NVIDIA runtime is ready for Docker"
