#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

# In-place upgrade of the Splunk apps and (where it changes) the DSDL container
# image configuration. Intended for the CLOUD-connected environment, run on an
# instance (directly or via SSM). Scope: the AI Toolkit (AITK), DSDL, and
# Python for Scientific Computing (PSC) apps only.
#
# Flow:
#   0. (optional) Stage locally-held app packages (the repo apps/ dir) up to the S3 prefix, so
#      "drop a new .tgz/.spl in apps/ and upgrade" works end-to-end. Auto when the dir has
#      packages; forced with --stage, skipped with --no-stage.
#   1. For each app: pick the newest package from S3, compare its app.conf version to the INSTALLED
#      version, and install (-update 1) only if strictly newer (--force overrides). cloud-connect
#      is installed BEFORE aitk.
#   2. Read the upgraded DSDL app's default/images.conf to learn the image URIs it
#      now expects; compare to what this instance is currently configured to use.
#   3. For each CHANGED image: (GPU host) pull the new image from Docker Hub, push it
#      to ECR, re-pull it locally, and remove stale containers so the new image is used;
#      then rewrite mltk-container/local/images.conf to the new ECR references.
#   4. Reload/restart Splunk.
#
# cloud-connect (cc) is always installed BEFORE aitk — AITK depends on it — regardless of the
# order given in --apps; requesting aitk implicitly pulls in cc.
#
# Usage:
#   sudo ./upgrade-apps.sh [--apps cc,aitk,dsdl,psc] [--stage|--no-stage] [--apps-dir DIR] [--force] [--dry-run]
#
# Reads config from /opt/splunk-ai/bootstrap.env (+ secrets): LICENSE_BUCKET,
# SPLUNK_APPS_S3_PREFIX, ECR_REGISTRY_URI, ECR_REPOSITORY_NAME, AIRGAPPED, SPLUNK_*.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

APPS="cc,aitk,dsdl,psc"
DRY_RUN="false"
FORCE="false"       # reinstall even when the installed version is >= the candidate
STAGE_APPS="auto"   # auto = stage local apps/ when it has packages; yes = force; no = skip
LOCAL_APPS_DIR="${LOCAL_APPS_DIR:-${SCRIPT_DIR}/../apps}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apps) APPS="$2"; shift 2 ;;
    --stage) STAGE_APPS="yes"; shift ;;
    --no-stage) STAGE_APPS="no"; shift ;;
    --apps-dir) LOCAL_APPS_DIR="$2"; shift 2 ;;
    --force) FORCE="true"; shift ;;
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

# --- Execution context: on the Splunk VM, or outside it? ----------------------
# ON the VM (bootstrap, or a manual on-instance run) the apps are installed from S3 into the local
# Splunk. OUTSIDE the VM (a manual update from a repo checkout on your laptop) there is no local
# Splunk to install into — the job there is to STAGE the local apps/ up to S3, and the instances
# pick them up on their own upgrade/bootstrap. Detected by the on-instance markers bootstrap writes;
# override with RUN_CONTEXT=vm|local.
if [[ -n "${RUN_CONTEXT:-}" ]]; then
  [[ "${RUN_CONTEXT}" == "vm" ]] && ON_VM=true || ON_VM=false
elif [[ -f /opt/splunk-ai/bootstrap.env || -d "${SPLUNK_HOME}" ]]; then
  ON_VM=true
else
  ON_VM=false
fi

# Staging: auto => only OUTSIDE the VM (a manual update); --stage/--no-stage force it either way.
case "${STAGE_APPS}" in
  yes) DO_STAGE=true ;;
  no)  DO_STAGE=false ;;
  *)   [[ "${ON_VM}" == "true" ]] && DO_STAGE=false || DO_STAGE=true ;;
esac
DO_INSTALL="${ON_VM}"   # installing needs the local Splunk, so only on the VM

require_cmd aws
require_env LICENSE_BUCKET   # needed for both staging (target) and install (source)

if [[ "${DO_INSTALL}" == "true" ]]; then
  require_root
  mkdir -p "${WORK_DIR}"
  # Ensure we have the admin password (Secrets Manager), like the bootstrap does.
  if [[ -z "${SPLUNK_ADMIN_PASSWORD:-}" ]]; then
    bash "${SCRIPT_DIR}/fetch-secrets.sh" || true
    # shellcheck disable=SC1090
    [[ -f "${BOOTSTRAP_SECRETS_FILE}" ]] && { set -a; source "${BOOTSTRAP_SECRETS_FILE}"; set +a; }
  fi
  require_env SPLUNK_ADMIN_PASSWORD
fi

# Filename pattern for each in-scope app key. Function form (not an associative array) so the
# script also runs under the macOS system bash 3.2 — which matters for the local staging path.
app_pattern() {
  case "$1" in
    cc)   echo "splunk-cloud-connect" ;;
    aitk) echo "splunk-ai-toolkit" ;;
    dsdl) echo "splunk-app-for-data-science-and-deep-learning" ;;
    psc)  echo "python-for-scientific-computing" ;;
    *)    return 1 ;;
  esac
}
# Canonical install order — cloud-connect (cc) MUST precede aitk (AITK depends on it).
INSTALL_ORDER=(cc psc dsdl aitk)

normalize_prefix() {
  local p="$1"; [[ -n "$p" && "$p" != */ ]] && p="$p/"; echo "$p"
}

# Stage locally-held app packages (the repo apps/ dir) up to the S3 prefix before upgrading, so a
# fresh package dropped into apps/ becomes the newest key the upgrade then installs. Only real app
# packages are synced (README/.gitkeep excluded). Auto-skips when the dir is absent (e.g. running on
# an instance where only scripts/ are staged) unless --stage was given explicitly.
stage_local_apps() {
  if [[ ! -d "${LOCAL_APPS_DIR}" ]]; then
    warn "No local apps dir at ${LOCAL_APPS_DIR}; nothing to stage"
    return 0
  fi
  local found
  found="$(find "${LOCAL_APPS_DIR}" -maxdepth 1 -type f \
            \( -name '*.tgz' -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.spl' \) 2>/dev/null | head -1)"
  if [[ -z "${found}" ]]; then
    log "No app packages (*.tgz/*.tar/*.tar.gz/*.spl) in ${LOCAL_APPS_DIR}; nothing to stage"
    return 0
  fi
  local prefix; prefix="$(normalize_prefix "${SPLUNK_APPS_S3_PREFIX}")"
  log "Staging local apps ${LOCAL_APPS_DIR}/ -> s3://${LICENSE_BUCKET}/${prefix}"
  local includes=(--exclude '*' --include '*.tgz' --include '*.tar' --include '*.tar.gz' --include '*.spl')
  if [[ "${DRY_RUN}" == "true" ]]; then
    aws s3 cp "${LOCAL_APPS_DIR}/" "s3://${LICENSE_BUCKET}/${prefix}" --recursive --dryrun "${includes[@]}"
    return 0
  fi
  retry 3 5 aws s3 cp "${LOCAL_APPS_DIR}/" "s3://${LICENSE_BUCKET}/${prefix}" --recursive --only-show-errors "${includes[@]}"
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

# Read an app version from an app.conf: prefer [launcher] version, else the first version= found.
app_conf_version() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  awk '
    /^\[/{sec=$0}
    /^[[:space:]]*version[[:space:]]*=/{
      v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/[[:space:]]/,"",v)
      if (sec=="[launcher]" && v!="") {print v; done=1; exit}
      if (first=="") first=v
    }
    END{ if (!done && first!="") print first }   # exit runs END, so guard against a double print
  ' "$f"
}

# Installed version of an app id (local/app.conf overrides default/app.conf). Empty if absent.
installed_app_version() {
  local app_id="$1" v
  v="$(app_conf_version "${SPLUNK_HOME}/etc/apps/${app_id}/local/app.conf" 2>/dev/null || true)"
  [[ -z "$v" ]] && v="$(app_conf_version "${SPLUNK_HOME}/etc/apps/${app_id}/default/app.conf" 2>/dev/null || true)"
  echo "$v"
}

# From a package tarball, echo "<app_id>\t<version>" (app_id = the archive's top-level dir).
package_id_and_version() {
  local pkg="$1" tmp top ver
  top="$(tar -tf "$pkg" 2>/dev/null | sed 's#^\./##; /^$/d' | grep -m1 -oE '^[^/]+' || true)"
  [[ -z "$top" ]] && return 1
  tmp="$(mktemp -d)"
  tar -xf "$pkg" -C "$tmp" "${top}/local/app.conf" 2>/dev/null || true
  tar -xf "$pkg" -C "$tmp" "${top}/default/app.conf" 2>/dev/null || true
  ver="$(app_conf_version "${tmp}/${top}/local/app.conf" 2>/dev/null || true)"
  [[ -z "$ver" ]] && ver="$(app_conf_version "${tmp}/${top}/default/app.conf" 2>/dev/null || true)"
  rm -rf "$tmp"
  printf '%s\t%s\n' "$top" "$ver"
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

  # Version gate: compare the candidate package's app.conf version to what's installed, and skip
  # unless it's strictly newer (override with --force). Derives the app id from the package itself.
  local id_ver app_id cand_ver cur_ver newest
  id_ver="$(package_id_and_version "${install_target}" 2>/dev/null || true)"
  app_id="${id_ver%%$'\t'*}"; cand_ver="${id_ver#*$'\t'}"
  if [[ -n "${app_id}" ]]; then
    cur_ver="$(installed_app_version "${app_id}")"
    log "${app_id}: installed=${cur_ver:-none} candidate=${cand_ver:-unknown}"
    if [[ "${FORCE}" != "true" && -n "${cur_ver}" && -n "${cand_ver}" ]]; then
      newest="$(printf '%s\n%s\n' "${cur_ver}" "${cand_ver}" | sort -V | tail -n1)"
      if [[ "${newest}" == "${cur_ver}" ]]; then
        log "${app_id}: installed ${cur_ver} is >= candidate ${cand_ver}; skipping (use --force to reinstall)"
        return 2   # 2 = skipped (up-to-date); the caller uses this to NOT trigger post-install work
      fi
    fi
  else
    warn "Could not determine app id/version from $(basename "${s3_key}"); proceeding without version gate"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] would: splunk install app ${install_target} -update 1 (${app_id:-app} ${cur_ver:-none} -> ${cand_ver:-candidate})"
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
  local dsdl_changed=0 app key pattern raw rc
  # Parse --apps into a space-delimited membership set (portable; no associative arrays).
  local want=" "
  IFS=',' read -r -a raw <<< "${APPS}"
  for app in "${raw[@]}"; do
    app="$(echo "${app}" | tr -d '[:space:]')"
    [[ -z "${app}" ]] && continue
    if ! app_pattern "${app}" >/dev/null 2>&1; then warn "Unknown app '${app}'; skipping"; continue; fi
    case "${want}" in *" ${app} "*) : ;; *) want="${want}${app} " ;; esac
  done
  # AITK depends on cloud-connect — guarantee cc is present (order is set by INSTALL_ORDER below).
  case "${want}" in
    *" aitk "*)
      case "${want}" in
        *" cc "*) : ;;
        *) log "aitk requested without cc; adding cloud-connect so it installs BEFORE aitk"; want="${want}cc " ;;
      esac ;;
  esac
  # Install in canonical order (cc first, aitk last), regardless of --apps ordering.
  for app in "${INSTALL_ORDER[@]}"; do
    case "${want}" in *" ${app} "*) : ;; *) continue ;; esac
    pattern="$(app_pattern "${app}")"
    key="$(newest_key_for_pattern "${pattern}")"
    if [[ -z "${key}" ]]; then
      warn "No package found for ${app} (pattern ${pattern}) under s3://${LICENSE_BUCKET}/${SPLUNK_APPS_S3_PREFIX}"
      continue
    fi
    log "Upgrading ${app} -> ${key}"
    rc=0; install_app_key "${key}" || rc=$?
    # Post-install work ONLY when the app was actually (re)installed (rc 0), not skipped (2)/failed (1).
    if [[ ${rc} -eq 0 ]]; then
      [[ "${app}" == "dsdl" ]] && dsdl_changed=1
      [[ "${app}" == "aitk" ]] && aitk_restore_agents_nav
    fi
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
  python3 "${SCRIPT_DIR}/dsdl/dsdl_images_conf_to_manifest.py" "${DEFAULT_IMAGES_CONF}" > "${manifest}"

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
  python3 "${SCRIPT_DIR}/dsdl/generate_default_images_conf.py"
  if id -u splunk >/dev/null 2>&1; then chown splunk:splunk "${LOCAL_IMAGES_CONF}"; fi
  chmod 0644 "${LOCAL_IMAGES_CONF}"
}

log "Starting app upgrade (context=$([[ ${ON_VM} == true ]] && echo VM || echo local), stage=${DO_STAGE}, install=${DO_INSTALL}, apps=${APPS}, dry_run=${DRY_RUN})"

if [[ "${DO_STAGE}" == "true" ]]; then
  stage_local_apps
fi

# Outside the VM there's no local Splunk to install into: staging is the whole job, so stop here.
if [[ "${DO_INSTALL}" != "true" ]]; then
  log "Ran outside the VM: local apps staged to S3 (if any). The instances install them on their next upgrade/bootstrap."
  log "To install now, run this on each instance (directly or via SSM), or re-run bootstrap."
  log "App upgrade (stage-only) completed"
  exit 0
fi

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
