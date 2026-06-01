# ClaudeDeck

> A minimalist Windows dashboard to keep an eye on all your running [Claude Code](https://claude.com/claude-code) sessions at a glance — and jump straight to the right editor window.

When you juggle several very different projects, two costs pile up: knowing **which session needs you**, and **reloading context** when you switch. ClaudeDeck shows every open Claude Code session in one place — whether Claude is **working**, **waiting for you**, or **done**, with the last prompt for each — and lets you click to focus the exact VS Code / Cursor window. It lives in your system tray, with a large always-on-top overview that pops up whenever a task finishes.

No Node, no Python, no dependencies — just PowerShell and a few Claude Code hooks.

## Features

### See everything at a glance

- **System-tray icon** — click for a compact list of your sessions.
- **Large centered overview** — a big, readable panel (great on 4K) that pops up automatically when a task finishes, or on demand. Auto-fits its height to the number of sessions; flicker-free (only repaints when something actually changes).
- **Three live states** — a spinning indicator while Claude works, 🟠 **waiting for you** (permission / question), ⚪ finished — each with the last prompt and elapsed time. Sessions that need you sort to the top and **breathe orange**, so you never miss a blocked one.
- **Per-project badge** — a stable colour + the project initials in a square badge at the start of each row (and a colour swatch in the tray menu), so different repos are instantly recognisable.

### Know what just happened

- **"Who just finished?" highlight** — when the overview pops up, the row of the session that just completed pulses green for a moment.
- **Unopened-completion border** — a finished session you haven't opened yet gets a subtle blue outline; it clears the moment you click the row.
- **Forgotten-task reminder** — a gentle nudge if a finished task sits unattended for a while.

### Act fast

- **Click to focus** — clicking a session brings its VS Code / Cursor window to the front, **without resizing or moving it**.
- **Global hotkey** — `Win+Alt+C` opens/focuses the overview from anywhere (configurable; falls back automatically if the combo is taken).
- **Follows you across virtual desktops** — the overview appears on whichever Windows virtual desktop you're on (uses only the documented `IVirtualDesktopManager` API, so it won't break on Windows updates).
- **Pinned to the primary monitor** — always shows on the screen with the taskbar, never drifts to a second monitor.

## Screenshots

> *Add your screenshots here (`docs/tray.png`, `docs/overview.png`).*

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) or PowerShell 7
- [Claude Code](https://claude.com/claude-code)
- VS Code and/or Cursor (the click-to-focus targets their windows)

## Install

### One file, one click (recommended)

1. Download **[`ClaudeDeck-Setup.cmd`](ClaudeDeck-Setup.cmd)** (right-click → *Save link as…*).
2. Double-click it.

That's it. It's a single self-contained file — every script is embedded inside it, so there's nothing else to download and it works offline. No Node, no Python, no `git`.

> **First run:** Windows may show *"Windows protected your PC"* (SmartScreen) or a *"Do you want to run this file?"* prompt, because the file isn't code-signed. Click **More info → Run anyway** (or **Run**). You can inspect the file in any text editor first — it's plain text.

### From source (developers)

```powershell
git clone https://github.com/hydropix/claude-deck.git
cd claude-deck
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> **Maintainers:** `ClaudeDeck-Setup.cmd` is generated from `install.ps1` + `scripts/`. After changing either, regenerate it with `powershell -ExecutionPolicy Bypass -File .\tools\build-setup.ps1` (and optionally verify the embed with `.\tools\verify-bundle.ps1`), then commit the updated `.cmd`.

### What the installer does (either way)

1. Copy the scripts to `%USERPROFILE%\.claude\sessions\`.
2. Merge the required hooks into `%USERPROFILE%\.claude\settings.json` (idempotent — it backs up the file first and never removes your existing hooks).
3. Create a Startup shortcut (tray launches at logon) and a Desktop shortcut for the large view.
4. Start the tray immediately.

> The tray icon may land in the hidden-icons area on Windows 11 — click the `^` chevron near the clock, then drag it onto the taskbar to pin it.

## Usage

- **Tray icon** → click for the compact session list; click a row to focus that session's editor window.
- **Large view** → opens automatically when a task finishes, or via the global hotkey **`Win+Alt+C`**, the **ClaudeDeck (grand)** desktop shortcut, or the tray menu **Afficher en grand**. Close it with **`Esc`** or the **✕**.

## Options

Options live in the tray menu (state stored as small files under `~/.claude/sessions/`):

| Option | Default | Effect |
| --- | --- | --- |
| **Ne pas deranger** (Do Not Disturb) | off | Suspends the auto-popup on task completion and the forgotten-task reminders. |
| **Fermer au clic exterieur** (close on outside click) | **off** | When on, the overview also closes on a click anywhere outside it (0.5s grace to avoid accidental closes). `Esc` / **✕** always work. |
| **Transparence** (transparency) | Legere (92 %) | Sets the overview window opacity: Aucune / Legere / Moyenne / Forte (100 / 92 / 80 / 65 %). Applied live. |
| **Taille** (size) | Normale (55 %) | Sets the overview width: Compacte / Normale / Large / Tres large (42 / 55 / 68 / 82 % of screen width). Applied live. |
| **Mises a jour automatiques** (auto-update) | **off** | When on, ClaudeDeck checks the GitHub repo a couple of times a day for a newer version. See [Updates](#updates). |

**Position:** the overview header has three buttons next to **✕** — ▲ (top), ▬ (center), ▼ (bottom) — to dock the window to the top, middle, or bottom of the primary screen. The active one is highlighted; the choice is remembered.

**Change the hotkey:** edit `$HotMods` / `$HotVk` near the bottom of `scripts/session-tray.ps1` (the modifier/virtual-key tables are in the comments). The Windows key alone is mostly reserved by the OS, so `Win+Alt+<key>` is the reliable space.

## Updates

ClaudeDeck can keep itself up to date from this GitHub repo — **opt-in, and off by default**.

- Turn it on with the tray menu **Mises a jour automatiques** (or check on demand with **Verifier les mises a jour**).
- When enabled, the tray compares the installed version (`~/.claude/sessions/version.txt`) with [`scripts/version.txt`](scripts/version.txt) on the `main` branch a couple of times a day. The check runs in a hidden background process, so it never blocks the UI; if you're offline it simply does nothing.
- If a newer version exists you get a tray balloon and an **Installer la mise a jour (vX)** entry at the top of the menu. Clicking it downloads the latest [`ClaudeDeck-Setup.cmd`](ClaudeDeck-Setup.cmd) and runs it — the same idempotent installer, so it refreshes the scripts, re-merges hooks, and restarts the tray.
- The current version is always shown at the bottom of the tray menu.

> The updater lives in [`scripts/session-update.ps1`](scripts/session-update.ps1). Forking? Change the `$Owner` / `$Repo` / `$Branch` variables at the top so it points at your own repo.
>
> **Maintainers:** the version number comes from the latest **git tag** — that's the single source of truth. To publish a release: `git tag v1.1.0`, then run `tools/build-setup.ps1` (it writes `scripts/version.txt` from the tag and regenerates `ClaudeDeck-Setup.cmd`), then commit the regenerated `version.txt` + `.cmd` and push (`git push && git push --tags`). Installed clients with auto-update on pick it up on their next check.

## How it works

A few Claude Code hooks write a tiny JSON state file per session under `~/.claude/sessions/state/`:

| Hook | Action |
| --- | --- |
| `UserPromptSubmit` | mark the session **running** + record the prompt |
| `Notification` | mark the session **waiting** when Claude needs a permission/approval |
| `Stop` | mark the session **done** + pop the large overview (unless DND) |
| `SessionEnd` | remove the session |

Two PowerShell apps read those files:

- `session-tray.ps1` — the tray icon, compact menu, global hotkey, and reminders.
- `session-view.ps1` — the large always-on-top overview.

Clicking a session resolves the matching IDE window by its title (e.g. `… - MyProject - Visual Studio Code`) and brings it to the foreground; if no window matches, it falls back to opening the folder in the real VS Code.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the scripts, the shortcuts, and the ClaudeDeck hooks from `settings.json` (leaving your other hooks intact).

## Notes & limitations

- Hooks use Claude Code's `"shell": "powershell"` option.
- The **waiting** state is detected from permission/approval notifications; idle and auth notifications are ignored.
- Click-to-focus matches the project folder name in the window title; sessions opened directly in your home folder may not match (no folder name in the title).
- The large view "follows" you to the active virtual desktop within ~350 ms of switching.
- Per-project colours come from a hash of the project name, so two names can occasionally land on a similar hue.

## License

MIT — see [LICENSE](LICENSE).
