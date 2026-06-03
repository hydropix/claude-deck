# Claude Sessions - minimalist Windows tray launcher.
#
# The tray is intentionally tiny: its menu holds only the essentials - open the
# large view ("the desk") and quit. Everything else - the live session list AND
# every setting (Do-not-disturb, transparency, size, updates, statistics, the
# favorite-workspaces save/reopen) - lives in the desk's on-screen gear menu (see
# session-view.ps1), which is the single canonical control surface.
#
# The tray still earns its keep by: owning the global hotkey (Win+Alt+C) that opens
# the desk from anywhere, and running the background auto-update check that the desk
# then surfaces.

# Single-instance guard: if another tray process is already running, exit.
# (A named mutex proved unreliable here, so we scan for a sibling process.)
$dupes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*session-tray.ps1*' })
if ($dupes.Count -gt 0) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Shared library + the Pomodoro engine / activity classifier (dot-sourced into this
# scope). session-common provides Get-CDPath / Get-CDUtf8 and the updater bridge
# (Invoke-Updater / Get-UpdateInfo); session-pomodoro owns the whole Pomodoro clock,
# the foreground-activity classifier (Get-PomoCategory, reused by the focus nudge),
# and starts its own 1s timer. Load common first - the Pomodoro file depends on it.
. (Join-Path $PSScriptRoot 'session-common.ps1')
. (Join-Path $PSScriptRoot 'session-pomodoro.ps1')

# --- Background auto-update (off by default) -------------------------------
# When autoUpdFlag is present, the tray periodically asks session-update.ps1 to
# compare the installed version with the GitHub repo and writes update.json. The
# desk's gear menu reads that file and offers the install. The toggle itself also
# lives in the desk - the tray only runs the check.
$autoUpdFlag = Join-Path $env:USERPROFILE '.claude\sessions\autoupdate.flag'
$updInfoFile = Join-Path $env:USERPROFILE '.claude\sessions\update.json'

# Invoke-Updater (launch the check/apply) and Get-UpdateInfo (read update.json) live
# in session-common.ps1, shared with the deck.

# Check only when enabled, and at most once an hour. The throttle window (55 min)
# sits just under the hourly timer so every tick actually re-checks - a freshly
# published release is then noticed within ~1h instead of being suppressed for 12h.
function Invoke-UpdateCheckThrottled {
  if (-not (Test-Path $autoUpdFlag)) { return }
  try {
    if (Test-Path $updInfoFile) {
      $j = [System.IO.File]::ReadAllText($updInfoFile) | ConvertFrom-Json
      if ($j.checked -and ((Get-Date) - [datetime]$j.checked).TotalMinutes -lt 55) { return }
    }
  } catch {}
  Invoke-Updater '-Check'
}

# Pop a one-shot tray balloon the first time we see a given available version this
# session, so the user is told without having to open the desk's gear menu. The
# tray menu (Build-Menu) carries the actual "Install update" action.
$script:notifiedUpdVer = $null
function Show-UpdateNotice {
  $u = Get-UpdateInfo
  if (-not $u) { return }
  $ver = [string]$u.latest
  if ($ver -and $ver -ne $script:notifiedUpdVer) {
    $script:notifiedUpdVer = $ver
    try {
      $notify.BalloonTipTitle = 'ClaudeDeck update available'
      $notify.BalloonTipText  = ('Version {0} is ready. Open the deck (Win+Alt+C) or the tray menu to install.' -f $ver)
      $notify.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
      $notify.ShowBalloonTip(8000)
    } catch {}
  }
}

# App icon: prefer the bundled logo.ico (sits next to this script, both in the
# repo and once deployed to ~/.claude/sessions); fall back to a system icon.
function Get-AppIcon {
  $p = Join-Path $PSScriptRoot 'logo.ico'
  if (Test-Path $p) { try { return New-Object System.Drawing.Icon($p) } catch {} }
  return [System.Drawing.SystemIcons]::Information
}
$appIcon = Get-AppIcon

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $appIcon
$notify.Text = 'Claude Sessions'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

# The whole tray menu: open the desk, and quit (plus a prominent install entry
# when an update is waiting). Nothing else by design.
function Build-Menu {
  $menu.Items.Clear()

  # Shown only when update.json reports a newer version - mirrors the desk's gear menu.
  $upd = Get-UpdateInfo
  if ($upd) {
    $ui = $menu.Items.Add(("Install update (v{0})" -f $upd.latest))
    $ui.ForeColor = [System.Drawing.Color]::FromArgb(80, 160, 90)
    $ui.ToolTipText = "Downloads and runs the latest ClaudeDeck-Setup.cmd from GitHub"
    $ui.Add_Click({ Invoke-Updater '-Apply' })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  }

  $big = $menu.Items.Add('Show large view')
  $big.ToolTipText = "Open the deck - sessions and all settings live there (also Win+Alt+C)"
  $big.Add_Click({
    $vbs = Join-Path $env:USERPROFILE '.claude\sessions\show-view.vbs'
    Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs) -ErrorAction SilentlyContinue
  })

  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  $quit = $menu.Items.Add('Quit')
  $quit.ToolTipText = "Stop ClaudeDeck entirely (tray + desk)"
  $quit.Add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
}

# Background update check: an initial check shortly after start, then hourly
# (throttled to ~12h inside Invoke-UpdateCheckThrottled).
$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 8000   # first tick ~8s after launch, then switches to hourly
$updTimer.Add_Tick({
  $updTimer.Interval = 3600000
  Show-UpdateNotice            # surface any already-known update (balloon, once per version/session)
  Invoke-UpdateCheckThrottled  # then maybe launch a fresh check; its result shows next tick / on menu open
})
$updTimer.Start()

$menu.Add_Opening({ Build-Menu })

# Left-click also opens the menu (NotifyIcon shows it on right-click by default)
$notify.Add_MouseClick({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $m = $notify.GetType().GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $m.Invoke($notify, $null)
  }
})

# --- Global hotkey: open/focus the large view from anywhere ---------------
# Default Win+Alt+C (the Win key alone is mostly reserved by Windows; Win+Alt+
# <key> is registrable). Edit $HotMods / $HotVk below to change.
#   modifiers: ALT=1, CTRL=2, SHIFT=4, WIN=8 (combine with -bor); NOREPEAT=0x4000
#   key (VK):  'C'=0x43  'S'=0x53  'D'=0x44  'J'=0x4A  F8=0x77  F9=0x78
$HotMods = (1 -bor 8 -bor 0x4000)   # Win + Alt (+ no-repeat)
$HotVk   = 0x43                     # C

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class HotKeyWindow : NativeWindow {
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint m, uint vk);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  const int WM_HOTKEY = 0x0312;
  public event Action Pressed;
  int _id = 0;
  public HotKeyWindow() { CreateHandle(new CreateParams()); }
  public bool Register(uint mods, uint vk) { return RegisterHotKey(this.Handle, ++_id, mods, vk); }
  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_HOTKEY && Pressed != null) Pressed();
    base.WndProc(ref m);
  }
}
"@

# --- Pomodoro engine + focus classifier ------------------------------------
# The whole Pomodoro clock and the foreground-activity classifier now live in
# session-pomodoro.ps1 (dot-sourced at the top). It runs its own 1s timer and
# publishes pomodoro.json; it also exposes Get-PomoCategory + Play-PomoChime,
# which the focus nudge below reuses.

# ============================================================================
# Focus nudge
# When NO Claude session is active and you've drifted onto a distracting app,
# Claude - who is bored and rather keen on your projects - pokes you with the
# gentle chime and a flash of the deck (stamped via focus-nudge.txt, which the
# deck watches). Opt-in via focus.flag (toggled from the deck's gear menu),
# silenced by Do-Not-Disturb, and throttled so it never turns into a pest. It
# reuses the Pomodoro engine's foreground classifier.
# ============================================================================
$focusFlag      = Join-Path $env:USERPROFILE '.claude\sessions\focus.flag'
$dndFlag        = Join-Path $env:USERPROFILE '.claude\sessions\dnd.flag'
$stateDir       = Join-Path $env:USERPROFILE '.claude\sessions\state'
$nudgeSignal    = Join-Path $env:USERPROFILE '.claude\sessions\focus-nudge.txt'  # tray stamps [Environment]::TickCount here on each nudge; the deck flashes when it's fresh
$NUDGE_GAP_MS   = 180000   # at most one nudge per 3 minutes
$ACTIVE_WIN_MIN = 30       # a running/waiting session counts as active only if touched within 30 min
$script:lastNudge = 0      # [Environment]::TickCount of the last nudge (0 = never)

# A session is "active" (so Claude is NOT bored) when any state file is running or
# waiting AND was touched recently - a stale 'running' from a dead session must not
# suppress the nudge forever.
function Any-SessionActive {
  if (-not (Test-Path $stateDir)) { return $false }
  $now = Get-Date
  foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
    try {
      $o = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
      $upd = $f.LastWriteTime
      try { $upd = [datetime]$o.updated } catch {}
      if (($now - $upd).TotalMinutes -gt $ACTIVE_WIN_MIN) { continue }
      if ($o.status -eq 'running' -or $o.status -eq 'waiting') { return $true }
    } catch {}
  }
  return $false
}

# Every 20s: if enabled, not DND, off cooldown, no active session, and you're on a
# known distraction -> chime + stamp the signal file (the deck flashes on the stamp).
$focusTimer = New-Object System.Windows.Forms.Timer
$focusTimer.Interval = 20000
$focusTimer.Add_Tick({
  if (-not (Test-Path $focusFlag)) { return }
  if (Test-Path $dndFlag) { return }
  if (([Environment]::TickCount - $script:lastNudge) -lt $NUDGE_GAP_MS) { return }
  if (Any-SessionActive) { return }
  $info = Get-PomoCategory
  if ($info.cat -ne 'distract') { return }
  $script:lastNudge = [Environment]::TickCount
  try { Set-Content -LiteralPath $nudgeSignal -Value $script:lastNudge -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
  Play-PomoChime
  # If the deck is closed there'd be nothing to shake you - pop it so the Matrix
  # animation can play. The deck reads the (just-written) stamp on startup and, if
  # it's fresh, runs the gag immediately. If the deck is already open we leave it
  # be (its own poll plays the animation) so we don't yank focus needlessly.
  try {
    $deckOpen = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*session-view.ps1*' }).Count -gt 0
    if (-not $deckOpen) {
      $vbs = Join-Path $env:USERPROFILE '.claude\sessions\show-view.vbs'
      Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs) -ErrorAction SilentlyContinue
    }
  } catch {}
})
$focusTimer.Start()

$hk = New-Object HotKeyWindow
$hk.add_Pressed({
  $vbs = Join-Path $env:USERPROFILE '.claude\sessions\show-view.vbs'
  Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs) -ErrorAction SilentlyContinue
})
# Try the chosen combo; fall back to a couple of alternatives if it's taken.
foreach ($try in @(
    @{ m = $HotMods;               v = $HotVk },
    @{ m = (1 -bor 8 -bor 0x4000); v = 0x4A },   # Win+Alt+J
    @{ m = (2 -bor 1 -bor 0x4000); v = 0x43 })) {  # Ctrl+Alt+C
  if ($hk.Register([uint32]$try.m, [uint32]$try.v)) { break }
}

[System.Windows.Forms.Application]::Run()
