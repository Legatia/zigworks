# harness: remote MCP servers (HTTP, token, sign-in) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** A section of `mcp.ini` may name a `url` instead of a `command`: the server is reached over MCP's Streamable HTTP, with a stored token or an OAuth sign-in (`harness mcp login NAME`). Its tools go through the gate, rules, grants, money and the log exactly as a program's (`mcp SERVER/TOOL`). `harness mcp list|login|logout`; `/status` says which servers need a sign-in.

**Architecture:** `mcp.zig` keeps the one `Server` the rest of harness uses (`start`, `tools`, `call`, `readResource`, `subscribe`, `deinit`, `kill`, `stopAll`); a server with a url gets a `remote: *mcp_http.Remote` instead of a process, and the JSON-RPC requests (`initialize`, `tools/list`, `tools/call`, …) are the same code over either transport. `mcp_http.zig` is the transport: a POST per message, JSON or event-stream answers, the session and protocol version, the 404 restart, server requests answered, the GET stream for resource updates, the DELETE on stop, worded errors. `oauth.zig` is the sign-in: discovery, registration, PKCE, the loopback listener, the code exchange, and the `Keeper` that holds a server's tokens (secret `mcp-NAME`), refreshes them and writes them back. `fake_mcp.zig` gets the HTTP stand-in (MCP server and authorization server), routed from `fake.zig`. `main.zig` gets `harness mcp`. `core.zig` passes a server's token or sign-in to `Server.start` and says in `/status` which need a sign-in.

**Tech Stack:** Zig 0.17.1, std only.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-routines-undo-copies-memory-design.md`, Part 1 without the morning routine; rules 4, 6 and 7 of `2026-11-22-harness-platform-overview.md`; error wording as `2026-11-22-harness-model-providers-design.md`.

## Global Constraints

- Zig 0.17.1, std only; macOS, Linux, Windows. At the end these compile: `zig build -Dtarget=x86_64-windows`, `-Dtarget=x86_64-linux-musl`, `-Dtarget=aarch64-linux-musl`, and `zig build unit-build -Dtarget=…` for each; `zig build test` passes in Debug and `-Doptimize=ReleaseSafe`.
- Baseline: 658 pass, 27 skipped, `smoke: all ok` (73 checks). Existing tests change only where behaviour changes on purpose (listed in Done).
- Tokens and sign-in values are stored secrets only (`harness secret add`, or the store's `mcp-NAME` written by `harness mcp login`): never in a file, a log line, a model request, an item, output or test output; masked like every secret, including a token refreshed while harness runs and one a server says back.
- No real services: the stand-in (`fake.zig` / `fake_mcp.zig`) plays the MCP servers and the authorization server; a test is the browser.
- Touch `core.zig` and `agent.zig` only where needed (listed in Done). Every new Core field set in `Core.open`.
- Timing tests leave margins and print what they measured when they fail.
- Copy: plain labels, no slogans.
- Tests from `harness/`: `export PATH=~/.local/zig/zig-aarch64-macos-0.17.1:$PATH; zig build test --summary all --cache-dir $SCRATCH/zc-remote-mcp > FILE 2>&1`, read the tail; one test: `-Dtest-filter=NAME`.

## Rulings

1. **The listener ends on the first `/callback` request; other paths get 404.** What: a request for another path (a browser's `/favicon.ico`, a spare connection that sends nothing) is answered 404 or dropped and does not end it; the first `/callback` ends it whatever it carries (a wrong `state` fails the sign-in, nothing stored). Why: browsers open spare connections and ask for icons; counting those would end a sign-in before its answer. Cost if wrong: for up to 5 minutes another local program can get 404s from the port (it can't sign in: the state is checked).
2. **HTTP failures come back as the tool's error, worded.** What: 401, 403, 429 after its wait, 5xx, a redirect, a 404 without a session and an unreachable server are returned as the call's error result ("atlassian refused the sign-in: harness mcp login atlassian"), not as a Zig error that `agent.zig` would show as "failed: Unauthorized"; at start they are the note's detail. A trigger polling such a server backs off as for any failed poll instead of pausing. Why: the model and the owner see what to do, and `agent.zig` and `sources.zig` stay as they are. Cost if wrong: a trigger on a server whose sign-in was refused retries with backoff (the owner is told after 5 failures) rather than pausing.
3. **`header =` may not set the headers harness writes itself either:** Accept, Accept-Encoding, Connection, Transfer-Encoding, User-Agent, Last-Event-ID (besides the spec's Authorization, Host, Content-*, Mcp-*, MCP-Protocol-Version). Why: a second copy makes the request ambiguous. Cost if wrong: a server that wants its own User-Agent can't get one.
4. **`secret =` is refused in a section with a url;** token, header and login need a url; client_id and scope need `login = oauth`. Why: a line that would do nothing is a mistake the owner should see. Cost if wrong: none known.
5. **A POST's event stream is not resumed.** What: an event stream that ends before its answer fails the call ("the connection ended before the answer"); the GET stream sends `Last-Event-ID` when it reopens. Why: resuming is optional in MCP and needs the server to keep events. Cost if wrong: a call cut off by a proxy fails instead of being resumed (the model can call again).
6. **The GET stream does not restart a session.** What: a 404 on the GET stream marks the session ended; the next request starts it again (once, under the request lock) and subscribes again to what was subscribed. Why: one place restarts sessions, so a stream never races a call. Cost if wrong: updates pause until the next request (triggers read their resources every `every` anyway).
7. **The protected resource metadata comes from the 401's `resource_metadata`, else the well-known places** (`/.well-known/oauth-protected-resource` + the url's path, then at the root, RFC 9728 §3.1). Why: some servers leave the header out. Cost if wrong: none (only tried without the header).
8. **Each login registers a new client** (unless `client_id =`), kept with the tokens. Why: the loopback port changes per login and some servers compare redirect URIs exactly. Cost if wrong: one stale client per login at the authorization server.
9. **`mcp-NAME` holds the tokens, the client and the token endpoint as JSON**, in parts where the store limits a value (`putLong`, the Credential Manager's 2560 bytes). Why: a refresh needs the client and the endpoint, and nothing may be in a file. Cost if wrong: none known.
10. **After a 401 the store is read again before refreshing.** What: a `harness mcp login NAME` done while `harness run` goes is picked up at the next 401 without `/reload`. Why: the spec allows the login with `harness run` going. Cost if wrong: none (one store read per 401).
11. **`harness mcp list` starts program servers to list their tools** (in their own folders, with their secrets, as `harness run` does) and stops them. Why: "its tools when it can be reached"; a program is reached by starting it. Cost if wrong: the command runs the servers' code for a moment (twice over while `harness run` goes).
12. **A url server with neither token nor login is kind `url`** in `mcp list` (the spec names program, token and sign-in). Why: an http server on this machine may need no sign-in. Cost if wrong: one label.

## Files

- Create `src/mcp_http.zig` (transport), `src/oauth.zig` (sign-in), this plan.
- Modify `src/mcp.zig` (keys, `Auth`, the facade), `src/http.zig` (DELETE, `accept`, kept response headers), `src/sock.zig` (`Listener.acceptWithin`), `src/fake_mcp.zig` (HTTP stand-in, authorization server), `src/fake.zig` (routes), `src/fake_main.zig` (`--browse URL`, the smoke's browser), `src/main.zig` (`harness mcp`, masks, `secret list`, test imports), `src/core.zig` (token or sign-in passed to start; `/status`), `scripts/smoke.sh`, `README.md`.

---

### Task 1: mcp.ini — url, token, header, login, client_id, scope

**Interfaces — Produces (mcp.zig):** `ServerConfig.url`, `.token` (a stored secret's name), `.headers: []const std.http.Header` (≤ 8), `.login: bool`, `.client_id`, `.scope` (all defaulted); `pub const Kind = enum { program, token, signin, url }`, `pub fn kind(cfg) Kind`, `pub fn signinSecret(buf, name) []const u8` (`mcp-NAME`); `pub const ConfigError`; `configReason` for each new error: `CommandAndUrl`, `TokenAndLogin`, `PlainHttpUrl`, `BadMcpUrl`, `BadMcpHeader`, `ReservedMcpHeader`, `SecretWithUrl`, `UrlOnlyKey`, `SignInOnlyKey`, `BadLoginValue` (names not used by rules, folders, environments or config, whose reasons share `parseProblem`'s chain).

- [x] Step 1: tests — `bad_mcp_ini_sections_name_their_line` (through `core.parseProblem`: command and url; token and login; http to a non-loopback host; a forbidden header — each "mcp.ini line N has an error: … (reason)"); `parse_config_reads_servers_at_a_url` (the spec's two examples; kinds; loopback http; headers in order; comments after values); `parse_config_refuses_bad_remote_lines` (the other refusals).
- [x] Step 2: run; compile errors (no fields, no errors).
- [x] Step 3: implement. Step 4: whole suite. Step 5: commit `harness mcp: url, token, header and login in mcp.ini`.

### Task 2: Streamable HTTP, the stand-in, and servers at a url in the instance

**Interfaces — Produces:**
- http.zig: `Request.method` gains `DELETE`; `Request.accept` (default `*/*`); `Request.keep: []const []const u8` names response headers kept in `Response.kept` (≤ 4, freed by `deinit`).
- sock.zig: `Listener.acceptWithin(l, timeout_ms, stop) !?Handle` (null: time up or stopped).
- mcp_http.zig: `Auth = union { none, token: {name, value}, signin: *oauth.Keeper }`; `Remote.open(gpa, io, Options) !*Remote`, `request(arena, method, params_json, stop, deadline_ns) ![]const u8` (error.Said: `why()` holds the worded failure), `notify`, `startStream`, `remember(uri)`, `mask(arena, text)`, `signInRefused()`, `end()`, `destroy()`; `protocol_versions = .{"2025-06-18", "2025-03-26"}`.
- mcp.zig: `StartOptions.auth: Auth = .none`; `Server.remote`; `start` of a url server; `call`/`readResource` give `error.Said` as the error result; `stopAll` ends remote servers in parallel with the programs' grace.
- fake_mcp.zig `Http` (in `fake.Server.mcp`): `POST|GET|DELETE /mcp/FLAVOR` (json, sse, old, token, signin), sessions (`endSessions`, `dropStreams`, counters), event-stream answers with a notification and a `ping` first, `notify:URI` pushed on the session's GET stream, every request recorded in `mcp-requests.jsonl`.
- core.zig: `McpStart.auth`; a token server's token by `secretValue` ("token \"X\" is not stored (harness secret add X)" when missing).

- [x] Step 1: tests — mcp_http.zig: `json_and_event_stream_answers_list_and_call_tools`, `a_session_that_ended_is_started_again`, `resource_updates_arrive_over_the_event_stream` (and the stream reopened after it ends), `a_2025_03_26_server_is_taken_and_another_version_refused`, `errors_name_the_server_and_what_to_do` (401 token, 403, 429 waited once, 5xx, a redirect not followed, 404 without a session), `stop_and_the_deadline_end_an_http_call`, `the_session_is_deleted_on_stop`; core.zig: `http_mcp_tools_list_and_call_through_the_gate`, `token_and_headers_are_sent_and_never_logged`.
- [x] Step 2: run; compile errors (no mcp_http, no `fake.Server.mcp`).
- [x] Step 3: implement. Step 4: whole suite. Step 5: commit `harness mcp: servers at a url over Streamable HTTP`.

### Task 3: signing in (OAuth)

**Interfaces — Produces (oauth.zig):** `Tokens` (JSON in `mcp-NAME`), `load(io, gpa, store, name) !?Tokens`, `save`; `login(gpa, io, arena, LoginOptions) !Tokens` (error.Said + `said` text); `Keeper.open(gpa, io, store, name, masks) !*Keeper` (error.NotSignedIn), `bearer`, `renew(used)`, `refused()`. Fake: protected resource metadata, RFC 8414 and OpenID metadata, `/auth/register`, `/auth/authorize` (302 back with code, state, iss), `/auth/token` (PKCE S256 checked; refresh rotates), `expireTokens()`.

- [x] Step 1: tests — oauth.zig: `oauth_login_registers_exchanges_and_refreshes` (metadata, registration, PKCE and state checked by the stand-in, tokens kept; a keeper refreshes before expiry and once after a 401), `the_login_listener_takes_one_request_and_ends` (a wrong state ends it with nothing stored, the port closes; no request: it ends at its time), `a_set_client_id_skips_registration_and_openid_is_the_fallback`; core.zig: `a_sign_in_server_starts_signed_in_and_status_says_when_not`.
- [x] Step 2: run; compile errors. Step 3: implement. Step 4: whole suite. Step 5: commit `harness mcp: sign in with OAuth`.

### Task 4: harness mcp list, login, logout

**Interfaces — Produces (main.zig):** `mcp list | login NAME | logout NAME` (usage, `badArgs`); `App.mcpSecrets` adds tokens and sign-in values (masked from the start); `secret list` lines for tokens and sign-ins. fake_main.zig `--browse URL` (follows the stand-in's redirect to the listener).

- [x] Step 1: tests — main.zig `mcp_commands_take_their_arguments`; smoke: `mcp list` (program and token servers, their tools), `mcp login` through the browser stand-in, the tokens in the store and nowhere else, `mcp list` says signed in, `mcp logout`.
- [x] Step 2–5: run, implement, suite, commit `harness mcp: mcp list, login and logout`.

### Task 5: README and final checks

- [x] README: remote servers (url, token, header), signing in (login, logout, `ssh -L` for a machine without a browser), errors, what is not built (client credentials, device flow, signing in from chat; a token in another header), commands, the State line's counts.
- [x] Debug and ReleaseSafe suites; cross builds and `unit-build`; commit `harness mcp: README for servers at a url and signing in`.

## Done

- Branch `platform/remote-mcp`: plan 3bbff8c; Task 1 52a5ee8, Task 2 918670d, Task 3 b305abd, Task 4 87f841e, Task 5 (README, a logout a running harness respects, this section).
- Debug and ReleaseSafe: `Build Summary: 8/8 steps succeeded; 680/707 tests passed (27 skipped)` (baseline 658/685: +22); `smoke: all ok` (78 checks: +5). Cross builds and `unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl compile.
- No existing test changed.
- core.zig: `McpStart.auth` and its pass to `Server.start`; in `startMcp`, a token server's token (`secretValue`) and a sign-in server's store (not signed in: skipped with "not signed in (harness mcp login NAME)"); `/status`'s MCP part through `mcpStatus` (servers whose sign-in was refused since). Three tests next to the MCP tests. agent.zig: untouched (Ruling 2).
- Further rulings made while building:
  13. **A failure at start keeps its kind as the error name** (Refused, NotFound, Redirected, RateLimited, Upstream, Unreachable, BadVersion, BadAnswer), the worded text as the note's detail: core's note format stays ("atlassian: did not start (Refused) atlassian refused the sign-in: harness mcp login atlassian"). Cost if wrong: the word in parentheses repeats what follows.
  14. **A logout is respected by a running harness**: a renewal first reads the store; nothing kept means refused (no renewal writes the tokens back), and `/reload` stops the server. Why: "logout forgets the tokens" would otherwise be undone at the next renewal. Cost if wrong: one store read per renewal.
  15. **`harness mcp login|logout` refuse a name starting with `-`** (an option), though mcp.ini takes one. Cost if wrong: such a server can't be signed in to from the terminal.
- Left out: the morning routine (after workflows, as the spec orders); resuming a POST's event stream (Ruling 5); client-credential and device sign-ins and signing in from a conversation (the spec's "not built"); a stored secret in another header than Authorization; proxies.
