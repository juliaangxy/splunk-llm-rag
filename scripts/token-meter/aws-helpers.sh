#!/usr/bin/env bash
# AWS-only helpers — EC2 instance-metadata (IMDSv2) + SplunkAiRole → IP discovery.
#
# These exist ONLY for the optional AWS tag-based routing in configure-token-meter-routes.sh
# (resolve a peer Splunk instance by its SplunkAiRole tag). They are NOT sourced by the core
# token-metering scripts (install-token-meter.sh / 11-token-metrics.sh / start-token-meter-
# proxies.sh), so an on-prem install never touches AWS. On non-AWS hosts every function here
# returns empty (no 169.254 metadata service / no `aws` CLI) and callers fall back to explicit
# hosts (e.g. TOKEN_METER_DEFAULT_HOST / a route's hec_host).

imds_token() {
  curl -s -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true
}

imds_get() {
  local path="$1" tok
  tok="$(imds_token)"
  curl -s -m 3 -H "X-aws-ec2-metadata-token: ${tok}" \
    "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null || true
}

local_private_ip() { imds_get local-ipv4; }
local_instance_id() { imds_get instance-id; }

local_vpc_id() {
  local mac
  mac="$(imds_get mac)"
  [[ -n "${mac}" ]] && imds_get "network/interfaces/macs/${mac}/vpc-id"
}

# SplunkAiRole tag of THIS instance (search-head | gpu-host), empty if unavailable.
local_splunk_ai_role() {
  local id
  id="$(local_instance_id)"
  [[ -z "${id}" ]] && return 0
  aws ec2 describe-instances --instance-ids "${id}" \
    --query 'Reservations[].Instances[].Tags[?Key==`SplunkAiRole`].Value | [0]' \
    --output text 2>/dev/null | sed 's/^None$//'
}

# resolve_role_ip <role>: private IP of the running instance tagged SplunkAiRole=<role>
# in this VPC. Narrows by ENVIRONMENT_NAME's Name-tag prefix when available so a shared
# VPC (cloud + airgapped) doesn't cross-match. Prints empty string if not found.
resolve_role_ip() {
  local role="$1" vpc
  [[ -z "${role}" ]] && return 0
  vpc="$(local_vpc_id)"
  local -a filters=("Name=tag:SplunkAiRole,Values=${role}" "Name=instance-state-name,Values=running")
  [[ -n "${vpc}" ]] && filters+=("Name=vpc-id,Values=${vpc}")
  [[ -n "${ENVIRONMENT_NAME:-}" ]] && filters+=("Name=tag:Name,Values=${ENVIRONMENT_NAME}-splunk-ai-*")
  aws ec2 describe-instances --filters "${filters[@]}" \
    --query 'Reservations[].Instances[].PrivateIpAddress' --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d;/^None$/d' | head -1
}
