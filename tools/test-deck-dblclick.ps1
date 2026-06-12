# Repro harness: does double-click still expand the collapsed deck after the gear
# menu has been opened? Drives the REAL UI with injected mouse input (the cursor
# will move for a few seconds). The deck refreshes/repositions every 2s, so every
# click re-reads the target's live rect and state changes are retried.
param([string]$ViewPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class TestInput {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(int flags, int dx, int dy, int data, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public const int DOWN = 0x02, UP = 0x04;
  public static void Click(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(60);
    mouse_event(DOWN, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40);
    mouse_event(UP, 0, 0, 0, IntPtr.Zero);
  }
  public static void DblClick(int x, int y) {
    Click(x, y); System.Threading.Thread.Sleep(110); Click(x, y);
  }
}
"@

function Stop-Deck {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like '*session-tray.ps1*' -or $_.CommandLine -like '*session-view.ps1*' -or $_.CommandLine -like '*session-stats.ps1*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# --- launch ------------------------------------------------------------------
Stop-Deck
$repo = Split-Path $PSScriptRoot -Parent
if (-not $ViewPath) { $ViewPath = Join-Path $repo 'scripts\session-view.ps1' }
$p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$ViewPath -PassThru -WindowStyle Hidden

$root = $null
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 500
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
  $root = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
  if ($root) { break }
}
if (-not $root) { Write-Host 'FAIL: deck window never appeared'; exit 1 }
$hwnd = [IntPtr]$root.Current.NativeWindowHandle
Start-Sleep -Seconds 3   # let the first refresh settle size/position

function Get-FormHeight {
  $r = New-Object TestInput+RECT
  [void][TestInput]::GetWindowRect($hwnd, [ref]$r)
  return ($r.B - $r.T)
}
function Find-Lbl([string]$name) {
  $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
  for ($t = 0; $t -lt 6; $t++) {
    $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if ($el) { return $el }
    Start-Sleep -Milliseconds 500
  }
  return $null
}
# Double-click the title and wait for the height to change in the wanted direction.
# Re-reads the live rect each attempt (the deck repositions itself on refresh).
function Toggle-Deck([bool]$wantCollapsed, [int]$tries = 3) {
  for ($a = 0; $a -lt $tries; $a++) {
    $el = Find-Lbl 'Claude Code Sessions'
    if (-not $el) { Start-Sleep -Milliseconds 500; continue }
    $b = $el.Current.BoundingRectangle
    [TestInput]::DblClick([int]($b.X + $b.Width / 2), [int]($b.Y + $b.Height / 2))
    Start-Sleep -Milliseconds 900
    $h = Get-FormHeight
    $collapsed = ($h -le 80)
    if ($collapsed -eq $wantCollapsed) { return $true }
  }
  return $false
}

$fail = 0
Write-Host ("initial height: {0}px" -f (Get-FormHeight))

if (Toggle-Deck $true)  { Write-Host ("PASS: dblclick collapsed the deck ({0}px)" -f (Get-FormHeight)) }
else { Write-Host 'FAIL: dblclick did not collapse'; $fail++ }

if (Toggle-Deck $false) { Write-Host ("PASS: dblclick expanded the deck ({0}px)" -f (Get-FormHeight)) }
else { Write-Host 'FAIL: baseline dblclick expand broken'; $fail++ }

if (-not (Toggle-Deck $true)) { Write-Host 'FAIL: could not re-collapse for the menu step'; $fail++ }

# Open the gear menu on the collapsed strip.
$gear = Find-Lbl ([string][char]0xE8B8)   # MAT.settings glyph
if (-not $gear) { Write-Host 'FAIL: gear label not found via UIA'; Stop-Deck; exit 1 }
$g = $gear.Current.BoundingRectangle
[TestInput]::Click([int]($g.X + $g.Width / 2), [int]($g.Y + $g.Height / 2))
Start-Sleep -Milliseconds 1200
Write-Host 'gear menu opened'

# The repro: try to expand by double-click after the menu. Three attempts — the
# first click of attempt #1 legitimately dismisses the menu; attempts #2-3 tell
# us whether the breakage is persistent.
if (Toggle-Deck $false 3) { Write-Host 'PASS: dblclick after the gear menu expanded the deck' }
else {
  Write-Host 'REPRO: dblclick is dead after the gear menu (3 attempts) -> PERSISTENT'; $fail++
  # Do SINGLE clicks still arrive? Click the expand (v) button.
  $exp = Find-Lbl ([string][char]0xE5CF)   # MAT.expand glyph (shown while collapsed)
  if ($exp) {
    $x = $exp.Current.BoundingRectangle
    [TestInput]::Click([int]($x.X + $x.Width / 2), [int]($x.Y + $x.Height / 2))
    Start-Sleep -Milliseconds 900
    if ((Get-FormHeight) -gt 80) { Write-Host 'INFO: single click on the expand button STILL WORKS -> only dblclick coalescing broke' }
    else { Write-Host 'INFO: single click on the expand button is ALSO dead -> all mouse input eaten' }
  } else { Write-Host 'INFO: expand button not found via UIA' }
}

Stop-Deck
if ($fail) { Write-Host ("--- {0} FAILURE(S) ---" -f $fail); exit 1 }
Write-Host '--- DONE ---'
exit 0
