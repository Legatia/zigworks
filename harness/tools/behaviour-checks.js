// Dev only: see behaviour-checks.html. Each check logs `ok NAME` or `FAIL NAME: why`.
import { createAvatar, drawClosedEyes, closedLidSpan, readHead } from '/desk/static/avatar.js';
import { loadImage } from '/desk/static/fit.js';

const q = new URLSearchParams(location.search);
const pack = q.get('pack') || '/desk/avatars/butler/';
// the faces the mouth's checks run on (names under /desk/avatars/), else the pack
const faces = q.get('faces') ? q.get('faces').split(',').map((n) => '/desk/avatars/' + n + '/') : [pack];
const voice = '/desk/avatars/audio/voice.wav';
const logEl = document.getElementById('log');
const results = {};
const log = (m) => { logEl.textContent += m + '\n'; console.log('[behaviour] ' + m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const check = (name, ok, detail) => { results[name] = { ok: !!ok, detail }; log((ok ? 'ok ' : 'FAIL ') + name + ' ' + JSON.stringify(detail)); };
/** Samples f() every frame for ms. */
const sample = (ms, f) => new Promise((ok) => { const out = [], t0 = performance.now(); const step = () => { out.push(f()); if (performance.now() - t0 < ms) requestAnimationFrame(step); else ok(out); }; step(); });

// 0. drawn closed lids: the lash line runs smoothly, no step between neighbouring columns
{
  const still = await loadImage(pack + 'still.jpg');
  const meta = readHead(await (await fetch(pack + 'head.bin', { cache: 'no-cache' })).arrayBuffer()).meta;
  const c = drawClosedEyes(still, meta), g = c.getContext('2d');
  const lines = meta.eyes.map((e) => {
    const xs = e.outline.map((p) => p[0]), ys = e.outline.map((p) => p[1]);
    const x0 = Math.ceil(Math.min(...xs) + 0.2 * (Math.max(...xs) - Math.min(...xs))), x1 = Math.floor(Math.max(...xs) - 0.2 * (Math.max(...xs) - Math.min(...xs)));
    const y0 = Math.floor(Math.min(...ys) - 6), y1 = Math.ceil(Math.max(...ys) + 6);
    const d = g.getImageData(x0, y0, x1 - x0, y1 - y0).data, w = x1 - x0;
    const rows = [];
    // within the eye's opening (where the lids meet when drawn shut)
    const inside = (px, py) => { let c = false; const o = e.outline; for (let i = 0, j = o.length - 1; i < o.length; j = i++) { const [ax, ay] = o[i], [bx, by] = o[j]; if ((ay > py) !== (by > py) && px < ((bx - ax) * (py - ay)) / (by - ay) + ax) c = !c; } return c; };
    for (let x = 0; x < w; x++) {
      let best = Infinity, by = null;
      for (let y = 0; y < y1 - y0; y++) {
        if (!inside(x0 + x + 0.5, y0 + y + 0.5)) continue;
        const o = (y * w + x) * 4, l = 0.299 * d[o] + 0.587 * d[o + 1] + 0.114 * d[o + 2];
        if (l < best) { best = l; by = y; }
      }
      if (by !== null) rows.push(by);
    }
    const jumps = rows.slice(1).map((r, i) => Math.abs(r - rows[i]));
    return { maxJump: Math.max(...jumps), columns: rows.length };
  });
  check('drawn_lash_lines_have_no_step', lines.every((l) => l.maxJump <= 1), { lines });
  // and on the drawn face, shut and resting: the drawn lash line runs on without a step.
  // It is found by its own path (closedLidSpan, which drew it: 0.9 of the way down the
  // lid): its offset at the eye's middle (the darkest row within 8 px of the path),
  // then column by column within 5 px of the path so offset; a step is a jump of 3 px
  // or more between neighbours, across the middle 80% of the eye. Rendered at about
  // the photo's scale, for gaze straight, up and down, with and without reduced motion
  // (the head held at its rest pose), and once with the lid broken on purpose
  // (debug.lidBreak: its outer half 4 px down), which must be caught.
  const lashSteps = async (gy, rm, lidBreak = 0) => {
    const el = document.createElement('div');
    el.style.width = '2400px'; el.style.height = '1371px';
    document.body.appendChild(el);
    // the head held at its rest pose, so the drawn lid is where the photo has it (the
    // resting state's pitch moves the shut eye some px; that's the pose, not the lid)
    const r = await createAvatar(el, '/desk/avatars/drawn/', { reducedMotion: rm, debug: { time: 0, breath: 0, gaze: { x: 0, y: gy }, pose: { yaw: 0, pitch: 0, roll: 0 }, lidBreak } });
    r.setState('resting');
    const shot = r.snapshot(), v = shot.view, sg = shot.getContext('2d');
    r.dispose(); el.remove();
    const sx = shot.width / v.w, sy = shot.height / v.h;
    return meta.eyes.map((e) => {
      const xs = e.outline.map((p) => p[0]), ax = Math.min(...xs), bx = Math.max(...xs);
      const X0 = Math.ceil((ax + 0.1 * (bx - ax) - v.x0) * sx), X1 = Math.floor((bx - 0.1 * (bx - ax) - v.x0) * sx);
      const ys = e.outline.map((p) => p[1]);
      const Y0 = Math.floor((Math.min(...ys) - 12 - v.y0) * sy), Y1 = Math.ceil((Math.max(...ys) + 12 - v.y0) * sy);
      const w = X1 - X0, H = Y1 - Y0, d = sg.getImageData(X0, Y0, w, H).data;
      const L = (x, y) => { if (y < 0 || y >= H) return 255; const o = (y * w + x) * 4; return 0.299 * d[o] + 0.587 * d[o + 1] + 0.114 * d[o + 2]; };
      // the path, in this crop's rows
      const path = (x) => { const span = closedLidSpan(e, v.x0 + (X0 + x + 0.5) / sx); return span ? (span.top + 0.9 * (span.bot - span.top) - v.y0) * sy - Y0 : null; };
      const darkest = (x, c, reach) => { let best = Infinity, row = Math.round(c); for (let y = Math.round(c - reach); y <= Math.round(c + reach); y++) if (L(x, y) < best) { best = L(x, y); row = y; } return row; };
      const mid = w >> 1, offset = darkest(mid, path(mid), 8 * sy) - path(mid);
      const line = [];
      for (let x = 0; x < w; x++) { const p = path(x); line.push(p === null ? null : darkest(x, p + offset, 5 * sy)); }
      let steps = 0, worst = 0;
      const at = [];
      for (let x = 1; x < w; x++) {
        if (line[x] === null || line[x - 1] === null) continue;
        const j = Math.abs(line[x] - line[x - 1]);
        worst = Math.max(worst, j);
        if (j >= 3) { steps++; at.push(x); }
      }
      return { steps, worst, columns: w, offset: +offset.toFixed(1), at: at.join(',') };
    });
  };
  const seen = {};
  for (const [name, gy, rm] of [['straight', 0, false], ['up', 3, false], ['down', -3, false], ['straightStill', 0, true], ['upStill', 3, true], ['downStill', -3, true]]) seen[name] = await lashSteps(gy, rm);
  const broken = await lashSteps(0, false, 4);
  check('drawn_lids_shut_without_a_step_in_the_lash_line', Object.values(seen).every((d) => d.every((l) => l.steps === 0)) && broken.every((l) => l.steps >= 1), { ...seen, brokenOnPurpose: broken });
}
const a = await createAvatar(document.getElementById('a'), pack, {});
a.setState('needs');
await sleep(500);

// 0b. the mouth's parts and the lips, on each face (the head at its rest pose, at about
// the photo's scale), each frame against the same frame without the mouth's parts:
//  - shut ("needs"): no pale line of teeth along the lips' seam (heads with their own
//    mouth parts; an older head's reseated row isn't judged);
//  - open (jawOpen 0.3 and 0.6): the parts are drawn lit (the upper teeth show)
{
  const frame = async (face, setup, noMouthParts) => {
    const el = document.createElement('div');
    el.style.width = '2400px'; el.style.height = '1371px';
    document.body.appendChild(el);
    const r = await createAvatar(el, face, { reducedMotion: false, debug: { time: 0, breath: 0, gaze: { x: 0, y: 0 }, pose: { yaw: 0, pitch: 0, roll: 0 }, noMouthParts, ...setup.debug } });
    if (setup.state) r.setState(setup.state);
    const shot = r.snapshot();
    r.dispose(); el.remove();
    return shot;
  };
  // pixels in the mouth's box (the inner lips, ±pad px) the parts make brighter by more than 25
  const brighter = async (face, meta, setup, pad) => {
    const withParts = await frame(face, setup, false), without = await frame(face, setup, true), v = withParts.view;
    const sx = withParts.width / v.w, sy = withParts.height / v.h;
    const A = withParts.getContext('2d'), B = without.getContext('2d');
    const inner = meta.mouth.inner, xs = inner.map((p) => p[0]), ys = inner.map((p) => p[1]);
    const X0 = Math.floor((Math.min(...xs) - v.x0) * sx), X1 = Math.ceil((Math.max(...xs) - v.x0) * sx);
    const Y0 = Math.floor((Math.min(...ys) - pad[0] - v.y0) * sy), Y1 = Math.ceil((Math.max(...ys) + pad[1] - v.y0) * sy);
    const da = A.getImageData(X0, Y0, X1 - X0 + 1, Y1 - Y0 + 1).data, db = B.getImageData(X0, Y0, X1 - X0 + 1, Y1 - Y0 + 1).data;
    let n = 0, worst = 0;
    for (let o = 0; o < da.length; o += 4) {
      const d = 0.299 * (da[o] - db[o]) + 0.587 * (da[o + 1] - db[o + 1]) + 0.114 * (da[o + 2] - db[o + 2]);
      worst = Math.max(worst, d);
      if (d > 25) n++;
    }
    return { pixels: da.length / 4, brighter: n, worst: Math.round(worst) };
  };
  const shut = {}, open = {};
  for (const face of faces) {
    const meta = readHead(await (await fetch(face + 'head.bin', { cache: 'no-cache' })).arrayBuffer()).meta;
    const mw = meta.mouth.right[0] - meta.mouth.left[0], name = face.split('/').slice(-2)[0];
    // (a head fitted on an older base draws its own reseated row: not judged shut)
    shut[name] = meta.arrays['teeth.jaw'] ? await brighter(face, meta, { state: 'needs' }, [3, 3]) : 'an older head: not judged';
    open[name] = {};
    for (const jaw of [0.3, 0.6]) open[name][jaw] = await brighter(face, meta, { debug: { neutral: true, shapes: { jawOpen: jaw } } }, [0.1 * mw, 0.6 * mw]);
  }
  check('closed_lips_show_no_teeth', Object.values(shut).every((r) => typeof r === 'string' || r.brighter <= 2), shut);
  check('the_open_mouth_shows_its_teeth', Object.values(open).every((r) => r[0.3].brighter >= 50 && r[0.6].brighter >= 50), open);
}
// 0d. no near-black round the nose's base at rest (the resting state, its own pose: the
// head pitched as people see it most), on each face: between the nose tip and the upper
// lip, across the mouth's width, pixels darker than 30 and darker than the photo's own
// darkest there less 10 (the nostrils are dark in a photo too)
{
  const dark = {};
  for (const face of faces) {
    const meta = readHead(await (await fetch(face + 'head.bin', { cache: 'no-cache' })).arrayBuffer()).meta;
    const still = await loadImage(face + 'still.jpg');
    const el = document.createElement('div');
    el.style.width = '2400px'; el.style.height = '1371px';
    document.body.appendChild(el);
    const r = await createAvatar(el, face, { reducedMotion: false, debug: { time: 0, breath: 0 } });
    r.setState('resting');
    const shot = r.snapshot(), v = shot.view, sx = shot.width / v.w, sy = shot.height / v.h;
    r.dispose(); el.remove();
    const lipTop = Math.min(...meta.mouth.outer.map((p) => p[1]));
    const x0 = meta.mouth.left[0], x1 = meta.mouth.right[0], y0 = meta.face.noseTip[1], y1 = lipTop;
    const sg = document.createElement('canvas'); sg.width = still.width; sg.height = still.height;
    const sc = sg.getContext('2d'); sc.drawImage(still, 0, 0);
    const sd = sc.getImageData(Math.round(x0), Math.round(y0), Math.round(x1 - x0), Math.round(y1 - y0)).data;
    let photoMin = 255;
    for (let o = 0; o < sd.length; o += 4) photoMin = Math.min(photoMin, 0.299 * sd[o] + 0.587 * sd[o + 1] + 0.114 * sd[o + 2]);
    const X0 = Math.round((x0 - v.x0) * sx), Y0 = Math.round((y0 - v.y0) * sy), w = Math.round((x1 - x0) * sx), h = Math.round((y1 - y0) * sy);
    const d = shot.getContext('2d').getImageData(X0, Y0, w, h).data, th = Math.min(30, photoMin - 10);
    let n = 0, lo = 255;
    for (let o = 0; o < d.length; o += 4) { const l = 0.299 * d[o] + 0.587 * d[o + 1] + 0.114 * d[o + 2]; lo = Math.min(lo, l); if (l < th) n++; }
    dark[face.split('/').slice(-2)[0]] = { pixels: w * h, nearBlack: n, darkest: Math.round(lo), photoDarkest: Math.round(photoMin) };
  }
  check('no_near_black_round_the_nose_at_rest', Object.values(dark).every((r) => r.nearBlack <= 2), dark);
}
// 0c. the chin's lower edge stays smooth as the jaw opens (0, 0.3, 0.6; the head at its
// rest pose), seen in the head's opacity alone (the debug alphaView: grey on black, no
// photo): per column under the mouth and its corners (its width, a third over each
// side), the lowest row of the chin where it starts to show; its turning points (a
// sawtooth has many, a smooth chin one or two)
{
  const meta = readHead(await (await fetch(pack + 'head.bin', { cache: 'no-cache' })).arrayBuffer()).meta;
  const seen = {};
  for (const jaw of [0, 0.3, 0.6]) {
    const el = document.createElement('div');
    el.style.width = '2400px'; el.style.height = '1371px';
    document.body.appendChild(el);
    const r = await createAvatar(el, pack, { reducedMotion: false, debug: { time: 0, breath: 0, neutral: true, alphaView: true, shapes: { jawOpen: jaw }, pose: { yaw: 0, pitch: 0, roll: 0 } } });
    const shot = r.snapshot(), v = shot.view, sx = shot.width / v.w, sy = shot.height / v.h, g = shot.getContext('2d');
    r.dispose(); el.remove();
    const mw = meta.mouth.right[0] - meta.mouth.left[0], chin = meta.face.chin;
    const X0 = Math.round((meta.mouth.left[0] - 0.35 * mw - v.x0) * sx), X1 = Math.round((meta.mouth.right[0] + 0.35 * mw - v.x0) * sx);
    const Y0 = Math.round((meta.mouth.center[1] - v.y0) * sy), Y1 = Math.round((chin[1] + 0.9 * mw - v.y0) * sy);
    const d = g.getImageData(X0, Y0, X1 - X0, Y1 - Y0).data, w = X1 - X0, h = Y1 - Y0;
    const A = (x, y) => d[(y * w + x) * 4] / 255; const LEVEL = 0.15; // where the head starts to show: the faint wisps live there 
    // from the mouth's level down: the first row where the head is no longer opaque
    const edge = [];
    for (let x = 0; x < w; x++) { let e = -1; for (let y = 0; y < h; y++) if (A(x, y) > LEVEL) e = y; else if (e >= 0 && y - e > 2) break; edge.push(e); }
    // its turning points with 2 px or more between them: a smooth jaw turns once or
    // twice (the chin's bottom), a sawtooth at every tooth
    let turns = 0, dir = 0, ext = null;
    for (const e of edge) {
      if (e < 0) continue;
      if (ext === null) { ext = e; continue; }
      if (dir === 0) { if (e >= ext + 2) { dir = 1; ext = e; } else if (e <= ext - 2) { dir = -1; ext = e; } }
      else if (dir === 1) { if (e > ext) ext = e; else if (e <= ext - 2) { turns++; dir = -1; ext = e; } }
      else if (e < ext) ext = e; else if (e >= ext + 2) { turns++; dir = 1; ext = e; }
    }
    seen[jaw] = { columns: w, turns };
  }
  // at rest the head shows the photo's own pixels over the backplate's, so its edge
  // can't be seen; open, it can
  check('the_chins_lower_edge_stays_smooth_as_the_jaw_opens', [0.3, 0.6].every((j) => seen[j].turns <= 6), seen);
}
// 1. a provider's voice: the mouth moves only while it plays, the jaw with its loudness
{
  const t0 = performance.now();
  const p = a.speak({ text: 'Your flight to Lisbon moved to nine forty.', audioUrl: voice });
  const frames = await sample(2600, () => { const i = a.inspect(); return { tau: i.tau, jaw: a.shapes().jawOpen, talking: i.talking }; });
  const done = await p;
  const ms = performance.now() - t0;
  const before = Math.max(0, ...frames.filter((f) => f.tau !== null && f.tau < 0.4).map((f) => f.jaw));
  const during = Math.max(0, ...frames.filter((f) => f.tau !== null && f.tau > 0.6 && f.tau < 1.6).map((f) => f.jaw));
  const after = await sample(400, () => a.shapes().jawOpen);
  check('provider_voice_moves_the_mouth_only_while_it_plays', done === true && before < 0.03 && during > 0.1 && after[after.length - 1] < 0.02,
    { done, ms: Math.round(ms), jawBefore: +before.toFixed(3), jawDuring: +during.toFixed(3), jawAfter: +after[after.length - 1].toFixed(3) });
}
// 2. a second speak ends the first: the first resolves false
{
  const first = a.speak({ text: 'One.', audioUrl: voice });
  await sleep(700);
  const second = a.speak({ text: 'Two.', audioUrl: voice });
  const r1 = await first, r2 = await second;
  check('a_second_speak_ends_the_first', r1 === false && r2 === true, { first: r1, second: r2 });
}
// 3. stop while the voice is still loading: nothing plays
{
  const p = a.speak({ text: 'Never heard.', audioUrl: voice });
  a.stop();
  const r = await p;
  const jaws = await sample(800, () => a.shapes().jawOpen);
  check('stop_while_loading_plays_nothing', r === false && Math.max(...jaws) < 0.03 && !a.inspect().talking, { resolved: r, maxJaw: +Math.max(...jaws).toFixed(3) });
}
// 4. a voice that isn't there: rejected, no mouth movement
{
  let err = null;
  try { await a.speak({ text: 'Nothing.', audioUrl: '/desk/avatars/audio/none.wav' }); } catch (e) { err = e.message; }
  check('a_missing_voice_is_refused_plainly', err && /didn't play/.test(err) && a.shapes().jawOpen < 0.03, { err });
}
// 5. the browser's voice (headless Chrome may have none): it ends or is refused, and the mouth only moves once it started
{
  let r, err = null;
  const t0 = performance.now();
  const p = a.speak({ text: 'Hello.', browser: true }).then((x) => (r = x), (e) => (err = e.message));
  const jaws = await sample(6000, () => ({ jaw: a.shapes().jawOpen, talking: a.inspect().talking }));
  await p;
  const moved = jaws.some((j) => j.jaw > 0.05 && !j.talking);
  check('the_browser_voice_moves_the_mouth_only_once_it_speaks', !moved && (r === true || err), { resolved: r ?? null, err, ms: Math.round(performance.now() - t0), voices: speechSynthesis.getVoices().length });
}
// 6. resting draws at most 30 a second (frames at least 29 ms apart), working on every frame
{
  const draws = async (ms) => {
    const ticks = await sample(ms, () => ({ t: performance.now(), drawn: a.inspect().drawn }));
    const at = [];
    for (let i = 1; i < ticks.length; i++) if (ticks[i].drawn > ticks[i - 1].drawn) at.push(ticks[i].t);
    const gaps = at.slice(1).map((x, i) => x - at[i]);
    return { ticks: ticks.length - 1, draws: at.length, minGap: gaps.length ? Math.round(Math.min(...gaps)) : null };
  };
  a.setState('resting'); await sleep(600);
  const resting = await draws(2000);
  a.setState('working'); await sleep(300);
  const working = await draws(2000);
  check('resting_draws_30_a_second', resting.minGap >= 29 && working.draws >= working.ticks * 0.9, { resting, working });
}
// 7. nothing is drawn while the page is hidden; drawing comes back
{
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
  document.dispatchEvent(new Event('visibilitychange'));
  await sleep(100);
  const d0 = a.inspect().drawn; await sleep(1000); const hiddenFrames = a.inspect().drawn - d0;
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
  document.dispatchEvent(new Event('visibilitychange'));
  const d1 = a.inspect().drawn; await sleep(600); const back = a.inspect().drawn - d1;
  check('nothing_is_drawn_while_hidden', hiddenFrames === 0 && back > 3, { hiddenFrames, back });
}
// 8. the states' faces
{
  const settle = async (st) => { a.setState(st); await sleep(1800); return a.shapes(); };
  const r = await settle('resting');
  const qd = await settle('quiet'); const filter = a.inspect().filter;
  const w = await settle('working');
  const n = await settle('needs');
  const u = await settle('urgent');
  check('the_states_show', r.eyeBlink_L > 0.9 && qd.eyeBlink_L > 0.9 && /brightness\(0\.6\)/.test(filter) && w.browDown_L > 0.25 && n.browInnerUp > 0.15 && n.eyeBlink_L < 0.9 && u.browOuterUp_L > 0.3 && u.eyeWide_L > 0.2,
    { resting: +r.eyeBlink_L.toFixed(2), quiet: [+qd.eyeBlink_L.toFixed(2), filter], working: +w.browDown_L.toFixed(2), needsYou: +n.browInnerUp.toFixed(2), urgent: [+u.browOuterUp_L.toFixed(2), +u.eyeWide_L.toFixed(2)] });
  // arrive in resting: the eyes open for the glance, then close again
  a.setState('resting'); await sleep(2500);
  a.arrive();
  const open = await sample(1200, () => a.shapes().eyeBlink_L);
  await sleep(2500);
  check('arrive_opens_the_eyes_for_a_glance', Math.min(...open) < 0.3 && a.shapes().eyeBlink_L > 0.7, { minDuringGlance: +Math.min(...open).toFixed(2), after: +a.shapes().eyeBlink_L.toFixed(2) });
  // moments
  a.setState('needs'); await sleep(1500);
  a.moment('smile'); await sleep(900); const sm = a.shapes().mouthSmile_L; await sleep(2200); const smAfter = a.shapes().mouthSmile_L;
  a.moment('concern'); await sleep(900); const co = a.shapes().mouthFrown_L;
  check('moments_come_and_go', sm > 0.4 && smAfter < 0.15 && co > 0.2, { smile: +sm.toFixed(2), smileAfter2s: +smAfter.toFixed(2), concern: +co.toFixed(2) });
}
// 9. reduced motion: no drift, no nods, no mouth outside speech; blinks and breathing stay
{
  a.dispose(); // one avatar drawing at a time from here
  const b = await createAvatar(document.getElementById('b'), pack, { reducedMotion: true });
  b.setState('working'); await sleep(3000);
  const poses = await sample(4000, () => b.inspect().pose);
  const span = (k) => Math.max(...poses.map((p) => p[k])) - Math.min(...poses.map((p) => p[k]));
  b.moment('smile'); await sleep(900);
  const s = b.shapes();
  const p = b.speak({ text: 'Your flight moved.', audioUrl: voice });
  const jaw = await sample(1800, () => b.shapes().jawOpen);
  await p;
  const blinks = await sample(7000, () => b.shapes().eyeBlink_L);
  check('reduced_motion_keeps_blinks_and_breath_drops_drift_nods_and_mouth', span('pitch') < 0.05 && span('yaw') < 0.05 && s.mouthSmile_L < 0.01 && s.cheekSquint_L > 0.2 && Math.max(...jaw) > 0.1 && Math.max(...blinks) > 0.5,
    { pitchSpan: +span('pitch').toFixed(3), yawSpan: +span('yaw').toFixed(3), smileMouth: +s.mouthSmile_L.toFixed(3), smileCheek: +s.cheekSquint_L.toFixed(2), jawSpeaking: +Math.max(...jaw).toFixed(2), blinked: +Math.max(...blinks).toFixed(2) });
  // 10. dispose mid-speech: the promise settles, the audio closes, the canvas goes
  const p2 = b.speak({ text: 'Cut short.', audioUrl: voice });
  await sleep(900);
  b.dispose();
  const r2 = await p2;
  await sleep(200);
  check('dispose_mid_speech_ends_it', r2 === false && b.inspect().audio === 'closed' && !document.querySelector('#b canvas'), { resolved: r2, audio: b.inspect().audio });
}
// 11. after dispose: speaking does nothing and settles at once
{
  const c = await createAvatar(document.getElementById('b'), pack, {});
  const glCanvas = document.querySelector('#b canvas');
  const gl = glCanvas.getContext('webgl2');
  c.dispose();
  const t0 = performance.now();
  const r1 = await Promise.race([c.speak({ text: 'Gone.', browser: true }), sleep(3000).then(() => 'pending')]);
  const spoke = speechSynthesis.speaking || speechSynthesis.pending;
  const r2 = await Promise.race([c.speak({ text: 'Gone.', audioUrl: voice }), sleep(3000).then(() => 'pending')]);
  let threw = null;
  try { c.setState('working'); c.moment('smile'); c.arrive(); c.stop(); } catch (e) { threw = e.message; }
  check('after_dispose_speak_settles_and_says_nothing', r1 === false && r2 === false && !spoke && !threw && performance.now() - t0 < 1000, { browser: r1, audio: r2, spoke, threw });
  // its WebGL context is let go, not left for the garbage collector
  check('dispose_lets_the_webgl_context_go', gl && gl.isContextLost(), { lost: gl && gl.isContextLost() });
}
// 12. a browser voice that fails doesn't cut off the next one 5 s later
{
  const c = await createAvatar(document.getElementById('b'), pack, {});
  const orig = speechSynthesis.speak.bind(speechSynthesis);
  let first = true;
  speechSynthesis.speak = (u) => { if (first) { first = false; setTimeout(() => u.onerror({ error: 'synthesis-failed' }), 20); return; } orig(u); };
  let err = null;
  try { await c.speak({ text: 'This fails.', browser: true }); } catch (e) { err = e.message; }
  const t0 = performance.now();
  const long = 'The morning brief is ready. Your flight to Lisbon moved to nine forty, the driver knows, the calendar is updated, and the hotel has your late arrival on file. Two packages arrive today, one needs a signature, and the boiler service is on Thursday at ten.';
  const r = await c.speak({ text: long, browser: true });
  const ms = Math.round(performance.now() - t0);
  speechSynthesis.speak = orig;
  check('a_failed_browser_voice_does_not_cut_off_the_next', err && r === true && ms > 5500, { err, resolved: r, ms });
  // 13. a voice that starts and never says it ended: the talk still ends
  speechSynthesis.speak = (u) => { setTimeout(() => u.onstart && u.onstart(), 20); };
  const t1 = performance.now();
  const r3 = await Promise.race([c.speak({ text: 'Hello there.', browser: true }), sleep(15000).then(() => 'pending')]);
  speechSynthesis.speak = orig;
  check('a_voice_that_never_ends_still_ends_the_talk', r3 !== 'pending' && !c.inspect().talking, { resolved: r3, ms: Math.round(performance.now() - t1) });
  // 14. audio that can't start (an autoplay policy holding the audio back): refused, not hanging
  const Real = globalThis.AudioContext;
  globalThis.AudioContext = class extends Real { get state() { return 'suspended'; } resume() { return new Promise(() => {}); } };
  c.dispose();
  const d = await createAvatar(document.getElementById('b'), pack, {});
  let err2 = null;
  const r4 = await Promise.race([d.speak({ text: 'Held.', audioUrl: voice }).catch((e) => { err2 = e.message; return 'rejected'; }), sleep(8000).then(() => 'pending')]);
  globalThis.AudioContext = Real;
  check('audio_that_cannot_start_is_refused', r4 === 'rejected' && /didn't start/.test(err2 || ''), { result: r4, err: err2 });
  d.dispose();
}
const failed = Object.entries(results).filter(([, v]) => !v.ok).map(([k]) => k);
log(failed.length ? failed.length + ' failed: ' + failed.join(', ') : 'all ' + Object.keys(results).length + ' passed');
window.__r = { results, failed };
window.__ready = true;
