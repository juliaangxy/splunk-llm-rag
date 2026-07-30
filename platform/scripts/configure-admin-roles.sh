#!/usr/bin/env bash
set -euo pipefail

# Grant the DSDL/MLTK app roles to the admin role after the apps are installed, so the
# admin user can use DSDL containers, MLTK models, etc. without manual role edits.
# Idempotent: preserves admin's existing imported roles, only adds ones that actually
# exist (skips + warns on any that don't), and never fails the bootstrap.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
ADMIN_ROLE="${ADMIN_ROLE:-admin}"
# Roles the AITK (Splunk_ML_Toolkit) + DSDL apps define; override with ADMIN_EXTRA_ROLES.
ADMIN_EXTRA_ROLES="${ADMIN_EXTRA_ROLES:-dsdl_admin mltk_admin mltk_container_admin mltk_container_user mltk_dsdl_admin mltk_model_admin}"

if [[ ! -x "${SPLUNK_HOME}/bin/splunk" ]]; then
  warn "Splunk not present; skipping admin role configuration"
  exit 0
fi
require_env SPLUNK_ADMIN_PASSWORD
if ! wait_for_port 127.0.0.1 8089 300; then
  warn "Splunk mgmt port not up; skipping admin role configuration"
  exit 0
fi

log "Granting extra roles to '${ADMIN_ROLE}': ${ADMIN_EXTRA_ROLES}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER}" SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD}" \
ADMIN_ROLE="${ADMIN_ROLE}" ADMIN_EXTRA_ROLES="${ADMIN_EXTRA_ROLES}" \
python3 - <<'PY'
import os, sys, json, ssl, base64, urllib.request, urllib.parse

mgmt = "https://127.0.0.1:8089"
user = os.environ["SPLUNK_ADMIN_USER"]
pw = os.environ["SPLUNK_ADMIN_PASSWORD"]
admin_role = os.environ["ADMIN_ROLE"]
desired = os.environ["ADMIN_EXTRA_ROLES"].split()

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
auth = base64.b64encode(f"{user}:{pw}".encode()).decode()

def call(path, data=None):
    r = urllib.request.Request(mgmt + path, data=data, method=("POST" if data is not None else "GET"))
    r.add_header("Authorization", "Basic " + auth)
    return urllib.request.urlopen(r, context=ctx, timeout=30).read()

try:
    roles = json.loads(call("/services/authorization/roles?count=0&output_mode=json"))
    have = {e["name"] for e in roles.get("entry", [])}
    admin = json.loads(call(f"/services/authorization/roles/{admin_role}?output_mode=json"))
    cur = admin["entry"][0]["content"].get("imported_roles") or []
    if isinstance(cur, str):
        cur = [cur]
    add = [r for r in desired if r in have and r not in cur]
    missing = [r for r in desired if r not in have]
    if add:
        final = sorted(set(cur) | set(add))
        body = "&".join("imported_roles=" + urllib.parse.quote(r) for r in final).encode()
        call(f"/services/authorization/roles/{admin_role}", data=body)
        print("Updated admin imported_roles ->", final)
    else:
        print("Admin already imports the requested roles:", sorted(cur))
    if missing:
        print("WARNING: these roles were not found (app not installed or different name):",
              missing, file=sys.stderr)
except Exception as exc:  # never break bootstrap over a role tweak
    print(f"WARNING: could not update admin roles: {exc}", file=sys.stderr)
PY

log "Admin role configuration completed"
