# scripts/verify-history-promote-on-paste.ps1
# Verifies the fix for: pasting an older history item did not move it back to the top of the
# list (unlike snippets, where UseSnippetAt already promotes to top via PromoteSnippetToTop).
# This probes:
# A) Pasting the older of two history items (PasteHistoryAt) promotes it to ClipHistory[1] and
#    refreshes its timestamp.
# B) The promotion is reflected in history-store.csv (via HistStoreMarkPromoted/RewriteHistStoreIfPending)
#    so it is not lost on restart.
# C) A fresh process instance (simulating a restart) restores the promoted item at the top.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-histpromote-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null
$archiveDir = Join-Path $stage 'archive-out'
New-Item -ItemType Directory -Path $archiveDir | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

$archiveDirIni = $archiveDir -replace '\\', '\\'
$sitesIni = @"
[clipboard]
autoclear=1
archivedir=$archiveDirIni
"@
Set-Content (Join-Path $stage 'sites.ini') $sitesIni -Encoding UTF8

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

# F9 marks user-copy tick; F7 forces immediate quarantine commit; F4 pastes the OLDEST
# ClipHistory entry (last index) via PasteHistoryAt, exercising the same code path as
# clicking/number-key-selecting the bottom row in the launcher; F8 forces the rewrite timer
# to fire now instead of waiting the 2s debounce; F6 dumps ClipHistory[1].text so the harness
# can confirm which item ended up on top without depending on clipboard state.
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
F4:: {
    global ClipHistory
    if (ClipHistory.Length >= 1)
        PasteHistoryAt(ClipHistory.Length)   ; oldest item (last index) -- exercises the paste-time promote path
    try FileAppend("pasted`n", A_ScriptDir . "\paste.flag", "UTF-8")
}
F8:: {
    SetTimer(RewriteHistStoreIfPending, 0)
    RewriteHistStoreIfPending()
    try FileAppend("rewritten`n", A_ScriptDir . "\rewrite.flag", "UTF-8")
}
F6:: {
    global ClipHistory
    top := (ClipHistory.Length >= 1) ? ClipHistory[1].text : "EMPTY"
    try FileAppend(top . "`n", A_ScriptDir . "\top.flag", "UTF-8")
}
'@
if ($code -notmatch 'F9::') {
    $code = $code.Replace('XButton1::ShowLauncher()', $helpers)
}
Set-Content -Path $ahkPath -Value $code -Encoding UTF8

$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
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

function Copy-AndCommit($proc, $marker) {
    $driver = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$marker"
Sleep 3500
Send "{F7}"
Sleep 300
ExitApp 0
"@
    $driverPath = Join-Path $stage ('driver-' + $marker + '.ahk')
    Set-Content $driverPath $driver -Encoding UTF8
    $d = Start-Process -FilePath $ahkExe -ArgumentList @($driverPath) -Wait -PassThru -WindowStyle Hidden
    if ($d.ExitCode -ne 0) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "FAIL: commit driver ($marker) exit=$($d.ExitCode)"
    }
}

# --- Instance 1: seed two items. markerB is committed last, so ClipHistory = [B, A] (B on top). ---
$proc1 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc1.HasExited) { throw "soushin (instance 1) exited early code=$($proc1.ExitCode)" }

$markerA = 'histpromote-old-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$markerB = 'histpromote-new-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Copy-AndCommit $proc1 $markerA
Copy-AndCommit $proc1 $markerB

$storeText = Get-StoreText
if ($storeText -notlike "*$markerA*" -or $storeText -notlike "*$markerB*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: seed items did not both reach history-store.csv before paste"
}
Write-Output 'PASS seed: both items committed to history-store.csv'

# --- Paste the OLDEST item (markerA, at ClipHistory[2]) and force the rewrite now. ---
$pasteFlag = Join-Path $stage 'paste.flag'
$rewriteFlag = Join-Path $stage 'rewrite.flag'
$driverPaste = @"
#Requires AutoHotkey v2.0
Send "{F4}"
Sleep 200
Send "{F8}"
Sleep 300
Send "{F6}"
Sleep 300
ExitApp 0
"@
Set-Content (Join-Path $stage 'driverPaste.ahk') $driverPaste -Encoding UTF8
$dP = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driverPaste.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($dP.ExitCode -ne 0) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: paste driver exit=$($dP.ExitCode)"
}
if (-not (Test-Path $pasteFlag) -or -not (Test-Path $rewriteFlag)) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: paste.flag or rewrite.flag was not written (PasteHistoryAt/RewriteHistStoreIfPending not exercised)"
}

$topFlag = Join-Path $stage 'top.flag'
if (-not (Test-Path $topFlag)) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: top.flag was not written"
}
$topText = (Get-Content $topFlag -Raw).Trim()
if ($topText -ne $markerA) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: after pasting the oldest item ($markerA), ClipHistory[1] is '$topText', expected '$markerA' -- promote-on-paste did not move it to the top"
}
Write-Output 'PASS A: pasting the oldest item promoted it to ClipHistory[1]'

$storeText = Get-StoreText
$lines = $storeText -split "`r`n" | Where-Object { $_ -ne '' -and $_ -ne 'time,type,text' }
$lastLine = $lines[-1]
if ($lastLine -notlike "*$markerA*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: promoted item ($markerA) is not the last (newest) row in history-store.csv after rewrite. Last row: $lastLine"
}
Write-Output 'PASS B: promotion reflected in history-store.csv (promoted item is the newest row)'

Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# --- Instance 2 (simulated restart): the promoted item must restore at the top. ---
$proc2 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Milliseconds 800
if ($proc2.HasExited) { throw "soushin (instance 2 / restart) exited early code=$($proc2.ExitCode)" }

if (Test-Path $topFlag) { Remove-Item $topFlag -Force }
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
    throw "FAIL: top-check driver exit=$($dC.ExitCode)"
}
Start-Sleep -Milliseconds 300
if (-not (Test-Path $topFlag)) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: top.flag was not written by the restarted instance"
}
$topTextAfterRestart = (Get-Content $topFlag -Raw).Trim()
if ($topTextAfterRestart -ne $markerA) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: restarted instance has '$topTextAfterRestart' on top, expected the promoted item '$markerA' to survive the restart"
}
Write-Output "PASS C: restarted instance restored the promoted item ($markerA) at the top"

Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK history-promote-on-paste probe'
