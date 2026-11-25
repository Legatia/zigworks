# The Desk Alone, `config set`, Local Time: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `harness run` works with the desk as the only way in, `harness config set/get` edits config.ini safely, and `[chat] utc_offset = auto` follows the computer's zone.

**Architecture:** A desk-only `Channel` (`DeskOnly`, core.zig) takes the Telegram channel's place behind the existing `DeskTee`, so every path that posts through `c.chan` reaches the desk unchanged; `Core.alone` marks the mode for the few places that differ (echo skipped, unknown conversations to main with their name in front, non-item buttons carried on the desk and pressed through a new `POST /desk/api/press`). `config set` reuses `mail.setKey` + `parseProblem(config.parse)` + `util.writeReplace`. Local time: `Config.utc_auto` set by the parser; `Core` resolves `cfg.chat.utc_offset` from `zones.localNow` at every settings load and once a minute in `tick`, so the ~80 readers of the `i32` see the current offset with no call of their own.

**Tech Stack:** Zig 0.17.1, std only; POSIX sh smoke test; desk page JS.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, section "First run, and the desk alone (added 2026-11-25)": "harness runs with the desk alone", "`harness config set`", "Local time".

## Global Constraints

- Zig `~/.local/zig/zig-aarch64-macos-0.17.1/zig`; std only; cross builds for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl must pass (`zig build` and `zig build unit-build`).
- With a bot token stored and `[chat] telegram = on`: behaviour byte-for-byte as before, pairing included.
- Start lines, verbatim: `Telegram is off. The desk is the only way in.` / `No bot token is stored under "NAME", so Telegram is off. The desk is the only way in.`
- `config set`: exit 0 on success; non-zero, one line on stderr, file untouched when the result doesn't parse. Comments and order kept. `provider NAME.url` names a named section; a missing section is added at the end.
- `utc_offset = auto` is what `init` writes; `+HH:MM` unchanged; an unreadable zone is UTC, said once at start.
- No edits to: `src/desk/fit.js`, `src/desk/avatar.js`, `tools/`, `desk-assets/`, NOTICE files, the asset-serving part of `appserver.zig`, the avatar stage and Settings parts of `desk.js`/`index.html`/CSS, `.github/workflows/`, `desk-app/`.
- Copy: plain labels and sentences, no slogans, no real names.

## Review Focus

1. A post to a household member's or a group's conversation while Telegram is off: must fail as "not delivered" (logged, kept per `worthRetry`), never be counted as told. Test in Task 2 (`desk_only_refuses_shared_conversations`).
2. A press on the desk of a button whose message was edited or is gone: the desk answers "That button is out of date." and nothing runs. Test in Task 3.
3. `config set` on a key that doesn't exist, a value that doesn't parse, and a pasted secret in a `key`/`token` setting: refused, file byte-identical. Tests in Task 5.
4. Desk-alone with `[apps] on = off`: exits with one line naming what to turn on, instead of running with no way in. Smoke check in Task 4.
5. Daylight saving: the offset in use changes without a restart. Test in Task 6 (`auto_offset_follows_the_zone_at_each_refresh`, with a stubbed reader).

---

### Task 1: The desk's history keeps buttons and the channel's message id

**Files:** Modify `harness/src/deskwin.zig` (Msg, History, msgJson + tests).

**Interfaces — Produces:**
- `Msg.chan: i64 = 0` (the channel's message id; never in JSON), `Msg.buttons: []const [2][]const u8 = &.{}` (label, data; JSON carries labels only, as `"buttons":["Taken"]`, and only when non-empty).
- `History.edit(h, a, chan: i64, text: ?[]const u8) !?Found` — the message with that `chan` (non-zero): its text replaced when given, its buttons dropped; returns it with its conversation, copied into `a`.
- `History.find` (exists) returns `buttons` and `chan` too.

- [ ] Test `buttons_are_kept_labels_shown_and_an_edit_drops_them`: add a msg with `.chan = 900, .buttons = &.{.{"Taken","mtok:taken"}}`; `msgJson` has `"buttons":["Taken"]` and not `mtok`; `edit(a, 900, "Taken at 08:01.")` returns its conv; listed again: text replaced, no `"buttons"`; `edit(a, 901, null)` is null.
- [ ] Run, watch it fail; implement (dupe/free buttons in add/freeMsg/copyMsg); pass; commit.

### Task 2: `DeskOnly` channel and `Core.alone`

**Files:** Modify `harness/src/core.zig` (new `DeskOnly`, `Core.alone`, `Core.attachAlone`, DeskTee changes, `placeOf`, `deskEcho`, `whyUndelivered`/`worthRetry`, `deskRecord` taking chan+buttons, tests near the desk tests).

**Interfaces — Produces:**
- `pub fn attachAlone(c: *Core) void` — `c.alone = true`, attaches `c.desk_only.channel()` through `attach`.
- `DeskOnly` methods: `send` → `Sent{.first = next(), .count = 1}`; `buttons` → `next()`; `clear`, `edit` no-ops at this level; `document` keeps the file (Task 3 rules: `state/desk-files/`, basename only, private file) and returns `next()`. Ids from a counter seeded with `util.nowMs` (unique across restarts). Each refuses (`error.TelegramOff` / null) a place whose conversation the desk doesn't show (`deskShows(place.name)` false: shared, member, mail).
- `error.TelegramOff`: `whyUndelivered` → "Telegram is off"; `worthRetry` false.
- In `alone`: DeskTee notes carry `chan` (the id the inner returned) and the non-item buttons; `DeskTee.edit`/`clear` call `c.deskEdited(chan, text)` which updates history and pushes feed event `edit` (`{"conv":…,"msg":…}`).
- `placeOf`: in `alone`, a name harness doesn't know goes to main with its name in front (as Telegram without topics), not under its own name.
- `deskEcho`: returns at once in `alone`.

- [ ] Tests (fixture: `Fix` without the recorder, `attachAlone`, no `setOwner`):
  - `desk_alone_reply_reaches_the_desk_unpaired`: queue a turn in main (scripted reply "Three flats match."); desk history of main has it from harness.
  - `desk_alone_unknown_conversation_goes_to_main_with_its_name`: `sayIn("news", "x")` → main's history has `[news] x`.
  - `desk_only_refuses_shared_conversations`: a shared conv added; `deliverIn(shared, …)` returns `error.TelegramOff`; no desk history for it.
  - `desk_alone_no_echo`: `deskSend` in alone mode with `[desk] echo` on: no error, the turn runs.
  - `desk_alone_start_warning_reaches_the_desk`: `pending_warning` set before `attachAlone` → main's history has it.
- [ ] Watch them fail; implement; pass; commit.

### Task 3: Pressing a message's button on the desk

**Files:** Modify `harness/src/core.zig` (`handleCallbackText` split into owner check + `ownerPress`; `Emergency.press` split into `pressBy(is_owner)`; `deskPress`; `deskApiIn` route `press`), `harness/src/desk/desk.js` (chat messages only: render `m.buttons` under the text, click → `post("press",{id:m.id,n:i})`, show `said`; event `edit` replaces the message in `S.msgs`).

**Interfaces — Produces:** `POST /desk/api/press {"id":DESK_MSG_ID,"n":INDEX}` → `{"ok":true}` or `{"said":"That button is out of date."}`; 404 for no such message; works only in `alone` (else "Buttons are pressed in Telegram.", 409).

- [ ] Tests: `desk_press_takes_a_medication_reminder` style is heavy; use quick replies: a post with quick replies (`sendWithButtons` labels "Yes","No") in alone mode; press n=0 through `deskApiIn` → a turn queued with text "Yes"; second press of the same → out of date (the buttons were dropped by the edit/clear or quick post gone). Plus `desk_press_acks_an_urgent_alert`: an alert posted with [I'm on it] in alone mode, press → alert acked by owner. Plus `a_file_is_kept_for_the_desk`: a post with a file in alone mode → file in `state/desk-files/`, desk line names it.
- [ ] Fail, implement, pass, commit.

### Task 4: `harness run` with the desk alone; init's next steps; doctor; usage

**Files:** Modify `harness/src/main.zig` (`runCmd`, `usage`, `initText` + its test), `harness/src/doctor.zig` (Bot line when off/no token), `harness/scripts/smoke.sh`, `harness/src/fake_main.zig` + `harness/src/fake.zig` (`--desk-enter HOME` prints a session cookie; `--desk-api HOME COOKIE METHOD PATH [BODY]` prints the status then the body).

- `runCmd`: Telegram unusable (off, or no token) → if no desk server (`!cfg.apps.on` or `c.app_server == null`) fail with one line: `Telegram is off and so is the desk's server; turn on [apps] on in config.ini, or Telegram ([chat] telegram = on and harness secret add NAME)` (no-token variant names the secret). Else print the spec's line on stderr, `attachAlone`, say the line once in main, start worker, `poller_on`, ticker, then wait for `quitting`. The "running on" line drops "not paired yet" in this mode.
- `initText` (both variants): Next: 1 provider + key, 2 `harness run`, 3 `harness open`; then "Telegram, for your phone (optional): harness secret add telegram, then harness pair while harness runs, and send /pair CODE to the bot."
- usage: `run  run the agent: the desk, the scheduler, and Telegram when a bot token is stored`.
- doctor: telegram off → ok, "Telegram is off in config.ini; the desk is the way in (harness open)"; no token → ok, "No bot token stored, so Telegram is off; the desk is the way in. For your phone: harness secret add NAME".
- [ ] Unit test of `initText` updated first (fails), then code. Doctor test line 447 updated first.
- [ ] Smoke: a fresh home, no telegram secret, a task `every = 5m` (its reply first), harness run → stderr has the no-token line; desk enter; task result in main's history; send a message → reply seen; a shell call not allowed → item in state → answered `once` via `answer` → the turn's final reply seen; `[apps] on = off` + no token → run exits 1 with the one line. Commit.

### Task 5: `harness config set` / `config get`

**Files:** Create `harness/src/config_cmd.zig` (pure: `pub fn parseKey(args) ?Key`, `pub fn setText(a, text, key, value) !Result`, `pub fn getValue(a, text, key) !Got`, tests); modify `main.zig` (dispatch `config`, usage lines, running note).

**Interfaces:** `Key = struct { section: []const u8, key: []const u8 }`; `parseKey` takes `["model.url"]`, `["provider local.url"]`, or `["provider","local.url"]`. `setText` → `.{ .text }` or `.{ .refused = LINE }`; `getValue` → `.{ .value }` or `.{ .refused = LINE }`.
- Refusals: no `.` → usage; unknown section/key → "config.ini has no setting SECTION.KEY"; parse fails → `Not changed: config.ini line N has an error: …` (from `core.parseProblem`); a `key`/`token` setting whose value isn't a secret's name → "SECTION.KEY takes a stored secret's name (a-z, 0-9, - and _); store the value with harness secret add NAME".
- `get`: the file's value when set, else the default (reflection over `Config`), `off` for a null optional, `auto` for an auto offset, "" for a provider key unset.
- Running (`lockHeld`): stdout "harness is running: send /reload to use it." or, for `chat.telegram`, `chat.token`, `apps.*`, `voice_agent.listen`, "harness is running: restart it to use this (harness stop, then harness run)."
- [ ] Tests (fail first): comments/order kept; named section updated in place; missing section appended; bad value refused with the line; unknown key refused; pasted key refused; get default / set / provider; CRLF kept. Smoke: set then get round-trips; a bad `chat.utc_offset = 5` exits non-zero, one stderr line, file `cmp`-identical. Commit.

### Task 6: `utc_offset = auto`

**Files:** Modify `harness/src/zones.zig` (`pub fn localNow(io, a, now_s) ?i32`: Windows `GetTimeZoneInformation` declared by hand, else `offsetAt(.., "", now_s)`; pure `pub fn windowsOffset(ret: u32, bias, std_bias, dst_bias: i32) ?i32`), `config.zig` (`Config.utc_auto`, parse of `auto`, defaults_ini line), `core.zig` (`refreshLocalTime`: at loadSettings, and in tick at most once a minute; `sayAtStart` once when unreadable; `local_reader` seam for tests), `main.zig` (`log search`), `hermes_import.zig` (no DST note when auto).
- [ ] Tests first: `parse` of `auto` sets `utc_auto` and a later `+01:00` clears it; defaults_ini has `utc_offset = auto`; `windowsOffset(2, -60, 0, -60) == 120` (Warsaw summer), `(1, -60, 0, -60) == 60`, `(0xFFFFFFFF, …) == null`, `(0, 300, 0, -60) == -300`; core `auto_offset_follows_the_zone_at_each_refresh` with a stub reader returning 60 then 120; `unreadable_zone_is_utc_and_said_once`.
- [ ] Implement; pass; cross-build windows; commit.

### Task 7: Docs and review

- README: Desk section notes Telegram is optional; `config set/get`; `utc_offset = auto`. Ledger/plan rulings. One fresh reviewer on the branch diff + spec; one fix pass.

## Rulings (recorded as made)

1. Non-item buttons (quick replies, Undo, [Taken], helpers, money pause, [I'm on it]) are carried on the desk only in desk-alone mode; with Telegram the desk shows them as before (none). Cost if wrong: presses missing on the desk with Telegram on, as today.
2. Files a post carries are kept in `state/desk-files/` and the desk names them. Cost: a file the owner must open from the folder.
3. Posts to shared conversations (groups, members) fail as "Telegram is off" and are not retried. Cost: the household isn't told while Telegram is off.
4. `config set` takes `provider NAME.url` as one argument or two words. `get` prints `auto` for an auto offset.
7. `config set` takes several `KEY VALUE` pairs in one call, written together and parsed once: a new provider's `api` and `url` only read together, so the app's "Other" needs one call (`config set "provider other.api" openai "provider other.url" URL model.provider other`). The spec's one-pair form is unchanged. Cost if wrong: the app builder uses a form the spec didn't name.
8. `config set` keeps the changed line's own comment and changes the last occurrence (the one in use); a setting named `key` or `token` takes only a secret's name (a-z, 0-9, - and _). A value with control characters or ` ;`/` #` is refused.
9. A running harness after `config set`: "send /reload" except `chat.telegram`, `chat.token`, `apps.on`, `apps.port` ("restart"). Nothing is printed when harness isn't running.
10. Desk alone, `/conversation new`: "Conversations other than main are Telegram topics, and Telegram is off." Topics made before still work on the desk.
11. doctor: no bot token or Telegram off is fine (the desk is the way in), not a failure.
12. `utc_offset = auto` is resolved at settings load and once a minute in the tick (under the settings lock); readers keep reading the `i32`. `config.Config.utc_auto` is not a key of its own.
5. TZ environment variable is not read; the system's zone is.
6. Offset refreshed once a minute; a time computed for the future uses today's offset.

## Done

Tasks 1 to 7 done; see the branch log. Verification and review results are in the branch's final report.
