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

const MESSAGES = {
  'no-face': 'No face found in this photo. Use a photo of one face, facing the camera.',
  faces: 'This photo has more than one face. Use a photo of one face.',
  'eyes-closed': 'Use a photo with the eyes open.',
  'mouth-open': 'Use a photo facing the camera with the mouth closed.',
  'closed-no-face': 'No face found in the eyes-closed photo.',
  'closed-open': 'The eyes in the eyes-closed photo look open. Close the eyes and change nothing else.',
  'closed-moved': "This eyes-closed photo doesn't line up with the portrait. Change only the eyes.",
};
const problem = (code, message) => ({ code, message: message || MESSAGES[code] });
const score = (res, face, name) => {
  const c = res.faceBlendshapes?.[face]?.categories?.find((x) => x.categoryName === name);
  return c ? c.score : 0;
};

/** How far the face turns from the camera, in degrees, from the
 *  landmarker's transformation matrix (column-major 4×4). */
export function turnedBy(matrix) {
  const m = matrix?.data || matrix;
  if (!m || m.length < 16) return 0;
  return (Math.acos(Math.min(1, Math.abs(m[10]))) * 180) / Math.PI;
}

/** The still's checks, on the landmarker's result: null when it's fine. */
export function checkPhoto(res) {
  const n = res.faceLandmarks?.length || 0;
  if (n === 0) return problem('no-face');
  if (n > 1) return problem('faces');
  const deg = turnedBy(res.facialTransformationMatrixes?.[0]);
  if (deg > 8) return problem('turned', `This face is turned about ${Math.round(deg)}° from the camera. Use a photo facing the camera.`);
  if (score(res, 0, 'eyeBlinkLeft') >= 0.5 || score(res, 0, 'eyeBlinkRight') >= 0.5) return problem('eyes-closed');
  if (score(res, 0, 'jawOpen') >= 0.2) return problem('mouth-open');
  return null;
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

/** The eyes-closed photo's checks against the still's result. */
export function checkClosed(openRes, closedRes, W, H, W2, H2) {
  if (W2 !== W || H2 !== H) return problem('closed-size', `This eyes-closed photo is ${W2}×${H2}; the portrait is ${W}×${H}. Use the same picture with only the eyes changed.`);
  if (!closedRes.faceLandmarks?.length) return problem('closed-no-face');
  if (closedShift(openRes.faceLandmarks[0], closedRes.faceLandmarks[0], W, H) > 12) return problem('closed-moved');
  if (score(closedRes, 0, 'eyeBlinkLeft') < 0.5 || score(closedRes, 0, 'eyeBlinkRight') < 0.5) return problem('closed-open');
  return null;
}
