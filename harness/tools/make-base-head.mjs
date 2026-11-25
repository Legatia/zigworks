// Dev only: makes the avatar's base head (desk-assets/base-head.bin) from
// USC ICT's ICT-FaceKit (MIT), at a pinned commit.
//
//   node tools/make-base-head.mjs DATA OUT [--parts-only]
//
// 1. Downloads the neutral head and the 53 expressions the mapping reads
//    into DATA/ict-facekit/COMMIT/, each checked by SHA-256 (a file
//    already there with the right hash is kept).
// 2. Keeps the region the avatar needs (the face, the back of the head and
//    the mouth's inside, cut under the chin and the jaw), simplifies it
//    keeping vertices where they are, maps ICT's expressions onto the 52
//    ARKit names, and adds the teeth, gums and tongue with their jaw motion:
//    DATA/desk-assets/base-head-parts.bin.
// 3. Runs tools/make-base-head.html in headless Chrome through the dev
//    server: MediaPipe's 478 landmarks found on a render of it and kept as
//    points on its surface; the page writes DATA/desk-assets/base-head.bin.
// 4. Copies that to OUT (harness/desk-assets/base-head.bin is the
//    committed one) and prints its size.
//
// Needs DATA/desk-assets/mediapipe/ (sh tools/fetch-desk-assets.sh
// DATA/desk-assets), python3 and Chrome (CHROME= overrides its path).
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { packHead, readHead, SHAPES } from '../src/desk/fit.js';
import { ARKIT_FROM_ICT, ICT, ICT_FILES, compact, foldsBehind, isNeck, majority, parseObj, sealBlink, simplify, triangulate, vertexNormals } from './base-head-lib.mjs';

export const COMMIT = 'da5f95a607f5e6b37755b38d3385d7f2853732e5';
const RAW = `https://raw.githubusercontent.com/USC-ICT/ICT-FaceKit/${COMMIT}/FaceXModel/`;
// SHA-256 of each file at COMMIT (their git blob hashes matched the commit's tree)
const SHA256 = new Map([
  ['generic_neutral_mesh.obj', 'eedbc2576d8e5ea57f55255b8f98263213a1efb5431d8bfceed1d7aef10271f9'],
  ['browDown_L.obj', 'd1dcd14fc085a9e258dec62a4bfe4a31d592cce5d8918a3892c20f480653f4c1'],
  ['browDown_R.obj', '66a2c72ab64999af168795f27182d011f52b90958c402d719d3ec8ff7d1c8939'],
  ['browInnerUp_L.obj', '81fb1625794ea36fb13303234ce06cef798acfdbc489077e22ae195a705bc92e'],
  ['browInnerUp_R.obj', '5e66b46cdad89fd1237273db2b885511688cf37636cedfdde432a4844c9109e7'],
  ['browOuterUp_L.obj', '022d5342687e51351f4cad6dd1abd42c3bb1b752d0b235bdc7fc588ab0d79c90'],
  ['browOuterUp_R.obj', '1e4722060538b274ed49ed872525d770b5bfd9262b7bce1b6310f49356f5b531'],
  ['cheekPuff_L.obj', 'f53fd2bdeb8e26d0db8a684ab9c095c6bb113b74575dec329facae2799ff18c6'],
  ['cheekPuff_R.obj', 'cd5b5d0f3a653a1fa31abeb65daf8fd6ffdf83a4d1bf22333a469b13b96fa801'],
  ['cheekSquint_L.obj', '572fe87f2e0cdd0a7ff868b9173d0ff08ee2bc73bf94c17b603f6e5d5b8fbe26'],
  ['cheekSquint_R.obj', 'a9afa0aac432159e89eb54dbbb3139864b8cc1c4208c3c0e9c420d0d8050b99a'],
  ['eyeBlink_L.obj', 'f5ed1c3072a400083b7d4f7f5cb3d73882b7ebb95c3232f957394db8cf7fe19e'],
  ['eyeBlink_R.obj', 'd281ad0af03e89a70abf1214d52c295b3a279c9b35f6795938c4487f467ca003'],
  ['eyeLookDown_L.obj', 'e7da4fa6509af5da25fab1a34255889a68f06b90fd37f65c6c05e5bdbbe2f755'],
  ['eyeLookDown_R.obj', 'ac466de6decf619701f3ee7f80fa7371020d325084b41ad7f4b2840e232abf83'],
  ['eyeLookIn_L.obj', '1e037332bc059a95d05fcb24728ae297a2d4d268ff0cf623d3647d2a4f86bd31'],
  ['eyeLookIn_R.obj', '3d64db0e51ad28e76eff56217da401c5ee563b5e76a207cb192046465bbab14a'],
  ['eyeLookOut_L.obj', '235739695136c40b7a2c3239a100ff75b7bfc271ae195aeb55330848c999c9c8'],
  ['eyeLookOut_R.obj', 'ac10dfa83ccaca7fd76fe96d74f8cbc80582e2ef914d1092827b54f88125650e'],
  ['eyeLookUp_L.obj', '72ed342df43489a76e9d468df3ca7f48328f41c924af0c03d88fde9905d82848'],
  ['eyeLookUp_R.obj', 'd8ade1cab9f7f0c4ef6ec007f33e9c9df90a58c666b9aac5a784192cd389e899'],
  ['eyeSquint_L.obj', 'ecb8244f083cf55fa9f0277427b8213315176a624d9ac3a09b533c7fbc68917e'],
  ['eyeSquint_R.obj', '0dffbbc651b9cdbc346ead32ba102051200c72ed8a93e7b33f07149e18390b8a'],
  ['eyeWide_L.obj', '015a995b0f09783683f5575af7e4c939cd758d194d7ca2e8ffacb9ddbabf0078'],
  ['eyeWide_R.obj', '4b8207f6013a751ae35affba62cc70bd6b53e046bbe48e8fd5a150450a7789ed'],
  ['jawForward.obj', 'a0126b2926b69540f478e4c48f05e370868050e6c33718e53c2f17e190a3b239'],
  ['jawLeft.obj', '5af90cd941660fb0116948866414e4321035de754b7ebec787f8144445d2d9e9'],
  ['jawOpen.obj', '8d84355e10f48b05550980cee385bcd426f4797090da76a20de0535bb2f99f4a'],
  ['jawRight.obj', 'd719335ad69a8f18797501d4728910c7a467aecbbae260923192b1bf242eec97'],
  ['mouthClose.obj', '4a44b94c269407cf1171483d87d99d2cbdea9c66242aabf2ad0f57cb785aa193'],
  ['mouthDimple_L.obj', '189f6e01adbf1e13147fe4d505d1f3006e5ce4590ae150064b810274093d29b0'],
  ['mouthDimple_R.obj', '4cf674b98d6d34a16fab462fbd9ecb2cb5e39ccaf3f50459b9ac7d59fbd6a215'],
  ['mouthFrown_L.obj', '1bfd720ad024e5805ac8472df170c2c96c09e817e02b66f916057d6e2d31ee9b'],
  ['mouthFrown_R.obj', 'ae3da92fa1dc70010c6bec810338d740287c71b8730694c97876cab5af241f74'],
  ['mouthFunnel.obj', 'd4f1dba04c1af5fc37452c88cc54a72f1133296c26d9abe0f8adb74dc5c2577f'],
  ['mouthLeft.obj', '01fb69aa8ac07c5762719c9bb2eec5372652c9f1e73509a63d01e7e60e28b885'],
  ['mouthLowerDown_L.obj', '8847660d51e2a72f2bce6ce9add7d58abab1cef967420db83056891291c0b2de'],
  ['mouthLowerDown_R.obj', 'b5143ed50d41c91d80ddc8b565f6274eaf514509ec6f895797db34ca92a85b68'],
  ['mouthPress_L.obj', 'de2bdaf2fa7199294ff7a281cd8f6647bf5ca9a6f84588bd7f7779fff4c61396'],
  ['mouthPress_R.obj', 'ca8d9973b3231e51b8b76d3e7af7f7f3432959b7c37148fc25e7c643252847b6'],
  ['mouthPucker.obj', '9929c31025667683809f70df7dce612f72e3acfc7f9e8acb939f6636509dbc5c'],
  ['mouthRight.obj', 'e3faaf5ed51715e77122d76e8187d5ba83ea9f54e15e29c52e64f26c52e66bda'],
  ['mouthRollLower.obj', '1f577e1129eef4f9e9dc26aa739c6d0f15b27253dee89af3428db6816666e910'],
  ['mouthRollUpper.obj', 'a69ec7407adfd6a5f4c818179bb4604d9e506c07671976f75ac33ef8f54a1bb0'],
  ['mouthShrugLower.obj', '1eedd7831b0408bdcbc9aefe23b11803c54f81da5fc9be1fe81fc7a5117c0b88'],
  ['mouthShrugUpper.obj', '2bd3e3f1568366f2fd84717f0f63aee9f56eed4c303fc4f234aadd81d430032c'],
  ['mouthSmile_L.obj', '91794e73cef330f1c7d1f4541723544708536b39d5dd6ed35fd8f83f676b7af4'],
  ['mouthSmile_R.obj', '3fb3de3da9f8358edbb933a65ce6e44c25a2501f30dcb240daea725b68adac84'],
  ['mouthStretch_L.obj', '9187105730bad43023c63e2a91c979091b9289dd8fc1b587885412b8f7a3d2b7'],
  ['mouthStretch_R.obj', 'd985452085a19d6b3da397ca2cd2f938d8e08761d2e684e87640f3639bdf5f6d'],
  ['mouthUpperUp_L.obj', 'd49483aca6cbbb7a559edf4865aec62970560ddf3a0d34e5b208488bff59f722'],
  ['mouthUpperUp_R.obj', '299e3da0f36ca80c0c74e51900b67bfe6bb5b0101aaf46ce30075064c26a7f02'],
  ['noseSneer_L.obj', '47c5d66ddc1ba146480f0e43b1084f439e0e7d2af31bcec3e6a3bffc420ffa4d'],
  ['noseSneer_R.obj', 'c384c41331124b9cd4b99c1bbe8aef56318cae2b8db6ff0f573a7347ebbe8caa'],
]);
// the jaw's contour from the chin to the jaw's right angle: ICT's chin (Multi-PIE
// 68's point 8) and its right extended jawline's lower part (its README)
const JAWLINE = [966, 800, 1447, 801, 2199, 1673, 781, 844, 243, 1902, 1834];
// how far the upper teeth and gums come down (cm) as the lips part
const UPPER_DOWN = 0.2;
// the ears' box (cm): outward of |x| 6.9, y −2.5 to 7, behind z 2 (the head's
// side is at |x| 7.2–7.9 there, the ears reach 9.2, their bowls dip to 6.6)
const EAR = { x: 6.9, y: [-2.5, 7], z: 2 };
// how much more the silhouette's error counts in the simplifier
const SILHOUETTE = 8;
// the head is simplified to about this many vertices (ICT's region has 12,948)
const TARGET = 4500;
// the poses whose shapes the simplifier keeps dense (each with the neutral)
const POSES = [['jawOpen'], ['jawOpen', 'mouthClose'], ['eyeBlink_L'], ['eyeBlink_R'], ['mouthSmile_L'], ['mouthSmile_R'], ['mouthFunnel'],
  ['mouthPucker'], ['mouthRollUpper'], ['mouthRollLower'], ['browInnerUp'], ['cheekPuff'], ['noseSneer_L'], ['noseSneer_R']];

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const say = (m) => console.log('[base] ' + m);
const sha = (b) => createHash('sha256').update(b).digest('hex');

async function fetchAll(dir) {
  mkdirSync(dir, { recursive: true });
  for (const name of ICT_FILES) {
    const want = SHA256.get(name), out = join(dir, name);
    if (!want) throw new Error('no pinned SHA-256 for ' + name);
    if (existsSync(out) && sha(readFileSync(out)) === want) continue;
    let body = null;
    for (let i = 0; i < 3 && !body; i++) {
      const r = await fetch(RAW + name).catch(() => null);
      if (r && r.ok) body = Buffer.from(await r.arrayBuffer());
    }
    if (!body) throw new Error(name + ": the download didn't work");
    const got = sha(body);
    if (got !== want) throw new Error(`${name}: SHA-256 ${got}, expected ${want}; not kept`);
    writeFileSync(out + '.part', body);
    renameSync(out + '.part', out);
    say('fetched ' + name);
  }
}

const inRange = (i, [a, b]) => i >= a && i <= b;

/** The faces joined (by shared vertices) to the most others. */
function largestPiece(faces) {
  const parent = new Map(), find = (x) => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
  for (const f of faces) for (const v of f) if (!parent.has(v)) parent.set(v, v);
  for (const f of faces) for (let k = 1; k < f.length; k++) { const a = find(f[0]), b = find(f[k]); if (a !== b) parent.set(a, b); }
  const size = new Map();
  for (const f of faces) { const r = find(f[0]); size.set(r, (size.get(r) || 0) + 1); }
  const best = [...size].sort((x, y) => y[1] - x[1])[0][0];
  return faces.filter((f) => find(f[0]) === best);
}

/** The parts file: the head (simplified), the 52 shapes, the mouth's parts,
 *  and the eyeballs for the landmark render only. */
export function buildParts(dir) {
  const neutral = parseObj(readFileSync(join(dir, 'generic_neutral_mesh.obj'), 'utf8'));
  const N0 = neutral.pos, n0 = N0.length / 3;
  if (n0 !== ICT.vertices) throw new Error(`the neutral head has ${n0} vertices, not ${ICT.vertices}`);
  const delta = new Map();
  for (const name of ICT_FILES.slice(1)) {
    const e = parseObj(readFileSync(join(dir, name), 'utf8')).pos;
    if (e.length !== N0.length) throw new Error(name + ' has another vertex count');
    delta.set(name.replace(/\.obj$/, ''), e.map((v, i) => v - N0[i]));
  }
  const arkit = (s) => {
    const d = new Float64Array(N0.length);
    for (const f of ARKIT_FROM_ICT[s]) { const x = delta.get(f); for (let i = 0; i < d.length; i++) d[i] += x[i]; }
    return d;
  };
  const shapes = new Map(SHAPES.map((s) => [s, arkit(s)]));

  // the head's region without the neck: what faces the camera below the
  // jaw's contour (ICT's extended jawline, the chin to the jaw's angle) goes,
  // and what's left that isn't joined to the face
  const P = (i) => [N0[i * 3], N0[i * 3 + 1], N0[i * 3 + 2]];
  const inRegion = (i) => inRange(i, ICT.face) || inRange(i, ICT.headNeck) || inRange(i, ICT.mouthSocket);
  // as triangles: a cut through ICT's quads then steps by half a quad
  const asTris = (t) => { const o = []; for (let i = 0; i < t.length; i += 3) o.push([t[i], t[i + 1], t[i + 2]]); return o; };
  let headFaces = asTris(triangulate(neutral.faces.filter((f) => f.every(inRegion)), N0));
  {
    const nrm = vertexNormals(N0, triangulate(headFaces, N0));
    const neck = isNeck(N0, nrm, { contour: JAWLINE.map((i) => [Math.abs(P(i)[0]), P(i)[1]]), facing: 0.25, floor: -10 });
    // the ears go too: their deep folds, hidden from the front, would open as
    // cracks when the head turns; the backplate carries them, as it does the
    // hair (EAR: the box round each ear, outward of the head's side)
    const ear = (i) => Math.abs(N0[i * 3]) > EAR.x && N0[i * 3 + 1] > EAR.y[0] && N0[i * 3 + 1] < EAR.y[1] && N0[i * 3 + 2] < EAR.z;
    // decided vertex by vertex, then smoothed by the neighbours (two passes),
    // so the cut's edge has no teeth to show when the jaw drops
    const cut = new Uint8Array(n0);
    for (const f of headFaces) for (const i of f) cut[i] = neck(i) || ear(i) ? 1 : 0;
    const smooth = majority(cut, triangulate(headFaces, N0), 2);
    headFaces = largestPiece(headFaces.filter((f) => !f.some((i) => smooth[i])));
  }
  // each eye opening's edge tucks in behind the lids (towards the eye
  // socket, which isn't kept): that fold goes, so the opening's edge is the
  // lid margin seen from the front
  {
    const tri = triangulate(headFaces, N0), ec = new Map();
    for (let t = 0; t < tri.length; t += 3) for (let k = 0; k < 3; k++) {
      const a = tri[t + k], b = tri[t + (k + 1) % 3], key = Math.min(a, b) * n0 + Math.max(a, b);
      ec.set(key, (ec.get(key) || 0) + 1);
    }
    const seeds = new Set();
    for (const [key, c] of ec) if (c === 1) for (const v of [Math.floor(key / n0), key % n0]) if (inRange(v, ICT.face) && N0[v * 3 + 1] > 1 && N0[v * 3 + 2] > 5) seeds.add(v);
    const fold = foldsBehind({ pos: N0, idx: tri, seeds: [...seeds], eps: 0.02 });
    headFaces = headFaces.filter((f) => !f.some((v) => fold.has(v)));
    say(`eye openings: ${seeds.size} edge vertices, ${fold.size} in the folds behind the lids dropped`);
  }
  const local = compact(triangulate(headFaces, N0), n0);
  const ids = []; for (let i = 0; i < n0; i++) if (local.map[i] >= 0) ids.push(i);
  const sub = (src) => { const o = new Float64Array(ids.length * 3); ids.forEach((g, j) => o.set([src[g * 3], src[g * 3 + 1], src[g * 3 + 2]], j * 3)); return o; };
  const pos = sub(N0);
  const idx = triangulate(headFaces, N0).map((v) => local.map[v]);
  const poses = [pos, ...POSES.map((names) => { const p = new Float64Array(pos); for (const s of names) { const d = sub(shapes.get(s)); for (let i = 0; i < p.length; i++) p[i] += d[i]; } return p; })];
  const t0 = Date.now();
  // the face's silhouette (in front, side-on to the camera: the jaw's
  // underside, the cheeks' sides) weighs more, so its edge stays smooth where
  // the head fades into the backplate
  const nrm = vertexNormals(pos, idx);
  const weight = Float64Array.from({ length: ids.length }, (_, j) => (pos[j * 3 + 2] > 2 && Math.abs(nrm[j * 3 + 2]) < 0.45 && !inRange(ids[j], ICT.mouthSocket) ? SILHOUETTE : 1));
  const simple = simplify({ pos, idx, poses, lock: new Uint8Array(ids.length), weight, target: TARGET });
  const kept = compact(simple, ids.length);
  say(`head: ${ids.length} vertices, ${idx.length / 3} triangles in the region; ${kept.kept} vertices, ${simple.length / 3} triangles kept (${Date.now() - t0} ms)`);
  const gid = []; for (let j = 0; j < ids.length; j++) if (kept.map[j] >= 0) gid.push(ids[j]);
  const pick = (src) => { const o = new Float32Array(gid.length * 3); gid.forEach((g, j) => o.set([src[g * 3], src[g * 3 + 1], src[g * 3 + 2]], j * 3)); return o; };
  const arrays = {
    'head.pos': pick(N0),
    'head.idx': gid.length < 65536 ? new Uint16Array(simple.map((v) => kept.map[v])) : new Uint32Array(simple.map((v) => kept.map[v])),
    'head.part': Uint8Array.from(gid, (g) => (inRange(g, ICT.mouthSocket) ? 1 : 0)),
  };
  for (const s of SHAPES) arrays['shape.' + s + '.pos'] = pick(shapes.get(s));
  // the blinks close fully: without the lid rim behind the margin (the fold,
  // dropped) ICT's upper lids stop up to 1.2 mm short on the inner half
  {
    const hp = arrays['head.pos'], hi = arrays['head.idx'], n = gid.length, ec = new Map();
    for (let t = 0; t < hi.length; t += 3) for (let k = 0; k < 3; k++) { const a = hi[t + k], b = hi[t + (k + 1) % 3], key = Math.min(a, b) * n + Math.max(a, b); ec.set(key, (ec.get(key) || 0) + 1); }
    const edge = new Set();
    for (const [key, c] of ec) if (c === 1) for (const v of [Math.floor(key / n), key % n]) if (hp[v * 3 + 1] > 1 && hp[v * 3 + 2] > 5) edge.add(v);
    for (const [side, sign] of [['L', 1], ['R', -1]]) {
      const vs = [...edge].filter((v) => hp[v * 3] * sign > 0), cy = vs.reduce((a, v) => a + hp[v * 3 + 1], 0) / vs.length;
      const name = 'shape.eyeBlink_' + side + '.pos';
      arrays[name] = sealBlink({ pos: hp, delta: arrays[name], upper: vs.filter((v) => hp[v * 3 + 1] > cy), lower: vs.filter((v) => hp[v * 3 + 1] <= cy), overlap: 0.03, reach: 0.4 });
    }
  }

  // the mouth's parts: teeth, gums and tongue, riding jawOpen by their own motion
  const isMouth = (i) => inRange(i, ICT.gumsTongue) || inRange(i, ICT.teeth);
  const mt = triangulate(neutral.faces.filter((f) => f.every(isMouth)), N0);
  const mc = compact(mt, n0);
  const mid = []; for (let i = 0; i < n0; i++) if (mc.map[i] >= 0) mid.push(i);
  const pickM = (src) => { const o = new Float32Array(mid.length * 3); mid.forEach((g, j) => o.set([src[g * 3], src[g * 3 + 1], src[g * 3 + 2]], j * 3)); return o; };
  // ICT's upper incisors sit wholly behind the upper lip; as the lips part
  // they come down 2 mm (a man's usual display at rest, Vig & Brundo 1978),
  // with the upper gums (the points the jaw doesn't move): teeth.show, which
  // the desk applies with the jaw's opening, so shut lips hide them
  const jawD = shapes.get('jawOpen'), show = new Float32Array(mid.length * 3);
  mid.forEach((g, j) => { if (Math.hypot(jawD[g * 3], jawD[g * 3 + 1], jawD[g * 3 + 2]) < 0.05) show[j * 3 + 1] = -UPPER_DOWN; });
  arrays['teeth.pos'] = pickM(N0);
  arrays['teeth.show'] = show;
  arrays['teeth.idx'] = new Uint16Array(mt.map((v) => mc.map[v]));
  arrays['teeth.jaw'] = pickM(shapes.get('jawOpen'));
  arrays['teeth.kind'] = Uint8Array.from(mid, (g) => (inRange(g, ICT.teeth) ? 0 : 1));

  // for the landmark render only: ICT's whole neutral head and neck at full
  // resolution (the landmarks are found on a natural head and steer the warp;
  // they needn't lie on the kept surface), and the eyeballs
  const isWhole = (i) => inRange(i, ICT.face) || inRange(i, ICT.headNeck) || inRange(i, ICT.mouthSocket);
  const wt = triangulate(neutral.faces.filter((f) => f.every(isWhole)), N0);
  const wc = compact(wt, n0);
  const wid = []; for (let i = 0; i < n0; i++) if (wc.map[i] >= 0) wid.push(i);
  const wo = new Float32Array(wid.length * 3); wid.forEach((g, j) => wo.set(P(g), j * 3));
  arrays['render.head.pos'] = wo;
  arrays['render.head.idx'] = new Uint16Array(wt.map((v) => wc.map[v]));
  // the eyeballs
  const isEye = (i) => inRange(i, ICT.eyeballLeft) || inRange(i, ICT.eyeballRight);
  const et = triangulate(neutral.faces.filter((f) => f.every(isEye)), N0);
  const ec = compact(et, n0);
  const eid = []; for (let i = 0; i < n0; i++) if (ec.map[i] >= 0) eid.push(i);
  const eo = new Float32Array(eid.length * 3); eid.forEach((g, j) => eo.set(P(g), j * 3));
  arrays['render.eyes.pos'] = eo;
  arrays['render.eyes.idx'] = new Uint16Array(et.map((v) => ec.map[v]));
  arrays['render.eyes.iris'] = Uint8Array.from(eid, (g) => (inRange(g, ICT.irisLeft) || inRange(g, ICT.irisRight) ? 1 : 0));

  const meta = {
    kind: 'base-parts', vertices: gid.length, shapes: SHAPES, units: 'cm',
    source: { name: 'ICT-FaceKit', url: 'https://github.com/USC-ICT/ICT-FaceKit', commit: COMMIT, license: 'MIT', ictVertices: gid },
  };
  say(`mouth parts: ${mid.length} vertices, ${mt.length / 3} triangles; eyeballs: ${eid.length} vertices`);
  return packHead(meta, arrays);
}

const freePort = () => new Promise((ok, no) => { const s = createServer(); s.on('error', no); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => ok(p)); }); });

async function runPage(data) {
  const port = await freePort();
  const srv = spawn('python3', ['-I', here('devserver.py'), String(port), data], { stdio: ['ignore', 'pipe', 'inherit'] });
  try {
    const token = await new Promise((ok, no) => {
      let buf = '';
      srv.stdout.on('data', (d) => { buf += d; const m = /^token (\S+)/m.exec(buf); if (m) ok(m[1]); });
      srv.on('exit', () => no(new Error("the dev server didn't start")));
    });
    const url = `http://127.0.0.1:${port}/tools/make-base-head.html#token=${token}`;
    const r = spawnSync(process.execPath, [here('headless.mjs'), url, '--wait', 'window.__done', '--eval', 'window.__done', '--timeout', '240'], { encoding: 'utf8' });
    process.stdout.write(r.stdout);
    if (r.status !== 0) throw new Error('the landmark page failed');
  } finally { srv.kill(); }
}

async function main() {
  const args = process.argv.slice(2);
  const [data, out] = args.filter((a) => !a.startsWith('--'));
  if (!data || (!out && !args.includes('--parts-only'))) { console.error('usage: node tools/make-base-head.mjs DATA OUT [--parts-only]'); process.exit(2); }
  const cache = join(data, 'ict-facekit', COMMIT);
  await fetchAll(cache);
  say('ICT-FaceKit files checked: ' + ICT_FILES.length);
  const parts = buildParts(cache);
  mkdirSync(join(data, 'desk-assets'), { recursive: true });
  writeFileSync(join(data, 'desk-assets', 'base-head-parts.bin'), new Uint8Array(parts));
  say('wrote desk-assets/base-head-parts.bin, ' + parts.byteLength + ' bytes');
  if (args.includes('--parts-only')) return;
  if (!existsSync(join(data, 'desk-assets', 'mediapipe', 'vision_bundle.mjs'))) throw new Error('no MediaPipe files in DATA/desk-assets: run sh tools/fetch-desk-assets.sh DATA/desk-assets');
  const made = join(data, 'desk-assets', 'base-head.bin');
  rmSync(made, { force: true });
  await runPage(data);
  if (!existsSync(made)) throw new Error("the page didn't write desk-assets/base-head.bin");
  const buf = readFileSync(made);
  const head = readHead(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  if (head.meta.kind !== 'base') throw new Error('the page wrote a ' + head.meta.kind);
  mkdirSync(dirname(out), { recursive: true });
  copyFileSync(made, out);
  say(`${out}: ${statSync(out).size} bytes, ${head.meta.vertices} vertices, ${head.meta.shapes.length} shapes, sha256 ${sha(buf)}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => { console.error('make-base-head: ' + (e && e.message)); process.exit(1); });
}
