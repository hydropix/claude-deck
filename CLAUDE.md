# CLAUDE.md

Guidance for working on ClaudeDeck — a minimalist Windows tray dashboard for Claude Code
sessions, written in PowerShell (no Node/Python). Shell is PowerShell on Windows.

## Key fact: the app runs from the installed copy, not the repo

The tray and view run from `%USERPROFILE%\.claude\sessions\`, **not** from `scripts/` in
this repo. Editing a script in the repo has **no effect** on the running app until it's
redeployed. Each script is a hidden `powershell.exe` process launched via `wscript`.

## Testing changes — do this after EVERY code change

Apply this systematically whenever you modify any script under `scripts/`:

1. **Kill the running app** (both tray and large view; the single-instance guard otherwise
   makes a fresh process `exit 0`):
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
     Where-Object { $_.CommandLine -like '*session-tray.ps1*' -or $_.CommandLine -like '*session-view.ps1*' } |
     ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```

2. **Run the edited script straight from the repo** (fastest iteration — scripts read state
   from `~/.claude/sessions/state/` via hardcoded paths, so this reflects your edits live):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-view.ps1   # large view
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-tray.ps1   # tray
   ```
   Running in a visible terminal (no `-WindowStyle Hidden`) surfaces PowerShell errors —
   use it for debugging.

3. **Validate the real deployment** (only when the change looks good, not every iteration):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```
   `install.ps1` is idempotent and non-destructive: it stops the tray, copies scripts to
   `~/.claude/sessions/`, recreates shortcuts, backs up `settings.json`, and restarts the tray.

## Before committing

If you changed anything under `scripts/` or `install.ps1`, regenerate the single-file
installer and verify the embedded copies match:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-bundle.ps1   # expect "--- ALL MATCH ---"
```

`ClaudeDeck-Setup.cmd` is generated (base64-embedded scripts + a copy of `install.ps1`'s
logic) — never edit it by hand. The version number comes from the latest git tag.

## Releasing

The git tag is the single source of truth for the version. **Default to a patch bump
(`0.0.+1`)** — e.g. `v0.1.1` → `v0.1.2` — unless the user asks for a different one. The
process (the tag drives `version.txt`, which auto-update clients compare against):

```powershell
git commit ...                     # land your changes first
git tag v0.1.2                     # patch bump from the latest tag
powershell -File .\tools\build-setup.ps1     # writes scripts/version.txt + regenerates the .cmd from the tag
powershell -File .\tools\verify-bundle.ps1   # expect "--- ALL MATCH ---"
git add scripts/version.txt ClaudeDeck-Setup.cmd
git commit -m "Release v0.1.2: regenerate version.txt and installer from tag"
git tag -f v0.1.2                  # move the tag onto the release commit
git push origin main && git push origin v0.1.2
```

## Language

All user-facing text and comments are in **English**. Keep it that way.
