# harness: the desk's base head from ICT-FaceKit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the avatar's base head (three.js's Face Cap sample, license unverified) with one made from USC ICT's ICT-FaceKit (MIT), committed at `harness/desk-assets/base-head.bin` with `base-head-NOTICE.txt`, and keep the fit and the renderer right on it.

**Architecture:** A node dev tool (`tools/make-base-head.mjs`) downloads only the ICT files it needs at a pinned commit (SHA-256 pinned in the tool), keeps the region the avatar needs, simplifies it with a multi-pose quadric half-edge collapse (vertices are kept, never moved, so every expression delta carries over exactly), maps ICT's expressions onto the 52 ARKit names, and writes a parts file; the browser page (`tools/make-base-head.html`, three.js vendored only) renders it, finds MediaPipe's 478 landmarks, snaps the eye outlines onto the mesh's eye openings and writes `base-head.bin` (format version 1, `"kind":"base"`). The tool runs the page itself through the dev server and headless Chrome. fit.js carries the new optional arrays (the teeth's and gums' jaw motion and kind, the mouth socket's flag) into the fitted head; avatar.js draws ICT's real upper and lower rows and gums instead of the reseated and mirrored Face Cap row.

**Tech Stack:** node (no packages) for the tool and checks; plain ES modules and three.js r170 (vendored) in the page; MediaPipe tasks-vision 0.10.14; Python 3 stdlib dev server; headless Chrome (SwiftShader); Zig 0.17.1 std only for `harness avatar check`.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md` ("How the head works", "The avatar pack", "Fitting a portrait", "Built-in avatars", "Constraints"), and the avatar's plan `docs/superpowers/plans/2026-11-25-desk-avatar.md` (head file v1, rulings 1–37).

## Global Constraints

- ICT-FaceKit at commit `da5f95a607f5e6b37755b38d3385d7f2853732e5`, MIT ("Copyright (c) 2020 USC Institute for Creative Technologies"); every OBJ carries the same MIT header. Only `FaceXModel/generic_neutral_mesh.obj` and the 53 expression OBJs the mapping uses are downloaded (no identity OBJs, no `cheekRaiser_*`, no `PupilDilate_*`); each checked by SHA-256 pinned in the tool. The download is never committed.
- Head file format stays version 1. Additions are optional arrays a v1 reader ignores; `avatar check` checks them when present.
- Base head ≤ about 4 MB; report the base's and a fitted head's bytes and vertex counts.
- Face Cap is read by no tool after this branch; its hash and mentions go; the docs say where the base head comes from.
- Never commit the butler's portraits, a fitted pack or facecap.glb. Scratch: `$SCRATCH/ict/` (`SCRATCH=/tmp/scratch`), never /tmp (headless runs with `TMPDIR=$SCRATCH/ict/tmp`).
- Don't touch appserver.zig's serving, build.zig's install or the release workflow (another builder ships `desk-assets/`).
- Zig std only; `zig build test --summary all` Debug and ReleaseSafe; cross `zig build` and `zig build unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `--cache-dir $SCRATCH/ict/zig-cache`. Base e9addff: unit 1560/1582, 22 skipped.
- Copy per CLAUDE.md: plain labels, no slogans.

## Review Focus

1. **A pack fitted on the Face Cap base** (the owner's local butler, before a refit): it still draws (no teeth.jaw / teeth.kind / head.part: teeth rigid, no lower row, interior by the old lip test) and `avatar check` still passes it. Test: test-avatar `an_old_head_without_the_new_arrays_still_reads`; Zig `a_head_without_the_optional_arrays_passes` (the existing good-pack test).
2. **An optional array of the wrong size or type** (a hand-edited or truncated head): `avatar check` names it; avatar.js shows the still with a problem rather than drawing garbage. Zig test `optional_arrays_are_checked_when_present`.
3. **The tool run twice** (or on another machine): byte-identical base-head.bin; a corrupted cached OBJ is fetched again; a hash mismatch stops with the file's name. Checked in Task 1 Step 6.
4. **The mouth opened wide** (jawOpen 0.6, speaking): no see-through to the backplate inside the mouth, teeth and gums seated, no floating roots. Comparison images, Task 5.
5. **The head turned to ±4° yaw and pitch**: no blank eyes, no seam at the head's edge or the jaw's underside. Comparison images, Task 5.

---

### Task 1: The ICT reader, the simplifier and the parts file (node)

**Files:**
- Create: `harness/tools/base-head-lib.mjs` (pure: OBJ parsing, the shape map, the cut, triangulation, the simplifier, compaction), `harness/tools/make-base-head.mjs` (CLI: fetch, build, run the page, write the output)
- Modify: `harness/tools/test-avatar.mjs` (checks for the pure parts)

**Interfaces:**
- `parseObj(text) → { pos: Float64Array, faces: number[][] }` (0-based).
- `ARKIT_FROM_ICT: { [arkit]: string[] }` — the ICT files summed for each of fit.js's 52 `SHAPES`; `[]` for a zero shape.
- `triangulate(faces, pos) → Uint32Array` (quads split on the shorter diagonal).
- `keepAbove(pos, cut) → (i) → bool` with `cut = { chin: [y, z], angle: [y, z] }`: keep a vertex above the line under the chin and the jaw angles (behind the angle, the angle's height).
- `simplify({ pos, idx, poses: Float64Array[], lock: Uint8Array, target }) → Uint32Array` (indices into the same vertices; a vertex count ≤ target where reachable).
- `compact(idx, n) → { map: Int32Array, kept: number }`.
- `make-base-head.mjs DATA OUT` → writes `DATA/desk-assets/base-head-parts.bin` (kind `base-parts`), then runs the page, then copies `DATA/desk-assets/base-head.bin` to OUT and prints sizes.

- [x] **Step 1: Failing checks** in test-avatar.mjs: `obj_faces_and_vertices_are_read` (a 2-quad OBJ with `f a/b c/d …` and comments); `every_arkit_name_maps_and_the_split_ones_sum` (52 keys, `browInnerUp` → `['browInnerUp_L','browInnerUp_R']`, `cheekPuff` likewise, `tongueOut` → `[]`, the rest to themselves); `quads_split_on_the_shorter_diagonal`; `the_cut_keeps_the_face_and_drops_the_throat`; `simplify_keeps_locked_vertices_and_reaches_its_target` (a 21×21 grid dome, its border locked, target 120: border all kept, ≤ 120 used, no triangle flipped, still one connected manifold); `simplify_keeps_where_a_pose_moves` (a flat grid whose pose bends one row: that row's vertices survive more than the flat rest); `compact_maps_used_vertices_in_order`.
- [x] **Step 2:** `node harness/tools/test-avatar.mjs` fails (no lib).
- [x] **Step 3: Implement** the lib. The simplifier: per-vertex quadrics summed over the poses (each pose's planes at that pose's positions), half-edge collapse u→v (v kept where it is), a heap of edge costs with lazy re-evaluation, rejected when: u or v is locked and u is the locked one, the link condition fails, a triangle flips (in the neutral pose or jawOpen's) or gets a min angle under 8°.
- [x] **Step 4: Implement** make-base-head.mjs's build: fetch each file into `DATA/ict-facekit/da5f95a…/` (kept when its hash matches, fetched again when not, stop on a mismatch after download); the head = Face (0–9408) + Head and neck (9409–11247) + Mouth socket (11248–13293), cut by `keepAbove`; locked: open-boundary vertices; poses: neutral and neutral + the deltas of jawOpen, mouthClose+jawOpen, eyeBlink_L, eyeBlink_R, mouthSmile_L, mouthSmile_R, mouthFunnel, mouthPucker, mouthRollUpper, mouthRollLower, browInnerUp, cheekPuff, noseSneer_L, noseSneer_R; target 4500 vertices. The mouth parts = Gums and tongue (14062–17038) + Teeth (17039–21450), not simplified, with their jawOpen deltas and kind (0 tooth, 1 gum or tongue). For the render only: both eyeballs (21451–24590) with an iris flag. Units: ICT's centimetres.
- [x] **Step 5:** checks pass; the tool's build step prints vertex and triangle counts.
- [x] **Step 6:** Commit.

### Task 2: The landmark page and the committed base head

**Files:**
- Modify: `harness/tools/make-base-head.html`, `harness/tools/make-base-head.js` (rewritten: no Face Cap, no CDN), `harness/tools/devserver.py` (`/desk/assets/` falls back to `harness/desk-assets/`), `harness/tools/fetch-desk-assets.sh` (comment)
- Create: `harness/desk-assets/base-head.bin`, `harness/desk-assets/base-head-NOTICE.txt`

**Interfaces:**
- Consumes: `base-head-parts.bin` (kind `base-parts`: `head.pos`, `head.idx`, `head.part` u8, `shape.NAME.pos` f32 ×52, `teeth.pos`, `teeth.idx`, `teeth.jaw`, `teeth.kind`, `render.eyes.pos`, `render.eyes.idx`, `render.eyes.iris`; meta `source`).
- Produces `base-head.bin`, kind `base`: the parts' arrays without `render.*`, plus `landmarks` (f32 478×3, NaN where none); meta `{ kind, vertices, shapes, source: { name: 'ICT-FaceKit', url, commit, license: 'MIT' }, units: 'cm' }`.

- [x] **Step 1:** The page renders the parts front-on (orthographic, 1024², skin tone, sclera and iris coloured), runs the landmarker, raycasts each landmark onto the head (the eyeballs count as surface only for the eye outlines' fall-through), then moves each of the 32 eye-outline landmarks (EYE_A, EYE_B) to the nearest point of its eye opening's boundary in the front view (z from the boundary). It logs hits and the eye snap's largest move, saves `base-head.bin` and `debug/base-render.png`.
- [x] **Step 2:** devserver: a missing `DATA/desk-assets/` file is served from `harness/desk-assets/`.
- [x] **Step 3:** Run `node tools/make-base-head.mjs $SCRATCH/ict/data-ict harness/desk-assets/base-head.bin`; expect ≥ 466 of the first 468 landmarks, 52 shapes, ≤ 4 MB; look at base-render.png (landmarks on the eyes, lips, brows). Run it again: same bytes.
- [x] **Step 4:** base-head-NOTICE.txt (first named NOTICE, renamed so it reads apart from the release archive's NOTICE.txt): ICT-FaceKit's copyright line and MIT text, the commit, the files used, how the file was made.
- [x] **Step 5:** Commit.

### Task 3: fit.js carries the new arrays

**Files:** Modify `harness/src/desk/fit.js`, `harness/tools/test-avatar.mjs`

**Interfaces:**
- `fitGeometry(base, P, W, H)` additionally writes, when the base has them: `teeth.jaw` (f32 3T: each mouth-part vertex's warped jawOpen motion), `teeth.kind` (u8 T), `head.part` (u8 N); meta `base` (the base's `source.name`, or `"unknown"`).

- [x] **Step 1: Failing checks:** `fit_geometry_carries_the_teeths_jaw_and_kind` (the synthetic base with a 3-vertex teeth jaw delta: teeth.jaw = the similarity's scale × delta; kind copied; head.part copied); `an_old_base_without_the_new_arrays_fits_as_before` (the tiny-head fixture unchanged byte for byte).
- [x] **Step 2:** fails; **Step 3:** implement; **Step 4:** passes.
- [x] **Step 5:** Commit.

### Task 4: `harness avatar check` checks the optional arrays

**Files:** Modify `harness/src/avatar.zig`

- [x] **Step 1: Failing Zig test** `optional_arrays_are_checked_when_present`: testHead with `teeth.jaw` of 3T f32 and `teeth.kind` T u8 and `head.part` N u8 passes; `teeth.jaw` with 3T−3 values → "head.bin's array teeth.jaw has 6 values; 3 teeth points need 9"; `head.part` as f32 → "head.bin's array head.part is f32; it should be u8".
- [x] **Step 2:** `zig build test -Dtest-filter=avatar` fails; **Step 3:** implement; **Step 4:** passes. The shape names' comment no longer says Face Cap.
- [x] **Step 5:** Commit.

### Task 5: avatar.js on the new head, the butler refitted, the comparison

**Files:** Modify `harness/src/desk/avatar.js`, `harness/tools/test-avatar.mjs`; scratch only: comparison images.

- [x] **Step 1:** The mouth parts: one mesh from `teeth.pos` with a morph target `teeth.jaw` driven by jawOpen; teeth ivory, gums and tongue their colour, both darkening with depth behind the incisors' front; heads without `teeth.jaw` keep their teeth rigid (Review Focus 1). The interior: `head.part` = 1 is inside wherever it shows; the old lip-polygon test stays for the inner lips and for old heads. The reseat, the mirrored lower row and `zLip`-based teeth constants go.
- [x] **Step 2:** Refit the butler on the ICT head (fit-pack.html) into `$SCRATCH/ict/data-ict`; the Face Cap fit stays in `$SCRATCH/ict/data-fc`.
- [x] **Step 3:** Screenshots of both at the frozen poses (resting closed, quiet, working, needs, urgent, speaking jawOpen 0.3 and 0.6, smile, blink 0.5, yaw ±4, pitch ±4), labelled side by side in `$SCRATCH/ict/compare/`. Look for: cracks at creases, a streak at the nostrils, light lines on the lids, blank eyes on a turn, a sliver of open eye when closed, teeth hidden or floating, a seam at the backplate. Re-derive what depended on Face Cap (the crease margin, the mouth zone, eyeball depth) only where the images show a defect; each change a ruling.
- [x] **Step 4:** A second face: a public-domain portrait (US government work) fitted the same way, a few poses.
- [x] **Step 5:** test-avatar, fit-checks, behaviour-checks pass; changes to checks only where they pinned Face Cap's geometry, named here.
- [x] **Step 6:** Commit.

### Task 6: Docs, the ledger, the full runs

**Files:** `harness/README.md` (Avatar packs, Fitting, What isn't shipped yet), `harness/tools/README`, the spec's lines naming Face Cap, `docs/superpowers/specs/2026-11-23-harness-gaps.md`, the ledger, this plan (Rulings, Done).

- [x] **Step 1:** Docs.
- [x] **Step 2:** Zig Debug and ReleaseSafe, the cross builds and unit-builds; node checks; headless checks.
- [x] **Step 3:** One fresh reviewer (opus) of the whole branch; one fix pass; ledger entry with the numbers; commit.

## Rulings

(Each: what — why — cost if wrong.)

1. ICT → ARKit: 49 names map one to one; `browInnerUp` = `browInnerUp_L` + `browInnerUp_R` and `cheekPuff` = `cheekPuff_L` + `cheekPuff_R` (their masks overlap like a partition: the sum's largest move equals one side's, 0.609 and 1.410 cm); `tongueOut` is a zero shape (ICT has none; Face Cap's was zero too); `cheekRaiser_L/R` and `PupilDilate_L/R` are not used — cost if wrong: a brow or cheek move twice as strong at the midline.
2. The kept region: Face + Head and neck + Mouth socket, cut under the chin and jaw angles (the throat and the neck go; the jaw's underside stays and fades by its normal, as Face Cap's did); the eye sockets, lacrimal, blend, occlusion and lash meshes go — the photo is projected from the front and the backplate carries the neck; the back of the head keeps the rotation pivot's depth at mid-head as before — cost if wrong: a seam under the jaw at a nod.
3. The simplifier keeps vertices in place (half-edge collapse), so the 52 deltas are ICT's own, never resampled; poses in its error keep the lips, lids and brows dense — cost if wrong: the dev tool is slow (seconds).
4. Teeth and gums aren't simplified, and gums and tongue ship with the teeth (they hide the roots; a wide mouth shows a gum line); they ride jawOpen by their own per-vertex deltas, not a rigid jaw vector — cost if wrong: about 0.3 MB in each head.
5. The eyeballs stay spheres textured from the photo (ICT's eyeballs are used only in the landmark render): the sphere's size from the photo already matches ICT's (radius 0.57 of the eye's width against 0.56) — cost if wrong: none found.
6. New arrays are optional additions to version 1 (`teeth.jaw`, `teeth.kind`, `head.part`); version 1 readers ignore them — cost if wrong: an old harness draws a new head with rigid teeth.
7. ICT's face region folds in behind each lid, so its open edge isn't the lid margin; that fold (120 vertices hidden from the front, reached from the opening) is dropped before simplifying — cost if wrong: none seen; a lid's inner rim can't show when it rolls.
8. The throat goes by the jaw's contour seen from the front (ICT's chin and extended jawline) and facing the camera (normal z > 0.25), not by a plane (a plane left the throat or cut the chin) — cost if wrong: a jagged fade under the jaw (the edge fade covers it).
9. The landmarks are found on ICT's full-resolution neutral head (with its neck and mouth socket, render only) and kept as points on it; a miss takes the nearest hit within 4 px; the 32 eye-outline points move radially onto the kept head's openings — cost if wrong: none (landmarks only steer the warp).
10. Old heads (no teeth.jaw) keep the reseated row and mirrored lower row; heads with teeth.jaw draw ICT's rows, gums and tongue as one mesh with a jawOpen morph — cost if wrong: ~25 lines kept for packs fitted on Face Cap.
11. The mouth parts are drawn only within an ellipse round the mouth in their rest positions (0.75 of its width across, 0.3 up, 0.9 down): ICT's gums reach up behind the nose, where deep creases are cut away — cost if wrong: a very long upper lip could lose a sliver of gum at a wide mouth.
12. The head fades over 30 px (×k) towards its outer open edge (not the eye openings), computed at load (edgeDistance) — the cut under the jaw showed as a sawtooth — cost if wrong: the jaw's underside fades a little sooner.
13. The upper teeth and upper gums come down 2 mm in the maker: ICT's incisors sit wholly behind the upper lip; 2 mm is a man's usual display at rest (Vig & Brundo 1978) — cost if wrong: a little more tooth when the lips part.
14. The mouth's inside counts only within the lip zone and not above 0.4 of the mouth's width over its centre (head.part = 1, or hidden at rest, as before): the socket and the nose's creases are hidden at rest and showed through the nostrils — cost if wrong: none seen.
15. A head with its own mouth parts keeps the true depth for the mouth's inside (0.9999 only for older heads): the lips then hide the teeth at their seam — cost if wrong: none seen.
16. ICT's teeth darken over 60 px behind the incisors' front (to 0.08), gums and tongue over 150 px (0.8 to 0.3): the premolars showed grey in the corners, then the floor went black — cost if wrong: a darker mouth on a very large face (scaled by k).
17. The simplifier weighs the face's silhouette band (in front, |normal z| < 0.45) 8× — the jaw's underside had gone coarse — cost if wrong: fewer vertices elsewhere (the same 4,500).
18. The ears are dropped from the head (outward of |x| 6.9 cm, y −2.5 to 7, z < 2) and carried by the backplate: ICT's ear folds opened as cracks on a turn — cost if wrong: an ear turns only with the backplate's depth-following.
19. Brow weights ×2 (browInnerUp) and ×1.5 (browOuterUp, browDown), capped at 1, in the states, moments, the glance and long words: ICT's brow shapes move about half and two thirds as far, and urgent must show raised brows — cost if wrong: stronger brows on a pack fitted on Face Cap. Other shapes keep the weights (ICT's smile is a little subtler than Face Cap's).
20. The maker seals the blink: each upper-margin point ends 0.3 mm past the lower margin, the lid above following over 4 mm — with the fold dropped, ICT's upper lids stopped up to 1.2 mm short on the inner half — cost if wrong: a shut lid 0.3 mm lower than ICT drew it.
21. (Overturned by the coordinator, second pass: rewritten, not kept failing.) The old drawn_lids_shut_without_a_step_in_the_lash_line started its "lash line" at the darkest row inside the photo's eye outline at the middle column, followed it ±2 rows, and called a second line 3–9 rows above it, nearly as dark, a doubled lid; it rendered at 0.57 of the photo's scale with the resting state's pose. Two things made it wrong: the shut eye is the drawn lash line plus the photo's own upper lid line (which the drawn lid leaves above it), so which one it started on decided the verdict; and the resting pitch moves the shut eye 5–13 px depending on the head's pivot depth, so a 3 px shift (Face Cap against ICT) flipped that choice, and at 0.57 a 2 px line reads lighter or darker by its sub-pixel place. It passed Face Cap by luck: started on the lash line, it failed Face Cap too. The new check finds the drawn lash line by the path that drew it (closedLidSpan, shared with drawClosedEyes: 0.9 of the way down the lid), offset at the eye's middle within 8 px, then followed within 5 px; a step is a jump of 3 px or more between neighbouring columns across the middle 80% of the eye; no step is allowed. It renders at about the photo's scale with the head held at its rest pose, for gaze straight, up and down, with and without reduced motion, and once with the lid broken on purpose (a test-only debug.lidBreak: the outer half 4 px down), which must show a step. Face Cap- and ICT-fitted packs give the same numbers (0 steps; the break 1 step of 4 px); with every lid broken it fails — cost if wrong: a doubled line (not a step) on drawn lids isn't looked for any more.
22. The comparisons draw the Face Cap fit with e9addff's renderer (exported to scratch), the ICT fit with this branch's — cost if wrong: none.
23. The second test faces are US Army official portraits (public domain, Wikimedia Commons), in scratch only; every NASA astronaut portrait tried was refused by the fit (teeth or a turn) — cost if wrong: none.
24. The eyeballs stay spheres (Ruling 5); the frontal-pitch calibration (11°) stays: it reads the photo, not the head — cost if wrong: none.

25. (Second pass) The notice is `harness/desk-assets/base-head-NOTICE.txt`, not `NOTICE`: the release packing copies every *NOTICE*/*LICENSE* beside base-head.bin next to its own NOTICE.txt — cost if wrong: none.
26. (Second pass) Shut lips hide the mouth's parts: the pale line along the closed lips was ICT's lower incisors (their tops 5.6 mm above the upper ones' tips, right behind the lips' hairline seam) and the 2 mm-lowered upper teeth. The mouth's parts are shaded by how far the lips part (the inner lips' middle gap from the shape weights, 3 to 15 px ×k), and the upper teeth's 2 mm is an optional array, `teeth.show` (f32, warped like `teeth.jaw`, checked by `avatar check`), applied by the same opening; Ruling 13's drop stays, applied only as the lips part. Scaling the drop by jawOpen alone left the lower row showing. Visemes that part the lips with little jaw (S, E, I) still show teeth — cost if wrong: a shape that parts only the lips' corners keeps the teeth dark.
27. (Second pass) The chin's lower edge at jawOpen 0.6: the cause was the neck cut's sawtooth (vertex-by-vertex removal on ICT's quads with an irregular facing threshold), out of sight at rest, turned into view as the jaw drops; the 30 px edge fade (Ruling 12) only softened it into wisps. The maker now cuts triangles (half-quad steps) and smooths the cut by a majority of neighbours (two passes), and the head fades over 60 px (×k) to the cut — cost if wrong: the jaw's underside fades a little sooner (out of sight at rest).
28. (Second pass) The new checks read the head itself, not the photo: closed_lips_show_no_teeth compares a frame with and without the mouth's parts (test-only debug.noMouthParts); the_chins_lower_edge_stays_smooth_as_the_jaw_opens reads the head's opacity alone (test-only debug.alphaView) — photo-based measures (the still's seam, edge steps, bends, streaks) were dominated by the smile's lip shift, stubble and the collar and didn't separate the heads — cost if wrong: a defect seen only in colour at the chin isn't caught there.
29. (Second pass) The chin check holds the head at its rest pose and judges jawOpen 0.3 and 0.6 (at most 6 turning points of the edge where it starts to show; before the fix 19 and 17, after 5 and 5); at rest the head shows the photo's own pixels over the backplate's, so its edge can't be seen and 0 is judged by eye — cost if wrong: none seen.
30. (Third pass) The lips' gap that shows the mouth's parts (Ruling 26) is read from one vertex on each lip, told apart by the jaw: among the lips' front vertices (not the mouth's inside) within 12 px (×k) of the inner lips' middle, the upper is the one jawOpen moves least, the lower the one it moves down most. The second pass took the front-most vertex within 6 px of landmarks 13 and 14 — one spot on a shut mouth — so on two faces both picks were one lip (or one vertex), the gap never opened and their open mouths stayed dark. Checks on every test face: the_open_mouth_shows_its_teeth (jawOpen 0.3 and 0.6, the parts drawn lit) and closed_lips_show_no_teeth — cost if wrong: none seen on three faces.
31. (Third pass) closed_lips_show_no_teeth judges heads with their own mouth parts only: a head fitted on Face Cap draws its reseated row through its own parted neutral lips, and stays pixel-identical to e9addff's renderer at rest — cost if wrong: an older head's teeth at rest aren't judged.
32. (Fourth pass) The mouth's parts are drawn no higher than the photo's upper-lip top (the highest point of the outer lip outline) plus half the lip's height, in place of a fixed 0.3 of the mouth's width (Ruling 11). Cause of the black arc under the nose tip (two faces with short upper lips, resting pose): the nose's underside is hidden at rest, so the head cuts it away; at the resting 2.6° pitch the gaps open, and the upper gums, inside the old 0.3 zone on those faces and drawn at 10% while the lips are shut (Ruling 26), showed through as near-black. Evidence: the arc is gone with the mouth's parts left out (test-only debug.noMouthParts), and the head's opacity (debug.alphaView) has its gaps along the nose's underside. Check no_near_black_round_the_nose_at_rest (resting state and pose, every test face; between the nose tip and the upper lip, pixels darker than 30 and than the photo's darkest there less 10): RED mg 14, Shelton 7; GREEN 0, 0. It can't see the butler (its photo is near-black under the nose: darkest 10) — cost if wrong: a gum line hidden behind a very lifted upper lip (more than half the lip's height) shows the mouth's inside instead.
## Done

- Commits: b5ff7d4 (the maker's lib and CLI), bb901d3 (the landmark page, the committed base head and its notice (now base-head-NOTICE.txt), the dev server's fallback), 87b38e9 (fit.js's optional arrays), 0d31499 (avatar check), c06941a (the renderer on ICT), 72cf6f0 (sealed blinks), ce9cd81 (docs), e716d11 (the mouth below the nose), 2077a4f (rulings), 18fa277 (review fixes), then this Done and the ledger.
- Sizes:
  - base head: 3,222,448 bytes; 4,500 vertices, 8,576 triangles; mouth parts 7,389 vertices, 14,504 triangles; 478 landmarks.
  - fitted butler: 3,327,880 bytes.
  - Face Cap, for comparison: base 1,766,672 bytes, fitted butler 1,844,840 bytes; 2,694 vertices.
- Checks:
  - node test-avatar.mjs: 36.
  - fit-checks: as expected.
  - behaviour-checks: 18 of 19 (Ruling 21).
  - avatar check: passes the ICT-fitted, drawn and Face Cap-fitted packs, and names a short head.part.
  - Zig and cross builds: in the platform ledger.
- Comparisons (Face Cap fit by e9addff's renderer beside the ICT fit): 14 poses of the butler and 9 of each of two public-domain portraits, in the scratch space.
- Second pass (the coordinator's four items):
  - Commits: 60fda6b (base-head-NOTICE.txt), 03b07a4 (shut lips hide the teeth; teeth.show), d25b3ed (a smooth chin as the jaw opens), 094e4d0 (the drawn-lids check rewritten).
  - Base head: 3,311,792 bytes, 4,500 vertices, 8,684 triangles. A fitted head is 3,417,240 bytes.
  - Checks:
    - node: 37.
    - behaviour-checks: 21 of 21. Once, 20 of 21: the_states_show read urgent's eyeWide 0.03 during a blink; two reruns 21 of 21.
    - fit-checks as expected.
    - avatar check good on the ICT-fitted and Face Cap-fitted packs.
  - Zig, Debug and ReleaseSafe: 1561/1583, 22 skipped; smoke all ok. Cross builds and unit-builds ok.
- Third pass (two faces' open mouths dark): 43cb9b4 (the lips told apart by the jaw; checks on every test face). behaviour-checks 22 of 22 with faces=butler,mil-official-portrait-of-mg,mil-general-henry-shelton-of; node 37; Debug and ReleaseSafe 1561/1583 (22 skipped), smoke all ok; cross builds ok.
- Fourth pass (the black arc under the nose tip): the mouth's parts capped at the upper lip's top; check no_near_black_round_the_nose_at_rest (Ruling 32).
