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
import * as bh from './base-head-lib.mjs';

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

check('fit_geometry_carries_the_teeths_jaw_and_kind', () => {
  const b = syntheticBase();
  b.meta.source = { name: 'ICT-FaceKit' };
  b.arr['teeth.jaw'] = new Float32Array([0, 0, 0, 0, 0, 0, 0, -0.5, 0.2]); // the third point drops and comes forward
  b.arr['teeth.kind'] = new Uint8Array([0, 0, 1]);
  b.arr['head.part'] = new Uint8Array(81).fill(0); b.arr['head.part'][40] = 1;
  const s = 40, th = (5 * Math.PI) / 180;
  const g = fit.fitGeometry(baseOf(b), similarLandmarks(b, s, th, 1000, -600), W, H);
  const j = g.arrays['teeth.jaw'];
  eq(j instanceof Float32Array, true); eq(j.length, 9);
  near(j[0], 0, 1e-4); near(j[1], 0, 1e-4); near(j[2], 0, 1e-4);
  near(j[6], s * Math.sin(th) * 0.5, 1e-3, 'dx'); near(j[7], -s * Math.cos(th) * 0.5, 1e-3, 'dy'); near(j[8], s * 0.2, 1e-3, 'dz');
  eq(JSON.stringify([...g.arrays['teeth.kind']]), '[0,0,1]');
  eq('teeth.show' in g.arrays, false, 'no teeth.show without the base having one');
  b.arr['teeth.show'] = new Float32Array([0, -0.2, 0, 0, -0.2, 0, 0, 0, 0]); // the upper points come down when the lips part
  const gs = fit.fitGeometry(baseOf(b), similarLandmarks(b, s, th, 1000, -600), W, H);
  near(gs.arrays['teeth.show'][1], -s * Math.cos(th) * 0.2, 1e-3, 'show dy'); near(gs.arrays['teeth.show'][0], s * Math.sin(th) * 0.2, 1e-3, 'show dx');
  near(gs.arrays['teeth.show'][7], 0, 1e-4);
  eq(g.arrays['head.part'].length, 81); eq(g.arrays['head.part'][40], 1);
  eq(g.meta.base, 'ICT-FaceKit');
  // a base without them: no such arrays, no base name
  const g0 = fit.fitGeometry(baseOf(syntheticBase()), similarLandmarks(b, s, th, 1000, -600), W, H);
  eq('teeth.jaw' in g0.arrays || 'teeth.kind' in g0.arrays || 'head.part' in g0.arrays || 'base' in g0.meta, false);
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

check('a_refusal_is_an_error_with_the_tables_line', () => {
  const r = fit.judgePhoto({ ...good, jawOpen: 0.5, width: 1000, height: 1300 });
  const e = fit.refusal(r);
  eq(e instanceof Error, true); eq(e.message, MSG.mouth); eq(e.code, 'mouth-open');
  eq(JSON.stringify(e.warnings), JSON.stringify([MSG.bands]));
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
  // the desk page's upload writes an [avatar] section
  eq(fit.packIni({ still: 'still.jpg', head: 'head.bin', eyes: 'eyes.png', eyemask: 'eyemask.png' }),
    '[avatar]\nstill = still.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n');
  const ini = av.parseIni('# x\r\n[avatar]\r\nstill = a.jpg\n closed=b.jpg \n');
  eq(ini.still, 'a.jpg'); eq(ini.closed, 'b.jpg');
  eq(av.parseIni('[other]\nstill = x.jpg\n[avatar]\nstill = a.jpg\n').still, 'a.jpg', 'other sections are not the avatar');
  eq(av.parseIni('still = a.jpg\n').still, 'a.jpg', 'a file with no section');
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
  // as the desk page calls them ("needs" is the spec's "needs you")
  eq(av.STATES.join('|'), 'resting|quiet|working|needs|urgent|speaking');
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

// ---------- the base head's maker (tools/base-head-lib.mjs) ----------
check('obj_faces_and_vertices_are_read', () => {
  const o = bh.parseObj('# a comment\nmtllib x.mtl\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 2 0 0\nvt 0 0\nusemtl M\nf 1/1 2/1 3/1 4/1\nf 2/1 5/1 3/1\n');
  eq(o.pos.length, 15); eq(o.pos[3], 1); eq(o.pos[13], 0);
  eq(JSON.stringify(o.faces), '[[0,1,2,3],[1,4,2]]');
});
check('every_arkit_name_maps_and_the_split_ones_sum', () => {
  eq(Object.keys(bh.ARKIT_FROM_ICT).length, 52);
  for (const s of SHAPES) eq(Array.isArray(bh.ARKIT_FROM_ICT[s]), true, s);
  eq(JSON.stringify(bh.ARKIT_FROM_ICT.browInnerUp), '["browInnerUp_L","browInnerUp_R"]');
  eq(JSON.stringify(bh.ARKIT_FROM_ICT.cheekPuff), '["cheekPuff_L","cheekPuff_R"]');
  eq(bh.ARKIT_FROM_ICT.tongueOut.length, 0);
  for (const s of SHAPES) if (!['browInnerUp', 'cheekPuff', 'tongueOut'].includes(s)) eq(JSON.stringify(bh.ARKIT_FROM_ICT[s]), JSON.stringify([s]));
  // the files to fetch: the neutral and 53 expressions
  eq(bh.ICT_FILES.length, 54); eq(bh.ICT_FILES[0], 'generic_neutral_mesh.obj');
});
check('quads_split_on_the_shorter_diagonal', () => {
  // a rhombus: 0-2 is the long diagonal, 1-3 the short one
  const pos = new Float64Array([0, 0, 0, 2, 1, 0, 4, 0, 0, 2, -1, 0]);
  const t = bh.triangulate([[0, 1, 2, 3]], pos);
  eq(t.length, 6);
  eq([...t].filter((v) => v === 1 || v === 3).length, 4, 'both triangles hold the short diagonal');
  eq(JSON.stringify([...bh.triangulate([[0, 1, 2]], pos)]), '[0,1,2]');
});
check('the_neck_is_what_faces_the_camera_below_the_jaw', () => {
  // the jaw's contour seen from the front, [|x|, y], and level past its end
  const jaw = { contour: [[0, -7.5], [3, -6.9], [6.3, -3.9]], facing: 0.25, floor: -10 };
  //   chin's front    under the chin   throat          neck's side    ear lobe       back of the neck  deep
  const pos = [0, -7.4, 10, 1, -8.2, 9, 0, -9.5, 6, 6.5, -5, 3, 8, -1.5, 1, 0, -8, -8, 0, -11, -5];
  const nrm = [0, -0.3, 0.95, 0, -0.95, 0.1, 0, -0.1, 0.99, 0.6, 0, 0.8, 0.3, 0, 0.95, 0, 0, -1, 0, 0, -1];
  const neck = bh.isNeck(new Float64Array(pos), new Float64Array(nrm), jaw);
  eq(JSON.stringify([0, 1, 2, 3, 4, 5, 6].map(neck)), '[false,false,true,true,false,false,true]');
  eq(bh.vertexNormals(new Float64Array([0, 0, 0, 1, 0, 0, 0, 1, 0]), new Uint32Array([0, 1, 2]))[2], 1);
});
check('the_fold_behind_an_opening_is_found', () => {
  // a sheet at z=1 with a hole round vertex (5,5); the hole's ring folds back under the sheet
  const k = 11, pos = [], idx = [];
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) pos.push(c, r, 1);
  const inHole = (r, c) => r >= 4 && r < 6 && c >= 4 && c < 6;
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) {
    if (inHole(r, c)) continue;
    const a = r * k + c; idx.push(a, a + 1, a + k + 1, a, a + k + 1, a + k);
  }
  const ring = [[4, 4], [4, 5], [4, 6], [5, 6], [6, 6], [6, 5], [6, 4], [5, 4]].map(([r, c]) => r * k + c);
  const fold = ring.map((v) => { const x = pos[v * 3], y = pos[v * 3 + 1]; pos.push(5 + (x - 5) * 1.4, 5 + (y - 5) * 1.4, 0); return pos.length / 3 - 1; });
  for (let i = 0; i < 8; i++) { const j = (i + 1) % 8; idx.push(ring[i], ring[j], fold[j], ring[i], fold[j], fold[i]); }
  const hidden = bh.foldsBehind({ pos: new Float64Array(pos), idx: new Uint32Array(idx), seeds: fold, eps: 0.05 });
  eq(JSON.stringify([...hidden].sort((a, b) => a - b)), JSON.stringify([...fold].sort((a, b) => a - b)));
});
// a dome grid, k×k, with its triangles
function dome(k) {
  const pos = new Float64Array(k * k * 3), idx = [];
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) {
    const x = c / (k - 1) * 2 - 1, y = r / (k - 1) * 2 - 1;
    pos.set([x, y, 1 - 0.5 * (x * x + y * y)], (r * k + c) * 3);
  }
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) { const a = r * k + c; idx.push(a, a + 1, a + k + 1, a, a + k + 1, a + k); }
  return { pos, idx: new Uint32Array(idx) };
}
const used = (idx) => new Set(idx);
const normalZ = (pos, idx, t) => {
  const p = (i) => [pos[idx[t + i] * 3], pos[idx[t + i] * 3 + 1], pos[idx[t + i] * 3 + 2]];
  const [a, b, c] = [p(0), p(1), p(2)];
  return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
};
check('simplify_keeps_locked_vertices_and_reaches_its_target', () => {
  const k = 21, { pos, idx } = dome(k);
  const lock = new Uint8Array(k * k);
  for (let i = 0; i < k; i++) lock[i] = lock[(k - 1) * k + i] = lock[i * k] = lock[i * k + k - 1] = 1;
  const out = bh.simplify({ pos, idx, poses: [pos], lock, target: 120 });
  const u = used(out);
  eq(u.size <= 120, true, 'vertices used ' + u.size);
  for (let i = 0; i < k * k; i++) if (lock[i]) eq(u.has(i), true, 'locked ' + i);
  for (let t = 0; t < out.length; t += 3) eq(normalZ(pos, out, t) > 0, true, 'triangle ' + t / 3 + ' faces up');
  // a manifold: every edge has one or two triangles, and the border's edges one
  const ec = new Map();
  for (let t = 0; t < out.length; t += 3) for (let e = 0; e < 3; e++) { const a = out[t + e], b = out[t + (e + 1) % 3]; const key = Math.min(a, b) + ',' + Math.max(a, b); ec.set(key, (ec.get(key) || 0) + 1); }
  eq([...ec.values()].every((c) => c <= 2), true, 'manifold');
});
check('simplify_keeps_where_a_pose_moves', () => {
  const k = 21, pos = new Float64Array(k * k * 3), idx = [];
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) pos.set([c, r, 0], (r * k + c) * 3);
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) { const a = r * k + c; idx.push(a, a + 1, a + k + 1, a, a + k + 1, a + k); }
  // the pose folds the grid along row 10 (a crease, as lips parting)
  const pose = new Float64Array(pos);
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) pose[(r * k + c) * 3 + 2] = Math.abs(r - 10) * 0.8;
  const lock = new Uint8Array(k * k);
  for (let i = 0; i < k; i++) lock[i] = lock[(k - 1) * k + i] = lock[i * k] = lock[i * k + k - 1] = 1;
  const out = bh.simplify({ pos, idx: new Uint32Array(idx), poses: [pos, pose], lock, target: 130 });
  const u = used(out);
  let crease = 0, flat = 0;
  for (let c = 1; c < k - 1; c++) { if (u.has(10 * k + c)) crease++; if (u.has(5 * k + c)) flat++; }
  eq(crease > flat, true, `crease row kept ${crease}, a flat row ${flat}`);
});
check('simplify_keeps_more_where_a_vertex_weighs_more', () => {
  // a gently curved sheet: the right half weighs 20 times the left
  const k = 21, pos = new Float64Array(k * k * 3), idx = [];
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) pos.set([c, r, 0.02 * ((c - 10) ** 2 + (r - 10) ** 2)], (r * k + c) * 3);
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) { const a = r * k + c; idx.push(a, a + 1, a + k + 1, a, a + k + 1, a + k); }
  const weight = new Float64Array(k * k);
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) weight[r * k + c] = c > 10 ? 20 : 1;
  const out = bh.simplify({ pos, idx: new Uint32Array(idx), poses: [pos], lock: new Uint8Array(k * k), weight, target: 150 });
  const u = used(out);
  let right = 0, left = 0;
  for (let r = 1; r < k - 1; r++) for (let c = 1; c < k - 1; c++) if (u.has(r * k + c)) { if (c > 10) right++; else if (c < 10) left++; }
  eq(right > left * 1.5, true, `right ${right}, left ${left}`);
});
check('the_blink_is_sealed_so_the_lids_meet', () => {
  // lower margin at y 0 (0–4), upper margin at y 1 closing by 0.9 (a 0.1 gap),
  // a lid point 0.2 above the margin, a brow point far above, the lower margin still
  const pos = new Float32Array([0, 0, 0, 2, 0, 0, 4, 0, 0, 0, 1, 0, 2, 1, 0, 4, 1, 0, 2, 1.2, 0, 2, 3, 0]);
  const delta = new Float32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -0.9, 0, 0, -0.9, 0, 0, -1.2, 0, 0, -0.9, 0, 0, 0, 0]);
  const out = bh.sealBlink({ pos, delta, upper: [3, 4, 5], lower: [0, 1, 2], overlap: 0.03, reach: 0.4 });
  near(out[4 * 3 + 1], -1.03, 1e-6, 'the margin goes 0.03 past');
  near(out[3 * 3 + 1], -1.03, 1e-6);
  near(out[5 * 3 + 1], -1.2, 1e-6, 'already past: unchanged');
  near(out[6 * 3 + 1], -0.9 - 0.13 * 0.5, 1e-6, 'half the correction 0.2 up');
  eq(out[7 * 3 + 1], 0, 'far above: unchanged');
  eq(out[1 * 3 + 1], 0, 'the lower margin: unchanged');
});
check('a_jagged_cut_is_smoothed_by_its_neighbours', () => {
  // a 9×9 grid cut below row 4, with one vertex of row 4 cut too (a tooth) and one of row 5 kept (a notch)
  const k = 9, idx = [];
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) { const a = r * k + c; idx.push(a, a + 1, a + k + 1, a, a + k + 1, a + k); }
  const cut = new Uint8Array(k * k);
  for (let r = 5; r < k; r++) for (let c = 0; c < k; c++) cut[r * k + c] = 1;
  cut[4 * k + 4] = 1; cut[5 * k + 2] = 0;
  const out = bh.majority(cut, new Uint32Array(idx), 2);
  eq(out[4 * k + 4], 0, 'the tooth is kept again'); eq(out[5 * k + 2], 1, 'the notch is cut');
  eq(out[2 * k + 2], 0); eq(out[7 * k + 7], 1, 'far from the edge: unchanged');
});
check('compact_maps_used_vertices_in_order', () => {
  const { map, kept } = bh.compact(new Uint32Array([4, 2, 7, 2, 7, 9]), 10);
  eq(kept, 4);
  eq(JSON.stringify([...map]), '[-1,-1,0,-1,1,-1,-1,2,-1,3]');
});

check('the_head_fades_towards_its_outer_edge_not_its_eye_openings', () => {
  // a 9×9 grid, 10 px apart, with a hole round vertex (4,4) standing for an eye opening
  const k = 9, pos = new Float32Array(k * k * 3), idx = [];
  for (let r = 0; r < k; r++) for (let c = 0; c < k; c++) pos.set([c * 10, -r * 10, 0], (r * k + c) * 3);
  for (let r = 0; r < k - 1; r++) for (let c = 0; c < k - 1; c++) {
    if (r >= 3 && r < 5 && c >= 3 && c < 5) continue;
    const a = r * k + c; idx.push(a, a + k, a + 1, a + 1, a + k, a + k + 1);
  }
  const eyes = [{ center: [40, 40], width: 20 }];
  const d = av.edgeDistance(pos, new Uint16Array(idx), eyes);
  eq(d[0], 0); eq(d[4 * k], 0, 'the outer edge');
  near(d[1 * k + 1], 10, 1e-6, 'one in'); near(d[2 * k + 2], 20, 1e-6);
  eq(d[3 * k + 3] > 0, true, 'the eye opening is not an edge'); near(d[3 * k + 3], 30, 1e-6);
});
check('only_a_head_with_its_own_mouth_parts_fades_to_its_edge', () => {
  // an open edge round a "mouth" (an older head's lips): no fade there
  const pos = new Float32Array([0, 0, 0, 10, 0, 0, 0, -10, 0]), idx = new Uint16Array([0, 1, 2]);
  const eyes = [{ center: [100, 100], width: 10 }];
  const old = av.headEdge(pos, idx, { eyes, arrays: {} });
  eq([...old].every((d) => d >= 1e6), true, 'an older head: no fade');
  const own = av.headEdge(pos, idx, { eyes, arrays: { 'teeth.jaw': [] } });
  eq(own[0], 0, 'a head with its own mouth parts fades');
});
check('an_optional_array_of_the_wrong_size_is_a_problem', () => {
  const head = (n, t, extra) => ({ meta: { vertices: n, arrays: { 'head.pos': ['f32', 0, 0], 'teeth.pos': ['f32', 0, 0], ...Object.fromEntries(Object.keys(extra).map((k) => [k, ['f32', 0, 0]])) } },
    arr: (name) => ({ 'head.pos': new Float32Array(n * 3), 'teeth.pos': new Float32Array(t * 3), ...extra })[name] });
  eq(av.optionalProblem(head(3, 2, {})), null);
  eq(av.optionalProblem(head(3, 2, { 'teeth.jaw': new Float32Array(6), 'teeth.kind': new Uint8Array(2), 'head.part': new Uint8Array(3) })), null);
  has(av.optionalProblem(head(3, 2, { 'teeth.jaw': new Float32Array(3) })), 'teeth.jaw');
  has(av.optionalProblem(head(3, 2, { 'teeth.kind': new Uint8Array(3) })), 'teeth.kind');
  has(av.optionalProblem(head(3, 2, { 'head.part': new Uint8Array(2) })), 'head.part');
  has(av.optionalProblem(head(3, 2, { 'teeth.show': new Float32Array(5) })), 'teeth.show');
  eq(av.optionalProblem(head(3, 2, { 'teeth.show': new Float32Array(6) })), null);
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

// the voice with no face (createVoice), over a stand-in built-in voice and
// a stand-in audio element
async function acheck(name, fn) {
  try { await fn(); n++; console.log('ok ' + n + ' ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + '\n  ' + (e && e.stack || e)); }
}
{
  const kept = { synth: globalThis.speechSynthesis, utt: globalThis.SpeechSynthesisUtterance, audio: globalThis.Audio };
  const said = []; let cancels = 0;
  globalThis.SpeechSynthesisUtterance = class { constructor(text) { this.text = text; } };
  globalThis.speechSynthesis = { getVoices: () => [{ name: 'Samantha', lang: 'en-US' }, { name: 'Daniel', lang: 'en-GB' }], speak: (u) => said.push(u), cancel: () => { cancels++; } };
  const els = [];
  globalThis.Audio = class { constructor() { els.push(this); this.paused = false; } play() { this.played = true; return Promise.resolve(); } pause() { this.paused = true; } };

  await acheck('a_voice_alone_says_a_reply_with_the_built_in_voice', async () => {
    const v = av.createVoice();
    const p = v.speak({ text: 'Three flats match.', browser: true });
    eq(said.length, 1); eq(said[0].text, 'Three flats match.'); eq(said[0].voice.name, 'Daniel');
    said[0].onstart(); said[0].onend();
    eq(await p, true);
  });
  await acheck('stopping_a_voice_alone_cancels_the_built_in_voice', async () => {
    const v = av.createVoice();
    const p = v.speak({ text: 'Never finished.', browser: true });
    said[said.length - 1].onstart();
    const before = cancels;
    v.stop();
    eq(await p, false); eq(cancels, before + 1);
  });
  await acheck('a_voice_alone_plays_a_providers_audio_and_lets_it_go', async () => {
    const v = av.createVoice();
    const made = [], gone = [];
    const kc = URL.createObjectURL, kr = URL.revokeObjectURL;
    URL.createObjectURL = (b) => { made.push(b); return 'blob:test-' + made.length; };
    URL.revokeObjectURL = (u) => gone.push(u);
    try {
      const audio = new Blob([new Uint8Array(8)], { type: 'audio/wav' });
      const p = v.speak({ text: 'Played.', audio });
      const el = els[els.length - 1];
      eq(made[0], audio); eq(el.src, 'blob:test-1'); eq(el.played, true);
      await Promise.resolve();
      el.onended();
      eq(await p, true); eq(gone.join(), 'blob:test-1');
      // a second reply replaces the first: the first ends unsaid
      const first = v.speak({ text: 'One.', audio });
      const one = els[els.length - 1];
      const second = v.speak({ text: 'Two.', audio });
      eq(await first, false); eq(one.paused, true);
      els[els.length - 1].onended();
      eq(await second, true);
    } finally { URL.createObjectURL = kc; URL.revokeObjectURL = kr; }
  });
  await acheck('a_voice_alone_says_why_nothing_was_heard', async () => {
    const v = av.createVoice();
    let err = '';
    globalThis.Audio = class { play() { return Promise.reject(new Error('no decoder')); } pause() {} };
    try { await v.speak({ text: 'Unplayable.', audio: new Blob([new Uint8Array(4)]) }); } catch (e) { err = e.message; }
    eq(err, "The voice didn't play: no decoder");
    globalThis.speechSynthesis = undefined;
    err = '';
    try { await av.createVoice().speak({ text: 'No voice.', browser: true }); } catch (e) { err = e.message; }
    eq(err, 'There is no built-in voice here.');
    err = '';
    try { await v.speak({ text: 'Nothing to say it with.' }); } catch (e) { err = e.message; }
    eq(err, 'speak needs audio or browser: true');
  });
  globalThis.speechSynthesis = kept.synth; globalThis.SpeechSynthesisUtterance = kept.utt; globalThis.Audio = kept.audio;
}

console.log(failed ? `${failed} failed, ${n} passed` : `all ${n} passed`);
process.exit(failed ? 1 : 0);
