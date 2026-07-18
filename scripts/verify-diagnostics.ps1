# scripts/verify-diagnostics.ps1
# Phase1 probe for the self-diagnostic instrumentation (ClipDiag/DiagBump/CopyDiagnostics)
# and the XButton2 direct-registration fix for screenshots.
# See _docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md for the design this verifies.
# A) CopyDiagnostics produces well-formed JSON with the expected top-level shape
# B) A user-copy text event increments capText and pushText (sanity: counters actually move)
# C) A self-write (SetClipboardImage) increments selfSuppress (the bug's root-cause counter)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-diag-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Set-Content (Join-Path $stage 'sites.ini') "[clipboard]`n" -Encoding UTF8
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8

# F9 marks user-copy tick (reused pattern from verify-clip-filter.ps1).
# F10 triggers CopyDiagnostics() directly and additionally writes the resulting text to a
# request/response file so the harness can read it without depending on live clipboard state
# racing with the driver process's own clipboard writes.
$helper = @'
XButton1::ShowLauncher()
F9:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
F10:: {
    CopyDiagnostics()   ; 実際のトレイメニュー項目と同じ経路(自己抑制の発火も含めて再現する)
    txt := ""
    try txt := A_Clipboard
    outPath := A_ScriptDir . "\diag-out.json"
    if FileExist(outPath)
        FileDelete(outPath)
    FileAppend(txt, outPath, "UTF-8")
    try FileAppend("ready`n", A_ScriptDir . "\diag.flag", "UTF-8")
}
'@
if ($code -notmatch 'F9::') {
    $code = $code.Replace('XButton1::ShowLauncher()', $helper)
}
Set-Content -Path $ahkPath -Value $code -Encoding UTF8

$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
# Only target leftover probe processes launched from a $env:TEMP staging dir (ss-*-verify-*).
# Do not touch the real running app started from dist\soushin-suggest.exe.
Get-Process | Where-Object {
    ($_.ProcessName -match 'soushin|AutoHotkey') -and
    ($_.Path -and $_.Path -like (Join-Path $env:TEMP 'ss-*-verify-*'))
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$proc = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc.HasExited) { throw "soushin exited early code=$($proc.ExitCode)" }

function Get-DiagSnapshot {
    $outPath = Join-Path $stage 'diag-out.json'
    $flagPath = Join-Path $stage 'diag.flag'
    Remove-Item $outPath, $flagPath -ErrorAction SilentlyContinue
    $driver = @'
#Requires AutoHotkey v2.0
Send "{F10}"
Sleep 300
ExitApp 0
'@
    $driverPath = Join-Path $stage 'driver-f10.ahk'
    Set-Content $driverPath $driver -Encoding UTF8
    $d = Start-Process -FilePath $ahkExe -ArgumentList @($driverPath) -Wait -PassThru -WindowStyle Hidden
    if ($d.ExitCode -ne 0) { throw "F10 driver exit=$($d.ExitCode)" }
    $deadline = (Get-Date).AddSeconds(5)
    while (-not (Test-Path $flagPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $flagPath)) { throw 'diag.flag not created (F10 handler did not run)' }
    if (-not (Test-Path $outPath)) { throw 'diag-out.json not created' }
    return Get-Content $outPath -Raw -Encoding UTF8
}

try {
    # --- Test A: well-formed JSON with expected top-level shape ---
    $snap0 = Get-DiagSnapshot
    $parsed = $snap0 | ConvertFrom-Json -ErrorAction Stop
    if ($parsed.app -ne 'soushin-suggest') { throw "FAIL A: app field wrong: $($parsed.app)" }
    if ($null -eq $parsed.uptimeMs) { throw 'FAIL A: uptimeMs missing' }
    if ($null -eq $parsed.watchOn) { throw 'FAIL A: watchOn missing' }
    if ($null -eq $parsed.histLen) { throw 'FAIL A: histLen missing' }
    if ($null -eq $parsed.cfg.userWindowMs) { throw 'FAIL A: cfg.userWindowMs missing' }
    if ($null -eq $parsed.counters) { throw 'FAIL A: counters missing' }
    Write-Output 'PASS A: CopyDiagnostics/BuildDiagText produces well-formed JSON with expected shape'

    # --- Test B: user-copy text event moves capText/pushText counters ---
    $marker = 'diag-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $driverB = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$marker"
Sleep 500
ExitApp 0
"@
    Set-Content (Join-Path $stage 'driver-b.ahk') $driverB -Encoding UTF8
    $dB = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driver-b.ahk')) -Wait -PassThru -WindowStyle Hidden
    if ($dB.ExitCode -ne 0) { throw "FAIL B: driver exit=$($dB.ExitCode)" }
    Start-Sleep -Milliseconds 300
    $snap1 = Get-DiagSnapshot | ConvertFrom-Json
    $capText1 = if ($snap1.counters.capText) { $snap1.counters.capText.n } else { 0 }
    $pushText1 = if ($snap1.counters.pushText) { $snap1.counters.pushText.n } else { 0 }
    if ($capText1 -lt 1) { throw "FAIL B: capText did not increment (got $capText1)" }
    if ($pushText1 -lt 1) { throw "FAIL B: pushText did not increment (got $pushText1)" }
    Write-Output "PASS B: user-copy text event moved capText=$capText1 pushText=$pushText1"

    # --- Test C: CopyDiagnostics' own clipboard write correctly self-suppresses ---
    # CopyDiagnostics() sets SelfClipTick before writing A_Clipboard (same pattern as
    # SetClipboardImage, which the screenshot bug depends on). snap1's F10 call therefore should
    # have already fired ClipChanged -> self-suppressed once by the time we take snap2. Give the
    # OnClipboardChange callback + -120ms debounce timer extra settle time before snapshotting.
    $selfSuppressBefore = if ($snap1.counters.selfSuppress) { $snap1.counters.selfSuppress.n } else { 0 }
    Start-Sleep -Milliseconds 500
    $snap2 = Get-DiagSnapshot | ConvertFrom-Json
    $selfSuppressAfter = if ($snap2.counters.selfSuppress) { $snap2.counters.selfSuppress.n } else { 0 }
    if ($selfSuppressAfter -le $selfSuppressBefore) {
        throw "FAIL C: selfSuppress did not increment after a CopyDiagnostics call wrote the clipboard (before=$selfSuppressBefore after=$selfSuppressAfter)"
    }
    Write-Output "PASS C: CopyDiagnostics' own clipboard write correctly self-suppresses (selfSuppress $selfSuppressBefore -> $selfSuppressAfter), confirming the counter reacts to the same SelfClipTick mechanism the screenshot bug depends on"

    Write-Output 'OK Phase1 diagnostics probe'
}
finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    if (-not $env:SS_DEBUG_KEEP_STAGE) {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "DEBUG: stage kept at $stage"
    }
}
