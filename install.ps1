# ClaudeDeck installer (Windows).
# Copies the scripts, merges the required Claude Code hooks into settings.json
# (idempotent, non-destructive), creates shortcuts, and starts the tray.
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$src      = Join-Path $ScriptRoot 'scripts'
$dest     = Join-Path $env:USERPROFILE '.claude\sessions'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'

Write-Host 'ClaudeDeck - installation...' -ForegroundColor Cyan

# --- 0) Stop running ClaudeDeck processes ----------------------------------
# The deck loads logo.ico + MaterialIcons-Regular.ttf and holds them open, so a
# copy/update while it (or the tray/recap/stats) is running would fail to
# overwrite those files - and PS aborts the whole copy on the first locked file,
# half-applying the update. Stop them all first; the tray is restarted in step 4.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object {
    $_.CommandLine -like '*session-tray.ps1*'  -or $_.CommandLine -like '*session-view.ps1*' -or
    $_.CommandLine -like '*session-recap.ps1*' -or $_.CommandLine -like '*session-stats.ps1*'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 700   # let the font/icon handles release before we copy

# --- 1) Copy scripts -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Get-ChildItem $src -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force }
Write-Host "  Scripts -> $dest"

# --- 2) Merge hooks into settings.json -------------------------------------
function ConvertTo-HashtableDeep($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [string]) { return $o }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    return $h
  }
  if ($o -is [System.Collections.IEnumerable]) {
    return @($o | ForEach-Object { ConvertTo-HashtableDeep $_ })
  }
  return $o
}

function Add-Hook($hooks, $evt, $command, $marker) {
  if (-not $hooks.Contains($evt) -or $null -eq $hooks[$evt]) { $hooks[$evt] = @() }
  $arr = @($hooks[$evt])
  foreach ($grp in $arr) {
    if ($grp -and $grp.Contains('hooks')) {
      foreach ($hk in @($grp['hooks'])) {
        if ($hk -and $hk['command'] -and ($hk['command'] -like "*$marker*")) { return }  # already installed
      }
    }
  }
  $arr += [ordered]@{ hooks = @([ordered]@{ type = 'command'; shell = 'powershell'; command = $command }) }
  $hooks[$evt] = $arr
}

if (Test-Path $settings) {
  Copy-Item $settings "$settings.bak" -Force
  $raw = [System.IO.File]::ReadAllText($settings)   # UTF-8 (Get-Content -Raw would mangle accents on PS 5.1)
  $obj = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }
} else {
  $obj = [pscustomobject]@{}
}
$cfg = ConvertTo-HashtableDeep $obj
if ($cfg -isnot [System.Collections.IDictionary]) { $cfg = [ordered]@{} }
if (-not $cfg.Contains('hooks') -or $cfg['hooks'] -isnot [System.Collections.IDictionary]) { $cfg['hooks'] = [ordered]@{} }
$hooks = $cfg['hooks']

$trackerPrompt = '& "$env:USERPROFILE\.claude\sessions\session-tracker.ps1" -Event prompt'
$trackerStop   = '& "$env:USERPROFILE\.claude\sessions\session-tracker.ps1" -Event stop'
$trackerEnd    = '& "$env:USERPROFILE\.claude\sessions\session-tracker.ps1" -Event end'
$trackerNotify = '& "$env:USERPROFILE\.claude\sessions\session-tracker.ps1" -Event notify'
# The large view auto-opens on Stop, unless "Do not disturb" (dnd.flag) is set.
$viewStop = (@'
if (-not (Test-Path "$env:USERPROFILE\.claude\sessions\dnd.flag")) { Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $env:USERPROFILE '.claude\sessions\show-view.vbs') + '"') }
'@).Trim()

Add-Hook $hooks 'UserPromptSubmit' $trackerPrompt '-Event prompt'
Add-Hook $hooks 'Notification'     $trackerNotify '-Event notify'
Add-Hook $hooks 'Stop'             $trackerStop   '-Event stop'
Add-Hook $hooks 'Stop'             $viewStop      'show-view.vbs'
Add-Hook $hooks 'SessionEnd'       $trackerEnd    '-Event end'

# Normalize: PS 5.1 ConvertFrom-Json unwraps single-element arrays into bare
# objects, so re-running the installer would otherwise serialize hooks as
# objects and break Claude Code ("Expected array, but received object"). Force
# every event value and its inner 'hooks' back into real arrays before writing.
foreach ($evt in @($hooks.Keys)) {
  $grps = @($hooks[$evt])
  foreach ($g in $grps) {
    if ($g -is [System.Collections.IDictionary] -and $g.Contains('hooks')) { $g['hooks'] = @($g['hooks']) }
  }
  $hooks[$evt] = $grps
}

$cfg['hooks'] = $hooks

# Silence Claude Code's built-in notification sound so ClaudeDeck's own chime
# (played by session-tracker.ps1 on a genuine waiting state) is the single audible
# cue. Only set when absent, so a user's explicit choice is never overridden.
if (-not $cfg.Contains('preferredNotifChannel') -or -not $cfg['preferredNotifChannel']) {
  $cfg['preferredNotifChannel'] = 'notifications_disabled'
  Write-Host '  Native notification sound disabled (preferredNotifChannel)'
}

$json = $cfg | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  Hooks merged into $settings (backup: settings.json.bak)"

# --- 2b) Seed / top up .env (user-editable LLM / recap settings) -----------
# Create .env from .env.example ONCE; never overwrite an existing .env so the
# user's edits (e.g. their server URL / API key) survive updates. When .env
# already exists, TOP IT UP with any keys the template gained since (e.g. a new
# provider option) - appended with their example values, existing values are
# never touched - so new settings stay discoverable after an update.
$envFile     = Join-Path $dest '.env'
$envTemplate = Join-Path $dest '.env.example'
function Get-EnvKeys($path) {
  $keys = @{}
  if (Test-Path $path) {
    foreach ($l in [System.IO.File]::ReadAllLines($path)) {
      $t = $l.Trim()
      if ($t -and -not $t.StartsWith('#')) { $k = ($t -split '=', 2)[0].Trim(); if ($k) { $keys[$k] = $true } }
    }
  }
  return $keys
}
if (Test-Path $envTemplate) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  if (-not (Test-Path $envFile)) {
    Copy-Item $envTemplate $envFile -Force
    Write-Host "  .env created from .env.example (edit it to set your LLM provider / server)"
  } else {
    $have = Get-EnvKeys $envFile
    $missing = @()
    foreach ($l in [System.IO.File]::ReadAllLines($envTemplate)) {
      $t = $l.Trim()
      if ($t -and -not $t.StartsWith('#')) {
        $k = ($t -split '=', 2)[0].Trim()
        if ($k -and -not $have.ContainsKey($k)) { $missing += $l }
      }
    }
    if ($missing.Count -gt 0) {
      $block = "`r`n# --- new settings added by the ClaudeDeck updater (see .env.example for docs) ---`r`n" + ($missing -join "`r`n") + "`r`n"
      [System.IO.File]::AppendAllText($envFile, $block, $utf8NoBom)
      Write-Host ("  .env topped up with {0} new setting(s)" -f $missing.Count)
    }
  }
}

# --- 3) Shortcuts ----------------------------------------------------------
$ws = New-Object -ComObject WScript.Shell
$icon = Join-Path $dest 'logo.ico'   # deployed alongside the scripts in step 1

$startup = [Environment]::GetFolderPath('Startup')
$lnk = $ws.CreateShortcut((Join-Path $startup 'ClaudeDeck Tray.lnk'))
$lnk.TargetPath       = 'wscript.exe'
$lnk.Arguments        = '"' + (Join-Path $dest 'start-tray.vbs') + '"'
$lnk.WorkingDirectory = $dest
if (Test-Path $icon) { $lnk.IconLocation = $icon }
$lnk.Description       = 'ClaudeDeck tray'
$lnk.Save()

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk2 = $ws.CreateShortcut((Join-Path $desktop 'ClaudeDeck (Large).lnk'))
$lnk2.TargetPath       = 'wscript.exe'
$lnk2.Arguments        = '"' + (Join-Path $dest 'show-view.vbs') + '"'
$lnk2.WorkingDirectory = $dest
$lnk2.IconLocation     = if (Test-Path $icon) { $icon } else { 'imageres.dll,109' }
$lnk2.Description       = 'ClaudeDeck - large view'
$lnk2.Save()
Write-Host '  Startup + desktop shortcuts created'

# --- 4) (Re)start the tray -------------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*session-tray.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dest 'start-tray.vbs') + '"')

Write-Host ''
Write-Host 'Done. The tray icon is running (look under the ^ hidden-icons area on Windows 11).' -ForegroundColor Green
Write-Host 'Open a new Claude Code session (or send a prompt) to populate the deck.' -ForegroundColor Green
