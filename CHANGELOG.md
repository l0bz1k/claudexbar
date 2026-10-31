# Changelog

All notable changes to ClaudexBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.7.1] — 2026-10-31

### Changed
- Providers are listed alphabetically in every menu.
- A provider that's switched off shows "off" instead of "wait" (it isn't
  polled at all, so "wait" looked like it was loading).
- The menu keeps showing a provider's last known figures through a transient
  error (rate limit, network blip), like the tray already did, instead of
  flashing "net".

### Fixed
- **Polling no longer hammers a rate-limited endpoint.** After an HTTP 429 the
  next poll of that provider waits 2, 4, 8… minutes (capped at 10), and a
  success resets it; "Refresh All" always goes out. Anthropic's usage
  endpoint had started refusing about every other per-minute poll.

## [0.7.0] — 2026-10-31

### Added
- **AI Golden Hour** (Auto-start 5h Session → AI Golden Hour). Pick a time of
  day; every day while it's on, session windows are timed so they reset —
  back to 100% — at that time. A window resets a fixed time after it starts,
  so ClaudexBar anchors it that much earlier (09:00 for a 14:00 golden hour
  with 5-hour windows). Windows that fit before then still start as usual —
  none are skipped; only the one that would still be running at the anchor
  time is held until it. Works for every provider with a session window,
  whatever its length. The picker suggests now + 5 h 01 min; a time less than
  a window away starts working the next day. If a window is already running
  at the anchor time (you were working), you get one notification that
  today's golden hour isn't reachable, and the usual schedule continues. With
  the lid closed the anchor goes out at the next wake, so the reset can come
  late.

### Changed
- Auto-start's cooldown and daily attempt cap follow the window's length
  (one attempt per window, minus 10 minutes for providers that round a
  window's start down), instead of a fixed 5 hours / 5 per day.

## [0.6.1] — 2026-10-30

### Changed
- **Choose which CLIs get updated.** "CLI Updates" now lists Codex, Claude
  Code and opencode with checkboxes; both "Update Selected CLIs Now" (renamed
  from "Update Claude & Codex Now") and the daily auto-update only touch the
  checked ones. Codex and Claude Code are checked by default; opencode is not —
  its releases include major-version jumps. opencode updates with its own
  `opencode upgrade`, which detects brew/npm/curl installs.
- The update result window lists only the CLIs that were actually updated.

## [0.6.0] — 2026-10-30

### Added
- **OpenCode Free** provider — opencode's own free tier (Zen free models).
  It has no usage API: the server only answers "Free usage limit reached"
  (HTTP 429 + `Retry-After`) when a request is refused. opencode stores that
  response, headers included, in its local database; ClaudexBar reads the
  newest one (read-only, no network) and shows 0% with a countdown to the
  reset. Otherwise it shows "ok" — the remaining free allowance is never
  reported, so there's no honest percentage to show. Opt-in in the menu.
- **opencode's version** on the OpenCode Free row, green when current and
  orange when a newer release exists — like Codex and Claude Code. It's
  deliberately **not** auto-updated: opencode releases include major-version
  jumps (1.x → 2.x), which should be your call.

### Changed
- **Usage figures in the menu line up in columns.** The name column is as
  wide as the longest provider name (with its version), the first figure is
  right-aligned and the second follows a common separator, so session values
  sit under session values and weekly under weekly.

## [0.5.0] — 2026-10-30

### Added
- **OpenRouter** provider: the free-model daily request quota (resets at
  00:00 UTC) and the prepaid credit balance — or the key's own spending limit
  when one is set — from `openrouter.ai/api/v1/key` and `/credits`.
- **OpenCode Go** provider: the subscription's rolling 5-hour, weekly and
  monthly limits from the official `opencode.ai/zen/go/v1/usage` endpoint.
  The tray shows the 5-hour window plus whichever of weekly/monthly is closer
  to running out; all three are in the tooltip.
- Both read the API key opencode already stores (`~/.local/share/opencode/
  auth.json`, or `OPENROUTER_API_KEY` / `OPENCODE_API_KEY`), so there's nothing
  extra to configure. They're off by default: turn them on in the menu.
  ⌥ → "Re-auth" runs `opencode auth login`.
- Tooltips use each window's own name ("Free-model requests today", "Credit
  balance", "Monthly limit").

### Notes
- The OpenCode Go response format is taken from its documentation and
  community clients and hasn't been verified against a live Go account yet;
  the parser accepts the documented and alternate field layouts.

## [0.4.3] — 2026-10-29

### Fixed
- **Repeated Keychain password prompts.** Since 0.3.3 every poll read *all*
  credential sources up front, including Claude Code's Keychain item, even
  while ClaudexBar's own session worked. Claude Code rewrites that item when it
  refreshes its token, which resets the item's access list — so each of those
  refreshes cost a password prompt (and the pending prompt stalled Claude
  updates in the tray). Sources are now read lazily: Claude Code's item is only
  touched when ClaudexBar's own session can't be used.

## [0.4.2] — 2026-10-28

### Fixed
- **In-app update failed on a single dropped connection.** Downloads are now
  retried up to three times with a short pause — proxied/VPN connections to
  GitHub drop now and then, and a 404 can briefly appear while a release's
  files are being re-uploaded. A failure now says why (HTTP status or network
  error) instead of just "download failed".
- A successful update no longer leaves its work folder in the temporary
  directory; leftovers from interrupted updates are removed at launch.

## [0.4.1] — 2026-10-28

### Changed
- **A Cloudflare block now shows as "vpn" instead of "err".** chatgpt.com and
  claude.ai sit behind Cloudflare, which can refuse a distrusted IP (often a
  VPN/proxy exit) with an HTML "Unable to load site" page and HTTP 403. That
  used to surface as a generic "err", which looks like an app or CLI bug. It's
  now recognised (403 + HTML + Cloudflare markers only), the tray shows "vpn",
  and the tooltip and log name the blocked IP and suggest another proxy node.
- Hovering a status word ("auth", "net", "vpn", "err") now explains it.

## [0.4.0] — 2026-10-28

### Added
- **In-app updates.** ClaudexBar checks this fork's GitHub releases once a
  day (at launch, after wake, and on an hourly tick once a day has passed —
  the schedule survives sleep and relaunches). A newer version appears at the
  top of the menu as "⬆ Update to x.y.z…", with one notification per release.
  "Install and Relaunch" downloads the release, verifies it against the
  published SHA-256, checks the version and signature of the unpacked app,
  swaps it in (restoring the old one if anything fails) and relaunches.
  "Skip This Version" and "Later" are available; the release page is always
  one click away.

### Fixed
- **Update checks pointed at the upstream repository**, so a future upstream
  release would have been offered as an "update" that drops every patch in
  this fork. They now use this fork's releases.
- Update prompts no longer suggest building from source.

## [0.3.3] — 2026-10-28

### Fixed
- **Stuck on "auth" after re-logging into Claude Code.** ClaudexBar always
  preferred its own stored session, and when that session's refresh token was
  rejected it never looked at Claude Code's login — so `claude login` didn't
  help. All credential sources are now tried in order; a definitively rejected
  own session (HTTP 400/401 on refresh) is discarded so it stops shadowing a
  valid Claude Code login.
- **ClaudexBar no longer refreshes Claude Code's token.** Claude rotates the
  refresh token on every refresh, so refreshing Claude Code's credential (and
  keeping the rotated result) silently invalidated the copy Claude Code holds,
  leaving both apps sharing one session. Claude Code's token is now used
  read-only while it's valid; only ClaudexBar's own session (Re-authenticate
  in the menu) is ever refreshed.

## [0.3.2] — 2026-09-27

### Changed
- **Pace warning can be toggled per window**: Display → "Pace Warning ▲:
  Session (5h)" and "Pace Warning ▲: Weekly / Monthly". Both start from the
  previous single setting, so nothing changes until you flip one.

### Fixed
- **A started window at 100% looked unstarted.** A tiny first message (such
  as the auto-start anchor) rounds to 0% used, and the tray then showed "5h /
  100%" — identical to an idle window — even though the clock was running.
  A full window now shows its countdown once it has started; idle windows
  (Claude's null reset, Codex's "now + full length") still show "5h".

## [0.3.1] — 2026-09-27

### Fixed
- **Auto-start was late after sleeping through a reset.** With the lid
  closed the Mac only wakes for ~45 s about once an hour (Power Nap /
  DarkWake), so the detector's "three observations in a row" rule took three
  such wakes to fire — about two hours of the new window wasted — and the
  timer scheduled for just after the reset can't fire during sleep. The end of
  the last running window is now remembered on disk; once it has passed, the
  first observation of a fresh window anchors immediately (the old
  multi-sample rule still applies when no boundary is known).
- The anchor message now holds an idle-sleep assertion while the CLI runs, so
  a DarkWake doesn't put the Mac back to sleep mid-send.

## [0.3.0] — 2026-09-27

### Added
- **Show used % instead of remaining** (Display → Show Used %), matching the
  Claude and ChatGPT apps, which both show usage consumed.
- **Pace warning.** A ▲ next to a window's countdown means that at the rate
  you've been using it, the limit runs out before the window resets. Needs at
  least 10% of the window elapsed and 10% used before it projects anything,
  so a single early prompt doesn't trigger it. Toggle under Display.
- **Hover tooltip** on the menu-bar item: what each number means (left vs
  used), when each window resets, and the pace projection behind any ▲.
- **Copy Diagnostics** menu item: versions, settings, each provider's last
  response and auto-start state, which CLIs were found, and the log tail —
  secret-redacted and with the home folder shortened to `~`, ready to paste
  into an issue.

### Fixed
- **Unchecking "Launch at Login" quit the app** when it had been started at
  login: it booted out the launchd job the app itself was running under. It
  now only removes the LaunchAgent plist, which is all that's needed to skip
  the next login.

### Changed
- `ProcessRunner` moved into the core library and is now covered by tests
  (exit codes, timeouts, 1 MB output without pipe stalls, launch failures,
  redaction). 64 tests total.

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
