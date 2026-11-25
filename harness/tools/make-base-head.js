// Dev only: the landmark step of the base head (tools/make-base-head.mjs).
// Renders the head made from ICT-FaceKit (desk-assets/base-head-parts.bin)
// front on, finds MediaPipe's 478 landmarks on the render and keeps each
// one's point on the head's surface, so the fit itself never renders the
// model. The eye outlines are moved onto the head's eye openings, which is
// where the fit puts the photo's eye outlines.
import * as THREE from '/desk/static/vendor/three.module.min.js';
import { FaceLandmarker, FilesetResolver } from '/desk/assets/mediapipe/vision_bundle.mjs';
import { packHead, readHead, EYE_A, EYE_B } from '/desk/static/fit.js';

const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[base] ' + m); };
const fail = (m) => { log('ERROR ' + m); window.__done = { error: String(m) }; throw new Error(m); };
window.onunhandledrejection = (e) => fail(e.reason && (e.reason.stack || e.reason));
const devToken = new URLSearchParams(location.hash.slice(1)).get('token') || '';
const save = async (path, body) => { const r = await fetch('/save/' + path, { method: 'POST', body, headers: { 'X-Dev-Token': devToken } }); if (!r.ok) fail('save ' + path + ' ' + r.status); log('saved ' + path); };

const r0 = await fetch('/desk/assets/base-head-parts.bin', { cache: 'no-store' });
if (!r0.ok) fail('no desk-assets/base-head-parts.bin (run tools/make-base-head.mjs)');
const parts = readHead(await r0.arrayBuffer());
if (parts.meta.kind !== 'base-parts') fail('base-head-parts.bin is a ' + parts.meta.kind);
const hpos = parts.arr('head.pos'), hidx = parts.arr('head.idx'), N = parts.meta.vertices;

// ---------- the front render ----------
const R = 1024;
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setSize(R, R); renderer.setPixelRatio(1);
// the render: ICT's whole neutral head at full resolution, with its neck
const hg = new THREE.BufferGeometry();
hg.setAttribute('position', new THREE.BufferAttribute(parts.arr('render.head.pos'), 3));
hg.setIndex(new THREE.BufferAttribute(parts.arr('render.head.idx'), 1));
hg.computeVertexNormals();
const head = new THREE.Mesh(hg, new THREE.MeshLambertMaterial({ color: new THREE.Color(0.86, 0.66, 0.56) }));
const eg = new THREE.BufferGeometry();
const epos = parts.arr('render.eyes.pos'), iris = parts.arr('render.eyes.iris');
eg.setAttribute('position', new THREE.BufferAttribute(epos, 3));
eg.setIndex(new THREE.BufferAttribute(parts.arr('render.eyes.idx'), 1));
eg.computeVertexNormals();
const ecol = new Float32Array(iris.length * 3);
for (let i = 0; i < iris.length; i++) ecol.set(iris[i] ? [0.22, 0.14, 0.1] : [0.92, 0.9, 0.86], i * 3);
eg.setAttribute('color', new THREE.BufferAttribute(ecol, 3));
const eyes = new THREE.Mesh(eg, new THREE.MeshLambertMaterial({ vertexColors: true }));
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x30343a);
scene.add(new THREE.AmbientLight(0xffffff, 1.2));
const dl = new THREE.DirectionalLight(0xffffff, 1.7); dl.position.set(0.3, 0.6, 10); scene.add(dl);
scene.add(head, eyes);
hg.computeBoundingBox();
const box = hg.boundingBox;
// the frame: the head's width, from its top to below the chin (the kept
// head's lowest point near the middle, in front)
let chinY = Infinity;
for (let i = 0; i < N; i++) if (Math.abs(hpos[i * 3]) < 0.5 && hpos[i * 3 + 2] > box.max.z - 6) chinY = Math.min(chinY, hpos[i * 3 + 1]);
chinY -= 1.5;
const half = Math.max((box.max.x - box.min.x) / 2, (box.max.y - chinY) / 2) * 1.08;
const c = new THREE.Vector3((box.min.x + box.max.x) / 2, (box.max.y + chinY) / 2, 0);
const camZ = box.max.z + 10;
const cam = new THREE.OrthographicCamera(-half, half, half, -half, 0.1, camZ - box.min.z + 10);
cam.position.set(c.x, c.y, camZ); cam.lookAt(c.x, c.y, box.min.z);
renderer.render(scene, cam);
const rcan = document.createElement('canvas'); rcan.width = R; rcan.height = R;
rcan.getContext('2d').drawImage(renderer.domElement, 0, 0);
document.getElementById('pics').appendChild(rcan);

// ---------- the landmarks on the render, then on the surface ----------
const fileset = await FilesetResolver.forVisionTasks('/desk/assets/mediapipe/wasm');
const landmarker = await FaceLandmarker.createFromOptions(fileset, {
  baseOptions: { modelAssetPath: '/desk/assets/mediapipe/face_landmarker.task', delegate: 'CPU' }, runningMode: 'IMAGE', numFaces: 1,
});
const res = landmarker.detect(rcan);
if (!res.faceLandmarks.length) fail('no face found on the head\'s render');
const Q = res.faceLandmarks[0];
const world = (q) => [c.x - half + q.x * 2 * half, c.y + half - q.y * 2 * half];
const ray = new THREE.Raycaster();
const lm = new Float32Array(478 * 3).fill(NaN);
let hits = 0, hits468 = 0;
// a point just off the silhouette takes the nearest hit within 4 px of the render
const near = [[0, 0], ...[1, 2, 3, 4].flatMap((r) => [...Array(8).keys()].map((k) => [r * Math.cos(k * Math.PI / 4), r * Math.sin(k * Math.PI / 4)]))];
for (let i = 0; i < 478; i++) {
  const [wx, wy] = world(Q[i]);
  let h = null;
  for (const [dx, dy] of near) {
    ray.set(new THREE.Vector3(wx + dx * (2 * half) / R, wy + dy * (2 * half) / R, camZ), new THREE.Vector3(0, 0, -1));
    // a lid's point that falls through an eye opening lands on the eyeball, not inside the skull
    h = ray.intersectObjects([head, eyes], false)[0];
    if (h) break;
  }
  if (!h) continue;
  lm.set([h.point.x, h.point.y, h.point.z], i * 3);
  hits++; if (i < 468) hits468++;
}
log('on the surface: ' + hits + ' of 478 (' + hits468 + ' of the first 468)');

// ---------- the eye outlines onto the eye openings ----------
// the openings: the head's open boundary edges round each eye
const edges = new Map();
for (let t = 0; t < hidx.length; t += 3) for (let k = 0; k < 3; k++) {
  const a = hidx[t + k], b = hidx[t + (k + 1) % 3], key = Math.min(a, b) * N + Math.max(a, b);
  edges.set(key, (edges.get(key) || 0) + 1);
}
const boundary = [...edges].filter(([, n]) => n === 1).map(([key]) => [Math.floor(key / N), key % N]);
const P = (i) => [hpos[i * 3], hpos[i * 3 + 1], hpos[i * 3 + 2]];
let moved = 0;
for (const ids of [EYE_A, EYE_B]) {
  const pts = ids.map((i) => world(Q[i]));
  const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length, cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  const w = Math.max(...pts.map((p) => p[0])) - Math.min(...pts.map((p) => p[0]));
  // the opening's edges: boundary edges within an eye's width of this eye's centre
  const segs = boundary.filter(([a, b]) => Math.hypot(P(a)[0] - cx, P(a)[1] - cy) < w && Math.hypot(P(b)[0] - cx, P(b)[1] - cy) < w);
  if (segs.length < 8) fail('no eye opening found near the eye at ' + cx.toFixed(2) + ', ' + cy.toFixed(2));
  // each outline point goes onto the opening's edge along the line from the
  // eye's centre through it, so the points keep their order and spacing
  ids.forEach((id, k) => {
    const [x, y] = pts[k], ux = x - cx, uy = y - cy;
    let best = null;
    for (const [a, b] of segs) {
      const A = P(a), B = P(b), ex = B[0] - A[0], ey = B[1] - A[1];
      const den = ux * ey - uy * ex;
      if (Math.abs(den) < 1e-12) continue;
      const s = ((A[0] - cx) * ey - (A[1] - cy) * ex) / den, t = ((A[0] - cx) * uy - (A[1] - cy) * ux) / den;
      if (s <= 0 || t < 0 || t > 1) continue;
      const q = [A[0] + t * ex, A[1] + t * ey, A[2] + t * (B[2] - A[2])];
      if (!best || s < best.s) best = { s, q, d: Math.hypot(q[0] - x, q[1] - y) };
    }
    if (!best) fail('an eye outline point has no edge beyond it');
    lm.set(best.q, id * 3);
    moved = Math.max(moved, best.d);
  });
}
const px = R / (2 * half);
log('eye outlines moved onto the openings: at most ' + (moved * px).toFixed(1) + ' px of the render (' + moved.toFixed(3) + ' cm)');

// ---------- the base head ----------
const arrays = {};
for (const name of Object.keys(parts.meta.arrays)) if (!name.startsWith('render.')) arrays[name] = parts.arr(name);
arrays.landmarks = lm;
const { arrays: _a, kind: _k, ...rest } = parts.meta;
const buf = packHead({ ...rest, kind: 'base' }, arrays);
await save('desk-assets/base-head.bin', buf);

// a picture of what was found, for checking by eye: green as found, magenta
// where none, yellow the eye outlines as kept
{
  const g = rcan.getContext('2d');
  g.fillStyle = '#0f0';
  for (let i = 0; i < 478; i++) g.fillRect(Q[i].x * R - 1.5, Q[i].y * R - 1.5, 3, 3);
  g.fillStyle = '#f0f';
  for (let i = 0; i < 478; i++) if (Number.isNaN(lm[i * 3])) g.fillRect(Q[i].x * R - 3, Q[i].y * R - 3, 6, 6);
  g.fillStyle = '#ff0';
  for (const i of [...EYE_A, ...EYE_B]) g.fillRect((lm[i * 3] - c.x + half) * px - 1.5, (c.y + half - lm[i * 3 + 1]) * px - 1.5, 3, 3);
  await save('debug/base-render.png', await new Promise((ok) => rcan.toBlob(ok)));
}
window.__done = { hits, hits468, eyeMoveCm: +moved.toFixed(4), vertices: N, shapes: parts.meta.shapes.length, teeth: parts.arr('teeth.pos').length / 3, bytes: buf.byteLength };
log('done ' + JSON.stringify(window.__done));
