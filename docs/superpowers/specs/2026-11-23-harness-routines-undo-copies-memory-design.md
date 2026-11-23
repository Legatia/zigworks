# harness: remote MCP servers and morning routines, undo, try in a copy, long memory

2026-11-23. The owner read a list of fifteen "build this" agent features
(Suraj Sharma, 2026-11-22) and asked to build the four close to harness:

| The post | harness today | This spec adds |
|---|---|---|
| An agent that wakes every morning, reads Slack, triages Jira, drafts PRs | schedules, briefs, triggers (gap 6), workflows (gap 7); MCP servers started as local programs (stdio) | MCP servers over HTTP with a token or a sign-in; a ready-made morning routine, tested end to end |
| Snapshot before an agent writes; one-click undo | each run snapshots the folders it changes, before and after (gap 3); `/changes`, `/restore` | an Undo button on the run's message that takes back that run's changes, file by file |
| The coding agent runs its tests in isolated machines before touching the main branch | sandboxes and remotes (gap 2), copy-on-write clones | `workspace = copy`: a run works in its own copy; its changes come back to be applied or dropped, after an optional check |
| Long memory compacted into a small window without losing the needle | memory items, `recall`, one rolling summary per conversation | `history`: search every past turn; summaries by day, week and month in the prompt |

The overview (`2026-11-22-harness-platform-overview.md`) binds: the gate
decides, the owner approves, plain files, std only, secrets only through
`harness secret add` or a sign-in, plain labels.

## Part 1. Remote MCP servers and the morning routine

### MCP over HTTP

The services' own MCP servers (GitHub, Slack, Atlassian, Linear, Notion)
are reached over HTTP. A section of `mcp.ini` takes `url` instead of
`command`:

```ini
[github]
url = https://api.githubcopilot.com/mcp/
token = github                 ; a stored secret, sent as Authorization: Bearer
header = X-MCP-Toolsets: issues,pull_requests   ; repeatable

[atlassian]
url = https://mcp.atlassian.com/v1/mcp
login = oauth                  ; sign in once: harness mcp login atlassian
```

- `command` and `url` exclude each other; `token` and `login = oauth`
  exclude each other; `url` is https, or http to a loopback address. A
  `header` may not set Authorization, Host, Content-*, Mcp-* or
  MCP-Protocol-Version. The money keys apply as to other servers.
- Streamable HTTP (MCP 2025-06-18, and 2025-03-26 when the server answers
  with it): each message a POST with `Accept: application/json,
  text/event-stream`; the answer is JSON or an event stream carrying the
  answer (server requests in it are answered as stdio's are: not
  supported); `Mcp-Session-Id` kept from `initialize`; a 404 with a session
  means it ended: initialize again once and resend (a 404 call did not
  run). Resource updates: a GET event stream when the server offers
  subscriptions, kept open and reopened with backoff; otherwise triggers
  read resources every `every`, as now. The session is deleted on stop.
- Errors, as for model providers: 401 → one refresh for a sign-in, then
  "atlassian refused the sign-in: harness mcp login atlassian" (a token:
  name the secret); 403 refused; 429 waits as told once within the turn's
  time; 5xx upstream. Redirects are not followed. Answers are masked like
  stdio output; tokens never reach a log line, a model request or output.
- The gate, rules, grants, money and logs treat these tools exactly as
  stdio servers' tools (`mcp SERVER/TOOL`).

### Signing in (OAuth)

`harness mcp login NAME` (terminal; with `harness run` going or not)
follows MCP's authorization spec: the server's 401 names its protected
resource metadata (RFC 9728) → the authorization server's metadata
(RFC 8414, or OpenID discovery) → dynamic client registration (RFC 7591)
unless `client_id =` is set → an authorization link with PKCE (S256), a
`state` and the `resource` (RFC 8707), redirected to
`http://127.0.0.1:PORT/callback` on a listener that takes one request for
5 minutes → the code exchanged for tokens. Tokens and the client are kept
in the store as secret `mcp-NAME` (never in a file), refreshed before they
expire and once after a 401. `scope =` overrides the metadata's scopes.
The link is printed, not opened; on a machine without a browser the owner
forwards the port (`ssh -L`), as the README says. `harness mcp logout
NAME` forgets the tokens; `harness mcp list` names each server, its kind
(program, token, sign-in), whether it is signed in, and its tools.

Not built: client-credential and device flows, signing in from chat.

### The morning routine

After workflows (gap 7) land: `harness/examples/morning/` with a README
(what to install, which tokens or sign-ins, the rules it needs), an
`mcp.ini` part, a `triggers.ini` part (a schedule at 07:30 Monday to
Friday starting workflow `morning`) and `workflows/morning.wf`: read
yesterday's mentions and new items (Slack, Jira, GitHub; tool steps), a
`do` step that triages them into a digest and suggested replies (answer
json), a `review` of the digest, `say` it, an `approve` of the replies, a
`do` step that posts them (needs `allow mcp SERVER/TOOL *` in
`[workflow:morning]`, as the README says). Tool names differ per server:
the README tells the owner to read them from `harness mcp list`. A smoke
check runs the routine against the fake MCP server playing all three and
ends with the replies posted.

## Part 2. Undo

A run that changed files in snapshotted folders ends its message (the chat
reply, or the post of a task, trigger or workflow step) with "Changed 3
files in notes/ and site/." and an **Undo** button (data
`u<run>-<16 hex of an HMAC of the run number with the log's key>`; no
state kept for it). The terminal prints `/undo 41` instead.

Undo takes back that run's changes file by file, from its "before" and
"after" snapshots (helpers' changes are the run's): a file as the run left
it gets its old content back (removed if the run made it, made again if
the run removed it); a file changed since is left and listed ("notes/a.md
changed since; left as it is"). A database's `-wal`, `-shm` and
`-journal` files go with it, and are left with it. Before it writes, undo
snapshots each folder (by the owner), so `/restore` can take the undo
back. Refused while a run is going, and when the run's snapshots are gone
("too old to undo: its snapshots were pruned").

`/undo` (the newest run with changes in this conversation), `/undo RUN`,
`harness undo RUN`. Only the owner's press counts (in a group too, as
approvals). Log kind `files`, event `undo` (run, folders, undone, left).
Databases reached through MCP servers or the network are not covered (the
README says so).

## Part 3. Try in a copy (environments, gap 2)

Built by the Windows session with runs picking an environment; the Mac
session adds and tests the macOS branch.

`workspace = copy` in a sandbox section of `environments.ini`: each run in
that environment gets its own copy of the workspace in
`state/env/NAME/copies/RUN/`, cloned copy-on-write where the file system
can and copied otherwise; `copy_mb = 2048` caps it (larger: the run is
refused before it starts); folders.ini's `skip` applies; `.git` is copied.
The sandbox sees the copy (Linux: at the workspace's own path; macOS and
Windows: at the copy's path, which the run's tools and `dir` use), and the
run's file tools act on it.

At the run's end, the files that differ from the workspace as it was when
copied are its changes. None: the copy goes. Otherwise an inbox item, kind
`copy`: "Run 41 (box) changed 4 files in its copy", the list and sizes,
Show (a diff, 2 KB per file), Apply, Drop. `check = COMMAND` runs in the
copy, in the sandbox, after the run, within the run's time; its exit code
and last 20 lines go in the item. `apply = ask | check` (default ask):
`check` applies at once when the check passes, and asks otherwise.

Apply snapshots the workspace folders first (so Part 2's Undo is on the
"Applied" message), then writes each changed file whose workspace file is
still as it was when copied; one changed since is left and listed, and the
copy is kept 7 days (its path shown); otherwise the copy goes. The run
never writes the workspace itself. Each run has its own copy, so several
can work at once (definitions' `parallel` places). Log kind `env`: `copy`
(run, files, mb, cloned|copied), `check` (exit), `applied`, `dropped`.

## Part 4. Long memory

**Search everything.** A `history` tool, `{"words", "conversation"?,
"before"?, "run"?}`: up to 20 matching turns, newest first — the owner's
messages, the agent's replies, the first 2 KB of tool results — each with
its date, conversation and run; with `run`, that run's session view (16
KB). Every word must be in the turn (case does not matter) or the quoted
phrase. It reads the log, which keeps every turn (masked); private
conversations keep no words in the log, so they are never found. Who sees
what: a run in one of the owner's own conversations (main, the terminal,
the owner's topics) searches every conversation; a run in a shared
conversation searches only that one; schedule, trigger and workflow runs
search their `to` conversation. `/history WORDS`, `harness log search WORDS`. A
read tool: allowed unless a rule says otherwise.

**Summaries by day, week and month.** Once a day (03:00 owner's time, or
the first tick after), the memory model summarizes each conversation's
previous day from the log (up to 200 KB of its text; at most 150 words)
into `state/summaries/CONV/day/YYYY-MM-DD.md`; on Mondays the week's days
fold into `week/YYYY-Www.md` (150 words); on the 1st the month's weeks
into `month/YYYY-MM.md` (200 words). Kept: days 60, weeks 400 days,
months always. Not for private conversations.

**The prompt.** After pinned memory and before the rolling summary:
"Earlier in this conversation:" the three latest day summaries, the two
latest weeks not covered by them, the three latest months — at most 1,500
words — and one line saying `history` finds anything older or exact.
Shared conversations get only their own.

`[memory] summaries = on|off` (default on), `summary_model` (default the
memory model). Log kind `memory`, event `summary` (conversation, period,
words, tokens). Not built: embeddings or a vector index, a trigram index
of the log (later, trigrep's).

## Tests

- Part 1: `http_mcp_tools_list_and_call_through_the_gate` (fake HTTP MCP:
  JSON and event-stream answers), `a_session_that_ended_is_started_again`,
  `token_and_headers_are_sent_and_never_logged`,
  `bad_mcp_ini_sections_name_their_line` (command and url; token and login;
  http to a non-loopback host; a forbidden header),
  `oauth_login_registers_exchanges_and_refreshes` (fake authorization
  server: metadata, registration, PKCE checked, state checked, refresh on
  expiry and after a 401), `the_login_listener_takes_one_request_and_ends`,
  `resource_updates_arrive_over_the_event_stream`; smoke: the morning
  routine against the fake MCP server.
- Part 2: `undo_takes_back_only_that_runs_changes`,
  `a_file_changed_since_is_left_and_listed`,
  `a_database_goes_with_its_wal_and_shm`, `undo_can_be_restored`,
  `undo_is_refused_while_a_run_goes_and_when_too_old`,
  `the_undo_button_needs_the_right_hmac_and_the_owner`.
- Part 3: `a_runs_writes_stay_in_its_copy`, `copy_is_a_clone_where_it_can_be`,
  `apply_writes_only_files_unchanged_since`,
  `apply_check_applies_when_the_check_passes`, `two_runs_two_copies`,
  `copy_mb_refuses_before_the_run`, `drop_removes_the_copy`.
- Part 4: `history_finds_old_turns_by_words_and_phrase`,
  `history_keeps_to_what_the_run_may_see`,
  `days_fold_into_weeks_and_months` (fake clock, fake model),
  `the_prompt_carries_the_latest_summaries_within_1500_words`,
  `summaries_off_makes_no_calls`, `history_run_returns_its_session`.

## Calls I made (the owner can change them)

- OAuth sign-in only from the terminal (the redirect must reach the
  harness machine); tokens live in the secret store.
- Undo works file by file and never overwrites a file changed since;
  no inbox item per run (the button is checked by an HMAC instead).
- Try in a copy asks before applying by default; applying on a passing
  check is opt-in per environment.
- History searches the log (every turn is already there, masked); no
  index until the log is large enough to need one.
- Summaries cost one small model call per active conversation per day
  (plus weekly and monthly); on by default, `summaries = off` stops them.

## Order

Part 1's HTTP and sign-in now (mcp.zig, new files); Part 4 next; Part 2
after the workflows merge (it changes the end of a run); the routine after
workflows; Part 3 with the Windows session's next batch.
