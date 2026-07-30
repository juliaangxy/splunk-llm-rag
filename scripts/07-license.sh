#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
LICENSE_BUCKET="${LICENSE_BUCKET:-}"
LICENSE_KEY="${LICENSE_KEY:-}"
LICENSES_S3_PREFIX="${LICENSES_S3_PREFIX:-licenses/}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
LICENSE_DIR="${SPLUNK_HOME}/etc/licenses/enterprise"

require_env LICENSE_BUCKET
require_env SPLUNK_ADMIN_PASSWORD
require_cmd aws

log "Applying Splunk Enterprise license(s) from S3"
mkdir -p "${LICENSE_DIR}"
chown splunk:splunk "${LICENSE_DIR}"
chmod 750 "${LICENSE_DIR}"

normalize_key_list() {
	local raw="$1"
	local item
	local -a parsed=()
	IFS=',' read -r -a parsed <<< "${raw}"
	for item in "${parsed[@]}"; do
		# Trim leading/trailing whitespace around each key.
		item="$(echo "${item}" | xargs)"
		if [[ -n "${item}" ]]; then
			echo "${item}"
		fi
	done
}

discover_license_keys_from_s3_prefix() {
	local normalized_prefix="${LICENSES_S3_PREFIX}"
	if [[ -n "${normalized_prefix}" && "${normalized_prefix}" != */ ]]; then
		normalized_prefix="${normalized_prefix}/"
	fi

	if [[ -z "${normalized_prefix}" ]]; then
		warn "LICENSES_S3_PREFIX is empty; discovering .lic/.License files from entire bucket"
	fi

	local list_output
	if ! list_output="$(aws s3api list-objects-v2 --bucket "${LICENSE_BUCKET}" --prefix "${normalized_prefix}" --query 'Contents[].Key' --output text 2>&1)"; then
		if echo "${list_output}" | grep -qi "AccessDenied"; then
			error "S3 list denied for s3://${LICENSE_BUCKET}/${normalized_prefix} (missing s3:ListBucket permission on bucket arn:aws:s3:::${LICENSE_BUCKET})"
		else
			error "Failed listing license files under s3://${LICENSE_BUCKET}/${normalized_prefix}: ${list_output}"
		fi
		return 1
	fi

	echo "${list_output}" \
		| tr '\t' '\n' \
		| sed '/^None$/d' \
		| grep -Ei '\.(lic|license)$' || true
}

download_license_keys=()
if [[ -n "${LICENSE_KEY}" ]]; then
	log "Using explicit LICENSE_KEY entries"
	while IFS= read -r key; do
		download_license_keys+=("${key}")
	done < <(normalize_key_list "${LICENSE_KEY}")
else
	log "LICENSE_KEY is empty; discovering all license files from s3://${LICENSE_BUCKET}/${LICENSES_S3_PREFIX}"
	while IFS= read -r key; do
		download_license_keys+=("${key}")
	done < <(discover_license_keys_from_s3_prefix)
fi

if [[ "${#download_license_keys[@]}" -eq 0 ]]; then
	if [[ -n "${LICENSE_KEY}" ]]; then
		error "LICENSE_KEY did not contain any valid S3 object key(s)"
	else
		error "No .lic/.License files found under s3://${LICENSE_BUCKET}/${LICENSES_S3_PREFIX}"
	fi
	exit 1
fi

local_license_paths=()
license_index=0
for key in "${download_license_keys[@]}"; do
	license_index=$((license_index + 1))
	license_filename="$(basename "${key}")"
	local_license_path="${LICENSE_DIR}/${license_index}-${license_filename}"

	retry 5 10 aws s3 cp "s3://${LICENSE_BUCKET}/${key}" "${local_license_path}"
	chown splunk:splunk "${local_license_path}"
	chmod 640 "${local_license_path}"

	if [[ ! -s "${local_license_path}" ]]; then
		error "Downloaded license file is empty: ${local_license_path}"
		exit 1
	fi

	local_license_paths+=("${local_license_path}")
done

if [[ ! -x "${SPLUNK_HOME}/bin/splunk" ]]; then
	error "Splunk binary not found at ${SPLUNK_HOME}/bin/splunk"
	exit 1
fi

ensure_splunk_reloadable_change_health_non_interactive \
	"Splunk is running before license import; using reload-safe validation before importing licenses" \
	"Splunk is not running after license file update; attempting direct start" \
	"Splunk did not recover through reload-safe validation before license import"

log "Ensuring Splunk boot-start service is configured"
"${SPLUNK_HOME}/bin/splunk" enable boot-start -user splunk --accept-license --answer-yes --no-prompt

if command -v systemctl >/dev/null 2>&1; then
	systemctl daemon-reload
	systemctl list-unit-files | grep -i splunk || true

	if ! systemctl start Splunkd.service && ! systemctl start splunk.service; then
		warn "Could not start Splunkd.service or splunk.service; falling back to direct Splunk start"
		splunk_start_non_interactive
	fi

	systemctl status Splunkd.service --no-pager || systemctl status splunk.service --no-pager || true
fi

wait_for_port 127.0.0.1 8089 300
wait_for_port 127.0.0.1 8000 300

log "Importing license with Splunk CLI"
for local_license_path in "${local_license_paths[@]}"; do
	if ! splunk_run add licenses "${local_license_path}" >/dev/null 2>&1; then
		warn "splunk add licenses returned non-zero for ${local_license_path}; checking whether a valid enterprise license is already present"
	fi
done

if ! splunk_run list licenser-groups 2>/dev/null | grep -qi "Enterprise"; then
	error "Splunk does not report an Enterprise licenser group after license import"
	error "Verify the license file is a valid, unexpired Splunk Enterprise license: ${local_license_path}"
	exit 1
fi

splunk_run status >/dev/null
log "Splunk license import completed from ${#local_license_paths[@]} file(s) in s3://${LICENSE_BUCKET}"
