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
