#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export POD_QOS_CLASS="${POD_QOS_CLASS:-best-effort}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-cce-best-effort-consumer}"
export QUEUE_NAME="${QUEUE_NAME:-cce-best-effort}"

exec "${SCRIPT_DIR}/run-deployment-load.sh" "$@"
