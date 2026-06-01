# Claude Sessions — large centered overlay (4K-friendly).
# Big dark always-on-top window listing sessions. Click a row to focus its
# VS Code / Cursor window. Auto-refreshes. Press Esc (or click ✕) to close.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::SetProcessDPIAware() | Out-Null } catch {}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinFocus {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  const int SW_RESTORE = 9;
  public static bool FocusByTitle(string needle) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      string t = sb.ToString();
      bool isIde = t.IndexOf("Visual Studio Code", StringComparison.OrdinalIgnoreCase) >= 0
                || t.IndexOf("Cursor", StringComparison.OrdinalIgnoreCase) >= 0;
      if (isIde && t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return RaiseWindow(found);
  }
  // Find a top-level window whose title EXACTLY matches (returns hwnd or zero).
  public static IntPtr FindExact(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      if (string.Equals(sb.ToString(), title, StringComparison.OrdinalIgnoreCase)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static bool RaiseWindow(IntPtr found) {
    if (found == IntPtr.Zero) return false;
    if (IsIconic(found)) ShowWindow(found, SW_RESTORE);  // only un-minimize; never resize a maximized/normal window
    uint pid; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, fg, true);
    BringWindowToTop(found);
    SetForegroundWindow(found);
    AttachThreadInput(cur, fg, false);
    return true;
  }
}

// Documented virtual-desktop API (stable across Windows updates).
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
  bool IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow);
  Guid GetWindowDesktopId(IntPtr topLevelWindow);
  void MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
}

public class VDesk {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  static IVirtualDesktopManager _mgr;
  static IVirtualDesktopManager Mgr() {
    if (_mgr == null) {
      Type t = Type.GetTypeFromCLSID(new Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a"));
      _mgr = (IVirtualDesktopManager)Activator.CreateInstance(t);
    }
    return _mgr;
  }
  // Keep the window on whatever desktop the user is currently viewing: if it's
  // not on the current desktop, move it there. Makes it feel pinned to all
  // desktops, using only the documented IVirtualDesktopManager.
  public static void FollowToCurrentDesktop(IntPtr hwnd) {
    try {
      var mgr = Mgr();
      if (mgr.IsWindowOnCurrentVirtualDesktop(hwnd)) return;
      IntPtr fg = GetForegroundWindow();
      if (fg == IntPtr.Zero || fg == hwnd) return;
      Guid id = mgr.GetWindowDesktopId(fg);
      if (id == Guid.Empty) return;
      mgr.MoveWindowToDesktop(hwnd, ref id);
    } catch {}
  }
}
"@

# Single-instance: if a view window is already open, pull it onto THIS desktop
# (so it never yanks you to another desktop) and focus it, then exit.
$WindowTitle = 'Sessions Claude Code'
$existing = [WinFocus]::FindExact($WindowTitle)
if ($existing -ne [System.IntPtr]::Zero) {
  [VDesk]::FollowToCurrentDesktop($existing)
  [WinFocus]::RaiseWindow($existing)
  exit 0
}

$stateDir = Join-Path $env:USERPROFILE '.claude\sessions\state'

# --- Sizing relative to the primary screen (looks right at any resolution) ---
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formW  = [int]($screen.Width  * 0.55)
$formH  = [int]($screen.Height * 0.70)
$titlePt = [single]([math]::Max(20, $screen.Height / 60))   # ~ 24pt on 1440p, scales on 4K
$rowPt   = [single]([math]::Max(15, $screen.Height / 85))

$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rowBg  = [System.Drawing.Color]::FromArgb(36, 36, 42)
$hover  = [System.Drawing.Color]::FromArgb(52, 52, 62)
$green  = [System.Drawing.Color]::FromArgb(80, 220, 130)
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'   # pin to the PRIMARY screen (with the taskbar), not the 2nd monitor
$form.Size            = New-Object System.Drawing.Size($formW, $formH)
$formLeft = [int]($screen.X + ($screen.Width - $formW) / 2)
$form.Location        = New-Object System.Drawing.Point($formLeft, [int]($screen.Y + ($screen.Height - $formH) / 2))
$form.BackColor       = $bg
$form.TopMost         = $true
$form.ShowInTaskbar   = $true
$form.Text            = $WindowTitle
$form.KeyPreview      = $true

# Reduce flicker: enable double buffering (protected property, set via reflection).
$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
$dbProp.SetValue($form, $true, $null)

# Header
$headerH = [int]($titlePt * 2.6)
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = $headerH
$header.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Sessions Claude Code'
$title.ForeColor = $white
$title.Font = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, [int](($headerH - $title.PreferredHeight) / 2))
$header.Controls.Add($title)

# Close button (X) — top-right corner
$close = New-Object System.Windows.Forms.Label
$close.Text = [char]0x2715   # heavy multiplication X
$close.ForeColor = $grey
$close.Font = New-Object System.Drawing.Font('Segoe UI', $titlePt, [System.Drawing.FontStyle]::Bold)
$close.AutoSize = $true
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.Add_MouseEnter({ $close.ForeColor = [System.Drawing.Color]::FromArgb(240, 90, 90) })
$close.Add_MouseLeave({ $close.ForeColor = $grey })
$close.Add_Click({ $form.Close() })
$header.Controls.Add($close)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Echap pour fermer'
$hint.ForeColor = $grey
$hint.Font = New-Object System.Drawing.Font('Segoe UI', [single]($rowPt * 0.7))
$hint.AutoSize = $true
$header.Controls.Add($hint)

# Keep X and hint pinned to the right edge
$header.Add_Resize({
  $close.Location = New-Object System.Drawing.Point(($header.Width - $close.Width - 20), [int](($headerH - $close.Height) / 2))
  $hint.Location  = New-Object System.Drawing.Point(($header.Width - $close.Width - $hint.Width - 44), [int](($headerH - $hint.Height) / 2))
})

# Scrollable list
$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Dock = 'Fill'
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $bg
$listPadV = 24   # top + bottom padding
$list.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$dbProp.SetValue($list, $true, $null)   # double-buffer the list too
$form.Controls.Add($list)
$list.BringToFront()

$rowH = [int]($rowPt * 3.4)
$rowMargin = 10

function Make-Row($s, $running, $promptText, $age) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.BorderSize = 0
  $btn.FlatAppearance.MouseOverBackColor = $hover
  $btn.BackColor = $rowBg
  $btn.ForeColor = if ($running) { $green } else { $grey }
  $btn.Font = New-Object System.Drawing.Font('Segoe UI', $rowPt)
  $btn.TextAlign = 'MiddleLeft'
  $btn.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 0)
  $btn.Width  = $list.ClientSize.Width - 40
  $btn.Height = $rowH
  $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $rowMargin)
  $btn.TabStop = $false
  $dot = if ($running) { [char]0x25CF } else { [char]0x25CB }
  $sep = [char]0x2014
  $btn.Text = ('{0}   {1}    {2}    {3}    ({4})' -f $dot, $s.project, $sep, $promptText, $age)
  $proj = [string]$s.project
  $cwd  = [string]$s.cwd
  $btn.Add_Click({
    if (-not [WinFocus]::FocusByTitle($proj)) {
      # Fallback: focus/open the REAL VS Code (never Cursor).
      $codeExe = (Get-Process -Name Code -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
      if ($codeExe -and $cwd) { Start-Process $codeExe -ArgumentList ('"{0}"' -f $cwd) -ErrorAction SilentlyContinue }
    }
  }.GetNewClosure())
  return $btn
}

$script:lastSig = $null

function Refresh-List {
  $now = Get-Date
  $sessions = @()
  if (Test-Path $stateDir) {
    foreach ($f in Get-ChildItem $stateDir -Filter *.json -ErrorAction SilentlyContinue) {
      try { $s = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
      try { $upd = [datetime]$s.updated } catch { $upd = $f.LastWriteTime }
      if (($now - $upd).TotalHours -gt 24) { continue }
      $sessions += [pscustomobject]@{ s = $s; upd = $upd }
    }
  }
  $sessions = @($sessions | Sort-Object { $_.upd } -Descending)

  # Build display rows
  $rows = @()
  foreach ($e in $sessions) {
    $s = $e.s
    $running = ($s.status -eq 'running')
    $p = [string]$s.last_prompt
    if (-not $p) { $p = '(pas de demande)' }
    if ($p.Length -gt 90) { $p = $p.Substring(0, 90) + [char]0x2026 }
    $mins = [int]($now - $e.upd).TotalMinutes
    $age = if ($mins -lt 1) { 'maintenant' } elseif ($mins -lt 60) { "${mins}m" } else { "$([int]($mins / 60))h" }
    $rows += [pscustomobject]@{ s = $s; running = $running; p = $p; age = $age }
  }

  # Anti-flicker: only rebuild when the displayed content actually changed.
  $sig = ($rows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.s.project, $_.running, $_.p, $_.age }) -join "`n"
  if ($sig -eq $script:lastSig) { return }
  $script:lastSig = $sig

  $list.SuspendLayout()
  $list.Controls.Clear()
  if ($rows.Count -eq 0) {
    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = 'Aucune session active'
    $empty.ForeColor = $grey
    $empty.Font = New-Object System.Drawing.Font('Segoe UI', $rowPt)
    $empty.AutoSize = $true
    $list.Controls.Add($empty)
  } else {
    foreach ($r in $rows) { $list.Controls.Add((Make-Row $r.s $r.running $r.p $r.age)) }
  }
  $list.ResumeLayout()

  # Auto-fit the window height to the number of rows (no big empty area).
  $count   = [math]::Max(1, $rows.Count)
  $desired = $headerH + $listPadV + ($count * ($rowH + $rowMargin)) + 6
  $maxH    = [int]($screen.Height * 0.9)
  $minH    = $headerH + $listPadV + ($rowH + $rowMargin) + 6
  $newH    = [math]::Min($maxH, [math]::Max($minH, $desired))
  if ($form.Height -ne $newH -or $form.Left -ne $formLeft) {
    $form.Height = $newH
    $form.Left   = $formLeft   # keep it on the primary screen, horizontally centered
    $form.Top    = [int]($screen.Y + ($screen.Height - $newH) / 2)
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Refresh-List })
$timer.Start()

# Follow the user across virtual desktops (feels pinned to all desktops).
$followTimer = New-Object System.Windows.Forms.Timer
$followTimer.Interval = 350
$followTimer.Add_Tick({ try { [VDesk]::FollowToCurrentDesktop($form.Handle) } catch {} })
$followTimer.Start()

$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
$form.Add_Shown({ Refresh-List })
$form.Add_FormClosed({ $timer.Stop(); $followTimer.Stop() })

[void]$form.ShowDialog()
