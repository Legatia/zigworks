// The avatar's fit: a portrait made into a pack's head (head.bin), eye
// texture (eyes.png) and blink mask (eyemask.png), in the browser.
//
//   const { head, eyes, eyemask, report } = await fit(photo, closedPhoto);
//
// Face landmarks are found on the photo (MediaPipe Face Landmarker, from
// /desk/assets/mediapipe/); the base head (/desk/assets/base-head.bin)
// carries the same 478 landmarks on its own surface. A 2D similarity and
// an RBF warp map the base head onto the photo, and its 52 expression
// shapes go through the same warp. The head file's layout is in harness's
// README (Avatar packs) and src/avatar.zig.

export const SHAPES = ['browInnerUp', 'browDown_L', 'browDown_R', 'browOuterUp_L', 'browOuterUp_R', 'eyeLookUp_L', 'eyeLookUp_R',
  'eyeLookDown_L', 'eyeLookDown_R', 'eyeLookIn_L', 'eyeLookIn_R', 'eyeLookOut_L', 'eyeLookOut_R', 'eyeBlink_L', 'eyeBlink_R',
  'eyeSquint_L', 'eyeSquint_R', 'eyeWide_L', 'eyeWide_R', 'cheekPuff', 'cheekSquint_L', 'cheekSquint_R', 'noseSneer_L', 'noseSneer_R',
  'jawOpen', 'jawForward', 'jawLeft', 'jawRight', 'mouthFunnel', 'mouthPucker', 'mouthLeft', 'mouthRight', 'mouthRollUpper',
  'mouthRollLower', 'mouthShrugUpper', 'mouthShrugLower', 'mouthClose', 'mouthSmile_L', 'mouthSmile_R', 'mouthFrown_L',
  'mouthFrown_R', 'mouthDimple_L', 'mouthDimple_R', 'mouthUpperUp_L', 'mouthUpperUp_R', 'mouthLowerDown_L', 'mouthLowerDown_R',
  'mouthPress_L', 'mouthPress_R', 'mouthStretch_L', 'mouthStretch_R', 'tongueOut'];

// MediaPipe's face mesh: the eye openings (image-left eye first), the lips
export const EYE_A = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246];
export const EYE_B = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466];
export const LIP_IN = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191];
export const LIP_OUT = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185];

// ---------- the head file (format version 1) ----------

export const HEAD_MAGIC = [0x89, 0x48, 0x45, 0x41, 0x44, 0x0d, 0x0a, 0x1a]; // "\x89HEAD\r\n\x1a"
export const HEAD_VERSION = 1;
const TYPE_NAMES = new Map([[Float32Array, 'f32'], [Int16Array, 'i16'], [Uint16Array, 'u16'], [Uint32Array, 'u32'], [Uint8Array, 'u8']]);

/** Packs a header object and named typed arrays into a head file. */
export function packHead(meta, arrays) {
  const desc = {};
  let off = 0;
  const list = Object.entries(arrays);
  for (const [name, ta] of list) {
    const ty = TYPE_NAMES.get(ta.constructor);
    if (!ty) throw new Error('packHead: ' + name + ' is a ' + ta.constructor.name);
    off = (off + 3) & ~3;
    desc[name] = [ty, off, ta.length];
    off += ta.byteLength;
  }
  const hdr = new TextEncoder().encode(JSON.stringify({ ...meta, arrays: desc }));
  const hlen = (hdr.length + 3) & ~3;
  const out = new Uint8Array(16 + hlen + ((off + 3) & ~3));
  out.set(HEAD_MAGIC, 0);
  const dv = new DataView(out.buffer);
  dv.setUint32(8, HEAD_VERSION, true);
  dv.setUint32(12, hlen, true);
  out.set(hdr, 16);
  out.fill(32, 16 + hdr.length, 16 + hlen);
  for (const [name, ta] of list) out.set(new Uint8Array(ta.buffer, ta.byteOffset, ta.byteLength), 16 + hlen + desc[name][1]);
  return out.buffer;
}

const TYPES = { f32: Float32Array, i16: Int16Array, u16: Uint16Array, u32: Uint32Array, u8: Uint8Array };

/** A head file (format version 1): { version, meta, arr(name) }. Throws a
 *  plain Error when it isn't one this module reads. */
export function readHead(buf) {
  const bytes = new Uint8Array(buf);
  if (bytes.length < 16 || HEAD_MAGIC.some((b, i) => bytes[i] !== b)) {
    if (bytes.length >= 8 && HEAD_MAGIC.every((b, i) => bytes[i] === b)) throw new Error("the head file's header runs past the end of the file");
    throw new Error('this is not a head file');
  }
  const dv = new DataView(buf);
  const version = dv.getUint32(8, true), hlen = dv.getUint32(12, true);
  if (version > 1) throw new Error(`the head file is format version ${version}, made by a newer harness`);
  if (version < 1 || hlen % 4 || 16 + hlen > bytes.length) throw new Error("the head file's header runs past the end of the file");
  const meta = JSON.parse(new TextDecoder().decode(bytes.subarray(16, 16 + hlen)));
  const base = 16 + hlen;
  const arr = (name) => {
    const d = meta.arrays && meta.arrays[name];
    if (!d) throw new Error('the head file has no ' + name);
    const T = TYPES[d[0]];
    if (!T || d[1] % 4 || base + d[1] + d[2] * T.BYTES_PER_ELEMENT > bytes.length) throw new Error('the head file\'s ' + name + ' runs past the end of the file');
    return new T(buf, base + d[1], d[2]);
  };
  for (const name of Object.keys(meta.arrays || {})) arr(name);
  return { version, meta, arr };
}

/** avatar.ini's text for a pack's files ({ still, closed?, head?, eyes?, eyemask? }). */
export function packIni(files) {
  let s = '';
  for (const k of ['still', 'closed', 'head', 'eyes', 'eyemask']) if (files[k]) s += k + ' = ' + files[k] + '\n';
  return s;
}

// ---------- the warp ----------

/** 2D Procrustes (x, y) from src to dst points ([x, y, z]); z is scaled
 *  about the source's centroid. */
export function similarity2D(src, dst) {
  const n = src.length;
  const sc = [0, 0, 0], tc = [0, 0, 0];
  for (let i = 0; i < n; i++) for (let k = 0; k < 3; k++) { sc[k] += src[i][k] / n; tc[k] += dst[i][k] / n; }
  let sxx = 0, sxy = 0, ss = 0, tt = 0;
  for (let i = 0; i < n; i++) {
    const ax = src[i][0] - sc[0], ay = src[i][1] - sc[1], bx = dst[i][0] - tc[0], by = dst[i][1] - tc[1];
    sxx += ax * bx + ay * by; sxy += ax * by - ay * bx; ss += ax * ax + ay * ay; tt += bx * bx + by * by;
  }
  const theta = Math.atan2(sxy, sxx);
  const scale = Math.sqrt(tt / ss); // the ratio of the spreads, as the prototype
  const c = Math.cos(theta), s = Math.sin(theta);
  const apply = (v) => {
    const ax = v[0] - sc[0], ay = v[1] - sc[1], az = v[2] - sc[2];
    return [tc[0] + scale * (c * ax - s * ay), tc[1] + scale * (s * ax + c * ay), scale * az];
  };
  return { scale, theta, apply };
}

/** An RBF warp (biharmonic r kernel plus an affine part) of x/y
 *  displacements `disp` at control points `ctrl`, solved in units of
 *  `unit` per pixel so the numbers stay near 1. Returns p → p + d(p). */
export function solveRbf(ctrl, disp, lambda, unit) {
  const N = ctrl.length, S = N + 4, U = unit;
  const A = new Float64Array(S * S), B = new Float64Array(S * 2);
  const dist = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]);
  for (let i = 0; i < N; i++) {
    for (let j = 0; j < N; j++) A[i * S + j] = dist(ctrl[i], ctrl[j]) * U + (i === j ? lambda : 0);
    const p = ctrl[i], row = [1, p[0] * U, p[1] * U, p[2] * U];
    for (let k = 0; k < 4; k++) { A[i * S + N + k] = row[k]; A[(N + k) * S + i] = row[k]; }
    B[i * 2] = disp[i][0] * U; B[i * 2 + 1] = disp[i][1] * U;
  }
  // Gaussian elimination with partial pivoting
  for (let col = 0; col < S; col++) {
    let piv = col;
    for (let r = col + 1; r < S; r++) if (Math.abs(A[r * S + col]) > Math.abs(A[piv * S + col])) piv = r;
    if (piv !== col) {
      for (let k = 0; k < S; k++) { const t = A[col * S + k]; A[col * S + k] = A[piv * S + k]; A[piv * S + k] = t; }
      for (let k = 0; k < 2; k++) { const t = B[col * 2 + k]; B[col * 2 + k] = B[piv * 2 + k]; B[piv * 2 + k] = t; }
    }
    const d = A[col * S + col];
    if (Math.abs(d) < 1e-300) throw new Error('the warp has no solution (landmarks on one line?)');
    for (let r = col + 1; r < S; r++) {
      const f = A[r * S + col] / d;
      if (!f) continue;
      for (let k = col; k < S; k++) A[r * S + k] -= f * A[col * S + k];
      B[r * 2] -= f * B[col * 2]; B[r * 2 + 1] -= f * B[col * 2 + 1];
    }
  }
  const X = new Float64Array(S * 2);
  for (let r = S - 1; r >= 0; r--) for (let k = 0; k < 2; k++) {
    let s = B[r * 2 + k];
    for (let j = r + 1; j < S; j++) s -= A[r * S + j] * X[j * 2 + k];
    X[r * 2 + k] = s / A[r * S + r];
  }
  const cx = new Float64Array(N), cy = new Float64Array(N), cz = new Float64Array(N);
  for (let i = 0; i < N; i++) { cx[i] = ctrl[i][0]; cy[i] = ctrl[i][1]; cz[i] = ctrl[i][2]; }
  return (a) => {
    let dx = X[N * 2] + X[(N + 1) * 2] * a[0] * U + X[(N + 2) * 2] * a[1] * U + X[(N + 3) * 2] * a[2] * U;
    let dy = X[N * 2 + 1] + X[(N + 1) * 2 + 1] * a[0] * U + X[(N + 2) * 2 + 1] * a[1] * U + X[(N + 3) * 2 + 1] * a[2] * U;
    for (let i = 0; i < N; i++) {
      const r = Math.hypot(a[0] - cx[i], a[1] - cy[i], a[2] - cz[i]) * U;
      dx += X[i * 2] * r; dy += X[i * 2 + 1] * r;
    }
    return [a[0] + dx / U, a[1] + dy / U, a[2]];
  };
}

/** Vertex normals on the welded topology (vertices at one place share a
 *  normal), so seams don't show in the relight term. */
function normalsOn(P3, idx, weld, groups) {
  const acc = new Float64Array(groups * 3);
  for (let f = 0; f < idx.length; f += 3) {
    const a = idx[f] * 3, b = idx[f + 1] * 3, c = idx[f + 2] * 3;
    const ux = P3[b] - P3[a], uy = P3[b + 1] - P3[a + 1], uz = P3[b + 2] - P3[a + 2];
    const vx = P3[c] - P3[a], vy = P3[c + 1] - P3[a + 1], vz = P3[c + 2] - P3[a + 2];
    const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    for (const v of [idx[f], idx[f + 1], idx[f + 2]]) { const w = weld[v] * 3; acc[w] += nx; acc[w + 1] += ny; acc[w + 2] += nz; }
  }
  const out = new Float32Array(weld.length * 3);
  for (let i = 0; i < weld.length; i++) {
    const w = weld[i] * 3, l = Math.hypot(acc[w], acc[w + 1], acc[w + 2]) || 1;
    out[i * 3] = acc[w] / l; out[i * 3 + 1] = acc[w + 1] / l; out[i * 3 + 2] = acc[w + 2] / l;
  }
  return out;
}

function q16(f, mx) {
  const s = mx > 0 ? 32767 / mx : 0, o = new Int16Array(f.length);
  for (let i = 0; i < f.length; i++) o[i] = Math.round(f[i] * s);
  return o;
}

const centroid = (pts) => pts.reduce((a, p) => [a[0] + p[0] / pts.length, a[1] + p[1] / pts.length, a[2] + (p[2] || 0) / pts.length], [0, 0, 0]);
const img = (p) => [p[0], -p[1]]; // world (y up) to image (row down)

/**
 * The head fitted to a photo's landmarks, with no pixels involved.
 * base: { meta: { vertices, shapes }, arr(name) } of a base head;
 * P: the photo's 478 landmarks as [x, y, z] in world units (pixels, y up,
 * z toward the camera); W, H: the photo's size.
 * Returns { arrays, meta, report }: the head file's arrays, its header
 * fields that come from geometry, and numbers for the fit's report.
 */
export function fitGeometry(base, P, W, H) {
  const N = base.meta.vertices;
  const bpos = base.arr('head.pos'), idx = base.arr('head.idx'), blm = base.arr('landmarks');
  const at = (a, i) => [a[i * 3], a[i * 3 + 1], a[i * 3 + 2]];

  // the similarity, from the landmarks the base has (not the irises)
  const src = [], dst = [];
  for (let i = 0; i < 468; i++) {
    if (Number.isNaN(blm[i * 3])) continue;
    src.push(at(blm, i)); dst.push(P[i]);
  }
  const sim = similarity2D(src, dst);
  let e0 = 0;
  const aligned = src.map((s, i) => { const a = sim.apply(s); e0 += Math.hypot(a[0] - dst[i][0], a[1] - dst[i][1]); return a; });

  // the warp onto the photo's landmarks
  const ctl = [], disp = [];
  for (let i = 0; i < aligned.length; i++) {
    const c = aligned[i];
    if (ctl.some((o) => Math.hypot(o[0] - c[0], o[1] - c[1], o[2] - c[2]) < 1.5)) continue;
    ctl.push(c); disp.push([dst[i][0] - c[0], dst[i][1] - c[1]]);
  }
  const warp = solveRbf(ctl, disp, 2e-3, 1 / sim.scale);
  const full = (v) => warp(sim.apply(v));
  let e1 = 0;
  for (let i = 0; i < src.length; i++) { const w = full(src[i]); e1 += Math.hypot(w[0] - dst[i][0], w[1] - dst[i][1]); }

  // the head: positions and the photo projection
  const pos = new Float32Array(N * 3), uv = new Float32Array(N * 2), uvC = new Float32Array(N * 2);
  for (let i = 0; i < N; i++) {
    const w = full(at(bpos, i));
    pos.set(w, i * 3); uv.set([w[0] / W, 1 + w[1] / H], i * 2);
  }
  // where each vertex lands with both eyes shut: the closed portrait's projection
  const bl = base.arr('shape.eyeBlink_L.pos'), br = base.arr('shape.eyeBlink_R.pos');
  for (let i = 0; i < N; i++) {
    const d = [bl[i * 3] + br[i * 3], bl[i * 3 + 1] + br[i * 3 + 1], bl[i * 3 + 2] + br[i * 3 + 2]];
    if (!d[0] && !d[1] && !d[2]) { uvC[i * 2] = uv[i * 2]; uvC[i * 2 + 1] = uv[i * 2 + 1]; continue; }
    const w = full([bpos[i * 3] + d[0], bpos[i * 3 + 1] + d[1], bpos[i * 3 + 2] + d[2]]);
    uvC.set([w[0] / W, 1 + w[1] / H], i * 2);
  }
  // welded topology: vertices at one place (to 1e-4) share a normal
  const weld = new Int32Array(N), keys = new Map();
  for (let i = 0; i < N; i++) {
    const k = Math.round(bpos[i * 3] * 1e4) + ',' + Math.round(bpos[i * 3 + 1] * 1e4) + ',' + Math.round(bpos[i * 3 + 2] * 1e4);
    if (!keys.has(k)) keys.set(k, keys.size);
    weld[i] = keys.get(k);
  }
  const nrm = normalsOn(pos, idx, weld, keys.size);

  // the 52 shapes, carried through the warp
  const arrays = { 'head.pos': pos, 'head.nrm': nrm, 'head.uv': uv, 'head.uvC': uvC, 'head.idx': N < 65536 ? new Uint16Array(idx) : new Uint32Array(idx) };
  const shapeScale = [];
  let jaw = null;
  for (const name of SHAPES) {
    const bd = base.arr('shape.' + name + '.pos');
    const dp = new Float32Array(N * 3), mp = new Float32Array(pos);
    let mx = 0;
    for (let i = 0; i < N; i++) {
      const d = at(bd, i);
      if (!d[0] && !d[1] && !d[2]) continue;
      const w = full([bpos[i * 3] + d[0], bpos[i * 3 + 1] + d[1], bpos[i * 3 + 2] + d[2]]);
      for (let k = 0; k < 3; k++) { const v = w[k] - pos[i * 3 + k]; dp[i * 3 + k] = v; mp[i * 3 + k] = w[k]; mx = Math.max(mx, Math.abs(v)); }
    }
    let dn = new Float32Array(N * 3), mxn = 0;
    if (mx > 0) {
      const mn = normalsOn(mp, idx, weld, keys.size);
      for (let i = 0; i < N * 3; i++) { dn[i] = mn[i] - nrm[i]; mxn = Math.max(mxn, Math.abs(dn[i])); }
    }
    arrays['shape.' + name + '.pos'] = q16(dp, mx);
    arrays['shape.' + name + '.nrm'] = q16(dn, mxn);
    shapeScale.push([mx, mxn]);
    if (name === 'jawOpen') {
      // the lower teeth ride on the mean of the 40 vertices that move most
      const order = [...Array(N).keys()].sort((a, b) => Math.hypot(dp[b * 3], dp[b * 3 + 1], dp[b * 3 + 2]) - Math.hypot(dp[a * 3], dp[a * 3 + 1], dp[a * 3 + 2]));
      const top = order.slice(0, Math.min(40, N));
      jaw = [0, 0, 0];
      for (const i of top) for (let k = 0; k < 3; k++) jaw[k] += dp[i * 3 + k] / top.length;
    }
  }
  // the teeth, through the same warp
  const tb = base.arr('teeth.pos'), tpos = new Float32Array(tb.length);
  for (let i = 0; i < tb.length / 3; i++) tpos.set(full(at(tb, i)), i * 3);
  arrays['teeth.pos'] = tpos;
  const tidx = base.arr('teeth.idx');
  arrays['teeth.idx'] = tb.length / 3 < 65536 ? new Uint16Array(tidx) : new Uint32Array(tidx);

  // the photo's own features, in image pixels (row down)
  const lm = (i) => img(P[i]);
  const eyes = [EYE_A, EYE_B].map((ids) => {
    const outline = ids.map((i) => P[i]);
    const c = centroid(outline);
    const xs = outline.map((p) => p[0]);
    return { center: img(c), width: Math.max(...xs) - Math.min(...xs), outline: outline.map(img) };
  });
  const irises = [468, 473].map((ci) => {
    const c = P[ci];
    const r = [1, 2, 3, 4].reduce((s, k) => s + Math.hypot(P[ci + k][0] - c[0], P[ci + k][1] - c[1]), 0) / 4;
    return [c[0], -c[1], r];
  });
  for (const e of eyes) e.iris = irises.reduce((b, I) => (!b || Math.hypot(I[0] - e.center[0], I[1] - e.center[1]) < Math.hypot(b[0] - e.center[0], b[1] - e.center[1]) ? I : b), null);
  eyes.sort((a, b) => a.center[0] - b.center[0]);
  const meta = {
    kind: 'head', vertices: N, image: [W, H], shapes: SHAPES, shapeScale,
    face: { noseTip: lm(1), chin: lm(152), forehead: lm(10), left: lm(234), right: lm(454) },
    mouth: { center: img(centroid(LIP_IN.map((i) => P[i]))), left: lm(61), right: lm(291), inner: LIP_IN.map(lm), outer: LIP_OUT.map(lm), jaw },
    eyes,
  };
  const report = {
    pairs: src.length, controls: ctl.length, scale: sim.scale, rotation: (sim.theta * 180) / Math.PI,
    residualSimilarity: e0 / src.length, residualWarp: e1 / src.length,
  };
  return { arrays, meta, report };
}

// ---------- the checks ----------

// The fit's refusals and warnings, exactly as the spec's table ("Fitting a portrait").
export const MESSAGES = {
  'no-face': 'No face found. Use a clear photo of one face.',
  faces: "There's more than one face. Use a photo of one person.",
  turned: 'The face is turned. Use a photo facing the camera.',
  'mouth-open': 'The mouth is open. Use a photo with the mouth closed.',
  'eyes-closed': 'The eyes are closed. Use a photo with the eyes open; add an eyes-closed version after.',
  small: 'The face is too small. Use a larger photo.',
  soft: 'This will look soft. A larger photo looks sharper.',
  bands: 'A photo wider than tall fills the window; this one leaves bands at the sides.',
  'closed-moved': "This eyes-closed photo doesn't line up with the portrait. Change only the eyes.",
  'closed-open': 'The eyes in the eyes-closed photo are open. Close the eyes and change nothing else.',
};
const score = (res, face, name) => {
  const c = res.faceBlendshapes?.[face]?.categories?.find((x) => x.categoryName === name);
  return c ? c.score : 0;
};

// The landmarker reads a face looking into the lens as pitched about 11°
// (its canonical face leans back): the butler, frontal, reads 10.3–12.5° in
// every crop, while its yaw reads within 1.2° of 0.
const FRONTAL_PITCH = 11;

/** How far the face turns from looking into the lens, in degrees: the
 *  angle of its forward axis from frontal (yaw as the landmarker reads it,
 *  pitch less the landmarker's own 11°), from the landmarker's
 *  transformation matrix (column-major 4×4). Where the face sits in the
 *  frame doesn't count. */
export function turnedBy(matrix) {
  const m = matrix?.data || matrix;
  if (!m || m.length < 16) return 0;
  const f = [m[8], m[9], m[10]];
  const yaw = (Math.atan2(f[0], f[2]) * 180) / Math.PI;
  const pitch = (Math.atan2(-f[1], f[2]) * 180) / Math.PI - FRONTAL_PITCH;
  return Math.hypot(yaw, pitch);
}

/** What the checks look at, from the landmarker's result on a W×H photo:
 *  { faces, turned (°), jawOpen, lipGap (px between the inner lips),
 *  blinkLeft, blinkRight, faceWidth (px, cheek to cheek), width, height }. */
export function photoFacts(res, W, H) {
  const faces = res.faceLandmarks?.length || 0;
  const facts = { faces, turned: 0, jawOpen: 0, lipGap: 0, blinkLeft: 0, blinkRight: 0, faceWidth: 0, width: W, height: H };
  if (!faces) return facts;
  const L = res.faceLandmarks[0];
  const px = (i) => [L[i].x * W, L[i].y * H];
  const d = (a, b) => Math.hypot(px(a)[0] - px(b)[0], px(a)[1] - px(b)[1]);
  facts.turned = turnedBy(res.facialTransformationMatrixes?.[0]);
  facts.jawOpen = score(res, 0, 'jawOpen');
  facts.lipGap = d(13, 14);
  facts.blinkLeft = score(res, 0, 'eyeBlinkLeft');
  facts.blinkRight = score(res, 0, 'eyeBlinkRight');
  facts.faceWidth = d(234, 454);
  return facts;
}

/** The still's checks, the spec's table in its order: { ok, code?,
 *  message?, warnings }. The first refusal is the one said; warnings are
 *  given either way. */
export function judgePhoto(f) {
  const warnings = [];
  if (f.faces === 1 && f.faceWidth >= 250 && f.faceWidth < 500) warnings.push(MESSAGES.soft);
  if (f.height > f.width) warnings.push(MESSAGES.bands);
  const refuse = (code) => ({ ok: false, code, message: MESSAGES[code], warnings });
  if (!f.faces) return refuse('no-face');
  if (f.faces > 1) return refuse('faces');
  if (f.turned > 8) return refuse('turned');
  // open: the landmarker's jaw score, or the inner lips apart (teeth showing)
  if (f.jawOpen >= 0.2 || f.lipGap > 0.025 * f.faceWidth) return refuse('mouth-open');
  if (f.blinkLeft >= 0.5 || f.blinkRight >= 0.5) return refuse('eyes-closed');
  if (f.faceWidth < 250) return refuse('small');
  return { ok: true, warnings };
}

/** How far the closed photo's landmarks outside the eyes are from the
 *  still's, on average, in pixels. */
export function closedShift(open, closed, W, H) {
  // what may move: the eyes, the lids and the creases above them, within
  // 0.8 of an eye's width of its centre
  const zone = [EYE_A, EYE_B].map((ids) => {
    const xs = ids.map((i) => open[i].x * W), ys = ids.map((i) => open[i].y * H);
    return { x: xs.reduce((a, b) => a + b) / xs.length, y: ys.reduce((a, b) => a + b) / ys.length, r: 0.8 * (Math.max(...xs) - Math.min(...xs)) };
  });
  let s = 0, n = 0;
  for (let i = 0; i < 468; i++) {
    const x = open[i].x * W, y = open[i].y * H;
    if (zone.some((z) => Math.hypot(x - z.x, y - z.y) < z.r)) continue;
    s += Math.hypot((open[i].x - closed[i].x) * W, (open[i].y - closed[i].y) * H);
    n++;
  }
  return n ? s / n : 0;
}

/** The eyes-closed photo's checks: { sameSize, faces, shift (px, from
 *  closedShift), blinkLeft, blinkRight } in, { ok, code?, message? } out.
 *  Another size, no face or a shift over 12 px don't line up. */
export function judgeClosed(f) {
  if (!f.sameSize || f.faces < 1 || !(f.shift <= 12)) return { ok: false, code: 'closed-moved', message: MESSAGES['closed-moved'] };
  if (f.blinkLeft < 0.5 || f.blinkRight < 0.5) return { ok: false, code: 'closed-open', message: MESSAGES['closed-open'] };
  return { ok: true };
}

// ---------- in the browser ----------

/** SHA-256 of some bytes, as lowercase hex: the still's fingerprint in
 *  the head, so a head isn't drawn over another photo of the same size. */
export async function sha256Hex(buf) {
  const d = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** An image's pixels as the browser shows it (a phone photo's EXIF
 *  orientation applied) in a canvas, and its bytes when it came as a URL or
 *  a Blob. src: a Blob or File, a URL, an image element, an ImageBitmap or
 *  a canvas. A URL is fetched with no-cache (a cheap revalidation), so a
 *  file changed on disk is seen at once. The avatar decodes its still the
 *  same way, so the fit and the drawing agree. */
export async function readImage(src) {
  let bytes = null, blob = null;
  if (typeof src === 'string') {
    const r = await fetch(src, { cache: 'no-cache' });
    if (!r.ok) throw new Error("the image didn't load");
    bytes = await r.arrayBuffer();
    blob = new Blob([bytes], { type: r.headers.get('Content-Type') || '' });
  } else if (typeof Blob !== 'undefined' && src instanceof Blob) {
    blob = src;
    bytes = await src.arrayBuffer();
  }
  let source = src;
  if (blob) {
    const url = URL.createObjectURL(blob);
    source = new Image();
    source.decoding = 'async';
    try {
      await new Promise((ok, no) => { source.onload = ok; source.onerror = () => no(new Error("the image didn't load")); source.src = url; });
      if (source.decode) await source.decode().catch(() => {});
    } finally { URL.revokeObjectURL(url); }
  } else if (src && src.complete === false) {
    await new Promise((ok, no) => { src.onload = ok; src.onerror = () => no(new Error("the image didn't load")); });
  }
  const w = source.naturalWidth || source.videoWidth || source.width, h = source.naturalHeight || source.videoHeight || source.height;
  if (!w || !h) throw new Error("the image didn't load");
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  c.getContext('2d').drawImage(source, 0, 0, w, h);
  return { canvas: c, bytes };
}

/** readImage's canvas alone. */
export async function loadImage(src) {
  return (await readImage(src)).canvas;
}

const ASSETS = '/desk/assets/';
let landmarkerFor = null; // one landmarker per assets folder, made once

async function landmarker(assets) {
  if (landmarkerFor && landmarkerFor.assets === assets) return landmarkerFor.ready;
  const ready = (async () => {
    const { FaceLandmarker, FilesetResolver } = await import(assets + 'mediapipe/vision_bundle.mjs');
    const fileset = await FilesetResolver.forVisionTasks(assets + 'mediapipe/wasm');
    return FaceLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: assets + 'mediapipe/face_landmarker.task', delegate: 'CPU' },
      runningMode: 'IMAGE', numFaces: 2, outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true,
    });
  })();
  landmarkerFor = { assets, ready };
  ready.catch(() => { if (landmarkerFor && landmarkerFor.ready === ready) landmarkerFor = null; });
  return ready;
}

// the fit files missing (desk-assets), or WebAssembly not allowed
const NO_START = "Fitting couldn't start: its files (desk-assets) are missing or blocked.";

const inPoly = (poly, x, y) => {
  let ins = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [ax, ay] = poly[i], [bx, by] = poly[j];
    if ((ay > y) !== (by > y) && x < ((bx - ax) * (y - ay)) / (by - ay) + ax) ins = !ins;
  }
  return ins;
};
const edgeDist = (poly, x, y) => {
  let best = Infinity;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [ax, ay] = poly[j], [bx, by] = poly[i], dx = bx - ax, dy = by - ay;
    const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy || 1)));
    best = Math.min(best, Math.hypot(x - ax - t * dx, y - ay - t * dy));
  }
  return best;
};
const luma = (r, g, b) => 0.299 * r + 0.587 * g + 0.114 * b;
const median = (vals, q = 0.5) => { if (!vals.length) return null; const s = [...vals].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(s.length * q))]; };

/** The photo's reflection in an iris: the spot that stands out most from a
 *  small ring round it (a catchlight is an isolated dot, often touching the
 *  upper lid; the lids' wet edges are bright too, but as a band), grown to
 *  the pixels brighter than halfway to the iris. [x, y, r], or null when
 *  there's none. lumaAt(x, y) and inCrop(x, y) read the photo. */
export function findCatchlight(lumaAt, inCrop, icx, icy, ir, irisL) {
  const inIris = (x, y) => inCrop(x, y) && Math.hypot(x - icx, y - icy) <= ir * 0.95;
  const ringR = Math.max(3, ir * 0.22);
  let best = -Infinity, bx = 0, by = 0, bl = 0;
  for (let y = Math.floor(icy - ir); y <= icy + ir; y++) for (let x = Math.floor(icx - ir); x <= icx + ir; x++) {
    if (!inIris(x, y)) continue;
    const l = lumaAt(x, y);
    if (l < 120) continue;
    let ring = 0, m = 0;
    for (let q = 0; q < 12; q++) {
      const rx = Math.round(x + ringR * Math.cos((q * Math.PI) / 6)), ry = Math.round(y + ringR * Math.sin((q * Math.PI) / 6));
      if (inCrop(rx, ry)) { ring += lumaAt(rx, ry); m++; }
    }
    const score = l - ring / (m || 1);
    if (score > best) { best = score; bx = x; by = y; bl = l; }
  }
  if (!(best > 50)) return null;
  const th = (bl + irisL) / 2, reach = ringR;
  let sx = 0, sy = 0, sn = 0;
  for (let y = Math.floor(by - reach); y <= by + reach; y++) for (let x = Math.floor(bx - reach); x <= bx + reach; x++) {
    if (!inCrop(x, y) || Math.hypot(x - bx, y - by) > reach || lumaAt(x, y) <= th) continue;
    sx += x; sy += y; sn++;
  }
  return sn ? [sx / sn, sy / sn, Math.max(2, Math.sqrt(sn / Math.PI))] : null;
}

/** The eyeballs' texture: a crop round both eyes with the photo's
 *  reflections removed and each iris completed under the lids (by its
 *  mirror image), keeping a band of photo round the lids; plus where each
 *  reflection was. Mutates meta.eyes (catchlight) and sets meta.eyeCrop. */
function eyeTexture(photo, meta) {
  const W = photo.width, H = photo.height, eyes = meta.eyes;
  const pad = 0.55;
  const cx0 = Math.max(0, Math.floor(Math.min(...eyes.map((e) => e.center[0] - e.width * (0.5 + pad)))));
  const cx1 = Math.min(W, Math.ceil(Math.max(...eyes.map((e) => e.center[0] + e.width * (0.5 + pad)))));
  const cy0 = Math.max(0, Math.floor(Math.min(...eyes.map((e) => e.center[1] - e.width * (0.35 + pad)))));
  const cy1 = Math.min(H, Math.ceil(Math.max(...eyes.map((e) => e.center[1] + e.width * (0.35 + pad)))));
  const ew = cx1 - cx0, eh = cy1 - cy0;
  const c = document.createElement('canvas');
  c.width = ew; c.height = eh;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(photo, cx0, cy0, ew, eh, 0, 0, ew, eh);
  const img = g.getImageData(0, 0, ew, eh), D = img.data, src = new Uint8ClampedArray(D);
  const at = (x, y) => ((y - cy0) * ew + (x - cx0)) * 4;
  const inCrop = (x, y) => x >= cx0 && x < cx1 && y >= cy0 && y < cy1;
  for (const e of eyes) {
    const [icx, icy, ir] = e.iris, poly = e.outline, k = e.width / 130;
    // the white and the iris, from the photo's own pixels
    const scl = [[], [], []], irs = [[], [], []];
    for (let y = Math.floor(icy - e.width); y < icy + e.width; y++) for (let x = Math.floor(e.center[0] - e.width); x < e.center[0] + e.width; x++) {
      if (!inCrop(x, y) || !inPoly(poly, x, y)) continue;
      const o = at(x, y), d = Math.hypot(x - icx, y - icy);
      const into = d > ir * 1.2 ? scl : d < ir * 0.95 ? irs : null;
      if (into) for (let q = 0; q < 3; q++) into[q].push(src[o + q]);
    }
    const sclera = scl.map((v) => median(v, 0.6) ?? 120), irisCol = irs.map((v) => median(v) ?? 60);
    const lumaAt = (x, y) => { const o = at(x, y); return luma(src[o], src[o + 1], src[o + 2]); };
    const cl = findCatchlight(lumaAt, inCrop, icx, icy, ir, luma(...irisCol));
    e.catchlight = cl;
    // the eye rebuilt
    const R2 = e.width * 1.2, band = 6 * k;
    for (let y = Math.max(cy0, Math.floor(icy - R2)); y < Math.min(cy1, icy + R2); y++) for (let x = Math.max(cx0, Math.floor(icx - R2)); x < Math.min(cx1, icx + R2); x++) {
      const o = at(x, y), d = Math.hypot(x - icx, y - icy);
      let col;
      if (cl && Math.hypot(x - cl[0], y - cl[1]) < cl[2] * 2.2) col = irisCol;
      else if (inPoly(poly, x, y) || edgeDist(poly, x, y) < band) col = null; // the photo, and a band round the lids
      else if (d < ir) {
        const my = Math.round(2 * icy - y);
        col = inCrop(x, my) && inPoly(poly, x, my) ? [src[at(x, my)], src[at(x, my) + 1], src[at(x, my) + 2]] : irisCol;
      } else {
        const f = Math.min(1, (d - ir) / (e.width * 0.9));
        col = sclera.map((v) => v * (1 - 0.35 * f));
      }
      if (col) { D[o] = col[0]; D[o + 1] = col[1]; D[o + 2] = col[2]; }
    }
  }
  g.putImageData(img, 0, 0);
  meta.eyeCrop = [cx0, cy0, ew, eh];
  return c;
}

/** The skin tone a drawn closed lid takes, per eye: the median of the
 *  skin 6–22 px (at the butler's scale) under the lower lid. The open
 *  upper lid is folded into the socket's shadow; a closed lid faces the
 *  light like the skin under the eye (the butler's closed portrait: lids
 *  about 135,119,115, the skin under the eyes about 125,100,100, the band
 *  above the open lids about 52,34,37). */
function lidTones(photo, meta) {
  const g = photo.getContext('2d', { willReadFrequently: true });
  for (const e of meta.eyes) {
    const k = e.width / 130, xs = e.outline.map((p) => p[0]);
    const x0 = Math.floor(Math.min(...xs)), x1 = Math.ceil(Math.max(...xs));
    const y0 = Math.floor(e.center[1]), y1 = Math.min(photo.height, Math.ceil(Math.max(...e.outline.map((p) => p[1])) + 24 * k));
    const w = Math.max(1, x1 - x0), data = g.getImageData(x0, y0, w, Math.max(1, y1 - y0)).data;
    const ch = [[], [], []];
    for (let x = x0 + Math.round(0.15 * (x1 - x0)); x < x1 - 0.15 * (x1 - x0); x++) {
      // the lower lid's edge in this column
      let bottom = null;
      for (let y = y1 - 1; y >= y0; y--) if (inPoly(e.outline, x + 0.5, y + 0.5)) { bottom = y; break; }
      if (bottom === null) continue;
      for (let y = Math.round(bottom + 6 * k); y <= bottom + 22 * k && y < y1; y++) {
        const o = ((y - y0) * w + (x - x0)) * 4;
        for (let q = 0; q < 3; q++) ch[q].push(data[o + q]);
      }
    }
    e.lid = ch.map((v) => Math.round(median(v) ?? 150));
  }
}

/** Where the eyes-closed portrait blends in: a quarter-size mask, red for
 *  the image-left eye and green for the other, soft at the edge. */
function eyeMask(W, H, meta) {
  const S = 4, mw = Math.round(W / S), mh = Math.round(H / S);
  const r = new Float32Array(mw * mh), gr = new Float32Array(mw * mh);
  meta.eyes.forEach((e, k) => {
    const into = k === 0 ? r : gr;
    const cx = e.center[0] / S, cy = (e.center[1] - e.width * 0.12) / S, ax = (e.width * 0.78) / S, ay = (e.width * 0.5) / S;
    for (let y = Math.max(0, Math.floor(cy - ay - 1)); y <= Math.min(mh - 1, cy + ay + 1); y++) for (let x = Math.max(0, Math.floor(cx - ax - 1)); x <= Math.min(mw - 1, cx + ax + 1); x++) {
      if (((x + 0.5 - cx) / ax) ** 2 + ((y + 0.5 - cy) / ay) ** 2 <= 1) into[y * mw + x] = 1;
    }
  });
  // soften: three box blurs each way (about a Gaussian of the prototype's width)
  const rad = Math.max(1, Math.round((meta.eyes[0].width * 0.12) / S / 1.7));
  const blur = (a) => {
    const tmp = new Float32Array(a.length), n = 2 * rad + 1;
    for (let pass = 0; pass < 3; pass++) {
      for (let y = 0; y < mh; y++) for (let x = 0; x < mw; x++) {
        let s = 0;
        for (let d = -rad; d <= rad; d++) s += a[y * mw + Math.min(mw - 1, Math.max(0, x + d))];
        tmp[y * mw + x] = s / n;
      }
      for (let y = 0; y < mh; y++) for (let x = 0; x < mw; x++) {
        let s = 0;
        for (let d = -rad; d <= rad; d++) s += tmp[Math.min(mh - 1, Math.max(0, y + d)) * mw + x];
        a[y * mw + x] = s / n;
      }
    }
  };
  blur(r); blur(gr);
  const c = document.createElement('canvas');
  c.width = mw; c.height = mh;
  const g = c.getContext('2d');
  const img = g.createImageData(mw, mh);
  for (let i = 0; i < mw * mh; i++) { img.data[i * 4] = Math.round(255 * r[i]); img.data[i * 4 + 1] = Math.round(255 * gr[i]); img.data[i * 4 + 3] = 255; }
  g.putImageData(img, 0, 0);
  return c;
}

const toBlob = (c) => new Promise((ok, no) => c.toBlob((b) => (b ? ok(b) : no(new Error("the image couldn't be written"))), 'image/png'));
const scores = (res) => Object.fromEntries((res.faceBlendshapes?.[0]?.categories || []).filter((c) => c.score >= 0.1).map((c) => [c.categoryName, +c.score.toFixed(2)]));

/**
 * Fits a portrait: the pack's head (head.bin), eye texture (eyes.png) and
 * blink mask (eyemask.png). closedPhoto, the same portrait with the eyes
 * closed, is optional and checked against it. Resolves to
 *   { ok, message?, code?, warnings: [], faceWidth, closedUsed,
 *     files: { head: ArrayBuffer, eyes: Blob, eyemask: Blob } | null, report }
 * where message is the plain line for the owner when it's refused (the
 * spec's table) and warnings are lines to show either way.
 * options.assets: where the fit files are (default /desk/assets/).
 */
export async function fit(photo, closedPhoto, options = {}) {
  const assets = options.assets || ASSETS;
  const t0 = performance.now();
  const result = { ok: false, warnings: [], faceWidth: null, closedUsed: false, files: null, report: null };
  const refuse = (code, message, extra) => Object.assign(result, { ok: false, code, message }, extra);
  let still, closed, stillBytes;
  try {
    const [s0, c0] = await Promise.all([readImage(photo), closedPhoto ? readImage(closedPhoto) : null]);
    still = s0.canvas; stillBytes = s0.bytes; closed = c0 && c0.canvas;
  } catch (e) {
    return refuse('image', "The photo didn't open. Use a JPEG or PNG.");
  }
  let lmk, baseBuf;
  try {
    [lmk, baseBuf] = await Promise.all([
      landmarker(assets),
      fetch(assets + 'base-head.bin').then((r) => { if (!r.ok) throw new Error('base-head.bin ' + r.status); return r.arrayBuffer(); }),
    ]);
  } catch (e) {
    console.warn('fit: ' + (e && e.message));
    return refuse('assets', NO_START);
  }
  try {
    const base = readHead(baseBuf);
    if (base.meta.kind !== 'base') return refuse('assets', NO_START);
    const W = still.width, H = still.height;
    const res = lmk.detect(still);
    const facts = photoFacts(res, W, H);
    const verdict = judgePhoto(facts);
    result.warnings = verdict.warnings;
    result.faceWidth = facts.faces === 1 ? Math.round(facts.faceWidth) : null;
    if (!verdict.ok) return refuse(verdict.code, verdict.message);
    let closedShiftPx = null;
    if (closed) {
      const sameSize = closed.width === W && closed.height === H;
      const resC = sameSize ? lmk.detect(closed) : { faceLandmarks: [] };
      const faces = resC.faceLandmarks?.length || 0;
      closedShiftPx = faces ? closedShift(res.faceLandmarks[0], resC.faceLandmarks[0], W, H) : null;
      const c = judgeClosed({ sameSize, faces, shift: closedShiftPx, blinkLeft: score(resC, 0, 'eyeBlinkLeft'), blinkRight: score(resC, 0, 'eyeBlinkRight') });
      if (!c.ok) return refuse(c.code, c.message);
    }
    const L = res.faceLandmarks[0];
    const P = L.map((p) => [p.x * W, -p.y * H, -p.z * W]);
    const g = fitGeometry(base, P, W, H);
    const eyesCanvas = eyeTexture(still, g.meta);
    lidTones(still, g.meta);
    const maskCanvas = eyeMask(W, H, g.meta);
    g.meta.photo = { expression: scores(res), turned: +facts.turned.toFixed(1), faceWidth: result.faceWidth };
    // the still's fingerprint: the pack's still must be these very bytes
    if (stillBytes) g.meta.still = { bytes: stillBytes.byteLength, sha256: await sha256Hex(stillBytes) };
    const head = packHead(g.meta, g.arrays);
    const [eyes, eyemask] = await Promise.all([toBlob(eyesCanvas), toBlob(maskCanvas)]);
    result.report = {
      ...g.report, image: [W, H], turned: g.meta.photo.turned, expression: g.meta.photo.expression, closedShift: closedShiftPx,
      catchlights: g.meta.eyes.map((e) => e.catchlight), lids: g.meta.eyes.map((e) => e.lid), eyeCrop: g.meta.eyeCrop,
      bytes: head.byteLength, ms: Math.round(performance.now() - t0),
    };
    return Object.assign(result, { ok: true, closedUsed: !!closed, files: { head, eyes, eyemask } });
  } catch (e) {
    console.error(e);
    return refuse('failed', "The fit didn't work on this photo. Try another one.");
  }
}
