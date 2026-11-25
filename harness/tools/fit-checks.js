// Dev only: see fit-checks.html.
import { fit, loadImage, readHead } from '/desk/static/fit.js';

const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[checks] ' + m); };
const still = await loadImage('/desk/avatars/butler/still.jpg');
const closed = await loadImage('/desk/avatars/butler/closed.jpg');
const canvas = (w, h, draw) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d'); g.fillStyle = '#000'; g.fillRect(0, 0, w, h); draw(g); return c; };
const W = still.width, H = still.height;
// fit() resolves the pack's files, or rejects with the line to show
const attempt = async (photo, closedPhoto) => {
  try { const r = await fit(photo, closedPhoto); return { ok: true, r: { ...r, files: r }, warnings: r.warnings, faceWidth: r.face.width, closedUsed: r.closed }; }
  catch (e) { return { ok: false, code: e.code, message: e.message, warnings: e.warnings }; }
};
const results = {};

const upright = await attempt(still);
const meta = readHead(upright.r.files.head).meta;
results.upright = { ok: upright.ok, turned: upright.r.report.turned, faceWidth: upright.faceWidth, warnings: upright.warnings };

// the reflections are out of the eye texture: nothing bright left round
// each one, and each found where the photo's bright dot is (the butler's
// are at the top of the iris, by the upper lid)
{
  const eyes = await loadImage(upright.r.files.eyes);
  const g = eyes.getContext('2d'), [cx0, cy0] = meta.eyeCrop;
  results.reflections = meta.eyes.map((e) => {
    if (!e.catchlight) return { bright: null };
    const [ix, iy, ir] = e.catchlight;
    let bright = 0;
    for (let y = Math.floor(iy - 3 * ir); y <= iy + 3 * ir; y++) for (let x = Math.floor(ix - 3 * ir); x <= ix + 3 * ir; x++) {
      if (Math.hypot(x - ix, y - iy) > ir * 2) continue;
      const d = g.getImageData(x - cx0, y - cy0, 1, 1).data;
      if (0.299 * d[0] + 0.587 * d[1] + 0.114 * d[2] > 170) bright++;
    }
    return { bright, above: e.catchlight[1] < e.iris[1] - ir, catchlight: e.catchlight.map((v) => +v.toFixed(1)), iris: e.iris.map((v) => +v.toFixed(1)) };
  });
}

// a phone photo: pixels turned 90°, an EXIF tag saying so
const exif = await fetch('/desk/avatars/checks/still-exif6.jpg');
if (exif.ok) {
  const blob = await exif.blob();
  const a = await attempt(blob);
  if (!a.ok) results.exif = a;
  else {
    const m = readHead(a.r.files.head).meta;
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
// a small face: the still at a fifth of its size (the face about 120 px wide)
results.small = await attempt(canvas(W / 5, H / 5, (g) => g.drawImage(still, 0, 0, W / 5, H / 5)));
// a soft one: at two-thirds (about 400 px wide), and the same cut taller than wide
results.soft = await attempt(canvas(W * 2 / 3, H * 2 / 3, (g) => g.drawImage(still, 0, 0, W * 2 / 3, H * 2 / 3)));
results.tall = await attempt(canvas(1000, 1300, (g) => g.drawImage(still, 870, 0, 1000, 1300, 0, 0, 1000, 1300)));
// a closed photo moved 20 px
results.closedMoved = await attempt(still, canvas(W, H, (g) => g.drawImage(closed, 20, 0)));
// a closed photo of another size
results.closedSize = await attempt(still, canvas(W / 2, H / 2, (g) => g.drawImage(closed, 0, 0, W / 2, H / 2)));
// the still as its own closed photo
results.closedOpen = await attempt(still, still);
// the real pair
const pair = await attempt(still, closed);
results.pair = { ok: pair.ok, closedUsed: pair.ok && pair.closedUsed, closedShift: pair.ok ? +pair.r.report.closedShift.toFixed(2) : pair };

for (const [k, v] of Object.entries(results)) log(k + ': ' + JSON.stringify(v));
window.__r = results;
window.__ready = true;
