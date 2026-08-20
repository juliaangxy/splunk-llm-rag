#!/usr/bin/env bash
set -euo pipefail

# Run the SOC/SRE scenario ON the Splunk host via SSM, then fetch the report back to agents/reports/.
# Why a wrapper: run_scenario.py needs the Splunk MCP (:8089) AND HEC (:8088) as *localhost* — HEC
# isn't reachable off-box, so you can't fully run it (populate + invoke) from a laptop. This stages
# the script + datagen onto the host, runs it there, and downloads the timestamped report.
#
# Resolves automatically: the host by SplunkAiRole=gpu-host tag (or --instance-id); the MCP token +
# admin password from config/cloud.env (or --mcp-token / --admin-password); region from AWS_REGION
# (default ap-southeast-1). Extra args are passed through to run_scenario.py.
#
# Usage:
#   ./agents/run-scenario.sh                                  # populate + invoke all three, fetch report
#   ./agents/run-scenario.sh --mode playbook                 # SPL-only (no LLM)
#   ./agents/run-scenario.sh --duration-min 90 --skip-datagen
#   ./agents/run-scenario.sh --instance-id i-0abc... --region us-east-1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-ap-southeast-1}"
INSTANCE=""
MODE="aiagent"
MCP="${SplunkMCPToken:-}"
PW="${SPLUNK_ADMIN_PASSWORD:-}"
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --mcp-token) MCP="$2"; shift 2;;
    --admin-password) PW="$2"; shift 2;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) PASS+=("$1"); shift;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

env_get() { grep -E "^(export )?$1=" "${REPO}/config/cloud.env" 2>/dev/null | head -1 \
              | sed -E "s/^(export )?$1=//; s/^[\"']//; s/[\"']$//"; }
[[ -n "${MCP}" ]] || MCP="$(env_get SplunkMCPToken)"
[[ -n "${PW}"  ]] || PW="$(env_get SPLUNK_ADMIN_PASSWORD)"
[[ -n "${MCP}" && -n "${PW}" ]] || { echo "ERROR: need SplunkMCPToken + SPLUNK_ADMIN_PASSWORD (config/cloud.env or --mcp-token/--admin-password)" >&2; exit 1; }

if [[ -z "${INSTANCE}" ]]; then
  INSTANCE="$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:SplunkAiRole,Values=gpu-host" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
fi
[[ -n "${INSTANCE}" && "${INSTANCE}" != "None" ]] || { echo "ERROR: no running gpu-host found in ${REGION}; pass --instance-id" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/opt/agents/reports/scenario-report-${STAMP}.md"
LOCAL_OUT="${REPO}/agents/reports/scenario-report-${STAMP}.md"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
echo "[run-scenario] host=${INSTANCE} region=${REGION} mode=${MODE} -> ${OUT}"

# --- build the launch command (stage files + nohup run) -----------------------------------------
python3 - "${REPO}" "${MCP}" "${PW}" "${MODE}" "${OUT}" "${TMP}" "${PASS[@]:-}" <<'PY'
import base64, json, os, sys
repo, mcp, pw, mode, out, tmp = sys.argv[1:7]
extra = " ".join(a for a in sys.argv[7:] if a)
def b64f(p): return base64.b64encode(open(p, "rb").read()).decode()
files = {
    "/opt/agents/run_scenario.py":            "agents/run_scenario.py",
    "/opt/agents/datagen/datagen_common.py":  "scripts/datagen/datagen_common.py",
    "/opt/agents/datagen/security_datagen.py":"scripts/datagen/security_datagen.py",
    "/opt/agents/datagen/app_datagen.py":     "scripts/datagen/app_datagen.py",
    "/opt/agents/datagen/infra_datagen.py":   "scripts/datagen/infra_datagen.py",
}
writes = "\n".join("echo %s | base64 -d > %s" % (b64f(os.path.join(repo, s)), d) for d, s in files.items())
tmpl = (
    "set -e\n"
    "mkdir -p /opt/agents/datagen /opt/agents/reports\n"
    "{writes}\n"
    "MCP=$(echo {mcp}|base64 -d); PW=$(echo {pw}|base64 -d)\n"
    "cd /opt/agents\n"
    "rm -f /opt/agents/scenario.log\n"
    "nohup python3 run_scenario.py --mode {mode} --mcp-token \"$MCP\" --admin-password \"$PW\" "
    "--datagen-dir /opt/agents/datagen --out {out} {extra} > /opt/agents/scenario.log 2>&1 &\n"
    "echo launched PID $!\n"
).format(writes=writes, mcp=base64.b64encode(mcp.encode()).decode(),
         pw=base64.b64encode(pw.encode()).decode(), mode=mode, out=out, extra=extra)
json.dump({"commands": [tmpl]}, open(os.path.join(tmp, "launch.json"), "w"))
PY

CMD=$(aws ssm send-command --region "${REGION}" --instance-ids "${INSTANCE}" \
  --document-name AWS-RunShellScript --parameters file://"${TMP}/launch.json" \
  --timeout-seconds 120 --query 'Command.CommandId' --output text)
sleep 6
LAUNCH="$(aws ssm get-command-invocation --command-id "${CMD}" --instance-id "${INSTANCE}" \
  --region "${REGION}" --query 'StandardOutputContent' --output text 2>&1 || true)"
echo "[run-scenario] ${LAUNCH}"

# --- poll the log until the report is written ---------------------------------------------------
cat > "${TMP}/poll.json" <<'JSON'
{"commands":["tail -n 3 /opt/agents/scenario.log 2>/dev/null; grep -q Wrote /opt/agents/scenario.log 2>/dev/null && echo __DONE__ || true"]}
JSON
echo "[run-scenario] running (populate + invoke; ~2-8 min)…"
DONE=false
for i in $(seq 1 40); do
  sleep 20
  PC=$(aws ssm send-command --region "${REGION}" --instance-ids "${INSTANCE}" \
        --document-name AWS-RunShellScript --parameters file://"${TMP}/poll.json" \
        --timeout-seconds 40 --query 'Command.CommandId' --output text 2>/dev/null || true)
  [[ -n "${PC}" ]] || continue
  for _ in $(seq 1 8); do
    S=$(aws ssm list-command-invocations --command-id "${PC}" --instance-id "${INSTANCE}" \
          --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)
    [[ "${S}" == "Success" || "${S}" == "Failed" ]] && break; sleep 3
  done
  LOG=$(aws ssm get-command-invocation --command-id "${PC}" --instance-id "${INSTANCE}" \
         --region "${REGION}" --query 'StandardOutputContent' --output text 2>/dev/null || true)
  printf '  … %s\n' "$(printf '%s' "${LOG}" | grep -vE '__DONE__' | tail -n 1)"
  if printf '%s' "${LOG}" | grep -q '__DONE__'; then DONE=true; break; fi
done
${DONE} || { echo "ERROR: scenario didn't finish in time; check /opt/agents/scenario.log on ${INSTANCE}" >&2; exit 1; }

# --- surface the pre-invoke validation block from the host log ----------------------------------
cat > "${TMP}/vlog.json" <<'JSON'
{"commands":["sed -n '/validating agent configuration/,/invoking agents/p' /opt/agents/scenario.log 2>/dev/null | grep -v 'invoking agents'"]}
JSON
VC=$(aws ssm send-command --region "${REGION}" --instance-ids "${INSTANCE}" \
      --document-name AWS-RunShellScript --parameters file://"${TMP}/vlog.json" \
      --timeout-seconds 40 --query 'Command.CommandId' --output text 2>/dev/null || true)
if [[ -n "${VC}" ]]; then
  for _ in $(seq 1 10); do
    S=$(aws ssm list-command-invocations --command-id "${VC}" --instance-id "${INSTANCE}" \
          --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)
    [[ "${S}" == "Success" || "${S}" == "Failed" ]] && break; sleep 3
  done
  VOUT="$(aws ssm get-command-invocation --command-id "${VC}" --instance-id "${INSTANCE}" \
          --region "${REGION}" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  [[ -n "${VOUT}" ]] && { echo "[run-scenario] --- agent validation (from host log) ---"; printf '%s\n' "${VOUT}" | sed 's/^/  /'; }
fi

# --- fetch the report (gzip+base64 to survive the SSM stdout cap) --------------------------------
cat > "${TMP}/fetch.json" <<JSON
{"commands":["gzip -c ${OUT} | base64"]}
JSON
FC=$(aws ssm send-command --region "${REGION}" --instance-ids "${INSTANCE}" \
      --document-name AWS-RunShellScript --parameters file://"${TMP}/fetch.json" \
      --timeout-seconds 60 --query 'Command.CommandId' --output text)
for _ in $(seq 1 12); do
  S=$(aws ssm list-command-invocations --command-id "${FC}" --instance-id "${INSTANCE}" \
        --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)
  [[ "${S}" == "Success" || "${S}" == "Failed" ]] && break; sleep 3
done
mkdir -p "${REPO}/agents/reports"
aws ssm get-command-invocation --command-id "${FC}" --instance-id "${INSTANCE}" --region "${REGION}" \
  --query 'StandardOutputContent' --output text 2>/dev/null | tr -d '\n' | base64 -d | gunzip > "${LOCAL_OUT}"
echo "[run-scenario] report -> ${LOCAL_OUT} ($(wc -c < "${LOCAL_OUT}") bytes)"