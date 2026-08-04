#!/usr/bin/env bash
set -euo pipefail

# Create an Amazon Bedrock Knowledge Base backed by Amazon S3 Vectors and ingest documents from
# an S3 prefix (default: the synthetic incident case notes at s3://ai-splunk-ai-bucket/kb-documents/).
#
# It provisions, idempotently:
#   1. an S3 Vectors bucket + vector index (dimension matched to the embedding model),
#   2. an IAM role the KB assumes (embed model + read docs + vector access),
#   3. the Bedrock Knowledge Base (S3_VECTORS storage),
#   4. an S3 data source, then starts + waits on an ingestion job.
#
# Runs two ways:
#   * At BOOTSTRAP — toggled stage; no-ops unless CREATE_BEDROCK_KB=true. NOTE: the caller's role
#                    then needs iam/s3vectors/bedrock/s3 permissions (heavy) — usually easier to
#                    run this MANUALLY with admin credentials, like the S3 upload step.
#   * MANUALLY     — run directly with flags/config any time.
#
# Usage:
#   ./setup-bedrock-kb.sh [--config myconf.env] [--region us-east-1] \
#     [--kb-name splunk-ai-kb] [--data-s3-uri s3://bucket/prefix/] \
#     [--stage-dir ./kb-documents | --no-stage] [--source-s3-uri s3://src/prefix/] \
#     [--embed-model amazon.titan-embed-text-v2:0] [--embed-dim 1024] \
#     [--vector-bucket splunk-ai-kb-vectors] [--vector-index splunk-ai-kb-index] \
#     [--kb-role-arn arn:...:role/xyz] [--dry-run]
#
# "Bring your own config": pass --config <file> (a shell env file) and/or any flag/env below to
# override every default.
#
# NOTE on region + model: Bedrock reads the data source from a bucket in the KB's OWN region, and
# the embedding model must exist in that region (and be allowed by any org SCP). --source-s3-uri
# copies docs from another bucket/region into --data-s3-uri first. Example: an SCP that blocks
# Cohere but allows Titan means using a Titan region like us-east-1 (Titan isn't in ap-southeast-1).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# --- Toggle: no-op at bootstrap unless enabled; a manual run (any flag) always runs.
ENABLED="${CREATE_BEDROCK_KB:-false}"
[[ $# -gt 0 ]] && ENABLED=true
if [[ "${ENABLED}" != "true" ]]; then
  log "setup-bedrock-kb: disabled (set CREATE_BEDROCK_KB=true or pass flags); skipping"
  exit 0
fi

# --- Optional config file (sourced first so flags below can still override) ---
DRY_RUN=false
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [[ "${ARGS[$i]}" == "--config" ]]; then
    cfg="${ARGS[$((i+1))]:-}"
    [[ -f "${cfg}" ]] || { error "--config file not found: ${cfg}"; exit 2; }
    # shellcheck disable=SC1090
    source "${cfg}"; log "loaded config ${cfg}"
  fi
done

# --- Defaults (override via env, --config, or flags) ---
REGION="${REGION:-${AWS_REGION:-ap-southeast-1}}"
KB_NAME="${KB_NAME:-splunk-ai-kb}"
DATA_S3_URI="${DATA_S3_URI:-s3://ai-splunk-ai-bucket/kb-documents/}"
SOURCE_S3_URI="${SOURCE_S3_URI:-}"   # optional: sync docs from another S3 prefix into DATA_S3_URI
# Local dir staged (uploaded) into DATA_S3_URI before ingestion. Defaults to the repo's
# kb-documents/ so the version-controlled case notes are the source of truth. '' disables.
STAGE_DIR="${STAGE_DIR:-${SCRIPT_DIR}/../../kb-documents}"
EMBED_MODEL="${EMBED_MODEL:-amazon.titan-embed-text-v2:0}"
EMBED_DIM="${EMBED_DIM:-1024}"
VECTOR_BUCKET="${VECTOR_BUCKET:-splunk-ai-kb-vectors}"
VECTOR_INDEX="${VECTOR_INDEX:-splunk-ai-kb-index}"
DATA_SOURCE_NAME="${DATA_SOURCE_NAME:-s3-kb-documents}"
KB_ROLE_ARN="${KB_ROLE_ARN:-}"
KB_ROLE_NAME="${KB_ROLE_NAME:-bedrock-kb-${KB_NAME}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)         shift 2;;                 # already handled above
    --region)         REGION="$2"; shift 2;;
    --kb-name)        KB_NAME="$2"; shift 2;;
    --data-s3-uri)    DATA_S3_URI="$2"; shift 2;;
    --source-s3-uri)  SOURCE_S3_URI="$2"; shift 2;;
    --stage-dir)      STAGE_DIR="$2"; shift 2;;
    --no-stage)       STAGE_DIR=""; shift;;
    --embed-model)    EMBED_MODEL="$2"; shift 2;;
    --embed-dim)      EMBED_DIM="$2"; shift 2;;
    --vector-bucket)  VECTOR_BUCKET="$2"; shift 2;;
    --vector-index)   VECTOR_INDEX="$2"; shift 2;;
    --kb-role-arn)    KB_ROLE_ARN="$2"; shift 2;;
    --data-source-name) DATA_SOURCE_NAME="$2"; shift 2;;
    --dry-run)        DRY_RUN=true; shift;;
    -h|--help)        sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

require_cmd aws

# aws wrapper that respects --dry-run and always targets the chosen region.
awsr() { if $DRY_RUN; then echo "  DRYRUN: aws $*"; else aws --region "${REGION}" "$@"; fi; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
  if $DRY_RUN; then ACCOUNT_ID="<ACCOUNT_ID>"; else error "cannot resolve AWS account — are your credentials valid?"; exit 1; fi
fi
PARTITION="aws"
EMBED_MODEL_ARN="arn:${PARTITION}:bedrock:${REGION}::foundation-model/${EMBED_MODEL}"

# Parse the S3 URI into bucket + inclusion prefix.
_uri="${DATA_S3_URI#s3://}"
DATA_BUCKET="${_uri%%/*}"
DATA_PREFIX="${_uri#"${DATA_BUCKET}"}"; DATA_PREFIX="${DATA_PREFIX#/}"
log "KB '${KB_NAME}' in ${REGION} | docs=s3://${DATA_BUCKET}/${DATA_PREFIX} | embed=${EMBED_MODEL}(${EMBED_DIM}) | vectors=${VECTOR_BUCKET}/${VECTOR_INDEX}"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 0) Docs bucket: ensure it exists in the KB region, optionally sync, and NEVER ingest 0 --
#        docs silently (a missing/empty bucket previously produced an empty KB with no error).
_stage_dir=""
[[ -n "${STAGE_DIR}" && -d "${STAGE_DIR}" ]] && _stage_dir="$(cd "${STAGE_DIR}" && pwd)"
if $DRY_RUN; then
  echo "  DRYRUN: ensure docs bucket ${DATA_BUCKET} in ${REGION}${_stage_dir:+ + stage ${_stage_dir}}${SOURCE_S3_URI:+ + sync from ${SOURCE_S3_URI}}"
else
  if ! aws s3api head-bucket --bucket "${DATA_BUCKET}" >/dev/null 2>&1; then
    log "Creating docs bucket s3://${DATA_BUCKET} in ${REGION}"
    if [[ "${REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${DATA_BUCKET}" --region "${REGION}" >/dev/null 2>&1 || true
    else
      aws s3api create-bucket --bucket "${DATA_BUCKET}" --region "${REGION}" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null 2>&1 || true
    fi
  fi
  # Stage the version-controlled local case notes into the KB's docs bucket. Only the incident
  # notes (INC-*.md) go up — README.md and any other files are excluded so the KB isn't polluted.
  if [[ -n "${_stage_dir}" ]]; then
    log "Staging local docs ${_stage_dir}/ -> ${DATA_S3_URI}"
    aws s3 sync "${_stage_dir}/" "${DATA_S3_URI}" --exclude "*" --include "INC-*.md" >/dev/null
  elif [[ -n "${STAGE_DIR}" ]]; then
    warn "stage dir '${STAGE_DIR}' not found; skipping local staging"
  fi
  if [[ -n "${SOURCE_S3_URI}" ]]; then
    log "Syncing docs ${SOURCE_S3_URI} -> ${DATA_S3_URI}"
    aws s3 sync "${SOURCE_S3_URI}" "${DATA_S3_URI}" >/dev/null
  fi
  # Warn if the docs bucket is in a different region than the KB (Bedrock wants same-region docs).
  _bregion="$(aws s3api get-bucket-location --bucket "${DATA_BUCKET}" --query 'LocationConstraint' --output text 2>/dev/null || true)"
  [[ -z "${_bregion}" || "${_bregion}" == "None" ]] && _bregion="us-east-1"
  [[ "${_bregion}" != "${REGION}" ]] && warn "docs bucket ${DATA_BUCKET} is in ${_bregion}, not the KB region ${REGION}; use --source-s3-uri to copy into a ${REGION} bucket"
  # Fail loudly on an empty prefix instead of ingesting nothing.
  _ndocs="$(aws s3 ls "s3://${DATA_BUCKET}/${DATA_PREFIX}" --recursive 2>/dev/null | grep -c . || true)"
  if [[ "${_ndocs}" == "0" ]]; then
    error "no documents found at ${DATA_S3_URI} — nothing to ingest (pass --source-s3-uri to populate it)"
    exit 1
  fi
  log "  ${_ndocs} object(s) under ${DATA_S3_URI}"
fi

# --- 1) S3 Vectors bucket + index ---------------------------------------------------------
log "Ensuring S3 Vectors bucket + index"
awsr s3vectors create-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" >/dev/null 2>&1 \
  || log "  vector bucket exists (or dry-run)"
# Bedrock stores the chunk text in metadata; keep it non-filterable per the S3 Vectors integration.
awsr s3vectors create-index --vector-bucket-name "${VECTOR_BUCKET}" --index-name "${VECTOR_INDEX}" \
  --data-type float32 --dimension "${EMBED_DIM}" --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT"]}' >/dev/null 2>&1 \
  || log "  vector index exists (or dry-run)"

if $DRY_RUN; then
  VECTOR_BUCKET_ARN="arn:${PARTITION}:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}"
  VECTOR_INDEX_ARN="${VECTOR_BUCKET_ARN}/index/${VECTOR_INDEX}"
else
  VECTOR_BUCKET_ARN="$(aws --region "${REGION}" s3vectors get-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" \
    --query 'vectorBucket.vectorBucketArn' --output text)"
  VECTOR_INDEX_ARN="$(aws --region "${REGION}" s3vectors get-index --vector-bucket-name "${VECTOR_BUCKET}" \
    --index-name "${VECTOR_INDEX}" --query 'index.indexArn' --output text)"
fi
log "  vectorBucketArn=${VECTOR_BUCKET_ARN}"
log "  indexArn=${VECTOR_INDEX_ARN}"

# --- 2) IAM role the KB assumes (unless one was supplied) ---------------------------------
if [[ -z "${KB_ROLE_ARN}" ]]; then
  log "Ensuring IAM role ${KB_ROLE_NAME}"
  cat > "${WORK}/trust.json" <<JSON
{ "Version": "2012-10-17", "Statement": [{
    "Effect": "Allow", "Principal": {"Service": "bedrock.amazonaws.com"}, "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "${ACCOUNT_ID}"},
      "ArnLike": {"aws:SourceArn": "arn:${PARTITION}:bedrock:*:${ACCOUNT_ID}:knowledge-base/*"}
    }}]}
JSON
  cat > "${WORK}/perms.json" <<JSON
{ "Version": "2012-10-17", "Statement": [
    {"Sid": "Embed", "Effect": "Allow", "Action": ["bedrock:InvokeModel"], "Resource": "${EMBED_MODEL_ARN}"},
    {"Sid": "ReadDocs", "Effect": "Allow", "Action": ["s3:GetObject", "s3:ListBucket"],
     "Resource": ["arn:${PARTITION}:s3:::${DATA_BUCKET}", "arn:${PARTITION}:s3:::${DATA_BUCKET}/*"],
     "Condition": {"StringEquals": {"aws:ResourceAccount": "${ACCOUNT_ID}"}}},
    {"Sid": "Vectors", "Effect": "Allow",
     "Action": ["s3vectors:GetIndex", "s3vectors:QueryVectors", "s3vectors:PutVectors",
                "s3vectors:GetVectors", "s3vectors:ListVectors", "s3vectors:DeleteVectors"],
     "Resource": ["${VECTOR_BUCKET_ARN}", "${VECTOR_BUCKET_ARN}/*"]}
  ]}
JSON
  awsr iam create-role --role-name "${KB_ROLE_NAME}" \
    --assume-role-policy-document "file://${WORK}/trust.json" >/dev/null 2>&1 \
    || log "  role exists (or dry-run)"
  # Refresh the trust policy on reuse too — create-role is a no-op if the role already exists, so
  # a role first made in another region would otherwise keep a stale region-scoped SourceArn.
  awsr iam update-assume-role-policy --role-name "${KB_ROLE_NAME}" \
    --policy-document "file://${WORK}/trust.json" >/dev/null 2>&1 || true
  awsr iam put-role-policy --role-name "${KB_ROLE_NAME}" --policy-name kb-access \
    --policy-document "file://${WORK}/perms.json" >/dev/null 2>&1 || true
  if $DRY_RUN; then
    KB_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${KB_ROLE_NAME}"
  else
    KB_ROLE_ARN="$(aws iam get-role --role-name "${KB_ROLE_NAME}" --query 'Role.Arn' --output text)"
    log "  waiting 15s for IAM role propagation"; sleep 15
  fi
fi
log "  roleArn=${KB_ROLE_ARN}"

# --- 3) Knowledge Base (reuse if a KB with this name already exists) -----------------------
KB_ID=""
if ! $DRY_RUN; then
  KB_ID="$(aws --region "${REGION}" bedrock-agent list-knowledge-bases \
    --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" --output text 2>/dev/null || true)"
  [[ "${KB_ID}" == "None" ]] && KB_ID=""
fi
if [[ -z "${KB_ID}" ]]; then
  # The dimensions/embeddingDataType config is Titan-v2-specific; other models (e.g. Cohere,
  # Titan v1) reject it and use their fixed native dimension. Only send it for Titan v2.
  EMBED_CFG=""
  if [[ "${EMBED_MODEL}" == amazon.titan-embed-text-v2* ]]; then
    EMBED_CFG=",
    \"embeddingModelConfiguration\": {\"bedrockEmbeddingModelConfiguration\": {\"dimensions\": ${EMBED_DIM}, \"embeddingDataType\": \"FLOAT32\"}}"
  fi
  cat > "${WORK}/kbconf.json" <<JSON
{ "type": "VECTOR", "vectorKnowledgeBaseConfiguration": {
    "embeddingModelArn": "${EMBED_MODEL_ARN}"${EMBED_CFG}
  }}
JSON
  cat > "${WORK}/storage.json" <<JSON
{ "type": "S3_VECTORS", "s3VectorsConfiguration": {
    "vectorBucketArn": "${VECTOR_BUCKET_ARN}", "indexArn": "${VECTOR_INDEX_ARN}"}}
JSON
  log "Creating knowledge base ${KB_NAME}"
  if $DRY_RUN; then
    echo "  DRYRUN: aws bedrock-agent create-knowledge-base --name ${KB_NAME} --role-arn ${KB_ROLE_ARN} ..."
    KB_ID="kb-DRYRUN"
  else
    KB_ID="$(aws --region "${REGION}" bedrock-agent create-knowledge-base \
      --name "${KB_NAME}" --role-arn "${KB_ROLE_ARN}" \
      --knowledge-base-configuration "file://${WORK}/kbconf.json" \
      --storage-configuration "file://${WORK}/storage.json" \
      --query 'knowledgeBase.knowledgeBaseId' --output text)" || {
        error "create-knowledge-base failed. Config used:"; cat "${WORK}/kbconf.json" "${WORK}/storage.json" >&2; exit 1; }
  fi
else
  log "Reusing existing knowledge base ${KB_NAME} (${KB_ID})"
fi
log "  knowledgeBaseId=${KB_ID}"

# --- 4) Data source (reuse if present) -----------------------------------------------------
DS_ID=""
if ! $DRY_RUN; then
  DS_ID="$(aws --region "${REGION}" bedrock-agent list-data-sources --knowledge-base-id "${KB_ID}" \
    --query "dataSourceSummaries[?name=='${DATA_SOURCE_NAME}'].dataSourceId | [0]" --output text 2>/dev/null || true)"
  [[ "${DS_ID}" == "None" ]] && DS_ID=""
fi
if [[ -z "${DS_ID}" ]]; then
  if [[ -n "${DATA_PREFIX}" ]]; then
    PREFIX_JSON=", \"inclusionPrefixes\": [\"${DATA_PREFIX}\"]"
  else
    PREFIX_JSON=""
  fi
  cat > "${WORK}/ds.json" <<JSON
{ "type": "S3", "s3Configuration": {"bucketArn": "arn:${PARTITION}:s3:::${DATA_BUCKET}"${PREFIX_JSON}}}
JSON
  log "Creating data source ${DATA_SOURCE_NAME}"
  if $DRY_RUN; then
    echo "  DRYRUN: aws bedrock-agent create-data-source --knowledge-base-id ${KB_ID} --name ${DATA_SOURCE_NAME} ..."
    DS_ID="ds-DRYRUN"
  else
    DS_ID="$(aws --region "${REGION}" bedrock-agent create-data-source \
      --knowledge-base-id "${KB_ID}" --name "${DATA_SOURCE_NAME}" \
      --data-source-configuration "file://${WORK}/ds.json" \
      --query 'dataSource.dataSourceId' --output text)"
  fi
else
  log "Reusing existing data source ${DATA_SOURCE_NAME} (${DS_ID})"
fi
log "  dataSourceId=${DS_ID}"

# --- 4.5) CloudWatch log delivery so ingestion problems are visible (not silent) -----------
if $DRY_RUN; then
  echo "  DRYRUN: configure CloudWatch APPLICATION_LOGS delivery for the KB"
else
  KB_ARN="arn:${PARTITION}:bedrock:${REGION}:${ACCOUNT_ID}:knowledge-base/${KB_ID}"
  LG_NAME="/aws/vendedlogs/bedrock/knowledge-base/${KB_NAME}"
  aws --region "${REGION}" logs create-log-group --log-group-name "${LG_NAME}" >/dev/null 2>&1 || true
  # Cost hygiene: cap log retention (default 14d) so ingestion logs don't accumulate forever.
  aws --region "${REGION}" logs put-retention-policy --log-group-name "${LG_NAME}" \
    --retention-in-days "${KB_LOG_RETENTION_DAYS:-14}" >/dev/null 2>&1 || true
  LG_ARN="$(aws --region "${REGION}" logs describe-log-groups --log-group-name-prefix "${LG_NAME}" \
    --query 'logGroups[0].arn' --output text 2>/dev/null || true)"
  LG_ARN="${LG_ARN%:\*}"
  if [[ -n "${LG_ARN}" && "${LG_ARN}" != "None" ]]; then
    aws --region "${REGION}" logs put-delivery-source --name "kb-${KB_NAME}-src" \
      --resource-arn "${KB_ARN}" --log-type APPLICATION_LOGS >/dev/null 2>&1 || true
    DEST_ARN="$(aws --region "${REGION}" logs put-delivery-destination --name "kb-${KB_NAME}-dst" \
      --delivery-destination-configuration "destinationResourceArn=${LG_ARN}" \
      --query 'deliveryDestination.arn' --output text 2>/dev/null || true)"
    if [[ -n "${DEST_ARN}" && "${DEST_ARN}" != "None" ]]; then
      aws --region "${REGION}" logs create-delivery --delivery-source-name "kb-${KB_NAME}-src" \
        --delivery-destination-arn "${DEST_ARN}" >/dev/null 2>&1 || true
    fi
    log "  CloudWatch logs -> ${LG_NAME}"
  else
    warn "  could not set up CloudWatch log delivery (non-fatal)"
  fi
fi

# --- 5) Ingest -----------------------------------------------------------------------------
if $DRY_RUN; then
  echo "  DRYRUN: aws bedrock-agent start-ingestion-job --knowledge-base-id ${KB_ID} --data-source-id ${DS_ID}"
  log "DRY RUN complete."
  exit 0
fi
log "Starting ingestion job"
JOB_ID="$(aws --region "${REGION}" bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" \
  --query 'ingestionJob.ingestionJobId' --output text)"
log "  ingestionJobId=${JOB_ID}; waiting for completion (up to ~15m)"
for _ in $(seq 1 90); do
  STATUS="$(aws --region "${REGION}" bedrock-agent get-ingestion-job \
    --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --ingestion-job-id "${JOB_ID}" \
    --query 'ingestionJob.status' --output text 2>/dev/null || echo UNKNOWN)"
  case "${STATUS}" in
    COMPLETE) log "  ingestion COMPLETE"; break;;
    FAILED)   error "ingestion FAILED — see the Bedrock console for details"; break;;
    *)        sleep 10;;
  esac
done

echo
log "Knowledge base ready. Use this id in the MCP deploy:"
log "  BedrockKnowledgeBaseId=${KB_ID}"
