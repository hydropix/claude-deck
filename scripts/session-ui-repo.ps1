# ClaudeDeck - repository / terminal helpers for the deck's row context menu
# (dot-sourced by session-view.ps1). Self-contained: no dependency on deck state.
#
# Resolves a session's working directory to its git remote web URL and the
# host-aware deep links (issues / PRs / CI) shown when you right-click a row, plus
# a small "open a terminal here" helper.

# Resolve a session's git remote to a browsable web URL (or $null). We read
# .git/config directly rather than spawning git.exe - no console flash, no PATH
# dependency - walking up from the session's cwd so a sub-directory still resolves,
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
# unknown forge - the menu then shows only the repo home entry.
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

# Resolve the VS Code / Cursor executable so we can open a workspace even when NO
# editor is currently running (the row click's "focus an open window" path having
# missed). Preference order: a running editor (so we reuse whatever the user has
# open), then the `code` / `cursor` CLI shim on PATH (bin\code.cmd sits next to
# ..\Code.exe), then the known per-user / machine-wide install locations. $null if
# nothing is found.
function Resolve-IdeExe {
  foreach ($name in 'Code', 'Cursor') {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }
  }
  foreach ($cli in @(@{ cmd = 'code'; exe = 'Code.exe' }, @{ cmd = 'cursor'; exe = 'Cursor.exe' })) {
    $cmd = Get-Command $cli.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
      $exe = Join-Path (Split-Path (Split-Path $cmd.Source -Parent) -Parent) $cli.exe
      if (Test-Path -LiteralPath $exe) { return $exe }
    }
  }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
    (Join-Path $env:ProgramFiles  'Microsoft VS Code\Code.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

# Open a session's workspace folder in VS Code / Cursor. Used as the row click's
# fallback when no editor window matched the project: launches a new window (or
# reuses an existing one for that folder if the editor is already running). Returns
# $true when an editor was launched.
function Open-Workspace([string]$cwd) {
  if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) { return $false }
  $exe = Resolve-IdeExe
  if (-not $exe) { return $false }
  try { Start-Process $exe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction Stop; return $true }
  catch { return $false }
}
