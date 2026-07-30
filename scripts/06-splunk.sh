#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_PACKAGE_URL="${SPLUNK_PACKAGE_URL:-}"
SPLUNK_PACKAGE_S3_KEY="${SPLUNK_PACKAGE_S3_KEY:-}"
SPLUNK_PACKAGE_S3_PREFIX="${SPLUNK_PACKAGE_S3_PREFIX:-splunk-rpms/}"
SPLUNK_PACKAGE_PATH="${SPLUNK_PACKAGE_PATH:-}"
LICENSE_BUCKET="${LICENSE_BUCKET:-}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"

require_env SPLUNK_ADMIN_PASSWORD

run_with_timeout() {
	local seconds="${1}"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "${seconds}" "$@"
	else
		"$@"
	fi
}

ensure_splunk_ownership() {
	if id splunk >/dev/null 2>&1; then
		log "Normalizing Splunk ownership on writable paths"
		for path in \
			"${SPLUNK_HOME}/var" \
			"${SPLUNK_HOME}/etc" \
			"${SPLUNK_HOME}/opt" \
			"${SPLUNK_HOME}/ftr"; do
			if [[ -d "${path}" ]]; then
				chown -R splunk:splunk "${path}"
			fi
		done
		log "Ownership normalization complete"
	fi
}

stop_existing_splunk() {
	log "Checking for existing splunkd process"
	if pgrep -f splunkd >/dev/null 2>&1; then
		warn "Detected existing splunkd process; attempting clean stop"
		run_with_timeout 120 su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk stop" >/dev/null 2>&1 || true
		run_with_timeout 120 "${SPLUNK_HOME}/bin/splunk" stop --accept-license --answer-yes --no-prompt --run-as-root >/dev/null 2>&1 || true
		pkill -f splunkd >/dev/null 2>&1 || true
		pkill -f "${SPLUNK_HOME}.*mongod" >/dev/null 2>&1 || true
		sleep 2
		log "Existing splunkd cleanup finished"
	else
		log "No existing splunkd process detected"
	fi
}

release_splunk_ports() {
	log "Checking Splunk-required ports for stale listeners"
	local ports=(8000 8089 8065 8191)
	local port

	for port in "${ports[@]}"; do
		local pids
		if command -v ss >/dev/null 2>&1; then
			pids="$(run_with_timeout 15 bash -c "ss -ltnp 'sport = :${port}' 2>/dev/null | awk 'NR>1 {print \$NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u | tr '\n' ' '")"
		elif command -v lsof >/dev/null 2>&1; then
			pids="$(run_with_timeout 15 lsof -nP -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null | tr '\n' ' ')"
		else
			warn "Neither ss nor lsof is available; skipping pre-check for port ${port}"
			continue
		fi

		if [[ -z "${pids// }" ]]; then
			continue
		fi

		warn "Port ${port} has existing listener(s): ${pids}; attempting cleanup"
		for pid in ${pids}; do
			local cmd
			cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
			if [[ "${cmd}" == *"${SPLUNK_HOME}"* || "${cmd}" == *splunkd* || "${cmd}" == *mongod* ]]; then
				kill -TERM "${pid}" >/dev/null 2>&1 || true
			else
				warn "Port ${port} is held by non-Splunk process (pid=${pid} cmd=${cmd}); leaving it untouched"
			fi
		done
		sleep 2
	done
	log "Port preflight completed"
}

run_splunk_start() {
	local start_log
	start_log="$(mktemp)"

	log "Preparing Splunk runtime state"
	ensure_splunk_ownership
	stop_existing_splunk
	release_splunk_ports
	log "Starting Splunk daemon"

	if run_with_timeout 300 su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" >"${start_log}" 2>&1; then
		rm -f "${start_log}"
		log "Splunk start command completed successfully"
		return 0
	fi

	if grep -q '/opt/splunk/lib/python3.7/site-packages' "${start_log}"; then
		warn "Detected legacy python3.7 site-packages path warning during Splunk start; retrying startup."

		if run_with_timeout 60 su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk status" >/dev/null 2>&1; then
			warn "Splunk is already running despite legacy-path warning."
			rm -f "${start_log}"
			return 0
		fi

		if run_with_timeout 300 su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" >>"${start_log}" 2>&1; then
			rm -f "${start_log}"
			return 0
		fi
	fi

	if grep -q "ERROR: http port \[8000\] - port is already bound" "${start_log}"; then
		warn "Port 8000 is already bound; attempting one more stop/start cycle"
		stop_existing_splunk
		ensure_splunk_ownership

		if run_with_timeout 300 su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" >>"${start_log}" 2>&1; then
			rm -f "${start_log}"
			return 0
		fi
	fi

	error "Splunk failed to start. Output follows:"
	sed 's/^/[splunk-start] /' "${start_log}" >&2
	rm -f "${start_log}"
	return 1
}

resolve_splunk_package_s3_key_from_prefix() {
	local normalized_prefix="${SPLUNK_PACKAGE_S3_PREFIX}"
	if [[ -n "${normalized_prefix}" && "${normalized_prefix}" != */ ]]; then
		normalized_prefix="${normalized_prefix}/"
	fi

	if [[ -z "${normalized_prefix}" ]]; then
		return 1
	fi

	require_env LICENSE_BUCKET
	require_cmd aws

	local list_output
	if ! list_output="$(aws s3api list-objects-v2 --bucket "${LICENSE_BUCKET}" --prefix "${normalized_prefix}" --query 'Contents[].Key' --output text 2>&1)"; then
		error "Failed listing RPMs under s3://${LICENSE_BUCKET}/${normalized_prefix}: ${list_output}"
		return 1
	fi

	local rpm_keys=()
	while IFS= read -r key; do
		if [[ -n "${key}" ]]; then
			rpm_keys+=("${key}")
		fi
	done < <(echo "${list_output}" | tr '\t' '\n' | sed '/^None$/d' | grep -Ei '\.rpm$' | sort)

	if [[ "${#rpm_keys[@]}" -eq 0 ]]; then
		error "No .rpm package found under s3://${LICENSE_BUCKET}/${normalized_prefix}"
		return 1
	fi

	if [[ "${#rpm_keys[@]}" -gt 1 ]]; then
		local last_index=$(( ${#rpm_keys[@]} - 1 ))
		warn "Multiple RPMs found under s3://${LICENSE_BUCKET}/${normalized_prefix}; using ${rpm_keys[${last_index}]}"
		echo "${rpm_keys[${last_index}]}"
		return 0
	fi

	echo "${rpm_keys[0]}"
}

log "Installing Splunk Enterprise"
if [[ ! -x "${SPLUNK_HOME}/bin/splunk" ]]; then
	log "Splunk binary not found; installing package"
	if [[ -n "${SPLUNK_PACKAGE_PATH}" && -f "${SPLUNK_PACKAGE_PATH}" ]]; then
		pkg_path="${SPLUNK_PACKAGE_PATH}"
	elif [[ -n "${SPLUNK_PACKAGE_S3_KEY}" ]]; then
		require_env LICENSE_BUCKET
		require_cmd aws
		pkg_path="/tmp/splunk-enterprise.rpm"
		log "Downloading Splunk package from s3://${LICENSE_BUCKET}/${SPLUNK_PACKAGE_S3_KEY}"
		retry 5 10 aws s3 cp "s3://${LICENSE_BUCKET}/${SPLUNK_PACKAGE_S3_KEY}" "${pkg_path}"
	elif [[ -n "${SPLUNK_PACKAGE_S3_PREFIX}" ]]; then
		pkg_path="/tmp/splunk-enterprise.rpm"
		if resolved_s3_key="$(resolve_splunk_package_s3_key_from_prefix)"; then
			log "Downloading Splunk package from s3://${LICENSE_BUCKET}/${resolved_s3_key}"
			retry 5 10 aws s3 cp "s3://${LICENSE_BUCKET}/${resolved_s3_key}" "${pkg_path}"
		elif [[ -n "${SPLUNK_PACKAGE_URL}" ]]; then
			warn "No RPM found under s3://${LICENSE_BUCKET}/${SPLUNK_PACKAGE_S3_PREFIX}; falling back to SPLUNK_PACKAGE_URL"
			log "Downloading Splunk package from SPLUNK_PACKAGE_URL"
			retry 5 10 curl -fL "${SPLUNK_PACKAGE_URL}" -o "${pkg_path}"
		else
			error "No .rpm package found under s3://${LICENSE_BUCKET}/${SPLUNK_PACKAGE_S3_PREFIX} and SPLUNK_PACKAGE_URL is not set"
			exit 1
		fi
	elif [[ -n "${SPLUNK_PACKAGE_URL}" ]]; then
		pkg_path="/tmp/splunk-enterprise.rpm"
		log "Downloading Splunk package from SPLUNK_PACKAGE_URL"
		retry 5 10 curl -fL "${SPLUNK_PACKAGE_URL}" -o "${pkg_path}"
	else
		error "Set SPLUNK_PACKAGE_PATH, SPLUNK_PACKAGE_S3_KEY, SPLUNK_PACKAGE_S3_PREFIX, or SPLUNK_PACKAGE_URL to install Splunk Enterprise"
		exit 1
	fi

	log "Installing Splunk RPM package"
	retry 3 5 rpm -Uvh --replacepkgs "${pkg_path}"
	log "Splunk package installation finished"
fi

mkdir -p "${SPLUNK_HOME}/etc/system/local"
cat > "${SPLUNK_HOME}/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = ${SPLUNK_ADMIN_USER}
PASSWORD = ${SPLUNK_ADMIN_PASSWORD}
EOF
chown splunk:splunk "${SPLUNK_HOME}/etc/system/local/user-seed.conf"

run_splunk_start
log "Configuring Splunk boot-start"
"${SPLUNK_HOME}/bin/splunk" enable boot-start -user splunk --accept-license --answer-yes --no-prompt
su -s /bin/bash splunk -c "${SPLUNK_HOME}/bin/splunk status"
log "Splunk Enterprise is installed and running"
