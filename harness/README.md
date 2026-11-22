# harness

A personal agent you talk to in Telegram (or the terminal). It does
research, hands parts of a job to helpers that work in parallel, sends a
morning brief on the topics you follow, runs scheduled tasks, uses MCP
servers and saved skills, and remembers what you bring up. Every action it
takes, and every action of its helpers, passes one gate and is written to
one log you can check.

```
Telegram ⇄ ┐                          ┌─ shell, files, fetch, browse, web, search
terminal ⇄ ┼─► agent ─► gate ─► tools ┼─ MCP servers (money tools: asked every time)
schedule ──┘    │  ▲  ▲   │           └─ delegate ─► helpers ─► gate ─► tools
                ▼  │  │   ▼
          omnigate memory skills  action log
```

One binary for macOS, Linux (x86_64, arm64) and Windows (x86_64), about
1.9 MB on macOS and 2.3 MB on Linux stripped, nothing beyond the Zig
standard library (and the system's Security framework on macOS). Models
are reached only through [omnigate](https://github.com/Legatia/omnigate),
which holds the provider keys and the budgets.

**State: 0.3.0, tested on macOS by its own tests: 348 unit tests, among
them the browser and login tests against headless Chrome and local pages,
and an end-to-end script of 45 checks that drives the real binary against
stand-ins for omnigate, Telegram, feeds, search and two MCP servers. An
earlier build of 0.3.0 also passed its tests in CI on Linux and Windows.
Nothing has run yet against a real omnigate, Telegram bot, MCP server or
website.** See [Limits](#limits).

## Quick start

```
harness init                      # writes ~/.local/share/harness
harness secret add omnigate       # your omnigate key (typed, not shown)
harness secret add telegram       # the bot token from @BotFather
harness secret add search         # optional: a Brave Search API key
harness run                       # keep this running
harness pair                      # then send the printed /pair CODE to your bot
```

Set omnigate's address (there is none by default) and route names in
`config.ini` first; until the address and the key are there, commands say
so and model calls are refused. The first Telegram account to send a valid
pairing code (valid 10 minutes) becomes the owner; messages from anyone
else are dropped and logged, and a pairing attempt from another account is
answered. To move the bot to another account, run `harness pair` again and
send the new code from that account; the old one is told.

`harness chat` does the same in the terminal, for trying it out. Ctrl-D
leaves; a question waiting for an answer is answered Deny.

## The data folder

Everything for one instance is in one folder (`--home DIR`,
`HARNESS_HOME`, or `$XDG_DATA_HOME/harness`, by default
`~/.local/share/harness`; `%LOCALAPPDATA%\harness` on Windows). Copy it to
move the instance. On macOS and Windows the secrets are in the system's
key store under a name kept in `state/store-id` (`harness` for the default
folder), so a copy keeps them and each folder made apart has its own; a
copy you run as a second instance shares them until you delete its
`state/store-id`. On Linux they are in `secrets/`, files only you can
read, so a copy carries them. With `HARNESS_STORE=DIR` they are files in
DIR.

| Path | What |
|---|---|
| `config.ini` | omnigate url and routes, search, Telegram, limits, memory switches |
| `rules` | gate rules |
| `briefs.ini` | briefs and their topics |
| `tasks.ini` | scheduled tasks |
| `mcp.ini` | MCP servers (optional) |
| `logins.ini` | the agent's own logins: name, site, username (no secrets) |
| `profiles/` | each login's browser profile (its cookies) |
| `skills/` | saved skills, one folder each (`NAME/SKILL.md`) |
| `memory/` | one file per memory item |
| `workspace/` | where the agent's files and commands live |
| `log/actions.jsonl` | the action log |
| `secrets/` | Linux: the stored secrets, a file each |
| `state/` | grants, seen feed items, owner, status, lock, approval numbers, money totals, the log's key, `store-id`, `mcp/NAME` (each MCP server's own folder) |

On macOS and Linux, `config.ini`, `rules`, `logins.ini` and `mcp.ini` are
refused if other users can write them. Harness names a settings file it
refuses, and the line of one that does not read. Changes to the settings
files apply after `/reload`; harness tells you when it notices one.

## The gate

Every tool call is decided in one place, in this order:

1. Hard limits no rule lifts: files only inside `workspace/` and no write
   to a symlink; fetch, browse and web only http and https, and no
   address with a name before `@`.
2. A matching `deny` line in `rules`.
3. A grant you gave with "Allow 24 h".
4. The first matching `allow` or `ask` line.
5. The tool's default: `shell`, `fetch`, `browse`, `web`, `login`,
   `skill_save` and MCP tools ask; so does `write_file` for a path with a
   part starting with "." (`.git/config`, `.npmrc`); files, search,
   memory, `skill` and `delegate` are allowed (each helper's own calls
   pass the gate like any other).

```
deny  shell rm -rf *
allow fetch https://news.ycombinator.com/*
allow shell git status
```

File rules and grants see the path inside the workspace: `./notes/a`,
`x/../notes/a`, its absolute path or a symlink to it count as `notes/a`,
and on macOS and Windows so does `Notes/A`. A grant covers the exact
command, path or MCP tool, or a host in any letter case. A `deny` rule
applies to briefs.ini sources too.

Rules for `fetch` and `browse` match an address by its parts: the scheme,
the host (`*.example.com` is every name below example.com, `*` any host),
the port (none: the scheme's own; `:*` any) and the path with its query
(none: any). `allow fetch https://*.example.com/*` covers
`https://docs.example.com/a`, never `https://evil.com/.example.com/`.
`web` rules name a host the same way (`*.example.com`, `localhost:8080`).
An `allow` rule for these must be written so, and harness names the line
that is not; a `deny` or `ask` rule may be any pattern, matched against
the whole address.

The gate, fetch, browse and web read an address the same way. One with a
name before `@` (`good.com@evil.com`), a backslash or a space, or a host
with `%` or letters outside ASCII, is refused (an international name is
written in its `xn--` form). Otherwise every spelling of a host is the
same host: any letter case, a trailing dot, the scheme's own port, an IPv4
address written as `0x7f.1` or `2130706433`. `.` and `..` in a path are
resolved before the rules see it, and a path that hides one from them
(`..%2F`, `..;`) is refused.

`ask` sends you the whole call (a file's content too) with three buttons:
Allow once, Allow 24 h, Deny. A long one comes in several messages with
the buttons on the last; a call over 12 KB is refused. A button from
before a restart, or under another question, answers nothing, and harness
says it is out of date. No answer in `approval_seconds` (default 10
minutes), or before the turn's time (`turn_seconds`) is up, counts as
Deny. In a scheduled run nobody can answer, so `ask` is Deny there, and
the run says what it skipped.

`/stop` stops everything at once: the running turn, any shell command and
everything it started, and background runs. `/new` starts a fresh
conversation; memory stays. Ctrl-C or a kill (SIGINT, SIGTERM; on Windows
Ctrl-C or closing the console) does what `/stop` does, logs it, and ends
harness; another instance can start at once.

Shell commands get only `PATH`, `HOME`, `LANG` and `TERM` (on Windows also
the system's own variables such as `SystemRoot`, `TEMP` and `APPDATA`,
without which programs there cannot reach the network or find their
files; MCP servers get the same). Stored secrets are masked in all tool
output as `[secret:NAME]` before anything is cut from it, and before the
model or the log sees it. A tool call gets at most what is left of the
turn's time.

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
twice, and they ask you one question at a time; one that can't be answered
before the turn ends is refused without asking. `/stop` stops them too.

Every model call of a turn marks its unchanging start (tools, the stable
part of the instructions) for omnigate's prompt cache, and each step of a
turn reads the earlier steps from cache. When a conversation outgrows
`conversation_bytes`, the oldest turns are replaced by a summary instead
of being dropped; turns that still don't fit after the summary are
dropped, logged, and the agent is told.

## Research

`fetch` turns pages into readable text (headings, lists, tables, links
with full addresses; menus, footers and scripts dropped) and returns long
pages in parts, each saying where the next starts. `browse` does the same
after a headless Chrome or Chromium has run the page's JavaScript, with a
fresh throwaway profile each time (no cookies, no sign-ins), loading
nothing from any host but the page's own and saving no downloads. It is
offered only when a browser is found (`[browser] path`, or the usual
install places).

`fetch` follows up to 5 redirects, never from https to http or to an
address with a name before `@`; each passes the gate as a fetch of its own
(on a host the call already reached only a `deny` rule stops it), and the
answer says where it ended. `fetch`, `search`, `browse` and each `web`
action end when the turn's time is up, redirects and all; `/stop` ends
one under way.

## Logins

The agent can have accounts of its own: a GitHub account for a bot, a
newsletter sign-up, a test shop. They are the agent's accounts, never
yours: don't give it your own passwords.

```
harness login add github-bot --site github.com --username agent-bot@example.com
Password for github-bot (not shown; empty: the agent makes one when it signs up):
TOTP secret for github-bot (not shown; empty for none):
Added github-bot to logins.ini (site github.com). Stored its password and TOTP secret in the macOS Keychain.

harness login list
harness login rm github-bot       # its secrets and its browser profile too
```

`logins.ini` holds the name, site and username; the password, the TOTP
secret and the passkeys go to the key store (`login-NAME-password`,
`login-NAME-totp`, `login-NAME-passkeys`). `/logins` lists them in chat.

The agent uses them through `web`, an interactive headless Chrome: open a
page, type into a field, click, press Enter, Tab or Escape, read. Each
action returns the address, the page's fields, buttons and links numbered
by `ref`, and its text. One browser per turn, closed when the turn ends
or on `/stop`. Opened with a login, it uses the login's own profile in
`profiles/NAME`, so the cookies (those that end with the session too), and
with them the sign-in, stay for the next turn. Without one, a throwaway
profile is deleted afterwards. Chrome's own password manager is off in
every profile; downloads are refused, and a tab or window a page opens is
closed before it loads anything (the agent is told its address). A click
is the mouse's, at the element's centre; one under a banner or dialog is
refused. Alerts and leaving-the-page questions are accepted, confirm and
prompt dialogs dismissed, and the agent sees their text when they come
from the page's own host.

The model types placeholders, never values: `{login:NAME.username}`,
`{login:NAME.password}`, `{login:NAME.code}` (the current TOTP code).
Harness fills them in, and the log, the gate and the model see only the
placeholder.

- **Bound to the site.** A value is typed only into a page on the very
  host the gate allowed the login on, and only on the login's site or a
  name below it (`github.com`, `gist.github.com`; not
  `github.com.evil.com`), over https (http only for `localhost`). The
  check and the typing are one script in the page, run where the page's
  own scripts can't change what it sees, so a redirect in between can't
  catch the value. Only fields of the page itself (its open shadow roots
  too), never of frames. A placeholder is the whole text of a `type`
  action, and goes only into a matching field: a password into a password
  field, a username into a text or e-mail field, a code into a text,
  number or phone field (or one marked for one-time codes).
- **Sign-ups.** A login stored without a password gets one (24 letters,
  digits and symbols) the first time its password placeholder is typed on
  its site; it is stored before it is typed.
- **Passkeys.** A browser opened with a login has a software security key
  holding that login's passkeys. After every action harness reads it back:
  new passkeys for the login's site are stored, any other is removed and
  the agent is told. So the agent can add a passkey in a site's settings
  and sign in with it next time, and can't make or use one for another
  site. If the stored passkeys can't be read, none are loaded and new ones
  aren't saved; the agent is told.
- **The gate.** `web` asks for each host (a 24 h grant covers the host),
  again when a click lands on a host not yet allowed in this session;
  `login` asks the first time a browser uses a login on a host (`NAME
  HOST`; a 24 h grant covers that login there). Scheduled runs: asking is
  refusing, as everywhere. Helpers never get `web`.
- **Masked.** Every login's password, TOTP secret and current code are
  masked in what `web` returns; stored login passwords in all tool output.

Not handled: CAPTCHAs, codes sent by SMS or e-mail (the agent asks you),
cards and payments.

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
max_per_call = 500   ; this server's caps; default: [money] in config.ini
max_per_day = 2000
```

Servers start together (20 s in all) with `harness run`, `chat` and
`task run` and on `/reload`, each in a folder of its own (`state/mcp/NAME`,
never the workspace), with only PATH, HOME, LANG, TERM and their named
secrets (`harness secret add github`; `/reload` picks up one added
meanwhile). Their tools appear as `github__list_issues` and ask by
default; a 24 h grant covers that tool with any input; rules match
`mcp github/list_issues *` (the server, the tool, then the whole input as
JSON). Server names use a-z, 0-9, - and _, up to 32 (no `__`); secret
names follow `harness secret add`. A tool whose `server__tool` name is
over 64 characters, or that another tool already has, is left out;
`/status` says which, and what started.

### Money

Tools listed under `money =` are asked every time, with no "Allow 24 h"
button; no grant or `allow` rule lifts that (a `deny` rule still applies).
Helpers never get them. `/dryrun on` stops money calls from being made:
the agent is told what would have been sent. It applies at once, to a
call waiting for your answer too; the money question says whether it is
on.

`max_per_call` and `max_per_day` are hard caps checked before you are
asked: the server's own lines in mcp.ini, else `[money]` in config.ini
(there 0: no cap). In a server's section `none` lifts config.ini's cap
for that server, and harness says so at start and in `/status`; `0` there
is an error (write `none`, or remove the line to use config.ini's). Each
server has its own day total in `state/money`. With a
cap set, a money tool that `amount =` gives no field is refused, and so is
a call without its amount (`tool:none` moves no amount). An amount counts
toward the day from the moment you are asked, so two runs cannot both
pass the same cap; it is taken back only if the call is not made. A call
that was sent stays counted even if it failed or timed out, since that
does not prove nothing happened. If `state/money` is damaged or cannot be
read or written, money calls are refused with the reason. Scheduled runs
never move money unless you set `[money] scheduled = on` and a cap for
that server.

In mcp.ini, `amount =` and the caps need a `money =` line in the same
section, a per-tool `amount` names only tools listed there, and `none` is
said per tool, never alone. A server whose `money =` names a tool it does
not have is not started.

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
that was changed, removed or reordered, and also lines cut from the end,
by the last line named in `state/status`. Harness warns at start if the
log does not end where it left it. Stored secrets are masked in every
field, what you type included.

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
picks up to 5 lasting facts from the turns since its last run. When the
agent or that call saves an item, you get one line: "Saved to memory: …
(/forget ID)". A repeat is not saved twice; a correction (another number,
or a "not") is a new item. Commands: `/memory`, `/pin ID`, `/unpin ID`,
`/forget ID`, `/memory auto on|off` (off: only pinned items go in unless
something is looked up on request), `/private on|off` (on: nothing
written to memory, and the log keeps only sizes and hashes keyed with
`state/log-key`).

## Briefs

```ini
[morning]
at = 07:00
topic = Zig | https://ziglang.org/news/index.xml | search: zig release
```

At the time (in `utc_offset`), harness fetches the feeds (RSS and Atom)
and searches, drops links they gave before (a link is forgotten 60 days
after they last gave it), and only if something is new asks the model
once to write the brief, a link on every line. At most 15 new items per
topic go in; the brief says how many more there were, and those are not
sent later. A quiet day costs no model call. A feed's redirect is
followed on its own host, to another host only with an `allow fetch` rule
or a grant. A brief missed while harness was down runs when it starts. A
brief or task whose answer does not get through runs again after 5
minutes, then 10, 20 … up to 2 hours. `/brief` sends one now; `/topic add`
and `/topic rm` change the topics from chat.

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
`NOTHING`; calls skipped for want of approval are listed either way
("Skipped (needs approval): …"). A task whose omnigate budget is spent is
paused until `/task resume NAME`. `/tasks`,
`/task add NAME | every 15m | instruction`, `/task rm NAME`.

## Commands

`/stop`, `/new`, `/status`, `/brief [NAME]`, `/topics`, `/topic add|rm`, `/tasks`,
`/task add|rm|resume`, `/memory`, `/remember`, `/pin`, `/unpin`,
`/forget`, `/private on|off`, `/skills`, `/skill rm`, `/logins`,
`/dryrun on|off`, `/reload`, `/help`.

CLI: `init`, `secret add|rm|list`, `login add|list|rm`, `pair`, `run`, `chat`, `brief [NAME]`,
`task run NAME`, `memory [list|pin|unpin|forget ID]`, `log verify|tail`,
`health`, `version`. `--home DIR` may come anywhere on the line;
arguments a command does not take are refused. `health` exits 0 only
while `harness run` holds the folder and has ticked in the last 90 s.

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
  nothing it asked for runs. `/stop` waits up to 3 seconds for things to
  end, then answers and says a model call is still ending. A stopped brief
  or task waits for its next scheduled time. A model call ends by the
  turn's time limit; one that timed out is not sent again. A request the
  API refuses as invalid drops that turn, and you are told.
- **Windows.** `/stop` ends a shell command but not processes it started.
- **Feeds** are read up to 4 MiB, fetched pages up to 1 MiB, rendered
  pages up to 4 MiB.
- **MCP servers and the browser** run as you, like shell commands. An MCP
  server is a program you chose to run; harness limits its environment,
  not what it does. The browser gets only PATH, HOME and LANG (on Windows
  also the system's own variables), and never the macOS Keychain or a
  desktop keyring.
- **Money caps** are whole numbers in the units of the tools' amount
  fields, one day total per server: keep each server's money tools in one
  unit (say USD). They trust the tool to mean what that field says.
- **The Windows Credential Manager** keeps at most 2560 bytes of a value;
  `secret add` refuses longer ones.
- **One owner, one chat.** Messages sent while the agent works are queued.
- **`web` is macOS and Linux only** for now (Chrome is driven through
  pipes on file descriptors 3 and 4); on Windows it is not offered.
- **Login cookies are on disk** in `profiles/NAME`, readable by you (the
  folder is 0700), like any browser profile. Anyone who can read the data
  folder can use those sessions.
- **Site binding is by host name.** A login for `example.com` is typed on
  any name below it, and its passkeys are kept only for the site or a name
  below it; a site needs a dot (except `localhost`), but harness doesn't
  know the public suffix list, so set the site no wider than needed.

Not in 0.3.0: the Agent Client Protocol server, desktop use (headdesk), a
sandbox per command, WhatsApp and voice, helpers that report back later,
cards and payments for the agent, the browser on Windows, screenshots,
and the hosted service.

## Build

```
zig build                     # zig-out/bin/harness
zig build test --summary all  # unit tests, then scripts/smoke.sh end to end
```

Zig 0.17.1.
