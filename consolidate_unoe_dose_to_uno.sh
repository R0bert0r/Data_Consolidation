#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

UNOE_ROOT="/srv/dev-disk-by-uuid-9E0E3E860E3E580B"
DOSE_ROOT="/srv/dev-disk-by-uuid-2B0BF1C64E9BEBE1"
UNO_ROOT="/srv/dev-disk-by-uuid-92c1be66-0355-44da-b61b-8d4029d3f2c4"

RUN_ID=""
LOGDIR=""
DRY_RUN=false
PHASE="all"
SELF_TEST=false

CURRENT_ACTION="initializing"

trap 'echo "ERROR: ${SCRIPT_NAME} failed during: ${CURRENT_ACTION}. Logs: ${LOGDIR:-unknown}" >&2' ERR

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [--dry-run] [--phase <name>] [--run-id <id>] [--log-dir <dir>]

Phases:
  preflight
  prepare_dest
  copy_unoe
  copy_dose_overlay
  resolve_conflicts
  verify_pre_dedupe
  dedupe_hardlinks
  compute_create_time_manifest
  post_verify
  all (default)

Options:
  --dry-run           Run rsync in dry-run mode; destructive phases are skipped.
  --self-test         Run lightweight CSV and bash syntax checks; no mounts required.
  --phase <name>      Run a specific phase.
  --run-id <id>       Override run ID (default: YYYY-MM-DD_HHMMSS).
  --log-dir <dir>     Override log directory (default under UNO).
  -h, --help          Show this help message.
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: ${SCRIPT_NAME} must be run as root (EUID 0)." >&2
    exit 1
  fi
}

check_tools() {
  local tools=(rsync find stat sha256sum getfattr setfattr jdupes python3)
  for tool in "${tools[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      if [[ "${tool}" == "jdupes" ]]; then
        echo "ERROR: jdupes is required. Install with: apt install jdupes" >&2
      else
        echo "ERROR: required tool missing: ${tool}" >&2
      fi
      exit 1
    fi
  done
}

init_run() {
  if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="$(date +"%Y-%m-%d_%H%M%S")"
  fi
  if [[ -z "${LOGDIR}" ]]; then
    LOGDIR="${UNO_ROOT}/90_System_Artifacts/Consolidation_Logs/${RUN_ID}"
  fi
  mkdir -p "${LOGDIR}"
}

log_status() {
  echo "[${SCRIPT_NAME}] ${1} (logs: ${LOGDIR})"
}

csv_quote() {
  local value="${1}"
  local escaped="${value//\"/\"\"}"
  if [[ "${escaped}" == *","* || "${escaped}" == *"\""* || "${escaped}" == *$'\n'* || "${escaped}" =~ ^[[:space:]] || "${escaped}" =~ [[:space:]]$ ]]; then
    printf '"%s"' "${escaped}"
  else
    printf '%s' "${escaped}"
  fi
}

csv_row() {
  local file="${1}"
  shift
  local first=true
  local field
  {
    for field in "$@"; do
      if [[ "${first}" == "true" ]]; then
        first=false
      else
        printf ','
      fi
      csv_quote "${field}"
    done
    printf '\n'
  } >> "${file}"
}

is_excluded_dir_name() {
  local name="${1}"
  if [[ "${name}" == '$RECYCLE.BIN' || "${name}" == "System Volume Information" ]]; then
    return 0
  fi
  return 1
}

find_files_pruned() {
  local root="${1}"
  find "${root}" \
    \( -type d \( -name '$RECYCLE.BIN' -o -name 'System Volume Information' \) -prune \) \
    -o -type f -print0
}

find_top_level_files() {
  local root="${1}"
  find "${root}" -mindepth 1 -maxdepth 1 -type f -print0
}

rsync_excludes() {
  RSYNC_EXCLUDES=(
    '--exclude=$RECYCLE.BIN/'
    '--exclude=$RECYCLE.BIN/***'
    '--exclude=System Volume Information/'
    '--exclude=System Volume Information/***'
  )
}

rsync_common_flags() {
  RSYNC_COMMON_FLAGS=(-a --itemize-changes --stats --chown=tom:sambashare)
}

run_rsync() {
  local src="${1}"
  local dest="${2}"
  local extra_flags_name="${3}"
  local log_file="${4}"
  local -a cmd
  local -a extra=()

  rsync_common_flags
  rsync_excludes

  if [[ -n "${extra_flags_name}" ]]; then
    local -n extra_ref="${extra_flags_name}"
    extra=("${extra_ref[@]}")
  fi

  cmd=(rsync "${RSYNC_COMMON_FLAGS[@]}" "${RSYNC_EXCLUDES[@]}")
  if [[ "${DRY_RUN}" == "true" ]]; then
    cmd+=(--dry-run)
  fi
  cmd+=("${extra[@]}" "${src}" "${dest}")

  CURRENT_ACTION="rsync ${src} -> ${dest}"
  "${cmd[@]}" 2>&1 | tee -a "${log_file}"
}

verify_rsync_dryrun() {
  local src="${1}"
  local dest="${2}"
  local extra_flags_name="${3}"
  local log_file="${4}"
  local -a cmd
  local -a extra=()

  rsync_common_flags
  rsync_excludes

  if [[ -n "${extra_flags_name}" ]]; then
    local -n extra_ref="${extra_flags_name}"
    extra=("${extra_ref[@]}")
  fi

  cmd=(rsync "${RSYNC_COMMON_FLAGS[@]}" "${RSYNC_EXCLUDES[@]}" --dry-run)
  cmd+=("${extra[@]}" "${src}" "${dest}")

  CURRENT_ACTION="verify rsync dry-run ${src} -> ${dest}"
  "${cmd[@]}" 2>&1 | tee "${log_file}"
}

normalize_permissions() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_status "Dry run: skipping permission normalization"
    return 0
  fi

  CURRENT_ACTION="normalize permissions"
  local scopes=(
    "${UNO_ROOT}/01_Knowledge"
    "${UNO_ROOT}/02_Media"
    "${UNO_ROOT}/03_Technology"
    "${UNO_ROOT}/04_Personal"
    "${UNO_ROOT}/Research"
    "${UNO_ROOT}/ASH"
    "${UNO_ROOT}/Backups"
    "${UNO_ROOT}/Dropbox"
    "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders"
    "${UNO_ROOT}/90_System_Artifacts/Loose_Files"
  )

  for scope in "${scopes[@]}"; do
    if [[ -d "${scope}" ]]; then
      chown -R tom:sambashare "${scope}"
      find "${scope}" -type d -exec chmod 2775 {} +
      find "${scope}" -type f -exec chmod u+rwX,g+rwX,o-rwx {} +
    fi
  done
}

preflight() {
  log_status "Phase: preflight"
  CURRENT_ACTION="preflight"
  {
    echo "RUN_ID=${RUN_ID}"
    date -u
    df -h
    df -i
    findmnt
    uname -a
    rsync --version | head -n 3
    jdupes --version
    getfattr --version
  } > "${LOGDIR}/00_preflight.txt"
}

prepare_dest() {
  log_status "Phase: prepare_dest"
  CURRENT_ACTION="prepare destination"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Consolidation_Logs"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/UNOE"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/DOSE"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Loose_Files/UNOE"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Loose_Files/DOSE"
  mkdir -p "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000"
  mkdir -p "${UNO_ROOT}/02_Media/Photos/_From_Root/UNOE"
  mkdir -p "${UNO_ROOT}/02_Media/Photos/_From_Root/DOSE"
  normalize_permissions
}

is_image_file() {
  local file="${1,,}"
  case "${file}" in
    *.jpg|*.jpeg|*.png|*.gif|*.tiff|*.tif|*.bmp|*.heic) return 0 ;;
    *) return 1 ;;
  esac
}

build_mapping() {
  declare -gA MAP
  MAP["CBT's"]="01_Knowledge/01_Training/CBTs"
  MAP["PPL Training"]="01_Knowledge/01_Training/Aviation_PPL"
  MAP["Amazing Brain Training"]="01_Knowledge/01_Training/Brain_Training"
  MAP["Tutorials"]="01_Knowledge/01_Training/Tutorials"
  MAP["Education"]="01_Knowledge/01_Training/Education"
  MAP["Spanish"]="01_Knowledge/02_Languages/Spanish"
  MAP["ebooks"]="01_Knowledge/03_Books/eBooks"
  MAP["User Manuals"]="01_Knowledge/04_Manuals/User_Manuals"
  MAP["Alan Watts"]="01_Knowledge/05_Reference/Alan_Watts"
  MAP["Sacred Vedics"]="01_Knowledge/05_Reference/Sacred_Vedics"
  MAP["kris"]="01_Knowledge/05_Reference/Kris_Archive"
  MAP["How to tie a tie pics"]="01_Knowledge/05_Reference/Life_Skills/How_to_tie_a_tie"
  MAP["Research"]="Research"
  MAP["AUDIO"]="02_Media/Audio"
  MAP["Video"]="02_Media/Video"
  MAP["Pictures"]="02_Media/Photos"
  MAP["Programs"]="03_Technology/01_Software/Programs"
  MAP["000 - OBD SCAN PROGRAMS"]="03_Technology/01_Software/OBD_Scanners"
  MAP["Games"]="03_Technology/01_Software/Games"
  MAP["OS"]="03_Technology/01_Software/OS_Images"
  MAP["Drivers"]="03_Technology/01_Software/Drivers"
  MAP["ESXIVMS"]="03_Technology/02_Virtualization/ESXi_VMs"
  MAP["VirtualBox VMs"]="03_Technology/02_Virtualization/VirtualBox_VMs"
  MAP["Technical"]="03_Technology/03_Engineering_and_Tech_Notes/Technical"
  MAP["Troubleshooting"]="03_Technology/03_Engineering_and_Tech_Notes/Troubleshooting"
  MAP["Projects"]="03_Technology/03_Engineering_and_Tech_Notes/Projects"
  MAP["Scripts"]="03_Technology/03_Engineering_and_Tech_Notes/Scripts"
  MAP["Systems"]="03_Technology/03_Engineering_and_Tech_Notes/Systems"
  MAP["dev"]="03_Technology/03_Engineering_and_Tech_Notes/dev"
  MAP["Contracts"]="04_Personal/Legal/Contracts"
  MAP["Home Design"]="04_Personal/Home/Home_Design"
  MAP["Exercise"]="04_Personal/Fitness/Exercise"
  MAP["Vehicles"]="04_Personal/Vehicles"
  MAP["EACL"]="04_Personal/Home/Projects/EACL"
  MAP["found.000"]="90_System_Artifacts/Recovery/found.000"
}

copy_as_is_folders() {
  local src_root="${1}"
  local origin="${2}"
  local phase_label="${3}"
  local overlay="${4}"
  local verify_prefix="${5}"
  local log_file="${LOGDIR}/${phase_label}_as_is_${origin}.log"
  local -a extra_flags=()
  local folders=("ASH" "Backups" "Dropbox")
  if [[ "${overlay}" == "true" ]]; then
    extra_flags=(--ignore-existing)
  fi
  for folder in "${folders[@]}"; do
    if [[ -d "${src_root}/${folder}" ]]; then
      run_rsync "${src_root}/${folder}/" "${UNO_ROOT}/${folder}/" extra_flags "${log_file}"
      verify_rsync_dryrun "${src_root}/${folder}/" "${UNO_ROOT}/${folder}/" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_${folder}_${origin}.txt"
    fi
  done
}

copy_mapped_and_unmapped() {
  local src_root="${1}"
  local origin="${2}"
  local phase_label="${3}"
  local overlay="${4}"
  local verify_prefix="${5}"
  local log_file="${LOGDIR}/${phase_label}_mapped_${origin}.log"
  local -a extra_flags=()
  if [[ "${overlay}" == "true" ]]; then
    extra_flags=(--ignore-existing)
  fi

  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"

    if is_excluded_dir_name "${name}"; then
      continue
    fi

    if [[ "${name}" == "ASH" || "${name}" == "Backups" || "${name}" == "Dropbox" ]]; then
      continue
    fi

    if [[ "${name}" == "found.000" ]]; then
      run_rsync "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000/" extra_flags "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000/" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_found.000_${origin}.txt"
      continue
    fi

    if [[ -n "${MAP[${name}]:-}" ]]; then
      run_rsync "${entry}/" "${UNO_ROOT}/${MAP[${name}]}/" extra_flags "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/${MAP[${name}]}/" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_${name}_${origin}.txt"
    else
      run_rsync "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/${origin}/${name}/" extra_flags "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/${origin}/${name}/" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_unmapped_${name}_${origin}.txt"
    fi
  done < <(find "${src_root}" -mindepth 1 -maxdepth 1 -type d -print0)
}

copy_loose_files() {
  local src_root="${1}"
  local origin="${2}"
  local phase_label="${3}"
  local overlay="${4}"
  local verify_prefix="${5}"
  local -a extra_flags=()
  if [[ "${overlay}" == "true" ]]; then
    extra_flags=(--ignore-existing)
  fi

  local log_file="${LOGDIR}/${phase_label}_loose_${origin}.log"

  while IFS= read -r -d '' file; do
    local base
    base="$(basename "${file}")"
    if is_excluded_dir_name "${base}"; then
      continue
    fi
    if is_image_file "${base}"; then
      run_rsync "${file}" "${UNO_ROOT}/02_Media/Photos/_From_Root/${origin}/${base}" extra_flags "${log_file}"
      verify_rsync_dryrun "${file}" "${UNO_ROOT}/02_Media/Photos/_From_Root/${origin}/${base}" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_loose_images_${origin}.txt"
    else
      run_rsync "${file}" "${UNO_ROOT}/90_System_Artifacts/Loose_Files/${origin}/${base}" extra_flags "${log_file}"
      verify_rsync_dryrun "${file}" "${UNO_ROOT}/90_System_Artifacts/Loose_Files/${origin}/${base}" extra_flags "${LOGDIR}/${verify_prefix}_verify_dryrun_loose_files_${origin}.txt"
    fi
  done < <(find_top_level_files "${src_root}")
}

copy_unoe() {
  log_status "Phase: copy_unoe"
  CURRENT_ACTION="copy_unoe"
  copy_as_is_folders "${UNOE_ROOT}" "UNOE" "20" "false" "41"
  copy_mapped_and_unmapped "${UNOE_ROOT}" "UNOE" "20" "false" "41"
  copy_loose_files "${UNOE_ROOT}" "UNOE" "20" "false" "41"
}

copy_dose_overlay() {
  log_status "Phase: copy_dose_overlay"
  CURRENT_ACTION="copy_dose_overlay"
  copy_as_is_folders "${DOSE_ROOT}" "DOSE" "21" "true" "42"
  copy_mapped_and_unmapped "${DOSE_ROOT}" "DOSE" "21" "true" "42"
  copy_loose_files "${DOSE_ROOT}" "DOSE" "21" "true" "42"
}

sha256_file() {
  sha256sum "${1}" | awk '{print $1}'
}

mtime_utc() {
  local epoch
  epoch="$(stat -c %Y "${1}")"
  date -u -d "@${epoch}" +"%Y-%m-%dT%H:%M:%SZ"
}

size_bytes() {
  stat -c %s "${1}"
}

get_create_time() {
  local file="${1}"
  local value
  local parsed

  local birth
  birth="$(stat -c %W "${file}" 2>/dev/null || echo 0)"
  if [[ "${birth}" =~ ^[0-9]+$ && "${birth}" -gt 0 ]]; then
    if parsed="$(date -u -d "@${birth}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"; then
      echo "${parsed}|ok"
      return 0
    fi
  fi

  if value="$(getfattr -h -e hex -n system.ntfs_crtime_be --only-values "${file}" 2>/dev/null)"; then
    value="${value//[[:space:]]/}"
    value="${value#0x}"
    if [[ -n "${value}" && "${value}" =~ ^[0-9a-fA-F]+$ && ${#value} -ge 16 && $(( ${#value} % 2 )) -eq 0 ]]; then
      if (( ${#value} > 16 )); then
        value="${value: -16}"
      fi
      if parsed="$(python3 - "${value}" <<'PY'
import sys
value = sys.argv[1].strip()
try:
    if len(value) < 16:
        raise ValueError("short")
    filetime = int(value, 16)
    unix = (filetime / 10_000_000) - 11644473600
    if unix < 0:
        raise ValueError("negative")
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(unix, tz=timezone.utc)
    print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    sys.exit(1)
PY
2>/dev/null)"; then
        echo "${parsed}|ok"
        return 0
      fi
      echo "|parse_error"
      return 0
    fi
  fi

  if value="$(getfattr -h -e hex -n system.ntfs_crtime --only-values "${file}" 2>/dev/null)"; then
    value="${value//[[:space:]]/}"
    value="${value#0x}"
    if [[ -n "${value}" && "${value}" =~ ^[0-9a-fA-F]+$ && ${#value} -ge 16 && $(( ${#value} % 2 )) -eq 0 ]]; then
      if (( ${#value} > 16 )); then
        value="${value: -16}"
      fi
      if parsed="$(python3 - "${value}" <<'PY'
import sys
value = sys.argv[1].strip()
try:
    if len(value) < 16:
        raise ValueError("short")
    filetime = int(value, 16)
    unix = (filetime / 10_000_000) - 11644473600
    if unix < 0:
        raise ValueError("negative")
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(unix, tz=timezone.utc)
    print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    sys.exit(1)
PY
2>/dev/null)"; then
        echo "${parsed}|ok"
        return 0
      fi
      echo "|parse_error"
      return 0
    fi
  fi

  echo "|missing"
}

provenance_file=""

init_provenance() {
  provenance_file="${LOGDIR}/33_dest_provenance.csv"
  if [[ ! -f "${provenance_file}" ]]; then
    echo "dest_path,source_origin,source_path,src_create_time_utc,create_time_status,src_mtime_utc,size_bytes,sha256" > "${provenance_file}"
  fi
}

append_provenance() {
  local dest_rel="${1}"
  local origin="${2}"
  local src_path="${3}"
  local create_time="${4}"
  local create_status="${5}"
  local src_mtime="${6}"
  local size="${7}"
  local sha="${8}"

  csv_row "${provenance_file}" "${dest_rel}" "${origin}" "${src_path}" "${create_time}" "${create_status}" "${src_mtime}" "${size}" "${sha}"
}

create_time_coverage() {
  local report="${LOGDIR}/52_create_time_coverage.txt"
  python3 - "${provenance_file}" "${report}" <<'PY'
import csv
import sys

provenance = sys.argv[1]
report = sys.argv[2]

total = 0
ok_count = 0
missing_count = 0
parse_error_count = 0

try:
    with open(provenance, newline='') as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            total += 1
            status = (row.get('create_time_status') or '').strip()
            if status == 'ok':
                ok_count += 1
            elif status == 'missing':
                missing_count += 1
            elif status == 'parse_error':
                parse_error_count += 1
except Exception:
    pass

with open(report, 'w') as handle:
    handle.write(f"total_files_seen={total}\n")
    handle.write(f"ok_count={ok_count}\n")
    handle.write(f"missing_count={missing_count}\n")
    handle.write(f"parse_error_count={parse_error_count}\n")
PY
}

record_provenance_for_bucket() {
  local src_root="${1}"
  local dest_root="${2}"
  local origin="${3}"

  if [[ ! -d "${src_root}" ]]; then
    return 0
  fi

  while IFS= read -r -d '' file; do
    local rel
    rel="${file#${src_root}/}"
    local dest_path="${dest_root}/${rel}"
    if [[ -f "${dest_path}" ]]; then
      local dest_rel="${dest_path#${UNO_ROOT}/}"
      local src_sha
      src_sha="$(sha256_file "${file}")"
      local sha
      sha="$(sha256_file "${dest_path}")"
      if [[ "${sha}" != "${src_sha}" ]]; then
        continue
      fi
      local size
      size="$(size_bytes "${dest_path}")"
      local mtime
      mtime="$(mtime_utc "${file}")"
      local create_info
      create_info="$(get_create_time "${file}")"
      local create_time="${create_info%%|*}"
      local create_status="${create_info##*|}"
      append_provenance "${dest_rel}" "${origin}" "${file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
    fi
  done < <(find_files_pruned "${src_root}")
}

record_provenance_loose_files() {
  local src_root="${1}"
  local origin="${2}"

  while IFS= read -r -d '' file; do
    local rel
    rel="${file#${src_root}/}"
    if [[ "${rel}" == */* ]]; then
      continue
    fi
    local base
    base="$(basename "${file}")"
    if is_excluded_dir_name "${base}"; then
      continue
    fi
    local dest_path
    if is_image_file "${base}"; then
      dest_path="${UNO_ROOT}/02_Media/Photos/_From_Root/${origin}/${base}"
    else
      dest_path="${UNO_ROOT}/90_System_Artifacts/Loose_Files/${origin}/${base}"
    fi
    if [[ -f "${dest_path}" ]]; then
      local src_sha dest_sha
      src_sha="$(sha256_file "${file}")"
      dest_sha="$(sha256_file "${dest_path}")"
      if [[ "${src_sha}" != "${dest_sha}" ]]; then
        continue
      fi
      local dest_rel="${dest_path#${UNO_ROOT}/}"
      local size
      size="$(size_bytes "${dest_path}")"
      local mtime
      mtime="$(mtime_utc "${file}")"
      local create_info
      create_info="$(get_create_time "${file}")"
      local create_time="${create_info%%|*}"
      local create_status="${create_info##*|}"
      append_provenance "${dest_rel}" "${origin}" "${file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${dest_sha}"
    fi
  done < <(find_files_pruned "${src_root}")
}

record_provenance_all() {
  init_provenance
  record_provenance_for_bucket "${UNOE_ROOT}/ASH" "${UNO_ROOT}/ASH" "UNOE"
  record_provenance_for_bucket "${UNOE_ROOT}/Backups" "${UNO_ROOT}/Backups" "UNOE"
  record_provenance_for_bucket "${UNOE_ROOT}/Dropbox" "${UNO_ROOT}/Dropbox" "UNOE"
  record_provenance_for_bucket "${DOSE_ROOT}/ASH" "${UNO_ROOT}/ASH" "DOSE"
  record_provenance_for_bucket "${DOSE_ROOT}/Backups" "${UNO_ROOT}/Backups" "DOSE"
  record_provenance_for_bucket "${DOSE_ROOT}/Dropbox" "${UNO_ROOT}/Dropbox" "DOSE"

  for key in "${!MAP[@]}"; do
    record_provenance_for_bucket "${UNOE_ROOT}/${key}" "${UNO_ROOT}/${MAP[${key}]}" "UNOE"
    record_provenance_for_bucket "${DOSE_ROOT}/${key}" "${UNO_ROOT}/${MAP[${key}]}" "DOSE"
  done

  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"
    if is_excluded_dir_name "${name}"; then
      continue
    fi
    if [[ -z "${MAP[${name}]:-}" && "${name}" != "ASH" && "${name}" != "Backups" && "${name}" != "Dropbox" && "${name}" != "found.000" ]]; then
      record_provenance_for_bucket "${entry}" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/UNOE/${name}" "UNOE"
    fi
  done < <(find "${UNOE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0)

  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"
    if is_excluded_dir_name "${name}"; then
      continue
    fi
    if [[ -z "${MAP[${name}]:-}" && "${name}" != "ASH" && "${name}" != "Backups" && "${name}" != "Dropbox" && "${name}" != "found.000" ]]; then
      record_provenance_for_bucket "${entry}" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/DOSE/${name}" "DOSE"
    fi
  done < <(find "${DOSE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0)

  record_provenance_loose_files "${UNOE_ROOT}" "UNOE"
  record_provenance_loose_files "${DOSE_ROOT}" "DOSE"

  create_time_coverage
}

collision_log_candidates=""
collision_log_resolution=""
collision_log_actions=""

init_collision_logs() {
  collision_log_candidates="${LOGDIR}/30_collision_candidates.csv"
  collision_log_resolution="${LOGDIR}/31_conflict_resolution.csv"
  collision_log_actions="${LOGDIR}/32_conflict_actions.log"
  if [[ ! -f "${collision_log_candidates}" ]]; then
    echo "dest_path,classification,chosen_action,unoe_path,unoe_size,unoe_mtime_utc,unoe_sha256,dose_path,dose_size,dose_mtime_utc,dose_sha256,resulting_paths" > "${collision_log_candidates}"
  fi
  if [[ ! -f "${collision_log_resolution}" ]]; then
    echo "dest_path,classification,chosen_action,unoe_path,unoe_size,unoe_mtime_utc,unoe_sha256,dose_path,dose_size,dose_mtime_utc,dose_sha256,resulting_paths" > "${collision_log_resolution}"
  fi
  : > "${collision_log_actions}"
}

suffix_name() {
  local path="${1}"
  local suffix="${2}"
  local dir
  dir="$(dirname "${path}")"
  local base
  base="$(basename "${path}")"
  local name="${base%.*}"
  local ext=""
  if [[ "${base}" == *.* ]]; then
    ext=".${base##*.}"
  fi

  if [[ "${name}" =~ __UNOE(_[0-9]+)?$ || "${name}" =~ __DOSE(_[0-9]+)?$ ]]; then
    echo "${path}"
    return 0
  fi

  local candidate="${dir}/${name}__${suffix}${ext}"
  if [[ ! -e "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi

  local idx=2
  while true; do
    candidate="${dir}/${name}__${suffix}_${idx}${ext}"
    if [[ ! -e "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
    idx=$((idx + 1))
  done
}

resolve_one_collision() {
  local unoe_file="${1}"
  local dose_file="${2}"
  local dest_file="${3}"

  local unoe_sha dose_sha
  unoe_sha="$(sha256_file "${unoe_file}")"
  dose_sha="$(sha256_file "${dose_file}")"

  local unoe_size dose_size unoe_mtime dose_mtime
  unoe_size="$(size_bytes "${unoe_file}")"
  dose_size="$(size_bytes "${dose_file}")"
  unoe_mtime="$(mtime_utc "${unoe_file}")"
  dose_mtime="$(mtime_utc "${dose_file}")"

  local classification=""
  local action=""
  local resulting_paths=""

  if [[ "${unoe_sha}" == "${dose_sha}" ]]; then
    classification="identical"
    action="no_action"
    resulting_paths="${dest_file}"
    csv_row "${collision_log_candidates}" "${dest_file}" "${classification}" "${action}" "${unoe_file}" "${unoe_size}" "${unoe_mtime}" "${unoe_sha}" "${dose_file}" "${dose_size}" "${dose_mtime}" "${dose_sha}" "${resulting_paths}"
    return 0
  fi

  classification="conflict"
  csv_row "${collision_log_candidates}" "${dest_file}" "${classification}" "pending" "${unoe_file}" "${unoe_size}" "${unoe_mtime}" "${unoe_sha}" "${dose_file}" "${dose_size}" "${dose_mtime}" "${dose_sha}" ""

  local newest="UNOE"
  local unoe_epoch dose_epoch
  unoe_epoch="$(stat -c %Y "${unoe_file}")"
  dose_epoch="$(stat -c %Y "${dose_file}")"
  if [[ "${dose_epoch}" -gt "${unoe_epoch}" ]]; then
    newest="DOSE"
  elif [[ "${dose_epoch}" -eq "${unoe_epoch}" ]]; then
    if [[ "${dose_size}" -gt "${unoe_size}" ]]; then
      newest="DOSE"
    fi
  fi

  local newest_size
  local newest_file
  local other_file
  local other_suffix
  if [[ "${newest}" == "UNOE" ]]; then
    newest_file="${unoe_file}"
    newest_size="${unoe_size}"
    other_file="${dose_file}"
    other_suffix="DOSE"
  else
    newest_file="${dose_file}"
    newest_size="${dose_size}"
    other_file="${unoe_file}"
    other_suffix="UNOE"
  fi

  local other_size
  other_size="$(size_bytes "${other_file}")"

  if [[ "${newest_size}" -gt "${other_size}" ]]; then
    action="replace_with_newest"
    if [[ "${DRY_RUN}" == "false" ]]; then
      rm -f "${dest_file}"
      rsync -a --itemize-changes --stats --chown=tom:sambashare "${newest_file}" "${dest_file}" >> "${collision_log_actions}"
    fi
    resulting_paths="${dest_file}"
  else
    action="keep_both"
    local suffixed
    suffixed="$(suffix_name "${dest_file}" "${other_suffix}")"
    if [[ "${DRY_RUN}" == "false" ]]; then
      if [[ "${newest}" == "DOSE" ]]; then
        local current_sha
        current_sha="$(sha256_file "${dest_file}")"
        if [[ "${current_sha}" != "${dose_sha}" ]]; then
          mv "${dest_file}" "${suffixed}"
          rsync -a --itemize-changes --stats --chown=tom:sambashare "${dose_file}" "${dest_file}" >> "${collision_log_actions}"
        fi
        if [[ ! -f "${suffixed}" ]]; then
          rsync -a --itemize-changes --stats --chown=tom:sambashare "${unoe_file}" "${suffixed}" >> "${collision_log_actions}"
        fi
      else
        if [[ ! -f "${suffixed}" ]]; then
          rsync -a --itemize-changes --stats --chown=tom:sambashare "${dose_file}" "${suffixed}" >> "${collision_log_actions}"
        fi
      fi
    fi
    resulting_paths="${dest_file};${suffixed}"
  fi

  csv_row "${collision_log_resolution}" "${dest_file}" "${classification}" "${action}" "${unoe_file}" "${unoe_size}" "${unoe_mtime}" "${unoe_sha}" "${dose_file}" "${dose_size}" "${dose_mtime}" "${dose_sha}" "${resulting_paths}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    local dest_rel
    dest_rel="${dest_file#${UNO_ROOT}/}"
    local create_info
    local create_time
    local create_status
    local mtime
    local size
    local sha
    if [[ "${newest}" == "UNOE" ]]; then
      create_info="$(get_create_time "${unoe_file}")"
      create_time="${create_info%%|*}"
      create_status="${create_info##*|}"
      mtime="$(mtime_utc "${unoe_file}")"
      size="${unoe_size}"
      sha="${unoe_sha}"
      append_provenance "${dest_rel}" "UNOE" "${unoe_file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
    else
      create_info="$(get_create_time "${dose_file}")"
      create_time="${create_info%%|*}"
      create_status="${create_info##*|}"
      mtime="$(mtime_utc "${dose_file}")"
      size="${dose_size}"
      sha="${dose_sha}"
      append_provenance "${dest_rel}" "DOSE" "${dose_file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
    fi
    if [[ "${action}" == "keep_both" ]]; then
      local suffixed_rel
      suffixed_rel="${suffixed#${UNO_ROOT}/}"
      local other_create
      other_create="$(get_create_time "${other_file}")"
      local other_time="${other_create%%|*}"
      local other_status="${other_create##*|}"
      local other_mtime
      other_mtime="$(mtime_utc "${other_file}")"
      local other_sha
      other_sha="$(sha256_file "${other_file}")"
      append_provenance "${suffixed_rel}" "${other_suffix}" "${other_file}" "${other_time}" "${other_status}" "${other_mtime}" "${other_size}" "${other_sha}"
    fi
  fi
}

resolve_conflicts_in_bucket() {
  local unoe_base="${1}"
  local dose_base="${2}"
  local dest_base="${3}"

  if [[ ! -d "${unoe_base}" || ! -d "${dose_base}" ]]; then
    return 0
  fi

  while IFS= read -r -d '' dose_file; do
    local rel
    rel="${dose_file#${dose_base}/}"
    local unoe_file="${unoe_base}/${rel}"
    if [[ -f "${unoe_file}" ]]; then
      local dest_file="${dest_base}/${rel}"
      resolve_one_collision "${unoe_file}" "${dose_file}" "${dest_file}"
    fi
  done < <(find_files_pruned "${dose_base}")
}

resolve_conflicts() {
  log_status "Phase: resolve_conflicts"
  CURRENT_ACTION="resolve_conflicts"
  init_collision_logs
  init_provenance
  record_provenance_all

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY RUN: conflict resolution skipped" >> "${collision_log_actions}"
    return 0
  fi

  resolve_conflicts_in_bucket "${UNOE_ROOT}/ASH" "${DOSE_ROOT}/ASH" "${UNO_ROOT}/ASH"
  resolve_conflicts_in_bucket "${UNOE_ROOT}/Backups" "${DOSE_ROOT}/Backups" "${UNO_ROOT}/Backups"
  resolve_conflicts_in_bucket "${UNOE_ROOT}/Dropbox" "${DOSE_ROOT}/Dropbox" "${UNO_ROOT}/Dropbox"

  for key in "${!MAP[@]}"; do
    local dest_rel
    dest_rel="${MAP[${key}]}"
    resolve_conflicts_in_bucket "${UNOE_ROOT}/${key}" "${DOSE_ROOT}/${key}" "${UNO_ROOT}/${dest_rel}"
  done

  resolve_conflicts_in_bucket "${UNOE_ROOT}/found.000" "${DOSE_ROOT}/found.000" "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000"
}

verify_counts_bytes() {
  local output_file="${1}"
  CURRENT_ACTION="verify counts and bytes"
  {
    echo "UNO_ROOT=${UNO_ROOT}"
    date -u
    echo "File count:"; find "${UNO_ROOT}" -type f | wc -l
    echo "Dir count:"; find "${UNO_ROOT}" -type d | wc -l
    echo "Bytes:"; du -sb "${UNO_ROOT}"
  } > "${output_file}"
}

hash_sample_file=""

compute_hash_sample() {
  local output_file="${1}"
  hash_sample_file="${LOGDIR}/43_verify_hash_sample_list.txt"
  : > "${hash_sample_file}"

  local buckets=(
    "${UNO_ROOT}/01_Knowledge/01_Training/CBTs"
    "${UNO_ROOT}/02_Media/Video"
    "${UNO_ROOT}/03_Technology/01_Software/Games"
    "${UNO_ROOT}/03_Technology/01_Software/OS_Images"
    "${UNO_ROOT}/03_Technology/02_Virtualization/ESXi_VMs"
    "${UNO_ROOT}/04_Personal"
    "${UNO_ROOT}/Research"
  )

  if [[ -f "${collision_log_resolution}" ]]; then
    python3 - "${UNO_ROOT}" "${collision_log_resolution}" >> "${hash_sample_file}" <<'PY'
import csv
import os
import sys

uno_root = sys.argv[1]
csv_path = sys.argv[2]

try:
    with open(csv_path, newline='') as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row in reader:
            if not row:
                continue
            path = row[0]
            if not path:
                continue
            if path.startswith('/'):
                print(path)
            else:
                print(os.path.join(uno_root, path))
except Exception:
    pass
PY
  fi

  for bucket in "${buckets[@]}"; do
    if [[ -d "${bucket}" ]]; then
      python3 - "${RUN_ID}" "${bucket}" >> "${hash_sample_file}" <<'PY'
import os
import random
import sys

seed = sys.argv[1]
bucket = sys.argv[2]

rng = random.Random(f"{seed}|{bucket}")
files = []

try:
    for root, dirnames, filenames in os.walk(bucket):
        dirnames[:] = [d for d in dirnames if d not in ('$RECYCLE.BIN', 'System Volume Information')]
        for name in filenames:
            path = os.path.join(root, name)
            try:
                if os.path.isfile(path):
                    size = os.path.getsize(path)
                    files.append((size, path))
            except Exception:
                continue
except Exception:
    files = []

if not files:
    sys.exit(0)

files.sort(key=lambda item: item[0], reverse=True)
top_paths = [path for _, path in files[:50]]
all_paths = [path for _, path in files]

if len(all_paths) <= 200:
    sample_paths = list(all_paths)
else:
    sample_paths = rng.sample(all_paths, 200)

seen = set()
for path in top_paths + sample_paths:
    if path in seen:
        continue
    seen.add(path)
    print(path)
PY
    fi
  done

  python3 - "${hash_sample_file}" <<'PY' > "${hash_sample_file}.tmp"
import sys

src = sys.argv[1]
seen = set()

try:
    with open(src, 'r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            path = line.strip('\n')
            if not path:
                continue
            if path in seen:
                continue
            seen.add(path)
            print(path)
except Exception:
    pass
PY
  mv "${hash_sample_file}.tmp" "${hash_sample_file}"

  python3 - "${hash_sample_file}" "${output_file}" "${UNO_ROOT}" <<'PY'
import csv
import os
import sys
import hashlib

sample_list = sys.argv[1]
output_csv = sys.argv[2]
uno_root = sys.argv[3]

try:
    with open(output_csv, 'w', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(['path', 'sha256', 'size_bytes'])
        try:
            sample_handle = open(sample_list, 'r', encoding='utf-8', errors='replace')
        except Exception:
            sample_handle = None
        if sample_handle:
            with sample_handle:
                for line in sample_handle:
                    path = line.strip('\n')
                    if not path or not os.path.isfile(path):
                        continue
                    try:
                        size = os.path.getsize(path)
                    except Exception:
                        continue
                    rel_path = path[len(uno_root) + 1:] if path.startswith(uno_root + os.sep) else path
                    try:
                        sha256 = hashlib.sha256()
                        with open(path, 'rb') as data_handle:
                            for chunk in iter(lambda: data_handle.read(1024 * 1024), b''):
                                sha256.update(chunk)
                        digest = sha256.hexdigest()
                    except Exception:
                        continue
                    writer.writerow([rel_path, digest, size])
except Exception:
    pass
PY
}

verify_pre_dedupe() {
  log_status "Phase: verify_pre_dedupe"
  CURRENT_ACTION="verify_pre_dedupe"
  verify_counts_bytes "${LOGDIR}/40_verify_counts_bytes_pre_dedupe.txt"
  compute_hash_sample "${LOGDIR}/43_verify_hash_sample_pre_dedupe.csv"
}

dedupe_hardlinks() {
  log_status "Phase: dedupe_hardlinks"
  CURRENT_ACTION="dedupe_hardlinks"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY RUN: dedupe skipped" > "${LOGDIR}/60_dedupe_report.txt"
    return 0
  fi

  local dedupe_dirs=(
    "${UNO_ROOT}/01_Knowledge"
    "${UNO_ROOT}/02_Media"
    "${UNO_ROOT}/03_Technology"
    "${UNO_ROOT}/04_Personal"
    "${UNO_ROOT}/Research"
    "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders"
    "${UNO_ROOT}/90_System_Artifacts/Loose_Files"
    "${UNO_ROOT}/02_Media/Photos/_From_Root"
  )

  jdupes -r -L "${dedupe_dirs[@]}" 2>&1 | tee "${LOGDIR}/60_dedupe_report.txt"
  jdupes -r -L -v "${dedupe_dirs[@]}" 2>&1 > "${LOGDIR}/61_dedupe_actions.txt"
  jdupes -r -S "${dedupe_dirs[@]}" 2>&1 > "${LOGDIR}/62_dedupe_space_savings.txt"
}

compute_create_time_manifest() {
  log_status "Phase: compute_create_time_manifest"
  CURRENT_ACTION="compute_create_time_manifest"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY RUN: create time manifest skipped" > "${LOGDIR}/50_create_time_manifest.csv"
    return 0
  fi

  init_provenance
  if [[ ! -s "${provenance_file}" || "$(wc -l < "${provenance_file}")" -le 1 ]]; then
    echo "ERROR: Provenance file missing/empty; run provenance phase first." >&2
    exit 1
  fi
  python3 - "${provenance_file}" <<'PY'
import csv
import sys

path = sys.argv[1]
required = {
    'dest_path',
    'source_origin',
    'source_path',
    'src_create_time_utc',
    'create_time_status',
    'src_mtime_utc',
    'size_bytes',
    'sha256',
}
with open(path, newline='') as handle:
    reader = csv.DictReader(handle)
    header = reader.fieldnames or []
    if not required.issubset(set(header)):
        raise SystemExit("ERROR: Provenance file missing required headers.")
PY

  local manifest="${LOGDIR}/50_create_time_manifest.csv"
  local missing="${LOGDIR}/50_create_time_missing.csv"
  local instructions="${LOGDIR}/51_create_time_windows_apply_instructions.txt"

  python3 - "${provenance_file}" "${manifest}" "${missing}" "${UNO_ROOT}" <<'PY'
import csv
import os
import sys
from collections import defaultdict

provenance = sys.argv[1]
manifest = sys.argv[2]
missing = sys.argv[3]
uno_root = sys.argv[4]

sha_to_times = defaultdict(list)
sha_to_paths = defaultdict(list)
all_entries = []


def normalize_dest(path):
    if not path:
        return ""
    if path.startswith('/'):
        return path
    return os.path.join(uno_root, path)


try:
    with open(provenance, newline='') as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            dest_rel = (row.get('dest_path') or '').strip()
            sha = (row.get('sha256') or '').strip()
            ctime = (row.get('src_create_time_utc') or '').strip()
            status = (row.get('create_time_status') or '').strip()
            dest_abs = normalize_dest(dest_rel)
            all_entries.append((dest_rel, dest_abs, sha))
            if sha and dest_rel:
                sha_to_paths[sha].append(dest_rel)
            if sha and ctime and status == 'ok':
                sha_to_times[sha].append(ctime)
except Exception:
    pass

manifest_paths = {}
for sha, paths in sha_to_paths.items():
    times = sha_to_times.get(sha, [])
    if not times:
        continue
    earliest = sorted(times)[0]
    for path in paths:
        manifest_paths[path] = earliest

try:
    with open(manifest, 'w', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(['dest_path_relative_to_share', 'earliest_create_time_utc_iso8601'])
        for path, earliest in manifest_paths.items():
            writer.writerow([path, earliest])
except Exception:
    pass

missing_rows = {}
for dest_rel, dest_abs, sha in all_entries:
    if not dest_rel:
        continue
    if dest_rel in manifest_paths:
        continue
    if not dest_abs or not os.path.exists(dest_abs):
        reason = "destination_missing"
    elif not sha:
        reason = "missing_identity_key"
    else:
        reason = "missing_creation_time"
    missing_rows[(dest_rel, reason, sha)] = None

try:
    with open(missing, 'w', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(['dest_path', 'sha256'])
        for dest_rel, reason, sha in missing_rows.keys():
            writer.writerow([dest_rel, sha])
except Exception:
    pass
PY

  cat <<EOWIN > "${instructions}"
Apply creation times from Windows after copy completes.
This script does NOT apply creation times.

Example SMB path (update IP/share): \\192.168.1.123\UNO
Use the manifest at: ${manifest}
EOWIN
}

post_verify() {
  log_status "Phase: post_verify"
  CURRENT_ACTION="post_verify"
  verify_counts_bytes "${LOGDIR}/70_verify_counts_bytes_post_dedupe.txt"

  if [[ -f "${hash_sample_file}" ]]; then
    local output_file="${LOGDIR}/71_verify_hash_sample_post_dedupe.csv"
    echo "path,sha256,size_bytes" > "${output_file}"
    while IFS= read -r file; do
      if [[ -f "${file}" ]]; then
        local sha size
        sha="$(sha256_file "${file}")"
        size="$(size_bytes "${file}")"
        local rel_path
        rel_path="${file#${UNO_ROOT}/}"
        csv_row "${output_file}" "${rel_path}" "${sha}" "${size}"
      fi
    done < "${hash_sample_file}"
  fi
}

self_test() {
  log_status "Phase: self_test"
  CURRENT_ACTION="self_test"
  local script_path
  script_path="$(readlink -f "$0")"

  bash -n "${script_path}"

  local temp_dir
  temp_dir="$(mktemp -d)"
  trap '[[ -n "${temp_dir:-}" ]] && rm -rf "${temp_dir}"' EXIT

  local collision_csv="${temp_dir}/collision.csv"
  local provenance_csv="${temp_dir}/provenance.csv"

  echo "dest_path,classification,chosen_action,unoe_path,unoe_size,unoe_mtime_utc,unoe_sha256,dose_path,dose_size,dose_mtime_utc,dose_sha256,resulting_paths" > "${collision_csv}"
  csv_row "${collision_csv}" "path with spaces,comma\"quote" "conflict" "keep_both" "/src/path,one" "123" "2024-01-01T00:00:00Z" "sha1" "/src/path two" "456" "2024-01-02T00:00:00Z" "sha2" "result,path"

  echo "dest_path,source_origin,source_path,src_create_time_utc,create_time_status,src_mtime_utc,size_bytes,sha256" > "${provenance_csv}"
  csv_row "${provenance_csv}" "dest,with,comma\"quote" "UNOE" "/src/path with spaces" "2024-01-01T00:00:00Z" "ok" "2024-01-02T00:00:00Z" "123" "sha256value"

  python3 - "${collision_csv}" "${provenance_csv}" <<'PY'
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
    if "comma\"quote" not in row[0]:
        raise SystemExit(1)

with open(provenance, newline='') as handle:
    reader = csv.DictReader(handle)
    row = next(reader, None)
    if not row or 'dest_path' not in row:
        raise SystemExit(1)
    if "comma\"quote" not in row['dest_path']:
        raise SystemExit(1)
PY
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --self-test)
        SELF_TEST=true
        shift
        ;;
      --phase)
        PHASE="$2"
        shift 2
        ;;
      --run-id)
        RUN_ID="$2"
        shift 2
        ;;
      --log-dir)
        LOGDIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

run_phase() {
  local name="${1}"
  case "${name}" in
    self_test) self_test ;;
    preflight) preflight ;;
    prepare_dest) prepare_dest ;;
    copy_unoe) copy_unoe ;;
    copy_dose_overlay) copy_dose_overlay ;;
    resolve_conflicts) resolve_conflicts ;;
    verify_pre_dedupe) verify_pre_dedupe ;;
    dedupe_hardlinks) dedupe_hardlinks ;;
    compute_create_time_manifest) compute_create_time_manifest ;;
    post_verify) post_verify ;;
    all)
      preflight
      prepare_dest
      copy_unoe
      copy_dose_overlay
      resolve_conflicts
      verify_pre_dedupe
      dedupe_hardlinks
      compute_create_time_manifest
      post_verify
      ;;
    *)
      echo "ERROR: unknown phase: ${name}" >&2
      usage
      exit 1
      ;;
  esac
}

main() {
  parse_args "$@"
  if [[ "${SELF_TEST}" == "true" ]]; then
    self_test
    return 0
  fi
  require_root
  check_tools
  build_mapping
  init_run
  log_status "Starting run ${RUN_ID} (phase: ${PHASE}, dry-run: ${DRY_RUN})"
  run_phase "${PHASE}"
  normalize_permissions
  log_status "Completed"
}

main "$@"
