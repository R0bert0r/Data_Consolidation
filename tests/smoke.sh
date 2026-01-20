#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_PATH="${REPO_DIR}/consolidate_unoe_dose_to_uno.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

bash -n "${SCRIPT_PATH}"
SELF_TEST_DIR="${TEMP_DIR}" "${SCRIPT_PATH}" --self-test

python3 - "${TEMP_DIR}" <<'PY'
import csv
import os
import sys

temp_dir = sys.argv[1]
paths = [
    os.path.join(temp_dir, "collision.csv"),
    os.path.join(temp_dir, "provenance.csv"),
]

for path in paths:
    if not os.path.exists(path):
        raise SystemExit(1)
    with open(path, newline="") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    if not rows:
        raise SystemExit(1)
    expected_len = len(rows[0])
    for row in rows:
        if len(row) != expected_len:
            raise SystemExit(1)
PY

echo "Smoke OK"
