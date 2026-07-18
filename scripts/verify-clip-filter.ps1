# scripts/verify-clip-filter.ps1
# Phase1 security probe for CaptureClip user-action filter.
# A) Set-Clipboard inject with ticks forced to 0 -> must reject
# B) F9 sets LastUserCopyTick then clipboard change -> must accept
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-clip-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Copy-Item (Join-Path $repo 'dist\sites.ini') (Join-Path $stage 'sites.ini')
if (Test-Path (Join-Path $repo 'dist\snippets.ini')) {
    Copy-Item (Join-Path $repo 'dist\snippets.ini') (Join-Path $stage 'snippets.ini')
}
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8
$pattern = 'LastCaptureText := text, LastCaptureTick := now\r?\n    PushClipHistory\(text\)'
$inject = @'
LastCaptureText := text, LastCaptureTick := now
    try FileAppend(text . "`n", A_ScriptDir . "\accepted.log", "UTF-8")
    PushClipHistory(text)
'@
$newCode = [regex]::Replace($code, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $inject }, 1)
if ($newCode -eq $code) { throw 'CaptureClip PushClipHistory site not found for instrumentation' }
$code = $newCode

# Temp helpers: F9 marks user-copy tick; F8 zeros ticks and writes ready flag
$helpers = @'
XButton1::ShowLauncher()
F9:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
F8:: {
    global LastUserCopyTick, LastLButtonUpTick
    LastUserCopyTick := 0
    LastLButtonUpTick := 0
    try FileAppend("ready`n", A_ScriptDir . "\ready.flag", "UTF-8")
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

$log = Join-Path $stage 'accepted.log'
$ready = Join-Path $stage 'ready.flag'
Remove-Item $log, $ready -ErrorAction SilentlyContinue

# Zero ticks, then inject
$prep = @"
#Requires AutoHotkey v2.0
Send "{F8}"
Sleep 200
ExitApp 0
"@
Set-Content (Join-Path $stage 'prep.ahk') $prep -Encoding UTF8
Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'prep.ahk')) -Wait -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(5)
while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path $ready)) { throw 'ready.flag not created' }

$injectText = 'injected-test-string-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Set-Clipboard -Value $injectText
Start-Sleep -Milliseconds 700
$accepted = @()
if (Test-Path $log) { $accepted = @(Get-Content $log -Encoding UTF8) }
if ($accepted | Where-Object { $_ -like '*injected-test-string*' }) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: injected clipboard text was accepted by filter: $injectText"
}
Write-Output 'PASS inject filtered out'

# Accept path: F9 tick then clipboard write
Remove-Item $log -ErrorAction SilentlyContinue
$marker = 'user-copy-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$driver = @"
#Requires AutoHotkey v2.0
Send "{F9}"
Sleep 80
A_Clipboard := "$marker"
Sleep 500
ExitApp 0
"@
Set-Content (Join-Path $stage 'driver.ahk') $driver -Encoding UTF8
$d = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driver.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($d.ExitCode -ne 0) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: accept-path driver exit=$($d.ExitCode)"
}
Start-Sleep -Milliseconds 400
$accepted = @()
if (Test-Path $log) { $accepted = @(Get-Content $log -Encoding UTF8) }
if (-not ($accepted | Where-Object { $_ -like '*user-copy-marker*' })) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw 'FAIL: user-copy tick path was not accepted'
}
Write-Output 'PASS user-copy tick accepted'

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
if (-not $env:SS_DEBUG_KEEP_STAGE) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Output "DEBUG: stage kept at $stage"
}
Write-Output 'OK Phase1 security probe'
