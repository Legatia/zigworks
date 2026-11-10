# headterm

A headless terminal for AI agents, as a CLI and an MCP server. headterm runs a
program in a pseudo-terminal, keeps an emulated screen, and lets an agent read
the screen as text, see which rows changed, send keys and mouse events, and
wait for text or for output to go quiet. It drives full-screen programs (vim,
less, top, curses UIs, REPLs, `git add -p`) without tmux scripting.

Zig standard library and libc only. macOS and Linux.

## Quick start

```sh
headterm start py -- python3 -q                 # start a session named "py"
headterm wait py --text '>>> '                  # wait for the prompt, print the screen
headterm send py 'sum(range(10))' '<Enter>'     # type text and keys
headterm wait py --idle 300 --diff              # wait for quiet, print changed rows
headterm kill py                                # end the session
```

```
$ headterm wait py --idle 300 --diff
0|>>> sum(range(10))
1|45
2|>>>
[headterm] py 120x40 cursor=2,4 changed=3 running wait=ok(idle) waited=303ms
```

`headterm help <command>` lists a command's options.

## Build

Requires Zig 0.15.1.

```sh
zig build                          # zig-out/bin/headterm
zig build test                     # unit tests and end-to-end tests (CLI and MCP)
zig build -Doptimize=ReleaseSafe   # optimized build
```

## MCP server

`headterm mcp` serves MCP over stdio. Register it with Claude Code:

```sh
claude mcp add headterm -- /absolute/path/to/headterm mcp
```

Add `--scope user` after `add` to make it available in every project.

Example round trip (real output; `jsonrpc` fields trimmed):

```
→ {"id":1,"method":"tools/call","params":{"name":"headterm_start","arguments":{"name":"py","command":["python3","-q"],"cols":60,"rows":10,"then_wait":{"text":">>> "}}}}
← {"id":1,"result":{"content":[{"type":"text","text":"started py pid=67260\n>>>\n[headterm] py 60x10 cursor=0,4 running wait=ok(text) waited=78ms"}],"isError":false}}
→ {"id":2,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"py","keys":["sum(range(10))","<Enter>"],"then_wait":{"regex":"^\\d+$"}}}}
← {"id":2,"result":{"content":[{"type":"text","text":">>> sum(range(10))\n45\n[headterm] py 60x10 cursor=2,0 running wait=ok(regex) waited=2ms"}],"isError":false}}
→ {"id":3,"method":"tools/call","params":{"name":"headterm_kill","arguments":{"name":"py"}}}
← {"id":3,"result":{"content":[{"type":"text","text":"killed py"}],"isError":false}}
```

| Tool | Arguments | Returns |
| --- | --- | --- |
| `headterm_start` | `name`, `command`, `cols?`, `rows?`, `cwd?`, `ttl_s?`, `record?`, `then_wait?`, `styles?` | `started <name> pid=N` and the first screen |
| `headterm_send` | `name`, `keys`, `literal?`, `paste?`, `esc_delay_ms?`, `then_wait?`, `styles?` | the screen after `then_wait`, or `sent` |
| `headterm_screen` | `name`, `diff?`, `scrollback?`, `styles?` | the screen |
| `headterm_wait` | `name`, `text?`, `regex?`, `gone?`, `idle_ms?`, `exit?`, `timeout_ms?`, `styles?` | the screen |
| `headterm_resize` | `name`, `cols`, `rows` | confirmation |
| `headterm_kill` | `name` | confirmation |
| `headterm_list` | none | one line per session |

- `headterm_start` returns after 300 ms without output (at most 5 s), or
  when `then_wait` is met.
- `then_wait` has the fields of `headterm_wait`; `{}` means `{"idle_ms":300}`.
  `idle_ms` and `timeout_ms` are capped at 60000.
- `keys` elements are always keys or text, never options; `literal`, `paste`
  and `esc_delay_ms` are separate arguments.
- MCP sessions end after an hour without calls or output (`ttl_s`, 0 =
  never). They are ordinary sessions, so the CLI works on them too.
- Each MCP server process has its own diff marker.
- Screens leave out empty rows at the bottom (as with `--trim`).
- Tool failures (unknown session, rejected key, failed start, wait timeout)
  are results with `isError: true`; a failed wait still returns the screen.
  Protocol errors: `-32700` malformed JSON, `-32600` invalid request,
  `-32601` unknown method, `-32602` unknown tool or bad arguments (including a
  bad regex).
- Requests run one at a time. During a wait the server still reads stdin: a
  `notifications/cancelled` for the running request stops it (no reply), and
  other messages are handled afterwards in order. When stdin closes, queued
  requests finish, then the server exits.
- Protocol versions 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25; tools
  only. Nothing but JSON-RPC messages is written to stdout.

## Commands

| Command | Description |
| --- | --- |
| `start <name> [options] -- <cmd> [args...]` | Starts `cmd` in a new session and returns once it runs. Options: `--cols N` (120), `--rows N` (40), `--cwd DIR`, `--ttl S`, `--record FILE`, `--log FILE`. |
| `screen <name> [options]` | Prints the screen. Options: `--json`, `--diff`, `--styles`, `--trim`, `--scrollback N`, `--client ID`. |
| `send <name> [options] [--] <keys>...` | Sends keys, text and mouse events. Options: `--literal`, `--paste`, `--esc-delay MS`. |
| `wait <name> <conditions> [options]` | Waits for `--text`, `--regex`, `--text-gone`, `--idle MS` or `--exit` (default `--timeout` 10000), then prints the screen. Takes the `screen` options. |
| `resize <name> <cols> <rows>` | Resizes the terminal; the program gets SIGWINCH. |
| `kill <name>` | SIGHUP, then SIGTERM, then SIGKILL (500 ms apart) to the program's process group; removes the session. |
| `list [--json]` | Lists sessions; removes sockets left by crashed servers. |
| `mcp` | Runs the MCP server. |
| `help [command]`, `version` | |

Session names: 1-64 letters, digits, `.`, `_`, `-`, not starting with `.` or
`-`. Exit codes: `0` ok, `1` wait not met, `2` error (message on stderr).

### Sessions

- **Location:** each session is a background server listening on
  `$XDG_RUNTIME_DIR/headterm/<name>.sock`, or
  `$TMPDIR/headterm-$UID/<name>.sock` (`TMPDIR` defaults to `/tmp`). The
  directory has mode 0700, and headterm refuses one owned by another user.
- **Environment:** the program gets `TERM=xterm-256color` and the caller's
  environment, minus `COLUMNS` and `LINES`.
- **After exit:** the session outlives the program, so its last screen and
  exit status stay readable until `kill`.
- **TTL:** `--ttl S` ends the session after S seconds with no request and no
  output; a pending `wait` keeps it alive, and a program that keeps printing
  never expires. The CLI default is no TTL; MCP sessions default to 3600.
  `list --json` shows `ttl_s`.
- **Recording:** `--record FILE` writes an asciicast v2 file (`asciinema play
  FILE`). It holds a header with size and command, `"o"` events for output,
  `"i"` events for keys from `send`, and `"r"` for resizes. Invalid UTF-8 is
  recorded as U+FFFD, as asciinema does.

### send

Each argument is text or a key; key names are case-insensitive:

`<Enter>` `<Tab>` `<Esc>` `<Backspace>` `<Space>` `<Up>` `<Down>` `<Left>`
`<Right>` `<Home>` `<End>` `<PageUp>` `<PageDown>` `<Insert>` `<Delete>`
`<F1>`..`<F12>` `<lt>` (a literal `<`)

Modifiers: `<C-x>` Ctrl, `<M-x>` or `<A-x>` Alt, `<S-x>` Shift. They combine
(`<M-C-x>`) and work on named keys (`<C-Left>`, `<S-Tab>`). Arrows, Home and
End follow the program's cursor-key mode (DECCKM).

Mouse events take 0-based positions, like the cursor:

| Event | Sends |
| --- | --- |
| `<Click r,c>`, `<RightClick r,c>`, `<MiddleClick r,c>` | press and release |
| `<Drag r1,c1 r2,c2>` | press, motion along the path (in modes 1002 and 1003), release |
| `<ScrollUp r,c>`, `<ScrollDown r,c>` | wheel event |
| `<S-Click r,c>`, `<C-…>`, `<M-…>` | the same with Shift, Ctrl or Meta |

Mouse events work only after the program has enabled mouse reporting (modes 9,
1000, 1002 or 1003); otherwise `send` fails and sends nothing. They use the
SGR encoding if the program enabled mode 1006, else the X10/X11 encoding
(positions up to 223). Tested with
`vim -u NONE -c 'set nocompatible showmode mouse=a ttymouse=sgr'`: a click moves
the cursor there, and a drag starts `-- VISUAL --` with the dragged lines
selected.

- An unknown `<Name>` is an error; nothing is sent.
- `--literal` sends the following arguments as text, unparsed.
- `--paste` sends them as one block of text, in bracketed-paste markers if the
  program enabled mode 2004.
- Options are read up to `--` or `--literal`, so `send s -- --literal` types
  `--literal`.
- After a lone `<Esc>` followed by more input, headterm pauses 100 ms
  (`--esc-delay MS`, 0 = none), because busybox vi and readline read `ESC :` as
  Alt-`:`. vim's own Esc timeout can be longer; wait for `--idle` before
  relying on the mode change.
- `send` returns once the input is queued; `wait` shows the effect.

### wait

| Condition | Met when |
| --- | --- |
| `--text STR` | STR is on screen (trailing blanks count, so `'>>> '` matches a prompt) |
| `--regex RE` | a screen line, trailing spaces removed, matches RE |
| `--text-gone STR` | STR is not on screen (spinners, "Loading…") |
| `--idle MS` | no output for MS, counted from the later of the wait's start and the last output |
| `--exit` | the program exited |

The first condition met ends the wait.

- The current screen counts: `--text-gone` is met at once if the text never
  appeared, so wait for the text first if it may not be there yet.
- Text and regex match logical lines: rows that wrapped at the right edge are
  joined, so a long path split across rows still matches.
- If the program has exited and only screen conditions were given, the wait
  fails at once (reason `exited`).
- If the session is killed during a wait, the client gets the last screen
  with reason `killed` (exit code 1).

Regex syntax (own engine, `src/regex.zig`; an NFA, so matching is linear in
the screen size and cannot hang):

| Syntax | Meaning |
| --- | --- |
| `.` `[abc]` `[a-z]` `[^...]` | any character except newline; classes |
| `\d` `\w` `\s`, `\D` `\W` `\S` | digit, word, space and their complements (complements not inside `[...]`) |
| `^` `$` `\b` `\B` | line start and end, word boundary and its complement |
| `a\|b` `(...)` `(?:...)` | alternation, groups |
| `*` `+` `?` `{n}` `{n,}` `{n,m}` | repetition, counts up to 1000 |
| `\.` `\(` `\t` | escaped characters |
| `(?i)` at the start | ASCII letters match either case |

No backreferences or lookaround. A bad pattern is an error naming the problem
and its offset, e.g. `missing ')' at offset 4`.

### Diffs

`--diff` prints only the rows whose text or styles changed since this client
last got the screen from `screen` or `wait`. A moving menu selection counts,
even if no text changed, and after a resize every row does. `--client ID`
(1-64 bytes) picks a marker; without it, a shared default is used. Each MCP
server uses its own. A session keeps 64 markers and drops the least recently
used.

### Styles

`--styles` lists, per row, the runs of cells with non-default attributes:
selected menu items, red errors, focused fields.

```
$ headterm wait menu --text unsaved --styles
┌─ File ─────────────────────┐
│  Open                      │
...
[headterm] styles (row: [start-end attributes "text"], 0-based columns, end exclusive)
row 0: [2-8 bold " File"]
row 1: [2-13 inverse " Open"]
row 6: [2-17 fg=red "unsaved changes"]
[headterm] menu 30x8 cursor=6,17 alt running wait=ok(text) waited=55ms
```

- Columns are cells (a wide character takes two), `end` exclusive.
- The text has trailing spaces removed and is JSON-escaped; it is left out for
  all-blank runs such as a colored bar.
- Attributes, in order: `bold` `dim` `italic` `underline` `blink` `inverse`
  `hidden` `strike` `overline`, then `fg=` and `bg=`.
- Colors: `black` `red` `green` `yellow` `blue` `magenta` `cyan` `white`,
  `bright-<name>` (8-15), `16`-`255`, `#rrggbb`.
- Erased cells take the current background color (xterm's `bce`), so a bar
  drawn with an erase shows as a `bg=` run.

## Output

### Text

The screen rows (trailing spaces removed; `--trim` drops empty rows at the
bottom), then a status line:

```
[headterm] <name> <cols>x<rows> cursor=<row>,<col> [alt] [title="..."] [changed=N] <state> [wait=ok(<reason>)|wait=failed(<reason>) waited=<ms>ms]
```

- **State:** `<state>` is `running`, `exited=<code>` or
  `killed-by-signal=<n>`. Positions are 0-based.
- **`--diff`:** prints changed rows as `<row>|<text>`.
- **`--scrollback N`:** prints up to N older lines first, then
  `[headterm] end of scrollback (<n> lines)`.
- **`--styles`:** adds a `[headterm] styles ...` line and `row <n>: [...]`
  lines before the status line.

### JSON (`screen --json`, `wait --json`)

One object and a newline. Fields come in this order; "only" fields are
otherwise absent.

```json
{
  "name": "ed", "cols": 60, "rows": 10,
  "cursor": {"row": 1, "col": 16, "visible": true},
  "alt_screen": true, "title": "", "app_cursor_keys": true, "bracketed_paste": true,
  "pid": 18964, "exited": false, "exit_code": null, "exit_signal": null,
  "lines": ["line one", "line two (edited)", "..."],
  "styles": [[], [{"start": 0, "end": 17, "text": "line two (edited)", "attrs": ["bold"], "fg": "red", "bg": null}], "..."],
  "changed": [{"row": 1, "text": "line two (edited)", "styles": ["..."]}],
  "scrollback": ["older line", "..."],
  "wait": {"condition": "idle", "satisfied": true, "reason": "idle", "elapsed_ms": 402}
}
```

| Field | Meaning |
| --- | --- |
| `cursor` | 0-based position; `visible` is DECTCEM. |
| `alt_screen`, `app_cursor_keys`, `bracketed_paste` | Alternate screen, DECCKM and mode 2004 are on. |
| `title` | Last OSC 0/2 title. |
| `exit_code`, `exit_signal` | Set after a normal exit or a fatal signal; `null` while running. |
| `lines` | Every row. Absent with `--diff`. |
| `styles` | Only with `--styles` and without `--diff`: runs per row, parallel to `lines`; `fg`/`bg` are `null` for the default color. |
| `changed` | Only with `--diff`: changed rows; with `--styles` each has its `styles`. |
| `scrollback` | Only with `--scrollback N`: oldest first. |
| `wait` | Only from `wait`. `condition`: the first given, in the order text, regex, gone, idle, exit. `reason`: the condition met, or `timeout`, `exited`, `killed`. |

### JSON (`list --json`)

```json
[{"name":"ed","command":["vi","notes.txt"],"cols":60,"rows":10,"title":"","alt_screen":true,
  "pid":18964,"exited":false,"exit_code":null,"exit_signal":null,
  "server_pid":18963,"started_at_ms":1794304777917,"ttl_s":null}]
```

## Terminal emulation

Own parser and screen model (`src/vt.zig`): Paul Williams' DEC parser state
machine, with UTF-8 in the ground state. Unknown sequences are consumed, never
printed.

- **Text:** UTF-8 (invalid bytes become U+FFFD). Wide characters and emoji
  are 2 cells (table-based). One combining mark per cell is kept with its base
  character. Autowrap with pending wrap, tab stops, and DEC line drawing.
- **Cursor and editing:** CUU CUD CUF CUB CNL CPL CHA HPA HPR VPA VPR CUP HVP,
  IND RI NEL, DECSC/DECRC, CSI s/u, origin mode. ED EL ECH ICH DCH IL DL SU SD
  REP, insert mode, DECALN.
- **Screens:** scroll regions; alternate screen 47/1047/1049 with a saved
  cursor per screen; 2000 lines of scrollback.
- **Modes:** DECCKM, DECKPAM, DECAWM, DECTCEM, 2004, 1004, mouse
  9/1000/1002/1003/1006.
- **SGR:** full, including `38;5;n`, `38;2;r;g;b` and the colon forms; stored
  per cell.
- **Replies to the program:** CPR, DSR, DA1 (`ESC[?62;22c`), DA2, XTVERSION,
  DECRQM, `CSI 18 t`, OSC 10/11 color queries.
- **OSC:** OSC 0/2 set the title; other OSC, DCS, SOS, PM and APC strings are
  ignored.
- **Resize:** no reflow; if the cursor would fall off the bottom, top lines go
  to scrollback.

## Layout

| File | Contents |
| --- | --- |
| `src/main.zig` | CLI and help |
| `src/client.zig` | Session paths, start, list, socket client |
| `src/server.zig` | Session server: event loop, requests, rendering |
| `src/vt.zig` | Parser and screen model (no I/O) |
| `src/keys.zig` | Keys and mouse events to bytes |
| `src/regex.zig` | Regex engine |
| `src/record.zig` | asciicast v2 writer |
| `src/pty.zig` | PTY and child process |
| `src/mcp.zig` | MCP server |
| `src/session_test.zig` | Tests against real session servers |
| `scripts/smoke.sh`, `scripts/mcp_smoke.sh` | End-to-end tests, run by `zig build test` |

Socket protocol: the client sends `<len>\n` and `<len>` bytes of NUL-terminated
arguments; the server answers `ok|timeout|error`, `\n` and the body, then
closes.

## Limitations

- **Mouse:** no plain motion (mode 1003 hover) and no 1005/1015 encodings.
- **Underline:** color and kind (double, curly) are parsed but not reported.
- **Resize:** no reflow.
- **Character widths:** from a built-in table, which can disagree with the
  program's `wcwidth`. A second combining mark on a character is dropped.

## License

MIT
