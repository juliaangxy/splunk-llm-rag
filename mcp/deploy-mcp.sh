#!/usr/bin/env bash
set -euo pipefail

# Deploy the MCP server CloudFormation stack from an env file, auto-discovering the Bedrock
# Knowledge Base id so you don't have to paste it.
#
# Usage:
#   cp mcp/mcp.env.example mcp/mcp.env     # then edit
#   bash mcp/deploy-mcp.sh                 # discovers the KB, deploys
#   bash mcp/deploy-mcp.sh --env other.env --no-discover-kb --dry-run
#
# Flags:
#   --env <file>        env file to source (default: mcp/mcp.env)
#   --no-discover-kb    don't auto-discover the KB (use BedrockKnowledgeBaseId as-is)
#   --dry-run           print the aws cloudformation deploy command without running it

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/cloudformation/mcp-server.yaml"
log()  { printf '[deploy-mcp] %s\n' "$*"; }
warn() { printf '[deploy-mcp] WARN: %s\n' "$*" >&2; }
die()  { printf '[deploy-mcp] ERROR: %s\n' "$*" >&2; exit 1; }

ENV_FILE="${SCRIPT_DIR}/mcp.env"
DISCOVER_KB=true
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            ENV_FILE="$2"; shift 2;;
    --no-discover-kb) DISCOVER_KB=false; shift;;
    --discover-kb)    DISCOVER_KB=true; shift;;
    --dry-run)        DRY_RUN=true; shift;;
    -h|--help)        sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI is required"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE} (copy mcp/mcp.env.example to mcp/mcp.env and edit)"
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

REGION="${REGION:-ap-southeast-1}"
STACK_NAME="${STACK_NAME:-mcp-server}"
BEDROCK_REGION="${BedrockRegion:-${REGION}}"
KB_NAME="${KB_NAME:-splunk-ai-kb}"

# --- Auto-resolve networking from the platform VPC so the env needs almost nothing ----------
if [[ -z "${ExistingVpcId:-}" ]]; then
  ExistingVpcId="$(aws cloudformation describe-stacks --region "${REGION}" \
    --stack-name "${PLATFORM_NET_STACK:-splunk-ai-foundation-network}" \
    --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue | [0]" --output text 2>/dev/null || true)"
  [[ "${ExistingVpcId}" == "None" ]] && ExistingVpcId=""
  if [[ -z "${ExistingVpcId}" ]]; then
    ExistingVpcId="$(aws ec2 describe-vpcs --region "${REGION}" \
      --filters "Name=tag:Name,Values=${VPC_NAME:-splunk-ai-vpc}" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
    [[ "${ExistingVpcId}" == "None" ]] && ExistingVpcId=""
  fi
  [[ -n "${ExistingVpcId}" ]] && log "resolved ExistingVpcId=${ExistingVpcId}"
fi
if [[ -n "${ExistingVpcId:-}" ]]; then
  if [[ -z "${ExistingIgwId:-}" ]]; then
    ExistingIgwId="$(aws ec2 describe-internet-gateways --region "${REGION}" \
      --filters "Name=attachment.vpc-id,Values=${ExistingVpcId}" \
      --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)"
    [[ "${ExistingIgwId}" == "None" ]] && ExistingIgwId=""
    [[ -n "${ExistingIgwId}" ]] && log "resolved ExistingIgwId=${ExistingIgwId}"
  fi
  vpc_cidr="$(aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${ExistingVpcId}" \
    --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || true)"
  if [[ -z "${SplunkCidr:-}" && -n "${vpc_cidr}" && "${vpc_cidr}" != "None" ]]; then
    SplunkCidr="${vpc_cidr}"; log "defaulted SplunkCidr=${SplunkCidr} (whole VPC)"
  fi
  if [[ -z "${SubnetCidr:-}" && -n "${vpc_cidr}" && "${vpc_cidr}" != "None" ]] && command -v python3 >/dev/null 2>&1; then
    used="$(aws ec2 describe-subnets --region "${REGION}" --filters "Name=vpc-id,Values=${ExistingVpcId}" \
      --query 'Subnets[].CidrBlock' --output text 2>/dev/null || true)"
    SubnetCidr="$(python3 - "${vpc_cidr}" "${used}" <<'PY'
import ipaddress, sys
vpc = ipaddress.ip_network(sys.argv[1])
used = [ipaddress.ip_network(c) for c in sys.argv[2].split() if c]
for net in reversed(list(vpc.subnets(new_prefix=24))):
    if not any(net.overlaps(u) for u in used):
        print(net); break
PY
)"
    [[ -n "${SubnetCidr}" ]] && log "auto-picked free SubnetCidr=${SubnetCidr}"
  fi
fi

# --- Auto-discover the Bedrock KB id (on by default; skip if already set or --no-discover-kb) ---
discover_kb() {
  local region="$1" name="$2" rows id
  rows="$(aws bedrock-agent list-knowledge-bases --region "${region}" \
    --query 'knowledgeBaseSummaries[].[knowledgeBaseId,name]' --output text 2>/dev/null || true)"
  [[ -n "${rows}" ]] || { warn "no knowledge bases found in ${region}"; return 1; }
  # prefer an exact name match, else use the only KB if there's exactly one
  id="$(awk -v n="${name}" '$2==n{print $1; exit}' <<<"${rows}")"
  if [[ -n "${id}" ]]; then echo "${id}"; return 0; fi
  if [[ "$(printf '%s\n' "${rows}" | grep -c .)" -eq 1 ]]; then awk '{print $1}' <<<"${rows}"; return 0; fi
  warn "multiple KBs in ${region} and none named '${name}':"; printf '%s\n' "${rows}" >&2
  return 1
}

if ${DISCOVER_KB} && [[ -z "${BedrockKnowledgeBaseId:-}" ]]; then
  log "discovering Bedrock KB in ${BEDROCK_REGION} (name='${KB_NAME}')"
  if BedrockKnowledgeBaseId="$(discover_kb "${BEDROCK_REGION}" "${KB_NAME}")"; then
    log "  using KB ${BedrockKnowledgeBaseId}"
  else
    warn "could not auto-discover a KB — set BedrockKnowledgeBaseId in ${ENV_FILE} (the KB tool stays disabled otherwise)"
    BedrockKnowledgeBaseId=""
  fi
fi

# --- Assemble parameter overrides (only pass the ones that are set) -------------------------
OVERRIDES=()
add() { [[ -n "${2:-}" ]] && OVERRIDES+=("$1=$2"); return 0; }
add ExistingVpcId          "${ExistingVpcId:-}"
add ExistingIgwId          "${ExistingIgwId:-}"
add VpcCidr                "${VpcCidr:-}"
add SubnetCidr             "${SubnetCidr:-}"
add SplunkCidr             "${SplunkCidr:-}"
add AllowInternetAccess    "${AllowInternetAccess:-}"
add McpPort                "${McpPort:-}"
add BedrockKnowledgeBaseId "${BedrockKnowledgeBaseId:-}"
add BedrockRegion          "${BedrockRegion:-}"
add WebSearchProvider      "${WebSearchProvider:-}"
add WebSearchApiKey        "${WebSearchApiKey:-}"
add SearxngUrl             "${SearxngUrl:-}"
add InstanceType           "${InstanceType:-}"
add KeyName                "${KeyName:-}"
add TlsMode                "${TlsMode:-}"
add CodeS3Bucket           "${CodeS3Bucket:-}"
add CodeS3Prefix           "${CodeS3Prefix:-}"

log "stack=${STACK_NAME} region=${REGION} | ${#OVERRIDES[@]} parameter override(s)"
CMD=(aws cloudformation deploy --region "${REGION}" --stack-name "${STACK_NAME}"
     --template-file "${TEMPLATE}" --capabilities CAPABILITY_IAM
     --parameter-overrides "${OVERRIDES[@]}")

if ${DRY_RUN}; then
  printf '  DRYRUN:'; printf ' %q' "${CMD[@]}"; echo; exit 0
fi

"${CMD[@]}"

log "Stack outputs:"
aws cloudformation describe-stacks --region "${REGION}" --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs' --output table || true
log "Read the bearer token with:"
log "  aws secretsmanager get-secret-value --region ${REGION} --secret-id ${STACK_NAME}-mcp-auth-token --query SecretString --output text"
