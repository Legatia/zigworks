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
