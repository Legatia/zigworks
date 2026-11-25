// Checks for the avatar's pure JS (fit.js and avatar.js), run with node:
//
//   node tools/test-avatar.mjs                  run the checks
//   node tools/test-avatar.mjs --write-fixture  also write src/testdata/avatar/tiny-head.bin
//
// The browser parts (WebGL, MediaPipe, canvas) are checked through the
// preview page instead (tools/README).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as fit from '../src/desk/fit.js';
import * as av from '../src/desk/avatar.js';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const fixturePath = here('../src/testdata/avatar/tiny-head.bin');

let n = 0, failed = 0;
function check(name, fn) {
  try { fn(); n++; console.log('ok ' + n + ' ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + '\n  ' + (e && e.stack || e)); }
}
const eq = (a, b, msg) => { if (a !== b) throw new Error((msg || '') + ' expected ' + JSON.stringify(b) + ', got ' + JSON.stringify(a)); };
const near = (a, b, tol, msg) => { if (!(Math.abs(a - b) <= tol)) throw new Error((msg || '') + ' expected ' + b + ' ± ' + tol + ', got ' + a); };
const has = (s, sub) => { if (!String(s).includes(sub)) throw new Error('expected "' + sub + '" in "' + s + '"'); };
const throwsWith = (fn, sub) => { try { fn(); } catch (e) { has(e.message, sub); return; } throw new Error('expected a throw with "' + sub + '"'); };

// a deterministic random
function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

const SHAPES = fit.SHAPES;

/** A made-up base head: a k×k grid on a dome, the 52 shapes (two that move),
 *  a teeth triangle and 478 landmarks on the surface (a few missing). */
function syntheticBase(k = 9) {
  const N = k * k, pos = new Float32Array(N * 3);
  const dome = (x, y) => 3 - 0.1 * (x * x + y * y);
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) {
    const x = -4 + (8 * c) / (k - 1), y = 4 - (8 * r) / (k - 1);
    pos.set([x, y, dome(x, y)], (r * k + c) * 3);
  }
  const idx = [];
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) {
    const a = r * k + c, b = a + 1, d = a + k, e = d + 1;
    idx.push(a, d, b, b, d, e);
  }
  const shapes = {};
  for (const s of SHAPES) shapes[s] = new Float32Array(N * 3);
  for (let c = 0; c < k; c++) shapes.jawOpen[((k - 1) * k + c) * 3 + 1] = -1; // the bottom row drops
  shapes.eyeBlink_L[(k + 1) * 3 + 1] = -0.5;
  const rnd = rng(7), lm = new Float32Array(478 * 3);
  for (let i = 0; i < 478; i++) {
    const x = -3.8 + 7.6 * rnd(), y = -3.8 + 7.6 * rnd();
    lm.set(i % 97 === 5 ? [NaN, NaN, NaN] : [x, y, dome(x, y)], i * 3);
  }
  return {
    meta: { kind: 'base', vertices: N, shapes: SHAPES },
    arr: {
      'head.pos': pos, 'head.idx': new Uint16Array(idx), 'teeth.pos': new Float32Array([0, -2, 2, 1, -2, 2, 0.5, -2.5, 2]),
      'teeth.idx': new Uint16Array([0, 1, 2]), landmarks: lm,
      ...Object.fromEntries(SHAPES.map((s) => ['shape.' + s + '.pos', shapes[s]])),
    },
  };
}

/** The photo's landmarks as a similarity of the base's: scale s, angle th, offset. */
function similarLandmarks(base, s, th, ox, oy) {
  const lm = base.arr.landmarks, out = [];
  for (let i = 0; i < 478; i++) {
    const x = lm[i * 3], y = lm[i * 3 + 1], z = lm[i * 3 + 2];
    if (Number.isNaN(x)) { out.push([1000 + i, -500 - i, 0]); continue; } // the photo has every point
    out.push([ox + s * (Math.cos(th) * x - Math.sin(th) * y), oy + s * (Math.sin(th) * x + Math.cos(th) * y), s * z]);
  }
  return out;
}

const baseOf = (b) => ({ meta: b.meta, arr: (name) => b.arr[name] });

// ---------- the container ----------
check('pack_and_read_round_trip_every_type', () => {
  const arrays = {
    'a.f32': new Float32Array([1.5, -2, 3]), 'b.i16': new Int16Array([-32767, 0, 32767]),
    'c.u16': new Uint16Array([0, 65535]), 'd.u32': new Uint32Array([1, 4294967295]), 'e.u8': new Uint8Array([1, 2, 3, 4, 5]),
  };
  const buf = fit.packHead({ kind: 'head', vertices: 1 }, arrays);
  const h = av.readHead(buf);
  eq(h.meta.kind, 'head'); eq(h.version, 1);
  for (const [name, ta] of Object.entries(arrays)) {
    const got = h.arr(name);
    eq(got.constructor.name, ta.constructor.name, name);
    eq(JSON.stringify([...got]), JSON.stringify([...ta]), name);
  }
  const bytes = new Uint8Array(buf);
  eq(String.fromCharCode(...bytes.slice(1, 5)), 'HEAD');
  const hlen = new DataView(buf).getUint32(12, true);
  eq(hlen % 4, 0, 'header length');
  for (const [, [, off]] of Object.entries(h.meta.arrays)) eq(off % 4, 0, 'offset');
});

check('read_refuses_bad_magic_newer_versions_and_short_files', () => {
  const buf = fit.packHead({ kind: 'head' }, { x: new Float32Array(2) });
  const bad = new Uint8Array(buf.slice(0)); bad[1] = 88;
  throwsWith(() => av.readHead(bad.buffer), 'not a head file');
  const v2 = new Uint8Array(buf.slice(0)); new DataView(v2.buffer).setUint32(8, 2, true);
  throwsWith(() => av.readHead(v2.buffer), 'newer');
  throwsWith(() => av.readHead(buf.slice(0, 20)), 'past the end');
  const past = fit.packHead({ kind: 'head' }, { x: new Float32Array(2) });
  throwsWith(() => av.readHead(past.slice(0, past.byteLength - 4)), 'past the end');
});

// ---------- the warp ----------
check('similarity2D_recovers_scale_angle_and_offset', () => {
  const rnd = rng(3), src = [], dst = [];
  const s = 3.5, th = (7 * Math.PI) / 180;
  for (let i = 0; i < 60; i++) {
    const p = [rnd() * 10 - 5, rnd() * 10 - 5, rnd()];
    src.push(p);
    dst.push([120 + s * (Math.cos(th) * p[0] - Math.sin(th) * p[1]), -40 + s * (Math.sin(th) * p[0] + Math.cos(th) * p[1]), 0]);
  }
  const sim = fit.similarity2D(src, dst);
  near(sim.scale, 3.5, 1e-9, 'scale'); near(sim.theta, th, 1e-9, 'theta');
  const q = sim.apply(src[0]);
  near(q[0], dst[0][0], 1e-9); near(q[1], dst[0][1], 1e-9);
});

check('rbf_reproduces_its_controls_and_affine_fields', () => {
  const rnd = rng(11), ctrl = [], disp = [], aff = [];
  for (let i = 0; i < 40; i++) {
    const c = [rnd() * 100, rnd() * 100, rnd() * 20];
    ctrl.push(c); disp.push([rnd() * 6 - 3, rnd() * 6 - 3]);
    aff.push([0.02 * c[0] - 0.01 * c[1] + 0.03 * c[2] + 1.5, -0.015 * c[0] + 0.04 * c[1] - 2]);
  }
  const w = fit.solveRbf(ctrl, disp, 0, 0.05);
  for (let i = 0; i < ctrl.length; i++) {
    const p = w(ctrl[i]);
    near(p[0] - ctrl[i][0], disp[i][0], 1e-6, 'x at ' + i); near(p[1] - ctrl[i][1], disp[i][1], 1e-6, 'y at ' + i);
    eq(p[2], ctrl[i][2], 'z kept');
  }
  const wa = fit.solveRbf(ctrl, aff, 0, 0.05);
  const x = [33, 61, 7], p = wa(x);
  near(p[0] - x[0], 0.02 * 33 - 0.01 * 61 + 0.03 * 7 + 1.5, 1e-6, 'affine x'); near(p[1] - x[1], -0.015 * 33 + 0.04 * 61 - 2, 1e-6, 'affine y');
});

// ---------- the fit's geometry ----------
const W = 2000, H = 1200;
check('fit_geometry_of_a_similar_photo_is_the_similarity', () => {
  const b = syntheticBase();
  const s = 40, th = (5 * Math.PI) / 180;
  const P = similarLandmarks(b, s, th, 1000, -600);
  const g = fit.fitGeometry(baseOf(b), P, W, H);
  const pos = g.arrays['head.pos'], bp = b.arr['head.pos'];
  // the base's centroid of the paired landmarks moves to the photo's
  let worst = 0;
  const sim = fit.similarity2D(
    [...Array(468).keys()].filter((i) => !Number.isNaN(b.arr.landmarks[i * 3])).map((i) => [...b.arr.landmarks.slice(i * 3, i * 3 + 3)]),
    [...Array(468).keys()].filter((i) => !Number.isNaN(b.arr.landmarks[i * 3])).map((i) => P[i]));
  for (let i = 0; i < g.meta.vertices; i++) {
    const want = sim.apply([bp[i * 3], bp[i * 3 + 1], bp[i * 3 + 2]]);
    worst = Math.max(worst, Math.hypot(pos[i * 3] - want[0], pos[i * 3 + 1] - want[1]));
    near(pos[i * 3 + 2], want[2], 1e-3, 'z');
  }
  near(worst, 0, 1e-3, 'worst px');
  near(g.report.residualWarp, 0, 1e-3, 'residual');
  // uv is the projection onto the photo
  const uv = g.arrays['head.uv'];
  near(uv[0], pos[0] / W, 1e-6); near(uv[1], 1 + pos[1] / H, 1e-6);
  // a shape's delta is carried: jawOpen's (0, -1) becomes s·R(θ)·(0, -1)
  const k = g.meta.shapes.indexOf('jawOpen');
  const [mx] = g.meta.shapeScale[k];
  const jp = g.arrays['shape.jawOpen.pos'];
  const v = 80; // the bottom row's last vertex
  near((jp[v * 3] * mx) / 32767, s * Math.sin(th), 0.01, 'jaw dx'); near((jp[v * 3 + 1] * mx) / 32767, -s * Math.cos(th), 0.01, 'jaw dy');
  // shapes that don't move stay zero
  const still = g.arrays['shape.cheekPuff.pos'];
  eq(still.every((x) => x === 0), true, 'cheekPuff');
  // the closed-eye projection moves where the blink moves
  const uvC = g.arrays['head.uvC'];
  eq(uvC[10 * 2 + 1] < uv[10 * 2 + 1], true, 'uvC below for the blinked vertex');
  near(uvC[0], uv[0], 1e-9); near(uvC[1], uv[1], 1e-9);
  eq(g.meta.vertices, 81); eq(g.meta.shapes.length, 52); eq(g.arrays['head.idx'].length, 8 * 8 * 6);
  eq(g.meta.mouth.jaw.length, 3);
  eq(g.meta.eyes.length, 2); eq(g.meta.eyes[0].outline.length, 16); eq(g.meta.mouth.inner.length, 20);
  eq(g.meta.eyes[0].center[0] < g.meta.eyes[1].center[0], true, 'image-left eye first');
});

check('fit_geometry_warps_a_distorted_photo_onto_its_landmarks', () => {
  const b = syntheticBase();
  const P = similarLandmarks(b, 40, 0, 1000, -600).map(([x, y, z]) => [x + 8 * Math.sin(x / 60), y + 5 * Math.cos(y / 50), z]);
  const g = fit.fitGeometry(baseOf(b), P, W, H);
  eq(g.report.residualWarp < 0.5, true, 'residual after the warp ' + g.report.residualWarp);
  eq(g.report.residualSimilarity > 2, true, 'similarity alone leaves ' + g.report.residualSimilarity);
});

// ---------- the checks ----------
// a face's landmarks: spread over the face, the eye outlines small rings
const lmFace = () => {
  const out = Array.from({ length: 478 }, (_, i) => ({ x: 0.3 + 0.4 * ((i * 37) % 100) / 100, y: 0.2 + 0.5 * ((i * 53) % 100) / 100, z: 0 }));
  [[fit.EYE_A, 0.42], [fit.EYE_B, 0.58]].forEach(([ids, cx]) => ids.forEach((i, k) => {
    const a = (2 * Math.PI * k) / ids.length;
    out[i] = { x: cx + 0.03 * Math.cos(a), y: 0.4 + 0.012 * Math.sin(a), z: 0 };
  }));
  return out;
};
const turned = (deg) => { const r = (deg * Math.PI) / 180; return { data: [Math.cos(r), 0, -Math.sin(r), 0, 0, 1, 0, 0, Math.sin(r), 0, Math.cos(r), 0, 0, 0, -40, 1] }; };
const result = ({ faces = 1, yaw = 0, blink = 0.1, jaw = 0.02 } = {}) => ({
  faceLandmarks: Array.from({ length: faces }, lmFace),
  faceBlendshapes: Array.from({ length: faces }, () => ({ categories: [
    { categoryName: 'eyeBlinkLeft', score: blink }, { categoryName: 'eyeBlinkRight', score: blink }, { categoryName: 'jawOpen', score: jaw }] })),
  facialTransformationMatrixes: Array.from({ length: faces }, () => turned(yaw)),
});
// the spec's table, exactly ("Fitting a portrait")
const MSG = {
  noFace: 'No face found. Use a clear photo of one face.',
  faces: "There's more than one face. Use a photo of one person.",
  turned: 'The face is turned. Use a photo facing the camera.',
  mouth: 'The mouth is open. Use a photo with the mouth closed.',
  eyes: 'The eyes are closed. Use a photo with the eyes open; add an eyes-closed version after.',
  small: 'The face is too small. Use a larger photo.',
  soft: 'This will look soft. A larger photo looks sharper.',
  bands: 'A photo wider than tall fills the window; this one leaves bands at the sides.',
  lineUp: "This eyes-closed photo doesn't line up with the portrait. Change only the eyes.",
};
const good = { faces: 1, turned: 3, jawOpen: 0.02, lipGap: 1, blinkLeft: 0.15, blinkRight: 0.12, faceWidth: 613, width: 2720, height: 1536 };
check('the_photo_is_judged_by_the_specs_table', () => {
  const ok = fit.judgePhoto(good);
  eq(ok.ok, true); eq(ok.message, undefined); eq(JSON.stringify(ok.warnings), '[]');
  const refused = (over) => { const r = fit.judgePhoto({ ...good, ...over }); eq(r.ok, false, JSON.stringify(over)); return r.message; };
  eq(refused({ faces: 0 }), MSG.noFace);
  eq(refused({ faces: 2 }), MSG.faces);
  eq(refused({ turned: 8.5 }), MSG.turned);
  eq(fit.judgePhoto({ ...good, turned: 8 }).ok, true, '8° is within');
  eq(refused({ jawOpen: 0.4 }), MSG.mouth);
  eq(refused({ lipGap: 30 }), MSG.mouth); // lips apart, teeth showing
  eq(refused({ blinkLeft: 0.7 }), MSG.eyes);
  eq(refused({ blinkRight: 0.6 }), MSG.eyes);
  eq(refused({ faceWidth: 249 }), MSG.small);
  // the first that fails is the one said
  eq(refused({ turned: 20, jawOpen: 0.5, faceWidth: 100 }), MSG.turned);
});

check('the_photo_warns_without_refusing', () => {
  const soft = fit.judgePhoto({ ...good, faceWidth: 499 });
  eq(soft.ok, true); eq(JSON.stringify(soft.warnings), JSON.stringify([MSG.soft]));
  eq(JSON.stringify(fit.judgePhoto({ ...good, faceWidth: 500 }).warnings), '[]');
  const tall = fit.judgePhoto({ ...good, width: 1080, height: 1350, faceWidth: 300 });
  eq(tall.ok, true); eq(JSON.stringify(tall.warnings), JSON.stringify([MSG.soft, MSG.bands]));
  eq(JSON.stringify(fit.judgePhoto({ ...good, width: 1000, height: 1000 }).warnings), '[]', 'square is fine');
  // a refusal keeps its warnings
  const r = fit.judgePhoto({ ...good, width: 1080, height: 1350, jawOpen: 0.5 });
  eq(r.ok, false); eq(JSON.stringify(r.warnings), JSON.stringify([MSG.bands]));
});

// the landmarker's matrix (column-major) for a face yawed y° and pitched p°,
// at a place in the frame
const pose = (y, p, tx = 0, ty = 0, tz = -30) => {
  const a = (y * Math.PI) / 180, b = (p * Math.PI) / 180;
  // R = rotY(a) · rotX(b): its columns
  const c0 = [Math.cos(a), 0, -Math.sin(a)], c1 = [Math.sin(a) * Math.sin(b), Math.cos(b), Math.cos(a) * Math.sin(b)];
  const c2 = [Math.sin(a) * Math.cos(b), -Math.sin(b), Math.cos(a) * Math.cos(b)];
  return { data: [...c0, 0, ...c1, 0, ...c2, 0, tx, ty, tz, 1] };
};
check('the_landmarkers_result_becomes_the_judges_input', () => {
  // 478 points with the face's sides (234, 454) 0.25 of 2000 px apart and the lips together
  const lm = Array.from({ length: 478 }, () => ({ x: 0.5, y: 0.5, z: 0 }));
  lm[234] = { x: 0.375, y: 0.5, z: 0 }; lm[454] = { x: 0.625, y: 0.5, z: 0 };
  lm[13] = { x: 0.5, y: 0.6, z: 0 }; lm[14] = { x: 0.5, y: 0.605, z: 0 };
  const res = { faceLandmarks: [lm], faceBlendshapes: [{ categories: [{ categoryName: 'eyeBlinkLeft', score: 0.2 }, { categoryName: 'eyeBlinkRight', score: 0.3 }, { categoryName: 'jawOpen', score: 0.05 }] }],
    facialTransformationMatrixes: [pose(0, 11)] };
  const x = fit.photoFacts(res, 2000, 1000);
  eq(x.faces, 1); near(x.faceWidth, 500, 1e-9); near(x.lipGap, 5, 1e-9); near(x.turned, 0, 1e-9);
  eq(x.blinkLeft, 0.2); eq(x.blinkRight, 0.3); eq(x.jawOpen, 0.05); eq(x.width, 2000); eq(x.height, 1000);
  eq(fit.photoFacts({ faceLandmarks: [] }, 10, 10).faces, 0);
});

check('facing_the_camera_allows_for_the_landmarkers_own_pitch', () => {
  // a face looking into the lens reads about 11° pitched (the butler, in
  // every crop: 10.3–12.5°), wherever it sits in the frame
  near(fit.turnedBy(pose(0, 11)), 0, 1e-6, 'frontal');
  near(fit.turnedBy(pose(0, 11, 0, 3.2, -31)), 0, 1e-6, 'above the centre');
  near(fit.turnedBy(pose(0, 11, 5, -4, -20)), 0, 1e-6, 'off to a side');
  near(fit.turnedBy(pose(-0.9, 10.3)), Math.hypot(0.9, 0.7), 0.02, 'the butler, tall crop');
  near(fit.turnedBy(pose(0, 20)), 9, 0.01, 'looking down');
  near(fit.turnedBy(pose(6, 11)), 6, 0.05, 'turned aside');
  near(fit.turnedBy(pose(-9, 11)), 9, 0.05, 'turned the other way');
});

check('a_closed_photo_must_line_up_with_the_still', () => {
  const fine = { sameSize: true, faces: 1, shift: 5.7, blinkLeft: 0.65, blinkRight: 0.64 };
  eq(fit.judgeClosed(fine).ok, true);
  eq(fit.judgeClosed({ ...fine, shift: 12.5 }).message, MSG.lineUp);
  eq(fit.judgeClosed({ ...fine, shift: 12 }).ok, true, '12 px is within');
  eq(fit.judgeClosed({ ...fine, sameSize: false }).message, MSG.lineUp);
  eq(fit.judgeClosed({ ...fine, faces: 0 }).message, MSG.lineUp);
  eq(fit.judgeClosed({ ...fine, blinkLeft: 0.2 }).message, 'The eyes in the eyes-closed photo are open. Close the eyes and change nothing else.');
  // the shift is measured outside the eyes: moving every landmark 15 px reads 15
  const open = lmFace(), moved = open.map((p) => ({ ...p, x: p.x + 15 / 1000 }));
  near(fit.closedShift(open, moved, 1000, 800), 15, 1e-6);
});

check('pack_ini_lists_the_files', () => {
  eq(fit.packIni({ still: 'still.jpg', head: 'head.bin', eyes: 'eyes.png', eyemask: 'eyemask.png' }),
    'still = still.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n');
  eq(av.parseIni('# x\r\nstill = a.jpg\n closed=b.jpg \n').closed, 'b.jpg');
});

// ---------- speech ----------
check('the_timeline_has_a_word_per_word_and_a_shape_per_sound', () => {
  const tl = av.buildTimeline('Your flight moved to 9:40.', () => 0.5);
  eq(tl.words.map((w) => 'Your flight moved to 9:40.'.slice(w.i0, w.i1)).join('|'), 'Your|flight|moved|to|9|40');
  eq(tl.ends.length, 1, 'one sentence end');
  // "to": t (DD) 0.072 s, o (O) 0.112 s
  const to = tl.words[3], evs = tl.ev.filter((e) => e.t0 >= to.t0 - 1e-9 && e.t1 <= to.t1 + 1e-9);
  eq(evs.map((e) => e.vis).join(','), 'DD,O');
  near(evs[0].t1 - evs[0].t0, 0.072, 1e-9); near(evs[1].t1 - evs[1].t0, 0.112, 1e-9);
  // digits are said as words: 9 → "nine"
  eq(tl.ev.filter((e) => e.t0 >= tl.words[4].t0 - 1e-9 && e.t1 <= tl.words[4].t1 + 1e-9).map((e) => e.vis).join(','), 'nn,I,nn');
  eq(tl.dur > tl.words[5].t1, true, 'ends after the last word');
  eq(tl.ev.every((e, i) => i === 0 || e.t0 >= tl.ev[i - 1].t1 - 1e-9), true, 'in order');
  eq(av.buildTimeline('', () => 0.5).ev.length, 0);
});

check('a_timeline_stretches_onto_the_voiced_span', () => {
  const tl = av.buildTimeline('Hello there. Good morning.', () => 0.5);
  const st = av.stretchTimeline(tl, 0.2, 3.0);
  near(st.ev[0].t0, 0.2, 1e-9, 'first sound');
  near(st.ev[st.ev.length - 1].t1, 3.0, 1e-9, 'last sound');
  eq(st.words.length, tl.words.length);
  eq(st.words.every((w, i) => w.t0 < w.t1 && (i === 0 || w.t0 >= st.words[i - 1].t1 - 1e-9)), true, 'words in order');
  eq(st.ends.every((e) => e > 0.2 && e <= st.dur), true, 'sentence ends inside');
  eq(tl.ev[0].t0 !== 0.2, true, 'the original is unchanged');
});

check('the_voiced_span_skips_silence_at_both_ends', () => {
  const rate = 24000, s = new Float32Array(Math.round(rate * 1.8));
  for (let i = Math.round(0.5 * rate); i < Math.round(1.5 * rate); i++) s[i] = 0.3 * Math.sin((2 * Math.PI * 220 * i) / rate);
  for (let i = 0; i < s.length; i++) s[i] += 0.0005 * Math.sin(i * 1.3); // a little hiss
  const [a, b] = av.voicedSpan(s, rate);
  near(a, 0.5, 0.02, 'start'); near(b, 1.5, 0.02, 'end');
  const [c, d] = av.voicedSpan(new Float32Array(rate), rate);
  eq(c, 0); near(d, 1, 1e-9, 'silence: the whole length');
});

check('the_six_states_are_the_specs', () => {
  eq(av.STATES.join('|'), 'resting|quiet|working|needs you|urgent|speaking');
});

check('framing_keeps_the_face_in_view', () => {
  const face = { cx: 1370, w: 613, top: 296, h: 761 };
  const wide = av.frameView(2720, 1536, face, 1456 / 900);
  eq(wide.x0 <= face.cx - face.w / 2 && wide.x0 + wide.w >= face.cx + face.w / 2, true, 'face inside, wide');
  near(wide.w / wide.h, 1456 / 900, 1e-9, 'aspect');
  const tall = av.frameView(2720, 1536, face, 0.6);
  eq(tall.x0 <= face.cx - face.w / 2 && tall.x0 + tall.w >= face.cx + face.w / 2, true, 'face inside, tall');
  eq(tall.x0 >= 0 && tall.x0 + tall.w <= 2720, true, 'inside the photo');
});

check('the_head_turns_a_few_degrees_at_most', () => {
  // the spec: about ±4°; working's −2.2 yaw, drift and following the gaze reach −5.6
  const p = av.limitPose({ pitch: 6, yaw: -5.6, roll: 4 });
  eq(p.pitch, 4); eq(p.yaw, -4); eq(p.roll, 3);
  const q = av.limitPose({ pitch: -1.2, yaw: 2.5, roll: -0.4 });
  eq(q.pitch, -1.2); eq(q.yaw, 2.5); eq(q.roll, -0.4);
});

check('a_catchlight_is_found_or_none_never_nan', () => {
  // a 60×60 crop: an iris of radius 20 at (30, 30), a dark lid band above it
  const field = (iris, spot) => (x, y) => (y < 14 ? 40 : Math.hypot(x - 30, y - 30) <= 20 ? (Math.hypot(x - 30, y - 16) < 2 ? spot : iris) : 90);
  const inCrop = (x, y) => x >= 0 && y >= 0 && x < 60 && y < 60;
  const found = fit.findCatchlight(field(70, 230), inCrop, 30, 30, 20, 70);
  eq(Array.isArray(found) && found.every(Number.isFinite), true, 'found ' + JSON.stringify(found));
  near(found[0], 30, 1); near(found[1], 16, 1.5);
  // an iris as bright as the spot (the median brighter than the dot): none, not NaN
  eq(fit.findCatchlight(field(200, 205), inCrop, 30, 30, 20, 210), null);
  // no bright spot at all
  eq(fit.findCatchlight(field(70, 70), inCrop, 30, 30, 20, 70), null);
});

// ---------- the made-up head the Zig tests read ----------
function tinyHead() {
  const b = syntheticBase(3);
  const g = fit.fitGeometry(baseOf(b), similarLandmarks(b, 10, 0.02, 64, -40), 128, 96);
  const meta = { ...g.meta, eyeCrop: [10, 4, 44, 12], photo: {} };
  meta.eyes = meta.eyes.map((e) => ({ ...e, catchlight: null, lid: [200, 160, 140] }));
  return fit.packHead(meta, g.arrays);
}
check('the_tiny_head_fixture_is_what_the_packer_writes', () => {
  const buf = new Uint8Array(tinyHead());
  if (process.argv.includes('--write-fixture')) { mkdirSync(here('../src/testdata/avatar/'), { recursive: true }); writeFileSync(fixturePath, buf); }
  const have = new Uint8Array(readFileSync(fixturePath));
  eq(have.length, buf.length, 'length');
  eq(Buffer.compare(Buffer.from(have), Buffer.from(buf)), 0, 'bytes');
});

// the still's fingerprint (crypto.subtle, async)
try {
  const hex = await fit.sha256Hex(new TextEncoder().encode('abc').buffer);
  eq(hex, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  n++; console.log('ok ' + n + ' the_still_is_fingerprinted_by_sha256');
} catch (e) { failed++; console.log('FAIL the_still_is_fingerprinted_by_sha256\n  ' + (e && e.stack || e)); }

console.log(failed ? `${failed} failed, ${n} passed` : `all ${n} passed`);
process.exit(failed ? 1 : 0);
