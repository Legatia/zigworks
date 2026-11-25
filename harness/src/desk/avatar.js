// The desk's avatar: the portrait projected onto a rigged head with the
// 52 ARKit expression shapes, drawn live with WebGL 2 (three.js r170).
// Blinks, gaze, breathing, nods, expressions and lip-sync are generated
// as it runs; nothing loops.
//
//   const avatar = await createAvatar(element, '/desk/avatars/butler/', options);
//   avatar.setState('working');          // resting, quiet, working, needs you, urgent, speaking
//   avatar.moment('smile');              // or 'concern'
//   avatar.arrive();                     // the glance for a new item
//   await avatar.speak({ text, audioUrl });   // or { text, browser: true }
//   avatar.stop(); avatar.dispose();
//   const r = await avatar.fit(photo, closedPhoto);   // fit.js: { ok, message, warnings, faceWidth, closedUsed, files }
//
// A pack is a folder with avatar.ini naming its files (README: Avatar
// packs). A pack with only a still, a head that doesn't load, or no
// WebGL 2: the still, breathing (avatar.mode === 'still').
import * as THREE from './vendor/three.module.min.js';
import { readHead, readImage, loadImage, fit, sha256Hex } from './fit.js';

export { readHead, fit };

export const STATES = ['resting', 'quiet', 'working', 'needs you', 'urgent', 'speaking'];

// ---------- the pack's files ----------

const INI_KEYS = ['still', 'closed', 'head', 'eyes', 'eyemask'];

/** avatar.ini's `key = file` lines; unknown keys and bad lines are skipped. */
export function parseIni(text) {
  const out = {};
  for (const raw of String(text).split('\n')) {
    const line = raw.trim();
    if (!line || line[0] === '#' || line[0] === ';') continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim(), val = line.slice(eq + 1).trim();
    if (INI_KEYS.includes(key) && !(key in out) && /^[^./\\:][^/\\:]*$/.test(val)) out[key] = val;
  }
  return out;
}

// ---------- small helpers ----------

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const rand = (a, b) => a + Math.random() * (b - a);
const ease = (x) => { x = clamp(x, 0, 1); return x * x * (3 - 2 * x); };
const approach = (c, t, rate, dt) => c + (t - c) * (1 - Math.exp(-rate * dt));
const D2R = Math.PI / 180;
const both = (n, v) => ({ [n + '_L']: v, [n + '_R']: v });
const now = () => performance.now() / 1000;

/** The part of the photo to show for an element of this aspect: the face
 *  (face: { cx, w, top, h } in photo pixels) framed as the prototype did. */
export function frameView(W, H, face, aspect) {
  let vh = Math.min(H, face.h * 1.85);
  let vw = vh * aspect;
  if (vw < face.w * 1.35) { vw = face.w * 1.35; vh = vw / aspect; }
  if (vw > W) { vw = W; vh = vw / aspect; }
  const cx = clamp(face.cx, vw / 2, W - vw / 2);
  const cy = vh > H ? vh / 2 - 30 : clamp(face.top + face.h * 0.42, vh / 2, H - vh / 2);
  return { x0: cx - vw / 2, y0: cy - vh / 2, w: vw, h: vh };
}

/** The head turns a few degrees at most (the spec: about ±4°; roll ±3°). */
export function limitPose(p) {
  return { pitch: clamp(p.pitch, -4, 4), yaw: clamp(p.yaw, -4, 4), roll: clamp(p.roll, -3, 3) };
}

// ---------- speech: text to mouth shapes ----------

// mouth shapes (visemes) as ARKit shapes
const VIS = {
  PP: { mouthClose: 0.3, ...both('mouthPress', 0.42), mouthRollLower: 0.22, mouthRollUpper: 0.12 },
  FF: { mouthRollLower: 0.5, ...both('mouthUpperUp', 0.16), jawOpen: 0.05 },
  TH: { jawOpen: 0.12, ...both('mouthStretch', 0.1) },
  DD: { jawOpen: 0.13, ...both('mouthStretch', 0.12), mouthShrugUpper: 0.08 },
  kk: { jawOpen: 0.16, ...both('mouthStretch', 0.1) },
  CH: { jawOpen: 0.1, mouthFunnel: 0.42, mouthPucker: 0.22, mouthShrugUpper: 0.12 },
  SS: { jawOpen: 0.06, ...both('mouthStretch', 0.26), ...both('mouthSmile', 0.1) },
  nn: { jawOpen: 0.11, ...both('mouthStretch', 0.08) },
  RR: { jawOpen: 0.11, mouthFunnel: 0.22, mouthPucker: 0.28 },
  aa: { jawOpen: 0.3, ...both('mouthLowerDown', 0.2), ...both('mouthUpperUp', 0.08) },
  E: { jawOpen: 0.2, ...both('mouthStretch', 0.22), ...both('mouthSmile', 0.1), ...both('mouthLowerDown', 0.12) },
  I: { jawOpen: 0.13, ...both('mouthSmile', 0.22), ...both('mouthStretch', 0.22) },
  O: { jawOpen: 0.24, mouthFunnel: 0.5, mouthPucker: 0.18 },
  U: { jawOpen: 0.08, mouthPucker: 0.62, mouthFunnel: 0.28 },
};
const VOWELS = new Set(['aa', 'E', 'I', 'O', 'U']);
const DIGRAPHS = [['tch', 'CH'], ['sh', 'CH'], ['ch', 'CH'], ['th', 'TH'], ['ph', 'FF'], ['wh', 'U'], ['ng', 'nn'], ['ck', 'kk'], ['qu', 'kk'],
  ['ee', 'I'], ['ea', 'I'], ['oo', 'U'], ['ou', 'O'], ['ow', 'O'], ['oa', 'O'], ['ai', 'E'], ['ay', 'E'], ['ie', 'I'], ['oi', 'O'], ['oy', 'O'], ['au', 'O'], ['aw', 'O']];
const SINGLE = { a: 'aa', e: 'E', i: 'I', o: 'O', u: 'U', y: 'I', b: 'PP', p: 'PP', m: 'PP', f: 'FF', v: 'FF', t: 'DD', d: 'DD', n: 'nn', l: 'DD',
  k: 'kk', g: 'kk', c: 'kk', q: 'kk', x: 'kk', s: 'SS', z: 'SS', j: 'CH', r: 'RR', w: 'U', h: null };
const NUM = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];

/** The spoken text as a timeline of mouth shapes, at a nominal pace:
 *  { ev: [{ t0, t1, vis, amp }], words: [{ i0, i1, t0, t1, long }], ends: [t], dur }.
 *  Words keep their place in the text (i0, i1) for the voice's word
 *  boundaries; `ends` are the sentence ends (a small nod). */
export function buildTimeline(text, rnd = Math.random) {
  const ev = [], words = [], ends = [];
  let t = 0.1;
  const re = /([A-Za-z']+|\d+)|([.!?]+)|([,;:])/g;
  let m;
  while ((m = re.exec(text))) {
    if (m[1]) {
      const raw = m[1];
      let s = /\d/.test(raw) ? raw.split('').map((d) => NUM[+d]).join('') : raw.toLowerCase().replace(/'/g, '');
      if (s.length > 3 && s.endsWith('e') && !/[aeiou]e$/.test(s)) s = s.slice(0, -1); // a silent e
      const t0 = t;
      for (let i = 0; i < s.length;) {
        let vis, n = 1;
        const dg = DIGRAPHS.find(([g]) => s.startsWith(g, i));
        if (dg) { vis = dg[1]; n = dg[0].length; }
        else { if (i > 0 && s[i - 1] === s[i]) { i++; continue; } vis = SINGLE[s[i]]; }
        i += n;
        if (!vis) { t += 0.03; continue; }
        const dur = VOWELS.has(vis) ? 0.112 : 0.072;
        ev.push({ t0: t, t1: t + dur, vis, amp: 0.85 + 0.27 * rnd() });
        t += dur;
      }
      words.push({ i0: m.index, i1: m.index + raw.length, t0, t1: t, long: s.length > 6 });
      t += 0.045;
    } else if (m[2]) { t += 0.34; ends.push(t - 0.3); }
    else if (m[3]) { t += 0.16; }
  }
  return { ev, words, ends, dur: t + 0.1 };
}

/** The timeline with its spoken part [first sound, last sound] laid onto
 *  [start, end] seconds (a provider's audio: its voiced span). */
export function stretchTimeline(tl, start, end) {
  if (!tl.ev.length) return { ...tl, ev: [], words: tl.words.map((w) => ({ ...w })), ends: [...tl.ends], dur: end };
  const s0 = tl.ev[0].t0, s1 = tl.ev[tl.ev.length - 1].t1;
  const k = (end - start) / (s1 - s0 || 1);
  const map = (t) => start + (t - s0) * k;
  return {
    ev: tl.ev.map((e) => ({ ...e, t0: map(e.t0), t1: map(e.t1) })),
    words: tl.words.map((w) => ({ ...w, t0: map(w.t0), t1: map(w.t1) })),
    ends: tl.ends.map(map),
    dur: Math.max(end, map(tl.dur)),
  };
}

/** Where the voice is in a recording: [first, last] second whose 20 ms
 *  loudness is above a tenth of the loudest; the whole length if none. */
export function voicedSpan(samples, rate) {
  const win = Math.max(1, Math.round(rate * 0.02)), n = Math.floor(samples.length / win);
  const rms = new Float32Array(n);
  let peak = 0;
  for (let w = 0; w < n; w++) {
    let s = 0;
    for (let i = w * win; i < (w + 1) * win; i++) s += samples[i] * samples[i];
    rms[w] = Math.sqrt(s / win);
    peak = Math.max(peak, rms[w]);
  }
  const th = Math.max(peak * 0.1, 0.003);
  let a = -1, b = -1;
  for (let w = 0; w < n; w++) if (rms[w] > th) { if (a < 0) a = w; b = w; }
  if (a < 0) return [0, samples.length / rate];
  return [(a * win) / rate, ((b + 1) * win) / rate];
}

// ---------- behaviour ----------

const PROFILES = {
  resting: { shapes: { mouthClose: 0.03, mouthRollLower: 0.06, ...both('mouthPress', 0.08) }, closed: 1, pitch: 2.6, yaw: 0.4, roll: 0.6, breathRate: 0.16, breathAmp: 1.5, micro: 0.35, gaze: 'closed', nod: null, slow: true },
  quiet: { shapes: { mouthClose: 0.03, mouthRollLower: 0.06, ...both('mouthPress', 0.08) }, closed: 1, pitch: 3, yaw: 0.4, roll: 0.6, breathRate: 0.13, breathAmp: 1.7, micro: 0.25, gaze: 'closed', nod: null, slow: true, dim: 0.6 },
  working: { shapes: { browDown_L: 0.32, browInnerUp: 0.18, ...both('mouthPress', 0.22), mouthRollLower: 0.12, mouthLeft: 0.1, eyeSquint_L: 0.22, eyeSquint_R: 0.14 }, closed: 0, pitch: -1.0, yaw: -2.2, roll: -1.8, breathRate: 0.22, breathAmp: 0.9, micro: 0.8, gaze: 'think', nod: [9, 16] },
  'needs you': { shapes: { browInnerUp: 0.22, ...both('browOuterUp', 0.16), ...both('eyeWide', 0.1), ...both('mouthSmile', 0.08) }, closed: 0, pitch: -0.8, yaw: 0, roll: 0.4, breathRate: 0.25, breathAmp: 1, micro: 0.8, gaze: 'viewer', nod: [10, 18] },
  urgent: { shapes: { browInnerUp: 0.45, ...both('browOuterUp', 0.36), ...both('eyeWide', 0.28) }, closed: 0, pitch: -1.4, yaw: 0, roll: 0, breathRate: 0.3, breathAmp: 1, micro: 0.5, gaze: 'viewer', nod: null },
  speaking: { shapes: { browInnerUp: 0.06 }, closed: 0, pitch: -0.6, yaw: 0, roll: 0.3, breathRate: 0.24, breathAmp: 0.9, micro: 0.9, gaze: 'talk', nod: null },
};
const MOMENTS = {
  smile: { shapes: { ...both('mouthSmile', 0.58), ...both('cheekSquint', 0.32), ...both('eyeSquint', 0.22), ...both('mouthDimple', 0.12) }, secs: 2 },
  concern: { shapes: { browInnerUp: 0.62, ...both('browDown', 0.18), ...both('mouthFrown', 0.32), ...both('mouthPress', 0.2), ...both('eyeSquint', 0.1) }, secs: 2.5 },
};
const GLANCE = { browInnerUp: 0.2, ...both('browOuterUp', 0.12), ...both('eyeWide', 0.12) };
const MOUTH = /^(mouth|jaw|cheekPuff|tongue)/;

function blinkCurve(d) {
  if (d < 0) return 0;
  if (d < 0.075) return ease(d / 0.075);
  if (d < 0.115) return 1;
  if (d < 0.29) return 1 - ease((d - 0.115) / 0.175);
  return 0;
}
function nodCurve(d) {
  if (d < 0 || d > 1.05) return 0;
  if (d < 0.26) return ease(d / 0.26);
  if (d < 0.62) return 1 - 1.18 * ease((d - 0.26) / 0.36);
  return -0.18 * (1 - ease((d - 0.62) / 0.43));
}

// ---------- the pack ----------

async function loadPack(base) {
  // no-cache: the desk serves packs cacheable for a day, and a refit must show at once
  const r = await fetch(base + 'avatar.ini', { cache: 'no-cache' }).catch(() => null);
  if (!r || !r.ok) throw new Error("The avatar didn't load: there's no avatar.ini at " + base);
  const files = parseIni(await r.text());
  if (!files.still) throw new Error("The avatar didn't load: its avatar.ini names no still.");
  const { canvas: still, bytes: stillBytes } = await readImage(base + files.still).catch(() => { throw new Error("The avatar didn't load: its still " + files.still + " didn't load."); });
  const pack = { files, still, head: null, eyes: null, mask: null, closed: null, problem: null };
  if (files.head && files.eyes && files.eyemask) {
    try {
      const [buf, eyes, mask] = await Promise.all([
        fetch(base + files.head, { cache: 'no-cache' }).then((x) => { if (!x.ok) throw new Error(files.head + ' ' + x.status); return x.arrayBuffer(); }),
        loadImage(base + files.eyes), loadImage(base + files.eyemask),
      ]);
      const head = readHead(buf);
      if (head.meta.kind !== 'head') throw new Error(files.head + ' is not a fitted head');
      const [W, H] = head.meta.image || [];
      if (W !== still.width || H !== still.height) throw new Error(`it was fitted to a ${W}×${H} photo and the still is ${still.width}×${still.height}`);
      if (head.meta.still && head.meta.still.sha256 && stillBytes && (await sha256Hex(stillBytes)) !== head.meta.still.sha256) throw new Error('it was fitted to another photo');
      pack.head = head; pack.eyes = eyes; pack.mask = mask;
      pack.closed = files.closed ? await loadImage(base + files.closed).catch(() => null) : null;
      if (pack.closed && (pack.closed.width !== W || pack.closed.height !== H)) pack.closed = null;
    } catch (e) {
      pack.head = null;
      pack.problem = "The head didn't load (" + e.message + '); showing the portrait.';
    }
  }
  return pack;
}

/** The still with each eye drawn shut in its lid's own tone: the eyes-closed
 *  portrait when there is none. Per column of the eye, from the crease to
 *  the lash line: the crease's shadow, the lit lid, darker into the lashes;
 *  the skin's grain borrowed from under the eye; soft at every edge. */
function drawClosedEyes(still, meta) {
  const c = document.createElement('canvas');
  c.width = still.width; c.height = still.height;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(still, 0, 0);
  const mix = (a, b, t) => a + (b - a) * clamp(t, 0, 1);
  for (const e of meta.eyes) {
    const lid = e.lid || [150, 120, 115];
    const k = e.width / 130;
    const o = e.outline;
    // the lower lid runs corner to corner over points 0–8, the upper over 8–15 and back to 0
    const lower = o.slice(0, 9), upper = [o[8], ...o.slice(9), o[0]];
    const yAt = (arc, x) => {
      for (let i = 1; i < arc.length; i++) {
        const [ax, ay] = arc[i - 1], [bx, by] = arc[i];
        if ((x - ax) * (x - bx) <= 0 && ax !== bx) return ay + ((by - ay) * (x - ax)) / (bx - ax);
      }
      return null;
    };
    const xs = o.map((p) => p[0]), xL = Math.min(...xs), xR = Math.max(...xs);
    const feather = 2.5 * k;
    const bx0 = Math.max(0, Math.floor(xL - feather - 2)), bx1 = Math.min(c.width, Math.ceil(xR + feather + 2));
    const by0 = Math.max(0, Math.floor(Math.min(...o.map((p) => p[1])) - 12 * k)), by1 = Math.min(c.height, Math.ceil(Math.max(...o.map((p) => p[1])) + 40 * k));
    const w = bx1 - bx0, h = by1 - by0;
    if (w < 2 || h < 2) continue;
    const img = g.getImageData(bx0, by0, w, h), D = img.data, src = new Uint8ClampedArray(D);
    const at = (x, y) => ((y - by0) * w + (x - bx0)) * 4;
    // the skin under the eye: its mean, for the grain's ratio
    let mean = [0, 0, 0], mn = 0;
    for (let x = Math.ceil(xL); x < xR; x++) {
      const yb = yAt(lower, x);
      if (yb === null) continue;
      for (let y = Math.round(yb + 6 * k); y < Math.min(by1, yb + 22 * k); y++) { const q = at(x, y); for (let ch = 0; ch < 3; ch++) mean[ch] += src[q + ch]; mn++; }
    }
    mean = mn ? mean.map((v) => v / mn) : lid;
    for (let x = bx0; x < bx1; x++) {
      const xc = clamp(x, xL + 0.5, xR - 0.5);
      const yt0 = yAt(upper, xc), yb0 = yAt(lower, xc);
      if (yt0 === null || yb0 === null) continue;
      const u = (xc - xL) / (xR - xL);
      const top = yt0 - 4 * k * Math.sin(Math.PI * u); // over the upper lashes
      const bot = Math.max(top + 1, yb0 + 1.5 * k);
      const side = clamp(Math.min(x - (xL - feather), xR + feather - x) / (2 * feather), 0, 1); // soft at the corners
      for (let y = Math.max(by0, Math.floor(top - feather)); y < Math.min(by1, Math.ceil(bot + feather)); y++) {
        const v = (y - top) / (bot - top);
        const edge = v < 0 ? 1 - (top - y) / feather : v > 1 ? 1 - (y - bot) / feather : 1;
        const a = clamp(edge, 0, 1) * side;
        if (a <= 0) continue;
        const shade = v < 0.15 ? mix(0.62, 1.0, v / 0.15) : v < 0.55 ? mix(1.0, 1.05, (v - 0.15) / 0.4) : v < 0.86 ? mix(1.05, 0.88, (v - 0.55) / 0.31) : mix(0.88, 0.5, (v - 0.86) / 0.14);
        const lash = Math.exp(-(((v - 0.9) * (bot - top)) ** 2) / (2 * (1.1 * k) ** 2)); // the lash line
        // the grain: the skin under the eye, mirrored up
        const sy = clamp(Math.round(bot + (bot - y) * 0.6 + 6 * k), by0, by1 - 1);
        const q = at(x, y), sq = at(x, sy);
        for (let ch = 0; ch < 3; ch++) {
          const grain = clamp(src[sq + ch] / (mean[ch] || 1), 0.85, 1.15);
          const col = lid[ch] * shade * grain * (1 - 0.55 * lash);
          D[q + ch] = Math.round(src[q + ch] + (col - src[q + ch]) * a);
        }
      }
    }
    g.putImageData(img, bx0, by0);
  }
  return c;
}

// ---------- the head ----------

function texture(canvas) {
  const t = new THREE.CanvasTexture(canvas);
  t.colorSpace = THREE.NoColorSpace;
  t.anisotropy = 4;
  return t;
}

/** The scene for a fitted pack: the projected head, the eyeballs, the
 *  teeth and the backplate (the prototype's method). */
function buildHead(pack, canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, stencil: true, powerPreference: 'high-performance' });
  try {
    return buildScene(pack, renderer);
  } catch (e) {
    letGo(renderer);
    throw e;
  }
}

/** Frees the renderer and its WebGL context at once (a page has only a
 *  few contexts; a disposed avatar shouldn't hold one until collected). */
function letGo(renderer) {
  const gl = renderer.getContext();
  renderer.dispose();
  const ext = gl && gl.getExtension('WEBGL_lose_context');
  if (ext && !gl.isContextLost()) ext.loseContext();
}

function buildScene(pack, renderer) {
  renderer.setPixelRatio(Math.min(globalThis.devicePixelRatio || 1, 2));
  renderer.setClearColor(0x07070d, 1);
  const { meta, arr } = pack.head;
  const [W, H] = meta.image;
  const f = meta.face;
  const faceCx = (f.left[0] + f.right[0]) / 2, faceW = f.right[0] - f.left[0];
  const chinY = f.chin[1], browY = f.forehead[1], faceH = chinY - browY;
  const k = faceW / 613; // the prototype's pixel constants were set on a 613 px face
  const mouth = { x: meta.mouth.center[0], y: meta.mouth.center[1], w: meta.mouth.right[0] - meta.mouth.left[0] };
  const textures = [];
  const tex = (c) => { const t = texture(c); textures.push(t); return t; };
  const tOpen = tex(pack.still), tClosed = tex(pack.closed || drawClosedEyes(pack.still, meta)), tEyes = tex(pack.eyes), tMask = tex(pack.mask);

  // the head's geometry, with the 52 shapes
  const hpos = arr('head.pos'), hn = hpos.length / 3, hidx = arr('head.idx');
  const hg = new THREE.BufferGeometry();
  hg.setAttribute('position', new THREE.BufferAttribute(hpos, 3));
  hg.setAttribute('normal', new THREE.BufferAttribute(arr('head.nrm'), 3));
  hg.setAttribute('uv', new THREE.BufferAttribute(arr('head.uv'), 2));
  hg.setAttribute('uvC', new THREE.BufferAttribute(arr('head.uvC'), 2));
  hg.setIndex(new THREE.BufferAttribute(hidx, 1));
  hg.morphAttributes.position = [];
  hg.morphAttributes.normal = [];
  meta.shapes.forEach((name, s) => {
    const [mx, mxn] = meta.shapeScale[s];
    const p = arr('shape.' + name + '.pos'), n = arr('shape.' + name + '.nrm');
    const fp = new Float32Array(p.length), fn = new Float32Array(n.length);
    for (let i = 0; i < p.length; i++) { fp[i] = (p[i] * mx) / 32767; fn[i] = (n[i] * mxn) / 32767; }
    const ap = new THREE.BufferAttribute(fp, 3); ap.name = name;
    hg.morphAttributes.position.push(ap);
    hg.morphAttributes.normal.push(new THREE.BufferAttribute(fn, 3));
  });
  hg.morphTargetsRelative = true;
  hg.computeBoundingBox();
  const hb = hg.boundingBox, zc = (hb.min.z + hb.max.z) / 2;

  // what's hidden at rest (the mouth's inside, the sockets, the back): a front-depth raster
  const x0 = hb.min.x, y1 = hb.max.y;
  const gw = Math.ceil(hb.max.x - x0) + 2, gh = Math.ceil(y1 - hb.min.y) + 2;
  const depth = new Float32Array(gw * gh).fill(-1e9);
  {
    const X = (i) => hpos[i * 3] - x0, Y = (i) => y1 - hpos[i * 3 + 1], Z = (i) => hpos[i * 3 + 2];
    for (let t = 0; t < hidx.length; t += 3) {
      const a = hidx[t], b = hidx[t + 1], c = hidx[t + 2];
      const ax = X(a), ay = Y(a), bx = X(b), by = Y(b), cx = X(c), cy = Y(c);
      const den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
      if (Math.abs(den) < 1e-9) continue;
      const minx = Math.max(0, Math.floor(Math.min(ax, bx, cx))), maxx = Math.min(gw - 1, Math.ceil(Math.max(ax, bx, cx)));
      const miny = Math.max(0, Math.floor(Math.min(ay, by, cy))), maxy = Math.min(gh - 1, Math.ceil(Math.max(ay, by, cy)));
      for (let y = miny; y <= maxy; y++) for (let x = minx; x <= maxx; x++) {
        const px = x + 0.5, py = y + 0.5;
        const l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den;
        const l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den;
        const l3 = 1 - l1 - l2;
        if (l1 < -1e-4 || l2 < -1e-4 || l3 < -1e-4) continue;
        const z = l1 * Z(a) + l2 * Z(b) + l3 * Z(c);
        const q = y * gw + x;
        if (z > depth[q]) depth[q] = z;
      }
    }
    const hid = new Float32Array(hn);
    for (let i = 0; i < hn; i++) {
      const q = Math.floor(Y(i)) * gw + Math.floor(X(i));
      hid[i] = q >= 0 && q < depth.length ? Math.max(0, depth[q] - Z(i)) : 0;
    }
    hg.setAttribute('hid', new THREE.BufferAttribute(hid, 1));
  }
  // the lips' front depth, where the teeth sit
  let zLip = -1e9;
  for (let i = 0; i < hn; i++) {
    if (Math.abs(hpos[i * 3] - mouth.x) < mouth.w * 0.2 && Math.abs(-hpos[i * 3 + 1] - mouth.y) < 30 * k) zLip = Math.max(zLip, hpos[i * 3 + 2]);
  }

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(0, W, 0, -H, -5000, 5000);
  camera.position.set(0, 0, 2000); // the bounds are relative to this

  // the head turns about a point in the neck
  const pivot = new THREE.Vector3(faceCx, -(chinY + 0.18 * faceH), zc);
  const rig = new THREE.Group(); rig.position.copy(pivot);
  const headSpace = new THREE.Group(); headSpace.position.copy(pivot).negate();
  rig.add(headSpace); scene.add(rig);

  // the backplate: the portrait on a grid that follows the face's depth and breathes
  const cols = 273, rows = 155;
  const plate = new THREE.PlaneGeometry(W, H, cols - 1, rows - 1); plate.translate(W / 2, -H / 2, 0);
  {
    const pp = plate.attributes.position, n = pp.count;
    let zd = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const gx = Math.floor(pp.getX(i) - x0), gy = Math.floor(y1 - pp.getY(i));
      const d = gx >= 0 && gy >= 0 && gx < gw && gy < gh ? depth[gy * gw + gx] : -1e9;
      zd[i] = d > -1e8 ? Math.max(d, zc) : zc;
    }
    for (let pass = 0; pass < 3; pass++) {
      const o = new Float32Array(n);
      for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
        let sum = 0, m = 0;
        for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) {
          const rr = r + dr, cc = c + dc;
          if (rr < 0 || cc < 0 || rr >= rows || cc >= cols) continue;
          sum += zd[rr * cols + cc]; m++;
        }
        o[r * cols + c] = sum / m;
      }
      zd = o;
    }
    plate.setAttribute('zd', new THREE.BufferAttribute(zd, 1));
  }
  const plateU = {
    tMap: { value: tOpen }, hRot: { value: new THREE.Matrix3() }, pivot: { value: pivot.clone() }, hOff: { value: new THREE.Vector3() },
    zc: { value: zc }, headEll: { value: new THREE.Vector4(faceCx, -(browY + chinY) / 2 + 0.08 * faceH, faceW * 0.62, faceH * 0.72) },
    neck: { value: new THREE.Vector4(chinY, chinY + 0.42 * faceH, faceW * 0.3, faceCx) }, breath: { value: 0 }, k: { value: k },
    size: { value: new THREE.Vector2(W, H) },
  };
  const plateMat = new THREE.ShaderMaterial({
    uniforms: plateU, depthWrite: false, depthTest: false,
    vertexShader: `
      uniform mat3 hRot; uniform vec3 pivot; uniform vec3 hOff; uniform float zc; uniform vec4 headEll; uniform vec4 neck; uniform float breath; uniform float k; uniform vec2 size;
      attribute float zd;
      varying vec2 vUv;
      void main() {
        vUv = uv;
        vec3 p = position;
        vec2 e = (p.xy - headEll.xy) / headEll.zw;
        float wh = 1.0 - smoothstep(0.92, 1.45, length(e));
        float yi = -p.y;
        float wn = (1.0 - smoothstep(neck.x, neck.y, yi)) * (1.0 - smoothstep(neck.z, neck.z * 1.8, abs(p.x - neck.w))) * step(neck.x - 60.0 * k, yi);
        float w = max(wh, wn);
        vec3 q = vec3(p.xy, zd);
        vec3 moved = pivot + hRot * (q - pivot) + hOff;
        vec2 d = (moved.xy - q.xy) * w;
        float ws = smoothstep(neck.x - 40.0 * k, neck.y + 120.0 * k, yi);
        d.y += breath * ws;
        d.x += breath * 0.12 * ws * (p.x - neck.w) / (300.0 * k);
        // the photo's border stays put, so nothing past it comes into view
        float border = min(min(p.x, size.x - p.x), min(-p.y, size.y + p.y));
        d *= smoothstep(0.0, 48.0 * k, border);
        gl_Position = projectionMatrix * modelViewMatrix * vec4(p.xy + d, -1000.0, 1.0);
      }`,
    fragmentShader: `
      uniform sampler2D tMap; varying vec2 vUv;
      void main() { gl_FragColor = vec4(texture2D(tMap, vUv).rgb, 1.0); }`,
  });
  const plateMesh = new THREE.Mesh(plate, plateMat); plateMesh.renderOrder = -10; plateMesh.frustumCulled = false;
  scene.add(plateMesh);

  // the head's material: the photo, the closed portrait at a full blink, the relight term
  const poly = (pts) => pts.map((p) => new THREE.Vector2(p[0], -p[1]));
  const shrink = (pts, px) => { const c = pts.reduce((a, p) => a.add(p.clone()), new THREE.Vector2()).multiplyScalar(1 / pts.length); return pts.map((p) => p.clone().sub(c).multiplyScalar(1 - px / p.distanceTo(c)).add(c)); };
  const eyeA = shrink(poly(meta.eyes[0].outline), 1.5 * k), eyeB = shrink(poly(meta.eyes[1].outline), 1.5 * k);
  const bbox = (pts) => { const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y); return new THREE.Vector4(Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)); };
  const headU = {
    tOpen: { value: tOpen }, tClosed: { value: tClosed }, tMask: { value: tMask },
    blinkA: { value: 0 }, blinkB: { value: 0 },
    eyeA: { value: eyeA }, eyeB: { value: eyeB }, boxA: { value: bbox(eyeA) }, boxB: { value: bbox(eyeB) },
    mouthC: { value: new THREE.Vector2(mouth.x, -mouth.y) },
    lipPoly: { value: meta.mouth.outer.map((p) => new THREE.Vector2(mouth.x + (p[0] - mouth.x) * 1.12, -(mouth.y + (p[1] - mouth.y) * 1.9))) },
    L0: { value: new THREE.Vector3(0.0, 0.42, 1.0).normalize() }, relight: { value: 0.85 }, k: { value: k },
  };
  const headMat = new THREE.ShaderMaterial({
    uniforms: headU, side: THREE.DoubleSide, transparent: true, depthWrite: true, depthTest: true,
    stencilWrite: true, stencilRef: 1, stencilFunc: THREE.AlwaysStencilFunc, stencilZPass: THREE.ReplaceStencilOp,
    vertexShader: `
      #include <common>
      #include <morphtarget_pars_vertex>
      attribute vec2 uvC; attribute float hid;
      varying vec2 vUv; varying vec2 vUvC; varying vec3 vN; varying vec3 vN0; varying vec3 vRest; varying float vHid;
      void main() {
        vUv = uv; vUvC = uvC; vRest = position; vN0 = normal; vHid = hid;
        #include <beginnormal_vertex>
        #include <morphnormal_vertex>
        #include <begin_vertex>
        #include <morphtarget_vertex>
        vN = mat3(modelMatrix) * objectNormal;
        gl_Position = projectionMatrix * modelViewMatrix * vec4(transformed, 1.0);
      }`,
    fragmentShader: `
      uniform sampler2D tOpen; uniform sampler2D tClosed; uniform sampler2D tMask;
      uniform float blinkA; uniform float blinkB;
      uniform vec2 eyeA[16]; uniform vec2 eyeB[16]; uniform vec4 boxA; uniform vec4 boxB;
      uniform vec2 mouthC; uniform vec2 lipPoly[20]; uniform vec3 L0; uniform float relight; uniform float k;
      varying vec2 vUv; varying vec2 vUvC; varying vec3 vN; varying vec3 vN0; varying vec3 vRest; varying float vHid;
      bool inA(vec2 p) {
        if (p.x < boxA.x || p.x > boxA.z || p.y < boxA.y || p.y > boxA.w) return false;
        bool c = false;
        for (int i = 0; i < 16; i++) { vec2 a = eyeA[i]; vec2 b = eyeA[i == 0 ? 15 : i - 1];
          if (((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)) c = !c; }
        return c;
      }
      bool inB(vec2 p) {
        if (p.x < boxB.x || p.x > boxB.z || p.y < boxB.y || p.y > boxB.w) return false;
        bool c = false;
        for (int i = 0; i < 16; i++) { vec2 a = eyeB[i]; vec2 b = eyeB[i == 0 ? 15 : i - 1];
          if (((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)) c = !c; }
        return c;
      }
      bool inLips(vec2 p) {
        bool c = false;
        for (int i = 0; i < 20; i++) { vec2 a = lipPoly[i]; vec2 b = lipPoly[i == 0 ? 19 : i - 1];
          if (((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)) c = !c; }
        return c;
      }
      void main() {
        // the eye openings: the eyeballs show through
        if (inA(vRest.xy) || inB(vRest.xy)) discard;
        float crease = 12.0 * k; // hidden-surface tests need a margin at creases
        bool mouthZone = abs(vRest.x - mouthC.x) < 220.0 * k && abs(vRest.y - mouthC.y) < 140.0 * k && inLips(vRest.xy);
        bool inside = mouthZone && (!gl_FrontFacing || vHid > crease);
        vec3 col;
        float a = 1.0;
        if (inside) {
          float deep = smoothstep(10.0 * k, 60.0 * k, vHid);
          float below = smoothstep(4.0 * k, -26.0 * k, vRest.y - mouthC.y);
          vec3 lipInner = vec3(0.42, 0.17, 0.18);
          vec3 roof = vec3(0.07, 0.022, 0.026);
          vec3 tongue = vec3(0.34, 0.12, 0.13) * (1.0 - 0.55 * smoothstep(30.0 * k, 120.0 * k, vHid));
          col = mix(lipInner, mix(roof, tongue, below), deep);
        } else {
          col = texture2D(tOpen, vUv).rgb;
          vec2 m = texture2D(tMask, vUvC).rg;
          float wc = clamp(m.r * smoothstep(0.5, 0.97, blinkA) + m.g * smoothstep(0.5, 0.97, blinkB), 0.0, 1.0);
          col = mix(col, texture2D(tClosed, vUvC).rgb, wc);
          vec3 n = normalize(vN), n0 = normalize(vN0);
          float d = dot(n, L0) - dot(n0, L0);
          col *= clamp(1.0 + relight * d, 0.4, 1.5);
          a = smoothstep(0.04, 0.32, n0.z);
          // what can't be seen, or is hidden at rest, must not mask the eyeballs
          if (a < 0.02 || vHid > crease || !gl_FrontFacing) discard;
        }
        gl_FragColor = vec4(col, a);
        gl_FragDepth = inside ? 0.9999 : gl_FragCoord.z; // the mouth's inside sits behind the teeth
      }`,
  });
  const head = new THREE.Mesh(hg, headMat);
  head.updateMorphTargets();
  head.renderOrder = 5; head.frustumCulled = false;
  headSpace.add(head);
  const infl = head.morphTargetInfluences, IDX = head.morphTargetDictionary;

  // the eyeballs: spheres behind the openings, textured from the cleaned eye crop
  const [ecx0, ecy0, ecw, ech] = meta.eyeCrop;
  const eyes = meta.eyes.map((e) => {
    const iris = e.iris, r = e.width * 0.56;
    const zs = [];
    for (let i = 0; i < hn; i++) {
      const x = hpos[i * 3], y = hpos[i * 3 + 1];
      for (const p of e.outline) if (Math.hypot(x - p[0], y + p[1]) < Math.max(2.5, 5 * k)) { zs.push(hpos[i * 3 + 2]); break; }
    }
    zs.sort((a, b) => a - b);
    const zFront = zs.length ? zs[zs.length >> 1] : zLip;
    const center = new THREE.Vector3(iris[0], -iris[1], zFront - 3 * k - r);
    const g = new THREE.SphereGeometry(r, 48, 32);
    g.rotateZ(Math.PI / 2); // the poles to the sides: a clean front
    const p = g.attributes.position, uvs = new Float32Array(p.count * 2);
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i) + center.x, y = p.getY(i) + center.y;
      uvs[i * 2] = (x - ecx0) / ecw; uvs[i * 2 + 1] = 1 - (-y - ecy0) / ech;
    }
    g.setAttribute('uv', new THREE.BufferAttribute(uvs, 2));
    const cl = e.catchlight || [iris[0], iris[1], 3.6 * k];
    const u = {
      tEyes: { value: tEyes }, tClosed: { value: tClosed }, size: { value: new THREE.Vector2(W, H) }, center: { value: center.clone() }, blink: { value: 0 },
      glint: { value: new THREE.Vector3() }, glintR: { value: 3.6 * k }, glintI: { value: 0.85 },
    };
    const m = new THREE.ShaderMaterial({
      uniforms: u, transparent: true, depthTest: false, depthWrite: false,
      stencilWrite: true, stencilRef: 1, stencilFunc: THREE.NotEqualStencilFunc, stencilZPass: THREE.KeepStencilOp,
      vertexShader: `
        uniform vec3 center;
        varying vec2 vUv; varying vec3 vW; varying vec3 vN; varying vec3 vHome;
        void main() { vUv = uv; vHome = center + position; vec4 w = modelMatrix * vec4(position, 1.0); vW = w.xyz; vN = normalize(mat3(modelMatrix) * normal);
          gl_Position = projectionMatrix * viewMatrix * w; }`,
      fragmentShader: `
        uniform sampler2D tEyes; uniform sampler2D tClosed; uniform vec2 size; uniform float blink;
        uniform vec3 glint; uniform float glintR; uniform float glintI;
        varying vec2 vUv; varying vec3 vW; varying vec3 vN; varying vec3 vHome;
        void main() {
          vec3 col = texture2D(tEyes, vUv).rgb;
          col *= mix(0.6, 1.0, smoothstep(0.15, 0.75, vN.z));
          float d = length(vW.xy - glint.xy);
          col += glintI * (1.0 - smoothstep(glintR * 0.4, glintR, d)) * vec3(1.0, 0.98, 0.96) * (1.0 - blink);
          vec3 shut = texture2D(tClosed, vec2(vHome.x / size.x, 1.0 + vHome.y / size.y)).rgb;
          col = mix(col, shut, smoothstep(0.72, 0.98, blink));
          gl_FragColor = vec4(col, 1.0);
        }`,
    });
    const mesh = new THREE.Mesh(g, m); mesh.position.copy(center); mesh.renderOrder = 6; mesh.frustumCulled = false;
    headSpace.add(mesh);
    return { mesh, u, glintLocal: new THREE.Vector3(cl[0], -cl[1], zFront + 5 * k) };
  });

  // the teeth: the base's upper row seated at the lip line, a mirrored lower row on the jaw
  const tpos0 = arr('teeth.pos'), tidx = arr('teeth.idx');
  let tminY = Infinity, tmaxZ = -Infinity, tcx = 0;
  for (let i = 0; i < tpos0.length; i += 3) { tminY = Math.min(tminY, tpos0[i + 1]); tmaxZ = Math.max(tmaxZ, tpos0[i + 2]); tcx += tpos0[i]; }
  tcx /= tpos0.length / 3;
  const tipY = -mouth.y - 6 * k, dyT = tipY - tminY, dzT = zLip - 28 * k - tmaxZ, dxT = mouth.x - tcx;
  const upperPos = new Float32Array(tpos0.length), lowerPos = new Float32Array(tpos0.length);
  for (let i = 0; i < tpos0.length; i += 3) {
    const x = tpos0[i] + dxT, y = tpos0[i + 1] + dyT, z = tpos0[i + 2] + dzT;
    upperPos.set([mouth.x + (x - mouth.x) * 0.95, y, z], i);
    lowerPos.set([mouth.x + (x - mouth.x) * 0.86, tipY + 4 * k - (y - tipY) * 0.85, z - 11 * k], i);
  }
  const lowerIdx = new (tidx.constructor)(tidx.length);
  for (let t = 0; t < tidx.length; t += 3) { lowerIdx[t] = tidx[t]; lowerIdx[t + 1] = tidx[t + 2]; lowerIdx[t + 2] = tidx[t + 1]; }
  const teethMat = new THREE.ShaderMaterial({
    uniforms: { zFront: { value: zLip - 30 * k }, k: { value: k } },
    vertexShader: `varying vec3 vN; varying vec3 vP;
      void main() { vP = position; vN = normalize(mat3(modelMatrix) * normal); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: `uniform float zFront; uniform float k; varying vec3 vN; varying vec3 vP;
      void main() {
        float lit = 0.5 + 0.5 * max(0.0, dot(normalize(vN), normalize(vec3(0.0, 0.35, 1.0))));
        float depth = smoothstep(zFront - 110.0 * k, zFront - 4.0 * k, vP.z);
        vec3 col = vec3(0.78, 0.74, 0.68) * lit * mix(0.16, 0.85, depth);
        gl_FragColor = vec4(col, 1.0);
      }`,
  });
  const teethGeos = [];
  const mkTeeth = (p, ix) => {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(p, 3)); g.setIndex(new THREE.BufferAttribute(ix, 1)); g.computeVertexNormals();
    teethGeos.push(g);
    const m = new THREE.Mesh(g, teethMat); m.renderOrder = 1; m.frustumCulled = false; headSpace.add(m);
    return m;
  };
  mkTeeth(upperPos, tidx);
  const lowerTeeth = mkTeeth(lowerPos, lowerIdx);
  const jawVec = new THREE.Vector3(...meta.mouth.jaw);

  const face = { cx: faceCx, w: faceW, top: browY, h: faceH };
  const m3 = new THREE.Matrix3(), m4 = new THREE.Matrix4(), tmp = new THREE.Vector3();
  return {
    renderer, infl, IDX, k, face, W, H,
    resize(w, h) {
      renderer.setSize(w, h, false);
      const v = frameView(W, H, face, w / h);
      camera.left = v.x0; camera.right = v.x0 + v.w; camera.top = -v.y0; camera.bottom = -(v.y0 + v.h);
      camera.updateProjectionMatrix();
    },
    /** One frame: pose in degrees, blinks per image side, jaw, breath rise. */
    draw(pose, blinkA, blinkB, rise) {
      headU.blinkA.value = blinkA; headU.blinkB.value = blinkB;
      eyes[0].u.blink.value = blinkA; eyes[1].u.blink.value = blinkB;
      lowerTeeth.position.copy(jawVec).multiplyScalar(infl[IDX.jawOpen] * 0.82);
      rig.rotation.set(pose.pitch * D2R, pose.yaw * D2R, -pose.roll * D2R);
      rig.position.set(pivot.x, pivot.y + rise * 0.45, pivot.z);
      rig.updateMatrixWorld(true);
      m4.extractRotation(rig.matrixWorld); m3.setFromMatrix4(m4);
      plateU.hRot.value.copy(m3);
      plateU.hOff.value.set(0, rig.position.y - pivot.y, 0);
      plateU.breath.value = rise;
      for (const e of eyes) e.u.glint.value.copy(headSpace.localToWorld(tmp.copy(e.glintLocal)));
      renderer.render(scene, camera);
    },
    gaze(gx, gy) { for (const e of eyes) e.mesh.rotation.set(-gy * D2R, gx * D2R, 0); },
    dispose() {
      for (const t of textures) t.dispose();
      hg.dispose(); plate.dispose(); headMat.dispose(); plateMat.dispose(); teethMat.dispose();
      for (const g of teethGeos) g.dispose();
      for (const e of eyes) { e.mesh.geometry.dispose(); e.mesh.material.dispose(); }
      letGo(renderer);
    },
  };
}

// ---------- the still (no head, no WebGL 2) ----------

function buildStill(pack, canvas) {
  const meta = pack.head && pack.head.meta;
  const W = pack.still.width, H = pack.still.height;
  const face = meta
    ? { cx: (meta.face.left[0] + meta.face.right[0]) / 2, w: meta.face.right[0] - meta.face.left[0], top: meta.face.forehead[1], h: meta.face.chin[1] - meta.face.forehead[1] }
    : { cx: W / 2, w: Math.min(W, H) * 0.4, top: H * 0.18, h: Math.min(W, H) * 0.5 };
  const g = canvas.getContext('2d');
  let anim = null;
  return {
    resize(w, h) {
      const dpr = Math.min(globalThis.devicePixelRatio || 1, 2);
      canvas.width = Math.max(1, Math.round(w * dpr)); canvas.height = Math.max(1, Math.round(h * dpr));
      const v = frameView(W, H, face, w / h);
      g.fillStyle = '#07070d'; g.fillRect(0, 0, canvas.width, canvas.height);
      g.drawImage(pack.still, v.x0, v.y0, v.w, v.h, 0, 0, canvas.width, canvas.height);
    },
    /** Breathing: a 0.6% scale ease, slower when resting or quiet. */
    breathe(secs) {
      if (anim) anim.cancel();
      canvas.style.transformOrigin = '50% 100%';
      anim = canvas.animate ? canvas.animate([{ transform: 'scale(1)' }, { transform: 'scale(1.006)' }], { duration: secs * 500, direction: 'alternate', iterations: Infinity, easing: 'ease-in-out' }) : null;
    },
    dispose() { if (anim) anim.cancel(); },
  };
}

// ---------- the avatar ----------

/**
 * Loads the pack at packUrl (like /desk/avatars/butler/) and starts drawing
 * in element. options:
 *   reducedMotion  defaults to the system's setting
 *   still          true: draw the still only
 *   debug          { shapes, pose, gaze, breath, time, neutral }: a frozen pose for
 *                  checking by eye (neutral: no state's shapes, eyes open)
 * Resolves to the avatar once its first frame is drawn; rejects only when
 * not even the still loads. avatar.mode is 'head' or 'still';
 * avatar.fitted says whether the pack has a fitted head; avatar.problem
 * says in plain words why a fitted head isn't shown.
 */
export async function createAvatar(element, packUrl, options = {}) {
  const base = packUrl.endsWith('/') ? packUrl : packUrl + '/';
  const pack = await loadPack(base);
  const mq = globalThis.matchMedia ? matchMedia('(prefers-reduced-motion: reduce)') : null;
  const reduced = () => (options.reducedMotion ?? (mq ? mq.matches : false));
  const debug = options.debug || null;

  const canvas = document.createElement('canvas');
  canvas.style.cssText = 'display:block;width:100%;height:100%;transition:filter 1.2s ease';
  canvas.setAttribute('aria-hidden', 'true');
  element.appendChild(canvas);

  const avatar = {
    mode: 'still', fitted: !!(pack.files.head && pack.files.eyes && pack.files.eyemask), problem: pack.problem,
    setState, moment, arrive, speak, stop, dispose, fit,
  };

  // ---- the head, or the still ----
  let head = null, still = null, stillCanvas = null;
  if (pack.head && !options.still) {
    try {
      head = buildHead(pack, canvas);
      avatar.mode = 'head';
    } catch (e) {
      head = null;
      avatar.problem = /WebGL/i.test(String(e && e.message)) ? 'WebGL 2 is off here; showing the portrait.' : "The head couldn't be drawn (" + (e && e.message) + '); showing the portrait.';
    }
  }
  const showStill = () => {
    if (still) return;
    stillCanvas = document.createElement('canvas');
    stillCanvas.style.cssText = 'display:block;width:100%;height:100%;transition:filter 1.2s ease';
    stillCanvas.setAttribute('aria-hidden', 'true');
    canvas.style.display = 'none';
    element.appendChild(stillCanvas);
    still = buildStill(pack, stillCanvas);
    still.resize(element.clientWidth || 1, element.clientHeight || 1);
    still.breathe(PROFILES[S.state].slow ? 6 : 4.5);
    applyDim();
    avatar.mode = 'still';
  };
  const hideStill = () => {
    if (!still) return;
    still.dispose(); stillCanvas.remove(); still = null; stillCanvas = null;
    canvas.style.display = 'block';
    avatar.mode = 'head';
  };

  // ---- state ----
  const S = {
    state: 'resting', moment: null, momentUntil: 0, glanceUntil: 0,
    blinkT0: -10, nextBlink: now() + 1.5,
    gaze: { x: 0, y: 0 }, gazeT: { x: 0, y: 0 }, nextSaccade: 0,
    nodT0: -10, nextNod: 1e12, nodAmp: 3,
    closed: 1, breathPhase: 0, breathAmp: 1.5,
    pose: { pitch: 0, yaw: 0, roll: 0 },
    talk: null,
  };
  const n = head ? head.infl.length : 0;
  const slowT = new Float32Array(n), slowW = new Float32Array(n), fastT = new Float32Array(n), fastW = new Float32Array(n);
  const addTo = (target, shapes, k = 1, mouthToo = true) => {
    for (const name in shapes) {
      if (!mouthToo && MOUTH.test(name)) continue;
      const i = head.IDX[name];
      if (i !== undefined) target[i] += shapes[name] * k;
    }
  };
  const profile = () => PROFILES[S.talk ? (S.state === 'urgent' ? 'urgent' : 'speaking') : S.state];
  function applyDim() {
    const d = profile().dim;
    const f = d ? `brightness(${d})` : 'none';
    canvas.style.filter = f;
    if (stillCanvas) stillCanvas.style.filter = f;
  }

  function setState(state) {
    if (disposed) return;
    if (!STATES.includes(state)) { console.warn('avatar: no state ' + state); return; }
    if (state === S.state) return;
    S.state = state;
    const P = PROFILES[state];
    S.nextNod = P.nod && !reduced() ? now() + rand(1.2, 2.5) : 1e12;
    S.nextSaccade = 0;
    applyDim();
    if (still) still.breathe(P.slow ? 6 : 4.5);
    wake();
  }
  function moment(name) {
    if (disposed) return;
    if (!MOMENTS[name]) { console.warn('avatar: no moment ' + name); return; }
    S.moment = name; S.momentUntil = now() + MOMENTS[name].secs;
    wake();
  }
  function arrive() {
    if (disposed) return;
    S.glanceUntil = now() + 1.6;
    S.gazeT = { x: 0, y: 0 }; S.nextSaccade = S.glanceUntil;
    wake();
  }

  // ---- speech ----
  let audioCtx = null, synthVoice = null;
  const synth = globalThis.speechSynthesis || null;
  const pickVoice = () => {
    const vs = synth ? synth.getVoices() : [];
    synthVoice = vs.find((v) => /daniel/i.test(v.name) && /^en/i.test(v.lang)) || vs.find((v) => /en-GB/i.test(v.lang) && /male/i.test(v.name))
      || vs.find((v) => /en-GB/i.test(v.lang)) || vs.find((v) => /^en/i.test(v.lang)) || null;
  };
  if (synth) { pickVoice(); synth.addEventListener?.('voiceschanged', pickVoice); }

  /** Ends the current speech: its promise resolves `done`. */
  function endTalk(talk, done) {
    if (!talk || talk.over) return;
    talk.over = true;
    if (S.talk === talk) S.talk = null;
    try { talk.source && talk.source.stop(); } catch {}
    if (talk.browser && synth && !done) synth.cancel();
    clearTimeout(talk.timer);
    clearTimeout(talk.watch);
    applyDim();
    talk.resolve(done);
  }

  function speak({ text = '', audioUrl = null, browser = false, onWord = null } = {}) {
    if (disposed) return Promise.resolve(false);
    endTalk(S.talk, false);
    return new Promise((resolve, reject) => {
      const talk = { resolve, reject, over: false, tl: null, playing: false, onWord, lastWord: -1, ends: new Set() };
      S.talk = talk;
      const fail = (msg) => { if (talk.over) return; talk.over = true; clearTimeout(talk.timer); clearTimeout(talk.watch); if (S.talk === talk) S.talk = null; applyDim(); reject(new Error(msg)); };
      if (audioUrl) {
        (async () => {
          try {
            audioCtx = audioCtx || new (globalThis.AudioContext || globalThis.webkitAudioContext)();
            if (audioCtx.state === 'suspended') {
              await Promise.race([audioCtx.resume().catch(() => {}), new Promise((ok) => setTimeout(ok, 3000))]);
              if (talk.over) return;
              if (audioCtx.state !== 'running') { fail("The voice didn't start."); return; }
            }
            const r = await fetch(audioUrl);
            if (!r.ok) throw new Error('the voice ' + r.status);
            const data = await r.arrayBuffer();
            if (talk.over) return;
            const buf = await audioCtx.decodeAudioData(data);
            if (talk.over) return;
            const [v0, v1] = voicedSpan(buf.getChannelData(0), buf.sampleRate);
            talk.tl = stretchTimeline(buildTimeline(text), v0, v1);
            const src = audioCtx.createBufferSource(); src.buffer = buf;
            const an = audioCtx.createAnalyser(); an.fftSize = 1024;
            src.connect(an); an.connect(audioCtx.destination);
            talk.source = src; talk.analyser = an; talk.level = 0; talk.samples = new Float32Array(an.fftSize);
            const at = audioCtx.currentTime + 0.05;
            talk.clock = () => audioCtx.currentTime - at;
            src.onended = () => endTalk(talk, true);
            src.start(at);
            talk.playing = true;
            applyDim();
            wake();
          } catch (e) { fail("The voice didn't play: " + (e && e.message)); }
        })();
      } else if (browser) {
        if (!synth || !globalThis.SpeechSynthesisUtterance) { fail('There is no built-in voice here.'); return; }
        const tl = buildTimeline(text);
        talk.tl = tl; talk.browser = true;
        const u = new SpeechSynthesisUtterance(text);
        if (synthVoice) u.voice = synthVoice;
        u.rate = 0.96; u.pitch = 0.9;
        let t0 = 0;
        talk.clock = () => now() - t0;
        u.onstart = () => {
          if (talk.over) return;
          clearTimeout(talk.timer); t0 = now(); talk.playing = true; applyDim(); wake();
          // some voices never send onend (network voices cut off): the talk ends anyway
          talk.watch = setTimeout(() => endTalk(talk, true), (2 * tl.dur + 5) * 1000);
        };
        u.onboundary = (e) => {
          if (talk.over || (e.name && e.name !== 'word')) return;
          const w = tl.words.find((x) => x.i1 > e.charIndex);
          if (w) { talk.synced = true; talk.word = w; t0 = now() - w.t0; }
        };
        u.onend = () => endTalk(talk, true);
        u.onerror = (e) => { if (e.error === 'interrupted' || e.error === 'canceled') endTalk(talk, false); else fail("The voice didn't play: " + e.error); };
        talk.timer = setTimeout(() => { if (!talk.over && !talk.playing) { synth.cancel(); fail("The voice didn't start."); } }, 5000);
        synth.cancel();
        synth.speak(u);
      } else fail('speak needs audioUrl or browser: true');
    });
  }
  function stop() { endTalk(S.talk, false); }

  // ---- the frame loop ----
  let raf = 0, prev = now(), lastDraw = 0, disposed = false, lost = false, drawn = 0;
  const loop = () => {
    raf = 0;
    if (disposed || lost || !head) return;
    if (document.hidden) return; // drawing stops; visibilitychange starts it again
    const t = now();
    const talking = S.talk && S.talk.playing;
    const busy = talking || S.moment || t < S.glanceUntil;
    if (profile().slow && !busy && t - lastDraw < 1 / 30 - 0.004) { raf = requestAnimationFrame(loop); return; }
    lastDraw = t;
    frame(t);
    raf = requestAnimationFrame(loop);
  };
  function wake() { if (!raf && head && !disposed && !lost && !document.hidden) { prev = now(); raf = requestAnimationFrame(loop); } }

  function frame(tNow) {
    drawn++;
    const t = debug ? (debug.time ?? 0) : tNow;
    const dt = debug ? 10 : Math.min(0.1, tNow - prev); // slow frames still keep time; a long pause doesn't jump
    prev = tNow;
    const P = debug && debug.neutral ? { ...profile(), shapes: {}, closed: 0, micro: 0 } : profile();
    const rm = reduced();
    const talk = S.talk && S.talk.playing ? S.talk : null;
    const { infl, IDX } = head;

    // the voice's clock
    let tau = -1;
    if (talk) {
      tau = talk.clock();
      if (talk.synced && talk.word) tau = Math.min(tau, talk.word.t1 + 0.12);
      if (talk.onWord) {
        const wi = talk.tl.words.findIndex((w) => tau >= w.t0 - 0.02 && tau < w.t1);
        if (wi >= 0 && wi !== talk.lastWord) { talk.lastWord = wi; try { talk.onWord(talk.tl.words[wi].i0, talk.tl.words[wi].i1); } catch {} }
      }
      if (!rm) for (const e of talk.tl.ends) if (tau > e && !talk.ends.has(e)) { talk.ends.add(e); S.nodT0 = t; S.nodAmp = 2.2; }
    }

    // the slow layer: state, moment, glance
    slowT.fill(0);
    addTo(slowT, P.shapes, 1, !rm);
    if (S.moment && tNow < S.momentUntil) addTo(slowT, MOMENTS[S.moment].shapes, 1, !rm);
    else S.moment = null;
    const glancing = tNow < S.glanceUntil;
    if (glancing) addTo(slowT, GLANCE);
    if (talk && tau > 0) {
      const w = talk.tl.words.find((x) => tau >= x.t0 && tau < x.t1);
      if (w && w.long) addTo(slowT, { browInnerUp: 0.22, ...both('browOuterUp', 0.14) }); // brows lift on long words
    }
    for (let i = 0; i < n; i++) slowW[i] = approach(slowW[i], slowT[i], 5.5, dt);

    // the fast layer: mouth shapes, while the voice plays
    fastT.fill(0);
    if (talk && tau > 0) {
      let level = 1;
      if (talk.analyser) {
        talk.analyser.getFloatTimeDomainData(talk.samples);
        let s = 0;
        for (const v of talk.samples) s += v * v;
        talk.level = approach(talk.level, clamp(Math.sqrt(s / talk.samples.length) / 0.12, 0, 1), 30, dt);
        level = 0.35 + 0.65 * talk.level;
      }
      for (const e of talk.tl.ev) {
        if (e.t1 + 0.07 < tau) continue;
        if (e.t0 - 0.07 > tau) break;
        const w = ease((tau - (e.t0 - 0.06)) / 0.08) * (1 - ease((tau - (e.t1 - 0.02)) / 0.08));
        addTo(fastT, VIS[e.vis], w * e.amp * level);
      }
      if (talk.analyser) fastT[IDX.jawOpen] += 0.22 * talk.level; // the jaw follows the voice's loudness
    }
    for (let i = 0; i < n; i++) fastW[i] = approach(fastW[i], fastT[i], 26, dt);

    // the eyes: closure and blinks
    const closedTarget = glancing ? 0 : P.closed;
    S.closed = approach(S.closed, closedTarget, closedTarget ? 2.2 : 6, dt);
    if (!debug && t >= S.nextBlink && S.closed < 0.2) {
      S.blinkT0 = t;
      S.nextBlink = t + (Math.random() < 0.16 ? 0.34 : talk ? rand(1.8, 3.6) : rand(2.5, 6.0));
    }
    const blink = Math.max(S.closed, blinkCurve(t - S.blinkT0));

    // the gaze: saccades; the lids follow
    const mode = glancing ? 'viewer' : talk ? 'talk' : P.gaze;
    if (!debug && t >= S.nextSaccade) {
      let fx = 0, fy = 0, hold = rand(0.6, 2.4);
      if (mode === 'think') { if (Math.random() < 0.2) hold = rand(0.5, 0.9); else { fx = -9 + rand(-2.5, 2.5); fy = 5.5 + rand(-1.5, 1.5); } }
      else if (mode === 'talk' && Math.random() < 0.12) { fx = rand(-7, 7); fy = rand(-2, 4); hold = rand(0.4, 0.8); }
      else if (mode === 'closed') { fy = -3; hold = 3; }
      S.gazeT = { x: fx + rand(-0.9, 0.9), y: fy + rand(-0.6, 0.6) };
      S.nextSaccade = t + hold;
    }
    if (debug) S.gazeT = { x: debug.gaze?.x ?? 0, y: debug.gaze?.y ?? 0 };
    S.gaze.x = approach(S.gaze.x, S.gazeT.x, 32, dt); S.gaze.y = approach(S.gaze.y, S.gazeT.y, 32, dt);
    const gx = S.gaze.x, gy = S.gaze.y;
    head.gaze(gx, gy);
    const lids = {
      ...both('eyeLookUp', (Math.max(0, gy) / 10) * 0.45), ...both('eyeLookDown', (Math.max(0, -gy) / 10) * 0.6),
      eyeLookOut_L: (Math.max(0, gx) / 12) * 0.35, eyeLookIn_R: (Math.max(0, gx) / 12) * 0.35,
      eyeLookOut_R: (Math.max(0, -gx) / 12) * 0.35, eyeLookIn_L: (Math.max(0, -gx) / 12) * 0.35,
    };

    // the shapes, composed
    for (let i = 0; i < n; i++) infl[i] = slowW[i] + fastW[i];
    addTo(infl, lids);
    infl[IDX.eyeBlink_L] = Math.max(infl[IDX.eyeBlink_L], blink);
    infl[IDX.eyeBlink_R] = Math.max(infl[IDX.eyeBlink_R], blink);
    infl[IDX.eyeSquint_L] += 0.3 * ease((infl[IDX.eyeBlink_L] - 0.6) / 0.4);
    infl[IDX.eyeSquint_R] += 0.3 * ease((infl[IDX.eyeBlink_R] - 0.6) / 0.4);
    if (debug && debug.shapes) for (const name in debug.shapes) if (name in IDX) infl[IDX[name]] = debug.shapes[name];
    for (let i = 0; i < n; i++) infl[i] = clamp(infl[i], 0, 1);

    // breathing
    S.breathAmp = approach(S.breathAmp, P.breathAmp, 1.5, dt);
    S.breathPhase += dt * Math.PI * 2 * P.breathRate;
    const br = debug ? (debug.breath ?? 0) : 0.5 - 0.5 * Math.cos(S.breathPhase);
    const rise = S.breathAmp * 5 * head.k * br; // world y is up

    // the head's pose: drift, nods, following the gaze (none of it with reduced motion)
    if (P.nod && t >= S.nextNod && !talk && !rm) { S.nodT0 = t; S.nodAmp = rand(2.2, 3.4); S.nextNod = t + rand(...P.nod); }
    const mi = rm ? 0 : P.micro;
    const tp = {
      pitch: (glancing && !rm ? -1.2 : P.pitch) + mi * (0.4 * Math.sin(t * 0.23 + 2.1) + 0.2 * Math.sin(t * 0.83)) + (rm ? 0 : -0.12 * gy + S.nodAmp * nodCurve(t - S.nodT0)) + (P.slow ? 0.5 * br : 0),
      yaw: (glancing && !rm ? 0 : P.yaw) + mi * (0.55 * Math.sin(t * 0.29 + 1.3) + 0.3 * Math.sin(t * 0.71 + 0.2)) + (rm ? 0 : 0.22 * gx),
      roll: P.roll + mi * 0.3 * Math.sin(t * 0.19 + 0.7),
    };
    if (talk && tau > 0 && !rm) tp.pitch += 0.35 * Math.sin(tau * 5.1) * Math.min(1, tau);
    if (debug && debug.pose) Object.assign(tp, debug.pose);
    const tl = limitPose(tp);
    for (const key of ['pitch', 'yaw', 'roll']) S.pose[key] = approach(S.pose[key], tl[key], key === 'pitch' ? 9 : 4, dt);

    head.draw(S.pose, infl[IDX.eyeBlink_R], infl[IDX.eyeBlink_L], rise); // image-left eye, image-right eye
  }

  // ---- size, visibility, a lost context ----
  const resize = () => {
    const w = Math.max(1, element.clientWidth), h = Math.max(1, element.clientHeight);
    if (head && !lost) head.resize(w, h);
    if (still) still.resize(w, h);
    if (head && !lost && !raf) frame(now()); // a resize repaints at once
  };
  const ro = globalThis.ResizeObserver ? new ResizeObserver(resize) : null;
  if (ro) ro.observe(element); else addEventListener('resize', resize);
  const onVisible = () => { if (!document.hidden) wake(); };
  document.addEventListener('visibilitychange', onVisible);
  const onLost = (e) => { e.preventDefault(); lost = true; cancelAnimationFrame(raf); raf = 0; showStill(); avatar.problem = 'The graphics stopped (WebGL was lost); showing the portrait.'; };
  const onRestored = () => { lost = false; hideStill(); avatar.problem = pack.problem; resize(); wake(); };
  canvas.addEventListener('webglcontextlost', onLost);
  canvas.addEventListener('webglcontextrestored', onRestored);

  function dispose() {
    if (disposed) return;
    disposed = true;
    endTalk(S.talk, false);
    cancelAnimationFrame(raf); raf = 0;
    if (ro) ro.disconnect(); else removeEventListener('resize', resize);
    document.removeEventListener('visibilitychange', onVisible);
    canvas.removeEventListener('webglcontextlost', onLost);
    canvas.removeEventListener('webglcontextrestored', onRestored);
    if (synth) synth.removeEventListener?.('voiceschanged', pickVoice);
    if (head) head.dispose();
    if (still) still.dispose();
    still = null;
    if (audioCtx) audioCtx.close().catch(() => {});
    canvas.remove();
    if (stillCanvas) stillCanvas.remove();
  }

  // ---- go ----
  avatar.lose = head ? () => head.renderer.forceContextLoss() : () => {};
  avatar.shapes = () => (head ? Object.fromEntries(Object.entries(head.IDX).map(([k2, i]) => [k2, head.infl[i]])) : {});
  /** For checks: frames drawn, the pose, the eyes' closure, the voice's clock. */
  avatar.inspect = () => ({
    drawn, state: S.state, pose: { ...S.pose }, closed: S.closed, talking: !!(S.talk && S.talk.playing),
    tau: S.talk && S.talk.playing ? S.talk.clock() : null, filter: canvas.style.filter || (stillCanvas && stillCanvas.style.filter) || '',
    audio: audioCtx ? audioCtx.state : null, still: [pack.still.width, pack.still.height],
  });
  if (!head) showStill();
  else {
    S.closed = PROFILES[S.state].closed;
    resize();
    frame(now());
    wake();
  }
  applyDim();
  return avatar;
}
