#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/splunk-ai"
BOOTSTRAP_ENV_FILE="${BOOTSTRAP_ENV_FILE:-/opt/splunk-ai/bootstrap.env}"

# Load persisted bootstrap environment for manual stage re-runs.
if [[ -f "${BOOTSTRAP_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${BOOTSTRAP_ENV_FILE}"
  set +a
fi

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

warn() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN: $*" >&2
}

error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root" >&2
    exit 1
  fi
}

retry() {
  local attempts="${1}"
  shift
  local delay="${1}"
  shift
  local count=1

  until "$@"; do
    if [[ "${count}" -ge "${attempts}" ]]; then
      error "Command failed after ${attempts} attempts: $*"
      return 1
    fi

    warn "Command failed (attempt ${count}/${attempts}): $*"
    sleep "${delay}"
    count=$((count + 1))
  done
}

require_cmd() {
  local cmd="${1}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    error "Missing required command: ${cmd}"
    exit 1
  fi
}

require_env() {
  local env_name="${1}"
  if [[ -z "${!env_name:-}" ]]; then
    error "Required environment variable is not set: ${env_name}"
    exit 1
  fi
}

ensure_dnf_package() {
  local package_name="${1}"
  if ! rpm -q "${package_name}" >/dev/null 2>&1; then
    retry 5 10 dnf install -y "${package_name}"
  fi
}

wait_for_port() {
  local host="${1}"
  local port="${2}"
  local timeout_seconds="${3:-120}"
  local elapsed=0

  log "Waiting for ${host}:${port} (timeout ${timeout_seconds}s)"

  while ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; do
    if [[ "${elapsed}" -ge "${timeout_seconds}" ]]; then
      error "Timed out waiting for ${host}:${port}"
      return 1
    fi
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      log "Still waiting for ${host}:${port} after ${elapsed}s"
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "Detected ${host}:${port} is available after ${elapsed}s"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    error "Neither docker compose nor docker-compose is available"
    return 1
  fi
}

extract_docker_host_from_uri() {
	local docker_uri="${1:-tcp://127.0.0.1:2375}"
	# Extract host from URIs like tcp://127.0.0.1:2375 or https://10.0.0.1:2375
	# Returns just the IP/hostname part
	echo "${docker_uri}" | sed 's|^[^/]*//||;s|:.*||'
}

splunk_run() {
  local splunk_home="${SPLUNK_HOME:-/opt/splunk}"
  local splunk_user="${SPLUNK_OS_USER:-splunk}"
  local splunk_admin_user="${SPLUNK_ADMIN_USER:-admin}"
  local splunk_admin_password="${SPLUNK_ADMIN_PASSWORD:-}"
  local cmd=("${splunk_home}/bin/splunk" "$@")

  # Add auth automatically when credentials are available to avoid interactive prompts.
  if [[ -n "${splunk_admin_password}" ]]; then
    cmd+=("-auth" "${splunk_admin_user}:${splunk_admin_password}")
  fi

  local quoted_cmd=()
  local token
  for token in "${cmd[@]}"; do
    quoted_cmd+=("$(printf '%q' "${token}")")
  done

  su -s /bin/bash "${splunk_user}" -c "${quoted_cmd[*]}"
}

splunk_health_check() {
  wait_for_port 127.0.0.1 8089 300
  wait_for_port 127.0.0.1 8000 300
  splunk_run status >/dev/null
}

splunkd_health_check() {
  wait_for_port 127.0.0.1 8089 300
  splunk_run status >/dev/null
}

splunk_start_log_shows_progress() {
  local log_file="${1}"

  grep -Eqi 'Starting splunk server daemon \(splunkd\).*Done|WARNING: web interface does not seem to be available|Checking mgmt port \[8089\]: open|Checking http port \[8000\]: open' "${log_file}"
}

splunk_refresh_configs() {
  log "Requesting Splunk config refresh via /services/debug/refresh"

  if splunk_run _internal call /services/debug/refresh -method POST >/dev/null 2>&1; then
    return 0
  fi

  warn "Splunk config refresh request failed"
  return 1
}

splunkweb_health_check() {
  wait_for_port 127.0.0.1 8000 180
}

splunkweb_try_reconcile() {
  local web_log
  web_log="$(mktemp)"

  log "Attempting Splunk Web reconciliation"

  if ! splunk_run start splunkweb >"${web_log}" 2>&1; then
    if grep -qi "already running" "${web_log}"; then
      warn "Splunk Web start reconcile reported already running; validating web health"
    else
      warn "Splunk Web start reconcile failed before health validation"
      sed 's/^/[splunkweb-reconcile] /' "${web_log}" >&2
      rm -f "${web_log}"
      return 1
    fi
  fi

  if splunkweb_health_check; then
    rm -f "${web_log}"
    return 0
  fi

  warn "Splunk Web reconcile did not restore web health"
  sed 's/^/[splunkweb-reconcile] /' "${web_log}" >&2
  rm -f "${web_log}"
  return 1
}

splunk_refresh_and_reconcile_non_interactive() {
  log "Attempting lightweight Splunk config reload without full restart"

  if ! splunkd_health_check; then
    warn "Splunkd is not healthy enough for lightweight reload; full start/restart path is required"
    return 1
  fi

  splunk_refresh_configs || true

  if splunk_health_check; then
    return 0
  fi

  warn "Splunk config refresh completed but full health check still failed; attempting Splunk Web reconcile"
  if splunkweb_try_reconcile && splunk_health_check; then
    return 0
  fi

  warn "Lightweight Splunk reload path did not restore full health"
  return 1
}

ensure_splunk_reloadable_change_health_non_interactive() {
  local running_message="${1:-Splunk is running; attempting reload-safe health validation without a full restart}"
  local stopped_message="${2:-Splunk is not running; attempting direct start}"
  local failed_message="${3:-Splunk did not recover after reload-safe reconciliation attempts}"

  if splunk_run status >/dev/null 2>&1; then
    log "${running_message}"
    if splunk_refresh_and_reconcile_non_interactive; then
      return 0
    fi

    warn "Lightweight reload did not restore health; attempting start reconciliation without stopping Splunk"
    if splunk_try_start_reconcile; then
      return 0
    fi

    error "${failed_message}"
    return 1
  fi

  warn "${stopped_message}"
  splunk_start_non_interactive
}

ensure_splunk_restart_required_change_health_non_interactive() {
  local running_message="${1:-Splunk is running; validating health without forcing a full restart}"
  local stopped_message="${2:-Splunk is not running; attempting direct start}"

  if splunk_run status >/dev/null 2>&1; then
    log "${running_message}"
    if ! splunk_refresh_and_reconcile_non_interactive; then
      warn "Lightweight Splunk reload did not restore health; falling back to full restart"
      splunk_restart_non_interactive
    fi
  else
    warn "${stopped_message}"
    splunk_start_non_interactive
  fi
}

splunk_try_start_reconcile() {
  local start_log
  start_log="$(mktemp)"

  log "Attempting Splunk start reconciliation without stopping services"

  if ! splunk_run start --accept-license --answer-yes --no-prompt >"${start_log}" 2>&1; then
    if grep -qi "already running" "${start_log}"; then
      warn "Splunk start reconcile reported already running; validating service health"
    elif splunk_start_log_shows_progress "${start_log}"; then
      warn "Splunk start reconcile returned a non-zero exit after partial progress; validating service health"
    else
      warn "Splunk start reconcile failed before health validation"
      sed 's/^/[splunk-start-reconcile] /' "${start_log}" >&2
      rm -f "${start_log}"
      return 1
    fi
  fi

  if splunk_health_check; then
    rm -f "${start_log}"
    return 0
  fi

  warn "Splunk start reconcile did not restore full health"
  sed 's/^/[splunk-start-reconcile] /' "${start_log}" >&2
  rm -f "${start_log}"
  return 1
}

splunk_start_non_interactive() {
  local start_log
  start_log="$(mktemp)"

  log "Starting Splunk non-interactively"

  if ! splunk_run start --accept-license --answer-yes --no-prompt >"${start_log}" 2>&1; then
    if grep -qi "already running" "${start_log}"; then
      warn "Splunk start reported already running; validating service health"
    elif splunk_start_log_shows_progress "${start_log}"; then
      warn "Splunk start returned a non-zero exit after partial progress; validating service health before failing"
    else
      error "Splunk start failed"
      sed 's/^/[splunk-start] /' "${start_log}" >&2
      rm -f "${start_log}"
      return 1
    fi
  fi

  if splunk_health_check; then
    rm -f "${start_log}"
    return 0
  fi

  if splunkd_health_check; then
    warn "Splunkd is healthy but Splunk Web is not; trying config refresh and Splunk Web reconcile"
    splunk_refresh_configs || true
    if splunkweb_try_reconcile && splunk_health_check; then
      rm -f "${start_log}"
      return 0
    fi
  fi

  if splunk_try_start_reconcile; then
    rm -f "${start_log}"
    return 0
  fi

  warn "Splunk start path did not pass health checks; attempting one stop/start recovery"
  splunk_run stop --answer-yes --no-prompt >/dev/null 2>&1 || true
  sleep 3

  if splunk_run start --accept-license --answer-yes --no-prompt >/dev/null 2>&1 && splunk_health_check; then
    rm -f "${start_log}"
    return 0
  fi

  error "Splunk failed health checks after start/recovery sequence"
  sed 's/^/[splunk-start] /' "${start_log}" >&2
  rm -f "${start_log}"
  return 1
}

splunk_restart_non_interactive() {
  local restart_log
  restart_log="$(mktemp)"

  log "Restarting splunkd non-interactively"

  if splunk_run restart splunkd >"${restart_log}" 2>&1; then
    # Restart command can return before services are fully healthy.
    if splunk_health_check; then
      rm -f "${restart_log}"
      return 0
    fi

    if splunkd_health_check; then
      warn "Splunk restart left splunkd healthy but Splunk Web unavailable; trying config refresh and Splunk Web reconcile"
      splunk_refresh_configs || true
      if splunkweb_try_reconcile && splunk_health_check; then
        rm -f "${restart_log}"
        return 0
      fi
    fi

    warn "Splunk restart completed but health checks failed; attempting start reconciliation"
    rm -f "${restart_log}"
    splunk_start_non_interactive
    return $?
  fi

  if grep -Eqi 'splunkd.*(not|unavailable)|splunkweb.*(not|unavailable)|failed to connect|connection refused|service not started|not running' "${restart_log}"; then
    warn "Splunk restart failed due to splunkd/splunkweb availability; attempting start reconciliation"
    rm -f "${restart_log}"
    splunk_start_non_interactive
    return $?
  fi

  error "Splunk restart failed"
  sed 's/^/[splunk-restart] /' "${restart_log}" >&2
  rm -f "${restart_log}"
  return 1
}

ensure_state_dir() {
  mkdir -p "${STATE_DIR}"
}
