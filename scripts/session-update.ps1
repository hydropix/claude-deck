# ClaudeDeck self-updater (optional).
#
# Single distribution channel: GitHub *Releases*. The latest release's tag is the
# canonical version and its attached ClaudeDeck-Setup.cmd asset is the payload.
# Using the Releases API (not raw/main) means the updater only ever sees what was
# explicitly published - a push to main without a release can never serve stale bits.
#
#   -Check  : query releases/latest, compare its tag with the installed version
#             (STRICTLY greater => an update is offered) and write update.json.
#   -Apply  : download the release's installer to TEMP, copy THIS script out of the
#             install dir, and launch it in -Bootstrap mode (detached + hidden).
#             Returns immediately so the UI never blocks.
#   -Bootstrap (internal): the detached worker. Waits for every ClaudeDeck process
#             to exit (so no file handle blocks the copy - the real failure mode of
#             the old design), runs the installer silently, writes update-result.json
#             (read by the restarted tray to confirm success/failure), restarts the
#             tray if the install failed, and cleans up.
#
# Never throws into the UI. Every path ends in exit 0/1 and swallows its errors.
param(
  [switch]$Check,
  [switch]$Apply,
  [switch]$Bootstrap,
  [string]$Staged,
  [string]$Version
)

$ErrorActionPreference = 'SilentlyContinue'

# --- Repo configuration (change these if you fork the project) --------------
$Owner  = 'hydropix'
$Repo   = 'claude-deck'
$ApiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
$AssetName = 'ClaudeDeck-Setup.cmd'
$Marker = '#@CDINSTALLER@#'   # must match tools/build-setup.ps1

$dir        = Join-Path $env:USERPROFILE '.claude\sessions'
$verFile    = Join-Path $dir 'version.txt'
$infoFile   = Join-Path $dir 'update.json'
$resultFile = Join-Path $dir 'update-result.json'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

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

function Save-Result([bool]$ok, [string]$ver, [string]$err) {
  try {
    $o = [ordered]@{ ok = $ok; version = $ver; error = $err; ts = (Get-Date).ToString('o') }
    [System.IO.File]::WriteAllText($resultFile, ($o | ConvertTo-Json -Depth 4), $utf8NoBom)
  } catch {}
}

# Query releases/latest -> { version, assetUrl, notes } (or $null on any failure).
# GitHub's API rejects requests without a User-Agent, so always send one.
function Get-LatestRelease {
  try {
    $resp = Invoke-WebRequest -Uri $ApiUrl -UseBasicParsing -TimeoutSec 15 -Headers @{
      'User-Agent' = 'ClaudeDeck-Updater'
      'Accept'     = 'application/vnd.github+json'
    }
    $j = ([string]$resp.Content) | ConvertFrom-Json
    $ver = ([string]$j.tag_name -replace '^[vV]', '').Trim()
    # Reject anything that isn't a dotted-numeric version (e.g. a draft / odd tag).
    if (-not ($ver -match '^\d+(\.\d+){0,3}$')) { return $null }
    $assetUrl = $null
    foreach ($a in @($j.assets)) {
      if ($a.name -eq $AssetName) { $assetUrl = [string]$a.browser_download_url; break }
    }
    return [pscustomobject]@{ version = $ver; assetUrl = $assetUrl; notes = [string]$j.body }
  } catch { return $null }
}

# --- -Check -----------------------------------------------------------------
if ($Check) {
  $local = Get-LocalVersion
  $rel = Get-LatestRelease
  if (-not $rel) {
    Save-Info ([ordered]@{ current = $local; latest = $null; available = $false; assetUrl = $null; error = 'fetch-failed'; checked = (Get-Date).ToString('o') })
    exit 0
  }
  # Offer the update only when the published release is STRICTLY newer than the
  # installed version AND ships an installable asset. Strict '>' means a local dev
  # build that's ahead of the latest release never nags.
  $available = ((Compare-Version $rel.version $local) -gt 0) -and [bool]$rel.assetUrl
  Save-Info ([ordered]@{
    current   = $local
    latest    = $rel.version
    available = $available
    assetUrl  = $rel.assetUrl
    notes     = $rel.notes
    checked   = (Get-Date).ToString('o')
  })
  exit 0
}

# --- -Apply -----------------------------------------------------------------
if ($Apply) {
  # Resolve the asset URL + version: prefer the cached update.json (written by the
  # last -Check), fall back to a fresh API call so "Install" works even if the
  # cache is missing or stale.
  $assetUrl = $null; $ver = $null
  try {
    if (Test-Path $infoFile) {
      $j = [System.IO.File]::ReadAllText($infoFile) | ConvertFrom-Json
      $assetUrl = [string]$j.assetUrl; $ver = [string]$j.latest
    }
  } catch {}
  if (-not $assetUrl) {
    $rel = Get-LatestRelease
    if ($rel) { $assetUrl = $rel.assetUrl; $ver = $rel.version }
  }
  if (-not $assetUrl) { Save-Result $false $ver 'no-asset-url'; exit 1 }

  # Download the release installer to a staging path and sanity-check its size.
  $staged = Join-Path $env:TEMP 'ClaudeDeck-Setup.cmd'
  try {
    Invoke-WebRequest -Uri $assetUrl -UseBasicParsing -TimeoutSec 120 -OutFile $staged -Headers @{ 'User-Agent' = 'ClaudeDeck-Updater' }
  } catch { Save-Result $false $ver 'download-failed'; exit 1 }
  if (-not (Test-Path $staged) -or (Get-Item $staged).Length -lt 102400) { Save-Result $false $ver 'download-too-small'; exit 1 }

  # Copy THIS script out of the install dir: the installer is about to overwrite
  # everything under ~/.claude/sessions, so the worker must run from elsewhere.
  $boot = Join-Path $env:TEMP 'cd-bootstrap.ps1'
  try { Copy-Item $PSCommandPath $boot -Force } catch { Save-Result $false $ver 'bootstrap-copy-failed'; exit 1 }

  # Clear stale markers (the installer writes a fresh version.txt; the bootstrapper
  # writes a fresh update-result.json).
  Remove-Item $infoFile -Force -ErrorAction SilentlyContinue
  Remove-Item $resultFile -Force -ErrorAction SilentlyContinue

  # Launch the worker fully detached + hidden, then return immediately.
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $boot),
    '-Bootstrap', '-Staged', ('"{0}"' -f $staged), '-Version', ('"{0}"' -f $ver)
  ) -ErrorAction SilentlyContinue
  exit 0
}

# --- -Bootstrap (internal worker) -------------------------------------------
if ($Bootstrap) {
  $procNames = @('session-tray.ps1', 'session-view.ps1', 'session-recap.ps1', 'session-stats.ps1')

  function Get-DeckProcs {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $cl = $_.CommandLine; $cl -and ($procNames | Where-Object { $cl -like "*$_*" }) }
  }
  function Stop-Deck { Get-DeckProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }

  # 1) Stop the app and WAIT until it's truly gone. The deck holds logo.ico and the
  #    Material icon font open; the old design just slept 700ms and would half-apply
  #    the update if a handle was still held. Poll up to ~10s, then a grace pause so
  #    the file handles fully release before the installer writes over them.
  Stop-Deck
  for ($i = 0; $i -lt 40 -and (@(Get-DeckProcs).Count -gt 0); $i++) { Start-Sleep -Milliseconds 250; Stop-Deck }
  Start-Sleep -Milliseconds 800

  # 2) Extract the silent installer: the .cmd is a batch+PowerShell polyglot whose
  #    PS payload sits after the last marker. We run that payload directly with
  #    powershell, so there's no console window and no trailing 'pause' to hang on.
  $ok = $false; $err = $null
  try {
    $c = [System.IO.File]::ReadAllText($Staged)
    $idx = $c.LastIndexOf($Marker)
    if ($idx -lt 0) { throw 'marker-not-found' }
    $payload = $c.Substring($idx + $Marker.Length)
    $instPs = Join-Path $env:TEMP 'cd-install.ps1'
    [System.IO.File]::WriteAllText($instPs, $payload, $utf8NoBom)
    # IMPORTANT: do NOT use Start-Process -Wait here. The installer's last step
    # relaunches the tray (a forever-running process), and -Wait blocks on the whole
    # child tree - so it would never return. Capture the process with -PassThru and
    # wait on THAT process only (its detached tray/wscript children don't count).
    $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $instPs)
    )
    if ($p.WaitForExit(180000)) {
      $ok = ($p.ExitCode -eq 0)
      if (-not $ok) { $err = "installer-exit-$($p.ExitCode)" }
    } else {
      $err = 'installer-timeout'
    }
  } catch { $ok = $false; $err = "$_" }

  # 3) Record the outcome for the (restarted) tray to surface as a balloon.
  Save-Result $ok $Version $err

  # 4) On success the installer restarts the tray itself. On failure it may not have
  #    reached that step, so bring the tray back so the user is never left without it.
  if (-not $ok) {
    $trayVbs = Join-Path $dir 'start-tray.vbs'
    if (Test-Path $trayVbs) { Start-Process wscript.exe -ArgumentList ('"{0}"' -f $trayVbs) -ErrorAction SilentlyContinue }
  }

  # 5) Cleanup.
  Remove-Item $Staged -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $env:TEMP 'cd-install.ps1') -Force -ErrorAction SilentlyContinue
  exit 0
}

exit 0
