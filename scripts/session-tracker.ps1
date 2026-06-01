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

switch ($Event) {
  'prompt' {
    $cwd = [string]$data.cwd
    $proj = if ($cwd) { Split-Path $cwd -Leaf } else { 'session' }
    $prompt = ([string]$data.prompt -replace '\s+', ' ').Trim()
    Save ([ordered]@{
      session_id  = $id
      cwd         = $cwd
      project     = $proj
      last_prompt = $prompt
      status      = 'running'
      updated     = (Get-Date).ToString('o')
    })
  }
  'stop' {
    if (Test-Path $file) {
      $o = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
      $o.status  = 'done'
      $o.updated = (Get-Date).ToString('o')
      if ($o.PSObject.Properties.Name -contains 'seen') { $o.seen = $false }   # new completion = unseen
      Save $o
    } else {
      $cwd = [string]$data.cwd
      Save ([ordered]@{
        session_id  = $id
        cwd         = $cwd
        project     = if ($cwd) { Split-Path $cwd -Leaf } else { 'session' }
        last_prompt = ''
        status      = 'done'
        updated     = (Get-Date).ToString('o')
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
