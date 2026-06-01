# ClaudeDeck uninstaller (Windows).
# Stops the apps, removes shortcuts and scripts, and strips ClaudeDeck's hooks
# from settings.json (leaving your other hooks intact).
$ErrorActionPreference = 'Stop'

$dest     = Join-Path $env:USERPROFILE '.claude\sessions'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'

Write-Host 'ClaudeDeck - uninstall...' -ForegroundColor Cyan

# --- 1) Stop running apps --------------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*session-tray.ps1*' -or $_.CommandLine -like '*session-view.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- 2) Remove shortcuts ---------------------------------------------------
$startup = [Environment]::GetFolderPath('Startup')
$desktop = [Environment]::GetFolderPath('Desktop')
Remove-Item (Join-Path $startup 'ClaudeDeck Tray.lnk')    -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $desktop 'ClaudeDeck (grand).lnk') -Force -ErrorAction SilentlyContinue

# --- 3) Strip ClaudeDeck hooks from settings.json --------------------------
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

$markers = @('session-tracker.ps1', 'show-view.vbs')

if (Test-Path $settings) {
  Copy-Item $settings "$settings.bak" -Force
  $cfg = ConvertTo-HashtableDeep ([System.IO.File]::ReadAllText($settings) | ConvertFrom-Json)
  if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('hooks') -and $cfg['hooks'] -is [System.Collections.IDictionary]) {
    $hooks = $cfg['hooks']
    foreach ($evt in @($hooks.Keys)) {
      $kept = @()
      foreach ($grp in @($hooks[$evt])) {
        $isOurs = $false
        if ($grp -and $grp.Contains('hooks')) {
          foreach ($hk in @($grp['hooks'])) {
            if ($hk -and $hk['command']) {
              foreach ($m in $markers) { if ($hk['command'] -like "*$m*") { $isOurs = $true } }
            }
          }
        }
        if (-not $isOurs) {
          # PS 5.1 ConvertFrom-Json unwraps single-element arrays; force the
          # preserved group's inner 'hooks' back into a real array so we don't
          # corrupt the user's other hooks on write.
          if ($grp -is [System.Collections.IDictionary] -and $grp.Contains('hooks')) { $grp['hooks'] = @($grp['hooks']) }
          $kept += $grp
        }
      }
      if ($kept.Count -gt 0) { $hooks[$evt] = $kept } else { $hooks.Remove($evt) }
    }
    $cfg['hooks'] = $hooks
    $json = $cfg | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  Hooks cleaned in $settings (backup: settings.json.bak)"
  }
}

# --- 4) Remove scripts -----------------------------------------------------
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Done. ClaudeDeck removed.' -ForegroundColor Green
