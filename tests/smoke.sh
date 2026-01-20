#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_PATH="${REPO_DIR}/consolidate_unoe_dose_to_uno.sh"

bash -n "${SCRIPT_PATH}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

CSV_PATH="${TEMP_DIR}/csv_roundtrip.csv"

python3 - "${CSV_PATH}" <<'PY'
import csv
import sys

path = sys.argv[1]
rows = [
    ["col1", "col2", "col3"],
    ["path with spaces", 'comma,field', 'quote"field'],
    ["leading space", " trailing space ", "multi\nline"],
]
with open(path, "w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerows(rows)

with open(path, newline="") as handle:
    reader = csv.reader(handle)
    loaded = list(reader)

if not loaded:
    raise SystemExit(1)

expected_len = len(loaded[0])
for row in loaded:
    if len(row) != expected_len:
        raise SystemExit(1)
PY

echo "Smoke OK"
