# Long memory (Part 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent can search every past turn in the log (`history`, `/history`, `harness log search`), and each conversation gets summaries by day, week and month that go into its prompt.

**Architecture:** `history.zig` scans the log backward in 1 MB chunks (lowercased in place, one Boyer-Moore-Horspool table per word), keeps a bit per word for each run it has seen lines of, and completes a run at its first line (seq = rid), so the first 20 complete matches are the newest; hits are shown from their lines re-read by offset. `summaries.zig` holds the daily pass (reads the last 7 days of the log once, writes `state/summaries/CONV/{day,week,month}/…md` with util.writeReplace) and the prompt block. Core owns one `history.Source` and one `summaries.Job`; agent.zig gets one Run field, the tool, and the block.

**Tech Stack:** Zig 0.17.1, std only.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-routines-undo-copies-memory-design.md` (Part 4), with `2026-11-22-harness-platform-overview.md` (binding) and `2026-11-22-harness-conversations-design.md`.

## Global Constraints

- Toolchain `~/.local/zig/zig-aarch64-macos-0.17.1`; one cache dir (`scratchpad/zc-memory`); cross builds (`x86_64-windows`, `x86_64-linux-musl`, `aarch64-linux-musl`, and `unit-build` for each) into a scratch `-p` folder.
- Every new Core field set in `Core.open`. Secrets never in summaries, prompts, logs or test output: what is read from the log is masked again with the current mask list before it reaches a model or a file.
- Plain labels, no slogans (README, tool texts, command replies).
- Edits to agent.zig, core.zig, config.zig small and self-contained (other builders: workflows in core/agent/inbox/config, remote MCP in mcp/main).
- Spec values: up to 20 turns, newest first; tool results' first 2 KB; run view 16 KB; summaries 150/150/200 words; input cap 200 KB, newest kept; 03:00 owner's time; at most 7 days back, oldest first; kept: days 60, weeks 400 days, months always; prompt at most 1,500 words (3 days, 2 weeks not covered, 3 months); `[memory] summaries = on|off` (on), `summary_model` (default the memory model); log kind `memory`, event `summary` (conversation, period, words, tokens).

## Review Focus

- A private conversation's words must never come back from `history`, `/history`, `log search` or a summary (they are not in the log; the run view of a private run is refused) — test with real runs in core.
- A run that may not see a conversation must not learn it exists: a run view or a `conversation` outside its scope says only what this run searches.
- A summary pass must never block chat or a /reload forever: own thread; /reload says Busy while it runs; close waits; failures back off and are given up the next day.
- The cached part of the prompt must not change from turn to turn: the block depends only on the files (written once a day).
- A 50 MB log: one search well under a second in ReleaseSafe (measured, with a generous bound in Debug).

---

### Task 1: history.zig — search, hits, run view

**Files:** Create `harness/src/history.zig`; Modify `harness/src/memory.zig` (a `test {}` that pulls in history.zig and summaries.zig, so main.zig's list stays as it is).

**Interfaces (Produces):**
- `pub const Scope = struct { all: bool, conversation: []const u8 = "" }`
- `pub const Source = struct { log_path, summaries_dir, ctx, shared: ?*const fn (?*anyopaque, []const u8) bool; pub fn scopeOf(s, by, conversation) Scope }` — all when `by == "owner"` and the conversation is not shared.
- `pub fn parseTerms(a, words) ![]const Term` (quoted phrases and words; `Term{ text, scan }`, scan = JSON-escaped, lowercased).
- `pub fn search(a, io, path, scope, Query{ terms, conversation: ?[]const u8, before_s: ?i64, max = 20 }) !Found{ hits: []Hit, more: bool }`
- `pub fn render(a, io, path, found, terms, utc_offset, max_bytes) ![]const u8`
- `pub fn runView(a, io, path, scope, rid, max_bytes) ![]const u8`
- `pub fn answer(a, io, src: *const Source, view: View{ scope, utc_offset }, input_json) !Answer{ text, is_error }`; `pub fn gateArg(a, input_json) ![]const u8` (the words, or `run N`); `pub const tool_def: model.ToolDef`.

Tests (hand-written log lines in a temp file):
- [ ] `history_finds_old_turns_by_words_and_phrase`: all words in one run across owner message, post and tool output (any case) → hit; a word missing → no hit; `"flight to oslo"` matches as typed only; newest first; a word only in a label (`chat`, `owner`) finds nothing.
- [ ] `history_shows_20_turns_and_where_the_older_ones_are`: 25 matching runs → 20 shown and "before = …" for the rest; `before` keeps older ones only.
- [ ] `search_keeps_to_its_scope`: all vs one conversation; `conversation` filter; private lines (`{"bytes":N,"hmac":…}`) never match; `history`'s own tool output is not searched.
- [ ] `history_run_returns_its_session`: run view ≤ 16 KB with "harness log session N shows all" when cut; a run of another conversation: "No run N here"; a private run refused.
- [ ] Run each with `-Dtest-filter`, see it fail (no file), implement, see it pass; commit.

### Task 2: the `history` tool in runs

**Files:** `gate.zig` (kind `history`, default allow), `tools.zig` (two switch arms, own lines), `agent.zig` (Run field `history: ?*const history.Source`, `allows`, `toolDefs` after the built-in list, the arg and the call in `callToolRaw`, output masked again with `r.env.secrets`), `core.zig` (field `history_src` set in open; `baseRun` sets it).

- [ ] `history_keeps_to_what_the_run_may_see` (core): chat in main finds main's, house-search's and family's turns; a task with `to = house-search` finds only house-search's; its run view of main's run says "No run … here".
- [ ] `a_private_conversations_words_are_never_found` (core): a turn in a private topic, then history from main: nothing; the words are not in the log file.
- [ ] `history_is_offered_like_recall` (agent): main's tool list has `history`, scheduled runs too; a definition names it; a bare `delegate` task keeps 0.3's six (Ruling 3); a call is allowed without asking, a deny rule stops it. Full suite; commit.

### Task 3: `/history` and `harness log search`, and a large log

**Files:** `core.zig` (`/history WORDS` → `historyText`, 3,500 bytes, help line), `main.zig` (`log search WORDS…`: an argument with spaces is a phrase; dates in config.ini's utc_offset; usage line), `history.zig` (timing test).

- [ ] `the_history_command_finds_old_turns` (core), `log_search_takes_words_and_phrases_from_the_command_line` (history.zig, `searchText`), `log_search_takes_words` (main.zig, the argument check).
- [ ] `a_search_over_a_50_mb_log_stays_fast`: builds a 50 MB log in the temp folder, searches a word in its oldest run; prints ms; bound 20 s Debug / 5 s release-modes. Commit.

### Task 4: summaries.zig — the daily pass

**Files:** Create `harness/src/summaries.zig`.

**Interfaces (Produces):** `pub const Job = struct { pass_day: ?i64, retry_s: i64, failures, running: std.atomic.Value(bool); pub fn due(j, now_s, utc_offset) bool; pub fn pass(j, env: Env) void; pub fn deinit(j, gpa) void }`; `pub const Env = struct { gpa, io, log_path, dir, now_s, utc_offset, client: *model.Client, log: *log_mod.Log, secrets, private: ?Private, stop }`; `isoWeek(day) {year, week}`; file names `day/YYYY-MM-DD.md`, `week/YYYY-Www.md`, `month/YYYY-MM.md`, a given-up period `PERIOD.given-up`.

- [ ] `days_fold_into_weeks_and_months` (fake clock: `now_s` passed in; fake model: TestEnv): a log over 2026-10-26 … 2026-12-01; passes day by day; day files with the model's text; Monday's pass folds the week (request carries that week's day summaries, 150 words); Dec 1 folds November (weeks whose Sunday is in it + Nov 30's day); a day with no turns makes no call; a silent scheduled run makes no call; `memory` lines `summary` with conversation, period, words, tokens.
- [ ] `missed_days_are_caught_up_oldest_first_at_most_7_back`.
- [ ] `a_failed_summary_is_tried_again_then_given_up`: 500 → no file, retry not before 5 min; same day success → file; failure through the day → next day's pass writes `.given-up`, logs `summary given up`, no call.
- [ ] `a_pass_stops_after_3_failed_calls`, `summaries_are_kept_60_days_weeks_400_days_months_always`, `a_summary_never_holds_a_secret` (a value stored after the line was written is masked in the request and the file). Commit.

### Task 5: summaries where harness runs

**Files:** `config.zig` (`Memory.summaries: bool = true`, `summary_model: []const u8 = ""`, template lines), `core.zig` (field `summary_job` set in open; `tick` → `summariesDue` when `poller_on`; thread; `summarizeNow()`; close waits; /reload Busy while it runs).

- [ ] `summaries_off_makes_no_calls` (core): turns logged today, clock at tomorrow 03:30: off → tick → no model request, no folder; on → tick → the day file and one request.
- [ ] config test for the two keys; commit.

### Task 6: the prompt

**Files:** `summaries.zig` (`pub fn promptBlock(a, io, dir, conv, history_line: bool) !?[]const u8`), `agent.zig` (`systemParts`: after the memory items, before the rolling summary; not for helpers or `memory: pinned`).

- [ ] `the_latest_summaries_are_picked_within_1500_words` (summaries.zig): 3 latest days, the 2 latest weeks not covered by them, 3 latest months; oldest dropped first past 1,500 words; the history line only when asked.
- [ ] `the_prompt_carries_the_latest_summaries_within_1500_words` (agent.zig): order pinned → block → rolling summary; same bytes in two turns; none for a helper or `memory: pinned`. Commit.

### Task 7: README, State line, verification

- [ ] README: Long memory (history, /history, log search, summaries and their cost, `summaries = off`), data-folder row `state/summaries/`, log lines, not built (embeddings, an index), commands, State line counts.
- [ ] Full suite Debug and ReleaseSafe, cross builds, plan notes; commit; remove the cache dir and the scratch install folder.

## Rulings

Each: what – why – cost if wrong.

1. **A turn is a run.** `history` matches a run (one `rid`): its first line's message, its posts (not refused ones, not a scheduled run's NOTHING), its answer, its tool calls' arguments and results (the 2 KB the log keeps). Helpers are runs of their own. `history`'s own results are not searched. – The log keeps a run's words on several lines; "every word must be in the turn" needs one unit, and a URL is found by its address. – A word that is only in a gate line's reason or a label (tool, run, conversation) is not found.
2. **Who sees what.** A run whose `by` is `owner`, in a conversation not shared, searches every conversation (0.3's lines without one too); every other run only its own conversation (its `to`). `/history` is the owner's: as an owner's run in the conversation it is sent in. `harness log search`: everything. A run view or a `conversation` outside the scope says only what this run searches. – The spec's three cases come to this one rule (owners' runs only happen where the owner talks; groups are post-only). – None expected; an app's run (gap 8) is treated as a scheduled one.
3. **Helpers keep 0.3's six default tools.** `history` is offered wherever there is a log, within a definition's `tools` and a task's narrowing, exactly as `recall` is; but a `delegate` task that names no tools still gets search, fetch, browse, read_file, recall, skill. – `agents.default_tools` is documented as "0.3's six" in agents.zig, the README and the delegate tool's description; a helper is handed a standalone task. – A bare helper can't search the history; cost to change: one word in `default_tools` and three texts.
4. **The log does not rotate** (log.zig has no rotation): history and the summaries read `log/actions.jsonl` only. – Nothing to read beside it. – When rotation is built, `search` and `readDays` read the parts too.
5. **A private run's view is refused** ("Run 41 is private: what was said in it is not in the log"), not shown with its labels. – "Private conversations are never found"; the labels say where and when the owner talked privately. – The model can't see a private run's steps; the owner still has `/session` there.
6. **A day's input.** The runs of that conversation that day the owner started, and the others that posted there (`sent` or `kept`); helpers left out (their answers are in their run's delegate result); the owner's messages (scheduled runs' instructions with their label), posts, the answer of a run that posted nothing, tool calls with 300 bytes of their argument and 500 of their result; 200 KB, newest runs kept. – A trigger or task that checks every 5 minutes and stays silent would otherwise make every day of `main` "active" and fill its summaries with checks. – A scheduled run that only wrote files leaves nothing in the summaries (`history` still finds it).
7. **Folds.** A week folds in the pass after its Sunday (Monday 03:00), from its day summaries; a month in the pass after its last day, from the summaries of the ISO weeks whose Sunday falls in it, and the day summaries of its days no such week summary covers (the days after its last Sunday, a week whose fold was given up). – ISO weeks cross months; on the 1st the month's last week is not over. – A week across two months is summarised with the month its Sunday is in.
8. **Retries.** A failed call is tried again by a later pass 5 minutes after, then 10, 20, 40, then every hour, while it is the same day (the owner's time); the first pass of a later day gives it up: it logs `summary given up` and writes `PERIOD.given-up` beside the summaries (pruned with them), so it is not tried again. A pass stops after 3 failed calls (the model is likely not there). A week or month waits for its days that wait. The failures are kept in memory: after a restart a failing period gets one more day of tries. – Bounded cost, nothing blocks chat. – A failing period costs up to about 20 failed calls on its day.
9. **"Weeks not covered" and the cap.** A week is covered when it has day summaries and all of them are among the 3 shown; one with none left (older than 60 days) is not. Months: the 3 latest, as written. Past 1,500 words whole summaries go, the oldest period first; one alone over it is cut to its first 1,500 words. – The spec names "not covered" for weeks only. – The latest month can repeat what a shown week says.
10. **Which prompts.** Runs whose definition reads shared memory (`memory: shared`), in their conversation (a task's: its `to`); not helpers, not `memory: pinned` definitions. The block is in the cached part, after the memory items (pinned and the strongest) and before the rolling summary: its bytes change only when the daily pass writes a file (once a day, plus a retry's success that day). – A definition with `memory: pinned` gets "pinned items only" (the agents spec's R3); helpers get their task alone. – A quiet definition does not see what was said in the conversation.
11. **Where the pass runs.** In `harness run` and `harness chat` (where `tick` starts pollers), on a thread of its own; `/reload` says Busy while it runs and `close` waits for it; settings are read under their lock at its start. – A pass reads the providers that /reload replaces. – A one-off `harness task run` makes no summaries.
12. **Matching.** Case is ignored for ASCII letters; a word matches inside a longer one ("flat" finds "flats"); a phrase matches as written, single spaces included. – std only; no stemming. – "É" and "é" differ; a phrase split by a line break is not found (its words are).
13. **Long summaries** are cut at twice the asked words (300, 300, 400) when written. – A model that ignores the limit would otherwise push the rest out of the prompt. – None.
14. **`summaries = off` also keeps the summaries already written out of prompts** (the files stay; on brings them back). – Off reads as "the feature is off"; an owner who switches it off for privacy would not expect last week in the prompt. – An owner who only wanted to save the calls loses summaries that cost nothing more.
15. **`before` also takes a time** (`YYYY-MM-DD HH:MM[:SS]`, the owner's time), which the "more turns" line gives, so the next page starts where the last one ended. – A date alone can't page through a busy day. – None.

## Notes (as built)

- Commits: 32a7fba (history.zig), 4249a47 (the tool in runs), b2405e6 (`/history`, `log search`), 7dd6ff7 (summaries.zig), then the prompt, the daily job, the README.
- Speed (Task 3): a search that reads all of a 50 MB log (the word only in its oldest run) took 613 ms in a debug build and 66 ms in ReleaseSafe on this Mac, busy with a VM and two other builds; the test's bound is 20 s debug, 5 s otherwise. No index.
- Existing tests changed: none. The prompt changes only where a conversation has summaries, and the tool list only where a run has a log (agent.zig's test fixture has none).
- Shared files touched: agent.zig (one import each for history and summaries, the Run field `history`, one line each in `allows`, `toolDefs`, `callToolRaw`'s argument and call, `earlierBlock` and its one line in `systemParts`; two tests), core.zig (two imports, fields `history_src` and `summary_job` set in `open`, `baseRun`'s `.history`, `/history` and its help line, `historyText`, `sharedConversation`, the tick's one line, `summariesDue`/`summaryThread`/`summarizeNow`/`conversationIsPrivate`, close's wait and free, /reload's Busy; four tests), config.zig (`[memory] summaries`, `summary_model`, two template lines; one test), gate.zig (the kind), tools.zig (two switch arms), main.zig (`log search`, usage, argument check; one test), memory.zig (a test block pulling in history.zig and summaries.zig, so main.zig's list is unchanged).
- Found in review after the README commit, fixed test-first: a log line longer than the read block (none harness writes; a hand-edited log) made the backward search loop forever (seen: the new test ran 3 minutes until stopped) and the summaries' reader stop early; a run id below 1 panicked the reader. Tests `a_line_longer_than_a_block_is_passed_over` (history.zig, block sizes 512 to 16 KB) and `a_line_no_harness_writes_does_not_stop_the_pass` (summaries.zig).
- Flake seen once in a full run, passing alone three times: `an_attachment_outside_the_workspace_or_holding_a_stored_secret_is_refused` (core.zig): it waits for the post to arrive, then reads the log's last `send` line, which is written just after the post is delivered. Not changed here.
