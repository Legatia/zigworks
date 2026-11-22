# harness apps (gap 8)

Gap 8 of `2026-11-22-harness-platform-overview.md` (binding); Windows
session, phase C (the server first, before phase 0; reads, acts and runs
after it). From the sibling specs it uses `by` (`app:NAME`, the
overview's Shared formats) and named conversations (conversations spec);
item format v1, the answer function and `who` on grants (inbox spec);
`folders.ini` (file roles).

**Intent.** The post: apps the agent builds are files the owner keeps,
changes and forks, some ship like an OS's, shown in several containers; the
platform is their OS. Here: an app is a folder of web files harness serves
to the owner's browser; it reads what harness exposes and asks it to act.

## Goals

1. `apps/NAME/`: `app.ini` and web files, plain files; every version kept.
2. Served by harness (std's HTTP server, 127.0.0.1), entered by a link with
   a token made at each start.
3. Reads only what its manifest lists; acts only through harness (gate,
   log, the owner's answer); sends data nowhere else; no secrets, no money.
4. Built by the agent in the workspace, installed with one question.
5. Built-ins (inbox, log, files) ship in the binary; any app forkable.

## Non-goals (phase C)

Chat beside an app, canvases, panels (need a browser conversation, gap 4,
or the hosted client; the shell leaves room). Phone links, a Telegram Mini
App (need https: hosted). Apps that work with no browser open (triggers,
workflows). As acts: money tools, `web`, logins, `delegate`, `remember`,
`skill_save`, `ask_owner`, setup tools (`app_save` and the others, the
overview's Shared formats). Settings edited from a page. Outside hosts
for scripts, styles, images or fonts (see Calls).

## What the owner does

```
harness run
Apps: http://127.0.0.1:53418/s/Qm9fT2xk3vYp0aLwZr8eHg/   (new each start)

harness app list               # name, version, built in, reads, acts, state
harness app fork log my-log    # a copy to change in apps/my-log (not its data)
harness app versions my-log    # then: app revert my-log 2 (a new version)
harness app approve my-log     # serve again after a change outside harness
harness app rm my-log          # folder, data, versions
```

`harness chat` prints the line too. Chat: `/apps` (with links), `/app
approve NAME`, `/app rm NAME`. config.ini `[apps]`: `on = on`, `port = 0`
(a free port each start), `act_seconds = 120`, `runs_per_hour = 20` (per
app). No browser on that machine: a fixed `port` and `ssh -L`.

## Data

`apps/NAME/` holds `app.ini` and the current files; `apps/NAME/data/` the
app's data (api/data), never served or versioned. `state/apps/NAME/approved`:
version, SHA-256 of app.ini and files, when, by. `state/apps/NAME/versions/N/`:
the last 10 earlier versions. `state/apps/pending/ID/`: a save being asked.

```ini
[app]
name = reading-list      ; = folder: a-z, 0-9, -, up to 32
title = Reading list
description = Links I saved, with notes; marks the ones I read.
version = 3              ; written by harness, as is forked_from
reads = files            ; any of memory, inbox, log, files
files = reading/*        ; workspace paths it may read and act on (file rules)
acts = write_file, fetch, run:main   ; tools, SERVER/TOOL, run:DEFINITION
to = main                ; where its questions and runs report (gap 4)
```

Entry `index.html`; 200 files, 4 MiB, 1 MiB each; parts `[A-Za-z0-9._-]`,
not starting with `.`; no symlinks; html js mjs css json svg png jpg gif
webp ico woff2 txt md. Reserved: inbox, log, files, api, home, review,
pending (`state/apps/pending/` holds saves being asked). Data: 1000 keys
of 256 KiB.

## Serving

`run` and `chat` start it: `sock.Listener` on 127.0.0.1, a thread per
connection (32 at most), `std.http.Server` over `sock.Socket` (head 16 KiB,
body 1 MiB, idle 30 s), as in `fake.zig`. The port is harness's alone: no
SO_REUSEPORT; on Windows SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR (which there
lets another program bind the same port).

Tokens: per start a 32-byte key (`randomSecure`, memory only); the shell
token 16 random bytes, an app's HMAC-SHA256(key, NAME and version) cut to
16; base64url, compared in constant time. An old link gets "This link is
from an earlier start of harness. Ask for the app again."

Paths: `/s/SHELL/` (home), `/s/SHELL/NAME?view=V`, `/s/SHELL/review/ID`,
`/s/SHELL/api/...` (the shell's calls), `/a/APP/...` (files; API under
`api/`); else 404, one body. `Host` must be `127.0.0.1:PORT` (no DNS
rebinding); `Origin` absent or `http://127.0.0.1:PORT`, on `/a/` also
`null`; else 403. App HTML only with `Sec-Fetch-Dest: iframe` (a page in a
tab of its own could navigate itself anywhere).

**The shell** (harness's page, in the binary) shows the app in `<iframe
sandbox="allow-scripts allow-forms" referrerpolicy="no-referrer" allow="">`
from `/a/APP/?in=page&view=V`. Without `allow-same-origin` the frame's
origin is opaque: no reach into the shell, other apps, cookies or storage;
its `api/` calls are cross-origin, answered (preflights too) with
`Access-Control-Allow-Origin: null` on its own token paths only. A bar above
it shows every open inbox item at once, oldest first as `/inbox` lists
them, each with its choices (and a text box where the item takes text),
and answers each through the inbox's answer function `(id, key, text)`,
`via` `bar`, as the terminal does: once, the first answer wins,
Telegram's buttons are edited. The bar is reached only with the shell
token; the items' own tokens stay with Telegram's buttons. Apps can't
press them; the bar ignores clicks in its first 0.5 s and shows titles
as text.

Every response: `Referrer-Policy: no-referrer`, `X-Content-Type-Options:
nosniff`, `Cache-Control: no-store`. Shell: COOP and CORP same-origin, CSP
`default-src O; frame-ancestors 'none'; base-uri 'none'`. App (O =
`http://127.0.0.1:PORT`):

```
default-src 'none'; script-src O; style-src O 'unsafe-inline';
img-src O data: blob:; font-src O; media-src O blob:; connect-src O;
form-action 'none'; frame-src 'none'; worker-src 'none'; object-src 'none';
base-uri 'none'; frame-ancestors O; sandbox allow-scripts allow-forms
```

No inline script or eval (a `<script>` in a log line can't run in the
viewer); the shell's `default-src O` (so `frame-src O`) keeps the frame
from navigating away; the sandbox stops popups and top-level navigation;
`connect-src` never widens.

## The API

Relative to the app (`fetch('api/inbox')`); JSON, masked like tool output,
errors `{"error": "..."}`.

- `GET api/info`: name, version, manifest, container (`in`).
- `GET api/memory` (id, level, pinned, created, body),
  `api/inbox?state=open|all` (format v1, inbox spec),
  `api/log?after=SEQ&limit=N&wait=S` (`wait` up to 25 s), `api/log/runs`
  and `api/log/session/RID` (as `harness log runs` and `log session
  --json`, conversations spec), `api/log/verify`, `api/files?path=P`
  (entries, text up to 1 MiB, images): each needs its `reads`, files P in
  `files` too.
- `GET`, `PUT`, `DELETE api/data/KEY`, `GET api/data`: its own data.
- `POST api/act {"tool","input"}`, `GET api/act/ID?wait=S`: state `done`,
  `asked` or `refused`, and the output.
- `POST api/run {"agent","text"}`, `GET api/run/ID?wait=S`: the answer.

**Reads**: unlisted, refused before the gate; listed, the gate as kind
`app_read`, argument `NAME memory|inbox|log` (default allow; `deny app_read
* log` stops all apps), or `read_file` PATH (file rules). Logged once per
page load and subject, and every refusal; per poll, the log viewer would
fill the log.

**Acts**: tool in `acts`, path in `files`, then the agent's own path
(`decideAndAsk`, same tool code) with `by` = `app:NAME`: same rules and
defaults, questions prefixed `[app:NAME]` in its `to` conversation,
"Allow 24 h" kept with `who` = `app:NAME` in `state/grants` (inbox spec):
that app only. Writes go into `state/written`. 2 at once per app, 4 in
all, `act_seconds`; `/stop` ends them. `run:main` starts a run of the main
agent (a named definition after gap 1), labelled `app NAME` with `by`
`app:NAME`; its calls may ask (the overview's rule 3); its answer goes to
the app, not a conversation. One run per app at a time, `runs_per_hour`,
counted in `concurrent_runs`.

## How the agent builds an app

`app_draft {"name","as"}` copies app NAME to `app-drafts/AS/` in the
workspace (allowed by default); the agent edits it with `write_file`.
`app_save {"name","from"}` checks that folder, copies it to
`state/apps/pending/ID/` (what is shown is what is installed) and asks:
kind `app_save`, argument NAME, a setup call (the overview's Shared
formats): asked every time (no 24 h button, no `allow` rule lifts it,
`deny` applies), offered only in runs the owner started from a
conversation. It shows
`[app_save] NAME v4 (was v3)`, app.ini in full, each file's size, SHA-256
and new/changed/same/removed, changes to reads, files and acts, and
`{app-review:ID}`, sent as the link to the review page (every file in full,
the same buttons, the draft running with no reads or acts). On Allow it is
installed by renames, `approved` written before the swap (a crash leaves one
version whole; the next start finishes), the old one moved to `versions/`;
on Deny or no answer the copy is removed. The tool's answer names inline
scripts and `on...=` handlers, which won't run.

The agent writes `{app:NAME}` or `{app:NAME/VIEW}` in an answer or `send`;
harness puts in the link when sending, so no token reaches the log or the
model. The model sees app names, titles and descriptions. An item made by
`ask_owner` with `app` (inbox spec) carries `{app:NAME/item-ID}`: the app
shows the draft from `api/inbox`, and the bar or Telegram answers it.

Approved shell commands run as the owner and can rewrite `apps/`, so at
start, on `/reload` and before serving app HTML, files are compared with
`approved`; an app that differs isn't served ("changed outside harness", a
log line) until `/app approve NAME` makes it a new version. Hand edits too.

## Built-in apps

From the binary (`harness/apps/NAME/`, `@embedFile`), changing with harness;
read-only, fork to change. Not built in: memory (`/memory` covers it; a good
first app to ask for), settings (files and `/reload`), chat (gap 4).

- **inbox** (reads inbox): what waits for the owner, by kind and starter,
  with history, where Telegram has a stream. Answers go through the bar:
  an app that answered could approve itself.
- **log** (reads log): the session view, today `harness log runs` and `log
  session` in a terminal; runs with their steps, lines live, filters by
  run, started by, kind, tool and decision; `log verify`.
- **files** (`files = *`): where the agent's work lands; folders, text with
  line numbers, images.

## Log and other gaps

Kind `app`: `server started` (port, no token), `opened` (name, version,
reads), `read`, `saved` (name, version, sha256, files, by, agent, item),
`changed outside harness`, `approved`, `reverted`, `forked`, `removed`,
`refused` (host, origin, token, frame; one per reason per minute). Acts
and runs write the usual gate and tool lines with `by` = `app:NAME`.

Conversations (4): links as `{app:...}`; the manifest's `to` names the
conversation. Inbox (5): apps read format v1, never answer; app questions
are items with `by` `app:NAME`; the bar answers via `(id, key, text)`.
Roles (3): a file call passes both the manifest's `files` and
`folders.ini` for `app:NAME`. Environments (2): shell acts run where an
`app:NAME` or `app` pin says. Definitions (1): `run:NAME`. Triggers (6):
webhooks later on this server (`POST /hooks/NAME`, outside the token
paths, triggers spec).

## Platform notes

- **Windows**: listener and HTTP server run there already (test
  stand-ins); add the exclusive bind; check loopback raises no firewall
  prompt. Everywhere refuse `\`, `:` (`index.html::$DATA`), parts ending in
  `.` or space, device names (`con`, `nul`, `com1`), and at save names
  differing only in case. Map URL paths to files, never pass them through.
- **macOS**: Safari 16.4+ has sandboxed frames and `Sec-Fetch-Dest`. Browser
  tests drive headless Chrome via `cdp.zig` (Windows: after the web handoff).

Limits (README): links work only on the machine running harness; whoever
has one and reaches its 127.0.0.1 can open apps until the restart, and
Telegram sees the links it carries; CSP doesn't cover WebRTC or DNS
prefetch, so an app could leak data it reads that way; browser storage
lasts one start.

## Hosted version

An https address per instance; the owner signs in (passkey or Telegram
login) for a session cookie instead of a token in the link. Each app its
own origin (`APP--INSTANCE` under a separate apps domain); frame and CSP
stay. Telegram Mini App: the menu button opens the shell, `{app:NAME}`
becomes a `web_app` button (the app opens in the chat), `initData` checked
with the bot token's HMAC and the owner's id. The instance's front end
(beside omnigate) ends TLS and forwards to the app server on 127.0.0.1.

## Tests

- `app_ini_refuses_bad_manifests` (keys, names, acts, a `hosts` line,
  sizes; names the line); `app_server_binds_loopback_alone` (a second
  bind fails).
- `app_requests_need_host_token_origin`: Host `localhost:P` 403; old or
  unknown token 404, one body; Origin `http://evil.test` 403; `null` only
  on `/a/`. `app_tokens_change_each_start_and_version`.
- `app_html_only_into_a_frame`; `app_responses_carry_csp_and_headers`;
  `app_paths_refuse_tricks` (`..`, `%2e%2e`, `data/x`, `a::$DATA`,
  `con.txt`, trailing dot, symlink: 404).
- `app_reads_follow_the_manifest`: unlisted 403, no gate line; `deny
  app_read * log` 403 with one; 50 polls, one `read` line.
  `app_answers_are_masked`: memory, file and log line with a secret.
- `app_act_passes_the_gate_as_the_app`: `by` `app:NAME`, `[app:NAME]` in
  the question; Allow once done, Deny refused; not in `acts`: unasked.
  `app_grants_cover_one_app_only`; `app_run_within_limits` (second: 429);
  `bar_answers_an_item_once` (`via` `bar`, Telegram's buttons edited, a
  later press "already answered"; no app path reaches the answer call);
  `bar_shows_every_open_item` (three items, answered out of order).
- `app_save_installs_what_was_shown` (draft changed after the call: the
  snapshot is installed; hashes asked; no token logged);
  `app_save_asked_every_time` (no 24 h, allow rule ignored, scheduled
  refused); `app_changed_outside_not_served_until_approved`.
- `app_versions_fork_revert`; `builtin_apps_from_the_binary`;
  `app_placeholder_filled_only_when_sent`; `stop_ends_app_acts_and_runs`;
  `app_server_stops_within_2s` (all OSes, keep-alive connections open).
- Headless Chrome: `app_frame_cannot_get_out` (fetch to another port,
  `location =`, `window.open`, `parent.document`, `localStorage`, inline
  script: the stand-in sees nothing, the script doesn't run);
  `builtin_apps_show_their_data`.

## Calls I made

- One origin per start, apps kept apart by sandboxed opaque-origin frames
  in harness's shell; not a port per app (cookies span ports), not
  `NAME.localhost` (Safari). So `Origin: null` passes on an app's own token
  paths: the one exception to "no other origin".
- Token in the path, not a cookie or query: relative URLs carry it.
- Only the owner answers questions (Telegram, terminal, the bar).
- `app_save` asked every time, like money. The question carries the
  manifest (what the gate enforces) and every file's hash; full text behind
  the review link, as questions stop at 12 KB.
- Drafts in the workspace; built-ins from the binary; reads logged once.

Changed to fit the overview's Shared formats:

- `by` and grants' `who` are `app:NAME` (was `app NAME`); the manifest's
  conversation key is `to` (was `conversation`), as in every other file;
  an MCP act is `SERVER/TOOL` (was `mcp:SERVER/TOOL`).
- `app_save` is a setup call: offered only in runs the owner started from
  a conversation; no setup tool or `ask_owner` is an act.
- The bar shows every open item and answers each by id, as the inbox
  fixes it; `pending` is a reserved name, since saves being asked live
  in `state/apps/pending/`.

Settled (were questions for the owner):

- Inbox, log and files stay the built-ins (was question 2); a memory
  viewer is a good first app to ask the agent for.
- No outside hosts (was question 3; `hosts =` is gone, a manifest that
  has it is refused): a script, style, image or font from another host
  could carry what the app reads to that host, against goal 3 ("sends
  data nowhere else"). Libraries are copied into the app; 4 MiB holds
  them.

## Questions for the owner

Question 1 (app links on your phone before the hosted address) is
question 4 of the overview's "Questions for the owner"; the others are
settled above.
