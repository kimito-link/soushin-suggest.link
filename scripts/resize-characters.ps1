# scripts/resize-characters.ps1
# Resizes the yukkuri-charactore-english source PNGs down to the display
# sizes actually used on the LP (2x for retina), and writes them to
# assets/yukkuri-resized/. Run once, then base64-embed the outputs.

Add-Type -AssemblyName System.Drawing

$repo = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $repo "assets\yukkuri-charactore-english"
$outDir = Join-Path $repo "assets\yukkuri-resized"

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# (source relative path, output name, target pixel size)
$jobs = @(
    @{ Src = "link\link-yukkuri-smile-mouth-open.png";        Out = "rinku-smile-176.png";  Size = 176 },
    @{ Src = "link\link-yukkuri-normal-mouth-closed.png";      Out = "rinku-normal-176.png"; Size = 176 },
    @{ Src = "link\link-yukkuri-smile-mouth-open.png";         Out = "rinku-smile-128.png";  Size = 128 },
    @{ Src = "link\link-yukkuri-normal-mouth-open.png";        Out = "rinku-normal-128.png"; Size = 128 },
    @{ Src = "link\link-yukkuri-normal-mouth-closed.png";      Out = "rinku-normal2-128.png"; Size = 128 },
    @{ Src = "link\link-yukkuri-smile-mouth-open.png";         Out = "rinku-smile-64.png";   Size = 64 },
    @{ Src = "link\link-yukkuri-smile-mouth-closed.png";       Out = "rinku-smile2-64.png";  Size = 64 },

    @{ Src = "konta\kitsune-yukkuri-normal.png";               Out = "konta-normal-176.png"; Size = 176 },
    @{ Src = "konta\kitsune-yukkuri-smile-mouth-open.png";     Out = "konta-smile-88.png";   Size = 88 },
    @{ Src = "konta\kitsune-yukkuri-smile-mouth-open.png";     Out = "konta-smile-128.png";  Size = 128 },
    @{ Src = "konta\kitsune-yukkuri-smile-mouth-open.png";     Out = "konta-smile-64.png";   Size = 64 },

    @{ Src = "tanunee\tanuki-yukkuri-normal-mouth-closed.png"; Out = "tanu-normal-176.png";  Size = 176 },
    @{ Src = "tanunee\tanuki-yukkuri-half-eyes-mouth-closed.png"; Out = "tanu-tired-176.png"; Size = 176 },
    @{ Src = "tanunee\tanuki-yukkuri-smile-mouth-closed.png";  Out = "tanu-smile-128.png";   Size = 128 },
    @{ Src = "tanunee\tanuki-yukkuri-normal-mouth-open.png";   Out = "tanu-normal-128.png";  Size = 128 },
    @{ Src = "tanunee\tanuki-yukkuri-normal-mouth-open.png";   Out = "tanu-normal-64.png";   Size = 64 },

    @{ Src = "link\link-yukkuri-normal-mouth-closed.png";      Out = "rinku-normal-256.png"; Size = 256 },
    @{ Src = "tanunee\tanuki-yukkuri-normal-mouth-closed.png"; Out = "tanu-normal-168.png";  Size = 168 },
    @{ Src = "konta\kitsune-yukkuri-normal.png";               Out = "konta-normal-168.png"; Size = 168 }
)

foreach ($j in $jobs) {
    $srcPath = Join-Path $srcDir $j.Src
    $outPath = Join-Path $outDir $j.Out
    if (-not (Test-Path $srcPath)) {
        Write-Warning "Missing source: $srcPath"
        continue
    }
    $srcImg = [System.Drawing.Image]::FromFile($srcPath)
    $size = $j.Size
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $bmp.SetResolution($srcImg.HorizontalResolution, $srcImg.VerticalResolution)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($srcImg, 0, 0, $size, $size)
    $g.Dispose()
    $srcImg.Dispose()
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $outSize = (Get-Item $outPath).Length
    Write-Output ("$($j.Out): ${size}x${size}, $outSize bytes")
}
