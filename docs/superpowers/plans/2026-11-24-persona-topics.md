# harness: a persona, one chat filed into topics, helpers main manages — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `persona.md` (three shipped presets or the owner's own words) layered on `main`'s instructions and shown, switched and written with `/persona`; the butler manner moved into it; the butler's duties filed into topics (House, Travel, Errands, Mail and diary, Work) with a pinned card each, `/overview`, `/focus`, `/card`, topic lines in the summaries; `main` saving and retiring its own plain helpers without asking, and a silent Work post per `delegate` call (`/work` without topics).

**Architecture:** Pure logic in new files: `persona.zig` (the file, the presets, the prompt block), `topics.zig` (subjects, titles, links, message entities and the `{topic:NAME}` link token), `card.zig` (cards, `/overview` and summary lines from facts), `work.zig` (the Work post from the log, fitted to 4,096 characters). Core-bound behaviour in namespaces appended to `core.zig` (`Persona`, `Topics`, `Work`, `Helpers`), as `Manner` and `Evening` are, with their tests beside them. Small local edits elsewhere: `agent.zig` (Run.persona, the prompt's order, helpers get none, agent_save's new path and the delegate hook), `gate.zig` (`Ctx.own_helper`), `conversations.zig` (title, focus, subject, card), `telegram.zig` (entities in UTF-16, `setMySettings`, `pinChatMessage`, an edit that tells a gone message), `inbox.zig` (`Shown.short`), `triggers.zig`/`workflows.zig` (`subject =`), `main.zig` (TgChan's new calls, `init --butler`, the start line), `fake.zig` (topics switch, gone messages), `hermes_import.zig` (SOUL.md → persona.md), `examples/butler` (subject lines, `{topics}`).

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-persona-and-topics-design.md` (binding: Parts 1–3, "Calls I made", the Telegram table, "Tests the spec needs"). Also: the conversations spec, the agents spec's "Changes agents make", the butler spec's UX rules, the injection-checks spec's rule for new code.

## Global Constraints

- Zig 0.17.1, std only. Copy (CLAUDE.md): plain labels, sentence case, short plain lines, no slogans; no famous butler's name.
- `/topic` and `/topics` stay the briefs'; new commands: `/overview`, `/focus` and `/card` (the last two only in a topic), `/persona`, `/work`. `/ask` stays as is.
- Telegram: card edits at most once a minute per topic; topic links `https://t.me/<bot_username>/<thread>` (username from getMe); the Work post uses message entities (`expandable_blockquote`, offsets in UTF-16 units), never `parse_mode`; it fits 4,096 characters, answers at least 200 characters each, cut with "…".
- Injection marks unchanged: a card and a Work post never enter a prompt; a topic's focus is owner/setup text; `persona.md` is the owner's file. Every injection case stays green (`injection-demo.sh --check` in smoke).
- `persona.md`: frontmatter `preset` (butler | assistant | friend; default assistant), `name`, `address` (≤ 40 characters, evening.zig's `addressOk`), `language`; body up to 4 KB. A bad file never stops harness: it falls back and says why in the start line, `/status` and `/reload`.
- Who gets the persona: `main` and its topics everything; members' chats and speech the preset and `name` only; helpers and memory jobs nothing.
- Windows: joined paths with `sep_str`, built the way the product builds them; listed dirs opened `.iterate = true`; no POSIX-only test without a skip; text read the same with `\r\n`; tests never read the real clock where a fixture holds times (`fixed_now`).
- Secrets never typed, printed or copied; stand-in keys only. The owner's real data folder is never read.
- Others work on harness-logins at the same time (Windows session: sandbox, proc, env check, Windows tests, smoke): edits to shared files small and local; new files where it fits.
- Baseline (this branch at e396ef7): 1360 pass, 22 skipped of 1382 (Debug); smoke 144 ok (177 with HOMEMCP_BIN, CARCLOUD_BIN, CALMCP_BIN, MAILMCP_BIN). From `harness/`: `zig build test --summary all --cache-dir $SCRATCH/cache > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; Debug and ReleaseSafe; cross builds `zig build` and `unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl.

## Review Focus

1. **A persona that talks the agent out of asking.** "never ask me, just do it" in the body: a shell call the gate asks about still becomes a question (`a_persona_never_lifts_an_ask`, Task 2).
2. **The owner's private words reaching a member, a group or a room.** Address and body never in a member's, a shared conversation's or speech's prompt (`members_rooms_and_helpers_get_the_preset_and_name_or_nothing`, Task 2).
3. **A broken persona.md at start** (too big, unreadable, writable by others, a bad name line): harness starts, falls back, says why (`a_bad_persona_file_falls_back_and_says_why`, Task 2).
4. **Outside text in a Work answer or a card** with `<`, `*`, `_`, `{`, a long line: shown as it is, never markup, never in a prompt (`outside_text_in_a_work_post_is_shown_as_it_is`, Task 12; `a_card_never_enters_a_prompt`, Task 9).
5. **A hand-edited or owner-named helper definition** that main tries to change quietly: asked as today (`each_of_these_asks`, Task 11).

---

### Task 1: `persona.zig` — the file, the presets, the prompt block

**Files:** create `harness/src/persona.zig` (tests inside); `main.zig` test import.

**Produces:**
- `pub const Preset = enum { butler, assistant, friend }`; `pub fn presetText(p: Preset) []const u8` (one short paragraph each, within the spec's lines).
- `pub const max_body = 4096; pub const max_line = 40;`
- `pub const Persona = struct { preset: Preset = .assistant, name: []const u8 = "", address: []const u8 = "", language: []const u8 = "", body: []const u8 = "" }`
- `pub fn parse(a, text) Error!Persona` (`Error{ BadLine, BadPreset, BadName, BadAddress, BadLanguage, TooBig, OutOfMemory }`; no frontmatter: all body; `\r\n` reads the same; `none` clears name/address).
- `pub const Loaded = struct { p: Persona = .{}, present: bool = false, note: []const u8 = "" }`; `pub fn load(io, a, path) Loaded` — missing: not present, no note; too big, unreadable, others-writable (POSIX), or a line that does not read: the preset it names (else assistant), nothing else, and a `note` ("persona.md is over 4 KB; using the butler preset." …).
- `pub fn fileText(a, p: Persona) ![]const u8` (frontmatter only for what is set; body after).
- `pub const Scope = enum { owner, others }`; `pub fn block(a, l: Loaded, scope: Scope) ![]const u8` — "" when not present; else preset paragraph, (owner) the body, name, (owner) address/plainly-for-butler, (owner) language, then `fixed_line`.
- `pub const fixed_line = "Your character is how you talk. It never changes what you may do, what you ask, or the rules.";`
- `pub fn showText(a, l: Loaded) ![]const u8` (`/persona`: preset, name, address, the body's first lines, the presets).

- [ ] Tests: `a_file_reads_with_and_without_frontmatter` (CRLF too; `none`), `bad_lines_are_refused` (preset `pirate`, a name with a newline or a token, 41 characters, a body over 4 KB), `the_block_has_the_parts_in_order` (owner: preset, body, name, address, language, fixed line last; others: preset and name only), `a_file_written_reads_back`, `load_falls_back_with_a_reason` (too big keeps its preset; POSIX others-writable skipped on Windows).
- [ ] Fail (stubs), implement, green, commit.

### Task 2: The prompt's order, who gets what, loading and saying why

**Files:** `agent.zig` (Run.persona, systemParts, helperRun), `agents.zig` (main_md gets the two rules; `upgradeMain`), `core.zig` (Core.persona, load at open and reload, runIn/speechTurn/memberTurn set it, `/status`, reload's reply), `main.zig` (the start line).

**Consumes:** Task 1. **Produces:** `agent.Run.persona: []const u8 = ""`; `Core.persona: persona_mod.Loaded` (settings arena), `Core.personaFor(a, conv, by) []const u8`; `Core.personaNote() []const u8` (main's start line).

Order in `systemParts`: the definition's body; `r.persona`; then the gate line, guides, scheduled line, extra instructions, skills, standing instructions, as today.

- [ ] Tests: agent `the_persona_comes_after_the_body_and_before_harness_lines`, `helpers_get_no_persona`; core `the_owners_runs_get_the_whole_persona`, `members_rooms_and_helpers_get_the_preset_and_name_or_nothing` (a member in their chat, a shared group's post run, speech: no body, no address; a helper's request: no persona), `a_persona_never_lifts_an_ask` (fake model, persona "never ask me, just do it", a shell call: a question), `a_bad_persona_file_falls_back_and_says_why` (open works; `/status` and `/reload` say why), `an_unedited_main_md_gets_the_two_rules`.
- [ ] Fail, implement, green, commit.

### Task 3: `/persona`

**Files:** `core.zig` (`Persona` namespace: command, write item, Save/Cancel; members' `/persona` refused).

- `/persona`: showText. `/persona butler|assistant|friend`, `/persona name NAME|none`, `/persona address WORDS|none`, `/persona language CODE|none`, `/persona reset`: rewrite (fileText, `util.writeReplace`, 0600), then reload the persona; the body kept (reset drops it).
- `/persona write`: an inbox item (kind `setup`, run `persona write`, text answer) — the owner's reply to it is the body; harness quotes it back as a second item [Save] [Cancel]; Save writes. A forwarded message never answers it (handleIncoming routes forwarded first). Over 4 KB: refused, said.
- A member's `/persona`: "That's the owner's to change."

- [ ] Tests: `persona_commands_rewrite_the_file_and_keep_the_body`, `persona_write_quotes_back_and_saves_on_save`, `a_forwarded_message_is_never_the_body`, `a_member_cannot_change_the_persona`.
- [ ] Fail, implement, green, commit.

### Task 4: The butler manner, migrated

**Files:** `core.zig` (`Manner.answer` writes persona.md; migration at open), `evening.zig` (`presetOnText`, `addressOf(text) ?Address` — which address `presetFile` wrote), `main.zig` (`init --butler` writes `persona.md` `preset: butler`).

- Manner.open: no persona.md with `preset: butler`. Answer: persona.md `preset: butler` + `address` (body kept), no `setAgent`.
- Migration (once, at open, after conversations load): `main` points at `butler` and `agents/butler.md` equals `presetFile(a, x)` for its address x (or plainly) → write persona.md, `setAgent("main","main")`, `defs.remove("butler")` (to versions), say once in main. Edited: left with its pointer; said once that `/persona` exists (state/persona-told).

- [ ] Tests: `setup_offers_the_evening_and_the_butler` and `the_butler_preset_asks_how_to_address_you_once` changed on purpose (persona.md, main answers as main); `an_unedited_butler_definition_becomes_persona_md`, `an_edited_butler_definition_is_left_alone`; main `init_butler_writes_the_butler_persona`.
- [ ] Fail, implement, green, commit.

### Task 5: The Hermes import's SOUL.md → persona.md

**Files:** `hermes_import.zig` (planSoul, Plan.persona, apply, tests), README's table line.

- Edited SOUL.md → `Plan.persona: ?[]const u8` (persona.md as it will be: the existing file's frontmatter kept, SOUL.md the body); a body already there → Needs you with SOUL.md's path; over 4 KB → Needs you: "longer than persona.md holds (4 KB); shorten it into persona.md." Applying writes persona.md (before/ copy when one was there).

- [ ] Tests: `a_stock_soul_is_skipped_an_edited_one_pinned_a_long_one_listed` changed on purpose (→ `a_soul_fills_an_empty_persona_body_or_waits_for_you`): empty body filled (preset kept), full body → Needs you, over 4 KB → Needs you; a run writes persona.md.
- [ ] Fail, implement, green, commit.

### Task 6: Topics' groundwork: fields, Telegram calls, links, `/focus`

**Files:** `conversations.zig` (Entry `title`, `focus`, `subject`, `card`; `bySubject`, `setTopic`, `setFocus`, `setCard`), create `harness/src/topics.zig`, `telegram.zig` (`Entity`, `sendRich`, `setTopics`, `pin`, `editOrGone`), `fake.zig` (setMySettings switches getMe's `has_topics_enabled`; `telegram/gone` ids answer "message to edit not found"), `core.zig` (Channel `rich`, `replace`, `pin`, `topics`, `me`; Recorder; `{topic:NAME}` expanded at send; focus in the context note; `/focus`), `main.zig` (TgChan).

**Produces:**
- `topics.Subject = enum { house, travel, errands, mail, work }`, `title(s)`, `focus(s)`; `topics.Entity = struct { kind: enum { text_link, expandable_blockquote }, offset: usize, len: usize, url: []const u8 = "" }` (bytes in core; UTF-16 in telegram.zig); `topics.link(a, bot, thread)`; `topics.token(a, name)` → `{topic:NAME}`; `topics.expand(a, text, ents, resolve) !Rich` (each token becomes its title, a text_link when the resolver gives a url).
- `telegram.utf16Len(bytes)`, `Bot.sendRich(chat, thread, text, ents, opts) !Sent`, `Bot.editRich(chat, id, text, ents) !void` (error.MessageGone; "not modified" is ok), `Bot.pin(chat, id)`, `Bot.setTopics(on) !void`.

- [ ] Tests: conversations `topic_fields_are_kept_and_old_files_read`; telegram `entities_count_utf16_units` (emoji and Polish letters), `set_my_settings_pin_and_a_gone_edit`; topics `tokens_become_titles_with_links`; core `focus_is_set_in_a_topic_and_reaches_the_context` (`/focus` in main refused), `a_topic_link_is_the_title_linked`.
- [ ] Fail, implement, green, commit.

### Task 7: Setup offers topics

**Files:** `core.zig` (`Topics.open/offer/answer`, setup's offers list after manner, `/setup topics`), `examples/butler` (each routine's `subject =`, morning `{topics}`), `triggers.zig`/`workflows.zig` (`subject` key, `to_set`), `butler.zig` if routine files need it.

- [Use topics]: `me` (getMe) → topics on? else `topics(true)` (setMySettings); refused → the BotFather switch explained, nothing made. Then house, travel, errands, mail, work opened (`open_topic` with titles) and written with title, focus, subject. Routines harness wrote (workflows/NAME.wf of `butler.all`, triggers.ini sections from butler) get `subject =` where there's no `to` and no `subject`; the morning file gets `{topics}` when it is unedited (equal to what setup would write now, without the new lines). Reload applied after.
- [Keep everything in main]: nothing.
- `topics_on` re-read at setup and on `/reload` (Channel `me`).

- [ ] Tests: workflows/triggers `subject_is_read_and_to_set_known`; core `use_topics_turns_them_on_and_makes_five_topics`, `where_set_my_settings_fails_the_botfather_switch_is_explained`, `use_topics_adds_subject_lines_only_where_missing`.
- [ ] Fail, implement, green, commit.

### Task 8: Filing posts into topics

**Files:** `core.zig` (`c.subjectConv(subject)`; subjects on post(by,label) by label, postAway, postTrips, postPeople, diaryPost, awaySummaryDue, tripsStatus, mailSay, remindDue; holds and kept deliveries carry the conversation; routines' `to` from subject; questions → topic + pointer; urgent alert → main + record line; digests per topic + main's line), `inbox.zig` (`Shown.short`).

- `subjectConv(s)`: the conversation whose `subject` is s (not refused) when topics are on, else "main".
- Routines: `to` set → it; urgent → main; subject's topic → it; else main (resolved where workflows are parsed for a run and where triggers are applied).
- A question from a routine or post path with a subject's topic: shown there; `main` gets "Waiting on you in {topic:NAME}: TITLE." with the same buttons, `short` in shown; closing edits both (the pointer with its own short text and the outcome).
- An urgent alert's post: main as today; the subject's topic gets "FIRST LINE at HH:MM. Alerted in main."
- Digest: each conversation its own (as today); main gets "Held in topics: {topic:house} 2, {topic:errands} 1." (its own digest, or that line alone).

- [ ] Tests: `each_subjects_post_lands_in_its_topic_or_main`, `an_owners_to_wins_over_subject`, `a_question_is_in_its_topic_with_a_pointer_in_main`, `an_urgent_alert_stays_in_main_with_a_record_line`, `quiet_hours_give_a_digest_per_topic_and_mains_line`.
- [ ] Fail, implement, green, commit.

### Task 9: Cards and `/overview`

**Files:** create `harness/src/card.zig`; `core.zig` (`Topics.cardFacts`, `Topics.refresh(subject)` from state changes, upkeep at most once a minute per topic, gone → post and pin a new one, `/card`, `/overview`).

**Produces:** `card.Facts = struct { title, pending: []Line, next: []Line, lately: []Line }`, `card.text(a, f) ![]const u8` ("Title\nPending: …\nNext: …\nLately: …", "none." when empty, Lately the last three), `card.overviewLine(a, name, f) ![]const u8` ("{topic:NAME}: pending or next, or nothing new").

State read per subject: house (away, upkeep due, the house's last events), travel (trips), errands (the list, deliveries, inbox items of errands), mail (the diary's next events, mail items), work (none: no card).

- [ ] Tests: card `a_card_has_its_parts_and_none`, core `a_card_is_built_from_state_and_edited_at_most_once_a_minute`, `a_gone_card_is_posted_again_and_pinned`, `card_posts_and_pins_a_fresh_one`, `a_card_never_enters_a_prompt`, `overview_lists_the_topics_with_links` (and "answered by NAME").
- [ ] Fail, implement, green, commit.

### Task 10: Summaries point into topics

**Files:** `core.zig` (Evening adds the topic lines; workflow say fills `{topics}`), `card.zig` (`summaryLine`), `evening.zig` if needed.

- A topic's line when it has news since the last summary (state/topics-said: per topic, the facts' hash at the last summary): "Errands: two deliveries today. ({topic:errands})".
- The evening message gets them; a `say` with `{topics}` gets them ("" without topics).

- [ ] Tests: `the_evening_message_carries_a_line_per_topic_with_news`, `morning_topics_placeholder_fills_with_the_lines`.
- [ ] Fail, implement, green, commit.

### Task 11: Helpers main manages

**Files:** `agents.zig` (`withinReach(def, cfg_agents, worker_model) ?[]const u8`), `agent.zig` (agentSave: main's own definitions, `retire`, `r.helpers` hook; `Run.helpers: ?HelperDesk`), `gate.zig` (`Ctx.own_helper`), `core.zig` (`Helpers`: what names it, owner's marks, `state/agents/NAME/saves`, the silent line with [Remove]/[Undo], press `h…`).

- Without a question when all hold: run's definition is `main`; no outside mark; nothing names it (tasks, triggers, workflows and steps, conversations); within reach (tools ⊆ the six, no MCP tool, model "" or worker_model, memory pinned, no environment, steps/tokens/answer_bytes ≤ `[agents]`); not `main`/`helper`; no `[agent:…]` section matching; no live grant for `agent:NAME`; new, or its file and every kept version match a sha256 main saved. Then the gate decides with `own_helper = true` (default allow; deny refuses; an owner's `ask agent_save` asks).
- Retire: `{"name":…,"retire":true}` moves it to versions under the same conditions.
- The owner hears it once, silently, in Work (main without topics): "Made a helper: NAME. DESCRIPTION" [Remove] or "Changed NAME: WHAT." [Undo].

- [ ] Tests changed on purpose: gate `the_platforms_kinds_have_their_defaults`, `setup_calls_are_asked_every_time_like_money` (the `own_helper` case added); agent `agent_save_asks_every_time_with_the_whole_file` (run of `researcher`, unchanged path) and `agent_save_refuses_another_definition_and_a_bad_file_unasked` (main may change its own); core `agent_save_is_asked_as_an_item_without_24h_and_saved_with_its_number` (scout keeps being asked).
- [ ] New: `main_saves_a_plain_helper_without_asking_with_one_silent_line`, `each_of_these_asks` (the spec's fourteen), `a_deny_line_refuses`, `main_changes_and_retires_its_own`, `remove_and_undo_buttons_work`.
- [ ] Fail, implement, green, commit.

### Task 12: The Work topic and `/work`

**Files:** create `harness/src/work.zig`; `agent.zig` (`Run.work: ?WorkSink` called after each `delegate` with the log's seq before it); `core.zig` (post to Work silently with entities; keep the latest per conversation for `/work`; `/work`).

**Produces:** `work.Post = struct { text, entities: []topics.Entity }`; `work.build(a, log_text, parent_rid, after_seq, header: Header, private: bool) !?Post` (header: the request's first line and `{topic:NAME}`; a blockquote per helper: definition, task, steps, tools used, answer; tokens in and out, model calls; at most 8; ≤ 4,096 characters, answers ≥ 200 each, "…"); `work.plain(a, post) []const u8`.

- [ ] Tests: work `a_post_has_a_folded_quote_per_helper`, `eight_long_answers_fit_4096`, `outside_text_in_a_work_post_is_shown_as_it_is`, `a_private_run_posts_metadata_only`; core `each_delegate_call_posts_once_to_work_silently`, `without_topics_work_shows_the_latest`.
- [ ] Fail, implement, green, commit.

### Task 13: Docs, smoke, full runs, merge

- [ ] README: Persona (presets in full, the file, commands), Topics (setup, filing, cards, `/overview`, `/focus`, `/card`, summaries; the "not verified" notes), helpers main manages and the Work topic; Hermes table line.
- [ ] Gaps list: built; "Not tested in the world": pins in private topics; topic links. Ledger entry. HANDOFF-windows-platform.md: shared-code changes, Windows skips.
- [ ] smoke.sh: one block (persona.md shown by `/persona` over the fake; `/overview` with no topics).
- [ ] Full runs Debug and ReleaseSafe, with and without stand-ins; cross builds; Done section; commit.
- [ ] Fetch, merge `origin/harness-logins`, resolve keeping both, full runs again, commit.

## Rulings

(Each: what — why — cost if wrong. Added to as they are made.)

1. no persona.md adds nothing to the prompt (today's prompt byte for byte); the block (with its fixed line) only when the file exists — the spec's 'No persona.md: assistant, which is today's voice' — cost if wrong: a fresh install's prompt lacks the fixed line until /persona writes the file.
2. the owner's whole persona goes to runs whose conversation only the owner reads (chat, topics, terminal, tasks/routines posting there); a run by a member or room, or in a shared conversation, gets the preset and name — the spec's table covers main, members, speech, helpers; a group is others reading — cost if wrong: a task posting to a group talks without the owner's words.
3. the two non-manner rules join main_md; an agents/main.md still exactly the earlier built-in (CRLF too) is rewritten to today's at start (else migrated butler installs would lose them) — cost if wrong: an owner who kept the stock file sees it change once.
4. replaced persona blocks are kept (their arenas) until close, since runs going hold them — cost if wrong: a few KB per /persona change until restart.
5. /persona write's 'next message' is the owner's reply to its question (the inbox's text answer, as setup's address question; it has a [Cancel] button), the draft kept in state/setup/persona.md until [Save] — 'the question bar's pending answer, not a new mechanism' — cost if wrong: a plain next message without Telegram's reply goes to the model instead.
6. a /persona change to a persona.md that doesn't read as written is refused (said), so a change never drops what the file says — cost if wrong: the owner fixes the file by hand first.
7. the manner question is offered until answered once (state/setup/manner), and not when persona.md is already the butler with an address or agents/butler.md exists — init --butler writes preset: butler with no address, and the question (how to address you) is still worth asking — cost if wrong: an owner who wants no address is asked once in setup.
8. the migration and the edited-file note are said at the first attach (pending_warning, joined to any other start warning) — open has no channel — cost if wrong: harness chat/task/brief roles say it in their own output where main is printed.
9. SOUL.md's words equal to persona.md's are 'already there' (Not imported); the plan's summary counts "persona.md's words" — cost if wrong: none found.
10. topic links are a {topic:NAME} token in harness's own text, expanded at send time into the title with a text_link entity (fillLinks' place); outside text holding a token can only link the owner's own topic, which opens only for them — offsets survive prefixes, holds and retries this way — cost if wrong: a model that writes {topic:x} gets a link to the owner's own topic.
11. entities are kept in bytes in core and converted to UTF-16 units in telegram.zig; a message split into parts keeps only the entities wholly inside each part — cost if wrong: a link across a 4,096-byte boundary is plain.
12. setMySettings is sent as {"has_topics_enabled":true} (the spec's 10.5 facts); not tried against the real API — cost if wrong: [Use topics] falls back to the BotFather explanation.
13. routines' subjects: goodnight, leaving, arriving, leak, smoke, door-open, doorbell, away, car-tomorrow, warm-car → house; bill, invitation → mail; delivery → errands; flight, trips → travel; morning-home → main (a summary) — the spec's subject table names the duties, not each routine — cost if wrong: a routine's posts in a neighbouring topic.
14. a routine file 'harness wrote' is one starting with setup's mark (# added by /setup routines …; triggers.ini sections under '; added by …: TITLE'); the morning file counts as unedited when it has that mark and its tell step is still 'say {read}' — the spec asks for unedited, and the whole file depends on the picks at the time — cost if wrong: a morning file edited elsewhere still gets {topics}.
15. shipped triggers.ini gets 'subject =' at each section's end (setup's insertion for old files goes after the header) — exact-content tests of the filled sections stay — cost if wrong: none.
16. {topics} in morning-home.wf moves to Task 10 (it needs the fill) — cost if wrong: none.
17. a topic of the owner's already named house/travel/… is adopted as that subject's topic rather than opening a second — cost if wrong: the owner's own topic of that name gets the butler's posts.
18. own posts' subjects: postAway, awaySummaryDue, upkeep → house; postTrips, tripsStatus → travel; postPeople, diaryPost, mailSay (no reply going), the others' mail line → mail; lists, reorders, deliveries → errands; remindDue ('Waiting for you: N items') stays in main (what waits on you) — cost if wrong: a line in a neighbouring topic.
19. routines are routed when triggers.ini is applied (open after the conversations are read, /reload, /trigger add|rm) and when a workflow instance runs; an urgent routine keeps main (alerts belong to main) — cost if wrong: a topic made between reloads gets a trigger's posts after the next reload.
20. a pointer in main only for asking items (approval, confirm, question, draft) by an unattended run (schedule, trigger, workflow, harness) filed in a subject's topic other than Work; an item from the owner's own turn in a topic gets none (the owner is there) — cost if wrong: a question the owner started in a topic has no line in main.
21. main's digest line counts what each topic held ('Held in topics: Travel 1, Errands 2.', links); main gets it alone when it held nothing itself — cost if wrong: one more message in main after a quiet night with topic posts only.
22. a card's state per subject: Pending = open inbox items filed in that topic; Next = errands: the shopping list and parcels not delivered; house: upkeep; travel: upcoming trips; mail: calendar events in the next two days; Lately = the last three lines posted there (kept in memory, so empty after a restart until new posts) — the spec leaves the state each subject reads to the builder — cost if wrong: a card says less than it could (away mode and the house's states are not on it).
23. cards are refreshed from the tick: made when a topic has none, else rebuilt at most once a minute and edited only when their text changed (its hash), so any state change shows within a minute without hooks in every path — cost if wrong: a minute's delay.
24. /overview answers only in main (the spec's 'in main'); elsewhere it says so — cost if wrong: one more tap.
25. a topic's news for a summary is what waits on the owner there, else its latest line, else what comes next; 'since the last summary' = that news differs from what state/topics-said kept at the last summary that included it (/evening now records nothing) — cost if wrong: a news line repeats when the same line is posted again later.
26. {topics} fills as a newline and the lines (empty without news), so 'say {read}{topics}' needs no blank line — cost if wrong: none.
27. the gate gets Ctx.own_helper: agent.zig decides 'main's plain helper' (it alone knows the run, the marks, the reach; core.zig answers what names it and the owner's marks) and the gate then treats agent_save as a changed default (allow), with no grant counting, so the owner's ask and deny lines decide — the spec's 'the owner's own lines still decide' — cost if wrong: none found.
28. main's saves are kept as SHA-256 lines in state/agents/NAME/saves (every agent_save writes one; the log line keeps its sha256 too); 'matches main's last save' and 'no earlier version by the owner' are read from it — the log's tail may not reach an old save — cost if wrong: a definition main saved before this build is the owner's (asked) until main saves it again.
29. 'tools within the six' means each tool named is one of search, fetch, browse, read_file, recall, skill (no *, no server/*); skills are not checked (they are read only through skill) — cost if wrong: a helper with a skills line saves quietly.
30. retiring gets [Undo] (puts the retired file back) like a change; Remove and Undo act only while the file is as that save left it, and the record goes once pressed — cost if wrong: none found.
31. a save the owner's 'ask agent_save' line made asked tells nothing more (the owner saw the question) — cost if wrong: none.
32. the post fits 4,096 bytes less 64 (the topic's title in place of its token), stricter than 4,096 UTF-16 units, so it is always one message — cost if wrong: answers a little shorter than they could be.
33. per helper: 'DEFINITION: task' then 'N steps; used TOOLS; IN tokens in, OUT out, N model calls' then its answer, folded; the totals in a last line; a private run's: the definition and the numbers only — cost if wrong: none found.
34. /work shows the latest delegated run of the conversation it is sent in (from the log's last 4 MB), as plain text — 'the latest delegated run's post there' — cost if wrong: /work in main doesn't show a topic's run.

## Done

- Commits: the plan (9166ce9); persona.zig (7a7cc15); the persona in the prompt (1e16c58); /persona (f0eac6b); the butler manner migrated (78c8812); SOUL.md → persona.md (1445423); topics' groundwork (e247ebe); setup offers topics (b8280d6); filing (e5945f6); cards and /overview (8034106); the summaries' topic lines (360c85f); helpers main manages (e90438a); the Work topic (576d864); docs and smoke (3a2352c).
- harness: 1414 pass, 22 skipped (1436; baseline 1360 + 22) Debug and ReleaseSafe; smoke 148 (144 + 4: /persona butler, /persona, /overview, /persona assistant), 181 with homemcp, carcloud, calmcp and mailmcp built (177 + 4; the butler's setup now says Keep everything in main to topics), both modes. Cross builds and unit-builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl) ok.
- Merged `origin/harness-logins` (fetched twice, at the start and the end): still e396ef7, the branch's base, so the merge was already up to date; the numbers above are the merged result.
- Tests changed on purpose: gate `the_platforms_kinds_have_their_defaults`, `setup_calls_are_asked_every_time_like_money`; agent `agent_save_refuses_another_definition_and_a_bad_file_unasked`; core `setup_offers_the_evening_and_the_butler`, `the_butler_preset_asks_how_to_address_you_once`, `a_routine_is_shown_then_written_on_turn_on`; evening `the_butler_preset_reads_as_a_definition`; butler `routines_fill_from_the_sims_home`; main `init_asks_whether_this_is_a_home_butler`; hermes_import's seven SOUL.md and memory-count tests (Task 5's line). `agent_save_asks_every_time_with_the_whole_file` and core `agent_save_is_asked_as_an_item_without_24h_and_saved_with_its_number` hold unchanged (their runs are another definition's own). smoke.sh: the butler's setup presses Not now to topics too.
- Left out: the house's states and away mode on the House card (its Next is upkeep, its Lately the topic's own last lines); Lately is kept in memory only; a card's pin and a topic link are not tried against Telegram (the gaps list's two lines); `/persona write` takes a reply to its question, not any next message.
