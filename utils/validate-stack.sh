#!/usr/bin/env bash
set -euo pipefail

STACK_FILE="${1:-cloudformation/main.yaml}"

echo "Validating ${STACK_FILE}"
aws cloudformation validate-template --template-body "file://${STACK_FILE}"
