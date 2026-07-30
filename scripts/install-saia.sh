#!/usr/bin/env bash
set -euo pipefail

# Install the Splunk AI Assistant (SAIA — app id Splunk_AI_Assistant_Cloud) onto the
# running cloud-env instances (GPU host + search head). Run from an aws-authenticated
# laptop. It uploads the package to the apps bucket (so future deploys install it too),
# then installs it on both instances via SSM and restarts Splunk.
#
#   ./scripts/install-saia.sh
#
# Overridable env: REGION, STACK (per-env main stack), APP_FILE (repo-relative),
#   RESOURCE_NAME_PREFIX, APPS_LICENSE_BUCKET (skip stack lookup if set).
#
# IMPORTANT: SAIA's Models/Agents features still require an ENABLED Splunk Cloud
# connection (a provisioned tenant). Installing the app is necessary but NOT sufficient
# — the Models tab will load its setup UI, but connecting still needs the tenant/quota
# resolved with the provisioning team.

REGION="${REGION:-ap-southeast-1}"
STACK="${STACK:-splunk-ai-cloud}"
PREFIX="${RESOURCE_NAME_PREFIX:-splunk-ai}"
APP_FILE="${APP_FILE:-apps/splunk-ai-assistant_220.tgz}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI required" >&2; exit 1; }
[[ -f "${REPO_ROOT}/${APP_FILE}" ]] || { echo "ERROR: not found: ${REPO_ROOT}/${APP_FILE}" >&2; exit 1; }

# Resolve the apps bucket (reuse if provided, else read the storage stack output).
APPS_BUCKET="${APPS_LICENSE_BUCKET:-}"
if [[ -z "${APPS_BUCKET}" ]]; then
  APPS_BUCKET="$(aws cloudformation describe-stacks --region "${REGION}" \
    --stack-name "${PREFIX}-foundation-storage" \
    --query "Stacks[0].Outputs[?OutputKey=='AppsLicenseBucketName'].OutputValue" --output text 2>/dev/null || true)"
fi
[[ -n "${APPS_BUCKET}" && "${APPS_BUCKET}" != "None" ]] || {
  echo "ERROR: could not resolve apps bucket; set APPS_LICENSE_BUCKET" >&2; exit 1; }

base="$(basename "${APP_FILE}")"

echo "== Staging ${base} to s3://${APPS_BUCKET}/splunk-apps/ =="
aws s3 cp "${REPO_ROOT}/${APP_FILE}" "s3://${APPS_BUCKET}/splunk-apps/${base}" --region "${REGION}"

resolve_instance() {  # <parent-stack-logical-id> <instance-logical-id>
  local nested
  nested="$(aws cloudformation describe-stack-resources --region "${REGION}" --stack-name "${STACK}" \
    --logical-resource-id "$1" --query "StackResources[0].PhysicalResourceId" --output text)"
  aws cloudformation describe-stack-resources --region "${REGION}" --stack-name "${nested}" \
    --logical-resource-id "$2" --query "StackResources[0].PhysicalResourceId" --output text
}

# SAIA + Cloud Connect belong ONLY on the GPU host (the "main" Splunk). The search head
# is a lean AI-command / proxy / token-metrics test client and must NOT get SAIA.
GPU_ID="$(resolve_instance GpuInstanceStack GpuInstance)"
echo "GPU (main, SAIA target)=${GPU_ID}"

# On-instance: pull the package from S3, install with -update, restart Splunk.
REMOTE=". /opt/splunk-ai/bootstrap.env 2>/dev/null; . /opt/splunk-ai/bootstrap.secrets.env 2>/dev/null; \
aws s3 cp s3://${APPS_BUCKET}/splunk-apps/${base} /tmp/${base} --region ${REGION} && \
/opt/splunk/bin/splunk install app /tmp/${base} -update 1 -auth admin:\$SPLUNK_ADMIN_PASSWORD && \
/opt/splunk/bin/splunk restart"

echo "== Installing SAIA on the GPU host via SSM (restarts Splunk ~1-2 min) =="
CMD="$(aws ssm send-command --region "${REGION}" --instance-ids "${GPU_ID}" \
  --document-name AWS-RunShellScript --comment "install Splunk_AI_Assistant_Cloud" \
  --parameters "{\"commands\":[$(printf '%s' "${REMOTE}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]}" \
  --query "Command.CommandId" --output text)"

echo "SSM command id: ${CMD}"
echo
echo "Watch status:  aws ssm list-command-invocations --region ${REGION} --command-id ${CMD} --details \\"
echo "                 --query 'CommandInvocations[].{Instance:InstanceId,Status:Status}' --output table"
echo
echo "NOTE: SAIA is now installed. Its Models/Agents features still need an ENABLED"
echo "Splunk Cloud connection (a provisioned tenant). Until that's resolved (tenant quota"
echo "with the provisioning team), the Models tab will load but can't connect."
