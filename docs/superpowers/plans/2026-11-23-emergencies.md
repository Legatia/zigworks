# harness: emergencies — acknowledging, escalation, the safe-direction fallback, smoke and CO watched (section 1 of the duties spec) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An urgent alert is never left with nobody. A tap on any of its buttons, or a reply to it, acknowledges it. Unacknowledged, it goes to household members in order (`[butler] escalate = 5m anna, 15m piotr`; a trigger's or workflow's own `escalate`, or `escalate = no`): "Nobody has answered this yet: Water under the kitchen sink." [I'm on it]; the house's speakers say it again at each step where the alert's trigger announces; a member's "I'm on it" acknowledges it for everyone and the owner is told who. An urgent workflow's `approve` step with `yes` may say `fallback 5m`: with nobody acknowledging, harness makes that step's call itself, once, only lock, close or arm, and says so ("No one answered in 5 minutes: Water main closed (it reports closed)."); setup offers it for the leak routine. homemcp keeps smoke and CO detectors as watched only (kind `smoke`): discover lists them, they push their state, nothing acts on them; a `smoke` routine says it at once, on every speaker, and escalates.

**Architecture:** A new `alerts.zig`: the escalation line's reader (`parseEscalate`), and `Store`, `state/alerts` (alerts open: their first message, the item, the steps and who was told, the fallback, the speakers' line, the acknowledgement), written whole before harness acts on a change, with the plans (urgent trigger or workflow → its steps) core refreshes beside the urgent list. `config.zig` reads `[butler] escalate`; `triggers.zig` `escalate` and `speakers = all`; `workflows.zig` `escalate` in the head and `fallback D` on an approve step, each checked when the file is read. `core.zig` gets one section (`---- emergencies ----`: making an alert from a post or an item, acknowledging, the presses of [I'm on it], escalation and the fallback at each tick, the speakers) and one-line hooks: `postShaped`, `addItem`, `askStep`, `settle`, `handleCallbackText`, `handleIncoming`, `noteUrgent`, `actTrigger`, `tick`, `open`/`close`; the instance's yes answered by the fallback carries key `fallback` (agent.zig logs "made by harness"), `wstate.State.absent` puts "No one answered in N minutes: " before its next say, `inbox.Via.fallback` says it on the question. `butler.zig` gets kind `smoke`, the smoke routine, the leak's fallback offer. homemcp: kind `smoke` in model, config, discover, server, sim.

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-butler-duties-design.md` section 1 (and its tests and calls); `2026-11-23-harness-butler-design.md` (UX rules, red lines); the ledger's notes on urgent, quiet hours, members, the inbox, workflows' `approve`+`yes`, homemcp's guarded tool, discover, announce, the routines and `/setup routines`.

## Global Constraints

- Two other builders work at the same time (calmcp and the diary; people): core.zig edits stay in their own section and one-line hooks.
- Every new Core field set in `Core.open`; state files through `util.writeReplace`; secrets never in logs or output; members never approve anything guarded.
- Existing tests change only where behaviour changes on purpose (listed in Done).
- Baseline: harness 951 pass, 20 skipped, smoke 101 ok (122 with HOMEMCP_BIN and CARCLOUD_BIN); homemcp its unit tests and smoke.
- Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc-emerg > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; with the stand-ins (homemcp and carcloud built with `-p` into scratch folders, HOMEMCP_BIN/CARCLOUD_BIN their `bin` folders); Debug and ReleaseSafe; cross builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `zig build` and `unit-build`) with `-p` into a scratch folder. homemcp from `homemcp/` the same.
- Windows: templates read the same with `\r\n`; the smoke script runs under macOS's `/bin/sh`.

## Review Focus

### Red lines

1. **Never unlock, open or disarm unattended.** `fallback` is a bad line unless the next step is `SERVER/home_guarded` with `action` lock, close, arm_home or arm_away, fixed in the file (as `yes` already requires), in a workflow that says `urgent yes`. (`fallback_takes_only_a_safe_call_of_an_urgent_routine`, `a_fallback_on_unlock_is_refused_when_read`.)
2. **The fallback call is the gate's like any other.** It answers the question as the yes tap would, once; the gate decides the call again (deny rules, `/dryrun`, caps hold) and logs "made by harness: no one answered in time". (`the_fallback_makes_the_safe_call_once_and_says_so`.)
3. **Members approve nothing.** A member gets the alert's first line and [I'm on it], never its buttons; their tap only acknowledges. (`a_members_on_it_acknowledges_for_everyone`.)
4. **Smoke and CO detectors are never acted on.** homemcp: kind `smoke` has no action; an `allow` or `guarded` line on one is refused when the file is read; `home_set`/`home_guarded` refuse it; harness's smoke routine has no tool step. (homemcp `smoke_and_co_are_watched_only`, `discover_writes_safe_defaults`; harness `the_smoke_routine_says_it_everywhere_and_escalates`.)

### Alerts never lost

1. **Escalation survives a restart**: `state/alerts` is written before each step acts; steps due while harness was stopped go at the first tick, in order; [I'm on it] works after a restart (a token per alert, on disk). (`escalation_survives_a_restart`.)
2. **A send that fails doesn't stop it**: an owner's post that didn't get through is still an alert (kept as a delivery item too); a member who can't be reached is logged and the owner told, and the next step still goes. (`escalation_goes_on_when_a_member_cant_be_reached`.)
3. **Only an acknowledgement stops it**: a tap or a reply by the owner, an answer to its item from anywhere, or a member's [I'm on it]; the fallback doesn't. Nothing escalates for a non-urgent alert. (`escalation_in_order_until_acknowledged`, `nothing_escalates_for_non_urgent_alerts`.)

## Rulings

(Each: what – why – cost if wrong. Added to as they are made.)

1. **Acknowledging is a tap or a reply.** What: any press on the alert's message (its buttons, [I'm on it], a quick reply), a reply to it, an answer to its question from anywhere (`/answer`, the terminal), or a member's [I'm on it]; a message typed beside it without replying is not. Why: the spec's words; a message beside it may be about something else, and a needless message to Anna costs less than a missed alert. Cost if wrong: an owner who types "on it" without replying still has the household told.
2. **An urgent post that escalates gets [I'm on it] for the owner too.** What: a post (not a question) of an urgent trigger or workflow with escalation steps carries one button; a question's own buttons acknowledge already. Why: UX rule 3 (one tap); without it a reply would be the only, hidden, way. Cost if wrong: one more button on urgent posts.
3. **One alert per instance, or per run of a trigger.** What: the first message to the owner of an urgent workflow's instance (its question or post) or of an urgent trigger's run is the alert; the instance's later messages ("Water main closed") are not. Why: an outcome is not another emergency. Cost if wrong: a second emergency within one instance escalates as the first.
4. **Plans.** What: `[butler] escalate` applies to every urgent trigger and workflow; their own `escalate` replaces it, `escalate = no` turns it off; `escalate` without `urgent` is a bad line, and on a trigger that starts a workflow too (the workflow's head says it). Why: one place for the household's order; the exception where it applies. Cost if wrong: an urgent alert that isn't about the home reaches the household unless it says `escalate = no` (the README says so).
5. **Steps.** What: 1 to 5 of `DURATION MEMBER`, comma-separated, each later than the one before, from 1 minute to 24 hours after the alert's first message, a member once. Members are checked when a step is due (the list is state, not settings). Cost if wrong: a typo in a name is found at the first emergency (logged, the owner told).
6. **What a member gets.** What: "Nobody has answered this yet: TEXT" [I'm on it] in their own chat with the bot (made as a conversation if it isn't one), TEXT the alert's first line; never its buttons. One who can't be reached (not joined, never wrote to the bot) is logged, the owner told once per alert, and the next step still goes. Cost if wrong: none found.
7. **A member's [I'm on it] acknowledges for everyone.** What: escalation stops, no fallback; the owner hears "Anna is on it: TEXT"; the other members' messages are edited "Anna is on it, HH:MM"; the owner's question stays open (members approve nothing). The owner acknowledging after members were told edits theirs "The owner answered, HH:MM". A member's reply in words is not an acknowledgement (it is their message to the bot). Cost if wrong: Anna replying "coming" doesn't stop Piotr being told.
8. **Speakers.** What: where the alert's trigger (or the trigger that started its workflow) has `announce`, each escalation step says that line again, through the gate as the trigger's own announce (urgent: at night too); the line is noted when the trigger acts. Why: the spec; the line the owner wrote. Cost if wrong: a workflow started by hand (no trigger) has nothing said.
9. **`state/alerts`.** What: `{"v":1,"next":N,"alerts":[…]}`, written whole before what follows acts on it, texts masked; an alert closes when acknowledged, when its question closes otherwise (expired, withdrawn, void), or 24 hours after it began; closed alerts are dropped. Cost if wrong: none found.
10. **The fallback.** What: at D after the question, nobody acknowledging and the question open, harness answers it as the yes tap would (via `fallback`), once; the call is the gate's (logged "made by harness: no one answered in time"); the instance's next `say` begins "No one answered in N minutes: "; the question's message says "Close the water main (no one answered: harness did it), 03:17"; an `alert` log line `absence` holds the alert, its time, the fallback's time and the call. Escalation goes on (the fallback is no acknowledgement). Why: the spec; the instance's own say reads back what the device reported. Cost if wrong: a routine without a say after the call tells the owner only by the edited question.
11. **The fallback's limits.** What: `fallback D` goes with `yes`, in a workflow that says `urgent yes`, before a `SERVER/home_guarded` step whose `action` is lock, close, arm_home or arm_away; D from 1 minute to less than the step's timeout. Why: the red lines; homemcp's own allow list is the second wall. Cost if wrong: a valve on a plain switch (safe way `off`) gets no fallback.
12. **The leak's fallback offered after Turn on.** What: when the leak routine is turned on with a valve (kind valve, close), a second item: the line it adds shown first, "If nobody answers in 5 minutes, I close the water main myself, once, and tell you." [Turn on] [Not now]; Turn on writes leak.wf again from its template only while it is as setup wrote it, else says to add the line by hand; `/setup routines` offers it again while leak is on without it. Cost if wrong: an owner who edited leak.wf adds a line by hand.
13. **homemcp kind `smoke`.** What: smoke, CO and gas detectors; no action at all; `allow` or `guarded` on one refused when the file is read; `home_set`/`home_guarded` refuse it; its state is `ALARM` or `clear`; discover writes them with no allow and lists them "Watched, never acted on". Why: the spec; a kind of its own keeps them out of every action path. Cost if wrong: a CO detector reads `kind = smoke`.
14. **The smoke routine.** What: a workflow `smoke` (urgent, one say) and a trigger section per detector (`to is ALARM`, urgent, `announce` with `speakers = all` when the home has a speaker that may announce); escalation from `[butler]`; no fallback (nothing to close). Cost if wrong: none found.
15. **`speakers = all`** on a trigger with `announce`: said on every speaker, not only in the event's room. Why: smoke concerns the whole house. Cost if wrong: none found.
16. **Log kind `alert`**: open, escalated, announced, acknowledged, absence, closed. Cost if wrong: none.

## Files

- Create `harness/src/alerts.zig`; `harness/examples/butler/workflows/smoke.wf`.
- Modify `harness/src/config.zig`, `triggers.zig`, `workflows.zig`, `wstate.zig` (`absent`), `inbox.zig` (`Via.fallback`), `agent.zig` (one line), `log.zig` (kind), `butler.zig`, `core.zig` (section + hooks), `fake_mcp.zig` (a smoke alarm), `examples/butler/*`, `scripts/smoke.sh`, `README.md`, `TESTERS.md`.
- homemcp: `src/model.zig`, `config.zig`, `discover.zig`, `server.zig`, `sim.zig`, `main.zig` (check's line), `scripts/smoke.sh`, `README.md`.

---

### Task 1: Reading escalate, speakers and fallback

- [ ] **Step 1: Write the failing tests:** alerts.zig `escalate_reads_steps_or_no`; config.zig `butler_escalate_reads`; triggers.zig `escalate_and_speakers_are_read`; workflows.zig `escalate_is_read_in_the_head`, `fallback_takes_only_a_safe_call_of_an_urgent_routine`, `a_fallback_on_unlock_is_refused_when_read`.
- [ ] **Step 2:** run; expect failures (no such keys).
- [ ] **Step 3:** implement; readings say them.
- [ ] **Step 4:** whole suite green.
- [ ] **Step 5:** commit.

### Task 2: Alerts, acknowledging and escalation

- [ ] **Step 1: Write the failing tests:** alerts.zig `the_store_keeps_alerts_across_a_load`; core.zig `escalation_in_order_until_acknowledged` (owner's [I'm on it], a reply, item answers), `a_members_on_it_acknowledges_for_everyone`, `nothing_escalates_for_non_urgent_alerts`, `escalation_survives_a_restart`, `escalation_goes_on_when_a_member_cant_be_reached`, `speakers_say_it_again_at_each_step`.
- [ ] **Step 2–4:** fail, implement, green.
- [ ] **Step 5:** commit.

### Task 3: The fallback

- [ ] **Step 1: Write the failing tests:** core.zig `the_fallback_makes_the_safe_call_once_and_says_so`, `no_fallback_once_someone_is_on_it`; butler/core `setup_offers_the_leaks_fallback`.
- [ ] **Step 2–5:** fail, implement, green, commit.

### Task 4: homemcp: smoke and CO watched

- [ ] **Step 1: Write the failing tests:** `smoke_and_co_are_watched_only` (config refusals, server refusals, state), discover's test (listed, watched), events (pushed); smoke script.
- [ ] **Step 2–5:** fail, implement, green (Debug and ReleaseSafe), commit.

### Task 5: The smoke routine

- [ ] **Step 1: Write the failing tests:** butler.zig `the_smoke_routine_fills_for_a_home_with_one`; core.zig `the_smoke_routine_says_it_everywhere_and_escalates`; smoke script with the stand-ins.
- [ ] **Step 2–5:** fail, implement, green, commit.

### Task 6: READMEs, TESTERS.md, the full runs

- [ ] READMEs (harness, homemcp), TESTERS.md: plain labels, State lines; Debug and ReleaseSafe, with and without the stand-ins; cross builds; this plan's Done; commit.

## Done

(Filled at the end.)
