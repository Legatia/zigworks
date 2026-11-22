# Platform build ledger (from 2026-11-22)

Owner: "Start. Work on everything doesn't need me." Specs:
docs/superpowers/specs/2026-11-22-harness-*.md (overview binding). Branch
harness-logins (specs at ef45996). Each piece: a builder in its own worktree
and branch, test-driven, then merged here, suite + cross builds, CI.

## Order (Mac session)
1. Phase 0 — shared gate foundation (overview "Shared formats", "Phase 0"). Push when CI green (the Windows session waits on it).
2. Phase A — conversations ∥ triggers; then inbox.
3. Phase B — workflows ∥ agent definitions ∥ file roles.
4. macOS sandbox runner + APFS clone helper — after the Windows session pushes sandbox/clone interfaces.

## Waiting on the owner (not built)
- Q1 email: conversations' email channel, triggers' mail kind.
- Q2 money from automation: built with the safe default — money calls from trigger- and workflow-started runs refused behind a setting that is off.
- Q3 default environment, Q4 apps on the phone: the Windows session's part.

## Progress
- Phase 0 done (branch platform/phase0, 9 commits d23bcbe..4aee886; plan docs/superpowers/plans/2026-11-22-phase0.md), merged: Debug and ReleaseSafe 408/410 (2 skipped), smoke ok, cross builds ok.
  - Rulings: state/grants gets a `#` first line and escaped keys (also fixes a 0.3 bug: a 24 h grant for a command with a line break wrote an extra grant line); a chat grant no longer covers helpers (Allow 24 h writes agent:main / agent:helper; 0.3 grants still cover all); task/brief names not checked against the name rule (by = schedule:NAME as written; phase A's parser should enforce it); an `ask` in a delegator's or origin's section narrows a default allow.
  - For phase A/B: gate.Ctx has who, env (default host), shared (gap 4 sets shared for sends to a shared conversation and passes it to noteSkipped's second decision); Decision.allow_day false for money, setup, shared sends (inbox buttons follow it); Grants.addFor(tool, env, key, who, expiry) and covers(...); start runs with Core.runAs(client, label, .{ .by = "trigger:NAME" }, flag) (nobody-can-answer for schedule, trigger, workflow); a workflow tool step passes scheduled = false and waits in the inbox; Run.logRun writes run lines; log.Tag gets `conversation` in gap 4, which decides private-line labels; trigger/workflow arguments judged by their first word; no new kind is offered to the model yet — each gap enables its tool only in owner-started runs.
- Order revised for clean merges: conversations ∥ file roles → inbox ∥ agent definitions → triggers → workflows (inbox and agents need conversations; triggers need the inbox; workflows need triggers and the inbox).
- Phase 0 pushed (1bcebe5); Linux ReleaseSafe flaked on a_helpers_question_after_the_deadline_is_not_asked (assumed a 2 s turn ends at 2 s; with the rounded-up end it lasts 2–3 s) → d3ad2a8 fixes that test and widens the fetch-and-web bound. CI run 45045062127: all 22 jobs green.
- Conversations (gap 4) merged (platform/conversations a151a22..7983e62, plan docs/superpowers/plans/2026-11-22-conversations.md): 442/444 Debug and ReleaseSafe, smoke 48 ok, cross builds ok. Email left out (Q1).
  - Rulings: a final send that is held or fails still ends the turn (logged delivered:false; the reply is only in the log until the inbox); the terminal's conversation is `terminal` in `harness chat`, the run's `to` in brief/task run; under Telegram `terminal` isn't offered; any refusal of a send into a topic counts as the topic refused (posts go to main until restart); a send line keeps the first message id plus `parts`.
  - For next builders: state/conversations = JSON lines (name, channel, chat, thread, audience, private, created), temp+rename; run lines rid, conversation, run…; log kind `send` (to, event, bytes, text, files, buttons, final, implicit, delivered, message, parts, why). APIs: conversations.List (callers hold mutex); Core Place, Channel(place), handleIncoming, handleTextIn, sayIn, runIn(client, label, who, conv, flag); Core RunOut{tag, sched} (run outbox: [NAME] prefix, NOTHING silent, skipped noted, undelivered kept); agent Run.outbox/conversation/conv_private/context_note, Outbox{find,names,post}, postReply, TurnResult.replied, decideAndAskWith(…, AskExtra{shared, ask_why}); session.zig runs/lastRunIn/render/raw.
  - Inbox: questions go to the run's conversation (ChatAsk.conv); undelivered task/brief posts are in-memory Undelivered{conv,text,links}; failed chat finals only logged; button data letters taken: `a` approvals, `r` quick replies.
  - Triggers: runIn(…, to, …) plus RunOut with sched; a `to` without a conversation opens its topic at the first post.
  - Agents: contexts keyed by conversation (16 kept, LRU) → key by {definition, conversation}, add `agent` to Entry save/load; helpers never get send.
  - Left out: contexts surviving restart, parallel turns, topic rename, hourly counters and quick replies persisted.
- File roles (gap 3) built (platform/file-roles abfa549..4f915f2, plan docs/superpowers/plans/2026-11-22-file-roles.md, on 1bcebe5): 448/450 Debug and ReleaseSafe, smoke 51 ok, cross builds ok, no existing test edited. Merging into harness-logins (after conversations) gave 19 conflict hunks (README 4, agent 4, config 2, core 6, log 1, main 2).
  - Rulings: the written-files list names the writer except the asking definition's own run's files (0.3 question text kept); snapshot lines carry mtime (5 fields); folders.ini sections are relative folders or `[/]` (absolute, `..`, `*` are bad lines); `snapshot` tool and shell `dir` offered only when folders.ini has a section; helpers share their parent run's snapshots; over snapshot_mb each folder keeps its newest.
  - Added: folders.ini (read, write, run, vars = NAME:secret, snapshots = on|off|N, skip; guarded, watched, /reload; init writes comments only); /folders, /access WHO [ORIGIN], /snapshots [FOLDER], /snapshot, /changes, /restore; harness snapshot list|take|changes|restore; [limits] snapshot_mb = 5120; roles checked right after the hard limits (refusal final, not "skipped"); vars host-only, masked, missing secret refuses before asking, PATH/HOME/LANG/TERM/system vars refused; store snapshots/objects/ab/<sha256> + folders/<key>/<id>, one mutex, restore snapshots first, no symlink writes, refused while a run goes; clone hook CloneFn = fn(io, src, dst) anyerror!bool, snapshots.platform_clone (null); log kind `files`.
  - For environments: folders.view(who) (none/read/write per folder for mounts), Decision.dir (where a command starts), folderVars only for host, checkpoints = take on env:NAME (state/env/NAME/home), Written.listFor(…, view).
  - For agents: agent:NAME entries work for any definition; an app's own call is Who{.agent = ""}, writes via Written.addBy(rel, "app:NAME", "").
  - Left out: per-FS clone helpers; gap 8's manifest files check; by-hand /restore of a large folder blocks the command thread; restore leaves emptied folders; README state line unchanged.
