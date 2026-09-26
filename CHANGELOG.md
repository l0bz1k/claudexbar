# Changelog

All notable changes to ClaudexBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

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
