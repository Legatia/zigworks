# headdesk

A headless desktop for AI agents on Linux. headdesk is its own Wayland
display server: graphical apps run inside it with no monitor and no GPU, and
an agent lists their windows, takes pictures of them, clicks, types, waits
until they have stopped drawing, and can freeze them and let single frames
through. "headterm, but for graphical apps."

One static binary of about 300 KB, pure Zig, no C libraries: it speaks the
Wayland wire protocol itself. Linux only (x86_64, arm64). On Windows it runs
inside WSL2, on macOS inside a Linux VM or container; it does not control the
host's own apps.

**State: 0.1.0, an experiment. Tested only against the small test client
that ships with it (`headdesk-testclient`), by the tests in this folder. No
real app (GTK, Qt, Firefox, Chromium) has been run on it yet**, so which of
them work is not known. See [Limits](#limits).

## Using it from an agent

Put headdesk on PATH and add one line to the agent's instructions (for Claude Code, `CLAUDE.md`):

```
For graphical Linux apps use the headdesk CLI: `headdesk start NAME -- CMD` makes a private desktop with the app in it, then `headdesk wait NAME`, `headdesk windows NAME`, `headdesk shot NAME FILE.png [--window N]`, `headdesk click NAME X Y [--window N]`, `headdesk key NAME ctrl+s`, `headdesk type NAME TEXT`, and `headdesk kill NAME` at the end; `headdesk help` has the rest.
```

## Quick start

Real output, with the test client as the app (a blue window with a red
button; a click on the button opens a green menu):

```
$ headdesk start demo --size 640x400 -- headdesk-testclient "first window"
started demo pid=399 size=640x400

$ headdesk wait demo --windows 1
settled after=323ms windows=1 changed=0,0,640x400

$ headdesk windows demo
window 1 toplevel at=0,0 size=640x400 keyboard app=headdesk.testclient title="first window"

$ headdesk click demo 50 40
at=50,40 window=1

$ headdesk wait demo --windows 2
settled after=302ms windows=2 changed=20,60,120x80

$ headdesk windows demo
window 1 toplevel at=0,0 size=640x400 app=headdesk.testclient title="first window"
window 2 popup at=20,60 size=120x80 parent=1 keyboard

$ headdesk shot demo menu.png --window 2
shot file=/home/me/menu.png size=120x80 bytes=517

$ headdesk click demo 40 40 --window 2
at=60,100 window=2

$ headdesk wait demo
settled after=303ms windows=1 changed=20,20,120x120

$ headdesk key demo ctrl+s Return
$ headdesk type demo 'Hi!'
$ headdesk kill demo
```

`wait` answers when nothing has been drawn for a while and says which part
of the desktop is different from the last time it answered: after the click
on the button, exactly the menu's rectangle.

## Commands

`NAME` is the desktop's name. Every answer is a line of `key=value` words
(or a list of lines) and an exit code: 0 done, 1 not reached (a wait timed
out), 2 a wrong command, 4 no such desktop.

| Command | |
|---|---|
| `start NAME [--size WxH] [--cwd DIR] -- CMD...` | A new desktop (default 1280x800) with `CMD` in it. Returns once the desktop answers; it keeps running in the background. |
| `exec NAME -- CMD...` | One more program on that desktop. |
| `list` | The desktops that are running. |
| `status NAME` | Size, number of windows and apps, each app's pid or exit code, and every request an app made that this server does not know (`unknown ...`). |
| `kill NAME` | Ends the apps (SIGTERM, then SIGKILL after half a second) and the desktop. |
| `windows NAME` | Every window, menu and popup: number, kind, place, size, parent, which one has the keyboard, title. |
| `shot NAME FILE.png [--window N]` | The whole desktop as a PNG, or window `N` alone at full size, whatever covers it. |
| `wait NAME [--idle MS] [--timeout MS] [--windows N]` | Until nothing has been drawn for `--idle` (300 ms) and at least `N` windows are open. Says how long it took and the area that changed since the last wait that settled (`changed=X,Y,WxH` or `changed=none`). After `--timeout` (10 s): `timeout`, exit 1. |
| `click NAME X Y [--window N] [--button left\|right\|middle] [--double]` | Moves the pointer there and clicks. `X Y` are desktop pixels from the top left, or with `--window` pixels of that window. |
| `move NAME X Y [--window N]` | Moves the pointer only. |
| `scroll NAME STEPS` | Wheel notches down (negative: up) where the pointer is. |
| `key NAME KEY...` | Keys with their modifiers, each pressed and let go: `Return`, `Tab`, `Escape`, `F5`, `a`, `ctrl+s`, `ctrl+shift+t`, `alt+F4`. |
| `type NAME TEXT` | ASCII text, key by key, on a US layout. |
| `focus NAME N` | Brings window `N` to the front and gives it the keyboard. |
| `close NAME N` | Asks window `N` to close, as its close button would. |
| `freeze NAME` | Apps are no longer told to draw (they get no frame callbacks). |
| `step NAME [N]` | While frozen: lets `N` frames (1) through. |
| `thaw NAME` | Back to normal. |
| `log NAME [--since N]` | One numbered record of every input and every drawing, in order, with the area each drawing changed. |
| `output NAME` | What the apps printed (stdout and stderr). |

## How it works

- **One process per desktop.** `start` forks a process that listens on a
  Wayland socket and a control socket in its own directory
  (`$XDG_RUNTIME_DIR/headdesk/NAME`, else `$TMPDIR/headdesk-UID/NAME`;
  `HEADDESK_DIR` overrides the base). Apps are started with
  `XDG_RUNTIME_DIR` set to that directory and `WAYLAND_DISPLAY=wayland-0`,
  so nothing of theirs meets another desktop. `GDK_BACKEND`,
  `QT_QPA_PLATFORM` and `MOZ_ENABLE_WAYLAND` are set to Wayland unless the
  caller set them; `DISPLAY` is removed.
- **The protocol by hand.** No libwayland, no wlroots: messages are parsed
  and built in `src/wire.zig`. Offered to apps: `wl_compositor`,
  `wl_subcompositor`, `wl_shm`, `wl_seat` (pointer and keyboard),
  `wl_output`, `wl_data_device_manager`, `xdg_wm_base` (windows, and popups
  with grabs) and `wp_viewporter`.
- **Shared memory only.** Apps hand over pictures in shared memory
  (`wl_shm`); there are no GPU buffers. On every commit the picture is copied
  and compared with the one before, which is where `changed=` comes from:
  what really differs, not what the app said it damaged.
- **Windows.** A window without a parent fills the desktop (it is told it is
  maximized); a window with a parent (a dialog) keeps its own size and is
  centred. Popups go where their positioner says, slid onto the desktop.
- **Input** goes straight into the protocol: there is no input device and no
  permission prompt. The keyboard is one fixed US layout that apps get as
  XKB text.
- **Freezing.** An app draws when the server tells it a frame is due.
  `freeze` stops telling; `step` tells once.

## Limits

- **No real app has been run yet.** The starting set of interfaces is a
  guess at what GTK 4, Qt 6, Firefox and Chromium need; `status` lists what
  an app asked for and did not get.
- **"Settled" is not "done".** An app that waits for the network looks idle;
  an app with a blinking caret or a spinner never settles (use `--timeout`,
  or `freeze`).
- **No GPU buffers** (`linux-dmabuf`): an app that can't draw into shared
  memory shows nothing.
- **Text** is ASCII on a US layout, typed as keys. No input method, no
  clipboard, no drag and drop; the data-device interface is there but empty.
- **No accessibility tree**: windows are known by rectangle and title, their
  contents only as pixels.
- **No X11 apps** (no Xwayland), no touch, no cursor in pictures, one output
  at scale 1, no window decorations drawn by the server.
- **No sandbox.** Apps run as the calling user with its files; the desktop
  only gives them their own display.
- Subsurfaces apply on every commit (no synchronized mode) and are stacked
  in the order they were made.

## Building

Zig 0.17.1, on Linux:

```sh
zig build -Doptimize=ReleaseSafe      # zig-out/bin/headdesk and headdesk-testclient
zig build test                        # unit tests, then scripts/smoke.sh with the test client
```

## Layout

| File | |
|---|---|
| `src/main.zig` | The command line; `start` forks the desktop |
| `src/desk.zig` | One desktop: sockets, the loop, the commands, starting apps |
| `src/server.zig` | The display server: clients, surfaces, windows, the picture, input |
| `src/wire.zig` | The Wayland wire format |
| `src/keymap.zig` | The keyboard layout: key table and XKB text |
| `src/png.zig` | PNG files |
| `src/sys.zig` | Linux system calls |
| `src/testclient.zig` | The test client: a window, a button, a menu |
| `scripts/smoke.sh` | The end-to-end test, run by `zig build test` |
| `HANDOFF.md`, `research/` | Where the project came from |

## License

MIT
