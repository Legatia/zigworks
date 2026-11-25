// Dev only: the base head for the fit (desk-assets/base-head.bin), made once
// from three.js r170's Face Cap sample (facecap.glb). It renders the neutral
// head (every expression weight zeroed: the GLB loads with some set), finds
// MediaPipe's 478 landmarks on the render, and keeps each one's point on
// the head's surface, so the fit itself never renders the model.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { KTX2Loader } from 'three/addons/loaders/KTX2Loader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { FaceLandmarker, FilesetResolver } from '/desk/assets/mediapipe/vision_bundle.mjs';
import { packHead, SHAPES } from '/desk/static/fit.js';

const FACECAP_SHA256 = '6bfce6d0fcbb5839f5102b79733007859fef7c5df6d9eb49e2264542810b5f64';
const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[base] ' + m); };
const fail = (m) => { log('ERROR ' + m); window.__done = { error: String(m) }; throw new Error(m); };
window.onunhandledrejection = (e) => fail(e.reason && (e.reason.stack || e.reason));
// the dev server's token for this run, from the URL's #token=...
const devToken = new URLSearchParams(location.hash.slice(1)).get('token') || '';
const save = async (path, body) => { const r = await fetch('/save/' + path, { method: 'POST', body, headers: { 'X-Dev-Token': devToken } }); if (!r.ok) fail('save ' + path + ' ' + r.status); log('saved ' + path); };
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

// ---------- the model, checked ----------
const glb = await (await fetch('/desk/assets/facecap.glb')).arrayBuffer();
const sha = hex(await crypto.subtle.digest('SHA-256', glb));
if (sha !== FACECAP_SHA256) fail('facecap.glb has SHA-256 ' + sha + ', expected ' + FACECAP_SHA256);
log('facecap.glb ok, ' + glb.byteLength + ' bytes');

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
const R = 1024;
renderer.setSize(R, R); renderer.setPixelRatio(1);
const ktx2 = new KTX2Loader().setTranscoderPath('https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/libs/basis/').detectSupport(renderer);
const gltf = await new GLTFLoader().setKTX2Loader(ktx2).setMeshoptDecoder(MeshoptDecoder).parseAsync(glb, '');
const root = gltf.scene;
root.updateMatrixWorld(true);
const M = {};
root.traverse((o) => { if (o.isMesh) M[o.parent.name] = o; });
const head = M.head, teeth = M.teeth;
if (!head || !teeth) fail('no head or teeth mesh in the model');
const dict = head.morphTargetDictionary;
for (const s of SHAPES) if (!(s in dict)) fail('the model has no shape ' + s);
const loaded = head.morphTargetInfluences.map((w, i) => (w ? Object.keys(dict).find((k) => dict[k] === i) + '=' + w.toFixed(2) : '')).filter(Boolean);
log('weights at load: ' + (loaded.join(' ') || 'none'));
root.traverse((o) => { if (o.morphTargetInfluences) o.morphTargetInfluences.fill(0); });

// ---------- the front render (an orthographic camera's bounds are relative to its position) ----------
const box = new THREE.Box3().setFromObject(head);
const c = box.getCenter(new THREE.Vector3());
const half = Math.max(box.max.x - box.min.x, box.max.y - box.min.y) * 0.6;
const camZ = Math.max(50, box.max.z + 10);
const cam = new THREE.OrthographicCamera(-half, half, half, -half, -100, 100 + camZ);
cam.position.set(c.x, c.y, camZ); cam.lookAt(c.x, c.y, 0);
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x30343a);
scene.add(new THREE.AmbientLight(0xffffff, 1.3));
const dl = new THREE.DirectionalLight(0xffffff, 1.6); dl.position.set(0.3, 0.6, 10); scene.add(dl);
head.material.color = new THREE.Color(1.0, 0.86, 0.76);
scene.add(root);
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
if (!res.faceLandmarks.length) fail('no face found on the model render');
const Q = res.faceLandmarks[0];
log('landmarks on the render: ' + Q.length);
// the eyeballs count as surface: the head mesh has holes at the eyes, and a
// lid's landmark that falls through one lands inside the back of the skull
const surface = [head, M.eyeLeft, M.eyeRight].filter(Boolean);
const ray = new THREE.Raycaster();
const lm = new Float32Array(478 * 3).fill(NaN);
let hits = 0, hits468 = 0;
for (let i = 0; i < 478; i++) {
  const wx = c.x - half + Q[i].x * 2 * half, wy = c.y + half - Q[i].y * 2 * half;
  ray.set(new THREE.Vector3(wx, wy, camZ), new THREE.Vector3(0, 0, -1));
  const h = ray.intersectObjects(surface, false)[0];
  if (!h) continue;
  lm.set([h.point.x, h.point.y, h.point.z], i * 3);
  hits++; if (i < 468) hits468++;
}
log('on the surface: ' + hits + ' of 478 (' + hits468 + ' of the first 468)');

// ---------- the head in world space ----------
const worldOf = (mesh, i, d) => {
  const v = new THREE.Vector3().fromBufferAttribute(mesh.geometry.attributes.position, i);
  if (d) v.add(d);
  return v.applyMatrix4(mesh.matrixWorld);
};
const hn = head.geometry.attributes.position.count;
const pos = new Float32Array(hn * 3);
for (let i = 0; i < hn; i++) pos.set(worldOf(head, i).toArray(), i * 3);
const arrays = { 'head.pos': pos, 'head.idx': new Uint16Array(head.geometry.index.array) };
if (!head.geometry.morphTargetsRelative) fail('the model\'s shapes are not relative');
for (const s of SHAPES) {
  const attr = head.geometry.morphAttributes.position[dict[s]];
  const d = new Float32Array(hn * 3), v = new THREE.Vector3();
  for (let i = 0; i < hn; i++) {
    v.fromBufferAttribute(attr, i);
    if (!v.x && !v.y && !v.z) continue;
    const w = worldOf(head, i, v).sub(worldOf(head, i));
    d.set(w.toArray(), i * 3);
  }
  arrays['shape.' + s + '.pos'] = d;
}
const tn = teeth.geometry.attributes.position.count, tpos = new Float32Array(tn * 3);
for (let i = 0; i < tn; i++) tpos.set(worldOf(teeth, i).toArray(), i * 3);
arrays['teeth.pos'] = tpos;
arrays['teeth.idx'] = new Uint16Array(teeth.geometry.index.array);
arrays.landmarks = lm;

const buf = packHead({ kind: 'base', vertices: hn, shapes: SHAPES, source: { file: 'facecap.glb', sha256: FACECAP_SHA256, three: 'r170' } }, arrays);
await save('desk-assets/base-head.bin', buf);

// a picture of what was found, for checking by eye
{
  const g = rcan.getContext('2d');
  g.fillStyle = '#0f0';
  for (let i = 0; i < 478; i++) g.fillRect(Q[i].x * R - 1.5, Q[i].y * R - 1.5, 3, 3);
  g.fillStyle = '#f0f';
  for (let i = 0; i < 478; i++) if (Number.isNaN(lm[i * 3])) g.fillRect(Q[i].x * R - 3, Q[i].y * R - 3, 6, 6);
  await save('debug/base-render.png', await new Promise((ok) => rcan.toBlob(ok)));
}
window.__done = { hits, hits468, vertices: hn, shapes: SHAPES.length, teeth: tn, bytes: buf.byteLength };
log('done ' + JSON.stringify(window.__done));
