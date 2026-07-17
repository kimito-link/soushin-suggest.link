# scripts/verify-all.ps1
# Runs every Phase1 safety-net probe in sequence. Stops at the first failure.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-all.ps1
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

$probes = @(
    'verify-clip-filter.ps1'
    'verify-archive-quarantine.ps1'
    'verify-clibor-import.ps1'
    'verify-diagnostics.ps1'
    'verify-history-persist.ps1'
    'verify-snippet-promote.ps1'
)

foreach ($probe in $probes) {
    $path = Join-Path $scriptDir $probe
    Write-Output "=== Running $probe ==="
    & powershell -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        Write-Error "FAILED: $probe (exit=$LASTEXITCODE)"
        exit 1
    }
}

Write-Output ''
Write-Output "=== Running verify-numkey-hotif.ahk ==="
$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
& $ahkExe (Join-Path $scriptDir 'verify-numkey-hotif.ahk')
if ($LASTEXITCODE -ne 0) {
    Write-Error "FAILED: verify-numkey-hotif.ahk (exit=$LASTEXITCODE)"
    exit 1
}
Write-Output 'PASS numkey-hotif'

Write-Output ''
Write-Output 'OK all Phase1 probes passed'
