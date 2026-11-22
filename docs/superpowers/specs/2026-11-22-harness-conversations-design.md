# harness: conversations (gap 4)

2026-11-22. Gap 4 of `2026-11-22-harness-platform-overview.md` (binding).
Built first by the Mac session in phase A, after phase 0: the inbox (gap
5) and triggers (gap 6) use the conversation a run reports to and the
`by` field described here (its form is fixed in the overview's Shared
formats; phase 0 builds it). One binary, one gate, one log, one owner
stay.

## Intent

John Suh's post: what a person deals with should be a conversation (a
Slack channel, an iMessage or WhatsApp chat, an email thread) where the
agent posts through a tool call, not the assistant's own messages; direct
access to the session is for inspecting and debugging. Harness posts each
turn's last text, after a limit its working text, to its one chat. Here
conversations become named places, `send` the way in, the log the session.

## Goals

1. Conversations: the private Telegram chat (`main`), its topics (one per
   subject, each with its own context), the terminal; email threads later.
2. `send`: text, workspace files and quick replies to a conversation.
3. Every run logs its id, label, `by` and conversation;
   `/session` and `harness log session` show its steps.
4. Nothing breaks: a turn that does not end with `send` still gets its
   answer posted; tasks and briefs post where they did.

## Non-goals (this build)

- Email, WhatsApp, Slack, iMessage, Signal; talking with the agent where
  others read (groups are post-only).
- Two conversations' turns at once: one queue, one chat turn at a time, as
  today (one per conversation can follow once the inbox lets several
  questions wait; gap 1 does it, with a mailbox per conversation and
  definition). Contexts surviving a restart. Streaming. Voice.

## What the owner does

A topic the owner opens in the chat with the bot is a conversation from its
first message, named after it ("House search" is `house-search`). Topics
need Telegram's topics in private chats switched on for the bot in
@BotFather (Bot API 9.3); without them all posts go to the one chat with
`[NAME]` in front, as `harness chat` prints them.

```
/conversations                 name, where, private, last used
/conversation new NAME         open topic NAME in your chat with the bot
/conversation rename OLD NEW   (not main or terminal)
/conversation rm NAME          harness forgets it; the topic stays
/conversation add NAME         sent in a group: the agent may post there
/session [N]                   the steps behind the last answer here (N runs back, up to 20)
/new, /private on|off          for this conversation only
```

`tasks.ini`, `briefs.ini`: `to = NAME` (default `main`; a name that is no
conversation yet opens that topic at its first post). `config.ini`
`[limits]`: `sends_per_run = 10`, `sends_per_hour = 60` (per conversation).
CLI: `harness log runs [N]`, `harness log session RID [--json]`.

## Design

### Conversations

`state/conversations`, one JSON object per line, written whole (temporary
file, then rename) before harness acts on a change:

```json
{"name":"main","channel":"telegram","chat":123456789,"thread":0,"audience":"own","private":false,"created":"2026-11-22T09:00:00Z"}
{"name":"house-search","channel":"telegram","chat":123456789,"thread":5012,"audience":"own","private":true,"created":"2026-11-22T09:30:00Z"}
{"name":"family","channel":"telegram","chat":-1001234567890,"thread":0,"audience":"shared","private":false,"created":"2026-11-22T10:00:00Z"}
```

- Names: a-z, 0-9, `-`, `_`, up to 32; from a topic's name: lower case,
  spaces to `-`, other characters dropped, `-2` on a clash, `topic-THREAD`
  if nothing is left. `audience`: `own` (only the owner reads it: the
  private chat, its topics, `terminal`) or `shared` (others do: a group).
- Routing in, by chat and thread: the private chat without a thread (or
  its general topic) is `main`; a topic of it is that topic's
  conversation, made at its first message (named from the replied-to
  `forum_topic_created`); in a group only the owner's `/conversation add
  NAME` is read. Anything else is dropped and logged, as a stranger's is.
- Telegram: updates carry `message_thread_id` and the chat's type; `getMe`
  at start gives the bot's username (a command may end in `@BOTNAME`) and
  whether topics are on; sends add `message_thread_id`; new `sendDocument`
  (multipart in http.zig) and `createForumTopic`. A topic Telegram refuses:
  posts go to `main` with `[NAME]` in front; the owner is told once why.
- Each own conversation has its own context (today's one `conv`), `/new`,
  private flag and quiet-time memory writer (its own `memory_upto`), which
  with summaries reads a `send`'s text as the agent's words. At most 16
  contexts are kept: for a 17th, the least recently used is dropped after
  the writer has read it, and the model is told turns were dropped.
  `harness chat`, `brief` and `task run` print every post, with `[NAME]`
  in front when it is for another conversation.
- Pairing another account moves `main` to its chat and drops the old
  account's topics, saying which. Upgrade: harness writes `terminal`, and
  `main` once an owner is paired; `private on` in `state/switches` becomes
  `main`'s.

### Runs

A run's first log line carries these (and `agent`, its definition, gap
1); every later line `rid` and `conversation`:

- `rid`: that line's `seq` (`log.write` returns it); helpers have their
  own and carry `parent`. `run`: the label as today (`chat`, `task NAME`).
- `by`, who started it, one token as the overview's Shared formats fix it,
  `KIND` or `KIND:NAME` (gaps 1, 2 and 3 match it with patterns):
  `owner` (a message, button or command), `schedule:NAME` (a task or
  brief), `trigger:NAME`, `workflow:NAME/STEP`, `app:NAME`. Helpers (gap
  1's delegated runs) carry their parent's `by`; which definition runs is
  in `agent`, so `agent:NAME` names definitions and is never a `by`.
- `conversation`: a chat turn's is where its message came from, a task's
  or brief's its `to`, a helper's its parent's; triggers, workflows and
  apps name theirs in their own files.

The model learns its conversation and the others' names in the per-turn
context block, not the cached instructions, so the prompt cache holds:
"Conversation: house-search (Telegram topic). Others: main, trading."

### `send`

```json
{"to":"house-search","text":"Three flats match: …","files":["flats.csv"],"buttons":["Book viewings","Not now"],"final":true}
```

- `to`: a conversation's name, default the run's; an unknown name is
  refused, naming the known ones (only the owner and settings make
  conversations). `text`: up to 16 KB, sent in 4096-byte parts as today.
- `files`: up to 4 workspace files of up to 20 MB, sent as documents,
  confined as for `read_file`; a path with a part starting with "." is
  asked, as `write_file` is; a file holding a stored secret is refused.
- `buttons`: up to 4 quick replies of up to 32 bytes, own conversations
  only. A press posts the label as the owner's message there (a new turn
  whose context names the post) and clears them. Data
  `r<post>-<token>:<n>`, counted once, only from their own message; the
  token is new each start, so one from before a restart answers nothing.
- `final: true`: the reply. Once posted (or kept to be sent again, gap
  5), the turn ends without another model call: calls after it in the same
  reply are not run, the tool's result (`posted to house-search (2
  messages, 1 file)`) is the turn's last message, and the next turn's
  message joins it in one user message. Refused, the turn goes on and the
  model is told why.
- Helpers don't get `send`: their answer goes to the run that started them.

A turn's reply is its `send` with `final`, else the model's last text when
it stops on its own, posted by harness through the same path
(`"implicit":true` in the log), so nothing breaks while the agent learns
`send`. A `send` without `final` is a note and never takes the reply's
place. A turn ended by a limit or an error posts harness's line for it
("Step limit reached for this turn."), never working text (today that
text reaches the owner and hides the reason); a stopped one posts nothing.
The instructions: "The owner sees only what you post with send. Reply with
send and final: true; send without final for a note while you keep
working. Your other text goes to the log." The fallback is not mentioned.

Tasks get `send`; a task's reply goes to its `to` unless it is NOTHING,
with "Skipped (needs approval): …" added as today. A brief posts what it
wrote the same way. A post of a run the owner did not start has the name
of what started it in front (`[btc-watch]`).

The gate: new kind `send`, argument the conversation's name. `own`:
allowed by default. `shared`: asked every time with the whole post and the
files' names, no "Allow 24 h" (others read it; it can't be taken back); an
`allow send NAME` rule lifts that, `deny` stops it, a scheduled run is
refused as with every ask. The implicit reply passes the gate too: after
`deny send main`, harness says in main that a rule stopped it.

### What the owner sees, what the log keeps

| In a conversation | In the log |
|---|---|
| posts and replies; harness's lines (command replies, Queued, Stopped, errors); questions (gap 5); memory notices | all of that, and the owner's message, every model call, every tool call with input and output (2 KB each), gate decisions, working text, helpers' work |

Command replies go where the command came from, instance lines (settings
changed, the log warning at start) to `main`, memory notices to the run's
conversation. New log kind `send`: `rid`, `conversation`, `to`, `bytes`,
`text`, `files`, `buttons`, `final`, `implicit`, `delivered`, message ids.
Private lines keep `run`, `conversation`, `by`, `agent`, `to`, `event`
readable (as `tool`, `decision`, `why` today) so the session view works;
texts stay hashed.

### Private mode and rate limits

`/private on|off` applies to the conversation it is sent in. A run is
private when its conversation is, at its start or from when it is switched
on (as today); a `send` line is private when its run or its target is.

- `sends_per_run` (10): the 11th `send` is refused and the model told.
- `sends_per_hour` (60) per conversation, all runs and replies counted:
  past it posts are logged, not sent, and `main` hears once an hour:
  "Posts to trading are over 60 an hour: 12 not sent. /session shows them."
- Telegram's 429s are waited out as today (as told, up to 60 s, twice).

### The log as the session view

`/session [N]`: this conversation's last run (or N back): the owner's
message, each model call (tokens), each tool call (tool, argument cut to
80 bytes, gate decision and why, ok or error, output size), each helper in
a line, posts, how it ended; one message of up to 3,500 bytes, then
"harness log session 18234 shows all". It reads the log's last 4 MB.
`harness log runs [N]` (20): a line per run (rid, time, label, by,
conversation, steps, end). `harness log session RID [--json]`: the run and its helpers,
readable or raw; apps (gap 8) read the same through harness.

### Email threads (later): what they need

A mailbox of the agent's own: IMAP with IDLE, SMTP, std's TLS client, the
password in the key store like a login's (OAuth-only providers such as
Gmail need a token flow, so start with app passwords). A conversation per
thread by `Message-ID`, `In-Reply-To`, `References`; MIME (multipart,
base64, quoted-printable, UTF-8, Latin-1); HTML to text with page.zig.
Mail counts as the owner's only from the owner's address and when the
provider's `Authentication-Results` says DKIM or SPF passed (a `From` is
easy to forge); other mail is a trigger's source (gap 6). `own` when the
owner is the only other address in the thread, else `shared`.

### How it touches the other gaps

Inbox (5): questions go to the run's conversation; a post that does not
get through becomes an item; `ask_owner` blocks, quick replies don't.
Triggers (6), workflows (7): their runs post to the conversation their
file names (`to`); `sends_per_hour` keeps a busy trigger from flooding it.
Definitions (1): a conversation names its definition (`agent` in its line
of `state/conversations`, `/agent NAME`). Roles (3): match the who (`by`
and the definitions). Apps (8): opened by a link posted with `send`,
report to their `to`, read sessions in `harness log session --json`'s
format.
Environments (2): `files` come from the run's workspace as it sees it.

## Platform notes

The same on macOS, Linux and Windows: conversations are Telegram's and the
terminal's. `state/conversations` is replaced by a rename (on Windows over
the existing file). A file for `send` is read whole; 20 MB bounds it.

## Tests

core.zig (the Recorder notes each post's conversation and thread):

- `a_reply_goes_to_the_conversation_the_message_came_from` (topic 5012,
  not main); `a_new_topic_is_a_conversation_named_after_it_before_its_turn_starts`.
- `send_final_posts_once_and_ends_the_turn_without_another_model_call`;
  `a_turn_that_stops_without_send_posts_its_last_text_once` (logged
  `implicit`); `a_note_mid_turn_does_not_take_the_replys_place`;
  `working_text_is_never_posted` (text and a tool call, then the step
  limit: the owner gets the limit's line).
- `send_to_another_conversation_is_allowed_and_logged`;
  `send_to_an_unknown_conversation_names_the_known_ones`;
  `send_to_a_shared_conversation_asks_every_time_without_24h_and_is_denied_unattended`;
  `helpers_never_get_send`.
- `a_task_posts_to_its_conversation_with_its_name_in_front` (today's task
  and brief tests pass unchanged); `the_11th_send_of_a_run_is_refused`;
  `posts_over_the_hourly_limit_are_not_sent_and_main_is_told_once`.
- `private_is_per_conversation_and_covers_sends_into_it`;
  `new_resets_only_its_conversation`;
  `the_17th_context_drops_the_least_used_after_its_memories_are_written`.
- `an_attachment_outside_the_workspace_or_holding_a_stored_secret_is_refused`;
  `a_quick_reply_counts_once_and_not_after_a_restart`.
- `every_line_of_a_run_carries_its_rid_and_conversation`;
  `session_shows_the_last_run_here_and_only_labels_for_a_private_one`;
  `pairing_another_account_moves_main_and_drops_the_old_topics`.

telegram.zig: `updates_carry_the_topic_and_sends_go_to_it`,
`documents_are_sent_as_multipart`. log.zig:
`labels_stay_readable_in_private_lines`. main.zig:
`log_runs_and_log_session_read_runs_back`. smoke.sh: a message in a topic
is answered there, `/session` lists its tool call, a task with `to =`
posts to its topic.

## Calls I made (the owner can change them)

- The fallback stays: a turn that ends without a final `send` posts its
  last text through the send path; the model is told to use `send`.
- `final: true` ends the turn without another model call, so a reply
  through `send` costs what a text reply does. Helpers get no `send`.
- Topics in the owner's private chat with the bot. Groups are shared and
  post-only: asked every time, no 24 h; an `allow` rule lifts it.
- `/private` per conversation; `/stop`, `/dryrun`, `/memory auto` stay
  instance-wide. One chat turn at a time; at most 16 contexts in memory.
- Quick replies don't block; a run that must wait uses `ask_owner` (gap 5).
- Files: workspace only, documents, 20 MB, none holding a stored secret.
  10 sends a run, 60 an hour per conversation. Labels readable when private.

Changed to fit the overview's Shared formats:

- `by` is one token, `KIND:NAME` (was `KIND NAME`); a schedule is
  `schedule:NAME`. A helper keeps its parent's `by`, and its definition
  is the new `agent` field, so `agent NAME` is no longer a `by` value.
- A conversation names its definition (gap 1's call); a definition no
  longer names its conversation.

Settled (were questions for the owner):

- The fallback stays (was question 1): dropping it can lose a reply, and
  every implicit post is logged as such, so how often the agent skips
  `send` can be checked before anyone turns it off.
- Groups only as registered (was question 2): nothing is posted where
  others read unless the owner sends `/conversation add NAME` in that
  group, and every post there is asked; `/conversation rm NAME` ends it.

## Questions for the owner

Question 3 (email: an address of the agent's own, or your mailbox) is
question 1 of the overview's "Questions for the owner"; the others are
settled above.
