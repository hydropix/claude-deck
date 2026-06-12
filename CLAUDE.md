# CLAUDE.md

Guidance for working on ClaudeDeck — a minimalist Windows tray dashboard for Claude Code
sessions, written in PowerShell (no Node/Python). Shell is PowerShell on Windows.

## How it works (architecture)

ClaudeDeck has no server and no daemon doing the tracking — it piggybacks on **Claude Code
hooks**. The flow is one-directional: hooks write state files, the UI reads them.

```text
Claude Code  --(hooks: UserPromptSubmit/Stop/Notification/SessionEnd)-->  session-tracker.ps1
                                                                                |
                       writes per-session state  ~/.claude/sessions/state/<session_id>.json
                       appends event log          ~/.claude/sessions/stats/events.jsonl
                                                                                |
   session-tray.ps1 (always running) ----reads state----> tray menu of live sessions
   session-view.ps1 (large overlay)  ----reads state----> full-screen session list
   session-stats.ps1 (dashboard)     ----reads events---> activity / focus-time charts
```

Scripts under `scripts/` are split into **entry points** (run directly / by a launcher) and
**dot-sourced modules** (libraries loaded into an entry point's scope; never run on their own).

**Entry points:**

- **session-tracker.ps1** — the only thing hooks call. Takes `-Event prompt|stop|notify|end`,
  reads the hook's JSON payload from stdin, and writes the session's state file (+ appends to
  `events.jsonl`). It **must never throw into Claude Code**: every path ends in `exit 0` and
  errors are swallowed. It also reads the session transcript to compute context-window tokens.
  **Deliberately standalone** — it does NOT dot-source the shared library, so a bug there can
  never break a hook.
- **session-tray.ps1** — the long-lived tray icon (`NotifyIcon`). Lists active sessions, lets
  you click one to focus its VS Code/Cursor window, and owns all settings toggles (DND,
  transparency, size, auto-update) which it persists as flag/text files. Hosts the global
  hotkey (Win+Alt+C) that opens the large view. Single-instance via a process scan. Dot-sources
  `session-common.ps1` + `session-pomodoro.ps1`.
- **session-view.ps1** — the large always-on-top overlay, auto-popped on `Stop` (unless
  `dnd.flag`). Same per-session data as the tray, bigger. Reads `opacity.txt` / `size.txt` live.
  Dot-sources `session-common.ps1` + `session-ui-interop.ps1` + `session-ui-icons.ps1` +
  `session-ui-repo.ps1`. The file still owns the form build, layout, row rendering, animations
  and the focus-nudge "Matrix" effect (one cohesive WinForms window).
- **session-stats.ps1** — the statistics dashboard. Reads `events.jsonl`, pairs prompt→stop
  events into "turns" to derive focus time, and draws today/week cards, a 14-day activity chart,
  and top projects. Supports `-Print` for a headless text summary (use this to test the math).
  Dot-sources `session-common.ps1`.
- **session-recap.ps1** — the weekly recap popup, auto-opened by the tray every Friday at 17:00
  (and from the tray's "Weekly recap" menu). Gathers the work week's user requests (Mon 00:00 →
  now) per project by reading the Claude Code transcripts under `~/.claude/projects/<dir>/*.jsonl`,
  pairs each project with its **completed** (ticked-done) tasks from `objectives.json` — pending
  tasks are skipped as noise — and asks an LLM for a short per-project synthesis. The provider is pluggable via `.env` (`Get-CDEnv`): `LLM_PROVIDER=ollama`
  (native `/api/generate`) or `openai` (any OpenAI-compatible `/v1/chat/completions` endpoint). LLM calls run
  in a background runspace, polled by a UI timer so cards fill in as they arrive; if Ollama is off
  or unreachable it falls back to listing the raw requests. `-Print` dumps the gathered data
  headlessly (test the parsing without UI/LLM); `-Days N` overrides the window. Dot-sources
  `session-common.ps1`.
- **session-update.ps1** — optional self-updater. Single channel: **GitHub Releases**
  (the latest release's tag is the canonical version, its attached `ClaudeDeck-Setup.cmd`
  asset is the payload — so a push to `main` without a release can never serve stale bits).
  `-Check` queries `releases/latest` (User-Agent header required by the API), compares its
  tag with the installed `version.txt` (**strictly greater** ⇒ offer the update — a local dev
  build ahead of the release never nags) and writes `update.json` (incl. `assetUrl`/`notes`).
  `-Apply` downloads the asset to TEMP, copies **itself** out of the install dir, and relaunches
  in `-Bootstrap` (detached + hidden), returning immediately so the UI never blocks. `-Bootstrap`
  is the worker: it **waits for every ClaudeDeck process to exit** (polling until the logo/font
  handles release — the real failure mode of the old 700ms-sleep design), extracts the installer's
  silent PS payload from the `.cmd` (after the `#@CDINSTALLER@#` marker — no console, no `pause`),
  runs it, writes `update-result.json` (`ok`/`version`/`error`) for the restarted tray to surface
  as a balloon, and restarts the tray itself if the install failed. NB: it must NOT use
  `Start-Process -Wait` (that blocks on the relaunched tray forever); it uses `-PassThru` +
  `$p.WaitForExit()`. Standalone (a leaf, run as a child process).
- **session-workspaces.ps1** — favorite-workspace save/restore. Dual-mode: run directly with
  `-Save`/`-Restore`/`-List`, or dot-sourced. Run as a hidden child process by the deck, NOT
  dot-sourced into it (its `param()` block + action logic would leak — see its header).
- **\*.vbs** (`start-tray`, `show-view`, `show-stats`, `show-recap`) — thin launchers that run the matching
  `.ps1` via `powershell -WindowStyle Hidden` so there's no console flash. Shortcuts and the
  tray menu always go through these, never the `.ps1` directly.

**Dot-sourced modules** (pure definitions; param-less and side-effect-light so they're safe to
load into a live WinForms scope — see `session-common.ps1`'s header for the rules):

- **session-common.ps1** — the shared library every UI script loads: the data-layout paths
  (`Get-CDRoot` / `Get-CDPath`), UTF-8-no-BOM writes (`Get-CDUtf8` / `Write-CDText`), the flag
  toggle (`Toggle-Flag`), the per-project colour/badge helpers (`Get-ProjectColor` /
  `Get-Initials` / `Get-TextOn` / `Hue2Rgb`), the `.env` reader (`Get-CDEnv`, with built-in
  defaults), and the self-updater bridge (`Get-LocalVersion` / `Invoke-Updater` / `Get-UpdateInfo`).
  Single source of truth for things that used to be copy-pasted across the deck, tray and stats.
- **session-pomodoro.ps1** — the whole Pomodoro engine + the foreground-activity classifier,
  loaded by the tray. Runs its own 1s timer, publishes `pomodoro.json`, consumes
  `pomodoro-cmd.txt`, and exposes `Get-PomoCategory` / `Play-PomoChime` (also used by the tray's
  focus nudge). The deck only *renders* `pomodoro.json` and writes control tokens.
- **session-ui-interop.ps1** — the deck's native types: `[WinFocus]` (find/raise IDE windows,
  global mouse polling, taskbar flash), `[VDesk]` (follow the active virtual desktop) and
  `[NoActivateForm]` (a Form that never steals keyboard focus). Pure `Add-Type`.
- **session-ui-icons.ps1** — Material icon font loading + glyph/badge rendering for the deck
  (`$script:MAT`, `New-IconFont`, `Get-IconChar`, `Set-IconLabel`, `New-MatIcon`, `New-Badge`).
- **session-ui-repo.ps1** — the row context-menu helpers: resolve a session's git remote to a
  web URL + host-aware deep links (`Get-RepoWebUrl` / `Get-RepoMenuLabel` / `Get-RepoSubLinks`)
  and `Open-Terminal`.

Dot-sourcing runs a file in the **caller's** scope, so `$script:` state and `$PSScriptRoot`
stay shared — that's why the modules can define functions the entry point's controls/timers
use. All files live flat under `scripts/` (the installer and `build-setup.ps1` copy/embed
`Get-ChildItem -File` non-recursively, so a subfolder would NOT ship).

### Data & settings layout (`~/.claude/sessions/`)

All runtime state lives here, **not** in the repo. The UI and tracker communicate only through
these files:

- `state/<session_id>.json` — one per session: `project`, `last_prompt`, `status`
  (`running`/`waiting`/`done`), `updated`, `ctx_tokens`. Overwritten each event; pruned after 24h.
- `stats/events.jsonl` — append-only history (`{ ts, ev, id, project, ctx }` per line). This is
  what makes trends/durations possible; trimmed to 90 days by the stats view. When **cloud sync**
  is on, each machine appends to its own `events-<HOST>.jsonl` in the sync folder instead (so two
  PCs never collide on an append); the stats view reads every `events*.jsonl` and merges them
  (`Get-CDEventLogs`). The local `events.jsonl` keeps being read as legacy/pre-sync history.
- `objectives.json` — `{ items: { "<project>": [ { text, done, desc }, ... ] } }`: the manually-
  typed per-project TODO list. Each task has a `text` (title), a `done` flag, and an optional
  `desc` — a rich-text note stored as **RTF** (empty string when none; pure-ASCII so it survives
  PS 5.1 encoding). The deck's group header shows the list as a ONE-LINE scrollable todo (mouse
  wheel cycles tasks, a click toggles the shown task's done, the pencil opens the full add/edit/
  delete/reorder editor — the per-task Add/Edit dialog (`Edit-TaskDetail` in `session-view.ps1`)
  is a resizable window with the title plus a `RichTextBox` note + Bold/Italic/Bullet toolbar);
  the weekly recap reads only the ticked-done tasks' `text` as "completed". A legacy single
  `"<text>"` string is still read as one undone task — see `ConvertTo-CDTasks` /
  `Format-CDObjective` in `session-common.ps1`, the shared normaliser both surfaces use.
- Flag files (presence = on): `dnd.flag`, `closeoutside.flag`, `autoupdate.flag`.
- Value files: `opacity.txt` (20–100), `size.txt` (scale), `update.json` (the last `-Check`
  result: `current`/`latest`/`available`/`assetUrl`/`notes`), `update-result.json` (written by
  the updater's `-Bootstrap` worker after an install — `ok`/`version`/`error` — read once by the
  restarted tray to show a success/failure balloon, then deleted), `version.txt`,
  `update-attempted.txt` (the last version the tray tried to auto-install — with
  `autoupdate.flag` on, a found update is installed without a click; this marker caps each
  version at one automatic attempt so a failing release degrades to the manual "Install
  update" entry instead of an install/restart loop),
  `recap-shown.txt` (Monday-date tag of the last shown weekly recap, so it fires once/week),
  `sync.txt` (the cloud-sync folder path, when configured — see below).
- `.env` — user-editable settings (seeded once from `.env.example`, never overwritten): the
  weekly-recap LLM config — `LLM_PROVIDER` (`ollama`|`openai`), `LLM_URL`/`LLM_MODEL`/`LLM_API_KEY`
  for the OpenAI-compatible path, the legacy `OLLAMA_URL`/`OLLAMA_MODEL` for the native path
  (honoured as fallbacks), plus `LLM_ENABLED`/`LLM_TIMEOUT` and `RECAP_INCLUDE_OUTCOMES`/
  `RECAP_OUTCOME_CHARS`. Read via `Get-CDEnv`. Saved recaps land in `recaps/recap-<Monday>.md`.

**Cloud sync (optional, opt-in).** Set a folder kept in sync across machines (Google Drive /
OneDrive / Synology Drive) via the deck's gear menu ("Cloud sync folder…") — the path is stored
in `sync.txt`. Only the **portable** user data follows you: `objectives.json` (one shared file)
and the activity history (per-machine `events-<HOST>.jsonl`, conflict-free). Machine-local things
(live `state/`, flags, opacity/size, version) never sync. The mechanism lives in `session-common.ps1`
(`Get-CDSyncDir` / `Get-CDObjectivesPath` / `Get-CDEventWritePath` / `Get-CDEventLogs` / `Set-CDSyncDir`);
the tracker mirrors the event-path logic inline (`Get-EventLogPath`) since it can't dot-source the lib.
Every helper falls back to the local copy when the folder is unset or temporarily unreachable (drive
not mounted yet), so nothing ever breaks. `objectives.json` is single-file last-write-wins (rare
two-PC-at-once edits can lose one side); events are per-host so they never collide.

### Hooks wired by the installer

`install.ps1` merges these into `~/.claude/settings.json` (idempotently — it matches on a marker
string, never duplicates): `UserPromptSubmit`→tracker prompt, `Stop`→tracker stop **and** the
view auto-popup, `Notification`→tracker notify, `SessionEnd`→tracker end.

### PowerShell 5.1 conventions (recurring gotchas)

These patterns are deliberate across the codebase — match them:

- **Always write UTF-8 without BOM** via `[System.IO.File]::WriteAllText(..., $utf8NoBom)`;
  `Set-Content`/`Get-Content -Raw` mangle accents on PS 5.1.
- **No non-ASCII literals in source.** Build glyphs from code points (`[char]0x2014` for an em
  dash, etc.) so files survive any encoding.
- **`ConvertFrom-Json` unwraps single-element arrays** into bare objects — re-wrap with `@(...)`
  before serializing, or Claude Code rejects `settings.json` ("Expected array, received object").
- **The tracker must never fail loudly.** `$ErrorActionPreference = 'SilentlyContinue'` + `exit 0`.

## Key fact: the app runs from the installed copy, not the repo

The tray and view run from `%USERPROFILE%\.claude\sessions\`, **not** from `scripts/` in
this repo. Editing a script in the repo has **no effect** on the running app until it's
redeployed. Each script is a hidden `powershell.exe` process launched via `wscript`.

## Testing changes — do this after EVERY code change

Apply this systematically whenever you modify any script under `scripts/`:

1. **Kill the running app** (tray, large view, and stats window; the single-instance guard
   otherwise makes a fresh process `exit 0`):
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
     Where-Object { $_.CommandLine -like '*session-tray.ps1*' -or $_.CommandLine -like '*session-view.ps1*' -or $_.CommandLine -like '*session-stats.ps1*' } |
     ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```

2. **Run the edited script straight from the repo** (fastest iteration — scripts read state
   from `~/.claude/sessions/state/` and `stats/` via hardcoded paths, so this reflects your
   edits live):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-view.ps1   # large view
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-tray.ps1   # tray
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-stats.ps1  # stats window
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\session-stats.ps1 -Print  # stats math, headless
   ```
   Running in a visible terminal (no `-WindowStyle Hidden`) surfaces PowerShell errors —
   use it for debugging. `-Print` is the fastest way to sanity-check stats computations.
   The tracker can't be run usefully on its own — it needs a hook JSON payload on stdin.

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
self-updater reads **GitHub Releases** (`releases/latest`), so the final `gh release create`
(with the `.cmd` attached as an asset) is **mandatory, not optional** — without it, pushing
to `main` ships nothing to update clients (the tag drives `version.txt`, the published release
is what `-Check` compares against and `-Apply` downloads):

```powershell
git commit ...                     # land your changes first
git tag v0.1.2                     # patch bump from the latest tag
powershell -File .\tools\build-setup.ps1     # writes scripts/version.txt + regenerates the .cmd from the tag
powershell -File .\tools\verify-bundle.ps1   # expect "--- ALL MATCH ---"
git add scripts/version.txt ClaudeDeck-Setup.cmd
git commit -m "Release v0.1.2: regenerate version.txt and installer from tag"
git tag -f v0.1.2                  # move the tag onto the release commit
git push origin main && git push origin v0.1.2
gh release create v0.1.2 ClaudeDeck-Setup.cmd --title "ClaudeDeck v0.1.2" --notes "..."  # REQUIRED: the updater's channel
```

## Language

All user-facing text and comments are in **English**. Keep it that way.
