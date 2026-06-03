# ClaudeDeck - shared library (dot-sourced by the UI scripts).
#
# This is the single home for the small helpers that used to be copy-pasted across
# session-view.ps1, session-tray.ps1, session-stats.ps1 and session-update.ps1:
#   * the data-layout paths under ~/.claude/sessions  (Get-CDRoot / Get-CDPath)
#   * UTF-8 (no BOM) file writes                       (Get-CDUtf8 / Write-CDText)
#   * flag-file presence toggle                        (Toggle-Flag)
#   * per-project accent colour + initials badge       (Get-ProjectColor / Get-Initials / Get-TextOn)
#   * the self-updater bridge                          (Get-LocalVersion / Invoke-Updater / Get-UpdateInfo)
#
# DOT-SOURCE SAFETY (same rules as session-workspaces.ps1): this file is dot-sourced
# into a live WinForms scope, so it MUST stay side-effect free -
#   * no param() block,
#   * no $ErrorActionPreference at script scope (it would leak into the caller),
#   * top level defines functions + pure constants only - nothing that runs UI or IO.
# Every function guards itself with try/catch. The colour helpers return
# System.Drawing.Color, so the caller must have loaded System.Drawing before calling
# them (every consumer does); they are never invoked at dot-source time.
#
# NB: session-tracker.ps1 deliberately does NOT depend on this file. It runs inside
# Claude Code hooks and must never throw, so it stays fully self-contained.

# --- Data & settings layout ------------------------------------------------
# Every runtime file lives under ~/.claude/sessions. Resolve paths through these
# two helpers instead of re-typing the '.claude\sessions' literal everywhere, so
# the layout has a single source of truth.
function Get-CDRoot { Join-Path $env:USERPROFILE '.claude\sessions' }
function Get-CDPath([string]$relative) { Join-Path (Get-CDRoot) $relative }

# --- UTF-8 without BOM ------------------------------------------------------
# PS 5.1's Set-Content / Out-File mangle accents; always write through this.
$script:CDUtf8 = New-Object System.Text.UTF8Encoding($false)
function Get-CDUtf8 { return $script:CDUtf8 }
function Write-CDText([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, $script:CDUtf8)
}

# --- Flag files (presence = on) --------------------------------------------
# Toggle a flag file on/off. $path is the full flag path (callers already hold it).
function Toggle-Flag([string]$path) {
  if (Test-Path $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  else { Set-Content -LiteralPath $path -Value '' -Encoding ASCII -ErrorAction SilentlyContinue }
}

# --- Per-project accent colour + initials badge ----------------------------
# Stable hash of the project name -> hue, so the same project always gets the same
# colour in both the deck and the stats dashboard.
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
# Up to two letters for the badge: leading capitals (camel/Pascal), else the first
# two characters upper-cased.
function Get-Initials($name) {
  if (-not $name) { return '?' }
  $caps = ($name -creplace '[^A-Z0-9]', '')
  if ($caps.Length -ge 2) { return $caps.Substring(0, 2) }
  return ($name.Substring(0, [math]::Min(2, $name.Length))).ToUpper()
}
# Black or white text, whichever stays legible on the given background.
function Get-TextOn($color) {
  $lum = (0.299 * $color.R + 0.587 * $color.G + 0.114 * $color.B) / 255.0
  if ($lum -gt 0.58) { return [System.Drawing.Color]::FromArgb(25, 25, 30) } else { return [System.Drawing.Color]::White }
}

# --- .env settings ----------------------------------------------------------
# User-editable settings live in ~/.claude/sessions/.env (seeded from .env.example
# by the installer). Currently only the weekly-recap Ollama config. Returns a
# hashtable of UPPER-CASE keys, pre-filled with defaults so callers never have to
# null-check. KEY=VALUE per line; blank lines and #comments ignored; surrounding
# single/double quotes stripped. Side-effect free (reads the file on each call).
function Get-CDEnv {
  $env = @{
    # Provider: 'ollama' (native /api/generate) or 'openai' (any OpenAI-compatible
    # /v1/chat/completions endpoint). The LLM_* keys are the generic config used by
    # both; the legacy OLLAMA_* keys are still honoured as fallbacks (so an existing
    # .env keeps working). Empty LLM_* default => "unset", falls back to OLLAMA_*.
    LLM_PROVIDER           = 'ollama'
    LLM_URL                = ''
    LLM_MODEL              = ''
    LLM_API_KEY            = ''
    LLM_ENABLED            = ''
    LLM_TIMEOUT            = ''
    OLLAMA_URL             = 'http://ai_server.mds.com:11434'
    OLLAMA_MODEL           = 'gemma4:latest'
    OLLAMA_ENABLED         = 'true'
    OLLAMA_TIMEOUT         = '60'
    RECAP_INCLUDE_OUTCOMES = 'true'
    RECAP_OUTCOME_CHARS    = '250'
  }
  try {
    $f = Get-CDPath '.env'
    if (Test-Path $f) {
      foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        $t = ([string]$line).Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq).Trim().ToUpper()
        $v = $t.Substring($eq + 1).Trim().Trim('"').Trim("'")
        if ($k) { $env[$k] = $v }
      }
    }
  } catch {}
  return $env
}

# --- Self-updater bridge ----------------------------------------------------
# session-update.ps1 does the actual version compare / download; these helpers let
# the deck and the tray launch it and read its result (update.json) without each
# re-deriving the paths. (Legacy names kept so existing call sites are unchanged.)
function Get-LocalVersion {
  try { $v = Get-CDPath 'version.txt'; if (Test-Path $v) { return ([System.IO.File]::ReadAllText($v)).Trim() } } catch {}
  return $null
}
# Launch a version check / install in a hidden background process (never blocks the UI).
function Invoke-Updater([string]$mode) {
  $updScript = Get-CDPath 'session-update.ps1'
  if (-not (Test-Path $updScript)) { return }
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $updScript), $mode
  ) -ErrorAction SilentlyContinue
}
# The parsed update.json when a newer version is available, else $null.
function Get-UpdateInfo {
  try {
    $f = Get-CDPath 'update.json'
    if (Test-Path $f) {
      $j = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
      if ($j.available) { return $j }
    }
  } catch {}
  return $null
}
