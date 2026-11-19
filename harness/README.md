# harness

A personal agent you talk to in Telegram (or the terminal). It does
research, sends a morning brief on the topics you follow, runs scheduled
tasks, and remembers what you bring up. Every action it takes passes one
gate and is written to one log you can check.

```
Telegram ⇄ ┐                         ┌─ shell, files, fetch, search
terminal ⇄ ┼─► agent ─► gate ─► tools │
schedule ──┘    │  ▲      │           
                ▼  │      ▼           
          omnigate  memory  action log
```

One binary for macOS, Linux (x86_64, arm64) and Windows (x86_64), about
1.6 MB stripped, nothing beyond the Zig standard library (and the system's
Security framework on macOS). Models are reached only through
[omnigate](https://github.com/Legatia/omnigate), which holds the provider
keys and the budgets.

**State: 0.1.0, tested by its own tests (91 unit tests, and an end-to-end
script that drives the real binary against stand-ins for omnigate,
Telegram, feeds and search) on macOS. Not yet run against a real omnigate
or a real Telegram bot; the Windows build has only been compiled.** See
[Limits](#limits).

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
5. The tool's default: `shell` and `fetch` ask; files, search and memory
   are allowed.

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
everything it started, and background runs.

Shell commands get only `PATH`, `HOME`, `LANG` and `TERM`. Stored secrets
are masked in all tool output as `[secret:NAME]` before the model or the
log sees it.

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

`/stop`, `/status`, `/brief [NAME]`, `/topics`, `/topic add|rm`, `/tasks`,
`/task add|rm|resume`, `/memory`, `/remember`, `/pin`, `/unpin`,
`/forget`, `/private on|off`, `/reload`, `/help`.

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
- **No streaming.** Answers arrive whole. Model calls are not interrupted
  by `/stop`; it takes effect before the next call.
- **Windows.** `/stop` ends a shell command but not processes it started.
  The lock is judged by the status file's age, so after a crash a new
  instance can start 90 seconds later.
- **Feeds** are read up to 4 MiB, fetched pages up to 1 MiB.
- **One owner, one chat.** Messages sent while the agent works are queued.

Not in 0.1.0: the Agent Client Protocol server, browser and desktop use
(headdesk), a sandbox per command, WhatsApp and voice, trading safeguards
beyond the gate, and the hosted service.

## Build

```
zig build                     # zig-out/bin/harness
zig build test --summary all  # unit tests, then scripts/smoke.sh end to end
```

Zig 0.17.1.
