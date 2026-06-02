# Generates scripts/logo.ico (multi-resolution) from logo.png.
# Re-run whenever logo.png changes. The .ico lives under scripts/ so the
# installer + single-file bundle pick it up automatically (they embed every
# file in scripts/ byte-for-byte).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$png  = Join-Path $root 'logo.png'
$ico  = Join-Path $root 'scripts\logo.ico'

$src   = [System.Drawing.Image]::FromFile($png)
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs  = @()
foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($src, 0, 0, $s, $s)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += , @{ size = $s; bytes = $ms.ToArray() }
  $bmp.Dispose(); $ms.Dispose()
}
$src.Dispose()

# .ico container: ICONDIR + one ICONDIRENTRY per image + the PNG payloads.
# PNG-compressed entries are valid in .ico on Windows Vista and later.
$out = New-Object System.IO.MemoryStream
$bw  = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0)            # reserved
$bw.Write([uint16]1)            # type = icon
$bw.Write([uint16]$pngs.Count)  # image count
$offset = 6 + (16 * $pngs.Count)
foreach ($p in $pngs) {
  $dim = if ($p.size -ge 256) { 0 } else { $p.size }   # 0 means 256 in the .ico spec
  $bw.Write([byte]$dim)         # width
  $bw.Write([byte]$dim)         # height
  $bw.Write([byte]0)            # palette count
  $bw.Write([byte]0)            # reserved
  $bw.Write([uint16]1)          # color planes
  $bw.Write([uint16]32)         # bits per pixel
  $bw.Write([uint32]$p.bytes.Length)
  $bw.Write([uint32]$offset)
  $offset += $p.bytes.Length
}
foreach ($p in $pngs) { $bw.Write($p.bytes) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($ico, $out.ToArray())
$out.Dispose()

Write-Host ("logo.ico written: {0} bytes (sizes: {1})" -f (Get-Item $ico).Length, ($sizes -join ', ')) -ForegroundColor Green
