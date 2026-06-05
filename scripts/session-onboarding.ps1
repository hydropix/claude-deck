# ClaudeDeck - first-run setup panel.
#
# A single dark panel (no wizard steps) that lets a new user configure the things
# that can't be auto-detected: the weekly-recap LLM, an optional cloud-sync folder,
# automatic updates, and the focus-nudge / Do-Not-Disturb behaviour. The tray opens
# it ONCE on first launch (gated by onboarding-done.flag) and exposes it again from
# both the tray menu and the deck's gear menu.
#
# It only WRITES the same files the rest of the deck already reads - .env (LLM),
# sync.txt (Set-CDSyncDir), autoupdate.flag, focus-off.flag, dnd.flag - so it adds
# no new state of its own beyond onboarding-done.flag (the "shown once" marker).
#
# Dot-sources session-common.ps1 for every helper (paths, UTF-8 writes, the cloud
# sync setter, the .env reader, the brand accent). Unlike the deck this is a normal
# focusable Form (the user is typing into it), so it does NOT use the NoActivateForm
# interop type.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::SetProcessDPIAware() | Out-Null } catch {}

. (Join-Path $PSScriptRoot 'session-common.ps1')

# Single-instance: if a setup panel is already open, surface nothing fancy - just exit.
$mutexCreated = $false
$script:onbMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeDeckOnboarding', [ref]$mutexCreated)
if (-not $mutexCreated) { exit 0 }

# --- Palette (mirrors the deck so the two surfaces feel like one app) -------
$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rowBg  = [System.Drawing.Color]::FromArgb(36, 36, 42)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$green  = [System.Drawing.Color]::FromArgb(80, 220, 130)
$red    = [System.Drawing.Color]::FromArgb(225, 110, 95)
$accent = Get-CDAccent
$accentText = Get-TextOn $accent

$iconPath = Join-Path $PSScriptRoot 'logo.ico'

# --- Settings file paths (resolved once) ------------------------------------
$autoUpdFlag  = Get-CDPath 'autoupdate.flag'
$focusOffFlag = Get-CDPath 'focus-off.flag'   # presence = nudge DISABLED (it's on by default)
$dndFlag      = Get-CDPath 'dnd.flag'
$doneFlag     = Get-CDPath 'onboarding-done.flag'

# --- .env writer: set/replace specific keys, preserving comments ------------
# Reads the existing .env line-by-line (or seeds from .env.example when missing),
# overwrites the value of every key in $kv in place, and appends any key that was
# absent. Keeps the documented template comments intact - unlike a full rewrite.
function Set-EnvValues($kv) {
  $path = Get-CDPath '.env'
  $tmpl = Get-CDPath '.env.example'
  $lines = @()
  try {
    if (Test-Path $path)      { $lines = [System.IO.File]::ReadAllLines($path) }
    elseif (Test-Path $tmpl)  { $lines = [System.IO.File]::ReadAllLines($tmpl) }
  } catch {}
  $remaining = @{}
  foreach ($k in $kv.Keys) { $remaining[$k] = $true }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    $t = ([string]$line).Trim()
    $matched = $false
    if ($t -and -not $t.StartsWith('#')) {
      $eq = $t.IndexOf('=')
      if ($eq -ge 1) {
        $key = $t.Substring(0, $eq).Trim()
        if ($kv.Contains($key)) {
          $out.Add(('{0}={1}' -f $key, $kv[$key]))
          [void]$remaining.Remove($key)
          $matched = $true
        }
      }
    }
    if (-not $matched) { $out.Add([string]$line) }
  }
  foreach ($k in @($remaining.Keys)) { $out.Add(('{0}={1}' -f $k, $kv[$k])) }
  Write-CDText $path (($out -join "`r`n") + "`r`n")
}

# Set or clear a flag file (presence = on).
function Set-FlagState([string]$path, [bool]$on) {
  try {
    if ($on) { if (-not (Test-Path $path)) { Set-Content -LiteralPath $path -Value '' -Encoding ASCII -ErrorAction SilentlyContinue } }
    else     { if (Test-Path $path)        { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
  } catch {}
}

# --- Small styled-control factories -----------------------------------------
function New-Lbl([string]$text, [single]$size, $color, [bool]$bold = $false) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.AutoSize = $true
  $l.UseMnemonic = $false   # keep literal '&' (e.g. "Focus & notifications")
  $l.ForeColor = $color
  $l.BackColor = [System.Drawing.Color]::Transparent
  $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
  $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
  return $l
}
function New-Txt([string]$val, [int]$w) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.Text = [string]$val
  $t.BackColor = $rowBg
  $t.ForeColor = $white
  $t.BorderStyle = 'FixedSingle'
  $t.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
  $t.Width = $w
  return $t
}
function New-Btn([string]$text, [int]$w, $back, $fore) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.UseMnemonic = $false   # keep literal '&' (e.g. "Save & finish")
  $b.FlatStyle = 'Flat'
  $b.BackColor = $back
  $b.ForeColor = $fore
  $b.FlatAppearance.BorderSize = 0
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $b.Size = New-Object System.Drawing.Size($w, 32)
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $b
}
function New-Chk([string]$text, [bool]$checked) {
  $c = New-Object System.Windows.Forms.CheckBox
  $c.Text = $text
  $c.Checked = $checked
  $c.AutoSize = $true
  $c.ForeColor = $white
  $c.BackColor = [System.Drawing.Color]::Transparent
  $c.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  return $c
}

# ============================================================================
# Form
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'ClaudeDeck setup'
$form.FormBorderStyle = 'FixedDialog'
$form.StartPosition   = 'CenterScreen'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.ShowInTaskbar   = $true
$form.TopMost         = $true
$form.BackColor       = $bg
$form.ForeColor       = $white
$form.ClientSize      = New-Object System.Drawing.Size(560, 680)
try { if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) } } catch {}

# --- Header band ------------------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 72
$header.BackColor = $accent
$form.Controls.Add($header)

$hTitle = New-Lbl 'Welcome to ClaudeDeck' 15 $accentText $true
$hTitle.Location = New-Object System.Drawing.Point(24, 14)
$header.Controls.Add($hTitle)

$hSub = New-Lbl 'A couple of optional settings to get the most out of it.' 9.5 $accentText
$hSub.Location = New-Object System.Drawing.Point(24, 44)
$header.Controls.Add($hSub)

# --- Footer band (buttons) --------------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'
$footer.Height = 56
$footer.BackColor = $bg
$form.Controls.Add($footer)

$btnSave = New-Btn 'Save & finish' 140 $accent $accentText
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnSave.Location = New-Object System.Drawing.Point(404, 12)
$footer.Controls.Add($btnSave)

$btnSkip = New-Btn 'Skip for now' 120 $rowBg $grey
$btnSkip.Location = New-Object System.Drawing.Point(24, 12)
$footer.Controls.Add($btnSkip)

# --- Scrollable content panel ----------------------------------------------
$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'
$content.BackColor = $bg
$content.AutoScroll = $true
$content.Padding = New-Object System.Windows.Forms.Padding(0)
$form.Controls.Add($content)
$content.BringToFront()

# Layout cursor: place controls top-to-bottom; helpers advance $script:y.
$LM = 24            # left margin
$CW = 500           # default content width
$script:y = 16
function Place($ctl, [int]$x, [int]$h, [int]$gap = 8) {
  $ctl.Location = New-Object System.Drawing.Point($x, $script:y)
  $content.Controls.Add($ctl)
  $script:y += $h + $gap
}
# Two controls on one row, then advance once by the taller height.
function PlaceRow($a, [int]$ax, $b, [int]$bx, [int]$h, [int]$gap = 8) {
  $a.Location = New-Object System.Drawing.Point($ax, $script:y)
  $b.Location = New-Object System.Drawing.Point($bx, $script:y)
  $content.Controls.Add($a); $content.Controls.Add($b)
  $script:y += $h + $gap
}
function SectionGap { $script:y += 14 }

# --- Intro ------------------------------------------------------------------
$intro = New-Lbl ("ClaudeDeck tracks your Claude Code sessions from the system tray." + [char]10 +
                  "Open it anytime with the Win+Alt+C hotkey. The hooks are already installed -" + [char]10 +
                  "everything below is optional and can be changed later from the gear menu.") 9.5 $grey
$intro.MaximumSize = New-Object System.Drawing.Size($CW, 0)
Place $intro $LM 56 6

# ============================================================================
# Section 1 - Weekly recap (LLM synthesis)
# ============================================================================
SectionGap
Place (New-Lbl 'Weekly recap - AI synthesis' 11.5 $white $true) $LM 24 4
$recapHelp = New-Lbl ('Every Friday ClaudeDeck can summarize your week per project using an LLM.' + [char]10 +
                      'Pick a backend, or leave it disabled to just list your raw requests.') 9 $grey
$recapHelp.MaximumSize = New-Object System.Drawing.Size($CW, 0)
Place $recapHelp $LM 36 8

# Provider combo
$lblProv = New-Lbl 'Provider' 10 $white
$cboProv = New-Object System.Windows.Forms.ComboBox
$cboProv.DropDownStyle = 'DropDownList'
$cboProv.FlatStyle = 'Flat'
$cboProv.BackColor = $rowBg
$cboProv.ForeColor = $white
$cboProv.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
$cboProv.Width = 300
[void]$cboProv.Items.Add('Disabled (no LLM)')
[void]$cboProv.Items.Add('Ollama (local / self-hosted server)')
[void]$cboProv.Items.Add('OpenAI-compatible endpoint')
PlaceRow $lblProv $LM $cboProv 140 28 12

# URL / Model / API key fields (visibility depends on the provider)
$lblUrl = New-Lbl 'Server URL' 10 $white
$txtUrl = New-Txt '' 360
PlaceRow $lblUrl $LM $txtUrl 140 26 8

$lblModel = New-Lbl 'Model' 10 $white
$txtModel = New-Txt '' 360
PlaceRow $lblModel $LM $txtModel 140 26 8

$lblKey = New-Lbl 'API key' 10 $white
$txtKey = New-Txt '' 360
$txtKey.UseSystemPasswordChar = $true
PlaceRow $lblKey $LM $txtKey 140 26 10

# Test connection
$btnTest = New-Btn 'Test connection' 150 $rowBg $white
$lblTest = New-Lbl '' 9 $grey
PlaceRow $btnTest 140 $lblTest 300 34 8

# Prefill from the current .env. We keep one bucket of values per provider so that
# switching the combo restores sensible defaults instead of showing the wrong URL.
$envv = Get-CDEnv
$enabled = $true
$en = ([string]$envv['LLM_ENABLED']); if (-not $en) { $en = ([string]$envv['OLLAMA_ENABLED']) }
if ($en -and $en.ToLower() -eq 'false') { $enabled = $false }
$prov = ([string]$envv['LLM_PROVIDER']).ToLower()

$script:bucket = @{
  1 = @{ url = [string]$envv['OLLAMA_URL']; model = [string]$envv['OLLAMA_MODEL']; key = '' }
  2 = @{ url = [string]$envv['LLM_URL'];    model = [string]$envv['LLM_MODEL'];    key = [string]$envv['LLM_API_KEY'] }
}
$initIdx = if (-not $enabled) { 0 } elseif ($prov -eq 'openai') { 2 } else { 1 }
$script:prevIdx = $initIdx

# Show only the fields the chosen provider needs (hidden rows just leave a gap).
function Apply-LLMVisibility([int]$i) {
  $showUrl = ($i -ne 0)
  $showKey = ($i -eq 2)
  foreach ($c in @($lblUrl, $txtUrl, $lblModel, $txtModel, $btnTest, $lblTest)) { $c.Visible = $showUrl }
  $lblKey.Visible = $showKey; $txtKey.Visible = $showKey
}
function Load-Bucket([int]$i) {
  if ($script:bucket.Contains($i)) {
    $txtUrl.Text = $script:bucket[$i].url
    $txtModel.Text = $script:bucket[$i].model
    $txtKey.Text = $script:bucket[$i].key
  } else { $txtUrl.Text = ''; $txtModel.Text = ''; $txtKey.Text = '' }
}
function Save-Bucket([int]$i) {
  if ($script:bucket.Contains($i)) {
    $script:bucket[$i].url = $txtUrl.Text
    $script:bucket[$i].model = $txtModel.Text
    $script:bucket[$i].key = $txtKey.Text
  }
}
# Apply the initial selection + prefill FIRST, then wire the change handler. Doing
# it in this order matters: assigning SelectedIndex fires SelectedIndexChanged, and
# if the handler were already attached its Save-Bucket would overwrite the freshly
# prefilled bucket with the (still empty) textboxes before Load-Bucket runs.
$cboProv.SelectedIndex = $initIdx
Load-Bucket $initIdx
Apply-LLMVisibility $initIdx
$cboProv.Add_SelectedIndexChanged({
  Save-Bucket $script:prevIdx
  $i = $cboProv.SelectedIndex
  Load-Bucket $i
  Apply-LLMVisibility $i
  $script:prevIdx = $i
  $lblTest.Text = ''
})

# Test connection: a short synchronous probe (the recap reaches the same endpoint).
$btnTest.Add_Click({
  $i = $cboProv.SelectedIndex
  $url = ([string]$txtUrl.Text).Trim()
  if (-not $url) { $lblTest.ForeColor = $red; $lblTest.Text = 'Enter a server URL first.'; return }
  $btnTest.Enabled = $false
  $lblTest.ForeColor = $grey; $lblTest.Text = 'Testing...'
  [System.Windows.Forms.Application]::DoEvents()
  try {
    if ($i -eq 1) {
      $u = $url.TrimEnd('/') + '/api/tags'
      $r = Invoke-RestMethod -Uri $u -TimeoutSec 8 -ErrorAction Stop
      $n = @($r.models).Count
      $lblTest.ForeColor = $green; $lblTest.Text = ("Connected - {0} model(s) available." -f $n)
    } else {
      $u = $url.TrimEnd('/') + '/v1/models'
      $headers = @{}
      $key = ([string]$txtKey.Text).Trim()
      if ($key) { $headers['Authorization'] = "Bearer $key" }
      $r = Invoke-RestMethod -Uri $u -Headers $headers -TimeoutSec 8 -ErrorAction Stop
      $n = @($r.data).Count
      $lblTest.ForeColor = $green; $lblTest.Text = ("Connected - {0} model(s) available." -f $n)
    }
  } catch {
    $lblTest.ForeColor = $red
    $msg = [string]$_.Exception.Message
    if ($msg.Length -gt 60) { $msg = $msg.Substring(0, 60) + '...' }
    $lblTest.Text = ("Failed: {0}" -f $msg)
  }
  $btnTest.Enabled = $true
})

# ============================================================================
# Section 2 - Cloud sync folder
# ============================================================================
SectionGap
Place (New-Lbl 'Cloud sync folder (optional)' 11.5 $white $true) $LM 24 4
$syncHelp = New-Lbl ('Mirror your per-project todos and activity history to a folder kept in sync' + [char]10 +
                     'across machines (Google Drive / OneDrive / Synology). Point each PC at it.') 9 $grey
$syncHelp.MaximumSize = New-Object System.Drawing.Size($CW, 0)
Place $syncHelp $LM 36 8

$script:syncPath = [string](Get-CDSyncDir)
$txtSync = New-Txt $script:syncPath 332
$txtSync.ReadOnly = $true
$btnBrowse = New-Btn 'Browse...' 80 $rowBg $white
$btnBrowse.Height = 26
$btnClear = New-Btn 'Clear' 60 $rowBg $grey
$btnClear.Height = 26
$txtSync.Location = New-Object System.Drawing.Point($LM, $script:y)
$btnBrowse.Location = New-Object System.Drawing.Point(364, $script:y)
$btnClear.Location = New-Object System.Drawing.Point(452, $script:y)
$content.Controls.Add($txtSync); $content.Controls.Add($btnBrowse); $content.Controls.Add($btnClear)
$script:y += 34

$btnBrowse.Add_Click({
  try {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick a folder synced across your PCs (Google Drive / OneDrive / Synology Drive).'
    if ($script:syncPath) { $dlg.SelectedPath = $script:syncPath }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $script:syncPath = $dlg.SelectedPath
      $txtSync.Text = $script:syncPath
    }
    $dlg.Dispose()
  } catch {}
})
$btnClear.Add_Click({ $script:syncPath = ''; $txtSync.Text = '' })

# ============================================================================
# Section 3 - Updates
# ============================================================================
SectionGap
Place (New-Lbl 'Updates' 11.5 $white $true) $LM 24 6
$chkUpd = New-Chk 'Check for updates automatically (GitHub releases)' (Test-Path $autoUpdFlag)
Place $chkUpd $LM 24 8

# ============================================================================
# Section 4 - Focus & notifications
# ============================================================================
SectionGap
Place (New-Lbl 'Focus & notifications' 11.5 $white $true) $LM 24 6
# Focus nudge is ON by default (opt-OUT via focus-off.flag), so "enabled" = flag absent.
$chkFocus = New-Chk 'Nudge me when I drift onto a distraction with no session running' (-not (Test-Path $focusOffFlag))
Place $chkFocus $LM 24 6
$chkDnd = New-Chk 'Do not disturb (do not auto-open the deck when a task finishes)' (Test-Path $dndFlag)
Place $chkDnd $LM 24 12

# ============================================================================
# Save / Skip
# ============================================================================
function Mark-Done { Set-FlagState $doneFlag $true }

$btnSkip.Add_Click({ Mark-Done; $form.Close() })

$btnSave.Add_Click({
  # --- LLM -> .env ---
  Save-Bucket $cboProv.SelectedIndex
  $i = $cboProv.SelectedIndex
  $kv = [ordered]@{}
  if ($i -eq 0) {
    $kv['LLM_ENABLED'] = 'false'
  } elseif ($i -eq 1) {
    $kv['LLM_PROVIDER'] = 'ollama'; $kv['LLM_ENABLED'] = 'true'
    $kv['OLLAMA_URL']  = ([string]$script:bucket[1].url).Trim()
    $kv['OLLAMA_MODEL'] = ([string]$script:bucket[1].model).Trim()
  } else {
    $kv['LLM_PROVIDER'] = 'openai'; $kv['LLM_ENABLED'] = 'true'
    $kv['LLM_URL']     = ([string]$script:bucket[2].url).Trim()
    $kv['LLM_MODEL']   = ([string]$script:bucket[2].model).Trim()
    $kv['LLM_API_KEY'] = ([string]$script:bucket[2].key).Trim()
  }
  Set-EnvValues $kv

  # --- Cloud sync (Set-CDSyncDir clears when empty) ---
  try { Set-CDSyncDir $script:syncPath | Out-Null } catch {}

  # --- Flags ---
  $wantUpd = $chkUpd.Checked
  $hadUpd  = (Test-Path $autoUpdFlag)
  Set-FlagState $autoUpdFlag $wantUpd
  if ($wantUpd -and -not $hadUpd) { try { Invoke-Updater '-Check' } catch {} }   # kick off a first check
  Set-FlagState $focusOffFlag (-not $chkFocus.Checked)   # checked = nudge ON = flag ABSENT
  Set-FlagState $dndFlag $chkDnd.Checked

  Mark-Done
  $form.Close()
})

# Esc closes (and still marks done, so it never re-nags on the next launch).
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Mark-Done; $form.Close() } })

[void]$form.ShowDialog()
try { $script:onbMutex.ReleaseMutex() } catch {}
