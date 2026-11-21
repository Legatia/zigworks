# README changes asked for by the audit fix builders

Apply to harness/README.md after all fix branches are merged. Copy rules: plain
labels, no slogans. Check each against the merged code before writing it.

## G1 (gate, approvals, tool output)
- Gate item 1: "files only inside `workspace/`, never written through a symlink".
- Gate item 5, after "MCP tools ask;": "so does `write_file` for a path with a part starting with "." (`.git/config`, `.npmrc`);".
- After the rules example: "File rules and grants see the path inside the workspace: `./notes/a`, `x/../notes/a`, its absolute path or a symlink to it count as `notes/a`, and on macOS and Windows so does `Notes/A`. A grant covers the exact command, path or MCP tool; a host in any case. A `deny` rule applies to briefs.ini sources too."
- Ask paragraph: "`ask` sends you the whole call (a file's content too) … a long one comes in several messages with the buttons on the last; a call over 12 KB is refused. No answer in `approval_seconds`, or before the turn's time is up, counts as Deny."
- Shell paragraph: "masked … before anything is cut from it. A tool gets what is left of the turn's time."
- Helpers: "one question that can't be answered before the turn ends is refused without asking."
- MCP: rules match "the whole input as JSON".
- Money: "`/dryrun` applies at once, to a call waiting for your answer too; the money question says whether it is on."
- Quick start: "In `harness chat`, Ctrl-D leaves; a waiting question is answered Deny."
- Data table, `state/`: add "approval numbers".

## R (runtime, CLI, store)
1. "Set omnigate's address and route names in `config.ini` first." → "Set omnigate's address (there is none by default) and route names in `config.ini` first."
2. "Copy it to move the instance; secrets live in the system's key store, not in the folder." → "Copy it to move the instance; secrets live in the system's key store under a name kept in `state/store-id`, so a copy keeps them, and each folder made apart has its own (the default folder keeps `harness`, as before)." (Also fix the Linux case, I24: without HARNESS_STORE, Linux keeps them in `DATA/secrets/`, files only the user can read — so on Linux a copy of the folder carries them.)
3. `state/` row: add "`store-id`, `mcp/NAME` (each MCP server's own folder)".
4. "`config.ini`, `rules` and `logins.ini` are refused if other users can write them." → "`config.ini`, `rules`, `logins.ini` and `mcp.ini` are refused if other users can write them; harness names the file, and the line that does not read."
5. MCP: "Servers are started when harness starts and on `/reload`, in the workspace folder," → "Servers start together (20 s in all) with `harness run`, `chat` and `task run` and on `/reload`, each in a folder of its own (`state/mcp/NAME`, never the workspace),". After "(`harness secret add github`)" add "; `/reload` picks up one added meanwhile".
6. After the /stop paragraph: "Ctrl-C or a kill (SIGINT, SIGTERM; on Windows Ctrl-C or closing the console) does what `/stop` does, logs it, and ends harness with the folder free."
7. CLI: "`--home DIR` may come anywhere on the line; arguments a command does not take are refused. `health` exits 0 only while `harness run` holds the folder and has ticked in the last 90 s."
8. Limits: delete "The lock is judged by the status file's age, so after a crash a new instance can start 90 seconds later."; delete the "MCP servers start one after another…" bullet and the "A password made at sign-up…" bullet; add "The Windows Credential Manager keeps at most 2560 bytes of a value; `secret add` refuses longer ones."

## G2 (money, MCP config, model)
- MCP example `[broker]`: add `max_per_call = 500   ; this server's caps; default: [money] in config.ini` and `max_per_day = 2000`.
- MCP: "Server names use a-z, 0-9, - and _ (no `__`); secret names follow `harness secret add`. A tool whose `server__tool` name is over 64 characters, or that another tool already has, is left out; /status says which."
- Money, replace the caps sentence: "`max_per_call` and `max_per_day` are hard caps checked before you are asked: the server's own lines in mcp.ini, else `[money]` in config.ini (0: no cap). Each server has its own day total in `state/money`. With a cap set, a money tool that `amount =` gives no field is refused, and so is a call without its amount (`tool:none` moves no amount). A server whose `money =` names a tool it does not have is not started. If `state/money` cannot be written or read, money calls are refused with the reason."
- Money: "…`scheduled = on` and at least one cap" → "…and a cap for that server".
- Limits: "one day total across all servers: keep all money tools in one unit" → "one day total per server: keep each server's money tools in one unit".
- Helpers: "Every model call marks…" → "Every model call of a turn marks…". Add: "turns that still don't fit after the summary are dropped, logged, and the agent is told."
- Limits, No streaming: add "A model call ends by the turn's time limit; one that timed out is not sent again. A request the API refuses as invalid drops that turn, and you are told."
- mcp.ini stricter now: `amount`/`max_per_*` without `money =`, a bare `amount = none`, a per-tool entry for a tool not in `money =` are errors.

## D (network, Telegram, briefs, memory, log)
1. Quick start, after "dropped and logged.": "A pairing attempt from another account is answered. To move the bot to another account, run `harness pair` again and send the new code from that account; the old one is told."
2. Research: "`fetch` follows up to 5 redirects, never from https to http; each passes the gate as a fetch of its own (on a host the call already reached only a `deny` rule stops it), and the answer says where it ended."
3. The log: "No secret value is ever written to it." → "Stored secrets are masked in every field, what you type included. `harness log verify` also finds lines cut from the end, by the last line named in `state/status`."
4. Memory: "…picks up to 5 lasting facts from the turns since its last run. When the agent or that call saves an item, you get one line: "Saved to memory: … (/forget ID)". A repeat is not saved twice; a correction (another number, or a "not") is a new item." And: "the log keeps only sizes and hashes keyed with `state/log-key`".
5. Briefs: "drops links it sent before (one is forgotten after 60 days out of its feeds)… At most 15 new items per topic go in; the brief says how many more there were. A feed's redirect is followed on its own host, to another host only with an `allow fetch` rule or a grant. A brief or task answer that does not get through runs again after 5 minutes, then 10, 20 … up to 2 hours."
6. Scheduled tasks: "Its answer is sent to you unless it is `NOTHING`; calls skipped for want of approval are listed either way ("Skipped (needs approval): …")."
7. Data folder table, `state/`: add "the log's key".

## A5 (docs only)
- XDG_DATA_HOME is honoured for the default folder: mention it.
- Binary size: Linux musl about 2.1 MB, macOS about 1.7 MB (re-measure after the merge).
- Unit test and smoke check counts (re-count after the merge).

## W (browser, logins) — pending
## S (smoke, approval buttons) — pending

## W (browser, logins)
1. Research: "...with a fresh throwaway profile each time (no cookies, no sign-ins), loading nothing from any host but the page's own and saving no downloads."
2. Logins example output: "Added github-bot to logins.ini (site github.com). Stored its password and TOTP secret in the macOS Keychain."
3. "so the cookies (those that end with the session too), and with them the sign-in, stay for the next turn."
4. "Chrome's own password manager is off in every profile." → "Chrome's own password manager is off in every profile; downloads are refused, and a tab or window a page opens is closed before it loads anything (the agent is told its address). A click is the mouse's, at the element's centre; one under a banner or dialog is refused."
5. Dialogs: "...and the agent sees their text when they come from the page's own host."
6. Bound to the site: "...on the very host the gate allowed the login on, over https..."; "Only fields of the page itself (its open shadow roots too), never of frames."
7. Passkeys: "If the stored passkeys can't be read, none are loaded and new ones aren't saved; the agent is told."
8. Limits: "...and a passkey only for the site or a name below it; a site needs a dot (but `localhost`)..."
9. Limits: "The browser keeps harness's environment." → "The browser gets only PATH, HOME and LANG (on Windows also the system's own variables), and never the macOS Keychain or a desktop keyring."
