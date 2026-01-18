# UNOE/DOSE to UNO Consolidation Workflow

## Summary
This workflow consolidates two source shares (UNOE and DOSE) into a single UNO share by performing a controlled copy/merge, resolving conflicts deterministically, and verifying the result with hashes before proceeding. After the merge, it optionally performs hardlink-based deduplication to reduce space while preserving file content, and it generates a creation-time manifest to allow a Windows-side step that re-applies creation timestamps that Linux cannot preserve. The process is structured to be resumable, with clear logging and per-phase outputs to validate correctness before moving forward.

## Preconditions
- **Write freeze is imposed** on UNOE and DOSE for the duration of the workflow.
- **UNO share settings**:
  - Store DOS attributes **enabled**
  - Extended attributes (xattrs) **enabled**
  - Recycle bin **disabled**
- **Run as `tom` via sudo** (ownership and ACL expectations assume `tom:sambashare`).

## Tools Required on OMV
Install the following tools on the OMV host before running the workflow:

```bash
sudo apt-get update
sudo apt-get install -y \
  rsync \
  jdupes \
  attr \
  coreutils \
  xattr \
  findutils \
  gawk
```

Additional utilities used by the scripts (typically already present):
- `sha256sum` (from `coreutils`)
- `getfattr` / `setfattr` (from `attr`)
- `rsync`
- `jdupes`

## Paths and Ownership
- `UNOE_ROOT=/srv/dev-disk-by-uuid-9E0E3E860E3E580B`
- `DOSE_ROOT=/srv/dev-disk-by-uuid-2B0BF1C64E9BEBE1`
- `UNO_ROOT=/srv/dev-disk-by-uuid-92c1be66-0355-44da-b61b-8d4029d3f2c4`
- Ownership target: `tom:sambashare`

## Files Produced and Log Locations
Each run produces a uniquely named `RUN_ID` directory. The directory layout follows this pattern:

```
./runs/<RUN_ID>/
  logs/
    phase1_copy_unoe.log
    phase2_copy_dose.log
    phase3_verify.log
    phase4_dedupe.log
    phase5_manifest.log
  manifests/
    creation_time_manifest.csv
  verification/
    unoe_hashes.sha256
    dose_hashes.sha256
    uno_hashes.sha256
    verification_summary.txt
  rsync/
    unoe_rsync.log
    dose_rsync.log
  reports/
    conflicts_report.txt
    dedupe_report.txt
```

> The exact filenames may vary by script options, but all logs and artifacts are contained under `./runs/<RUN_ID>/`.

## How to Run
> **Always run as `tom` via sudo** and ensure the write freeze is in effect.

### Dry-Run
Use dry-run mode to validate what will be copied/merged without changing UNO:

```bash
sudo -u tom ./run.sh --dry-run --run-id <RUN_ID>
```

Review the rsync logs and conflict report before proceeding.

### Phase-by-Phase
Run each phase explicitly so you can review outputs between steps:

```bash
# Phase 1: copy UNOE into UNO
sudo -u tom ./run.sh --phase copy-unoe --run-id <RUN_ID>

# Phase 2: copy DOSE into UNO (conflict handling enabled)
sudo -u tom ./run.sh --phase copy-dose --run-id <RUN_ID>

# Phase 3: verification (hashing + comparison)
sudo -u tom ./run.sh --phase verify --run-id <RUN_ID>

# Phase 4: hardlink dedupe
sudo -u tom ./run.sh --phase dedupe --run-id <RUN_ID>

# Phase 5: creation-time manifest generation
sudo -u tom ./run.sh --phase manifest --run-id <RUN_ID>
```

### Full Run
Run all phases sequentially:

```bash
sudo -u tom ./run.sh --run-id <RUN_ID>
```

### Resume After Failure
If a phase fails, fix the issue and re-run **only the failed phase** with the same `RUN_ID`:

```bash
sudo -u tom ./run.sh --phase <failed-phase> --run-id <RUN_ID>
```

The workflow is designed to be idempotent for completed phases, so re-running a prior successful phase is safe but unnecessary.

## Conflict Handling
When both UNOE and DOSE contain the same relative path, the conflict strategy is:

1. Compare timestamps and sizes.
2. If the **newer file is also larger**, keep the **newer** file.
3. Otherwise, **keep both** by suffixing the conflicting file name.

Suffixing is **idempotent**. If the same conflict is encountered again, the script will not create duplicate suffixes; it will recognize and preserve the previously suffixed filename.

## Verification Outputs and What to Check
Verification produces SHA-256 hash lists for UNOE, DOSE, and UNO. Review `verification_summary.txt` and confirm:

- All expected files are present in UNO.
- Any conflicts are documented in `conflicts_report.txt`.
- Hash mismatches are investigated and resolved before proceeding to dedupe.

If there are mismatches, do **not** proceed to hardlink dedupe or manifest generation until the cause is understood.

## Hardlink Dedupe (jdupes)
The dedupe phase uses `jdupes` to replace identical files with hardlinks to a single inode, reducing space usage.

**Scope:**
- Dedupe **excludes** `ASH/Backups/Dropbox`.
- Dedupe **excludes** `90_System_Artifacts`.

**Caution:**
- Hardlinked files share the same inode. **Editing one file modifies all hardlinked copies.**
- Only run dedupe after verification passes.

## Windows Creation-Time Apply Step
Linux cannot preserve Windows creation time (`ctime`) during file operations, so a manifest is generated for a Windows-side apply step.

- **Manifest location:** `./runs/<RUN_ID>/manifests/creation_time_manifest.csv`

### Example PowerShell Command
```powershell
.\Apply-CreationTime.ps1 -ManifestPath "C:\path\to\creation_time_manifest.csv" -ShareRoot "\\UNO\share"
```

### Validate in Windows Explorer
After applying creation times:
1. Open Windows Explorer and check several representative directories.
2. Confirm **Created** timestamps match expectations for key files.
3. Spot-check files that were in conflict to ensure the correct version is present.

## Safety Notes
- **No writes to sources** occur (UNOE/DOSE are only read for file content and metadata). The workflow reads metadata and file contents for hashing and comparison.
- **Access times (atime) may change** due to reads.
- **Creation times (ctime) cannot be preserved** on Linux because `ctime` is inode change time, not Windows creation time. The Windows apply step restores creation timestamps using the manifest.
