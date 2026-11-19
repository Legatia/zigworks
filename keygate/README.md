# keygate

Lets an agent use API keys it never sees. The agent gets a placeholder and a
local URL; keygate holds the real key, checks each request against your
rules, adds the key on the way out, and masks it in what comes back.

```
agent ──http──▶ 127.0.0.1:7311/github/... ──https──▶ api.github.com
   placeholder        checks the rule            real key in the header
   ◀── answer with the key masked, one log line per request
```

macOS, Linux (x86_64, arm64) and Windows (x86_64). One binary, nothing
beyond the Zig standard library (and the system's Security framework on
macOS). Values live in the macOS Keychain, the Windows Credential Manager,
or on Linux in files only you can read.

**State: 0.1.0, tested by its own tests (unit tests, and an end-to-end
script against a stand-in service) on macOS, and by hand over https against
httpbin.org with a dummy key. Not yet used with an agent day to day, and the
Windows store has only been compiled, not run.** See [Limits](#limits).

## Quick start

1. Write the rules, `~/.config/keygate/rules` (`%APPDATA%\keygate\rules` on
   Windows), and make sure only you can change it (`chmod 600`):

   ```ini
   [github]
   upstream = https://api.github.com
   header = Authorization: Bearer {secret}
   allow = GET /repos/me/scratch/
   allow = POST /repos/me/scratch/issues
   expires = 2026-12-31
   env = GITHUB_TOKEN
   ```

2. Store the value. It is typed at the terminal and not shown; never paste
   it into the agent's chat:

   ```
   $ keygate add github
   Value for github (not shown):
   Stored github in the macOS Keychain.
   ```

3. Start the gateway and give its output to the agent's environment:

   ```
   $ keygate serve --env-file ~/.keygate.env
   keygate 0.1.0: listening on 127.0.0.1:7311, logging to ~/.local/state/keygate/log.jsonl
   Give the agent these (placeholders, not the values):
   GITHUB_TOKEN=kg-github-3f9c…
   KEYGATE_GITHUB_URL=http://127.0.0.1:7311/github
   ```

4. The agent calls the URL with the placeholder where the key would go:

   ```
   curl -H "Authorization: Bearer $GITHUB_TOKEN" "$KEYGATE_GITHUB_URL/repos/me/scratch/issues"
   ```

   SDKs that take a base URL work the same way: base URL
   `$KEYGATE_GITHUB_URL`, key `$GITHUB_TOKEN`.

## Rules

One section per secret. Nothing is sent that no `allow` line names.

| Key | Meaning |
|---|---|
| `upstream` | `https://host[:port][/base]`. `http://` only for this machine. |
| `header` | The header the real value goes in; `{secret}` marks where. |
| `allow` | `METHOD /path-prefix`, one per line; `*` for any method. A prefix ends at a path segment: `/repos/me` covers `/repos/me/x`, not `/repos/meow`. |
| `expires` | `YYYY-MM-DD` or `YYYY-MM-DDTHH:MMZ`, UTC. After it, every request is refused. |
| `env` | The variable name for the placeholder (and for `keygate run`). Default `KEYGATE_<NAME>`. |

## What the gateway does with each request

Refused, with a line in the log, when:

- the Host header is not this gateway (a web page using DNS rebinding);
- it doesn't carry the secret's placeholder in some header (any other
  program on the machine, or a browser);
- its path has `..`, `//`, a backslash, or an encoded `/`, `.`, `\` or `%`
  (paths that could mean a different path upstream than the rule saw);
- no `allow` line covers the method and path, or the rule has expired;
- it asks for an upgrade (WebSocket) or `CONNECT`.

Otherwise the request goes upstream with the placeholder's headers removed,
the rule's header added with the real value, `Accept-Encoding: identity`,
and nothing else changed. Redirects are not followed. The answer comes back
whole, with the value masked as `[keygate:NAME]` in the body and headers:
the value itself, its hex, its percent-encoding and its base64 at any
alignment (as in a `Basic` header). An answer the service sends compressed
anyway is refused, since it can't be checked.

The log (`~/.local/state/keygate/log.jsonl`) gets one JSON line per request:
time, secret, method, path without the query, allowed or denied and why,
status, and how many values were masked. Neither the value nor the
placeholder is ever written to it.

## keygate run: the weaker mode

Some tools need the real value: `gh`, `npm publish`, a database client.

```
keygate run github -- gh issue list
```

puts the value in that one command's environment (as `env` names it) and
masks it in the command's output. This is weaker than the gateway, and
keygate says so each time: the command, and anything it starts, can read
the value and send it anywhere. Masking catches accidents, not a program
that sets out to disguise a value (printing it as character codes, for
example). Use the gateway where the service has an HTTP API.

## Limits

- **Same user, same machine.** keygate keeps the key out of the model's
  context and limits what requests can do with it. It is not a wall against
  an agent that runs arbitrary commands as you: such an agent can edit the
  rules file before the next `serve`, read the Linux store's files, or ask
  the Keychain (which normally asks you first). For that, run the agent in
  a sandbox or as another user, where only the gateway's port is reachable.
- **Allowed is allowed.** A rule bounds which calls the key can make, not
  what the agent does with the answers. Keep `allow` lines narrow: write
  endpoints on public services (comments, gists) are how keys and data have
  leaked through allowed hosts.
- **No streaming.** Answers are read whole (up to 64 MiB) before they are
  masked and passed on, so streamed answers (server-sent events) arrive at
  once at the end. Requests up to 32 MiB.
- **Header credentials only.** A key that goes in the query string or the
  body is not supported.
- **Masking is a guard against accidents.** In tests by others, models that
  could read a value got it past output redaction by encoding it first. The
  gateway's protection is that the agent never has the value; masking only
  stops the service from handing it back.
- **Keychain prompts.** On macOS, each new build of keygate is a new program
  to the Keychain, which may ask once before giving it a value it stored
  with an earlier build.
- **Linux store.** Files in `~/.local/share/keygate/secrets`, mode 600 in a
  700 directory; not encrypted. The Secret Service (GNOME Keyring, KWallet)
  is not used yet.

## Build

```
zig build                     # zig-out/bin/keygate
zig build test --summary all  # unit tests, then scripts/smoke.sh end to end
```

Zig 0.17.1.
