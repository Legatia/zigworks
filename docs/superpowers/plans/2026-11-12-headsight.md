# headsight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CLI that lets coding agents wait for a screen or camera region to change, settle or show text, and get back one line plus a small crop, instead of repeated screenshots.

**Architecture:** Pure Zig core (block diff, box merging, the wait state machine, argument parsing, reference store, output) that builds and is unit-tested on Linux and macOS. One Objective-C file behind a C header does the Apple parts (ScreenCaptureKit, AVFoundation, Vision, ImageIO, permission checks). `main.zig` wires them together; on Linux every command reports "not supported".

**Tech Stack:** Zig 0.15.1, Objective-C with ARC compiled by Zig's build, macOS 14+ frameworks: ScreenCaptureKit, AVFoundation, CoreMedia, CoreVideo, CoreGraphics, ImageIO, Vision, Foundation, AppKit (for nothing but `NSRunningApplication`, if needed).

**Spec:** `docs/superpowers/specs/2026-11-12-headsight-design.md`

## Global Constraints

- Zig 0.15.1; `build.zig.zon` `.minimum_zig_version = "0.15.1"`, `.version = "0.1.0"`.
- macOS 14 or later (`-mmacosx-version-min=14.0` on the Objective-C file); Apple Silicon release only.
- Coordinates everywhere: pixels of the source at full resolution, origin top left, `X,Y,W,H`.
- Block size 16 px. Screen change threshold: mean absolute difference per byte above 0.50 (score units of 1/100: 50).
- `wait` defaults: `--timeout 120` s, `--still` 800 ms, screen 30 fps.
- Crops: PNG in `$TMPDIR/headsight/`, padded 16 px around the box, long side at most 1024 px, files older than 24 h removed at the start of each run.
- References: `$TMPDIR/headsight/ref/NAME.ref`, mode 0600, deleted after 3600 s or by `drop`. Names: letters, digits, `.`, `_`, `-`, 1-64 chars.
- Exit codes: 0 event/success, 1 timeout, 2 usage error, 3 permission missing, 4 capture failed.
- The camera opens only when the command has `--source camera` or `--camera NAME`, and closes before the command returns.
- No frame data printed or sent anywhere; only crop paths, boxes, text.
- Copy: plain labels, no slogans (user's CLAUDE.md). Permission line format, verbatim: `permission: Screen Recording is off for "<App>". System Settings > Privacy & Security > Screen Recording.` (Camera: same with `Camera`.)
- Do not commit, tag or push. The user commits. Checkpoints are `zig build test` passing.

## Review Focus

1. The watched window closes or minimises during `wait --window`: expect `window closed after=…` and exit 4 at once, not a wait until the timeout. (Task 3 test `stream_error_ends_wait`, Task 7 maps the SCK stop error.)
2. The display sleeps or no frames arrive: the timeout must still fire on time. (Task 3 test `timeout_without_frames`; Task 7 stream has its own timeout.)
3. A region outside the source, or zero-sized, or a box taken from a different source: usage error naming the source size, exit 2. (Task 4 test `region_outside_source`.)
4. An agent reads coordinates off a downscaled crop: every crop line prints `origin=X,Y scale=S` so crop pixels can be converted. (Task 6 test `crop_line_has_origin_and_scale`.)
5. A reference name like `../x` or a reference whose source size has changed: rejected with a clear message. (Task 5 tests `bad_names_rejected`, `size_mismatch_reported`.)

## File Structure

```
headsight/
  build.zig, build.zig.zon, LICENSE, README.md
  scripts/smoke.sh          CLI paths that need no capture (help, usage errors, drop, Linux "not supported")
  scripts/live.sh           manual, macOS: real capture against a fixture page
  scripts/fixture.swift     window with timed changes used by live.sh and the eval
  src/main.zig              command dispatch, help text, exit codes
  src/args.zig              argv -> Request (pure)
  src/frame.zig             Frame type, Rect, region checks (pure)
  src/diff.zig              block scores, changed-block mask, camera noise floor (pure)
  src/boxes.zig             changed blocks -> boxes, padding, cap (pure)
  src/watch.zig             wait state machine: change / still / text (pure, OCR injected)
  src/store.zig             crop dir, references, cleanup (std.fs)
  src/output.zig            event lines and JSON (pure)
  src/platform.zig          extern decls for the C API; Linux stubs
  src/mac/capture.h         C API
  src/mac/capture.m         Apple implementation
```

---

### Task 1: Project skeleton, Frame and block diff

**Files:** Create `headsight/build.zig`, `headsight/build.zig.zon`, `headsight/LICENSE` (MIT, "Copyright (c) 2026 headsight contributors"), `headsight/src/main.zig` (stub that imports all modules for tests), `headsight/src/frame.zig`, `headsight/src/diff.zig`. Modify `.github/workflows/ci.yml` (add `headsight` to `matrix.project`).

**Interfaces — Produces:**
- `frame.Rect = struct { x: u32, y: u32, w: u32, h: u32 }` with `fn contains(outer: Rect, inner: Rect) bool`, `fn clamp(r: Rect, w: u32, h: u32) Rect`, `fn pad(r: Rect, by: u32, w: u32, h: u32) Rect`.
- `frame.Frame = struct { px: []const u8, w: u32, h: u32, stride: u32 }` (BGRA, 4 bytes/px), `fn full(f: Frame) Rect`.
- `diff.B: u32 = 16`; `diff.Grid = struct { bw: u32, bh: u32, region: Rect, scores: []u16 }` (score = mean abs diff per byte ×100), `fn init(alloc, region: Rect) !Grid`, `fn deinit`.
- `diff.score(g: *Grid, prev: Frame, cur: Frame) void` — fills `g.scores` for blocks of `g.region`; partial edge blocks are scored over their real pixels.
- `diff.Mask = []bool` and `diff.changed(g: Grid, thresh: []const u16 or uniform u16, out: []bool) u32` — returns count. Accepts either a uniform threshold (`diff.changedUniform(g, t, out)`) or per-block (`diff.changedPerBlock(g, floor, margin, out)`).
- `diff.NoiseFloor = struct { max: []u16 }`, `fn observe(nf: *NoiseFloor, g: Grid) void` (keeps per-block max).

- [ ] **Step 1: Tests in `diff.zig`:** `identical_frames_no_change` (0 changed); `small_patch_found` (3024x1964 frame, invert 6x6 at (1001,503) → exactly one changed block, the one covering x 992-1008, y 496-512); `region_limits_scoring` (change outside region → 0); `edge_blocks_scored` (frame 1000x1000, change at (995,995) → 1 changed block); `per_block_floor` (noise 6 everywhere, floor learned 6, margin 4 → noise-only frame 0 changed, a +40 patch 1 changed). Frame tests: `rect_clamp_and_pad`.
- [ ] **Step 2: Run** `cd headsight && zig build test` → fails (symbols missing).
- [ ] **Step 3: Implement.** SIMD over 64-byte rows for full blocks (as in the spike), scalar for edge blocks. `build.zig` mirrors headterm's (strip option, `unit` and `test` steps); on macOS add `src/mac/capture.m` with flags `-fobjc-arc -mmacosx-version-min=14.0` and the frameworks — but only from Task 7 on; in Task 1 the build is pure Zig.
- [ ] **Step 4: Run** `zig build test` → all pass. Also `zig build test -Dtarget=x86_64-linux-musl` compiles (`zig build -Dtarget=x86_64-linux-musl`).

### Task 2: Boxes

**Files:** Create `headsight/src/boxes.zig`.

**Interfaces — Consumes:** `diff.Grid`, `frame.Rect`. **Produces:** `boxes.find(alloc, g: Grid, mask: []const bool, max_boxes: u32) !Result` where `Result = struct { boxes: []Rect (source coords, largest area first, at most max_boxes), total: u32 }`; `boxes.unionOf(bs: []const Rect) Rect`.

- [ ] **Step 1: Tests:** `single_block` (one block → one 16x16 box in source coords, offset by region origin); `adjacent_merge` (blocks (2,2),(3,2) → one 32x16 box); `gap_of_one_block_merges` ((2,2),(4,2) → one box); `far_apart_separate` ((0,0),(10,10) → two boxes, larger first); `cap_keeps_largest` (12 isolated single blocks plus one 3x3 group, max 8 → 8 boxes, first is the 3x3 group, total 13); `edge_box_clipped` (block at the region's ragged edge → box clipped to region).
- [ ] **Step 2: Run, see fail. Step 3: Implement** — connected components over the block grid with 8-neighbours after dilating by one block (gap tolerance 1), box = bounding rect of each component in pixels, clipped to the region. **Step 4: Run, pass.**

### Task 3: Wait state machine

**Files:** Create `headsight/src/watch.zig`.

**Interfaces — Consumes:** Tasks 1-2. **Produces:**
```zig
pub const Mode = union(enum) { change, still: u32 /*ms*/, text: []const u8 };
pub const Opts = struct { mode: Mode, region: Rect, ignore: []const Rect, timeout_ms: u32, camera: bool, max_boxes: u32 = 8 };
pub const OcrFn = *const fn (ctx: ?*anyopaque, f: Frame, r: Rect, out: *std.ArrayList(TextLine)) anyerror!void;
pub const TextLine = struct { text: []const u8, box: Rect, confidence: f32 };
pub const Event = union(enum) {
    changed: struct { at_ms: u64, boxes: []Rect, total: u32 },
    still: struct { at_ms: u64 },
    text: struct { at_ms: u64, line: TextLine },
    size_changed: struct { at_ms: u64, w: u32, h: u32 },
    timeout: struct { at_ms: u64 },
    source_gone: struct { at_ms: u64 },
};
pub const Watch = struct {
    pub fn init(alloc, opts: Opts, ocr: ?OcrFn, ocr_ctx: ?*anyopaque, reference: ?Frame) !Watch;
    pub fn feed(w: *Watch, f: ?Frame, now_ms: u64) !?Event; // f == null: idle tick (no new pixels)
    pub fn sourceGone(w: *Watch, now_ms: u64) Event;
    pub fn timedOut(w: *Watch, now_ms: u64) Event;
    pub fn last(w: *Watch) ?Frame; // last complete frame kept (for the crop)
    pub fn deinit(w: *Watch) void;
};
```
Rules: the first frame becomes the reference unless `reference` was given. `change`: event when any non-ignored block exceeds the threshold. `still`: track the time of the last change (start counts as a change at 0); event when `now - last_change >= ms`; idle ticks advance time. `text`: run OCR on the first frame and on every frame with a change, case-insensitive substring match per line, event on the first match (text already on screen counts). Frame size different from the reference → `size_changed`. Camera (`camera = true`): the first 15 frames are discarded, the next 30 learn a per-block noise floor, threshold per block = floor + 400 (4.00) and at least 800; a change must hold for 3 consecutive frames; `still` uses the same test. Screen: uniform threshold 50, no debounce.

- [ ] **Step 1: Tests:** `change_detected_with_boxes`; `ignore_rect_suppresses`; `still_after_quiet_period` (changes at 0,100,200 ms, frames to 1100 → still at ≥1000); `still_with_idle_ticks` (one frame then idle ticks only → still at 800); `text_already_present` (fake OCR returns "Export Done" on the first frame → text event at 0); `text_only_ocrs_on_change` (fake OCR counts calls: 1 for first frame, unchanged frames add 0); `reference_given_detects_prior_change` (reference differs from the first live frame → changed at once); `size_change_reported`; `camera_noise_ignored` (frames with ±6 random noise for 100 frames → no event; then a sustained +60 patch for 3 frames → changed); `camera_flicker_debounced` (patch for 2 frames only → no event); `timeout_without_frames` (`timedOut` gives timeout with at_ms); `stream_error_ends_wait` (`sourceGone` gives source_gone).
- [ ] **Step 2-4:** fail, implement, pass.

### Task 4: Arguments

**Files:** Create `headsight/src/args.zig`.

**Interfaces — Produces:**
```zig
pub const Source = union(enum) { screen, window: []const u8, camera: ?[]const u8 };
pub const Command = enum { snap, wait, diff, drop, text, windows, help, version };
pub const Request = struct {
    cmd: Command, source: Source = .screen, region: ?Rect = null, ignore: []Rect = &.{},
    mode: ?watch.Mode = null, timeout_ms: u32 = 120_000, fps: u32 = 30,
    name: ?[]const u8 = null /* snap --name, drop NAME */, since: ?[]const u8 = null,
    accurate: bool = false, json: bool = false, help_topic: ?[]const u8 = null,
};
pub fn parse(alloc, argv: []const []const u8) ParseError!Request; // error carries a message via a diag out-param
pub fn checkRegion(r: Rect, src_w: u32, src_h: u32, diag: *Diag) error{Usage}!void;
pub fn validName(s: []const u8) bool;
```
Flags per the spec's command list: `--source screen|camera`, `--window TEXT`, `--camera NAME`, `--region X,Y,W,H`, `--ignore X,Y,W,H` (repeatable), `--change`, `--still[=MS]`, `--text TEXT`, `--since NAME`, `--name NAME`, `--timeout S` (decimal seconds), `--fps N` (1-60), `--accurate`, `--json`. `diff` requires `--since`. `drop` takes one name. `wait` requires exactly one of `--change`, `--still`, `--text`.

- [ ] **Step 1: Tests:** `wait_change_window`; `still_default_and_value` (`--still` → 800, `--still=1500` → 1500); `wait_needs_one_mode` (none or two → Usage, message names the three flags); `region_parse_errors` (`1,2,3`, `a,b,c,d`, `0,0,0,10` → Usage); `region_outside_source` (`checkRegion(3000,0,100,100)` on 3024x1964 → Usage, message contains `3024x1964`); `camera_name_implies_camera`; `diff_requires_since`; `bad_names_rejected` (`../x`, `a/b`, empty, 65 chars); `unknown_flag` (message names it); `timeout_decimal` (`--timeout 1.5` → 1500).
- [ ] **Step 2-4:** fail, implement, pass.

### Task 5: Store (crops and references)

**Files:** Create `headsight/src/store.zig`.

**Interfaces — Produces:**
```zig
pub const Store = struct {
    pub fn open(alloc, base: []const u8 /* $TMPDIR/headsight */, now_s: i64) !Store; // creates dirs, removes crops > 86400 s and refs > 3600 s
    pub fn cropPath(s: *Store) ![]const u8;              // base/<pid hex>-<n>.png
    pub fn saveRef(s: *Store, name: []const u8, r: RefMeta, f: Frame) !void; // write tmp + rename, mode 0600
    pub fn loadRef(s: *Store, name: []const u8, now_s: i64) !Ref; // error.NoSuchRef, error.RefExpired
    pub fn dropRef(s: *Store, name: []const u8) !bool;  // false if absent
};
pub const RefMeta = struct { source: args.Source, window_id: u32, region: Rect, created_s: i64, src_w: u32, src_h: u32 };
pub const Ref = struct { meta: RefMeta, frame: Frame /* tight stride, owned */ };
```
File format (builder's choice, fixed here): 8-byte magic `HSREF001`, then little-endian u32 fields (src_w, src_h, region x/y/w/h, window_id, source kind 0/1/2), i64 created_s, u16 length + bytes of the window text or camera name, then region w×h×4 BGRA bytes, tightly packed.

- [ ] **Step 1: Tests** (temp dir under `std.testing.tmpDir`): `ref_roundtrip`; `ref_mode_0600`; `ref_expires_after_hour` (load at created+3601 → RefExpired and file removed); `drop_ref`; `cleanup_old_crops` (touch a crop with mtime −25 h → removed on open; −1 h kept); `size_mismatch_reported` (helper `store.checkSize(ref, src_w, src_h) error{SizeChanged}`); `bad_names_rejected` (saveRef with `../x` → error.BadName, nothing written outside base).
- [ ] **Step 2-4:** fail, implement, pass.

### Task 6: Output

**Files:** Create `headsight/src/output.zig`.

**Interfaces — Produces:** `output.Writer` over `std.Io.Writer` with `json: bool`; functions `snap(w, SnapInfo)`, `event(w, watch.Event, CropInfo)`, `diffResult(w, name, age_s, boxes, crops: []CropInfo)`, `textLines(w, []TextLine)`, `windows(w, []WindowInfo)`, `permission(w, what: enum{screen, camera}, app: ?[]const u8)`, `noGuiHost(w)`, `unsupported(w)`. `CropInfo = struct { path: []const u8, origin_x: u32, origin_y: u32, scale: f32 }`.

Exact text lines (seconds with one decimal):
```
snap source=screen size=3024x1964 scale=2 region=0,0,3024,1964 crop=PATH origin=0,0 scale=0.34
changed after=12.4s boxes=1 crop=PATH origin=796,424 scale=1
  box 812,440,388,96
still after=2.1s crop=PATH origin=0,0 scale=0.5
text after=31.0s found="Export Done: 42 files" box=402,310,520,48 crop=PATH origin=386,294 scale=1
size changed after=3.0s size=1200x800
window closed after=4.2s
timeout after=120.0s
diff since=before age=42s boxes=2
  box 10,10,100,40 crop=PATH origin=0,0 scale=1
  "Invoice 2026-118" box=120,80,410,40
(no text)
id=4512 app="Safari" title="Fixture" size=1440x900 at=0,25
```
`snap` line: the second `scale=` is the crop scale; rename the first to `pixel_scale=`. `--json`: one object per call with the same field names (`boxes` as arrays of 4 numbers).
No-GUI host: `permission: no app on this Mac started this process (ssh or launchd?), so macOS has nowhere to grant Screen Recording. Run the agent from a terminal app on this Mac.`
Unsupported: `headsight: screen and camera capture need macOS 14 or later; this platform is not supported yet.`

- [ ] **Step 1: Tests** for each line above, plus `crop_line_has_origin_and_scale` and `json_changed_event` (parse with `std.json` and check fields). **Step 2-4:** fail, implement, pass.

### Task 7: Apple capture layer

**Files:** Create `headsight/src/mac/capture.h`, `headsight/src/mac/capture.m`, `headsight/src/platform.zig`. Modify `headsight/build.zig` (on macOS: add the `.m` file and frameworks ScreenCaptureKit, AVFoundation, CoreMedia, CoreVideo, CoreGraphics, ImageIO, Vision, Foundation, UniformTypeIdentifiers; `linkSystemLibrary("objc")`).

**Interfaces — Produces (C API, mirrored as `extern` in platform.zig; on Linux `platform` functions return `error.Unsupported`):**
```c
enum { HS_OK = 0, HS_TIMEOUT = 1, HS_PERMISSION = 3, HS_FAIL = 4, HS_GONE = 5, HS_NO_HOST = 6, HS_NO_CAMERA_KEY = 7 };
typedef struct { const uint8_t *px; int w, h, stride; } hs_frame;
typedef struct { int kind; /* 0 display, 1 window, 2 camera */ uint32_t window_id; const char *camera_name; int fps; } hs_source;
int  hs_host_app(char *buf, int len);              /* 1 found (bundle display name), 0 none (ssh/launchd) */
int  hs_screen_access(int request);                /* 1 granted; request=1 calls CGRequestScreenCaptureAccess once */
int  hs_camera_access(void);                       /* HS_OK, HS_PERMISSION, HS_NO_CAMERA_KEY (host app lacks NSCameraUsageDescription); asks if undecided */
typedef void (*hs_window_cb)(void *ctx, uint32_t id, const char *app, const char *title, int x, int y, int w, int h);
int  hs_windows(hs_window_cb cb, void *ctx);       /* on-screen layer-0 windows, front to back */
int  hs_shot(const hs_source *src, uint8_t **px, int *w, int *h, int *stride, double *pixel_scale); /* caller frees with hs_free */
typedef int (*hs_frame_cb)(void *ctx, const hs_frame *f /* NULL = idle tick */); /* return 1 to stop */
int  hs_stream(const hs_source *src, int timeout_ms, hs_frame_cb cb, void *ctx); /* HS_OK stopped by cb, HS_TIMEOUT, HS_GONE (window closed / stream stopped), errors */
typedef void (*hs_text_cb)(void *ctx, const char *text, float conf, int x, int y, int w, int h); /* pixel coords, top left */
int  hs_ocr(const hs_frame *f, int x, int y, int w, int h, int accurate, hs_text_cb cb, void *ctx);
int  hs_write_png(const char *path, const hs_frame *f, int x, int y, int w, int h, int max_side, double *scale_out);
void hs_free(void *p);
```
Notes: screen via `SCStream` with `minimumFrameInterval = 1/fps`, `showsCursor = NO`, idle frames delivered as `cb(ctx, NULL)`; window source via `SCContentFilter initWithDesktopIndependentWindow:`; `didStopWithError` → `HS_GONE`. Camera via `AVCaptureDeviceDiscoverySession` (built-in wide angle and external types, no Continuity warning), `AVCaptureSessionPreset1280x720` set after `addInput` and checked with `canSetSessionPreset`, BGRA output. The camera session is stopped before `hs_stream` returns. Host app: walk parent pids with `proc_pidpath`/`proc_pidinfo` to the nearest ancestor inside a `.app` bundle; its `NSCameraUsageDescription` decides `HS_NO_CAMERA_KEY`. OCR: Vision `VNRecognizeTextRequest`, fast unless `accurate`, results converted from normalised bottom-left to pixel top-left coords of the frame. PNG: ImageIO, downscaled with high interpolation so the long side ≤ max_side.

- [ ] **Step 1: Tests** in `platform.zig`, skipped unless macOS (`if (builtin.os.tag != .macos) return error.SkipZigTest`), needing no permission: `png_roundtrip_size` (write 2000x500 → file exists, scale 0.512); `ocr_synthetic` (render "Export Done 42" with a test helper `hs_test_render_text(w, h, text)` added to capture.m → OCR finds a line containing "Export Done"); `host_app_does_not_crash` (returns 0 or 1).
- [ ] **Step 2-4:** fail, implement, pass (`zig build test` on macOS; Linux build still compiles).

### Task 8: Commands

**Files:** Modify `headsight/src/main.zig`. Create `headsight/scripts/smoke.sh`, add it to `build.zig` `test` step like headterm (`addSystemCommand`, `addArtifactArg`).

**Interfaces — Consumes:** everything above.

Behaviour per command (exit codes from Global Constraints):
- Every capture command: on Linux print `unsupported`, exit 4. On macOS: screen sources check `hs_screen_access(1)`; no host → `noGuiHost`, exit 3; denied → `permission` line naming the host app, exit 3. Camera: `hs_camera_access`; `HS_NO_CAMERA_KEY` → `camera: "<App>" can't use the camera (it has no camera usage description). Run the agent from Terminal or iTerm2.` exit 3.
- `--window TEXT`: `hs_windows`, first (frontmost) whose app or title contains TEXT, case-insensitive; none → `no window matches "TEXT"` with up to 5 candidates, exit 2.
- `snap`: `hs_shot`; check region; crop PNG (region or whole); with `--name`, `saveRef`.
- `wait`: optional `--since` → `loadRef` + `checkSize`; `hs_stream` feeding `Watch.feed` (stop on event), `HS_TIMEOUT` → `timedOut`, `HS_GONE` → `sourceGone`; write the crop: `changed` → union of boxes padded 16; `still` → whole region; `text` → the line's box padded 16. Exit 0, or 1 on timeout, 4 on source gone.
- `diff --since`: `loadRef`, one `hs_shot` of the same source (camera: a 15-frame warm-up stream, then compare with threshold 800), boxes, one crop per box (max 8). Exit 0 whether or not there are changes.
- `drop NAME`: `dropRef`; absent → `no reference named "NAME"`, exit 2.
- `text`: `hs_shot` (camera: warm-up stream, last frame), `hs_ocr` over region.
- `windows`, `help [command]`, `version` (prints `headsight 0.1.0`).
- Help text: modelled on headterm's: usage summary, then per command; includes the exit codes and one example per command.

- [ ] **Step 1: smoke.sh** (no capture needed): `help` exits 0 and lists the 6 commands; `wait` with no mode → exit 2 and message; `--region 1,2,3` → exit 2; `drop missing` → exit 2 and message; `version` prints `headsight 0.1.0`; `TMPDIR` set to a temp dir so nothing real is touched.
- [ ] **Step 2: Run** `zig build test` → smoke fails. **Step 3: Implement. Step 4:** `zig build test` passes on macOS; `zig build -Dtarget=x86_64-linux-musl` builds.

### Task 9: Live check on this Mac

**Files:** Create `headsight/scripts/fixture.html` (title "headsight fixture"; query parameters: `done=SECONDS` shows "Export Done: 42 files" after that delay; `toast=SECONDS` shows a toast for 3 s; `count=1` animates a counter for 3 s then settles at 7310; static otherwise) and `headsight/scripts/live.sh` (manual: opens the fixture in the default browser, runs `windows`, `snap --window "headsight fixture" --name live`, `wait --text "Export Done" --window …`, `wait --still`, `diff --since live`, `text --window …`, a `wait --change` that times out with `--timeout 2`, and checks exit codes and output prefixes). Camera is checked by hand: `wait --change --source camera --timeout 10` (wave), `snap --source camera`.

- [ ] **Step 1: Run** `scripts/live.sh` → every check `ok`. Record timings (snap latency, wait-to-event latency) for the README.
- [ ] **Step 2: Fix** anything found; re-run until clean.
- [ ] **Step 3: Host matrix.** For each of Terminal, iTerm2, Ghostty, VS Code, Claude desktop that is installed (`ls /Applications`), run `headsight snap` and `headsight wait --change --source camera --timeout 3` from it (Terminal and iTerm2 via `osascript`; the others by hand with the user) and record: works / permission message / camera refused. Results go in the README's hosts section.

### Task 10: README, CI, release

**Files:** Create `headsight/README.md` (what it is, the agent instruction line verbatim from the spec, quick start, commands, permissions and hosts, privacy, limits, measured results placeholder filled in Task 11). Modify `.github/workflows/release.yml`: add `headsight-v*` to tags and the `case`; for `headsight` on Linux matrix entries, skip the build and upload (`if-no-files-found: ignore`). Modify root `README.md` to list headsight.

- [ ] **Step 1:** `zig build test` in each of the three projects passes; `actionlint` if installed, otherwise YAML parses (`python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))'`).

### Task 11: Evaluation

Harness in the scratchpad (not shipped), modelled on the round 2/3 harness: headless Claude Code (Sonnet), 3 runs per task per condition, conditions (a) shell only, (b) headsight on PATH (`~/.local/bin/headsight`) plus the instruction line in the run's CLAUDE.md. Tasks 1-4 from the spec's Evaluation section, each with the fixture page in a browser window opened by the harness. Record time, cost, correct. Pass bar from the spec. Runs only after the user agrees to a time (it opens windows on their Mac).

- [ ] **Step 1:** build the harness and dry-run one task per condition.
- [ ] **Step 2:** with the user's go-ahead, the full run; results into `headsight/README.md` and `IDEAS.md`.
