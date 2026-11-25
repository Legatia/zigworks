// Dev only: see fit-checks.html.
import { fit, loadImage, readHead } from '/desk/static/fit.js';

const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[checks] ' + m); };
const still = await loadImage('/desk/avatars/butler/still.jpg');
const closed = await loadImage('/desk/avatars/butler/closed.jpg');
const canvas = (w, h, draw) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d'); g.fillStyle = '#000'; g.fillRect(0, 0, w, h); draw(g); return c; };
const W = still.width, H = still.height;
const attempt = async (photo, closedPhoto) => { try { const r = await fit(photo, closedPhoto); return { ok: true, r }; } catch (e) { return { ok: false, code: e.code, message: e.message }; } };
const results = {};

const upright = await attempt(still);
const meta = readHead(upright.r.head).meta;
results.upright = { ok: upright.ok, turned: upright.r.report.turned };

// a phone photo: pixels turned 90°, an EXIF tag saying so
const exif = await fetch('/desk/avatars/checks/still-exif6.jpg');
if (exif.ok) {
  const blob = await exif.blob();
  const a = await attempt(blob);
  if (!a.ok) results.exif = a;
  else {
    const m = readHead(a.r.head).meta;
    const d = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1]);
    results.exif = { ok: true, image: m.image, eyes: m.eyes.map((e, k) => +d(e.center, meta.eyes[k].center).toFixed(2)), mouth: +d(m.mouth.center, meta.mouth.center).toFixed(2), chin: +d(m.face.chin, meta.face.chin).toFixed(2) };
  }
}
// no face: the background beside him
results.noFace = await attempt(canvas(700, 900, (g) => g.drawImage(still, W - 700, 0, 700, 900, 0, 0, 700, 900)));
// two faces side by side
results.twoFaces = await attempt(canvas(W, H / 2, (g) => { g.drawImage(still, 0, 0, W / 2, H / 2); g.drawImage(still, W / 2, 0, W / 2, H / 2); }));
// the eyes-closed portrait as the still
results.eyesClosed = await attempt(closed);
// a closed photo moved 20 px
results.closedMoved = await attempt(still, canvas(W, H, (g) => g.drawImage(closed, 20, 0)));
// a closed photo of another size
results.closedSize = await attempt(still, canvas(W / 2, H / 2, (g) => g.drawImage(closed, 0, 0, W / 2, H / 2)));
// the still as its own closed photo
results.closedOpen = await attempt(still, still);
// the real pair
const pair = await attempt(still, closed);
results.pair = { ok: pair.ok, closedShift: pair.ok ? +pair.r.report.closedShift.toFixed(2) : pair };

for (const [k, v] of Object.entries(results)) log(k + ': ' + JSON.stringify(v));
window.__r = results;
window.__ready = true;
