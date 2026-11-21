# Paranoid Mode

Paranoid Mode makes sure ClaudexBar talks to **Claude** and **Codex** only
while your Mac's internet traffic leaves from a country you allow. If the
exit IP is anywhere else — or its country can't be confirmed — nothing is
sent: no usage poll, no token refresh, no sign-in, no auto-start message.

It's off by default. Turn it on in the menu: **Paranoid Mode → Only Send
Claude / Codex Requests From Allowed Countries**.

## Who it's for

Use it if you reach Claude or Codex through a VPN or proxy and must never
contact them from another location, for example:

- your account, plan or workplace policy expects requests from one country,
  and a request from elsewhere could get it flagged or limited;
- your VPN sometimes drops or reconnects to a different node, and you'd rather
  have ClaudexBar pause than leak a request over your real connection;
- you route by application (per-process rules) and want proof that
  ClaudexBar's traffic really takes the intended path.

Without a VPN or proxy it does nothing useful: your exit IP is simply your
own, and you'd only be checking your home country.

## How it works

1. Before a Claude or Codex request, ClaudexBar asks **three independent
   GeoIP services** which country its current exit IP is in:
   - Cloudflare — `https://1.1.1.1/cdn-cgi/trace` (the `loc=` line);
   - IPinfo — `https://api.ipinfo.io/lite/me` with a token, or
     `https://ipinfo.io/json` without one (see below);
   - GeoJS — `https://get.geojs.io/v1/ip/geo.json` (no key, no published
     rate limit).
2. The request goes out only if **at least two of the three** answer with a
   country on your list — or see one of your [trusted exit IPs](#trusted-exit-ips).
3. A service that fails counts *against*: a timeout (6 s), an error, an
   unreadable answer or a used-up quota is a "no". With one service down,
   the other two must both agree. It *fails closed*.
4. A blocked request is never sent. A token refresh that's held back doesn't
   spend the refresh token, and your login isn't marked expired.

### Why three, and why a majority

GeoIP databases disagree, especially about VPN and hosting addresses, and
each corrects itself on its own schedule. For one Amsterdam VPN exit, IPinfo
said Germany for a while and then fixed it — just as Cloudflare's database
started saying Germany. With two services that both had to agree, requests
stayed on hold for days although the exit never moved. With three, one
outdated database is outvoted; two that agree on another country still
block.

Keep in mind that Cloudflare sits in front of many websites and passes them
the country *its* database names. When Cloudflare is the one outvoted, a
Cloudflare-fronted service may still see you in that other country.

The GeoIP lookups are made by the ClaudexBar process itself, through the same
network session as the provider requests. So per-process routing rules
(VPN/proxy apps that route by process name) send the checks exactly the way
they send the requests they guard.

### What is checked

| Covered | Not covered |
|---|---|
| Claude: usage, plan (profile), token refresh, in-app sign-in (code exchange) | OpenRouter, OpenCode Go, OpenCode Free |
| Codex: usage, banked resets, `codex login` start | CLI updates (`npm`/`brew` downloads) |
| Auto-start 5h Session: checked right before the CLI is launched | Your own use of `claude` / `codex` in a terminal |

### How often it checks

- **While the country matches:** one check per polling round. Claude and
  Codex are polled together and share it; the few calls of one poll are
  covered by a 20-second cache.
- **While requests are on hold:** the blocking answer stands for up to 5
  minutes, so a long outage doesn't burn through a GeoIP quota.
- **At once** on a network change (VPN up/down, Wi-Fi switch, interface
  change), a settings change, or **Check Exit IP Now…**.

If your VPN app switches to another node without the Mac seeing a network
change, the switch can take up to 5 minutes to be noticed — use **Check Exit
IP Now** to skip the wait.

## Choosing countries

**Paranoid Mode → Allowed Countries** has checkboxes for NL, DE, LV, FR, GB,
FI, NO, DK, PL, ES, IT and US. **Add Country Code…** accepts any two-letter
ISO 3166-1 code (BE, SE, CH, …). You can allow several; at least one always
stays checked. The default is the Netherlands (NL).

## Trusted exit IPs

If you know your VPN's exit address, you can vouch for it: **Paranoid Mode →
Trust Current Exit IP (…)** (offered once a check has run) or **Add Trusted
Exit IP…** (any IPv4 or IPv6 address). When at least two of the three
services see a trusted IP, requests go out **whatever country the databases
put it in**. This is the sturdiest check when the databases keep arguing: an
address you know is yours beats anyone's guess about where it is.

- If the VPN switches to another node or drops, the services see a different
  IP and the country rule applies again — so a lost tunnel still blocks.
- Trust only your own VPN's dedicated or fixed exit. A shared exit used by
  many customers proves only that you're on that provider.
- Click a trusted IP in the menu to remove it. The addresses aren't written
  to the log; **Copy Diagnostics** shows only how many there are.

## The IPinfo token (recommended)

Without a token, IPinfo's public endpoint allows **1,000 requests a day per
IP address — shared by everyone using that IP.** Behind a VPN, that's every
other customer on the same exit node. A 1-minute refresh alone needs about
1,440 checks a day, so without a token the quota will run out and Paranoid
Mode will hold your requests until it resets.

A free **IPinfo Lite** token has no daily or monthly cap for country lookups.

### Getting one

1. Sign up at [ipinfo.io/signup](https://ipinfo.io/signup) (free, no card).
2. Open [ipinfo.io/dashboard/lite](https://ipinfo.io/dashboard/lite) and copy
   your **access token** (a short string of letters and digits).
3. In ClaudexBar: **Paranoid Mode → Set IPinfo Token…**, paste it, **Save**.

The menu then shows **IPinfo token: set — no daily limit**, and a check
runs right away; its dialog shows `ipinfo.io (Lite token): NL — Netherlands`
when the token works.

### How the token is handled

- Stored in your login Keychain (item `ClaudexBar-IPinfo-Token`), written by
  ClaudexBar itself — so reading it never shows a Keychain prompt.
- Sent only to `api.ipinfo.io`, only in the `Authorization` header — never
  in a URL, never in the log or in **Copy Diagnostics** (which only says
  "set" / "not set").
- **Remove IPinfo Token** deletes it; ClaudexBar goes back to the public
  endpoint and its daily limit.
- If you ever shared it somewhere, regenerate it in the IPinfo dashboard and
  set the new one.

Please paste the token through the menu rather than adding the Keychain item
yourself (e.g. with `security add-generic-password`): an item created by
another program makes macOS ask for permission, again after every update.

## Reading the status

**Check Exit IP Now…** asks all three services right away and opens a dialog
with the answer: each service's country and the exit IP it saw (or why it
failed), your allowed countries and trusted IPs, the rule ("2 of 3"), and
whether Claude/Codex requests are sent or on hold. It works
with Paranoid Mode off too — handy to see what it would decide before you
turn it on. With the mode on, a successful check also lets a held-back
Claude/Codex poll go out at once.

The same result stays in the **Paranoid Mode** submenu, second line:

| Shown | Meaning |
|---|---|
| `Exit IP in NL — ✓ sending (12:03:41)` | All three services say NL; requests go out |
| `Exit IP in NL (2 of 3 sources; 1.1.1.1 says DE) — ✓ sending` | Outvoted: one database disagrees, the majority says NL |
| `Exit IP 203.0.113.7 is trusted (sources say DE) — ✓ sending` | A trusted exit IP; the country doesn't matter |
| `Exit IP in DE — ✗ holding requests` | The exit country isn't allowed |
| `GeoIP sources disagree (DE / NL); 1 of 3 confirm an allowed country, 2 needed — ✗ …` | Not enough agreement (often one service down plus one that disagrees) |
| `GeoIP lookup failed (ipinfo.io: daily limit reached …) — ✗ …` | IPinfo's quota is used up — add a token |
| `GeoIP lookup failed (ipinfo.io: token rejected (HTTP 403)) — ✗ …` | The token is wrong or revoked |
| `GeoIP lookup failed (1.1.1.1: timed out) — ✗ …` | A service couldn't be reached |
| `Not checked yet` | No Claude/Codex request has needed a check since launch |

In the provider list, a held-back Claude or Codex row shows **`geo`**. The
tray keeps the last known figures at full brightness for up to 5 held-back
polls in a row, then dims them to show they're no longer current; the tooltip
says why and since when. The first successful request brings everything back.

When a GeoIP quota runs out you also get **one notification per day** (UTC),
and the log (**⌥ → Open Logs…**) gets one line saying which service hit its
limit. Requests stay on hold the whole time — Paranoid Mode never falls back
to sending unchecked.

## Limits of the check

Paranoid Mode checks the country of the IP that the GeoIP services see. That
is the right IP as long as the GeoIP requests and the Claude/Codex requests
leave the same way. It is **not** protection against:

- **DNS leaks.** Resolving `api.anthropic.com` or `chatgpt.com` through your
  local DNS server happens outside this check.
- **Split routing by destination.** If your VPN routes by domain or IP (not
  by process), the GeoIP services may go one way and Claude/Codex another.
- **IPv4 vs IPv6 paths** that exit in different places.
- **The CLIs.** Auto-start sends its message through the `claude` / `codex`
  CLI, a separate process. The check runs right before the launch, but if
  your routing rules match by process name, add those CLIs to them too.
- **A VPN dropping in the milliseconds** between the check and the request.

## Troubleshooting

- **Always `geo`, status says a country you didn't expect** — check which
  node your VPN is on, then **Check Exit IP Now…**.
- **"sources disagree"** — first open **Check Exit IP Now…**: if all three
  show the *same IP* but different countries, it's the databases arguing —
  trust that IP (if it's really your VPN's). If they show *different IPs*,
  your VPN sends some traffic another way; check its split-tunnel / per-app
  settings.
- **"daily limit reached"** — set an IPinfo token (above).
- **"token rejected"** — copy the token again from the IPinfo dashboard.
- **Turning it off** — uncheck the first item in **Paranoid Mode**; Claude
  and Codex are polled again immediately.
