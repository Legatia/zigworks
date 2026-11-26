# harness: the fit files and an empty stage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fresh install draws a deliberate stage and can fit a portrait: `/desk/assets/…` is served from the data folder, beside the binary, or the app bundle; harness's release archives carry `desk-assets/`; with no avatar the stage shows an outline and [Add a portrait]; with no fit files Settings says so and turns the upload off. Also the desk voice's known minors in the Settings handlers.

**Architecture:** `appserver.zig` learns a list of asset places (`assetDirs`) built from the data folder and harness's own folder (`DeskOptions.exe_dir`, which core passes from `c.exe_dir`), and serves a file from the first place that has it with the same no-follow walk as today. The same module answers whether the fit files are all there (`fitFilesThere`), which core puts in the state JSON's settings, with the folder they go in. The page reads that: no avatar → an inline-SVG bust and a button; no fit files → a line, the folder, and the upload controls in a disabled fieldset. A shell script packs `desk-assets/` for the release job and runs locally against a temp folder.

**Tech Stack:** Zig 0.17.1, std only; the desk is plain HTML/CSS/JS in the binary; POSIX sh for the packing script; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, "First run, and the desk alone (added 2026-11-25)" › "The fit files and an empty stage" (as of 3ceecf8, binding).

## Global Constraints

- Zig `~/.local/zig/zig-aarch64-macos-0.17.1/zig`, std only, no new dependencies; the desk's JS stays plain modules.
- Never committed: MediaPipe's files, any `base-head.bin`, `facecap.glb`, any portrait or avatar pack.
- Not edited (other builders): `src/desk/fit.js`, `src/desk/avatar.js`, `tools/`, `desk-assets/`, existing NOTICE files, `runCmd`, `initCmd`/`initText`, config defaults and time handling, `desk-app/`.
- Serving: same 20 MB cap, ETag, `Cache-Control: private, max-age=86400`; no path may leave its folder; links inside a place are never followed (as today).
- Copy: "Add a portrait"; "The fit files aren't installed."; plain labels, no slogans, no all-caps labels, no decorative arrows; how to get the files goes behind the existing "i" (`.info > button`).
- Runs use a temp `HARNESS_HOME`, `HARNESS_STORE`, and a `HERMES_HOME` that doesn't exist; no real provider API, only `harness-fake`.
- Verification from `harness/` with `--cache-dir ../../zc-files`: `zig build test --summary all` Debug and `-Doptimize=ReleaseSafe`; `zig build -Dtarget=T` and `zig build unit-build -Dtarget=T` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl.

## Review Focus

1. **A file in a later place reached through a link or `..`** (a symlink inside `desk-assets/` beside the binary pointing at `~/.ssh`, `/desk/assets/../../MacOS/harness`): 404, as in the data folder (`desk_assets_never_leave_their_places`, Task 1; smoke, Task 1).
2. **A partial install** (MediaPipe's files there, no `base-head.bin`, or only some wasm files): the desk must not claim the fit files are there and then fail at fit time (`fit_files_are_there_only_when_all_are`, Task 2).
3. **The chosen avatar's folder deleted while the desk is open, or the default `butler` with no pack**: the outline and [Add a portrait], never a black box (`the_avatars_listed_are_the_packs_there`, Task 2; the page, Task 3, checked in a browser).
4. **Two settings changes at once** (Voice typed, then the provider changed, which fires two POSTs): both kept, the later kind's clearing applied once (`desk_settings_written_one_at_a_time`, Task 4).
5. **The release run with a hash mismatch or no base head**: the job fails with one line naming what is wrong, never an archive without the files (`pack-desk-assets.sh` run locally with a bad hash stand-in and with no base head, Task 5).

---

### Task 1: Serve `/desk/assets/…` from three places

**Files:**
- Modify: `harness/src/appserver.zig` (DeskOptions, Server fields/start/deinit, `desk()`, helpers, tests)
- Modify: `harness/src/core.zig` (~5528: pass `.exe_dir = c.exe_dir`)
- Modify: `harness/src/fake.zig`, `harness/src/fake_main.zig` (`harness-fake --desk-get HOME PATH...`)
- Modify: `harness/scripts/smoke.sh` (a desk run from a copied binary)

**Interfaces:**
- Produces: `DeskOptions.exe_dir: []const u8 = ""`; `pub fn assetDirs(a: Allocator, home: []const u8, exe_dir: []const u8) ![]const []const u8` → `[home/desk-assets]` plus, when `exe_dir` is set, `exe_dir/desk-assets` and `dirname(exe_dir)/Resources/desk-assets`; `fn deskFileKind(io, a, dir, rel) !?u64` (size when `rel` is a plain file reached without links, null otherwise); `pub fn fitFilesThere(io: Io, a: Allocator, dirs: []const []const u8) bool` (Task 2 uses it).
- `harness-fake --desk-get HOME PATH...`: enters like `--desk`, then prints one line per PATH: `PATH STATUS BODY` (body up to 60 bytes, newlines as spaces).

- [ ] **Step 1: failing tests** in appserver.zig: `desk_assets_come_from_the_first_place_that_has_them` (a fixture with `exe_dir = ROOT/app/Contents/MacOS`; `a.txt` in data, beside and bundle → data's; `b.txt` beside and bundle → beside's; `c.txt` bundle only → bundle's, with `cache-control: private, max-age=86400` and its etag; 304 on If-None-Match; no exe_dir → only data's, `c.txt` 404), `desk_assets_never_leave_their_places` (`/desk/assets/../MacOS/x.txt`, `%2e%2e`, a symlink in the bundle place to a file outside → 404; a 20 MB + 1 file beside → 413).
- [ ] **Step 2: run, see them fail** (`zig build unit -Dtest-filter=desk_assets`).
- [ ] **Step 3: implement**: the server keeps `asset_dirs` (owned); `desk()` tries each for `/desk/assets/`; the first place whose walk finds the file wins; TooBig in a place answers 413 there. Core passes `exe_dir`.
- [ ] **Step 4: tests pass.**
- [ ] **Step 5: smoke**: copy `$H` to `$T/fitapp/Contents/MacOS/harness`, files in the three places plus a link to `config.ini` in the bundle place; run it on a data folder of its own (Telegram from the stand-in, no pairing needed); `--desk-get` checks order, a removal falling through, `..` and the link.
- [ ] **Step 6: commit.**

### Task 2: The state says whether the fit files are there and which avatars are

**Files:** Modify `harness/src/core.zig` (`deskSettingsJson`, `deskAvatars`, tests).

**Interfaces:**
- Consumes: `appserver.assetDirs`, `appserver.fitFilesThere`, `appserver.fit_files` (the 6 MediaPipe paths `fetch-desk-assets.sh` names and `base-head.bin`).
- Produces in `settings`: `"fit_files":BOOL,"fit_dir":"DATA/desk-assets"`; `avatars` lists `butler` only when `avatars/butler/` is a folder.

- [ ] **Step 1: failing tests**: `desk_state_says_whether_the_fit_files_are_there` (none → `"fit_files":false` and `fit_dir` the data folder's `desk-assets`; all 7 in data → true; base head moved beside a fake exe_dir → still true), `fit_files_are_there_only_when_all_are` (six of seven → false), `the_avatars_listed_are_the_packs_there` (no `avatars/` → `"avatars":[]`; `{"avatar":"butler"}` refused with no pack). `desk_settings_write_and_reload` changes on purpose: `"avatars":["me"]`.
- [ ] **Step 2: fail. Step 3: implement. Step 4: pass. Step 5: commit.**

### Task 3: The page: an empty stage and no fit files

**Files:** Modify `harness/src/desk/index.html`, `desk.css`, `desk.js`; test in `appserver.zig` (`the_desk_page_draws_an_empty_stage_and_says_when_the_fit_files_are_missing`).

- Empty stage: `#emptyStage` in `.frame` (shown until an avatar draws): `<button id="addPortraitBtn" class="btn cut-s">Add a portrait</button>` (hidden until known there is no avatar) above an inline SVG bust (`viewBox="0 0 400 400"`, head ellipse, neck and shoulders path, `fill="none"`, stroke from `--ring` mixed with `--line-hi`, `vector-effect: non-scaling-stroke`); a 0.6% breathing scale that `prefers-reduced-motion` and the page's `reducedMotion` stop.
- `showStage()`: no avatar when `settings.avatars` doesn't include `settings.avatar`, or `createAvatar` throws → the avatar disposed, `#emptyStage` shown with the button.
- [Add a portrait]: `renderSettings()`, `showModal()`, `#ownAvatar` scrolled into view, focus on `#upName`, or on `#fitMissing` when the files aren't there.
- No fit files: `#fitMissing` (tabindex -1): "The fit files aren't installed." + "They go in `<fit_dir>`." + an "i" bubble on where they come from; the upload rows inside `<fieldset id="upControls" class="bare">` set `disabled`.
- Avatar choices with none: "No avatars yet."
- [ ] Steps: failing page test (strings and ids above) → implement → pass → commit. Then Task 6's browser check.

### Task 4: The voice setting's minors (each test first)

**Files:** Modify `harness/src/core.zig` (`deskSettings`, `deskSettingsJson`, tests), `harness/src/voice.zig` (`Speaker`), `harness/src/fake.zig` (gemini script `"body"`).

- [ ] `a_second_switch_clears_by_what_was_written`: config.ini says `speak = openai`, `speak_voice = nova` by hand (cfg still gemini, not reloaded); POST `{"speak":"gemini"}` → no `speak_voice` in the file, cfg's voice "". Fix: the kind before is the file's `[desk] speak` resolved against the file's own providers (`config.parse` of the text), the live cfg when it doesn't parse.
- [ ] `a_settings_post_writes_only_the_key_it_names`: `{"speak_model":5,"speak_voice":"Charon"}`, `{"speak":"off","speak_voice":"x"}`, `{"avatar":7}` → 400 and the file unchanged. Fix: exactly one known key, its value a string.
- [ ] `desk_settings_written_one_at_a_time`: 2 threads × 20 POSTs (`speak_model` m0..m19, `speak_voice` v0..v19) → the file ends with `m19` and `v19`. Fix: `setup_mutex` held over read-write-apply; the cfg reads in `deskSettings` and `deskSettingsJson` under `settings_mutex`.
- [ ] `googles_bad_key_is_one_line`: a 400 with Google's body (`"message":"API key not valid. Please pass a valid API key."`, `"reason":"API_KEY_INVALID"`) → KeyRefused, "gemini refused the key stored as gemini."; any other 400 reads "gemini refused the request: MESSAGE" (not "Rejected …").
- [ ] `a_model_with_models_prefix_is_the_same_model`: `models/gemini-3.8-flash-lite-tts` → path `/v1beta/models/gemini-3.8-flash-lite-tts:generateContent`.
- [ ] Commit after each green.

### Task 5: Release archives carry `desk-assets/`

**Files:** Create `harness/scripts/pack-desk-assets.sh`, `harness/licenses/mediapipe-LICENSE.txt` (MediaPipe v0.10.14's LICENSE, verbatim), `harness/licenses/desk-assets-NOTICE.txt`; modify `.github/workflows/release.yml`.

- `sh scripts/pack-desk-assets.sh DEST` (run from `harness/`): fails first, with one line, when `desk-assets/base-head.bin` is missing; runs `tools/fetch-desk-assets.sh DEST` (its hash check fails the script); copies `base-head.bin` and any `LICENSE*`/`NOTICE*` beside it in `harness/desk-assets/`; adds `DEST/LICENSE-mediapipe.txt` and `DEST/NOTICE.txt`; lists the 7 required files and fails if one is missing. `FETCH=path` overrides the fetch script (for the local mismatch check only).
- Workflow: for `harness`, `sh scripts/pack-desk-assets.sh "$pkg/desk-assets"` before archiving, both branches (zip and tar).
- [ ] Run locally: a temp checkout copy with the local base head (licence-held, temp only) → listing; without it → the one line, exit 1; a FETCH stand-in that exits 1 → exit 1. Commit.

### Task 6: README, verification, screenshots, review

- README (Desk / Avatar packs): where the fit files are looked for, in order; the archive's `desk-assets/`.
- The suites, cross builds, smoke; screenshots of the empty stage and the no-fit-files Settings, light and dark emulation, 900 px and 1456 px wide (scratchpad `files-shots/`), read by eye.
- One fresh reviewer over the branch diff with the spec; fixes for Critical/Important test-first.

## Rulings

- Ruling 1: the desk has one look: dark (`color-scheme: dark`); it doesn't follow the system's light or dark setting. The empty stage and the note were checked under both `prefers-color-scheme` values and draw the same; the outline takes its colours from the tokens (`--ring`, `--line-hi`) — cost if wrong: a light look, when made, needs its own token values (nothing in the outline is hard-coded).
- Ruling 2: Settings lists only the avatar packs there are; the held butler only when `avatars/butler/` is there, and choosing it otherwise is refused. A fresh install (`avatar = butler`, no pack) shows "No avatars yet." and the empty stage — cost if wrong: when the butler ships beside the binary, `deskAvatars` and `/desk/avatars/` must look there too (one place each).
- Ruling 3: a place that has the file but over 20 MB answers 413; it doesn't fall through to the next place — cost if wrong: a broken oversized copy in the data folder hides a good one beside the binary.
- Ruling 4: "the fit files are there" means each of the seven (MediaPipe's six, the no-SIMD pair included, and `base-head.bin`) is found, as the server would serve it, in one place or another; stats only — cost if wrong: files of two versions split across places would count as installed (the fetch pins one version, so only a hand-made mix).
- Ruling 5: the folder named is the data folder's `desk-assets/`, in full (the one the owner can write); where the release and the app put them is behind the "i" — cost if wrong: one line.
- Ruling 6: the outline shows from the first paint until an avatar draws, so the stage is never an empty black box, even while a pack loads; [Add a portrait] shows only once there is known to be none — cost if wrong: an owner with an avatar sees the outline for the moment the head loads.
- Ruling 7: a listed pack that fails to load gives the empty stage and the button, and isn't tried again at every state refresh (it was); a new choice, a fit, or a reload tries again — cost if wrong: a pack repaired on disk shows after a reload.
- Ruling 8: [Add a portrait] opens Settings scrolled to "Your own avatar" with the focus on Name; without the fit files, on their note — cost if wrong: none.
- Ruling 9: a settings POST takes exactly one of avatar, speak, speak_model, speak_voice, with a string value; JSON null counts as absent — cost if wrong: none known.
- Ruling 10: the kind a new `speak` is compared with is the one config.ini names (parsed with its own providers); a file that doesn't parse falls back to what harness runs with — cost if wrong: none (the file is what the next reload applies).
- Ruling 11: the desk's settings writes hold `setup_mutex` (as setup's answers do) for read, write and apply; the live settings they and the state's settings read are read under `settings_mutex` — cost if wrong: a state request waits while a /reload runs.
- Ruling 12: Google's 400 is a bad key when its `error.details[].reason` is `API_KEY_INVALID`; it then reads as any refused key. Every other 400 or 422, either format, reads "NAME refused the request: MESSAGE." — cost if wrong: a gateway that words a bad key otherwise reads "refused the request: …" with its own words.
- Ruling 13: a leading `models/` is dropped from a Gemini-format model; an OpenAI-format model is sent as given — cost if wrong: none.
- Ruling 14: the release packing fails unless `harness/desk-assets/` holds a `*LICENSE*` or `*NOTICE*` file beside `base-head.bin` (ICT-FaceKit's MIT notice must travel with it); every such file is copied into the archive's `desk-assets/` — cost if wrong: if the base head's notice lands elsewhere (harness/NOTICE), the release stops with that line until one is placed beside it or the script's pattern changes.
- Ruling 15: MediaPipe's licence is committed (`licenses/mediapipe-LICENSE.txt`: its repository's LICENSE at v0.10.14, Apache 2.0 plus the UTF-8 code's notice; SHA-256 8707eef0…0ed8), not fetched at release; MediaPipe has no NOTICE file; `licenses/desk-assets-NOTICE.txt` names each file, version, source and licence — cost if wrong: a MediaPipe version bump needs the licence checked again.
- Ruling 16: the Windows zip gets `desk-assets/` too (packed before the zip and tar branches part) — cost if wrong: about 23 MB more per Windows download.
- Ruling 18 (final review): `../Resources/desk-assets/` is looked in only when the binary's folder is an app bundle's `Contents/MacOS`, not for every binary (`/usr/local/bin` would have meant `/usr/local/Resources`) — cost if wrong: a bundle laid out otherwise isn't searched.
- Ruling 19 (final review): the archive's `THIRD-PARTY-mediapipe.txt` names the libraries found in MediaPipe's WebAssembly by their strings (TensorFlow Lite, Abseil, ruy, FlatBuffers, OpenCV: Apache 2.0; XNNPACK and Protocol Buffers: BSD 3-Clause; FP16: MIT; Eigen: MPL 2.0 with where its source is; Emscripten's runtime: MIT/NCSA), with the BSD and MIT texts from each project's current repository — cost if wrong: a library linked without a string naming it, or an older copyright line, is missing from it; checking against MediaPipe 0.10.14's build files is left.
- Ruling 17: `avatar.dispose()` replaces the page's call to `destroy()`, which the avatar module never had, so a switched-away avatar now lets its WebGL context go — cost if wrong: none.

## Done

- Base (3ceecf8), Debug: unit 1560/1582 (22 skipped); smoke all ok but for this branch's 3 new checks (written before the code).
- Head, Debug and ReleaseSafe: unit 1573/1595 (22 skipped), smoke all ok (the 3 new fit-file checks among them). Cross builds and unit-builds for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl ok.
- Seen once under load (screenshots and builds beside the suite): core `a_quick_reply_counts_once_and_not_after_a_restart` timed out; 5/5 alone and green in both later full runs; this branch doesn't touch it.
- `desk_settings_written_one_at_a_time` passed before its fix too: the lost update isn't reproducible on demand; kept as a guard.
- The packing run locally from a temp copy holding the licence-held base head (never committed): a real fetch; kept files by hash; a changed pinned hash (exit 1, the fetch's own line); no base head, no notice beside it, a colliding NOTICE.txt, a failing fetch (exit 1, one line each). The archive laid out as the workflow does (aarch64-macos, ReleaseSafe). The workflow itself is unrun (it needs a tag).
- Checked in headless Chrome against a throwaway harness and the stand-in: the empty stage and the no-fit-files Settings at 820 and 1456 px, under light and dark emulation; reduced motion stops the breathing; a pack that fails to load gives the outline; with the fit files, an upload and fit in the page loads one avatar (two before the review fix).
- Final review (fresh reviewer): no Critical; 3 Important fixed (d4ae0e0); its 6 Minor all fixed there too.
- Left: replies aren't read aloud while there's no avatar (speech plays through the avatar module); THIRD-PARTY-mediapipe.txt not checked against MediaPipe 0.10.14's build files; the desk app's bundle doesn't carry desk-assets/ yet (desk-app/ is another builder's).
