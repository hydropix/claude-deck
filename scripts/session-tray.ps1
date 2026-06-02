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

# --- Background auto-update (off by default) -------------------------------
# When autoUpdFlag is present, the tray periodically asks session-update.ps1 to
# compare the installed version with the GitHub repo and writes update.json. The
# desk's gear menu reads that file and offers the install. The toggle itself also
# lives in the desk - the tray only runs the check.
$autoUpdFlag = Join-Path $env:USERPROFILE '.claude\sessions\autoupdate.flag'
$updInfoFile = Join-Path $env:USERPROFILE '.claude\sessions\update.json'
$updScript   = Join-Path $env:USERPROFILE '.claude\sessions\session-update.ps1'

# Launch a version check in a hidden background process (never blocks the UI).
function Invoke-Updater([string]$mode) {
  if (-not (Test-Path $updScript)) { return }
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $updScript), $mode
  ) -ErrorAction SilentlyContinue
}
# Check only when enabled, and at most a couple of times a day (throttled via update.json).
function Invoke-UpdateCheckThrottled {
  if (-not (Test-Path $autoUpdFlag)) { return }
  try {
    if (Test-Path $updInfoFile) {
      $j = [System.IO.File]::ReadAllText($updInfoFile) | ConvertFrom-Json
      if ($j.checked -and ((Get-Date) - [datetime]$j.checked).TotalHours -lt 12) { return }
    }
  } catch {}
  Invoke-Updater '-Check'
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

# The whole tray menu: open the desk, and quit. Nothing else by design.
function Build-Menu {
  $menu.Items.Clear()

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
  Invoke-UpdateCheckThrottled
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
