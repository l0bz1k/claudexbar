<p align="center">
  <img src="assets/icon.png" width="120" alt="ClaudexBar">
</p>

<h1 align="center">ClaudexBar</h1>

<p align="center">
  Codex &amp; Claude Code usage limits in your macOS menu bar — zero-config, native, dependency-free.
</p>

<p align="center">
  <a href="https://github.com/l0bz1k/claudexbar/actions/workflows/ci.yml"><img src="https://github.com/l0bz1k/claudexbar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
</p>

> **This is a patched fork** of [ipangdz/claudexbar](https://github.com/ipangdz/claudexbar).
> Grab the latest build from [Releases](https://github.com/l0bz1k/claudexbar/releases).

A small native macOS menu-bar app that shows **Codex** and **Claude Code** usage limits at a glance. Zero-config: it reuses your existing CLI login, shows each provider's session (5-hour) and weekly windows, and warns before you run low — no API keys, no browser cookies, no dependencies.

## What's different from upstream

This fork exists to fix a handful of real issues hit running the original daily on a ChatGPT Go + Claude Pro setup:

- **Codex on the ChatGPT Go plan no longer shows `err`.** The Go plan reports a single, non-standard 30-day quota window instead of the usual 5-hour/weekly pair; upstream's parser didn't recognize it and failed to decode. It's now shown correctly, with a dynamically computed label (e.g. `30d`) instead of a hardcoded one.
- **Countdown labels no longer round down to whole hours.** `4h35m` used to display as `4h` (the minutes were silently dropped once the countdown passed the one-hour mark); it now shows the real remaining time.
- **Transparent menu-bar icon.** The pill used to paint its own opaque light/dark background — the only icon in the menu bar that didn't blend in like every other one. It's now a proper template image, matching native menu-bar icons, and the tray is only ever as wide as its actual text (no more wasted space, no more clipped trailing characters like `3h1` instead of `3h1m`). The provider glyph was also dropped to reclaim horizontal space.
- **Opt-in "Auto-start 5h Session".** If a rate-limit window sits idle/unstarted while you're away, this sends one trivial message through the real `claude`/`codex` CLI to start its clock early, so idle time before your first prompt of the day isn't wasted quota. Off by default, per provider, with a cooldown, a daily cap, and a circuit breaker that disables itself after repeated failed attempts until you manually re-enable it.

- **Used or remaining %, pace warning, tooltip, diagnostics.** Optionally show *used* % like the Claude/ChatGPT apps; a ▲ marks a window you're on pace to exhaust before it resets; hovering explains every number; **Copy Diagnostics** produces a redacted report for bug reports.
- **"Launch at Login" no longer quits the app when unchecked**, plus a round of reliability fixes from a code review (no on-disk HTTP cache, timeouts on every CLI call, log rotation, refresh on wake).

Full details, including the two real bugs found and fixed along the way, are in [CHANGELOG.md](CHANGELOG.md#020--2026-09-26).

## Screenshots

<p align="center">
  <img src="assets/Screenshot.png" width="640" alt="ClaudexBar"><br>
  <em>Codex &amp; Claude Code usage right in the menu bar — right-click for the menu, hold ⌥ Option for re-auth.</em>
</p>

## Features

- Native AppKit menu bar app with no Dock icon and no main window.
- Two providers only: Codex and Claude Code.
- Codex auth from `~/.codex/auth.json`. Claude Code auth from a ClaudexBar-managed OAuth credential in Keychain (`ClaudexBar-Claude-Credentials`), falling back to `CLAUDE_CODE_OAUTH_TOKEN` and Claude Code's own `Claude Code-credentials` login.
- Re-auth: Codex opens `codex login` in Terminal; Claude Code opens your browser to Claude's sign-in page. After you approve, Claude shows a one-time code — paste it into the ClaudexBar dialog and it stores its own access+refresh credential (no Terminal).
- Configurable refresh interval and remaining-usage notifications.
- No telemetry, analytics, or browser cookies. The only value you paste is the one-time Claude authorization code, which is exchanged for a token and never stored.

## Install

Works on **both Apple Silicon and Intel** Macs (macOS 13+).

1. Download `ClaudexBar.zip` from [Releases](https://github.com/l0bz1k/claudexbar/releases/latest).
2. Unzip it and move `ClaudexBar.app` to `/Applications` (or `~/Applications`).
3. Open it. It isn't notarized (no Apple Developer ID), so Gatekeeper will
   refuse to launch it normally the first time — **right-click the app →
   Open → Open** to confirm you trust it. You only need to do this once.
4. Optional: turn on **Launch at Login** from its menu.

**After installing or updating, macOS asks once for Keychain access** ("ClaudexBar wants to use your confidential information…") — click **Always Allow**. Because the app is ad-hoc signed rather than signed with a Developer ID, macOS ties that permission to the exact build, so it asks again after each update. Until you answer, Claude Code usage shows `wait`.

To update later, download the new release and repeat steps 1–2 (step 3 is only needed again if you moved or re-downloaded the app).

The app is a menu-bar accessory (`LSUIElement`), so its icon appears in Finder/Spotlight rather than the Dock.

## Uninstall

1. Quit ClaudexBar (right-click the menu-bar icon → **Quit**, or select it and press `⌘Q`).
2. Move `ClaudexBar.app` to the Trash.
3. If you had turned on **Launch at Login**, remove its LaunchAgent:
   ```bash
   launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.ipang.claudexbar.plist 2>/dev/null
   rm -f ~/Library/LaunchAgents/com.ipang.claudexbar.plist ~/Library/LaunchAgents/com.ipang.claudexbar.cli-updater.plist
   ```
4. Optional — remove its settings and logs:
   ```bash
   defaults delete com.ipang.claudexbar 2>/dev/null
   rm -rf ~/Library/Logs/ClaudexBar
   ```

This does not touch Codex or Claude Code credentials.

## Usage

ClaudexBar can switch providers automatically: when both providers are enabled, it watches lightweight local context (foreground app/window text and recent Codex/Claude session-file activity) and switches only after one provider has been the clear winner for a short debounce window. It does not use CPU usage or shell process scans as deciding signals.

The right-click menu can also check and update the installed Claude Code and Codex CLIs. **Daily Auto-update** uses a low-priority macOS LaunchAgent and the CLIs' own `update` commands; turning it off removes only ClaudexBar's updater job. Claude Code may still use its own native auto-updater.

Left-click the pill to cycle between enabled providers. Manual clicks still work in auto mode and temporarily pin your choice so the pill does not jump around while you move between tools. If only one provider is enabled, left-click leaves that provider selected. Right-click for the menu.

The right-click menu lists the two providers, Codex and Claude Code, as 1-click checkbox rows:

- The checkbox toggles whether the provider is enabled (both enabled → left-click cycles between them; only one enabled provider → ClaudexBar stays on it; none enabled → paused/off).
- The row shows that provider's live usage (`5h% · 7d%`), or a status word (`auth` / `net` / `err`) when there is a problem.
- Re-auth actions are exposed through ⌥ Option alternates.
- **Hold ⌥ Option** to swap **Open Logs…** into the maintenance area.

Below the providers are Refresh All, Smart Auto Switch, Launch at Login, Refresh Interval, and Notify When Remaining.

The left usage column is the current session window. The right column is the weekly budget. Session usage also chips away at the weekly budget.

## Troubleshooting

- `auth` for Codex: run `codex login`.
- `auth` for Claude Code: choose `Re-auth` → `Claude Code` from the ClaudexBar menu. Your browser opens to Claude's sign-in page (`claude.com/cai/oauth/authorize`). Approve access; Claude's callback page then shows a one-time `code#state` string. Copy it and paste it into the ClaudexBar dialog (it pre-fills from your clipboard when it recognises a code). ClaudexBar exchanges it for an access+refresh credential — with the full scopes the usage endpoint needs — stored in the Keychain service `ClaudexBar-Claude-Credentials`, then refreshes usage. The code and tokens are never logged.
- Why a paste (and not a fully automatic flow): Claude's OAuth client does not accept a `localhost` redirect, so the authorization code is returned to Claude's own callback page rather than to ClaudexBar directly. The one paste bridges that page back to the app.
- Why a separate credential: Claude Code's own `Claude Code-credentials` login rotates its refresh token on every refresh, so a background menu-bar app reading that snapshot would be invalidated whenever Claude Code refreshes (and vice versa). ClaudexBar runs its own OAuth sign-in to get an independent credential it refreshes on its own (the access token lasts ~8 hours and is refreshed automatically).
- `login` stuck in the pill: the code exchange is still running or failed. Check `auth` afterwards and re-run `Re-auth` → `Claude Code`.
- `auth` right after re-auth: the paste may have been incomplete. Re-run and paste the entire `code#state` string from Claude's page.
- If you want terminal Claude Code sessions to use a manually generated token too, set:

  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN='<token>'
  ```

- Claude `err`/HTTP 403: the stored credential lacks a required scope. Run `Re-auth` → `Claude Code` again — ClaudexBar requests the correct scope set itself. (Note: `claude setup-token` is **not** used; its token has too narrow a scope for the usage endpoint. See [docs/AUTH.md](docs/AUTH.md).)
- `net`: the usage endpoint could not be reached or may be rate limited. Use the provider's `Refresh` from the menu a little later.

## Non-goals

- No history graphs.
- No cost estimation.
- No embedded/in-app web view: sign-in happens in your real browser via the official CLI.
- No additional providers in MVP.

## Documentation

- [docs/AUTH.md](docs/AUTH.md) — how Codex and Claude Code authentication work, and why.
- [SECURITY.md](SECURITY.md) — security model and how to report a vulnerability.
- [CHANGELOG.md](CHANGELOG.md) — release notes.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The project is
deliberately narrow (Codex + Claude Code only) and dependency-free.

## Credits

All credit for the original design and implementation goes to
[ipangdz](https://github.com/ipangdz) — this fork exists only to carry a
handful of fixes and one opt-in feature on top of that work. If you don't
need those specifically, the [original project](https://github.com/ipangdz/claudexbar)
is the one to use and support.

## License

[MIT](LICENSE).
