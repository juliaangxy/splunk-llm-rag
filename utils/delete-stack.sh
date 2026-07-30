#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <environment: dev|staging|prod> <region> [stack-name|--shared|--all]" >&2
  echo "Example: $0 dev ap-southeast-1" >&2
  echo "Example: $0 dev ap-southeast-1 --shared" >&2
  echo "Example: $0 dev ap-southeast-1 --all" >&2
  echo "Example: $0 dev ap-southeast-1 my-custom-stack" >&2
  exit 1
fi

ENVIRONMENT="$1"
REGION="$2"
TARGET="${3:-main}"
MAIN_STACK_NAME="splunk-ai-${ENVIRONMENT}"
SHARED_STACK_NAME="splunk-ai-shared-${ENVIRONMENT}"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi

delete_stack() {
  local stack_name="$1"
  local stack_status

  echo "Checking stack status: ${stack_name} (${REGION})"
  stack_status="$(aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || true)"

  if [[ -z "${stack_status}" || "${stack_status}" == "None" ]]; then
    echo "Stack not found (already deleted): ${stack_name}"
    return 0
  fi

  if [[ "${stack_status}" == "DELETE_IN_PROGRESS" ]]; then
    echo "Deletion already in progress for ${stack_name}; waiting for completion..."
    aws cloudformation wait stack-delete-complete \
      --region "${REGION}" \
      --stack-name "${stack_name}"
    echo "Stack deletion completed: ${stack_name}"
    return 0
  fi

  echo "Deleting stack: ${stack_name} (current status: ${stack_status})"
  aws cloudformation delete-stack \
    --region "${REGION}" \
    --stack-name "${stack_name}"

  echo "Waiting for deletion to complete: ${stack_name}"
  aws cloudformation wait stack-delete-complete \
    --region "${REGION}" \
    --stack-name "${stack_name}"

  echo "Stack deletion completed: ${stack_name}"
}

case "${TARGET}" in
  --shared|shared)
    delete_stack "${SHARED_STACK_NAME}"
    ;;
  --all|all)
    delete_stack "${MAIN_STACK_NAME}"
    delete_stack "${SHARED_STACK_NAME}"
    ;;
  main)
    delete_stack "${MAIN_STACK_NAME}"
    ;;
  *)
    delete_stack "${TARGET}"
    ;;
esac
