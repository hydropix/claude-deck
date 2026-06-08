# ClaudeDeck — Statistics dashboard.
# Reads the append-only event log (stats\events.jsonl, written by session-tracker.ps1)
# and shows a dark, 4K-friendly panel: today / week summary cards, a 14-day activity
# chart, and the top projects by focus time. Press Esc (or click the X) to close.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File session-stats.ps1
#   ... -Print     # headless: compute and print a text summary instead of the window
param([switch]$Print)

$ErrorActionPreference = 'SilentlyContinue'

# Shared helpers (paths + the per-project colour/badge functions). Dot-sourcing
# only DEFINES the functions; their System.Drawing bodies run later, at paint time,
# once the assemblies below are loaded.
. (Join-Path $PSScriptRoot 'session-common.ps1')

$statsDir = Get-CDPath 'stats'

# --- Data ------------------------------------------------------------------

# Drop log entries older than 90 days (keeps files small; we never chart that far
# back). We only rewrite the logs THIS machine owns - the local events.jsonl and
# this host's events-<HOST>.jsonl in the sync folder - never another machine's
# per-host file (rewriting it would race with its appends and trip the sync tool's
# conflict detection). Best-effort.
function Remove-OldEvents {
  $cutoff  = (Get-Date).AddDays(-90)
  $targets = @((Join-Path $statsDir 'events.jsonl'), (Get-CDEventWritePath)) | Select-Object -Unique
  foreach ($logFile in $targets) {
    try {
      if (-not (Test-Path -LiteralPath $logFile)) { continue }
      $lines  = Get-Content -LiteralPath $logFile -ErrorAction Stop
      $keep   = New-Object System.Collections.Generic.List[string]
      $dropped = $false
      foreach ($ln in $lines) {
        if (-not $ln) { continue }
        $ok = $true
        try { $o = $ln | ConvertFrom-Json; if ([datetime]$o.ts -lt $cutoff) { $ok = $false } } catch { $ok = $true }
        if ($ok) { $keep.Add($ln) } else { $dropped = $true }
      }
      if ($dropped) {
        [System.IO.File]::WriteAllText($logFile, (($keep -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
      }
    } catch {}
  }
}

# Merge every event log: the local legacy events.jsonl plus one events-<HOST>.jsonl
# per machine from the sync folder (Get-CDEventLogs). Each machine's events are
# disjoint (a session id is machine-local), so concatenating is correct - no dedup.
function Read-Events {
  $events = New-Object System.Collections.Generic.List[object]
  foreach ($logFile in (Get-CDEventLogs)) {
    $lines = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
    foreach ($ln in $lines) {
      if (-not $ln) { continue }
      try { $o = $ln | ConvertFrom-Json } catch { continue }
      if (-not $o.ts) { continue }
      try { $t = [datetime]$o.ts } catch { continue }
      $events.Add([pscustomobject]@{ ts = $t; ev = [string]$o.ev; id = [string]$o.id; project = [string]$o.project; ctx = $o.ctx; sec = $o.sec })
    }
  }
  return $events
}

# Turn a flat event list into the numbers the view draws.
#   focus time = sum of prompt -> next-stop durations per session (a completed turn).
#   A turn longer than 2h is treated as an outlier (machine asleep, etc.) and dropped.
function Get-Stats($events) {
  $now       = Get-Date
  $today     = $now.Date
  $weekStart = $today.AddDays(-6)            # last 7 days, inclusive of today

  $events = @($events | Sort-Object ts)

  # Pair prompt -> stop per session to measure how long Claude actually worked.
  $lastPrompt = @{}
  $turns = New-Object System.Collections.Generic.List[object]
  foreach ($e in $events) {
    if ($e.ev -eq 'prompt') { $lastPrompt[$e.id] = $e }
    elseif ($e.ev -eq 'stop') {
      if ($lastPrompt.ContainsKey($e.id) -and $lastPrompt[$e.id]) {
        $p   = $lastPrompt[$e.id]
        $dur = ($e.ts - $p.ts).TotalSeconds
        if ($dur -ge 0 -and $dur -le 7200) {
          # tokens processed this turn = the context the model read at the stop
          # event (input + cache). A proxy for token throughput, not a true cost.
          $tok = 0; if ($null -ne $e.ctx) { try { $tok = [int]$e.ctx } catch { $tok = 0 } }
          $turns.Add([pscustomobject]@{ project = $p.project; end = $e.ts; dur = $dur; tok = $tok })
        }
        $lastPrompt[$e.id] = $null
      }
    }
  }

  # Distraction time (logged by the tray's classifier as 'distract' events, each
  # carrying the seconds spent off task in that stint). Kept SEPARATE from focus
  # time - it never inflates the focus totals; it surfaces as its own project row.
  $distract = @($events | Where-Object { $_.ev -eq 'distract' })
  $todayDistract = [int](($distract | Where-Object { $_.ts.Date -eq $today }     | ForEach-Object { try { [int]$_.sec } catch { 0 } } | Measure-Object -Sum).Sum)
  $weekDistract  = [int](($distract | Where-Object { $_.ts.Date -ge $weekStart } | ForEach-Object { try { [int]$_.sec } catch { 0 } } | Measure-Object -Sum).Sum)

  $prompts = @($events | Where-Object { $_.ev -eq 'prompt' })

  # Set of dates with at least one prompt -> streak.
  $active = @{}
  foreach ($p in $prompts) { $active[$p.ts.Date.ToString('yyyy-MM-dd')] = $true }
  $streak = 0
  $d = $today
  if (-not $active.ContainsKey($d.ToString('yyyy-MM-dd'))) { $d = $today.AddDays(-1) }  # grace: today not started yet
  while ($active.ContainsKey($d.ToString('yyyy-MM-dd'))) { $streak++; $d = $d.AddDays(-1) }

  # 14-day activity (prompts per day, oldest -> newest).
  $days = New-Object System.Collections.Generic.List[object]
  for ($i = 13; $i -ge 0; $i--) {
    $dd  = $today.AddDays(-$i)
    $cnt = @($prompts | Where-Object { $_.ts.Date -eq $dd }).Count
    $days.Add([pscustomobject]@{ date = $dd; count = $cnt })
  }

  # Today / week aggregates.
  $todayPrompts  = @($prompts | Where-Object { $_.ts.Date -eq $today })
  $weekPrompts   = @($prompts | Where-Object { $_.ts.Date -ge $weekStart })
  $todayWork     = [int](($turns | Where-Object { $_.end.Date -eq $today }     | Measure-Object dur -Sum).Sum)
  $weekWork      = [int](($turns | Where-Object { $_.end.Date -ge $weekStart } | Measure-Object dur -Sum).Sum)
  $todayTokens   = [long](($turns | Where-Object { $_.end.Date -eq $today }     | Measure-Object tok -Sum).Sum)
  $weekTokens    = [long](($turns | Where-Object { $_.end.Date -ge $weekStart } | Measure-Object tok -Sum).Sum)
  $todayProjects = @($todayPrompts | Select-Object -ExpandProperty project -Unique).Count
  $weekProjects  = @($weekPrompts  | Select-Object -ExpandProperty project -Unique).Count

  # Top projects this week, by focus time. Merge per-project prompts + work.
  $proj = @{}
  foreach ($p in $weekPrompts) {
    $k = $p.project; if (-not $k) { $k = 'session' }
    if (-not $proj.ContainsKey($k)) { $proj[$k] = [pscustomobject]@{ project = $k; prompts = 0; work = 0; tokens = [long]0 } }
    $proj[$k].prompts++
  }
  foreach ($t in @($turns | Where-Object { $_.end.Date -ge $weekStart })) {
    $k = $t.project; if (-not $k) { $k = 'session' }
    if (-not $proj.ContainsKey($k)) { $proj[$k] = [pscustomobject]@{ project = $k; prompts = 0; work = 0; tokens = [long]0 } }
    $proj[$k].work += $t.dur
    $proj[$k].tokens += $t.tok
  }
  $top = @($proj.Values | Sort-Object @{ Expression = 'work'; Descending = $true }, @{ Expression = 'prompts'; Descending = $true } | Select-Object -First 6)
  # Pin the distraction tally as its own row (always shown when there's any off-task
  # time this week), so it reads as a project even if it wouldn't make the top 6.
  if ($weekDistract -gt 0) {
    $top = @($top) + @([pscustomobject]@{ project = 'distraction'; prompts = 0; work = $weekDistract; tokens = [long]0 })
  }

  return [pscustomobject]@{
    todayPrompts = $todayPrompts.Count
    weekPrompts  = $weekPrompts.Count
    todayWork    = $todayWork
    weekWork     = $weekWork
    todayProjects = $todayProjects
    weekProjects  = $weekProjects
    todayTokens  = $todayTokens
    weekTokens   = $weekTokens
    todayDistract = $todayDistract
    weekDistract  = $weekDistract
    streak       = $streak
    days         = [object[]]$days     # [object[]] cast, not @(...): casting a Hashtable to
    top          = [object[]]$top      # [pscustomobject] throws on @() arrays-of-PSObject (PS 5.1)
    totalEvents  = $events.Count
  }
}

function Format-Dur($sec) {
  $sec = [int]$sec
  if ($sec -le 0) { return '0m' }
  # NB: [int]($sec/3600) would ROUND (PS banker's rounding: 1920s -> "1h 32m"),
  # so floor explicitly to truncate hours/minutes.
  $h = [int][math]::Floor($sec / 3600); $m = [int][math]::Floor(($sec % 3600) / 60)
  if ($h -gt 0) { return ('{0}h {1:00}m' -f $h, $m) }
  return ('{0}m' -f $m)
}

# Compact token count: 1234 -> "1.2k", 3400000 -> "3.4M". Best-effort, never
# throws. Uses invariant culture so the decimal is always a '.' (English UI).
function Format-Tokens($n) {
  try { $n = [double]$n } catch { return '0' }
  $ci = [System.Globalization.CultureInfo]::InvariantCulture
  if ($n -le 0)        { return '0' }
  if ($n -lt 1000)     { return ([int]$n).ToString($ci) }
  if ($n -lt 1000000)  { return ($n / 1000).ToString('0.#', $ci) + 'k' }
  return ($n / 1000000).ToString('0.#', $ci) + 'M'
}

# --- Headless mode (for testing the computation without a window) -----------
if ($Print) {
  Remove-OldEvents
  $st = Get-Stats (Read-Events)
  Write-Output ('Events logged : {0}' -f $st.totalEvents)
  Write-Output ('Today         : {0} prompts, {1} projects, {2} focus, {3} tokens' -f $st.todayPrompts, $st.todayProjects, (Format-Dur $st.todayWork), (Format-Tokens $st.todayTokens))
  Write-Output ('This week     : {0} prompts, {1} projects, {2} focus, {3} tokens' -f $st.weekPrompts, $st.weekProjects, (Format-Dur $st.weekWork), (Format-Tokens $st.weekTokens))
  Write-Output ('Distraction   : {0} today, {1} this week (off task)' -f (Format-Dur $st.todayDistract), (Format-Dur $st.weekDistract))
  Write-Output ('Streak        : {0} day(s)' -f $st.streak)
  Write-Output  'Activity (14d): '
  foreach ($d in $st.days) { Write-Output ('   {0}  {1}' -f $d.date.ToString('MM-dd'), ('#' * [math]::Min(40, $d.count))) }
  Write-Output  'Top projects  : '
  foreach ($p in $st.top) { Write-Output ('   {0,-24} {1,3} prompts  {2,-8}  {3,6} tok' -f $p.project, $p.prompts, (Format-Dur $p.work), (Format-Tokens $p.tokens)) }
  exit 0
}

# --- Window ----------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Set-CDDpiAware   # Per-Monitor-V2 DPI awareness (common); crisp on mixed-scaling displays

# Reuse the deck's exact project badge (New-Badge) so the workspace logo is
# pixel-identical here and in the large view. Must load AFTER System.Drawing and
# after session-common.ps1 (New-Badge depends on both).
. (Join-Path $PSScriptRoot 'session-ui-icons.ps1')

$WindowTitle = 'ClaudeDeck Statistics'

# Single instance: focus the existing window and exit if one is already open.
$mutexCreated = $false
$script:statsMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeDeckStats', [ref]$mutexCreated)
if (-not $mutexCreated) {
  Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class StatFocus {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  public static void Focus(string title) {
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h); if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 1); GetWindowText(h, sb, sb.Capacity);
      if (string.Equals(sb.ToString(), title, StringComparison.OrdinalIgnoreCase)) {
        if (IsIconic(h)) ShowWindow(h, 9); SetForegroundWindow(h); return false;
      }
      return true;
    }, IntPtr.Zero);
  }
}
"@
  [StatFocus]::Focus($WindowTitle)
  exit 0
}

# Palette (matches the large view).
$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$cardBg = [System.Drawing.Color]::FromArgb(36, 36, 42)
$barBg  = [System.Drawing.Color]::FromArgb(48, 48, 56)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$dim    = [System.Drawing.Color]::FromArgb(110, 110, 120)
$green  = [System.Drawing.Color]::FromArgb(80, 220, 130)
$orange = [System.Drawing.Color]::FromArgb(245, 175, 70)
$accent = [System.Drawing.Color]::FromArgb(110, 165, 240)

# Per-project accent colour + initials badge: Get-ProjectColor / Get-Initials /
# Get-TextOn now live in session-common.ps1 (shared with the deck).

# --- Sizing relative to the primary screen (looks right at any resolution) ---
# The Size preference (size.txt, written by the deck) scales this window in
# lockstep with the large view: same source file, same scale factor (widthPct/55,
# 55 = 1.0 reference), same window width (widthPct % of the screen). Read once at
# startup — the stats window is short-lived and reopened, not live-refreshed.
$screen  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$sizeFile = Get-CDPath 'size.txt'
$widthPct = 48                                              # default = Normal (matches the deck)
try { if (Test-Path $sizeFile) { $w = [int]((Get-Content $sizeFile -Raw -ErrorAction Stop).Trim()); if ($w -ge 30 -and $w -le 95) { $widthPct = $w } } } catch {}
$scale   = $widthPct / 55.0                                 # 55 = 1.0 reference (same as the deck)
$basePt  = [single][math]::Max(8, ($screen.Height / 95.0) * $scale)   # ~11pt at scale 1.0 on 1080p
$titlePt = [single]($basePt * 1.55)
$bigPt   = [single]($basePt * 2.0)
$smallPt = [single]($basePt * 0.78)

$fTitle = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$fBig   = New-Object System.Drawing.Font('Segoe UI', $bigPt,   [System.Drawing.FontStyle]::Bold)
$fLabel = New-Object System.Drawing.Font('Segoe UI', $smallPt, [System.Drawing.FontStyle]::Bold)
$fBody  = New-Object System.Drawing.Font('Segoe UI', $basePt)
$fSmall = New-Object System.Drawing.Font('Segoe UI', $smallPt)

$pad     = [int]($basePt * 1.7)
$headerH = [int]($titlePt * 2.4)
$cardH   = [int]($basePt * 5.8)
$chartH  = [int]($basePt * 6.8)
$rowH    = [int]($basePt * 2.9)

# Window width tracks the deck's Size preference (widthPct % of the screen), so
# the two windows are the same width on screen. Floored so the 3-card layout never
# cramps, and capped so it never overflows the monitor.
$formW = [int]([math]::Min($screen.Width * 0.95, [math]::Max(520, $screen.Width * $widthPct / 100.0)))
# Content height drives the window height so there's never a big empty area.
$contentH = $headerH + $pad + $cardH + $pad + ($basePt * 2.0) + $chartH + $pad + ($basePt * 2.0) + (6 * ($rowH + $basePt)) + $pad
$formH = [int]([math]::Min($screen.Height * 0.92, $contentH))

$sf = New-Object System.Drawing.StringFormat
$sfR = New-Object System.Drawing.StringFormat; $sfR.Alignment = 'Far'
$sfC = New-Object System.Drawing.StringFormat; $sfC.Alignment = 'Center'; $sfC.LineAlignment = 'Center'

function New-SolidBrush($c) { return New-Object System.Drawing.SolidBrush($c) }
function Add-RoundRect($g, $rect, $radius, $color) {
  $d = $radius * 2
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
  $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $br = New-SolidBrush $color
  $g.FillPath($br, $path)
  $br.Dispose(); $path.Dispose()
}

$script:stats = $null

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.Size            = New-Object System.Drawing.Size($formW, $formH)
$form.Location        = New-Object System.Drawing.Point(
  [int]($screen.X + ($screen.Width - $formW) / 2),
  [int]($screen.Y + ($screen.Height - $formH) / 2))
$form.BackColor       = $bg
$form.Text            = $WindowTitle
$form.KeyPreview      = $true
$form.ShowInTaskbar   = $true
$iconPath = Join-Path $PSScriptRoot 'logo.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }

$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
$dbProp.SetValue($form, $true, $null)

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = $headerH
$header.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'ClaudeDeck ' + [char]0x2014 + ' Statistics'
$title.ForeColor = $white; $title.Font = $fTitle; $title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point($pad, [int](($headerH - $title.PreferredHeight) / 2))
$header.Controls.Add($title)

$close = New-Object System.Windows.Forms.Label
$close.Text = [char]0x2715; $close.ForeColor = $grey; $close.Font = $fTitle; $close.AutoSize = $true
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.Add_MouseEnter({ $close.ForeColor = [System.Drawing.Color]::FromArgb(240, 90, 90) })
$close.Add_MouseLeave({ $close.ForeColor = $grey })
$close.Add_Click({ $form.Close() })
$header.Controls.Add($close)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Esc to close'; $hint.ForeColor = $grey; $hint.Font = $fSmall; $hint.AutoSize = $true
$header.Controls.Add($hint)

function Set-HeaderLayout {
  $cy = { param($c) [int](($headerH - $c.Height) / 2) }
  $x = $header.Width - $pad
  $x -= $close.Width;        $close.Location = New-Object System.Drawing.Point($x, (& $cy $close))
  $x -= ($hint.Width + $pad); $hint.Location  = New-Object System.Drawing.Point($x, (& $cy $hint))
}
$header.Add_Resize({ Set-HeaderLayout })
Set-HeaderLayout

# Body canvas — everything below the header is custom-painted.
$canvas = New-Object System.Windows.Forms.Panel
$canvas.Dock = 'Fill'; $canvas.BackColor = $bg
$dbProp.SetValue($canvas, $true, $null)
$form.Controls.Add($canvas)
$canvas.BringToFront()

# Draw one summary card: label on top, then a big value on the LEFT with its two
# sub-lines set to the RIGHT of it, vertically centred against the number — so the
# wide empty space beside the value is used instead of stacking everything down
# the left edge. Heights come from each font's real pixel height (scale-safe).
function Draw-Card($g, $rect, $label, $value, $valColor, $line1, $line2) {
  Add-RoundRect $g $rect ([int]($basePt * 0.8)) $cardBg
  $bL = New-SolidBrush $grey; $bV = New-SolidBrush $valColor; $bB = New-SolidBrush $white
  $px = $rect.X + [int]($basePt * 1.4)
  $y  = $rect.Y + $basePt * 0.9
  $g.DrawString($label.ToUpper(), $fLabel, $bL, [single]$px, [single]$y)
  $y += $fLabel.GetHeight($g) + $basePt * 0.4
  # Big value on the left.
  $g.DrawString($value, $fBig, $bV, [single]($px - 2), [single]$y)
  $bigH = $fBig.GetHeight($g)
  $vw   = $g.MeasureString($value, $fBig).Width
  # Sub-lines to the right, as a block centred on the value's height.
  $sx  = $px + $vw + $basePt * 0.7
  $l1h = if ($line1) { $fBody.GetHeight($g) }  else { 0 }
  $l2h = if ($line2) { $fSmall.GetHeight($g) } else { 0 }
  $lgap = if ($line1 -and $line2) { $basePt * 0.2 } else { 0 }
  $sy  = $y + ($bigH - ($l1h + $lgap + $l2h)) / 2
  if ($line1) { $g.DrawString($line1, $fBody, $bB, [single]$sx, [single]$sy); $sy += $l1h + $lgap }
  if ($line2) { $g.DrawString($line2, $fSmall, $bL, [single]$sx, [single]$sy) }
  $bL.Dispose(); $bV.Dispose(); $bB.Dispose()
}

$canvas.Add_Paint({
  param($snd, $e)
  $g = $e.Graphics
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $st = $script:stats
  $W = $canvas.ClientSize.Width
  $bGrey = New-SolidBrush $grey; $bWhite = New-SolidBrush $white; $bDim = New-SolidBrush $dim

  if (-not $st -or $st.totalEvents -eq 0) {
    $g.DrawString('No activity recorded yet.', $fTitle, $bWhite, (New-Object System.Drawing.RectangleF(0, ($canvas.ClientSize.Height/2 - $basePt*3), $W, $basePt*3)), $sfC)
    $g.DrawString('Use Claude Code and your stats will appear here.', $fBody, $bGrey, (New-Object System.Drawing.RectangleF(0, ($canvas.ClientSize.Height/2), $W, $basePt*3)), $sfC)
    $bGrey.Dispose(); $bWhite.Dispose(); $bDim.Dispose()
    return
  }

  $y = $pad

  # --- Summary cards (3 across) ---
  $gap   = $pad
  $cardW = [int](($W - $pad * 2 - $gap * 2) / 3)
  $c1 = New-Object System.Drawing.Rectangle($pad, $y, $cardW, $cardH)
  $c2 = New-Object System.Drawing.Rectangle(($pad + $cardW + $gap), $y, $cardW, $cardH)
  $c3 = New-Object System.Drawing.Rectangle(($pad + ($cardW + $gap) * 2), $y, ($W - $pad - ($pad + ($cardW + $gap) * 2)), $cardH)
  $projWord = { param($n) if ($n -eq 1) { '1 project' } else { ('{0} projects' -f $n) } }
  Draw-Card $g $c1 'Today'     ([string]$st.todayPrompts) $green  (& $projWord $st.todayProjects) ((Format-Dur $st.todayWork) + ' focus ' + [char]0x2022 + ' ' + (Format-Tokens $st.todayTokens) + ' tok')
  Draw-Card $g $c2 'This week' ([string]$st.weekPrompts)  $accent (& $projWord $st.weekProjects)  ((Format-Dur $st.weekWork) + ' focus ' + [char]0x2022 + ' ' + (Format-Tokens $st.weekTokens) + ' tok')
  $streakSub = if ($st.streak -eq 1) { 'day in a row' } else { 'days in a row' }
  Draw-Card $g $c3 'Streak'    ([string]$st.streak)       $orange $streakSub ('prompts: ' + $st.weekPrompts + ' this week')
  $y += $cardH + $pad

  # --- Activity chart (14 days) ---
  $g.DrawString('ACTIVITY ' + [char]0x2014 + ' LAST 14 DAYS', $fLabel, $bGrey, [single]$pad, [single]$y)
  $y += [int]($basePt * 2.0)
  $chartX = $pad; $chartW = $W - $pad * 2
  $labelH = [int]($basePt * 1.6)
  $barsH  = $chartH - $labelH
  $maxCnt = ($st.days | Measure-Object count -Maximum).Maximum
  if ($maxCnt -lt 1) { $maxCnt = 1 }
  $n = $st.days.Count
  $slot = $chartW / $n
  $barW = [int]([math]::Max(6, $slot * 0.62))
  $baseY = $y + $barsH
  $bAccent = New-SolidBrush $accent; $bToday = New-SolidBrush $green; $bBarBg = New-SolidBrush $barBg
  for ($i = 0; $i -lt $n; $i++) {
    $d = $st.days[$i]
    $cx = [int]($chartX + $slot * $i + ($slot - $barW) / 2)
    $h  = [int](($d.count / [double]$maxCnt) * ($barsH - $basePt))
    if ($h -lt 2 -and $d.count -gt 0) { $h = 2 }
    # track
    Add-RoundRect $g (New-Object System.Drawing.Rectangle($cx, $y, $barW, $barsH)) ([int]($barW/3)) $barBg
    $isToday = ($i -eq $n - 1)
    if ($d.count -gt 0) {
      $br = if ($isToday) { $bToday } else { $bAccent }
      Add-RoundRect $g (New-Object System.Drawing.Rectangle($cx, ($baseY - $h), $barW, $h)) ([int]($barW/3)) $br.Color
      $g.DrawString([string]$d.count, $fSmall, $bGrey, (New-Object System.Drawing.RectangleF($cx - $slot*0.2, ($baseY - $h - $basePt*1.3), $barW + $slot*0.4, $basePt*1.3)), $sfC)
    }
    # weekday letter under every bar; full date under first + last
    $lab = $d.date.ToString('ddd').Substring(0,1)
    if ($i -eq 0 -or $isToday) { $lab = $d.date.ToString('MM-dd') }
    $fl = if ($i -eq 0 -or $isToday) { $fSmall } else { $fSmall }
    $cl = if ($isToday) { $bWhite } else { $bDim }
    $g.DrawString($lab, $fl, $cl, (New-Object System.Drawing.RectangleF($cx - $slot*0.3, ($baseY + 2), $barW + $slot*0.6, $labelH)), $sfC)
  }
  $bAccent.Dispose(); $bToday.Dispose(); $bBarBg.Dispose()
  $y = $baseY + $labelH + $pad

  # --- Top projects this week ---
  $g.DrawString('TOP PROJECTS ' + [char]0x2014 + ' THIS WEEK', $fLabel, $bGrey, [single]$pad, [single]$y)
  $y += [int]($basePt * 2.0)
  $top = @($st.top)
  if ($top.Count -eq 0) {
    $g.DrawString('No focus time logged this week yet.', $fBody, $bGrey, [single]$pad, [single]$y)
  } else {
    $maxWork = ($top | Measure-Object work -Maximum).Maximum
    if ($maxWork -lt 1) { $maxWork = 1 }
    $badge = [int]($rowH * 0.62)
    $statW = [int]($basePt * 15)
    $distractRed = [System.Drawing.Color]::FromArgb(235, 95, 95)
    foreach ($p in $top) {
      $rowY = $y
      $isDistract = ($p.project -eq 'distraction')
      $bx = $pad; $by = $rowY + [int](($rowH - $badge)/2)
      if ($isDistract) {
        # Distinct red badge with a "!" so off-task time never reads like a project.
        $col = $distractRed
        Add-RoundRect $g (New-Object System.Drawing.Rectangle($bx, $by, $badge, $badge)) ([int]($badge * 0.28)) $col
        $bExc = New-SolidBrush $white
        $g.DrawString('!', $fLabel, $bExc, (New-Object System.Drawing.RectangleF($bx, $by, $badge, $badge)), $sfC)
        $bExc.Dispose()
      } else {
        # badge — same renderer as the deck (New-Badge) so the workspace logo is identical
        $col = Get-ProjectColor $p.project
        $bmp = New-Badge $p.project $badge
        $g.DrawImage($bmp, $bx, $by, $badge, $badge)
        $bmp.Dispose()
      }
      # name
      $nameX = $pad + $badge + [int]($basePt * 0.9)
      $nameTxt   = if ($isDistract) { 'Distraction' } else { $p.project }
      $nameBrush = if ($isDistract) { New-SolidBrush $distractRed } else { $bWhite }
      $g.DrawString($nameTxt, $fBody, $nameBrush, (New-Object System.Drawing.RectangleF($nameX, ($rowY + ($rowH - $basePt*1.6)/2), ($W - $nameX - $statW - $pad), $basePt*1.8)), $sf)
      if ($isDistract) { $nameBrush.Dispose() }
      # right-aligned stat: "12  ·  1h 20m  ·  1.2M tok"  (distraction: just the time off task)
      $statTxt = if ($isDistract) { (Format-Dur $p.work) + ' off task' }
                 else { ('{0} ' -f $p.prompts) + [char]0x2022 + ' ' + (Format-Dur $p.work) + ' ' + [char]0x2022 + ' ' + (Format-Tokens $p.tokens) + ' tok' }
      $statBrush = if ($isDistract) { New-SolidBrush $distractRed } else { $bGrey }
      $g.DrawString($statTxt, $fSmall, $statBrush, (New-Object System.Drawing.RectangleF(($W - $statW - $pad), ($rowY + ($rowH - $basePt*1.6)/2), $statW, $basePt*1.8)), $sfR)
      if ($isDistract) { $statBrush.Dispose() }
      # work bar under the name
      $barX = $nameX; $barFullW = $W - $nameX - $statW - $pad * 2
      $barY = $rowY + $rowH - [int]($basePt * 0.9)
      $bh = [int]($basePt * 0.55)
      Add-RoundRect $g (New-Object System.Drawing.Rectangle($barX, $barY, $barFullW, $bh)) ([int]($bh/2)) $barBg
      $fillW = [int]($barFullW * ($p.work / [double]$maxWork))
      if ($fillW -gt 2) { Add-RoundRect $g (New-Object System.Drawing.Rectangle($barX, $barY, $fillW, $bh)) ([int]($bh/2)) $col }
      $y += $rowH + [int]($basePt * 0.7)
    }
  }
  $bGrey.Dispose(); $bWhite.Dispose(); $bDim.Dispose()
})

function Update-Stats {
  Remove-OldEvents
  $script:stats = Get-Stats (Read-Events)
  # Auto-fit the window height to the actual content (no big empty area below
  # the last project), then keep it vertically centered on the primary screen.
  $rows = if ($script:stats -and $script:stats.totalEvents -gt 0) { [math]::Max(1, @($script:stats.top).Count) } else { 0 }
  if ($rows -gt 0) {
    $bodyH = $pad + $cardH + $pad + ($basePt * 2.0) + $chartH + $pad + ($basePt * 2.0) + ($rows * ($rowH + $basePt * 0.7)) + $pad
  } else {
    $bodyH = $basePt * 16
  }
  $newH = [int]([math]::Min($screen.Height * 0.92, ($headerH + $bodyH)))
  if ($form.Height -ne $newH) {
    $form.Height = $newH
    $form.Top    = [int]($screen.Y + ($screen.Height - $newH) / 2)
  }
  $canvas.Invalidate()
}

$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

# Refresh periodically so the dashboard stays live while open.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Stats })
$form.Add_Shown({ Update-Stats; $timer.Start() })
$form.Add_FormClosed({
  $timer.Stop()
  try { $script:statsMutex.ReleaseMutex() } catch {}
  try { $script:statsMutex.Dispose() } catch {}
})

[void]$form.ShowDialog()
