# harness

A personal agent you talk to in Telegram (or the terminal). It does
research, hands parts of a job to helpers that work in parallel, sends a
morning brief on the topics you follow, runs scheduled tasks, uses MCP
servers and saved skills, and remembers what you bring up. Every action it
takes, and every action of its helpers, passes one gate and is written to
one log you can check.

```
Telegram ⇄ ┐                          ┌─ shell, files, fetch, browse, search
terminal ⇄ ┼─► agent ─► gate ─► tools ┼─ MCP servers (money tools: asked every time)
schedule ──┘    │  ▲  ▲   │           └─ delegate ─► helpers ─► gate ─► tools
                ▼  │  │   ▼
          omnigate memory skills  action log
```

One binary for macOS, Linux (x86_64, arm64) and Windows (x86_64), about
1.6 MB stripped, nothing beyond the Zig standard library (and the system's
Security framework on macOS). Models are reached only through
[omnigate](https://github.com/Legatia/omnigate), which holds the provider
keys and the budgets.

**State: 0.2.0, tested by its own tests (156 unit tests, and an end-to-end
script of 25 checks that drives the real binary against stand-ins for
omnigate, Telegram, feeds, search and an MCP server) on macOS; 0.1.0's
tests also passed in CI on Linux and Windows. Not yet run against a real
omnigate, a real Telegram bot or a real MCP server.** See [Limits](#limits).

## Quick start

```
harness init                      # writes ~/.local/share/harness
harness secret add omnigate       # your omnigate key (typed, not shown)
harness secret add telegram       # the bot token from @BotFather
harness secret add search         # optional: a Brave Search API key
harness run                       # keep this running
harness pair                      # then send the printed /pair CODE to your bot
```

Set omnigate's address and route names in `config.ini` first. The first
Telegram account to send a valid pairing code (valid 10 minutes) becomes
the owner; messages from anyone else are dropped and logged.

`harness chat` does the same in the terminal, for trying it out.

## The data folder

Everything for one instance is in one folder (`--home DIR`,
`HARNESS_HOME`, or `~/.local/share/harness`; `%LOCALAPPDATA%\harness` on
Windows). Copy it to move the instance; secrets live in the system's key
store, not in the folder.

| Path | What |
|---|---|
| `config.ini` | omnigate url and routes, search, Telegram, limits, memory switches |
| `rules` | gate rules |
| `briefs.ini` | briefs and their topics |
| `tasks.ini` | scheduled tasks |
| `mcp.ini` | MCP servers (optional) |
| `skills/` | saved skills, one folder each (`NAME/SKILL.md`) |
| `memory/` | one file per memory item |
| `workspace/` | where the agent's files and commands live |
| `log/actions.jsonl` | the action log |
| `state/` | grants, seen feed items, owner, status, lock |

`config.ini` and `rules` are refused if other users can write them. Changes
to the settings files apply after `/reload`; harness tells you when it
notices one.

## The gate

Every tool call is decided in one place, in this order:

1. Hard limits no rule lifts: files only inside `workspace/`, fetch only
   http and https.
2. A matching `deny` line in `rules`.
3. A grant you gave with "Allow 24 h".
4. The first matching `allow` or `ask` line.
5. The tool's default: `shell`, `fetch`, `browse`, `skill_save` and MCP
   tools ask; files, search, memory, `skill` and `delegate` are allowed
   (each helper's own calls pass the gate like any other).

```
deny  shell rm -rf *
allow fetch https://news.ycombinator.com/*
allow shell git status
```

`ask` sends you the call with three buttons: Allow once, Allow 24 h, Deny.
No answer in `approval_seconds` (default 10 minutes) counts as Deny. In a
scheduled run nobody can answer, so `ask` is Deny there, and the run says
what it skipped.

`/stop` stops everything at once: the running turn, any shell command and
everything it started, and background runs. `/new` starts a fresh
conversation; memory stays.

Shell commands get only `PATH`, `HOME`, `LANG` and `TERM`. Stored secrets
are masked in all tool output as `[secret:NAME]` before the model or the
log sees it.

Money tools (below) are the exception: asked every time.

## Helpers

`delegate` hands up to 8 tasks to helpers that run at the same time:
research across several sources, comparisons, anything that splits into
parts. Each helper starts with a clean context, gets only the tools it was
given (never `delegate`, `remember`, `skill_save` or money tools), uses
`worker_model` unless the task asks for the strong one, and returns a short
answer, not its working. Limits per helper in `[agents]`: model calls,
input tokens and answer size; at most `parallel` run at once in the whole
instance. Helpers of one call share fetched pages, so none is downloaded
twice, and they ask you one question at a time. `/stop` stops them too.

Every model call marks its unchanging start (tools, the stable part of the
instructions) for omnigate's prompt cache, and each step of a turn reads
the earlier steps from cache. When a conversation outgrows
`conversation_bytes`, the oldest turns are replaced by a summary instead
of being dropped.

## Research

`fetch` turns pages into readable text (headings, lists, tables, links
with full addresses; menus, footers and scripts dropped) and returns long
pages in parts, each saying where the next starts. `browse` does the same
after a headless Chrome or Chromium has run the page's JavaScript, with a
fresh throwaway profile each time (no cookies, no sign-ins). It is offered
only when a browser is found (`[browser] path`, or the usual install
places).

## MCP

```ini
[github]
command = npx -y @modelcontextprotocol/server-github
secret = GITHUB_PERSONAL_ACCESS_TOKEN:github   ; env var : stored secret

[broker]
command = /opt/broker-mcp/server
secret = BROKER_KEY:broker
money = place_order, cancel_order              ; tools that move money
amount = place_order:notional_usd, cancel_order:none   ; or one field for all: amount = notional_usd
```

Servers are started when harness starts and on `/reload`, in the workspace
folder, with only PATH, HOME, LANG, TERM and their named secrets
(`harness secret add github`). Their tools appear as `github__list_issues`
and ask by default; a 24 h grant covers that tool with any input; rules
match `mcp github/list_issues *` (the server, the tool, then the input as
JSON). `/status` shows what started.

### Money

Tools listed under `money =` are asked every time, with no "Allow 24 h"
button; no grant or `allow` rule lifts that (a `deny` rule still applies).
Helpers never get them. `[money] max_per_call` and `max_per_day` are hard
caps checked before you are asked; with a cap set, a call without its
amount is refused (a tool listed as `:none` moves no amount). An amount
counts toward the day from the moment you are asked, so two runs cannot
both pass the same cap; it is taken back only if the call is not made. A
call that was sent stays counted even if it failed or timed out, since
that does not prove nothing happened. Scheduled runs never move money
unless you set `[money] scheduled = on` and at least one cap. `/dryrun on`
stops money calls from being made: the agent is told what would have been
sent.

## Skills

Skills are folders in the agentskills.io format (`skills/NAME/SKILL.md`
with `name` and `description`). The agent sees their names and
descriptions, loads one with `skill` when it fits, and can save one with
`skill_save` (asked). `/skills` lists them, `/skill rm NAME` removes one.

## The log

One JSON line per action: messages, model calls (tokens), gate decisions
with the reason, tool calls with their input and output (up to 2 KB each),
memory changes, briefs, tasks, settings changes. Each line carries the
SHA-256 of the line before it; `harness log verify` finds the first line
that was changed, removed or reordered, and harness warns at start if the
log does not end where it left it. No secret value is ever written to it.

## Memory

Each item is a plain file. Its strength comes from your mentions: each one
counts, recent ones count more (`ln Σ (days since + 1)^-0.5`). Only your
own messages count as mentions, not the agent's.

| Level | When it reaches the model |
|---|---|
| Pinned | always, whatever else is switched off |
| Top (the 20 strongest) | always, with automatic recall on |
| Middle | when a message has 30% of its key words |
| Bottom (sunk below strength −1) | when a message has 70% of its key words |

Items are written by you (`/remember TEXT`), by the agent (`remember`), and
after a conversation has been quiet for 30 minutes by one model call that
picks up to 5 lasting facts from it. Commands: `/memory`, `/pin ID`,
`/unpin ID`, `/forget ID`, `/memory auto on|off` (off: only pinned items
go in unless something is looked up on request), `/private on|off` (on:
nothing written to memory, and the log keeps only sizes and hashes).

## Briefs

```ini
[morning]
at = 07:00
topic = Zig | https://ziglang.org/news/index.xml | search: zig release
```

At the time (in `utc_offset`), harness fetches the feeds (RSS and Atom)
and searches, drops links it sent in the last 60 days, and only if
something is new asks the model once to write the brief, a link on every
line. A quiet day costs no model call. A brief missed while harness was
down runs when it starts. `/brief` sends one now; `/topic add` and
`/topic rm` change the topics from chat.

## Scheduled tasks

```ini
[btc-watch]
every = 15m
do = Check the BTC price and tell me if it moved more than 3% since the last check.

[weekly-review]
at = 18:00
days = fri
do = Summarise what you did for me this week.
```

Each run is the same agent with a fresh short conversation and the same
gate (with `ask` as Deny). Its answer is sent to you unless it is
`NOTHING`. A task whose omnigate budget is spent is paused until
`/task resume NAME`. `/tasks`, `/task add NAME | every 15m | instruction`,
`/task rm NAME`.

## Commands

`/stop`, `/new`, `/status`, `/brief [NAME]`, `/topics`, `/topic add|rm`, `/tasks`,
`/task add|rm|resume`, `/memory`, `/remember`, `/pin`, `/unpin`,
`/forget`, `/private on|off`, `/skills`, `/skill rm`, `/dryrun on|off`,
`/reload`, `/help`.

CLI: `init`, `secret add|rm|list`, `pair`, `run`, `chat`, `brief [NAME]`,
`task run NAME`, `memory [list|pin|unpin|forget ID]`, `log verify|tail`,
`health`, `version`.

## Limits

- **Same user, same machine.** An approved shell command runs as you and
  can reach the data folder, including the rules and the log. You see every
  such command before it runs (shell asks by default), and the log chain
  shows edits, but it is not a wall. A separate user or a sandbox per
  instance is the fix, and is planned for the hosted version.
- **The log is tamper-evident, not tamper-proof.** Someone who can write
  the file can rewrite the whole chain.
- **No streaming.** Answers arrive whole. A model call already under way
  when you send `/stop` is not cut off, but its answer is dropped and
  nothing it asked for runs. `/stop` waits up to 3 seconds for things to end,
  then answers and says a model call is still ending. A stopped brief or task waits for its next
  scheduled time.
- **Windows.** `/stop` ends a shell command but not processes it started.
  The lock is judged by the status file's age, so after a crash a new
  instance can start 90 seconds later.
- **Feeds** are read up to 4 MiB, fetched pages up to 1 MiB, rendered
  pages up to 4 MiB.
- **MCP servers and the browser** run as you, like shell commands. An MCP
  server is a program you chose to run; harness limits its environment,
  not what it does. The browser keeps harness's environment.
- **Money caps** are whole numbers in the units of the tools' amount
  fields, one day total across all servers: keep all money tools in one
  unit (say USD). They trust the tool to mean what that field says.
- **MCP servers start one after another** when harness starts (up to 20 s
  each), and a secret added for a new server needs a restart, not just
  `/reload`.
- **One owner, one chat.** Messages sent while the agent works are queued.

Not in 0.2.0: the Agent Client Protocol server, desktop use (headdesk), a
sandbox per command, WhatsApp and voice, helpers that report back later,
and the hosted service.

## Build

```
zig build                     # zig-out/bin/harness
zig build test --summary all  # unit tests, then scripts/smoke.sh end to end
```

Zig 0.17.1.
