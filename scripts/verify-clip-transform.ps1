# scripts/verify-clip-transform.ps1
# Verifies the one-shot format/convert submenu added in the Clibor-parity round 2:
# A) The closure-capture pitfall (AHK v2 for-loop variables are captured by reference) is
#    correctly avoided by MakeTransformHandler -- each menu entry must invoke its OWN
#    transform function, not always the last one in the list.
# B) LCMapJa (LCMapStringW wrapper) correctly performs fullwidth<->halfwidth conversion,
#    including the character-count change that only the two-call buffer-sizing pattern
#    handles correctly.
# C) A pure-format transform (strip newlines) works end-to-end via the exported functions.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'dist\soushin-suggest.ahk'
$stage = Join-Path $env:TEMP ('ss-cliptransform-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Set-Content (Join-Path $stage 'startup-prompted.flag') '1' -Encoding ascii
Set-Content (Join-Path $stage 'sites.ini') "[clipboard]`nautoclear=1`n" -Encoding UTF8

$ahkPath = Join-Path $stage 'soushin-suggest.ahk'
$code = Get-Content $ahkPath -Raw -Encoding UTF8

# NOTE: Japanese characters in a PowerShell here-string get mis-decoded as Shift-JIS on
# this machine (known landmine, see global CLAUDE.md). Build the fullwidth probe string
# from Unicode codepoints (AHK Chr() calls) instead of embedding literal Japanese.
# U+FF21..FF23 = fullwidth ABC, U+FF11..FF13 = fullwidth 123, U+30AC = katakana GA (x2)
$codepoints = @(0xFF21,0xFF22,0xFF23,0xFF11,0xFF12,0xFF13,0x30AC,0x30AC)
$ahkFullwidthExpr = ($codepoints | ForEach-Object { "Chr($_)" }) -join ' . '

$helpers = @'
XButton1::ShowLauncher()
F4:: {
    defs := ClipTransformDefs()
    out := ""
    i := 0
    for d in defs.format {
        i += 1
        fn := d.fn                                 ; obj.fn(x) directly would bind `this` as an
        out .= "format" . i . ":" . fn("  a`nb  ") . "`n"   ; extra arg in AHK v2; call via a plain var instead
    }
    i := 0
    for d in defs.convert {
        i += 1
        fn := d.fn
        out .= "convert" . i . ":" . fn("ABCabc123") . "`n"
    }
    __FULLWIDTH_PROBE__
    out .= "halfwidth:" . LCMapJa(fwProbe, 0x00400000) . "`n"
    out .= "fullwidth:" . LCMapJa("ABC123", 0x00800000) . "`n"
    FileAppend(out, A_ScriptDir . "\transform-result.txt", "UTF-8")
}
'@
$helpers = $helpers.Replace('__FULLWIDTH_PROBE__', "fwProbe := $ahkFullwidthExpr")
if ($code -notmatch 'F4::') {
    $code = $code.Replace('XButton1::ShowLauncher()', $helpers)
}
Set-Content -Path $ahkPath -Value $code -Encoding UTF8

$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
Get-Process | Where-Object {
    ($_.ProcessName -match 'soushin|AutoHotkey') -and
    ($_.Path -and $_.Path -like (Join-Path $env:TEMP 'ss-*-verify-*'))
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$proc = Start-Process -FilePath $ahkExe -ArgumentList @($ahkPath) -WorkingDirectory $stage -PassThru
Start-Sleep -Seconds 2
if ($proc.HasExited) { throw "soushin exited early code=$($proc.ExitCode)" }

$resultFlag = Join-Path $stage 'transform-result.txt'
$driver = @"
#Requires AutoHotkey v2.0
Send "{F4}"
Sleep 500
ExitApp 0
"@
Set-Content (Join-Path $stage 'driver.ahk') $driver -Encoding UTF8
$d = Start-Process -FilePath $ahkExe -ArgumentList @((Join-Path $stage 'driver.ahk')) -Wait -PassThru -WindowStyle Hidden
if ($d.ExitCode -ne 0) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: F4 driver exit=$($d.ExitCode)"
}
Start-Sleep -Milliseconds 500

if (-not (Test-Path $resultFlag)) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "FAIL: transform-result.txt was not written"
}
$lines = Get-Content $resultFlag -Encoding UTF8
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

function Get-Val($lines, $key) {
    $line = $lines | Where-Object { $_ -like "$key`:*" }
    if (-not $line) { throw "FAIL: missing key $key in transform-result.txt" }
    return $line.Substring($key.Length + 1)
}

$f1 = Get-Val $lines 'format1'
$f6 = Get-Val $lines 'format6'
if ($f1 -eq $f6) {
    throw "FAIL: format1 and format6 produced identical output ('$f1') -- closure-capture bug (all handlers use the last fn)"
}
Write-Output "PASS A: format1('$f1') differs from format6('$f6') -- MakeTransformHandler correctly binds each fn"

if ($f1 -match "`n") {
    throw "FAIL: format1 still contains a newline: '$f1'"
}
Write-Output "PASS A2: format1 (strip newlines) correctly removed the newline"

$c1 = Get-Val $lines 'convert1'
$c2 = Get-Val $lines 'convert2'
if ($c1 -ceq $c2) {
    throw "FAIL: convert1(upper) and convert2(lower) produced identical output -- closure-capture bug"
}
if ($c1 -cne 'ABCABC123') {
    throw "FAIL: convert1 (uppercase) expected 'ABCABC123', got '$c1'"
}
if ($c2 -cne 'abcabc123') {
    throw "FAIL: convert2 (lowercase) expected 'abcabc123', got '$c2'"
}
Write-Output "PASS B: convert1/convert2 (upper/lower) produced correct and distinct results"

$half = Get-Val $lines 'halfwidth'
$full = Get-Val $lines 'fullwidth'
if ($half.Length -le 0 -or $full.Length -le 0) {
    throw "FAIL: LCMapJa returned empty output"
}
if ($half -eq 'ＡＢＣ１２３ガガ') {
    throw "FAIL: halfwidth conversion did not change the input (LCMapStringW call failed silently)"
}
if ($full -eq 'ABC123') {
    throw "FAIL: fullwidth conversion did not change the input (LCMapStringW call failed silently)"
}
Write-Output "PASS C: LCMapJa halfwidth('$half') and fullwidth('$full') both transformed the input"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'OK clip-transform probe'
