// Dev only: see avatar-preview.html.
import { createAvatar, STATES } from '/desk/static/avatar.js';

const q = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
if (q.has('bare')) document.body.classList.add('bare');
$('infoBtn').addEventListener('click', () => { const b = $('bubble'); b.hidden = !b.hidden; $('infoBtn').setAttribute('aria-expanded', String(!b.hidden)); });
const nums = (s) => s.split(',').map(Number);

// a frozen pose from the query
let debug = null;
if (['shapes', 'pose', 'gaze', 'breath', 'neutral', 'freeze'].some((k) => q.has(k))) {
  debug = { time: Number(q.get('time') || 0), breath: Number(q.get('breath') || 0), neutral: q.get('neutral') === '1' };
  if (q.has('shapes')) debug.shapes = Object.fromEntries(q.get('shapes').split(',').map((kv) => { const [k, v] = kv.split(':'); return [k, Number(v)]; }));
  if (q.has('pose')) { const [yaw, pitch, roll = 0] = nums(q.get('pose')); debug.pose = { yaw, pitch, roll }; }
  if (q.has('gaze')) { const [x, y] = nums(q.get('gaze')); debug.gaze = { x, y }; }
}

const status = (a) => { $('status').textContent = `${a.mode}${a.fitted ? ', fitted' : ', not fitted'}${a.problem ? ' — ' + a.problem : ''}`; };
let avatar;
try {
  avatar = await createAvatar($('stage'), q.get('pack') || '/desk/avatars/butler/', {
    debug, still: q.get('nogl') === '1', reducedMotion: q.has('reduced') ? q.get('reduced') === '1' : undefined,
  });
} catch (e) {
  $('status').textContent = e.message;
  window.__result = { error: e.message };
  window.__ready = true;
  throw e;
}
window.__avatar = avatar;
status(avatar);

const stateBtns = STATES.map((s) => {
  const b = document.createElement('button');
  b.type = 'button'; b.textContent = s === 'needs' ? 'Needs you' : s[0].toUpperCase() + s.slice(1); b.dataset.state = s;
  b.addEventListener('click', () => { avatar.setState(s); stateBtns.forEach((x) => x.setAttribute('aria-pressed', String(x === b))); });
  $('states').appendChild(b);
  return b;
});
const st = q.get('state') || 'resting';
avatar.setState(st);
stateBtns.forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.state === st)));
document.querySelectorAll('[data-moment]').forEach((b) => b.addEventListener('click', () => avatar.moment(b.dataset.moment)));
$('arrive').addEventListener('click', () => avatar.arrive());
$('stop').addEventListener('click', () => avatar.stop());
$('dock').addEventListener('submit', async (e) => {
  e.preventDefault();
  const url = $('audio').value.trim();
  try {
    const done = await avatar.speak(url ? { text: $('text').value, audioUrl: url } : { text: $('text').value, browser: true });
    $('status').textContent = done ? 'Spoken' : 'Stopped';
  } catch (err) { $('status').textContent = err.message; }
  setTimeout(() => status(avatar), 1500);
});
if (q.get('moment')) avatar.moment(q.get('moment'));

const frames = (n) => new Promise((ok) => { const step = () => (n-- <= 0 ? ok() : requestAnimationFrame(step)); step(); });
await frames(3);
if (q.get('lose') === '1') { avatar.lose(); await new Promise((ok) => setTimeout(ok, 300)); await frames(2); status(avatar); }
window.__result = { mode: avatar.mode, fitted: avatar.fitted, problem: avatar.problem };
// check=edges: pixels of the clear colour along the frame's top and sides
// (the photo's border pulled into view)
if (q.get('check') === 'edges' && avatar.mode === 'head') {
  const gl = document.querySelector('#stage canvas');
  window.__result.edgeGaps = await new Promise((ok) => requestAnimationFrame(() => {
    const c = document.createElement('canvas'); c.width = gl.width; c.height = gl.height;
    const g = c.getContext('2d'); g.drawImage(gl, 0, 0);
    const d = g.getImageData(0, 0, c.width, c.height).data;
    let gaps = 0;
    const clear = (x, y) => { const o = (y * c.width + x) * 4; return Math.abs(d[o] - 7) <= 1 && Math.abs(d[o + 1] - 7) <= 1 && Math.abs(d[o + 2] - 13) <= 1; };
    for (let x = 0; x < c.width; x++) for (const y of [0, 1, 2]) if (clear(x, y)) gaps++;
    for (let y = 0; y < c.height; y++) for (const x of [0, 1, c.width - 2, c.width - 1]) if (clear(x, y)) gaps++;
    ok(gaps);
  }));
}
window.__ready = true;
