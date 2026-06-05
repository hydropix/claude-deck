# ClaudeDeck - weekly recap popup (entry point).
#
# Auto-popped by the tray every Friday at 17:00 (and openable on demand from the
# tray menu). It gathers the week's work PER PROJECT and shows a short synthesis:
#   * the developer's requests to Claude this week (read from the Claude Code
#     transcripts under ~/.claude/projects/<dir>/<session>.jsonl), grouped by the
#     project (the cwd leaf), filtered to the current work week (Mon 00:00 -> now);
#   * the COMPLETED (ticked-done) tasks for each project (objectives.json, the same
#     map the deck's per-project header edits) — pending tasks are skipped as noise;
#   * a clean, short bullet summary produced by an LLM. The provider is pluggable
#     via ~/.claude/sessions/.env (Get-CDEnv): LLM_PROVIDER=ollama (native) or
#     'openai' (any OpenAI-compatible /v1/chat/completions endpoint). When the LLM
#     is disabled or unreachable we fall back to listing the raw requests.
#
# The LLM calls run in a background runspace so the window paints immediately and
# each project's card fills in as its summary returns (a UI timer polls a
# synchronized hashtable - WinForms controls are only ever touched on the UI
# thread). Dot-sources session-common.ps1 for paths / colours / Get-CDEnv.
#
# Modes:
#   (none)   open the popup
#   -Print   headless: print the gathered data (test the gathering, no UI/LLM)
#   -Force   reserved (kept for symmetry with the tray trigger; no special effect)
#   -Days N  override the window to the last N days instead of "this week"
param([switch]$Print, [switch]$Force, [int]$Days = 0)

. (Join-Path $PSScriptRoot 'session-common.ps1')

# --- Single-instance guard (UI mode only) ----------------------------------
if (-not $Print) {
  $dupes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*session-recap.ps1*' })
  if ($dupes.Count -gt 0) { exit 0 }
}

# --- Time window: this work week (Mon 00:00) -> now, or last -Days ----------
$now = Get-Date
if ($Days -gt 0) {
  $start = $now.AddDays(-$Days)
} else {
  $daysFromMonday = ([int]$now.DayOfWeek + 6) % 7   # DayOfWeek: Sunday=0 -> Monday=0..Sunday=6
  $start = $now.Date.AddDays(-$daysFromMonday)
}

# --- Gather the week's requests, grouped by project -------------------------
# Strip the harness/IDE-injected wrapper blocks the same way the tracker does, so a
# turn that only carried an opened file / selection / reminder doesn't masquerade
# as a real request.
function Clean-Prompt([string]$text) {
  if (-not $text) { return '' }
  $text = $text -replace '(?s)<ide_opened_file>.*?</ide_opened_file>', ''
  $text = $text -replace '(?s)<ide_selection>.*?</ide_selection>', ''
  $text = $text -replace '(?s)<system-reminder>.*?</system-reminder>', ''
  $text = $text -replace '(?s)<command-message>.*?</command-message>', ''
  $text = $text -replace '(?s)<command-name>.*?</command-name>', ''
  $text = $text -replace '(?s)<command-args>.*?</command-args>', ''
  $text = $text -replace '(?s)<local-command-stdout>.*?</local-command-stdout>', ''
  $text = $text -replace '(?s)<local-command-caveat>.*?</local-command-caveat>', ''
  return ($text -replace '\s+', ' ').Trim()
}

# Injected / housekeeping turns that aren't a real user request: the auto
# compaction summary, an interrupt marker, a bare slash-command echo, etc.
function Is-NoisePrompt([string]$text) {
  if (-not $text) { return $true }
  if ($text -match '^\[Request interrupted') { return $true }
  if ($text -match '^This session is being continued from a previous conversation') { return $true }
  if ($text -match '^(?i:caveat: the messages below)') { return $true }
  return $false
}

# Pull the human text out of a transcript "user" line. Returns '' for tool-result
# turns (those are tool output fed back to the model, not something the user typed).
function Get-UserText($msg) {
  if ($null -eq $msg) { return '' }
  $c = $msg.content
  if ($c -is [string]) { return Clean-Prompt $c }
  $parts = @()
  foreach ($b in @($c)) {
    if ($null -eq $b) { continue }
    if ($b.type -eq 'tool_result') { return '' }   # tool output, not a user request
    if ($b.type -eq 'text' -and $b.text) { $parts += [string]$b.text }
  }
  return Clean-Prompt ($parts -join ' ')
}

# The concluding takeaway of a turn = the LAST text block of an assistant message
# (its final paragraph, after any tool calls). We never keep tool_use / thinking /
# code blocks - only that closing prose, and the caller truncates it.
function Get-AsstText($msg) {
  if ($null -eq $msg) { return '' }
  $c = $msg.content
  if ($c -is [string]) { return ($c -replace '\s+', ' ').Trim() }
  $last = ''
  foreach ($b in @($c)) {
    if ($b -and $b.type -eq 'text' -and $b.text) { $last = [string]$b.text }
  }
  return ($last -replace '\s+', ' ').Trim()
}

# Whether to pair each request with Claude's concluding takeaway, and how hard to
# truncate that takeaway - both editable in .env (RECAP_INCLUDE_OUTCOMES /
# RECAP_OUTCOME_CHARS) so the prompt sent to the LLM stays as small as you want.
$cfg = Get-CDEnv
$includeOutcomes = ($cfg.RECAP_INCLUDE_OUTCOMES -match '^(?i:true|1|yes|on)$')
$OUTCOME_CHARS = 250; try { $OUTCOME_CHARS = [int]$cfg.RECAP_OUTCOME_CHARS } catch {}

$projectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$byProject = @{}   # project -> ArrayList of @{ q = request; a = truncated takeaway } (chronological)

# Record one finished turn (request + its concluding takeaway), de-duping a
# request identical to the immediately preceding one (resend / queued duplicate).
function Add-Turn($proj, $q, $a) {
  if (-not $proj) { $proj = 'session' }
  if (-not $byProject.ContainsKey($proj)) { $byProject[$proj] = New-Object System.Collections.ArrayList }
  $lst = $byProject[$proj]
  if ($lst.Count -gt 0 -and $lst[$lst.Count - 1].q -eq $q) { return }
  $aa = ''
  if ($includeOutcomes -and $a) {
    if ($a.Length -gt $OUTCOME_CHARS) { $aa = $a.Substring(0, $OUTCOME_CHARS).TrimEnd() + [char]0x2026 } else { $aa = $a }
  }
  [void]$lst.Add([pscustomobject]@{ q = $q; a = $aa })
}

if (Test-Path $projectsRoot) {
  foreach ($dir in Get-ChildItem $projectsRoot -Directory -ErrorAction SilentlyContinue) {
    foreach ($file in Get-ChildItem $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
      # A file last written before the window can only hold older turns - skip it.
      if ($file.LastWriteTime -lt $start) { continue }
      # Walk the file in order, pairing each real request with the conclusion of its
      # turn = the last assistant text seen before the NEXT real request. tool_result
      # turns and noise never start a turn; assistant texts between them just refresh
      # the running "last takeaway".
      $curProj = $null; $curQ = $null; $lastA = ''
      try {
        foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
          if (-not $line) { continue }
          $isUser = ($line.IndexOf('"type":"user"') -ge 0)
          $isAsst = (-not $isUser) -and ($line.IndexOf('"type":"assistant"') -ge 0)
          if (-not $isUser -and -not $isAsst) { continue }
          $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
          if (-not $o) { continue }

          if ($o.type -eq 'assistant') {
            $at = Get-AsstText $o.message
            if ($at) { $lastA = $at }
            continue
          }
          if ($o.type -ne 'user') { continue }

          $text = Get-UserText $o.message
          if (Is-NoisePrompt $text) { continue }   # tool_result / injected turn: not a request

          # A new real request closes the previous turn.
          if ($null -ne $curQ) { Add-Turn $curProj $curQ $lastA }
          $curProj = $null; $curQ = $null; $lastA = ''

          $ts = $null; try { $ts = ([datetime]$o.timestamp).ToLocalTime() } catch { continue }
          if ($ts -lt $start -or $ts -gt $now) { continue }   # out of window: don't open a turn
          $proj = ''
          if ($o.cwd) { $proj = Split-Path ([string]$o.cwd) -Leaf }
          if (-not $proj) { $proj = 'session' }
          $curProj = $proj; $curQ = $text
        }
        if ($null -ne $curQ) { Add-Turn $curProj $curQ $lastA }   # flush the last open turn
      } catch {}
    }
  }
}

# Per-project COMPLETED tasks (from the same objectives.json the deck edits). We
# deliberately keep only the ticked-done tasks here: pending / "for later" tasks are
# noise in a recap of what was actually accomplished. A legacy string objective has
# no done flag, so it contributes nothing (it isn't "completed").
$completed = @{}
try {
  $objFile = Get-CDObjectivesPath
  if (Test-Path $objFile) {
    $oj = [System.IO.File]::ReadAllText($objFile) | ConvertFrom-Json
    if ($oj -and $oj.items) {
      foreach ($p in $oj.items.PSObject.Properties) {
        $doneTexts = @(ConvertTo-CDTasks $p.Value | Where-Object { $_.done } | ForEach-Object { [string]$_.text })
        if ($doneTexts.Count -gt 0) { $completed[$p.Name] = ($doneTexts -join '; ') }
      }
    }
  }
} catch {}

# Build the ordered project list (most-active first), then assemble the text fed to
# the LLM with WHOLE-WEEK COVERAGE as the priority. The old design kept only the
# 60 newest turns and then only the last ~9000 chars of the block, so a very active
# project's early-week work (e.g. a whole feature shipped Monday) never reached the
# model - it summarized only the tail of the week. Now: every turn's REQUEST (the
# "what was worked on") is always represented; the assistant takeaways are added
# best-effort on the most RECENT turns with whatever budget is left; and if even the
# requests overflow we sample evenly across the week (keeping the first and last) so
# both ends survive instead of only the tail.
$Q_CHARS   = 220   # per-request hard cap, so one long paste can't dominate the block
$MAX_CHARS = if ($includeOutcomes) { 12000 } else { 8000 }

function Truncate-Text([string]$s, [int]$n) {
  if (-not $s) { return '' }
  if ($s.Length -le $n) { return $s }
  return $s.Substring(0, $n).TrimEnd() + [char]0x2026
}

$projList = @()
foreach ($proj in ($byProject.Keys | Sort-Object { -$byProject[$_].Count })) {
  $allTurns = @($byProject[$proj])
  $realCount = $allTurns.Count   # what the card/header reports (true week total)
  $turns = $allTurns

  # 1) Requests-only floor: every turn, chronological, each request capped.
  $reqLen = 0
  foreach ($t in $turns) { $reqLen += (Truncate-Text $t.q $Q_CHARS).Length + 3 }

  # 2) If even the requests overflow, sample evenly across the week (always keeping
  #    the first and last turn) rather than dropping the start.
  if ($reqLen -gt $MAX_CHARS -and $turns.Count -gt 2) {
    $keep = [math]::Max(2, [int][math]::Floor($turns.Count * $MAX_CHARS / $reqLen))
    if ($keep -lt $turns.Count) {
      $idx = New-Object System.Collections.ArrayList
      for ($i = 0; $i -lt $keep; $i++) { [void]$idx.Add([int][math]::Round($i * ($turns.Count - 1) / ($keep - 1))) }
      $idx = @($idx | Select-Object -Unique | Sort-Object)
      $turns = @($idx | ForEach-Object { $allTurns[$_] })
    }
  }

  # 3) Spend the leftover budget on takeaways, newest-first, then render in order.
  $withA = @{}
  if ($includeOutcomes) {
    $used = 0
    foreach ($t in $turns) { $used += (Truncate-Text $t.q $Q_CHARS).Length + 3 }
    for ($i = $turns.Count - 1; $i -ge 0; $i--) {
      $a = $turns[$i].a
      if (-not $a) { continue }
      $cost = $a.Length + 6
      if ($used + $cost -gt $MAX_CHARS) { break }
      $withA[$i] = $true; $used += $cost
    }
  }
  $lines = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $turns.Count; $i++) {
    [void]$lines.Add('- ' + (Truncate-Text $turns[$i].q $Q_CHARS))
    if ($withA.ContainsKey($i)) { [void]$lines.Add('  ' + [char]0x2192 + ' ' + $turns[$i].a) }   # -> takeaway
  }
  $block = ($lines -join "`n")

  $done = ''
  if ($completed.ContainsKey($proj)) { $done = $completed[$proj] }
  $projList += [pscustomobject]@{
    project   = $proj
    completed = $done
    count     = $realCount
    turns     = $allTurns
    prompts   = @($allTurns | ForEach-Object { $_.q })
    block     = $block
  }
}

$rangeLabel = ('{0} -> {1}' -f $start.ToString('ddd dd MMM'), $now.ToString('ddd dd MMM HH:mm'))

# --- Headless print mode (test the gathering without UI / LLM) --------------
if ($Print) {
  Write-Host ("Weekly recap  [{0}]" -f $rangeLabel)
  Write-Host ("Projects with activity: {0}`n" -f $projList.Count)
  foreach ($p in $projList) {
    Write-Host ("=== {0}  ({1} request(s)) ===" -f $p.project, $p.count) -ForegroundColor Cyan
    if ($p.completed) { Write-Host ("Completed: {0}" -f $p.completed) -ForegroundColor Yellow }
    $show = @($p.turns); if ($show.Count -gt 8) { $show = $show[0..7] }
    foreach ($t in $show) {
      $q = if ($t.q.Length -gt 140) { $t.q.Substring(0, 137) + '...' } else { $t.q }
      Write-Host ("  - {0}" -f $q)
      if ($includeOutcomes -and $t.a) {
        $a = if ($t.a.Length -gt 140) { $t.a.Substring(0, 137) + '...' } else { $t.a }
        Write-Host ("      -> {0}" -f $a) -ForegroundColor DarkGray
      }
    }
    Write-Host ''
  }
  exit 0
}

# ============================================================================
# UI
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Palette (mirrors session-view.ps1).
$bg     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$cardBg = [System.Drawing.Color]::FromArgb(36, 36, 42)
$headBg = [System.Drawing.Color]::FromArgb(18, 18, 22)
$grey   = [System.Drawing.Color]::FromArgb(150, 150, 158)
$dim    = [System.Drawing.Color]::FromArgb(110, 110, 120)
$white  = [System.Drawing.Color]::FromArgb(235, 235, 240)
$blue   = [System.Drawing.Color]::FromArgb(120, 175, 240)
$iconPath = Join-Path $PSScriptRoot 'logo.ico'

# Optional scaling / opacity to match the deck's settings.
$scale = 1.0
try { $sz = (Get-Content (Get-CDPath 'size.txt') -ErrorAction Stop | Select-Object -First 1); if ($sz) { $scale = [math]::Min(2.0, [math]::Max(0.8, [double]$sz)) } } catch {}
function PX([int]$n) { return [int][math]::Round($n * $scale) }

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'ClaudeDeck Weekly Recap'
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $bg
$form.ForeColor     = $white
$form.ClientSize    = New-Object System.Drawing.Size((PX 780), (PX 700))
$form.MinimumSize   = New-Object System.Drawing.Size((PX 520), (PX 360))
$form.TopMost       = $true
$form.ShowInTaskbar = $true
try { if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) } } catch {}
try { $op = [int](Get-Content (Get-CDPath 'opacity.txt') -ErrorAction Stop | Select-Object -First 1); if ($op -ge 20 -and $op -le 100) { $form.Opacity = $op / 100.0 } } catch {}

# --- Header -----------------------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = (PX 56); $header.BackColor = $headBg
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Weekly recap'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', (12 * $scale))
$title.ForeColor = $white; $title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point((PX 18), (PX 9))
$header.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = ('{0}    |    {1} project(s)' -f $rangeLabel, $projList.Count)
$sub.Font = New-Object System.Drawing.Font('Segoe UI', (9 * $scale))
$sub.ForeColor = $grey; $sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point((PX 19), (PX 32))
$header.Controls.Add($sub)

# --- Scrollable card list ---------------------------------------------------
$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Dock = 'Fill'; $list.AutoScroll = $true; $list.WrapContents = $false
$list.FlowDirection = 'TopDown'; $list.BackColor = $bg
$list.Padding = New-Object System.Windows.Forms.Padding((PX 14), (PX 10), (PX 14), (PX 10))
$form.Controls.Add($list)
$list.BringToFront()

# --- Footer (actions) -------------------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'; $footer.Height = (PX 48); $footer.BackColor = $headBg
$form.Controls.Add($footer)

function New-FooterButton([string]$text, [int]$x) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.FlatStyle = 'Flat'; $b.AutoSize = $false
  $b.Size = New-Object System.Drawing.Size((PX 116), (PX 30))
  $b.Location = New-Object System.Drawing.Point((PX $x), (PX 9))
  $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
  $b.BackColor = $cardBg; $b.ForeColor = $white
  $b.Font = New-Object System.Drawing.Font('Segoe UI', (9 * $scale))
  $footer.Controls.Add($b)
  return $b
}
$btnRegen = New-FooterButton 'Regenerate' 14
$btnCopy  = New-FooterButton 'Copy'       140
$btnSave  = New-FooterButton 'Save .md'   256
$btnClose = New-FooterButton 'Close'      382
$btnClose.Add_Click({ $form.Close() })

# --- Card rendering ---------------------------------------------------------
# One card per project; $script:cards keeps the body label + project so the poll
# timer can fill it once its summary returns.
$script:cards = @{}

function New-Card($p) {
  $accent = Get-ProjectColor $p.project
  $cardW = [int]($form.ClientSize.Width - (PX 44))

  $card = New-Object System.Windows.Forms.Panel
  $card.Width = $cardW; $card.BackColor = $cardBg; $card.AutoSize = $true
  $card.AutoSizeMode = 'GrowAndShrink'
  $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (PX 12))
  $card.Padding = New-Object System.Windows.Forms.Padding((PX 12), (PX 10), (PX 12), (PX 12))

  $stripe = New-Object System.Windows.Forms.Panel
  $stripe.Dock = 'Left'; $stripe.Width = (PX 4); $stripe.BackColor = $accent
  $card.Controls.Add($stripe)

  # Badge with the project initials.
  $badge = New-Object System.Windows.Forms.Label
  $badge.Text = (Get-Initials $p.project); $badge.BackColor = $accent
  $badge.ForeColor = (Get-TextOn $accent); $badge.TextAlign = 'MiddleCenter'
  $badge.Font = New-Object System.Drawing.Font('Segoe UI Semibold', (9 * $scale))
  $badge.Size = New-Object System.Drawing.Size((PX 30), (PX 22))
  $badge.Location = New-Object System.Drawing.Point((PX 12), (PX 10))
  $card.Controls.Add($badge); $badge.BringToFront()

  $name = New-Object System.Windows.Forms.Label
  $name.Text = ('{0}   ({1} request(s))' -f $p.project, $p.count)
  $name.Font = New-Object System.Drawing.Font('Segoe UI Semibold', (10 * $scale))
  $name.ForeColor = $white; $name.AutoSize = $true
  $name.Location = New-Object System.Drawing.Point((PX 50), (PX 8))
  $card.Controls.Add($name); $name.BringToFront()

  $y = (PX 32)
  if ($p.completed) {
    $obj = New-Object System.Windows.Forms.Label
    $obj.Text = ([char]0x2713 + ' ' + $p.completed)   # check mark: tasks completed
    $obj.Font = New-Object System.Drawing.Font('Segoe UI', (9 * $scale), [System.Drawing.FontStyle]::Italic)
    $obj.ForeColor = $blue; $obj.AutoSize = $true; $obj.MaximumSize = New-Object System.Drawing.Size(($cardW - (PX 70)), 0)
    $obj.Location = New-Object System.Drawing.Point((PX 50), $y)
    $card.Controls.Add($obj); $obj.BringToFront()
    $y += (PX 22)
  }

  $body = New-Object System.Windows.Forms.Label
  $body.Text = 'Generating summary'
  $body.Font = New-Object System.Drawing.Font('Segoe UI', (10 * $scale))
  $body.ForeColor = $dim; $body.AutoSize = $true
  $body.MaximumSize = New-Object System.Drawing.Size(($cardW - (PX 64)), 0)
  $body.Location = New-Object System.Drawing.Point((PX 50), ($y + (PX 4)))
  $card.Controls.Add($body); $body.BringToFront()

  $list.Controls.Add($card)
  $script:cards[$p.project] = @{ body = $body; rendered = $false; project = $p.project }
}

function Render-Cards {
  $list.SuspendLayout(); $list.Controls.Clear(); $script:cards = @{}
  if ($projList.Count -eq 0) {
    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = 'No Claude activity recorded this week.'
    $empty.Font = New-Object System.Drawing.Font('Segoe UI', (11 * $scale))
    $empty.ForeColor = $grey; $empty.AutoSize = $true
    $empty.Margin = New-Object System.Windows.Forms.Padding((PX 6), (PX 12), 0, 0)
    $list.Controls.Add($empty)
  } else {
    foreach ($p in $projList) { New-Card $p }
  }
  $list.ResumeLayout()
}

# Bulleted raw-prompt fallback (LLM disabled or unreachable).
function Raw-Summary($p) {
  $show = @($p.prompts); if ($show.Count -gt 8) { $show = $show[-8..-1] }
  ($show | ForEach-Object {
    $q = if ($_.Length -gt 160) { $_.Substring(0, 157) + '...' } else { $_ }
    [char]0x2022 + ' ' + $q
  }) -join "`r`n"
}

# --- Background synthesis (provider-agnostic) via a runspace ----------------
# Provider is chosen by LLM_PROVIDER ('ollama' | 'openai'). The generic LLM_* keys
# win when set; otherwise we fall back to the legacy OLLAMA_* keys so an existing
# .env keeps working unchanged.
$script:sync = [hashtable]::Synchronized(@{})
$script:rs = $null; $script:ps = $null

$llmProvider = ([string]$cfg.LLM_PROVIDER).Trim().ToLower(); if (-not $llmProvider) { $llmProvider = 'ollama' }
$llmUrl   = if ($cfg.LLM_URL)   { $cfg.LLM_URL }   else { $cfg.OLLAMA_URL }
$llmModel = if ($cfg.LLM_MODEL) { $cfg.LLM_MODEL } else { $cfg.OLLAMA_MODEL }
$llmKey   = [string]$cfg.LLM_API_KEY
$enabledRaw = if ($cfg.LLM_ENABLED) { $cfg.LLM_ENABLED } else { $cfg.OLLAMA_ENABLED }
$ollamaOn = ($enabledRaw -match '^(?i:true|1|yes|on)$')
$timeoutRaw = if ($cfg.LLM_TIMEOUT) { $cfg.LLM_TIMEOUT } else { $cfg.OLLAMA_TIMEOUT }
$llmTimeout = 60; try { $llmTimeout = [int]$timeoutRaw } catch {}

function Build-LlmPrompt($p) {
  $objLine = if ($p.completed) { ('Tasks the user ticked as DONE on this project: "{0}". Treat these as confirmed accomplishments.' -f $p.completed) } else { 'No tasks were ticked done on this project.' }
  $outcomeLine = if ($includeOutcomes) { 'Each request may be followed by a "' + [char]0x2192 + '" line: the assistant''s concluding takeaway for that turn (use it to capture what was actually resolved).' } else { '' }
  return @"
You are writing a concise weekly work recap for the project "$($p.project)".
$objLine
Below are the developer's requests to the AI coding assistant this week, in chronological order.
$outcomeLine
Summarize what was worked on, the goals pursued, and the outcomes reached, in 3 to 6 short bullet points.
Be specific and concrete, merge duplicates, and ignore trivial or aborted requests.
Reply in the SAME language as the requests. Output ONLY the bullet points (start each with "- "); no preamble, no closing remark, no title.

Requests:
$($p.block)
"@
}

function Start-Synthesis {
  # Reset state and (re)start the background runspace over all projects.
  foreach ($k in @($script:sync.Keys)) { [void]$script:sync.Remove($k) }
  if (-not $ollamaOn -or $projList.Count -eq 0) { return }   # fallback handled by the poll timer

  $jobs = @()
  foreach ($p in $projList) { $jobs += [pscustomobject]@{ project = $p.project; prompt = (Build-LlmPrompt $p) } }

  $script:rs = [runspacefactory]::CreateRunspace()
  $script:rs.Open()
  $script:rs.SessionStateProxy.SetVariable('jobs', $jobs)
  $script:rs.SessionStateProxy.SetVariable('sync', $script:sync)
  $script:rs.SessionStateProxy.SetVariable('provider', $llmProvider)
  $script:rs.SessionStateProxy.SetVariable('llmUrl', $llmUrl.TrimEnd('/'))
  $script:rs.SessionStateProxy.SetVariable('llmModel', $llmModel)
  $script:rs.SessionStateProxy.SetVariable('llmKey', $llmKey)
  $script:rs.SessionStateProxy.SetVariable('llmTimeout', $llmTimeout)

  $script:ps = [powershell]::Create()
  $script:ps.Runspace = $script:rs
  [void]$script:ps.AddScript({
    foreach ($j in $jobs) {
      $res = @{ done = $false; text = ''; error = '' }
      try {
        if ($provider -eq 'openai') {
          # OpenAI-compatible chat completions: OpenAI, OpenRouter, Groq, LM Studio,
          # vLLM, llama.cpp server, or Ollama's own /v1 endpoint.
          $headers = @{}
          if ($llmKey) { $headers['Authorization'] = 'Bearer ' + $llmKey }
          $body = @{ model = $llmModel; messages = @(@{ role = 'user'; content = $j.prompt }); stream = $false } | ConvertTo-Json -Depth 6
          $r = Invoke-RestMethod -Uri ('{0}/v1/chat/completions' -f $llmUrl) -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec $llmTimeout
          $res.text = ([string]$r.choices[0].message.content).Trim()
        } else {
          # Ollama native.
          $body = @{ model = $llmModel; prompt = $j.prompt; stream = $false } | ConvertTo-Json -Depth 4
          $r = Invoke-RestMethod -Uri ('{0}/api/generate' -f $llmUrl) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $llmTimeout
          $res.text = ([string]$r.response).Trim()
        }
        if (-not $res.text) { $res.error = 'empty response' }
      } catch {
        $res.error = $_.Exception.Message
      }
      $res.done = $true
      $sync[$j.project] = $res
    }
  })
  [void]$script:ps.BeginInvoke()
}

function Stop-Synthesis {
  try { if ($script:ps) { $script:ps.Stop(); $script:ps.Dispose() } } catch {}
  try { if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch {}
  $script:ps = $null; $script:rs = $null
}

# --- Poll timer: fill cards as summaries land; pulse the pending ones --------
$script:pulse = 0
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 400
$pollTimer.Add_Tick({
  $script:pulse++
  $dots = '.' * (($script:pulse % 4))
  $pending = $false
  foreach ($key in @($script:cards.Keys)) {
    $card = $script:cards[$key]
    if ($card.rendered) { continue }
    $p = $projList | Where-Object { $_.project -eq $key } | Select-Object -First 1

    if (-not $ollamaOn) {
      $card.body.ForeColor = $white; $card.body.Text = (Raw-Summary $p)
      $card.rendered = $true; continue
    }

    $r = $script:sync[$key]
    if ($r -and $r.done) {
      if ($r.error) {
        $card.body.ForeColor = $grey
        $card.body.Text = ((Raw-Summary $p) + "`r`n`r`n(" + [char]0x26A0 + ' LLM unavailable: ' + $r.error + ')')
      } else {
        $card.body.ForeColor = $white; $card.body.Text = $r.text
      }
      $card.rendered = $true
    } else {
      $pending = $true
      $card.body.ForeColor = $dim
      $card.body.Text = 'Generating summary' + $dots
    }
  }
  if (-not $pending) { $pollTimer.Stop() }
})

# --- Footer actions ---------------------------------------------------------
function Build-Markdown {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Weekly recap')
  [void]$sb.AppendLine($rangeLabel); [void]$sb.AppendLine('')
  foreach ($p in $projList) {
    [void]$sb.AppendLine(('## {0}' -f $p.project))
    if ($p.completed) { [void]$sb.AppendLine(('**Completed:** {0}' -f $p.completed)) }
    $c = $script:cards[$p.project]
    $txt = if ($c -and $c.rendered) { $c.body.Text } else { (Raw-Summary $p) }
    [void]$sb.AppendLine($txt); [void]$sb.AppendLine('')
  }
  return $sb.ToString()
}

$btnCopy.Add_Click({
  try { [System.Windows.Forms.Clipboard]::SetText((Build-Markdown)); $btnCopy.Text = 'Copied!' } catch { $btnCopy.Text = 'Copy failed' }
})
$btnSave.Add_Click({
  try {
    $dir = Get-CDPath 'recaps'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $fname = ('recap-{0}.md' -f $start.ToString('yyyy-MM-dd'))
    $path = Join-Path $dir $fname
    Write-CDText $path (Build-Markdown)
    $btnSave.Text = 'Saved'
    try { Start-Process explorer.exe ('/select,"{0}"' -f $path) } catch {}
  } catch { $btnSave.Text = 'Save failed' }
})
$btnRegen.Add_Click({
  Stop-Synthesis
  foreach ($key in @($script:cards.Keys)) { $script:cards[$key].rendered = $false; $script:cards[$key].body.Text = 'Generating summary' }
  Start-Synthesis
  $pollTimer.Start()
  $btnCopy.Text = 'Copy'; $btnSave.Text = 'Save .md'
})

# Re-flow card widths when the window is resized.
$form.Add_Resize({
  $w = [int]($form.ClientSize.Width - (PX 44))
  foreach ($c in $list.Controls) { if ($c -is [System.Windows.Forms.Panel]) { $c.Width = $w } }
})

$form.Add_FormClosed({ $pollTimer.Stop(); Stop-Synthesis })
$form.Add_Shown({
  Render-Cards
  Start-Synthesis
  $pollTimer.Start()
  $form.Activate()
})

[void]$form.ShowDialog()
