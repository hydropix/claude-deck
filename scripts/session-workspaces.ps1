# ClaudeDeck - open-workspace memory.
#
# Remembers which folders / .code-workspace files are currently open in VS Code
# (and Cursor) so they can be reopened in one click after a Windows logout or
# restart. The reliable source is each IDE's own globalStorage\storage.json,
# whose "windowsState.openedWindows" lists every open window with a full path
# (a window-title scan only yields the folder *name*, not the path).
#
# Two roles, kept here so the logic lives in one place:
#   Save-Workspaces    snapshot the open windows -> ~/.claude/sessions/workspaces.json
#   Restore-Workspaces read that snapshot back and relaunch each one
#
# Usable two ways:
#   - run directly for manual use / testing:
#       powershell -File .\scripts\session-workspaces.ps1 -Save
#       powershell -File .\scripts\session-workspaces.ps1 -Restore
#       powershell -File .\scripts\session-workspaces.ps1 -Restore -Only "C:\path\to\one"
#       powershell -File .\scripts\session-workspaces.ps1 -List   # print, no side effects
#   - dot-sourced by session-tray.ps1, which then calls the functions in-process
#     (a dot-source defines the functions only; the action block below is skipped).
param([switch]$Save, [switch]$Restore, [switch]$List, [string]$Only)

# NOTE: do NOT set $ErrorActionPreference here at script scope - when this file is
# dot-sourced (by the tray / view), that would leak into the caller and silently
# change its behaviour. Every function below already guards itself with try/catch.
# When run standalone, the action block at the bottom sets it locally.

$wsFile    = Join-Path $env:USERPROFILE '.claude\sessions\workspaces.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# The IDEs we know about: app tag, storage.json path, and how to find the exe to
# relaunch with. Cursor is a VS Code fork, so it uses the identical storage schema.
function Get-IdeDefs {
  @(
    [pscustomobject]@{
      app     = 'code'
      storage = (Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json')
      exes    = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft VS Code\Code.exe')
      )
      proc    = 'Code'
    },
    [pscustomobject]@{
      app     = 'cursor'
      storage = (Join-Path $env:APPDATA 'Cursor\User\globalStorage\storage.json')
      exes    = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe')
      )
      proc    = 'Cursor'
    }
  )
}

# Decode a VS Code "file:///c%3A/..." URI into a Windows path ("c:\...").
# [Uri]::LocalPath can't be trusted here: VS Code percent-encodes the drive colon
# ("c%3A"), and .NET then fails to recognise the drive and yields "/c:/..." with a
# leading slash and forward slashes. So we decode by hand.
function ConvertFrom-FileUri([string]$uri) {
  if (-not $uri) { return $null }
  try {
    $u = $uri -replace '^[A-Za-z]+:/+', ''        # drop the "file:///" scheme + leading slashes
    $u = [Uri]::UnescapeDataString($u)            # "c%3A/Plastic" -> "c:/Plastic"
    $u = $u -replace '/', '\'                       # to Windows separators
    if ($u -match '^\\([A-Za-z]:.*)$') { $u = $Matches[1] }   # "\c:\.." -> "c:\.."
    return $u
  } catch { return $null }
}

# A friendly leaf name for the menu: the folder name, or the .code-workspace
# file name with its extension stripped.
function Get-LeafName([string]$path, [string]$kind) {
  if (-not $path) { return 'workspace' }
  $leaf = Split-Path $path -Leaf
  if ($kind -eq 'workspace') { $leaf = $leaf -replace '\.code-workspace$', '' }
  if (-not $leaf) { $leaf = $path }
  return $leaf
}

# Read one IDE's storage.json and return its open windows as item objects.
function Read-OpenWindows($ide) {
  $items = @()
  try {
    if (-not (Test-Path $ide.storage)) { return $items }
    $raw  = [System.IO.File]::ReadAllText($ide.storage)
    $data = $raw | ConvertFrom-Json
    foreach ($w in @($data.windowsState.openedWindows)) {
      if (-not $w) { continue }
      $path = $null; $kind = $null
      if ($w.folder) {
        $path = ConvertFrom-FileUri ([string]$w.folder); $kind = 'folder'
      } elseif ($w.workspaceIdentifier -and $w.workspaceIdentifier.configURIPath) {
        $path = ConvertFrom-FileUri ([string]$w.workspaceIdentifier.configURIPath); $kind = 'workspace'
      } else {
        continue   # an empty window (no folder/workspace) - nothing to reopen
      }
      if (-not $path) { continue }
      $items += [ordered]@{
        app  = $ide.app
        kind = $kind
        path = $path
        name = (Get-LeafName $path $kind)
      }
    }
  } catch {}
  return $items
}

# Collect the open windows across every known IDE, de-duplicated by app+path.
function Get-OpenWorkspaces {
  $all  = @()
  foreach ($ide in (Get-IdeDefs)) { $all += (Read-OpenWindows $ide) }
  $seen = @{}; $out = @()
  foreach ($it in $all) {
    $key = ('{0}|{1}' -f $it.app, $it.path.ToLowerInvariant())
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true; $out += $it
  }
  return @($out)
}

# Snapshot the currently open workspaces to workspaces.json. Returns the number
# saved. Guard: if no IDE window is open, change nothing and return 0 - so a stray
# click never wipes the user's favorites, and the caller can report "nothing open".
function Save-Workspaces {
  try {
    $items = Get-OpenWorkspaces
    if ($items.Count -eq 0) { return 0 }
    $obj = [ordered]@{
      saved = (Get-Date).ToString('o')
      items = @($items)
    }
    $dir = Split-Path $wsFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($wsFile, ($obj | ConvertTo-Json -Depth 5), $utf8NoBom)
    return $items.Count
  } catch { return 0 }
}

# Read the saved snapshot back as an array of item objects (empty if none).
function Read-SavedWorkspaces {
  try {
    if (-not (Test-Path $wsFile)) { return @() }
    $data = [System.IO.File]::ReadAllText($wsFile) | ConvertFrom-Json
    return @($data.items)
  } catch { return @() }
}

# Resolve the executable to relaunch a given app with.
function Resolve-IdeExe([string]$app) {
  $ide = (Get-IdeDefs) | Where-Object { $_.app -eq $app } | Select-Object -First 1
  if (-not $ide) { return $null }
  # Prefer the path of a running instance (most accurate for the user's install).
  $running = (Get-Process -Name $ide.proc -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
  if ($running) { return $running }
  foreach ($e in $ide.exes) { if ($e -and (Test-Path $e)) { return $e } }
  # Last resort for VS Code: the "code" CLI shim on PATH.
  if ($app -eq 'code') {
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

# Reopen every saved workspace. Code.exe "<path>" opens a folder window; given a
# .code-workspace file it opens that as a workspace. If the window is already
# open the IDE just focuses it, so this is safe to click repeatedly.
# With $only set, restores just the saved item whose path matches (one click =
# one workspace - used by the deck's per-workspace submenu).
function Restore-Workspaces([string]$only) {
  $items = Read-SavedWorkspaces
  $opened = 0
  foreach ($it in $items) {
    $path = [string]$it.path
    if (-not $path) { continue }
    if ($only -and -not $path.Equals($only, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path $path)) { continue }   # workspace deleted/moved since the snapshot
    $exe = Resolve-IdeExe ([string]$it.app)
    if (-not $exe) { continue }
    try { Start-Process $exe -ArgumentList ('"{0}"' -f $path) -ErrorAction SilentlyContinue; $opened++ } catch {}
  }
  return $opened
}

# --- Action block: runs only on a direct invocation, not when dot-sourced -----
# ($MyInvocation.InvocationName is '.' when the file is dot-sourced, in which
# case we just want the function definitions above made available.)
if ($MyInvocation.InvocationName -ne '.') {
  $ErrorActionPreference = 'SilentlyContinue'
  if ($Save) {
    $n = Save-Workspaces
    Write-Host ("Saved {0} workspace(s) -> {1}" -f $n, $wsFile)
  } elseif ($Restore) {
    $n = Restore-Workspaces $Only
    Write-Host ("Reopened {0} workspace(s)." -f $n)
  } else {
    # -List (default): print what is currently open and what is saved.
    Write-Host '--- Currently open ---'
    foreach ($it in (Get-OpenWorkspaces)) { Write-Host ('  [{0}] {1}  ({2})' -f $it.app, $it.name, $it.path) }
    Write-Host '--- Saved snapshot ---'
    foreach ($it in (Read-SavedWorkspaces)) { Write-Host ('  [{0}] {1}  ({2})' -f $it.app, $it.name, $it.path) }
  }
  exit 0   # only on a direct run; a bare exit here would kill the tray that dot-sources us
}
