# harness: the gate as an MCP proxy for other agents

2026-11-27. From the gaps list (`2026-11-23-harness-gaps.md`, "Hermes
differentiators": "the gate as an MCP proxy for other agents (open)").
Builds on `2026-11-19-harness-design.md` (the gate, the inbox's
approvals), the MCP client (README, "MCP"), the who of a call
(`who.zig`) and the voice agent's server (`voiceagent.zig`), whose shape
this one copies.

The owner was not asked about the details here; they said to go on
building what doesn't need them. Every choice below that isn't in the gaps
line is the builder's call and is marked **Call**.

## Intent

harness already holds the owner's MCP servers (mcp.ini), their sign-ins
and keys, the rules about them, the approvals and the log. Another agent
on the same machine (Claude Code, Codex, Hermes, a script) that is given
those servers directly gets none of that: it holds the keys itself and
calls what it likes. With the proxy the other agent is given one MCP
server, harness. Each of its calls is decided by the gate as a call of
that agent, asked of the owner where a rule or the default says ask,
logged, and only then passed to the real server. The other agent never
holds the server's key.

## What it adds

harness serves MCP over Streamable HTTP inside `harness run`, at
`http://127.0.0.1:8766/mcp`. An outside agent is a **client**: a
`[client NAME]` section in config.ini and a token of its own.

```ini
[proxy]
listen = 127.0.0.1:8766     ; off: no proxy

[client claude-code]
servers = github, notes     ; mcp.ini's servers this client may reach
; token = client-claude-code  ; the stored secret holding its token
; money = off                 ; on: it may call tools that move money (asked every time)
```

```
harness secret add client-claude-code     # a token of 32 characters or more
claude mcp add --transport http harness http://127.0.0.1:8766/mcp \
  --header "Authorization: Bearer THE-TOKEN"
```

1. **What a client sees.** `tools/list` gives the tools of the servers its
   section names, under the names harness's own agent sees
   (`server__tool`), with their descriptions and input schemas. A server
   that is not named is not there for it. Tools that move money are listed
   only with `money = on`. **Call:** nothing is offered unless named;
   there is no `servers = *`. A new server in mcp.ini reaches no outside
   agent until the owner names it.
2. **A call is a gated call of that client.** `tools/call` runs as
   `client:NAME` (a new kind of who), with no agent definition, through
   the same path as an app's act: hard limits, deny rules, grants, the
   default for MCP tools (ask), allow and ask rules. Rules for it go in
   `[client:NAME]` or `[client]` sections of rules.ini; the sections
   without a who apply too, as for every call.
3. **Asking.** A call the gate asks about becomes an approval in the
   owner's inbox (conversation `main`), its text starting
   `[client:NAME] `. The HTTP request waits for the answer, at most
   `[limits] approval_seconds`. "Allow 24 h" grants that tool to
   `client:NAME` only. A denial, a timeout or a refusal comes back as the
   tool's result with `isError: true` and the gate's sentence ("refused
   by the gate: ...").
4. **Money.** Without `money = on` a money tool is refused for a client
   ("a client's calls move no money ([client NAME] money = on)"). With
   it, each call is asked every time (never a day's grant), within the
   caps of `[money]` and the server, and is written to the money record,
   as the owner's own agent's.
5. **What goes back.** The server's answer as text, with the stored
   secrets masked, as harness's own agent would get it.
6. **Hanging up withdraws.** When the client closes the connection while
   its call waits (its own timeout, or the user stopped it), the approval
   is withdrawn ("its run stopped") and the call is not made. `/stop`
   ends waiting calls too.
7. **The log** has each decision and call with `"run":"client NAME"`,
   `"by":"client:NAME"`.

## The settings

- `[proxy] listen`: an address of this machine and a port, or `off`.
  **Call:** loopback only in this version (127.0.0.1 or ::1); another
  address is refused when the file is read, with the reason. The requests
  are plain HTTP with a bearer token; an agent on another machine reaches
  it through an SSH tunnel.
- `[client NAME]`: NAME is a-z, 0-9, `-`, `_`, at most 32, starting with a
  letter or digit; at most 16 clients. Keys: `servers` (names as in
  mcp.ini, separated by commas; empty: the client is served and sees no
  tools), `token` (a stored secret's name; default `client-NAME`),
  `money` (on or off; default off). An unknown key is refused.
- The proxy runs with `harness run` when at least one client's token is
  stored. A client whose token is not stored, is shorter than 32
  characters, or equals an earlier client's is not served; `/status` and
  a message to the owner say which and why. With no `[client]` section
  nothing runs and nothing is said.
- Only the SHA-256 of each token is kept in memory; the token itself is
  masked wherever harness writes.
- `/reload` applies changes (the proxy restarts when its address, a
  client's name, token, servers or money changed). `harness config set
  client NAME.servers "github, notes"` works like the provider sections.
- `/status` has a line: `Proxy: MCP for other agents on 127.0.0.1:8766:
  claude-code (github, notes).`, and names a server a client lists that
  mcp.ini doesn't have.
- `/access client:NAME` answers as `/access app:NAME` does.

## The protocol

**Call:** the smallest correct server.

- `POST /mcp`, one JSON-RPC message per request, answered with
  `application/json`. No sessions (`Mcp-Session-Id` is not sent), no
  server-sent events: `GET` and `DELETE` are answered 405, which the
  specification allows.
- `initialize`: answers the client's `protocolVersion` when it is
  2025-06-18 or 2025-03-26, else 2025-06-18; capabilities `tools` only;
  `serverInfo` harness and its version; `instructions` saying that calls
  pass harness's gate, may wait for the owner's approval, and that a
  refusal starts with "refused by the gate".
- `ping`: `{}`. Notifications and responses (no `method`, or no `id`):
  202 with no body.
- `tools/list`: all of the client's tools at once (no cursor).
  `tools/call`: `{"content":[{"type":"text","text":...}],"isError":...}`.
  A name that is not among the client's tools: error -32602.
- An unknown method: -32601. A batch (an array): -32600. A body that is
  not JSON: -32700. A `MCP-Protocol-Version` header naming another
  version than the two: 400.
- The token is checked before the body is read: `Authorization: Bearer
  TOKEN`, else 401. The body is at most 1 MiB (413).
- A request with an `Origin` header is refused (403) unless the origin is
  the proxy's own address (`http://127.0.0.1:PORT`, `http://localhost:PORT`
  or `http://[::1]:PORT`): a web page in a browser never reaches it.
- At most 32 connections; at most 4 calls of one client going at once (a
  fifth is answered at once as a tool result with `isError`).
- Refusals are logged at most once a minute per kind, never with the
  token.

## With `/reload`

`/reload` frees the MCP servers and their tool lists, so a listing or a
call holds a claim `/reload` respects: while a client's call goes or
waits for its approval, `/reload` answers "Busy; send /reload again when
nothing is running.", as it does for a run. A request that arrives while
the servers restart waits up to 3 seconds, then is answered with an error
to try again. **Call:** the claim is counted apart from the background
runs, so a client's call waiting for its approval does not take a
scheduled run's place.

After a reload that changes the tools, a client learns of it when it
lists again (there is no stream to notify it on).

## Not in this

- harness's own tools (files, shell, web, send, memory) for outside
  agents: only the MCP servers' tools pass.
- MCP resources and prompts; the stdio transport; `servers = *`;
  listening beyond loopback; TLS.
- A conversation, memory or model for the client: harness adds no model
  call of its own to a proxied call.
- A command that prints the lines to paste: the README shows them for
  Claude Code, Codex and Hermes. **Call:** the token is the owner's to
  paste; harness never prints it.

## Tests that must exist

With the stand-in MCP server (`harness-fake --mcp`) behind a core, and a
plain HTTP client:

1. `client:NAME` is a who: a `[client:NAME]` section reaches that client's
   calls and no other's; "Allow 24 h" for one client does not cover
   another.
2. The settings: `[proxy]` and `[client NAME]` parse; a listen address
   that is not loopback, a bad name, an unknown key, a bad server name
   and a seventeenth client are refused with a reason.
3. No token, a wrong token: 401, and the body is not read. A known token
   names its client.
4. `initialize`, `ping`, a notification, `tools/list`, an unknown method,
   a batch, a body that is not JSON, `GET`, a foreign `Origin`, a body
   over the limit: each answered as above.
5. `tools/list` holds the tools of the named servers only, and no money
   tool without `money = on`.
6. A call the gate asks about: the inbox item is by `client:NAME`, its
   text starts `[client:NAME] `; "Allow once" makes the call and the
   answer goes back; "Deny" comes back with `isError` and the gate's
   sentence; the log has `"run":"client NAME","by":"client:NAME"`.
7. A rule in `[client:NAME]` allows without asking; a deny rule refuses.
8. A tool of a server the client doesn't name: -32602, nothing asked.
9. A money tool: refused without `money = on`; asked every time with it,
   with no "Allow 24 h" choice.
10. The client hangs up while its call waits: the item is withdrawn and
    the server is not called. `/stop` does the same.
11. `/reload` is refused while a call waits, and works after it ended; a
    reload that changes a client's servers changes what it lists.
12. A client whose token is short, missing or the same as another's is
    not served, and `/status` says why; with no client nothing listens.
13. The token is nowhere in the log.
