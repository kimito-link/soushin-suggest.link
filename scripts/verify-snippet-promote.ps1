# scripts/verify-snippet-promote.ps1
# Phase1 probe for "use a snippet -> it jumps to the top" (PromoteSnippetToTop, wired into
# UseSnippetAt). This is the "recently used floats to the top" behavior modeled on Chatwork/
# Coconala message lists, distinct from the manual drag/right-click reorder in the manager.
# A) Using the 3rd of 4 snippets moves its ini line to the front; the other 3 keep their
#    relative order.
# B) Using the item that's already first is a no-op (file content unchanged).
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-promote-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Set-Content (Join-Path $stage 'sites.ini') "[clipboard]`n" -Encoding UTF8
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii

$snippetsPath = Join-Path $stage 'snippets.ini'
$snippetsBody = @"
; comment line kept for the fixture
alpha=first snippet
beta=second snippet
gamma=third snippet
delta=fourth snippet
"@
Set-Content $snippetsPath $snippetsBody -Encoding UTF8

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8

# F6 calls PromoteSnippetToTop(label) directly with the label read from probe-req.txt,
# bypassing the launcher UI entirely (same pattern as verify-clibor-import.ps1's F6).
$helper = @'
XButton1::ShowLauncher()
F6:: {
    reqPath := A_ScriptDir . "\probe-req.txt"
    label := Trim(RegExReplace(FileRead(reqPath, "UTF-8"), "^\x{FEFF}"), " `t`r`n")
    try {
        PromoteSnippetToTop(label)
        FileAppend("done`n", A_ScriptDir . "\probe-done.flag", "UTF-8")
    } catch as e {
        FileAppend("ERROR: " . e.Message . " at " . e.File . ":" . e.Line . "`n", A_ScriptDir . "\probe-done.flag", "UTF-8")
    }
}
'@
if ($code -notmatch 'F6::') {
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

function Invoke-Promote {
    param([string]$Label)
    $reqPath = Join-Path $stage 'probe-req.txt'
    $donePath = Join-Path $stage 'probe-done.flag'
    if (Test-Path $donePath) { Remove-Item $donePath -Force }
    Set-Content $reqPath $Label -Encoding UTF8
    $driver = @"
#Requires AutoHotkey v2.0
Send "{F6}"
Sleep 300
ExitApp 0
"@
    $driverPath = Join-Path $stage 'driver.ahk'
    Set-Content $driverPath $driver -Encoding UTF8
    $d = Start-Process -FilePath $ahkExe -ArgumentList @($driverPath) -Wait -PassThru -WindowStyle Hidden
    if ($d.ExitCode -ne 0) { throw "driver exit=$($d.ExitCode)" }
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path $donePath)) { throw "probe-done.flag was not written" }
}

function Get-SnippetLabelOrder {
    (Get-Content $snippetsPath -Encoding UTF8) |
        Where-Object { $_ -match '=' -and $_ -notmatch '^\s*;' } |
        ForEach-Object { ($_ -split '=', 2)[0].Trim() }
}

# --- Test A: promoting the 3rd item (gamma) moves it to the front. ---
Invoke-Promote -Label 'gamma'
$order = Get-SnippetLabelOrder
$expectedA = @('gamma', 'alpha', 'beta', 'delta')
if (($order -join ',') -ne ($expectedA -join ',')) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: expected order [$($expectedA -join ',')], got [$($order -join ',')]"
}
Write-Output 'PASS A: using the 3rd snippet promotes it to the top, others keep relative order'

# --- Test B: promoting the item that's already first is a no-op. ---
$beforeText = Get-Content $snippetsPath -Raw -Encoding UTF8
Invoke-Promote -Label 'gamma'   # already first after test A
$afterText = Get-Content $snippetsPath -Raw -Encoding UTF8
if ($beforeText -ne $afterText) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: promoting the already-first item changed the file"
}
Write-Output 'PASS B: promoting the already-first snippet is a no-op'

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK Phase1 snippet-promote probe'
