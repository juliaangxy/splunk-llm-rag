#!/usr/bin/env bash
set -euo pipefail

# Populate the LOCAL Splunk with N minutes of historical demo incident data, using a ONE-SHOT
# container that runs inside this Splunk node's VM and exits when done (spins down). Re-runnable.
#
# Runs two ways:
#   * At BOOTSTRAP (default) — a stage on each Splunk node; acts when this node's role
#     (SPLUNK_DATA_SELF) is in SPLUNK_DATA_TARGETS (default 'search-head,gpu' = both).
#   * MANUALLY — run directly with flags any time; a flag always forces it to run.
#
# Usage:
#   sudo SPLUNK_ADMIN_PASSWORD=... ./populate-splunk-data.sh [--duration-min 240] \
#        [--end-offset-min N] [--append] [--splunk-host 127.0.0.1] \
#        [--hec-port 8088] [--mgmt-port 8089] [--hec-token <token>]
#
# Rerun behaviour: by DEFAULT it CLEANS the app/infra/security indexes first, so each run is a
# fresh, deterministic dataset (no duplicate incidents). Use --append to keep existing data.
# --end-offset-min back-dates the window (it ends N minutes ago instead of now).
# Duration default comes from SPLUNK_DATA_DURATION_MIN (env/bootstrap), else 60. Long-running
# live generation is a SEPARATE tool: datagen-live.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

DURATION_MIN="${SPLUNK_DATA_DURATION_MIN:-60}"
END_OFFSET_MIN="${SPLUNK_DATA_END_OFFSET_MIN:-0}"
CLEAN="${SPLUNK_DATA_CLEAN:-true}"
SPLUNK_HOST="${SPLUNK_HOST:-127.0.0.1}"
HEC_PORT="${HEC_PORT:-8088}"
MGMT_PORT="${MGMT_PORT:-8089}"
HEC_TOKEN="${HEC_TOKEN:-}"
CONTAINER="${DATAGEN_BACKFILL_CONTAINER:-splunk-datagen-backfill}"

[[ $# -gt 0 ]] && DATAGEN_FORCE=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration-min)   DURATION_MIN="$2"; shift 2;;
    --end-offset-min) END_OFFSET_MIN="$2"; shift 2;;
    --append)         CLEAN=false; shift;;
    --clean)          CLEAN=true; shift;;
    --splunk-host)    SPLUNK_HOST="$2"; shift 2;;
    --hec-port)       HEC_PORT="$2"; shift 2;;
    --mgmt-port)      MGMT_PORT="$2"; shift 2;;
    --hec-token)      HEC_TOKEN="$2"; shift 2;;
    -h|--help)        sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

if ! datagen_targeted; then
  log "populate: this node (self='${SPLUNK_DATA_SELF:-}') not in SPLUNK_DATA_TARGETS='${SPLUNK_DATA_TARGETS:-}'; skipping"
  exit 0
fi
require_root

if ! [[ "${DURATION_MIN}" =~ ^[0-9]+$ ]] || (( DURATION_MIN < 1 || DURATION_MIN > 1440 )); then
  error "--duration-min must be an integer 1..1440 (max 24h)"; exit 2
fi
[[ "${END_OFFSET_MIN}" =~ ^[0-9]+$ ]] || { error "--end-offset-min must be a non-negative integer"; exit 2; }

# Clean by default so a repopulate is deterministic (no duplicate incidents). --append skips this.
if [[ "${CLEAN}" == "true" ]]; then
  log "cleaning app/infra/security before repopulating (use --append to keep existing data)"
  datagen_reset_indexes "${SPLUNK_HOST}" "${MGMT_PORT}"
fi
datagen_ensure_splunk "${SPLUNK_HOST}" "${HEC_PORT}" "${MGMT_PORT}"
datagen_require_docker || { error "docker is required for the populate container"; exit 1; }
datagen_build_image

log "populating ~${DURATION_MIN} min of demo data (ending ${END_OFFSET_MIN} min ago) into app/infra/security (one-shot container)"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
# Foreground + --rm: runs the backfill, then the container exits and is removed (spins down).
docker run --rm --name "${CONTAINER}" --network host \
  -e DATAGEN_MODE=backfill -e DURATION_MIN="${DURATION_MIN}" -e END_OFFSET_MIN="${END_OFFSET_MIN}" \
  -e HEC_URL="${HEC_URL}" -e HEC_TOKEN="${HEC_TOKEN}" \
  "${DATAGEN_IMAGE}"

log "Done. Search it:  index=app OR index=infra OR index=security earliest=-$((DURATION_MIN + END_OFFSET_MIN))m"
log "Re-run any time (clean by default); for continuous data use datagen-live.sh."
