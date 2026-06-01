# ClaudeDeck

> A minimalist Windows dashboard to keep an eye on all your running [Claude Code](https://claude.com/claude-code) sessions at a glance — and jump straight to the right editor window.

ClaudeDeck shows every open Claude Code session in one place: what each one is doing, whether Claude is **working** or **done**, and lets you click to focus the exact VS Code / Cursor window for that task. It lives in your system tray, with a large always-on-top overview that pops up whenever a task finishes.

No Node, no Python, no dependencies — just PowerShell and a couple of Claude Code hooks.

## Features

- **System-tray icon** — click it for a compact list of your sessions.
- **Large centered overview** — a big, readable panel (great on 4K). Opens automatically every time Claude finishes a task, or on demand.
- **Live status per session** — 🟢 green dot = Claude is working, ⚪ grey dot = finished, with the last prompt and how long ago.
- **"Who just finished?" highlight** — when the overview pops up, the row of the session that just completed pulses green for a moment, so you instantly see which one called you.
- **Click to focus** — clicking a session brings its VS Code / Cursor window to the front **without resizing or moving it**.
- **Follows you across virtual desktops** — the overview appears on whichever Windows virtual desktop you're currently on (uses only the documented `IVirtualDesktopManager` API, so it won't break on Windows updates).
- **Pinned to the primary monitor** — always shows on the screen that has the taskbar, never drifts to a second monitor.
- **Flicker-free** — only repaints when something actually changes.

## Screenshots

> _Add your screenshots here (`docs/tray.png`, `docs/overview.png`)._

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) or PowerShell 7
- [Claude Code](https://claude.com/claude-code)
- VS Code and/or Cursor (the click-to-focus targets their windows)

## Install

```powershell
git clone https://github.com/hydropix/claude-deck.git
cd claude-deck
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer will:

1. Copy the scripts to `%USERPROFILE%\.claude\sessions\`.
2. Merge the required hooks into `%USERPROFILE%\.claude\settings.json` (idempotent — it backs up the file first and never removes your existing hooks).
3. Create a Startup shortcut (tray launches at logon) and a Desktop shortcut for the large view.
4. Start the tray immediately.

> The tray icon may land in the hidden-icons area on Windows 11 — click the `^` chevron near the clock, then drag it onto the taskbar to pin it.

## Usage

- **Tray icon** → click for the compact session list. Click a row to focus that session's editor window.
- **Large view** → opens automatically when a task finishes, or via the **ClaudeDeck (grand)** desktop shortcut, or the tray menu **Afficher en grand**. Close it with the **✕** or **Esc**.

## How it works

Three Claude Code hooks write a tiny JSON state file per session under `~/.claude/sessions/state/`:

| Hook | Action |
| --- | --- |
| `UserPromptSubmit` | mark the session **running** + record the prompt |
| `Stop` | mark the session **done** + pop the large overview |
| `SessionEnd` | remove the session |

Two PowerShell apps read those files:

- `session-tray.ps1` — the tray icon and compact menu.
- `session-view.ps1` — the large always-on-top overview.

Clicking a session resolves the matching IDE window by its title (e.g. `… - MyProject - Visual Studio Code`) and brings it to the foreground.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the scripts, the shortcuts, and the ClaudeDeck hooks from `settings.json` (leaving your other hooks intact).

## Notes & limitations

- Hooks use Claude Code's `"shell": "powershell"` option.
- Click-to-focus matches the project folder name in the window title; sessions opened directly in your home folder may not match (no folder name in the title).
- The large view "follows" you to the active virtual desktop within ~350 ms of switching.

## License

MIT — see [LICENSE](LICENSE).
