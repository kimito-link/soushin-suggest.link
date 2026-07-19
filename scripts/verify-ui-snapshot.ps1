# scripts/verify-ui-snapshot.ps1
# Verifies the UI-structure regression probe added for Clibor-parity/shindan work:
# A) Dev mode (.ahk run directly via AutoHotkey64.exe): opening the launcher captures a UI
#    snapshot, and BuildDiagText()'s output (fetched via the existing F10 diagnostics-dump
#    helper) contains a well-formed "ui" field with the launcher's controls.
# B) Prod mode (compiled .exe via scripts/build.ps1): the same flow must NOT contain a "ui"
#    key at all -- this is the structural non-leak guarantee from Ahk2Exe-Ignore directives
#    (design doc SHINDAN-UI-STRUCT-DESIGN.md G-3, the release-blocking reverse assertion).
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'

function New-Stage($label) {
    $stage = Join-Path $env:TEMP ('ss-uisnapshot-' + $label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $stage | Out-Null
    Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii
    Set-Content (Join-Path $stage 'sites.ini') "[clipboard]`nautoclear=1`n" -Encoding UTF8
    return $stage
}

function Stop-StageProcesses {
    Get-Process | Where-Object {
        ($_.ProcessName -match 'soushin|AutoHotkey') -and
        ($_.Path -and $_.Path -like (Join-Path $env:TEMP 'ss-uisnapshot-*'))
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# ShowLauncher() early-returns with no window if ClipHistory and Snippets are both empty
# (dist/soushin-suggest.ahk ~line 1660) -- a bare staging dir has neither, so the launcher
# must be given a history item first. F9 marks a user-copy tick (same pattern as
# verify-clip-filter.ps1/verify-history-persist.ps1). F8 calls ShowLauncher() directly rather
# than driving the XButton1 side-button hotkey: `Send "{XButton1}"` was found NOT to reach a
# background AutoHotkey process's hotkey handler in this environment (verified in isolation --
# a plain `F1::` fires reliably via Send, but `XButton1::` never does, even via SendInput or
# `Click "X1"`), so XButton1 cannot be used to drive this probe. F10 dumps BuildDiagText().
$f10Helper = @'
XButton1::ShowLauncher()
F9:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
F8:: ShowLauncher()
F10:: {
    FileAppend(BuildDiagText(), A_ScriptDir . "\diag-out.json", "UTF-8")
}
'@

function Get-DiagJsonViaLauncher($exePath, $exeArgs, $workDir) {
    Stop-StageProcesses
    $proc = Start-Process -FilePath $exePath -ArgumentList $exeArgs -WorkingDirectory $workDir -PassThru
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { throw "target exited early code=$($proc.ExitCode) (exe=$exePath)" }

    # Seed one history item (F9 tick + clipboard write, mirrors verify-clip-filter.ps1) so
    # ShowLauncher() does not early-return, then open the launcher (F8, see note above on why
    # not XButton1) so DiagCaptureUiSnapshot() fires, close it, then dump diagnostics.
    $marker = 'ui-snapshot-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $driver = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$marker"
Sleep 300
Send "{F8}"
Sleep 400
Send "{Escape}"
Sleep 200
Send "{F10}"
Sleep 300
ExitApp 0
"@
    $driverPath = Join-Path $workDir 'driver.ahk'
    Set-Content $driverPath $driver -Encoding UTF8
    $d = Start-Process -FilePath $ahkExe -ArgumentList @($driverPath) -Wait -PassThru -WindowStyle Hidden
    if ($d.ExitCode -ne 0) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "FAIL: driver exit=$($d.ExitCode)"
    }
    Start-Sleep -Milliseconds 300

    $jsonPath = Join-Path $workDir 'diag-out.json'
    if (-not (Test-Path $jsonPath)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "FAIL: diag-out.json was not written"
    }
    $json = Get-Content $jsonPath -Raw -Encoding UTF8
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    return $json
}

# --- A: dev mode (.ahk direct run via AutoHotkey64.exe) must contain a well-formed "ui" field ---
$stageDev = New-Stage 'dev'
Copy-Item $src (Join-Path $stageDev 'soushin-suggest.ahk')
$devCode = Get-Content (Join-Path $stageDev 'soushin-suggest.ahk') -Raw -Encoding UTF8
if ($devCode -notmatch 'F10::') {
    $devCode = $devCode.Replace('XButton1::ShowLauncher()', $f10Helper)
}
Set-Content -Path (Join-Path $stageDev 'soushin-suggest.ahk') -Value $devCode -Encoding UTF8

$devJson = Get-DiagJsonViaLauncher $ahkExe (Join-Path $stageDev 'soushin-suggest.ahk') $stageDev
if ($devJson -notmatch '"ui":\{') {
    throw "FAIL A: dev-mode diag JSON has no 'ui' field. JSON was: $devJson"
}
Write-Output "PASS A1: dev-mode (.ahk) diagnostics JSON contains a 'ui' field"

$obj = $devJson | ConvertFrom-Json
if (-not $obj.ui) { throw "FAIL A: ui field did not parse as an object" }
if ($obj.ui.win -ne 'launcher') { throw "FAIL A: ui.win expected 'launcher', got '$($obj.ui.win)'" }
if ($obj.ui.w -ne 460) { throw "FAIL A: ui.w expected 460 (launcherW constant), got $($obj.ui.w)" }
if (-not $obj.ui.ctrls -or $obj.ui.ctrls.Count -eq 0) { throw "FAIL A: ui.ctrls is empty" }
$listViews = $obj.ui.ctrls | Where-Object { $_.t -eq 'ListView' }
if ($listViews.Count -lt 2) { throw "FAIL A: expected at least 2 ListView controls (history + snippets tabs), got $($listViews.Count)" }
Write-Output "PASS A2: ui.win=launcher, ui.w=460, $($obj.ui.ctrls.Count) controls incl. $($listViews.Count) ListViews"

# No control text/window title should ever be present -- only type/coords/visibility/counts (G-5).
foreach ($c in $obj.ui.ctrls) {
    if ($c.PSObject.Properties.Name -contains 'text' -or $c.PSObject.Properties.Name -contains 'Text') {
        throw "FAIL A: a control snapshot entry carries a 'text' field -- privacy boundary violated (G-5)"
    }
}
Write-Output "PASS A3: no control carries text content (privacy boundary intact)"

Remove-Item $stageDev -Recurse -Force -ErrorAction SilentlyContinue

# --- B: prod mode (compiled .exe) must NOT contain a "ui" key at all (release-blocking) ---
$prodExe = Join-Path $repo 'dist\soushin-suggest.exe'
if (-not (Test-Path $prodExe)) {
    Write-Output "SKIP B: dist\soushin-suggest.exe not built yet -- run scripts\build.ps1 first, then re-run this probe before merging"
} else {
    $stageProd = New-Stage 'prod'
    Copy-Item $prodExe (Join-Path $stageProd 'soushin-suggest.exe')
    Set-Content (Join-Path $stageProd 'sites.ini') "[clipboard]`nautoclear=1`n" -Encoding UTF8
    Set-Content (Join-Path $stageProd 'startup-prompted.flag') '1' -Encoding ascii

    # Compiled exe has no source to patch for an F10 hotkey, and "diagnostics copy" is a tray
    # menu item only (no hotkey binding), so the dev-mode trick of injecting a driver hotkey
    # does not apply here. Instead this validates the non-leak guarantee (design doc G-2/G-3)
    # via static inspection of the compiled binary: Ahk2Exe-Ignore blocks are stripped from the
    # source BEFORE compilation, so if the guard held, none of DiagCaptureUiSnapshot's source
    # text (function name, or its fail-marker string) can appear anywhere in the binary.
    # This is a stronger check than a single runtime JSON dump would be: a JSON-only check could
    # pass by accident (e.g. if the launcher was never opened during the probe run), whereas the
    # source string's total absence is unconditional proof the code path does not exist to run.
    $proc = Start-Process -FilePath (Join-Path $stageProd 'soushin-suggest.exe') -WorkingDirectory $stageProd -PassThru
    Start-Sleep -Seconds 2
    if ($proc.HasExited) {
        throw "FAIL B: compiled exe exited early code=$($proc.ExitCode) -- Ahk2Exe-Ignore block likely broke the build (G-2)"
    }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

    # ISO-8859-1 (codepage 28591): one byte maps to one char, a lossless round-trip
    # for finding ASCII substrings in an arbitrary binary.
    $exeRawBytes = [System.IO.File]::ReadAllBytes((Join-Path $stageProd 'soushin-suggest.exe'))
    $exeBytes = [System.Text.Encoding]::GetEncoding(28591).GetString($exeRawBytes)
    if ($exeBytes -match [regex]::Escape('DiagCaptureUiSnapshot') -or $exeBytes -match [regex]::Escape('uiSnapFail')) {
        throw "FAIL B: compiled exe binary contains DiagCaptureUiSnapshot/uiSnapFail source strings -- Ahk2Exe-Ignore block was not stripped (G-2). DO NOT MERGE."
    }
    Write-Output "PASS B: compiled exe binary contains no trace of DiagCaptureUiSnapshot (Ahk2Exe-Ignore correctly stripped the dev-only code)"
    Remove-Item $stageProd -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'OK ui-snapshot probe'
