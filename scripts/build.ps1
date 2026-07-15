# scripts/build.ps1
# Compiles dist/soushin-suggest.ahk into dist/soushin-suggest.exe and repackages the zip.
#
# Root cause of past "Failed to compile: / exit 3" failures: NOT Ahk2Exe itself.
# Calling Ahk2Exe from Git Bash mangles the /in /out /base flags via MSYS path
# conversion, and without "/silent verbose" Ahk2Exe swallows the real error.
# This script avoids both by using Start-Process with individually quoted args
# and copying the source to an ASCII staging path first (OneDrive/Japanese path
# safety). Must always be invoked via PowerShell, never piped through Git Bash's
# inline -Command.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Version 1.1.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$repo   = Split-Path $PSScriptRoot -Parent
$src    = Join-Path $repo 'dist\soushin-suggest.ahk'
$icon   = Join-Path $repo 'assets\soushin-suggest.ico'
$distIni = Join-Path $repo 'dist\sites.ini'
$distSnippets = Join-Path $repo 'dist\snippets.ini'
$distReadme = Join-Path $repo 'dist\README.txt'

if (-not (Test-Path $src)) {
    Write-Error "Source not found: $src"
    exit 1
}
if (-not (Test-Path $icon)) {
    Write-Error "Icon not found: $icon (run scripts\make-icon.ps1 first)"
    exit 1
}

$stage = Join-Path $env:TEMP ('ss-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Copy-Item $icon (Join-Path $stage 'soushin-suggest.ico')

$ahk2exe = 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe'
$base    = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$outExe  = Join-Path $stage 'soushin-suggest.exe'

if (-not (Test-Path $ahk2exe)) {
    Write-Error "Ahk2Exe not found: $ahk2exe"
    exit 1
}
if (-not (Test-Path $base)) {
    Write-Error "AutoHotkey v2 base not found: $base"
    exit 1
}

$p = Start-Process -FilePath $ahk2exe -ArgumentList @(
    '/silent', 'verbose',
    '/in', "`"$stage\soushin-suggest.ahk`"",
    '/out', "`"$outExe`"",
    '/icon', "`"$stage\soushin-suggest.ico`"",
    '/base', "`"$base`""
) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $stage 'build.log') `
    -RedirectStandardError (Join-Path $stage 'build.err')

Get-Content (Join-Path $stage 'build.log'), (Join-Path $stage 'build.err') -ErrorAction SilentlyContinue

if ($p.ExitCode -ne 0 -or -not (Test-Path $outExe)) {
    Write-Error ("BUILD FAILED exit=" + $p.ExitCode)
    exit 1
}

Copy-Item $outExe (Join-Path $repo 'dist\soushin-suggest.exe') -Force
Write-Output ("Compiled: dist\soushin-suggest.exe (" + (Get-Item (Join-Path $repo 'dist\soushin-suggest.exe')).Length + " bytes)")

$zip = Join-Path $repo ("dist\soushin-suggest-v" + $Version + ".zip")
if (Test-Path $zip) { Remove-Item $zip }

$zipPaths = @(
    (Join-Path $repo 'dist\soushin-suggest.exe'),
    $distIni,
    $distReadme
)
if (Test-Path $distSnippets) {
    $zipPaths += $distSnippets
}
Compress-Archive -Path $zipPaths `
    -DestinationPath $zip -CompressionLevel Optimal

Remove-Item $stage -Recurse -Force
Write-Output ("OK: " + $zip)
