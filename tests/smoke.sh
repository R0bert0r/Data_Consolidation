#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_PATH="${REPO_DIR}/consolidate_unoe_dose_to_uno.sh"

bash -n "${SCRIPT_PATH}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

COLLISION_CSV="${TEMP_DIR}/collision.csv"
PROVENANCE_CSV="${TEMP_DIR}/provenance.csv"

cat <<'HEADER' > "${COLLISION_CSV}"
dest_path,classification,chosen_action,unoe_path,unoe_size,unoe_mtime_utc,unoe_sha256,dose_path,dose_size,dose_mtime_utc,dose_sha256,resulting_paths
HEADER

python3 - "${COLLISION_CSV}" <<'PY'
import csv
import sys

path = sys.argv[1]
row = [
    'path with spaces,comma"quote',
    'conflict',
    'keep_both',
    '/src/path,one',
    '123',
    '2024-01-01T00:00:00Z',
    'sha1',
    '/src/path two',
    '456',
    '2024-01-02T00:00:00Z',
    'sha2',
    'result,path',
]
with open(path, 'a', newline='') as handle:
    writer = csv.writer(handle)
    writer.writerow(row)
PY

cat <<'HEADER' > "${PROVENANCE_CSV}"
dest_path,source_origin,source_path,src_create_time_utc,create_time_status,src_mtime_utc,size_bytes,sha256
HEADER

python3 - "${PROVENANCE_CSV}" <<'PY'
import csv
import sys

path = sys.argv[1]
row = [
    'dest,with,comma"quote',
    'UNOE',
    '/src/path with spaces',
    '2024-01-01T00:00:00Z',
    'ok',
    '2024-01-02T00:00:00Z',
    '123',
    'sha256value',
]
with open(path, 'a', newline='') as handle:
    writer = csv.writer(handle)
    writer.writerow(row)
PY

python3 - "${COLLISION_CSV}" "${PROVENANCE_CSV}" <<'PY'
import csv
import sys

collision = sys.argv[1]
provenance = sys.argv[2]

with open(collision, newline='') as handle:
    reader = csv.reader(handle)
    header = next(reader, None)
    if not header or len(header) < 12:
        raise SystemExit(1)
    row = next(reader, None)
    if not row or len(row) < 12:
        raise SystemExit(1)
    if 'comma"quote' not in row[0]:
        raise SystemExit(1)

with open(provenance, newline='') as handle:
    reader = csv.DictReader(handle)
    row = next(reader, None)
    if not row or 'dest_path' not in row:
        raise SystemExit(1)
    if 'comma"quote' not in row['dest_path']:
        raise SystemExit(1)
PY

echo "Smoke tests passed."
