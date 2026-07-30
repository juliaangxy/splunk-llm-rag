#!/usr/bin/env bash
set -euo pipefail

# Fetch deployment secrets from AWS Secrets Manager and materialize them into
# a root-only env file that common.sh overlays for every subsequent stage.
#
# The secret is a JSON object, e.g.:
#   { "SPLUNK_ADMIN_PASSWORD": "...", "SPLUNK_HEC_TOKEN": "...", "HF_TOKEN": "..." }
#
# Inputs (from bootstrap.env / user-data):
#   SECRETS_MANAGER_SECRET_ID   name or ARN of the secret (required for secret-backed runs)
#   CFN_REGION / AWS_REGION     region for the API call
#   BOOTSTRAP_SECRETS_FILE      output path (default /opt/splunk-ai/bootstrap.secrets.env)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

SECRETS_MANAGER_SECRET_ID="${SECRETS_MANAGER_SECRET_ID:-}"
SECRETS_REGION="${CFN_REGION:-${AWS_REGION:-}}"
OUTPUT_FILE="${BOOTSTRAP_SECRETS_FILE:-/opt/splunk-ai/bootstrap.secrets.env}"

if [[ -z "${SECRETS_MANAGER_SECRET_ID}" ]]; then
  warn "SECRETS_MANAGER_SECRET_ID is not set; skipping Secrets Manager fetch (relying on any inline env values)"
  exit 0
fi

require_cmd aws
require_cmd python3

if [[ -z "${SECRETS_REGION}" ]]; then
  error "Region is required to fetch secrets; set CFN_REGION or AWS_REGION"
  exit 1
fi

log "Fetching deployment secrets from Secrets Manager: ${SECRETS_MANAGER_SECRET_ID}"
secret_json="$(retry 5 6 aws secretsmanager get-secret-value \
  --secret-id "${SECRETS_MANAGER_SECRET_ID}" \
  --region "${SECRETS_REGION}" \
  --query SecretString --output text)"

# Render the JSON object into `export KEY='value'` lines. Keys must be shell-safe
# identifiers; values are single-quote escaped.
umask 077
: > "${OUTPUT_FILE}"
SECRET_JSON="${secret_json}" python3 - "${OUTPUT_FILE}" <<'PY'
import json
import os
import re
import sys

out_path = sys.argv[1]
data = json.loads(os.environ["SECRET_JSON"])
if not isinstance(data, dict):
    raise SystemExit("Secret payload must be a JSON object of KEY/value pairs")

ident = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
with open(out_path, "a", encoding="utf-8") as fh:
    for key, value in data.items():
        if not ident.match(str(key)):
            print(f"WARN: skipping non-identifier secret key: {key}", file=sys.stderr)
            continue
        safe = str(value).replace("'", "'\"'\"'")
        fh.write(f"export {key}='{safe}'\n")
PY

chmod 600 "${OUTPUT_FILE}"
log "Wrote $(grep -c '^export ' "${OUTPUT_FILE}" || echo 0) secret(s) to ${OUTPUT_FILE}"
