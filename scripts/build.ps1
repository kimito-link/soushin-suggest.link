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
$logo   = Join-Path $repo 'assets\kimitolink-mark.png'
$logo14 = Join-Path $repo 'assets\kimitolink-mark-14.png'
$logoFull = Join-Path $repo 'assets\kimitolink-full-logo.png'
$logo18 = Join-Path $repo 'assets\kimitolink-mark-18.png'
$logoFull64 = Join-Path $repo 'assets\kimitolink-full-logo-64.png'
$logoFull73 = Join-Path $repo 'assets\kimitolink-full-logo-73.png'
$rinkuSearchIcon = Join-Path $repo 'assets\rinku-search-icon-22.png'
$kontaIcon = Join-Path $repo 'assets\konta-24.png'
$tanuneeIcon = Join-Path $repo 'assets\tanunee-24.png'
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
if (-not (Test-Path $logo)) {
    Write-Error "Logo not found: $logo"
    exit 1
}
if (-not (Test-Path $logo14)) {
    Write-Error "Logo (14px) not found: $logo14"
    exit 1
}
if (-not (Test-Path $logoFull)) {
    Write-Error "Full logo not found: $logoFull"
    exit 1
}
if (-not (Test-Path $logo18)) {
    Write-Error "Logo (18px) not found: $logo18"
    exit 1
}
if (-not (Test-Path $logoFull64)) {
    Write-Error "Full logo (64px) not found: $logoFull64"
    exit 1
}
if (-not (Test-Path $logoFull73)) {
    Write-Error "Full logo (73px) not found: $logoFull73"
    exit 1
}
if (-not (Test-Path $rinkuSearchIcon)) {
    Write-Error "Rinku search icon not found: $rinkuSearchIcon"
    exit 1
}
if (-not (Test-Path $kontaIcon)) {
    Write-Error "Konta icon not found: $kontaIcon"
    exit 1
}
if (-not (Test-Path $tanuneeIcon)) {
    Write-Error "Tanunee icon not found: $tanuneeIcon"
    exit 1
}

$stage = Join-Path $env:TEMP ('ss-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $src (Join-Path $stage 'soushin-suggest.ahk')
Copy-Item $icon (Join-Path $stage 'soushin-suggest.ico')
Copy-Item $logo (Join-Path $stage 'kimitolink-mark.png')
Copy-Item $logo14 (Join-Path $stage 'kimitolink-mark-14.png')
Copy-Item $logoFull (Join-Path $stage 'kimitolink-full-logo.png')
Copy-Item $logo18 (Join-Path $stage 'kimitolink-mark-18.png')
Copy-Item $logoFull64 (Join-Path $stage 'kimitolink-full-logo-64.png')
Copy-Item $logoFull73 (Join-Path $stage 'kimitolink-full-logo-73.png')
Copy-Item $rinkuSearchIcon (Join-Path $stage 'rinku-search-icon-22.png')
Copy-Item $kontaIcon (Join-Path $stage 'konta-24.png')
Copy-Item $tanuneeIcon (Join-Path $stage 'tanunee-24.png')

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

$distLogo = Join-Path $repo 'dist\kimitolink-mark.png'
$distLogo14 = Join-Path $repo 'dist\kimitolink-mark-14.png'
$distLogoFull = Join-Path $repo 'dist\kimitolink-full-logo.png'
$distLogo18 = Join-Path $repo 'dist\kimitolink-mark-18.png'
$distLogoFull64 = Join-Path $repo 'dist\kimitolink-full-logo-64.png'
$distLogoFull73 = Join-Path $repo 'dist\kimitolink-full-logo-73.png'
$distRinkuSearchIcon = Join-Path $repo 'dist\rinku-search-icon-22.png'
$distKontaIcon = Join-Path $repo 'dist\konta-24.png'
$distTanuneeIcon = Join-Path $repo 'dist\tanunee-24.png'
Copy-Item $logo $distLogo -Force
Copy-Item $logo14 $distLogo14 -Force
Copy-Item $logoFull $distLogoFull -Force
Copy-Item $logo18 $distLogo18 -Force
Copy-Item $logoFull64 $distLogoFull64 -Force
Copy-Item $logoFull73 $distLogoFull73 -Force
Copy-Item $rinkuSearchIcon $distRinkuSearchIcon -Force
Copy-Item $kontaIcon $distKontaIcon -Force
Copy-Item $tanuneeIcon $distTanuneeIcon -Force

$zip = Join-Path $repo ("dist\soushin-suggest-v" + $Version + ".zip")
if (Test-Path $zip) { Remove-Item $zip }

$zipPaths = @(
    (Join-Path $repo 'dist\soushin-suggest.exe'),
    $distIni,
    $distReadme,
    $distLogo,
    $distLogo14,
    $distLogoFull,
    $distLogo18,
    $distLogoFull64,
    $distLogoFull73,
    $distRinkuSearchIcon,
    $distKontaIcon,
    $distTanuneeIcon
)
if (Test-Path $distSnippets) {
    $zipPaths += $distSnippets
}
Compress-Archive -Path $zipPaths `
    -DestinationPath $zip -CompressionLevel Optimal

Remove-Item $stage -Recurse -Force
Write-Output ("OK: " + $zip)
