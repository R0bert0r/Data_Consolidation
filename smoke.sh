#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"
SCRIPT_PATH="${REPO_DIR}/consolidate_unoe_dose_to_uno.sh"

if [[ ! -f "${SCRIPT_PATH}" ]]; then
  echo "ERROR: consolidate_unoe_dose_to_uno.sh not found at ${SCRIPT_PATH}" >&2
  exit 1
fi

"${SCRIPT_DIR}/tests/smoke.sh"
