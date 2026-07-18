# scripts/verify-history-persist.ps1
# Phase1 probe for clipboard history persistence (history.persist toggle).
# A) With persist ON, a quarantine-committed copy writes a row to history-store.csv.
# B) A fresh process instance (simulating a restart) loads that row back into ClipHistory
#    via StartHistoryStoreLoad/FinishHistoryStoreLoad -- verified through CopyDiagnostics'
#    JSON dump (histLen reflects the restored count) rather than by reading GUI state.
# C) Quarantine is untouched: an auto-cleared copy still never reaches history-store.csv.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-histpersist-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
archivedir=$archiveDirIni
"@
Set-Content (Join-Path $stage 'sites.ini') $sitesIni -Encoding UTF8

# settings.ini pre-seeded with history.persist=on so this run doesn't need the UI toggle
# or the first-run prompt dialog.
$settingsIni = @"
[app]
version=1.17.0
[history]
persist=on
loadmax=10000
[state]
firstrunprompted=1
histpersistprompted=1
"@
Set-Content (Join-Path $stage 'settings.ini') $settingsIni -Encoding UTF8

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8

# Helpers: F9 marks user-copy tick; F7 forces an immediate CommitPendingArchive pass;
# F6 dumps histLen via CopyDiagnostics-style write to a probe file (avoids parsing clipboard).
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
F6:: {
    global ClipHistory
    try FileAppend(ClipHistory.Length . "`n", A_ScriptDir . "\histlen.flag", "UTF-8")
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

function Get-StoreText {
    $storePath = Join-Path $archiveDir 'history-store.csv'
    if (-not (Test-Path $storePath)) { return '' }
    return Get-Content $storePath -Raw -Encoding UTF8
}

# --- Instance 1: commit path. User-copy tick, write, wait past quarantine window, force-commit. ---
$proc1 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc1.HasExited) { throw "soushin (instance 1) exited early code=$($proc1.ExitCode)" }

$markerA = 'histpersist-commit-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
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
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: commit-path driver exit=$($dA.ExitCode)"
}
Start-Sleep -Milliseconds 500
$storeText = Get-StoreText
if ($storeText -notlike "*$markerA*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: quarantine-passed text with history.persist=on did not reach history-store.csv"
}
Write-Output 'PASS A: quarantine-passed text committed to history-store.csv'

# --- Test B: quarantine still cancels for the persistent store, same as the folder-archive log. ---
$markerB = 'histpersist-cancel-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
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
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: cancel-path driver exit=$($dB.ExitCode)"
}
Start-Sleep -Milliseconds 500
$storeText = Get-StoreText
if ($storeText -like "*$markerB*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: auto-cleared text reached history-store.csv (quarantine broken for the persistent store)"
}
Write-Output 'PASS B: auto-cleared text never reached history-store.csv (quarantine intact)'

Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# --- Instance 2 (simulated restart): a fresh process should load markerA back from the store. ---
$proc2 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Milliseconds 800   # startup sequence + the -50ms deferred StartHistoryStoreLoad
if ($proc2.HasExited) { throw "soushin (instance 2 / restart) exited early code=$($proc2.ExitCode)" }

$histFlag = Join-Path $stage 'histlen.flag'
if (Test-Path $histFlag) { Remove-Item $histFlag -Force }
$driverC = @"
#Requires AutoHotkey v2.0
Send "{F6}"
Sleep 300
ExitApp 0
"@
Set-Content (Join-Path $stage 'driverC.ahk') $driverC -Encoding UTF8
$dC = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driverC.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($dC.ExitCode -ne 0) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: histlen driver exit=$($dC.ExitCode)"
}
Start-Sleep -Milliseconds 300
if (-not (Test-Path $histFlag)) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: histlen.flag was not written by the restarted instance"
}
$histLen = (Get-Content $histFlag -Raw).Trim()
if ([int]$histLen -lt 1) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: restarted instance loaded $histLen history items, expected at least 1 (markerA)"
}
Write-Output "PASS C: restarted instance restored $histLen history item(s) from history-store.csv"

Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK Phase1 history-persist probe'
