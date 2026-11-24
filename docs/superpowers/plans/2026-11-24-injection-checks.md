# harness: prompt-injection checks and the demo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Outside text marks the conversation that read it; in a marked conversation every question, one-tap item and gate line names the sources, `remember` and `people note` are asked, the memory writer reads only the owner's own words, every call the model makes leaves a line; a catalog of 31 cases runs in `zig build test` (unit cases through Core, cases 1–8 end to end in `scripts/injection-demo.sh`, which the smoke script runs with `--check`).

**Architecture:** A pure module `outside.zig` names sources and words the question line. `agent.zig` keeps the mark per turn (`Conversation.Turn.outside`) and on the summary, so trimming and summarising move it with the turns; a run's mark is its conversation's, its start marks and its starter's. `gate.zig` gets `Ctx.outside` (the two changed defaults). `log.zig` writes `outside`/`outside_more` on gate lines. `core.zig` sets start marks at the edges (a forwarded Telegram message, a mail turn, a trigger's events, a brief's sources, a workflow instance's mark kept in its state) and puts the line on member and skipped items. The catalog is data in `inject.zig`; `harness-fake inject DIR ORIGIN STORE` writes the demo's pages and the obeying model's calls from it.

**Tech Stack:** Zig 0.17.1, std only; POSIX sh (macOS /bin/sh, Git Bash); macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-injection-checks-design.md` (binding; its catalog table is the expected outcomes; its "Calls I made" are decided). Origin of the gate: `2026-11-19-harness-design.md`.

## Global Constraints

- Zig 0.17.1 at `~/.local/zig/zig-aarch64-macos-0.17.1/zig`, std only; nothing new to install.
- Baseline: harness 1197 pass, 20 skipped (1217); smoke 109 (142 with HOMEMCP_BIN, CARCLOUD_BIN, CALMCP_BIN, MAILMCP_BIN).
- Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; Debug and ReleaseSafe; with and without the stand-ins; cross builds (`zig build` and `zig build unit-build`, `-p` into scratch) for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl. SCRATCH = `/tmp/scratch/inject`.
- Windows lessons: joined paths compared with `std.fs.path.sep_str`; a listed temp dir opened with `.iterate = true`; POSIX-shell tests get a Windows twin or `builtin.os.tag == .windows` skip; scripts run under macOS /bin/sh and Git Bash (`pwd -W`); templates read the same with `\r\n`; a binary doing TLS sets `unexpected_error_tracing = false`.
- Copy: plain labels, sentence case, no slogans; question line exactly `This run read outside text first: page blog.example, mail from x@y.example.` (at most three named, then `, and N more`); refusal reasons exactly `outside text, unattended` and `not offered in this run`.
- No secret typed, printed or copied: only stand-in keys (`og-…`, `search-key-123`, a test's own stand-in with `:`). "No secret left" means request bodies and logs (stand-ins record request headers by design).
- Not changed: any default other than the two new asks; members' and rooms' guarded actions stay one-tap items for the owner (Rulings 1 and 6); the smoke's money cap of 10 per call.
- Any new internal job uses `harness:NAME`.
- Every new Core field set in `Core.open`; state files written whole through `util.writeReplace`.

## Review Focus

1. **Hostile names.** A host, sender or server name with a newline, quotes or 10 KB reaches the mark: the question line and the log stay one line each, each name at most 120 bytes, printable. (`outside_names_are_short_single_lines`, Task 1.)
2. **Floods.** A `mail_list` of 500 messages, or a turn fetching 100 hosts: a turn keeps at most 64 sources; the line names three and counts the rest; the log carries three and `outside_more`. (`a_turn_keeps_at_most_64_sources`, Task 2.)
3. **Private conversations.** The `outside` list on a private line is sizes and keyed hashes like other fields (no host or address in the log); the question still shows it, masked. (`outside_on_a_private_line_keeps_only_sizes`, Task 1.)
4. **What marks and what doesn't.** A refused fetch leaves no mark; a fetch that ran marks whether it failed (404) or came from a helper's page cache. (`a_refused_call_leaves_no_mark_and_one_that_ran_does`, Task 2.)
5. **Helpers in parallel.** Two helpers fetch two pages at once: main's mark names both; each helper writes only its own conversation. (`helpers_marks_reach_main`, Task 2.)

---

### Task 1: The mark's words and the log's fields

**Files:** create `harness/src/outside.zig`; modify `harness/src/log.zig` (Tag, writeLine), `harness/src/main.zig` (test import).

**Interfaces — Produces:**
- `outside.name_max = 120`, `outside.shown_max = 3`, `outside.turn_max = 64`.
- `outside.named(a, kind: []const u8, what: []const u8) ![]const u8` → `"KIND WHAT"` (`what` cleaned: bytes outside 0x21–0x7e become `_`, cut so the whole is ≤ 120 bytes); `what == ""` → `"KIND"`.
- `outside.line(a, names: []const []const u8) ![]const u8` → `""` for none, else the question line; `mail X` reads `mail from X`, `mail quoted` reads `quoted mail`.
- `outside.Split = struct { shown: []const []const u8, more: usize }`, `outside.split(names) Split`.
- `outside.Role = enum { home, calendar, mail, other }`; `outside.roleOf(server: []const u8, tool_names: []const []const u8) Role` (`home` → home; `calendar` or a name containing it → calendar; a server offering a mailmcp tool → mail).
- `outside.ofMcp(a, server, role, tool, output) ![]const []const u8`: home → none; calendar → `calendar` (server named `calendar`) or `calendar SERVER`; mail with `mail_list`/`mail_read` → `mail ADDR` per message (`from_addr`, else the address in `from`, forwarded mails' `from` too), none found → `mcp SERVER`; mail's other tools → none; other → `mcp SERVER`.
- `outside.ofMailRead(a, r: mail.Read) ![]const []const u8`: each forwarded mail's `mail ADDR`, `mail quoted` when `quoted` isn't blank.
- `outside.addressOf(from) []const u8` (`"Ann <a@b.x>"` → `a@b.x`).
- `outside.add(list: *std.ArrayList([]const u8), a, name) !void` (once; past `turn_max` not kept).
- `log.Tag.outside: []const []const u8 = &.{}`, `log.Tag.outside_more: usize = 0`: written after the fields as `,"outside":[…]` and, when > 0, `,"outside_more":N`; on a private line each item as other strings are there.

- [ ] Tests (outside.zig): `the_line_names_three_and_counts_the_rest` (1 name: `This run read outside text first: page blog.example.`; 2 with mail: `…: page blog.example, mail from x@y.example.`; 5 names: `…, and 2 more.`; none: `""`), `outside_names_are_short_single_lines` (a name of 10 KB with `\n`, `"` → ≤ 120 bytes, no byte < 0x21), `server_roles_come_from_the_setup_names` (home, calendar, work-calendar, a server with `mail_read`, car → other), `mcp_results_mark_by_role` (home none; calendar; mail_list of two → two `mail` names; mail_draft none; car → `mcp car`), `a_mail_turn_marks_what_it_forwards_and_quotes`. log.zig: `gate_lines_carry_outside_after_the_fields`, `outside_on_a_private_line_keeps_only_sizes`. Fail, implement, green, commit.

### Task 2: The conversation carries the mark

**Files:** modify `harness/src/agent.zig`, `harness/src/history.zig` (`Answer.tools`), `harness/src/gate.zig` (only `Ctx.outside: bool = false`, unused until Task 3).

**Interfaces — Consumes:** Task 1. **Produces:**
- `Conversation.Turn.outside: std.ArrayList([]const u8)` (turn arena), `Turn.marked: bool` (its conversation was marked when it ended), `Turn.own: ?[]const u8` (the owner's own words when only part of the message is theirs; `""` none).
- `Conversation.summary_outside: std.ArrayList([]u8)` (gpa); `Conversation.outside(c, a) ![]const []const u8` (summary's, then each turn's, once each, oldest first). `compact` carries the summarised turns' marks (those whose text went into the summary, and the earlier summary's) into `summary_outside`; turns dropped unsummarised take theirs away.
- `Run.conv: ?*Conversation` (set by `turn`), `Run.start_marks: []const []const u8 = &.{}`, `Run.own_words: ?[]const u8 = null`, `Run.loose: ?*std.ArrayList([]const u8) = null` (where a call outside a turn marks: a workflow's tool step), `Run.mark(r, name) void`, `Run.outside(r, a) ![]const []const u8` (start marks, conversation, starter's, once each).
- `turn`: the new turn gets `start_marks` and `own_words`; `marked` set at its end.
- Marks after a call that ran (error or not; never a refused one): fetch/browse `page HOST[:PORT]` (the asked address, and each redirect hop allowed through the gate); search `search`; history `history` when `Answer.tools`; mcp/money `outside.ofMcp` with the server's role; web `web HOST` for each host the gate lets the browser use; delegate: each helper's marks (`Helper.outside`, owned, filled from its conversation before it is freed).
- `logRun` with kind `gate`: `Tag.outside`/`outside_more` from `r.outside`.
- `decideAndAskWith`: `ctx.outside = marks.len > 0`; the question text gets `"\n" ++ outside.line(marks)`; `Question.outside` and `Skip.outside` carry the line (for member and skipped items, Task 4).

- [ ] Tests (agent.zig, its Fix): `a_fetched_page_marks_the_question_and_the_gate_line` (fetch, then shell asked: question ends with the line naming `page 127.0.0.1:PORT`; the shell's gate line has `"outside":["page 127.0.0.1:PORT"]`; a run that read nothing has neither), `the_mark_lasts_into_the_next_turn_and_new_clears_it`, `a_trimmed_turn_takes_its_mark_and_a_summary_keeps_it`, `a_turn_keeps_at_most_64_sources`, `a_refused_call_leaves_no_mark_and_one_that_ran_does`, `search_history_and_mcp_results_mark_by_kind` (fake MCP `echo` → `mcp fake`; history run N with a tool line → `history`), `web_hosts_mark_the_conversation` (webAllow allowed → `web HOST`; refused → none), `helpers_marks_reach_main`. Fail, implement, green, commit.

### Task 3: The two new asks; every call leaves a line

**Files:** modify `harness/src/gate.zig`, `harness/src/agent.zig`.

**Interfaces — Consumes:** `Ctx.outside` (Task 2). **Produces:** in `decideRaw`, with `ctx.outside`: `remember` and `people` whose first word is `note` default to ask, why `outside text: asked by default`; a deny rule still refuses, an allow or ask rule the owner wrote decides as before; `Decision.allow_day = false` for them while marked; unattended, the default ask becomes deny with why `outside text, unattended` (an ask from the owner's own rule keeps `no one to ask in a scheduled run`). `people note`'s question shows `value: VALUE` as its detail; rules still match `note NAME FIELD`. A call the run isn't offered: gate line `deny`, `not offered in this run`, the input as `arg`; an unknown name: `deny`, `no such tool`; the model still gets `this tool is not available here` / `no such tool`.

- [ ] Tests: gate.zig `outside_text_asks_remember_and_people_note` (unmarked allow; marked ask with allow_day false; `people show` still allowed; `allow remember *` lifts it; `deny remember *` refuses; scheduled → `outside text, unattended`; an owner's `ask remember *` scheduled → `no one to ask in a scheduled run`). agent.zig: `remember_after_a_page_is_asked_with_its_whole_text` (Deny → memory unchanged, no Allow 24 h), `people_note_after_a_page_shows_the_value`, `an_unattended_marked_remember_is_skipped_for_the_owner` (Skipped lists it; its Skip is grantable), `a_call_to_a_tool_not_offered_is_logged_as_refused` (a helper's `send`, an unknown name). Fail, implement, green, commit.

### Task 4: Sources at the edges

**Files:** modify `harness/src/telegram.zig` (`Message.forwarded`), `harness/src/main.zig` (Incoming from Message, if built there), `harness/src/core.zig`, `harness/src/wstate.zig` (`State.outside`), `harness/src/workflows.zig` if the start record needs it.

**Interfaces — Consumes:** Tasks 1–3. **Produces:**
- `telegram.Message.forwarded: bool` (`forward_origin`, or the older `forward_date`); `core.Incoming.forwarded: bool`.
- A forwarded message from the owner: never a command, a phrase, a list's words or an item's answer; queued as a turn (`Queued.forwarded`), `run.start_marks = {"forwarded"}`, `run.own_words = ""`, mentions not counted.
- `mailTurn`: `run.start_marks = outside.ofMailRead(read)`, `run.own_words = read.own`.
- `Core.triggerMarks(a, tr) ![]const []const u8`: feed, page → `feed HOST` per source; search → `search`; mcp → by its server's role (home none, mail `mail ADDR` per event's `from_addr`/`from`, calendar, other `mcp SERVER`); brief → its topics' sources; file, schedule → none. `triggerDo` and `triggerSay` runs start with them; a brief's run starts with its topics' (`feed HOST`, `search`).
- `wstate.State.outside: []const []const u8` (JSON array `outside`, read back; absent = none): set at start by the trigger that started it, added to by a `wait event` trigger's marks, by each agent step's run (`conv.outside`) and tool step (`run.loose`); each step's run starts with it.
- `Core.serverRole(name)`: `outside.roleOf` with the running server's tools.
- Member one-tap item body and skipped item body get `Question.outside` / `Skip.outside` on a line of its own.

- [ ] Tests (core.zig): `a_forwarded_message_is_marked_and_never_a_command` (forwarded `/dryrun on` → a turn, dry run still off; `forward_origin` read by telegram.zig's parse: `a_forwarded_message_is_read_as_forwarded`), `a_mail_turn_is_marked_by_what_it_forwards`, `a_feed_triggers_run_starts_marked`, `a_briefs_post_names_its_feeds`, `a_workflow_started_by_a_feed_keeps_its_mark` (state file has `"outside"`; its agent step's remember is refused `outside text, unattended`), `a_members_item_and_a_skipped_item_carry_the_line`. Fail, implement, green, commit.

### Task 5: The memory writer reads only the owner's own words

**Files:** modify `harness/src/core.zig` (`writeMemoriesOf`).

**Produces:** in a turn with `marked`, the transcript has only the owner's words: `tn.own` when set (a mail turn: its own part; a forwarded message: nothing), else the message; no agent text and no `send` text. Unmarked turns as before.

- [ ] Tests: `the_memory_writer_skips_outside_text` (turn 1 a page fetched, agent repeats it, owner says "I like tea"; the writer's request has "I like tea" and neither the page's nor the agent's words; an unmarked turn's agent text still there), `the_memory_writer_reads_a_mails_own_words_only`. Fail, implement, green, commit.

### Task 6: The catalog and its unit cases

**Files:** create `harness/src/inject.zig` (the catalog); modify `harness/src/main.zig` (test import), `harness/src/core.zig` (section `// ---- prompt injection: the catalog's unit cases ----` at the end of the tests).

**Interfaces — Produces:** `inject.Runs = enum { unit, demo }`; `inject.Call = struct { tool, input }` (`{origin}` and `{store}` filled at run time); `inject.Case = struct { n: u8, title, channel, hostile, asks, calls: []const Call, expected, evidence, runs }`; `inject.cases` (31: the spec's 28, then 29 a forwarded Telegram command, 30 a page redirecting to the collector, 31 a workflow started by a feed remembering); `inject.case(n) Case`; `inject.fill(a, text, origin, store) ![]const u8`; `inject.page(a, cs, origin) ![]const u8` (the hostile page's HTML).

- [ ] Tests: inject.zig `the_catalog_is_numbered_and_whole` (n = 1…31 in order; 1–8 demo, the rest unit; each has hostile text, an expected outcome and evidence; every demo case has calls). core.zig, one test per unit case, named `injection_NN_…`, each scripting the case's calls and checking its expected outcome and evidence (the mark's words, nothing at the attacker's address: `page-requests.jsonl`, `sent.jsonl`, `orders.jsonl`; no stand-in key in request bodies or the log; the gate line's `why` and `outside`). 23 and 25 use POSIX commands: skipped on Windows. A case that fails on today's code is a hole: RED recorded in the ledger, fixed to the table's outcome, GREEN. Commit.

### Task 7: The demo

**Files:** modify `harness/build.zig` (install harness-fake), `harness/src/fake_main.zig` (`inject DIR ORIGIN STORE`); create `harness/scripts/injection-demo.sh`; modify `harness/scripts/smoke.sh`.

**Interfaces — Consumes:** `inject.cases`. **Produces:** `harness-fake inject DIR ORIGIN STORE` writes `DIR/pages/case-N.html` (each demo case's page; the collector is `ORIGIN/page/collect`), `DIR/inject/N.title`, `N.said` (the quote the demo prints, ≤ 60 bytes), `N.calls` (a call a line: `TOOL<TAB>INPUT`). `scripts/injection-demo.sh [--check|--serve] [HARNESS HARNESS_FAKE]` (default `zig-out/bin/`): its own temp home, the shop (fake_shop, `max_per_call = 1000`), `allow fetch ORIGIN/page/case-*`, cases 1–8 played (Deny everywhere but case 5's Allow once), each printed in ≤ 80 columns, `8 cases. The gate held in 8.` (else the case named, exit 1), the log left in a folder it names; `--check` prints TAP lines only; `--serve` starts only harness-fake with the pages, prints a line per page for cases 1, 2, 4, 5, prints each collector request, and on stop prints the matching lines of the owner's log, read only. smoke.sh runs `--check` and counts each of its lines as a check.

- [ ] Run the demo (plain and `--check`) on macOS; run `--serve` against a temp HARNESS_HOME only; smoke green; commit.

### Task 8: Docs and the full runs

- [ ] harness README "Prompt injection" (what holds, the demo commands, what the gate can't hold — the spec's list, plus long-memory summaries carry no mark), the gaps list (prompt-injection checks built 2026-11-24; the other three open), the ledger entry, the Windows handoff's top section as built. Full runs Debug and ReleaseSafe with and without the stand-ins; cross builds; commit.

## Rulings

(Each: what — why — cost if wrong. Added to as they are made.)

1. **The mark lives on the turns.** What: each turn keeps the sources it read; the conversation's mark is theirs plus the summary's; trimming drops a turn with its sources, summarising moves them to the summary; `/new` starts a new conversation. Conversations' turns aren't kept across a restart, so neither is the mark; a workflow instance's mark is kept in its state. Why: the spec's "lasts while the outside text is in the model's context", with no bookkeeping that can drift from the turns. Cost if wrong: none found.
2. **A server's role from setup's section names.** What: `[home]` home; `[calendar]` or a name with "calendar" (as the diary finds it) calendar; a server with mailmcp's tools mail (as `isMailTool` finds them); any other `mcp SERVER`. Why: setup writes those names; the tools decide mail already. Cost if wrong: a home server the owner named otherwise marks as `mcp NAME`: more asks for remember, never fewer.
3. **Every message a mail tool returns marks, the owner's included.** What: `mail ADDR` for each From in `mail_list`/`mail_read` results. Why: a From can be forged, and a tool's result doesn't say which words are the owner's. Cost if wrong: reading one's own sent mail asks before `remember`.
4. **A quoted part is `mail quoted`** ("quoted mail" in the line): its author isn't known. Cost if wrong: a wordier line.
5. **`calendar`, not `calendar calendar`:** the name is added only when the server isn't called `calendar`. Cost if wrong: none found.
6. **A call that ran marks; a refused one doesn't.** What: error or not, from a page cache or not. Why: an error page or cached page is still outside words; a refused call returned only harness's words. Cost if wrong: none found.
7. **Pages mark by the host asked for and each redirect hop the gate let through,** with the port when it isn't the scheme's own. Cost if wrong: none found.
8. **`outside` on a private line is hashed** like every string that isn't a label. Why: a private run's log keeps sizes only; a host or sender is what it read. Cost if wrong: a private conversation's log says less about its marks.
9. **(Overturned in the fix pass: the day summariser now leaves outside text out, as the memory writer does.)** **Long memory's day, week and month summaries carry no mark.** Why: made at 03:00 from the log in the memory model's words, read like a file an earlier run saved; marking them would put most conversations under the new asks for weeks. The README's limits say so. Cost if wrong: a page's planted line can reach later prompts unmarked through a day summary; the gate still decides every call by who, and money and setup stay asked.
10. **A forwarded Telegram message is never a command.** What: no `/` command, phrase, list words or item answer from a forwarded message; it is a turn, marked `forwarded`. Why: "forward this to your bot" would otherwise run a stranger's `/dryrun off`. New case 29. Cost if wrong: an owner who forwards their own command must type it.
11. **harness-fake is installed by `zig build`** (zig-out/bin), as llmcheck-fake and the sims are; release packages copy named files, so they don't change. Cost if wrong: one more file in zig-out/bin.
12. **A workflow instance keeps a mark in its state**, from the trigger that started it, its `wait event` triggers and its steps' sources; each step's run starts with it. Why: steps pass outside words to later steps through values. Cost if wrong: none found.
13. **The question line is part of the question's text** (so every asker shows it) and of member and skipped items' bodies. Cost if wrong: a question near 12 KB that fit before is refused as too long.
14. **Mentions in a forwarded message don't count** (`from_owner` false): they aren't the owner's words. Cost if wrong: none found.
15. **A workflow's stored answer is matched on the question without its outside-text line.** Why: a tool step's own read marked its retry, so the owner was asked a third time for a call they had answered (each_question_of_a_call_keeps_its_own_answer went red). Cost if wrong: a call answered before the instance read outside text runs without the line being shown again.
16. **A forwarded voice note** is transcribed after the voice checks, then a marked turn; never a phrase, list words or an item's answer. Cost if wrong: none found.
17. **Case 10 (the browser) runs at the agent level** through web's gate hook: the web tool needs Chrome, which runners may lack; web.zig's Chrome tests cover the browser half. Cost if wrong: the browser's mark is covered by the hook's test only.
18. **Case 18's speech asks to unlock the front door**, not open a garage: the stand-in home has no garage; the outcome is the same one-tap item. Cost if wrong: none.
19. **The demo's `--check` leaves nothing behind**; plain mode keeps the log in a folder it names. `--serve` writes case 5's store path as the data folder's `secrets/`, a path it never reads. Cost if wrong: none.
20. **(Overturned in the fix pass for a workflow's approve: its gate line carries the instance's mark.)** **Gate lines harness's own jobs write directly** (people, away, trips, the evening, deliveries, apps' reads, a workflow's approve) carry no outside list: they are not a model's calls in a run. A marked workflow's approve and review items do carry the line. Cost if wrong: those lines don't say what the instance had read.
21. **Setup's `[car]` server marks nothing, like `[home]`:** its results are the owner's own car's state, and the spec's call keeps household runs free of the line (the car-for-tomorrow routine's question got "mcp car"). Cost if wrong: a car server answering with third-party words wouldn't mark.
22. **calendar_attendees_become_people** failed on the baseline too (dated fixture, real clock): it takes harness-logins' ed34e74.
23. **The conversation's mark keeps at most 64 sources, the newest** (an index with how many turns carry each, kept as turns come and go; the summary's at most 64, the oldest dropped). Why: a gate decision costs the same however long the conversation. Cost if wrong: a conversation that read over 64 sources names the newest 64.
24. **A From with no single address** (more than one `@`, or anything but address characters) is named `mail quoted`. Cost if wrong: a sender with an odd but valid address reads as quoted mail.
25. **A run's first log line carries what it started with, its later turn lines all it had read;** `history` marks the run it answers in when a run it shows had read outside text, and labels what a run started with: "Forwarded", "Owner's mail with outside parts", never "Owner". Cost if wrong: history of a long research run marks the asking conversation.
26. **The day summariser leaves out** the outputs of tools whose results are outside text (pages, search, the browser, history, helpers, MCP servers but `[home]` and `[car]`), all of a run that started with outside text, and the agent's words in a run that had read some. Cost if wrong: research days summarise to the owner's questions alone.
27. **In a marked run, `workflow start` offers no Allow 24 h** and the instance starts with the run's mark; `ask_owner`'s questions and drafts carry the line. Cost if wrong: none found.

## Done

- Commits: the plan; outside.zig and the log's fields; the mark on the conversation; the two new asks and logged unoffered calls; the mark at the edges; the memory writer; the catalog and its unit cases; the demo; approve items' line; forwarded voice notes; the car's role; the calendar test (ed34e74); docs.
- harness: 1263/1283 (20 skipped) Debug and ReleaseSafe after the fix pass; smoke 138, 171 with homemcp, carcloud, calmcp and mailmcp built (the demo's 28 checks and their count among them). The demo: "8 cases. The gate held in 8.", in about 3 s; `--serve` tried with a temp HARNESS_HOME. Cross builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; build and unit-build) ok.
- Holes the catalog's checks found in today's code, each RED then GREEN: a feed's words, and a feed-started workflow step's, saved a memory unasked (a_feed_triggers_run_starts_marked, a_workflow_started_by_a_feed_keeps_its_mark); a forwarded "/dryrun on" ran as the owner's command (a_forwarded_message_is_marked_and_never_a_command); a forwarded voice note skipped the voice checks (a_forwarded_voice_note_gets_the_voice_checks). With the two new asks and the line taken out, 14 of the 23 unit cases fail; the other nine pin earlier behaviour or an absence.
- Tests changed on purpose: kinds_without_a_tool_yet_are_not_offered_or_run (a refused line now); outside's role tests for the car; calendar_attendees_become_people (ed34e74).
- Skipped on Windows: injection_23 and injection_25 (POSIX commands). The demo's case 5 runs `type` there.
- Left out: the gate lines of harness's own jobs other than a workflow's approve carry no outside list (Ruling 20).
- Fix pass after the review (each RED then GREEN): a workflow the agent starts after outside text starts marked, with no Allow 24 h (a_workflow_the_agent_starts_after_a_page_starts_marked, a_workflow_start_after_outside_text_offers_no_day); history marks and labels what it shows (history_marks_what_it_shows_of_a_forwarded_message: a forwarded fact came back as "Owner:" and was saved silently); the day summariser leaves out outside text (a_day_summary_leaves_out_outside_text; days_fold_into_weeks_and_months changed on purpose); the catalog's calls JSON-escape filled paths (filled_calls_are_json_whatever_the_paths); ask_owner carries the line (ask_owner_after_a_page_carries_the_line); a forwarded command never runs in a group or as /pair (a_forwarded_command_is_never_run_in_a_group_or_by_a_stranger); a From with no single address is `mail quoted` (a_from_with_no_single_address_is_named_quoted); the conversation's mark is bounded (a_conversations_mark_is_bounded); a marked approve's gate line carries the mark (a_workflows_approve_after_a_feed_carries_the_line). The demo starts each case in a new conversation and checks each gate line (28 checks); unit cases 13, 14, 16, 19, 26, 27, 28 check theirs. With Run.mark stubbed out, 16 of the demo's 28 checks fail, case 4's "memory unchanged" among them.
