#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

CREATE_SNAPSHOT_ON_SUCCESS="${CREATE_SNAPSHOT_ON_SUCCESS:-true}"

create_post_config_snapshot() {
	require_cmd aws
	require_cmd curl

	local token
	local md_headers=()
	token="$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)"
	if [[ -n "${token}" ]]; then
		md_headers=(-H "X-aws-ec2-metadata-token: ${token}")
	fi

	local instance_id
	local region
	instance_id="$(curl -s "${md_headers[@]}" http://169.254.169.254/latest/meta-data/instance-id)"
	region="$(curl -s "${md_headers[@]}" http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F '"' '/"region"/ {print $4; exit}')"

	if [[ -z "${instance_id}" || -z "${region}" ]]; then
		error "Could not resolve instance metadata for snapshot creation"
		return 1
	fi

	local root_device
	local volume_id
	root_device="$(aws ec2 describe-instances --region "${region}" --instance-ids "${instance_id}" --query 'Reservations[0].Instances[0].RootDeviceName' --output text)"
	volume_id="$(aws ec2 describe-instances --region "${region}" --instance-ids "${instance_id}" --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${root_device}'].Ebs.VolumeId | [0]" --output text)"

	if [[ -z "${volume_id}" || "${volume_id}" == "None" ]]; then
		error "Could not resolve root EBS volume ID for snapshot creation"
		return 1
	fi

	local snapshot_description
	local snapshot_id
	snapshot_description="splunk-ai post-config snapshot ${instance_id} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	snapshot_id="$(aws ec2 create-snapshot \
		--region "${region}" \
		--volume-id "${volume_id}" \
		--description "${snapshot_description}" \
		--tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=splunk-ai-post-config},{Key=InstanceId,Value=${instance_id}},{Key=CreatedBy,Value=splunk-ai-bootstrap}]" \
		--query 'SnapshotId' \
		--output text)"

	if [[ -z "${snapshot_id}" || "${snapshot_id}" == "None" ]]; then
		error "Snapshot creation returned no SnapshotId"
		return 1
	fi

	log "Created post-config snapshot ${snapshot_id} for volume ${volume_id}"
}

if [[ "${CREATE_SNAPSHOT_ON_SUCCESS}" == "true" ]]; then
	create_post_config_snapshot
else
	log "Skipping snapshot because CREATE_SNAPSHOT_ON_SUCCESS=${CREATE_SNAPSHOT_ON_SUCCESS}"
fi
