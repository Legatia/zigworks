// Dev only: see fit-pack.html.
import { fit, packIni } from '/desk/static/fit.js';
import { parseIni } from '/desk/static/avatar.js';

const q = new URLSearchParams(location.search);
const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[fit] ' + m); };
const show = (blob) => { const i = new Image(); i.src = URL.createObjectURL(blob); document.getElementById('pics').appendChild(i); };
// the dev server's token for this run, from the URL's #token=...
const devToken = new URLSearchParams(location.hash.slice(1)).get('token') || '';
const save = async (path, body) => { const r = await fetch('/save/' + path, { method: 'POST', body, headers: { 'X-Dev-Token': devToken } }); if (!r.ok) throw new Error('save ' + path + ' ' + r.status); log('saved ' + path); };

try {
  const pack = q.get('pack');
  let still = q.get('still'), closed = q.get('closed'), files = null;
  if (pack) {
    const r = await fetch('/desk/avatars/' + pack + '/avatar.ini');
    if (!r.ok) throw new Error('no avatar.ini in ' + pack);
    files = parseIni(await r.text());
    still = '/desk/avatars/' + pack + '/' + files.still;
    closed = files.closed ? '/desk/avatars/' + pack + '/' + files.closed : null;
  }
  log('fitting ' + still + (closed ? ' with ' + closed : ''));
  let out;
  try {
    out = await fit(still, closed);
  } catch (e) {
    log('NOT FITTED: ' + e.code + ': ' + e.message);
    for (const w of e.warnings || []) log('warning: ' + w);
    window.__result = { ok: false, code: e.code, message: e.message, warnings: e.warnings || [] };
    window.__ready = true;
    throw e;
  }
  for (const w of out.warnings) log('warning: ' + w);
  log('face ' + out.face.width + ' px wide; eyes-closed version ' + (out.closed ? 'used' : 'not used'));
  log(JSON.stringify(out.report, null, 1));
  show(out.eyes); show(out.eyemask);
  if (pack) {
    await save('avatars/' + pack + '/head.bin', out.head);
    await save('avatars/' + pack + '/eyes.png', out.eyes);
    await save('avatars/' + pack + '/eyemask.png', out.eyemask);
    const ini = { ...files, head: 'head.bin', eyes: 'eyes.png', eyemask: 'eyemask.png' };
    if (!out.closed) delete ini.closed;
    await save('avatars/' + pack + '/avatar.ini', packIni(ini));
  }
  window.__result = { ok: true, warnings: out.warnings, faceWidth: out.face.width, closedUsed: out.closed, report: out.report };
} catch (e) {
  log('ERROR: ' + e.message);
  window.__result = { ok: false, error: e.message };
}
window.__ready = true;
