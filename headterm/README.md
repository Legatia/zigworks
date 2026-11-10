# headterm

A headless terminal for AI agents, as a CLI and an MCP server. headterm runs a
program in a pseudo-terminal, keeps an emulated screen, and lets an agent read
the screen as text, see which rows changed, send keys and mouse events, and
wait for text or for output to go quiet. It drives full-screen programs (vim,
less, top, curses UIs, REPLs, `git add -p`) without tmux scripting.

Use it only for programs that need a real terminal: TUI menus, passphrase
prompts read from the TTY, editors, interactive REPLs and debuggers. Anything
that takes stdin or flags is simpler in a plain shell.

Zig standard library and libc only. macOS and Linux.

## Using it from an agent

Put headterm on PATH and add one line to the agent's instructions (for Claude Code, `CLAUDE.md`):

```
For programs that need a real terminal (TUI menus, wizards, passphrase prompts read from the TTY, full-screen apps), use the headterm CLI: `headterm run --send KEYS... --wait-text TEXT --screen -- CMD` plays keys and waits and prints the screen in one call; `headterm help run` has the details.
```

In tests with Claude Code (Sonnet, 3 runs per task), that beat an agent with only a shell on every task:

| task | shell only | headterm CLI |
|---|---|---|
| curses menu | 15.2 s, $0.049 | 9.7 s, $0.024 |
| passphrase read from the TTY | failed 3/3 | 7.4 s, $0.014 |
| four-screen setup wizard | 90.7 s, $0.120 | 12.3 s, $0.038 |
| find a value in a full-screen dashboard | 42.1 s, $0.118 | 11.9 s, $0.025 |

The shell-only agent writes its own pty scripts for menus and wizards, and declines to bypass a TTY check. The MCP server (below) also solved every task, but costs more: clients load MCP tools on demand, and agents drive it one key at a time.

Wizards built with the common Node prompt libraries are harder: the agent can't know the screens in advance, and checkbox lists show what is selected only by color. Same setup, 4 runs per task, median time, every run correct:

| setup wizard built with | headterm 0.2.0 | headterm 0.3.0 |
|---|---|---|
| enquirer | 60.0 s, wizard started 3–9 times | 25.0 s, started 1–2 times |
| @clack/prompts | 39.6 s, started 4–5 times | 18.6 s, started 1–2 times |
| prompts | 45.1 s, started 2–5 times | 17.6 s, started 1–2 times |

The difference comes from keeping the session between calls (`run --name N --keep`, then `run --session N`), a note under the screen that says which marks differ in color, and a wait for exit that stops after 2 s when the program is reading keys.

## Quick start

One command for a whole interaction:

```
$ headterm run --cols 60 --rows 10 --send '<Down>' --send '<Enter>' --wait-exit -- python3 configure.py
started run-11537 pid=11541
1 send ok
2 wait ok(exit) 6ms
final screen:
saved cache = S3 bucket
[headterm] run-11537 60x10 cursor=1,0 exited=0
session ended
```

Or step by step:

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

Most interactions take one `headterm_run` call. Choosing an entry in a curses
menu (real output):

```
→ {"name":"headterm_run","arguments":{"command":["python3","configure.py"],"cols":60,"rows":8,
   "steps":[{"wait":{"text":"Where should"}},{"send":["<Down>"]},{"screen":true},{"send":["<Enter>"]},{"wait":{"exit":true}}]}}
← started run-15942-48800 pid=15947
  1 wait ok(text) 32ms
  2 send ok
  3 screen:
  Where should the build cache live?

     local disk
     S3 bucket
     disabled

  Up/Down to move, Enter to choose
  [headterm] highlighted: row 3 "S3 bucket"
  [headterm] run-15942-48800 60x8 cursor=6,32 alt running
  4 send ok
  5 wait ok(exit) 4ms
  final screen:
  saved cache = S3 bucket
  [headterm] run-15942-48800 60x8 cursor=1,0 exited=0
  session ended
```

The other tools are for step-by-step use: `headterm_start`, then
`headterm_send` with `then_wait`, `headterm_screen`, `headterm_kill`.

| Tool | Arguments | Returns |
| --- | --- | --- |
| `headterm_run` | `command` or `session`, `steps`, `keep?`, `name?`, `cwd?`, `cols?`, `rows?`, `ttl_s?`, `record?`, `styles?` | each step's result and the final screen (see [run](#run)) |
| `headterm_start` | `name`, `command`, `cols?`, `rows?`, `cwd?`, `ttl_s?`, `record?` | `started <name> pid=N` and the first screen |
| `headterm_send` | `name`, `keys`, `literal?`, `paste?`, `esc_delay_ms?`, `then_wait?`, `styles?` | the screen after `then_wait`, or `sent` |
| `headterm_screen` | `name`, `diff?`, `scrollback?`, `styles?` | the screen |
| `headterm_wait` | `name`, `text?`, `regex?`, `gone?`, `idle_ms?`, `exit?`, `timeout_ms?`, `styles?` | the screen |
| `headterm_resize` | `name`, `cols`, `rows` | confirmation |
| `headterm_kill` | `name` | confirmation |
| `headterm_list` | none | one line per session |

- `headterm_start` returns once the program's first output has been quiet for
  300 ms (at most 2 s), or when `then_wait` is met (still accepted, no longer
  listed).
- `then_wait` has the fields of `headterm_wait`; `{}` means `{"idle_ms":300}`.
  `idle_ms` and `timeout_ms` are capped at 60000.
- `keys` elements are always keys or text, never options; `literal`, `paste`
  and `esc_delay_ms` are separate arguments.
- MCP sessions end after an hour without calls or output (`ttl_s`, 0 =
  never); `headterm_run` sessions after 10 minutes unless `keep` is set. They
  are ordinary sessions, so the CLI works on them too.
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
- tools/list is 4.7 KB. The tool descriptions are kept short because agents
  load them into context.

## Commands

| Command | Description |
| --- | --- |
| `run <steps> -- <cmd> [args...]`, `run --session NAME <steps>` | Starts `cmd` (or uses a session), plays the steps, prints each result and the final screen, ends the session (a `--session` one only when its program has exited). See [run](#run). |
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

### run

`run` does a whole interaction in one command or tool call. Steps, in
order:

| CLI | JSON (`--steps`, `headterm_run`) | Does |
| --- | --- | --- |
| `--send KEY` (repeatable) | `{"send":["<Down>","<Enter>"]}` | send keys, as in [send](#send) |
| `--send-text TEXT` | `{"send":["a<b>"],"literal":true}` | send plain text |
| `--wait-text S`, `--wait-regex R`, `--wait-gone S`, `--wait-idle MS`, `--wait-exit`, then `--timeout MS` | `{"wait":{"text":"S","timeout_ms":5000}}` | wait as in [wait](#wait) |
| `--screen` | `{"screen":true}` | include the screen at this point |

- **Output:** one line per step (`2 wait ok(text) 32ms`), the screens asked
  for, then the final screen with the exit status. `--styles` adds styled
  runs.
- **Timing:** keys are held until the program's first output has settled,
  unless a wait comes first. A screen taken right after a send waits for the
  program to react to the keys, then until its output has been quiet for
  200 ms, so `--send Down Enter --screen` needs no wait step in between.
- **Success:** the session ends (`--keep` keeps it). Exit code 0.
- **Step by step:** start with `--name NAME --keep`, then play more steps
  with `run --session NAME`. Steps played with `--session` leave the session
  running, and end it once its program has exited. `headterm kill NAME` ends
  it sooner; a kept session also ends after an hour without use (`--ttl S`,
  0 = never).
- **A failed step** (a wait that times out) stops the run. The result then
  holds the screen at that point and `stopped at step N of M`, and the session
  is kept for 10 minutes. Continue it with `run --session NAME` (MCP:
  `session`) or with `send` and `screen`. If the program has already exited,
  the session ends instead. Exit code 1; MCP: `isError`.
- **Options:** `--name`, `--cwd`, `--cols`, `--rows`, `--ttl`, `--record`.

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
  never expires. `start` has no TTL by default; `run --keep` and MCP
  sessions default to 3600.
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

The brackets can be left out when the argument is exactly a key name:
`send s Down Down Enter`, `send s C-c`. Names in another case (`down`,
`enter`) are keys too, unless the same `send` has a key spelled as above:
`send s billing enter` presses Enter, while `send s up Enter` types `up` (a
debugger command) and presses Enter. When that happens the reply says
`sent as keys: Enter`. `--literal` always types the words.

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
- Keys sent within 5 s of start, before the program has printed anything, are
  held until its first output has been quiet for 150 ms (at most 2 s). Some
  programs drop typeahead that arrives before they are ready.
- `send` returns once the input is queued; `wait` shows the effect.

### wait

| Condition | Met when |
| --- | --- |
| `--text STR` | STR is on screen (trailing blanks count, so `'>>> '` matches a prompt) |
| `--regex RE` | a screen line, trailing spaces removed, matches RE |
| `--text-gone STR` | STR is not on screen (spinners, "Loading…") |
| `--idle MS` | the screen has not changed for MS, counted from the later of the wait's start and the last change. Output that leaves the screen as it was doesn't count, nor does a cursor that the program draws and blinks itself (Bubble Tea forms): a change of colors alone that puts back the screen before the last one |
| `--settle MS` | the program has printed something, then nothing for MS. After a send, only output since the send counts; a program that prints nothing within 500 ms is taken as settled |
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
- A wait for `--exit` alone fails after 2 s, not at the timeout, when the
  program is probably waiting for input (reason `awaiting-input`): it printed
  something, then the screen stayed as it was for 2 s, and the terminal is in raw mode or has echo
  off, as menus, wizards and password prompts set it. The screen says so.
  This happens once per send, so a program that was working after all can be
  waited for again. A plain line prompt (`read`, `input()`) can't be told
  apart from a quiet program and runs into the timeout.

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
- **Highlighted rows:** without `--styles`, rows with highlighted text are
  named in one line before the status line, at most three:
  `[headterm] highlighted: row 3 "S3 bucket"`. Highlighted means a background
  that differs from the screen's most common one: inverse, or a colored bar.
  A program that paints the whole screen in one color doesn't count. This
  usually finds the selected menu item at no extra cost.
- **Style-only lists:** some checkbox lists show state by style alone
  (enquirer prints `✔` on every row, green when selected; clack and prompts
  mark the focused row by underline or by not dimming it). Without `--styles`
  two more lines say so:
  `[headterm] "✔" differs in style: rows 3,4 dim fg=bright-black ("ESLint", "Vitest"); row 5 fg=green ("Prettier")`
  for consecutive rows with the same mark in two or three styles (the labels
  are named for lists of up to 10 rows), and
  `[headterm] styled unlike the rows around it: row 4 "ESLint" (underline fg=cyan; others plain)`
  for one or two rows of a list of three or more whose label has a style of
  its own. The second is written only while the program hides the cursor,
  which is when it draws its own focus.

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
| `wait` | Only from `wait`. `condition`: the first given, in the order text, regex, gone, idle, exit. `reason`: the condition met, or `timeout`, `awaiting-input`, `exited`, `killed`. |

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
