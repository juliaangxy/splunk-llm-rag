#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

# In-place upgrade of the Splunk apps and (where it changes) the DSDL container
# image configuration. Intended for the CLOUD-connected environment, run on an
# instance (directly or via SSM). Scope: the AI Toolkit (AITK), DSDL, and
# Python for Scientific Computing (PSC) apps only.
#
# Flow:
#   1. Install the newest matching app package(s) from S3 (-update 1).
#   2. Read the upgraded DSDL app's default/images.conf to learn the image URIs it
#      now expects; compare to what this instance is currently configured to use.
#   3. For each CHANGED image: (GPU host) pull the new image from Docker Hub, push it
#      to ECR, re-pull it locally, and remove stale containers so the new image is used;
#      then rewrite mltk-container/local/images.conf to the new ECR references.
#   4. Reload/restart Splunk.
#
# Usage:
#   sudo ./upgrade-apps.sh [--apps aitk,dsdl,psc] [--dry-run]
#
# Reads config from /opt/splunk-ai/bootstrap.env (+ secrets): LICENSE_BUCKET,
# SPLUNK_APPS_S3_PREFIX, ECR_REGISTRY_URI, ECR_REPOSITORY_NAME, AIRGAPPED, SPLUNK_*.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

APPS="aitk,dsdl,psc"
DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apps) APPS="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
LICENSE_BUCKET="${LICENSE_BUCKET:-}"
SPLUNK_APPS_S3_PREFIX="${SPLUNK_APPS_S3_PREFIX:-splunk-apps/}"
ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}"
DEFAULT_IMAGES_CONF="${SPLUNK_HOME}/etc/apps/mltk-container/default/images.conf"
LOCAL_IMAGES_CONF="${SPLUNK_HOME}/etc/apps/mltk-container/local/images.conf"
WORK_DIR="/opt/splunk-ai/upgrade"
mkdir -p "${WORK_DIR}"

# Ensure we have the admin password (Secrets Manager), like the bootstrap does.
if [[ -z "${SPLUNK_ADMIN_PASSWORD:-}" ]]; then
  bash "${SCRIPT_DIR}/fetch-secrets.sh" || true
  # shellcheck disable=SC1090
  [[ -f "${BOOTSTRAP_SECRETS_FILE}" ]] && { set -a; source "${BOOTSTRAP_SECRETS_FILE}"; set +a; }
fi

require_env LICENSE_BUCKET
require_env SPLUNK_ADMIN_PASSWORD
require_cmd aws

# Filename patterns for the in-scope apps.
declare -A APP_PATTERN=(
  [aitk]="splunk-ai-toolkit"
  [dsdl]="splunk-app-for-data-science-and-deep-learning"
  [psc]="python-for-scientific-computing"
)

normalize_prefix() {
  local p="$1"; [[ -n "$p" && "$p" != */ ]] && p="$p/"; echo "$p"
}

newest_key_for_pattern() {
  # List keys under the prefix matching a pattern; return the version-sorted newest.
  local pattern="$1" prefix
  prefix="$(normalize_prefix "${SPLUNK_APPS_S3_PREFIX}")"
  aws s3api list-objects-v2 --bucket "${LICENSE_BUCKET}" --prefix "${prefix}" \
    --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^None$/d' \
    | grep -Ei "${pattern}.*\.(tgz|tar|tar\.gz|spl)$" \
    | sort -V | tail -n1 || true
}

install_app_key() {
  local s3_key="$1" dest install_target
  dest="${WORK_DIR}/$(basename "${s3_key}")"
  log "Downloading s3://${LICENSE_BUCKET}/${s3_key}"
  retry 5 10 aws s3 cp --only-show-errors "s3://${LICENSE_BUCKET}/${s3_key}" "${dest}"
  install_target="${dest}"
  if [[ "${dest}" == *.spl ]]; then
    install_target="${dest%.spl}.tgz"; cp -f "${dest}" "${install_target}"
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] would: splunk install app ${install_target} -update 1"
    return 0
  fi
  if splunk_run install app "${install_target}" -update 1; then
    log "Updated app from $(basename "${s3_key}")"
  else
    warn "Failed to update app from $(basename "${s3_key}")"
    return 1
  fi
}

# AITK (Splunk_ML_Toolkit) v6 adds the Agents tab via default/data/ui/nav/default.xml.
# A stale local nav override from an older AITK version FULLY replaces that nav (Splunk
# nav is not merged), which hides the Agents tab after upgrade. Move it aside (backup,
# not hard-delete) so the v6 default nav — with Agents — takes effect.
aitk_restore_agents_nav() {
  local app_id="${AITK_APP_ID:-Splunk_ML_Toolkit}"
  local nav="${SPLUNK_HOME}/etc/apps/${app_id}/local/data/ui/nav/default.xml"
  if [[ ! -f "${nav}" ]]; then
    log "No AITK local nav override found (${nav}); nothing to clean up"
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] would back up stale AITK local nav override: ${nav}"
    return 0
  fi
  local ts; ts="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo bak)"
  mv "${nav}" "${nav}.pre-v6-${ts}.bak"
  if id -u splunk >/dev/null 2>&1; then chown splunk:splunk "${nav}.pre-v6-${ts}.bak" 2>/dev/null || true; fi
  log "Removed stale AITK local nav override (backed up to ${nav}.pre-v6-${ts}.bak)"

  # Reload the app so the nav change takes effect now. Note: `splunk reload app` is NOT a
  # valid CLI command; the correct path is the app _reload REST endpoint.
  if splunk_run _internal call "/services/apps/local/${app_id}/_reload" -method POST >/dev/null 2>&1; then
    log "Reloaded ${app_id}; Agents tab restored"
  else
    warn "Could not reload ${app_id} via REST; the Agents tab will appear after the Splunk restart at the end of this run"
  fi
}

upgrade_selected_apps() {
  local dsdl_changed=0 app key
  IFS=',' read -r -a wanted <<< "${APPS}"
  for app in "${wanted[@]}"; do
    app="$(echo "${app}" | tr -d '[:space:]')"
    local pattern="${APP_PATTERN[${app}]:-}"
    if [[ -z "${pattern}" ]]; then warn "Unknown app '${app}'; skipping"; continue; fi
    key="$(newest_key_for_pattern "${pattern}")"
    if [[ -z "${key}" ]]; then
      warn "No package found for ${app} (pattern ${pattern}) under s3://${LICENSE_BUCKET}/${SPLUNK_APPS_S3_PREFIX}"
      continue
    fi
    log "Upgrading ${app} -> ${key}"
    install_app_key "${key}" || true
    [[ "${app}" == "dsdl" ]] && dsdl_changed=1
    [[ "${app}" == "aitk" ]] && aitk_restore_agents_nav
  done
  return $dsdl_changed
}

# --- Container image reconciliation ---------------------------------------

current_local_image_refs() {
  # repo+image lines from the current local/images.conf (empty if none).
  [[ -f "${LOCAL_IMAGES_CONF}" ]] || return 0
  awk '
    /^\[/{repo="";img=""}
    /^[[:space:]]*repo[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");repo=$0}
    /^[[:space:]]*image[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");img=$0; if(img!="") print repo img}
  ' "${LOCAL_IMAGES_CONF}" | sort -u
}

reconcile_dsdl_images() {
  if [[ ! -f "${DEFAULT_IMAGES_CONF}" ]]; then
    warn "DSDL default images.conf not found at ${DEFAULT_IMAGES_CONF}; skipping image reconciliation"
    return 0
  fi
  if [[ -z "${ECR_REGISTRY_URI}" || -z "${ECR_REPOSITORY_NAME}" ]]; then
    warn "ECR registry/repo not configured; skipping image reconciliation"
    return 0
  fi
  require_cmd python3

  local manifest="${WORK_DIR}/dsdl-images-current.json"
  log "Deriving expected image set from upgraded DSDL app"
  python3 "${SCRIPT_DIR}/dsdl_images_conf_to_manifest.py" "${DEFAULT_IMAGES_CONF}" > "${manifest}"

  # Desired ECR refs from the manifest.
  local repo_uri="${ECR_REGISTRY_URI}/${ECR_REPOSITORY_NAME}"
  mapfile -t desired < <(jq -r --arg r "${repo_uri}" '.images[] | ($r + ":" + .ecr_tag)' "${manifest}" | sort -u)

  # What the instance currently references.
  mapfile -t current < <(current_local_image_refs)
  local before="${WORK_DIR}/refs.before"; printf '%s\n' "${current[@]:-}" | sort -u > "${before}"
  local after="${WORK_DIR}/refs.after";   printf '%s\n' "${desired[@]}"     | sort -u > "${after}"

  mapfile -t changed < <(comm -13 "${before}" "${after}")
  if [[ "${#changed[@]}" -eq 0 ]]; then
    log "No container image URI changes detected; configuration already current"
  else
    log "Detected ${#changed[@]} new/changed container image URI(s):"
    printf '  %s\n' "${changed[@]}"
  fi

  local has_docker=0
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && has_docker=1

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] would push new tags to ECR, rewrite local/images.conf, and (GPU host) re-pull/recreate"
    return 0
  fi

  # Push any changed images to ECR and re-pull them (GPU host only has a live dockerd).
  if [[ "${has_docker}" -eq 1 && "${#changed[@]}" -gt 0 ]]; then
    while IFS= read -r line; do
      # line: <stanza>\t<source>\t<ecr_tag>
      local stanza source ecr_tag target
      stanza="$(cut -f1 <<<"$line")"; source="$(cut -f2 <<<"$line")"; ecr_tag="$(cut -f3 <<<"$line")"
      target="${repo_uri}:${ecr_tag}"
      # Only act on images whose target ref is in the changed set.
      printf '%s\n' "${changed[@]}" | grep -qxF "${target}" || continue

      if is_airgapped; then
        log "Airgapped: expecting ${target} to be pre-seeded in ECR; pulling from ECR only"
      else
        log "Pulling ${source} from Docker Hub and pushing ${target}"
        ecr_login_for_image "${target}"
        retry 5 6 docker pull "${source}"
        docker tag "${source}" "${target}"
        retry 5 6 docker push "${target}"
      fi

      # Re-pull the (new) image locally and remove containers still on the old image.
      ensure_image "${target}"
      local old_ref
      while IFS= read -r old_ref; do
        [[ -n "${old_ref}" ]] || continue
        # old refs that share the same repo path but differ by tag = superseded
        if [[ "${old_ref%%:*}" == "${target%%:*}" && "${old_ref}" != "${target}" ]]; then
          local cids
          cids="$(docker ps -aq --filter "ancestor=${old_ref}" 2>/dev/null || true)"
          if [[ -n "${cids}" ]]; then
            log "Removing stale container(s) on ${old_ref} so ${target} is used"
            docker rm -f ${cids} >/dev/null 2>&1 || true
          fi
        fi
      done < "${before}"
    done < <(jq -r '.images[] | [.stanza, .source, .ecr_tag] | @tsv' "${manifest}")
  elif [[ "${#changed[@]}" -gt 0 ]]; then
    log "No local dockerd (search head); updating image configuration only (GPU host performs the re-pull)"
  fi

  # Rewrite local/images.conf to the reconciled ECR references (idempotent).
  log "Rewriting ${LOCAL_IMAGES_CONF} to reconciled ECR references"
  ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME}" \
  DSDL_IMAGES_MANIFEST="${manifest}" IMAGES_CONF_PATH="${LOCAL_IMAGES_CONF}" \
  python3 "${SCRIPT_DIR}/generate_default_images_conf.py"
  if id -u splunk >/dev/null 2>&1; then chown splunk:splunk "${LOCAL_IMAGES_CONF}"; fi
  chmod 0644 "${LOCAL_IMAGES_CONF}"
}

log "Starting app upgrade (apps=${APPS}, dry_run=${DRY_RUN})"
set +e; upgrade_selected_apps; dsdl_upgraded=$?; set -e

if [[ "${dsdl_upgraded}" -eq 1 ]]; then
  log "DSDL was upgraded; reconciling container images"
  reconcile_dsdl_images
else
  log "DSDL not in scope/updated; skipping container image reconciliation"
fi

if [[ "${DRY_RUN}" != "true" && -x "${SPLUNK_HOME}/bin/splunk" ]]; then
  ensure_splunk_restart_required_change_health_non_interactive \
    "Splunk is running after app upgrade; reloading before any full restart" \
    "Splunk is not running after app upgrade; issuing start"
fi

log "App upgrade completed"
