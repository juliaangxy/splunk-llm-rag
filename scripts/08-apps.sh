#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
APPS_DIR="/opt/splunk-ai/apps"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
LICENSE_BUCKET="${LICENSE_BUCKET:-}"
SPLUNK_APP_S3_KEYS="${SPLUNK_APP_S3_KEYS:-}"
SPLUNK_APPS_S3_PREFIX="${SPLUNK_APPS_S3_PREFIX:-splunk-apps/}"
SKIP_SPLUNK_APPS_BOOTSTRAP="${SKIP_SPLUNK_APPS_BOOTSTRAP:-false}"
APPS_INSTALLED_COUNT=0

require_env SPLUNK_ADMIN_PASSWORD
require_env LICENSE_BUCKET
require_cmd aws

if [[ "${SKIP_SPLUNK_APPS_BOOTSTRAP}" == "true" ]]; then
	log "Skipping Splunk app installation stage because SKIP_SPLUNK_APPS_BOOTSTRAP=true"
	exit 0
fi

mkdir -p "${APPS_DIR}"

ensure_splunk_ready_for_app_install() {
	ensure_splunk_reloadable_change_health_non_interactive \
		"Splunk is running before app installation; using reload-safe validation for app changes" \
		"Splunk is not running before app installation; attempting direct start" \
		"Splunk did not recover through reload-safe validation before app installation"
	wait_for_port 127.0.0.1 8089 300
	wait_for_port 127.0.0.1 8000 300
}

collect_s3_app_keys() {
	local normalized_prefix="${SPLUNK_APPS_S3_PREFIX}"
	if [[ -n "${normalized_prefix}" && "${normalized_prefix}" != */ ]]; then
		normalized_prefix="${normalized_prefix}/"
	fi

	if [[ -n "${SPLUNK_APP_S3_KEYS}" ]]; then
		while IFS= read -r key; do
			key="${key##+([[:space:]])}"
			key="${key%%+([[:space:]])}"
			if [[ -n "${key}" ]]; then
				echo "${key}"
			fi
		done < <(echo "${SPLUNK_APP_S3_KEYS}" | tr ',;' '\n')
		return 0
	fi

	if [[ -z "${normalized_prefix}" ]]; then
		warn "SPLUNK_APPS_S3_PREFIX is empty and SPLUNK_APP_S3_KEYS is unset; skipping app installation"
		return 0
	fi

	# List candidate package objects under the configured prefix.
	# Use s3api object keys directly to avoid brittle parsing of `aws s3 ls` column output.
	local list_output
	if ! list_output="$(aws s3api list-objects-v2 --bucket "${LICENSE_BUCKET}" --prefix "${normalized_prefix}" --query 'Contents[].Key' --output text 2>&1)"; then
		if echo "${list_output}" | grep -qi "AccessDenied"; then
			error "S3 list denied for s3://${LICENSE_BUCKET}/${normalized_prefix} (missing s3:ListBucket permission on bucket arn:aws:s3:::${LICENSE_BUCKET})"
			error "Workaround: set SPLUNK_APP_S3_KEYS explicitly to bypass prefix discovery"
		else
			error "Failed listing app packages under s3://${LICENSE_BUCKET}/${normalized_prefix}: ${list_output}"
		fi
		return 1
	fi

	echo "${list_output}" \
		| tr '\t' '\n' \
		| sed '/^None$/d' \
		| grep -Ei '\.(tgz|tar|tar\.gz|spl)$' || true
}

download_app_from_s3_key() {
	local s3_key="${1}"
	local app_index="${2}"
	local key_basename
	key_basename="$(basename "${s3_key}")"

	if [[ -z "${key_basename}" || "${key_basename}" == "/" || "${key_basename}" == "." ]]; then
		key_basename="app-${app_index}.tgz"
	fi

	local destination="${APPS_DIR}/${app_index}-${key_basename}"
	if ! retry 5 10 aws s3 cp --only-show-errors "s3://${LICENSE_BUCKET}/${s3_key}" "${destination}"; then
		error "Failed to download app package from s3://${LICENSE_BUCKET}/${s3_key}"
		return 1
	fi

	if ! tar -tzf "${destination}" >/dev/null 2>&1 && ! tar -tf "${destination}" >/dev/null 2>&1; then
		error "Downloaded file from s3://${LICENSE_BUCKET}/${s3_key} is not a valid tarball"
		return 1
	fi

	echo "${destination}"
}

install_app_from_file() {
	local app_file="${1}"
	local install_target="${app_file}"
	local install_log
	install_log="$(mktemp)"
	local converted_from_spl=0
	local temp_install_target=""

	if [[ "${app_file}" == *.spl ]]; then
		# Splunk CLI may treat .spl input as a non-file install target; install from a .tgz path instead.
		temp_install_target="${app_file%.spl}.tgz"
		cp -f "${app_file}" "${temp_install_target}"
		install_target="${temp_install_target}"
		converted_from_spl=1
	fi

	if splunk_run install app "${install_target}" -update 1 >"${install_log}" 2>&1; then
		log "Installed app package $(basename "${app_file}")"
		if [[ "${converted_from_spl}" -eq 1 ]]; then
			rm -f "${temp_install_target}"
		fi
		rm -f "${install_log}"
		return 0
	else
		if grep -qi "splunkd is unreachable" "${install_log}"; then
			warn "Splunkd became unreachable during app install; attempting one recovery start and retry"
			if splunk_start_non_interactive && splunk_run install app "${install_target}" -update 1 >"${install_log}" 2>&1; then
				log "Installed app package $(basename "${app_file}") after recovery retry"
				if [[ "${converted_from_spl}" -eq 1 ]]; then
					rm -f "${temp_install_target}"
				fi
				rm -f "${install_log}"
				return 0
			fi
		fi

		warn "Failed to install app package $(basename "${app_file}"); continuing bootstrap"
		if grep -q "python3.7/site-packages" "${install_log}"; then
			warn "Package $(basename "${app_file}") appears incompatible with this Splunk Python runtime (python3.7 path expected)."
		fi
		warn "Install output for $(basename "${app_file}"):"
		sed 's/^/[app-install] /' "${install_log}" >&2
		if [[ "${converted_from_spl}" -eq 1 ]]; then
			rm -f "${temp_install_target}"
		fi
		rm -f "${install_log}"
		return 1
	fi
}

install_apps_from_s3() {
	local app_index=0
	local installed_count=0
	local s3_key
	local app_keys=()

	if ! mapfile -t app_keys < <(collect_s3_app_keys); then
		return 1
	fi

	for s3_key in "${app_keys[@]}"; do
		s3_key="${s3_key##+([[:space:]])}"
		s3_key="${s3_key%%+([[:space:]])}"
		if [[ -z "${s3_key}" ]]; then
			continue
		fi

		app_index=$((app_index + 1))
		log "Downloading app ${app_index} from s3://${LICENSE_BUCKET}/${s3_key}"

		local app_file
		if app_file="$(download_app_from_s3_key "${s3_key}" "${app_index}")"; then
			if install_app_from_file "${app_file}"; then
				installed_count=$((installed_count + 1))
			fi
		else
			warn "Skipping app key due to download/validation failure: ${s3_key}"
		fi
	done

	if [[ "${app_index}" -eq 0 ]]; then
		warn "No app tarballs were found in s3://${LICENSE_BUCKET}/${SPLUNK_APPS_S3_PREFIX}; skipping install"
		APPS_INSTALLED_COUNT=0
		return 0
	fi

	APPS_INSTALLED_COUNT="${installed_count}"
	log "Processed ${app_index} app package object(s); successfully installed ${installed_count} package(s)"
}

log "Installing Splunk apps from S3 bucket ${LICENSE_BUCKET}"
ensure_splunk_ready_for_app_install
install_apps_from_s3

if [[ "${APPS_INSTALLED_COUNT}" -gt 0 ]]; then
	log "Installed ${APPS_INSTALLED_COUNT} app package(s); deferring Splunk restart and app configuration to stage 09-configure.sh"
else
	log "Skipping Splunk restart because no app packages were installed"
fi

ensure_splunk_reloadable_change_health_non_interactive \
	"Splunk is running after app installation; applying reload-safe validation for installed apps" \
	"Splunk is not running after app installation; attempting direct start" \
	"Splunk did not recover through reload-safe validation after app installation"

wait_for_port 127.0.0.1 8089 300
wait_for_port 127.0.0.1 8000 300
log "Splunk app installation stage completed"
