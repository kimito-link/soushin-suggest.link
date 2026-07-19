# scripts/verify-history-delete-persist.ps1
# Verifies the fix for: "this history to delete" only removed the in-memory ClipHistory entry,
# leaving history-store.csv untouched. Since history persistence defaults to ON, the deleted
# item resurrected on the next restart. This probes:
# A) Deleting an item removes it from history-store.csv within the rewrite window.
# B) A fresh process instance (simulating a restart) does NOT restore the deleted item.
# C) A second, un-deleted item survives the rewrite (delete is selective, not a wipe).
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-histdelete-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

# F9 marks user-copy tick; F7 forces immediate quarantine commit; F5 deletes the topmost
# (most-recent) ClipHistory entry via DeleteHistoryItem (exercises the same code path as
# the launcher's right-click "delete this history"); F8 forces the rewrite timer to fire now
# instead of waiting the 2s debounce, so the test does not depend on real-time timing.
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
F5:: {
    global ClipHistory
    if (ClipHistory.Length >= 1)
        DeleteHistoryItem(ClipHistory[1])
    try FileAppend("deleted`n", A_ScriptDir . "\delete.flag", "UTF-8")
}
F8:: {
    SetTimer(RewriteHistStoreIfPending, 0)
    RewriteHistStoreIfPending()
    try FileAppend("rewritten`n", A_ScriptDir . "\rewrite.flag", "UTF-8")
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

# --- Instance 1: seed two items (B committed after A, so B ends up at ClipHistory[1]). ---
$proc1 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc1.HasExited) { throw "soushin (instance 1) exited early code=$($proc1.ExitCode)" }

$markerA = 'histdel-keep-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$markerB = 'histdel-delete-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Copy-AndCommit $proc1 $markerA
Copy-AndCommit $proc1 $markerB

$storeText = Get-StoreText
if ($storeText -notlike "*$markerA*" -or $storeText -notlike "*$markerB*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: seed items did not both reach history-store.csv before delete"
}
Write-Output 'PASS seed: both items committed to history-store.csv'

# --- Delete the most-recent item (markerB, at ClipHistory[1]) and force the rewrite now. ---
$deleteFlag = Join-Path $stage 'delete.flag'
$rewriteFlag = Join-Path $stage 'rewrite.flag'
$driverDelete = @"
#Requires AutoHotkey v2.0
Send "{F5}"
Sleep 200
Send "{F8}"
Sleep 300
ExitApp 0
"@
Set-Content (Join-Path $stage 'driverDelete.ahk') $driverDelete -Encoding UTF8
$dD = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driverDelete.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($dD.ExitCode -ne 0) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: delete driver exit=$($dD.ExitCode)"
}
if (-not (Test-Path $deleteFlag) -or -not (Test-Path $rewriteFlag)) {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: delete.flag or rewrite.flag was not written (DeleteHistoryItem/RewriteHistStoreIfPending not exercised)"
}

$storeText = Get-StoreText
if ($storeText -like "*$markerB*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: deleted item ($markerB) is still present in history-store.csv after rewrite"
}
if ($storeText -notlike "*$markerA*") {
    Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: undeleted item ($markerA) was lost during the rewrite (should be selective, not a wipe)"
}
Write-Output 'PASS A: deleted item removed from history-store.csv, undeleted item survives'

Stop-Process -Id $proc1.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# --- Instance 2 (simulated restart): deleted item must NOT resurrect; kept item must restore. ---
$proc2 = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Milliseconds 800
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
if ([int]$histLen -ne 1) {
    Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: restarted instance loaded $histLen history item(s), expected exactly 1 (only markerA should survive)"
}
Write-Output "PASS B: restarted instance restored exactly $histLen history item (deleted item did not resurrect)"

Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK history-delete-persist probe'
