# headsight

Sight for AI agents without a stream of screenshots. headsight waits until a
region of the screen, a window or the camera changes, goes still, or shows
some text, and then prints one line and the path of a small crop of just that
region. It also reads text on the device, and compares a region with a
reference taken earlier.

An agent that waits for something visual today takes screenshot after
screenshot and sends each one to the model: a 1600x900 image is about 1,900
input tokens, so polling every 10 s for 10 minutes is about 115k tokens and 60
model turns. With headsight it is one command that blocks, and the model does
nothing until there is something to look at.

macOS 14 or later on Apple Silicon. Zig standard library, libc and Apple's
frameworks (ScreenCaptureKit, AVFoundation, Vision, ImageIO); one binary.

## Using it from an agent

Put headsight on PATH and add one line to the agent's instructions (for Claude Code, `CLAUDE.md`):

```
To wait for something on screen or camera to change, settle, or show text, use the headsight CLI instead of repeated screenshots: `headsight wait --change|--still|--text TEXT [--window APP] [--region X,Y,W,H]` blocks and prints a crop path; `headsight help` has the details.
```

Measured results with Claude Code are pending (see Evaluation below).

## Quick start

Real output, against the test window in `scripts/fixture.swift`:

```
$ headsight wait --text "Export Done" --window "headsight fixture" --timeout 20
text after=2.4s found="Export Done: 42 files" box=130,197,770,82 crop=/var/folders/…/T/headsight/9e3a-1.png origin=114,181 scale=1

$ headsight wait --still --window "headsight fixture"
still after=2.1s crop=/var/folders/…/T/headsight/9e2e-1.png origin=0,0 scale=0.51

$ headsight snap --window "headsight fixture" --name before
snap source=window size=2000x1336 pixel_scale=2 region=0,0,2000,1336 crop=/var/folders/…/T/headsight/9e25-1.png origin=0,0 scale=0.51 ref=before
  (the page changes)
$ headsight diff --since before
diff since=before age=7s boxes=3
  box 368,192,544,96 crop=/var/folders/…/T/headsight/9e59-1.png origin=352,176 scale=1
  box 128,592,320,80 crop=/var/folders/…/T/headsight/9e59-2.png origin=112,576 scale=1
  box 464,384,208,80 crop=/var/folders/…/T/headsight/9e59-3.png origin=448,368 scale=1

$ headsight text --window "headsight fixture"
  "Export Done: 42 files" box=130,197,770,82
  "Counter: 7310" box=126,397,530,68
  "Plan: Pro" box=130,597,316,68
```

The crop is a PNG the agent opens with its own image tool. `origin` and `scale`
convert crop pixels back to source pixels: source = origin + crop / scale.

## Commands

| command | what it does |
|---|---|
| `snap [source] [--region R] [--name NAME]` | saves a crop; with `--name`, also keeps the region at full resolution as a reference |
| `wait --change\|--still[=MS]\|--text TEXT [source] [--region R] [--ignore R]... [--since NAME] [--timeout S]` | blocks until the region changes, stays unchanged for MS (default 800), or shows TEXT (case-insensitive; text already there counts) |
| `diff --since NAME` | every area that changed since the reference, with a crop of each (up to 8) |
| `drop NAME` | deletes a reference |
| `text [source] [--region R] [--accurate]` | the text lines in the region, with boxes |
| `windows` | windows that can be watched, front to back |

- Sources: the main display (default), `--window TEXT` (the frontmost window
  on the current desktop whose app name or title contains TEXT, including
  always-on-top windows; it is followed when it moves or is covered), `--source camera`, `--camera NAME`.
- Regions are `X,Y,W,H` in pixels of the source, origin top left. Every box
  headsight prints uses the same coordinates, so a box can be passed back as
  `--region`.
- `--json` gives one JSON object instead of the line.
- Exit codes: 0 event or success, 1 timeout, 2 usage error, 3 permission
  missing, 4 capture failed (including `window gone`: the watched window
  closed, was minimised, its app was hidden, or it moved to another desktop;
  macOS doesn't tell these apart without Accessibility access).

What changed since the agent last looked: `snap --name before`, make the
change, then `wait --change --since before` (reports a change made before the
call at once) or `wait --still` followed by `diff --since before`. References
live in `$TMPDIR/headsight/ref/` with mode 0600, are never shown to the model,
and are deleted after an hour or by `drop`.

## How it decides

- Screen and windows: frames come from ScreenCaptureKit at 30 fps (`--fps`).
  macOS marks frames where nothing changed, and those cost nothing. Other
  frames are compared with the reference in 16x16 blocks; a block changes when
  its mean difference per byte is above 0.5. Changed blocks within one block
  of each other form a box. A 6x6 pixel change on a Retina screen is found.
- Windows: the title bar (top 28 points) is left out of `wait` and `diff`. It
  changes when focus moves and shows macOS's recording indicator while a
  window is captured. Windows with a toolbar (Safari, Finder) also restyle the
  toolbar when focus moves; leave it out with `--ignore` or watch a `--region`
  below it.
- Camera: 1280x720. The first frames are skipped while exposure settles, a
  noise level is measured per block over about a second, and a change has to
  stand out from it for 3 frames in a row. Sensor noise and flicker do not
  count as changes.
- `--text` runs Apple's text recognition on the first frame and then only on
  frames that changed.

## Permissions and hosts

macOS gives Screen Recording and Camera access to the app that started the
agent (Terminal, iTerm2, VS Code, Claude), not to headsight. When access is
missing, headsight names that app and the System Settings page:

```
permission: Screen Recording is off for "Terminal". System Settings > Privacy & Security > Screen Recording.
```

Tested: Terminal (screen, windows and camera). Not yet tested: iTerm2,
Ghostty, VS Code's terminal, the Claude desktop app. Agents over ssh or under
launchd have no app to hold the permission and get a message saying so.

## Privacy

- Frames stay on the Mac. Nothing is sent anywhere; headsight prints paths,
  boxes and text.
- Crops are capped at 1024 px on the long side and removed after a day.
  Full-resolution frames exist only as named references, removed after an hour.
- The camera opens only for a command that names it (`--source camera`,
  `--camera NAME`) and closes before the command returns.

## Limits

- macOS doesn't redraw windows that are fully covered, or anything while the
  screen is locked, so nothing changes there. headsight prints a note when the
  screen is locked.
- Text recognition mixes up similar characters (`0`/`O`) like any OCR;
  `--accurate` is slower and better on small text.
- It sees and reads; it doesn't click or type.
- macOS only. On Linux it builds and says capture is not supported.

## Speed

On a MacBook Pro (Apple Silicon, built-in Retina display 3024x1964):

| | |
|---|---|
| `snap` of a window | about 0.2 s |
| `wait --change --since NAME` when the change already happened | 0.14 s |
| `diff --since NAME` | 0.14 s |
| `text` on a window | 0.15 s |
| watching the whole screen at 30 fps (measured with the prototype, same capture and comparison code) | about 5% of one core, 84 MB |
| `snap --source camera` (includes warm-up) | about 1.9 s |

## Evaluation

Planned before 0.1.0: headless Claude Code (Sonnet), 3 runs per task, with
only a shell (`screencapture`) against headsight plus the line above, on four
watching tasks (wait for an export to finish, read a counter once it settles,
report every visual change after an edit, catch a toast shown for 3 s).

## Build

Requires Zig 0.15.1 and Xcode's command line tools.

```sh
zig build                          # zig-out/bin/headsight
zig build test                     # unit tests and CLI checks (no capture needed)
scripts/live.sh                    # live check against a test window (needs Screen Recording)
```

## License

MIT
