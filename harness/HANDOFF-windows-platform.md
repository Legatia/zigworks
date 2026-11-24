# Handoff to the Windows session: platform work (gaps 2 and 8, Windows items, hosted notes)

From the Mac session, 2026-11-22. The owner asked to spec the gaps between
harness and the "Agent platform of 2027" blueprint and to share the work
with you. Eight specs are written and reconciled; you own apps (gap 8),
environments (gap 2), the open Windows items and the hosted design notes.

## Coming next from the Mac session: prompt-injection checks (2026-11-24)

Spec: `docs/superpowers/specs/2026-11-24-harness-injection-checks-design.md`
(0435b84). It has been reviewed and is waiting on the owner's approval.
Nothing is built yet. The Mac session builds it once approved.

**The idea.** The checks assume the model obeys the hostile text. Each
check tests that the gate's outcome holds, that nothing reached the
attacker, that no secret left harness, and that the log says why. There
are 28 cases:

- end to end, in `scripts/injection-demo.sh`, which the smoke script runs
  with `--check`, so Windows CI runs it under Git Bash;
- the rest as unit cases through Core.

**What will change in shared code** (expect small conflicts there):

- **Outside text marks the conversation.** The mark is saved with the
  conversation's state, trimmed with its turns, carried by summaries and
  cleared by `/new`.
  - Sources: pages, the browser, search, feeds, others' mail, the calendar
    and other MCP servers' results, forwarded Telegram messages
    (`forward_origin`), `history` results and helpers' marks.
  - Not sources: shell output, workspace files, MCP tool descriptions, the
    home server, and members' and rooms' messages.
- **Questions and one-tap items** in a marked conversation get one line
  naming up to three sources. Gate log lines carry
  `"outside":[…]` and `"outside_more":N`.
- **Two changed defaults:** in a marked conversation, `remember` and
  `people note` are asked. Unattended, they are refused and become a
  skipped item. An owner's allow line still lifts them.
- **The memory writer** reads only the owner's own words in marked turns.
  It skips quoted and forwarded mail, forwarded Telegram messages and the
  agent's replies.
- **A call to a tool the run isn't offered** is now logged as refused,
  with `not offered in this run`. Today it writes no line.

**Until it lands, keep your edits small in:**

- `gate.zig`'s defaults;
- `agent.zig`'s call path (the "not available here" branch);
- `core.zig`'s memory writer and question text;
- the conversations' state format;
- `telegram.zig`'s message parsing.

**For Windows:**

- Cases 5, 23 and 25 use POSIX commands (`cat`, `base64`, `rev`,
  `od -c`). On Windows each gets a Windows twin or a skip, like the other
  POSIX-shell tests.
- If a demo case fails only on Windows CI, say so in your status section.

**A rule for new code from now on:**

- A new source of third-party words adds to the mark.
- A new tool that keeps text for later runs is asked in a marked
  conversation.

**After this,** the remaining Hermes differentiators are:

- importing a Hermes setup and agentskills.io skills;
- the gate as an MCP proxy;
- private conversations on a local model.

None is claimed yet. Ask the owner before you start one.

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
