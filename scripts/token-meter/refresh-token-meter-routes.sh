#!/usr/bin/env bash
set -euo pipefail

# Idempotent self-heal for the token-meter HEC destination. Re-runs the destination
# generator and, ONLY if the resolved destination actually changed, restarts the proxies.
#
# Why this exists: on a fresh deploy the GPU host signals stack-complete before the
# search head instance is even created (SearchHeadStack DependsOn GpuInstanceStack), so
# when the GPU generates its destination during bootstrap the search head can't be resolved
# yet and it falls back to shipping to itself. A systemd timer runs this script every few
# minutes; once the search head appears its IP resolves, the destination file changes, and
# the proxies are restarted to pick it up. Steady state is a no-op (checksum unchanged), so
# it also self-heals if a peer instance is later replaced with a new private IP.
#
# Config comes from bootstrap.env (TOKEN_METER_DEFAULT_ROLE), sourced by common.sh — the
# same value the deploy set.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/aws-helpers.sh"   # IMDS + SplunkAiRole->IP (AWS-only role resolution)

require_root

ROUTES_OUT="${ROUTES_OUT:-/opt/splunk-ai/token-meter-routes.json}"

# aws in a bare systemd context may lack a region; take it from IMDS.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds_get placement/region)}"

before=""
[[ -f "${ROUTES_OUT}" ]] && before="$(sha256sum "${ROUTES_OUT}" | awk '{print $1}')"

TOKEN_METER_DEFAULT_ROLE="${TOKEN_METER_DEFAULT_ROLE:-search-head}" \
  bash "${SCRIPT_DIR}/configure-token-meter-routes.sh" >/dev/null 2>&1 || {
    warn "destination generation failed; leaving existing destination in place"
    exit 0
  }

after=""
[[ -f "${ROUTES_OUT}" ]] && after="$(sha256sum "${ROUTES_OUT}" | awk '{print $1}')"

if [[ "${before}" != "${after}" ]]; then
  log "Token-meter destination changed; restarting proxies to apply"
  bash "${SCRIPT_DIR}/start-token-meter-proxies.sh" >/dev/null 2>&1 || warn "proxy restart failed"
else
  log "Token-meter destination unchanged; no restart needed"
fi
