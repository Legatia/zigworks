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
check('photo_checks_say_what_to_change', () => {
  eq(fit.checkPhoto(result()), null);
  eq(fit.checkPhoto(result({ faces: 0 })).code, 'no-face');
  eq(fit.checkPhoto(result({ faces: 2 })).code, 'faces');
  const t = fit.checkPhoto(result({ yaw: 10 }));
  eq(t.code, 'turned'); has(t.message, 'about 10°');
  eq(fit.checkPhoto(result({ yaw: 7 })), null);
  eq(fit.checkPhoto(result({ blink: 0.7 })).code, 'eyes-closed');
  const m = fit.checkPhoto(result({ jaw: 0.4 }));
  eq(m.code, 'mouth-open'); eq(m.message, 'Use a photo facing the camera with the mouth closed.');
});

check('facing_the_camera_means_facing_where_the_camera_is', () => {
  // a face above the frame's centre (y 3.2 at 31 away) that looks at the
  // camera is pitched about 5.9° against the camera's axis, and faces it
  const a = Math.atan2(3.2, 31);
  const at = { data: [1, 0, 0, 0, 0, Math.cos(a), Math.sin(a), 0, 0, -Math.sin(a), Math.cos(a), 0, 0, 3.2, -31, 1] };
  near(fit.turnedBy(at), 0, 0.01, 'looking at the camera');
  // the same face pitched 8° more is turned 8°
  const b = a + (8 * Math.PI) / 180;
  near(fit.turnedBy({ data: [1, 0, 0, 0, 0, Math.cos(b), Math.sin(b), 0, 0, -Math.sin(b), Math.cos(b), 0, 0, 3.2, -31, 1] }), 8, 0.01, 'pitched');
  near(fit.turnedBy(turned(6)), 6, 0.01, 'yaw at the centre');
});

check('a_closed_photo_must_line_up_with_the_still', () => {
  const open = result(), closed = result({ blink: 0.9 });
  eq(fit.checkClosed(open, closed, 1000, 800, 1000, 800), null);
  eq(fit.checkClosed(open, closed, 1000, 800, 900, 800).code, 'closed-size');
  const moved = result({ blink: 0.9 });
  moved.faceLandmarks[0] = moved.faceLandmarks[0].map((p) => ({ ...p, x: p.x + 15 / 1000 }));
  const r = fit.checkClosed(open, moved, 1000, 800, 1000, 800);
  eq(r.code, 'closed-moved'); eq(r.message, "This eyes-closed photo doesn't line up with the portrait. Change only the eyes.");
  eq(fit.checkClosed(open, result({ blink: 0.1 }), 1000, 800, 1000, 800).code, 'closed-open');
  eq(fit.checkClosed(open, result({ faces: 0 }), 1000, 800, 1000, 800).code, 'closed-no-face');
});

check('pack_ini_lists_the_files', () => {
  eq(fit.packIni({ still: 'still.jpg', head: 'head.bin', eyes: 'eyes.png', eyemask: 'eyemask.png' }),
    'still = still.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n');
  eq(av.parseIni('# x\r\nstill = a.jpg\n closed=b.jpg \n').closed, 'b.jpg');
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

console.log(failed ? `${failed} failed, ${n} passed` : `all ${n} passed`);
process.exit(failed ? 1 : 0);
