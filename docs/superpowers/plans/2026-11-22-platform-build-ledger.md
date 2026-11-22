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
