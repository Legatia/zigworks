# harness: design

2026-11-19. Working name `harness`; the name is open. Lives in zigworks next to
headterm, trigrep, headsight, headsound, llmcheck, headdesk and keygate.

## Intent

A personal agent you run (or we host for you) that you talk to in Telegram,
that does research and sends a morning brief on the topics you follow, and
that you can check: every action passes one gate, is written to one log, and
stays inside limits it cannot raise. It answers the complaints recorded
against OpenClaw, Hermes Agent and OpenBot (reports `Zig computer use and
harness.md` and `Hosting a per customer agent harness.md` in
`~/Downloads/reports/`):

- updates break things → one binary, one data folder, swap the file to update;
- memory grows to many GB → hard bounds on everything held in memory;
- agents act with full access and partial logs → default-deny gate, grants
  that expire, a log of every action;
- runaway cost → collection without the model, per-run budgets enforced by
  omnigate;
- standing instructions lost on compaction → pinned items rebuilt into every
  model call.

The user's own words that set scope: everything works through chat; memory
ranks by freshness and by how often the user brings something up, old items
sink and come back only when very relevant; a toggle for automatic recall;
models only through the user's gateway, omnigate; first jobs are research and
a daily brief; a paid hosted version later, earning a subscription plus a
margin on model use. One agent does everything: chat, research, briefs,
scheduled tasks and, later, trading. There are no separate products or
tiers; trading is the same agent with the right tools and rules.

## Goals (this build, v0.1.0)

1. Chat with the agent in Telegram, owner only, and in the terminal
   (`harness chat`) through the same core.
2. An agent loop over omnigate's Anthropic-style `/v1/messages` with tools.
3. One gate for every tool call: rules (allow / ask / deny), approvals as
   Telegram buttons (once, 24 hours, deny), grants that expire, a stop command
   that works mid-run.
4. An append-only, hash-chained action log with `harness log verify`.
5. Memory as plain files ranked by mentions and age, three levels plus pinned
   items, keyword recall without a model call, toggles for automatic recall
   and for private conversations.
6. Morning briefs: feeds and searches collected without the model, already
   seen items dropped, one model call only when something is new, a link on
   every item.
6a. Scheduled tasks: any instruction run by the same agent on a schedule
   (`at` a time of day, or `every` N minutes), through the same gate, with
   `ask` treated as deny. This is how monitoring and, later, trading run.
7. Hard limits: conversation size, steps per turn, tool output, run time,
   concurrent runs; omnigate's 402 (budget spent) stops the run and says so.
8. Linux, macOS and Windows; one binary; Zig 0.17.1; tests that run without
   network, plus an end-to-end script against stand-in services.

## Non-goals (v0.1.0; planned later, in this order)

- The Agent Client Protocol server (so OpenBot and editors can drive it).
- Browser and desktop runs (headdesk, a headless browser) in throwaway
  containers; computer use generally.
- Running each tool command in a sandbox (bubblewrap/Landlock on Linux).
- The hosting service: sign-up, billing, provisioning, admin view, one
  instance per customer on shared EU servers.
- WhatsApp and our own chat app; voice memos via headsound.
- Trading safeguards beyond the gate: paper mode, allowed markets and size
  caps checked in the request body, exchange keys through keygate. Until
  then trading works only as far as the owner's rules allow the agent's
  tools to reach an exchange.
- Streaming model answers to the chat as they are written.

## Anti-goals (a failure even if everything works)

- A secret reaches the model's context, the log or a tool's output unmasked.
- The agent does something the gate did not see, or the log leaves an action
  out.
- Someone other than the paired owner can make it act.
- Memory use grows with uptime.
- A scheduled run waits for an approval nobody can give, or retries a model
  call after omnigate said the budget is spent.
- Copy in chat or docs with slogans; labels are plain (user's CLAUDE.md).

## Constraints

- Zig 0.17.1; std only, plus the system's Security framework on macOS for the
  key store (as keygate).
- Each zigworks tool is its own project with its own copies of shared files.
  Copy and adapt: `sock.zig`, `http.zig`, `sse.zig`, `jv.zig` from llmcheck;
  `store.zig`, `scrub.zig` from keygate. No cross-project imports.
- omnigate is the only model endpoint. It authenticates `/v1/messages` with
  `x-api-key`; 402 means the key's budget is spent; 429 carries `retry-after`.
- Secrets (omnigate key, Telegram bot token, search API key) live in the OS
  store via keygate's `store.zig`, service name `harness`. Tools never get
  them in their environment.

## How it is put together

One process, `harness run`, with these parts:

```
Telegram ⇄ chat ─┐                       ┌─ shell, files, fetch, search
terminal ⇄ chat ─┼─► core (turns, jobs) ─► gate ─► tools
scheduler ───────┘        │   ▲              │
                          ▼   │              ▼
                   omnigate (model)      action log
                          memory (files)
```

### Data folder

Everything for one instance is under one folder, `HARNESS_HOME` or
`--home DIR` (default `~/.local/share/harness`, `%LOCALAPPDATA%\harness`).
Copying the folder moves the instance (secrets excepted: they are in the OS
store, or in `secrets/` when the file store is used).

```
config.ini        model, chat, limits, memory switches
rules             gate rules, one per line
briefs.ini        briefs and topics
memory/           one file per memory item
workspace/        the agent's working directory for files and commands
state/            grants, seen feed items, conversations, owner id, status
log/actions.jsonl the action log
```

`harness init` writes commented defaults. Files the agent could use to raise
its own limits (`config.ini`, `rules`) are refused if writable by others, as
keygate does; the gate denies tool writes outside `workspace/` by default.

### config.ini (defaults shown)

```ini
[model]
url = http://127.0.0.1:8080       ; omnigate
model = claude-sonnet              ; the omnigate route name
memory_model = claude-haiku        ; for writing memories
key = omnigate                     ; name of the secret holding the key
max_tokens = 4096

[chat]
telegram = on
token = telegram                   ; secret name
api = https://api.telegram.org     ; changeable for tests
utc_offset = +00:00                ; for brief times and dates shown

[limits]
steps_per_turn = 20
turn_seconds = 600
tool_output_bytes = 16384
conversation_bytes = 200000        ; oldest turns dropped beyond this
concurrent_runs = 2
approval_seconds = 600

[memory]
auto = on
top_size = 20
```

### Runs and concurrency

One process owns a data folder: `harness run` and `harness chat` take a lock
file (`state/lock`) and the second one refuses to start. The owner has one
conversation. A message that arrives during a turn is queued and the owner
is told ("Queued; /stop cancels the current turn"). Briefs and the memory
writer run in their own runs beside the chat; `concurrent_runs` counts all
runs, so the default 2 is the chat turn plus one background run, and a
background run waits for a free slot.

### Agent loop

A turn: build the system prompt (base instructions, pinned items, top level,
recalled items, the date), send the conversation and tool definitions to
omnigate (non-streaming), run requested tools through the gate, repeat until
the model stops or a limit is reached. Before every model call and every tool
call the stop flag is checked. Conversation history is bounded by
`conversation_bytes`; when it is exceeded the oldest whole turns are dropped
and the model is told how many. Pinned items are never part of the history,
so dropping turns cannot lose them.

Errors: 402 ends the run with "Model budget used up" to the owner and a log
line, no retry. 429 waits `retry-after` (capped at 60 s) once, then ends the
run. Connection errors retry once.

### Tools (v0.1.0)

| Tool | Does | Gate default |
|---|---|---|
| `shell` | `sh -c` (Windows: `cmd /c`) in `workspace/`, time limit, output capped | ask |
| `read_file` | a file under `workspace/` | allow |
| `write_file` | a file under `workspace/` | allow |
| `fetch` | HTTP GET of a URL, text only, size capped | ask per host |
| `search` | web search (Brave Search API; key in the store) | allow |
| `recall` | memory search by words | allow |
| `remember` | writes a memory item (counts as no mention) | allow |

Tool environments get no secrets: the shell runs with a reduced environment
(PATH, HOME, LANG, TERM) and the omnigate key, bot token and search key are
never in it. Output that contains a stored secret is masked with
`scrub.zig` before it reaches the model or the log.

### Gate

`rules` lines. A matching `deny` always wins; otherwise the first matching
`allow` or `ask` line decides; otherwise the tool's default from the table
above (built in, not written into `rules` by `init`, which writes only
commented examples):

```
deny  shell rm -rf *
allow fetch https://news.ycombinator.com/*
ask   shell *
```

Hard limits no rule can lift: `read_file` and `write_file` resolve paths
and refuse anything outside `workspace/`; `fetch` refuses non-http(s)
schemes. `rules` and `config.ini` are read at start. If either file changes
while running, the change is not applied; the owner is told and it applies
after `/reload` from the owner. Accepted risk in v0.1.0: an approved `shell`
command runs as the same user and can reach the data folder; the fix is a
separate user or sandbox (hosting, later), and the owner sees every such
command before it runs because `shell` defaults to `ask`.

Pattern syntax: `*` matches any run of characters; the pattern is matched
against the tool's main argument (command line, path, URL). `ask` in a chat
turn sends the owner a message with what will run and three buttons: Allow
once, Allow 24 h, Deny. No answer in `approval_seconds` counts as Deny.
`Allow 24 h` stores a grant (tool + exact argument, or the URL host for
`fetch`) in `state/grants` with its expiry. In a scheduled run, `ask` is
Deny and the brief says what was skipped. Every decision is logged.

Brief sources: a feed or search listed in `briefs.ini` is allowed because
the owner listed it (by editing the file or with `/topic add`); the gate
records that reason. Nothing else a brief does is allowed implicitly.

`/stop` (or Ctrl-C in `harness chat`) sets the stop flag, kills a running
shell command, and ends all runs; the reply lists what was stopped.

### Action log

`log/actions.jsonl`, one JSON object per line: `seq`, `time` (UTC),
`kind` (turn, model, tool, gate, memory, brief, chat, config), the
details, and `prev`, the SHA-256 of the previous line. Tool arguments and
output are stored up to 2 KB, masked. `harness log verify` checks the chain
and reports the first broken line. The last hash is also kept in
`state/status`, so a rewritten log is caught on start. This is
tamper-evident, not tamper-proof: an agent running commands as the same user
could rewrite both; separate users (hosting) close that.

### Memory

Each item is a file `memory/<id>.md`:

```
id: 20261119-0007
created: 2026-11-19T08:12:00Z
mentions: 2026-11-19T08:12:00Z 2026-11-21T07:40:00Z
pinned: no
terms: zig compiler release
---
The user follows Zig compiler releases and wants breaking changes first.
```

- Strength: `ln(Σ (age_in_days + 1)^-0.5)` over the item's mentions
  (ACT-R base-level formula).
- Levels: pinned (always in the prompt, never sinks); top (the `top_size`
  strongest, always in the prompt when auto recall is on); middle; bottom.
  The middle/bottom line is at strength −1.0.
- Recall: words of the message (lowercased, 3+ letters, stop words removed)
  against each item's `terms` plus body words. Middle items are added when
  at least 30% of the item's terms appear; bottom items need 70%. At most 8
  are added per turn, strongest first.
- Mentions: a message from the owner that matches an item at 50% or more
  adds a mention. The agent's own messages never add mentions.
- Writing: `remember` (agent) and `/remember TEXT` (owner) write an item
  straight away, no confirmation; after a conversation goes quiet for 30
  minutes, one call to `memory_model` writes up to 5 items from it. The
  owner removes unwanted ones with `/forget`. A new item whose terms
  overlap an existing one by 80% or more becomes a mention of that one.
- Switches: `/memory auto on|off` (off: only pinned items go in; `recall`
  still works on request); `/private on|off` (no items written, no mentions
  counted). Both persist per chat. While private is on, log lines keep
  only metadata: kind, tool name, gate decision, sizes and a SHA-256 of the
  content, not the text.
- Commands: `/memory` lists items by level with strength and last mention;
  `/pin ID`, `/unpin ID`, `/forget ID`.
- Every write, mention, pin and recall is logged.

### Briefs

`briefs.ini`:

```ini
[morning]
at = 07:00
topic = Zig | https://ziglang.org/news/index.xml | search: zig 0.18 release
topic = AI agents | https://news.ycombinator.com/rss | search: agent harness
```

At the `at` time: fetch each feed (RSS 2.0 and Atom) and run each search,
drop items whose link was sent before (`state/seen`, kept 60 days), and if
nothing is new, send "Nothing new on: …" without a model call. Otherwise one
model call writes the brief from the new items and the topic's memory items,
with the item's link after each line, and it is sent to the owner. The
items, the call and the delivery are logged. `/brief` runs it now;
`/topics` lists topics; `/topic add NAME | sources` and `/topic rm NAME`
change `briefs.ini` (logged). A brief does not wait for approvals and uses
no tools other than fetch of the listed feeds and search.

### Scheduled tasks

`tasks.ini`:

```ini
[btc-watch]
every = 15m
do = Check the BTC price on the exchange API and tell me if it moved more than 3% since the last check.

[weekly-review]
at = 18:00
days = fri
do = Summarise what you did for me this week from the log.
```

Each task runs as a background run of the same agent: its own short
conversation (fresh each time, so nothing grows), the memory switches of the
owner's chat, the gate with `ask` as deny, and the answer sent to the owner
unless it is exactly `NOTHING` (the prompt tells the model it may answer
that). `every` is at least 5 minutes. `/tasks` lists them; `/task add NAME |
every 15m | instruction`, `/task rm NAME` change the file (logged). A task
that hits 402 is paused until the owner sends `/task resume NAME`.

### Telegram

Long polling `getUpdates` (timeout 50 s). Pairing: `harness pair` prints a
one-time code valid for 10 minutes; the first account to send `/pair CODE`
becomes the owner (`state/owner`). Messages from anyone else are dropped and
logged with their user id. Replies longer than 4,096 characters are split.
Approvals use inline keyboards and `callback_query`. Commands: `/stop`,
`/status`, `/brief`, `/topics`, `/topic`, `/memory`, `/remember`, `/pin`,
`/unpin`, `/forget`, `/private`, `/tasks`, `/task`, `/reload`, `/help`.

### CLI

```
harness init                     write the data folder with defaults
harness secret add|rm|list NAME  store a secret (typed, not shown)
harness pair                     print a pairing code for Telegram
harness run                      run the agent (Telegram + scheduler)
harness chat                     talk in the terminal (same core)
harness brief [NAME]             run a brief now, print it
harness memory [list|pin|unpin|forget]
harness log verify | tail
harness health                   exit 0 if running and recent
harness version | help
```

`harness run` writes `state/status` (pid, start, last tick, last log hash)
every 30 seconds; `harness health` reads it.

## Testing

- Unit tests per module, run without network.
- `harness-fake`: one stand-in binary serving a scripted omnigate
  (`/v1/messages` answers from a script file, including tool calls, 402 and
  429), a Telegram Bot API (getUpdates queue, sendMessage record,
  callback queries) and feeds.
- `scripts/smoke.sh`: init, secrets in a file store, pair, a chat turn with a
  tool call that needs approval, the button press, a brief with one new and
  one seen item, a 402, `/stop` during a long command, `log verify`,
  memory ranking after mentions.
- Real services need the user: an omnigate key and a Telegram bot token,
  which only they can create and enter.

## Left to the builder

File and module layout; the exact system prompt; JSON shapes of log lines;
the stop-word list; RSS/Atom edge cases; Windows details of the shell tool.

## Calls I made (not discussed with the user)

- Telegram long polling instead of a webhook (works behind NAT, no TLS
  certificate needed).
- Brave Search as the search provider.
- Non-streaming model calls in v0.1.0.
- Scheduled runs treat `ask` as deny.
- Memory thresholds and the ACT-R formula above.
- A UTC offset setting instead of time-zone names (std has no tz data).
- ACP server moved to the first item after v0.1.0.
- Rule precedence (deny wins), the hard path limits, reload only on
  `/reload`, the single-process lock, queued messages, implicit allow of
  listed brief sources, memory written without confirmation, metadata-only
  logging in private mode (settled after the builder check).
