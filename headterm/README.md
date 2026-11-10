# headterm

A headless terminal for AI agents, usable as a CLI or as an MCP server.
headterm runs a program in a pseudo-terminal, keeps an emulated screen, and
lets an agent read the screen as plain text, see which rows changed, send
keys, and wait for text or for output to go quiet. It drives full-screen
programs (vim, less, top, curses UIs, REPLs, `git add -p`) without tmux
scripting.

Written in Zig with no dependencies beyond the Zig standard library and libc.
Runs on macOS and Linux.

## Build

Requires Zig 0.15.1.

```sh
zig build                          # -> zig-out/bin/headterm
zig build test                     # unit tests + end-to-end tests (CLI and MCP)
zig build unit                     # unit tests only
zig build -Doptimize=ReleaseSafe   # optimized build
```

## Example

```sh
$ headterm start ed --cols 60 --rows 10 -- vi notes.txt
started ed pid=18964
$ headterm wait ed --idle 500
line one
line two
line three
~
~
~
~
~
~
"notes.txt" 3L, 29B
[headterm] ed 60x10 cursor=0,0 alt running wait=ok(idle) waited=531ms
$ headterm send ed j A ' (edited)' '<Esc>' ':w' '<Enter>'
$ headterm wait ed --idle 400 --diff
1|line two (edited)
9|"notes.txt" 3L, 38B written
[headterm] ed 60x10 cursor=1,16 alt changed=2 running wait=ok(idle) waited=402ms
$ headterm send ed ':q' '<Enter>'
$ headterm wait ed --exit
$ headterm kill ed
```

## Commands

| Command | Description |
| --- | --- |
| `headterm start <name> [--cols 120] [--rows 40] [--cwd DIR] [--log FILE] -- <cmd> [args...]` | Starts a session server that owns the PTY. Returns once the program has been exec'd; exec and chdir failures are reported here. `--log` appends the raw PTY output to FILE. |
| `headterm screen <name> [--json] [--diff] [--scrollback N]` | Prints the visible screen. |
| `headterm send <name> [--literal] [--paste] [--esc-delay MS] <arg>...` | Sends keys and text. |
| `headterm wait <name> (--text STR \| --idle MS \| --exit) [--timeout MS] [--json] [--diff] [--scrollback N]` | Blocks until a condition holds, then prints the screen. |
| `headterm resize <name> <cols> <rows>` | Resizes the PTY and the screen and sends SIGWINCH. |
| `headterm kill <name>` | Sends SIGHUP, then SIGTERM, then SIGKILL (500 ms apart) to the program's process group and stops the session server. |
| `headterm list [--json]` | Lists sessions. Removes sockets left behind by crashed servers. |
| `headterm mcp` | Runs the MCP server on stdin/stdout (see [MCP server](#mcp-server)). |

Session names use letters, digits, `.`, `_` and `-` (max 64, no leading dot).

Exit codes: `0` success, `1` wait condition not met (timeout), `2` error
(message on stderr).

### Sessions

Each session is a background server process listening on
`$XDG_RUNTIME_DIR/headterm/<name>.sock`, or `$TMPDIR/headterm-$UID/<name>.sock`
when `XDG_RUNTIME_DIR` is unset (`TMPDIR` defaults to `/tmp`). The directory
is created with mode 0700, and headterm refuses to use one owned by another
user.

The session server keeps running after the program exits, so the final screen
and exit status stay readable. `kill` ends it.

The program gets `TERM=xterm-256color` and the caller's environment, minus
`COLUMNS` and `LINES`.

### send

Each argument is either literal text or a key in angle brackets. Key names are
case-insensitive:

`<Enter>` `<Tab>` `<Esc>` `<Backspace>` `<Space>` `<Up>` `<Down>` `<Left>`
`<Right>` `<Home>` `<End>` `<PageUp>` `<PageDown>` `<Insert>` `<Delete>`
`<F1>`..`<F12>` `<lt>` (a literal `<`)

Modifiers: `<C-x>` Ctrl, `<M-x>` or `<A-x>` Meta/Alt (ESC prefix), `<S-x>`
Shift. They combine (`<M-C-x>`) and apply to named keys as well (`<C-Left>`
sends `ESC[1;5D`, `<S-Tab>` sends `ESC[Z`).

- Arrow keys, Home and End follow the program's cursor-key mode (DECCKM):
  `ESC[A` normally, `ESC O A` in application mode.
- An unknown `<Name>` is an error and nothing is sent. Use `--literal` to send
  the following arguments as text, unparsed.
- `--paste` sends the following arguments as text, wrapped in bracketed-paste
  markers when the program has enabled bracketed paste (mode 2004).
- A standalone `<Esc>` followed by more input is sent, then headterm pauses
  100 ms (`--esc-delay MS`, 0 to disable) before sending the rest. Without the
  pause, many programs (busybox vi, readline) read `ESC :` as an Alt chord.
  vim's own Esc timeout can still exceed that, so wait for `--idle` before
  relying on the mode change.

`send` returns once the bytes are queued for the program. Use `wait` to see
the effect.

### wait

- `--text STR`: STR appears on any visible row. Rows are matched with trailing
  blanks kept, so `--text '>>> '` matches a Python prompt. The current screen
  counts, so text that is already shown satisfies the wait at once.
- `--idle MS`: no output for MS milliseconds, counted from when the wait began
  or from the last output, whichever is later.
- `--exit`: the program has exited.
- `--timeout MS`: default 10000.

When several conditions are given, the first one met ends the wait. A `--text`
wait on a program that has already exited fails at once (reason `exited`)
rather than running out the timeout.

If the session is killed during a wait, the waiting client gets the final
screen with reason `killed` and exits with code 1.

### Diffs

`--diff` prints only rows that differ from the screen headterm last returned
for this session, from either `screen` or `wait`. There is one marker per
session, shared by all clients. After a resize, every row counts as changed.

## Output

### Text

One line per screen row with trailing spaces removed, then a status line:

```
[headterm] <name> <cols>x<rows> cursor=<row>,<col> [alt] [title="..."] [changed=N] <state> [wait=ok(<reason>)|wait=failed(<reason>) waited=<ms>ms]
```

`<state>` is `running`, `exited=<code>` or `killed-by-signal=<n>`. Rows and
columns are 0-based. With `--diff`, each changed row is printed as
`<row>|<text>`. With `--scrollback N`, up to N scrollback lines (oldest first)
come first, followed by `[headterm] end of scrollback (<n> lines)`.

### JSON (`screen --json`, `wait --json`)

One object followed by a newline. Fields appear in this order; fields marked
"only" are absent otherwise.

```json
{
  "name": "ed",
  "cols": 60,
  "rows": 10,
  "cursor": {"row": 1, "col": 16, "visible": true},
  "alt_screen": true,
  "title": "",
  "app_cursor_keys": true,
  "bracketed_paste": true,
  "pid": 18964,
  "exited": false,
  "exit_code": null,
  "exit_signal": null,
  "lines": ["line one", "line two (edited)", "..."],
  "changed": [{"row": 1, "text": "line two (edited)"}],
  "scrollback": ["older line", "..."],
  "wait": {"condition": "idle", "satisfied": true, "reason": "idle", "elapsed_ms": 402}
}
```

| Field | Meaning |
| --- | --- |
| `cursor.row`, `cursor.col` | 0-based cursor position. `visible` is the DECTCEM state. |
| `alt_screen` | The program is on the alternate screen (full-screen mode). |
| `title` | Last title set with OSC 0 or OSC 2. |
| `app_cursor_keys` | DECCKM is on. |
| `bracketed_paste` | Mode 2004 is on. |
| `pid` | The program's pid. |
| `exited`, `exit_code`, `exit_signal` | `exit_code` is set after a normal exit, `exit_signal` if a signal killed the program. Both are `null` while it runs. |
| `lines` | Every row, trailing spaces trimmed. Absent with `--diff`. |
| `changed` | Only with `--diff`: rows that changed, with their 0-based row number. |
| `scrollback` | Only with `--scrollback N` (N > 0): up to N lines, oldest first. |
| `wait` | Only from `wait`. `condition` is the first condition given (`text`, `idle` or `exit`). `reason` is `text`, `idle` or `exit` when `satisfied` is true, and `timeout`, `exited` or `killed` when it is false. |

### JSON (`list --json`)

An array with one object per session:

```json
[{"name":"ed","command":["vi","notes.txt"],"cols":60,"rows":10,"title":"","alt_screen":true,
  "pid":18964,"exited":false,"exit_code":null,"exit_signal":null,
  "server_pid":18963,"started_at_ms":1794304777917}]
```

## MCP server

`headterm mcp` runs an MCP server over stdio. It reads newline-delimited
JSON-RPC 2.0 on stdin and writes one reply per line on stdout; nothing else
goes to stdout. It supports protocol versions 2024-11-05, 2025-03-26,
2025-06-18 and 2025-11-25, and offers tools only.

To register it with Claude Code, build it and run:

```sh
claude mcp add headterm -- /absolute/path/to/headterm mcp
```

Add `--scope user` after `add` to make it available in every project. Use the
absolute path of your `headterm` binary.

Sessions started through MCP are ordinary sessions: `headterm list`,
`headterm screen` and the other CLI commands work on them too, and they keep
running after the MCP server exits until they are killed.

| Tool | Arguments | Returns |
| --- | --- | --- |
| `headterm_start` | `name`, `command` (string array), `cols?`, `rows?`, `cwd?`, `then_wait?` | `started <name> pid=N` and the first screen, once output has been idle for 300 ms (at most 5 s) or `then_wait` is met |
| `headterm_send` | `name`, `keys` (string array, same syntax as `headterm send`), `then_wait?` | the screen after the wait, or `sent` without `then_wait` |
| `headterm_screen` | `name`, `diff?`, `scrollback?` | the screen |
| `headterm_wait` | `name`, `text?`, `idle_ms?`, `exit?`, `timeout_ms?` | the screen |
| `headterm_resize` | `name`, `cols`, `rows` | confirmation |
| `headterm_kill` | `name` | confirmation |
| `headterm_list` | none | one line per session |

`then_wait` takes the same fields as `headterm_wait` (`text`, `idle_ms`,
`exit`, `timeout_ms`); an empty object means `{"idle_ms": 300}`. Use
`headterm_send` with `then_wait` to act and see the result in one call.
`idle_ms` and `timeout_ms` are capped at 60000.

Screens use the CLI text format: rows, then the `[headterm] ...` status line.
Empty rows between the last non-empty row and the status line are left out;
the status line still gives the full size.

Errors:

- Tool failures are results with `isError: true`: an unknown session, a
  rejected key, a failed start, or a wait that times out or can no longer be
  met. A wait failure still returns the screen.
- JSON-RPC errors: `-32700` for malformed JSON, `-32600` for a request that
  isn't a JSON object or has no method, `-32601` for an unknown method, and
  `-32602` for an unknown tool or bad arguments (missing or wrongly typed
  field, value out of range).

## Terminal emulation

headterm has its own VT parser and screen model (`src/vt.zig`), built as
Paul Williams' DEC parser state machine with UTF-8 decoding in the ground
state. Unknown or unsupported sequences are consumed and never printed.

Supported:

- UTF-8, with East Asian wide characters and emoji as width 2 (table-based)
  and invalid input shown as U+FFFD. Combining marks are dropped.
- Autowrap with the pending-wrap state, tab stops (HT, HTS, TBC, CHT, CBT),
  and DEC Special Graphics line drawing (`ESC ( 0`, SO/SI).
- Cursor movement: CUU CUD CUF CUB CNL CPL CHA HPA HPR VPA VPR CUP HVP, IND RI
  NEL, DECSC/DECRC, CSI s/u, origin mode (DECOM).
- Editing: ED (0-3), EL, ECH, ICH, DCH, IL, DL, SU, SD, REP, insert mode
  (IRM), DECALN.
- Scroll regions (DECSTBM) and alternate screen modes 47, 1047 and 1049, with
  a separate saved cursor per screen and mode 1048.
- 2000 lines of scrollback for the main screen.
- Modes: DECCKM, DECKPAM/DECKPNM, DECAWM, DECTCEM, bracketed paste (2004).
  Focus (1004) and mouse modes (9, 1000, 1002, 1003, 1006) are tracked, but
  headterm sends no mouse or focus events.
- SGR is parsed completely, including `38;5;n`, `38;2;r;g;b` and the colon
  forms. Styles are not stored per cell yet.
- Replies to the program: CPR (`CSI 6 n`, `CSI ? 6 n`), DSR (`CSI 5 n`), DA1
  (`ESC[?62;22c`), DA2, XTVERSION, DECRQM, the text-area size query
  (`CSI 18 t`) and OSC 10/11 color queries.
- OSC 0 and OSC 2 set the window title. DCS, SOS, PM, APC and other OSC
  strings are ignored.
- Resize keeps the screen contents without reflowing. If the cursor would end
  up below the new bottom edge, the top lines move into scrollback.

## Layout

| File | Contents |
| --- | --- |
| `src/main.zig` | CLI |
| `src/vt.zig` | Parser and screen model: no I/O, unit-tested |
| `src/keys.zig` | Key names to bytes |
| `src/pty.zig` | PTY allocation and child spawn |
| `src/server.zig` | Session server: event loop, requests, rendering |
| `src/client.zig` | Session paths, start, list and socket client |
| `src/mcp.zig` | MCP server (JSON-RPC over stdio) |
| `scripts/smoke.sh` | End-to-end test of the CLI, run by `zig build test` |
| `scripts/mcp_smoke.sh` | End-to-end test of `headterm mcp`, run by `zig build test` |

Wire protocol: the client sends `<len>\n`, then `<len>` bytes of NUL-terminated
arguments, and keeps the connection open. The server answers with
`ok|timeout|error`, `\n` and the body, then closes the connection.

## Limitations

- No styling in the output (colors, bold and so on) and no mouse input.
- No reflow on resize.
- Combining characters are dropped, and character widths come from a built-in
  table that can disagree with the program's `wcwidth`.
- One diff marker per session, shared by all clients.

## License

MIT
