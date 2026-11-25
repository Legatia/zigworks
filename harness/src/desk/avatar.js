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

const HEAD_MAGIC = [0x89, 0x48, 0x45, 0x41, 0x44, 0x0d, 0x0a, 0x1a];
const TYPES = { f32: Float32Array, i16: Int16Array, u16: Uint16Array, u32: Uint32Array, u8: Uint8Array };

/** A head file (format version 1): { version, meta, arr(name) }. Throws a
 *  plain Error when it isn't one this module reads. */
export function readHead(buf) {
  const bytes = new Uint8Array(buf);
  if (bytes.length < 16 || HEAD_MAGIC.some((b, i) => bytes[i] !== b)) {
    if (bytes.length >= 8 && HEAD_MAGIC.every((b, i) => bytes[i] === b)) throw new Error("the head file's header runs past the end of the file");
    throw new Error('this is not a head file');
  }
  const dv = new DataView(buf);
  const version = dv.getUint32(8, true), hlen = dv.getUint32(12, true);
  if (version > 1) throw new Error(`the head file is format version ${version}, made by a newer harness`);
  if (version < 1 || hlen % 4 || 16 + hlen > bytes.length) throw new Error("the head file's header runs past the end of the file");
  const meta = JSON.parse(new TextDecoder().decode(bytes.subarray(16, 16 + hlen)));
  const base = 16 + hlen;
  const arr = (name) => {
    const d = meta.arrays && meta.arrays[name];
    if (!d) throw new Error('the head file has no ' + name);
    const T = TYPES[d[0]];
    if (!T || d[1] % 4 || base + d[1] + d[2] * T.BYTES_PER_ELEMENT > bytes.length) throw new Error('the head file\'s ' + name + ' runs past the end of the file');
    return new T(buf, base + d[1], d[2]);
  };
  for (const name of Object.keys(meta.arrays || {})) arr(name);
  return { version, meta, arr };
}
