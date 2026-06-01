# Claude Sessions — minimalist Windows tray app.
# Left/right click the tray icon: list of active Claude Code sessions.
#   ● green = Claude is working   ○ grey = finished
# Click a session -> focus its VS Code / Cursor window (by title, no new window).

# Single-instance guard: if another tray process is already running, exit.
# (A named mutex proved unreliable here, so we scan for a sibling process.)
$dupes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*session-tray.ps1*' })
if ($dupes.Count -gt 0) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Win32 helper: focus an existing IDE window by title substring ---
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
      if (isIde && t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) {
        found = h; return false;
      }
      return true;
    }, IntPtr.Zero);
    if (found == IntPtr.Zero) return false;
    if (IsIconic(found)) ShowWindow(found, SW_RESTORE);  // only un-minimize; never resize a maximized/normal window
    uint pid;
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, fg, true);
    BringWindowToTop(found);
    SetForegroundWindow(found);
    AttachThreadInput(cur, fg, false);
    return true;
  }
}
"@

$stateDir    = Join-Path $env:USERPROFILE '.claude\sessions\state'
$dndFlag     = Join-Path $env:USERPROFILE '.claude\sessions\dnd.flag'
$closeFlag   = Join-Path $env:USERPROFILE '.claude\sessions\closeoutside.flag'
$opacityFile = Join-Path $env:USERPROFILE '.claude\sessions\opacity.txt'   # 20..100 (window opacity %)
$sizeFile    = Join-Path $env:USERPROFILE '.claude\sessions\size.txt'      # 30..95  (window width, % of screen)

# --- Optional auto-update (off by default) ---------------------------------
# When autoUpdFlag is present, the tray periodically asks session-update.ps1 to
# compare the installed version with the GitHub repo and writes update.json.
$autoUpdFlag = Join-Path $env:USERPROFILE '.claude\sessions\autoupdate.flag'
$updInfoFile = Join-Path $env:USERPROFILE '.claude\sessions\update.json'
$updScript   = Join-Path $env:USERPROFILE '.claude\sessions\session-update.ps1'
$verFile     = Join-Path $env:USERPROFILE '.claude\sessions\version.txt'
$script:updNotified = $false

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

# Per-project accent colour (hash of name -> hue) + a small colour swatch icon.
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
function New-Swatch($color) {
  $bmp = New-Object System.Drawing.Bitmap(16, 16)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear($color); $g.Dispose()
  return $bmp
}
# Context occupied, compact: "117k (59%)" — empty when unknown (old state files).
function Format-Ctx($s) {
  $tok = $s.ctx_tokens
  if ($null -eq $tok) { return '' }
  $k = if ([int]$tok -ge 1000) { '{0}k' -f [int][math]::Round([int]$tok / 1000.0) } else { [string][int]$tok }
  if ($null -ne $s.ctx_pct) { return ('{0} ({1}%)' -f $k, [int]$s.ctx_pct) }
  return $k
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = 'Claude Sessions'
$notify.Visible = $true

# Ballon de demarrage : aide a reperer l'icone (souvent dans la zone masquee ^)
try {
  $notify.BalloonTipTitle = 'Claude Sessions'
  $notify.BalloonTipText  = 'Actif. Clique cette icone pour voir tes sessions.'
  $notify.ShowBalloonTip(4000)
} catch {}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

function Add-Click($item, $proj, $cwd) {
  $item.Add_Click({
    if (-not [WinFocus]::FocusByTitle($proj)) {
      # Fallback: focus/open the REAL VS Code (never Cursor). Resolve the exe
      # from the running Code process so `code` (= Cursor here) is bypassed.
      $codeExe = (Get-Process -Name Code -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
      if ($codeExe -and $cwd) { Start-Process $codeExe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction SilentlyContinue }
    }
  }.GetNewClosure())
}

function Build-Menu {
  $menu.Items.Clear()
  $now = Get-Date
  $sessions = @()
  if (Test-Path $stateDir) {
    foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
      try { $s = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
      try { $upd = [datetime]$s.updated } catch { $upd = $f.LastWriteTime }
      if (($now - $upd).TotalHours -gt 24) { Remove-Item $f.FullName -Force -EA SilentlyContinue; continue }
      $st = [string]$s.status
      if ($st -ne 'running' -and $st -ne 'waiting') { $st = 'done' }
      $order = switch ($st) { 'waiting' { 0 } 'running' { 1 } default { 2 } }
      $sessions += [pscustomobject]@{ s = $s; upd = $upd; st = $st; order = $order }
    }
  }
  # Sort: waiting first, then running, then done; newest within each group.
  $sessions = @($sessions | Sort-Object @{ Expression = 'order' }, @{ Expression = 'upd'; Descending = $true })

  if ($sessions.Count -eq 0) {
    $it = $menu.Items.Add('Aucune session active')
    $it.Enabled = $false
  } else {
    foreach ($e in $sessions) {
      $s = $e.s
      switch ($e.st) {
        'running' { $dot = [char]0x25CF; $fc = [System.Drawing.Color]::FromArgb(80, 200, 120) }   # ●
        'waiting' { $dot = [char]0x25CF; $fc = [System.Drawing.Color]::FromArgb(235, 150, 40) }    # ● (attend)
        default   { $dot = [char]0x25CB; $fc = [System.Drawing.Color]::DimGray }                   # ○
      }
      $p = [string]$s.last_prompt
      if (-not $p) { $p = '(pas de demande)' }
      if ($p.Length -gt 64) { $p = $p.Substring(0, 64) + [char]0x2026 }
      $mins = [int]($now - $e.upd).TotalMinutes
      $age = if ($mins -lt 1) { "maintenant" } elseif ($mins -lt 60) { "${mins}m" } else { "$([int]($mins/60))h" }
      $it = New-Object System.Windows.Forms.ToolStripMenuItem
      $sep = [char]0x2014   # em dash, built from code point (no non-ASCII literal in source)
      $ctxStr = Format-Ctx $s
      if ($ctxStr) { $it.Text = ('{0}  {1}   {2}   {3}   ({4})   {5} {6}' -f $dot, $s.project, $sep, $p, $age, [char]0x2022, $ctxStr) }
      else         { $it.Text = ('{0}  {1}   {2}   {3}   ({4})' -f $dot, $s.project, $sep, $p, $age) }
      $it.ForeColor = $fc
      try { $it.Image = New-Swatch (Get-ProjectColor ([string]$s.project)) } catch {}   # per-project colour
      Add-Click $it ([string]$s.project) ([string]$s.cwd)
      [void]$menu.Items.Add($it)
    }
  }
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Prominent "install update" entry, shown only when a newer version was found.
  $upd = Get-UpdateInfo
  if ($upd) {
    $ui = New-Object System.Windows.Forms.ToolStripMenuItem(("Installer la mise a jour (v{0})" -f $upd.latest))
    $ui.ForeColor = [System.Drawing.Color]::FromArgb(80, 160, 90)
    $ui.ToolTipText = "Telecharge et execute le dernier ClaudeDeck-Setup.cmd depuis GitHub"
    $ui.Add_Click({ Invoke-Updater '-Apply' })
    [void]$menu.Items.Add($ui)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  }

  $dnd = New-Object System.Windows.Forms.ToolStripMenuItem('Ne pas deranger')
  $dnd.Checked = (Test-Path $dndFlag)
  $dnd.ToolTipText = "Suspend l'ouverture automatique de la grande vue et les rappels"
  $dnd.Add_Click({
    if (Test-Path $dndFlag) { Remove-Item $dndFlag -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $dndFlag -Value '' -Encoding ASCII }
  })
  [void]$menu.Items.Add($dnd)

  $co = New-Object System.Windows.Forms.ToolStripMenuItem('Fermer au clic exterieur')
  $co.Checked = (Test-Path $closeFlag)
  $co.ToolTipText = "Fermer la grande vue quand on clique en dehors (desactive par defaut)"
  $co.Add_Click({
    if (Test-Path $closeFlag) { Remove-Item $closeFlag -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $closeFlag -Value '' -Encoding ASCII }
  })
  [void]$menu.Items.Add($co)

  # Transparency submenu — writes opacity % to opacity.txt (read live by the view).
  $curOp = 92   # default: light transparency (Legere)
  try { if (Test-Path $opacityFile) { $curOp = [int]((Get-Content $opacityFile -Raw -ErrorAction Stop).Trim()) } } catch {}
  $opMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Transparence')
  $opMenu.ToolTipText = "Rend la grande vue plus ou moins transparente"
  foreach ($lvl in @(
      @{ v = 100; l = 'Aucune (opaque)' },
      @{ v = 92;  l = 'Legere' },
      @{ v = 80;  l = 'Moyenne' },
      @{ v = 65;  l = 'Forte' })) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($lvl.l)
    $mi.Checked = ($curOp -eq $lvl.v)
    $val = $lvl.v
    $mi.Add_Click({ Set-Content -LiteralPath $opacityFile -Value $val -Encoding ASCII -ErrorAction SilentlyContinue }.GetNewClosure())
    [void]$opMenu.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($opMenu)

  # Size submenu — writes window width (% of screen) to size.txt (read live by the view).
  $curSize = 55
  try { if (Test-Path $sizeFile) { $curSize = [int]((Get-Content $sizeFile -Raw -ErrorAction Stop).Trim()) } } catch {}
  $szMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Taille')
  $szMenu.ToolTipText = "Largeur de la grande vue"
  foreach ($sz in @(
      @{ v = 42; l = 'Compacte' },
      @{ v = 55; l = 'Normale' },
      @{ v = 68; l = 'Large' },
      @{ v = 82; l = 'Tres large' })) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($sz.l)
    $mi.Checked = ($curSize -eq $sz.v)
    $val = $sz.v
    $mi.Add_Click({ Set-Content -LiteralPath $sizeFile -Value $val -Encoding ASCII -ErrorAction SilentlyContinue }.GetNewClosure())
    [void]$szMenu.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($szMenu)

  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Auto-update toggle (opt-in / off by default) + manual check.
  $au = New-Object System.Windows.Forms.ToolStripMenuItem('Mises a jour automatiques')
  $au.Checked = (Test-Path $autoUpdFlag)
  $au.ToolTipText = "Verifie periodiquement le depot GitHub et propose d'installer les nouvelles versions"
  $au.Add_Click({
    if (Test-Path $autoUpdFlag) { Remove-Item $autoUpdFlag -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $autoUpdFlag -Value '' -Encoding ASCII; Invoke-Updater '-Check' }
  })
  [void]$menu.Items.Add($au)

  $chk = $menu.Items.Add('Verifier les mises a jour')
  $chk.ToolTipText = "Cherche maintenant une nouvelle version sur GitHub"
  $chk.Add_Click({
    Invoke-Updater '-Check'
    try { $notify.ShowBalloonTip(3000, 'ClaudeDeck', 'Recherche de mises a jour...', [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
  })

  $ver = Get-LocalVersion
  if ($ver) {
    $vi = $menu.Items.Add("ClaudeDeck v$ver")
    $vi.Enabled = $false
  }

  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  $big = $menu.Items.Add('Afficher en grand')
  $big.Add_Click({
    $vbs = Join-Path $env:USERPROFILE '.claude\sessions\show-view.vbs'
    Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs) -ErrorAction SilentlyContinue
  })
  $quit = $menu.Items.Add('Quitter')
  $quit.Add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
}

# Reminder: nudge once when a finished task has been sitting for a while
# (so completed work isn't forgotten). Skipped while "Ne pas deranger" is on.
$script:reminded = @{}
$remindTimer = New-Object System.Windows.Forms.Timer
$remindTimer.Interval = 60000   # check every minute
$remindTimer.Add_Tick({
  # Notify once per session when a new version is available (independent of DND).
  if (-not $script:updNotified) {
    $upd = Get-UpdateInfo
    if ($upd) {
      $script:updNotified = $true
      try { $notify.ShowBalloonTip(6000, 'ClaudeDeck - mise a jour disponible', ("Version $($upd.latest) disponible. Clique l'icone -> Installer la mise a jour."), [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
  }
  if (Test-Path $dndFlag) { return }
  $now = Get-Date
  if (-not (Test-Path $stateDir)) { return }
  foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
    try { $s = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
    if ([string]$s.status -ne 'done') { continue }
    try { $upd = [datetime]$s.updated } catch { continue }
    $key = [string]$s.session_id + '|' + [string]$s.updated
    if ((($now - $upd).TotalMinutes -ge 15) -and (-not $script:reminded.ContainsKey($key))) {
      $script:reminded[$key] = $true
      try { $notify.ShowBalloonTip(5000, 'Tache terminee en attente', ([string]$s.project + ' : ' + [string]$s.last_prompt), [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
  }
})
$remindTimer.Start()

# Auto-update: an initial check shortly after start, then hourly (throttled to ~12h).
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
$HotLabel = 'Win+Alt+C'

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
$registered = $null
foreach ($try in @(
    @{ m = $HotMods;                  v = $HotVk; lbl = $HotLabel },
    @{ m = (1 -bor 8 -bor 0x4000);    v = 0x4A;   lbl = 'Win+Alt+J' },
    @{ m = (2 -bor 1 -bor 0x4000);    v = 0x43;   lbl = 'Ctrl+Alt+C' })) {
  if ($hk.Register([uint32]$try.m, [uint32]$try.v)) { $registered = $try.lbl; break }
}
try {
  if ($registered) {
    $notify.ShowBalloonTip(4000, 'Claude Sessions', "Raccourci global : $registered (ouvre la grande vue)", [System.Windows.Forms.ToolTipIcon]::Info)
  }
} catch {}

[System.Windows.Forms.Application]::Run()
