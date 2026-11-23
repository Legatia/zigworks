# harness platform: the gaps to the 2027 agent platform blueprint

The owner shared John Suh's post "Agent platform of 2027" (x.com, 2026-11-22):
eight parts an agent platform needs. Compared with harness 0.3 (branch
`harness-logins`), the owner asked: "Spec all the gaps and share some work
with the windows session." This file is binding for the eight specs below; a
spec that disagrees with it is wrong, or must say why and change this file.

## What harness stays

A personal agent first: one owner, one data folder, one binary (Zig, std
only). The hosted version later runs one isolated instance per customer.
These specs make harness's parts fit a platform without making the binary
multi-tenant now. Where a gap only makes sense for many tenants, the spec
describes the local part harness builds now and a design note for the
hosted version.

## Rules every spec keeps

1. Every action passes the one gate and is written to the one log —
   including actions started by triggers, workflows, apps and other
   agent definitions. A new source of actions is a new value of "who
   started it", never a way around the gate.
2. Anything that changes what runs without the owner watching (a new
   trigger, workflow, app that acts, agent definition, environment) is
   asked once, with what it will do shown in full, and is listed where the
   owner can see and remove it ("Setup calls" below).
3. Runs nobody watches (started by a schedule, a trigger or a workflow)
   keep today's rule: `ask` is deny there, and what was skipped is
   reported and kept as an inbox item. The rule is about runs: a
   workflow's tool step is not a run and can wait, so what the gate asks
   there becomes an inbox approval the instance waits on until the step's
   `timeout`, then counts as Deny (gap 7). Runs the owner started, and app
   runs (gap 8), may ask.
4. Secrets and login values never reach the model, an app, a trigger's
   payload as text, or the log. Money rules stay as they are and apply to
   every new source of actions.
5. Data stays in the data folder as plain files (the owner can read, copy
   and back it up); state that must survive a restart is written before it
   is acted on.
6. macOS, Linux and Windows. A part that can't work on one says so in the
   spec and the README, and is refused there with a plain message.
7. Copy: plain labels, no slogans.

## Words used in all specs

- **Agent definition** (gap 1): a named file `agents/NAME.md` — model
  route, instructions, allowed tools, skills, limits. Today's agent is the
  definition `main`. Helpers are runs of a definition.
- **Run**: one execution of a definition on one input (a chat message, a
  task, a trigger event, a workflow step). Each run has a label, a who
  (what started it, its definition, the definitions that delegated it:
  "Who" below) and a conversation it reports to.
- **Conversation** (gap 4): where the owner and agents exchange messages —
  the Telegram chat and its topics, the terminal, later email threads and
  others. Agents post with the `send` tool. A turn that ends without a
  final `send` has its last text posted through the same path, logged as
  `implicit`, so nothing breaks while the agent learns `send`; working
  text and a run's internal steps are never posted. The log is the
  session view.
- **Inbox** (gap 5): the items waiting for the owner — approvals,
  questions, drafts to review, failed deliveries, things a trigger or
  workflow is waiting on.
- **Trigger** (gap 6): an event source (feed, mailbox, webhook, file,
  schedule, …) with a filter; a match starts a run or a workflow.
- **Workflow** (gap 7): a code-defined sequence of steps (tool calls,
  agent runs, waits for an event or an approval) whose state is kept on
  disk, so it survives restarts.
- **App** (gap 8): a folder with a manifest and web files, served by
  harness on the owner's machine (later the hosted address), opened from a
  conversation; it reads data and acts only through harness, so through
  the gate.
- **Environment** (gap 2): where commands run — the host workspace
  (today), a sandbox, or a remote machine.
- **Roles on files** (gap 3): permissions on workspace folders per who
  (owner, schedule, definition, trigger, workflow, app).

## The specs

| Gap | Spec | Built by |
|---|---|---|
| Shared foundation | this file, "Phase 0" | Mac session, phase 0 |
| 4 Conversations | `2026-11-22-harness-conversations-design.md` | Mac session, phase A |
| 5 Inbox | `2026-11-22-harness-inbox-design.md` | Mac session, phase A |
| 6 Triggers | `2026-11-22-harness-triggers-design.md` | Mac session, phase A |
| 7 Workflows | `2026-11-22-harness-workflows-design.md` | Mac session, phase B |
| 1 Agent definitions | `2026-11-22-harness-agents-design.md` | Mac session, phase B (local); hosted note |
| 3 Roles on files | `2026-11-22-harness-file-roles-design.md` | Mac session, phase B (local); hosted note |
| 8 Apps | `2026-11-22-harness-apps-design.md` | Windows session, phase C |
| 2 Environments | `2026-11-22-harness-environments-design.md` | Windows session, phase C |

Order: phase 0 first, then A before B (workflows use triggers and the
inbox; definitions and roles use the who from phase 0 and the
conversations of A). Phase C runs alongside A and B once phase 0 has
landed: its gate parts (`shell@ENV` rules and grants, pins, `env_save`;
apps' reads, acts and runs as `app:NAME`) need phase 0, the bar needs the
inbox's answer function (A), and a sandbox mounts folders by role only
once gap 3 is in (B; until then it mounts the workspace as its
`workspace =` line says). Before phase 0 lands the Windows session does
the work that doesn't touch the gate ("Phase 0" below).

The Windows session also owns the open Windows items
(`harness/HANDOFF-windows-audit.md`, `harness/HANDOFF-windows-web.md`) and
the hosted design notes (gaps 1, 2, 3), since it works with omnigate and
Elixir there.

## Shared formats

Decided once here for all eight specs, where they had differed; each spec
was edited to match and lists what changed under its calls. The owner can
change any of these like the calls at the end.

### Who

"Who started it" is one token, `KIND` or `KIND:NAME`, never with a space:

| Value | What started it |
|---|---|
| `owner` | a message, button or command of the owner (`/workflow start`, `/ask NAME` too) |
| `schedule:NAME` | a task or brief, also run by hand (names are unique across `tasks.ini`, `briefs.ini`, `triggers.ini`) |
| `trigger:NAME` | an event trigger (gap 6) |
| `workflow:NAME/STEP` | a workflow's step (gap 7) |
| `app:NAME` | an app's run, or its own read or act (gap 8) |
| `agent:NAME` | names a definition (gap 1) in patterns; never a `by` |

- The log field is `by` (no `started_by`). A run's `by` is what started
  it at the top of its chain: a delegated run carries its parent's `by`
  and adds `parent` (the parent's `rid`), and every run names its
  definition in `agent` (`main` or `helper` until gap 1). So the who of a
  call is the definition doing it (D), the definitions that delegated it
  (D1…Dk, through `parent`) and `by`. What is not a run logs `by` the
  same way: an app's own act `app:NAME`; a workflow instance or a setup
  change started from a run, that run's `by` and `agent`.
- A pattern is a who value with `*` as in rules; a bare kind (`trigger`)
  covers every name of that kind; `workflow:NAME` covers all its steps.
  `agent:` patterns match definitions, the others `by`. Patterns are used
  in rules sections and grants (below), `folders.ini` (gap 3 says how a
  list matches the whole chain) and `environments.ini` pins (gap 2: `by`
  only; a delegated run takes its parent's environment).
- Labels (`run`) stay display text as today: `chat`, `task NAME`,
  `chat/h2`, `workflow NAME#N/STEP`. An inbox item a workflow instance
  waits on names it by that label (`waiter`).
- NAME is the part's own name: never `:`, `/`, `*` or a space, and never a
  word its commands take (`add`, `rm`, `show`, …).

### Log lines

- A run's first line: `rid` (that line's `seq`), `run`, `by`, `agent`,
  `parent` (a delegated run) and `conversation` (gap 4). Later lines:
  `rid` and `conversation`; `gate` and `tool` lines also `agent`;
  `shell`'s also `env` (gap 2) and `dir` (gap 3).
- Each part logs setup changes under its own kind (`trigger`, `workflow`,
  `agent`, `app`, `env`): `saved` (`name`, `by`, `agent`, `item`, `sha256`
  of the new text) and `removed` (`name`, `by`). Event names keep today's
  style (`task added`).
- An inbox item is "item N" everywhere: its id, which replaces the
  approval numbers of `state/approvals` (gap 5).

### Rules

`rules` keeps one rule a line, `ACTION TOOL[@ENV] PATTERN`: ACTION is
`allow`, `ask` or `deny`; TOOL a gate kind (table below); PATTERN the
argument as that kind defines it (today's kinds as today). `@ENV` (gap 2)
is only for kinds that run in an environment, `shell` for now: `shell`
matches in every environment, `shell@box` only in box. A header
`[PATTERN]` (gap 1), a who pattern, starts lines that apply only to calls
whose who it matches; lines before the first header, or after `[all]`,
apply to every call.

```
deny  shell rm -rf *
allow fetch https://news.ycombinator.com/*

[agent:coder]
allow shell@box zig build*

[schedule:btc-watch]
allow fetch https://api.coinbase.com/*
```

The gate decides in this order (the agents spec has the detail):

1. hard limits, as today;
2. roles (gap 3): a refusal is final, nothing is asked;
3. a matching `deny` in the shared part or in a section matching D,
   D1…Dk or `by`;
4. listed sources (gap 6); money and setup calls, asked every time;
5. a grant for this TOOL[@ENV] and key whose `who` is empty, `agent:D`,
   or matches `by`;
6. the first matching `allow` or `ask` in a section matching D, then in
   one matching `by`, then in the shared part; an `ask` in a section
   matching D1…Dk or `by` turns an allow from another section into ask;
7. the kind's default; `ask` is deny where nobody can answer (rule 3).

A section matching `by` may allow, as a grant for `by` does (in the
agents spec only D's could); sections of the definitions that delegated
only narrow, so no definition widens another by delegating.

### Grants

`state/grants`, one a line, tab-separated: `TOOL[@ENV]`, expiry (Unix
seconds, as today), key (as today: the exact command; the host for fetch,
browse and web; `SERVER/TOOL` for MCP; `NAME HOST` for a login; the path
for files), `who` (a who value; empty covers any run, as 0.3's lines do).
`@` in TOOL is only ever an environment: a definition goes in `who`. A
`shell` grant always names its environment; a 0.3 line without one is
`shell@host`. Who a new grant gets:

- Allow 24 h: the asker, `agent:D` for a call in a run, `app:NAME` for an
  app's own act, `workflow:NAME` for a workflow's tool step (that
  workflow's instances, nothing else).
- Allow for this task, trigger or workflow, from a `skipped` item (gap 5,
  30 days): `schedule:NAME`, `trigger:NAME` or `workflow:NAME`.

`/grants` lists them, `/grant rm N` removes one (gap 5).

### Gate kinds

Today's kinds keep their arguments and defaults. New ones (phase 0 adds
the kinds and defaults, each gap its tool):

| Kind | Argument | Default | Gap |
|---|---|---|---|
| `send` | the conversation | allow to an own one; to a shared one asked every time, no Allow 24 h | 4 |
| `ask_owner` | the question | allow | 5 |
| `mail` | the mailbox | ask (a trigger's own polls are listed reads) | 6 |
| `trigger` | `add NAME`, `rm NAME`, `test NAME`, `list` | add: setup; rm: ask; others allow | 6 |
| `workflow` | `save NAME`, `start NAME`, `stop NAME#N`, `check`, `list`, `show NAME` | save: setup; start, stop: ask; others allow | 7 |
| `agent_save` | the name | setup | 1 |
| `app_read` | `NAME memory`, `NAME inbox` or `NAME log` | allow | 8 |
| `app_draft` | the app's name | allow | 8 |
| `app_save` | the name | setup | 8 |
| `env_save` | the name | setup | 2 |
| `snapshot` | the folder | allow | 3 (was gap 2's `env_checkpoint`) |

`shell` takes `env` (gap 2) and `dir` (gap 3) in its input; its argument
stays the command.

### Setup calls

A tool call that adds or changes what runs without the owner watching is
a setup call: `trigger` `add` (gap 6), `workflow` `save` (gap 7),
`agent_save` (gap 1), `app_save` (gap 8), `env_save` (gap 2). Each is an
approval the run waits on (an inbox `approval` item, gap 5), not an item
left for later: the agent usually goes on with what it set up, and a run
that has ended can't be told the answer.

- Asked every time, like money: Allow once and Deny, no Allow 24 h; no
  grant or `allow` rule lifts it; a `deny` rule stops it. A text reply
  denies it and gives the agent the reason, so it can propose again.
- The question shows the whole new text and harness's own reading of it,
  not the model's, within the 12 KB an item holds (apps link the files
  from a review page; a workflow whose question would be longer is
  refused, and the owner can still write it by hand).
- Setup tools are offered only in runs the owner started from a
  conversation: never in delegated, scheduled, trigger, workflow or app
  runs, nor as a workflow's tool step or an app's act.
- On Allow the text is written before it applies, marked with who asked
  and the item (`added by agent:main 2026-11-22 (item 41)`), logged
  `saved`, and listed where the owner can see and remove it:
  `/triggers`, `/workflows`, `/agents`, `/apps`, `/envs`. What the owner
  writes by hand needs no approval; `rules`, `folders.ini`, pins and
  `mcp.ini` have no setup tool at all.

### Secrets in commands

Stored secrets reach a program only where the owner named them: an MCP
server's `secret =` lines (mcp.ini, as today; later inside a sandbox too)
and a folder's `vars` (gap 3), which reach host commands started in that
folder. A command in a sandbox or on a remote gets no secret or login
value (gap 2). The specs refer here instead of restating it.

### Snapshots

Workspace versions are kept one way, gap 3's snapshots, and the file
roles spec owns them. Gap 2's checkpoints are these snapshots:

- What: a workspace folder, or an environment's home as `env:NAME`.
- When: around the runs that change a folder marked `snapshots` in
  `folders.ini`; by hand (`/snapshot FOLDER [LABEL]`, `harness snapshot
  take`); by the agent's `snapshot` tool (default allow).
- Restore: the owner only (`/restore FOLDER ID`, `harness snapshot
  restore`), refused while a run is going; it snapshots first, so it can
  be undone. No tool restores.
- Store and limits: gap 3's (`snapshots/` in the data folder, each
  content once; the newest 50 per folder; `[limits] snapshot_mb`).
  Objects are written by cloning where the file system can (APFS, btrfs,
  XFS, ReFS and Dev Drives), else copied. Gap 2's `checkpoints/`, `[env]
  copy_mb`, `env checkpoint`, `env restore` and its two tools are gone.
- Hosted: a cloud machine's own snapshots and clones (gap 2) are the
  machine's; the workspace's versions stay snapshots.

### Smaller points

- The conversation a file reports to is its `to` key, default `main`:
  `tasks.ini`, `briefs.ini`, `triggers.ini`, a workflow's header,
  `app.ini` (which said `conversation`).
- In files a built-in tool is its name and an MCP tool `SERVER/TOOL`
  (`SERVER/*` all of a server's), as rules match it: definitions' and
  triggers' `tools`, a workflow's `tool` step and `tools`, an app's
  `acts`, a trigger's `mcp` source. The model sees `SERVER__TOOL`.
- A workflow step's `env NAME` (gap 7) picks where its commands run, on a
  `tool shell` or a `do` step; gap 2 reads it after pins and before the
  definition's `environment`; a file naming no environment is refused.

### Phase 0

Built first, by the Mac session, before phases A, B and C touch the gate.
It changes no behaviour by itself: 0.3's tests pass unchanged.

1. The who: `Who` (`agent`, `by`, `parent`) on every run (a chat turn:
   `owner`, `main`; a task or brief: `schedule:NAME`, `main`; a helper:
   its parent's `by`, `helper`, `parent`), in `gate.Ctx`, and written to
   the log as above (`conversation` follows with gap 4).
2. Rules: sections and `TOOL@ENV`, the gate order above, with roles an
   empty step until gap 3 and `host` the only environment until gap 2.
3. Grants: the `who` field and `@ENV`; Allow 24 h writes `agent:D`; 0.3
   lines read as before.
4. Gate kinds: the table above with their defaults, setup calls asked
   every time like money, and "nobody can answer" set for schedule,
   trigger and workflow runs (today's `Ctx.scheduled`).

Before phase 0 lands, the Windows session works on what doesn't touch the
gate (its handoff: `harness/HANDOFF-windows-platform.md`):

- The open Windows items: `harness/HANDOFF-windows-audit.md` (I27's job
  objects first, for shell, MCP, browse and Chrome; the mintty echo; the
  lock, Ctrl-C and Credential Manager checks; the symlink tests) and
  `harness/HANDOFF-windows-web.md`.
- The sandbox backends as standalone runners (AppContainer with I27's job
  object; bubblewrap, tested in WSL) and the SSH remote with `env key`;
  the macOS runner (sandbox-exec) is the Mac session's, which can test it;
  `environments.ini` read and checked; gap 2's backend tests run against
  the runners.
- The app server: the loopback listener with the exclusive bind, tokens,
  the Host, Origin and frame checks, headers and CSP, the path checks
  (Windows names too), `app.ini` read and checked, app files and the
  built-in apps' pages served; the `api/` reads, acts and runs wait for
  phase 0.
- The clone helpers the snapshot store uses (btrfs and XFS, ReFS and Dev
  Drive block cloning), as functions with their own tests; APFS is the
  Mac session's.
- On Windows: replacing a file by rename while another process reads it
  (`state/inbox`, `state/conversations`, `state/grants`).
- The hosted design notes (gaps 1, 2, 3).

After phase 0 lands: environments in the gate (`shell@ENV`, pins,
`env_save`), apps' `api/` as `app:NAME`, then the bar once the inbox
(phase A) is in.

## Calls made here (the owner can change them)

- One gap per spec, built in phases, not one big release; a phase 0 for
  what all of them change in the gate and the log.
- Agent definitions as Markdown files with a header, like skills.
- Apps served from the owner's machine on 127.0.0.1 with a per-start
  token; Telegram opens them as links (a Mini App later, with the hosted
  address).
- Environments: sandboxes on the owner's machine first (one backend per
  platform), then POSIX remotes over the system's SSH, both in phase C;
  VMs, WSL and Windows remotes later. (The environments spec builds
  remotes in phase C; this line said "after".)
- The shared formats above.

## Questions for the owner

Merged from the eight specs. The others are settled as calls in their
specs, marked "settled".

1. **Answered 2026-11-23: "A and C opt-in"** — the butler's own address,
   and the owner's mailbox read-only with drafts, off until turned on
   (`2026-11-23-harness-email-design.md`). The question was: Email
   (conversations, triggers): the agent's own address you forward
   to, or your mailbox? Own: your threads are conversations; harness sees
   only what you forward. Yours: mail triggers read your whole INBOX,
   read-only; no email conversations.
2. Money (triggers, workflows): may runs started by mail, feeds, pages or
   workflows move money under `[money] scheduled = on`? Yes: as specced.
   No: never; workflows only in tool steps asked in the inbox. Or a
   separate switch, off by default.
3. Default environment (environments) for runs started by schedules,
   triggers, workflows and apps: host or sandbox? Host: as today; allowed
   commands reach the data folder. Sandbox: no data folder, home or
   network unless allowed; Linux needs bubblewrap.
4. Apps on your phone (apps) before hosting? No: links open only on the
   harness machine (or via `ssh -L`). Yes: harness behind a TLS front you
   run (`tailscale serve`); anyone reaching it with a link opens apps
   until restart.
