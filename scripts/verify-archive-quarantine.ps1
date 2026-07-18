# scripts/verify-archive-quarantine.ps1
# Phase1 probe for the text archive quarantine (QueueTextArchive -> CommitPendingArchive)
# and its auto-clear cancellation path (MaybeDropAutoCleared).
# Runs against a staged copy with archivetext=on and a short autoclear window so both
# the commit path and the cancel path complete in a few seconds.
# A) User-copy tick + write, wait past the quarantine window -> history-*.csv must exist and contain the marker
# B) User-copy tick + write, then a second "auto-clear" write before the window elapses -> file must NOT contain the marker
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-archive-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null
$archiveDir = Join-Path $stage 'archive-out'
New-Item -ItemType Directory -Path $archiveDir | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

# autoclear=1 -> quarantine window = 1s + 2s margin = 3s. archivedir points into the isolated stage.
$archiveDirIni = $archiveDir -replace '\\', '\\'
$sitesIni = @"
[clipboard]
autoclear=1
archivetext=on
archivedir=$archiveDirIni
"@
Set-Content (Join-Path $stage 'sites.ini') $sitesIni -Encoding UTF8

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8

# Helpers: F9 marks user-copy tick (reused from verify-clip-filter.ps1 pattern);
# F7 forces an immediate CommitPendingArchive pass so the probe doesn't wait on the 5s SetTimer tick.
$helpers = @'
XButton1::ShowLauncher()
F9:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
F7:: {
    CommitPendingArchive()
    try FileAppend("ready`n", A_ScriptDir . "\commit.flag", "UTF-8")
}
'@
if ($code -notmatch 'F9::') {
    $code = $code.Replace('XButton1::ShowLauncher()', $helpers)
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

function Get-ArchivedHistoryText {
    $historyDir = Join-Path $archiveDir 'history'
    if (-not (Test-Path $historyDir)) { return '' }
    $files = Get-ChildItem $historyDir -Filter 'history-*.csv' -ErrorAction SilentlyContinue
    if (-not $files) { return '' }
    return ($files | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n"
}

# --- Test A: commit path. User-copy tick, write, wait past quarantine window, force-commit, expect file. ---
$markerA = 'quarantine-commit-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$driverA = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$markerA"
Sleep 3500
Send "{F7}"
Sleep 300
ExitApp 0
"@
Set-Content (Join-Path $stage 'driverA.ahk') $driverA -Encoding UTF8
$dA = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driverA.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($dA.ExitCode -ne 0) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: commit-path driver exit=$($dA.ExitCode)"
}
Start-Sleep -Milliseconds 500
$text = Get-ArchivedHistoryText
if ($text -notlike "*$markerA*") {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: quarantine commit did not write marker to history CSV"
}
Write-Output 'PASS quarantine commit wrote to disk after window elapsed'

# --- Test B: cancel path. User-copy tick, write, then a same-text re-capture before window elapses
#     simulates an auto-clear (MaybeDropAutoCleared fires when clipboard reverts to the pre-capture
#     value within ClipAutoClearSec). Expect the marker never reaches disk. ---
$markerB = 'quarantine-cancel-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$driverB = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$markerB"
Sleep 400
A_Clipboard := ""
Sleep 3500
Send "{F7}"
Sleep 300
ExitApp 0
"@
Set-Content (Join-Path $stage 'driverB.ahk') $driverB -Encoding UTF8
$dB = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driverB.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($dB.ExitCode -ne 0) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: cancel-path driver exit=$($dB.ExitCode)"
}
Start-Sleep -Milliseconds 500
$text = Get-ArchivedHistoryText
if ($text -like "*$markerB*") {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: auto-cleared text was committed to disk (quarantine cancel broken)"
}
Write-Output 'PASS auto-cleared text never reached disk'

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK Phase1 archive quarantine probe'
