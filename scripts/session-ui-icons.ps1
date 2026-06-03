# ClaudeDeck - icon rendering for the deck (dot-sourced by session-view.ps1).
#
# We bundle MaterialIcons-Regular.ttf (Apache 2.0) next to this script and load it
# privately (no system install). All deck glyphs - position, gear, close, the
# Pomodoro controls and the per-session status dots - are drawn from it. If the
# font is missing we fall back to Unicode glyphs in Segoe UI, so the deck still works.
#
# Dot-source AFTER System.Drawing is loaded and AFTER session-common.ps1 (New-Badge
# uses Get-ProjectColor / Get-Initials / Get-TextOn from there). The private font
# collection is created here, at dot-source time, into the caller's $script: scope.

#   settings e8b8  close e5cd  vertical_align_top/bottom e25a/e258
#   fiber_manual_record e061 (filled)  radio_button_unchecked e836 (outline)
#   play e037  pause e034  skip e044  replay e042  expand_less/more e5ce/e5cf
#   edit e3c9 (pencil — the per-project objective button)
$script:MAT = @{ top=0xE25A; bottom=0xE258; settings=0xE8B8; close=0xE5CD;
                 dotFull=0xE061; dotEmpty=0xE836;
                 play=0xE037; pause=0xE034; skip=0xE044; replay=0xE042;
                 collapse=0xE5CE; expand=0xE5CF; edit=0xE3C9 }   # expand_less / expand_more (chevrons) + edit (pencil)
$script:matPfc    = $null
$script:matFamily = $null
$matPath = Join-Path $PSScriptRoot 'MaterialIcons-Regular.ttf'
if (Test-Path $matPath) {
  try {
    $script:matPfc = New-Object System.Drawing.Text.PrivateFontCollection
    $script:matPfc.AddFontFile($matPath)
    $script:matFamily = $script:matPfc.Families[0]
  } catch { $script:matFamily = $null }
}
$script:iconFamily = if ($script:matFamily) { $script:matFamily } else { New-Object System.Drawing.FontFamily('Segoe UI') }

# A label font for header icons (point-sized, so it scales with the layout).
# UseCompatibleTextRendering=$true on the label routes through GDI+, which is
# what makes the privately-loaded font actually render.
function New-IconFont([single]$pt) {
  New-Object System.Drawing.Font($script:iconFamily, $pt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
}
# Fallback Unicode glyph for each Material codepoint (used when the font is absent).
function Get-IconChar([int]$matCode, [int]$fallback) {
  if ($script:matFamily) { return [string][char]$matCode }
  return [string][char]$fallback
}
# Configure a header Label as an icon (Material codepoint or Unicode fallback).
function Set-IconLabel($lbl, [int]$matCode, [int]$fallback, [single]$pt) {
  $lbl.UseCompatibleTextRendering = $true
  $lbl.Font = New-IconFont $pt
  $lbl.Text = Get-IconChar $matCode $fallback
}
# Render a Material glyph to a transparent bitmap (used for the per-session
# status dots, so a row can mix the dot's font with the prompt's font, and so
# the "running" dot can be rotated). $px is the glyph size in pixels.
function New-MatIcon([int]$matCode, [int]$fallback, [single]$px, $color, [single]$angle = 0) {
  $box = [int][math]::Ceiling($px * 1.5)
  $bmp = New-Object System.Drawing.Bitmap($box, $box)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  if ($angle -ne 0) {
    $g.TranslateTransform($box / 2.0, $box / 2.0)
    $g.RotateTransform($angle)
    $g.TranslateTransform(-$box / 2.0, -$box / 2.0)
  }
  $font = New-Object System.Drawing.Font($script:iconFamily, $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $br = New-Object System.Drawing.SolidBrush($color)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString((Get-IconChar $matCode $fallback), $font, $br, (New-Object System.Drawing.RectangleF(0, 0, $box, $box)), $sf)
  $g.Dispose(); $br.Dispose(); $font.Dispose(); $sf.Dispose()
  return $bmp
}

# A rounded colour swatch with the project initials (the per-row project badge).
# Colour + initials + contrasting text colour come from session-common.ps1.
function New-Badge($name, $size) {
  $color = Get-ProjectColor $name
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $d = [int]($size * 0.42)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $d, $d, 180, 90)
  $path.AddArc($size - $d - 1, 0, $d, $d, 270, 90)
  $path.AddArc($size - $d - 1, $size - $d - 1, $d, $d, 0, 90)
  $path.AddArc(0, $size - $d - 1, $d, $d, 90, 90)
  $path.CloseFigure()
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.FillPath($brush, $path)
  $font = New-Object System.Drawing.Font('Segoe UI', [single]($size * 0.40), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $tb = New-Object System.Drawing.SolidBrush((Get-TextOn $color))
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString((Get-Initials $name), $font, $tb, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)
  $g.Dispose(); $brush.Dispose(); $tb.Dispose(); $font.Dispose(); $path.Dispose()
  return $bmp
}
