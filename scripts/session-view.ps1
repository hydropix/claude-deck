# Claude Sessions — large centered overlay (4K-friendly).
# Big dark always-on-top window listing sessions. Click a row to focus its
# VS Code / Cursor window. Auto-refreshes. Press Esc (or click ✕) to close.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::SetProcessDPIAware() | Out-Null } catch {}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinFocus {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
  const int SW_RESTORE = 9;
  public static bool FocusByTitle(string needle) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      string t = sb.ToString();
      bool isIde = t.IndexOf("Visual Studio Code", StringComparison.OrdinalIgnoreCase) >= 0
                || t.IndexOf("Cursor", StringComparison.OrdinalIgnoreCase) >= 0;
      if (isIde && t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return RaiseWindow(found);
  }
  // Find a top-level window whose title EXACTLY matches (returns hwnd or zero).
  public static IntPtr FindExact(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      if (string.Equals(sb.ToString(), title, StringComparison.OrdinalIgnoreCase)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static bool RaiseWindow(IntPtr found) {
    if (found == IntPtr.Zero) return false;
    if (IsIconic(found)) ShowWindow(found, SW_RESTORE);  // only un-minimize; never resize a maximized/normal window
    uint pid; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, fg, true);
    BringWindowToTop(found);
    SetForegroundWindow(found);
    AttachThreadInput(cur, fg, false);
    return true;
  }
  public static bool AnyMouseDown() {
    return ((GetAsyncKeyState(0x01) & 0x8000) != 0) || ((GetAsyncKeyState(0x02) & 0x8000) != 0);
  }
  public static bool CursorOutside(int l, int t, int r, int b) {
    POINT p; if (!GetCursorPos(out p)) return false;
    return (p.X < l || p.X > r || p.Y < t || p.Y > b);
  }
}

// Documented virtual-desktop API (stable across Windows updates).
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
  bool IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow);
  Guid GetWindowDesktopId(IntPtr topLevelWindow);
  void MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
}

public class VDesk {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  static IVirtualDesktopManager _mgr;
  static IVirtualDesktopManager Mgr() {
    if (_mgr == null) {
      Type t = Type.GetTypeFromCLSID(new Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a"));
      _mgr = (IVirtualDesktopManager)Activator.CreateInstance(t);
    }
    return _mgr;
  }
  // Keep the window on whatever desktop the user is currently viewing: if it's
  // not on the current desktop, move it there. Makes it feel pinned to all
  // desktops, using only the documented IVirtualDesktopManager.
  public static void FollowToCurrentDesktop(IntPtr hwnd) {
    try {
      var mgr = Mgr();
      if (mgr.IsWindowOnCurrentVirtualDesktop(hwnd)) return;
      IntPtr fg = GetForegroundWindow();
      if (fg == IntPtr.Zero || fg == hwnd) return;
      Guid id = mgr.GetWindowDesktopId(fg);
      if (id == Guid.Empty) return;
      mgr.MoveWindowToDesktop(hwnd, ref id);
    } catch {}
  }
}
"@

$WindowTitle = 'Claude Code Sessions'

# Single-instance via a named mutex. Exactly one view is alive at a time: if we
# can't create the mutex, another view already owns it -> pull its window onto THIS
# desktop (so it never yanks you elsewhere), focus it, and exit. The mutex is
# released the instant this view closes (see FormClosed), so a task finishing right
# after you close the view still pops a fresh one. The old process-scan guard could
# mistake a just-closed (still-dying) process for a live instance and silently
# swallow that popup — which is why the view didn't always appear.
$mutexCreated = $false
$script:viewMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeDeckView', [ref]$mutexCreated)
if (-not $mutexCreated) {
  $existing = [WinFocus]::FindExact($WindowTitle)
  if ($existing -ne [System.IntPtr]::Zero) {
    [VDesk]::FollowToCurrentDesktop($existing)
    [WinFocus]::RaiseWindow($existing)
  }
  exit 0
}

$stateDir    = Join-Path $env:USERPROFILE '.claude\sessions\state'
$closeFlag   = Join-Path $env:USERPROFILE '.claude\sessions\closeoutside.flag'   # opt-in: close on outside click
$posFile     = Join-Path $env:USERPROFILE '.claude\sessions\position.txt'        # top | center | bottom
$opacityFile = Join-Path $env:USERPROFILE '.claude\sessions\opacity.txt'         # 20..100 (window opacity %)
$sizeFile    = Join-Path $env:USERPROFILE '.claude\sessions\size.txt'            # 30..95 (window width, % of screen)

# Preferences (position + opacity + size) are re-read on every refresh so changes
# from the tray menu apply live without reopening the view.
$script:position = 'center'
$script:opacity  = 0.92          # default: light transparency (Light)
$script:widthPct = 55            # default window width (% of screen)
function Read-Prefs {
  $script:position = 'center'
  try { if (Test-Path $posFile) { $p = (Get-Content $posFile -Raw -ErrorAction Stop).Trim().ToLower(); if ($p -in @('top','center','bottom')) { $script:position = $p } } } catch {}
  $script:opacity = 0.92         # default: light transparency (Light)
  try { if (Test-Path $opacityFile) { $v = [int]((Get-Content $opacityFile -Raw -ErrorAction Stop).Trim()); if ($v -ge 20 -and $v -le 100) { $script:opacity = $v / 100.0 } } } catch {}
  $script:widthPct = 55          # default window width
  try { if (Test-Path $sizeFile) { $w = [int]((Get-Content $sizeFile -Raw -ErrorAction Stop).Trim()); if ($w -ge 30 -and $w -le 95) { $script:widthPct = $w } } } catch {}
}
Read-Prefs

# --- Sizing relative to the primary screen (looks right at any resolution) ---
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formW  = [int]($screen.Width  * $script:widthPct / 100)
$formH  = [int]($screen.Height * 0.70)
$titlePt = [single]([math]::Max(20, $screen.Height / 60))   # ~ 24pt on 1440p, scales on 4K
$rowPt   = [single]([math]::Max(15, $screen.Height / 85))

# Vertical placement for a window of height $h, per the chosen position.
function Get-FormTop($h) {
  $margin = [int][math]::Max(24, $screen.Height * 0.04)
  switch ($script:position) {
    'top'    { return [int]($screen.Y + $margin) }
    'bottom' { return [int]($screen.Y + $screen.Height - $h - $margin) }
    default  { return [int]($screen.Y + ($screen.Height - $h) / 2) }
  }
}

$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rowBg  = [System.Drawing.Color]::FromArgb(36, 36, 42)
$hover  = [System.Drawing.Color]::FromArgb(52, 52, 62)
$green  = [System.Drawing.Color]::FromArgb(80, 220, 130)
$orange = [System.Drawing.Color]::FromArgb(245, 175, 70)   # "waiting for you"
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)
$unseen = [System.Drawing.Color]::FromArgb(150, 175, 220)   # border: finished & not yet opened

# Stable per-project accent colour (hash of the name -> hue).
function Hue2Rgb($p, $q, $t) {
  if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
  if ($t -lt (1.0/6)) { return $p + ($q - $p) * 6 * $t }
  if ($t -lt 0.5)     { return $q }
  if ($t -lt (2.0/3)) { return $p + ($q - $p) * ((2.0/3) - $t) * 6 }
  return $p
}
function Get-ProjectColor($name) {
  if (-not $name) { $name = '?' }
  $hsh = 0
  foreach ($c in $name.ToCharArray()) { $hsh = [int](($hsh * 31 + [int]$c) % 360) }
  $h = $hsh / 360.0; $s = 0.55; $l = 0.62
  $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
  $p = 2 * $l - $q
  $r = Hue2Rgb $p $q ($h + 1.0/3); $g = Hue2Rgb $p $q $h; $b = Hue2Rgb $p $q ($h - 1.0/3)
  return [System.Drawing.Color]::FromArgb([int]($r * 255), [int]($g * 255), [int]($b * 255))
}
# Context occupied, compact: "117k" — empty string when unknown (old state files).
# We show raw tokens only (no %), since the model's true context window isn't reliably known.
function Format-Ctx($s) {
  $tok = $s.ctx_tokens
  if ($null -eq $tok) { return '' }
  if ([int]$tok -ge 1000) { return '{0}k' -f [int][math]::Round([int]$tok / 1000.0) }
  return [string][int]$tok
}
function Get-Initials($name) {
  if (-not $name) { return '?' }
  $caps = ($name -creplace '[^A-Z0-9]', '')
  if ($caps.Length -ge 2) { return $caps.Substring(0, 2) }
  return ($name.Substring(0, [math]::Min(2, $name.Length))).ToUpper()
}
function Get-TextOn($color) {
  $lum = (0.299 * $color.R + 0.587 * $color.G + 0.114 * $color.B) / 255.0
  if ($lum -gt 0.58) { return [System.Drawing.Color]::FromArgb(25, 25, 30) } else { return [System.Drawing.Color]::White }
}
# A rounded colour swatch with the project initials.
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
# Mark a session as "seen" (clears the unseen border) by writing into its state file.
function Set-Seen($sid) {
  try {
    $f = Join-Path $stateDir ($sid + '.json')
    if (Test-Path $f) {
      $o = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
      if ($o.PSObject.Properties.Name -contains 'seen') { $o.seen = $true } else { $o | Add-Member -NotePropertyName seen -NotePropertyValue $true }
      [System.IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'   # pin to the PRIMARY screen (with the taskbar), not the 2nd monitor
$form.Size            = New-Object System.Drawing.Size($formW, $formH)
$formLeft = [int]($screen.X + ($screen.Width - $formW) / 2)
$form.Location        = New-Object System.Drawing.Point($formLeft, (Get-FormTop $formH))
$form.BackColor       = $bg
$form.Opacity         = $script:opacity
$form.TopMost         = $true
$form.ShowInTaskbar   = $true
$form.Text            = $WindowTitle
$form.KeyPreview      = $true

# Reduce flicker: enable double buffering (protected property, set via reflection).
$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
$dbProp.SetValue($form, $true, $null)

# Header
$headerH = [int]($titlePt * 2.6)
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = $headerH
$header.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Claude Code Sessions'
$title.ForeColor = $white
$title.Font = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, [int](($headerH - $title.PreferredHeight) / 2))
$header.Controls.Add($title)

# Close button (X) — top-right corner
$close = New-Object System.Windows.Forms.Label
$close.Text = [char]0x2715   # heavy multiplication X
$close.ForeColor = $grey
$close.Font = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$close.AutoSize = $true
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.Add_MouseEnter({ $close.ForeColor = [System.Drawing.Color]::FromArgb(240, 90, 90) })
$close.Add_MouseLeave({ $close.ForeColor = $grey })
$close.Add_Click({ $form.Close() })
$header.Controls.Add($close)

# --- Position buttons (▲ top, ▬ middle, ▼ bottom) — to the left of X ---
$posTip = New-Object System.Windows.Forms.ToolTip
$posPt  = [single]($titlePt * 0.6)
function New-PosButton($glyph, $tip) {
  $b = New-Object System.Windows.Forms.Label
  $b.Text = $glyph
  $b.ForeColor = $grey
  $b.Font = New-Object System.Drawing.Font('Segoe UI', $posPt, [System.Drawing.FontStyle]::Bold)
  $b.AutoSize = $true
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $posTip.SetToolTip($b, $tip)
  $header.Controls.Add($b)
  return $b
}
$script:posTop = New-PosButton ([char]0x25B2) 'Position: top'
$script:posMid = New-PosButton ([char]0x25AC) 'Position: center'
$script:posBot = New-PosButton ([char]0x25BC) 'Position: bottom'

# Highlight the active position; the others stay dim.
function Update-PosHighlight {
  $script:posTop.ForeColor = if ($script:position -eq 'top')    { $white } else { $grey }
  $script:posMid.ForeColor = if ($script:position -eq 'center') { $white } else { $grey }
  $script:posBot.ForeColor = if ($script:position -eq 'bottom') { $white } else { $grey }
}
function Set-Position($pos) {
  try { Set-Content -LiteralPath $posFile -Value $pos -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
  $script:position = $pos
  $form.Top = Get-FormTop $form.Height
  Update-PosHighlight
}
$script:posTop.Add_Click({ Set-Position 'top' })
$script:posMid.Add_Click({ Set-Position 'center' })
$script:posBot.Add_Click({ Set-Position 'bottom' })
foreach ($pb in @($script:posTop, $script:posMid, $script:posBot)) {
  $pb.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(120, 175, 240) }.GetNewClosure())
  $pb.Add_MouseLeave({ Update-PosHighlight }.GetNewClosure())
}
Update-PosHighlight

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Esc to close'
$hint.ForeColor = $grey
$hint.Font = New-Object System.Drawing.Font('Segoe UI', [single]($rowPt * 0.7))
$hint.AutoSize = $true
$header.Controls.Add($hint)

# Keep X, the position buttons and the hint pinned to the right edge.
# Layout from the right:  [hint]  ▲ ▬ ▼   ✕
$header.Add_Resize({
  $cy = { param($c) [int](($headerH - $c.Height) / 2) }
  $x  = $header.Width - 20
  $x -= $close.Width;          $close.Location          = New-Object System.Drawing.Point($x, (& $cy $close))
  $x -= ($script:posBot.Width + 18); $script:posBot.Location = New-Object System.Drawing.Point($x, (& $cy $script:posBot))
  $x -= ($script:posMid.Width + 10); $script:posMid.Location = New-Object System.Drawing.Point($x, (& $cy $script:posMid))
  $x -= ($script:posTop.Width + 10); $script:posTop.Location = New-Object System.Drawing.Point($x, (& $cy $script:posTop))
  $x -= ($hint.Width + 24);    $hint.Location           = New-Object System.Drawing.Point($x, (& $cy $hint))
})

# Scrollable list
$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Dock = 'Fill'
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $bg
$listPadV = 24   # top + bottom padding
$list.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$dbProp.SetValue($list, $true, $null)   # double-buffer the list too
$form.Controls.Add($list)
$list.BringToFront()

$rowH = [int]($rowPt * 3.4)
$rowMargin = 10
$badgeSize = [int]($rowPt * 2.0)

# Spinner frames for "running" (a rotating half-disc) — animated by $spinTimer.
$script:spinFrames = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)   # ◐ ◓ ◑ ◒

function Make-Row($s, $status, $seen, $promptText, $age) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.MouseOverBackColor = $hover
  $btn.BackColor = $rowBg
  # Border is reserved for "finished but not opened yet" (unseen completion).
  if ($status -eq 'done' -and -not $seen) {
    $btn.FlatAppearance.BorderSize  = 2
    $btn.FlatAppearance.BorderColor = $unseen
  } else {
    $btn.FlatAppearance.BorderSize = 0
  }
  switch ($status) {
    'running' { $fc = $green;  $glyph = $script:spinFrames[0] }   # rotating disc (animated)
    'waiting' { $fc = $orange; $glyph = [char]0x25CF }            # ●
    default   { $fc = $grey;   $glyph = [char]0x25CB }            # ○
  }
  $btn.ForeColor = $fc
  $btn.Font = New-Object System.Drawing.Font('Segoe UI', $rowPt)
  $btn.TextAlign = 'MiddleLeft'
  $btn.TextImageRelation = 'ImageBeforeText'
  $btn.ImageAlign = 'MiddleLeft'
  $btn.Image = New-Badge ([string]$s.project) $badgeSize   # coloured square + initials
  $btn.Padding = New-Object System.Windows.Forms.Padding(14, 0, 18, 0)
  $btn.Width  = $list.ClientSize.Width - 40
  $btn.Height = $rowH
  $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $rowMargin)
  $btn.TabStop = $false
  $sep = [char]0x2014
  $ctxStr = Format-Ctx $s
  $ctxPart = if ($ctxStr) { '    ' + [char]0x2022 + ' ' + $ctxStr } else { '' }   # • 117k (59%)
  $rest = ('  {0}    {1}    {2}    ({3}){4}' -f $s.project, $sep, $promptText, $age, $ctxPart)
  $btn.Text = '  ' + $glyph + $rest
  if ($status -eq 'running') { $btn.Tag = $rest }   # spinner timer rewrites: '  ' + frame + Tag
  $btn.Add_Disposed({ param($snd, $e) try { if ($snd.Image) { $snd.Image.Dispose() } } catch {} })
  $proj = [string]$s.project
  $cwd  = [string]$s.cwd
  $sid  = [string]$s.session_id
  $btn.Add_Click({
    Set-Seen $sid                                          # mark this completion as opened
    if (-not [WinFocus]::FocusByTitle($proj)) {
      # Fallback: focus/open the REAL VS Code (never Cursor).
      $codeExe = (Get-Process -Name Code -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
      if ($codeExe -and $cwd) { Start-Process $codeExe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction SilentlyContinue }
    }
  }.GetNewClosure())
  return $btn
}

# --- Row background animations ---
#   * waiting rows  -> continuous orange "breathing" (needs your attention)
#   * just-finished -> transient green flash (which session called you)
$script:waitBtns    = @()                                              # buttons currently waiting
$script:flashBtn    = $null
$script:flashStart  = 0
$script:greenHi     = [System.Drawing.Color]::FromArgb(55, 140, 90)
$script:orangeHi    = [System.Drawing.Color]::FromArgb(150, 95, 25)    # blended toward, behind orange text
$script:lastAnimKey = $null

function Blend-Color($a, $b, $m) {
  $r  = [int]($a.R + ($b.R - $a.R) * $m)
  $g  = [int]($a.G + ($b.G - $a.G) * $m)
  $bl = [int]($a.B + ($b.B - $a.B) * $m)
  return [System.Drawing.Color]::FromArgb($r, $g, $bl)
}

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 33
$animTimer.Add_Tick({
  $t = [Environment]::TickCount
  # waiting rows breathe (orange)
  $breathe = 0.30 + 0.30 * (0.5 - 0.5 * [math]::Cos(($t / 900.0) * 2 * [math]::PI))   # ~0.0..0.6
  foreach ($b in @($script:waitBtns)) {
    try { $b.BackColor = (Blend-Color $rowBg $script:orangeHi $breathe) } catch {}
  }
  # just-finished flash (green, fades out over 2.2s, ~3 pulses)
  if ($script:flashBtn) {
    $el = $t - $script:flashStart
    if ($el -ge 2200) {
      try { $script:flashBtn.BackColor = $rowBg } catch {}
      $script:flashBtn = $null
    } else {
      $m = (1.0 - ($el / 2200.0)) * (0.5 - 0.5 * [math]::Cos(($el / 650.0) * 2 * [math]::PI))
      try { $script:flashBtn.BackColor = (Blend-Color $rowBg $script:greenHi $m) } catch { $script:flashBtn = $null }
    }
  }
  if ((@($script:waitBtns).Count -eq 0) -and (-not $script:flashBtn)) { $animTimer.Stop() }
})

# Spinner: rotate the glyph on every running row (so it visibly "turns").
$script:spinBtns = @()
$spinTimer = New-Object System.Windows.Forms.Timer
$spinTimer.Interval = 110
$spinTimer.Add_Tick({
  if (@($script:spinBtns).Count -eq 0) { $spinTimer.Stop(); return }
  $f = $script:spinFrames[ [int]([Environment]::TickCount / 110) % $script:spinFrames.Count ]
  foreach ($b in @($script:spinBtns)) {
    try { $b.Text = '  ' + $f + [string]$b.Tag } catch {}
  }
})

$script:lastSig = $null

function Refresh-List {
  # Apply live preference changes (position + opacity + size).
  Read-Prefs
  Update-PosHighlight
  if ($form.Opacity -ne $script:opacity) { $form.Opacity = $script:opacity }
  $wantW = [int]($screen.Width * $script:widthPct / 100)
  if ($script:formW -ne $wantW) {
    $script:formW    = $wantW
    $script:formLeft = [int]($screen.X + ($screen.Width - $wantW) / 2)
    $form.Width      = $wantW
    $form.Left       = $script:formLeft
    $script:lastSig  = $null            # force a row rebuild so rows reflow to the new width
  }
  $wantTop = Get-FormTop $form.Height
  if ($form.Top -ne $wantTop) { $form.Top = $wantTop }

  $now = Get-Date
  $sessions = @()
  if (Test-Path $stateDir) {
    foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
      try { $s = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
      try { $upd = [datetime]$s.updated } catch { $upd = $f.LastWriteTime }
      if (($now - $upd).TotalHours -gt 24) { continue }
      $sessions += [pscustomobject]@{ s = $s; upd = $upd }
    }
  }
  $sessions = @($sessions | Sort-Object { $_.upd } -Descending)

  # Build display rows (status + duration)
  $rows = @()
  foreach ($e in $sessions) {
    $s = $e.s
    $status = [string]$s.status
    if ($status -ne 'running' -and $status -ne 'waiting') { $status = 'done' }
    $p = [string]$s.last_prompt
    if (-not $p) { $p = '(no prompt)' }
    if ($p.Length -gt 90) { $p = $p.Substring(0, 90) + [char]0x2026 }
    $mins = [int]($now - $e.upd).TotalMinutes
    $age = if ($mins -lt 1) { 'now' } elseif ($mins -lt 60) { "${mins}m" } else { "$([int]($mins / 60))h" }
    $order = switch ($status) { 'waiting' { 0 } 'running' { 1 } default { 2 } }
    $seen  = [bool]$s.seen
    $unseenDone = ($status -eq 'done' -and -not $seen)   # finished & not yet opened -> border
    $rows += [pscustomobject]@{ s = $s; status = $status; p = $p; age = $age; order = $order; upd = $e.upd; seen = $seen; unseenDone = $unseenDone }
  }
  # Sort: waiting first, then running, then done; newest within each group.
  $rows = @($rows | Sort-Object @{ Expression = 'order' }, @{ Expression = 'upd'; Descending = $true })

  # Anti-flicker: only rebuild when the displayed content actually changed.
  $sig = ($rows | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.s.project, $_.status, $_.p, $_.age, $_.unseenDone }) -join "`n"
  if ($sig -eq $script:lastSig) { return }
  $script:lastSig = $sig

  # Which session just finished? (newest 'done' row = the one that triggered this update)
  $triggerSid = $null; $triggerKey = $null
  foreach ($r in $rows) {
    if ($r.status -eq 'done') { $triggerSid = [string]$r.s.session_id; $triggerKey = $triggerSid + '|' + [string]$r.s.updated; break }
  }

  # Buttons are about to be recreated; reset animation targets.
  $animTimer.Stop(); $spinTimer.Stop()
  $script:waitBtns = @()
  $script:spinBtns = @()
  $script:flashBtn = $null

  $list.SuspendLayout()
  $list.Controls.Clear()
  $triggerBtn = $null
  $waiting = @()
  $spinning = @()
  if ($rows.Count -eq 0) {
    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = 'No active sessions'
    $empty.ForeColor = $grey
    $empty.Font = New-Object System.Drawing.Font('Segoe UI', $rowPt)
    $empty.AutoSize = $true
    $list.Controls.Add($empty)
  } else {
    foreach ($r in $rows) {
      $b = Make-Row $r.s $r.status $r.seen $r.p $r.age
      $list.Controls.Add($b)
      if ($r.status -eq 'waiting') { $waiting += $b }
      if ($r.status -eq 'running') { $spinning += $b }
      if ($triggerSid -and ([string]$r.s.session_id -eq $triggerSid)) { $triggerBtn = $b }
    }
  }
  $list.ResumeLayout()

  # Auto-fit the window height to the number of rows (no big empty area).
  $count   = [math]::Max(1, $rows.Count)
  $desired = $headerH + $listPadV + ($count * ($rowH + $rowMargin)) + 6
  $maxH    = [int]($screen.Height * 0.9)
  $minH    = $headerH + $listPadV + ($rowH + $rowMargin) + 6
  $newH    = [math]::Min($maxH, [math]::Max($minH, $desired))
  $wantTop = Get-FormTop $newH
  if ($form.Height -ne $newH -or $form.Left -ne $formLeft -or $form.Top -ne $wantTop) {
    $form.Height = $newH
    $form.Left   = $formLeft   # keep it on the primary screen, horizontally centered
    $form.Top    = $wantTop    # top / center / bottom per the chosen position
  }

  # Drive animations: running rows spin; waiting rows breathe; a NEW completion flashes once.
  $script:waitBtns = $waiting
  $script:spinBtns = $spinning
  if ($triggerKey -and ($triggerKey -ne $script:lastAnimKey)) {
    $script:lastAnimKey = $triggerKey
    $script:flashBtn    = $triggerBtn
    $script:flashStart  = [Environment]::TickCount
    $script:shownAt     = [Environment]::TickCount   # re-arm the click-outside grace on a fresh pop
  }
  if ((@($script:waitBtns).Count -gt 0) -or $script:flashBtn) { $animTimer.Start() }
  if (@($script:spinBtns).Count -gt 0) { $spinTimer.Start() }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Refresh-List })
$timer.Start()

# Follow the user across virtual desktops (feels pinned to all desktops).
$followTimer = New-Object System.Windows.Forms.Timer
$followTimer.Interval = 350
$followTimer.Add_Tick({ try { [VDesk]::FollowToCurrentDesktop($form.Handle) } catch {} })
$followTimer.Start()

$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

# Close on a click OUTSIDE the window (left or right button), but only after a
# 0.5s grace since it (re)appeared. The window intentionally doesn't steal
# focus, so we poll the global mouse state rather than rely on Deactivate.
$script:shownAt  = [Environment]::TickCount
$script:prevDown = $false
$form.Add_Shown({ $script:shownAt = [Environment]::TickCount; Refresh-List })

$clickTimer = New-Object System.Windows.Forms.Timer
$clickTimer.Interval = 50
$clickTimer.Add_Tick({
  $down = [WinFocus]::AnyMouseDown()
  if ($down -and -not $script:prevDown -and (([Environment]::TickCount - $script:shownAt) -ge 500) -and (Test-Path $closeFlag)) {
    $b = $form.Bounds
    if ([WinFocus]::CursorOutside($b.Left, $b.Top, $b.Right, $b.Bottom)) { $form.Close() }
  }
  $script:prevDown = $down
})
$clickTimer.Start()

$form.Add_FormClosed({
  $timer.Stop(); $followTimer.Stop(); $animTimer.Stop(); $clickTimer.Stop(); $spinTimer.Stop()
  # Release the single-instance mutex immediately so the next finished task can
  # pop a fresh view without racing this process's shutdown.
  try { $script:viewMutex.ReleaseMutex() } catch {}
  try { $script:viewMutex.Dispose() } catch {}
})

[void]$form.ShowDialog()
