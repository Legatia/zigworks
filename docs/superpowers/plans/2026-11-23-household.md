# harness: household members (Part 6 of the butler spec) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The family uses the owner's harness, safely. The owner adds a member with `/member add NAME`; harness answers with a one-time code (8 characters, 10 minutes) the person sends to the bot (`/join CODE`, or the `t.me/BOT?start=CODE` link, in a direct chat or in a group the owner registered). `/members` lists them, `/member rm NAME` ends it; they are kept in `state/members` (written whole). A member's message in a registered group or in their own direct chat starts a run whose who is `member:NAME`; anyone else stays ignored (logged as dropped). Members' calls are decided by `[member]` and `[member:NAME]` sections in `rules`, with defaults when the owner wrote none: search, homemcp's reads and `home_set` (lights, plugs, climate, covers within homemcp's limits) alone; guarded and money tools always the owner's one-tap question ("Anna asks to unlock the front door" [Unlock] [No]); never files, shell, the browser with logins, memory, setup kinds or settings commands. A call that needs the owner does not make the member's run wait: the owner gets the question, the member is told at once that the owner was asked, and the owner's tap makes that exact call and tells both what happened.

**Architecture:** `who.zig` gets the kind `member`. `gate.zig` decides a member's call in its own order (`decideMember`): what members may use at all, a deny anywhere, money asked every time, the member's own conversation for posts, then `[member:NAME]`, `[member]`, the household defaults; the shared part and the definitions' sections only narrow; no grant covers a member; no "Allow 24 h". A new `household.zig` holds the members file (names, codes as hashes, accounts), the asks waiting for the owner (`state/member-asks`), the plain words of a call ("unlock the front door", [Unlock]) and the members' messages. `agent.zig` offers a member's run only `send`, `search`, `fetch`/`browse` (when a member rule names them) and MCP tools, sends no files from it, and passes the call's kind and argument with a question. `core.zig` reads non-owners' messages (`/join`, a member's text and commands), runs a member's turn on the chat worker with harness's household instructions, an empty memory, no history or summaries and only its own conversation, turns the gate's ask into the owner's item (waiter `member NAME`) and, on the owner's answer, makes the call on a thread of its own (`agent.stepCall`, the gate deciding again) and says the outcome to the member and on the owner's message. `fake_mcp.zig` gets a homemcp stand-in (`--mcp --home`) for the tests.

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-butler-design.md` (UX rules, Part 6, red lines, tests); the overview's Who, Rules, Grants and nobody-can-answer runs (`2026-11-22-harness-platform-overview.md`); conversations (groups, `/conversation add`, audience shared, pairing) and the inbox (only the owner answers; items of shared conversations shown in main).

## Global Constraints

- Work in `who.zig`, `rules.zig`, `gate.zig`, the new `household.zig`, small edits in `agent.zig` (offered tools, `Question`, the send guide, files in a member's send), `core.zig` (non-owners' messages, pairing, commands, the member's turn, the asks, one line in `settle`), `fake_mcp.zig`/`fake_main.zig` (the stand-in), `config.zig`'s rules comment only, README. Another builder changes `telegram.zig`, `config.zig` (`[voice]`, `[butler]`) and core's posting path; one changes `homemcp/`.
- Every new Core field is set in `Core.open`; state files go through `util.writeReplace`; codes are never logged, stored in the clear or shown to anyone but the owner.
- Existing tests change only where behaviour changes on purpose (listed in Done).
- Baseline: 798 pass, 19 skipped, smoke all ok (85 checks).
- Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc-household > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; the full suite per task; `-Doptimize=ReleaseSafe` and the cross builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `zig build` and `unit-build`, `-p` into a scratch folder) at the end.

## Review Focus: privacy between members and the owner

What a reviewer checks first, each with the test that holds it:

1. **A member's run sees nothing of the owner's.** Its prompt has harness's household instructions, not `agents/main.md`'s body; an empty memory (no pinned or strongest items, no recall); no summaries and no `history`; a context note naming only its own conversation and who wrote; its outbox knows only its own conversation (an unknown name lists nothing); no `read_file`, `shell`, `web`, `recall`, `remember`, `skill`, `delegate`, `ask_owner`, setup tools; `send` carries no workspace files. (`a_members_run_sees_nothing_of_the_owners`.)
2. **The owner's rules and grants written for the owner don't reach members.** The shared part and `[agent:…]` sections may deny or ask, never allow, for a member; grants (a 0.3 one for any run, `agent:main`'s 24 h ones) never cover a member; a member's question never offers "Allow 24 h". (gate tests.)
3. **Only the owner decides.** Items for members' asks are shown in the owner's chat (`main`), answered only by the owner's presses or replies; a member's press is dropped. The call made on Yes is the exact argument asked about, decided again by the gate (a deny added meanwhile stops it). (`a_members_unlock_becomes_the_owners_question`, `members_never_answer_items`.)
4. **Members' chats stay out of the owner's memory.** A member's turns are never read by the memory writer. (`a_members_run_sees_nothing_of_the_owners`.)
5. **Codes.** 40 bits from the system's secure random source, stored as SHA-256, compared whole, once, for 10 minutes; never in the log or the model's requests. (`the_owner_adds_a_member_with_a_one_time_code`.)

## Rulings

(Each: what – why – cost if wrong. Added to as they are made.)

1. **A member's call that needs the owner does not wait.** What: the gate's `ask` in a member's run becomes the owner's item at once and the call stops there (`Answer.deferred`, as a workflow's tool step); the member is told by harness that the owner was asked; the owner's Yes makes that exact call on a thread of its own and harness says the outcome to the member, read back as the tool gives it. Why: one chat turn runs at a time; a member's run waiting up to 10 minutes for the owner would hold everyone's messages, the owner's too. Cost if wrong: the outcome is the tool's own words ("done: front_door is unlocked"), not the model's.
2. **Only MCP calls can wait for the owner.** What: for a member, an `ask` on `fetch`, `browse` or `send` is a refusal ("an allow line under [member] lets members use it"); MCP calls (`mcp`, money) become the owner's question. Why: an MCP call is an action harness can make on a tap; a page read or a post only means something inside the run that asked. Cost if wrong: `ask fetch *` under `[member]` refuses instead of asking.
3. **Household defaults.** What: with no member line deciding a call: `search` allowed; MCP tools named `home_state`, `home_wait`, `home_set` (homemcp's reads and ordinary devices, on any server name) allowed; other MCP tools asked of the owner; money tools (homemcp's `home_guarded` when mcp.ini lists it) asked every time; `fetch` and `browse` refused; a post only to the member's own conversation. Why: the spec's "reads, and lights, plugs, climate and covers within limits"; a page read could carry the home's state out in its address; the car's status can carry its location, so it is the owner's to allow. Cost if wrong: a member asking for the car's battery makes the owner tap once (`[member]` `allow mcp cloud/car_status *` lifts it); another server's tool called `home_set` would be allowed.
4. **What members never get, whatever the rules.** What: `shell`, `read_file`, `write_file`, `web`, `login`, `recall`, `remember`, `history`, `skill`, `skill_save`, `delegate`, `ask_owner`, `snapshot`, `trigger`, `workflow`, `agent_save`, apps' and environments' kinds, `mail`; the run is not offered them and the gate refuses them. Why: each reaches the owner's files, machine, accounts, memory or settings. Cost if wrong: the owner can't share a folder with the family through harness.
5. **The shared part and definitions' sections only narrow for members.** What: a deny there stops a member's call, an ask there turns a member's allow into the owner's question; an allow there does not apply to members. Why: those lines were written for the owner's runs (`allow shell make*`, `allow mcp github/*`). Cost if wrong: an owner who wants a line for everyone writes it under `[member]` too.
6. **`[member:NAME]` before `[member]`.** What: the first matching allow or ask in a section naming members (`[member:anna]`, `[member:a*]`), then in `[member]`, then the defaults. Why: the narrower section is the owner's word about that person, whichever comes first in the file. Cost if wrong: none found.
7. **A member's run uses harness's household instructions, not agents/main.md's body.** What: the conversation's definition (tools, model, limits) with harness's own instructions for members. Why: main.md is the owner's and may hold personal details. Cost if wrong: the owner's language or style lines don't carry over to members.
8. **The owner's own messages in a group stay as today** (only `/conversation add` is read there). Why: in a group the family asks; a run of the owner's has the owner's memory and tools, and its every post where others read is asked. Cost if wrong: the owner can't ask in the family group; a later step can run them with the household's scope.
9. **A member's direct chat is a conversation named after the member** (`anna`; `anna-2` when that name is taken), audience shared, made when they join there or at their first direct message. Why: the owner's agent can then post to them (asked every time, as to a group), and routing in stays by chat and thread. Cost if wrong: none found.

## Files

- Modify `harness/src/who.zig` (kind `member`, `isMember`), `harness/src/rules.zig` (the section reason), `harness/src/gate.zig` (`Ctx.here`, `decideMember`, `memberOffers`, `allow_day`).
- Create `harness/src/household.zig` (members file, codes, asks file, plain words, tests).
- Modify `harness/src/agent.zig` (`Run.allows` for members, `Question.tool`/`arg`, `Ctx.here`, the deferred reason's text, no files in a member's send, the send guide for members).
- Modify `harness/src/core.zig` (Core field, non-owners' messages, `/join`, the member's turn, `/member`, `/members`, help, the asks, `settle`'s hook, pairing, tests).
- Modify `harness/src/fake_mcp.zig`, `harness/src/fake_main.zig` (`--mcp --home`), `harness/src/config.zig` (rules comment), `harness/README.md`, `harness/build.zig` only if the new file needs adding to the test list.

---

### Task 1: The member kind and its decisions

**Interfaces — Produces:** who.zig `member` kind, `pub fn isMember(by) bool`; gate.zig `Ctx.here: bool = false` (a send to the run's own conversation), `Gate.memberOffers(g, tool, who) bool`, member decisions in `decide`.

- [ ] **Step 1: Write the failing tests:**
  - who.zig `member_is_a_who_kind`: `member:anna` a value, `member`, `member:a*` patterns; `matchesBy("member", "member:anna")`; not `owner`; not unattended.
  - rules.zig `member_sections_parse`.
  - gate.zig `a_members_defaults`: home_state, home_wait, home_set (any server) and search allowed; another MCP tool asked; money asked with no 24 h; fetch and browse refused; send to `here` allowed, elsewhere refused; shell, read_file, write_file, web, recall, remember, history, skill, delegate, agent_save, trigger add, workflow save, ask_owner, snapshot refused even with `[member]` allow lines; `allow_day` false for every member decision.
  - gate.zig `member_sections_decide_for_members_only`: `[member]` allow, `[member:anna]` ask over it, `[member:ben]` doesn't reach anna; a `[member]` allow for fetch; the shared part's allow and `[agent:main]`'s allow don't reach a member, their deny and ask do; `[owner]` doesn't reach; an ask for fetch under `[member]` is a refusal.
  - gate.zig `no_grant_covers_a_member`: a 0.3 grant, an `agent:main` grant, a `member:anna` grant: still asked.
  - gate.zig `member_offers_fetch_only_when_a_member_rule_names_it`.
- [ ] **Step 2:** run; expect compile errors / failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green.
- [ ] **Step 5:** commit `harness gate: household members' calls (member:NAME, [member] sections, defaults) (Part 6)`.

### Task 2: Members, codes and members' runs

**Interfaces — Produces:** household.zig `validName`, `Members` (`load`, `save`, `add`, `remove`, `join`, `byUser`, `find`, `list`), `newCode`, `display`, words; core.zig `/member add|rm NAME`, `/members`, `/join CODE` and `/start CODE` from non-owners, members' messages queued with the member's name, `memberTurn`; agent.zig `Run.allows` for members, no files in a member's send, the members' send guide.

- [ ] **Step 1: Write the failing tests:**
  - household.zig `member_names_codes_and_the_file`: the name rule; a code joins once, within 10 minutes, compared whole and in any case; the file holds SHA-256 of the code, never the code; it reads back; a second account can't take a used name's code.
  - core.zig `the_owner_adds_a_member_with_a_one_time_code`: `/member add anna` → a code; `/members`; a wrong code refused; the code from account 77 in a direct chat joins (welcome to 77, the owner told in main); used again from 78 refused; expired refused (`fixed_now` + 601); `/member add Bad Name` refused; the code nowhere in the log.
  - core.zig `a_members_run_sees_nothing_of_the_owners`: a pinned memory and a topic `house-search` exist; anna writes in her chat: the request has the household instructions and "From: Anna", not main.md's body, the pinned item, `house-search`, `shell`, `read_file`, `recall`, `remember`, `history`, `delegate`, `ask_owner`; the log's run line says `"by":"member:anna"`; the reply goes to her chat; no memory written from her turns.
  - core.zig `a_member_in_a_group_and_strangers`: a registered group; anna's message there runs in that conversation and is answered there; a stranger's message there and in a direct chat dropped and logged; `/join` in an unregistered group dropped.
  - core.zig `a_member_cannot_change_settings`: `/reload`, `/dryrun on`, `/member add ben`, `/private on` from anna answered "Commands are for the owner…", nothing changed; `/help` gives the members' help.
  - core.zig `member_rm_ends_their_access`: `/member rm anna`: her next message dropped, her conversation gone; `/members` empty.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green.
- [ ] **Step 5:** commit `harness: household members — /member add|rm, /members, /join; members' runs with the household's scope (Part 6)`.

### Task 3: Asks become the owner's one-tap question

**Interfaces — Produces:** household.zig `Asks` (`state/member-asks`: `add`, `take`, `openOf`), `plainCall(a, arg)`, `yesLabel(a, arg)`; agent.zig `Question.tool`, `Question.arg`; core.zig `MemberAsk` (the member's asker), `memberAnswered(id)` from `settle`, `memberCall` on a thread; fake_mcp.zig `--home` (home_state, home_set, home_guarded, home_wait).

- [ ] **Step 1: Write the failing tests:**
  - household.zig `a_call_in_plain_words`: `home/home_guarded {"device":"front_door","action":"unlock"}` → `unlock the front door`, [Unlock]; on/off → `turn on the hall light`, [Turn on]; a value → `set the thermostat temperature to 21`; a device with odd characters, or another tool → the server, tool and input as given, [Allow].
  - core.zig `a_member_turns_a_light_on`: the stand-in; anna asks; the model calls `home__home_set` → no question, the reply posted to anna.
  - core.zig `a_members_unlock_becomes_the_owners_question`: `home__home_guarded` unlock → in main `Anna asks to unlock the front door.` with [Unlock] [No], no "Allow 24 h"; anna told `I asked the owner: unlock the front door.`; the model's result says it waits (item 1); the run ends; the owner taps Unlock → the stand-in's door unlocked, anna told `The owner said yes: done: front_door is unlocked`, the owner's message edited with it.
  - core.zig `the_owner_says_no_or_nothing`: a reply with text → anna told `The owner said no: unlock the front door. They said: not now.`; an ask left until it expires → `No answer from the owner in time`.
  - core.zig `members_never_answer_items`: anna presses the item's button → dropped, still open.
  - core.zig `an_ask_waits_across_a_restart`: harness closed and opened again: the owner's tap still makes the call.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green.
- [ ] **Step 5:** commit `harness: a member's guarded or asked call becomes the owner's one-tap question; the tap makes it (Part 6)`.

### Task 4: README, rules comment, final checks

- [ ] **Step 1:** README: Household members (adding, removing, the code and the link, groups and privacy mode, what members may and may not do by default, `[member]` and `[member:NAME]`, what the owner is asked, what members can't see), commands, the State line.
- [ ] **Step 2:** `zig build test` (Debug) and `-Doptimize=ReleaseSafe`; cross builds and `unit-build`.
- [ ] **Step 3:** commit `harness README: household members (Part 6)`; the plan's Done section.

## Done

(Filled in at the end.)
