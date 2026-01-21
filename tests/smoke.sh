#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -n "${REPO_DIR}" && -f "${REPO_DIR}/smoke.sh" ]]; then
  bash "${REPO_DIR}/smoke.sh"
elif [[ -f "${SCRIPT_DIR}/../smoke.sh" ]]; then
  bash "${SCRIPT_DIR}/../smoke.sh"
else
  echo "ERROR: smoke.sh not found." >&2
  exit 1
fi
