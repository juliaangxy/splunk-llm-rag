#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./utils/push-docker-images-to-ecr.sh [aws-region] [source-image=target-repo ...]

Pulls one or more Docker images and pushes them into ECR.
If source mappings are not provided as arguments, this script reads the source images from:
	- CONTAINER_IMAGE_PROFILES_JSON (JSON array of objects with source_image or image)
	- DOCKER_SOURCE_IMAGES (comma-separated list)
If neither env var is set, it falls back to the three default Splunk images.
When explicit source-image=target-repo mappings are provided as arguments, each target-repo is used as-is.
In env/default mapping mode (no explicit mappings), target images are pushed into a single ECR repository named ECR_REPOSITORY_NAME when set.
Each source image is tagged with a unique tag derived from the source image name and version.

Examples:
	export CONTAINER_IMAGE_PROFILES_JSON='[{"role":"gpu_container","name":"gpu_container_dev","source_image":"splunk/mltk-container-golden-gpu:5.2.3"},{"role":"llm_rag","name":"llm_rag_dev","source_image":"splunk/mltk-container-ubi-llm-rag:5.2.3"},{"role":"cpu_container","name":"cpu_container_dev","source_image":"splunk/mltk-container-golden-cpu:5.2.3"}]'
	export DOCKER_SOURCE_IMAGES='splunk/mltk-container-golden-gpu:5.2.3,splunk/mltk-container-ubi-llm-rag:5.2.3,splunk/mltk-container-golden-cpu:5.2.3'
	export ECR_REGISTRY_URI='123456789012.dkr.ecr.ap-southeast-1.amazonaws.com'
	export ECR_REPOSITORY_NAME='ai-splunk-ecr'
	./utils/push-docker-images-to-ecr.sh

	./utils/push-docker-images-to-ecr.sh ap-southeast-1

Optional environment variables:
  AWS_PROFILE          AWS profile to use for AWS CLI calls.
	CONTAINER_IMAGE_PROFILES_JSON
											 JSON array of container profile objects. Each object may include source_image, image, and target_repo.
	DOCKER_SOURCE_IMAGES
											 Comma-separated list of Docker source images to pull.
	ECR_LOGIN_PASSWORD    Optional pre-fetched output of `aws ecr get-login-password`.
	USE_PROVIDED_ECR_LOGIN_PASSWORD  Set to true to force use of ECR_LOGIN_PASSWORD instead of fetching a fresh token.
	ECR_REGISTRY_URI     Target ECR registry URI. Example: 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com
	ECR_REPOSITORY_NAME  Target ECR repository name. Example: ai-splunk-ecr
EOF
}

if [[ $# -lt 0 ]]; then
	usage
	exit 1
fi

REGION="${1:-${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}}"
if [[ -n "${1:-}" ]]; then
	shift || true
fi

HAS_EXPLICIT_MAPPINGS=0
if [[ $# -gt 0 ]]; then
	HAS_EXPLICIT_MAPPINGS=1
fi

if ! command -v aws >/dev/null 2>&1; then
	echo "ERROR: aws CLI is required" >&2
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: docker is required" >&2
	exit 1
fi

declare -a AWS_PROFILE_ARG=()
if [[ -n "${AWS_PROFILE:-}" ]]; then
	AWS_PROFILE_ARG=(--profile "${AWS_PROFILE}")
fi

aws_cli() {
	if [[ "${#AWS_PROFILE_ARG[@]}" -gt 0 ]]; then
		aws "${AWS_PROFILE_ARG[@]}" "$@"
	else
		aws "$@"
	fi
}

if [[ -z "${REGION}" && -z "${ECR_REGISTRY_URI:-}" ]]; then
	echo "ERROR: provide an AWS region argument or set REGION/AWS_REGION/AWS_DEFAULT_REGION" >&2
	exit 1
fi

if [[ -n "${ECR_REGISTRY_URI:-}" ]]; then
	REGISTRY="${ECR_REGISTRY_URI%/}"
	REGISTRY_HOST="${REGISTRY%%/*}"
	REGISTRY="${REGISTRY_HOST}"
	if [[ -z "${REGION}" ]]; then
		if [[ "${REGISTRY}" =~ dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
			REGION="${BASH_REMATCH[1]}"
		else
			echo "ERROR: Could not infer AWS region from ECR_REGISTRY_URI: ${REGISTRY}" >&2
			exit 1
		fi
	fi
else
	ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
	REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

echo "Logging into ${REGISTRY}"
if [[ "${USE_PROVIDED_ECR_LOGIN_PASSWORD:-false}" == "true" ]]; then
	if [[ -z "${ECR_LOGIN_PASSWORD:-}" ]]; then
		echo "ERROR: USE_PROVIDED_ECR_LOGIN_PASSWORD=true but ECR_LOGIN_PASSWORD is empty." >&2
		exit 1
	fi
	echo "Using ECR login password supplied via environment."
else
	if [[ -n "${ECR_LOGIN_PASSWORD:-}" ]]; then
		echo "Ignoring ECR_LOGIN_PASSWORD from environment and fetching a fresh token."
	else
		echo "Fetching ECR login password from AWS CLI..."
	fi
	if ! ECR_LOGIN_PASSWORD="$(aws_cli ecr get-login-password --region "${REGION}")"; then
		echo "ERROR: Failed to get ECR login password from AWS CLI." >&2
		exit 1
	fi
fi

printf '%s' "${ECR_LOGIN_PASSWORD}" | docker login --username AWS --password-stdin "${REGISTRY}"

make_default_mappings() {
	cat <<'EOF'
splunk/mltk-container-golden-gpu:5.2.3=mltk-container-golden-gpu-5.2.3
splunk/mltk-container-ubi-llm-rag:5.2.3=mltk-container-ubi-llm-rag-5.2.3
splunk/mltk-container-golden-cpu:5.2.3=mltk-container-golden-cpu-5.2.3
EOF
}

parse_mapping() {
	local mapping="$1"
	local source_image target_repo

	if [[ "${mapping}" != *"="* ]]; then
		echo "ERROR: Image mapping must use source-image=target-repo syntax: ${mapping}" >&2
		exit 1
	fi

	source_image="${mapping%%=*}"
	target_repo="${mapping#*=}"

	if [[ -z "${source_image}" || -z "${target_repo}" ]]; then
		echo "ERROR: Invalid image mapping: ${mapping}" >&2
		exit 1
	fi

	echo "${source_image}|${target_repo}"
}

make_env_mappings() {
	local profiles_json="${CONTAINER_IMAGE_PROFILES_JSON:-}"
	local source_images="${DOCKER_SOURCE_IMAGES:-}"
	local source_image
	local repo_name

	if [[ -n "${profiles_json}" ]]; then
		if ! command -v python3 >/dev/null 2>&1; then
			echo "ERROR: python3 is required to parse CONTAINER_IMAGE_PROFILES_JSON" >&2
			exit 1
		fi

		CONTAINER_IMAGE_PROFILES_JSON="${profiles_json}" python3 - <<'PY'
import json
import os
import sys

profiles = json.loads(os.environ['CONTAINER_IMAGE_PROFILES_JSON'])
if not isinstance(profiles, list):
    raise SystemExit('CONTAINER_IMAGE_PROFILES_JSON must be a JSON array')

seen = set()
for profile in profiles:
    if not isinstance(profile, dict):
        continue
    source_image = str(profile.get('source_image') or profile.get('image') or '').strip()
    if not source_image or source_image in seen:
        continue
    seen.add(source_image)
    target_repo = str(profile.get('target_repo') or '').strip()
    if not target_repo:
        image_no_tag = source_image.split('@', 1)[0]
        image_no_tag = image_no_tag.rsplit(':', 1)[0]
        target_repo = image_no_tag.rsplit('/', 1)[-1]
    print(f'{source_image}={target_repo}')
PY
		return 0
	fi

	if [[ -z "${source_images}" ]]; then
		cat <<'EOF'
splunk/mltk-container-golden-gpu:5.2.3=mltk-container-golden-gpu-5.2.3
splunk/mltk-container-ubi-llm-rag:5.2.3=mltk-container-ubi-llm-rag-5.2.3
splunk/mltk-container-golden-cpu:5.2.3=mltk-container-golden-cpu-5.2.3
EOF
		return 0
	fi

	while IFS=',' read -ra source_image_list; do
		for source_image in "${source_image_list[@]}"; do
			source_image="$(echo "${source_image}" | xargs)"
			if [[ -n "${source_image}" ]]; then
				repo_name="$(repo_name_from_source "${source_image}")"
				echo "${source_image}=${repo_name}"
			fi
		done
	done <<< "${source_images}"
}

normalize_repository_name() {
	local repo_name="${1}"
	local use_repo_override="${2:-1}"
	if [[ "${use_repo_override}" == "1" && -n "${ECR_REPOSITORY_NAME:-}" ]]; then
		echo "${ECR_REPOSITORY_NAME}"
	else
		echo "${repo_name}"
	fi
}

repo_name_from_source() {
	local source_image="$1"
	local image_no_tag="${source_image%@*}"
	image_no_tag="${image_no_tag%:*}"
	basename "${image_no_tag}"
}

source_image_tag() {
	local source_image="$1"
	if [[ "${source_image}" == *"@"* ]]; then
		echo "latest"
		return 0
	fi

	if [[ "${source_image}" == *":"* ]]; then
		echo "${source_image##*:}"
	else
		echo "latest"
	fi
}

target_image_tag() {
	local source_image="$1"
	local repo_name
	local source_tag

	repo_name="$(repo_name_from_source "${source_image}")"
	source_tag="$(source_image_tag "${source_image}")"
	echo "${repo_name}-${source_tag}"
}

push_image() {
	local source_image="$1"
	local target_repo="$2"
	local use_repo_override="${3:-1}"
	local target_repo_name target_tag target_image

	target_repo_name="$(normalize_repository_name "${target_repo}" "${use_repo_override}")"
	target_tag="$(target_image_tag "${source_image}")"
	target_image="${REGISTRY}/${target_repo_name}:${target_tag}"

	# Force the instances' architecture (amd64) so images pulled on an arm64 dev machine
	# (Apple Silicon) are the right arch — otherwise ECR gets arm64 images the EC2 hosts
	# can't run, and single-arch amd64 images (e.g. golden-cpu) fail to pull at all.
	echo "Pulling ${source_image} (platform ${DOCKER_PLATFORM:-linux/amd64})"
	docker pull --platform "${DOCKER_PLATFORM:-linux/amd64}" "${source_image}"

	echo "Tagging ${source_image} as ${target_image}"
	docker tag "${source_image}" "${target_image}"

	echo "Pushing ${target_image}"
	docker push "${target_image}"

	echo "Pushed ${source_image} -> ${target_image}"
}

declare -a mappings=()
if [[ $# -eq 0 ]]; then
	while IFS= read -r line; do
		[[ -n "${line}" ]] && mappings+=("${line}")
	done < <(make_env_mappings)
else
	mappings=("$@")
fi

for mapping in "${mappings[@]}"; do
	parsed="$(parse_mapping "${mapping}")"
	source_image="${parsed%%|*}"
	target_repo="${parsed#*|}"
	if [[ "${HAS_EXPLICIT_MAPPINGS}" -eq 1 ]]; then
		push_image "${source_image}" "${target_repo}" 0
	else
		push_image "${source_image}" "${target_repo}" 1
	fi
done

echo "Done. Images are available in ECR registry ${REGISTRY}."