#!/usr/bin/env bash
# Shared helpers for the datagen scripts (populate-splunk-data.sh + datagen-live.sh).
# Source AFTER setting SCRIPT_DIR to this folder.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

DATAGEN_IMAGE="${DATAGEN_IMAGE:-splunk-datagen:latest}"
DATAGEN_INDEXES=(app infra security)

# Enabled for this instance if its role (SPLUNK_DATA_SELF) is in SPLUNK_DATA_TARGETS (a comma
# list of search-head/gpu, or 'all'/'both'), or DATAGEN_FORCE=true (a manual run with flags).
datagen_targeted() {
  local targets=",${SPLUNK_DATA_TARGETS:-}," self="${SPLUNK_DATA_SELF:-}"
  [[ "${DATAGEN_FORCE:-false}" == "true" ]] && return 0
  [[ "${targets}" == *",all,"* || "${targets}" == *",both,"* ]] && return 0
  [[ -n "${self}" && "${targets}" == *",${self},"* ]] && return 0
  return 1
}

# Ensure the app/infra/security indexes + a HEC token exist on a Splunk (via admin REST), and
# export HEC_URL + HEC_TOKEN for it. Skips creation if HEC_TOKEN is already set.
#   args: <host> <hec-port> <mgmt-port>   env: SPLUNK_ADMIN_USER/PASSWORD, DATAGEN_HEC_TOKEN_NAME
datagen_ensure_splunk() {
  local host="${1:-127.0.0.1}" hecport="${2:-8088}" mgmtport="${3:-8089}"
  HEC_URL="https://${host}:${hecport}/services/collector/event"
  [[ -n "${HEC_TOKEN:-}" ]] && { log "using provided HEC token for ${host}"; return 0; }
  require_env SPLUNK_ADMIN_PASSWORD
  local mgmt="https://${host}:${mgmtport}" auth="${SPLUNK_ADMIN_USER:-admin}:${SPLUNK_ADMIN_PASSWORD}"
  local idx code
  for idx in "${DATAGEN_INDEXES[@]}"; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' -u "${auth}" "${mgmt}/services/data/indexes" \
      -d name="${idx}" -d datatype=event 2>/dev/null || true)"
    case "${code}" in 20*|409) ;; *) warn "index '${idx}' create returned HTTP ${code}";; esac
  done
  local idx_csv name
  idx_csv="$(IFS=,; echo "${DATAGEN_INDEXES[*]}")"
  name="${DATAGEN_HEC_TOKEN_NAME:-datagen}"
  curl -sk -u "${auth}" "${mgmt}/services/data/inputs/http/http" -d disabled=0 -d enableSSL=1 >/dev/null 2>&1 || true
  curl -sk -u "${auth}" "${mgmt}/services/data/inputs/http" \
    -d name="${name}" -d index=app -d indexes="${idx_csv}" -d disabled=0 >/dev/null 2>&1 || true
  curl -sk -u "${auth}" "${mgmt}/services/data/inputs/http/${name}/enable" -X POST >/dev/null 2>&1 || true
  HEC_TOKEN="$(curl -sk -u "${auth}" "${mgmt}/services/data/inputs/http/${name}?output_mode=json" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["entry"][0]["content"]["token"])' 2>/dev/null || true)"
  [[ -n "${HEC_TOKEN}" ]] || { error "could not create/read HEC token '${name}' on ${host}"; return 1; }
  log "HEC token '${name}' ready on ${host} (indexes: ${idx_csv})"
}

# Wipe the demo indexes (delete + let ensure recreate) so a repopulate is a clean, deterministic
# dataset instead of accumulating duplicates. These indexes hold only datagen data.
#   args: <host> <mgmt-port>   env: SPLUNK_ADMIN_USER/PASSWORD
datagen_reset_indexes() {
  local host="${1:-127.0.0.1}" mgmtport="${2:-8089}"
  require_env SPLUNK_ADMIN_PASSWORD
  local mgmt="https://${host}:${mgmtport}" auth="${SPLUNK_ADMIN_USER:-admin}:${SPLUNK_ADMIN_PASSWORD}"
  local idx code
  for idx in "${DATAGEN_INDEXES[@]}"; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' -u "${auth}" -X DELETE "${mgmt}/services/data/indexes/${idx}" 2>/dev/null || true)"
    case "${code}" in 20*|404) log "cleared index '${idx}' (${code})";; *) warn "could not clear index '${idx}' (HTTP ${code}); data may accumulate";; esac
  done
  sleep 2   # let the deletions settle before recreating
}

# Ensure Docker is present (installs it on demand — the search head has no 01-docker stage).
datagen_require_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  log "docker not found; installing it"
  ensure_dnf_package docker 2>/dev/null || true
  systemctl enable --now docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1
}

# Build the (shared) datagen image from this folder's Dockerfile.
datagen_build_image() { docker build -t "${DATAGEN_IMAGE}" "${SCRIPT_DIR}" >/dev/null; }
