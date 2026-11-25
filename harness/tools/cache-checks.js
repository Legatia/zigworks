// Dev only: see cache-checks.html. A pack changed on disk (a refit, a new
// still) is seen by the next createAvatar in the same page, whatever the
// browser's cache holds.
import { createAvatar } from '/desk/static/avatar.js';

const devToken = new URLSearchParams(location.hash.slice(1)).get('token') || '';
const logEl = document.getElementById('log');
const log = (m) => { logEl.textContent += m + '\n'; console.log('[cache] ' + m); };
const save = async (path, body) => { const r = await fetch('/save/' + path, { method: 'POST', body, headers: { 'X-Dev-Token': devToken } }); if (!r.ok) throw new Error('save ' + path + ' ' + r.status); };
const bytes = async (url) => (await fetch(url, { cache: 'no-store' })).arrayBuffer();
const results = {};
const check = (name, ok, detail) => { results[name] = { ok: !!ok, detail }; log((ok ? 'ok ' : 'FAIL ') + name + ' ' + JSON.stringify(detail)); };
const el = document.getElementById('a');
const big = await bytes('/desk/avatars/butler/still.jpg'), small = await bytes('/desk/avatars/mismatch/still.jpg');

await save('avatars/cachetest/big.jpg', big);
await save('avatars/cachetest/small.jpg', small);
await save('avatars/cachetest/x.jpg', big);
await save('avatars/cachetest/avatar.ini', 'still = big.jpg\n');
let a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const first = a.inspect().still;
a.dispose();
// avatar.ini changed on disk
await save('avatars/cachetest/avatar.ini', 'still = small.jpg\n');
a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const second = a.inspect().still;
a.dispose();
check('a_changed_avatar_ini_is_seen_at_once', first[0] === 2720 && second[0] === 1360, { first, second });
// the still replaced under the same name
await save('avatars/cachetest/avatar.ini', 'still = x.jpg\n');
a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const third = a.inspect().still;
a.dispose();
await save('avatars/cachetest/x.jpg', small);
a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const fourth = a.inspect().still;
a.dispose();
check('a_replaced_still_is_seen_at_once', third[0] === 2720 && fourth[0] === 1360, { third, fourth });
// a head fitted to the butler's still, over another photo of the same size
await save('avatars/cachetest/still.jpg', await bytes('/desk/avatars/butler/closed.jpg'));
for (const f of ['head.bin', 'eyes.png', 'eyemask.png']) await save('avatars/cachetest/' + f, await bytes('/desk/avatars/butler/' + f));
await save('avatars/cachetest/avatar.ini', 'still = still.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n');
a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const other = { mode: a.mode, problem: a.problem };
a.dispose();
await save('avatars/cachetest/still.jpg', big);
a = await createAvatar(el, '/desk/avatars/cachetest/', {});
const own = { mode: a.mode, problem: a.problem };
a.dispose();
check('a_head_over_another_still_of_the_same_size_shows_the_still', other.mode === 'still' && /another photo/.test(other.problem || '') && own.mode === 'head', { other, own });
const failed = Object.entries(results).filter(([, v]) => !v.ok).map(([k]) => k);
log(failed.length ? failed.length + ' failed' : 'all ' + Object.keys(results).length + ' passed');
window.__r = { results, failed };
window.__ready = true;
