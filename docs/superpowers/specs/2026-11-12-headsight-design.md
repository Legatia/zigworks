# headsight: design

2026-11-12. Working name; the name is open. Third tool in zigworks, after headterm and trigrep.

## Intent

Give coding agents sight without a stream of screenshots. An agent asks headsight to wait until a region of the screen (or the camera) changes or settles, or until some text appears there, and gets back one short line plus a small crop of just that region. It can also read text from a region on the device, and compare two images.

Today an agent can look once (take a screenshot or a camera photo and read the image). Every further look is a full image through the model. Waiting for something visual means polling screenshots: a 1600x900 image is about 1,900 input tokens (Anthropic's estimate of width x height / 750), so polling every 10 s for 10 minutes is about 115k tokens and 60 model turns. headsight makes that one blocking call with no model work while it waits. It is the same trade headterm made for terminals.

Order of use, as the user decided: first a tool agents install for themselves (CLI plus one line in the agent's instructions, like headterm). Later headterm, trigrep and headsight are combined into a consumer product. The likely role there: noticing when an agent in any window is waiting on the person, and (camera) whether the person is present. That product is out of scope here.

## Goals

1. `wait` blocks until a region changes, goes still, or shows given text, and returns one event line, the changed boxes, and a crop. The model does nothing while it waits.
2. Small changes are caught. A 6x6 pixel change on a Retina screen must be detected (the spike does this; a 64-bit perceptual hash of the whole screen does not).
3. Text is read from a region on the device, without a model call.
4. Screen and camera use the same commands.
5. One binary with no runtime dependencies (no Node, Python, Tesseract or ffmpeg).
6. The benefit is measured with real agent runs before v0.1.0 is called done (see Evaluation).

## Non-goals (v1)

- Clicking or typing into apps (computer use).
- Recognising objects, faces or gestures, or any model other than Apple's on-device text recognition.
- Reading accessibility trees or web page structure. This comes later; when it does, structure is read before pixels.
- Linux and Windows capture. The diff core stays portable; capture sits behind a C interface so a Linux backend (V4L2 for the camera) can be added.
- An MCP server. The CLI comes first because in the headterm tests the CLI plus one instruction line beat MCP on time and cost.
- Recording video, or sending a continuous stream to the model.

## Anti-goals (a failure even if everything else works)

- Frames leave the machine, or anything is kept beyond the crops and named references the agent asked for, or a reference is kept longer than an hour.
- It becomes another way to put full screenshots in front of the model. Crops are the default output, capped at 1024 px on the long side; full-resolution frames exist only as named references, which the model never sees.
- The camera turns on without a command that names it (`--source camera`), or stays on after the command returns.
- `wait --change` on the camera fires on sensor noise.

## Constraints

- Zig 0.15.1, the version the repo uses. Apple APIs go through one Objective-C file compiled by Zig's own build, behind a plain C interface (proven in the spike). Keeping everything in Zig is not a goal; the user only cares that performance is good.
- macOS 14 or later (needed for `SCScreenshotManager`), Apple Silicon first.
- Permissions belong to the app that started the agent (the terminal app or Claude), not to headsight. In the spike, Screen Recording was already granted to that app and the camera was granted on first use; the binary needed no Info.plist.
- Lives in the zigworks monorepo as the top-level folder `headsight/`, MIT, with its own `build.zig`, README and `build.zig.zon` version.
- CI runs `zig build test` per project on `ubuntu-latest` and `macos-15` (Zig 0.15.1 can't link on the macOS 26 runner). headsight must build and pass tests on Linux too: the diff core and box merging are tested there, and every Linux command says it is not supported on this platform. No Linux release binaries in v0.1; the release workflow builds headsight for Apple Silicon macOS only.
- Releases follow the repo's tag scheme (`headsight-v<version>`). Pushing a tag, publishing a release, and committing are the user's decisions.
- Hosts for v0.1: agents started from a GUI app on the user's Mac. Test matrix, screen and camera in each: Terminal, iTerm2, Ghostty, VS Code's terminal, and the Claude desktop app. Agents over ssh or under launchd get a clear "no GUI app to hold the permission" message; no signed helper app in v0.1. If a host app has no camera usage description, macOS ends the process on camera access: check this in the matrix and document which hosts can use `--source camera`.

## Spike results

Throwaway code, 2026-11-12, MacBook Pro (Apple Silicon), macOS 15.7.1, built-in Retina display 3024x1964, Zig 0.15.1, SDK 26.2.

| what | result |
|---|---|
| Build | Zig compiled the Objective-C file with `-fobjc-arc` and linked ScreenCaptureKit, AVFoundation, CoreMedia, CoreVideo, CoreGraphics, Vision and CoreText on the first try. Binary 325 KB, system frameworks only. |
| One screenshot (full resolution) | 240 ms for the first, then 41-45 ms. |
| Screen stream at 30 fps for 8 s | 29.5 frames/s delivered. macOS marked 127 of 236 frames idle (nothing changed, no pixels sent). Whole run: 0.44 s CPU in 8.1 s (about 5% of one core), 84 MB resident. |
| OS dirty rectangles | Present on every complete frame but coarse: a mean of 3.4 million of the 5.9 million pixels per frame. Too coarse for boxes, so headsight does its own comparison. |
| Block comparison in Zig (16x16 blocks, mean absolute byte difference, SIMD) | 0.56 ms on a full Retina frame in a tight loop; 2.0 ms mean (4.3 ms max) on live stream buffers, plus 1.6 ms to keep a copy. A 6x6 change was found as one block with the right box. |
| Complete frames with no visible change | 30 of 103 complete frames had no block above 1 (mean abs diff per byte). The OS idle flag is a free first filter, not the answer. |
| Camera (built-in, "MacBook Pro Camera") | Permission was not yet decided and was granted during the run. First frame about 5 s after start, including the permission step. 26.6 frames/s, 1920x1080 although 1280x720 was requested (the preset was not applied). Comparison 0.56 ms per frame. Sensor noise: half the frames had a block above 8, so a fixed threshold does not work. AVFoundation printed a deprecation warning for Continuity Camera device types. |
| Text recognition (Apple Vision) | Synthetic image with two known lines: fast mode read both ("0x1F" came back as "Ox1 F"), accurate mode read "Ox1F". Warm timings: 1400x220 image 5.6 ms fast, 42 ms accurate; full Retina screen 43 ms fast (51 lines), 450 ms accurate; a 900x300 region 6.6 ms fast, 64 ms accurate. First call cold: 120 ms fast, 360 ms accurate. |

## Prior art

| project | what it does | difference |
|---|---|---|
| claude-screen-mcp (npm 0.4.1, Oct 2026, 0 stars) | MCP server: screenshots, `wait_for_change`, `get_screen_diff`, OCR, text search with boxes. Node with sharp and tesseract.js. | Polls a full capture every 500 ms and compares a 64-bit dHash (a 9x8 greyscale thumbnail), which can't see small changes. No wait-until-still, no region in the wait, no camera. Tesseract downloads 7.5 MB of language data on first use. |
| Screen Vision MCP (Python) | Screenshots, OCR, watching the screen over time, phone camera by QR pairing. | Python plus tesseract plus ffmpeg; listed as inactive. |
| evalstate webcam MCP | Webcam frames and screenshots on request. | No change detection. Built for Claude Desktop (Jan 2025). |
| eyeballs | Visual change check for a URL against a baseline. | Web pages only. |
| point-and-speak (Claude Code mod) | Voice plus mouse pointing; attaches screenshots and the element under the pointer. | A different job (pointing), not waiting or watching. |

## Interface

These are decided (my calls, open to the user's change).

### Commands

```
headsight snap  [SOURCE] [REGION] [--name NAME]
headsight wait  (--change | --still[=MS] | --text TEXT) [SOURCE] [REGION] [--since NAME] [--ignore X,Y,W,H]... [--timeout S]
headsight diff  --since NAME
headsight drop  NAME
headsight text  [SOURCE] [REGION] [--accurate]
headsight windows
headsight help [COMMAND]
```

- `snap` writes a crop of the region (or of the whole source, downscaled, if no region) and prints its path, the source size and the pixel scale.
- `snap --name NAME` also keeps the full-resolution frame of that source and region as a named reference: raw pixels in `$TMPDIR/headsight/ref/`, file mode 0600, never printed or shown to the model, deleted after one hour or by `headsight drop NAME`. This is how "what changed since I last looked" works, like headterm's kept sessions, but with no background process: the reference is a file.
- `wait --change --since NAME` compares against the reference instead of the first frame of the wait, so a change that happened before the call is reported at once.
- `diff --since NAME` captures the same source and region now and prints every changed box with a crop of each. Typical use: `snap --name before`, edit the CSS, `wait --still`, `diff --since before`.
- Camera references are allowed; the camera still opens only for the command that names it.

- SOURCE: `--source screen` (default, the main display), `--source camera` (default camera), `--window TEXT` (the frontmost window whose app name or title contains TEXT; capture follows the window if it moves), `--camera NAME`.
- REGION: `--region X,Y,W,H` in pixels of the source at full resolution, origin top left. Every box headsight prints uses the same coordinates, so a box from one command can be passed as the region of the next. `snap` prints the source size and its pixel scale.
- `wait --change` returns when any block in the region changes. `wait --still=MS` (default 800 ms) returns when nothing in the region has changed for that long; if it is already still, after MS. `wait --text TEXT` returns when TEXT (case-insensitive substring) appears in the region; recognition runs only on frames that changed, never on a timer.
- `--timeout` default 120 s for `wait`. `--ignore` excludes areas such as a clock.
- `windows` lists capturable windows: app, title, size, position.
- A reference taken with `--window` or `--region` stores that window or region, and `--since` uses it; if the window's size has changed, `diff` and `wait --since` say so instead of guessing.

### Output

One short line per result, key=value, in the style of headterm, then any extra lines (boxes, recognised text):

```
$ headsight wait --change --window Safari --timeout 60
changed after=12.4s boxes=1 crop=/var/folders/.../headsight/3f2a-1.png
  box 812,440,388,96
$ headsight wait --text Done --region 0,0,1200,800
text after=31.0s found="Export Done: 42 files" box=402,310,520,48 crop=/var/folders/.../headsight/3f2b-1.png
$ headsight text --window Preview
  "Invoice 2026-118" box=120,80,410,40
  "Total: 1,240.00 EUR" box=120,610,380,40
```

- Crops are PNG files in `$TMPDIR/headsight/`, padded around the box and downscaled so the long side is at most 1024 px. The path is printed; the agent opens it with its own image tool. Files older than 24 h are removed at the start of each run.
- `--json` prints one JSON object instead, for scripts.
- Exit codes: 0 event or success, 1 timeout, 2 usage error, 3 permission missing, 4 capture failed.
- Missing permission prints one line naming the place to fix it, for example: `permission: Screen Recording is off for "Terminal". System Settings > Privacy & Security > Screen Recording.` It is checked before capture (`CGPreflightScreenCaptureAccess`, `AVCaptureDevice authorizationStatus`).

### Change detection

- Screen: frames come from a ScreenCaptureKit stream (default 30 fps, `--fps` to change). Idle frames are skipped. Complete frames are compared to the last reference frame in 16x16 blocks; a block changes when its mean absolute difference per byte is above 0.5. Changed blocks are merged into boxes. The cursor is not captured.
- Camera: 1280x720 (apply the preset correctly). The first frames are discarded while exposure settles, then a noise floor is measured per block over about one second. A change must exceed the floor by a margin and last a few consecutive frames. The camera is opened for the command and closed when it returns.
- `--still` means no changed block for MS milliseconds, using the same thresholds.

### Agent instruction line

Shipped in the README, the same way as headterm's:

```
To wait for something on screen or camera to change, settle, or show text, use the headsight CLI instead of repeated screenshots: `headsight wait --change|--still|--text TEXT [--window APP] [--region X,Y,W,H]` blocks and prints a crop path; `headsight help` has the details.
```

## Evaluation

Run before v0.1.0 is called done, the same way as headterm's rounds (see IDEAS.md): headless Claude Code (Sonnet), 3 runs per task per condition, answers checked against ground truth, time and cost recorded.

Conditions: (a) shell only (it can use `screencapture` and read images); (b) headsight on PATH plus the instruction line.

Screen tasks, each a local HTML page opened in a browser window by the harness:
1. A fake export shows "Done" with a file count after a random 20-90 s. Report the count.
2. A counter animates for a few seconds, then settles. Report the final value.
3. The agent changes one CSS value in a local page. Report every visual change. The fixture also changes something unintended elsewhere. (With headsight: `snap --name`, the edit, `wait --still`, `diff --since`.)
4. A toast shows for 3 s at a random moment within 60 s. Report its text.

The camera is checked by hand in v0.1 (no automated fixture).

Pass bar: (b) beats (a) on time or cost on at least 3 of the 4 tasks, with equal or better correctness. If not, stop and report, as with trigrep's first round.

The evaluation opens windows on the user's Mac and needs the machine free while it runs, so it is scheduled with the user.

## Calls made after the review

A reviewer read this document as a builder would. Its three open points were settled as follows (my calls, open to the user's change):

1. Before-and-after comparison uses named references (`snap --name`, `--since`, `diff --since`, `drop`) kept as files for at most an hour. No daemon, and no reading of arbitrary PNG files.
2. v0.1 ships for Apple Silicon macOS only. Linux builds the tested core and reports "not supported".
3. v0.1 supports agents started from GUI apps (the host matrix under Constraints). No ssh or launchd support and no signed helper app.

## Left to the builder

- Module layout, and how capture, diff, boxes and output are split.
- Box merging (connected blocks, a gap tolerance, a cap on boxes per event).
- SIMD widths, whether to compare downscaled frames, reuse of buffers.
- PNG writing (ImageIO on macOS is fine), temp file names, the raw reference file format.
- The Objective-C capture file is written fresh; the spike code is throwaway and stays in the scratchpad.
- The exact camera noise floor and debounce numbers, tuned by hand.
- The JSON field names.
- Tests: the diff core and box merging are unit-tested on synthetic frames on both CI platforms.

## Open for later

The name; Linux capture; an MCP server; reading accessibility trees and page structure before pixels; how headsight feeds the consumer product.
