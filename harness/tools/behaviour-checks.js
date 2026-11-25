// Dev only: see behaviour-checks.html. Each check logs `ok NAME` or `FAIL NAME: why`.
import { createAvatar } from '/desk/static/avatar.js';

const q = new URLSearchParams(location.search);
const pack = q.get('pack') || '/desk/avatars/butler/';
const voice = '/desk/avatars/audio/voice.wav';
const logEl = document.getElementById('log');
const results = {};
const log = (m) => { logEl.textContent += m + '\n'; console.log('[behaviour] ' + m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const check = (name, ok, detail) => { results[name] = { ok: !!ok, detail }; log((ok ? 'ok ' : 'FAIL ') + name + ' ' + JSON.stringify(detail)); };
/** Samples f() every frame for ms. */
const sample = (ms, f) => new Promise((ok) => { const out = [], t0 = performance.now(); const step = () => { out.push(f()); if (performance.now() - t0 < ms) requestAnimationFrame(step); else ok(out); }; step(); });

const a = await createAvatar(document.getElementById('a'), pack, {});
a.setState('needs you');
await sleep(500);

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
  const n = await settle('needs you');
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
  a.setState('needs you'); await sleep(1500);
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
const failed = Object.entries(results).filter(([, v]) => !v.ok).map(([k]) => k);
log(failed.length ? failed.length + ' failed: ' + failed.join(', ') : 'all ' + Object.keys(results).length + ' passed');
window.__r = { results, failed };
window.__ready = true;
