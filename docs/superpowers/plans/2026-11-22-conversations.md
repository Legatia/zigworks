# Conversations (gap 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans
> (inline, test-driven). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Conversations as named places (the private Telegram chat `main`,
its topics, groups the owner registers, the terminal), `send` as the way
in, every run's lines carrying its conversation, and the log as the
session view; nothing breaks for an agent that does not use `send` yet.

**Spec:** `docs/superpowers/specs/2026-11-22-harness-conversations-design.md`
under the binding overview
`docs/superpowers/specs/2026-11-22-harness-platform-overview.md`. Phase 0
is in (`gate.Ctx.shared`, `Decision.allow_day`, `Core.runAs`,
`Run.logRun`). Email is left out entirely (the owner's question 1).

**Architecture:** a new `conversations.zig` keeps `state/conversations`
(JSON lines, temporary file then rename). Core routes Telegram messages
in by chat and thread, keeps a context per own conversation (at most 16),
and posts to a `Place` (chat, thread) through a Channel that now takes
one. `agent.zig` owns `send` (validation, the gate, the log line) and
reaches Core through an `Outbox` (find a conversation, list them, post);
Core owns places, topics, the hourly limit and quick replies. A new
`session.zig` reads runs back from the log for `/session` and `harness
log runs|session`.

**Tech:** Zig 0.17.1, std only. Tests: `zig build test` (unit, then
`scripts/smoke.sh`); `-Dtest-filter=NAME` (added in task 1) runs some.

## Rulings

Where the spec can't work as written, the smallest change that keeps its
intent (what – why – cost if wrong):

- R1. A final `send` that was held by the hourly limit or did not get
  through still ends the turn; its `send` line says `delivered: false`
  and the tool result tells the model. – Before gap 5 nothing can keep a
  chat post, and going on would let the model post into the same limit
  again. – A reply lost to a network error is only in the log (`/session`
  shows it) until gap 5 keeps it.
- R2. The terminal's own conversation is `terminal` in `harness chat`
  and the run's `to` in `harness brief` and `task run`; posts to any
  other conversation print with `[NAME]` in front. – "Another
  conversation" needs a home, and this keeps `task run`'s output as it
  was. – None beyond what the terminal prints.
- R3. Under Telegram (`harness run`) the agent is not offered `terminal`:
  it is left out of "Others:" and a `send` to it is refused as an unknown
  conversation. – No channel reaches the terminal there; a post would
  only fail. – The agent can't leave a note for a later `harness chat`.
- R4. Any refusal Telegram gives a send into a topic counts as that topic
  refused (its posts go to main with `[NAME]` in front until restart). –
  The Bot API client sees "refused", not why (a deleted topic is a 400 like
  others). – A post refused for another reason sends that topic's posts
  to main until harness restarts.
- R5. A `send` line keeps the first message's id and how many messages
  the post took (`message`, `parts`), not every id. – A channel returns
  the first id; Telegram's ids for one post's parts follow each other. –
  An app that wants each id infers them.

Notes:

- Tasks 5 and 6 landed as one commit (6bf975a): Task 6's edits were made
  on top of Task 5's before Task 5 was committed. Each was tested on its
  own (Task 5's suite green before Task 6 was written; Task 6's tests seen
  failing against the old behaviour, then the whole suite green).
- Existing tests changed on purpose: `a_runs_lines_carry_its_id_and_its_first_line_says_who_started_it`
  (log.zig: labels readable when private); `telegram_send_before_pairing_is_an_error`
  (main.zig: the channel takes a place); `private_turns_stay_out_of_memory`,
  `a_turn_running_when_private_goes_on_stays_out_of_memory` (core.zig: a
  context per conversation). The Recorder (test helper) notes each post's
  place and keeps up to 4 buttons.

## File map

| File | Change |
|---|---|
| `build.zig` | `-Dtest-filter` for the unit tests |
| `src/log.zig` | `Tag.conversation`, kind `send`, labels readable in private lines |
| `src/conversations.zig` | new: names, entries, `state/conversations`, the upgrade |
| `src/config.zig` | `to =` in tasks.ini and briefs.ini; `[limits] sends_per_run`, `sends_per_hour` |
| `src/http.zig` | `Request.content_type`, `multipart` |
| `src/telegram.zig` | topics in updates, `getMe`, sends to a thread, `sendDocument`, `createForumTopic` |
| `src/fake.zig` | non-JSON bodies recorded as strings; `getMe`, `createForumTopic` |
| `src/agent.zig` | `send`, `Outbox`, `postReply`, run's conversation and context note, merged user messages |
| `src/core.zig` | places, routing in, contexts per conversation, commands, posting, quick replies, `/session` |
| `src/session.zig` | new: runs and sessions read back from the log |
| `src/main.zig` | TgChan and TermChan with places, getMe, `log runs`, `log session` |
| `scripts/smoke.sh`, `README.md` | topic, `/session`, a task's `to` |

---

### Task 1: log labels, the `send` kind, a test filter

**Files:** `src/log.zig`, `build.zig`

- `pub const Kind = enum { …, recovered, send };`
- `Tag.conversation: ?[]const u8 = null`, written right after `rid`
  (`"rid":5,"conversation":"main","run":"chat",…`), so lines that match
  `"run":…,"by":…` today still do.
- `value()`: in private lines `run`, `conversation`, `by`, `agent`, `to`
  and `event` stay readable besides `tool`, `decision`, `why`.
- `build.zig`: `b.option([]const []const u8, "test-filter", …)` passed
  as the unit tests' `filters`.

Tests (log.zig):
- `labels_stay_readable_in_private_lines`: a private first line with
  conversation `house-search` reads
  `"rid":1,"conversation":"house-search","run":"chat","by":"owner","agent":"main","text":{"bytes":13}`;
  a private `send` line keeps `"to":"main","event":"posted"` and hashes
  its `text`; neither text is in the file.
- Changed on purpose (labels readable when private):
  `a_runs_lines_carry_its_id_and_its_first_line_says_who_started_it`
  now expects `"rid":6,"run":"chat","by":"owner"` on its private line.

- [ ] test fails (no `conversation` field; `run` hashed) → implement → passes → suite → commit

### Task 2: the conversations list

**Files:** `src/conversations.zig` (new), `src/main.zig` (test import)

```zig
pub const max_name = 32;
pub fn validName(name: []const u8) bool; // a-z 0-9 - _, 1..32, not new/rename/rm/add
pub const Audience = enum { own, shared };
pub const Kind = enum { telegram, terminal };
pub const Entry = struct { name: []u8, channel: Kind, chat: i64, thread: i64,
    audience: Audience, private: std.atomic.Value(bool), created: i64,
    // in memory only: refused topic, told, dropped turns, last used, hourly posts
    refused: bool, told: bool, dropped_turns: usize, used_s: i64,
    posts: std.ArrayList(i64), held: u32, told_held_s: i64 };
pub const New = struct { name, channel = .telegram, chat, thread = 0, audience = .own, private = false, created };
pub const List = struct {
    pub fn init(gpa, io, path) List; pub fn deinit(l: *List) void;
    pub fn load(l: *List) !void; pub fn save(l: *List) !void; // temp file, then rename
    pub fn find(l, name) ?*Entry; pub fn at(l, chat, thread) ?*Entry;
    pub fn add(l, New) !*Entry; pub fn rename(l, old, new) !void; pub fn remove(l, name) bool;
    pub fn ensure(l, owner: ?i64, private_main: bool, now_s: i64) !bool; // terminal; main once paired
    pub fn fromTopic(l, a, topic: ?[]const u8, thread: i64) ![]const u8; // the name for a new topic
};
```

Callers hold `List.mutex`. Removed entries move to `gone` (freed at
deinit): a run may still read their `private` flag.

Tests:
- `the_list_is_written_whole_and_read_back`: main, house-search (thread
  5012, private) and family (shared) are three lines of exactly the
  spec's form; no `.tmp` is left; a fresh List reads them back; a line
  that does not read is skipped, the rest kept.
- `names_from_topics_follow_the_name_rule`: "House search" →
  `house-search`, again → `house-search-2`; "Ünïcode!!" → `ncode`;
  "!!!" (thread 5013) → `topic-5013`; "Add" → `add-2`; 40 letters cut to
  32; `validName` refuses `Main`, `a b`, `a/b`, ``, 33 letters, `rm`.
- `an_old_folder_gets_terminal_and_main_once_paired`: `ensure(null,…)`
  writes `terminal` only; `ensure(42, true,…)` adds `main` (chat 42,
  private); a third call changes nothing (returns false).

- [ ] tests fail (no file) → implement → pass → suite → commit

### Task 3: `to` and the send limits in the settings

**Files:** `src/config.zig`

- `Limits.sends_per_run: u32 = 10`, `Limits.sends_per_hour: u32 = 60`,
  both in `defaults_ini`.
- `Task.to: []const u8 = "main"`, `Brief.to: []const u8 = "main"`; `to =
  NAME` refused unless `conversations.validName(NAME)`.

Test `tasks_and_briefs_name_their_conversation`: `to = house-search`
read; default `main`; `to = House Search` and `to = a/b` are BadConfig;
a brief's `to`; the two limits' defaults.

- [ ] fail → implement → pass → suite → commit

### Task 4: Telegram topics, documents and the stand-in

**Files:** `src/http.zig`, `src/telegram.zig`, `src/fake.zig`

```zig
// http.zig
Request.content_type: []const u8 = "application/json";
pub const Part = struct { name: []const u8, value: []const u8, filename: ?[]const u8 = null };
pub fn multipart(a, boundary: []const u8, parts: []const Part) ![]u8;
// telegram.zig
Update.message: { …, message_id, chat_type = "private", thread = 0, topic: ?[]const u8 = null }
Update.callback: { …, thread = 0 }
pub const Sent = struct { first: i64 = 0, count: u32 = 0 };
pub const Me = struct { username: []const u8, topics: bool };
pub fn getMe(b, arena) !Me;
pub fn sendTo(b, chat, thread, text) !Sent;            // send() = sendTo(chat, 0, …)
pub fn sendButtonsTo(b, chat, thread, text, buttons) !i64;
pub fn sendDocument(b, chat, thread, name, data) !i64;  // multipart
pub fn createForumTopic(b, chat, name) !i64;            // the new thread
```

A message's thread is `message_thread_id` in a private chat, and in a
group only with `is_topic_message` (there it also marks reply threads).
Its topic name is `forum_topic_created.name` on it or on the message it
replies to. The stand-in records a body that is not JSON as a JSON string,
answers `getMe` from `telegram/me.json` (default: topics on) and
`createForumTopic` with thread 5000+n (an error while
`telegram/no-topics` exists).

Tests (telegram.zig):
- `updates_carry_the_topic_and_sends_go_to_it`: a topic message gives
  thread 5012, topic "House search", chat type private; a group message
  type supergroup, thread 0; a press in the topic thread 5012;
  `sendTo(42, 5012, …)` carries `"message_thread_id":5012`, `send(42,
  …)` none; `getMe` says the username and topics on;
  `createForumTopic` returns a thread and is recorded with its name.
- `documents_are_sent_as_multipart`: `sendDocument(42, 5012,
  "flats.csv", …)` is one `sendDocument` call whose body has the
  chat_id, message_thread_id and document parts, the file name and the
  bytes; `multipart` drops `"`, CR and LF from a file name.

- [ ] fail → implement → pass → suite → commit

### Task 5: places, routing in, replies where the message came from

**Files:** `src/core.zig`, `src/main.zig`

```zig
pub const Place = struct { name: []const u8 = "main", chat: i64 = 0, thread: i64 = 0 };
pub const Sent = struct { first: i64 = 0, count: u32 = 0 };
pub const Channel = struct { ctx,
    send: fn (ctx, Place, text) anyerror!Sent,
    buttons: fn (ctx, Place, text, buttons) ?i64,
    clear: fn (ctx, Place, id) void,
    send_to: ?fn (ctx, chat, text) anyerror!void = null,
    document: ?fn (ctx, Place, name, data) anyerror!i64 = null,
    open_topic: ?fn (ctx, chat, name) anyerror!i64 = null };
pub const Incoming = struct { from: i64, chat: i64, chat_type = "private", thread = 0, topic: ?[]const u8 = null, text: []const u8 };
Core.convs: conversations.List; Core.topics_on; Core.bot_name_buf/len
pub fn handleIncoming(c, Incoming) !void;   // handleMessage(from, text) = the private chat
pub fn handleTextIn(c, conv, text) !void;   // handleText(text) = main
pub fn sayIn(c, conv, text) void; pub fn deliverIn(c, conv, text) !void; // say/deliver = main
pub fn setBot(c, username, topics_on) void;
fn commandIn(c, a, conv, text) ![]const u8; // command(a, text) = main
```

- Routing: the private chat without a thread is `main`; a thread of it is
  that topic's conversation, made (and written) before its message is
  queued; in a group only the owner's `/conversation add NAME` is read;
  anything else is dropped and logged. `/cmd@BOT` is `/cmd`.
- Queue items carry their conversation; replies, Queued, errors and
  command replies go where the message came from; instance lines to
  `main`; the run's questions to its conversation.
- `/conversations`; `/conversation new|rename|rm|add`.
- Pairing: the first owner gets `main`; another account moves `main` to
  its chat and drops the old account's topics, saying which.
- main.zig: TgChan sends to a place's chat and thread; getMe at start;
  the poll loop passes chat, type, thread, topic; TermChan prints
  `[NAME]` in front of posts not for its home (R2).

Tests (core.zig; the Recorder notes each post's conversation and thread):
- `a_reply_goes_to_the_conversation_the_message_came_from`: a message
  in topic 5012 is answered in house-search, thread 5012, not main.
- `a_new_topic_is_a_conversation_named_after_it_before_its_turn_starts`:
  right after `handleIncoming` (no worker), `state/conversations` has
  house-search with thread 5012; a second topic of the same name is
  house-search-2.
- `pairing_another_account_moves_main_and_drops_the_old_topics`: after
  77 pairs, main's chat is 77, house-search is gone, and the new owner
  is told "house-search".
- `conversation_commands_open_rename_and_forget`: `/conversation new
  trading` opens a topic (Recorder thread) and lists it in
  `/conversations`; rename to `markets`; `rm` forgets it; main and
  terminal can't be renamed or removed.
- `a_group_is_read_only_for_conversation_add`: a group message is
  dropped and logged; the owner's `/conversation add family@harness_bot`
  there makes `family` shared; a stranger's is dropped.
- Changed on purpose (the channel takes a place):
  `telegram_send_before_pairing_is_an_error` (main.zig) calls
  `send(ctx, place, text)`.

- [ ] fail → implement → pass → suite → commit

### Task 6: a context per conversation; runs carry their conversation

**Files:** `src/core.zig`, `src/agent.zig`

```zig
const Context = struct { name: []u8, conv: agent.Conversation, memory_upto: usize,
    turns_since_memory: u32, last_owner_s: i64, used: u64, reset: std.atomic.Value(bool) };
const max_contexts = 16;
fn contextFor(c, name) !*Context;   // the 17th drops the least used after its memories are written
pub fn contextOf(c, name) ?*Context; // tests
fn chatTurnIn(c, conv, text, note: ?[]const u8) void; // chatTurn(text) = main
Run.conversation: []const u8 = ""; Run.conv_private: ?*const std.atomic.Value(bool) = null;
Run.context_note: []const u8 = "";
```

- `/new` and `/private` act on the conversation they are sent in; a run
  is private when its conversation is, at its start or once switched on;
  0.3's `private on` becomes main's.
- `logRun` writes `conversation` on every line of a run (not when empty).
- The per-turn context block names the conversation and the others:
  "Conversation: house-search (Telegram topic). Others: main, trading."
- The quiet-time writer runs per context.

Tests:
- `new_resets_only_its_conversation`.
- `the_17th_context_drops_the_least_used_after_its_memories_are_written`:
  17 topics; the 17th turn makes a writer call that reads the first
  topic's turn; 16 contexts remain; the next turn in the first topic is
  told turns were dropped.
- `every_line_of_a_run_carries_its_rid_and_conversation` (a turn with a
  tool call in a topic; its context block names it and the others).
- Changed on purpose (contexts per conversation):
  `private_turns_stay_out_of_memory`,
  `a_turn_running_when_private_goes_on_stays_out_of_memory` read main's
  context instead of `Core.conv` / `Core.turns_since_memory`.

- [ ] fail → implement → pass → suite → commit

### Task 7: `send` and the reply

**Files:** `src/agent.zig`, `src/core.zig`

```zig
pub const Target = struct { name, shared = false, private = false, exists = true, kind: []const u8 = "" };
pub const Attachment = struct { name: []const u8, data: []const u8 };
pub const Post = struct { to, text, files: []const Attachment = &.{}, buttons: []const []const u8 = &.{}, final = false, implicit = false };
pub const Delivery = struct { status: enum { sent, kept, held, silent, failed }, messages: []const u8 = "", parts: u32 = 0, files: u32 = 0, why: []const u8 = "" };
pub const Outbox = struct { ctx, find: fn (ctx, a, name) ?Target, names: fn (ctx, a) []const []const u8, post: fn (ctx, a, *const Post) Delivery };
Run.outbox: ?Outbox = null; Run.sends: u32 = 0; TurnResult.replied: bool = false;
pub fn postReply(r: *Run, a, text) !Reply; // the implicit reply: gate, post, log `implicit`
```

- The tool (only with an outbox, never for helpers): `to` (default the
  run's), `text` (16 KB), `final`. A final post ends the turn: later
  calls in the reply get "not run: the turn ended with your final send",
  the results are kept, and the next turn's message joins them in one
  user message (`Conversation.messages` merges same-role neighbours).
  Refused, the turn goes on.
- Instructions (stable part, runs with `send`): "The owner sees only what
  you post with send. …"
- Core's `RunOut` (the outbox): places, `[NAME]` in front of posts of runs
  the owner did not start. chatTurn: replied → nothing more; ended by a
  limit or an error → harness's line, never working text; else the
  implicit reply, and a refused one is said ("a rule stopped it").
- The memory writer and summaries read a `send`'s text as the agent's.

Tests (core.zig):
- `send_final_posts_once_and_ends_the_turn_without_another_model_call`
  (one model request; next turn's request has the send's result and the
  new text in one user message, the result first).
- `a_turn_that_stops_without_send_posts_its_last_text_once` (log
  `"implicit":true`).
- `a_note_mid_turn_does_not_take_the_replys_place`.
- `working_text_is_never_posted` (text and a call, then the step limit:
  the owner gets "Step limit reached for this turn." only).
- `helpers_never_get_send` (not in a helper's tools; asked by name, "not
  available here").
- `a_rule_that_stops_the_reply_is_said_in_main` (`deny send main`).

- [ ] fail → implement → pass → suite → commit

### Task 8: other conversations, shared ones, limits, files

**Files:** `src/agent.zig`, `src/core.zig`

- Unknown `to`: refused, naming the known ones (the run's own `to` that
  is no conversation yet opens its topic at the first post).
- Shared: `gate.Ctx.shared`, the question shows the whole post and the
  files' names, no Allow 24 h; denied unattended (noted as skipped).
- `sends_per_run`: the 11th refused. `sends_per_hour` per conversation:
  past it logged, not sent; main told once an hour.
- `files`: ≤ 4, ≤ 20 MB, confined as for `read_file`; a part starting
  with "." asks; one holding a stored secret is refused; sent as
  documents. `buttons`: ≤ 4 of ≤ 32 bytes, own conversations only.
- A send line is private when its run or its target is.
- A topic Telegram refuses: posts go to main with `[NAME]` in front; the
  owner is told once why.

Tests (core.zig): `send_to_another_conversation_is_allowed_and_logged`,
`send_to_an_unknown_conversation_names_the_known_ones`,
`send_to_a_shared_conversation_asks_every_time_without_24h_and_is_denied_unattended`,
`the_11th_send_of_a_run_is_refused`,
`posts_over_the_hourly_limit_are_not_sent_and_main_is_told_once`,
`private_is_per_conversation_and_covers_sends_into_it`,
`an_attachment_outside_the_workspace_or_holding_a_stored_secret_is_refused`,
`a_refused_topic_posts_to_main_with_its_name_in_front`.

- [ ] fail → implement → pass → suite → commit

### Task 9: tasks and briefs post to their `to`

**Files:** `src/core.zig`

- Tasks get `send` (outbox with the task's `to`, `[NAME]` in front,
  `NOTHING` silent, "Skipped (needs approval): …" added to the reply);
  briefs post what they wrote through `postReply`. A message that did not
  get through is kept with its conversation and sent again there.

Test: `a_task_posts_to_its_conversation_with_its_name_in_front` (a task
with `to = house-search` answers there with `[check]`; a brief with `to`
too); today's task and brief tests pass unchanged.

- [ ] fail → implement → pass → suite → commit

### Task 10: quick replies

**Files:** `src/core.zig`

- `buttons` on a post: data `r<post>-<token>:<n>` (the token is the
  start's nonce); a press counts once and only from its own message,
  posts the label as the owner's message in that conversation (a turn
  whose context block names the post) and clears the buttons; a press
  from before a restart answers nothing.

Test: `a_quick_reply_counts_once_and_not_after_a_restart`.

- [ ] fail → implement → pass → suite → commit

### Task 11: the session view

**Files:** `src/session.zig` (new), `src/core.zig`, `src/agent.zig`,
`src/main.zig`

```zig
pub const RunInfo = struct { rid: u64, time, label, by, conversation, parent: ?u64, steps: ?i64, end: []const u8 };
pub fn runs(a, log_text) ![]RunInfo;                       // oldest first
pub fn lastRunIn(a, log_text, conversation, back: usize) ?u64; // 1: the last; helpers left out
pub fn render(a, log_text, rid, max: usize) ![]const u8;   // max 0: all
pub fn raw(a, log_text, rid) ![]const u8;                  // the run's and its helpers' lines
pub fn tail(io, a, path, max: usize) ![]const u8;          // from the first whole line
```

- `/session [N]` (up to 20): one message of up to 3,500 bytes, then
  "harness log session RID shows all"; reads the log's last 4 MB.
- `harness log runs [N]` (20), `harness log session RID [--json]`.
- Tool lines get `bytes` (the whole output's size).

Tests: `session_shows_the_last_run_here_and_only_labels_for_a_private_one`
(core), `log_runs_and_log_session_read_runs_back` (main).

- [ ] fail → implement → pass → suite → commit

### Task 12: smoke and README

- smoke.sh: a message in a topic is answered there; `/session` there
  lists its tool call; a task with `to = house-search` posts to that
  topic.
- README: Conversations, `send`, commands, `to =`, the limits, the log's
  `conversation` and `send` lines, `harness log runs|session`.

- [ ] smoke fails first → implement → `zig build test`, ReleaseSafe,
  cross builds → commit

## Review Focus

- Every post of the agent passes the gate as `send` (the implicit reply
  and a brief's too); harness's own lines don't; shared posts are asked
  every time, with no Allow 24 h, and refused unattended.
- No working text is posted: only a final `send`, the implicit reply, or
  harness's line for a limit or an error.
- A final `send` leaves a valid conversation: every tool call has its
  result, results first in the next user message.
- `state/conversations` is written before a new conversation is used.
- Secrets: a file holding a stored secret is never sent; send lines are
  masked; private runs and targets hash texts, labels stay readable.
- Every new Core field is set in `Core.open`.
