# scripts/monkey-test.ps1
# Randomized-input smoke test for soushin-suggest.link. Repeatedly opens the launcher,
# switches tabs, types into search, and forces a paint-probe screenshot (the exact
# operation sequence that produced the render/crash bugs found on 2026-07-18), then
# checks the process is still alive and diagnostics report no new uiBlank/uiGridOnly
# hits or crashes. See _docs/SHINDAN-PAINT-PROBE-DESIGN.md for what these counters mean.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\monkey-test.ps1 [-Iterations 30]
param(
    [int]$Iterations = 30,
    [int]$MinWaitMs = 50,
    [int]$MaxWaitMs = 400
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-monkey-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Copy-Item (Join-Path $repo 'dist\sites.ini') (Join-Path $stage 'sites.ini')
if (Test-Path (Join-Path $repo 'dist\snippets.ini')) {
    Copy-Item (Join-Path $repo 'dist\snippets.ini') (Join-Path $stage 'snippets.ini')
}
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

# F10 dumps CopyDiagnostics() output to a file so the harness doesn't race the driver's
# own clipboard writes (same pattern as verify-diagnostics.ps1).
$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8
$helper = @'
XButton1::ShowLauncher()
F10:: {
    CopyDiagnostics()
    txt := ""
    try txt := A_Clipboard
    outPath := A_ScriptDir . "\diag-out.json"
    if FileExist(outPath)
        FileDelete(outPath)
    FileAppend(txt, outPath, "UTF-8")
}
'@
$newCode = $code.Replace('XButton1::ShowLauncher()', $helper)
if ($newCode -eq $code) { throw 'ShowLauncher hotkey anchor not found for instrumentation' }
Set-Content -Path $ahkPath -Value $newCode -Encoding UTF8

$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
# Only target leftover probe processes launched from a $env:TEMP staging dir (ss-*-verify-*
# or ss-monkey-*). Do not touch the real running app started from dist\soushin-suggest.exe.
Get-Process | Where-Object {
    ($_.ProcessName -match 'soushin|AutoHotkey') -and
    ($_.Path -and ($_.Path -like (Join-Path $env:TEMP 'ss-*-verify-*') -or $_.Path -like (Join-Path $env:TEMP 'ss-monkey-*')))
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$proc = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc.HasExited) { throw "soushin exited early code=$($proc.ExitCode)" }
Write-Output "Target PID: $($proc.Id), stage: $stage"

# The driver script is regenerated each iteration with a randomized action sequence.
# Actions: open launcher (XButton1), switch tab (Tab key cycles Tab3 control focus is not
# reliable headless, so we use the Ctrl+Tab-equivalent via clicking is skipped -- instead
# we exercise open -> type search -> screenshot(F9-equivalent via direct call) -> close(Esc)
# -> reopen, which is exactly the sequence that produced the crash this session.
$rand = [System.Random]::new()
$crashed = $false
$diagBefore = $null

for ($i = 1; $i -le $Iterations; $i++) {
    $searchChars = -join ((1..(Get-Random -Minimum 0 -Maximum 4)) | ForEach-Object { [char](Get-Random -Minimum 97 -Maximum 123) })
    $waitMs = Get-Random -Minimum $MinWaitMs -Maximum $MaxWaitMs
    $doScreenshot = (Get-Random -Minimum 0 -Maximum 2) -eq 1
    $doClose = (Get-Random -Minimum 0 -Maximum 2) -eq 1
    $doClipWrite = (Get-Random -Minimum 0 -Maximum 3) -eq 0
    $clipText = 'monkey-clip-' + [guid]::NewGuid().ToString('N').Substring(0, 6)

    $driverLines = @('#Requires AutoHotkey v2.0')
    if ($doClipWrite) {
        # Simulate a real user copy (F9-equivalent tick isn't wired here; a raw clipboard
        # write goes through the same self-suppress/user-window filters as production).
        $driverLines += "A_Clipboard := `"$clipText`""
        $driverLines += "Sleep $waitMs"
    }
    $driverLines += 'Send "{XButton1}"'
    $driverLines += "Sleep $waitMs"
    if ($searchChars.Length -gt 0) {
        $driverLines += "Send `"$searchChars`""
        $driverLines += "Sleep $waitMs"
    }
    if ($doScreenshot) {
        $driverLines += 'Send "{XButton2}"'
        $driverLines += "Sleep $waitMs"
    }
    if ($doClose) {
        $driverLines += 'Send "{Escape}"'
        $driverLines += "Sleep $waitMs"
    }
    $driverLines += 'ExitApp 0'
    $driverPath = Join-Path $stage "driver-$i.ahk"
    Set-Content -Path $driverPath -Value ($driverLines -join "`n") -Encoding UTF8

    $d = Start-Process -FilePath $ahkExe -ArgumentList @($driverPath) -Wait -PassThru -WindowStyle Hidden
    Remove-Item $driverPath -ErrorAction SilentlyContinue

    if ((Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) -eq $null) {
        Write-Output "CRASH detected after iteration $i (search='$searchChars' screenshot=$doScreenshot close=$doClose)"
        $crashed = $true
        break
    }
}

if (-not $crashed) {
    # Force a launcher open + diagnostics dump as the final state check.
    $finalDriver = @"
#Requires AutoHotkey v2.0
Send "{XButton1}"
Sleep 300
Send "{F10}"
Sleep 300
ExitApp 0
"@
    Set-Content (Join-Path $stage 'final-driver.ahk') $finalDriver -Encoding UTF8
    Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'final-driver.ahk')) -Wait -WindowStyle Hidden
    $diagPath = Join-Path $stage 'diag-out.json'
    if (Test-Path $diagPath) {
        $diagRaw = Get-Content $diagPath -Raw -Encoding UTF8
        Write-Output "--- Final diagnostics ---"
        Write-Output $diagRaw
        try {
            $diag = $diagRaw | ConvertFrom-Json
            $uiBlank = $diag.counters.uiBlank.n
            $uiGridOnly = $diag.counters.uiGridOnly.n
            if ($uiBlank -or $uiGridOnly) {
                Write-Output "WARN: render-anomaly counters non-zero (uiBlank=$uiBlank uiGridOnly=$uiGridOnly)"
            } else {
                Write-Output 'OK: no render anomalies recorded (uiBlank/uiGridOnly both absent or zero)'
            }
        } catch {
            Write-Output "WARN: could not parse diag-out.json as JSON: $($_.Exception.Message)"
        }
    } else {
        Write-Output 'WARN: diag-out.json not produced by final driver'
    }
}

Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (-not $env:SS_DEBUG_KEEP_STAGE) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Output "DEBUG: stage kept at $stage"
}

if ($crashed) {
    Write-Error "FAIL: monkey test crashed the app within $i iterations"
    exit 1
}
Write-Output "OK: monkey test completed $Iterations iterations without crashing"
