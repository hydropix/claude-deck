# Claude Code session tracker — called by hooks.
# Writes one JSON state file per session under .claude\sessions\state\
# Never throws into Claude Code: any failure -> silent exit 0.
param([ValidateSet('prompt','stop','end','notify')][string]$Event = 'prompt')

$ErrorActionPreference = 'SilentlyContinue'

# Read hook payload (JSON) from stdin as RAW UTF-8 bytes.
# This bypasses [Console]::InputEncoding (often an OEM codepage that mangles
# accented chars). Falls back to $input for other invocation styles.
$raw = $null
try {
  $stdin = [Console]::OpenStandardInput()
  $ms = New-Object System.IO.MemoryStream
  $stdin.CopyTo($ms)
  if ($ms.Length -gt 0) { $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) }
} catch {}
if (-not $raw) { $raw = (@($input) -join "`n") }
$raw = $raw.Trim()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$id = $data.session_id
if (-not $id) { exit 0 }

$dir = Join-Path $env:USERPROFILE '.claude\sessions\state'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$file = Join-Path $dir ("{0}.json" -f $id)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Save($obj) { [System.IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 5), $utf8NoBom) }

# Context occupied: read the last assistant message's token usage from the
# session transcript (.jsonl). tokens = input + cache_creation + cache_read of
# the most recent message = how full the context window currently is.
# Window auto-detected from the model id (1M for "[1m]" models, else 200k).
function Get-ContextInfo($transcriptPath) {
  $res = @{ tokens = $null; pct = $null }
  try {
    if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { return $res }
    $lines  = Get-Content -LiteralPath $transcriptPath -Tail 120 -ErrorAction Stop
    $window = 200000
    $tokens = $null
    foreach ($ln in $lines) {
      if (-not $ln) { continue }
      try { $o = $ln | ConvertFrom-Json } catch { continue }
      $u = $o.message.usage
      if ($u -and ($null -ne $u.input_tokens)) {
        $t = [int]$u.input_tokens
        if ($null -ne $u.cache_creation_input_tokens) { $t += [int]$u.cache_creation_input_tokens }
        if ($null -ne $u.cache_read_input_tokens)     { $t += [int]$u.cache_read_input_tokens }
        $tokens = $t
      }
      $m = [string]$o.message.model
      if ($m) { $window = if ($m -match '(?i)1m') { 1000000 } else { 200000 } }
    }
    if ($null -ne $tokens) {
      $res.tokens = $tokens
      $res.pct    = [int][math]::Round($tokens / $window * 100)
    }
  } catch {}
  return $res
}
# Store context tokens/% onto an existing state object (idempotent add-or-set).
function Set-Ctx($o, $ctx) {
  foreach ($pair in @(@('ctx_tokens', $ctx.tokens), @('ctx_pct', $ctx.pct))) {
    if ($o.PSObject.Properties.Name -contains $pair[0]) { $o.($pair[0]) = $pair[1] }
    else { $o | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
  }
}

switch ($Event) {
  'prompt' {
    $cwd = [string]$data.cwd
    $proj = if ($cwd) { Split-Path $cwd -Leaf } else { 'session' }
    $prompt = ([string]$data.prompt -replace '\s+', ' ').Trim()
    $ctx = Get-ContextInfo ([string]$data.transcript_path)
    Save ([ordered]@{
      session_id  = $id
      cwd         = $cwd
      project     = $proj
      last_prompt = $prompt
      status      = 'running'
      updated     = (Get-Date).ToString('o')
      ctx_tokens  = $ctx.tokens
      ctx_pct     = $ctx.pct
    })
  }
  'stop' {
    if (Test-Path $file) {
      $o = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
      $o.status  = 'done'
      $o.updated = (Get-Date).ToString('o')
      if ($o.PSObject.Properties.Name -contains 'seen') { $o.seen = $false }   # new completion = unseen
      Set-Ctx $o (Get-ContextInfo ([string]$data.transcript_path))            # refresh context at end of turn
      Save $o
    } else {
      $cwd = [string]$data.cwd
      $ctx = Get-ContextInfo ([string]$data.transcript_path)
      Save ([ordered]@{
        session_id  = $id
        cwd         = $cwd
        project     = if ($cwd) { Split-Path $cwd -Leaf } else { 'session' }
        last_prompt = ''
        status      = 'done'
        updated     = (Get-Date).ToString('o')
        ctx_tokens  = $ctx.tokens
        ctx_pct     = $ctx.pct
      })
    }
  }
  'notify' {
    # Claude needs the user (permission request, question, etc.).
    # Scoped by the hook matcher; we also ignore the noisy idle notification.
    if (Test-Path $file) {
      $msg = ([string]$data.message -replace '\s+', ' ').Trim()
      # Only treat genuine "needs you" notifications (permission/approval) as waiting,
      # never the noisy idle prompt or auth notifications.
      if ($msg -match '(?i)permission|approv|confirm|allow|grant') {
        $o = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        $o.status  = 'waiting'
        $o.updated = (Get-Date).ToString('o')
        if ($o.PSObject.Properties.Name -contains 'waiting_msg') { $o.waiting_msg = $msg }
        else { $o | Add-Member -NotePropertyName waiting_msg -NotePropertyValue $msg }
        Save $o
      }
    }
  }
  'end' { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
exit 0
