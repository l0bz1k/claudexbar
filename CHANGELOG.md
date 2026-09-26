# Changelog

All notable changes to ClaudexBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.2.1] — 2026-09-27

Bug-fix release from a full code review of the fork.

### Fixed
- **Auto-start 5h Session could switch itself off permanently after a network
  blip.** A CLI launch that failed before the message left the Mac (no
  network, proxy 403, timeout) was counted as "anchor sent but the window
  didn't start"; two of those tripped the circuit breaker for good, with only
  a menu subtitle as a hint. Launch failures are now rolled back (they no
  longer consume the cooldown, the daily cap or the breaker) and retried with
  a 5 → 60 min exponential backoff. A breaker that does trip now re-arms after
  24 h, posts a notification once, and logs only on state changes instead of
  on every poll. Breakers left tripped by 0.2.0 are cleared on upgrade.
- **Corrupted HTTP cache flooding the error log.** Requests went through
  `URLSession.shared`, whose on-disk SQLite cache got corrupted and then
  logged three errors per poll indefinitely (3.7 MB and growing). All network
  calls now use an ephemeral, cache-less session — nothing token-bearing is
  written to disk — and the old cache is removed at launch.
- CLI version checks and updates now have timeouts (a hung `claude update`
  could previously block every later update until relaunch) and drain their
  output continuously.
- Codex requests send `chatgpt-account-id`, so accounts with several
  workspaces see the limits of the one Codex actually uses.
- Token-refresh form bodies escape `+`, `&` and `=` correctly.
- "Launch at Login" waits for `launchctl` instead of racing bootout/bootstrap.

### Changed
- Failed auto-start and CLI-update runs log a short, secret-redacted excerpt
  of the CLI's stderr, so failures are diagnosable.
- Logs are rotated at 1 MB (one previous generation kept); the launchd stderr
  capture is trimmed at launch when oversized.
- Usage refreshes shortly after the Mac wakes instead of on the next timer tick.
- Keychain read errors other than "not found" are reported to the unified log
  (`log show --predicate 'subsystem == "com.ipang.claudexbar"'`).
- Persisted auto-start state decodes tolerantly, so future fields won't reset
  cooldowns and caps on upgrade.

## [0.2.0] — 2026-09-26

Patched fork ([l0bz1k/claudexbar](https://github.com/l0bz1k/claudexbar)) with
fixes for issues found running this daily on a ChatGPT Go + Claude Pro setup.

### Fixed
- Codex: non-standard rate-limit window durations (e.g. the ChatGPT Go plan's
  30-day/2,592,000s window) no longer throw a decode error ("err" in the
  tray); the window is shown with a dynamically computed label (e.g. "30d")
  instead of the hardcoded "5h"/"1w".
- Countdown labels keep the minute remainder instead of rounding down to
  whole hours (e.g. "4h35m" instead of "4h").
- Tray text no longer clips its trailing character on some values (e.g.
  "3h1m" rendering as "3h1").

### Changed
- Tray rendering switched to a proper template image: fully transparent
  background matching every other menu-bar icon (previously an opaque
  light/dark "pill"), and the provider glyph was removed to save horizontal
  space. Column widths are now measured from the actual text on every
  redraw, so the tray is never wider than its content.

### Added
- Opt-in, per-provider "Auto-start 5h Session" feature: detects an
  idle/unstarted rate-limit window and anchors it by sending one trivial
  message through the real `claude`/`codex` CLI (not a raw API call), so
  idle time before your first prompt of the day isn't wasted. Includes a
  proactive check scheduled ~1 minute after a window's known reset time,
  cooldown/daily caps, and a circuit breaker that disables itself after
  repeated failed anchors. Off by default for both providers.

## Unreleased

### Changed
- Simplified Codex support to a single default account at `~/.codex/auth.json`.
- Removed Codex account hiding, hidden-account restore, manual account rescan,
  account badges, and per-account smart-switch detection.
- Kept provider-level enable/disable, paused/off, smart switching, and re-auth
  for the two supported providers: Codex and Claude Code.
- Redesigned smart auto switch: the pill now follows the provider that is
  actually consuming usage (works for CLI, desktop, web, and remote sessions)
  or the one clearly in the foreground; with no signal it stays on your last
  choice instead of falling back to Codex.
- Removed the filesystem-activity heuristic and its 5-second `~/.codex` /
  `~/.claude` scans.

## [0.1.0] — 2026-06-03

Initial release.

### Added
- Native AppKit menu-bar app (no Dock icon) showing Codex and Claude Code usage.
- Codex usage from `~/.codex/auth.json`; Claude Code usage via the OAuth usage endpoint.
- Claude Code authentication via in-app OAuth (Authorization Code + PKCE): browser
  sign-in, one code paste, full scopes, stored in the Keychain and auto-refreshed
  (8-hour token). See [docs/AUTH.md](docs/AUTH.md).
- Right-click menu: per-provider enable checklist that stays open while toggling;
  hold ⌥ Option to reveal Re-auth and Open Logs; Refresh All; Check for Updates.
- Left-click cycles the active provider; compact two-window pill (session + weekly).
- Threshold notifications (remaining-percentage based) and re-auth failure notifications.
- Lightweight update check against GitHub releases (no third-party dependencies).
- Security hardening: tokens only ever in the Keychain; all log lines routed through
  `SecretScanner` redaction.
