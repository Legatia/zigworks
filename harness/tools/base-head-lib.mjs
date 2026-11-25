// Dev only: the pure parts of the base-head maker (make-base-head.mjs).
// ICT-FaceKit's OBJ files read, its expressions mapped onto the 52 ARKit
// names the avatar uses, the head's region cut, and a simplifier that keeps
// vertices where they are, so every expression's deltas carry over exactly.
import { SHAPES } from '../src/desk/fit.js';

/** ICT's files for each ARKit name, summed; [] is a zero shape. ICT splits
 *  browInnerUp and cheekPuff into _L and _R (their masks overlap so the sum
 *  is the whole shape) and has no tongueOut. */
export const ARKIT_FROM_ICT = Object.fromEntries(SHAPES.map((s) => [s,
  s === 'browInnerUp' || s === 'cheekPuff' ? [s + '_L', s + '_R'] : s === 'tongueOut' ? [] : [s]]));

/** The files the maker needs from ICT-FaceKit's FaceXModel/: the neutral
 *  head and the 53 expressions the mapping reads. */
export const ICT_FILES = ['generic_neutral_mesh.obj',
  ...[...new Set(Object.values(ARKIT_FROM_ICT).flat())].sort().map((n) => n + '.obj')];

/** ICT's vertex ranges (its README's table), inclusive. */
export const ICT = {
  face: [0, 9408], headNeck: [9409, 11247], mouthSocket: [11248, 13293], gumsTongue: [14062, 17038],
  teeth: [17039, 21450], eyeballLeft: [21451, 23020], eyeballRight: [23021, 24590],
  irisLeft: [22221, 23020], irisRight: [23791, 24590], vertices: 26719,
};

/** An OBJ's vertices and faces (0-based vertex indices; texture and normal
 *  indices dropped). */
export function parseObj(text) {
  const pos = [], faces = [];
  for (const line of text.split('\n')) {
    if (line.startsWith('v ')) {
      const p = line.trim().split(/\s+/);
      pos.push(+p[1], +p[2], +p[3]);
    } else if (line.startsWith('f ')) {
      faces.push(line.trim().split(/\s+/).slice(1).map((s) => parseInt(s, 10) - 1));
    }
  }
  return { pos: new Float64Array(pos), faces };
}

const dist = (pos, a, b) => Math.hypot(pos[a * 3] - pos[b * 3], pos[a * 3 + 1] - pos[b * 3 + 1], pos[a * 3 + 2] - pos[b * 3 + 2]);

/** Triangles from faces: a quad split on its shorter diagonal, a larger
 *  polygon fanned. */
export function triangulate(faces, pos) {
  const out = [];
  for (const f of faces) {
    if (f.length === 3) out.push(f[0], f[1], f[2]);
    else if (f.length === 4) {
      const [a, b, c, d] = f;
      if (dist(pos, a, c) <= dist(pos, b, d)) out.push(a, b, c, a, c, d);
      else out.push(a, b, d, b, c, d);
    } else for (let i = 1; i + 1 < f.length; i++) out.push(f[0], f[i], f[i + 1]);
  }
  return new Uint32Array(out);
}

/** Area-weighted vertex normals, unit length. */
export function vertexNormals(pos, idx) {
  const out = new Float64Array(pos.length);
  for (let t = 0; t < idx.length; t += 3) {
    const nn = triNormal(pos, idx[t], idx[t + 1], idx[t + 2]);
    for (let k = 0; k < 3; k++) for (let q = 0; q < 3; q++) out[idx[t + k] * 3 + q] += nn[q];
  }
  for (let i = 0; i < out.length; i += 3) { const l = Math.hypot(out[i], out[i + 1], out[i + 2]) || 1; out[i] /= l; out[i + 1] /= l; out[i + 2] /= l; }
  return out;
}

/** Whether a vertex is neck, not head: below the jaw's contour seen from
 *  the front (jaw.contour: [|x|, y] from the chin out, level past its end)
 *  and facing the camera (normal z over jaw.facing), or below jaw.floor.
 *  The jaw's underside faces down, so it stays, as on a whole head. */
export function isNeck(pos, nrm, jaw) {
  const C = jaw.contour, last = C[C.length - 1];
  const yAt = (ax) => {
    if (ax >= last[0]) return last[1];
    for (let i = 1; i < C.length; i++) if (ax <= C[i][0]) { const [x0, y0] = C[i - 1], [x1, y1] = C[i]; return y0 + ((y1 - y0) * (ax - x0)) / (x1 - x0 || 1); }
    return C[0][1];
  };
  return (i) => {
    const x = pos[i * 3], y = pos[i * 3 + 1];
    if (y < jaw.floor) return true;
    return y < yAt(Math.abs(x)) && nrm[i * 3 + 2] > jaw.facing;
  };
}

/** The vertices of a fold hidden behind the surface in front of it (seen
 *  from +z), reached from `seeds` through hidden vertices only: an opening's
 *  edge that tucks in behind its rim. A vertex is hidden when a triangle
 *  not its own covers it more than `eps` nearer the front. */
export function foldsBehind({ pos, idx, seeds, eps }) {
  const n = pos.length / 3, T = idx.length / 3;
  const adj = Array.from({ length: n }, () => new Set());
  for (let t = 0; t < T; t++) for (let k = 0; k < 3; k++) { const a = idx[t * 3 + k], b = idx[t * 3 + (k + 1) % 3]; adj[a].add(b); adj[b].add(a); }
  // the triangles on a grid of their x/y boxes
  const cell = 0.5, grid = new Map(), key = (gx, gy) => gx * 100003 + gy;
  for (let t = 0; t < T; t++) {
    const xs = [0, 1, 2].map((k) => pos[idx[t * 3 + k] * 3]), ys = [0, 1, 2].map((k) => pos[idx[t * 3 + k] * 3 + 1]);
    for (let gx = Math.floor(Math.min(...xs) / cell); gx <= Math.floor(Math.max(...xs) / cell); gx++) {
      for (let gy = Math.floor(Math.min(...ys) / cell); gy <= Math.floor(Math.max(...ys) / cell); gy++) {
        const g = grid.get(key(gx, gy)); if (g) g.push(t); else grid.set(key(gx, gy), [t]);
      }
    }
  }
  const hidden = (v) => {
    const x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
    for (const t of grid.get(key(Math.floor(x / cell), Math.floor(y / cell))) || []) {
      const a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
      if (a === v || b === v || c === v) continue;
      const ax = pos[a * 3], ay = pos[a * 3 + 1], bx = pos[b * 3], by = pos[b * 3 + 1], cx = pos[c * 3], cy = pos[c * 3 + 1];
      const den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
      if (Math.abs(den) < 1e-12) continue;
      const l1 = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / den, l2 = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / den, l3 = 1 - l1 - l2;
      if (l1 < 0 || l2 < 0 || l3 < 0) continue;
      if (l1 * pos[a * 3 + 2] + l2 * pos[b * 3 + 2] + l3 * pos[c * 3 + 2] > z + eps) return true;
    }
    return false;
  };
  const out = new Set(), todo = seeds.filter(hidden);
  for (const s of todo) out.add(s);
  while (todo.length) {
    const v = todo.pop();
    for (const w of adj[v]) if (!out.has(w) && hidden(w)) { out.add(w); todo.push(w); }
  }
  return out;
}

/** The used vertices, renumbered in their order: map[old] = new or -1. */
export function compact(idx, n) {
  const map = new Int32Array(n).fill(-1);
  for (const v of idx) map[v] = 0;
  let kept = 0;
  for (let i = 0; i < n; i++) if (map[i] === 0) map[i] = kept++;
  return { map, kept };
}

// ---------- the simplifier ----------

class Heap {
  constructor() { this.k = []; this.v = []; }
  push(key, val) {
    const k = this.k, v = this.v;
    let i = k.length; k.push(key); v.push(val);
    while (i > 0) { const p = (i - 1) >> 1; if (k[p] <= key) break; k[i] = k[p]; v[i] = v[p]; i = p; }
    k[i] = key; v[i] = val;
  }
  pop() {
    const k = this.k, v = this.v, top = v[0], key = k[0];
    const lk = k.pop(), lv = v.pop();
    if (k.length) {
      let i = 0;
      for (;;) {
        let c = 2 * i + 1;
        if (c >= k.length) break;
        if (c + 1 < k.length && k[c + 1] < k[c]) c++;
        if (k[c] >= lk) break;
        k[i] = k[c]; v[i] = v[c]; i = c;
      }
      k[i] = lk; v[i] = lv;
    }
    return [key, top];
  }
  get size() { return this.k.length; }
}

const triNormal = (P, a, b, c) => {
  const ux = P[b * 3] - P[a * 3], uy = P[b * 3 + 1] - P[a * 3 + 1], uz = P[b * 3 + 2] - P[a * 3 + 2];
  const vx = P[c * 3] - P[a * 3], vy = P[c * 3 + 1] - P[a * 3 + 1], vz = P[c * 3 + 2] - P[a * 3 + 2];
  return [uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx];
};
const minAngle = (P, a, b, c) => {
  const ang = (o, p, q) => {
    const ux = P[p * 3] - P[o * 3], uy = P[p * 3 + 1] - P[o * 3 + 1], uz = P[p * 3 + 2] - P[o * 3 + 2];
    const vx = P[q * 3] - P[o * 3], vy = P[q * 3 + 1] - P[o * 3 + 1], vz = P[q * 3 + 2] - P[o * 3 + 2];
    const l = Math.hypot(ux, uy, uz) * Math.hypot(vx, vy, vz);
    return l ? Math.acos(Math.max(-1, Math.min(1, (ux * vx + uy * vy + uz * vz) / l))) : 0;
  };
  return Math.min(ang(a, b, c), ang(b, c, a), ang(c, a, b));
};

/**
 * Simplifies a triangle mesh by half-edge collapses (u merged into a
 * neighbour v, which stays where it is), cheapest first by the quadric
 * error summed over the poses (each pose: the same vertices, moved).
 * Locked vertices and the open boundary's are never removed. A collapse is
 * refused when it would break the surface's manifoldness, flip a triangle
 * in any pose, or make a triangle sharper than 8° (or than it was).
 * weight (optional, per vertex) scales a vertex's error: more weight, more
 * of the surface round it kept.
 * { pos, idx, poses: [Float64Array], lock: Uint8Array, weight?, target } →
 * the new triangles over the same vertices.
 */
export function simplify({ pos, idx, poses, lock, weight = null, target }) {
  const n = pos.length / 3, P = poses.length;
  const tris = Array.from(idx);
  const T = tris.length / 3;
  const alive = new Uint8Array(T).fill(1);
  const vt = Array.from({ length: n }, () => []);
  for (let t = 0; t < T; t++) for (let k = 0; k < 3; k++) vt[tris[t * 3 + k]].push(t);
  // the open boundary is locked too
  const locked = new Uint8Array(lock);
  {
    const ec = new Map();
    for (let t = 0; t < T; t++) for (let k = 0; k < 3; k++) {
      const a = tris[t * 3 + k], b = tris[t * 3 + (k + 1) % 3], key = a < b ? a * n + b : b * n + a;
      ec.set(key, (ec.get(key) || 0) + 1);
    }
    for (const [key, c] of ec) if (c === 1) { locked[Math.floor(key / n)] = 1; locked[key % n] = 1; }
  }
  // quadrics: P × n × 10 (a²,ab,ac,ad,b²,bc,bd,c²,cd,d²), area-weighted
  const Q = new Float64Array(P * n * 10);
  for (let p = 0; p < P; p++) {
    const X = poses[p];
    for (let t = 0; t < T; t++) {
      const a = tris[t * 3], b = tris[t * 3 + 1], c = tris[t * 3 + 2];
      const nn = triNormal(X, a, b, c), l = Math.hypot(...nn);
      if (!l) continue;
      const nx = nn[0] / l, ny = nn[1] / l, nz = nn[2] / l, d = -(nx * X[a * 3] + ny * X[a * 3 + 1] + nz * X[a * 3 + 2]), w = l / 2;
      const q = [nx * nx, nx * ny, nx * nz, nx * d, ny * ny, ny * nz, ny * d, nz * nz, nz * d, d * d];
      for (const v of [a, b, c]) { const o = (p * n + v) * 10, wv = w * (weight ? weight[v] : 1); for (let k = 0; k < 10; k++) Q[o + k] += wv * q[k]; }
    }
  }
  const cost = (u, v) => {
    let e = 0;
    for (let p = 0; p < P; p++) {
      const X = poses[p], x = X[v * 3], y = X[v * 3 + 1], z = X[v * 3 + 2];
      const ou = (p * n + u) * 10, ov = (p * n + v) * 10, q = (k) => Q[ou + k] + Q[ov + k];
      e += q(0) * x * x + 2 * q(1) * x * y + 2 * q(2) * x * z + 2 * q(3) * x + q(4) * y * y + 2 * q(5) * y * z + 2 * q(6) * y + q(7) * z * z + 2 * q(8) * z + q(9);
    }
    return Math.max(0, e);
  };
  const ver = new Uint32Array(n);
  const neighbours = (v) => {
    const s = new Set();
    for (const t of vt[v]) if (alive[t]) for (let k = 0; k < 3; k++) s.add(tris[t * 3 + k]);
    s.delete(v);
    return s;
  };
  const heap = new Heap();
  const pushEdges = (v) => {
    for (const w of neighbours(v)) {
      if (!locked[v]) heap.push(cost(v, w), [v, w, ver[v], ver[w]]);
      if (!locked[w]) heap.push(cost(w, v), [w, v, ver[w], ver[v]]);
    }
  };
  for (let v = 0; v < n; v++) if (!locked[v]) for (const w of neighbours(v)) heap.push(cost(v, w), [v, w, ver[v], ver[w]]);

  const used = new Uint8Array(n);
  for (const v of tris) used[v] = 1;
  let count = used.reduce((a, b) => a + b, 0);
  const dead = new Uint8Array(n);
  const MIN = (8 * Math.PI) / 180;

  const canCollapse = (u, v) => {
    // the link condition: u and v share exactly the vertices opposite their edge
    const nu = neighbours(u), nv = neighbours(v);
    if (!nu.has(v)) return false;
    const opposite = new Set();
    let shared = 0;
    for (const t of vt[u]) {
      if (!alive[t]) continue;
      const tv = [tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]];
      if (tv.includes(v)) { shared++; for (const x of tv) if (x !== u && x !== v) opposite.add(x); }
    }
    if (shared < 1 || shared > 2) return false;
    for (const x of nu) if (x !== v && nv.has(x) && !opposite.has(x)) return false;
    // the triangles that keep u, moved to v: no flip in any pose, not too sharp
    for (const t of vt[u]) {
      if (!alive[t]) continue;
      const tv = [tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]];
      if (tv.includes(v)) continue;
      const nt = tv.map((x) => (x === u ? v : x));
      for (let p = 0; p < P; p++) {
        const a = triNormal(poses[p], ...tv), b = triNormal(poses[p], ...nt);
        const la = Math.hypot(...a), lb = Math.hypot(...b);
        if (!lb || (la && (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (la * lb) < 0.3)) return false;
      }
      if (minAngle(pos, ...nt) < Math.min(MIN, minAngle(pos, ...tv))) return false;
    }
    return true;
  };

  while (count > target && heap.size) {
    const [, [u, v, vu, vv]] = heap.pop();
    if (dead[u] || dead[v] || ver[u] !== vu || ver[v] !== vv) continue;
    if (!canCollapse(u, v)) continue;
    for (const t of vt[u]) {
      if (!alive[t]) continue;
      let hasV = false;
      for (let k = 0; k < 3; k++) if (tris[t * 3 + k] === v) hasV = true;
      if (hasV) { alive[t] = 0; continue; }
      for (let k = 0; k < 3; k++) if (tris[t * 3 + k] === u) tris[t * 3 + k] = v;
      vt[v].push(t);
    }
    vt[u] = [];
    for (let p = 0; p < P; p++) { const ou = (p * n + u) * 10, ov = (p * n + v) * 10; for (let k = 0; k < 10; k++) Q[ov + k] += Q[ou + k]; }
    dead[u] = 1; count--;
    vt[v] = vt[v].filter((t) => alive[t]);
    ver[v]++;
    for (const w of neighbours(v)) ver[w]++;
    pushEdges(v);
    for (const w of neighbours(v)) pushEdges(w);
  }
  const out = [];
  for (let t = 0; t < T; t++) if (alive[t]) out.push(tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]);
  return new Uint32Array(out);
}

/** An eyeBlink shape that closes the lids fully: each upper-margin point
 *  (upper) whose blink stops short of the lower margin (lower, with its
 *  own blink motion) goes on to `overlap` past it, and the lid above
 *  follows, the correction fading out over `reach` from the margin. The
 *  head keeps no lid rim behind the margin, so a blink that stops short
 *  would leave a sliver of the eye open. Returns the new deltas. */
export function sealBlink({ pos, delta, upper, lower, overlap, reach }) {
  const out = new Float32Array(delta);
  const lo = lower.map((v) => [pos[v * 3] + delta[v * 3], pos[v * 3 + 1] + delta[v * 3 + 1]]).sort((a, b) => a[0] - b[0]);
  const yLow = (x) => {
    for (let i = 1; i < lo.length; i++) if (x >= lo[i - 1][0] && x <= lo[i][0]) { const t = (x - lo[i - 1][0]) / (lo[i][0] - lo[i - 1][0] || 1); return lo[i - 1][1] + t * (lo[i][1] - lo[i - 1][1]); }
    return null;
  };
  const corr = new Map();
  for (const u of upper) {
    const x = pos[u * 3] + delta[u * 3], y = pos[u * 3 + 1] + delta[u * 3 + 1], yl = yLow(x);
    const need = yl === null ? 0 : Math.min(0, yl - overlap - y);
    corr.set(u, need);
    out[u * 3 + 1] += need;
  }
  const margin = new Set([...upper, ...lower]);
  for (let w = 0; w < pos.length / 3; w++) {
    if (margin.has(w) || !(delta[w * 3 + 1] < -1e-4)) continue;
    let best = null, bd = Infinity;
    for (const u of upper) { const d = Math.hypot(pos[w * 3] - pos[u * 3], pos[w * 3 + 1] - pos[u * 3 + 1], pos[w * 3 + 2] - pos[u * 3 + 2]); if (d < bd) { bd = d; best = u; } }
    if (best !== null && bd < reach) out[w * 3 + 1] += corr.get(best) * (1 - bd / reach);
  }
  return out;
}

/** A set of vertices (1 = in it) smoothed by its neighbours: each pass, a
 *  vertex is in the set when more than half of the vertices it shares a
 *  triangle with are. A cut made vertex by vertex loses its teeth and
 *  notches. */
export function majority(set, idx, passes) {
  const n = set.length, adj = Array.from({ length: n }, () => new Set());
  for (let t = 0; t < idx.length; t += 3) for (let k = 0; k < 3; k++) for (let q = 0; q < 3; q++) if (k !== q) adj[idx[t + k]].add(idx[t + q]);
  let cur = new Uint8Array(set);
  for (let p = 0; p < passes; p++) {
    const next = new Uint8Array(cur);
    for (let v = 0; v < n; v++) {
      if (!adj[v].size) continue;
      let inSet = 0;
      for (const w of adj[v]) inSet += cur[w];
      if (inSet * 2 > adj[v].size) next[v] = 1; else if (inSet * 2 < adj[v].size) next[v] = 0;
    }
    cur = next;
  }
  return cur;
}
