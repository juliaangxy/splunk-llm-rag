#!/usr/bin/env bash
set -euo pipefail

# Idempotent self-heal for the token-meter routing table. Re-runs the route generator
# and, ONLY if the resolved routes actually changed, restarts the metering proxies.
#
# Why this exists: on a fresh deploy the GPU host signals stack-complete before the
# search head instance is even created (SearchHeadStack DependsOn GpuInstanceStack), so
# when the GPU generates its routes during bootstrap the search head can't be resolved
# yet and it falls back to routing to itself. A systemd timer runs this script every few
# minutes; once the search head appears its IP resolves, the routes file changes, and the
# proxies are restarted to pick it up. Steady state is a no-op (checksum unchanged), so
# it also self-heals if a peer instance is later replaced with a new private IP.
#
# Config comes from bootstrap.env (TOKEN_METER_ROUTES, TOKEN_METER_DEFAULT_ROLE), sourced
# by common.sh — the same values the deploy set.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

ROUTES_OUT="${ROUTES_OUT:-/opt/splunk-ai/token-meter-routes.json}"

# aws in a bare systemd context may lack a region; take it from IMDS.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds_get placement/region)}"

before=""
[[ -f "${ROUTES_OUT}" ]] && before="$(sha256sum "${ROUTES_OUT}" | awk '{print $1}')"

TOKEN_METER_ROUTES="${TOKEN_METER_ROUTES:-[]}" \
TOKEN_METER_DEFAULT_ROLE="${TOKEN_METER_DEFAULT_ROLE:-search-head}" \
  bash "${SCRIPT_DIR}/configure-token-meter-routes.sh" >/dev/null 2>&1 || {
    warn "route generation failed; leaving existing routes in place"
    exit 0
  }

after=""
[[ -f "${ROUTES_OUT}" ]] && after="$(sha256sum "${ROUTES_OUT}" | awk '{print $1}')"

if [[ "${before}" != "${after}" ]]; then
  log "Token-meter routes changed; restarting proxies to apply"
  bash "${SCRIPT_DIR}/start-token-meter-proxies.sh" >/dev/null 2>&1 || warn "proxy restart failed"
else
  log "Token-meter routes unchanged; no restart needed"
fi
