#!/usr/bin/env bash
set -euo pipefail

# Allowlist Splunk AI Toolkit **Agent Launchpad** egress IPs in your security groups, so Bedrock
# AgentCore (which runs your AITK agents outside your VPC) can reach the resources the agents call
# back into — chiefly the **custom MCP server** on :8000, and optionally the Splunk mgmt port :8089.
#
# IPs are per AWS region, read from utils/agentcore-region-ips.tsv (the externalised map; refresh it
# from Splunk's docs with utils/fetch-agentcore-ips.sh). Override the path with AGENTCORE_IP_MAP.
# Allowlist the region(s) your Agent Launchpad runs in (default: this deployment's region).
#
# Stays clean like utils/update-my-ip-access.sh: every rule it adds carries the description
# "aitk-agent-launchpad:<region>". It only ever touches rules with that marker, so your deploy's own
# rules are left alone. --revoke-stale removes marker rules for regions you no longer select.
#
# NOTE — a private-IP MCP still won't work. Allowlisting only opens the SG. If your custom MCP
# connection URL is a PRIVATE VPC IP (e.g. https://10.0.255.203:8000/mcp), AgentCore can't route to
# it regardless of the SG — the URL must be a publicly routable endpoint (public IP / DNS / ALB).
# See agents/reports/agentcore-mcp-test-report.md.
#
# Usage:
#   ./utils/whitelist-agentcore-ips.sh                          # MCP SG :8000, this region, dry-run off
#   ./utils/whitelist-agentcore-ips.sh --targets mcp,splunk     # also Splunk SGs :8089
#   ./utils/whitelist-agentcore-ips.sh --regions all --dry-run  # preview every region's IP
#   ./utils/whitelist-agentcore-ips.sh --regions us-east-1,eu-west-1 --revoke-stale
#   ./utils/whitelist-agentcore-ips.sh --extra sg-0abc:8000,sg-0def:8089   # arbitrary SG:port targets

REGION="${AWS_REGION:-ap-southeast-1}"     # AWS API region (where your SGs live)
REGIONS_CSV=""                              # Agent Launchpad regions to allowlist (default: $REGION)
TARGETS_CSV="mcp"                           # mcp | splunk | mcp,splunk
EXTRA_CSV=""                                # arbitrary sgid:port,... targets
ROLES_CSV="gpu-host,search-head"            # SplunkAiRole tags for the 'splunk' target
MCP_SG_PREFIX="mcp-server"                  # discover the MCP SG by group-name prefix
MCP_PORTS="8000"
SPLUNK_PORTS="8089"
MARKER_PREFIX="aitk-agent-launchpad"
REVOKE_STALE="false"
DRY_RUN="false"

# --- region -> Agent Launchpad IP, from the externalised map (refresh: utils/fetch-agentcore-ips.sh)
IP_MAP="${AGENTCORE_IP_MAP:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agentcore-region-ips.tsv}"
[[ -f "${IP_MAP}" ]] || { echo "ERROR: region->IP map not found: ${IP_MAP} (run utils/fetch-agentcore-ips.sh)" >&2; exit 1; }
ip_for_region() { awk -v r="$1" '$1==r && $1 !~ /^#/{print $2; exit}' "${IP_MAP}"; }
ALL_REGIONS="$(awk '$1 !~ /^#/ && NF{printf "%s ", $1}' "${IP_MAP}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)       REGION="$2"; shift 2;;
    --regions)      REGIONS_CSV="$2"; shift 2;;
    --targets)      TARGETS_CSV="$2"; shift 2;;
    --extra)        EXTRA_CSV="$2"; shift 2;;
    --roles)        ROLES_CSV="$2"; shift 2;;
    --mcp-sg-prefix) MCP_SG_PREFIX="$2"; shift 2;;
    --mcp-ports)    MCP_PORTS="$2"; shift 2;;
    --splunk-ports) SPLUNK_PORTS="$2"; shift 2;;
    --revoke-stale) REVOKE_STALE="true"; shift;;
    --dry-run)      DRY_RUN="true"; shift;;
    -h|--help) sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

# --- 1. resolve the selected Agent Launchpad IPs -----------------------------------------------
[[ -n "${REGIONS_CSV}" ]] || REGIONS_CSV="${REGION}"
if [[ "${REGIONS_CSV}" == "all" ]]; then
  REGIONS="${ALL_REGIONS}"
else
  REGIONS="$(printf '%s' "${REGIONS_CSV}" | tr ',' ' ')"
fi
# Build parallel "region ip/32" lines; fail early on an unknown region.
SELECTED=""   # newline-separated "region cidr"
for r in ${REGIONS}; do
  ip="$(ip_for_region "${r}")"
  if [[ -z "${ip}" ]]; then
    echo "ERROR: unknown Agent Launchpad region '${r}'. Known: ${ALL_REGIONS}" >&2; exit 1
  fi
  SELECTED="${SELECTED}${r} ${ip}/32
"
done
echo "Agent Launchpad IPs to allowlist:"
printf '%s' "${SELECTED}" | sed '/^$/d' | sed 's/^/  /'

# --- 2. resolve target (SG, port) pairs --------------------------------------------------------
# Emits newline-separated "SG PORT" lines.
TARGETS=""
add_target() { TARGETS="${TARGETS}$1 $2
"; }

want_mcp="false"; want_splunk="false"
for t in $(printf '%s' "${TARGETS_CSV}" | tr ',' ' '); do
  case "$t" in mcp) want_mcp="true";; splunk) want_splunk="true";;
    "") ;; *) echo "ERROR: --targets must be mcp and/or splunk (got '$t')" >&2; exit 2;; esac
done

if [[ "${want_mcp}" == "true" ]]; then
  MCP_SGS="$(aws ec2 describe-security-groups --region "${REGION}" \
      --filters "Name=group-name,Values=${MCP_SG_PREFIX}*" \
      --query 'SecurityGroups[].GroupId' --output text 2>&1 | tr '\t' '\n' | sed '/^$/d' | sort -u || true)"
  if [[ -z "${MCP_SGS}" || "${MCP_SGS}" == *"error"* ]]; then
    echo "WARN: no MCP security group found by name prefix '${MCP_SG_PREFIX}*' in ${REGION} "\
"(pass --extra sg-xxxx:8000)" >&2
  fi
  for sg in ${MCP_SGS}; do for pt in $(printf '%s' "${MCP_PORTS}" | tr ',' ' '); do add_target "${sg}" "${pt}"; done; done
fi

if [[ "${want_splunk}" == "true" ]]; then
  SP_SGS="$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=tag:SplunkAiRole,Values=${ROLES_CSV}" "Name=instance-state-name,Values=running,stopped" \
      --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text 2>&1 | tr '\t' '\n' | sed '/^$/d' | sort -u || true)"
  [[ -n "${SP_SGS}" ]] || echo "WARN: no SplunkAiRole (${ROLES_CSV}) SGs found in ${REGION}" >&2
  for sg in ${SP_SGS}; do for pt in $(printf '%s' "${SPLUNK_PORTS}" | tr ',' ' '); do add_target "${sg}" "${pt}"; done; done
fi

for pair in $(printf '%s' "${EXTRA_CSV}" | tr ',' ' '); do
  [[ -z "${pair}" ]] && continue
  sg="${pair%%:*}"; pt="${pair##*:}"
  [[ "${sg}" == sg-* && "${pt}" =~ ^[0-9]+$ ]] || { echo "ERROR: --extra expects sgid:port (got '${pair}')" >&2; exit 2; }
  add_target "${sg}" "${pt}"
done

TARGETS="$(printf '%s' "${TARGETS}" | sed '/^$/d' | sort -u)"
if [[ -z "${TARGETS}" ]]; then
  echo "ERROR: no target (security-group, port) pairs resolved. Use --targets mcp,splunk or --extra." >&2; exit 1
fi
echo "Targets (security-group : port):"
printf '%s\n' "${TARGETS}" | sed 's/ /  :/' | sed 's/^/  /'
echo "Region(API): ${REGION}   revoke-stale: ${REVOKE_STALE}   dry-run: ${DRY_RUN}"

run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "  would: aws $*"; else aws "$@" >/dev/null; fi; }

# --- 3. per (SG, port): add each selected IP; optionally revoke stale marker rules --------------
SELECTED_CIDRS="$(printf '%s' "${SELECTED}" | sed '/^$/d' | awk '{print $2}')"
printf '%s\n' "${TARGETS}" | while read -r SG PORT; do
  [[ -n "${SG}" ]] || continue
  echo "== ${SG} :${PORT} =="

  # existing rules THIS script manages on this port (marker prefix), as "cidr\tdescription"
  EXISTING="$(aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG}" --output json 2>/dev/null \
    | PORT="${PORT}" MARK="${MARKER_PREFIX}" python3 -c '
import sys, json, os
port=int(os.environ["PORT"]); mark=os.environ["MARK"]
sg=json.load(sys.stdin)["SecurityGroups"][0]
for p in sg.get("IpPermissions", []):
    if p.get("IpProtocol")=="tcp" and p.get("FromPort")==port and p.get("ToPort")==port:
        for r in p.get("IpRanges", []):
            d=r.get("Description","")
            if d.startswith(mark):
                print(r["CidrIp"]+"\t"+d)
' || true)"

  # add selected IPs
  printf '%s' "${SELECTED}" | sed '/^$/d' | while read -r RG CIDR; do
    if printf '%s\n' "${EXISTING}" | awk -F'\t' '{print $1}' | grep -qx "${CIDR}"; then
      echo "  :${PORT} already allows ${CIDR} (${RG})"; continue
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "  :${PORT} would allow ${CIDR} (${RG}, desc=${MARKER_PREFIX}:${RG})"; continue
    fi
    err="$(aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${SG}" \
      --ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},IpRanges=[{CidrIp=${CIDR},Description=${MARKER_PREFIX}:${RG}}]" \
      2>&1 >/dev/null || true)"
    if [[ -z "${err}" ]]; then echo "  :${PORT} allowed ${CIDR} (${RG})"
    elif printf '%s' "${err}" | grep -q 'InvalidPermission.Duplicate'; then echo "  :${PORT} already allows ${CIDR} (${RG})"
    else echo "  :${PORT} FAILED to allow ${CIDR} (${RG}): ${err}" >&2; fi
  done

  # revoke stale marker rules (ours, but for a region/IP no longer selected)
  if [[ "${REVOKE_STALE}" == "true" ]]; then
    printf '%s\n' "${EXISTING}" | while IFS=$'\t' read -r CIDR DESC; do
      [[ -n "${CIDR}" ]] || continue
      if ! printf '%s\n' ${SELECTED_CIDRS} | grep -qx "${CIDR}"; then
        echo "  :${PORT} revoke stale ${CIDR} (${DESC})"
        run ec2 revoke-security-group-ingress --region "${REGION}" --group-id "${SG}" \
          --ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},IpRanges=[{CidrIp=${CIDR}}]"
      fi
    done
  fi
done

echo "Done."
if [[ "${DRY_RUN}" != "true" ]]; then
  echo "Reminder: if the custom MCP URL is a private VPC IP, change it to a routable public endpoint"
  echo "or AgentCore still can't reach it (see agents/reports/agentcore-mcp-test-report.md)."
fi
