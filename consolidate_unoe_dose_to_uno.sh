#!/usr/bin/env bash
set -euo pipefail

# Consolidate UNOE and DOSE into UNO with taxonomy mapping, conflict handling,
# provenance tracking, verification, and dedupe.

SCRIPT_NAME="$(basename "$0")"

UNOE_ROOT="/srv/dev-disk-by-uuid-9E0E3E860E3E580B"
DOSE_ROOT="/srv/dev-disk-by-uuid-2B0BF1C64E9BEBE1"
UNO_ROOT="/srv/dev-disk-by-uuid-92c1be66-0355-44da-b61b-8d4029d3f2c4"

RUN_ID=""
LOGDIR=""
DRY_RUN=false
PHASE="all"

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
  local tools=(rsync find stat sha256sum getfattr setfattr jdupes)
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

rsync_excludes() {
  RSYNC_EXCLUDES=(
    "--exclude=\$RECYCLE.BIN/"
    "--exclude=\$RECYCLE.BIN/***"
    "--exclude=System Volume Information/"
    "--exclude=System Volume Information/***"
  )
}

rsync_common_flags() {
  RSYNC_COMMON_FLAGS=(-a --itemize-changes --stats --chown=tom:sambashare)
}

run_rsync() {
  local src="${1}"
  local dest="${2}"
  local extra_flags="${3}"
  local log_file="${4}"
  local -a cmd
  local -a extra=()
  rsync_common_flags
  rsync_excludes
  if [[ -n "${extra_flags}" ]]; then
    extra=(${extra_flags})
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
  local extra_flags="${3}"
  local log_file="${4}"
  local -a cmd
  local -a extra=()
  rsync_common_flags
  rsync_excludes
  if [[ -n "${extra_flags}" ]]; then
    extra=(${extra_flags})
  fi
  cmd=(rsync "${RSYNC_COMMON_FLAGS[@]}" "${RSYNC_EXCLUDES[@]}" --dry-run)
  cmd+=("${extra[@]}" "${src}" "${dest}")
  CURRENT_ACTION="verify rsync dry-run ${src} -> ${dest}"
  "${cmd[@]}" 2>&1 | tee "${log_file}"
}

normalize_permissions() {
  CURRENT_ACTION="normalize permissions"
  chown -R tom:sambashare "${UNO_ROOT}"
  find "${UNO_ROOT}" -type d -exec chmod 2775 {} +
  find "${UNO_ROOT}" -type f -exec chmod 664 {} +
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

is_excluded_name() {
  local name="${1}"
  if [[ "${name}" == "\$RECYCLE.BIN" || "${name}" == "System Volume Information" ]]; then
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
  local extra_flags=""
  local folders=("ASH" "Backups" "Dropbox")
  if [[ "${overlay}" == "true" ]]; then
    extra_flags="--ignore-existing"
  fi
  for folder in "${folders[@]}"; do
    if [[ -d "${src_root}/${folder}" ]]; then
      run_rsync "${src_root}/${folder}/" "${UNO_ROOT}/${folder}/" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${src_root}/${folder}/" "${UNO_ROOT}/${folder}/" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_${folder}_${origin}.txt"
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
  local extra_flags=""
  if [[ "${overlay}" == "true" ]]; then
    extra_flags="--ignore-existing"
  fi

  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"

    if is_excluded_name "${name}"; then
      continue
    fi

    if [[ "${name}" == "ASH" || "${name}" == "Backups" || "${name}" == "Dropbox" ]]; then
      continue
    fi

    if [[ "${name}" == "found.000" ]]; then
      run_rsync "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000/" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Recovery/found.000/" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_found.000_${origin}.txt"
      continue
    fi

    if [[ -n "${MAP[${name}]:-}" ]]; then
      run_rsync "${entry}/" "${UNO_ROOT}/${MAP[${name}]}/" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/${MAP[${name}]}/" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_${name}_${origin}.txt"
    else
      run_rsync "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/${origin}/${name}/" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${entry}/" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/${origin}/${name}/" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_unmapped_${name}_${origin}.txt"
    fi
  done < <(find "${src_root}" -mindepth 1 -maxdepth 1 -type d -print0)
}

copy_loose_files() {
  local src_root="${1}"
  local origin="${2}"
  local phase_label="${3}"
  local overlay="${4}"
  local verify_prefix="${5}"
  local extra_flags=""
  if [[ "${overlay}" == "true" ]]; then
    extra_flags="--ignore-existing"
  fi

  local log_file="${LOGDIR}/${phase_label}_loose_${origin}.log"

  while IFS= read -r -d '' file; do
    local base
    base="$(basename "${file}")"
    if is_excluded_name "${base}"; then
      continue
    fi
    if is_image_file "${base}"; then
      run_rsync "${file}" "${UNO_ROOT}/02_Media/Photos/_From_Root/${origin}/${base}" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${file}" "${UNO_ROOT}/02_Media/Photos/_From_Root/${origin}/${base}" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_loose_images_${origin}.txt"
    else
      run_rsync "${file}" "${UNO_ROOT}/90_System_Artifacts/Loose_Files/${origin}/${base}" "${extra_flags}" "${log_file}"
      verify_rsync_dryrun "${file}" "${UNO_ROOT}/90_System_Artifacts/Loose_Files/${origin}/${base}" "${extra_flags}" "${LOGDIR}/${verify_prefix}_verify_dryrun_loose_files_${origin}.txt"
    fi
  done < <(find "${src_root}" -mindepth 1 -maxdepth 1 -type f -print0)
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
  local attr
  local value
  local parsed
  for attr in system.ntfs_crtime_be user.ntfs_crtime; do
    if value="$(getfattr -n "${attr}" --only-values --absolute-names "${file}" 2>/dev/null)"; then
      if [[ -n "${value}" ]]; then
        if [[ "${attr}" == "system.ntfs_crtime_be" ]]; then
          if parsed="$(python3 - <<'PY'
import sys
value = sys.stdin.read().strip()
try:
    data = bytes.fromhex(value)
    if len(data) != 8:
        raise ValueError("length")
    ts = int.from_bytes(data, byteorder='big', signed=False)
    epoch = (ts / 10_000_000) - 11644473600
    if epoch < 0:
        raise ValueError("negative")
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
    print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    sys.exit(1)
PY
<<<"${value}" 2>/dev/null)"; then
            echo "${parsed}|ok"
            return 0
          fi
        else
          if parsed="$(python3 - <<'PY'
import sys
value = sys.stdin.read().strip()
try:
    from datetime import datetime, timezone
    if value.isdigit():
        epoch = int(value)
        dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
        print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
    else:
        raise ValueError("format")
except Exception:
    sys.exit(1)
PY
<<<"${value}" 2>/dev/null)"; then
            echo "${parsed}|ok"
            return 0
          fi
        fi
        echo "|parse_error"
        return 0
      fi
    fi
  done
  echo "|missing"
}

provenance_file=""

init_provenance() {
  provenance_file="${LOGDIR}/33_dest_provenance.csv"
  if [[ ! -f "${provenance_file}" ]]; then
    echo "dest_path,source_origin,source_path,src_create_time_utc,create_time_status,src_mtime_utc,size_bytes,sha256" > "${provenance_file}"
  fi
}

update_provenance() {
  local dest_rel="${1}"
  local origin="${2}"
  local src_path="${3}"
  local create_time="${4}"
  local create_status="${5}"
  local src_mtime="${6}"
  local size="${7}"
  local sha="${8}"

  local tmp
  tmp="${provenance_file}.tmp"
  awk -F, -v dest="${dest_rel}" 'NR==1{print;next} $1!=dest {print}' "${provenance_file}" > "${tmp}"
  echo "${dest_rel},${origin},${src_path},${create_time},${create_status},${src_mtime},${size},${sha}" >> "${tmp}"
  mv "${tmp}" "${provenance_file}"
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
      update_provenance "${dest_rel}" "${origin}" "${file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
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
    if is_excluded_name "${name}"; then
      continue
    fi
    if [[ -z "${MAP[${name}]:-}" && "${name}" != "ASH" && "${name}" != "Backups" && "${name}" != "Dropbox" && "${name}" != "found.000" ]]; then
      record_provenance_for_bucket "${entry}" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/UNOE/${name}" "UNOE"
    fi
  done < <(find "${UNOE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0)

  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"
    if is_excluded_name "${name}"; then
      continue
    fi
    if [[ -z "${MAP[${name}]:-}" && "${name}" != "ASH" && "${name}" != "Backups" && "${name}" != "Dropbox" && "${name}" != "found.000" ]]; then
      record_provenance_for_bucket "${entry}" "${UNO_ROOT}/90_System_Artifacts/Unmapped_Folders/DOSE/${name}" "DOSE"
    fi
  done < <(find "${DOSE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0)
  record_provenance_loose_files "${UNOE_ROOT}" "UNOE"
  record_provenance_loose_files "${DOSE_ROOT}" "DOSE"
}

record_provenance_loose_files() {
  local src_root="${1}"
  local origin="${2}"

  while IFS= read -r -d '' file; do
    local base
    base="$(basename "${file}")"
    if is_excluded_name "${base}"; then
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
      update_provenance "${dest_rel}" "${origin}" "${file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${dest_sha}"
    fi
  done < <(find_top_level_files "${src_root}")
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
    echo "${dest_file},${classification},${action},${unoe_file},${unoe_size},${unoe_mtime},${unoe_sha},${dose_file},${dose_size},${dose_mtime},${dose_sha},${resulting_paths}" >> "${collision_log_candidates}"
    return 0
  fi

  classification="conflict"
  echo "${dest_file},${classification},pending,${unoe_file},${unoe_size},${unoe_mtime},${unoe_sha},${dose_file},${dose_size},${dose_mtime},${dose_sha}," >> "${collision_log_candidates}"

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
    if [[ -f "${dest_file}" ]]; then
      local dest_sha
      dest_sha="$(sha256_file "${dest_file}")"
      local newest_sha
      newest_sha="$(sha256_file "${newest_file}")"
      if [[ "${dest_sha}" != "${newest_sha}" ]]; then
        if [[ "${DRY_RUN}" == "false" ]]; then
          rm -f "${dest_file}"
          rsync -a --itemize-changes --stats --chown=tom:sambashare "${newest_file}" "${dest_file}" >> "${collision_log_actions}"
        fi
      fi
    else
      if [[ "${DRY_RUN}" == "false" ]]; then
        rsync -a --itemize-changes --stats --chown=tom:sambashare "${newest_file}" "${dest_file}" >> "${collision_log_actions}"
      fi
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

  echo "${dest_file},${classification},${action},${unoe_file},${unoe_size},${unoe_mtime},${unoe_sha},${dose_file},${dose_size},${dose_mtime},${dose_sha},${resulting_paths}" >> "${collision_log_resolution}"

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
      update_provenance "${dest_rel}" "UNOE" "${unoe_file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
    else
      create_info="$(get_create_time "${dose_file}")"
      create_time="${create_info%%|*}"
      create_status="${create_info##*|}"
      mtime="$(mtime_utc "${dose_file}")"
      size="${dose_size}"
      sha="${dose_sha}"
      update_provenance "${dest_rel}" "DOSE" "${dose_file}" "${create_time}" "${create_status}" "${mtime}" "${size}" "${sha}"
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
      update_provenance "${suffixed_rel}" "${other_suffix}" "${other_file}" "${other_time}" "${other_status}" "${other_mtime}" "${other_size}" "${other_sha}"
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
  local seed="${RUN_ID}"
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

  for bucket in "${buckets[@]}"; do
    if [[ -d "${bucket}" ]]; then
      find "${bucket}" -type f -printf '%s\t%p\n' | sort -nr | head -n 50 | awk '{print $2}' >> "${hash_sample_file}"
      python3 - "${seed}" "${bucket}" >> "${hash_sample_file}" <<'PY'
import os, random, sys
seed = sys.argv[1]
path = sys.argv[2]
random.seed(seed)
files = []
for root, _, names in os.walk(path):
    for name in names:
        files.append(os.path.join(root, name))
if files:
    sample = files if len(files) <= 200 else random.sample(files, 200)
    for item in sample:
        print(item)
PY
    fi
  done

  if [[ -f "${collision_log_resolution}" ]]; then
    awk -F, 'NR>1 {print $1}' "${collision_log_resolution}" | while read -r rel; do
      if [[ -n "${rel}" ]]; then
        echo "${UNO_ROOT}/${rel}" >> "${hash_sample_file}"
      fi
    done
  fi

  sort -u "${hash_sample_file}" | grep -v '^$' > "${hash_sample_file}.tmp"
  mv "${hash_sample_file}.tmp" "${hash_sample_file}"

  echo "path,sha256,size_bytes" > "${output_file}"
  while IFS= read -r file; do
    if [[ -f "${file}" ]]; then
      local sha size
      sha="$(sha256_file "${file}")"
      size="$(size_bytes "${file}")"
      echo "${file#${UNO_ROOT}/},${sha},${size}" >> "${output_file}"
    fi
  done < "${hash_sample_file}"
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
  )

  jdupes -r -L -Q "${dedupe_dirs[@]}" | tee "${LOGDIR}/60_dedupe_report.txt"
  jdupes -r -L -Q -v "${dedupe_dirs[@]}" > "${LOGDIR}/61_dedupe_actions.txt"
  jdupes -r -S "${dedupe_dirs[@]}" > "${LOGDIR}/62_dedupe_space_savings.txt"
}

compute_create_time_manifest() {
  log_status "Phase: compute_create_time_manifest"
  CURRENT_ACTION="compute_create_time_manifest"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY RUN: create time manifest skipped" > "${LOGDIR}/50_create_time_manifest.csv"
    return 0
  fi

  local manifest="${LOGDIR}/50_create_time_manifest.csv"
  local missing="${LOGDIR}/50_create_time_missing.csv"
  local instructions="${LOGDIR}/51_create_time_windows_apply_instructions.txt"

  python3 - "${provenance_file}" "${manifest}" "${missing}" <<'PY'
import csv
import sys
from collections import defaultdict

provenance = sys.argv[1]
manifest = sys.argv[2]
missing = sys.argv[3]

sha_to_times = defaultdict(list)
sha_to_paths = defaultdict(list)

with open(provenance, newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        sha = row['sha256']
        ctime = row['src_create_time_utc']
        status = row['create_time_status']
        dest = row['dest_path']
        if sha and dest:
            sha_to_paths[sha].append(dest)
        if ctime and status == 'ok':
            sha_to_times[sha].append(ctime)

with open(manifest, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['dest_path_relative_to_share', 'earliest_create_time_utc_iso8601'])
    for sha, paths in sha_to_paths.items():
        if sha in sha_to_times and sha_to_times[sha]:
            earliest = sorted(sha_to_times[sha])[0]
            for path in paths:
                writer.writerow([path, earliest])

with open(missing, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['dest_path', 'sha256'])
    for sha, paths in sha_to_paths.items():
        if sha not in sha_to_times or not sha_to_times[sha]:
            for path in paths:
                writer.writerow([path, sha])
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
    echo "path,sha256,size_bytes" > "${LOGDIR}/71_verify_hash_sample_post_dedupe.csv"
    while IFS= read -r file; do
      if [[ -f "${file}" ]]; then
        local sha size
        sha="$(sha256_file "${file}")"
        size="$(size_bytes "${file}")"
        echo "${file#${UNO_ROOT}/},${sha},${size}" >> "${LOGDIR}/71_verify_hash_sample_post_dedupe.csv"
      fi
    done < "${hash_sample_file}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
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
  require_root
  check_tools
  build_mapping
  init_run
  log_status "Starting run ${RUN_ID} (phase: ${PHASE}, dry-run: ${DRY_RUN})"
  run_phase "${PHASE}"
  if [[ "${DRY_RUN}" == "false" ]]; then
    normalize_permissions
  fi
  log_status "Completed"
}

main "$@"
