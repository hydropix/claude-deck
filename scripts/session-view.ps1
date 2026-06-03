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
  // Standard taskbar attention flash (used by the focus nudge).
  [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO p);
  [StructLayout(LayoutKind.Sequential)] struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
  public static void Flash(IntPtr h, uint count) {
    FLASHWINFO fi = new FLASHWINFO();
    fi.cbSize = (uint)Marshal.SizeOf(fi);
    fi.hwnd = h; fi.dwFlags = 3 /* FLASHW_ALL */; fi.uCount = count; fi.dwTimeout = 0;
    FlashWindowEx(ref fi);
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

# A Form that NEVER steals the keyboard focus. The deck is an overlay that pops
# up on task completion, so it must not interrupt whatever you're typing in
# another window. ShowWithoutActivation skips activation when it's shown;
# WS_EX_NOACTIVATE also keeps it from grabbing focus if you later click it
# (rows/buttons/drag still work via their own mouse handlers).
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' -TypeDefinition @"
using System;
using System.Windows.Forms;
public class NoActivateForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      const int WS_EX_NOACTIVATE = 0x08000000;
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= WS_EX_NOACTIVATE;
      return cp;
    }
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
$dndFlag     = Join-Path $env:USERPROFILE '.claude\sessions\dnd.flag'            # suspend auto-popup on completion
$focusFlag   = Join-Path $env:USERPROFILE '.claude\sessions\focus.flag'          # opt-in: nudge me back when Claude is idle and I'm distracted
$posFile     = Join-Path $env:USERPROFILE '.claude\sessions\position.txt'        # top | bottom | free
$posXFile    = Join-Path $env:USERPROFILE '.claude\sessions\posx.txt'            # custom left (px); present = user dragged a horizontal spot
$posYFile    = Join-Path $env:USERPROFILE '.claude\sessions\posy.txt'            # custom top (px); used only when position = free
$opacityFile = Join-Path $env:USERPROFILE '.claude\sessions\opacity.txt'         # 20..100 (window opacity %)
$sizeFile    = Join-Path $env:USERPROFILE '.claude\sessions\size.txt'            # 30..95 (overall scale; 55 = Normal/1.0, drives width + fonts)

# --- Update / version files (shared with the tray) ---
$autoUpdFlag = Join-Path $env:USERPROFILE '.claude\sessions\autoupdate.flag'
$updInfoFile = Join-Path $env:USERPROFILE '.claude\sessions\update.json'
$updScript   = Join-Path $env:USERPROFILE '.claude\sessions\session-update.ps1'
$verFile     = Join-Path $env:USERPROFILE '.claude\sessions\version.txt'
$statsVbs    = Join-Path $env:USERPROFILE '.claude\sessions\show-stats.vbs'

# Pomodoro: the tray owns the clock + tracking and writes pomodoro.json; the deck
# header just renders it and drops control tokens into pomodoro-cmd.txt.
$pomoState   = Join-Path $env:USERPROFILE '.claude\sessions\pomodoro.json'
$pomoCmd     = Join-Path $env:USERPROFILE '.claude\sessions\pomodoro-cmd.txt'

# Focus nudge: the tray stamps a tick count into focus-nudge.txt on each nudge.
# We poll it on the 1s Pomodoro timer and play the animation when the stamp is fresh.
# At startup: a STALE stamp is seeded into lastNudgeSeen (so opening the deck later
# never replays an old nudge), but a FRESH one is left unseen - that's the case where
# the tray popped the deck open *for* this nudge, so the first poll should play it.
$nudgeFile   = Join-Path $env:USERPROFILE '.claude\sessions\focus-nudge.txt'
$script:lastNudgeSeen = $null
try {
  if (Test-Path $nudgeFile) {
    $nv = ([System.IO.File]::ReadAllText($nudgeFile)).Trim()
    $nAge = 999999
    try { $nAge = [Environment]::TickCount - [int]$nv } catch {}
    if (-not ($nAge -ge 0 -and $nAge -lt 12000)) { $script:lastNudgeSeen = $nv }
  }
} catch {}

function Get-LocalVersion {
  try { if (Test-Path $verFile) { return ([System.IO.File]::ReadAllText($verFile)).Trim() } } catch {}
  return $null
}
# Launch a version check / install in a hidden background process (never blocks the UI).
function Invoke-Updater([string]$mode) {
  if (-not (Test-Path $updScript)) { return }
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $updScript), $mode
  ) -ErrorAction SilentlyContinue
}
# Read the last check result -> the parsed object when an update is available, else $null.
function Get-UpdateInfo {
  try {
    if (Test-Path $updInfoFile) {
      $j = [System.IO.File]::ReadAllText($updInfoFile) | ConvertFrom-Json
      if ($j.available) { return $j }
    }
  } catch {}
  return $null
}
# Toggle a flag file on/off (used by the settings menu checkboxes).
function Toggle-Flag([string]$path) {
  if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
  else { Set-Content -LiteralPath $path -Value '' -Encoding ASCII -ErrorAction SilentlyContinue }
}

# --- Favorite-workspace helpers --------------------------------------------
# Run the shared helper as a hidden child process - NEVER dot-sourced. Dot-sourcing
# a param()-block script into this WinForms scope leaked side effects that broke the
# session list rendering. This mirrors Invoke-Updater above and keeps scopes clean.
$wsHelper = Join-Path $PSScriptRoot 'session-workspaces.ps1'
$wsFile   = Join-Path $env:USERPROFILE '.claude\sessions\workspaces.json'
function Invoke-Workspaces([string]$mode) {
  if (-not (Test-Path $wsHelper)) { return }
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $wsHelper), $mode
  ) -ErrorAction SilentlyContinue
}
# Count of saved favorites - read straight from workspaces.json (no helper needed).
function Get-FavCount {
  try { if (Test-Path $wsFile) { return @(([System.IO.File]::ReadAllText($wsFile) | ConvertFrom-Json).items).Count } } catch {}
  return 0
}

# --- Google Material Icons -------------------------------------------------
# We bundle MaterialIcons-Regular.ttf (Apache 2.0) next to this script and load
# it privately (no system install). All deck glyphs — position, gear, close and
# the per-session status dots — are drawn from it. If the font is missing we
# fall back to Unicode glyphs in Segoe UI, so the deck still works.
#   settings e8b8  close e5cd  vertical_align_top/bottom e25a/e258
#   fiber_manual_record e061 (filled)  radio_button_unchecked e836 (outline)
$script:MAT = @{ top=0xE25A; bottom=0xE258; settings=0xE8B8; close=0xE5CD;
                 dotFull=0xE061; dotEmpty=0xE836;
                 play=0xE037; pause=0xE034; skip=0xE044; replay=0xE042;
                 collapse=0xE5CE; expand=0xE5CF }   # expand_less / expand_more (chevrons)
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

# Preferences (position + opacity + size) are re-read on every refresh so changes
# from the tray menu apply live without reopening the view.
$script:position   = 'top'
$script:customLeft = $null       # custom horizontal left (px); $null = centered
$script:customTop  = $null       # custom top (px); used only when position = free
$script:opacity  = 0.92          # default: light transparency (Light)
$script:widthPct = 48            # default size = Normal (% of screen width)
function Read-Prefs {
  $script:position = 'top'
  try { if (Test-Path $posFile) { $p = (Get-Content $posFile -Raw -ErrorAction Stop).Trim().ToLower(); if ($p -in @('top','bottom','free')) { $script:position = $p } } } catch {}
  $script:customLeft = $null
  try { if (Test-Path $posXFile) { $script:customLeft = [int]((Get-Content $posXFile -Raw -ErrorAction Stop).Trim()) } } catch {}
  $script:customTop = $null
  try { if (Test-Path $posYFile) { $script:customTop = [int]((Get-Content $posYFile -Raw -ErrorAction Stop).Trim()) } } catch {}
  $script:opacity = 0.92         # default: light transparency (Light)
  try { if (Test-Path $opacityFile) { $v = [int]((Get-Content $opacityFile -Raw -ErrorAction Stop).Trim()); if ($v -ge 20 -and $v -le 100) { $script:opacity = $v / 100.0 } } } catch {}
  $script:widthPct = 48          # default size = Normal
  try { if (Test-Path $sizeFile) { $w = [int]((Get-Content $sizeFile -Raw -ErrorAction Stop).Trim()); if ($w -ge 30 -and $w -le 95) { $script:widthPct = $w } } } catch {}
}

# A dragged spot (including another monitor) is remembered only while this view
# stays open. On a fresh launch we come back to the primary screen: drop the custom
# placement and clear its files. The top/bottom anchor is a real preference and is
# kept (a leftover 'free' state collapses back to the default 'top').
function Reset-LaunchPosition {
  if ($script:position -eq 'free') {
    $script:position = 'top'
    try { Set-Content -LiteralPath $posFile -Value 'top' -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
  }
  $script:customLeft = $null
  $script:customTop  = $null
  try { Remove-Item -LiteralPath $posXFile -Force -ErrorAction SilentlyContinue } catch {}
  try { Remove-Item -LiteralPath $posYFile -Force -ErrorAction SilentlyContinue } catch {}
}
Read-Prefs
Reset-LaunchPosition   # fresh launch always starts on the primary screen

# --- Sizing relative to the primary screen (looks right at any resolution) ---
# The Size preference scales the WHOLE view homothetically: not just the window
# width, but fonts, badges, paddings, row + header heights — everything grows or
# shrinks together. The scale factor is $widthPct / 55 (55 is the 1.0 reference);
# the presets sit below it for a compact feel: Compact 36% -> 0.65x, Normal 48% ->
# 0.87x, Large 60% -> 1.09x.
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formH  = [int]($screen.Height * 0.70)

# Recompute every size-dependent dimension from the current $widthPct. Called at
# startup and again whenever the Size preference changes live (see Refresh-List).
function Compute-Dims {
  $script:scale     = $script:widthPct / 55.0                                   # 55 = 1.0 reference
  $script:formW     = [int]($screen.Width * $script:widthPct / 100)
  $script:titlePt   = [single]([math]::Max(20, $screen.Height / 60) * $script:scale)
  $script:rowPt     = [single]([math]::Max(15, $screen.Height / 85) * $script:scale)
  $script:posPt     = [single]($script:titlePt * 0.6)
  $script:headerH   = [int]($script:titlePt * 2.6)
  $script:rowH      = [int]($script:rowPt * 3.4)
  $script:rowMargin = [int][math]::Max(4, 10 * $script:scale)
  $script:badgeSize = [int]($script:rowPt * 2.0)
  $script:statPx    = [single]([math]::Max(11, $script:rowPt * 1.25))           # status-dot glyph size (px)
  $script:statBox   = [int][math]::Ceiling($script:statPx * 1.5)                # bitmap box (matches New-MatIcon)
  $script:listPadX  = [int][math]::Max(8, 16 * $script:scale)
  $script:listPadY  = [int][math]::Max(6, 12 * $script:scale)
  $script:listPadV  = $script:listPadY * 2
}
Compute-Dims
$script:appliedWidthPct = $script:widthPct   # tracks the size currently rendered

# The monitor the deck currently lives on. When the user has dragged a custom
# horizontal spot we resolve the screen under that point (so the deck can live on
# ANY monitor, and top/bottom anchor to THAT monitor); otherwise we default to the
# primary screen. $screen (primary) is still used as the sizing reference.
function Get-ActiveScreen {
  try {
    if ($null -ne $script:customLeft) {
      $cx = [int]$script:customLeft + [int]($script:formW / 2)
      $cy = if ($null -ne $script:customTop) { [int]$script:customTop } else { [int]$screen.Y }
      return [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx, $cy))).WorkingArea
    }
  } catch {}
  return $screen
}

# Vertical placement for a window of height $h, per the chosen position, on the
# deck's current monitor. In 'free' mode (the user dragged the deck) we honour the
# saved custom top, clamped to the whole virtual desktop so it can sit on another
# monitor yet never end up fully off-screen.
function Get-FormTop($h) {
  $sc = Get-ActiveScreen
  $margin = [int][math]::Max(24, $sc.Height * 0.04)
  switch ($script:position) {
    'top'    { return [int]($sc.Y + $margin) }
    'bottom' { return [int]($sc.Y + $sc.Height - $h - $margin) }
    'free'   {
      $t  = if ($null -ne $script:customTop) { $script:customTop } else { [int]($sc.Y + ($sc.Height - $h) / 2) }
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      return [int][math]::Max($vs.Y, [math]::Min($t, $vs.Y + $vs.Height - $h))
    }
    default  { return [int]($sc.Y + ($sc.Height - $h) / 2) }
  }
}

# Horizontal placement for a window of width $w: the saved custom left when the
# user has dragged one (clamped to the whole virtual desktop, so another monitor
# is allowed), otherwise centered on the current monitor. Kept independently of the
# vertical position, so snapping top/bottom preserves a custom horizontal spot.
function Get-FormLeft($w) {
  if ($null -ne $script:customLeft) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    return [int][math]::Max($vs.X, [math]::Min($script:customLeft, $vs.X + $vs.Width - $w))
  }
  $sc = Get-ActiveScreen
  return [int]($sc.X + ($sc.Width - $w) / 2)
}

$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rowBg  = [System.Drawing.Color]::FromArgb(36, 36, 42)
$hover  = [System.Drawing.Color]::FromArgb(52, 52, 62)
$green  = [System.Drawing.Color]::FromArgb(80, 220, 130)
$orange = [System.Drawing.Color]::FromArgb(245, 175, 70)   # "waiting for you"
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)
$unseen = [System.Drawing.Color]::FromArgb(150, 175, 220)   # border: finished & not yet opened

# Header chrome colours. The deck normally wears a near-black header; collapsed it
# turns into a warm orange strip with dark text/icons (so it reads as "tucked away
# but here"). $script:hdrFg / $script:hdrTitle are the LIVE resting colours the
# header's hover handlers fall back to, swapped by Set-Collapsed.
$script:headerBg    = [System.Drawing.Color]::FromArgb(18, 18, 22)
$script:collapsedBg = [System.Drawing.Color]::FromArgb(232, 145, 40)   # orange strip
$hdrDark            = [System.Drawing.Color]::FromArgb(40, 24, 4)       # icons on orange
$hdrDarkTitle       = [System.Drawing.Color]::FromArgb(28, 16, 2)       # title on orange
$script:hdrFg       = $grey    # resting icon colour (grey expanded, dark collapsed)
$script:hdrTitle    = $white   # title colour       (white expanded, dark collapsed)

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
# Dismiss a session from the list by stamping its CURRENT 'updated' value into a
# 'dismissed' field. The list hides the row while dismissed == updated; any new
# activity (prompt/stop/notify) rewrites 'updated' to a fresh timestamp, so the
# two no longer match and the row reappears on its own. No tracker change needed.
function Set-Dismissed($sid) {
  try {
    $f = Join-Path $stateDir ($sid + '.json')
    if (Test-Path $f) {
      $o = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
      $stamp = [string]$o.updated
      if ($o.PSObject.Properties.Name -contains 'dismissed') { $o.dismissed = $stamp } else { $o | Add-Member -NotePropertyName dismissed -NotePropertyValue $stamp }
      [System.IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}

$form = New-Object NoActivateForm
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'   # pin to the PRIMARY screen (with the taskbar), not the 2nd monitor
$form.Size            = New-Object System.Drawing.Size($formW, $formH)
$formLeft = Get-FormLeft $formW
$form.Location        = New-Object System.Drawing.Point($formLeft, (Get-FormTop $formH))
$form.BackColor       = $bg
$form.Opacity         = $script:opacity
$form.TopMost         = $true
$form.ShowInTaskbar   = $true
$form.Text            = $WindowTitle
$form.KeyPreview      = $true
# Taskbar / Alt-Tab icon: the bundled logo.ico (next to this script, in the repo
# and once deployed to ~/.claude/sessions). Silently skipped if missing.
$iconPath = Join-Path $PSScriptRoot 'logo.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }

# Reduce flicker: enable double buffering (protected property, set via reflection).
$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
$dbProp.SetValue($form, $true, $null)

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = $headerH
$header.BackColor = $script:headerBg
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Claude Code Sessions'
$title.ForeColor = $white
$title.Font = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, [int](($headerH - $title.PreferredHeight) / 2))
$header.Controls.Add($title)

# Close button (X) — top-right corner — Material "close" glyph
$close = New-Object System.Windows.Forms.Label
Set-IconLabel $close $script:MAT.close 0x2715 ([single]($titlePt * 0.92))
$close.ForeColor = $grey
$close.AutoSize = $true
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.Add_MouseEnter({ $close.ForeColor = [System.Drawing.Color]::FromArgb(240, 90, 90) })
$close.Add_MouseLeave({ $close.ForeColor = $script:hdrFg })
$close.Add_Click({ $form.Close() })
$header.Controls.Add($close)

# --- Position buttons (▲ top, ▬ middle, ▼ bottom) — to the left of X ---
$posTip = New-Object System.Windows.Forms.ToolTip
function New-PosButton($matCode, $fallback, $tip) {
  $b = New-Object System.Windows.Forms.Label
  Set-IconLabel $b $matCode $fallback ([single]($posPt * 1.15))
  $b.ForeColor = $grey
  $b.AutoSize = $true
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $posTip.SetToolTip($b, $tip)
  $header.Controls.Add($b)
  return $b
}
$script:posTop = New-PosButton $script:MAT.top    0x25B2 'Position: top'
$script:posBot = New-PosButton $script:MAT.bottom 0x25BC 'Position: bottom'

# --- Settings gear (⚙) — opens the full menu, mirroring the tray. So every
# option is reachable straight from the on-screen deck, not just the taskbar.
$script:gear = New-Object System.Windows.Forms.Label
Set-IconLabel $script:gear $script:MAT.settings 0x2699 ([single]($posPt * 1.15))
$script:gear.ForeColor = $grey
$script:gear.AutoSize = $true
$script:gear.Cursor = [System.Windows.Forms.Cursors]::Hand
$posTip.SetToolTip($script:gear, 'Settings')
$script:gear.Add_MouseEnter({ $script:gear.ForeColor = [System.Drawing.Color]::FromArgb(120, 175, 240) })
$script:gear.Add_MouseLeave({ $script:gear.ForeColor = $script:hdrFg })
$header.Controls.Add($script:gear)

# --- Collapse toggle — shrinks the deck to just the "Claude Code Sessions" strip,
# so it can be tucked away in one click yet stay one click from coming back. The
# session list is hidden and the window height drops to the header; clicking again
# restores the auto-fit height. State is intentionally per-session (not persisted):
# a fresh popup on task completion always opens expanded.
$script:collapseBtn = New-Object System.Windows.Forms.Label
Set-IconLabel $script:collapseBtn $script:MAT.collapse 0x2303 ([single]($posPt * 1.15))
$script:collapseBtn.ForeColor = $grey
$script:collapseBtn.AutoSize = $true
$script:collapseBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$posTip.SetToolTip($script:collapseBtn, 'Collapse to a single line')
$script:collapseBtn.Add_MouseEnter({ $script:collapseBtn.ForeColor = [System.Drawing.Color]::FromArgb(120, 175, 240) })
$script:collapseBtn.Add_MouseLeave({ $script:collapseBtn.ForeColor = $script:hdrFg })
$header.Controls.Add($script:collapseBtn)

# --- Pomodoro cluster (top row) --------------------------------------------
# All Pomodoro UI lives here in the deck header. The tray runs the clock + the
# focus tracking and publishes pomodoro.json; we render it and send control
# tokens (toggle/skip/reset) via pomodoro-cmd.txt. Layout (left -> right):
#   [play/pause]  MM:SS  <phase + status>  [skip] [replay]   ...then ▲ ▼ ⚙ ✕
$blue = [System.Drawing.Color]::FromArgb(120, 175, 240)   # break accent (none defined yet in this view)

function Send-PomoCmd([string]$cmd) {
  try { Set-Content -LiteralPath $pomoCmd -Value $cmd -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
}

# A clickable Material icon label for a Pomodoro control.
function New-PomoIcon($matCode, $fallback, $tip) {
  $b = New-Object System.Windows.Forms.Label
  Set-IconLabel $b $matCode $fallback ([single]($script:posPt * 1.1))
  $b.ForeColor = $grey
  $b.AutoSize = $true
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $posTip.SetToolTip($b, $tip)
  # Literal colours here: $white/$grey aren't in this function's local scope, so
  # GetNewClosure would capture them as null (matches the posTop/gear handlers).
  $b.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 240) })
  $b.Add_MouseLeave({ $this.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 158) })
  $header.Controls.Add($b)
  return $b
}
$script:pomoToggle = New-PomoIcon $script:MAT.play  0x25B6 'Start / pause the Pomodoro'
$script:pomoSkip   = New-PomoIcon $script:MAT.skip  0x23ED 'Skip to the next phase'
$script:pomoReset  = New-PomoIcon $script:MAT.replay 0x21BA 'Reset the current timer'

$script:pomoTime = New-Object System.Windows.Forms.Label
$script:pomoTime.ForeColor = $white
$script:pomoTime.Font = New-Object System.Drawing.Font('Segoe UI', [single]($posPt * 1.05), [System.Drawing.FontStyle]::Bold)
$script:pomoTime.AutoSize = $true
$script:pomoTime.Text = '25:00'
$header.Controls.Add($script:pomoTime)

$script:pomoStatus = New-Object System.Windows.Forms.Label
$script:pomoStatus.ForeColor = $grey
$script:pomoStatus.Font = New-Object System.Drawing.Font('Segoe UI', [single]($posPt * 0.7))
$script:pomoStatus.AutoSize = $true
$script:pomoStatus.Text = 'Focus'
$header.Controls.Add($script:pomoStatus)

$script:pomoToggle.Add_Click({ Send-PomoCmd 'toggle' })
$script:pomoSkip.Add_Click({ Send-PomoCmd 'skip' })
$script:pomoReset.Add_Click({ Send-PomoCmd 'reset' })

$script:pomoCycles = 4          # mirrors the tray's $CYCLES (long break grouping)
$script:pomo = $null

# Position the cluster left-to-right, just after the title.
function Layout-Pomo {
  if (-not $script:pomoToggle) { return }
  $cy  = { param($c) [int](($script:headerH - $c.Height) / 2) }
  $gap = [int][math]::Max(8, 12 * $script:scale)
  $x   = $title.Location.X + $title.Width + [int][math]::Max(20, 26 * $script:scale)
  foreach ($c in @($script:pomoToggle, $script:pomoTime, $script:pomoStatus, $script:pomoSkip, $script:pomoReset)) {
    $c.Location = New-Object System.Drawing.Point($x, (& $cy $c))
    $x += $c.Width + $gap
  }
}

function Read-PomoState {
  $script:pomo = $null
  try { if (Test-Path $pomoState) { $script:pomo = [System.IO.File]::ReadAllText($pomoState) | ConvertFrom-Json } } catch {}
}

function Render-Pomo {
  $o = $script:pomo
  $running = $false; $remaining = ($script:pomoCycles * 0) + 1500; $track = 'paused'; $status = 'Ready'; $completed = 0
  if ($o) {
    $running   = [bool]$o.running
    $remaining = [int]$o.remaining
    $track     = [string]$o.track
    $status    = [string]$o.status
    $completed = [int]$o.completed
  }
  $mm = [int][math]::Floor($remaining / 60); $ss = [int]($remaining % 60)
  $script:pomoTime.Text = ('{0:00}:{1:00}' -f $mm, $ss)
  $script:pomoTime.ForeColor = if ($running) { $white } else { $grey }

  # Play when paused, pause when running.
  if ($running) { $script:pomoToggle.Text = Get-IconChar $script:MAT.pause 0x23F8 }
  else          { $script:pomoToggle.Text = Get-IconChar $script:MAT.play  0x25B6 }

  # Cycle dots toward the long break.
  $done = $completed % $script:pomoCycles
  $dots = ''
  for ($i = 0; $i -lt $script:pomoCycles; $i++) { $dots += if ($i -lt $done) { [char]0x25CF } else { [char]0x25CB } }
  if (-not $status) { $status = 'Ready' }
  if ($status.Length -gt 26) { $status = $status.Substring(0, 26) + [char]0x2026 }
  $script:pomoStatus.Text = ('{0}   {1}' -f $status, $dots)
  $script:pomoStatus.ForeColor = switch ($track) { 'work' { $green } 'distract' { $orange } 'break' { $blue } default { $grey } }

  Layout-Pomo

  # While collapsed, the Pomodoro cluster can appear/disappear on its own (the tray
  # owns the clock), so keep its visibility and the strip width in sync with it.
  if ($script:collapsed) {
    Apply-PomoVisibility
    $active = Test-PomoActive
    if ($active -ne $script:collapsedActivePomo) {
      $script:collapsedActivePomo = $active
      $form.Width = Get-CollapsedWidth
      if (-not $script:dragging) { $form.Left = Get-FormLeft $form.Width }
      Layout-Header
    }
  }
}

# Blink the status when off track (pulse, never spin - a ClaudeDeck convention).
$script:pomoPulseOn = $false
$pomoPulse = New-Object System.Windows.Forms.Timer
$pomoPulse.Interval = 550
$pomoPulse.Add_Tick({
  if ($script:pomo -and [bool]$script:pomo.running -and ([string]$script:pomo.track -eq 'distract')) {
    $script:pomoPulseOn = -not $script:pomoPulseOn
    $script:pomoStatus.ForeColor = if ($script:pomoPulseOn) { $orange } else { $white }
  }
})
$pomoPulse.Start()

# The settings menu (rebuilt on every open so checkmarks reflect current state).
$script:settingsMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:menuOpen = $false
$script:settingsMenu.Add_Opening({ $script:menuOpen = $true })   # suppress click-outside-close while open
$script:settingsMenu.Add_Closed({ $script:menuOpen = $false; $script:shownAt = [Environment]::TickCount })

function Build-SettingsMenu {
  $m = $script:settingsMenu
  $m.Items.Clear()

  # Prominent "install update" entry, shown only when a newer version was found.
  $upd = Get-UpdateInfo
  if ($upd) {
    $ui = New-Object System.Windows.Forms.ToolStripMenuItem(("Install update (v{0})" -f $upd.latest))
    $ui.ForeColor = [System.Drawing.Color]::FromArgb(80, 160, 90)
    $ui.ToolTipText = "Downloads and runs the latest ClaudeDeck-Setup.cmd from GitHub"
    $ui.Add_Click({ Invoke-Updater '-Apply' })
    [void]$m.Items.Add($ui)
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  }

  $dnd = New-Object System.Windows.Forms.ToolStripMenuItem('Do not disturb')
  $dnd.Checked = (Test-Path $dndFlag)
  $dnd.ToolTipText = "Suspends the auto-popup of the large view on task completion"
  $dnd.Add_Click({ Toggle-Flag $dndFlag })
  [void]$m.Items.Add($dnd)

  $co = New-Object System.Windows.Forms.ToolStripMenuItem('Close on outside click')
  $co.Checked = (Test-Path $closeFlag)
  $co.ToolTipText = "Close this view when clicking outside it (off by default)"
  $co.Add_Click({ Toggle-Flag $closeFlag })
  [void]$m.Items.Add($co)

  $fn = New-Object System.Windows.Forms.ToolStripMenuItem('Focus nudge')
  $fn.Checked = (Test-Path $focusFlag)
  $fn.ToolTipText = "When no session is running and you drift to a distracting app, Claude nudges you back with a sound + popup (off by default)"
  $fn.Add_Click({ Toggle-Flag $focusFlag })
  [void]$m.Items.Add($fn)

  # Transparency submenu — writes opacity % (re-read live on the next refresh).
  $curOp = [int]([math]::Round($script:opacity * 100))
  $opMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Transparency')
  $opMenu.ToolTipText = "Make this view more or less transparent"
  foreach ($lvl in @(
      @{ v = 100; l = 'None (opaque)' },
      @{ v = 92;  l = 'Light' },
      @{ v = 80;  l = 'Medium' },
      @{ v = 65;  l = 'Strong' })) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($lvl.l)
    $mi.Checked = ($curOp -eq $lvl.v)
    $val = $lvl.v
    $mi.Add_Click({ Set-Content -LiteralPath $opacityFile -Value $val -Encoding ASCII -ErrorAction SilentlyContinue }.GetNewClosure())
    [void]$opMenu.DropDownItems.Add($mi)
  }
  [void]$m.Items.Add($opMenu)

  # Size submenu — writes a size value (the view rescales the WHOLE layout live).
  $curSize = $script:widthPct
  $szMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Size')
  $szMenu.ToolTipText = "Overall size of this view (scales everything together)"
  foreach ($sz in @(
      @{ v = 36; l = 'Compact' },
      @{ v = 48; l = 'Normal' },
      @{ v = 60; l = 'Large' })) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($sz.l)
    $mi.Checked = ($curSize -eq $sz.v)
    $val = $sz.v
    $mi.Add_Click({ Set-Content -LiteralPath $sizeFile -Value $val -Encoding ASCII -ErrorAction SilentlyContinue }.GetNewClosure())
    [void]$szMenu.DropDownItems.Add($mi)
  }
  [void]$m.Items.Add($szMenu)

  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Favorite workspaces - a fully manual pair. "Save" snapshots the VS Code /
  # Cursor windows open right now into workspaces.json; "Reopen" relaunches them
  # all in one click (survives a Windows restart). Closing/opening windows in
  # between changes nothing until you click Save again.
  $wsN = Get-FavCount

  $wsSave = New-Object System.Windows.Forms.ToolStripMenuItem('Save open workspaces as favorites')
  $wsSave.ToolTipText = "Remember the VS Code / Cursor windows open right now (overwrites the previous set)"
  $wsSave.Add_Click({ Invoke-Workspaces '-Save' })
  [void]$m.Items.Add($wsSave)

  $wsReTxt = if ($wsN -gt 0) { "Reopen favorite workspaces ($wsN)" } else { 'Reopen favorite workspaces' }
  $wsRe = New-Object System.Windows.Forms.ToolStripMenuItem($wsReTxt)
  $wsRe.ToolTipText = "Relaunch the workspaces saved as favorites"
  $wsRe.Enabled = ($wsN -gt 0)
  $wsRe.Add_Click({ Invoke-Workspaces '-Restore' })
  [void]$m.Items.Add($wsRe)

  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Auto-update toggle (opt-in / off by default) + manual check.
  $au = New-Object System.Windows.Forms.ToolStripMenuItem('Automatic updates')
  $au.Checked = (Test-Path $autoUpdFlag)
  $au.ToolTipText = "Periodically checks the GitHub repo and offers to install new versions"
  $au.Add_Click({
    if (Test-Path $autoUpdFlag) { Remove-Item $autoUpdFlag -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $autoUpdFlag -Value '' -Encoding ASCII; Invoke-Updater '-Check' }
  })
  [void]$m.Items.Add($au)

  $chk = New-Object System.Windows.Forms.ToolStripMenuItem('Check for updates')
  $chk.ToolTipText = "Check GitHub for a new version now"
  $chk.Add_Click({ Invoke-Updater '-Check' })
  [void]$m.Items.Add($chk)

  $ver = Get-LocalVersion
  if ($ver) {
    $vi = New-Object System.Windows.Forms.ToolStripMenuItem("ClaudeDeck v$ver")
    $vi.Enabled = $false
    [void]$m.Items.Add($vi)
  }

  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  $stats = New-Object System.Windows.Forms.ToolStripMenuItem('Show statistics')
  $stats.ToolTipText = "Open the statistics dashboard (activity, focus time, top projects)"
  $stats.Add_Click({ Start-Process wscript.exe -ArgumentList ('"{0}"' -f $statsVbs) -ErrorAction SilentlyContinue })
  [void]$m.Items.Add($stats)

  $hide = New-Object System.Windows.Forms.ToolStripMenuItem('Hide this view')
  $hide.ToolTipText = "Close the view (the tray keeps running; reopen with Win+Alt+C)"
  $hide.Add_Click({ $form.Close() })
  [void]$m.Items.Add($hide)

  $quit = New-Object System.Windows.Forms.ToolStripMenuItem('Quit ClaudeDeck')
  $quit.ToolTipText = "Close the view AND stop the tray (quits ClaudeDeck entirely)"
  $quit.Add_Click({
    # Stop the tray process, then close this view.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*session-tray.ps1*' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $form.Close()
  })
  [void]$m.Items.Add($quit)
}

$script:gear.Add_Click({
  Build-SettingsMenu
  $script:settingsMenu.Show($script:gear, (New-Object System.Drawing.Point(0, $script:gear.Height)))
})

# Collapse / expand the deck to its header strip. When collapsed the deck becomes a
# thin ORANGE bar: the width shrinks to just fit the title + header buttons, the
# list is hidden, the Pomodoro cluster is hidden unless a timer is actually running,
# and the window is pinned to the header height. Refresh-List skips its auto-fit
# while collapsed so a background refresh can't grow it back. Expanding restores
# everything (full width, dark header, list, fit-to-rows height).
$script:collapsed = $false
$script:collapsedActivePomo = $false

# True while a Pomodoro timer is actually running — the only state worth keeping
# on-screen when collapsed.
function Test-PomoActive { return ($script:pomo -and [bool]$script:pomo.running) }

# Show the Pomodoro cluster always when expanded; collapsed only when a timer runs.
function Apply-PomoVisibility {
  $show = (-not $script:collapsed) -or (Test-PomoActive)
  foreach ($c in @($script:pomoToggle, $script:pomoTime, $script:pomoStatus, $script:pomoSkip, $script:pomoReset)) {
    if ($c.Visible -ne $show) { $c.Visible = $show }
  }
}

# Minimal width that still fits the title, the right-hand button cluster, and the
# Pomodoro cluster when it's on screen. Mirrors the gaps used by Layout-Header /
# Layout-Pomo so the title and buttons just clear each other.
function Get-CollapsedWidth {
  $rightSpan = 20 + $close.Width + 18 + $script:gear.Width + 18 + $script:posBot.Width +
               10 + $script:posTop.Width + 18 + $script:collapseBtn.Width + 24 + $hint.Width
  $w = 24 + $title.Width + 30 + $rightSpan
  if (Test-PomoActive) {
    $gap  = [int][math]::Max(8, 12 * $script:scale)
    $lead = [int][math]::Max(20, 26 * $script:scale)
    $pw   = $lead
    foreach ($c in @($script:pomoToggle, $script:pomoTime, $script:pomoStatus, $script:pomoSkip, $script:pomoReset)) { $pw += $c.Width + $gap }
    $w += $pw
  }
  return [int]$w
}

function Set-Collapsed([bool]$c) {
  $script:collapsed = $c
  $list.Visible = -not $c
  # (if ...) can't be used as a command argument on PS 5.1 — compute first.
  $icoCode = if ($c) { $script:MAT.expand } else { $script:MAT.collapse }
  $icoFb   = if ($c) { 0x2304 } else { 0x2303 }
  $icoTip  = if ($c) { 'Expand the deck' } else { 'Collapse to a single line' }
  Set-IconLabel $script:collapseBtn $icoCode $icoFb ([single]($script:posPt * 1.15))
  $posTip.SetToolTip($script:collapseBtn, $icoTip)

  # Header chrome: orange strip + dark text collapsed, dark header + light text
  # expanded. Re-apply the resting colours so the hover handlers and the position
  # highlight fall back to the right palette.
  if ($c) {
    $header.BackColor = $script:collapsedBg
    $script:hdrFg     = $hdrDark
    $script:hdrTitle  = $hdrDarkTitle
  } else {
    $header.BackColor = $script:headerBg
    $script:hdrFg     = $grey
    $script:hdrTitle  = $white
  }
  $title.ForeColor              = $script:hdrTitle
  $close.ForeColor              = $script:hdrFg
  $script:gear.ForeColor        = $script:hdrFg
  $script:collapseBtn.ForeColor = $script:hdrFg
  Update-PosHighlight

  Apply-PomoVisibility
  $script:collapsedActivePomo = Test-PomoActive

  if ($c) {
    $form.Height = $script:headerH
    $form.Width  = Get-CollapsedWidth
    if (-not $script:dragging) {
      $form.Left = Get-FormLeft $form.Width
      $form.Top  = Get-FormTop $form.Height
    }
    Layout-Header
  } else {
    $form.Width = $script:formW
    if (-not $script:dragging) { $form.Left = Get-FormLeft $script:formW }
    Layout-Header
    $script:lastSig = $null   # force a rebuild + auto-fit on the next refresh
    Refresh-List
  }
}
$script:collapseBtn.Add_Click({ Set-Collapsed (-not $script:collapsed) })

# Highlight the active position; the others stay dim.
function Update-PosHighlight {
  $act = $script:hdrTitle   # white when expanded, dark when collapsed (on orange)
  $idl = $script:hdrFg
  $script:posTop.ForeColor = if ($script:position -eq 'top')    { $act } else { $idl }
  $script:posBot.ForeColor = if ($script:position -eq 'bottom') { $act } else { $idl }
}
function Set-Position($pos) {
  try { Set-Content -LiteralPath $posFile -Value $pos -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
  $script:position = $pos
  $form.Top = Get-FormTop $form.Height
  Update-PosHighlight
}
$script:posTop.Add_Click({ Set-Position 'top' })
$script:posBot.Add_Click({ Set-Position 'bottom' })
foreach ($pb in @($script:posTop, $script:posBot)) {
  $pb.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(120, 175, 240) }.GetNewClosure())
  $pb.Add_MouseLeave({ Update-PosHighlight }.GetNewClosure())
}
Update-PosHighlight

# --- Drag the deck anywhere on screen --------------------------------------
# Click-and-drag on empty header space (or the title) moves the whole window.
# On release we persist the new spot: posx.txt always (the custom horizontal,
# kept even when you later snap top/bottom) and posy.txt + position='free' for
# the vertical (overridden the moment you click the top/bottom buttons). The
# refresh timer skips repositioning while a drag is in progress (see Refresh-List).
$script:dragging   = $false
$script:dragOrigin = $null    # cursor screen position when the drag began
$script:dragStart  = $null    # window location when the drag began
$header.Cursor = [System.Windows.Forms.Cursors]::SizeAll
function Save-CustomPosition {
  $script:customLeft = $form.Left
  $script:customTop  = $form.Top
  $script:position   = 'free'
  try {
    Set-Content -LiteralPath $posXFile -Value $form.Left -Encoding ASCII -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $posYFile -Value $form.Top  -Encoding ASCII -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $posFile  -Value 'free'     -Encoding ASCII -ErrorAction SilentlyContinue
  } catch {}
  Update-PosHighlight
}
function Start-Drag {
  $script:dragging   = $true
  $script:dragOrigin = [System.Windows.Forms.Cursor]::Position
  $script:dragStart  = $form.Location
}
function Do-Drag {
  if (-not $script:dragging) { return }
  $cur = [System.Windows.Forms.Cursor]::Position
  $nx  = $script:dragStart.X + ($cur.X - $script:dragOrigin.X)
  $ny  = $script:dragStart.Y + ($cur.Y - $script:dragOrigin.Y)
  $form.Location = New-Object System.Drawing.Point([int]$nx, [int]$ny)
}
function End-Drag {
  if (-not $script:dragging) { return }
  $script:dragging = $false
  # Only persist if it actually moved — a bare click shouldn't switch to 'free'.
  $moved = ([math]::Abs($form.Left - $script:dragStart.X) -gt 3) -or ([math]::Abs($form.Top - $script:dragStart.Y) -gt 3)
  if ($moved) { Save-CustomPosition }
}
foreach ($dragSurface in @($header, $title)) {
  $dragSurface.Add_MouseDown({ param($snd, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-Drag } })
  $dragSurface.Add_MouseMove({ param($snd, $e) Do-Drag })
  $dragSurface.Add_MouseUp({   param($snd, $e) End-Drag })
}

$hint = New-Object System.Windows.Forms.Label
$hint.Text = ''
$hint.ForeColor = $grey
$hint.Font = New-Object System.Drawing.Font('Segoe UI', [single]($rowPt * 0.7))
$hint.AutoSize = $true
$header.Controls.Add($hint)

# Keep X, the gear, the collapse toggle, the position buttons and the hint pinned
# to the right edge.  Layout from the right:  [hint]  ⊟   ▲ ▼   ⚙   ✕
function Layout-Header {
  $cy = { param($c) [int](($script:headerH - $c.Height) / 2) }
  $x  = $header.Width - 20
  $x -= $close.Width;                       $close.Location             = New-Object System.Drawing.Point($x, (& $cy $close))
  $x -= ($script:gear.Width + 18);          $script:gear.Location       = New-Object System.Drawing.Point($x, (& $cy $script:gear))
  $x -= ($script:posBot.Width + 18);        $script:posBot.Location     = New-Object System.Drawing.Point($x, (& $cy $script:posBot))
  $x -= ($script:posTop.Width + 10);        $script:posTop.Location     = New-Object System.Drawing.Point($x, (& $cy $script:posTop))
  $x -= ($script:collapseBtn.Width + 18);   $script:collapseBtn.Location = New-Object System.Drawing.Point($x, (& $cy $script:collapseBtn))
  $x -= ($hint.Width + 24);                 $hint.Location              = New-Object System.Drawing.Point($x, (& $cy $hint))
  Layout-Pomo
}
$header.Add_Resize({ Layout-Header })

# Re-apply the current scale to every header control (fonts + heights). Called
# when the Size preference changes live so text grows/shrinks with the window.
function Restyle {
  $header.Height  = $script:headerH
  $title.Font     = New-Object System.Drawing.Font('Segoe UI', $script:titlePt, [System.Drawing.FontStyle]::Bold)
  $title.Location = New-Object System.Drawing.Point(24, [int](($script:headerH - $title.PreferredHeight) / 2))
  $close.Font     = New-IconFont ([single]($script:titlePt * 0.92))
  foreach ($pb in @($script:posTop, $script:posBot)) {
    $pb.Font = New-IconFont ([single]($script:posPt * 1.15))
  }
  $script:gear.Font = New-IconFont ([single]($script:posPt * 1.15))
  $script:collapseBtn.Font = New-IconFont ([single]($script:posPt * 1.15))
  $cCode = if ($script:collapsed) { $script:MAT.expand } else { $script:MAT.collapse }
  $cFb   = if ($script:collapsed) { 0x2304 } else { 0x2303 }
  $script:collapseBtn.Text = Get-IconChar $cCode $cFb
  foreach ($c in @($script:pomoToggle, $script:pomoSkip, $script:pomoReset)) { $c.Font = New-IconFont ([single]($script:posPt * 1.1)) }
  $script:pomoToggle.Text = Get-IconChar $script:MAT.play  0x25B6   # re-set so the glyph survives the re-font
  $script:pomoSkip.Text   = Get-IconChar $script:MAT.skip  0x23ED
  $script:pomoReset.Text  = Get-IconChar $script:MAT.replay 0x21BA
  $script:pomoTime.Font   = New-Object System.Drawing.Font('Segoe UI', [single]($script:posPt * 1.05), [System.Drawing.FontStyle]::Bold)
  $script:pomoStatus.Font = New-Object System.Drawing.Font('Segoe UI', [single]($script:posPt * 0.7))
  $hint.Font    = New-Object System.Drawing.Font('Segoe UI', [single]($script:rowPt * 0.7))
  $list.Padding = New-Object System.Windows.Forms.Padding($script:listPadX, $script:listPadY, $script:listPadX, $script:listPadY)
  Layout-Header
}

# Scrollable list
$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Dock = 'Fill'
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $bg
$list.Padding = New-Object System.Windows.Forms.Padding($script:listPadX, $script:listPadY, $script:listPadX, $script:listPadY)
$dbProp.SetValue($list, $true, $null)   # double-buffer the list too
$form.Controls.Add($list)
$list.BringToFront()

# $rowH, $rowMargin, $badgeSize, $statPx, $statBox are computed in Compute-Dims.

# Tooltip shared by every row's ✕ (hide) button.
$script:rowTip = New-Object System.Windows.Forms.ToolTip

# Resolve a session's git remote to a browsable web URL (or $null). We read
# .git/config directly rather than spawning git.exe — no console flash, no PATH
# dependency — walking up from the session's cwd so a sub-directory still resolves,
# and following the "gitdir:" pointer when .git is a file (worktrees / submodules).
# git@host:user/repo.git and ssh://git@host/user/repo.git are normalised to https.
function Get-RepoWebUrl([string]$cwd) {
  try {
    if (-not $cwd) { return $null }
    $dir = $cwd; $gitPath = $null
    for ($i = 0; $i -lt 8 -and $dir; $i++) {
      $cand = Join-Path $dir '.git'
      if (Test-Path $cand) { $gitPath = $cand; break }
      $parent = Split-Path $dir -Parent
      if (-not $parent -or $parent -eq $dir) { break }
      $dir = $parent
    }
    if (-not $gitPath) { return $null }
    # .git is a directory in a normal clone, a file ("gitdir: <path>") in a worktree.
    if (Test-Path $gitPath -PathType Container) {
      $configPath = Join-Path $gitPath 'config'
    } else {
      $first = (Get-Content -LiteralPath $gitPath -TotalCount 1 -ErrorAction Stop)
      if ($first -notmatch '^gitdir:\s*(.+)$') { return $null }
      $gd = $Matches[1].Trim()
      if (-not [System.IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $dir $gd }
      $configPath = Join-Path $gd 'config'
      if (-not (Test-Path $configPath)) {                          # worktree: config lives in the common dir
        $commondir = Join-Path $gd 'commondir'
        if (Test-Path $commondir) {
          $cd = ((Get-Content -LiteralPath $commondir -TotalCount 1).Trim())
          if (-not [System.IO.Path]::IsPathRooted($cd)) { $cd = Join-Path $gd $cd }
          $configPath = Join-Path $cd 'config'
        }
      }
    }
    if (-not (Test-Path $configPath)) { return $null }
    $cfg = [System.IO.File]::ReadAllText($configPath)
    # Prefer origin's url; fall back to the first remote url in the file.
    $url = $null
    $m = [regex]::Match($cfg, '(?ms)^\[remote "origin"\](.*?)(?=^\[|\Z)')
    if ($m.Success) {
      $um = [regex]::Match($m.Groups[1].Value, '(?m)^\s*url\s*=\s*(.+?)\s*$')
      if ($um.Success) { $url = $um.Groups[1].Value.Trim() }
    }
    if (-not $url) {
      $um = [regex]::Match($cfg, '(?m)^\s*url\s*=\s*(.+?)\s*$')
      if ($um.Success) { $url = $um.Groups[1].Value.Trim() }
    }
    if (-not $url) { return $null }
    $web = $url
    if     ($web -match '^git@([^:]+):(.+)$')        { $web = 'https://{0}/{1}' -f $Matches[1], $Matches[2] }
    elseif ($web -match '^ssh://git@([^/]+)/(.+)$')  { $web = 'https://{0}/{1}' -f $Matches[1], $Matches[2] }
    $web = $web -replace '\.git/?$', ''
    if ($web -match '^https?://') { return $web }
    return $null
  } catch { return $null }
}

# A menu label for a known forge, or a generic one for any other https remote.
function Get-RepoMenuLabel([string]$url) {
  if ($url -match 'github\.com')    { return 'Open on GitHub' }
  if ($url -match 'gitlab\.com')    { return 'Open on GitLab' }
  if ($url -match 'bitbucket\.org') { return 'Open on Bitbucket' }
  return 'Open repository in browser'
}

# Host-aware deep links (issues / changes / CI) under a repo web URL. Empty for an
# unknown forge — the menu then shows only the repo home entry.
function Get-RepoSubLinks([string]$url) {
  if ($url -match 'github\.com') {
    return @(@{ label = 'Issues'; url = "$url/issues" },
             @{ label = 'Pull requests'; url = "$url/pulls" },
             @{ label = 'Actions'; url = "$url/actions" })
  }
  if ($url -match 'gitlab\.com') {
    return @(@{ label = 'Issues'; url = "$url/-/issues" },
             @{ label = 'Merge requests'; url = "$url/-/merge_requests" },
             @{ label = 'Pipelines'; url = "$url/-/pipelines" })
  }
  if ($url -match 'bitbucket\.org') {
    return @(@{ label = 'Issues'; url = "$url/issues" },
             @{ label = 'Pull requests'; url = "$url/pull-requests" },
             @{ label = 'Pipelines'; url = "$url/pipelines" })
  }
  return @()
}

# Open a terminal at $cwd: prefer Windows Terminal, fall back to PowerShell.
function Open-Terminal([string]$cwd) {
  if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) { return }
  try { Start-Process wt.exe -ArgumentList ('-d "{0}"' -f $cwd) -ErrorAction Stop }
  catch { Start-Process powershell.exe -WorkingDirectory $cwd -ErrorAction SilentlyContinue }
}

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
  # Status dot is a Material glyph (own font), so it lives in its own Label to the
  # left of the project badge — the row text stays in Segoe UI.
  switch ($status) {
    'running' { $fc = $green;  $statCode = $script:MAT.dotFull;  $statFb = 0x25CF }  # filled circle (blinks)
    'waiting' { $fc = $orange; $statCode = $script:MAT.dotFull;  $statFb = 0x25CF }  # filled circle
    default   { $fc = $grey;   $statCode = $script:MAT.dotEmpty; $statFb = 0x25CB }  # outlined circle
  }
  $btn.ForeColor = $fc
  $btn.Font = New-Object System.Drawing.Font('Segoe UI', $rowPt)
  $btn.TextAlign = 'MiddleLeft'
  $btn.TextImageRelation = 'ImageBeforeText'
  $btn.ImageAlign = 'MiddleLeft'
  $btn.Image = New-Badge ([string]$s.project) $badgeSize   # coloured square + initials
  $statGap = 12
  $btn.Padding = New-Object System.Windows.Forms.Padding(($script:statBox + $statGap), 0, 18, 0)  # leave room for the status dot
  $btn.Width  = $list.ClientSize.Width - ($script:listPadX * 2 + 8)
  $btn.Height = $rowH
  $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $rowMargin)
  $btn.TabStop = $false
  $sep = [char]0x2014
  $rest = ('  {0}    {1}    {2}    ({3})' -f $s.project, $sep, $promptText, $age)
  $btn.AutoEllipsis = $true                          # truncate with "…" instead of wrapping to a 2nd line
  $btn.Text = $rest

  # Status dot (Material glyph rendered to a bitmap), pinned at the left edge.
  $statLbl = New-Object System.Windows.Forms.Label
  $statLbl.AutoSize  = $false
  $statLbl.Size      = New-Object System.Drawing.Size($script:statBox, $script:statBox)
  $statLbl.BackColor = [System.Drawing.Color]::Transparent
  $statLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
  $statLbl.Image     = New-MatIcon $statCode $statFb $script:statPx $fc
  $statLbl.Location  = New-Object System.Drawing.Point(8, [int](($btn.Height - $script:statBox) / 2))
  $btn.Controls.Add($statLbl)
  $statLbl.BringToFront()
  $btn.Tag = $statLbl                                # spinner timer rotates running rows' status dot
  # Dispose every image this row owns (badge + status dot) when the row goes away.
  $btn.Add_Disposed({ param($snd, $e)
    try { if ($snd.Image) { $snd.Image.Dispose() } } catch {}
    try { foreach ($cc in $snd.Controls) { if ($cc.Image) { $cc.Image.Dispose() } } } catch {}
  })

  # Hide (✕) button — pinned to the FAR right of the row. Dismisses this session
  # from the list (Set-Dismissed); it reappears on the session's next activity.
  # It lives in its own Label so its click never triggers the row's focus action.
  $closeLbl = New-Object System.Windows.Forms.Label
  $closeLbl.UseCompatibleTextRendering = $true
  $closeLbl.Font      = New-IconFont ([single]($rowPt * 0.85))
  $closeLbl.Text      = Get-IconChar $script:MAT.close 0x2715
  $closeLbl.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
  $closeLbl.BackColor = [System.Drawing.Color]::Transparent
  $closeLbl.AutoSize  = $true
  $closeLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
  $closeLbl.Anchor    = 'Top, Right'
  $script:rowTip.SetToolTip($closeLbl, 'Hide this session (reappears on its next activity)')
  $closeRight = 14
  $closeLbl.Location = New-Object System.Drawing.Point(
    ($btn.Width - $closeLbl.PreferredWidth - $closeRight),
    [int](($btn.Height - $closeLbl.PreferredHeight) / 2))
  $btn.Controls.Add($closeLbl)
  $closeLbl.BringToFront()
  $closeLbl.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(240, 90, 90) })
  $closeLbl.Add_MouseLeave({ $this.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120) })
  $closeSlot = $closeLbl.PreferredWidth + $closeRight + 10   # room the ✕ occupies on the right

  # Context size lives in its OWN slot pinned to the right edge — never part of the
  # row text, so a long prompt can't push it onto a second line (the text ellipsizes).
  # Sits just left of the ✕ button.
  $ctxLbl = $null
  $ctxStr = Format-Ctx $s
  if ($ctxStr) {
    $ctxLbl = New-Object System.Windows.Forms.Label
    $ctxLbl.Text      = [char]0x2022 + ' ' + $ctxStr        # • 117k
    $ctxLbl.Font      = New-Object System.Drawing.Font('Segoe UI', [single]($rowPt * 0.85))
    $ctxLbl.ForeColor = $grey
    $ctxLbl.BackColor = [System.Drawing.Color]::Transparent  # let the row bg (breathe/flash) show through
    $ctxLbl.AutoSize  = $true
    $ctxLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $ctxRight = $closeSlot + 4
    $ctxLbl.Anchor   = 'Top, Right'
    $ctxLbl.Location = New-Object System.Drawing.Point(
      ($btn.Width - $ctxLbl.PreferredWidth - $ctxRight),
      [int](($btn.Height - $ctxLbl.PreferredHeight) / 2))
    $btn.Controls.Add($ctxLbl)
  }
  # Reserve room on the right for the ✕ (+ ctx slot when present), but KEEP the
  # left room for the status dot (else the project badge slides over it).
  $rightPad = if ($ctxLbl) { $ctxLbl.PreferredWidth + $ctxRight + 12 } else { $closeSlot + 12 }
  $btn.Padding = New-Object System.Windows.Forms.Padding(($script:statBox + $statGap), 0, $rightPad, 0)

  $proj = [string]$s.project
  $cwd  = [string]$s.cwd
  $sid  = [string]$s.session_id
  $clickHandler = {
    Set-Seen $sid                                          # mark this completion as opened
    if (-not [WinFocus]::FocusByTitle($proj)) {
      # Fallback: focus/open the REAL VS Code (never Cursor).
      $codeExe = (Get-Process -Name Code -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
      if ($codeExe -and $cwd) { Start-Process $codeExe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction SilentlyContinue }
    }
  }.GetNewClosure()
  $btn.Add_Click($clickHandler)
  $statLbl.Add_Click($clickHandler)                   # the status dot is part of the clickable row
  if ($ctxLbl) { $ctxLbl.Add_Click($clickHandler) }   # the ctx slot is part of the clickable row
  # ✕ dismisses the session and refreshes immediately (don't focus the IDE).
  $closeLbl.Add_Click({ Set-Dismissed $sid; $script:lastSig = $null; Refresh-List }.GetNewClosure())

  # Right-click anywhere on the row -> open the project folder / a terminal, plus
  # the repo home and its issues / PRs / CI pages when there's a git remote. All
  # resolved lazily on Opening so we don't touch the filesystem for every row on
  # every refresh; remote-only entries are hidden when there's no remote, and the
  # whole menu is suppressed when nothing applies. The three deep links are reused
  # slots (text/url set on open) so one menu serves GitHub, GitLab or Bitbucket.
  $cmRow      = New-Object System.Windows.Forms.ContextMenuStrip
  $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open folder')
  $termItem   = New-Object System.Windows.Forms.ToolStripMenuItem('Open in terminal')
  $sep1       = New-Object System.Windows.Forms.ToolStripSeparator
  $openItem   = New-Object System.Windows.Forms.ToolStripMenuItem('Open repository in browser')
  $sub1 = New-Object System.Windows.Forms.ToolStripMenuItem('')
  $sub2 = New-Object System.Windows.Forms.ToolStripMenuItem('')
  $sub3 = New-Object System.Windows.Forms.ToolStripMenuItem('')
  $subItems = @($sub1, $sub2, $sub3)
  foreach ($it in @($folderItem, $termItem, $sep1, $openItem, $sub1, $sub2, $sub3)) { [void]$cmRow.Items.Add($it) }
  $cmRow.Add_Opening({
    param($snd, $e)
    $hasFolder = ($cwd -and (Test-Path -LiteralPath $cwd))
    $folderItem.Visible = $hasFolder
    $termItem.Visible   = $hasFolder
    $u = Get-RepoWebUrl $cwd
    if ($u) { $openItem.Visible = $true; $openItem.Text = Get-RepoMenuLabel $u; $openItem.Tag = $u }
    else    { $openItem.Visible = $false }
    $subs = if ($u) { @(Get-RepoSubLinks $u) } else { @() }
    for ($k = 0; $k -lt $subItems.Count; $k++) {
      if ($k -lt $subs.Count) { $subItems[$k].Visible = $true; $subItems[$k].Text = '      ' + $subs[$k].label; $subItems[$k].Tag = $subs[$k].url }
      else { $subItems[$k].Visible = $false }
    }
    $sep1.Visible = ($hasFolder -and $u)
    if (-not $hasFolder -and -not $u) { $e.Cancel = $true }
  }.GetNewClosure())
  $folderItem.Add_Click({ if ($cwd) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction SilentlyContinue } }.GetNewClosure())
  $termItem.Add_Click({ Open-Terminal $cwd }.GetNewClosure())
  $openItem.Add_Click({ if ($openItem.Tag) { Start-Process ([string]$openItem.Tag) -ErrorAction SilentlyContinue } }.GetNewClosure())
  foreach ($si in @($sub1, $sub2, $sub3)) { $si.Add_Click({ if ($this.Tag) { Start-Process ([string]$this.Tag) -ErrorAction SilentlyContinue } }) }
  $btn.ContextMenuStrip      = $cmRow
  $statLbl.ContextMenuStrip  = $cmRow
  $closeLbl.ContextMenuStrip = $cmRow
  if ($ctxLbl) { $ctxLbl.ContextMenuStrip = $cmRow }
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

# Running rows: the green dot blinks (smooth alpha pulse) — no rotation.
$script:spinLbls = @()   # status Labels of the running rows
$spinTimer = New-Object System.Windows.Forms.Timer
$spinTimer.Interval = 60
$spinTimer.Add_Tick({
  if (@($script:spinLbls).Count -eq 0) { $spinTimer.Stop(); return }
  $k = 0.5 - 0.5 * [math]::Cos(([Environment]::TickCount / 750.0) * 2 * [math]::PI)   # 0..1
  $col = [System.Drawing.Color]::FromArgb([int](80 + 175 * $k), $green.R, $green.G, $green.B)
  foreach ($l in @($script:spinLbls)) {
    try {
      $old = $l.Image
      $l.Image = New-MatIcon $script:MAT.dotFull 0x25CF $script:statPx $col
      if ($old) { $old.Dispose() }
    } catch {}
  }
})

$script:lastSig = $null

function Refresh-List {
  # Apply live preference changes (position + opacity + size).
  Read-Prefs
  Update-PosHighlight
  if ($form.Opacity -ne $script:opacity) { $form.Opacity = $script:opacity }
  if ($script:appliedWidthPct -ne $script:widthPct) {
    $script:appliedWidthPct = $script:widthPct
    Compute-Dims                        # rescale fonts/badges/paddings + width together
    Restyle                             # re-font the header to the new scale
    # Collapsed: keep the thin strip (recomputed for the new scale); else full width.
    $newW            = if ($script:collapsed) { Get-CollapsedWidth } else { $script:formW }
    $script:formLeft = Get-FormLeft $newW
    $form.Width      = $newW
    $form.Left       = $script:formLeft
    $script:lastSig  = $null            # force a row rebuild so rows re-font + reflow
  }
  # Re-apply the preferred placement live (top/bottom snap, or the dragged custom
  # spot) — but never fight an in-progress drag.
  if (-not $script:dragging) {
    $wantLeft = Get-FormLeft $form.Width
    if ($form.Left -ne $wantLeft) { $form.Left = $wantLeft }
    $wantTop = Get-FormTop $form.Height
    if ($form.Top -ne $wantTop) { $form.Top = $wantTop }
  }

  $now = Get-Date
  $sessions = @()
  if (Test-Path $stateDir) {
    foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
      try { $s = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
      try { $upd = [datetime]$s.updated } catch { $upd = $f.LastWriteTime }
      if (($now - $upd).TotalHours -gt 24) { continue }
      # Hidden via the row's ✕ — stays out until its next activity bumps 'updated'.
      if ($s.dismissed -and ([string]$s.dismissed -eq [string]$s.updated)) { continue }
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
  $script:spinLbls = @()
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
      if ($r.status -eq 'running') { $spinning += $b.Tag }   # $b.Tag = the row's status Label
      if ($triggerSid -and ([string]$r.s.session_id -eq $triggerSid)) { $triggerBtn = $b }
    }
  }
  $list.ResumeLayout()

  # Auto-fit the window height to the number of rows (no big empty area) — skipped
  # while collapsed, where the window is intentionally pinned to the header strip.
  if (-not $script:collapsed) {
    $count   = [math]::Max(1, $rows.Count)
    $desired = $headerH + $listPadV + ($count * ($rowH + $rowMargin)) + 6
    $maxH    = [int]($screen.Height * 0.9)
    $minH    = $headerH + $listPadV + ($rowH + $rowMargin) + 6
    $newH     = [math]::Min($maxH, [math]::Max($minH, $desired))
    $wantTop  = Get-FormTop $newH
    $wantLeft = Get-FormLeft $form.Width
    if ($form.Height -ne $newH -or $form.Left -ne $wantLeft -or $form.Top -ne $wantTop) {
      $form.Height = $newH
      if (-not $script:dragging) {
        $form.Left = $wantLeft   # custom dragged spot, else horizontally centered
        $form.Top  = $wantTop    # top / center / bottom / dragged per the chosen position
      }
    }
  }

  # Drive animations: running rows spin; waiting rows breathe; a NEW completion flashes once.
  $script:waitBtns = $waiting
  $script:spinLbls = $spinning
  if ($triggerKey -and ($triggerKey -ne $script:lastAnimKey)) {
    $script:lastAnimKey = $triggerKey
    $script:flashBtn    = $triggerBtn
    $script:flashStart  = [Environment]::TickCount
    $script:shownAt     = [Environment]::TickCount   # re-arm the click-outside grace on a fresh pop
  }
  if ((@($script:waitBtns).Count -gt 0) -or $script:flashBtn) { $animTimer.Start() }
  if (@($script:spinLbls).Count -gt 0) { $spinTimer.Start() }
}

# --- Focus-nudge "Matrix" animation -------------------------------------------
# When the tray fires a focus nudge it stamps focus-nudge.txt. We run a green
# digital-rain gag in the deck's top bar (the "Claude Code Sessions" strip) with
# a one-line wink; it stays up until you CLICK it (then fades out). The taskbar
# FlashWindowEx fires regardless, and the tray pops the deck open if it was closed.
$script:fxCW       = 16     # rain cell width (px)
$script:fxCH       = 18     # rain cell height (px)
$script:fxTrailLen = 11     # glyphs per falling column
$script:fxActive   = $false
$script:fxFading   = $false # set true on click -> fade out, then stop + hide
$script:fxFrame    = 0
$script:fxAlpha    = 1.0
$script:fxHeads    = @()
$script:fxSpeed    = @()
$script:fxLine     = ''
# ASCII glyphs (ASCII only, so any monospace font renders them - no tofu boxes).
$script:fxGlyphs = ('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$+*<>=/\|?!#%&{}[]'.ToCharArray())
# One-line wink (the deck header is a thin strip, so the Claude "mascot" is a
# compact bracket-face rather than the tall ASCII bot). Drawn centered over the rain.
$script:fxLines = @(
  "[o_o]  Wake up... the code won't write itself.",
  "[o_o]  Follow the white rabbit -> your TODOs.",
  "[-_-]  There is no spoon. Only un-merged branches.",
  "[o_o]  Knock knock. Claude wants to build.",
  "[>_>]  I know kung-fu. And also your codebase.",
  "[o_o]  Come back to the Matrix. Bring coffee.")

$script:fxFont      = New-Object System.Drawing.Font('Consolas', 13)
$script:fxArtFont   = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$script:fxHeadBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(205, 255, 205))
$script:fxArtBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 255, 180))
$script:fxTrail     = New-Object 'System.Drawing.SolidBrush[]' $script:fxTrailLen
for ($t = 0; $t -lt $script:fxTrailLen; $t++) {
  $gv = [int][math]::Max(60, 255 - $t * 20)
  $script:fxTrail[$t] = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(25, $gv, 60))
}

# Full-deck overlay panel the rain is painted onto (hidden until a nudge).
$fx = New-Object System.Windows.Forms.Panel
$fx.BackColor = [System.Drawing.Color]::Black
$fx.Visible = $false
$dbProp.SetValue($fx, $true, $null)   # double-buffer (same trick as the form)
$fx.Add_Click({ $script:fxFading = $true })   # click anywhere to fade out + dismiss
$fx.Add_Paint({
  param($snd, $e)
  $g = $e.Graphics
  $g.Clear([System.Drawing.Color]::Black)
  $w = $fx.ClientSize.Width; $h = $fx.ClientSize.Height
  $cw = $script:fxCW; $ch = $script:fxCH; $tl = $script:fxTrailLen
  $gn = $script:fxGlyphs.Length
  $cols = $script:fxHeads.Length
  for ($c = 0; $c -lt $cols; $c++) {
    $x = $c * $cw
    $head = $script:fxHeads[$c]
    for ($t = 0; $t -lt $tl; $t++) {
      $y = $head - $t * $ch
      if ($y -lt (-$ch) -or $y -gt $h) { continue }
      $row = [int][math]::Floor($y / $ch)
      $idx = [math]::Abs(($c * 131 + $row * 17 + ($script:fxFrame -shr 1) * 5)) % $gn
      $brush = if ($t -eq 0) { $script:fxHeadBrush } else { $script:fxTrail[$t] }
      $g.DrawString([string]$script:fxGlyphs[$idx], $script:fxFont, $brush, [single]$x, [single]$y)
    }
  }
  # Centered one-line wink on a dark backdrop, vertically centered in the bar.
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $lineSize = $g.MeasureString($script:fxLine, $script:fxArtFont)
  $bw = [math]::Min($w, $lineSize.Width + 32)
  $bh = [math]::Min($h, $lineSize.Height + 12)
  $veil = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(175, 0, 0, 0))
  $g.FillRectangle($veil, [single](($w - $bw) / 2), [single](($h - $bh) / 2), [single]$bw, [single]$bh)
  $veil.Dispose()
  $g.DrawString($script:fxLine, $script:fxArtFont, $script:fxArtBrush, (New-Object System.Drawing.RectangleF(0, 0, $w, $h)), $sf)
  # Fade-out veil over the whole frame.
  if ($script:fxAlpha -lt 1.0) {
    $a = [int]((1.0 - $script:fxAlpha) * 255)
    $fb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, 0, 0, 0))
    $g.FillRectangle($fb, 0, 0, $w, $h); $fb.Dispose()
  }
})
$form.Controls.Add($fx)

# Seed the falling columns for the current overlay width.
function Fx-Init {
  $cols = [int][math]::Max(1, [math]::Floor($fx.ClientSize.Width / $script:fxCW))
  $script:fxHeads = New-Object 'double[]' $cols
  $script:fxSpeed = New-Object 'double[]' $cols
  for ($i = 0; $i -lt $cols; $i++) {
    $script:fxHeads[$i] = [double](-(Get-Random -Minimum 0 -Maximum ([math]::Max(1, $fx.ClientSize.Height))))
    $script:fxSpeed[$i] = [double](Get-Random -Minimum 8 -Maximum 26)
  }
}

$fxTimer = New-Object System.Windows.Forms.Timer
$fxTimer.Interval = 60
$fxTimer.Add_Tick({
  $script:fxFrame++
  $h = $fx.ClientSize.Height
  for ($i = 0; $i -lt $script:fxHeads.Length; $i++) {
    $script:fxHeads[$i] += $script:fxSpeed[$i]
    if (($script:fxHeads[$i] - $script:fxTrailLen * $script:fxCH) -gt $h) {
      $script:fxHeads[$i] = [double](-(Get-Random -Minimum 0 -Maximum 200))
      $script:fxSpeed[$i] = [double](Get-Random -Minimum 8 -Maximum 26)
    }
  }
  # Runs indefinitely until clicked; a click starts a short fade-out, then we stop.
  if ($script:fxFading) {
    $script:fxAlpha = [math]::Max(0.0, $script:fxAlpha - (1.0 / 8.0))
    if ($script:fxAlpha -le 0.0) {
      $fxTimer.Stop(); $script:fxActive = $false; $script:fxFading = $false; $fx.Visible = $false
      try { $form.Refresh() } catch {}
      return
    }
  }
  $fx.Invalidate()
})

function Flash-Deck {
  try { [WinFocus]::Flash($form.Handle, 4) } catch {}
  if ($script:fxActive) { return }
  $script:fxLine   = $script:fxLines | Get-Random
  $script:fxFrame  = 0
  $script:fxAlpha  = 1.0
  $script:fxFading = $false
  # Header strip only (the "Claude Code Sessions" bar), not the whole deck.
  $fx.Bounds = New-Object System.Drawing.Rectangle(0, 0, $form.ClientSize.Width, $header.Height)
  Fx-Init
  $fx.Visible = $true
  $fx.BringToFront()
  $script:fxActive = $true
  $fxTimer.Start()
}
# Detect a fresh nudge stamp (< 15s old) and flash once per stamp.
function Check-FocusNudge {
  if (-not (Test-Path $nudgeFile)) { return }
  $val = $null
  try { $val = ([System.IO.File]::ReadAllText($nudgeFile)).Trim() } catch {}
  if (-not $val -or $val -eq $script:lastNudgeSeen) { return }
  $script:lastNudgeSeen = $val
  $age = 999999
  try { $age = [Environment]::TickCount - [int]$val } catch {}
  if ($age -ge 0 -and $age -lt 15000) { Flash-Deck }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Refresh-List })
$timer.Start()

# Pomodoro display refresh (1s, so the clock ticks smoothly in the header). We also
# piggyback the focus-nudge poll here - same 1s cadence, no extra timer.
$pomoTimer = New-Object System.Windows.Forms.Timer
$pomoTimer.Interval = 1000
$pomoTimer.Add_Tick({ Read-PomoState; Render-Pomo; Check-FocusNudge })
$pomoTimer.Start()

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
$form.Add_Shown({ $script:shownAt = [Environment]::TickCount; Refresh-List; Read-PomoState; Render-Pomo })

$clickTimer = New-Object System.Windows.Forms.Timer
$clickTimer.Interval = 50
$clickTimer.Add_Tick({
  $down = [WinFocus]::AnyMouseDown()
  if ($down -and -not $script:prevDown -and -not $script:menuOpen -and (([Environment]::TickCount - $script:shownAt) -ge 500) -and (Test-Path $closeFlag)) {
    $b = $form.Bounds
    if ([WinFocus]::CursorOutside($b.Left, $b.Top, $b.Right, $b.Bottom)) { $form.Close() }
  }
  $script:prevDown = $down
})
$clickTimer.Start()

$form.Add_FormClosed({
  $timer.Stop(); $followTimer.Stop(); $animTimer.Stop(); $clickTimer.Stop(); $spinTimer.Stop(); $pomoTimer.Stop(); $pomoPulse.Stop(); $fxTimer.Stop()
  # Release the single-instance mutex immediately so the next finished task can
  # pop a fresh view without racing this process's shutdown.
  try { $script:viewMutex.ReleaseMutex() } catch {}
  try { $script:viewMutex.Dispose() } catch {}
  # End the message loop started by Application::Run below.
  try { [System.Windows.Forms.Application]::ExitThread() } catch {}
})

# Show WITHOUT activating (so we don't snatch focus from whatever you're typing),
# then pump messages until the form closes. ShowDialog() is intentionally avoided
# here: it always activates the dialog and would steal the keyboard focus.
$form.Show()
[System.Windows.Forms.Application]::Run()
