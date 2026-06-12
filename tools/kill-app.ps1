# Dev helper: stop every running ClaudeDeck UI process (tray, large view, stats).
# Needed before relaunching/redeploying - the single-instance guard otherwise
# makes a fresh process exit 0. Run via:  powershell -File ./tools/kill-app.ps1
$ErrorActionPreference = 'SilentlyContinue'
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
  $cl = $_.CommandLine
  if ($cl -like '*session-tray.ps1*' -or $cl -like '*session-view.ps1*' -or $cl -like '*session-stats.ps1*') {
    Stop-Process -Id $_.ProcessId -Force
    $killed++
  }
}
Write-Host ("Stopped {0} ClaudeDeck process(es)." -f $killed)
