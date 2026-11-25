# harness: the desk's avatar, a live 3D head — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The desk's avatar as one plain-JS module: `createAvatar(element, packUrl, options)` draws the portrait projected onto a rigged head with the 52 ARKit shapes (blinks, gaze, breathing, nods, expressions, lip-sync generated live), `fit(photo, closedPhoto)` makes a pack's head from a portrait in the browser, and `harness avatar check NAME` checks a pack, std only.

**Architecture:** Three files the desk builder embeds at fixed paths: `harness/src/desk/avatar.js` (the prototype's renderer and behaviour, made a module; pure pieces exported for tests), `harness/src/desk/fit.js` (the prototype's fit without the model render: the base head carries the model's 478 landmark surface points; pure geometry exported for tests), `harness/src/desk/vendor/three.module.min.js` (r170, pinned). One versioned container for heads (`head.bin`, kind `head`) and the base head (`base-head.bin`, kind `base`), written by fit.js and read by avatar.js and avatar.zig. Dev tools in `harness/tools/` (not shipped): a 127.0.0.1 server with the desk's URL layout and CSP, the base-head maker, the fit page, the preview page with a frozen-pose query, the MediaPipe fetch script, and a node test script for the pure JS.

**Tech Stack:** Zig 0.17.1 std only (avatar check); plain ES modules, WebGL 2 through three.js r170; MediaPipe tasks-vision 0.10.14 (CPU delegate); Python 3 stdlib for the dev server; node for the JS unit checks; headless Chrome (SwiftShader) for screenshots.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md` — binding: "The avatar" (States; Always moving; How the head works; The avatar pack; Fitting a portrait; Built-in avatars; Your own avatar; The avatar module), "Speech" (lip-sync), "The look" (reduced motion), Constraints (tests: `avatar check` on good and bad packs with the made-up head; docs: README Avatar packs). Reference implementation: `~/Downloads/butler-3d-head/` (`prototype.html`, `fit.html`).

## Global Constraints

- Module interface exactly as the spec: `createAvatar(element, packUrl, options)`; `setState(state)` with `resting`, `quiet`, `working`, `needs you`, `urgent`, `speaking`; `moment("smile" | "concern")`; `arrive()`; `speak({ text, audioUrl })` or `speak({ text, browser: true })`, resolving when the voice ends; `stop()`; `fit(photo, closedPhoto)`; plus `dispose()`.
- avatar.js imports `./vendor/three.module.min.js` and nothing else outside its folder; it reads `packUrl + "avatar.ini"` and the files it names. fit.js loads `/desk/assets/mediapipe/vision_bundle.mjs`, its `wasm/` folder and `face_landmarker.task`, and `/desk/assets/base-head.bin`. No outside host at run time.
- three.js r170, `three.module.min.js` from the npm package three@0.170.0, SHA-256 `08fd7545d13d2c7fb65ab691530a802dafefd638596501854f267d0fb13c39e7`; MIT notice kept in `vendor/README`.
- MediaPipe tasks-vision 0.10.14 (Apache 2.0), files and model pinned by SHA-256 in `tools/fetch-desk-assets.sh`; the model is `face_landmarker/float16/1/face_landmarker.task`.
- The spec's numbers: blinks every 2.5–6 s (more often speaking); working nods every 9–16 s; the smile 2 s; head turns about ±4° at most; 30 fps when resting or quiet; no drawing while `document.hidden`; without WebGL 2 the still breathes by a 0.6% scale; the fit's checks: one face, facing the camera within 8°, eyes open and mouth closed by the landmarker's scores, a closed photo within 12 px outside the eyes.
- Reduced motion (spec "The look"): the head keeps blinking and breathing, drops the drift and the nods; the mouth moves only when speaking.
- Licensing: `facecap.glb`, `base-head.bin`, the butler's portraits and its fitted `head.bin`, `eyes.png`, `eyemask.png` never enter the repository. They live in the scratchpad (`desk-assets/`, `data/avatars/butler/`). Zig tests use a small made-up head.
- File ownership: this branch edits only `harness/src/desk/avatar.js`, `fit.js`, `vendor/`, `harness/src/avatar.zig` (+ its test data), a minimal hook in `harness/src/main.zig` (usage lines, dispatch line, test import), `harness/tools/`, the README's "Avatar packs" section, this plan and the ledger. No workflow files, no other Zig, no desk page files.
- Copy (CLAUDE.md): plain labels; fit and pack messages are plain sentences; any explanation in the preview page behind a small "i".
- Zig: std only; `zig build test --summary all` Debug and ReleaseSafe; cross `zig build` and `zig build unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `--cache-dir` under the worktree's `.superpowers/`. Known flake at the base: core `each_of_these_asks`.

## Review Focus

1. **A phone photo with an EXIF orientation tag** (the usual upload): the fit and the renderer must see it upright and the same way. Both decode through one `loadImage` that draws the browser-oriented image into a canvas. Test (Task 5): a rotated, tagged copy of the butler fits to landmarks within 2 px of the upright one.
2. **A head fitted to another photo** (the still replaced after fitting, or a different size): `avatar check` says so (`a_head_fitted_to_another_photo_is_a_problem`, Task 1); `createAvatar` shows the still breathing with `problem` set rather than a misplaced head (Task 6, preview check).
3. **Speech that overlaps** (`speak` during `speak`, `stop()` while the audio is still loading, `dispose()` mid-speech): the earlier promise settles, nothing keeps playing, the mouth closes (Task 7, headless check with a generated WAV).
4. **WebGL lost mid-session** (sleep, GPU reset): the still breathing, not a frozen or black frame (Task 6, preview `?lose=1`).
5. **A pack whose head is missing, truncated or from a newer version**: the still breathing with a plain `problem`, never a thrown error and a blank element (Task 6, preview with a truncated head; Task 1's Zig tests for the same files).

---

### Task 1: The head file and `harness avatar check`

**Files:**
- Create: `harness/src/avatar.zig`, `harness/src/testdata/avatar/tiny-head.bin` (made in Task 4 by fit.js's packer; Task 1 builds its heads in Zig)
- Modify: `harness/src/main.zig` (usage, dispatch, test import only)

**The container (head.bin and base-head.bin, version 1):**
- bytes 0–7: magic `89 48 45 41 44 0D 0A 1A` ("\x89HEAD\r\n\x1a"); 8–11: u32 LE format version (1); 12–15: u32 LE header length L, a multiple of 4; then L bytes of UTF-8 JSON padded with spaces; then the data block. Every array starts at a data offset that is a multiple of 4.
- JSON `arrays`: `{ NAME: [TYPE, OFFSET, COUNT] }`, TYPE one of `f32`, `i16`, `u16`, `u32`, `u8`; OFFSET from the data block's start; COUNT in elements.
- Kind `head` (a pack's): `kind`, `version`, `vertices` N, `image` [W, H] (the still's pixels), `shapes` (the 52 ARKit names), `shapeScale` (52 × [pos, nrm]), `face`, `mouth` (`center`, `left`, `right`, `inner` 20 points, `outer` 20 points, `jaw` [x, y, z]), `eyes` (2, image-left first: `center`, `width`, `outline` 16 points, `iris` [x, y, r], `catchlight` [x, y, r] or null, `lid` [r, g, b]), `eyeCrop` [x, y, w, h], `photo` (the landmarker's scores). Arrays: `head.pos`, `head.nrm` (f32, 3N), `head.uv`, `head.uvC` (f32, 2N), `head.idx` (u16 when N < 65536, else u32), `shape.NAME.pos`, `shape.NAME.nrm` (i16, 3N, value × scale / 32767), `teeth.pos` (f32), `teeth.idx`. Units: photo pixels, x right, y up (minus the row), z toward the camera.
- Kind `base`: `kind`, `version`, `vertices`, `shapes`, `source` {file, sha256}; arrays `head.pos`, `head.idx`, `shape.NAME.pos` (f32 deltas), `teeth.pos`, `teeth.idx`, `landmarks` (f32, 478 × 3, NaN where the model has none). Model units.

**avatar.ini:** `key = value` lines, `#` comments; keys `still` (required), `closed`, `head`, `eyes`, `eyemask`; values are plain file names in the pack's folder. `head`, `eyes` and `eyemask` come together or not at all.

**Interfaces:**
- Produces: `pub fn check(io: Io, a: Allocator, dir: []const u8) !Report` (`Report{ files: []File, head: ?HeadInfo, problems: []const []const u8, fitted: bool }`), `pub fn readHeader(a, bytes) !Header`, `pub fn text(a, name, Report) ![]const u8`, `pub fn validName(name) bool` (lowercase letters, digits, `-`, `_`, 1–64, first a letter or digit); main.zig's `avatar check NAME` prints `text(...)` and exits 0 when no problems, 1 otherwise; folder `HOME/avatars/NAME`.

- [ ] **Step 1: Failing tests in avatar.zig** (each builds a pack in a tmp dir; heads built by a test helper `testHead(a, .{...})` with 3 vertices and the 52 names):
  - `a_good_pack_passes_with_its_files_types_and_sizes`: JPEG still 64×32, PNG eyes and eyemask, closed JPEG 64×32, head v1 image [64, 32]; no problems, `fitted`; the text names each file with its type, pixel size and bytes, and the head's version, vertices and 52 shapes.
  - `a_pack_with_only_a_still_is_good_and_unfitted`.
  - `files_are_checked_by_their_magic_bytes`: a text file as `head.bin` → "head.bin is not a head file"; a PNG named `still.jpg` passes as PNG; a GIF still → "still.gif is not a JPEG or PNG".
  - `avatar_ini_problems_are_named`: missing file; no `still`; unknown key; `../x.jpg`; `head` without `eyes` → "head, eyes and eyemask go together"; a named file that isn't there.
  - `the_head_header_is_checked`: bad magic; version 2 → "made by a newer harness"; header past the end; a missing shape; a shape twice; `head.uv` with 3N; an array past the end; an offset not a multiple of 4; an index ≥ N; a base head in a pack → "the base head, not a fitted one"; `eyes` with 15 outline points.
  - `a_head_fitted_to_another_photo_is_a_problem`: head image [64, 32], still 80×32 → "head.bin was fitted to a 64×32 photo; the still is 80×32".
  - `jpeg_and_png_sizes_are_read`: SOF0 and SOF2 after an APP1; PNG IHDR.
  - `files_over_20_mb_are_a_problem` (sparse file).
  - main.zig `avatar_takes_check_and_a_name` (args: `check NAME` only; a bad name refused).
- [ ] **Step 2:** `zig build test -Dtest-filter=avatar` fails (no avatar.zig).
- [ ] **Step 3:** Implement avatar.zig (std.json for the header; read the data block once; every limit checked before indexing). Hook main.zig.
- [ ] **Step 4:** Tests pass; full Debug run.
- [ ] **Step 5:** Commit.

### Task 2: Vendored three.js, the fit files, the dev server

**Files:**
- Create: `harness/src/desk/vendor/three.module.min.js`, `harness/src/desk/vendor/README`, `harness/tools/fetch-desk-assets.sh`, `harness/tools/devserver.py`, `harness/tools/README`

**Interfaces:**
- `sh tools/fetch-desk-assets.sh DIR` writes `DIR/mediapipe/vision_bundle.mjs`, `DIR/mediapipe/wasm/vision_wasm{,_nosimd}_internal.{js,wasm}`, `DIR/mediapipe/face_landmarker.task`; each checked by SHA-256 (a file already there with the right hash is kept; a wrong one is fetched again; a mismatch after download stops with the file's name); curl, and `shasum -a 256` or `sha256sum`.
- `python3 -I tools/devserver.py PORT DATA` serves on 127.0.0.1: `/desk/static/` → `harness/src/desk/`, `/desk/avatars/` → `DATA/avatars/`, `/desk/assets/` → `DATA/desk-assets/`, `/tools/` → `harness/tools/`; `POST /save/PATH` → `DATA/PATH` (≤ 64 MB, inside DATA); types for `.mjs`/`.js` (text/javascript), `.wasm` (application/wasm), `.task`/`.bin` (application/octet-stream); every response carries the CSP under test (`--csp` overrides; default `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; style-src 'self'`).

- [ ] **Step 1:** Vendor the file from the npm tarball (registry sha512 checked), compare with jsDelivr's copy, record URL and SHA-256 and the MIT notice in `vendor/README`.
- [ ] **Step 2:** Write the fetch script with the pinned hashes; run it into `$SCRATCH/data/desk-assets`; run it again (all kept); corrupt one file and run (fetched again).
- [ ] **Step 3:** Write the dev server; `curl` one file of each kind and check its type and CSP header.
- [ ] **Step 4:** Commit.

### Task 3: The base head

**Files:**
- Create: `harness/tools/make-base-head.html`

**Interfaces:**
- Consumes: `packHead(meta, arrays) → ArrayBuffer` (fit.js, Task 4 — written first in Task 4's step 3 if this task runs first; the page imports `/desk/static/fit.js`).
- Produces: `DATA/desk-assets/base-head.bin`, kind `base`, from `facecap.glb` (SHA-256 checked in the page before use).

- [ ] **Step 1:** The page: loads three (vendored, via an import map) and its r170 addons (GLTFLoader, KTX2Loader, MeshoptDecoder, the basis transcoder) from jsDelivr at 0.170.0 (dev only); loads the GLB from `/desk/assets/facecap.glb`; zeroes every morph weight; renders the textured neutral head front-on at 1024 with an orthographic camera placed at the head (bounds relative to its position); runs the landmarker; raycasts each of the 478 points into the neutral head (NaN on a miss); writes world-space positions, shape deltas (world minus world), teeth; saves through `POST /save/desk-assets/base-head.bin`; prints counts (hits of 478, vertices, shapes).
- [ ] **Step 2:** Run it in headless Chrome; expect ≥ 468 hits of the first 468, 2694 vertices, 52 shapes.
- [ ] **Step 3:** Commit (the page only; base-head.bin stays in the scratchpad).

### Task 4: fit.js, the geometry (pure)

**Files:**
- Create: `harness/src/desk/fit.js` (pure part), `harness/tools/test-avatar.mjs`, `harness/src/testdata/avatar/tiny-head.bin`

**Interfaces:**
- Produces (named exports): `packHead(meta, arrays: {name: TypedArray}) → ArrayBuffer`; `similarity2D(src: Float64Array, dst: Float64Array) → {scale, theta, sc, tc, apply(x,y,z) → [x,y,z]}`; `solveRbf(ctrl: [x,y,z][], disp: [dx,dy][], lambda) → warp(x,y,z) → [x,y,z]`; `fitGeometry(base, landmarks478: [x,y,z][], W, H) → {arrays, meta, report}`; `checkPhoto(result, W, H) → null | {code, message}`; `checkClosed(open, closed, W, H, W2, H2) → null | {code, message}`; `packIni(files) → string`.
- avatar.js (named exports, Task 6/7 implement; Task 4's script tests them as they land): `readHead(buf) → {meta, arr(name)}`, `buildTimeline(text) → {ev, words, ends, dur}`, `stretchTimeline(tl, start, end) → tl`, `voicedSpan(samples, rate) → [t0, t1]`, `parseIni(text) → {still, closed?, head?, eyes?, eyemask?}`.

- [ ] **Step 1: Failing node checks** in `test-avatar.mjs` (`node harness/tools/test-avatar.mjs` prints `ok N` per check, exits 1 on a failure): pack/read round trip with every type, offsets multiples of 4, bad magic and version 2 refused; `similarity2D` recovers scale 3.5, 7°, offset (120, −40) to 1e-9; `solveRbf` with λ = 0 reproduces its controls to 1e-6 and is affine-exact on an affine field; `fitGeometry` on a synthetic base (a 9×9 grid "face" with 478 landmarks on it and two shapes) gives head.pos = the similarity of the base where the photo landmarks are a similarity of the base, carries a shape delta scaled by the similarity's scale, and uv = (x/W, 1 + y/H); `checkPhoto` messages for 0 faces, 2 faces, 10° yaw, eyeBlink 0.7, jawOpen 0.4; `checkClosed` for a 15 px shift and a different size; the tiny head packed again equals the committed `tiny-head.bin` byte for byte.
- [ ] **Step 2:** Run: fails (no fit.js).
- [ ] **Step 3:** Implement. The warp is the prototype's: 2D Procrustes in x/y with z scaled, then an RBF with the biharmonic r kernel plus an affine part on x/y displacements in face units (1/scale), λ = 2e-3, near-duplicate controls (< 1.5 px) dropped, Gaussian elimination with partial pivoting. Pairs: landmarks 0–467 that the base has. Normals on the welded topology (positions rounded to 1e-4). A shape's vertices with a zero delta reuse the base's warp. Jaw vector: mean delta of the 40 vertices that move most under `jawOpen`.
- [ ] **Step 4:** Passes; write `tiny-head.bin` from the script (`--write-fixture`); Task 1's `the_js_packer_and_this_reader_agree` reads it.
- [ ] **Step 5:** Commit.

### Task 5: fit.js in the browser, and the butler

**Files:**
- Modify: `harness/src/desk/fit.js`
- Create: `harness/tools/fit-pack.html`

**Interfaces:**
- Produces: `export async function fit(photo, closedPhoto?) → { head: ArrayBuffer, eyes: Blob, eyemask: Blob, report }`; photo/closedPhoto: a Blob, File, URL string, HTMLImageElement, ImageBitmap or canvas. A failed check rejects with an `Error` whose `message` is the plain line and `code` the check (`no-face`, `faces`, `turned`, `eyes-closed`, `mouth-open`, `closed-size`, `closed-moved`, `closed-open`, `assets`). `export async function loadImage(src) → HTMLCanvasElement` (the browser-oriented pixels; avatar.js uses the same).
- `fit-pack.html?pack=avatars/butler/` fits the pack's still (and closed) from its avatar.ini, saves `head.bin`, `eyes.png`, `eyemask.png` and a new avatar.ini through `/save/`, and prints the report.

- [ ] **Step 1:** Implement: MediaPipe from `/desk/assets/mediapipe/` (`FilesetResolver.forVisionTasks('/desk/assets/mediapipe/wasm')`, CPU, numFaces 2, blendshapes and transformation matrices); the checks first (messages in Rulings); `fitGeometry`; the eye crop cleanup (catchlights removed, the iris completed by mirroring, a 6 px band of photo kept round the lids), the eye mask (quarter size, R the image-left eye, G the other), lid tones (median of the band 3–10 px above each upper lid), `packHead`.
- [ ] **Step 2:** Fit the butler (still and closed) in headless Chrome through `fit-pack.html`; compare with the prototype's `head.bin`: vertex positions (mean and max px), uv, eyeCrop, catchlights. Expect mean < 1 px.
- [ ] **Step 3:** Review Focus 1: a 90°-rotated copy of the still with EXIF orientation 6 fits to landmarks within 2 px of the upright fit. A photo with no face, a closed-eyes photo as the still, and the closed photo shifted 20 px give their messages.
- [ ] **Step 4:** Find the CSP: run the fit under the dev server's default CSP with a `securitypolicyviolation` listener; record what is refused and the smallest CSP that passes.
- [ ] **Step 5:** Commit.

### Task 6: avatar.js, the renderer

**Files:**
- Create: `harness/src/desk/avatar.js` (renderer part), `harness/tools/avatar-preview.html`

**Interfaces:**
- Produces: `export async function createAvatar(element, packUrl, options = {}) → Avatar`, `Avatar = { setState, moment, arrive, speak, stop, fit, dispose, fitted: bool, mode: 'head' | 'still', problem: string | null }`. Options: `reducedMotion` (default from the media query), `debug: { shapes, pose, gaze, breath, time }` (a frozen pose for screenshots; the preview passes it from the query). Rejects only when not even the still loads.
- Preview: `avatar-preview.html?pack=/desk/avatars/butler/&state=…&shapes=jawOpen:0.3,…&pose=yaw,pitch,roll&gaze=x,y&breath=0&lose=1&nogl=1`; sets `window.__ready = true` after the first frame drawn with the frozen pose; buttons for each state, moment, arrive, speak (browser, or an audio URL) and stop; an "i" for what the page is.

- [ ] **Step 1:** Port the prototype's renderer: the projected head with relight; the rest-depth raster (`hid`) and the backplate following the face's depth and breathing; the stencil-cut openings (16-point outlines shrunk 1.5 px) and the eyeball spheres textured from `eyes.png` with the live catchlight; the blink blend into the closed portrait by the eye mask; the mouth interior (lip polygon, `!gl_FrontFacing || hid > 12`, depth 0.9999); the reseated upper teeth and the mirrored lower row on the jaw vector; framing from the face box. Without a closed photo: draw the closed eyes into a canvas copy of the still (each opening filled with its `lid` tone, darker towards a soft lash line along the lower outline).
- [ ] **Step 2:** The fallbacks: no WebGL 2, a still-only pack, a head that fails to load or doesn't match the still's size, a lost context → the still, `object-fit: cover`, breathing by `scale(1.006)` (Web Animations API, origin at the bottom), `mode = 'still'`, `problem` in plain words.
- [ ] **Step 3:** Screenshots (1456×900, SwiftShader) and read each: rest (against the portrait); full blink; half blink; `jawOpen` 0.3; smile; yaw 3.5° pitch 3°; resting; plus Review Focus 2, 4, 5 (mismatched still, `lose=1`, truncated head) and `nogl=1`. Ugly cases into the ledger and fixed.
- [ ] **Step 4:** Commit.

### Task 7: avatar.js, the behaviour and speech

**Files:**
- Modify: `harness/src/desk/avatar.js`, `harness/tools/avatar-preview.html`, `harness/tools/test-avatar.mjs`

**Interfaces:**
- Consumes: Task 6's object.
- Produces: the six states' profiles; `moment('smile')` 2 s, `moment('concern')` 2.5 s; `arrive()` (one glance: eyes to the viewer, brows up, 1.6 s; opens closed eyes for it); `speak({text, audioUrl})`: fetch, `decodeAudioData`, an `AnalyserNode`; the timeline stretched to the voiced span; jaw from the RMS; `speak({text, browser: true})`: `speechSynthesis`, word boundaries; the mouth only from the voice's start to its end; `speak` returns a Promise that resolves `true` at the end, `false` when stopped or replaced, and rejects when the voice can't play; `stop()`; `dispose()` (loop, listeners, audio, GL resources, the canvas).

- [ ] **Step 1: Failing node checks**: `buildTimeline("Your flight moved to 9:40.")` has words for each word and digit run, a sentence end, vowels 0.112 s and consonants 0.072 s; `stretchTimeline` to [0.2, 3.0] maps the first viseme to 0.2 and `dur` to 3.0; `voicedSpan` of 0.5 s silence, 1 s tone, 0.3 s silence → [0.5 ± 0.02, 1.5 ± 0.02]; `parseIni`.
- [ ] **Step 2:** Implement: the profiles (Rulings 7–9), 30 fps when resting or quiet, no frame while `document.hidden` (the loop stops and restarts on `visibilitychange`), reduced motion (Ruling 8), `ResizeObserver`.
- [ ] **Step 3:** Headless checks through the preview (`--autoplay-policy=no-user-gesture-required`): speak a generated WAV (the page samples `jawOpen` each frame: > 0.1 while the tone plays, 0 before and after); Review Focus 3 (a second speak resolves the first `false`; stop during the fetch; dispose mid-speech: no audio element or source left playing); screenshots of each state's face at a fixed time.
- [ ] **Step 4:** Commit.

### Task 8: Docs, the ledger, merge

**Files:**
- Modify: `harness/README.md` (a new "Avatar packs" section), `docs/superpowers/plans/2026-11-22-platform-build-ledger.md`, this plan (Rulings, Done)

- [ ] **Step 1:** README "Avatar packs": the pack's files and avatar.ini; fitting (what it checks, its messages); making an eyes-closed version with an image tool ("Close the eyes. Change nothing else."); `harness avatar check NAME`; the head file's layout; that Face Cap's license is unverified, so the base head and the butler aren't shipped yet.
- [ ] **Step 2:** Full Zig runs Debug and ReleaseSafe; cross builds and unit-builds; node checks; commit.
- [ ] **Step 3:** `git fetch origin`; merge `origin/harness-logins`; rerun all; commit; ledger entry with the numbers.

## Rulings

(Each: what — why — cost if wrong. Added to as they are made.)

1. head.bin gets a magic, a format version (1) and a tidy header; the prototype's unversioned head.bin isn't read, so the butler is refitted with fit.js — the spec says "versioned", and `avatar check` needs magic bytes — cost if wrong: none shipped; the prototype's file needs a refit (one run).
2. The base head is the same container with `kind: "base"`; it carries the model's world-space geometry, shape deltas, teeth and the 478 landmark surface points, not its eyes (the renderer's eyeballs are spheres sized from the photo) — cost if wrong: a later renderer wanting the model's eyes needs a new base head (one dev-page run).
3. Arrays the renderer never read are dropped (the eye meshes, teeth normals, uvs and lower-row flags) — cost if wrong: a head format v2.
4. Without a closed photo, the closed eyes are drawn at load from the still and the head's lid tones, not written as a file — the spec: "without it, the closed eyes are drawn" — cost if wrong: the drawn lids can't be looked at as a file.
5. A failed fit check rejects with a plain `message` and a `code` — cost if wrong: the page shows the message as is.
6. `speak` resolves `true` at the voice's end and `false` when stopped or replaced; rejects when the voice can't play, with no mouth movement — "the mouth moves only while the voice plays" — cost if wrong: the page catches a rejection.
7. needs you: eyes on you, brows a little up, an occasional small nod every 10–18 s (the spec lists "no nods" for urgent only; the owner asked for nodding when idle) — cost if wrong: a nod while an item waits.
8. Reduced motion: no drift, no nods (sentence-end nods too), no head following the gaze, no mouth or jaw shape outside speech (states' and moments' mouth parts dropped); blinks, saccades, the arrival glance (eyes only) and breathing kept — cost if wrong: a reduced-motion smile shows in the cheeks and eyes only.
9. quiet: the resting face, breathing slower and deeper, dimmed by `brightness(0.6)` on the canvas (CSS, eased) — cost if wrong: none found.
10. The still is decoded through an image element into a canvas for both the fit and the renderer, so an EXIF orientation is applied the same way in both — cost if wrong: none found.
11. Dev tools load three's addons and the basis transcoder from jsDelivr pinned at 0.170.0; they never ship — cost if wrong: the base-head page needs the network once.
12. Avatar names for `avatar check`: lowercase letters, digits, `-` and `_`, 1–64, first a letter or digit — cost if wrong: an upload named otherwise can't be checked by name.
13. Task order 1, 2, 4, 3, 5, 6, 7, 8 (the base-head page uses Task 4's packer) — cost if wrong: none.
14. avatar.js imports `readHead`, `loadImage` and `fit` from fit.js statically; fit.js loads MediaPipe only when fit() first runs — cost if wrong: fit.js (about 30 KB) is fetched with avatar.js.
15. The head's format version lives in the 16-byte preamble only, not also in the JSON — cost if wrong: none.
16. main.zig isn't `zig fmt`-clean at the base (0.17.1's fmt rewrites builtins across the file); only my lines are formatted — cost if wrong: none.
17. similarity2D and solveRbf take arrays of [x, y, z], solveRbf the unit (1/scale) too — cost if wrong: none.
18. The similarity's scale is the prototype's (the square root of the spreads' ratio) — cost if wrong: depth a few percent off the least-squares fit.
19. The closed photo's shift: the mean 2D distance in photo pixels of landmarks 0–467 farther than 0.8 eye-widths from each eye's centre; the butler's pair reads 5.7 px (the spec's "about 8" was the prototype's 3D mean); the limit stays 12 px — cost if wrong: a pair that moved 12–15 px in 3D terms passes.
20. Beyond the spec, the closed photo must be the still's size and have a face (both read "doesn't line up") and read as closed (both blink scores ≥ 0.5; its own line, "The eyes in the eyes-closed photo are open. Close the eyes and change nothing else.") — cost if wrong: a closed photo read as half open is refused, with a line not in the spec's table.
21. A CDP driver (tools/headless.mjs) instead of bare `--screenshot`, since the pages load wasm and fetch first — cost if wrong: none (dev only).
22. The base-head page's camera sits in front of the head's front, the far plane widened to match — cost if wrong: none.
23. The drawn lid's tone is the skin 6–22 px under the lower lid (the butler: about 125,100,100 against his real closed lids' 135,119,115; the band above the open lid is the socket's shadow, 52,34,37) — cost if wrong: a face lit from below gets lids a little bright.
24. A MediaPipe start failure and missing fit files share code `assets` and one line, "Fitting couldn't start: its files (desk-assets) are missing or blocked." — cost if wrong: a CSP mistake reads like missing files; the console has the cause.
25. The mask's blur is a box blur in JS, since WebKit's 2D canvas has no `filter` — cost if wrong: none.
26. (Security fix, the coordinator's) /csp-report stays tokenless but takes only `application/csp-report` bodies, 64 KB each, 1 MB in all — cost if wrong: a browser that sends reports as another type isn't logged.
27. (Spec change 793df7d) fit() resolves `{ ok, message?, code?, warnings[], faceWidth, closedUsed, files, report }` and doesn't reject; the refusals and warnings are the spec's table word for word, decided by pure photoFacts, judgePhoto and judgeClosed — cost if wrong: none (the coordinator's shape).
28. "Mouth open" = jawOpen ≥ 0.2 or the inner lips (13, 14) more than 2.5% of the face's width apart (teeth showing) — cost if wrong: lips slightly parted at rest are refused.
29. Face width = cheek to cheek (234–454) in photo pixels (the butler's 613); "soft" warns only when the face isn't refused as too small — cost if wrong: none.
30. A closed photo that fails refuses the whole fit, so the page keeps the head it had — cost if wrong: the owner removes the closed photo to refit the still alone.
31. "Turned" = the forward axis's angle from frontal, yaw as read and pitch less the landmarker's own 11° (overturns the line-of-sight measure first used, which read the butler 6.4° wide and 9.3° in a tall crop; now 0.9–1.7° in every crop) — cost if wrong: the 11° is calibrated on one face.
32. The prototype's pixel constants scale with the face's width over the butler's 613 px — cost if wrong: none for the butler (k = 1.0).
33. stretchTimeline maps the spoken part (first sound to last) onto the voice's voiced span — cost if wrong: none.
34. speak also takes onWord(i0, i1) for a caption — cost if wrong: an unused option.
35. The per-frame step is capped at 0.1 s (the prototype's 0.05), so slow frames keep real time — cost if wrong: a 100 ms hitch moves the face a bigger step.
36. The 30 fps cap is checked as frames at least 29 ms apart while resting — cost if wrong: none.

## Done

- Commits: the plan (7fa525b); avatar check and head v1 (a8cf5ad); three.js vendored, fetch script, dev server (c112fd5); fit.js's geometry, packer, reader (cddf85d); the base-head page and headless driver (23716ed); fit() in the browser and the butler fitted (2621c3b); the dev server's cross-site write fixed (58a3fde); the module, preview and the fit's table (3767d36); the border and the drawn lids (042536a); behaviour checks (0d8b6e4); a phone photo's size in avatar check (b931db7); docs.
- Checks: node tools/test-avatar.mjs, 18; behaviour-checks, 12; fit-checks on real images; the Zig numbers and the merge in the ledger.
- Ugly cases found and fixed, each also in the prototype: two catchlights per eye (the photo's reflection kept, a spot of the wet lid edge removed); lid landmarks fallen through the eye holes into the back of the skull (a red fleck in the open mouth); the photo's top border pulled into view at a few degrees of pitch. And: drawn closed lids that looked pasted on; a phone photo's size in avatar check; the turn read against the camera's axis or line of sight.
- Deferred: lip-sync with a real provider's audio and the browser voice heard by ear (checked by numbers in headless Chrome); fitting on the desk app's web views (WKWebView, WebView2, WebKitGTK) by the desk builders; the 11° frontal pitch calibrated on more faces; an own base head if Face Cap's license isn't cleared.
