# harness logins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent gets its own accounts: stored logins filled into pages by placeholder, bound to their site, with TOTP codes, generated passwords and passkeys, through a new interactive `web` tool.

**Architecture:** Three new modules (totp, logins, cdp) and the `web` tool module; wiring in gate, agent, core and main. Chrome is driven over the DevTools protocol through a pipe; passkeys use Chrome's virtual authenticator with keys kept in harness's key store.

**Tech Stack:** Zig 0.17.1 (`~/.local/zig/zig-aarch64-macos-0.17.1`), std only, headless Chrome.

**Spec:** `docs/superpowers/specs/2026-11-21-harness-logins-design.md` (binding).

## Global Constraints

- Branch `harness-logins` in `~/Desktop/zig-tools`. Do not push; do not touch branch `harness` (another session works there).
- std only; no new dependencies. Every new Core field initialised in `Core.open` (it sets `c.* = undefined`).
- Secret values never reach the model, the log, the gate text, or test output.
- Copy: plain labels, no slogans (README, help, chat text).
- `zig build test --summary all` in `harness/` must stay green (unit tests then `scripts/smoke.sh`); the cross builds must still compile: `zig build -Dtarget=x86_64-windows`, `-Dtarget=x86_64-linux-musl`, `-Dtarget=aarch64-linux-musl`.
- Tests that need Chrome skip (`error.SkipZigTest`) when `page.findBrowser` finds none, and on Windows.
- Commits end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01LRd9ysiExbunyd7Zje5Zjv`

## Review Focus

1. A page that navigates (or redirects) between the host check and the fill must not receive the value: the check and the fill are one page script.
2. A login placeholder typed on `evil.com` for site `github.com`, or on `github.com.evil.com`, or on `http://github.com`, is refused and types nothing.
3. A passkey created for an rpId outside the login's site is removed and never stored.
4. Chrome must not outlive the session (stop, timeout, turn end, crash of harness's request): kill the process group as `page.render` does.
5. The model's input with placeholders is what the log and gate show; no value in any log line, including errors from Chrome (scrub them).

---

### Task 1: TOTP (`harness/src/totp.zig`)

- `pub fn base32Decode(out: []u8, in: []const u8) ![]u8` — RFC 4648 alphabet, case-insensitive, ignores spaces and `=`.
- `pub fn code(seed: []const u8, unix_s: i64) [6]u8` — RFC 6238, HMAC-SHA1, 30 s step, 6 digits.
- Tests: RFC 6238 SHA1 vectors with seed `"12345678901234567890"`: t=59 → `287082`, t=1111111109 → `081804`, t=1234567890 → `005924`, t=2000000000 → `279037`; base32 of `"JBSWY3DPEHPK3PXP"` decodes to `"Hello!\xde\xad\xbe\xef"`.

### Task 2: Logins (`harness/src/logins.zig`)

- `Login{ name, site, username }`; `pub fn parse(arena, text) ![]Login` (ini sections, `site`, `username`; rejects bad names/sites).
- `pub fn validName`, `pub fn validSite` (lowercase host, labels a-z0-9-, dots, no scheme/path/port).
- `pub fn hostAllowed(site, scheme, host) bool` — host == site or ends with "." ++ site; scheme https, or http when site is `localhost`.
- `pub fn rpIdAllowed(site, rp_id) bool` — rp_id == site, or site ends with "." ++ rp_id (a parent domain the site may use, but never a bare public suffix: require at least one dot in rp_id unless rp_id == site), or rp_id ends with "." ++ site.
- `Placeholder{ login, field: enum{username,password,code} }`; `pub fn placeholders(arena, text) ![]Span` finds `{login:NAME.FIELD}`; unknown field → error.
- `pub fn genPassword(io) [24]u8` from letters, digits and `!#$%&*+-=?@^_`, at least one of each class.
- Passkeys: `Passkey{ id, rp_id, key, user, count }` (base64 strings), `encode(arena, []Passkey)` / `decode(arena, json)`.
- Secret names: `login-NAME-password`, `login-NAME-totp`, `login-NAME-passkeys`.
- Tests: parse; hostAllowed cases from Review Focus 2 (`github.com` ok, `gist.github.com` ok, `github.com.evil.com` no, `evilgithub.com` no, http no, `localhost` over http ok); rpIdAllowed (`github.com` ok, `com` no, `evil.com` no); placeholders; genPassword classes; passkeys round trip.

### Task 3: DevTools pipe (`harness/src/cdp.zig`)

- Launch (POSIX): `/bin/sh -c 'exec "$@" 3<&0 4>&1 0</dev/null 1>/dev/null' sh BROWSER ARGS…` with stdin and stdout as pipes, stderr ignored, `pgid = 0`. Our stdin pipe becomes Chrome's fd 3 (commands in), our stdout pipe its fd 4 (replies out). Args: `--headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions --mute-audio --remote-debugging-pipe --user-data-dir=DIR about:blank`.
- Framing: each message is JSON followed by one NUL byte, both ways. A reader thread splits replies; `call(method, params_json, session_id) ![]const u8` sends `{"id":N,"method":…,"params":…,"sessionId":…}` and waits for the reply with that id (timeout from the caller, stop flag honoured); events are dropped except those a caller asked to keep (`WebAuthn.credentialAdded` is not needed: credentials are read back with `WebAuthn.getCredentials`). A reply with `error` → `error.Cdp` with the message kept for the caller (scrubbed by the web tool).
- `Session.open(gpa, io, browser, profile_dir, stop, timeout_ms)`: launch, `Target.getTargets` → first `page` target, `Target.attachToTarget {targetId, flatten:true}` → sessionId, `Page.enable`, `Runtime.enable`.
- `navigate(url)`: `Page.navigate`, then wait until `document.readyState == "complete"` (poll `Runtime.evaluate`, 50 ms) plus 300 ms settle, bounded by the timeout.
- `evaluate(expr) ![]const u8` — `Runtime.evaluate {expression, returnByValue:true, awaitPromise:true}`, returns the JSON of `result.value`; an exception → `error.Script`.
- `close()`: `Browser.close`, then kill the process group (`std.posix.kill(-pid, .KILL)`), reap, join the reader; safe to call twice.
- Windows: `Session.open` returns `error.Unsupported`.
- Tests: framing over an in-memory reader (two messages and a partial third; an event between call and reply is skipped); with Chrome: open about:blank, `evaluate("1+1")` == `2`, close leaves no process (the pid is gone).

### Task 4: The web tool (`harness/src/web.zig`)

- `Web` holds the session state for one turn: `?cdp.Session`, the login in use, its values (fetched lazily from the store), granted hosts, the authenticator id, a throwaway profile path to delete at close.
- `pub fn run(w, ctx, input_json) ![]const u8` dispatches `open/type/click/key/read/close`; every action returns `snapshot()`.
- Snapshot script (one `Runtime.evaluate`): marks interactive elements of the top document with `data-hx-ref=N` (inputs not hidden, textarea, select, button, a[href], [role=button]), returns `{url, title, html, items:[{ref, tag, type, label}]}`; label from `aria-label`, associated `<label>`, `placeholder`, `name`, or text (cut at 80). Output: `URL`, `Title`, `Elements:` lines like `[2] input password "Password"`, then `page.extract(html, url).text` cut to `tool_output_bytes`.
- `type`: if the text holds placeholders, resolve values (gate `login` once per session; password generation per the spec; `code` from totp), then run ONE script that checks `location.protocol`/`location.hostname` with `hostAllowed` rules re-implemented in JS from constants harness passes in, finds the ref, focuses it, sets the value with the native setter of its prototype, dispatches `input` and `change`, returns `"ok"` or `"wrong-site HOST"`/`"no-element"`. Values are passed as JSON string literals. Without placeholders the same script runs without the host check. `enter:true` then presses Enter (`Input.dispatchKeyEvent` keyDown/char/keyUp, `\r`, keyCode 13).
- `click`: script `el.scrollIntoView(); el.click()`, then wait for readyState complete + 300 ms.
- Gate `web` per spec: on `open` (host of the url) and before each later action if `location.hostname` differs from the last granted host.
- Passkeys: on `open` with a login, `WebAuthn.enable {enableUI:false}`, `WebAuthn.addVirtualAuthenticator {options:{protocol:"ctap2", transport:"internal", hasResidentKey:true, hasUserVerification:true, isUserVerified:true, automaticPresenceSimulation:true}}`, then `WebAuthn.addCredential` for each stored passkey (`isResidentCredential:true`). After each action, `WebAuthn.getCredentials`: drop and `WebAuthn.removeCredential` any whose rpId fails `rpIdAllowed`; if the allowed set differs from the stored one (new id or higher signCount), save it. Note removals in the result.
- Masking: the result goes through a scrubber with every login's password, TOTP seed and the codes handed out this session.
- Logging: lines `web fill NAME HOST`, `web fill refused NAME HOST`, `web passkey saved NAME RPID`, `web passkey removed NAME RPID` through the run's log.
- Tests (Chrome; pages served by the fake server under `/page/NAME`, opened as `http://localhost:PORT/...`, logins with `site = localhost`):
  - `web_fills_a_login_on_its_site`: form page whose script shows `welcome USER` when the typed password equals the expected one; type username and password by placeholder, click submit; snapshot shows `welcome agent-bot`; the value is in no tool result and no log line.
  - `web_refuses_a_login_on_another_site`: login with `site = example.com`, page on localhost → result says it was refused, field stays empty.
  - `web_makes_a_password_on_sign_up`: login without password; typing `{login:x.password}` stores a 24-char value in the store and the page receives exactly it.
  - `web_totp_code_is_current`: page displays the typed code; equals `totp.code(seed, now)` (allow the neighbouring step).
  - `web_passkey_registers_then_signs_in`: session 1 runs `navigator.credentials.create` (rp id `localhost`, user id `agent-bot`, resident key required) from a page button; passkey saved to the store; session 2 (new Chrome, same login) runs `navigator.credentials.get` without allowCredentials and shows `signed in as agent-bot`.
  - Unit (no Chrome): rpId filter keeps `localhost`, drops `example.com`.

### Task 5: Wiring

- `gate.zig`: kinds `web` and `login`, default ask, grantKey `web` = host, `login` = whole argument.
- `agent.zig`: `web_def` (description lists logins by name, site and username, says placeholders and that values are never shown); Run gets `web: ?*web.Web` created per turn and closed at turn end and on stop; helpers never get `web`; `callTool` routes `web`.
- `core.zig`: `Paths.logins` (`logins.ini`) and `Paths.profiles`; initHome creates `profiles/` (0700); Core gets `store: ?store_mod.Store` (set by main) and the parsed logins (reloaded on `/reload`; `logins.ini` refused if writable by others); `/logins`; `/status` line; stored login passwords join `secret_list`.
- `main.zig`: `harness login add NAME --site HOST [--username U] [--stdin]` (tty: two hidden prompts; `--stdin`: two lines, password then TOTP seed, either may be empty), `login list`, `login rm NAME` (secrets, profile, section in logins.ini). Help text.
- Tests: gate kinds; `toolDefs` lists `web` only when a browser is found and never for helpers; `/logins` output; CLI add/list/rm through `scripts/smoke.sh` (two new checks).

### Task 6: Docs and finish

- README: a "Logins" section (what the owner does, placeholders, domain binding, passkeys, the gate, limits incl. POSIX only, cookies on disk in `profiles/`), commands list, version 0.3.0 in `build.zig.zon` and README state line; unit test count.
- IDEAS.md: "Cards for agents: the owner handles it for now" note (placeholder fill + money gate + issuer cards, PCI for hosted) and "Agent logins: built in harness 0.3 (branch harness-logins)".
- `harness/HANDOFF-windows-web.md`: what the Windows session needs (Chrome `--remote-debugging-pipe` on Windows reads/writes inherited handles; how harness spawns; the tests to enable).
- Final: full suite, cross builds, then the review.
