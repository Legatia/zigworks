# harness 0.3: the agent's own logins

The owner asked for a way to give the agent "some kind of login credentials,
like an account for the agent itself", then "something like passkeys for
agents", then: "spec it, plan it, build it end to end". Cards and payments
stay with the owner for now (see IDEAS.md).

Stays: one Zig binary, std only, every action through the one gate, one
hash-chained log, secrets masked in all tool output, the model never sees a
secret value.

## What the owner does

```
harness login add github-bot --site github.com --username agent-bot@example.com
Password for github-bot (not shown; empty: the agent makes one when it signs up):
TOTP secret for github-bot (not shown; empty for none):
Stored github-bot in the macOS Keychain.

harness login list
harness login rm github-bot
```

In chat: `/logins` lists them (name, site, username, password yes/no,
TOTP yes/no, passkeys N). Logins are the agent's own accounts, never the
owner's; the README says so.

## Storage

- `logins.ini` in the data folder (not secret): `[NAME]`, `site = HOST`,
  `username = …`. Refused if other users can write it, like `rules`.
- In the key store (same store as `harness secret`):
  `login-NAME-password`, `login-NAME-totp` (base32 seed),
  `login-NAME-passkeys` (JSON list of credentials: id, rpId, PKCS#8 private
  key, user handle, sign count; all base64).
- `profiles/NAME/` in the data folder: the login's own browser profile
  (cookies survive between sessions), created 0700. `login rm` deletes it
  and the three secrets.
- Names: a-z, 0-9, `-`, `_`; sites: a host name (no scheme, no path).

## The `web` tool

An interactive browser for the model, one tool with actions. A session is a
headless Chrome driven over the DevTools protocol through a pipe
(`--remote-debugging-pipe`, fds 3 and 4), never a network port.

```json
{"action":"open","url":"https://github.com/login","login":"github-bot"}
{"action":"type","ref":2,"text":"{login:github-bot.password}","enter":true}
{"action":"click","ref":5}
{"action":"key","key":"Enter"}        // Enter, Tab, Escape
{"action":"read"}
{"action":"close"}
```

- `open` with `login`: the login's persistent profile and its passkeys.
  Without: a throwaway profile, deleted at close (like browse).
- Every action returns the page afterwards: URL, title, a numbered list of
  the interactive elements of the top document (inputs with type and label,
  buttons, links, selects), then the readable text (page.extract), capped at
  `tool_output_bytes`. Elements carry a `ref` the next action uses.
- One session per turn; it closes at the end of the turn, on `/stop`, and on
  `close`. Cookies of a login's profile survive, so the next turn is still
  signed in.
- Placeholders in `type` text: `{login:NAME.username}`,
  `{login:NAME.password}`, `{login:NAME.code}` (the current TOTP code). They
  are filled in by harness; the model's input, the log and the gate show the
  placeholder.
- **Domain binding.** A placeholder is filled only if the page the value is
  typed into is on the login's site: the host equals the site or is a
  subdomain of it, and the scheme is https (http only when the site is
  `localhost`). The check and the typing happen in one script in the page,
  so a navigation in between can't redirect the value. Only top-document
  fields are listed and typed into, never iframes. A refused fill says why
  and types nothing.
- **Generated passwords.** If the login has no password and the model types
  `{login:NAME.password}` on the login's site, harness makes one (24
  characters, letters, digits, symbols), stores it, then types it. For
  sign-up pages.
- **Passkeys.** A session opened with a login gets a software security key
  (the DevTools protocol's virtual authenticator: CTAP2, internal transport,
  resident keys, user verification) loaded with the login's stored
  passkeys. After every action harness reads the authenticator's
  credentials back: new or changed credentials whose rpId belongs to the
  login's site are saved to the key store; any other credential is removed
  from the authenticator and the result says so. So the agent can add a
  passkey on a site's settings page and sign in with it next time, and a
  passkey can't be made or used for another site.
- Masking: the web tool's output masks every login's password, TOTP seed and
  current code, and the scrub list gets stored login passwords at start.
- POSIX only in 0.3 (the pipe uses fds 3 and 4). On Windows the tool says
  it isn't available yet; a handoff covers it (Chrome takes pipe handles
  there).

## The gate

- New kind `web`; argument: the page's host. Default `ask`; a 24 h grant
  covers the host, as for fetch and browse. Checked on `open` and again on
  every later action whose page host differs from the last one granted in
  this session (a click that lands on another site asks).
- New kind `login`; argument: `NAME HOST`. Checked the first time a session
  fills a login's placeholder or loads its passkeys (`open` with `login`).
  Default `ask`, grants allowed (a 24 h grant covers that login on that
  host).
- Scheduled runs: `ask` is deny, as everywhere.
- Helpers never get `web`.
- The tool's input in the log keeps the placeholders; the fill, the refused
  fill, saved and removed passkeys are logged as lines of their own (names
  and hosts only).

## Out of 0.3

Cards and payment logins, SMS and e-mail codes (the agent asks the owner),
CAPTCHAs (the agent tells the owner; never solved), sharing logins with
helpers, a browser on Windows, screenshots.

## Calls I made (owner can change)

- One `web` tool with actions rather than six tools: fewer tool
  definitions in every request.
- Session per turn, not per conversation: simpler stop rules; persistent
  profiles keep the sign-in.
- Passkeys through Chrome's virtual authenticator instead of our own
  WebAuthn code: Chrome does the protocol and the origin checks; we hold the
  keys and decide which rpIds may exist.
- Typing by setting the field's value in a page script (with input and
  change events) instead of key events: makes the host check and the fill
  one step.
