# scripts/make-icon.ps1
# One-time: extract the site favicon (base64 PNG in index.html) and build a
# multi-size .ico (16/32/48/64, PNG-compressed entries, Vista+) for Ahk2Exe /icon.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$html = Get-Content (Join-Path $repo 'index.html') -Raw
if ($html -notmatch 'rel="icon"[^>]*base64,([A-Za-z0-9+/=]+)') { throw 'favicon data URI not found in index.html' }
$src = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($Matches[1]))))
$sizes = 16, 32, 48, 64
$pngs = foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, 0, 0, $s, $s); $g.Dispose()
    $m = New-Object System.IO.MemoryStream
    $bmp.Save($m, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $m.ToArray()
}
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                     # ICONDIRENTRY x4
    $bw.Write([byte]$sizes[$i]); $bw.Write([byte]$sizes[$i])
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($d in $pngs) { $bw.Write($d) }
$assets = Join-Path $repo 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets | Out-Null }
[IO.File]::WriteAllBytes((Join-Path $assets 'soushin-suggest.ico'), $out.ToArray())
Write-Output ('OK: assets\soushin-suggest.ico (' + $out.Length + ' bytes)')
