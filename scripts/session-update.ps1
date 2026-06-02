# ClaudeDeck self-updater (optional) — checks the GitHub repo for a newer version.
#   -Check : compare the installed version with the repo's scripts/version.txt
#            and flag an update whenever they DIFFER (the published version is
#            canonical). Writes the result to update.json (read by the desk/tray).
#            Never throws.
#   -Apply : download the latest ClaudeDeck-Setup.cmd from the repo and run it
#            (the installer reinstalls the scripts, merges hooks, and restarts
#            the tray — it is idempotent and non-destructive).
param([switch]$Check, [switch]$Apply)

$ErrorActionPreference = 'SilentlyContinue'

# --- Repo configuration (change these if you fork the project) --------------
$Owner  = 'hydropix'
$Repo   = 'claude-deck'
$Branch = 'main'
$RawBase     = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
$VersionUrl  = "$RawBase/scripts/version.txt"
$InstallerUrl = "$RawBase/ClaudeDeck-Setup.cmd"

$dir       = Join-Path $env:USERPROFILE '.claude\sessions'
$verFile   = Join-Path $dir 'version.txt'
$infoFile  = Join-Path $dir 'update.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Get-LocalVersion {
  try { if (Test-Path $verFile) { return ([System.IO.File]::ReadAllText($verFile)).Trim() } } catch {}
  return '0.0.0'
}

# Returns 1 if $a > $b, -1 if $a < $b, 0 if equal (numeric, dotted semver).
function Compare-Version($a, $b) {
  $pa = @(($a -split '\.') | ForEach-Object { [int]($_ -replace '\D', '0') })
  $pb = @(($b -split '\.') | ForEach-Object { [int]($_ -replace '\D', '0') })
  $n = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
    $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
    if ($x -gt $y) { return 1 }
    if ($x -lt $y) { return -1 }
  }
  return 0
}

function Save-Info($obj) {
  try { [System.IO.File]::WriteAllText($infoFile, ($obj | ConvertTo-Json -Depth 4), $utf8NoBom) } catch {}
}

if ($Check) {
  $local = Get-LocalVersion
  $latest = $null
  try {
    # Cache-buster: raw.githubusercontent is served via a CDN with a short TTL.
    $url = $VersionUrl + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -Headers @{ 'Cache-Control' = 'no-cache' }
    $latest = ([string]$resp.Content).Trim()
  } catch {}

  # Reject an empty body or anything that isn't a dotted-numeric version (e.g. a
  # CDN error page served as HTML) so we never offer a bogus "update".
  if (-not $latest -or ($latest -notmatch '^\d+(\.\d+){0,3}$')) {
    Save-Info ([ordered]@{ current = $local; latest = $null; available = $false; error = 'fetch-failed'; checked = (Get-Date).ToString('o') })
    exit 0
  }
  # GitHub is the single source of truth and the only distribution channel, so the
  # published version is canonical. Offer the update whenever it DIFFERS from the
  # installed one - not only when it is strictly greater. This keeps self-update
  # working even when the local version.txt is missing, corrupted, or somehow ahead
  # of the release (e.g. a stray "1.0.0" that would otherwise block every update).
  $available = ((Compare-Version $latest $local) -ne 0)
  Save-Info ([ordered]@{ current = $local; latest = $latest; available = $available; checked = (Get-Date).ToString('o') })
  exit 0
}

if ($Apply) {
  $tmp = Join-Path $env:TEMP 'ClaudeDeck-Setup.cmd'
  try {
    $url = $InstallerUrl + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -Headers @{ 'Cache-Control' = 'no-cache' }
  } catch {
    exit 1
  }
  if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1024) { exit 1 }
  # Clear the "update available" marker; the installer writes the fresh version.txt.
  Remove-Item $infoFile -Force -ErrorAction SilentlyContinue
  # Run the installer (reinstalls scripts, merges hooks, restarts the tray).
  Start-Process -FilePath $tmp -ErrorAction SilentlyContinue
  exit 0
}

exit 0
