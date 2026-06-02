# Generates scripts/notify.wav - the discreet "a session needs you" chime played
# by session-tracker.ps1 on a genuine waiting notification. Kept as a generator
# (not a hand-committed mystery binary) so the sound stays tweakable and the asset
# is fully reproducible. Re-run after editing, then rebuild the bundle:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make-notify-wav.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$out  = Join-Path $root 'scripts\notify.wav'

$rate = 44100                       # samples / second
$amp  = 0.22                        # peak amplitude (0..1) - deliberately gentle

# A soft two-note rise (G5 -> C6): a pleasant, non-jarring "ti-dum".
$notes = @(
  @{ freq = 783.99; start = 0.000; dur = 0.16 }   # G5
  @{ freq = 1046.50; start = 0.11; dur = 0.26 }    # C6 (overlaps slightly for a connected feel)
)

$total   = 0.0
foreach ($n in $notes) { $end = $n.start + $n.dur; if ($end -gt $total) { $total = $end } }
$count   = [int]([math]::Ceiling($total * $rate))
$samples = New-Object 'double[]' $count

foreach ($n in $notes) {
  $s0 = [int]($n.start * $rate)
  $ns = [int]($n.dur * $rate)
  for ($i = 0; $i -lt $ns; $i++) {
    $t = $i / $rate
    # Exponential decay (bell-like) + 4 ms raised-cosine fade-in to kill the click.
    $env = [math]::Exp(-5.0 * ($t / $n.dur))
    $fadeN = [int](0.004 * $rate)
    if ($i -lt $fadeN) { $env *= 0.5 * (1 - [math]::Cos([math]::PI * $i / $fadeN)) }
    $idx = $s0 + $i
    if ($idx -ge 0 -and $idx -lt $count) {
      $samples[$idx] += [math]::Sin(2 * [math]::PI * $n.freq * $t) * $env
    }
  }
}

# Normalize to the target peak, then write a 16-bit mono PCM WAV.
$peak = 0.0
foreach ($v in $samples) { $a = [math]::Abs($v); if ($a -gt $peak) { $peak = $a } }
$scale = if ($peak -gt 0) { ($amp / $peak) * 32767.0 } else { 0.0 }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$dataBytes = $count * 2
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
$bw.Write([int](36 + $dataBytes))
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
$bw.Write([int]16)                  # fmt chunk size
$bw.Write([int16]1)                 # PCM
$bw.Write([int16]1)                 # mono
$bw.Write([int]$rate)               # sample rate
$bw.Write([int]($rate * 2))         # byte rate
$bw.Write([int16]2)                 # block align
$bw.Write([int16]16)                # bits / sample
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
$bw.Write([int]$dataBytes)
foreach ($v in $samples) {
  $s = [int][math]::Round($v * $scale)
  if ($s -gt 32767) { $s = 32767 } elseif ($s -lt -32768) { $s = -32768 }
  $bw.Write([int16]$s)
}
$bw.Flush()
[System.IO.File]::WriteAllBytes($out, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Write-Host ("Wrote {0} ({1:N0} bytes, {2:N0} ms)" -f $out, (Get-Item $out).Length, ($total * 1000)) -ForegroundColor Green
