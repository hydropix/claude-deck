# Sanity-check that ClaudeDeck-Setup.cmd embeds each scripts/* file byte-for-byte.
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$marker = '#@CDINSTALLER@#'
$c      = [IO.File]::ReadAllText((Join-Path $root 'ClaudeDeck-Setup.cmd'))
$inst   = $c.Substring($c.LastIndexOf($marker) + $marker.Length)
$ok = $true
Get-ChildItem (Join-Path $root 'scripts') -File | ForEach-Object {
  $orig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
  $rx   = "(?m)^\s*'" + [regex]::Escape($_.Name) + "'\s*=\s*'([A-Za-z0-9+/=]+)'"
  $m    = [regex]::Match($inst, $rx)
  if (-not $m.Success)              { Write-Host "MISSING  $($_.Name)"  -ForegroundColor Red;   $ok = $false; return }
  if ($m.Groups[1].Value -eq $orig) { Write-Host "OK       $($_.Name)"  -ForegroundColor Green }
  else                              { Write-Host "MISMATCH $($_.Name)"  -ForegroundColor Red;   $ok = $false }
}
Write-Host ("--- {0} ---" -f $(if ($ok) { 'ALL MATCH' } else { 'PROBLEM' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
if (-not $ok) { exit 1 }
