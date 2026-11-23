# harness: routines, guided setup and the tester kit (Parts 2, 7 and 8 of the butler spec) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Someone who runs Home Assistant (and maybe has a car on Smartcar) gets a working butler in ten minutes, in chat: `harness init` asks whether this is a home butler; after pairing, `/setup home` reads the home through `homemcp discover`, says in one message what harness will switch, what it will ask about and what it won't touch ([Looks right] [Change it]), and writes the files only after showing them; `/setup car` does the same for carcloud; then the routines are offered one at a time, a sentence each, [Turn on] [Not now]: goodnight, leaving, arriving, the morning summary, a leak, a door left open, the car for tomorrow. Each routine is a workflow file and triggers.ini sections under `harness/examples/butler/`, filled with the owner's devices. Guarded steps are an `approve` step followed by the guarded call, one tap; nothing guarded runs unattended. Testers get `harness doctor`, `harness report`, `harness/TESTERS.md` and release builds. Also `harness/examples/morning/`: the work morning routine (Slack, Jira, GitHub) of the routines spec's Part 1.

**Architecture:** A new `butler.zig` is pure: it reads a homemcp home file and `homemcp check`'s lines (devices, kinds, rooms, guarded, left out, sensors' states), says the setup summary in plain words, edits the pending home file (leave, ask, allow; unidentified switches guarded), picks the devices a routine needs and fills the routine templates (embedded from `examples/butler/` through a small `files.zig` there), and holds the routines' catalogue (name, sentence, what each needs, its files). `workflows.zig` gets `yes`/`no` on an approve step (its button makes the next tool step's call: the step's call is allowed once by that tap) and a `phrases` head line (the owner's message starts it, no model call); `triggers.zig` takes `start = workflow NAME TEXT` (TEXT, filled from the event, is the instance's input); `sources.zig` gives an MCP resource event the fields of its JSON text. `core.zig` gets one self-contained section: `/setup`, its items (kinds `setup`, `routine`, shown without a head), their answers (files written with `util.writeReplace`, shown first, then a reload), the yes-approve's one tap and the phrase start. `main.zig` gets `init`'s question, `doctor` and `report` (they read the folder without taking its lock, so they work while `harness run` does). `fake_mcp.zig`/`fake_main.zig` get the stand-ins the tests need: a fuller home, Slack, Jira and GitHub, and `discover`/`check` answers in homemcp's and carcloud's words.

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-butler-design.md` (UX rules, What it looks like, Parts 2, 7, 8, red lines, tests); `2026-11-23-harness-routines-undo-copies-memory-design.md` Part 1 (the morning routine); the ledger's notes on workflows, triggers, MCP resources, urgent, quiet hours, members, the inbox, Undo, homemcp 0.2 and its follow-up on switches discover can't identify.

## Global Constraints

- Work in `harness/` only (and `.github/workflows/release.yml`, this plan). homemcp and carcloud are run, never changed (another builder adds `announce` to homemcp and an endpoint to core for Part 9: keep core edits in their own section and out of the conversation-agent path).
- Every new Core field is set in `Core.open`; every file setup writes goes through `util.writeReplace` and is shown to the owner before it is written; secrets never in chat, logs, model requests, reports or output (the Home Assistant token is `harness secret add ha`, the Smartcar secret `harness secret add smartcar`, typed in a terminal).
- Red lines hold: no unlocking, opening a garage door or disarming from an event, a schedule or an unattended run (the routines only lock, close and ask; homemcp's home file never allows the other way); no generic call; cameras and smoke/CO detectors never acted on; events are data; car commands only through carcloud.
- Existing tests change only where behaviour changes on purpose (listed in Done).
- Baseline: 860 pass, 19 skipped, smoke all ok (91 checks).
- Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc-butler > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; the whole suite per task; with `HOMEMCP_BIN`/`CARCLOUD_BIN` (homemcp and carcloud built with the same cache dir into scratch folders) the smoke runs the routines against homemcp-sim and carcloud-sim; CI skips those. `-Doptimize=ReleaseSafe` and the cross builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `zig build` and `unit-build`, `-p` into a scratch folder) at the end.

## Review Focus

### First-run UX (what a new user sees)

1. **Ten minutes, in chat, no file edited.** `harness init` (one question) → secrets in the terminal → `harness run`, `harness pair` → `/setup home` → one summary → [Looks right] → routines one at a time → done. Each message is plain (no tool names, no JSON, units), says what to do next, and fits a phone screen. (`setup_home_from_discover_to_looks_right`, the smoke's setup run.)
2. **Shown before written.** Every file (home.ini, car.ini, mcp.ini's section, rules lines, a routine's workflow and triggers.ini sections) is posted before the button that writes it; nothing is written on `/setup home` alone. (`setup_writes_nothing_before_looks_right`, `a_routine_is_shown_then_written_on_turn_on`.)
3. **Mistakes are said with what to do.** No token stored → the exact `harness secret add ha` line; Home Assistant unreachable or refusing the token → which, and the address it tried; homemcp not found → where harness looked; a token pasted in chat → not echoed, not stored, the owner told to delete it. (`setup_home_says_what_is_missing`.)
4. **One tap decides.** A routine's guarded question is one message with action-named buttons ([Lock it] [Leave it], [Close the water main] [Ignore]); the tap makes the call and harness reads back what the device said. (`goodnight_asks_before_locking_and_one_tap_locks`, `leak_asks_to_close_the_valve_with_one_tap`.)
5. **doctor and report speak plainly**: a line per piece, each failing one with what to do. (`doctor_names_each_broken_piece`.)

### Red lines

1. **Nothing guarded runs unattended.** A guarded call in a routine runs only right after the owner's tap on that instance's question; the tap allows that one call once (not a grant; the gate decides it again, so a deny rule, a cap or `/dryrun` still stops it). A schedule- or event-started goodnight or leaving whose question nobody answers never locks; no routine unlocks, opens or disarms. (`goodnight_never_locks_unattended`, `a_yes_covers_only_the_next_call_once`.)
2. **The guarded call is exactly the next step's.** `yes` is refused unless the next step in the file is a tool step and the approve step has no `if`/`goto`/`end`; the tap counts for that step's first question only; a retry asks again. (workflows tests.)
3. **Unidentified switches stay guarded until sorted.** A plain `switch` discover could not identify is written `guarded = yes` and listed; only the owner's `/setup home allow NAME` lets it act. (`unidentified_switches_stay_guarded_until_sorted`.)
4. **Cameras and smoke/CO detectors** are never in a routine and are named as untouched in the summary. (butler tests.)
5. **Events are data.** Resource fields fill texts and tool inputs as values; an agent step gets them under "Data (from outside…)". (sources and routine tests.)
6. **Secrets.** The HA token and the Smartcar secret are read from the store at the call, passed only in the child's environment, masked; `report` holds no stored secret's value. (`report_holds_no_secret`.)

## Rulings

(Each: what – why – cost if wrong. Added to as they are made.)

1. **One tap for a guarded routine step: `yes`/`no` on an approve step.** What: `yes LABEL` (and optionally `no LABEL`) on an `approve` step shows its text alone with those two buttons; the yes tap is the next tool step's Allow once (its first gate question, once; the gate decides the call again). Without `yes`, approve is data as before (`an_approve_answer_grants_nothing` unchanged). Why: UX rule 3 ("its buttons do it") and the spec's one-tap leak, against two questions (approve, then the gate's "Allow this?" with JSON); opt-in keeps every existing workflow as it was, and harness's reading says it. Cost if wrong: a workflow author who writes vague yes text gets a call made on one tap (the reading names the call; an agent-saved file is asked with it).
2. **`phrases` head line.** What: `phrases goodnight, good night`: the owner's own message equal to one of them (case, spaces, punctuation and emoji aside) starts the workflow as `/workflow start NAME` does, without a model call; `start` must name `owner`. Why: "You: goodnight" is the butler's most used routine; a model deciding to start it costs a call and can do the work itself instead. Cost if wrong: a typed "goodnight" meant as chat starts the routine (it only asks before locking).
3. **`start = workflow NAME TEXT`.** What: text after the name, `{field}` filled from the event, is the instance's `{input}` (the event stays in `{event.FIELD}`). Why: one workflow serves every door or leak sensor and still names the right one in plain words ("Back door has been open for 10 minutes."). Cost if wrong: none found; a file without text works as before.
4. **An MCP resource event whose text is a JSON object also has its top-level fields** (strings as they are, numbers and booleans as written, others as JSON), besides `text`. Why: homemcp's events are `{"device","room","kind","from","to",…}`; `match = to is open` and `{event.device}` read plainly. Cost if wrong: a field called `text` in the JSON is shadowed by the whole text.
5. **`tag no` head line.** What: the workflow's posts and questions go without `[NAME#N]` in front. Why: the butler's messages read as sentences ("Front door locked. Good night."); the tag is for the owner's own workflows, where several run at once. Cost if wrong: two instances of one routine at once can't be told apart in the chat (each says its device, and `at-once` is the default 3).
6. **Plain inbox kinds `confirm`, `setup`, `routine`.** What: their text alone, no "Allow this? [41]" head; the answer edits the message into "Lock it, 03:00". Why: UX rules plain and short; the item id stays in the button data and `/inbox`. Cost if wrong: `/answer ID` users must look the id up in `/inbox`.
7. **Setup writes every file whole, then reloads.** What: each file through `util.writeReplace` after it was shown; then `/reload`, tried again for up to 20 s while a run is busy, else "Written; it applies after /reload". A failure says "Not done: why" (no claim that nothing was written: a later file may fail after an earlier one; tapping again writes them all the same, idempotently). Why: no half-applied settings by design, and no false comfort. Cost if wrong: a disk-full mid-way leaves home.ini without its mcp.ini section until the tap is repeated.
8. **Where homemcp and carcloud are.** What: `[butler] homemcp =`, `carcloud =` in config.ini, else next to harness, else PATH. Why: the release packages sit in one folder; tests point at stand-ins. Cost if wrong: an old homemcp on PATH is used; setup's mcp.ini line names the path it chose.
9. **Secret names `ha` and `smartcar`.** What: mcp.ini passes `HA_TOKEN:ha`, `SMARTCAR_CLIENT_SECRET:smartcar`. Why: short to type, said in every message that needs them. Cost if wrong: a token stored earlier as `homeassistant` (homemcp's own example) is stored again.
10. **A token in `/setup` is refused and withheld.** What: a `/setup` message with a word that looks like a token (long and mixed, or a JWT) is not echoed, not stored, logged as "(withheld: it looks like a token)", and the owner is told to delete it and use `harness secret add`. Why: red line, a token never in chat or log. Cost if wrong: an odd address that looks like a token is refused (it works with `http://`).
11. **The car: charging only, bounded by car.ini (after the security review).** What: car.ini allows `charge_start`, `charge_stop`, `charge_limit` (60–90), 10 a day, a minute apart, no location; rules allow `car_status` and the owner's `car_command`, with no `ask`/`deny` for part of a tool next to an `allow` for all of it (the gate matches JSON text). Why: the review's finding; carcloud's own allow list is the boundary. Cost if wrong: an owner who adds `unlock` to car.ini by hand gets it on their own request without a question (the README says car.ini is the boundary).
12. **The morning summary follows the night's digest.** What: a routine at quiet hours' end, a message of its own after the digest. Why: merging them would change quiet hours' holding in core (Part 9's builder is in core too); two messages is the smaller change. Cost if wrong: two messages each morning instead of one.
13. **Routine times and temperatures.** What: goodnight 15 minutes before quiet hours (22:00 without them), the morning summary at their end (07:00), the car 90 minutes before (20:30); 18 °C at night, 17 °C away, 21 °C home. Why: one sentence per offer says them; the file says them again. Cost if wrong: they don't move when `/quiet` changes later; the owner edits the file.
14. **Which devices a routine uses.** What: the first lock (a front door first), the first thermostat with a set temperature, the first valve that closes (or a switch noted as a valve), every leak sensor, every door and window sensor. Why: one routine, one sentence. Cost if wrong: a second lock isn't in goodnight until the file is edited.
15. **A trigger section per sensor** (`[leak-NAME]`, `[door-NAME]`), each with its start text. Why: a trigger watches one resource; the text names the device plainly. Cost if wrong: a home with 30 door sensors gets 30 sections.
16. **The work morning's schedule is `[morning-at]`.** Why: schedule names are shared with tasks and briefs, and `morning` is a brief's usual name. Cost: none.
17. **Unidentified switches carried over.** What: written `guarded = yes` with a note; `/setup home allow NAME` lifts it; a later `/setup home` keeps what the owner sorted (left out, allowed, asked). Why: red line 3 and no re-sorting. Cost if wrong: a switch renamed in Home Assistant is sorted again.
18. **`init` asks one question.** What: on a terminal, "Is this a home butler…? [y/N]"; `--butler` answers yes; with no terminal it doesn't ask and says `harness init --butler`. Yes turns quiet hours on (22:00-07:00) and the next steps name `harness secret add ha` and `/setup home`; after pairing, a butler with no home hears "Next: /setup home connects your home." Cost if wrong: none found.
19. **doctor reaches out; report masks what it can name.** What: doctor makes one short model request, asks Telegram's getMe and runs homemcp's and carcloud's own `check`; it takes no lock. report masks every secret a setting names plus, with the file store, every stored file; the Keychain and the Credential Manager are asked by name (store.zig can't list them), and bot tokens and passwords in addresses are taken out by their shape. Why: "is the model reachable" needs a request; listing the Keychain needs new platform code. Cost if wrong: a few tokens per doctor; on macOS or Windows a secret no setting names, pasted into a settings file, would reach the report.
20. **Release builds.** What: tags `harness-v*`, `homemcp-v*`, `carcloud-v*` in release.yml's matrix (macOS arm64, Linux x86-64 and arm64, Windows x86-64); these three ReleaseSafe, the others as before (ReleaseFast); harness's package adds TESTERS.md and examples/, homemcp's and carcloud's their `-sim`. Why: programs that hold secrets and act in homes keep their safety checks; testers can try without a home or car. Cost if wrong: somewhat larger, slower binaries.

## Files

- Create `harness/src/butler.zig` (home file, summary, edits, device picks, routine catalogue and filling; tests).
- Create `harness/examples/butler/` (`README.md`, `workflows/*.wf`, `triggers.ini`, `mcp.ini`, `rules`, `files.zig` embedding them), `harness/examples/morning/` (`README.md`, `workflows/morning.wf`, `triggers.ini`, `mcp.ini`, `rules`), `harness/TESTERS.md`.
- Modify `harness/build.zig` (the examples' module), `harness/src/workflows.zig`, `harness/src/triggers.zig`, `harness/src/sources.zig`, `harness/src/inbox.zig` (headless kinds), `harness/src/core.zig` (the setup section, the yes tap, phrases, the start text), `harness/src/main.zig` (init's question, doctor, report), `harness/src/fake_mcp.zig`, `harness/src/fake_main.zig`, `harness/scripts/smoke.sh`, `harness/README.md`, `.github/workflows/release.yml`.

---

### Task 1: What routines need from workflows and triggers

**Interfaces — Produces:** workflows.zig `Step.yes`, `Step.no`, `Workflow.phrases`, `phraseOf(text) ?[]const u8` (normalized), reading lines; triggers.zig `Trigger.start_input`; sources.zig resource events with JSON fields; inbox.zig kinds shown without a head (`confirm`, `setup`, `routine`); core.zig `approve`+`yes` items (kind `confirm`, labels, no tag), the tap carried to the next step (`wstate.Answer` with `ask = "yes:STEP"`), `WfAsker` taking it once, the phrase start in `handleTextIn`, the start text in `startWorkflow`.

- [x] **Step 1: Write the failing tests:**
  - workflows.zig `yes_and_no_go_on_an_approve_before_a_tool_step` (parsed; refused: on a say, without a tool step next, with if/goto/end on the approve, a label over 32 bytes or with a line break; the reading says the tap makes the call).
  - workflows.zig `phrases_start_by_the_owners_words` (parsed, normalized; refused without `owner` in start; `phraseOf`).
  - triggers.zig `start_takes_text_for_the_input`.
  - sources.zig `a_json_resource_gives_its_fields`.
  - inbox.zig `plain_kinds_show_their_text_alone`.
  - core.zig `a_yes_tap_makes_the_next_call_once` (fake MCP echo asked by default: one item with the two labels and no head, tap → the call made, no grant, no second question; a second tool step after it is asked), `a_no_tap_or_no_answer_makes_no_call`, `a_phrase_starts_its_workflow_without_the_model`, `a_trigger_start_text_is_the_input`.
- [x] **Step 2:** run; expect failures.
- [x] **Step 3:** implement.
- [x] **Step 4:** whole suite green.
- [x] **Step 5:** commit `harness workflows: approve yes/no is the next call's one tap; phrases; a trigger's start text; resource fields (Part 2)`.

### Task 2: The routines

**Interfaces — Produces:** `examples/butler/` files; butler.zig `Home` (`parse(text)`, devices, people, left out), `Checked` (`homemcp check` lines → states), `Picks` (`pick(home, checked)`), `Routine` catalogue (`routines`, `needs`, `sentence`, `files(a, picks, opts)`), `fill(a, template, values)`.

- [x] **Step 1: Write the failing tests:**
  - butler.zig `the_sims_home_reads` (homemcp-sim's discover output: 15 devices, 5 rooms, 2 people, guarded, left out with reasons).
  - butler.zig `routines_fill_from_the_sims_home` (each routine's files filled with the sim's devices read as workflows and triggers.ini sections, checked together: names, start lines, triggers; no placeholder left; no unlock, open or disarm anywhere; guarded calls only right after a yes approve).
  - butler.zig `a_routine_whose_devices_are_missing_is_not_offered`.
  - core.zig (fake home stand-in, fuller): `goodnight_asks_before_locking_and_one_tap_locks`, `goodnight_never_locks_unattended`, `leak_asks_to_close_the_valve_with_one_tap` (urgent: in quiet hours too), `a_door_left_open_is_said_after_ten_minutes`, `leaving_asks_and_arriving_warms`, `the_car_for_tomorrow_asks_to_charge`, `the_morning_summary_reads_car_and_house`.
  - smoke (HOMEMCP_BIN/CARCLOUD_BIN): each routine against homemcp-sim and carcloud-sim.
- [x] **Step 2:** run; expect failures.
- [x] **Step 3:** implement.
- [x] **Step 4:** whole suite green (with the sims).
- [x] **Step 5:** commit `harness: the butler's routines as workflows and triggers, filled with the owner's devices (Part 2)`.

### Task 3: The work morning routine

**Interfaces — Produces:** `examples/morning/`; fake_mcp.zig `--mcp --slack|--jira|--github`.

- [x] **Step 1:** smoke check `the morning routine reads Slack, Jira and GitHub, and posts the replies after an approve` (fails: no files, no stand-ins); core.zig `the_morning_routine_files_read`.
- [x] **Step 2–4:** implement; whole suite green.
- [x] **Step 5:** commit `harness examples: the work morning routine (Slack, Jira, GitHub), tested against the fake MCP server`.

### Task 4: Guided setup

**Interfaces — Produces:** main.zig `init` question (`--butler` answers yes without asking); core.zig `/setup`, `/setup home [URL]`, `/setup home leave|ask|allow NAME`, `/setup car CLIENT VEHICLE USER [API]`, `/setup routines`, items `setup` and `routine`, `state/setup/`; butler.zig `summary`, `edit`, `carSummary`; fake_main.zig `discover`/`check` stand-ins.

- [x] **Step 1: Write the failing tests:**
  - main.zig `init_asks_whether_this_is_a_home_butler` (the answer's effect on config.ini and the next steps).
  - butler.zig `the_summary_says_what_it_switches_asks_and_leaves`, `unidentified_switches_stay_guarded_until_sorted`, `edits_leave_ask_allow`.
  - core.zig `setup_home_says_what_is_missing` (no token, no homemcp, a token pasted), `setup_writes_nothing_before_looks_right`, `setup_home_from_discover_to_looks_right` (files shown, then written, the server started, the first routine offered), `change_it_takes_edits_and_shows_the_summary_again`, `a_routine_is_shown_then_written_on_turn_on`, `not_now_offers_the_next`, `setup_car_writes_the_car_file_after_looks_right`.
  - smoke: `/setup home` against homemcp-sim through `homemcp discover`, Looks right, every routine turned on.
- [x] **Step 2–4:** implement; whole suite green.
- [x] **Step 5:** commit `harness: guided setup — init asks, /setup home and /setup car in chat, routines offered one at a time (Part 7)`.

### Task 5: Tester kit

**Interfaces — Produces:** main.zig `doctor`, `report`; `TESTERS.md`; `release.yml` entries.

- [x] **Step 1: Write the failing tests:** main.zig `doctor_names_each_broken_piece` (no token, no key, no home, a refused token, a paused trigger, voice and quiet hours), `doctor_says_all_is_well_when_it_is`, `report_holds_no_secret` (every stored secret's value absent; the log's last 200 lines masked; settings without secrets; doctor's output in it); smoke: doctor and report offline.
- [x] **Step 2–4:** implement; whole suite green.
- [x] **Step 5:** commit `harness: doctor, report, TESTERS.md and release builds (Part 8)`.

### Task 6: README and final checks

- [x] README (plain labels): the butler — setup, routines, doctor/report, testing; the State line.
- [x] Debug and ReleaseSafe suites; cross builds; commit; the plan's Done.

## Done

All six tasks, in commits d4bedb2 (this plan), 8baeccf (Task 1), e78f9dc (Task 2), f31560b (Task 3, and the butler's car rules after the security review), 311029b (Task 4), then the tester kit (Task 5) and the README (Task 6).

- **Tests, by the Review Focus.** First-run UX: `init_asks_whether_this_is_a_home_butler`, `setup_home_says_what_is_missing`, `setup_home_from_discover_to_looks_right` (nothing written before Looks right), `change_it_takes_edits_and_shows_the_summary_again`, `a_routine_is_shown_then_written_on_turn_on` (Not now offers the next), `setup_car_writes_the_car_file_after_looks_right`, `the_summary_says_what_it_switches_asks_and_leaves`, `doctor_names_each_broken_piece`, `doctor_says_all_is_well_when_it_is`. Red lines: `a_yes_tap_makes_the_next_call_once`, `a_no_tap_or_no_answer_makes_no_call`, `goodnight_never_locks_unattended`, `yes_and_no_go_on_an_approve_before_a_tool_step`, `unidentified_switches_stay_guarded_until_sorted`, `edits_leave_ask_allow`, `routines_fill_from_the_sims_home` (no unlock or open in any filled file, no ask/deny next to an allow-all), `report_holds_no_secret`. The routines: `goodnight_asks_before_locking_and_one_tap_locks`, `leak_asks_to_close_the_valve_with_one_tap`, `a_door_left_open_is_said_after_ten_minutes`, `leaving_asks_and_arriving_warms`, `the_car_for_tomorrow_asks_to_charge`, `the_morning_summary_reads_car_and_house`.
- **Smoke, with homemcp-sim and carcloud-sim** (HOMEMCP_BIN, CARCLOUD_BIN; skipped without them): `/setup home` through `homemcp discover`, Looks right, six routines on; goodnight's tap locks the door and `homemcp check` reads it locked; the leak's tap closes the valve, read back closed; a door left open waits 10 minutes; the last one out turns the heating down (read back 17 °C), the first one back warms it; the morning summary reads the house; `/setup car`, its routine, and one tap starts charging (`carcloud check`: charging). Without them: `init --butler`, the work morning against the fake MCP servers, doctor and report.
- **Existing tests changed on purpose:** none. `init` left the no-argument list (it takes `--butler`); a butler folder's pairing hello names `/setup home` (other folders' is as before).
- **Left out:** the morning summary inside the digest (Ruling 12); routine times following a later `/quiet`; Zigbee2MQTT in `/setup home` beyond what `homemcp discover` reads; Smartcar Connect in chat (carcloud has no sign-in command: the car is connected once on Smartcar's side, and `/setup car` takes the ids its Dashboard shows, as carcloud's README says); listing the Keychain and the Credential Manager for the report (Ruling 19); `announce` and the conversation agent (Part 9, the other builder's).

