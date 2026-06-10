# ClaudeDeck - Pomodoro engine + activity classifier (dot-sourced by session-tray.ps1).
#
# The tray is the only always-alive ClaudeDeck process, so it owns the Pomodoro
# clock AND the focus tracking. This file holds all of that logic so the tray
# itself stays about the tray icon, menu, hotkey and updates. It:
#   * classifies the foreground window as self/work/distract/neutral/away
#     (Get-PomoCategory - also reused by the tray's focus nudge),
#   * runs the work/break clock on a 1s timer, advancing phases and logging
#     completed pomodoros,
#   * publishes the live state to pomodoro.json (the deck header renders it) and
#     consumes control tokens the deck drops into pomodoro-cmd.txt.
# There is NO separate window - all the Pomodoro UI lives in the deck's top row.
#
# DOT-SOURCE SAFETY: param-less, no script-scope $ErrorActionPreference (would leak
# into the tray); every function guards itself. Dot-source AFTER session-common.ps1
# (uses Get-CDPath / Get-CDUtf8) and AFTER System.Windows.Forms is loaded (Timer).
# Creating + starting $pomoTimer here mirrors the tray's old inline behaviour; it
# only ticks once the tray's Application::Run message loop is pumping.

$pomoState = Get-CDPath 'pomodoro.json'
$pomoCmd   = Get-CDPath 'pomodoro-cmd.txt'
$pomoLog   = Get-CDPath 'stats\pomodoro.jsonl'
$pomoUtf8  = Get-CDUtf8

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
  'steam','epic games','chess')

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
$WORK_KEYS     += Read-KeyList (Get-CDPath 'worksites.txt')
$DISTRACT_KEYS += Read-KeyList (Get-CDPath 'distractions.txt')

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

# Gentle cue on a phase change / focus nudge (you may be heads-down with the deck
# closed). Plays the same soft notify.wav rise the tracker uses, but ONCE - so it
# stays distinct from the work-done chime (which the tracker plays twice). The raw
# [console]::beep square waves it used to emit sound harsh on most hardware, so
# they're now only a fallback for when the chime asset is missing.
function Play-PomoChime {
  try {
    $wav = Join-Path $PSScriptRoot 'notify.wav'
    if (Test-Path $wav) {
      (New-Object System.Media.SoundPlayer $wav).PlaySync()
    } else {
      [console]::beep(587, 150)   # D5 - fallback only
      [console]::beep(880, 220)   # A5
    }
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
