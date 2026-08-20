#!/usr/bin/env bash
set -euo pipefail

# Push the reusable skills (agents/skills/*.md) into Splunk AITK's KV Store (aitk_agent_skills) by
# running apply-agents.py --apply. This is the codified, repeatable equivalent of hand-inserting
# skills — check the skill FILES into git, then run this to sync them to Splunk.
#
# Splunk management URL — first that resolves:
#   1. --splunk-url <url>
#   2. $SPLUNK_MGMT_URL
#   3. the mcp-server stack's SplunkMcpLoadBalancerEndpoint output (the NLB :8089), via AWS
#   4. https://localhost:8089   (when run ON the Splunk host)
# Admin password — first that's set: -p <pw>, $SPLUNK_ADMIN_PASSWORD, or config/cloud.env.
#
# The mgmt port (:8089) must be reachable from where you run this — on the Splunk host (localhost),
# or through the NLB from an IP allow-listed on the LB security group (see mcp/README.md).
#
# Usage:
#   ./agents/push-skills.sh                                   # all agents' skills, auto-resolve
#   ./agents/push-skills.sh --agents threatdetection          # just one agent's skills
#   ./agents/push-skills.sh --splunk-url https://host:8089 -p '<pw>'
#   ./agents/push-skills.sh --dry-run                         # preview (no writes)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-ap-southeast-1}"
STACK_NAME="${MCP_STACK_NAME:-mcp-server}"
SPLUNK_URL="${SPLUNK_MGMT_URL:-}"
PW="${SPLUNK_ADMIN_PASSWORD:-}"
AGENTS=""
EXTRA=()          # passed through to apply-agents.py (e.g. --dry-run maps to no --apply)
APPLY="--apply"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --splunk-url) SPLUNK_URL="$2"; shift 2;;
    -p|--password) PW="$2"; shift 2;;
    --agents) AGENTS="$2"; shift 2;;
    --dry-run) APPLY=""; shift;;                 # no --apply => apply-agents.py stays in dry-run
    -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) EXTRA+=("$1"); shift;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

# --- resolve the admin password ---------------------------------------------------------------
if [[ -z "${PW}" && -f "${REPO_ROOT}/config/cloud.env" ]]; then
  PW="$(grep -E '^(export )?SPLUNK_ADMIN_PASSWORD=' "${REPO_ROOT}/config/cloud.env" | head -1 \
        | sed -E 's/^(export )?SPLUNK_ADMIN_PASSWORD=//; s/^["'"'"']//; s/["'"'"']$//')"
fi
[[ -n "${PW}" ]] || { echo "ERROR: admin password not found — pass -p, set SPLUNK_ADMIN_PASSWORD, or add it to config/cloud.env" >&2; exit 1; }

# --- resolve the Splunk mgmt URL --------------------------------------------------------------
if [[ -z "${SPLUNK_URL}" ]] && command -v aws >/dev/null 2>&1; then
  ep="$(aws cloudformation describe-stacks --region "${REGION}" --stack-name "${STACK_NAME}" \
        --query "Stacks[0].Outputs[?OutputKey=='SplunkMcpLoadBalancerEndpoint'].OutputValue | [0]" \
        --output text 2>/dev/null || true)"
  if [[ -n "${ep}" && "${ep}" != "None" ]]; then
    SPLUNK_URL="${ep%%/services/mcp}"                    # https://<nlb>:8089/services/mcp -> https://<nlb>:8089
    echo "[push-skills] resolved Splunk mgmt URL from stack ${STACK_NAME}: ${SPLUNK_URL}"
  fi
fi
[[ -n "${SPLUNK_URL}" ]] || SPLUNK_URL="https://localhost:8089"
echo "[push-skills] target: ${SPLUNK_URL}  (mode: ${APPLY:-dry-run})"

# --- run apply-agents.py ----------------------------------------------------------------------
CMD=(python3 "${REPO_ROOT}/agents/apply-agents.py" --splunk-url "${SPLUNK_URL}" -u admin -p "${PW}")
[[ -n "${APPLY}" ]] && CMD+=(--apply --overwrite)
[[ -n "${AGENTS}" ]] && CMD+=(--agents "${AGENTS}")
[[ ${#EXTRA[@]} -gt 0 ]] && CMD+=("${EXTRA[@]}")
exec "${CMD[@]}"
