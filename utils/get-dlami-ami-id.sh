#!/usr/bin/env bash
set -euo pipefail

# Resolve the latest NVIDIA DLAMI (GPU PyTorch 2.9 on Amazon Linux 2023)
# for a user-provided AWS region.

REGION="${1:-}"
if [[ -z "${REGION}" ]]; then
  echo "Usage: $0 <aws-region>" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi

SSM_PARAMETER="/aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.9-amazon-linux-2023/latest/ami-id"

AMI_ID="$(aws ssm get-parameter \
  --region "${REGION}" \
  --name "${SSM_PARAMETER}" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)"

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  # Fallback to image name query if SSM lookup is unavailable in a region.
  AMI_ID="$(aws ec2 describe-images \
    --region "${REGION}" \
    --owners amazon \
    --filters \
      'Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.9 (Amazon Linux 2023) ????????' \
      'Name=state,Values=available' \
    --query 'reverse(sort_by(Images, &CreationDate))[:1].ImageId' \
    --output text)"
fi

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "ERROR: Could not resolve DLAMI ID for region ${REGION}" >&2
  exit 1
fi

echo "${AMI_ID}"
