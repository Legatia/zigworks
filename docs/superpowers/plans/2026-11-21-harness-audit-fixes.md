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

## Pending reports

A3 runtime/platform (K1 MCP startup serial, K2 MCP secret needs restart, K3
browse redirects/env/profile/Keychain).

## Fix ledger

(entries: `ID: fixed — test RED→GREEN — commit`, or `ID: Ruling: … — why — cost`)
