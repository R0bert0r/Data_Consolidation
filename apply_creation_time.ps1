# Usage examples:
#   .\apply_creation_time.ps1 -ManifestPath "50_create_time_manifest.csv" -ShareRoot "\\192.168.1.123\UNO"
#   .\apply_creation_time.ps1 -ManifestPath "C:\manifests\50_create_time_manifest.csv" -ShareRoot "\\192.168.1.123\UNO" -LogPath "C:\logs\apply_creation_time.log" -WhatIf
#   .\apply_creation_time.ps1 -ManifestPath "50_create_time_manifest.csv" -ShareRoot "\\192.168.1.123\UNO" -RetryCount 3 -MaxErrors 200

[CmdletBinding()]
param(
    [string]$ManifestPath = "50_create_time_manifest.csv",
    [Parameter(Mandatory = $true)]
    [string]$ShareRoot,
    [string]$LogPath = (Join-Path (Get-Location) "apply_creation_time.log"),
    [switch]$WhatIf,
    [int]$MaxErrors = 100,
    [int]$RetryCount = 2
)

Set-StrictMode -Version Latest

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data
    )

    $record = [ordered]@{
        timestamp_utc = [DateTime]::UtcNow.ToString("o")
    }

    foreach ($key in $Data.Keys) {
        $record[$key] = $Data[$key]
    }

    $json = $record | ConvertTo-Json -Compress
    Add-Content -LiteralPath $LogPath -Value $json -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Log -Data @{
        level = "error"
        status = "missing_manifest"
        manifest_path = $ManifestPath
        message = "Manifest file not found."
    }
    exit 1
}

$rows = Import-Csv -LiteralPath $ManifestPath -Encoding UTF8

$total = 0
$applied = 0
$skipped = 0
$missing = 0
$failed = 0
$stopDueToErrors = $false

foreach ($row in $rows) {
    $total++

    $relative = [string]$row.dest_path_relative_to_share
    $isoTime = [string]$row.earliest_create_time_utc_iso8601

    if ([string]::IsNullOrWhiteSpace($relative) -or [string]::IsNullOrWhiteSpace($isoTime)) {
        $failed++
        Write-Log -Data @{
            level = "error"
            status = "invalid_row"
            relative_path = $relative
            desired_time_utc = $isoTime
            message = "Row missing required fields."
        }
        if ($failed -gt $MaxErrors) {
            $stopDueToErrors = $true
            break
        }
        continue
    }

    $relative = $relative.TrimStart("\", "/")
    $fullPath = Join-Path -Path $ShareRoot -ChildPath $relative

    try {
        $desiredTime = [DateTime]::Parse(
            $isoTime,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    } catch {
        $failed++
        Write-Log -Data @{
            level = "error"
            status = "invalid_time"
            path = $fullPath
            desired_time_utc = $isoTime
            message = $_.Exception.Message
        }
        if ($failed -gt $MaxErrors) {
            $stopDueToErrors = $true
            break
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPath)) {
        $missing++
        Write-Log -Data @{
            level = "warn"
            status = "missing_path"
            path = $fullPath
            desired_time_utc = $desiredTime.ToString("o")
            message = "Path not found."
        }
        continue
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    $currentTime = $item.CreationTimeUtc
    $deltaSeconds = [Math]::Abs(($currentTime - $desiredTime).TotalSeconds)

    if ($deltaSeconds -le 2) {
        $skipped++
        Write-Log -Data @{
            level = "info"
            status = "skipped"
            path = $fullPath
            current_time_utc = $currentTime.ToString("o")
            desired_time_utc = $desiredTime.ToString("o")
            message = "Creation time already within tolerance."
        }
        continue
    }

    if ($WhatIf) {
        $skipped++
        Write-Log -Data @{
            level = "info"
            status = "whatif"
            path = $fullPath
            current_time_utc = $currentTime.ToString("o")
            desired_time_utc = $desiredTime.ToString("o")
            message = "WhatIf enabled. No changes applied."
        }
        continue
    }

    $setSucceeded = $false
    $lastError = $null

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $item.CreationTimeUtc = $desiredTime
            $item.Refresh()
            $setSucceeded = $true
            break
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 1
        }
    }

    if ($setSucceeded) {
        $applied++
        Write-Log -Data @{
            level = "info"
            status = "applied"
            path = $fullPath
            previous_time_utc = $currentTime.ToString("o")
            desired_time_utc = $desiredTime.ToString("o")
            message = "Creation time updated."
        }
    } else {
        $failed++
        Write-Log -Data @{
            level = "error"
            status = "failed"
            path = $fullPath
            desired_time_utc = $desiredTime.ToString("o")
            message = $lastError
        }
        if ($failed -gt $MaxErrors) {
            $stopDueToErrors = $true
            break
        }
    }
}

Write-Log -Data @{
    level = "info"
    status = "summary"
    total_rows = $total
    applied = $applied
    skipped = $skipped
    missing = $missing
    failed = $failed
    max_errors = $MaxErrors
    stopped_due_to_errors = $stopDueToErrors
}

if ($failed -gt 0 -or $stopDueToErrors) {
    if ($failed -gt $MaxErrors) {
        exit 2
    }
    exit 1
}

exit 0
