// The desk's avatar: the portrait projected onto a rigged head with the
// 52 ARKit expression shapes, drawn live with WebGL 2 (three.js r170).
//
//   const avatar = await createAvatar(element, '/desk/avatars/butler/', options);
//   avatar.setState('working'); avatar.moment('smile'); avatar.arrive();
//   await avatar.speak({ text, audioUrl }); avatar.stop(); avatar.dispose();
//
// A pack is a folder with avatar.ini naming its files (README: Avatar packs).

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

export { readHead } from './fit.js';
