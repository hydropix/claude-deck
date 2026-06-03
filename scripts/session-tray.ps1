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

# Read update.json -> the parsed object when a newer version is available, else $null.
function Get-UpdateInfo {
  try {
    if (Test-Path $updInfoFile) {
      $j = [System.IO.File]::ReadAllText($updInfoFile) | ConvertFrom-Json
      if ($j.available) { return $j }
    }
  } catch {}
  return $null
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

# ============================================================================
# Pomodoro engine
# The tray is the only always-alive ClaudeDeck process, so it owns the Pomodoro
# clock AND the focus tracking. It writes the live state to pomodoro.json; the
# deck header (session-view.ps1) renders that file and drops control tokens into
# pomodoro-cmd.txt, which we consume here every second. There is NO separate
# window - all the Pomodoro UI lives in the deck's top row.
# ============================================================================
$pomoState = Join-Path $env:USERPROFILE '.claude\sessions\pomodoro.json'
$pomoCmd   = Join-Path $env:USERPROFILE '.claude\sessions\pomodoro-cmd.txt'
$pomoLog   = Join-Path $env:USERPROFILE '.claude\sessions\stats\pomodoro.jsonl'
$pomoUtf8  = New-Object System.Text.UTF8Encoding($false)

# Configuration (minutes). Hard-coded by design - no settings file.
$WORK_MIN = 25; $SHORT_MIN = 5; $LONG_MIN = 15; $CYCLES = 4; $IDLE_SEC = 60

# Win32: foreground window title/process + system idle time.
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PomoActivity {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("kernel32.dll")] static extern uint GetTickCount();
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  public static string FgTitle() {
    IntPtr h = GetForegroundWindow();
    int len = GetWindowTextLength(h);
    if (len == 0) return "";
    StringBuilder sb = new StringBuilder(len + 1);
    GetWindowText(h, sb, sb.Capacity);
    return sb.ToString();
  }
  public static uint FgPid() {
    IntPtr h = GetForegroundWindow();
    uint pid; GetWindowThreadProcessId(h, out pid);
    return pid;
  }
  public static uint IdleMillis() {
    LASTINPUTINFO i = new LASTINPUTINFO();
    i.cbSize = (uint)Marshal.SizeOf(i);
    if (!GetLastInputInfo(ref i)) return 0;
    return GetTickCount() - i.dwTime;
  }
}
"@

# Classification lists (matched on process name; distractions only count inside a browser).
$WORK_PROCS = @(
  'unity','unityhub','code','code - insiders','cursor','windsurf','devenv',
  'rider64','rider','webstorm64','webstorm','pycharm64','pycharm','clion64','clion',
  'idea64','idea','goland64','phpstorm64','datagrip64','rubymine64','sublime_text',
  'notepad++','godot','blender','ue4editor','ue5editor','unrealeditor','3dsmax','maya',
  'houdini','houdinifx','zbrush','substance painter','photoshop','illustrator','afterfx',
  'adobe premiere pro','windowsterminal','wt','alacritty','wezterm-gui','wezterm','conemu64')
$BROWSER_PROCS = @('chrome','firefox','msedge','edge','brave','opera','vivaldi','arc','librewolf','zen','waterfox')

# Hybrid browser model: inside a browser, a WORK_KEYS hit -> 'work', else a
# DISTRACT_KEYS hit -> 'distract', else 'neutral' (the gray zone, never penalised).
# Both are matched as lowercase substrings of the window TITLE (tab titles rarely
# show the bare domain), so the tokens are brand/name fragments, not domains.
# Short/ambiguous tokens (aws, ign, max, monday) are deliberately omitted - they
# collide with ordinary words (draws, design, 3dsmax, the weekday).
$WORK_KEYS = @(
  # code / dev
  'github','gitlab','bitbucket','stack overflow','stackoverflow','localhost',
  '127.0.0.1','codepen','codesandbox','jsfiddle','replit','dev.to','mdn',
  'developer.mozilla','caniuse','can i use','regex101','leetcode','codewars','npm',
  # ai assistants
  'claude','chatgpt','openai','gemini','copilot','perplexity','huggingface',
  # project / docs / comms
  'jira','confluence','notion','linear','asana','trello','clickup','slack',
  'obsidian','monday.com','docs',
  # design
  'figma','framer','miro','excalidraw','dribbble','behance','adobe','canva',
  # cloud / deploy
  'vercel','netlify','cloudflare','supabase','firebase','heroku','digitalocean')
$DISTRACT_KEYS = @(
  # social
  'facebook','instagram','twitter','x.com',' / x','tiktok','snapchat','reddit',
  'tumblr','pinterest','mastodon','bluesky','threads',
  # video / streaming
  'youtube','netflix','twitch','vimeo','prime video','disney+','hulu',
  'dailymotion','crunchyroll','hbo',
  # fun / time-sinks
  '9gag','buzzfeed','imgur','deviantart',
  # shopping
  'amazon','ebay','aliexpress','etsy','temu',
  # gaming
  'steam','epic games')

# Optional per-user extensions: one keyword per line, lowercase substring match on
# the browser tab title; blank lines and #comments are ignored. Merged once at tray
# start - edit the file then restart the tray to apply. worksites.txt extends the
# work whitelist, distractions.txt extends the distraction blocklist.
function Read-KeyList([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  try {
    return @(Get-Content $path -ErrorAction Stop |
      ForEach-Object { $_.Trim().ToLower() } |
      Where-Object { $_ -and (-not $_.StartsWith('#')) })
  } catch { return @() }
}
$WORK_KEYS     += Read-KeyList (Join-Path $env:USERPROFILE '.claude\sessions\worksites.txt')
$DISTRACT_KEYS += Read-KeyList (Join-Path $env:USERPROFILE '.claude\sessions\distractions.txt')

function Get-AppLabel($pname) {
  switch -Regex ($pname) {
    '^code'    { return 'VS Code' }
    '^cursor'  { return 'Cursor' }
    '^unity'   { return 'Unity' }
    '^rider'   { return 'Rider' }
    '^devenv'  { return 'Visual Studio' }
    '^blender' { return 'Blender' }
    '(windowsterminal|^wt$|alacritty|wezterm|conemu)' { return 'Terminal' }
    'chrome|firefox|msedge|edge|brave|opera|vivaldi|arc' { return 'Browser' }
    default    { if ($pname) { return (Get-Culture).TextInfo.ToTitleCase($pname) } else { return 'desktop' } }
  }
}

# Returns @{ cat='self|work|distract|neutral|away'; label='<app/site>' } for the
# current foreground window.
function Get-PomoCategory {
  $idle = [PomoActivity]::IdleMillis()
  if ($idle -ge ($IDLE_SEC * 1000)) { return @{ cat = 'away'; label = 'idle' } }
  $title = [PomoActivity]::FgTitle()
  $fgPid = [PomoActivity]::FgPid()      # NB: never name this $pid - it's a read-only automatic var
  $pname = ''
  try { $pname = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName.ToLower() } catch {}
  # The deck / stats windows are "self": glancing at them never penalises focus.
  if ($title -eq 'Claude Code Sessions' -or $title -eq 'ClaudeDeck Statistics') { return @{ cat = 'self'; label = '' } }
  $tl = $title.ToLower()
  $isBrowser = $false
  foreach ($b in $BROWSER_PROCS) { if ($pname -eq $b) { $isBrowser = $true; break } }
  if ($isBrowser) {
    # Hybrid: a work site wins, then a known distraction; anything else in a
    # browser falls through to 'neutral' (the gray zone is never penalised).
    foreach ($k in $WORK_KEYS) {
      if ($tl.Contains($k)) { return @{ cat = 'work'; label = (Get-Culture).TextInfo.ToTitleCase($k.Trim()) } }
    }
    foreach ($k in $DISTRACT_KEYS) {
      if ($tl.Contains($k)) { return @{ cat = 'distract'; label = (Get-Culture).TextInfo.ToTitleCase($k.Trim()) } }
    }
  }
  foreach ($w in $WORK_PROCS) { if ($pname -eq $w) { return @{ cat = 'work'; label = (Get-AppLabel $pname) } } }
  return @{ cat = 'neutral'; label = (Get-AppLabel $pname) }
}

function Pomo-PhaseSeconds($ph) {
  switch ($ph) { 'short' { return $SHORT_MIN * 60 } 'long' { return $LONG_MIN * 60 } default { return $WORK_MIN * 60 } }
}

# Pomodoro runtime state.
$script:poRunning   = $false
$script:poPhase     = 'work'
$script:poRemaining = $WORK_MIN * 60
$script:poCompleted = 0
$script:poDay       = (Get-Date).ToString('yyyy-MM-dd')
$script:poTrack     = 'work'
$script:poStatus    = 'Ready'
$script:poFocusAcc  = 0
$script:poDistAcc   = 0
$script:poLastEff   = 'work'

# Restore the last persisted state on tray start (so a tray restart resumes).
try {
  if (Test-Path $pomoState) {
    $o = [System.IO.File]::ReadAllText($pomoState) | ConvertFrom-Json
    if ($o.phase)   { $script:poPhase = [string]$o.phase }
    if ($null -ne $o.remaining) { $script:poRemaining = [int]$o.remaining }
    if ($null -ne $o.completed) { $script:poCompleted = [int]$o.completed }
    if ($o.day)     { $script:poDay = [string]$o.day }
    if ($null -ne $o.running)   { $script:poRunning = [bool]$o.running }
  }
} catch {}

function Write-Pomo {
  try {
    $obj = [ordered]@{
      running   = $script:poRunning
      phase     = $script:poPhase
      remaining = [int]$script:poRemaining
      completed = [int]$script:poCompleted
      track     = $script:poTrack
      status    = $script:poStatus
      day       = $script:poDay
      updated   = (Get-Date).ToString('o')
    }
    [System.IO.File]::WriteAllText($pomoState, ($obj | ConvertTo-Json -Compress), $pomoUtf8)
  } catch {}
}

# Gentle cue on a phase change (you may be heads-down with the deck closed).
function Play-PomoChime {
  try {
    $wav = Join-Path $PSScriptRoot 'notify.wav'
    if (Test-Path $wav) { (New-Object System.Media.SoundPlayer($wav)).Play() }
    else { [System.Media.SystemSounds]::Asterisk.Play() }
  } catch {}
}

function Log-Pomodoro($focusSec, $distractSec) {
  try {
    $dir = Split-Path -Parent $pomoLog
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = (([ordered]@{ ts = (Get-Date).ToString('o'); ev = 'pomodoro'; focus = [int]$focusSec; distract = [int]$distractSec }) | ConvertTo-Json -Compress) + "`r`n"
    $fs = New-Object System.IO.FileStream($pomoLog, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $bytes = $pomoUtf8.GetBytes($line)
    $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
  } catch {}
}

# Move to the next phase. $natural=$true means a work pomodoro actually elapsed
# (counts + is logged); $false is a manual Skip (abandons, no credit).
function Advance-Pomo([bool]$natural) {
  if ($script:poPhase -eq 'work') {
    if ($natural) {
      $script:poCompleted++
      Log-Pomodoro $script:poFocusAcc $script:poDistAcc
    }
    # Long break after every $CYCLES completed pomodoros, else a short one.
    if ((($script:poCompleted % $CYCLES) -eq 0) -and ($script:poCompleted -gt 0)) { $script:poPhase = 'long' }
    else { $script:poPhase = 'short' }
  } else {
    $script:poPhase = 'work'
  }
  $script:poRemaining = Pomo-PhaseSeconds $script:poPhase
  $script:poFocusAcc = 0; $script:poDistAcc = 0
  if ($natural) { Play-PomoChime }   # a phase actually elapsed - cue the change
}

function Apply-PomoCmd($cmd) {
  switch ($cmd) {
    'toggle' { $script:poRunning = -not $script:poRunning }
    'start'  { $script:poRunning = $true }
    'pause'  { $script:poRunning = $false }
    'skip'   { Advance-Pomo $false }
    'reset'  {
      $script:poRunning = $false; $script:poPhase = 'work'
      $script:poRemaining = Pomo-PhaseSeconds 'work'
      $script:poFocusAcc = 0; $script:poDistAcc = 0
      $script:poTrack = 'work'; $script:poStatus = 'Ready'; $script:poLastEff = 'work'
    }
  }
}

$pomoTimer = New-Object System.Windows.Forms.Timer
$pomoTimer.Interval = 1000
$pomoTimer.Add_Tick({
  # New day -> reset the visible "today" counter.
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ($today -ne $script:poDay) { $script:poDay = $today; $script:poCompleted = 0 }

  # Consume any control command dropped by the deck header.
  if (Test-Path $pomoCmd) {
    $cmd = ''
    try { $cmd = ([System.IO.File]::ReadAllText($pomoCmd)).Trim().ToLower() } catch {}
    try { Remove-Item $pomoCmd -Force -ErrorAction SilentlyContinue } catch {}
    if ($cmd) { Apply-PomoCmd $cmd }
  }

  if (-not $script:poRunning) {
    $script:poTrack = 'paused'; $script:poStatus = 'Paused'
    Write-Pomo; return
  }

  if ($script:poPhase -ne 'work') {
    # Breaks just count down - no focus policing.
    $script:poTrack = 'break'; $script:poStatus = 'Break'
    $script:poRemaining--
    if ($script:poRemaining -le 0) { Advance-Pomo $true }
    Write-Pomo; return
  }

  # WORK phase: advance only while on a work window and active.
  $info = Get-PomoCategory
  $cat  = $info.cat
  if ($cat -eq 'self') { $cat = $script:poLastEff } else { $script:poLastEff = $cat }
  switch ($cat) {
    'work' {
      $script:poStatus = ('Focus - {0}' -f $info.label)
      $script:poRemaining--; $script:poFocusAcc++
      if ($script:poRemaining -le 0) { Advance-Pomo $true }
    }
    'distract' { $script:poStatus = ('Off track - {0}' -f $info.label); $script:poDistAcc++ }
    'away'     { $script:poStatus = 'Paused - away' }
    default    { $script:poStatus = ('Paused - {0}' -f $info.label) }
  }
  $script:poTrack = $cat
  Write-Pomo
})
$pomoTimer.Start()
Write-Pomo   # publish an initial state file immediately

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
