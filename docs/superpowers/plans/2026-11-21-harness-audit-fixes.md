# harness end-to-end audit (2026-11-21): findings and fix ledger

Owner's request: "Audit end to end and fix all issues". Branch `harness-logins`
(merged with main at ce92875). Five auditors, each in its own clone: web+logins
(A1), agent loop/gate/money (A2), runtime/platform (A3), network/data (A4),
end-to-end + docs (A5). Every fix: a test that fails first, then passes; full
suite green; cross builds compile. Grades are by effect on the owner.

CI run 44938713397 (69dca56): all harness jobs pass on Linux, macOS, Windows
(Linux 205 pass / 1 skip, so the Chrome tests ran there). llmcheck on Windows
hung until the job limit; main's llmcheck Windows fix merged in (ce92875).

## Critical

- C1 (A2) A money server with no `amount =` line is never capped:
  amountField returns "" (agent.zig:255), moneyCheck treats "" as "moves no
  amount" (agent.zig:802). Fix: with any cap set, a money tool without a
  configured amount field is refused; only explicit `tool:none` means no
  amount; say so at start and in /status.
- C2 (A2 I6 + A4 C1) Approvals and MCP rules see a silently cut argument:
  question = util.cut(arg, 1500) without a mark (agent.zig:726); MCP rules
  match cut(input_json, 1500) (agent.zig:646). Padding hides `; curl|sh` or a
  money `to` field. Fix: rules match the full input; the question shows the
  whole argument (several messages if long) or the call is refused.

## Important

Agent / gate / money / MCP (A2):
- I1 README's per-tool `amount = a:f, b:none` rejected by mcp.zig:87 (no
  server starts). Parse the comma list, validate each `tool:field`.
- I2 A `money =` name matching no tool fails open (agent.zig:272). Refuse to
  start a server whose money list names a tool it doesn't have.
- I3 Day rollover lets the cap be passed (MoneyLedger.add resets to the day
  given, agent.zig:305; dry-run release uses r.now(), agent.zig:834). Keep the
  reservation's day; ignore releases for a past day; never below 0.
- I4 Secrets masked after the output is cut/paged: shell (tools.zig:140),
  read_file capText, MCP (mcp.zig:373), fetch paging (tools.zig:339). Scrub
  the full raw output first, then cut/page.
- I5 Path deny rules dodged by `./.git/...` (gate.zig:157-169 discards
  confine()'s result). Match file rules on the confined workspace-relative path.
- I6 Non-UTF-8 tool output (util.zig:110 jsonString copies bytes >=0x80; cut
  at a byte, tools.zig:140) makes the next request invalid JSON; the failed
  turn is kept (agent.zig:567-576) so every later request fails until /new.
  Replace invalid sequences with U+FFFD at the tool boundary; drop a turn the
  API rejects with 400.

Network / data (A4):
- I7 A stale Telegram button approves a new question after a restart
  (callback ids restart at a1, core.zig:639; handleCallback ignores
  message_id, core.zig:600-611; Approval.msg never set). Per-process nonce in
  callback data + message_id check.
- I8 An undelivered brief/task answer counts as delivered (TgChan.send
  swallows errors, main.zig:499; runBrief marks seen, core.zig:1089-1096; 429
  not retried, telegram.zig:38-48). send returns an error; mark seen/ran only
  after delivery; honour retry_after.
- I9 Old feed items come back as new (seen entries expire 60 days after
  sending though still in the feed, brief.zig:55,122; only first 15 per topic
  marked, brief.zig:115). Refresh timestamps of links still present; mark all
  collected.
- I10 Memory writer recounts old turns and misses new ones (whole
  conversation since /new, cut to first 60 KB, core.zig:896,902). Send only
  turns since the last run, newest first, with existing items; writer merges
  are not owner mentions.
- I11 Corrections merge into the fact they correct (80% overlap,
  memory.zig:181-187; words() drops <3 chars and "don't"→"don",
  memory.zig:73-91). Merge only when numbers and negations agree.
- I12 Memory as lasting prompt injection (`remember` allowed by default; agent
  and writer items go into every prompt). Tell the owner about each agent or
  writer write (and/or mark unconfirmed until the owner mentions it).
- I13 Redirects neither followed nor shown (tools.zig:283, http.zig:278-281,
  brief.zig:136 says NotFound). Follow up to 5 hops, gate each hop, refuse
  https→http, drop auth/custom headers when the host changes; say the status.

Web / logins (A1):
- I14 Dialog text from a refused or unchecked host reaches the model
  (cdp.zig:73-80 queues without frame URL; web.zig:619-636 prints all). Keep
  the dialog's URL; print only those on the allowed host.
- I15 Any page can save files into ~/Downloads (no download behaviour set,
  cdp.zig:240-270, web.zig:300-321; browse likely too). Deny downloads
  (Browser.setDownloadBehavior deny; for browse --dump-dom set the throwaway
  profile's download dir inside the profile) and tell the model.
- I16 encodeURIComponent/encodeURI forms of a password escape masking
  (scrub.zig:131-161). Add both encodings; consider dropping `!%*^` from
  generated symbols.

## Minor (all to fix)

A2: grants compare case-insensitively (gate.zig:98,110); stable system part
orders top memories by strength (agent.zig:457) so mentions/remember rewrite the
cached prefix — sort by id, build once per turn; README says the system block is
marked but `changing` is always "" (agent.zig:567) — fix README or marks; tool
calls in a reply cut by max_tokens still run (agent.zig:578,596); Timeout retried
(model.zig:88): double billing, up to 2x15 min, ignores /stop and deadline;
ledger rewritten in place, write errors ignored (agent.zig:313) — write
temp+rename, report errors; brief sources skip deny rules (gate.zig:163); after a
summary further trimming is silent (agent.zig:463); summary call's 60 KB input
cap skips the newest turns (agent.zig:1012).
K4 MCP names collide (agent.zig:275, mcp.zig:113): reject `__` in server names,
skip duplicates and names outside [A-Za-z0-9_-]{1,64}.
K5 /dryrun (and /private, auto) copied into the run as plain bools
(core.zig:792,1187; agent.zig:833): atomics read at call time; dry-run state in
the money question.
K6 helper approvals and tool timeouts not bounded by the run's deadline
(core.zig:653,758; agent.zig:728,837): pass the deadline to the asker; cap tool
timeouts by remaining time.
K7 one money total across servers (agent.zig:287,810-818): caps and ledger per
server (mcp.ini max_per_call/max_per_day per section), global as default.

A4: brief/`at` task ending after midnight records the next day (core.zig:1054);
split() loops on >=4096 continuation bytes (util.zig:119, telegram.zig:145) —
hard-cut, repair UTF-8; /brief says "Collecting." when refused
(core.zig:1246); private mode: running turn logged in full and reaches the
writer (core.zig:774), /remember still writes (core.zig:1212), log hashes
unkeyed (log.zig:129) — HMAC with an instance key; `log verify` misses removed
trailing lines (log.zig:166-188) — compare with the hash in state/status;
memory ids from file content (memory.zig:392): copies resurrect, "../x" writes
outside memory/, created "-001-…" panics isoTime (util.zig:54).

A1: session cookies don't survive (try session.restore_on_startup, else
document); page can stall waits by redefining readyState (cdp.zig:409,421,453)
— poll in the isolated world; fill checks the site not the approved host
(web.zig:459,473,562,704-714) — pass the approved host, require equality;
failed key-store read silently disables passkey saving (web.zig:334-336,403) —
note it; throwaway profiles left after a kill (web.zig:313) — remove at start.
K8 rpIdAllowed parent domains (logins.zig:96): accept only site or below.
K9 host case/default port (web.zig:287-295,474-476): lowercase, strip default
ports, compare ignoring case.
K10 new tabs unseen/ungated (cdp.zig:240-270): browser-level
Target.setAutoAttach waitForDebuggerOnStart; close new pages, report URL.
K11 inbox/page_session leak on failed start (cdp.zig:195,230,234).
K12 generated password masked elsewhere only after restart (core.zig:266-272,
web.zig:522-526): Core-owned mask list behind a lock, appended via hook.
K13 trusted clicks (Input.dispatchMouseEvent) after K10 and I15.
K14 cookie-survival test (expiring cookie).
K15 open shadow roots in snapshot and fill scripts (web.zig:664,718).
K16 group kills before child.wait (cdp.zig:499-501,277).
K18 re-wait if a load started after the mark by snapshot time
(cdp.zig:436-444,520).

## End-to-end + docs (A5)

Important:
- I17 A scheduled run's refusals disappear when the model answers NOTHING
  (core.zig:1130-1132; README says "the run says what it skipped"). Collect
  refusals in the run; append "Skipped (needs approval): …" and send it even
  when the answer is NOTHING.
- I18 Secrets the owner types are logged and remembered in clear (owner
  message "my key is og-…" and `/remember …` land in actions.jsonl and
  memory/: agent.zig:495,611, core.zig:1163). Scrub every logged field in
  log.write and every memory write against the secret list.
- I19 All data folders share one secret store (Keychain service fixed to
  "harness", store.zig:108): `login rm` in a second home deleted the first
  home's secrets. Namespace the store per data folder, keeping existing
  secrets of the default folder working (the Windows session may already
  have stored real ones); `login rm` requires the logins.ini entry (or says
  clearly what it removes).
- I20 No SIGINT/SIGTERM handling: Ctrl-C in chat or kill of `harness run`
  leaves approved commands running (own pgid), no log line, the lock left;
  `health` then says running. Handle both: stopAll, log, close, release the
  lock; `health` checks the lock's pid.
- I21 A trailing `--home X` is silently ignored (main.zig:166): `init --home
  X` wrote to the default folder; `login rm victim --home other` removed from
  the default one. Accept global options anywhere or reject unknown args.
- I22 (= A4 minor) `log verify` misses lines cut from the end: compare with
  the last hash in state/status and report the missing tail.
- I23 mcp.ini not guarded like config.ini (0666 accepted, core.zig:390) and
  not in the change hash (core.zig:368). Add it to both.
- I24 README wrong for Linux secrets (DATA/secrets/ without HARNESS_STORE,
  main.zig:73): fix the sentence and the file table.

Minor: terminal money approval offers "[d] allow 24 h" (main.zig:600 ignores the
button list); Ctrl-D while an approval is pending doesn't leave (waits
approval_seconds); init's rules comment lists defaults wrongly (config.zig:363);
briefs.ini feeds skip deny rules (= A2 minor, gate.zig:163); re-pairing
undocumented and a /pair from another account is dropped silently; a task answer
before pairing is lost but logged "sent":true; names may start with `-`
(`secret add --stdin foo` stored "--stdin"); `--site com` accepted (single-label
sites other than localhost); misleading messages: `login add` with no values says
"Stored …", `login rm` always says entry+profile removed, settings errors name no
file/line and the permission hint omits logins.ini/mcp.ini, `log verify` with no
log prints FileNotFound, "model calls will be refused" is false (sent with an
empty key) — refuse them; `health` exits 0 while only `chat` runs; XDG_DATA_HOME
undocumented; default omnigate url 127.0.0.1:8080 (Docker on this Mac) gets the
key if init step 1 is skipped — no default url, refuse until set; README binary
size (Linux musl 2.08 MB, macOS 1.70 MB).
Smoke gaps to close: version/help/health; secret rm, pipe without --stdin; login
bad names/sites; MCP default ask, 24 h grant, money (asked every time, caps, dry
run); `harness brief` CLI; scheduled ask-means-deny with the skipped note; the
"no secret in log" check extended to owner messages.

## Runtime / platform (A3)

Critical:
- C3 Agent-written files become code run outside the gate: write_file asks
  nothing; MCP servers (mcp.zig:241) and shell (tools.zig:207) run in the
  workspace. Verified: planted workspace/.npmrc changes npx's registry (MCP
  restart on /reload or any CLI command), `python3 -m pkg` runs a planted
  pkg.py, `git status` (README's allow example) runs core.fsmonitor from a
  planted .git/config. Fix: MCP servers run in a folder the agent can't
  write; write_file asks for any path with a component starting with "."
  (default ask, grants allowed).
- C4 Telegram clients use freed memory after /reload (and /topic, /task
  add|rm, which reload): main.zig:534,540 pass c.cfg.chat.api from the
  settings arena freed at core.zig:443 (http Target points into it,
  http.zig:35). Real bot likely deaf until restart. Copy the URL into a
  long-lived allocation; rebuild the bots on reload.

Important:
- I25 write_file escapes the workspace through a dangling symlink (confine,
  gate.zig:199-209, walks past an unresolved final component; tools.zig:101
  creates the target). Refuse a final component that is a symlink; open
  without following.
- I26 The lock doesn't hold: check-then-write race (core.zig:1507-1524; 18/40
  simultaneous starts both ran → broken log chain, per-process money
  ledgers); EPERM pid counts alive after reboot (core.zig:1502); Windows never
  checks the pid (core.zig:1500) and whichever exits first deletes the lock
  (core.zig:1527). Hold an exclusive lock file (createFile .lock=.exclusive,
  nonblocking) for the process lifetime. (Signals: see I20.)
- I27 Windows: output reader threads joined without a time limit
  (tools.zig:224-229, mcp.zig:414-415, page.zig:1212-1215); a grandchild
  holding the pipe (start /b, MSBuild, gradle, npx .cmd) hangs the call,
  /stop and /reload. Job object with KILL_ON_JOB_CLOSE + TerminateJobObject;
  bounded drain. → Windows session (handoff), can't be run here.
- I28 (= I5, wider) path deny rules match the raw argument: `./private/k`,
  `a/../private/k`, absolute paths, `Private/k` on case-insensitive volumes,
  `private\k`. Match the confined, normalized, workspace-relative path,
  case-folded where the volume is case-insensitive.

Minor: Windows hidden input echoes under mintty/MSYS (main.zig:794-799 unchecked
console-mode calls) → Windows handoff; mcp.ini secret names unvalidated
(mcp.zig:73-77): wincred target() writes [128]u16 unbounded (store.zig:186-198),
dir store reads `../config.ini`; Credential Manager 2560-byte cap vs 64 KiB
accepted with a vague error.
K1 present (core.zig:814-855, mcp.zig:180; reload holds queue/settings
mutexes so /stop waits): start in parallel under one deadline, skip for memory
and brief, don't hold queue_mutex while starting.
K2 present (main.zig:91-135, core.zig:830; new secret never masked,
core.zig:267-272): fetch missing names from the store in startMcp and add them
to the mask list.
K3 present (page.zig:1181-1201 and cdp.zig:216 pass the whole environment, no
--use-mock-keychain/--password-store=basic; profile removed only by defer;
grant covers the first host only): reduced environment, both flags, sweep
state/harness-browser-* at open, --host-resolver-rules to keep browse on the
granted host.

## Assignment (parallel builders, one worktree and branch each)

- G1 gate, approvals, tool output — branch fix/gate: C2, C3 (write_file
  dot-path ask), I4, I5/I28, I6 (UTF-8 at the tool boundary), I7, I25, K5,
  K6, A2 minors: grants case, brief sources and deny; A4 minor split(); A5
  minors: terminal money approval offers 24 h, Ctrl-D with a pending approval.
  Owns gate.zig, rules.zig, util.zig, tools.zig (shell/read_file/write_file/
  fetch paging), core.zig askOwner/handleCallback/run flags, main.zig chat
  approval UI, agent.zig callTool's approval text and rule argument.
- G2 money, MCP config, model — branch fix/money: C1, I1, I2, I3, K4, K7,
  mcp.ini secret-name validation, A2 minors: cache ordering, max_tokens tool
  calls, Timeout retry, ledger write, silent trimming, summary input cap,
  drop a turn the API rejects (I6 second half); model calls refused without
  a key or url (A5). Owns agent.zig money/ledger/mcpTools/toolDefs/turn/
  compact/systemParts, mcp.zig parseConfig, model.zig.
- D network, briefs, memory, log, Telegram — branch fix/data: C4, I8-I13,
  I17, I18, I22, A4 minors (midnight day, /brief reply, private gaps, HMAC
  hashes, memory ids/paths/isoTime), A5 minors (re-pair reply, task before
  pairing, `log verify` with no log). Owns http.zig, telegram.zig, feeds.zig,
  brief.zig, memory.zig, log.zig, tools.zig get(), core.zig briefs/tasks/
  scheduler/memory writer/private/pair, main.zig Telegram channel.
- W browser and logins — branch fix/web: I14, I15, I16, A1 minors, K3, K8-K16,
  K18, A5 minors (`--site` single label, login add/rm messages). Owns web.zig,
  cdp.zig, logins.zig, totp.zig, scrub.zig, page.zig, main.zig loginCmd.
- R runtime, CLI, store — branch fix/runtime: C3 (MCP servers' folder), I19,
  I20, I21, I23, I26, K1, K2, K12 (Core-owned mask list behind a lock, with a
  hook web uses), A3 minors (wincred bounds and size cap), A5 minors (names
  starting with "-", settings errors name file/line, permission hint, health,
  default omnigate url removed); writes harness/HANDOFF-windows-audit.md for
  I27 and the mintty echo. Owns core.zig open/settings/lock/reload/startMcp/
  health/status/secret list, main.zig args/signals/secret cmd/App.store,
  store.zig, config.zig, mcp.zig Server.start, skills.zig.
- After the merge: README and docs (I24 and every doc note the builders
  report), smoke gaps, full suite, cross builds, CI.

## Fix ledger

(entries: `ID: fixed — test RED→GREEN — commit`, or `ID: Ruling: … — why — cost`)

### G1 fix/gate (65238ac..37ea9bc, 15 commits) — suite 233/235 (2 skipped), smoke ok, cross builds ok
- C2 fixed 1c48386 (rules see whole MCP input and every delegate task; question never cut: parts ≤4096 B with buttons on the last; >12 KB refused).
- C3 write_file part fixed a4059eb (dot-path writes ask; question shows the content).
- I4 fixed a36756c (mask, then cut/page; a tail that could start a secret is dropped when cut).
- I5/I28 fixed be975ef (confined, normalized path; symlinks followed; case ignored on macOS/Windows; deny also on the pre-symlink path).
- I6 first half fixed 9188d55 (U+FFFD at the tool boundary; util.jsonString always valid UTF-8).
- I7 Ruling c14894e: approval numbers continue across restarts (state/approvals) instead of nonce+message_id, because smoke.sh answers with fixed `a1:day`/message 1. FOLLOW-UP after merge: smoke reads callback data and message_id from the outbox; then add the nonce and the message-id check.
- I25 fixed d2214d0. K5 fixed 46f19b9 (switches are atomics; money question says whether dry run is on). K6 fixed 2f65664, 37ea9bc.
- Minors fixed: grants exact except hosts ab1d391 (Ruling: paths case-insensitive on macOS/Windows); deny before brief sources 4931230; split() 65238ac; terminal shows only offered answers ca6a064; Ctrl-D denies and leaves e3ec7a5.
- Merge points: agent.zig callMcp/turn/compact (G2), `Asker.ask(ctx, Question{text, allow_day, deadline_s})`, Run.switches; core.zig `switches: agent.Switches` replaces dry_run/private/auto_recall (R's Core.open, D's private code must use c.switches.private.load(.acquire)).
- Flaky once under load: web_profiles_keep_no_saved_passwords ("no page is open"); passed alone and on rerun — watch after merge.

### R fix/runtime (15 commits) — 225/227, smoke ok, cross builds ok; merged 3aa97ec → 254/256
- I21 3626a43; names start with a letter/digit 3626a43; default url removed b0c49cc; rules comment ebe3449; I23 1fa3f5d; settings errors file/line 71e4525; I26 1c2c02e (before: 8/8 simultaneous starts got through); health bdbc3db; I20 4e93b8c; C3 MCP folder e64b93e (state/mcp/NAME, 0700); K1 423ed17; K12 ce6b704 (masks.zig); K2 38600ec; Credential Manager bounds/2560 cap 9fabea7; I19 e7be6f7; I27 + mintty → harness/HANDOFF-windows-audit.md a55ba01.
- Rulings: I19 namespace kept in state/store-id (default folder keeps "harness"; a copy keeps its secrets; a copy used as a second instance shares them until store-id is deleted); HARNESS_STORE=DIR used as given; signals exit(0) after cleanup from a watcher thread (a model call under way is dropped, as with /stop); the lock file is never deleted, the OS lock counts.
- Notes for merge: D's log masking → &c.masks (masks.List.scrubAlloc); G2 must let Client.init accept "" (else an empty url fails Core.open and blocks `harness memory`); `login rm` requiring the logins.ini entry is W's (loginCmd); init's rules comment should mention dot-path writes (G1).

### G2 fix/money (17 commits) — 232/234, smoke ok, cross builds ok
- mcp.ini secret names d7a9033; I1 4790dd3; C1 a2356c0 (told at start, in the log and /status); I2 89a250e; K4 88d4cfe; K7 47efd91 (per-server caps and day totals); I3 0aad896; ledger write 9b712af, 206d68f; no key/url refused a9d32d1 (empty url no longer fails Core.open); Timeout not resent d086f7a; I6 second half 98c77e8 (400/413 drops the turn); max_tokens tool calls ac960ef; memory order / built once per turn aa68a3c; cache marks on turn calls 2b8a772 (code changed, README stays); silent trimming 273dc53; summary keeps newest 7ce1066.
- Rulings: stricter mcp.ini (amount/max_per_* without money =, bare `amount = none`, per-tool entry not in money = are parse errors); only ConnectFailed retried (ConnectionClosed after send isn't); /stop doesn't cut a model call under way (ends by the turn deadline; /stop ends a 429 wait); 413 like 400; old single-line state/money counts that day for every server; 64 ledger slots, a 65th server moving money that day is refused; damaged state/money refuses money calls until fixed and restarted; `max_per_day = 0` in a section means no cap for that server.

### D fix/data (16 commits) — 237/239, smoke ok, cross builds ok
- C4 d145be4; I8 13bce4d (also task-before-pairing "sent"); I9 984da62; I10 8ff7c49; I11 263fbce; I12 82fb809; I13 b673a17; I17 a90de8a; I18 2dd9dec; I22 + `log verify` with no log 4fd4d4c; midnight day ce0cf13; /brief reply 80d8572; HMAC log hashes 1fcbc19 (state/log-key 0600); private gaps 93fbca5; memory ids/isoTime 9ab9165; /pair from another account de636e1.
- Rulings: undelivered brief/task retried after 5 min doubling to 2 h (no persisted outbox; one model call per retry while Telegram is down); a redirect to a host the call already reached is stopped only by a deny rule (Allow once for one path covers a redirect to another path on that host); a turn running when /private on arrives is marked private when it ends.

### Merges into harness-logins
- fix/gate → 233/235. fix/runtime (3aa97ec) → 254/256. fix/money (9391623) → 282/284: startMcp combined (parallel start + money-list check before keeping a server), tests from both sides kept. fix/data → 316/318: Question+Notice, masks+skipped fields, redirectEnv under the deadline env, Start.restarting for /brief during a reload, private reads through run.isPrivate()/c.switches; integration fix: masks.List.on_change → Core.masksChanged refreshes the log's and memory's masks (test a_value_added_to_the_mask_list_is_masked_in_the_log_and_memory_too RED→GREEN).

### W fix/web (20 commits) — 231/233, smoke ok, cross builds ok
- I14 1043a4a; I15 0db7934 (web: Browser.setDownloadBehavior deny; browse: downloads kept inside the throwaway profile); I16 0d16f09 (generated passwords drop `!%*^`); K3 38f0dc8 (PATH, HOME, LANG=C.UTF-8; --use-mock-keychain, --password-store=basic; browse --host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE host); throwaway sweep 48e5c56; K8 b48c14a; K9 feca614; K10 080bc03; K11 a6cf1d3; K13 d5288c7; K14 test only 6c805b2; K15 d3af787; K16 964fa40; K18 1ddbe37; session cookies e26caca; readyState 45e64cc; approved host 2d81441; key-store read dd7fe59; A5 login messages and one-label sites 4e3d6b0; cleanup b9e9961.
- Rulings: browse (no DevTools channel) reports only a URL that is itself a download, a script-started download there is blocked silently; no TMPDIR given to Chrome; browse loads nothing from other hosts (CDN assets, cross-host redirects show Chrome's error page); --use-mock-keychain makes cookies already in existing login profiles unreadable once; the throwaway sweep runs at a process's first throwaway profile, not at start; new tabs are closed before their first request (popup sign-ins that talk to the opener can't complete); a covered element is refused, no script-click fallback; session cookies kept with --restore-last-session after deleting Default/Sessions* (the protected preference is reset by Chrome).
- fix/web (fdc27fc) → 343/345, smoke ok; cross builds (app + unit-build) ok for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl. Conflict: tests appended by D and W at the end of main.zig, both kept (W's local `const t` dropped).

### S fix/smoke (9 commits) — merged, 346/348, 45 smoke checks
- I7 follow-up 7142cad: callback data `a<number>-<nonce>:once|day|deny`, nonce per start; a press counts only from the question's own message (held until the message id is known); otherwise "That button is out of date: it answers nothing." and a log line. Fake writes message ids to telegram/out.jsonl; smoke presses the buttons actually sent.
- Smoke gaps 0d1cc79 (version/help/health/start notes; App.open notes a missing url), c78d644 (secret rm, pipe without --stdin), c27b353 (counter refactor), 84500fb (MCP ask/grant/money/cap/dry run on a second server), b7df580 (`harness brief` CLI), 9964c53 (owner-typed secret masked), 46c600d (scheduled ask-means-deny with the skipped note). Rules comment 4d49d74.
- Ruling: a failed write of state/approvals no longer refuses the question (the nonce tells old buttons apart).
- Found: a_slow_model_call_ends_with_the_turn flaky (deadline compared in seconds, call timed in ms) → fixed after the merge: client returns TimeUp when the deadline set the call's limit (a_call_ends_by_the_turn_deadline RED→GREEN).

## Final review of the merged branch (ce92875..harness-logins @ 1b8ef3d)

Seams hold (Core.open sets all fields, close order, no lock inversion, mask hook outside locks, money-list check after parallel start, nonce+message id end to end); C1, C4 closed; C2 closed except F2; C3 partly (F4). Second fix pass:

- F1 (Important) An undelivered task re-runs its tools: background() reschedules the whole task (core.zig:1602-1607, 1712); side effects repeat every retry. Keep the composed text per key; retry only its delivery (briefs too, unless re-collecting is intended).
- F2 (Important) askOwner ignores send failures: parts before the last go out with c.say, which drops errors (core.zig:898), so buttons can sit under a partial question and Allow runs it; and when sending the buttons fails (main.zig:679 → null) every press is "out of date" and the run waits approval_seconds. Send parts with deliver; deny if any part fails; deny at once with no message id.
- F3 (Important) skill_save is approved without showing what is saved (agent.zig:959-965 detail only for write_file; tools.zig:70). Show name, description and body as the detail (12 KB limit applies).
- F4 (Important) C3 partly closed: non-dot files the agent writes (pkg.py, conftest.py, Makefile) run under a later rule- or grant-allowed shell command (gate.zig:219, tools.zig:244). After any agent write in the workspace, the next shell call that a rule or grant would allow is asked once, listing the files written; scheduled runs skip it with the skipped note. Rules comment and README say so.
- F5 (Minor) Owner notices sent while c.lock is held (agent.zig:1002, core.zig:1416-1421): build under the lock, send after.
- F6 (Minor) K6 caps only shell/browser/MCP: web returns before the cap (agent.zig:935); fetch/search use fixed 30 s idle / 120 s per hop, up to 6 hops (tools.zig:423); a 1 s turn took 4.0 s. Pass the remaining time (total_ms) and honour /stop per hop.
- F7 (Minor) masksChanged can lose an update when two values are added at once (core.zig:475-488): serialize its body.
- F8 (Minor) I19 migration: an existing non-default folder on macOS/Windows gets a new random namespace (store.zig:164) and its keys stop being found. Use "harness" when state/store-id is missing but the folder already existed (e.g. has a log or config older than this version); README: delete state/store-id when a copy becomes a second instance.
- F9 (Ruling reversed) `max_per_day = 0` / `max_per_call = 0` in an mcp.ini section silently lifts config.ini's cap. Make it explicit: `none` lifts the cap for that server (said in start notes and /status); `0` in a section is an error.
- F10 (Important, pre-existing) URL rules match the raw URL as a glob: `allow fetch https://*.good.com/*` matches `https://evil.com/.good.com/`. Match URL-tool rules by parts: scheme, host (glob on the host only) and path.
- F11 (Important, pre-existing) userinfo URLs: browse follows `https://good.com@evil.com/` to evil.com. Refuse URLs with userinfo (or parse the real host with std.Uri everywhere a host is taken: gate grant keys, browse host rules, fetch, web).
- Noted, not fixed: K13 a page could move a cross-site frame under the pointer between the cover check and the press (theoretical); Keychain/Credential Manager namespace code has no test (HARNESS_STORE set everywhere) — add a pure-function test if missing.

Assignment: X (F1-F5, F7, F8) branch fix2/core; Y (F6, F9, F10, F11) branch fix2/urls.

### X fix2/core (8 commits) — merged, 358/360, smoke 45 ok, cross builds ok
- F1 1c31e3e (composed message kept per key; only delivery retried; briefs resent as written, links seen once it arrives); F2 2e00e9c (every part via deliver; a failed part or no message id → refused, Answer.unsent, owner told); F3 881fbbc (name, description, body shown; >12 KB refused); F4 b14f983 (agent.Written in Core, shared with helpers, kept in state/written; shell allowed by a rule or grant is asked naming the files; an allow clears what it showed; scheduled runs skip it); F5 ed14681; F7 7fd8699 (mask_mutex); F8 23e4567 (store.forFolder/claimNamespace; init writes store-id first; old folders keep "harness"); b438adf tidy.
- Rulings: kept undelivered messages are in memory only (a restart while one waits runs that brief/task once more); the written mark persists in state/written; deleting store-id in a copy gives it "harness" (README: make a second folder with init and copy everything except state/store-id).

### Y fix2/urls (6 commits) — merged, 375/377 (2 skipped), smoke 45 ok, cross builds ok
- F11 27baf6e (src/url.zig, one reader of addresses for the gate, grants, fetch/search/redirects, browse, web; userinfo, backslash, spaces, `%`/non-ASCII hosts refused; one form per host; std.Uri formatter dropped userinfo on redirects — now kept and refused); F10 086cf80, b1bf531 (address rules by parts; non-address allow rules for fetch/browse refused at load naming the line; paths hiding `..` refused); F6 9faca8e (fetch/search hops and web actions get the turn's remaining time; /stop checked every 100 ms in socket waits); F9 7c048d8, 49bfc95 (`none` lifts a server cap, said at start and in /status; `0` in a section is a parse error; mcp.ini parse errors in the start notes).
- Rulings: non-ASCII hosts refused (no IDNA tables; write xn--); saved grants keyed host:443 stop matching (expire within 24 h); deny/ask rules that aren't address patterns stay globs over the address; a pattern with no path covers any path; `*` in an allow host must be the whole host or its first label; DNS lookups not cut by the deadline or /stop; closing the browser at a turn's end keeps its own limits (≤ ~4 s) so cookies and passkeys are saved.
- Merge: README conflict only (address-rule paragraphs + the ask sentence naming skills); README test count updated to 377.

## CI rounds after the push (0b65768 → cfe408b)

- 0b65768: Linux `render_of_a_download_saves_nothing_and_says_so` (Chrome on Linux waits after a refused download → Timeout); macOS `mcp_servers_start_together_under_one_deadline` (slow runner); Windows `files_confined_to_workspace`, `tool_call_then_answer`, `a_fetch_and_a_web_action…`.
- b204ce1: download watcher (Downloads folder appearing ends Chrome) + empty output with a clean exit is a download (race, flaky on macOS; test render_says_a_download_even_when_the_browser_ends_before_its_folder_is_made RED→GREEN); timing test margins; Windows write tests print the error.
- 2dbb6e7: Windows write_file failed with AccessDenied (stat of a write-only handle) → create/open with read access; macOS timing printed 6.3 s (teardown of the servers).
- c98743e: a helper's turn never ends later than its parent's (whole-second rounding gave it one more second: Linux helpers test); MCP start test proves parallelism by both servers being up by the deadline; stop test with an 8 s server.
- 1d168a7, ada382b, e2486e4: every check of the turn's time in milliseconds (callTool cap, ask step, turn loop, helper start, MCP calls, model client), under 0.1 s nothing new is started or sent.
- cfe408b: the fetch-and-web test judges what ran (Windows doesn't offer web; Linux refuses at the gate; macOS before the tool).
