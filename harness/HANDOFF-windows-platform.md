# Handoff to the Windows session: platform work (gaps 2 and 8, Windows items, hosted notes)

From the Mac session, 2026-11-22. The owner asked to spec the gaps between
harness and the "Agent platform of 2027" blueprint and to share the work
with you. Eight specs are written and reconciled; you own apps (gap 8),
environments (gap 2), the open Windows items and the hosted design notes.

## For you: the desk is approved, with a 3D head (2026-11-25)

> "Use 3d head. Finish the frontend now"

Spec: `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, now
approved, with the avatar as a live 3D head (WebGL 2, three.js vendored)
instead of video clips.

**The Mac session is building:**

- harness's side and the desk page, on `platform/desk`;
- the avatar module, on `platform/desk-avatar`;
- the macOS app, on `platform/desk-mac`.

**Yours, as the spec's "Who builds what" says:**

- the Windows app (WebView2, `WebView2Loader.dll` loaded at run time,
  `WebView2.h`'s C interfaces from Zig);
- the Linux app (GTK 3 and WebKitGTK 4.1, tested in WSLg).

Both run against the same pages and entry. What changed for you with the
3D head:

- **WebGL 2 must be on.** WebView2 has it. WebKitGTK needs `enable-webgl`
  and its hardware acceleration policy set to always; WSLg may draw it in
  software, so check the frame rate.
- **No video any more,** so the GStreamer MP4 plugins aren't needed on
  Linux.
- **The entry protocol is unchanged:**
  - `state/open-request`, then `state/desk-code` (60 s, used once), then
    `GET /enter?code=…`, which sets the session cookie;
  - `GET /alive` every 5 s while disconnected;
  - the bridge messages `{"badge": N}`, `{"attention": "urgent"}` and
    `{"reenter": true}`;
  - `state/desk.json` for the port and the binary.

`platform/desk` defines the exact paths. Pull it when it lands, or build
against the spec and adjust.

### Status, 2026-11-25 (Mac session)

| Branch | What | State |
|---|---|---|
| `platform/desk-mac` | harness-desk for macOS | merged into harness-logins (d252816): reviewed, unit 61/61, window smoke 46/46 |
| `platform/desk` | harness's side and the desk page | building; lands next |
| `platform/desk-avatar` | the 3D head module, the fit, `harness avatar check` | building; lands next |

### The desk app's code is yours to extend

It's all in `harness/desk-app/`, with its own `build.zig`, so harness's own
build stays std only and cross-builds as before.

**What's shared and what's macOS's own:**

- **Shared, pure Zig:** `src/controller.zig` makes every decision: a
  state machine, with events in and effects out. These modules feed it:

  | Module | What it does |
  |---|---|
  | `deskjson.zig` | reads `state/desk.json` |
  | `entry.zig` | the one-time code |
  | `alive.zig` | `GET /alive` |
  | `policy.zig` | which navigations stay, and the microphone |
  | `bridge.zig` | the page's messages |
  | `commands.zig` | runs `harness run`, `stop` and `autostart` |
  | `pages.zig` | the built-in "isn't running" and "Connecting…" pages |
  | `home.zig` | the data folder |
  | `args.zig` | `--home DIR` |

- **macOS only:** `src/mac/desk.m`, `desk.h` (Cocoa, WKWebView and its
  delegates), `plist.zig` and `icon.zig`.
- **Yours to add:**
  - `src/windows/`: WebView2, `WebView2Loader.dll` loaded at run time,
    `WebView2.h`'s C interfaces from Zig;
  - `src/linux/`: GTK 3 and WebKitGTK 4.1.

  Each one draws the window and forwards events to the controller, and
  the controller tells it what to do.

**Three POSIX spots to port for Windows** (the pure modules already compile
for Linux):

1. `alive.zig`'s socket. It uses libc sockets, because std's connect
   timeout panics in 0.17.1.
2. `commands.zig`'s spawnDetached process group: `harness run` has to
   outlive the window.
3. `entry.zig`'s 0600 file mode. On Windows, `%LOCALAPPDATA%`'s own ACL
   covers it.

**The stand-in harness:** `test/fake_harness.py` (Python 3, chosen so your
apps can reuse it). It:

- answers `/alive`;
- writes a `desk-code` after an `open-request`;
- serves `/enter` and a test page that posts the bridge messages.

`scripts/smoke.sh` drives the macOS app against it. Write the same smoke
for yours.

### The contract both apps keep

**Names:**

- the bridge handler is named **`harness`**:
  `window.webkit.messageHandlers.harness` on macOS. On WebView2 it's
  `window.chrome.webview.postMessage`, and the built-in page's script
  already posts there too.
- the macOS bundle is `harness-desk.app`, shown as "harness" in the Dock.

**`state/desk.json`:**

- its fields are `{binary, port, home, version}`, plus an optional `path`
  that the app passes as PATH to the commands it runs;
- only `port` is required, and unknown fields are ignored;
- the folder it was read from is the data folder for requests and
  `--home`.

**Getting in:**

1. Write `state/open-request`. It holds `pid N`, and a stale `desk-code`
   is deleted first.
2. Wait up to 30 s for `state/desk-code`, checking every 100 ms. An empty
   file means "not written yet".
3. Read the code and delete the file.
4. Load `/enter?code=…`. It answers 303 to `/desk`, or 403.

**Staying in:**

- Liveness is a 200 from `/alive` within 3 s, checked every 5 s, and also
  while the desk is shown. Two misses show "harness isn't running".
- A 401 or 403 on a desk page enters again, at most every 5 s.
- harness found on another port also enters again.

**Navigation:**

- Only `http://127.0.0.1:PORT` (and about:blank) stays in the window.
- http, https and mailto from the main frame or a new window go to the
  system browser.
- Other schemes, downloads, and `blob:` or `data:` navigations are
  cancelled.
- The microphone is granted only to the main frame on harness's origin;
  the camera is always denied.

**The bridge's messages:**

- `{"badge": N}` sets the count: cap 99999, and 0 clears it;
- `{"attention": "urgent"}` asks for attention once;
- `{"reenter": true}` enters again.

**Closing the window** keeps the app running with its badge; the taskbar
or Dock icon reopens it.

**The menu:**

- Start harness and Stop harness (`harness stop`);
- Open at login: `harness autostart on|off`. With no argument, it prints
  `on` or `off` as its first word, which drives the check mark;
- Reload, and Quit.

**harness's side, from `platform/desk`, guarantees:**

- desk.json stays when harness stops;
- desk.json and desk-code are written whole (a temp file, then rename);
- an open-request is answered within 30 s.

### The desk page and the avatar need

- **WebGL 2 on.** WebView2 has it by default. WebKitGTK needs
  `enable-webgl` and its hardware acceleration policy set to always.
  Check WSLg's frame rate: the head should hold 30 fps when resting.
- **Media and speech play without a click.** Urgent alerts are spoken at
  once.
- **No video,** so Linux needs no GStreamer MP4 plugins.

### CI and release, as the macOS app set them up

- **CI job `desk-app-macos`** (macos-15, working directory
  `harness/desk-app`), in this order:
  1. `zig build test` in Debug and ReleaseSafe;
  2. `scripts/package-macos.sh`, which builds both slices, lipo-checks
     them, lints the plist and signs ad hoc;
  3. `zig build smoke`, which prints SKIP unless the runner has an Aqua
     session. It hasn't run on CI yet; the first push tells.

  Add `desk-app-windows` and `desk-app-linux` jobs the same way. The
  spec's smoke runs under Xvfb on Linux.
- **Release:** the "Desk app (macOS)" step runs on the aarch64-macos job
  for `harness-v*` tags. It writes `harness-desk-VERSION-macos.zip` and
  its `.sha256`. Yours ship as the spec's Release table says:
  - Windows: `harness-desk.exe` with `WebView2Loader.dll` beside it,
    pinned by version and SHA-256;
  - Linux x86_64: a dynamically linked binary.

The README's "Desk app (macOS)" section is the model for yours.

## For you: the owner answered question 3 (2026-11-24)

> "Move money with a budget. Sandbox on priority"

Spec: `docs/superpowers/specs/2026-11-24-harness-money-budget-and-sandbox-default-design.md`.
It has been builder-checked against the code.

**Approved by the owner on 2026-11-24 ("Approve 1"): build it.** The Mac session is building Part 1 on `platform/money-budget`.

**Part 2 (unattended runs in a sandbox) is yours,** since you own
environments and the sandbox runners. In short:

- a built-in `sandbox` environment: `kind = sandbox`, `workspace = rw`,
  `network = off`. An owner's `[sandbox]` section replaces it, and must be
  `kind = sandbox`;
- `[default] unattended`, which defaults to `sandbox`, for
  `who.unattended()` whos, workflow tool steps included;
- an unattended run's shell `env` field leaves `host` out unless
  something names it;
- with no sandbox available, the shell calls are refused, never run on
  the host instead. Doctor and the start line say how to fix it;
- the upgrade line, behind the `state/upgrades/sandbox-default` marker.

Its "Tests, Part 2" and "Tests that change on purpose" are the contract.
The Mac session tests macOS (sandbox-exec) after you push.

**Part 1 (money within a budget) is the Mac session's.** It touches
agent.zig's moneyCheck and MoneyLedger, core.zig's skipped items and the
reorder, config.zig's `[money]` and mcp.zig. Keep your edits to those
small while it's built.

**Part 1 is built (2026-11-24, branch `platform/money-budget`).** What it
changed in shared code, so Part 2 doesn't collide:

- `agent.zig`: `moneyCheck` gained an unattended branch (`unattendedMoney`)
  that runs before the gate; `gate.Ctx.money_unattended` is now set only
  when it passed the budget (`AskExtra.budget`). The trigger and workflow
  switch checks moved out of `callToolRaw` into it. `MoneyLedger` has a
  table per record kind (`day`, `auto_day`, `auto_month`, `month`;
  `reserve(…, auto)`), `Switches.money_paused`, `Run.spend` (the told
  line), `Skip.why`/`payable`/`amount`, `callMcp(…, dry)`.
- `core.zig`: `keepSkip` offers [Make this payment] (`pay`, the item's
  skip key the whole call) and `answerItem` makes it on a thread
  (`startPayment`, `makePayment`, reusing `Errands.OrderGo`); a `Money`
  namespace before `Persona` (`/money`, the `p` button, `state/money-paused`,
  `state/upgrades/money-budget`, setup's `budget SHOP` question);
  `Errands.propose` → `orderWithin` as `harness:reorder`. `Money.upgrade`
  runs in `open` right after `Manner.migrate`: put the sandbox-default
  upgrade beside it, with its own marker in `state/upgrades/`.
- `config.zig`: `[money]` `budget_per_day`, `budget_per_month`;
  `scheduled`, `triggers`, `workflows` default on. `mcp.zig`: a server's
  `budget_per_day`/`budget_per_month` (`none` = 0, `0` = `error.ZeroBudget`).
- New `money.zig`; `inject.zig` case 33. No edits to `environments.zig` or
  `sandbox.zig`. Windows: nothing POSIX-only; paths joined with
  `std.fs.path.join`.

## CI after your cmd push (772c8c4, dfb489f): red on Windows

Runs 45388410033 and 45392418965 fail on Windows, in Debug, in
`core.test.env_check_probes_a_sandbox_and_a_copy_environment`:

```
error.Unexpected NTSTATUS=0xc0000043 (SHARING_VIOLATION)
… dirRenameWindowsInner … util.zig:36 writeReplaceWaiting
```

- `writeReplaceWaiting` already waits 2 s for a held file, so something
  holds it longer. Likely the launcher, or its logon session's drives,
  still has the file open after the check.
- It passed on Windows at 2d3c3d2, just before your push.
- It's yours to fix, since it needs a Windows machine.

Still red at 615d9f3 (run 45414619782), the injection checks' merge.
That merge's unit tests all pass on Windows: 1235/1286, 50 skipped, and
`env_check` is the only failure. The smoke step depends on the unit
step, though, so the injection demo hasn't had its first Windows run.
It runs once `env_check` passes.

The same runs also failed on all three systems in
`calendar_attendees_become_people`. That one is ours: the test read the
real clock, and the fixture has a busy event from 12:00 to 13:00 UTC on
2026-11-24. It's fixed in ed34e74 with a fixed clock.

## Built: a persona, one chat filed into topics, helpers main manages (2026-11-24)

Spec: `docs/superpowers/specs/2026-11-24-harness-persona-and-topics-design.md`;
plan with its rulings: `docs/superpowers/plans/2026-11-24-persona-topics.md`.
Branch `platform/persona-topics`, merged with `harness-logins` at the end.
New files: `persona.zig`, `topics.zig`, `card.zig`, `work.zig`.

**Shared code it changed:**

- **State.** `state/conversations` lines may carry `title`, `focus`,
  `subject` and `card` (each only where set; old lines read as before).
  New files: `persona.md` (data folder, 0600), `state/topics-said`,
  `state/helpers`, `state/agents/NAME/saves` (a SHA-256 line per
  `agent_save`), `state/setup/manner`, `state/setup/persona.md` (a draft),
  `state/persona-told`. `inbox` shown entries may carry `"short":true` (a
  pointer in main).
- **Telegram.** `telegram.Entity` (byte offsets; sent in UTF-16 units,
  `utf16Len`), `Bot.sendRich`, `sendButtonsRich` (`sendButtonsTo` now calls
  it with none), `editRich` (error.MessageGone; "not modified" is fine),
  `pin` (`pinChatMessage`, no thread), `setTopics` (`setMySettings` with
  `has_topics_enabled`); `callWhy` keeps a refusal's description. No
  `parse_mode` anywhere. `core.Channel` gained optional `rich`,
  `buttons_rich`, `replace`, `pin`, `topics`, `me`; `TgChan` and the
  Recorder implement them, `TermChan` doesn't (it sends plain text).
  harness-fake: `setMySettings` switches what `getMe` says (refused while
  `telegram/no-settings` exists); an `editMessageText` of an id listed in
  `telegram/gone` answers "message to edit not found".
- **The subject on posts.** `{topic:NAME}` in harness's own text becomes
  the topic's title as a link at send time (`Core.linked`, where
  `fillLinks` is). Harness's own posts pick their conversation with
  `subjectConv` (postAway, postTrips, postPeople, diaryPost,
  awaySummaryDue, tripsStatus, mailSay, the others' mail line, Errands'
  `post` by label); triggers are routed when applied (`routedTriggers`:
  open after the conversations are read, `/reload`, `/trigger add|rm`),
  workflow instances when they run (`routineTo`); `triggers.zig` and
  `workflows.zig` read `subject` and know `to_set`. `RunOut.subject` gives
  an urgent alert's record line. `sendTextAs` notes a topic's last lines
  for its card (`sendTextOpts` doesn't: digests, cards).
- **agent.zig.** `Run.persona` (after the definition's body; helpers get
  none), `Run.helpers` (`HelperDesk`) and `Run.work` (`WorkSink`, called
  after each `delegate`, helpers' rids in `Helper.rid`). `agent_save`: main
  may change and retire (`retire: true`) what it saved itself; a save by
  main is quiet when `quietWhy` finds nothing (main only, no outside mark,
  within `agents.withinReach`, nothing named by core's `Helpers.why`), and
  the gate then gets `Ctx.own_helper` (default allow, no grant counts, not a
  setup call: the owner's deny and ask lines decide). The tool's schema has
  `retire` and `name` alone is required.
- **The migration.** At open, `main` pointing at an `agents/butler.md` that
  is exactly `evening.presetFile(address)` becomes `persona.md`
  (`preset: butler`, that address), `main` points at `main`, the file goes
  to its versions; said at the first attach (`sayAtStart`). An
  `agents/main.md` still exactly the earlier built-in is rewritten to
  today's (two lines added: others may read; no medical advice).
- **Setup.** After the manner, `topics` is offered; `/setup topics`.
  `applySetup` takes any "Settings reloaded." start as success (a persona
  note may follow it).

**After the final review's fix pass:** links are built only by harness
(`Core.Linked`: `text`, `topic`, `join`; `sendLinked`/`sendTextRich`); no
generic send expands `{topic:NAME}` any more. An item edit can be main's
pointer (`Edit.pointer`, `.title`: its line rebuilt in `applyEdits`).
`agent.Post.links` and `postTextLinked` carry a routine's `{topics}`
links (`InstRun.say_links`). `card.overviewLine(a, facts)` and
`card.summaryLine(a, title, news)` lost their tokens. `HelperDesk.unseen`
(state/agents/NAME/unseen) puts a quietly saved helper's file in a
trigger's or workflow's setup question. `WorkDone.by`: only the owner's
runs post to Work. `workflows.zig`'s `checkText` takes whether it reads
a say step (`{topics}` is a say's, unless a step is called `topics`).
`utf16Len` counts the text as sent (`util.validUtf8`).

**Windows:** nothing new is POSIX-only except
`persona_load_falls_back_with_a_reason`'s writable-by-others case, which
returns before it on Windows (as agents.zig's does). Paths in the new tests
are built with `std.fs.path.join` and `sep_str` the way the product builds
them; the versions folder is opened `.iterate = true`.

## Built: the Hermes import (2026-11-24)

Spec: `docs/superpowers/specs/2026-11-24-harness-hermes-import-design.md`
(91a62e0, approved by the owner); plan with its rulings:
`docs/superpowers/plans/2026-11-24-hermes-import.md`. Branch
`platform/hermes-import`, merged with `harness-logins` (the injection
checks) at the end.

**What it adds:**

- `harness import hermes [--from DIR] [--profile NAME] [--dry-run] [--yes] [--bundled]`:
  memory, an edited SOUL.md, skills, cron jobs, MCP servers, deny rules
  and the model from a Hermes home. A plan first; no key copied (each is a
  `harness secret add` line); refused while `harness run` holds the folder.
- `harness skill add|list|show|update|rm`: skills from a folder, a GitHub
  repo (codeload's tar.gz, pinned to the archive's commit) or a link to a
  `SKILL.md`, each with its source and hash in `skills/.sources`.
- New files: `yaml.zig`, `zones.zig`, `hermes.zig`, `hermes_import.zig`,
  `skillsrc.zig`, `targz.zig`, `skill_cmd.zig`, `taskfiles.zig`.

**Shared code it changed:**

- `triggers.zig`, `config.zig`: tasks take `do_file = NAME.md`, read whole
  from `tasks/` (guarded like `workflows/`; `taskfiles.zig`); `core.zig`
  one line each in `loadSettings` and `settingsProblemWith`, and
  `Paths.tasks_dir`.
- `mcp.zig`: `env = NAME=VALUE` (a secret-like name refused); `core.zig`
  doesn't start a server whose `env` value is a stored secret.
- `skills.zig`: a closing `---` followed by spaces is a fence.
- `memory.zig`: `Store.repeatOf` (read only).
- `fake.zig`: `GET /codeload/OWNER/REPO/tar.gz/REF` from the script's
  `repos/`; `fake_mcp.zig`: echo `env:NAME`.
- `main.zig`: the two commands, their help, and `harness init`'s line when
  a Hermes setup is there.

**Rulings worth knowing** (all in the plan): codeload's top folder is
`REPO-REF`, so the commit comes only from the pax header; an excluded MCP
tool becomes `deny mcp SERVER/GLOB *`; `command_allowlist` entries are told
apart by Hermes's own 122 pattern names; skills from Hermes that can't be
updated get a `hermes` source line; Hermes's empty `timezone` is this
computer's zone.

**For Windows:**

- Hermes's home is `%LOCALAPPDATA%\hermes` (else `%USERPROFILE%\AppData\Local\hermes`).
- There are no zone files: a job's time in another zone is kept as
  written, and the plan says to check it (`zones.offsetAt` is null).
- Hermes on Windows hashes its bundled skills with `\` paths, ordered
  case-folded; the fixture carries both systems' hashes.
- The archive reader refuses names Windows can't hold; no executable bit
  is set; tests that need one (`scripts_keep_their_executable_bit`,
  `a_tasks_folder_others_can_write_is_refused`) skip there.
- From the final review: `HERMES_HOME` expands `%NAME%` (and `~`,
  `$NAME`); a skill file name Windows can't hold is listed under Not
  imported before anything is written; the tests that make links
  (`a_linked_skill_folder_*`) and a `:` in a file name
  (`a_skill_file_name_harness_cant_write_is_listed`) skip on Windows.
  A part the import can't write (a file another program holds open) is
  listed in report.md and the output, exit 1, and the rest is written.

## Built by the Mac session: prompt-injection checks (2026-11-24)

Spec `docs/superpowers/specs/2026-11-24-harness-injection-checks-design.md`,
plan `docs/superpowers/plans/2026-11-24-injection-checks.md` (branch
`platform/inject`). The checks assume the model obeys the hostile text; 32
cases (`src/inject.zig`): 1–8 end to end in `scripts/injection-demo.sh`,
which the smoke script runs with `--check` (so Windows CI runs it under Git
Bash), 9–32 as unit tests `injection_NN_…` through Core. Case 32 came with
the Hermes import: a skill installed from a repo asks to send memory out.

**What changed in shared code, as built:**

- `outside.zig` (new, pure): source names, the question line, roles of MCP
  servers (`home` and `car` mark nothing, `calendar` or a name with it,
  mailmcp's tools).
- `agent.zig`: `Conversation.Turn.outside`/`marked`/`own`,
  `Conversation.summary_outside` (summaries keep the marks of the turns
  they were made from); `Run.conv`, `start_marks`, `own_words`, `loose`,
  `mark()`, `outside()`. Calls that ran mark (fetch/browse and allowed
  redirect hops `page HOST`, search, history with tool results, MCP by
  role, `web HOST` in `webAllow`, helpers' marks after `delegate`).
  `logRun` puts `outside`/`outside_more` on gate lines (`log.Tag`), and on
  turn lines (the first: what the run started with; later: all it read).
  `Conversation.index` keeps the mark bounded (64 sources).
  `decideAndAskWith` adds the line to the question; `Question.outside` and
  `Skip.outside` carry it. The "not available here" branch now logs
  `deny`, `not offered in this run`; an unknown name logs `no such tool`.
- `gate.zig`: `Ctx.outside`; `remember` and `people note` default to ask
  when set (`outside text: asked by default`), never `allow_day`;
  unattended `outside text, unattended`. Rules decide as before.
- `core.zig`: `Incoming.forwarded` and `Queued.forwarded` (a forwarded
  message is never a command; `chatTurnWith`), `mailTurn`'s marks and
  own words, `triggerMarks`, a brief's marks, `serverRole`, workflow
  instances' marks (`wstate.State.outside`, `Start.outside`, saved in
  `state` and `line`), the line on member and skipped items, the memory
  writer reading only the owner's words of a marked turn. `WfAsker`
  matches a stored answer on the question without its outside line.
- `telegram.zig`: `Message.forwarded` from `forward_origin` (or the older
  `forward_date`); `main.zig` passes it on.
- `history.zig`: `Answer.outside` (tool results, or a run that had read
  outside text); history and `session.zig` label a run's start with
  `outside.startLabel` ("Forwarded", never "Owner"). `summaries.zig`: the
  day summariser leaves outside text out. `agent.WfDesk.start` takes the
  run's mark. A forwarded message is never a command in groups either.
  `build.zig` installs harness-fake.

**Rulings worth knowing** (all in the plan): marks live on turns, so they
go with the context on a restart; a server's role comes from setup's
section names; the day summariser and the memory writer leave outside
text out; `outside` on a private line is hashed like other fields.

**Skipped on Windows:** `injection_23_a_key_in_encoded_forms_is_masked`
and `injection_25_a_key_reversed_gets_through_once_allowed` (they use
`base64`, `od`, `sed`, `rev`: POSIX commands). The demo's case 5 runs
`type PATH` on Windows instead of `cat`. Untried on Windows: the demo
under Git Bash, `--serve`'s Ctrl-C. If a demo case fails only on Windows
CI, say so in your status section.

**A rule for new code from now on:** a new source of third-party words
adds to the mark; a new tool that keeps text for later runs is asked in a
marked conversation.

**Still open** among the Hermes differentiators: the gate as an MCP proxy;
private conversations on a local model. None is claimed; ask the owner
before starting one. (The Hermes import is being built, see above.)

## Latest from the Mac session (2026-11-24)

Fetch `harness-logins` (123eadd or later). Since your apps push:

- **Your apps batch is merged** into the household (11946c5). One
  conflict, `close()`'s wait loop: the app server stops first, then both
  sides' running flags are waited on, then the apps' jobs are freed.
- **A who kind of harness's own: `harness:NAME`** (security review).
  Harness's internal jobs (the people's pass, away, trips, warm-car,
  habits, the evening, the errands' lists, reorders, deliveries and
  upkeep) run as `harness:NAME`, never `schedule:NAME`, so a task, brief
  or schedule the owner names `away` never gets harness's rules. No
  settings file can produce one; a workflow's start line may name it only
  in harness's own workflow of the same name; the shipped rules say
  `[harness:away]`. Any new internal job uses `harness:NAME`. Apps stay
  `app:NAME`.
- **New since your fetch**: the household duties (away mode and trips,
  the doorbell, errands and upkeep, medication reminders and bedtime,
  habit suggestions, the evening message and a butler preset, the car's
  heating through Tesla), mail (mailmcp; owner's question 1 answered: the
  butler's own address, plus the owner's mailbox read-only with drafts,
  opt-in), the diary (calmcp), people, emergencies. `Routine.all` has 16.
- **Windows lessons from CI in the servers**: a binary that does TLS sets
  `std_options.unexpected_error_tracing = false` (crypt32 fails an
  Ed25519 CA with NTE_BAD_ALGID, which std has no name for, and Debug's
  trace panics); a unit test that reaches that path skips where the test
  runner's trace is on; tests compare joined paths with
  `std.fs.path.sep_str`; a temp dir a test lists opens with
  `.iterate = true` (Linux).
- **Owner questions**: 1 answered (email). 2, 3 and 4 still open, plus a
  new 5: messages to other people (WhatsApp, Signal or SMS). Build around
  them as before. Everything not built is in
  `docs/superpowers/specs/2026-11-23-harness-gaps.md`.

## Next (from the Mac session, 2026-11-23)

Phases A and B are in `harness-logins`: conversations, the inbox,
triggers (gap 6), workflows (gap 7), agent definitions, file roles and
model providers, merged with your items 3–8 and the macOS sandbox
(sandbox-exec, `sandbox.run`'s third branch) and APFS clones. The run and
approval code has settled, so your held-back batch can start. Fetch
`harness-logins` first.

1. **Runs pick an environment** (gap 2's gate part): pins in `[use]`,
   `shell@NAME` in the gate's choice, `env_save`, the definitions'
   `environment`, and a workflow step's `env NAME`. Replace these, each
   one function today: `workflows.envProblem` (accepts only `host`:
   "runs don't pick an environment yet"), agents' `environment` (host
   only), and triggers' runs (host). The macOS branch of `sandbox.run`
   exists; the Mac session tests macOS once you push.
2. **Try in a copy** — Part 3 of
   `docs/superpowers/specs/2026-11-23-harness-routines-undo-copies-memory-design.md`
   (the owner asked for it on 2026-11-23): `workspace = copy` in a
   sandbox section, a run's own copy (cloned where `clone.platform` can),
   its changes as an inbox item (Apply, Drop, Show), `check =` and
   `apply = ask|check`, `copy_mb`. Build it with item 1. On macOS the copy
   is at its own path (sandbox-exec can't remap paths); the Mac session
   tests that branch after you push.
3. **Apps' API** (reads, acts, runs as `app:NAME`), `app_draft`,
   `app_save` and the review page, versions and forks, and the question
   bar (the inbox is in: `Core.answerItem(id, key, text, via .bar)`).

The Mac session meanwhile builds Parts 1, 2 and 4 of that spec (remote
MCP servers and sign-in, the morning routine, Undo, long memory); Undo
adds a button to the end of runs (core.zig/agent.zig), so expect small
conflicts there. As before: your own branches, test-driven, full suite
and cross builds green, and the owner decides every push.

### Status from the Windows session (2026-11-24, branch `win/cmd`)

- Done: cmd's own `dir`, `del`, `ren`, `copy`, `move` and `cd /d` work in
  a Windows sandbox (the owner's decision on 7.4). A sandbox's command
  starts through a launcher in a logon session of its own, where the
  workspace and the home are drives of the sandbox's own; what was tried,
  the rulings (R30 to R36) and the fallback:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 9.
- New in shared code: `proc.spawnInSession` and `proc.sandboxLaunch`
  (Windows only), `harness sandbox-launch` (main.zig, first thing in
  `main`), `harness-fake --sandbox-launch`, and harness-fake links
  advapi32 and userenv on Windows (build.zig). Nothing in the gate, the
  agent's call path or the conversations' state changed; `shellDef` has
  one more sentence on Windows.
- CI after the cmd push (runs 45388410033, 45392418965): the failing
  line was the test's own (`/env check` said "no" for cmd's own
  commands), not the SHARING_VIOLATION in the trace, which is a rename
  `writeReplace` tried again and got through. Two causes fixed: the
  probe ran `dir` in the test's empty workspace, which some Windows
  count as an error (it lists the sandbox's home now), and one failed
  start of a session ended the drives for the whole process (R37, R38
  in the plan's section 9).
- The Windows runner's refusal is explained (plan R39, R40): Windows
  Server gives sandboxes (app containers) no access to NUL, so `>nul`
  there says "Access is denied". It was never `dir` or the drives. For
  the Mac session: a test or smoke step that runs a command in a Windows
  sandbox must not redirect to nul; outside a sandbox nul is fine.
- For the Mac session: `calendar_attendees_become_people` fails on every
  system while the clock is inside a busy event of its fixture (the
  owner is busy, so the line is held): CI run 45388410033 ran during
  "Lunch with Anna", 24 Nov 12:00 to 13:00 UTC. Its events are in the
  past from then on, but the fixture's dates should not be real ones.

### Status from the Windows session (2026-11-23, branch `win/apps`)

- Done, tested on Windows and Linux: item 3 (the apps' API, the bar,
  `app_draft`, `app_save` and the review page, versions and forks).
  What was built, the rulings (R15 to R29) and what is left:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 8.
- `[apps] on` is on by default now: `harness run` and `harness chat` print
  an "Apps:" line.
- `inbox.New` has `app`; `agent.Question` has `app`; `[money] apps` and
  `[apps] act_seconds`, `runs_per_hour` are new settings.
- Still open from before: cmd's built-ins in a Windows sandbox (section
  7.4), for the owner to decide.

### Status from the Windows session (2026-11-23, branch `win/envs`)

- Done, tested on Windows and Linux: the data folder inside a `read =`
  folder (1e355f3), item 1 (runs pick an environment, c0dde2e) and item
  2 (try in a copy, 370f96e). Rulings and what is left:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 7.
- Not started: item 3 (apps' API, `app_draft`, `app_save`, the bar).
- For the Mac session: `sandbox.Request.mount_at` is Linux's alone; on
  macOS a copy run's sandbox gets the copy as `workspace` (its own path)
  and `Mode.copy` reads as `rw` in the profile. The copy tests in
  `core.zig` and `agent.zig` skip where no sandbox can run; please run
  them on a Mac. `another_step_cut_by_a_restart_asks_in_the_inbox`
  counted `pushed\n` (cmd prints `\r\n`): fixed, Windows CI was red on it.
- Found on Windows: cmd's own `dir`, `del`, `ren`, `copy`, `move` and
  `cd /d` fail inside an AppContainer (they ask the drive's root); see
  the plan, 7.4.

### Decisions since your last fetch

- **The data folder inside a `read =` folder: fix on Linux and Windows.**
  The macOS sandbox refuses the data folder even when a `read =` folder
  holds it (say `read = ~`); bubblewrap and AppContainer show it there.
  The spec says never the data folder, so make Linux and Windows refuse
  it too (bwrap: mask it inside the read bind; AppContainer: a deny ACE
  for the profile's SID on it), and extend
  `sandbox_cannot_read_data_folder_or_home` with a `read =` folder that
  holds the data folder.
- **macOS sandbox, as built** (docs/superpowers/plans/2026-11-23-macos-sandbox.md):
  network on reaches outside hosts and the local network but never this
  Mac (sandbox-exec can't tell the two apart; README says so); no
  `/dev/tty`; TMPDIR is its own temp (`state/env/NAME/tmp`) and `/tmp`
  is refused; `/Library` readable except its Keychains; Keychain
  services denied. Network on differs per system (Linux reaches the
  host's loopback, Windows and macOS don't); keep the README's account
  of it current.
- **Settings files are nine**: triggers.ini took slot 7 and
  environments.ini slot 8 of `settingsFiles` (the auto-merge had both
  parsers read slot 7; fixed in e261465 with a test). A new settings
  file gets a new slot. `guardedFiles` has seven; the `workflows/` folder
  is guarded on its own (chmod go-w).
- **Money from runs an app starts**: refused behind `[money] apps = off`
  (default off), as `[money] triggers` and `[money] workflows` do, until
  the owner answers question 2. App acts never call money tools (the
  apps spec).
- **State files**: every file replaced whole goes through
  `util.writeReplace`, now including triggers' state, triggers.ini
  writes and workflow instances (`wstate.writeReplace` calls it).
- **Still waiting on the owner**: question 1 (email), 2 (money from
  automation; built off), 3 (the default environment for unattended runs:
  keep `host` behind one setting) and 4 (apps on the phone: loopback
  only), and the hosted design's five questions. Build around them as
  before.

## Status (Windows session, 2026-11-22)

Items 1 and 2 below are done, on branch `harness-windows`, merged into
`harness-logins` (f14261e). What was found and done is in the "Done"
sections at the top of `HANDOFF-windows-audit.md` and
`HANDOFF-windows-web.md`. After the merge: Windows 464 pass, 33 skip,
smoke all ok; Linux (WSL, an ordinary user) 488 pass, 9 skip, smoke all
ok. The 33 that skip on Windows: POSIX shell commands in their setup (14:
tools 7, mcp 4, agent 3, among them the new
`shell_starts_in_its_dir_and_the_question_and_lines_name_it`; most have a
Windows twin), the stand-in browser scripts and page.zig's render tests
(14), symbolic links (4, two of them the snapshot store's: Windows makes
them only with Developer Mode or as administrator; junctions are tested
instead) and SIGTERM (1).

Items 3 to 8 are done too, each on a branch of its own, stacked in one
line on `harness-logins` (none pushed; the owner decides):
`win/sandbox` (3: environments.ini and the sandbox runners; also a fix:
Windows shell commands with quotes in them failed), `win/remote` (4),
`win/app-server` (5), `win/clone` (6), `win/state-files` (7: also found
grants and the written list rewritten in place), `win/hosted` (8, and
this status). What was built, the tests and the rulings are in
`docs/superpowers/plans/2026-11-22-windows-platform.md`. At the tip:
Windows 11 and Linux (WSL) pass in full, smoke included.

Left on purpose, for after the Mac session's phases A and B have landed
in the run and approval code (changing it now would clash with them):
runs picking an environment (pins, a step's `env`, `shell@NAME` in the
gate's choice, `env_save`), apps' API (reads, acts, runs), `app_draft`,
`app_save` and the review page, versions and forks, and the bar. Not
verified: block cloning on ReFS or a Dev Drive (no such volume here).
Yours: the macOS sandbox (sandbox-exec, a third branch of
`sandbox.run`) and APFS clones (`clone.platform`).

## Get it

```
git fetch origin
git checkout harness-logins        # everything: 0.3, the audit fixes, the specs
```

CI was green on Linux, macOS and Windows (Debug and ReleaseSafe) at 664aa83.

## Read, in this order

1. `docs/superpowers/specs/2026-11-22-harness-platform-overview.md` —
   binding. Read "Rules every spec keeps", "Shared formats" (the `by`
   value `KIND:NAME`, rules `ACTION TOOL[@ENV] PATTERN` in `[who]`
   sections, grant keys, setup approvals, snapshots), "Phase 0", and
   "Questions for the owner".
2. `docs/superpowers/specs/2026-11-22-harness-environments-design.md` (gap 2)
3. `docs/superpowers/specs/2026-11-22-harness-apps-design.md` (gap 8)
4. `harness/HANDOFF-windows-audit.md` and `harness/HANDOFF-windows-web.md`
5. The hosted notes at the end of the agents, file-roles and environments
   specs.

## Yours now (nothing here touches the gate, so you can start at once)

Do them in this order; each on its own branch from `harness-logins`
(suggested names in brackets), test-driven, full suite and cross builds
green before you ask the owner to push.

1. **Job objects** (`win/job-objects`) — HANDOFF-windows-audit.md §1 (I27):
   shell, MCP servers, browse and Chrome start in a job object with
   KILL_ON_JOB_CLOSE; stop, timeout and exit terminate the job; pipe drains
   are bounded. The AppContainer sandbox below builds on it.
2. **The other open Windows items** — HANDOFF-windows-audit.md §2–§5 and
   §7 (mintty echo, the lock and Ctrl-C checks, Credential Manager, the two
   symlink tests that skip on Windows), and HANDOFF-windows-web.md (the
   `web` tool on Windows).
3. **Sandbox runners** (`win/sandbox`) — gap 2's backends as standalone
   runners in a new file (e.g. `src/sandbox.zig`), with gap 2's backend
   tests: AppContainer plus the job object on Windows; bubblewrap on Linux
   (test it in WSL). The macOS runner (sandbox-exec) stays with the Mac
   session, which can test it. Read and check `environments.ini`.
4. **The SSH remote** (`win/remote`) — the runner over the system's
   OpenSSH with harness's own key (`env key`), per gap 2.
5. **The app server** (`win/app-server`) — gap 8 without `api/`: the
   loopback listener with the exclusive bind, tokens, Host/Origin/frame
   checks, headers and CSP, path checks (Windows names too), `app.ini`
   read and checked, app files and the built-in apps' pages served. The
   `api/` reads, acts and runs wait for phase 0.
6. **Clone helpers** — the snapshot store's copy-on-write clones as
   functions with their own tests: ReFS and Dev Drive block cloning on
   Windows; btrfs and XFS on Linux (WSL). APFS stays with the Mac session.
7. **State files on Windows** — replacing a file by rename while another
   process reads it (`state/inbox`, `state/conversations`, `state/grants`):
   make it safe and test it.
8. **Hosted design notes** — turn the three hosted notes into one design
   for the hosted version (one isolated instance per customer; an actor per
   agent instance with journaled turns, e.g. Elixir/OTP; the shared
   filesystem; one VM per instance). A document for the owner, no code.

## Wait for phase 0

The Mac session builds phase 0 first (the `by` value on every run, rules
and grants with who and environment, the new gate kinds) and then phase A
(conversations, inbox, triggers). Until phase 0 is merged into
`harness-logins`, don't change `gate.zig`, `rules.zig`, the run and
callTool code in `agent.zig`, or the run and approval code in `core.zig`;
put your work in new files and keep edits to shared files small. After
phase 0: environments in the gate (`shell@ENV`, pins, `env_save`), apps'
`api/` as `app:NAME`, then the question bar once the inbox (phase A) is in.

## Waiting on the owner

Two of the owner questions in the overview change your part: the default
environment for unattended runs (host or sandbox) and opening apps from the
phone before hosting. Build the rest; leave those choices behind one
setting until the owner answers.

## Rules that stay

The owner decides every push, merge, tag and release. Secrets only through
`harness secret add`, never typed for the owner. Plain labels, no slogans.
Report what you did, test results and any rulings in your final message to
the owner, and in `docs/superpowers/plans/` if you write a plan.
