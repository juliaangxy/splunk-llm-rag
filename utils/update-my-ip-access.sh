#!/usr/bin/env bash
set -euo pipefail

# Sync YOUR current public IP into the inbound security-group rules for SSH (22) and Splunk Web
# (8000) on the Splunk GPU host and search head — so you don't hand-edit the SG every time your
# IP changes (home/coffee-shop/VPN).
#
# How it stays clean: every rule this script adds gets a fixed description ("auto-my-ip" by
# default). On each run it revokes the PREVIOUS auto-added rule (whatever old IP it had) and adds
# your new /32. It only ever touches rules carrying that marker, so the deploy's own
# ALLOWED_SSH_CIDR / ALLOWED_SPLUNK_UI_CIDR and the VPC-internal rules are left untouched.
#
# Targets are discovered by the SplunkAiRole tag (gpu-host, search-head) — no IPs/IDs hard-coded.
# Uses your current aws CLI credentials (SSO / aws login). Mac bash 3.2 compatible (no mapfile).
#
# Usage:
#   ./utils/update-my-ip-access.sh [--region ap-southeast-1] [--ports 22,8000]
#                                  [--roles gpu-host,search-head] [--ip 1.2.3.4] [--dry-run]

REGION="${AWS_REGION:-ap-southeast-1}"
PORTS_CSV="22,8000"
ROLES_CSV="gpu-host,search-head"
MARKER="${IP_RULE_MARKER:-auto-my-ip}"   # SG-rule description that marks rules THIS script manages
FORCE_IP=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --ports)  PORTS_CSV="$2"; shift 2;;
    --roles)  ROLES_CSV="$2"; shift 2;;
    --ip)     FORCE_IP="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

# Confirm the AWS CLI can make a call before we start — but SHOW the real error rather than guessing
# "expired". A silent no-op was the original bug; a wrong diagnosis is just as unhelpful.
# if ! _who="$(aws sts get-caller-identity --region "${REGION}" 2>&1 >/dev/null)"; then
#   echo "ERROR: the AWS CLI could not authenticate. It reported:" >&2
#   echo "  ${_who}" >&2
#   echo "Fix the above (e.g. re-run your login: 'aws login' / 'aws sso login --profile <p>', or set" >&2
#   echo "AWS_PROFILE), then retry. If it succeeds in one terminal but not another, check that both use" >&2
#   echo "the same aws binary and profile:  which aws ; aws configure list" >&2
#   exit 1
# fi

# --- 1. current public IP ---------------------------------------------------------------------
if [[ -n "${FORCE_IP}" ]]; then
  MYIP="${FORCE_IP}"
else
  MYIP="$(curl -fsS --max-time 8 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "${MYIP}" ]] || MYIP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
fi
if ! printf '%s' "${MYIP}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  echo "ERROR: could not determine a valid public IPv4 (got: '${MYIP}')" >&2; exit 1
fi
CIDR="${MYIP}/32"
echo "Your public IP: ${CIDR}"

# --- 2. discover the target security groups (by SplunkAiRole tag) ------------------------------
ROLES_VALUES="$(printf '%s' "${ROLES_CSV}" | tr ',' ' ')"
# Capture stderr so an AWS auth/region error is SHOWN — not swallowed into a silent `set -e` exit.
if ! _raw="$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=tag:SplunkAiRole,Values=${ROLES_CSV}" "Name=instance-state-name,Values=running,stopped" \
      --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text 2>&1)"; then
  echo "ERROR: 'aws ec2 describe-instances' failed. The CLI reported:" >&2
  echo "  ${_raw}" >&2
  echo "" >&2
  echo "Note: this script runs the real 'aws' BINARY. If 'aws' works when you type it but not here," >&2
  echo "your 'aws' is likely a shell function/alias (SSO wrapper) that scripts can't use. Check with:" >&2
  echo "    type aws        # 'aws is a function/alias' => that's the cause" >&2
  echo "    which -a aws" >&2
  echo "Then run your login so the BINARY has creds, or invoke the wrapper first, e.g.:" >&2
  echo "    aws login && \$(which aws) sts get-caller-identity --region ${REGION}" >&2
  exit 1
fi
SGS="$(printf '%s' "${_raw}" | tr '\t' '\n' | sed '/^$/d' | sort -u)"
if [[ -z "${SGS}" ]]; then
  echo "ERROR: auth OK, but no instances tagged SplunkAiRole in [${ROLES_VALUES}] found in ${REGION}." >&2; exit 1
fi
echo "Target security groups: $(printf '%s' "${SGS}" | tr '\n' ' ')"
echo "Ports: ${PORTS_CSV}   (dry-run: ${DRY_RUN})"

run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "  would: aws $*"; else aws "$@" >/dev/null; fi; }

# --- 3. per SG, per port: revoke the old auto rule, add the new /32 ----------------------------
PORTS="$(printf '%s' "${PORTS_CSV}" | tr ',' ' ')"
for SG in ${SGS}; do
  echo "== ${SG} =="
  for PORT in ${PORTS}; do
    # CIDRs previously added by THIS script (marker description) on this port.
    OLD="$(aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG}" --output json 2>/dev/null \
      | PORT="${PORT}" MARKER="${MARKER}" python3 -c '
import sys, json, os
port = int(os.environ["PORT"]); marker = os.environ["MARKER"]
sg = json.load(sys.stdin)["SecurityGroups"][0]
for p in sg.get("IpPermissions", []):
    if p.get("IpProtocol") == "tcp" and p.get("FromPort") == port and p.get("ToPort") == port:
        for r in p.get("IpRanges", []):
            if r.get("Description") == marker:
                print(r["CidrIp"])
')"
    for c in ${OLD}; do
      if [[ "${c}" == "${CIDR}" ]]; then
        continue   # our rule already points at the current IP — reported by the add-check below
      fi
      echo "  :${PORT} revoke old ${c}"
      run ec2 revoke-security-group-ingress --region "${REGION}" --group-id "${SG}" \
        --ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},IpRanges=[{CidrIp=${c}}]"
    done
    # Add the new rule unless it's already present with our marker.
    if printf '%s\n' ${OLD} | grep -qx "${CIDR}"; then
      echo "  :${PORT} already allows ${CIDR}"
      continue
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "  :${PORT} would allow ${CIDR} (desc=${MARKER})"
      continue
    fi
    # Capture stderr so a real failure is reported (only a Duplicate is treated as benign).
    err="$(aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${SG}" \
      --ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},IpRanges=[{CidrIp=${CIDR},Description=${MARKER}}]" \
      2>&1 >/dev/null || true)"
    if [[ -z "${err}" ]]; then
      echo "  :${PORT} allowed ${CIDR}"
    elif printf '%s' "${err}" | grep -q 'InvalidPermission.Duplicate'; then
      echo "  :${PORT} already allows ${CIDR}"
    else
      echo "  :${PORT} FAILED to allow ${CIDR}: ${err}" >&2
    fi
  done
done

echo "Done. SSH + Splunk Web (${PORTS_CSV}) now allow ${CIDR} on the GPU host and search head."
