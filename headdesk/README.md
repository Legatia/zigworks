# headdesk

A headless desktop for AI agents on Linux. headdesk is its own Wayland
display server: graphical apps run inside it with no monitor and no GPU, and
an agent lists their windows, takes pictures of them, clicks, types, waits
until they have stopped drawing, and can freeze them and let single frames
through. "headterm, but for graphical apps." With `--sandbox` the apps run in
a box: they read the system but write only into the box, their home is
empty, and what they changed can be listed, kept as a snapshot or thrown away.

One static binary of about 300 KB, pure Zig, no C libraries: it speaks the
Wayland wire protocol itself. Linux only (x86_64, arm64). On Windows it runs
inside WSL2, on macOS inside a Linux VM or container; it does not control the
host's own apps.

**State: 0.1.0, an experiment.** The tests in this folder use a small test
client that ships with it (`headdesk-testclient`). Real apps have each been
started by hand, see [Apps tried](#apps-tried): GTK 4, Qt 6, Chrome and
Firefox drew correctly and opened a menu. See [Limits](#limits).

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
| `start NAME [--size WxH] [--cwd DIR] [--sandbox ...] -- CMD...` | A new desktop (default 1280x800) with `CMD` in it. Returns once the desktop answers; it keeps running in the background. With `--sandbox` the apps run in a [box](#boxes). |
| `exec NAME -- CMD...` | One more program on that desktop. |
| `list` | The desktops that are running. |
| `status NAME` | Size, number of windows and apps, each app's pid or exit code, the box if there is one, and every request an app made that this server does not know (`unknown ...`). |
| `kill NAME` | Ends the apps (SIGTERM, then SIGKILL after half a second) and the desktop; returns when the desktop is gone. |
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
| `record NAME DIR [--fps N]` | From now on, keeps a [recording](#recordings) in `DIR`: the log, every input, and a picture whenever the desktop changed (at most `N` a second, default 10). |
| `record NAME --stop` | Ends the recording and writes its page. `kill` ends it too. |
| `replay NAME DIR [--settle] [--speed X]` | Sends a recording's inputs to this desktop again, at the recorded times (`X` times as fast), or with `--settle` each one once the desktop has been quiet for 200 ms. Then says whether the desktop ends up looking the same: `picture=same`, or `picture=differs` and exit 1. |
| `box list` | The boxes: name, number of snapshots, open or closed. |
| `box diff BOX` | What was `added`, `changed` or `deleted` in the box since its last snapshot, as paths the apps saw. |
| `box snapshot BOX LABEL` | Keeps the box as it is now under `LABEL`; the box goes on from there. |
| `box snapshots BOX` | Its snapshots, oldest first. |
| `box restore BOX LABEL` | Back to that snapshot: what was written after it, and later snapshots, are gone. |
| `box reset BOX`, `box delete BOX` | Empties the box, snapshots included; removes it. |
| `check` | Whether this system lets you make boxes, and if not, why. |

## Boxes

```
$ headdesk start work --sandbox --share ~/project -- some-app
started work pid=439 size=1280x800 box=work
```

Options that go with `--sandbox`: `--box BOX` (which box; default the
desktop's name), `--share DIR` and `--share-ro DIR` (a directory of yours the
apps may use, or only read; shown at the same path), `--no-network`, and
`--as-root` (the apps are root inside the box, so that they can write
anywhere in it).

What an app in a box sees:

- **The system, to read.** `/usr`, `/etc`, `/var`, `/opt` and the rest of the
  root file system are there. Anything written, changed or deleted goes into
  the box's directory and nowhere else.
- **An empty home** of its own, kept in the box. Nothing of `/home`, `/root`,
  `/mnt` or `/media` is there, except what `--share` names.
- **Fresh `/tmp`, `/run` and `/dev`** (null, zero, full, random, urandom, tty,
  terminals of its own), its own `/proc` with only its own processes, and its
  own host name.
- **The network** as the host has it, or with `--no-network` only a loopback
  that is down.
- **The desktop's Wayland socket**, and not the desktop's control socket: an
  app can't drive its own desktop.

`exec` starts further programs in the same box while its first program
lives. When that ends, everything left in the box is ended with it.

A box outlives its desktop: start another desktop with the same `--box` and
the apps find what they left. Real output, after an app had written four
things:

```
$ headdesk box diff b1
added   /usr/hello-from-box
added   /root/note.txt
deleted /etc/hostname
changed /etc/issue
4 changed in box b1

$ headdesk box snapshot b1 clean
$ headdesk box restore b1 clean      # later: everything since is gone
```

`snapshot`, `restore`, `reset` and `delete` need the box closed (no desktop
using it). A snapshot costs nothing: what was written so far is set aside as
a layer and the box goes on writing above it.

Boxes are kept in `$HEADDESK_BOXES`, else `$XDG_DATA_HOME/headdesk/boxes`,
else `~/.local/share/headdesk/boxes`.

**How strong it is.** A box is made of Linux namespaces (user, mount, pid,
ipc, uts, and network with `--no-network`) with an overlay over each
top-level directory of the system, as containers and bubblewrap are made.
The apps have no privileges outside it and can't gain any (`no_new_privs`).
It is not a virtual machine: the kernel is shared, so a kernel bug can be a
way out, and nothing limits the CPU, memory or disk a box uses. With the
network on, an app can reach whatever the host can, including services on
localhost.

Tried on Ubuntu 24.04 in WSL2 (kernel 6.18), as root and as an ordinary
user: the tests, and by hand the GTK 4 demo and Chrome (which loaded a page
and left its 261 profile files in the box). Not tried: installing packages
inside a box, and other distributions.

## Recordings

```
$ headdesk record demo run1 --fps 20
recording dir=/home/me/run1 fps=20
  ... clicks, keys ...
$ headdesk record demo --stop
stopped pictures=5 inputs=4 dir=/home/me/run1
```

A recording is a directory:

| File | |
|---|---|
| `index.html` | A page with the pictures in order, a slider, and the log up to the picture shown, inputs in bold. Open it in a browser; it needs nothing else. |
| `frames/000001.png` ... | The desktop each time it looked different. |
| `frames.txt` | Per picture: number, milliseconds since the start, a hash of the pixels, and the area that changed (`20,60,120x80`). |
| `inputs.txt` | Per input: milliseconds, and the command as it was given. |
| `events.txt` | The log: inputs, windows opening and closing, every drawing. |
| `meta.txt` | The desktop's size and when the recording started. |

`replay` sends the inputs to a desktop again and compares the hash of how
it looks at the end with the recording's last picture, so a recording made
once is a test that can be run again:

```
$ headdesk start demo2 --size 640x400 -- the-app
$ headdesk replay demo2 run1 --settle
replayed inputs=4 picture=same
```

The desktop must have the recording's size, and the app must be in the state
it was in when the recording began: inputs are positions and keys, not
names of buttons. A picture that differs in one pixel differs; an app that
shows the time, a caret that blinks or an animation will differ for no good
reason (`freeze` helps with the last two).

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
  permission prompt. A click goes to the topmost surface whose input region
  holds the point. The keyboard is one fixed US layout that apps get as
  XKB text.
- **Freezing.** An app draws when the server tells it a frame is due.
  `freeze` stops telling; `step` tells once.

## Apps tried

The experiment this version was built for: do real apps start, draw and open
a menu on a display server that offers shared-memory buffers only? Each app
below was started by hand on 19 November 2026 (Ubuntu 24.04 in WSL2,
x86_64, as root, each under `dbus-run-session`, desktop 1024x700), and its
pictures were looked at.

| App | Started with | Connects | Draws | Picture right | Menu after a click | Asked for something unknown |
|---|---|---|---|---|---|---|
| GTK 4.14, `gtk4-widget-factory` | `GSK_RENDERER=cairo` | yes | yes | yes | yes: a dropdown opened under its button, and a click on an entry chose it | no |
| Qt 6.4, Qt Linguist | | yes | yes | yes | yes: the File menu | no |
| Chrome 158 | `--ozone-platform=wayland --disable-gpu --no-sandbox --no-first-run` | yes | yes | yes | yes: the main menu; Escape closed it | no |
| Firefox 160.0.1 | `--no-remote --profile DIR` | yes | yes | yes | yes: the main menu, after the welcome screen's button | no |
| Qt 5.15, FeatherPad | | yes | yes | yes | not checked | no |

Firefox did not react to clicks at first: it draws into a child surface
whose input region is empty, so that clicks reach its window underneath, and
this server ignored input regions. It honours them now; GTK, Qt and Chrome
were run again afterwards and still opened their menus.

Also seen: an address typed into Chrome with `type` loaded, and text typed
into the page arrived whole, shifted characters included
(`~!@#$%^&*()_+{}|:"<>?`). The layout's XKB text compiles with
libxkbcommon's `xkbcli`. GTK's window asked for 1391x757 on the 1024x700
desktop and was cut off at the edges. The GTK demo (spinners) and FeatherPad
(a blinking caret) never settled, as the limits below say.

Not tried: GTK without `GSK_RENDERER=cairo`, Chromium itself (Chrome stood
in for it), Electron apps, any real app on arm64, and more than a start, a
click or two and some typing in each.

- **Boxes** are the namespaces above, set up by hand with system calls (no
  bubblewrap, no container runtime). A directory that has other file systems
  mounted inside it can't be overlaid in one piece (WSL mounts drivers under
  `/usr/lib`): it is taken apart, its directories overlaid one by one, and
  the files directly in it and the other file systems shown read-only.

## Limits

- **A box is not a virtual machine**, see [Boxes](#boxes). Systems that
  forbid unprivileged user namespaces can't make one (`headdesk check` says
  so; on Ubuntu 24.04 `sysctl kernel.apparmor_restrict_unprivileged_userns=0`
  allows it). With `--as-root` an ordinary user is root only over the box's
  own files: programs that switch to other users, as package managers do,
  may fail.

- **Few apps, each tried briefly.** The set of interfaces was a guess at what
  GTK 4, Qt 6, Firefox and Chromium need, and held for the five above;
  `status` lists what an app asked for and did not get.
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
- **Without `--sandbox`** apps run as the calling user with its files; the
  desktop only gives them their own display.
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
| `src/box.zig` | Boxes: namespaces and the file system view an app gets |
| `src/boxes.zig` | Boxes on disk: snapshots, restore, what changed |
| `src/record.zig` | Recordings: pictures, inputs, log, the page |
| `src/sys.zig` | Linux system calls |
| `src/testclient.zig` | The test client: a window, a button, a menu |
| `scripts/smoke.sh` | The end-to-end test, run by `zig build test` |
| `HANDOFF.md`, `research/` | Where the project came from |

## License

MIT
