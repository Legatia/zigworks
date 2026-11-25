# harness: automation moves money within a budget — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unattended runs (schedules, triggers, workflows' agent steps, the reorder as `harness:reorder`) may make money calls without asking when a budget for automation is set (`[money] budget_per_day`/`budget_per_month`, or a server's own in mcp.ini), the call names an amount within the caps and the budget, spending isn't paused and the run read no outside text but the paying server's own; everything else unattended is refused and kept as a skipped item with [Make this payment]; each automated spend is told in main with [Pause automation spending]; `/money`, `/money budget`, `/money pause|resume`; old installs that spent get a budget from `max_per_day`.

**Architecture:** Pure logic in a new `money.zig` (budget resolution, month numbers, amounts as text, the told line, `/money`'s text, budget words, the upgrade's file edits). The ledger and the decision stay where the spec points: `agent.zig`'s `MoneyLedger` (three new record kinds, each its own first word and its own 64 slots) and `moneyCheck` (an unattended branch, run before the gate, which gets `money_unattended` only when the budget passed). `core.zig` gets a `Money` namespace (as `Persona`, `Topics`): the told line and its button (`p`), `/money`, pause kept in `state/money-paused`, the upgrade (`state/upgrades/money-budget`), setup's budget question; skipped items get the whole call and [Make this payment] (a `PayGo` asker, as `OrderGo`); the reorder orders within the budget. Small local edits: `config.zig` (keys, switch defaults), `mcp.zig` (per-server keys), `gate.zig` (the allow's why), `inject.zig` (case 33).

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-money-budget-and-sandbox-default-design.md`, **Part 1 only** (binding: "What changes" 1–10, Setup, Constraints, "Tests, Part 1", "Tests that change on purpose", "Calls I made"). Also: `2026-11-24-harness-injection-checks-design.md` (the outside-text mark; a new catalog case). Part 2 (the sandbox default) is the Windows session's: no edits to `environments.zig` or `sandbox.zig`.

## Global Constraints

- Zig 0.17.1, std only. Copy (CLAUDE.md): plain labels, sentence case, no slogans. The told line is the spec's: `Spent 12.50 on shop/order for the weekly-groceries task. Today 12.50 of 30; this month 40 of 200.` Buttons: `Make this payment`, `Pause automation spending`. Setup's question: "How much may routines spend without asking you, a day and a month?" with `None`, `Set an amount`, `Like this: 30 a day, 200 a month`.
- Money stays the strictest path: every unattended money decision is logged with the budget's numbers; the ledger is written whole (`util.writeReplace`); a ledger that can't be read or saved refuses money calls (today's rule); check and count under the ledger's one lock.
- Never unattended, whatever the budget: a money tool with no amount (`amount = …:none`, or none set), e.g. `home_guarded`; `mail_send` (the gate's mail check comes first and stays first: moneyCheck lets it through to the gate unreserved).
- Apps aren't unattended: `[money] apps` and app runs unchanged; no budget applies to them. Workflow tool steps stay asked (they aren't unattended runs).
- Defaults: `scheduled`, `triggers`, `workflows` on; `apps` off; budgets 0. mcp.ini `budget_per_day`/`budget_per_month`: a whole number, or `none` (automation spends nothing at that server); `0` refused like the caps; needs a `money =` line.
- Windows: joined paths with `sep_str`/`std.fs.path.join`, built the way the product builds them; listed dirs opened `.iterate = true`; text read the same with `\r\n`; no test reads the real clock where a fixture holds times (`fixed_now`).
- Secrets never typed, printed or copied; stand-in keys only. Others work on harness-logins at the same time: edits to shared files small and local.
- Baseline (75a5f48): 1427 pass, 22 skipped of 1449 (Debug); smoke 148 ok (181 with HOMEMCP_BIN, CARCLOUD_BIN, CALMCP_BIN, MAILMCP_BIN). From `harness/`: `zig build test --summary all --cache-dir $SCRATCH/cache > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; Debug and ReleaseSafe; cross builds `zig build` and `unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl.

## Review Focus

1. **Two unattended runs racing one budget** (25 of 30 spent, two calls of 10 at once): only one passes; the check and the count are one step under the ledger lock (`two_calls_cannot_both_pass_the_budget`, Task 3).
2. **The month's lines outlasting the daily slots**: 64 servers' day lines fill the day slots; the month line of a 65th day's spend is still kept, read back, and a new month starts at 0 (`month_lines_are_kept_apart_from_the_day_slots`, Task 2).
3. **[Make this payment] after the rules changed** (a cap lowered, a deny line added since): the tap makes the call through moneyCheck and the gate again, so it's refused with the reason and nothing is paid; a second tap answers nothing (`make_this_payment_makes_exactly_that_call_as_the_owner`, Task 4).
4. **Dry run on during an unattended spend within the budget**: nothing called, nothing counted toward the budget, no told line (`dry_run_spends_nothing_unattended_and_tells_nothing`, Task 5).
5. **An old install whose config.ini says `scheduled = off`** (as the old init wrote it): stays off; `/money budget` says the switch keeps routines from spending, and `/money` shows it (`money_budget_writes_config_and_reloads`, Task 5); an install with no `scheduled` line and a cap is not upgraded into spending (`an_install_that_spent_gets_a_budget_from_max_per_day_once`, Task 7).

---

### Task 1: Keys — `[money]` budgets, switch defaults, mcp.ini per-server budgets

**Files:** `config.zig` (Money, defaults_ini, tests), `mcp.zig` (ServerConfig, parseConfig, configReason, tests), `agent.zig` (McpTool fields, mcpTools copies them).

**Produces:** `config.Config.Money.budget_per_day: u32 = 0`, `.budget_per_month: u32 = 0`; `.scheduled = true`, `.triggers = true`, `.workflows = true`. `mcp.ServerConfig.budget_per_day: ?u32 = null`, `.budget_per_month: ?u32 = null` (0 = `none`); `error.ZeroBudget` (reason: "budget_per_day = 0 says nothing clear: write none (automation spends nothing at this server), or remove the line to use config.ini's"). `agent.McpTool.budget_per_day/budget_per_month: ?u32 = null`.

- [ ] Tests changed on purpose: config `agents_browser_and_money_sections` (~1165: `d.money.scheduled` now true; budgets 0), `trigger_and_money_settings_read` (~1378), `workflow_settings_read` (~1396); the `expectEqualDeep(d.money, defaults_ini)` lines follow (defaults_ini says `scheduled = on`, `triggers = on`, `workflows = on`, `budget_per_day = 0`, `budget_per_month = 0`). New: config `budgets_are_read_from_money`; mcp `parse_config_takes_budgets_per_server` (`none` → 0, `0` → ZeroBudget, a budget without `money =` → BadConfig, twice → BadConfig).
- [ ] Fail, implement, green, commit.

### Task 2: The ledger's new lines

**Files:** `agent.zig` (MoneyLedger, Reservation, tests).

**Produces:** record kinds, a line each, their own first word (no server name has `:`): `auto:day SERVER DAY TOTAL`, `auto:month SERVER MONTH TOTAL`, `all:month SERVER MONTH TOTAL`; today's `SERVER DAY TOTAL` and `DAY TOTAL` unchanged. Each kind has its own 64 slots. `money.monthOf(day: i64) i64` (year × 12 + month − 1, the owner's day). `MoneyLedger.spentAuto(server, day) f64`, `spentAutoMonth(server, month) f64`, `spentMonth(server, month) f64`. `reserve(io, server, day, amount, auto: bool) !Reservation` (`Reservation{ day, month, amount, auto }`), counting the day, the month and (auto) the automation day and month in one save; `release` takes all back. `save(io, today)` keeps day lines of today and later, month lines of this month and later.

- [ ] Tests: `money_ledger_keeps_a_total_per_server_and_reads_the_old_file` unchanged; new `the_ledger_keeps_automations_day_and_month_apart` (owner's 5 and automation's 7 on one day: day 12, auto day 7, month 12, auto month 7; read back; released; a file with only today's three-field lines reads as today; an unknown first word with 4 fields is damage), `month_lines_are_kept_apart_from_the_day_slots`.
- [ ] Fail, implement, green, commit.

### Task 3: moneyCheck's unattended branch

**Files:** `agent.zig` (moneyCheck, callToolRaw, decideAndAskWith/AskExtra, Switches, tests), `gate.zig` (the allow's why), `money.zig` (create: `Budget`, `budgetFor`, `amountText`), `main.zig` (test import).

**Produces:** `agent.Switches.money_paused: std.atomic.Value(bool)`. `money.Budget = struct { day: u32 = 0, month: u32 = 0, none: bool = false }` and `money.budgetFor(cfg: config.Config.Money, day: ?u32, month: ?u32) Budget` (a server's key wins per key; its 0 is `none`). `money.amountText(a, f64) ![]const u8` ("40", "12.50").

Unattended (`r.scheduled`) money call, in order, each refusal with its reason:
1. `mail_send`: let through unreserved (the gate refuses it).
2. `harness:` other than `harness:reorder`: refused.
3. switches: `scheduled`; and `triggers` for `trigger:`, `workflows` for `workflow:` agent steps (moved here from callToolRaw, same reasons).
4. no amount field (`.none`, `.unset`): "a money tool that names no amount is never used unattended".
5. paused: "automation spending is paused (/money resume)".
6. outside text: any mark other than `mcp SERVER` of the paying server: "it read outside text first (…), and outside text doesn't spend".
7. budget: `none` at the server; no budget above 0: "no budget for automation: /money budget N a day sets one".
8. the amount (as today), `max_per_call`, `max_per_day` (all spending), then the budget: "N more would be over the budget of B a day for automation (S so far today)", and the month's.
9. reserved with `auto = true`; the gate gets `money_unattended = true` (its why: "within the budget for automation: today S of B; this month M of N").
A refusal's gate line has `budget` with the numbers. Attended money calls are as today (counted with `auto = false`). Unattended no longer needs a cap.

- [ ] Tests changed on purpose: agent `money_in_scheduled_runs_only_when_switched_on` (default switch on: "no budget"; with a budget it spends), `unattended_money_needs_a_cap` → `unattended_money_needs_a_budget`, `none_in_a_servers_section_lifts_config_inis_cap_and_says_so` (its second half: no budget), `money_in_trigger_runs_is_refused_while_triggers_is_off` and `money_in_agent_steps_is_refused_while_workflows_is_off` (fixtures `.triggers = false` / `.workflows = false` and a budget); fixtures building `Money` with false switches get explicit values. gate `money_ignores_grants_and_allow_rules_and_is_refused_unattended` holds.
- [ ] New agent tests: `no_budget_refuses_unattended_money`, `a_budget_spends_within_it_and_refuses_past_it_per_day_and_month`, `a_servers_budget_overrides_money_sections_and_none_spends_nothing`, `the_owners_spending_counts_only_toward_max_per_day`, `a_money_tool_with_no_amount_is_never_unattended`, `outside_text_doesnt_spend_but_the_servers_own_results_do`, `paused_automation_spends_nothing`, `two_calls_cannot_both_pass_the_budget`, `harness_jobs_but_the_reorder_move_no_money`; money `budgets_resolve_per_key_and_none`, `amounts_read_plainly`.
- [ ] Fail, implement, green, commit.

### Task 4: Skipped money items and [Make this payment]

**Files:** `agent.zig` (Skip `why`, `payable`; the refusal path calls `skip`), `core.zig` (keepSkip, answerItem `pay`, PayGo, payJob, tests).

- A refused unattended money call (Task 3's refusals but 1, 2, 4) is a skipped item: body `NAME: SERVER/TOOL {json}`, then `Amount: X`, then `Not paid: WHY.`, then the outside line; its skip key the whole call (`BY\tmoney\tSERVER/TOOL {json}`), so each payment is its own item; choices [Make this payment] (`pay`, only when the masked call is the call) and [Dismiss]. A no-amount tool's (door unlock) and `mail_send`'s items: Dismiss only.
- `pay`: the call taken from the item (settling), the item closed, then on a thread of its own: a run as the owner (built-in main), its asker `PayGo` allowing that exact call once, through `agent.stepCall` (moneyCheck: caps, the owner's day; the gate: deny lines; dry run). Said in the item's conversation: "Paid: NAME {json}. The server says: …" or "Not paid: WHY."

- [ ] Tests: core `make_this_payment_makes_exactly_that_call_as_the_owner` (a task with no budget skips a shop order: the item shows the call, the amount, the reason and both buttons; the tap orders exactly that once, counted as the owner's; with the cap lowered since, a second such item's tap is refused and nothing is ordered), `no_amount_tools_and_mail_send_are_never_unattended` (a budget set; a task's `home_guarded` unlock and `mail_send`: refused, the mail one by the gate's own line, items with Dismiss only).
- [ ] Fail, implement, green, commit.

### Task 5: Telling, pausing and `/money`

**Files:** `agent.zig` (`Run.spend: ?SpendDesk`, called after an unattended money call was sent), `core.zig` (`Money` namespace: `told`, `press`, `command`, pause load/save; baseRun; handleCallbackText `p`; commandIn `/money`; help line), `money.zig` (`Spent`, `toldLine`, `ranFor`, `parseBudget`, `statusText`).

**Produces:** `agent.SpendDesk = struct { ctx, told: *const fn (ctx, Spent) void }`; `money.Spent = struct { server, tool, by, amount: f64, day_spent: f64, month_spent: f64, budget: Budget, failed: bool }`; `money.toldLine(a, Spent)`; `money.ranFor(a, by)` ("the NAME task", "the NAME trigger", "the NAME workflow", "the reorder"); `money.parseBudget(words) ?struct { n: u32, period: enum { day, month } }` ("30 a day", "200 a month"); `money.statusText(a, View)`.

- Told line: main, with sound, never held (said directly, not through a run's post); button `Pause automation spending` (data `p`). "The server said it failed." added when the call came back an error (it stays counted).
- `p`, or `/money pause`: `state/money-paused` written (a failed write is said: paused until harness stops); `/money resume` removes it. Read at open; unreadable reads as paused.
- `/money`: caps, budgets ([money]'s and each server's own), today and this month per server by you and by routines, the switches, paused or not. `/money budget N a day|a month`: `[money]` written (mail.setKey), applied (applySetup); the reply says when `scheduled` (or a switch) keeps routines from spending. Only in the owner's own conversations (a shared one: refused, said).

- [ ] Tests: core `an_automated_spend_is_told_in_main_with_a_pause_button` (a task within the budget: the line exactly as the spec's shape, in main, in quiet hours too; the button pauses: the next try refused and kept as a skipped item), `money_pause_and_resume_are_kept_across_restarts`, `money_shows_the_caps_budgets_spending_and_switches`, `money_budget_writes_config_and_reloads` (and `scheduled = off` said; in a shared conversation refused), `dry_run_spends_nothing_unattended_and_tells_nothing`; money `the_told_line_reads_as_the_spec`, `budget_words_read`.
- [ ] Fail, implement, green, commit.

### Task 6: The reorder spends within the budget

**Files:** `core.zig` (Errands.propose → `orderWithin`; `/setup reorder`'s reply; tests).

- With a budget for the shop and `scheduled` on and not paused: after the quote, the order is placed by a run `harness:reorder` (unattended, built-in main, no asker, no skipped keeper) through `agent.stepCall` (moneyCheck and the gate); told (Task 5's line) and "Ordered from Frisco: N items, TOTAL; off LIST. The shop says: …"; what was ordered comes off the list. Refused (over the budget or a cap): proposed for the tap as today, "Not ordered on its own: WHY." first in the body. No budget: proposed as today. Dry run: said, nothing proposed.
- `/setup reorder`'s on-text: unchanged when no budget applies; with one: "Within your budget for routines I order it and tell you; over it, nothing is bought until you tap Order it."

- [ ] Tests: `a_reorder_is_bought_only_on_the_owners_tap` holds (no budget); new `the_reorder_orders_within_the_budget_and_proposes_over_it`.
- [ ] Fail, implement, green, commit.

### Task 7: Old installs, and setup's budget question

**Files:** `core.zig` (`Money.upgrade` at open after the ledger, before servers start; `Money.offer`/`answer`; setupAnswer `budget SHOP`), `money.zig` (`upgradeTexts`).

- Upgrade, once (`state/upgrades/money-budget`): config.ini's `[money]` says `scheduled = on` (the file's own line, not the default) and has no budget key: `budget_per_day = max_per_day` written there when `max_per_day > 0`; each mcp.ini money section with its own `max_per_day` N and no budget key gets `budget_per_day = N`. Said once at the first attach (sayAtStart): what was set, `/money` and `/money pause`; with no day cap anywhere: routines no longer spend until a budget is set.
- Setup: `/setup reorder SHOP` (the one setup that connects a money server with an amount), when no budget applies to the shop and `state/setup/budget-SHOP` isn't there: an item with the spec's question and three buttons, a text reply too ("50 a day, 300 a month"). None: nothing written; Set an amount: the commands said; Like this: `[money]` 30 a day, 200 a month; a reply: what it names. The marker is written on any answer.

- [ ] Tests: core `an_install_that_spent_gets_a_budget_from_max_per_day_once` (also: a file with no `scheduled` line and a cap: nothing; a restart: said once), `setup_reorder_asks_once_how_much_routines_may_spend`; money `upgrade_texts_set_the_budget_where_the_cap_is`.
- [ ] Fail, implement, green, commit.

### Task 8: Injection case 33

**Files:** `inject.zig` (case 33; `the_catalog_is_numbered_and_whole` counts 33), `core.zig` (`injection_33_a_feed_asks_a_trigger_run_to_pay`).

- Case 33: a feed item tells an unattended trigger run to pay (a shop order within the budget and the caps): refused, whatever the budget, as outside text; a skipped item with [Make this payment]; nothing reached the shop; the gate line names the feed. Case 6 unchanged (the demo).

- [ ] Fail, implement, green, commit.

### Task 9: Docs, smoke, full runs, merge

- [ ] README: Money (budgets, per server, what counts where, never unattended, outside text doesn't spend, [Make this payment], the told line, `/money`, pause, upgrade); Reorders; the injection section's limit line; config comments. Gaps list: Part 1 built. Ledger: one entry. HANDOFF-windows-platform.md: a note under "For you: the owner answered question 3" on what Part 1 changed in shared code.
- [ ] smoke.sh: one block (`/money` over the fake: no budget; `/money budget 30 a day`; `/money pause`, `/money resume`).
- [ ] Full runs Debug and ReleaseSafe, with and without stand-ins; cross builds; Done section; commit.
- [ ] Fetch, merge `origin/harness-logins`, resolve keeping both, full runs again, commit.

## Rulings

(Each: what — why — cost if wrong. Added to as they are made.)

1. "Automated spending" is money moved without the owner's answer (an unattended call within the budget); anything the owner approved (a question, a workflow tool step, [Order it], [Make this payment]) is the owner's and counts only toward `max_per_day` — the spec's "the owner's own spending" — cost if wrong: an approved tool step doesn't use up the budget.
2. The budget replaces the cap as what unattended money needs; the caps still apply when set — "Automation spends only when a budget above 0 is set", and the spec's conditions name no cap — cost if wrong: an install with a budget and no caps spends up to the budget per call.
3. A server's `none` on either budget key means nothing spends there unattended; keys override `[money]` one by one, as the caps do — the spec's "none there means automation spends nothing at that server" — cost if wrong: a server with only `budget_per_day = none` can't use `[money]`'s month.
4. New ledger lines take first words `auto:day`, `auto:month`, `all:month` (no server name has `:`), with 64 slots per kind; `all:month` (every spending) is added so `/money` can show the owner's month — cost if wrong: a binary from before this change reads a new file as damaged and refuses money (the safe side) after a downgrade.
5. Every unattended money refusal from moneyCheck is a skipped item; [Make this payment] is offered for all but the never-unattended tools (no amount, `mail_send`) and `harness:` jobs, whose items offer Dismiss only — point 5's list (marked, no budget, over, paused) extended to switch-off and the caps, as "Anything else is refused, and becomes a skipped item with [Make this payment]" says — cost if wrong: a switch-off refusal invites a tap the owner meant to forbid (it's still the owner's own, asked-once call).
6. The skipped key of a payable money item is the whole call, so two payments are two items — "makes exactly that call" — cost if wrong: a trigger that keeps trying different amounts fills the inbox (bounded by its 200 open items).
7. The [Pause automation spending] button carries plain data `p` (no per-start token): it only stops spending, and only the owner's presses reach it — cost if wrong: an old message's button still pauses.
8. Pause is kept in its own file `state/money-paused` (present = paused; unreadable = paused) rather than `state/switches`, whose writes are best effort — cost if wrong: one more file in state.
9. The upgrade reads config.ini's own `scheduled = on` line, not the parsed value, since the default is on now; the budget goes where the day cap is (`[money]`, or a server's own section) — cost if wrong: an install that set `scheduled = on` and only per-call caps stops spending (it's told how to set a budget).
10. An install whose config.ini says `scheduled = off` (the old init wrote that line) keeps it; `/money budget` says the switch keeps routines from spending — an owner's line is never changed — cost if wrong: such owners edit one line before their budget applies.
11. Setup's budget question is asked in `/setup reorder SHOP` (the only setup that connects a money server with an amount: home's, mail's and the calendar's money tools name none and never spend unattended), once per shop; its answers write `[money]` — cost if wrong: a money server added by hand is never asked about.
12. The reorder's own line follows the told line (two messages) — the told line is the same for every automated spend; the reorder's says what came off the list — cost if wrong: one more message per order.
13. The switches' default flip moved to Task 3's commit, so no commit has them on without the budget check — cost if wrong: none.
14. The ledger reader treats a fifth field as damage (the old loop let one extra slip through) — cost if wrong: none.
15. Refusal reasons keep the caps' number style ("12.5"); the budget's note and the told line use two decimals ("12.50") — cost if wrong: two styles in the log.
16. Refusal order: `mail_send` to the gate; `harness:` jobs; no amount; then (payable) switches, paused, outside text, budget none or missing, amount, caps, budget a day, a month — cost if wrong: a refusal names its first reason only.
17. The payment tap reuses `Errands.OrderGo`; its result is said in the item's conversation (main when others read it) — cost if wrong: one line where the owner didn't look.
18. `/money`'s text is built in core.zig (it reads the ledger, config and running servers); money.zig keeps the pure pieces — cost if wrong: none.
19. A failed automated call is told too ("The server said it failed; it stays counted.") — cost if wrong: a line for a payment that may not have happened (it says so).
20. Skipped items wait out quiet hours as every skipped item does; only the told line goes at once — cost if wrong: a payment refused at night waits for the morning.
21. A budget-refused reorder proposal says "Not ordered on its own: WHY." at the end of its body; the reorder's own lines go through the errands' post (held in quiet hours) — cost if wrong: at night "Ordered from…" waits while the told line went.
22. The upgrade marker is written at every first start (said, or nothing to do); a file it can't write leaves it unmarked for the next start — cost if wrong: none found.
23. Setup's question also takes a reply ("50 a day, 300 a month"); Set an amount says the commands — cost if wrong: one more line.
24. Every unattended money decision's gate line has the budget's numbers, refusals before the budget check too — cost if wrong: one more ledger lock per call.

## Done

- Commits: the plan (0610a03); keys (b8eefcf); the ledger's lines (2ab7398); moneyCheck's unattended branch, switches on (65a69ca); skipped payments and [Make this payment] (743f2e0); told line, pause, `/money` (32ce546); the reorder within the budget (077a702); old installs and setup's question (12df3ca); injection case 33 (dd3361a); numbers on every decision (26f8f8f); two reorder tests changed on purpose (807a1c3); docs and smoke (b6b10e0).
- Before the merge (b6b10e0): 1457 pass, 22 skipped of 1479 (baseline 1427 of 1449: 30 new), Debug and ReleaseSafe; smoke 152 (148 + 4: `/money`, `/money budget`, pause, resume), 185 with homemcp, carcloud, calmcp and mailmcp (181 + 4), both modes. Cross builds and unit-builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl) ok.
- Tests changed on purpose: config `agents_browser_and_money_sections`, `trigger_and_money_settings_read`, `workflow_settings_read` (the defaults; their defaults_ini lines follow); agent `money_in_scheduled_runs_only_when_switched_on`, `unattended_money_needs_a_cap` (now `…_needs_a_budget`), `none_in_a_servers_section_lifts_config_inis_cap_and_says_so`, `money_in_trigger_runs_is_refused_while_triggers_is_off`, `money_in_agent_steps_is_refused_while_workflows_is_off`, `money_ledger_keeps_a_total_per_server_and_reads_the_old_file` (the month line after today's); core `the_order_goes_through_the_gates_caps_and_dry_run`, `a_shop_whose_order_tool_is_not_money_is_refused` (setup's budget question is an item). gate `money_ignores_grants_and_allow_rules_and_is_refused_unattended` holds unchanged.
- Found against the spec: `home_guarded` (amount none) was not refused unattended before this change when `scheduled = on` with a cap (amount 0 passed the caps and the gate allowed it); it is now, whatever the budget (`a_money_tool_with_no_amount_is_never_unattended`, `no_amount_tools_and_mail_send_are_never_unattended`).
- Seen on this Mac at the base (75a5f48) too: core `each_of_these_asks` is flaky (reload says Busy), 2 of 5 runs alone.
- Merged `origin/harness-logins` (c05f7a5: the Windows sandbox's NUL, the desk's spec) with no conflicts (06aa7bf). After the merge: 1457 pass, 22 skipped of 1479, Debug and ReleaseSafe; smoke 152, and 185 with the four stand-ins, both modes; cross builds and unit-builds ok. One ReleaseSafe stand-ins smoke run failed 11 checks across unrelated sections (members, Home Assistant, approvals, helpers' questions, a restart) while the machine's load average was about 23 (a virtual machine at 420% CPU); run again, all 185 passed.
