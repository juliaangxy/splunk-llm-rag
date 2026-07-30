#!/usr/bin/env bash
set -euo pipefail

# Resolve the latest Amazon Linux 2023 x86_64 AMI for a region. Used for the Splunk
# search head (t3.medium): a Splunk-supported general-purpose OS, not the GPU DLAMI.
# The bootstrap scripts target Amazon Linux 2023 (dnf / ec2-user / systemd), which the
# DLAMI is also built on, so behavior is identical minus the unneeded GPU stack.

REGION="${1:-}"
if [[ -z "${REGION}" ]]; then
  echo "Usage: $0 <aws-region>" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi

# Canonical public SSM parameter for the latest AL2023 x86_64 AMI.
SSM_PARAMETER="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

AMI_ID="$(aws ssm get-parameter \
  --region "${REGION}" \
  --name "${SSM_PARAMETER}" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)"

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  # Fallback to an image-name query if the SSM parameter is unavailable.
  AMI_ID="$(aws ec2 describe-images \
    --region "${REGION}" \
    --owners amazon \
    --filters \
      'Name=name,Values=al2023-ami-2023.*-kernel-*-x86_64' \
      'Name=state,Values=available' \
      'Name=architecture,Values=x86_64' \
    --query 'reverse(sort_by(Images, &CreationDate))[:1].ImageId' \
    --output text)"
fi

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "ERROR: Could not resolve Amazon Linux 2023 AMI ID for region ${REGION}" >&2
  exit 1
fi

echo "${AMI_ID}"
