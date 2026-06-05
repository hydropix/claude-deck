# Point git at the repo's tracked hooks directory so the pre-commit bundle guard
# is active. Run this ONCE per clone (git won't auto-enable hooks for security).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install-hooks.ps1
#
# Uses core.hooksPath (not a copy into .git/hooks) so the tracked hooks under
# tools/git-hooks/ stay the single source of truth — pulling an updated hook just
# works, no re-install needed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

& git -C $root config core.hooksPath 'tools/git-hooks'
if ($LASTEXITCODE -ne 0) { Write-Host 'Failed to set core.hooksPath' -ForegroundColor Red; exit 1 }

# Best-effort: flag the hook executable in the index (matters on WSL/Linux/macOS).
# Silently skipped if the file isn't tracked yet — it gets the bit when committed.
try { & git -C $root update-index --chmod=+x tools/git-hooks/pre-commit 2>$null | Out-Null } catch {}

Write-Host 'Git hooks enabled (core.hooksPath -> tools/git-hooks).' -ForegroundColor Green
Write-Host 'pre-commit will now regenerate + verify ClaudeDeck-Setup.cmd on any scripts/ change.'
