# harness: the inbox (gap 5)

2026-11-22. Gap 5 of `2026-11-22-harness-platform-overview.md` (binding).
Built by the Mac session in phase A, after phase 0 (the who, grants with
`who`) and conversations (gap 4: `rid`, `by`, `conversation`), before
triggers (gap 6: skipped, paused).
The apps spec (gap 8) relies on the item format fixed here. Rule 3 (ask is
deny unattended), money asked every time and masking stay.

## Intent

The post: the owner needs one focused inbox of approvals and questions,
and apps for reviewing intermediate work that needs a person. Harness asks
one question at a time, holds it in memory only, and a scheduled run that
needed an approval can only report what it skipped. Here all that waits
for the owner is an item in one file, shown where its run reports,
answered once, in any order.

## Goals

1. Items (approvals, questions, drafts, skipped calls, deliveries; other
   parts add kinds) in `state/inbox`, written before anyone acts on them.
2. Several open at once, each answered once by its buttons or a text
   reply, in any order; today's button rules kept, per item.
3. `ask_owner`: the agent asks a question, or shows a draft, and waits.
4. Unattended runs keep ask = deny; a skipped call becomes an item that
   can allow it for later runs of the same task.
5. Undelivered posts kept across restarts; `/inbox`, `/answer`, `/grants`,
   `harness inbox [--json]`; a fixed format for apps.

## Non-goals (this build)

- A browser inbox page (with apps, gap 8); answering from the CLI.
- A run waiting past its turn (waits that outlive a run are workflows',
  gap 7). Answering a scheduled run's question later: `ask_owner` is not
  offered there; a task can post quick replies with `send`.

## What the owner does

- Telegram: presses an item's buttons; replies to an item's message with
  text (an answer, an own version of a draft, or a reason that denies an
  approval); `/inbox` (what waits, a Show button each); `/answer ID TEXT`;
  `/grants`, `/grant rm N`.
- Terminal: `o`, `d`, `n` for approvals, `1` to `4` for other choices,
  with the id when several are open (`o 41`); the same commands.
- `harness inbox [--json]`: open items (with `--json` all kept ones, in
  format v1); it only reads, so it works while harness runs.
- `config.ini`: `[inbox] questions = 20` (run items open at once),
  `remind = 09:00` (owner's time, or `off`).
- `state/inbox` (new); `state/grants` gets a fourth field, `who` (phase
  0); `state/approvals` gives the first id, then is retired.

## Design

### Items

`state/inbox`: one JSON object per line, rewritten whole (temporary file,
then rename) under one lock on every change, before a waiter is told; open
items and those closed in the last 7 days, at most 500. Format v1, as
`harness inbox --json` prints it and apps get it:

```json
{"v":1,"id":41,"kind":"approval","status":"open",
 "created":"2026-11-22T14:02:11Z","expires":"2026-11-22T14:12:11Z",
 "by":"owner","agent":"main","rid":18234,"run":"chat",
 "conversation":"research","waiter":"run","app":null,
 "title":"shell: git push origin main","body":"shell: git push origin main",
 "choices":[{"key":"once","label":"Allow once"},{"key":"day","label":"Allow 24 h"},{"key":"deny","label":"Deny"}],
 "text":"reason","draft":null,"count":1,"answer":null}
```

- `status`: `open`, `answered`, `expired`, `void` (its run is gone, or it
  could not be shown), `withdrawn` (its run stopped), `done` (settled by
  harness: a post arrived). `waiter`: `run` (void at restart), the
  waiting instance's step label `workflow NAME#N/STEP` (gap 7) or
  `harness`; the last two are kept. `by` and `agent`: the run's, as the
  overview's Shared formats write them (`agent` null without a run).
- `text`, what a text answer is: `none`, `answer`, `draft` (an own
  version, taken as "use it") or `reason` (it denies; the agent gets it).
- `answer`: `{"key":"deny","text":"use staging","at":"…","via":"telegram"}`,
  `via`: `telegram`, `terminal`, `bar` (gap 8's shell) or `harness`
  (expiry, restart). `count`: how often the same thing came up. `app`: an
  app whose link the item's message carries (see `ask_owner`).
- In the file only (not in `--json`, not to apps): `token` (16 hex,
  random per item), `shown` (chat, thread, message id of up to 4 messages
  with its buttons), `post` (a delivery's conversation, text, files,
  links), `grant` (tool with its `@ENV`, key, who: the overview's Grants).
- `title` up to 200 bytes, `body` up to 12 KB (today's question limit; a
  longer call is refused). Both pass the log's mask list; a private run's
  item keeps its text while open, only size and keyed hash once closed.
- Log: new kind `inbox`, events `open` (id, kind, conversation, rid,
  title; private as its run), `shown`, `answered` (id, key, via, text
  size), `expired`, `void`, `withdrawn`, `done`, `remind`; gate lines name
  the item ("allowed once by the owner (item 41)").
- Kinds are open: a part may add one with its own choices and waiter
  `harness` or a workflow step (the table's last three rows).

| kind | made by | choices | waiter |
|---|---|---|---|
| approval | the gate's ask | once, day (not money, a shared send or a setup call), deny | run, workflow |
| question | `ask_owner`; a workflow's `approve` | up to 4 of the agent's, or Approve and Deny; text if it allows | run, workflow |
| draft | `ask_owner` with `draft`; a workflow's `review` | use, drop; text: an own version | run, workflow |
| skipped | an unattended call refused only for want of approval | allow for this task, trigger or workflow (30 days), dismiss | harness |
| delivery | a post that did not get through | send again, drop | harness |
| paused | a trigger that paused (gap 6) | resume, remove | harness |
| interrupted | a workflow step cut off by a restart or `/stop` (gap 7) | run again, skip, stop | workflow |
| failed | a workflow step that failed after its retries (gap 7) | run the step again, stop | workflow |

Setup calls (the overview's Shared formats: gap 6's `trigger add`, gap
7's `workflow save`, gap 1's `agent_save`, gap 8's `app_save`, gap 2's
`env_save`) are approvals the run waits on, asked every time, without
"Allow 24 h"; there are no separate setup items.

### Answering

- A press counts when its item is open, its token matches, and it comes
  from one of the item's `shown` messages (one before the channel said
  where the buttons are is checked once it has, as today). The first sets
  the answer, writes the file, then wakes the waiter; the item's messages
  are edited: buttons off, the outcome added ("Allowed once, 14:03").
- A press on a closed item with its token: "Already answered: allowed
  once at 14:03." (or expired, void, withdrawn). Any other: "That button
  is out of date: it answers nothing."
- Text, as a Telegram reply to an item's message or `/answer ID TEXT`:
  denies an approval ("denied by the owner: TEXT" to the agent), answers a
  question, replaces a draft; other kinds: "Item 45 takes the buttons
  only." A reply to any other message is a chat message, as today.
- Out of order: each item has its own waiter; answering 44 before 41
  wakes only 44's run. Runs and helpers no longer ask one at a time
  (today's `ask_lock` goes). At most `questions` (20) run items are open;
  one more waits for a place until its turn ends, then is refused. Other
  kinds don't count (at most 200 open; past that the oldest skipped
  expire).
- Expiry: a run's item at `approval_seconds` or when its turn ends,
  whichever is first, and none is made with no time left (today's rule); a
  workflow's when the workflow says (default 7 days); the others after 7
  days. The ticker closes them and tells their waiters (no answer: deny).
- Restart: run items are void at start, their messages edited. The item's
  own token replaces the per-start nonce: a button answers only its item,
  also when `state/inbox` was deleted (new ids, new tokens) or restored
  from a backup (its run items are void anyway).
- A run's item that could not be shown is void at once and its call
  denied, as today. `/stop` withdraws the items of the runs it stops;
  leaving `harness chat` withdraws open run items.

### `ask_owner`

```json
{"question":"Which account should I order from?","choices":["Personal","Work"],"text":false}
{"question":"Send this reply to Anna?","draft":"Hi Anna, …","app":"mail-review"}
```

Waits like an approval, with its expiry; the model gets `chose: Work`,
`wrote: …`, `draft used as it is`, `draft replaced by the owner: …`,
`dropped` or `no answer in time`. `app` names an installed app (gap 8):
the item's message carries its link, to review the draft there; the answer
still comes from Telegram, the terminal or the bar. Gate kind
`ask_owner`, argument the question, allowed by default. Offered only where
the owner can answer: not to helpers (their run asks) and not in
unattended runs (rule 3).

### Unattended runs

Rule 3 stays: ask is deny, and the run's post says "Skipped (needs
approval): …", now with the item's id. Each such call is also one
`skipped` item per task (or trigger, workflow) and call, as the gate keys
it; a repeat adds to `count`, also for 7 days after a dismiss. It is
posted once, silently.

"Allow for this task" adds a grant for that tool and key (the exact
command; the host for fetch, browse, web; the tool for MCP; `NAME HOST`
for a login) for the task, trigger or workflow the run belongs to: its
`by` (`schedule:NAME`, `trigger:NAME`, or `workflow:NAME` without the
step; a helper has its parent's), for 30 days. Its next run makes the
call; other tasks and triggers still can't; chat is unchanged. Why: the
run still waits for no one, but the owner, having seen the whole call
once, decides for later runs: rule 2's asked once, shown in full, listed
and removable, without writing a rule (a rule in the task's section,
`[schedule:NAME]`, does the same for good).

- Not offered for money (that stays `[money] scheduled` with caps) or a
  `send` where others read (that takes an `allow` rule line), for a run of
  no task, trigger or workflow (a brief), or for a call skipped only for
  files the agent wrote (`state/written`: a grant can't lift that check).
- `state/grants`: `tool` (with `@ENV` for `shell`, gap 2), `expiry`,
  `key`, `who`, tab-separated, as the overview's Grants fix them; `who` is
  `schedule:NAME`, `trigger:NAME`, `workflow:NAME` (here), `agent:NAME`
  (gap 1's 24 h grants) or `app:NAME` (gap 8's), empty for any run (0.3's
  grants). A definition goes in `who`, never in `tool`. `/grants` lists
  all with who and expiry; `/grant rm N` removes one. Both logged (kind
  `config`).

### Deliveries

A post (a `send`, a reply, a brief, a task's answer) that did not get
through becomes a `delivery` item; the run that posted is told "kept as
item 52". For a reason worth trying again it is sent again after 5
minutes, then 10, 20 … up to 2 hours (today's waits), now also after a
restart: a brief is sent as written, not collected again, its links seen
once it arrives; meanwhile it is only listed (`/inbox`, `harness inbox`),
and its brief or task does not run again (today's kept message). Sent:
`done`. Otherwise it is posted, silently, with "Send again" and "Drop".

### In Telegram and the terminal

- Each item is its own message in its conversation (the run's; `main` for
  deliveries and kinds without a run), buttons on one row (two for four
  choices), in parts with the buttons on the last when long, as today:

  ```
  Allow this? [41]
  shell: git push origin main
  (Reply with text to deny it and say why.)
  ```

  Others start `Question [44]`, `Draft to review [46]`, `Skipped [45]: task
  btc-watch could not make this call without you:`, `Not delivered [52]:`;
  helpers' items keep today's `[chat/h2]`. Button data:
  `i<id>-<token>:<key>`, under Telegram's 64 bytes.
- `/inbox`: a line per open item, oldest first (id, kind, conversation,
  age, title), each with a "Show 41" button (data `s41`; it never answers)
  that posts the item again with its buttons (added to `shown`), so one
  far up the chat is answered where the owner is. None: "Nothing is
  waiting for you."
- Sound: items a run or workflow waits on notify; skipped and delivery
  items go with `disable_notification`. Once a day at `remind`,
  if one has been open over 12 hours: "Waiting for you: 3 items. /inbox",
  silently.
- Terminal: items print as in Telegram (`Allow this? [41]` …) with the
  keys line; with several open a key needs the id, and a key alone lists
  the ids waiting.

### Apps and the other gaps

Apps (8) read items in format v1 through harness's API (`api/inbox`, the
apps spec) and never answer them: an app that answered could approve
itself. Gap 8's bar, harness's own page, answers like Telegram and the
terminal, through one function: `(id, key, text)`, accepted only for an
open item and a key it offers, once; `via` `bar`. Conversations (4): items
go to the run's conversation; `ask_owner` blocks, quick replies don't.
Triggers (6): skipped items for trigger runs, a kind for paused triggers.
Workflows (7): a step waiting for the owner makes an approval, question or
draft with waiter `workflow NAME#N/STEP`; the answer is in `state/inbox`
before the workflow is told, so one resumed after a restart finds it.
Definitions (1), triggers (6), workflows (7), apps (8), environments (2):
their setup calls are approvals. Roles (3), environments (2): grants and
items carry `who` and `by` as above.

## Platform notes

The same on all three. `state/inbox` is replaced by a rename; the Windows
session checks that this works while `harness inbox` reads the file.
Telegram: `editMessageText`, `disable_notification`, replied-to ids.

## Tests

core.zig (today's approval tests move onto items):

- `two_questions_wait_at_once_and_are_answered_out_of_order` (two helpers;
  item 2 first; each gets its own answer);
  `an_item_takes_one_answer_and_a_second_press_says_already_answered`;
  `a_press_counts_only_from_a_message_its_item_was_shown_in`;
  `a_press_before_the_message_id_is_known_is_checked_once_it_is`.
- `run_items_are_void_after_a_restart_and_their_buttons_answer_nothing`;
  `a_button_from_before_a_restart_answers_nothing_even_with_the_same_number_and_message`.
- `the_answer_is_in_state_inbox_before_the_run_goes_on`;
  `an_item_expires_at_approval_seconds_or_its_turns_end`;
  `stop_withdraws_the_items_of_the_runs_it_stops`.
- `a_text_reply_to_an_approval_denies_it_and_the_agent_gets_the_reason`;
  `ask_owner_returns_the_choice_or_the_text`;
  `a_draft_answered_with_text_returns_the_owners_version`;
  `ask_owner_is_not_offered_to_helpers_or_unattended_runs`.
- `a_call_a_task_skips_is_one_item_however_often`;
  `allowing_it_lets_that_task_alone_make_the_call_for_30_days` (next run
  makes it, another task still skips it, `/grants` lists it);
  `money_shared_send_and_written_file_skips_offer_no_grant`.
- `an_undelivered_brief_is_sent_after_a_restart_without_being_collected_again`;
  `show_posts_an_item_again_and_its_new_buttons_count`;
  `the_21st_question_waits_for_a_place_until_its_turn_ends`.
- `skipped_and_delivery_items_make_no_sound`;
  `the_reminder_comes_once_a_day_for_items_open_over_12h`;
  `items_hold_no_stored_secret_and_a_private_items_text_goes_when_it_closes`.

main.zig: `the_terminal_answers_by_id_when_several_are_open`,
`harness_inbox_json_prints_v1_without_the_kept_fields`. smoke.sh: helpers'
questions answered out of order; a press after a restart is out of date; a
skipped call allowed from its item runs on the task's next run.

## Calls I made (the owner can change them)

- One file of JSON lines, rewritten whole; closed items kept 7 days.
- A token per item instead of a nonce per start; run items void at start.
- All questions at once, helpers' too; at most 20 open.
- A text reply to an approval denies it and gives the agent the reason.
- `ask_owner` only where the owner can answer; apps read items, never
  answer them (Telegram, the terminal and gap 8's bar do).
- One skipped item per task and call; "Allow for this task" is a grant for
  that task alone, for 30 days, never for money or a send others read.
- Waiting items notify, others are silent; one reminder a day. One message
  per item, plus `/inbox` with Show buttons.
- Undelivered posts kept on disk: after a restart a brief is sent as
  written, not collected again (today it runs again).

Changed to fit the overview's Shared formats:

- `who` values are `KIND:NAME` (`schedule:NAME` for a task, was `task
  NAME`); a definition's grant is `who` `agent:NAME`, not `@AGENT` in
  `tool`, since `@` in `tool` is the environment.
- A workflow's `waiter` names its instance (`workflow NAME#N/STEP`), so an
  answer reaches the right one when several wait on the same step.
- Items carry `agent`. Setup calls from every gap are approvals (the
  kinds' table and the setup line); gaps 6 and 7's own kinds are listed
  in the table.

Settled (were questions for the owner):

- Task grants last 30 days (was question 1), listed in `/grants` and
  removable; the next skip after one ends offers it again.
- All questions at once, helpers' too, at most 20 open (was question 2):
  one at a time is what the inbox replaces.
- The reminder is on (was question 3): once a day at 09:00, silent, when
  something has waited over 12 hours; `remind = off` stops it.

## Questions for the owner

None left: the three above are settled.
