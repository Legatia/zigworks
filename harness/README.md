# harness

A personal agent you talk to in Telegram (or the terminal), in your chat
with the bot or in a topic of it per subject. It does research, hands
parts of a job to helpers that work in parallel, sends a morning brief on
the topics you follow, runs scheduled tasks, uses MCP servers and saved
skills, and remembers what you bring up. Every action it takes, and every
action of its helpers, passes one gate and is written to one log you can
check.

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

**State: 0.3.0, tested on macOS by its own tests: 477 unit tests (2 skipped), among
them the browser and login tests against headless Chrome and local pages,
and an end-to-end script of 54 checks that drives the real binary against
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
leaves; questions still waiting are withdrawn (not allowed).

## The data folder

Everything for one instance is in one folder (`--home DIR`,
`HARNESS_HOME`, or `$XDG_DATA_HOME/harness`, by default
`~/.local/share/harness`; `%LOCALAPPDATA%\harness` on Windows). Copy it to
move the instance. On macOS and Windows the secrets are in the system's
key store under a name kept in `state/store-id`: `harness` for the
default folder and for a folder an earlier harness used, a name of its
own for a folder made since. So a copy keeps them, and each folder made
apart has its own. A copy you run as a second instance shares them; to
give it secrets of its own, make its folder with `harness init --home
DIR`, copy everything but `state/store-id` into it, and add its secrets
there. On Linux they are in `secrets/`, files only you can read, so a
copy carries them. With `HARNESS_STORE=DIR` they are files in DIR.

| Path | What |
|---|---|
| `config.ini` | omnigate url and routes, search, Telegram, limits, memory switches, the inbox |
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
| `state/` | grants, seen feed items, owner, the conversations (`conversations`), what waits for you (`inbox`), status, lock, money totals, the log's key, `store-id`, files the agent wrote since you last allowed a command (`written`), `mcp/NAME` (each MCP server's own folder) |

On macOS and Linux, `config.ini`, `rules`, `logins.ini` and `mcp.ini` are
refused if other users can write them. Harness names a settings file it
refuses, and the line of one that does not read. Changes to the settings
files apply after `/reload`; harness tells you when it notices one.

## The gate

Every tool call is decided in one place, in this order:

1. Hard limits no rule lifts: files only inside `workspace/` and no write
   to a symlink; fetch, browse and web only http and https, and no
   address with a name before `@`.
2. A matching `deny` line in `rules`: in the shared part, or in a
   section for the call (see Sections).
3. A grant you gave with "Allow 24 h" for this call.
4. The first matching `allow` or `ask` line: in a section for the call's
   definition, then in one for what started its run, then in the shared
   part. An `ask` in a section for a definition that delegated the call,
   or for what started its run, makes an `allow` from elsewhere ask.
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

### Sections

A line `[WHO]` in `rules` starts lines that apply only to the calls it
names; the lines before the first section, or after `[all]`, apply to
every call.

| Section | Its lines apply to |
|---|---|
| `[owner]` | runs you started: your messages, buttons and commands |
| `[schedule:NAME]` | runs of the task or brief NAME, on schedule or by hand |
| `[agent:main]` | the agent's own calls in the chat, tasks and briefs |
| `[agent:helper]` | helpers' calls |

A kind alone covers all its names (`[schedule]`), and `*` works as in
rules (`[schedule:btc-*]`). A section for the call's own definition may
allow more for it, and so may one for what started its run, as a grant
would. A section for a definition that delegated the call (`main`, for
its helpers) only denies or asks: delegating never widens what a helper
may do.

```
deny  shell rm -rf *

[schedule:btc-watch]
allow fetch https://api.coinbase.com/*

[agent:helper]
deny  shell *
```

Sections for `trigger:NAME`, `workflow:NAME/STEP`, `app:NAME` and other
`agent:NAME` are read the same way; they apply once those parts exist. A
task or brief whose name has a space, `:`, `/` or `*` can't be named
exactly in a section; `[schedule]`, or a pattern with `*`, reaches it. A
section harness can't read (`[agnet:main]`) is refused, naming its line.

`shell@NAME` is a rule for commands in environment NAME; a `shell` rule
covers every environment. `host`, the workspace on this machine, is the
only environment for now, so `allow shell@host make*` is
`allow shell make*`. Other tools take no `@`.

After the agent writes a file in the workspace, a shell command that a
rule or a grant allows is asked first, naming the files written since you
last allowed a command (a `pkg.py` or `Makefile` can change what a
command runs), until you allow one; a scheduled run skips it. The list
is kept in `state/written`.

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

`ask` makes an item in your inbox (see Inbox): you get the whole call (a
file's content, a skill's description and body too) with three buttons,
Allow once, Allow 24 h and Deny, and may instead reply to it with text,
which denies it and gives the agent your reason. A long one comes in
several messages with the buttons on the last; a call over 12 KB is
refused, and so is one whose question, or any part of it, could not be
sent. A button answers only its own item; one from before a restart, or
of another item, answers nothing, and harness says why. No answer in
`approval_seconds` (default 10 minutes), or before the turn's time
(`turn_seconds`) is up, counts as Deny. In a scheduled run nobody can
answer, so `ask` is Deny there; the run says what it skipped, and each
skipped call is an item you can allow for that task.

"Allow 24 h" covers that call for the definition that asked: given in
the chat, it covers the agent's chat turns, tasks and briefs
(`agent:main`), not helpers; given to a helper, it covers helpers
(`agent:helper`). A grant kept without a who, as harness 0.3 kept them,
covers every run. `state/grants` holds one a line: the tool
(`shell@host` for a command), the expiry, the exact command, host, MCP
tool or path, and who it covers. `/grants` lists them with who they cover
and until when; `/grant rm N` removes one.

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

## Conversations

You and the agent talk in conversations: `main`, your private chat with
the bot; a topic of that chat per subject; groups you add; and `terminal`
(`harness chat`). Each of yours has its own context, `/new` and
`/private`. Messages wait in one queue, one turn at a time.

- **Topics.** A topic you open in your chat with the bot is a conversation
  from its first message, named after it ("House search" is
  `house-search`; `-2` when the name is taken, `topic-THREAD` when nothing
  is left of it). `/conversation new NAME` opens one from the chat.
  Telegram must have topics in private chats switched on for the bot
  (@BotFather, Bot API 9.3); a topic Telegram refuses has its posts come
  to `main` with `[NAME]` in front, and you are told once.
- **Groups.** In a group harness reads only your `/conversation add NAME`
  (`/conversation@BOT add NAME` too); from then on the agent may post
  there, each post asked. Nothing else said in a group reaches the agent.
- **`send`.** The agent posts with `send`: text up to 16 KB; up to 4
  workspace files up to 20 MB each, as documents (a file holding a stored
  secret is refused, one with a part starting with "." is asked); up to 4
  quick replies of up to 32 bytes, in your own conversations (a press is
  your message there, counted once; one from before a restart answers
  nothing). `final: true` is its reply and ends the turn. A turn that
  stops without one has its last text posted the same way, logged
  `implicit`; working text is never posted, and a turn ended by a limit
  or an error says which. A post that does not get through is kept and
  sent again (see Inbox).
- **The gate.** `send` is a gate kind, its argument the conversation:
  allowed to yours; where others read, asked every time with the whole
  post and the files' names, with no "Allow 24 h" (an `allow send NAME`
  rule lifts that, `deny` stops it, and a run nobody watches is refused).
  The reply passes it too: after `deny send main` harness tells you a rule
  stopped it.
- **Limits** (`[limits]` in config.ini): `sends_per_run = 10` posts in one
  run; `sends_per_hour = 60` to one conversation, all runs counted (past
  it posts are logged, not sent, and `main` hears once an hour).
- **Tasks and briefs** post to `to = NAME` in tasks.ini and briefs.ini
  (default `main`; a name that is no conversation yet opens that topic at
  its first post), with their name in front (`[btc-watch]`). Tasks get
  `send` too.
- **Where things go.** A command's reply goes where you sent it; settings
  notices and the log warning at start to `main`; questions and memory
  notices to the run's conversation. The agent is told its conversation
  and the others' names with each message.
- **Contexts.** At most 16 are kept: for a 17th the least used is dropped
  after the memory writer has read it, and the agent is told when that
  conversation comes back.
- **Pairing** another account moves `main` to it and forgets the old
  account's topics, saying which.

`state/conversations` keeps them, a JSON line each, rewritten whole
(a new file, then a rename) before harness acts on a change:

```json
{"name":"house-search","channel":"telegram","chat":123456789,"thread":5012,"audience":"own","private":false,"created":"2026-11-22T09:30:00Z"}
```

`/conversations` lists them; `/conversation rename OLD NEW` and
`/conversation rm NAME` (harness forgets it; a topic stays in Telegram)
work on any but `main` and `terminal`. `/session [N]` shows the steps
behind the last answer in the conversation it is sent in (N runs back, up
to 20): the message, each model call, each tool call with the gate's
decision, each helper, the posts and how it ended, in one message of up
to 3,500 bytes, read from the log's last 4 MB. `harness log runs [N]` lists
the last runs; `harness log session RID [--json]` shows one with its
helpers, whole or as its log lines. In the terminal every post is
printed, with `[NAME]` in front when it is for another conversation.

## Inbox

What waits for you is one list, kept in `state/inbox`: approvals (the
gate's `ask`), the agent's questions and drafts (`ask_owner`), calls a
scheduled task skipped, and posts that did not get through. Each is an
item with a number, shown as its own message in the conversation it
belongs to (a task's in its `to`, unless others read that; deliveries in
`main`):

```
Allow this? [41]
shell: git push origin main
(Reply with text to deny it and say why.)
```

- **Several at once.** Items wait side by side and are answered in any
  order: answering 44 leaves 41 waiting, helpers' questions too. At most
  `[inbox] questions` (20) questions and approvals of runs are open; one
  more waits for a place until its turn ends, then is refused.
- **Answering.** Press a button, or reply to the item's message with
  text: an approval's reason denies it (the agent gets your words), a
  question's words answer it, a draft's replace it. `/answer ID TEXT` does
  the same. A button answers only its own item, once, and only from a
  message the item was shown in; a later press says how it closed
  ("Already answered: allowed once, 14:03."), any other that it is out of
  date. When an item closes, its messages lose their buttons and show the
  outcome.
- **Expiry.** A run's item closes as Deny at `approval_seconds` or when
  its turn ends, others after 7 days. `/stop` withdraws the items of the
  runs it stops, and leaving `harness chat` withdraws open questions;
  after a crash, a run's open items are void.
- **`/inbox`** lists what waits, oldest first (up to 20), with a Show
  button each that posts the item again where you are. Once a day at
  `[inbox] remind` (09:00, your time; `off` for never), if something has
  waited over 12 hours, harness says how many items wait, without a sound.
  Items a run waits on make a sound; skipped calls and deliveries don't.
- **`ask_owner`.** The agent asks a question with up to 4 choices or to
  be answered in words, or shows a draft to use, drop or replace, and
  waits as for an approval. It gets "chose: Work", "wrote: …", "draft used
  as it is", "draft replaced by the owner: …", "dropped" or "no answer in
  time". It is offered only where you can answer: not to helpers, not in
  scheduled runs. Gate kind `ask_owner`, allowed by default.
- **Skipped calls.** Each call a scheduled task skipped for want of
  approval is one item per task and call (a repeat counts up, also after
  you dismiss it), posted once, without a sound. "Allow for this task"
  adds a grant for that call and that task alone, for 30 days: its next
  run makes the call; other tasks and the chat still can't. It is not
  offered for money, a post others read, a command skipped because the
  agent wrote files, or a task whose name has a space, `:`, `/` or `*`.
- **Deliveries.** A post that does not get through (a reply, a `send`, a
  brief, a task's answer) is kept and sent again after 5 minutes, then 10,
  20 … 2 hours, also after a restart; meanwhile its brief or task does not
  run again, and a brief is sent as written, not collected again. Its
  files and quick replies are not kept. One that can't be sent for another
  reason (no account paired yet) is posted with Send again and Drop.
- **Terminal.** Items print the same way, with their keys: `o`, `d` and
  `n` for an approval, `1` to `4` for other choices, with the item's
  number when several take the key (`o 41`).

`harness inbox` lists the open items; `harness inbox --json` prints every
item kept (open, and closed in the last 7 days, at most 500), a JSON
object a line, as apps will get them (format v1):

```json
{"v":1,"id":41,"kind":"approval","status":"open","created":"2026-11-22T14:02:11Z","expires":"2026-11-22T14:12:11Z","by":"owner","agent":"main","rid":18234,"run":"chat","conversation":"research","waiter":"run","app":null,"title":"shell: git push origin main","body":"shell: git push origin main","choices":[{"key":"once","label":"Allow once"},{"key":"day","label":"Allow 24 h"},{"key":"deny","label":"Deny"}],"text":"reason","draft":null,"count":1,"answer":null}
```

`status` is `open`, `answered`, `expired`, `void`, `withdrawn` or `done`
(a kept post went out); `answer` is `{"key","text","at","via"}` with `via`
`telegram`, `terminal` or `harness`. Texts are masked as in the log (a
stored secret shows as `[secret:NAME]`, in the message too); a private
conversation's item keeps its texts while open, then only their sizes and
keyed hashes (`{"bytes":N,"hmac":"…"}`). `state/inbox` is rewritten whole
before anyone acts on a change; its first line keeps the next number.
Harness 0.3's `state/approvals` gives the first number and is then
removed.

## Helpers

`delegate` hands up to 8 tasks to helpers that run at the same time:
research across several sources, comparisons, anything that splits into
parts. Each helper starts with a clean context, gets only the tools it was
given (never `delegate`, `remember`, `skill_save` or money tools), uses
`worker_model` unless the task asks for the strong one, and returns a short
answer, not its working. Limits per helper in `[agents]`: model calls,
input tokens and answer size; at most `parallel` run at once in the whole
instance. Helpers of one call share fetched pages, so none is downloaded
twice; their questions wait at once, each its own item (see Inbox), and
one that can't be answered before the turn ends is refused without
asking. `/stop` stops them too.

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
`skill_save` (asked, showing its name, description and body). `/skills`
lists them, `/skill rm NAME` removes one.

## The log

One JSON line per action: messages, model calls (tokens), gate decisions
with the reason, tool calls with their input and output (up to 2 KB each),
memory changes, briefs, tasks, settings changes, posts. Each line of a
run (a chat turn, a task, a brief, a helper's task) carries `rid`, the
run's id (the `seq` of its first line), `conversation`, where it reports
(a helper's is its parent's), and `run`, its label (`chat`, `task NAME`,
`brief NAME`, `chat/h1`). Its first line also names who started it,
`by` (`owner`, or `schedule:NAME` for a task or brief; a helper has its
parent's), its definition, `agent` (`main` or `helper`), and for a
helper `parent`, the rid of the run that delegated it; gate and tool
lines carry `agent` too, and tool lines the output's whole size, `bytes`.
A post is a line of kind `send`: `to`, `event` (`sent`, `refused`,
`held`, `kept`, `failed`), `bytes`, `text`, `files`, `buttons`, `final`,
`implicit`, `delivered`, the first message's id, the number of messages,
and the item a post that did not get through is kept as. Inbox items are
lines of kind `inbox`: `open` (`item`, `type`, `conversation`, `rid`,
`title`), `shown`, `answered` (`item`, `key`, `via`, the size of its
text), `expired`, `void`, `withdrawn`, `done`, `remind`; gate lines name
the item ("allowed once by the owner (item 41)"). A private run's lines, and a post into a private conversation,
keep sizes and keyed hashes of what was said, while their labels (`run`,
`conversation`, `by`, `agent`, `to`, `event`, `tool`, `decision`, `why`)
stay readable. Each line carries the
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
brief or task whose message does not get through is sent again as it was
written after 5 minutes, then 10, 20 … up to 2 hours; nothing is fetched,
written or run again for it, and it does not run again until it is
delivered or you drop it. It is kept in `state/inbox` (see Inbox), so a
restart does not lose it. `/brief` sends one now; `/topic add` and
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
gate (with `ask` as Deny). Its answer is posted to its `to` (`main` unless
it names another conversation) unless it is `NOTHING`; calls skipped for
want of approval are listed either way ("Skipped (needs approval): shell:
df -h (item 45)"), each an item you can allow for that task (see Inbox). A task whose omnigate budget is spent is
paused until `/task resume NAME`. `/tasks`,
`/task add NAME | every 15m | instruction`, `/task rm NAME`.

## Commands

`/stop`, `/new`, `/status`, `/brief [NAME]`, `/topics`, `/topic add|rm`, `/tasks`,
`/task add|rm|resume`, `/memory`, `/remember`, `/pin`, `/unpin`,
`/forget`, `/private on|off`, `/skills`, `/skill rm`, `/logins`,
`/dryrun on|off`, `/reload`, `/conversations`,
`/conversation new|rename|rm|add`, `/session [N]`, `/inbox`,
`/answer ID TEXT`, `/grants`, `/grant rm N`, `/help`. `/new` and
`/private` act on the conversation they are sent in; `/stop`, `/dryrun`
and `/memory auto` on everything.

CLI: `init`, `secret add|rm|list`, `login add|list|rm`, `pair`, `run`, `chat`, `brief [NAME]`,
`task run NAME`, `memory [list|pin|unpin|forget ID]`,
`log verify|tail|runs|session`, `inbox [--json]`,
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
- **One owner, one turn at a time.** Messages sent in any conversation
  while the agent works wait in one queue. Contexts do not survive a
  restart.
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
sandbox per command, email, WhatsApp, Slack and voice as conversations,
helpers that report back later,
cards and payments for the agent, the browser on Windows, screenshots,
and the hosted service.

## Build

```
zig build                     # zig-out/bin/harness
zig build test --summary all  # unit tests, then scripts/smoke.sh end to end
```

Zig 0.17.1.
