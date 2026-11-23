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
- [ ] `history_finds_old_turns_by_words_and_phrase`: all words in one run across owner message, post and tool output (any case) → hit; a word missing → no hit; `"flight to oslo"` matches as typed only; newest first; 25 matching runs → 20 shown and "before = …" for the rest; `before` keeps older ones only; a word only in a label (`chat`, `owner`) finds nothing; `history`'s own tool output is not searched.
- [ ] `search_keeps_to_its_scope`: all vs one conversation; `conversation` filter; private lines (`{"bytes":N,"hmac":…}`) never match.
- [ ] `history_run_returns_its_session`: run view ≤ 16 KB with "harness log session N shows all" when cut; a run of another conversation: "No run N here"; a private run refused.
- [ ] Run each with `-Dtest-filter`, see it fail (no file), implement, see it pass; commit.

### Task 2: the `history` tool in runs

**Files:** `gate.zig` (kind `history`, default allow), `tools.zig` (two switch arms, own lines), `agent.zig` (Run field `history: ?*const history.Source`, `allows`, `toolDefs` after the built-in list, the arg and the call in `callToolRaw`, output masked again with `r.env.secrets`), `core.zig` (field `history_src` set in open; `baseRun` sets it).

- [ ] `history_keeps_to_what_the_run_may_see` (core): chat in main finds main's, house-search's and family's turns; a task with `to = house-search` finds only house-search's; its run view of main's run says "No run … here".
- [ ] `a_private_conversations_words_are_never_found` (core): a turn in a private topic, then history from main: nothing; the words are not in the log file.
- [ ] Offered like recall: main's tool list has `history`; a bare `delegate` task's helper keeps 0.3's six (Ruling 3). Full suite; commit.

### Task 3: `/history` and `harness log search`, and a large log

**Files:** `core.zig` (`/history WORDS` → `historyText`, 3,500 bytes, help line), `main.zig` (`log search WORDS…`: an argument with spaces is a phrase; dates in config.ini's utc_offset; usage line), `history.zig` (timing test).

- [ ] `the_history_command_and_log_search_find_old_turns` (core + main's function).
- [ ] `a_search_over_a_50_mb_log_stays_fast`: builds a 50 MB log in the temp folder, searches a word in its oldest run; prints ms; bound 20 s Debug / 5 s release-modes. Commit.

### Task 4: summaries.zig — the daily pass

**Files:** Create `harness/src/summaries.zig`.

**Interfaces (Produces):** `pub const Job = struct { pass_day: ?i64, retry_s: i64, failures, running: std.atomic.Value(bool); pub fn due(j, now_s, utc_offset) bool; pub fn pass(j, env: Env) void; pub fn deinit(j, gpa) void }`; `pub const Env = struct { gpa, io, log_path, dir, now_s, utc_offset, client: *model.Client, log: *log_mod.Log, secrets, private: ?Private, stop }`; `isoWeek(day) {year, week}`; file names `day/YYYY-MM-DD.md`, `week/YYYY-Www.md`, `month/YYYY-MM.md`, a given-up period `PERIOD.given-up`.

- [ ] `days_fold_into_weeks_and_months` (fake clock: `now_s` passed in; fake model: TestEnv): a log over 2026-10-26 … 2026-12-01; passes day by day; day files with the model's text; Monday's pass folds the week (request carries that week's day summaries, 150 words); Dec 1 folds November (weeks whose Sunday is in it + Nov 30's day); a day with no turns makes no call; a silent scheduled run makes no call; `memory` lines `summary` with conversation, period, words, tokens.
- [ ] `missed_days_are_caught_up_oldest_first_at_most_7_back`.
- [ ] `a_failed_summary_is_tried_again_then_given_up`: 500 → no file, retry not before 5 min; same day success → file; failure through the day → next day's pass writes `.given-up`, logs `summary given up`, no call.
- [ ] `summaries_are_kept_60_days_weeks_400_months_always`; secrets in the log input are masked in the request. Commit.

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

(filled in as they are made; see the end of this file)
