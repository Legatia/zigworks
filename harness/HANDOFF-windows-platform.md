# Handoff to the Windows session: platform work (gaps 2 and 8, Windows items, hosted notes)

From the Mac session, 2026-11-22. The owner asked to spec the gaps between
harness and the "Agent platform of 2027" blueprint and to share the work
with you. Eight specs are written and reconciled; you own apps (gap 8),
environments (gap 2), the open Windows items and the hosted design notes.

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
