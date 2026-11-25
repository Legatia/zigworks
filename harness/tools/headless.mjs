// Drives headless Chrome over the DevTools protocol, for the avatar's dev
// pages: open a page, wait for a condition, print its console, take a
// screenshot, print a value.
//
//   node tools/headless.mjs URL [--wait EXPR] [--eval EXPR] [--shot FILE]
//        [--timeout SECONDS] [--size 1456x900] [--reduced-motion]
//
// --wait polls EXPR in the page until it is truthy (default: window.__ready);
// --eval prints EXPR's value as JSON after that. Exits 1 on a timeout or an
// uncaught error in the page.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const url = args[0];
if (!url || url.startsWith('--')) { console.error('usage: node tools/headless.mjs URL [--wait EXPR] [--eval EXPR] [--shot FILE] [--timeout S]'); process.exit(2); }
const waitExpr = opt('--wait', 'window.__ready');
const evalExpr = opt('--eval', null);
const shot = opt('--shot', null);
const timeout = Number(opt('--timeout', '90')) * 1000;
const [w, h] = opt('--size', '1456x900').split('x').map(Number);

const profile = mkdtempSync(join(tmpdir(), 'avatar-chrome-'));
const chrome = spawn(CHROME, ['--headless=new', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', `--window-size=${w},${h}`,
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--autoplay-policy=no-user-gesture-required', '--no-first-run',
  '--no-default-browser-check', '--hide-scrollbars', 'about:blank'], { stdio: 'ignore' });
const cleanup = () => { try { chrome.kill(); } catch {} try { rmSync(profile, { recursive: true, force: true }); } catch {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let code = 0;
try {
  let port;
  for (let i = 0; i < 100 && !port; i++) {
    const f = join(profile, 'DevToolsActivePort');
    if (existsSync(f)) port = readFileSync(f, 'utf8').split('\n')[0].trim();
    else await sleep(100);
  }
  if (!port) throw new Error('Chrome did not start');
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = no; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) { const { ok, no } = pending.get(msg.id); pending.delete(msg.id); msg.error ? no(new Error(msg.error.message)) : ok(msg.result); return; }
    if (msg.method === 'Runtime.consoleAPICalled') console.log('[page ' + msg.params.type + '] ' + msg.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
    if (msg.method === 'Runtime.exceptionThrown') { code = 1; console.log('[page exception] ' + (msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text)); }
    if (msg.method === 'Log.entryAdded') console.log('[page log ' + msg.params.entry.level + '] ' + msg.params.entry.text + (msg.params.entry.url ? ' ' + msg.params.entry.url : ''));
  };
  const send = (method, params = {}) => new Promise((ok, no) => { const i = ++id; pending.set(i, { ok, no }); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable');
  if (args.includes('--reduced-motion')) await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await send('Page.navigate', { url });
  const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.value;
  const t0 = Date.now();
  let ready = false;
  while (Date.now() - t0 < timeout) {
    try { ready = await evaluate(waitExpr); } catch {}
    if (ready) break;
    await sleep(250);
  }
  if (!ready) { code = 1; console.log('timed out waiting for ' + waitExpr); }
  if (evalExpr) console.log(JSON.stringify(await evaluate(evalExpr), null, 1));
  if (shot) {
    const r = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(shot, Buffer.from(r.data, 'base64'));
    console.log('screenshot ' + shot);
  }
  ws.close();
} catch (e) {
  code = 1;
  console.log('error: ' + (e.stack || e));
} finally {
  cleanup();
}
process.exit(code);
