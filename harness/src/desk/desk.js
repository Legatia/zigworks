// The desk: harness's own window. It draws harness's facts (GET state),
// a conversation's messages (GET history), and long-polls the events
// (GET events); it answers items, sends the owner's turns and settings
// through the desk API. The avatar's state comes from harness's facts
// (never from model text); the page adds `speaking` while its voice plays.
// The bridge tells the desk app the count of items, an urgent arrival and
// a lost session.

import { createAvatar, createVoice } from "/desk/static/avatar.js";

const $ = (id) => document.getElementById(id);
const API = "/desk/api/";
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const S = {
  seq: 0,
  data: null,
  conv: "main",
  convs: [],
  msgs: [],
  items: [],
  alerts: 0,
  runs: [],
  quiet: { now: false, hours: "" },
  settings: { avatar: "", avatars: [], speak: "off", speak_choices: ["off"], voice: false },
  offset: 0,
  speaking: false,
  speakQueue: [],
  lastSpoken: null,
  muted: false,
  speakTurn: 0,
  seenItems: null,
  lastBadge: -1,
  lastAlerts: 0,
  avatar: null,
  avatarName: null,
  // each load's number: a load that isn't the latest is let go
  avatarGen: 0,
  avatarError: "",
  reentered: false,
};

try {
  S.muted = localStorage.getItem("desk.muted") === "1";
} catch (_) {}

// ---- the bridge to the desk app ----

function bridge(msg) {
  try {
    const wk = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.harness;
    if (wk) return wk.postMessage(msg);
    if (window.chrome && window.chrome.webview) return window.chrome.webview.postMessage(msg);
  } catch (_) {}
}

function reenter() {
  if (S.reentered) return;
  S.reentered = true;
  bridge({ reenter: true });
}

// ---- the API ----

class SignedOut extends Error {}

async function api(path, opts = {}) {
  let r;
  try {
    r = await fetch(API + path, { credentials: "same-origin", ...opts });
  } catch (_) {
    // the browser's own words for this ("Load failed") say nothing
    throw new Error("harness isn't answering.");
  }
  if (r.status === 401) {
    reenter();
    throw new SignedOut("signed out");
  }
  const type = r.headers.get("content-type") || "";
  const body = type.startsWith("application/json") ? await r.json() : await r.text();
  if (!r.ok) {
    const why = body && body.error ? body.error : typeof body === "string" ? body : "It didn't work (" + r.status + ").";
    throw new Error(why);
  }
  return body;
}

function post(path, data) {
  return api(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(data) });
}

// ---- small helpers ----

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function clock(at) {
  const d = new Date((at + S.offset * 60) * 1000);
  return String(d.getUTCHours()).padStart(2, "0") + ":" + String(d.getUTCMinutes()).padStart(2, "0");
}

function minutes(started) {
  const m = Math.floor((Date.now() / 1000 - started) / 60);
  return m < 1 ? "under a minute" : m + " min";
}

function note(id, text, bad) {
  const p = $(id);
  if (!text) {
    p.hidden = true;
    p.textContent = "";
    return;
  }
  p.hidden = false;
  p.textContent = text;
  p.classList.toggle("bad", !!bad);
}

// ---- the state, from harness's facts ----

/** The spec's table: urgent, speaking (the page's), needs you, working, quiet, resting. */
function stateNow() {
  if (S.items.some((it) => it.urgent) || S.alerts > 0) return "urgent";
  if (S.speaking) return "speaking";
  if (S.items.length > 0) return "needs";
  if (S.runs.length > 0) return "working";
  if (S.quiet.now) return "quiet";
  return "resting";
}

const labels = { urgent: "urgent", speaking: "speaking", needs: "needs you", working: "working", quiet: "quiet hours", resting: "resting" };

function quietEnd() {
  const h = S.quiet.hours || "";
  return h.includes("-") ? h.split("-")[1] : "";
}

function renderCard() {
  const st = stateNow();
  document.body.dataset.state = st;
  if (S.avatar) S.avatar.setState(st);
  $("stateLabel").textContent = labels[st];
  let one = "";
  let two = "";
  if (st === "urgent") {
    const n = S.items.filter((it) => it.urgent).length;
    one = n > 0 ? (n === 1 ? "1 urgent item" : n + " urgent items") : "Urgent alert open";
    two = n > 0 ? "" : "Answer it in Telegram, or under Needs you when it asks.";
  } else if (st === "speaking") {
    // the card says harness's facts only; the words are in the caption
    one = "Reading a reply aloud.";
    const c = S.convs.find((x) => x.name === (S.speakingConv || S.conv));
    two = c ? "In " + c.title + "." : "";
  } else if (st === "needs") {
    one = S.items.length === 1 ? "1 open item" : S.items.length + " open items";
  } else if (st === "working") {
    const r = S.runs[0];
    const label = r.by === "owner" ? "“" + r.label + "”" : r.label;
    one = "Working: " + label;
    const helpers = r.helpers === 1 ? "1 helper" : r.helpers > 1 ? r.helpers + " helpers" : "";
    two = [helpers, minutes(r.started), S.runs.length > 1 ? S.runs.length - 1 + " more running" : ""].filter(Boolean).join(" · ");
  } else if (st === "quiet") {
    one = quietEnd() ? "Quiet until " + quietEnd() : "Quiet hours";
  } else {
    one = "No open items";
    two = S.data && S.data.next ? "Next: " + S.data.next : "";
  }
  $("line1").textContent = one;
  $("line2").textContent = two;
  $("line2").hidden = !two;
  // the graphics may stop or come back while the desk is open
  avatarNote();
  $("replayBtn").hidden = !(S.lastSpoken && S.settings.speak !== "off");
  const work = S.convs.find((c) => c.subject === "work");
  $("workBtn").hidden = !(st === "working" && work);
  const ro = $("readouts");
  ro.textContent = "";
  const helpers = S.runs.reduce((n, r) => n + (r.helpers || 0), 0);
  if (S.runs.length > 0) ro.append(el("span", null, S.runs.length + " running" + (helpers ? ", " + helpers + (helpers === 1 ? " helper" : " helpers") : "")));
  if (S.data) ro.append(el("span", null, "harness " + S.data.version));
}

function renderHeader() {
  const c = S.convs.find((x) => x.name === S.conv);
  const title = c ? c.title : S.conv;
  $("where").textContent = S.conv;
  $("chatTitle").textContent = title;
  const q = $("quietFact");
  if (S.quiet.hours) {
    const [from, to] = S.quiet.hours.split("-");
    q.textContent = S.quiet.now ? "quiet until " + to : "quiet from " + from;
    q.hidden = false;
  } else q.hidden = true;
  const sp = $("speakFact");
  sp.hidden = S.settings.speak === "off";
  sp.textContent = S.muted ? "voice muted" : "voice on";
  sp.classList.toggle("fact-on", !S.muted);
  $("muteBtn").setAttribute("aria-pressed", String(S.muted));
  $("muteBtn").setAttribute("aria-label", S.muted ? "Unmute" : "Mute");
  $("muteBtn").title = S.muted ? "Unmute" : "Mute";
  $("micBtn").hidden = !S.settings.voice;
  // where a recording goes, in sight while the microphone is offered
  const vp = S.settings.voice_provider || "";
  const vh = S.settings.voice_host || "";
  $("micWhere").textContent = S.settings.voice ? "Recordings are sent to " + (vp || "the voice provider") + (vh ? " (" + vh + ")" : "") + " to be transcribed." : "";
  $("micWhere").hidden = !S.settings.voice;
}

// ---- items: Needs you and the chat's buttons ----

// a click in the first half second after items were drawn is ignored:
// nothing can put a button under a click already on its way
let drawnAt = 0;
const fresh = () => Date.now() - drawnAt < 500;

async function answer(box, id, key, text) {
  if (fresh()) return;
  for (const b of box.querySelectorAll("button")) b.disabled = true;
  try {
    const d = await post("answer", { id, key, text });
    if (d.said) {
      const said = box.querySelector(".said") || box.appendChild(el("p", "said"));
      said.textContent = d.said;
    }
  } catch (e) {
    const said = box.querySelector(".said") || box.appendChild(el("p", "said"));
    said.textContent = e instanceof SignedOut ? "" : "The answer didn't reach harness.";
  }
  loadState();
}

function itemBox(it) {
  const box = el("div", "item cut " + (it.urgent ? "urgent" : "open"));
  box.append(el("div", "title", it.title || ""));
  if (it.body && it.body !== it.title) box.append(el("div", "body", it.body));
  if (it.draft) box.append(el("div", "body", it.draft));
  const where = it.conversation && it.conversation !== "main" ? "in " + it.conversation : "";
  const meta = [it.urgent ? "urgent" : "", where].filter(Boolean).join(" · ");
  if (meta) box.append(el("div", "meta" + (it.urgent ? " urgent" : ""), meta));
  const row = el("div", "choices");
  (it.choices || []).forEach((c, i) => {
    const b = el("button", "cut-s" + (i === 0 ? " first" : ""), c.label);
    b.type = "button";
    b.addEventListener("click", () => answer(box, it.id, c.key, null));
    row.append(b);
  });
  if (it.text && it.text !== "none") {
    const wrap = el("div", "answer");
    const input = el("input");
    input.type = "text";
    input.setAttribute("aria-label", "Your answer");
    input.placeholder = it.text === "reason" ? "Deny, and say why" : it.text === "draft" ? "Your own version" : "Your answer";
    const send = el("button", "cut-s", "Send");
    send.type = "button";
    send.addEventListener("click", () => {
      if (input.value.trim()) answer(box, it.id, "", input.value);
    });
    wrap.append(input, send);
    row.append(wrap);
  }
  if (row.childNodes.length) box.append(row);
  return box;
}

function renderNeeds() {
  const list = $("needs");
  list.textContent = "";
  for (const it of S.items) list.append(itemBox(it));
  const n = S.items.length;
  $("needsCount").textContent = n > 0 ? String(n) : "";
  $("needsCount").classList.toggle("urgent", S.items.some((it) => it.urgent));
  $("needsEmpty").hidden = n > 0;
  drawnAt = Date.now();
  if (n !== S.lastBadge) {
    S.lastBadge = n;
    bridge({ badge: n });
  }
}

// ---- topics and Lately ----

function renderTopics() {
  const ul = $("topics");
  ul.textContent = "";
  for (const c of S.convs) {
    const li = el("li");
    const b = el("button");
    b.type = "button";
    if (c.name === S.conv) b.setAttribute("aria-current", "true");
    const dot = el("span", "news-dot" + (c.news && c.name !== S.conv ? " on" : ""));
    dot.setAttribute("aria-hidden", "true");
    const names = el("span", "names");
    names.append(el("span", "name", c.title));
    const line = c.name === S.conv ? "Open here" : c.news ? "New since you looked" + (c.line ? ": " + c.line : "") : c.line;
    if (line) names.append(el("span", "line", line));
    b.append(dot, names);
    b.addEventListener("click", () => openConv(c.name));
    li.append(b);
    ul.append(li);
  }
}

function renderApps() {
  const ul = $("apps");
  ul.textContent = "";
  for (const app of (S.data && S.data.apps) || []) {
    const li = el("li");
    const link = el("a", null, app.title);
    link.href = "/desk/apps/" + encodeURIComponent(app.name);
    li.append(link);
    ul.append(li);
  }
}

function renderLately() {
  const ul = $("lately");
  ul.textContent = "";
  const list = (S.data && S.data.lately) || [];
  for (const l of list) {
    const li = el("li");
    li.append(el("span", "at", clock(l.at)), document.createTextNode(l.text));
    ul.append(li);
  }
  $("latelyEmpty").hidden = list.length > 0;
}

// ---- the chat ----

function msgItem(m) {
  if (!m.item) return null;
  return S.items.find((it) => it.id === m.item) || null;
}

function msgEl(m) {
  const li = el("li", "msg " + m.from + (m.urgent ? " urgent" : ""));
  const who = m.from === "you" ? "you" + (m.via === "telegram" ? " in Telegram" : m.via === "terminal" ? " in the terminal" : "") : "harness";
  li.append(el("span", "who", who + ", " + clock(m.at)));
  const open = msgItem(m);
  if (open) li.append(itemBox(open));
  else li.append(el("div", "text cut-s", m.text));
  // the desk alone: a message's own buttons (quick replies, Undo, Taken)
  if (!open && m.buttons && m.buttons.length) {
    const row = el("div", "choices");
    m.buttons.forEach((label, n) => {
      const b = el("button", "cut-s" + (n === 0 ? " first" : ""), label);
      b.type = "button";
      b.addEventListener("click", () => press(li, m.id, n));
      row.append(b);
    });
    li.append(row);
  }
  return li;
}

async function press(box, id, n) {
  if (fresh()) return;
  for (const b of box.querySelectorAll("button")) b.disabled = true;
  try {
    const d = await post("press", { id, n });
    if (d.said) box.append(el("p", "said", d.said));
  } catch (e) {
    if (!(e instanceof SignedOut)) {
      box.append(el("p", "said", "The press didn't reach harness."));
      for (const b of box.querySelectorAll("button")) b.disabled = false;
    }
  }
}

// The conversation stays on its newest message when the window changes size:
// a smaller window makes the log shorter and its lines wrap, which would leave
// the newest one below the edge.
let logAtEnd = true;
{
  const log = $("log");
  const far = () => log.scrollHeight - log.scrollTop - log.clientHeight;
  log.addEventListener("scroll", () => { logAtEnd = far() < 40; });
  if (globalThis.ResizeObserver) {
    new ResizeObserver(() => { if (logAtEnd && far() > 0) log.scrollTop = log.scrollHeight; }).observe(log);
  }
}

function renderChat() {
  const log = $("log");
  const atEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  log.textContent = "";
  if (S.msgs.length === 0) log.append(el("li", "empty", "No messages yet."));
  for (const m of S.msgs) log.append(msgEl(m));
  drawnAt = Date.now();
  if (atEnd || S.msgs.length < 4) log.scrollTop = log.scrollHeight;
}

async function loadHistory() {
  const conv = S.conv;
  try {
    const h = await api("history?conv=" + encodeURIComponent(conv));
    if (conv !== S.conv) return;
    S.msgs = h.messages || [];
    note("chatNote", h.note || "");
    renderChat();
  } catch (_) {}
}

let seenTimer = 0;
function markSeen() {
  clearTimeout(seenTimer);
  const conv = S.conv;
  seenTimer = setTimeout(() => post("seen", { conv }).catch(() => {}), 400);
}

async function openConv(name) {
  S.conv = name;
  try {
    history.replaceState(null, "", "#" + encodeURIComponent(name));
  } catch (_) {}
  const c = S.convs.find((x) => x.name === name);
  if (c) c.news = false;
  renderHeader();
  renderTopics();
  await loadHistory();
  markSeen();
}

$("compose").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("msg");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  note("composeNote", "");
  try {
    await post("send", { conv: S.conv, text });
  } catch (err) {
    if (!(err instanceof SignedOut)) {
      input.value = text;
      note("composeNote", err.message, true);
    }
  }
});

// ---- the voice: speaking replies, and the microphone ----

// spoken by the avatar, or with none chosen by a voice alone
const plainVoice = createVoice();
const voice = () => S.avatar || plainVoice;

function speakable(m, live) {
  if (!live || m.from !== "harness" || S.muted) return false;
  const mode = S.settings.speak;
  if (mode === "off") return false;
  if (m.urgent) return true;
  if (S.quiet.now) return false;
  return true;
}

async function speakNext() {
  if (S.speaking) return;
  const m = S.speakQueue.shift();
  if (!m) return;
  await speakMsg(m, m.conv);
  speakNext();
}

async function speakMsg(m, conv) {
  // muting, or a later reply, ends this one even while its voice is still on the way
  const turn = ++S.speakTurn;
  S.speaking = true;
  S.lastSpoken = m;
  if (conv) S.speakingConv = conv;
  $("caption").textContent = m.say || m.text;
  renderCard();
  try {
    if (S.settings.speak === "browser") {
      await voice().speak({ text: m.say || m.text, browser: true });
    } else {
      const r = await fetch(API + "speech", { method: "POST", credentials: "same-origin", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: m.id }) });
      if (r.status === 401) {
        reenter();
        throw new SignedOut("signed out");
      }
      if (!r.ok) {
        let why = await r.text();
        try {
          why = JSON.parse(why).error || why;
        } catch (_) {}
        throw new Error(why);
      }
      const audio = await r.blob();
      if (turn !== S.speakTurn) return;
      // the audio itself: the page may fetch only harness, not a blob: address
      await voice().speak({ text: m.say || m.text, audio });
    }
    if ($("composeNote").textContent.startsWith("Not read aloud: ")) note("composeNote", "");
  } catch (err) {
    // said under the chat, in the provider's words as harness put them
    if (turn === S.speakTurn && !(err instanceof SignedOut)) note("composeNote", "Not read aloud: " + ((err && err.message) || "the voice didn't play."), true);
  } finally {
    if (turn === S.speakTurn) {
      S.speaking = false;
      $("caption").textContent = "";
      renderCard();
    }
  }
}

$("replayBtn").addEventListener("click", () => {
  if (S.lastSpoken && !S.speaking) speakMsg(S.lastSpoken);
});

$("muteBtn").addEventListener("click", () => {
  S.muted = !S.muted;
  try {
    localStorage.setItem("desk.muted", S.muted ? "1" : "0");
  } catch (_) {}
  if (S.muted) {
    S.speakQueue = [];
    S.speakTurn++;
    plainVoice.stop();
    if (S.avatar) S.avatar.stop();
    // not left waiting on a voice that was stopped
    S.speaking = false;
    $("caption").textContent = "";
    renderCard();
  }
  renderHeader();
});

let recorder = null;
$("micBtn").addEventListener("click", async () => {
  if (recorder) {
    recorder.stop();
    return;
  }
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (_) {
    note("composeNote", "The microphone isn't available.", true);
    return;
  }
  const chunks = [];
  const conv = S.conv;
  let limit = 0;
  const idle = () => {
    clearTimeout(limit);
    stream.getTracks().forEach((t) => t.stop());
    recorder = null;
    $("micBtn").setAttribute("aria-pressed", "false");
    $("micBtn").setAttribute("aria-label", "Record a message");
    $("micBtn").title = "Record a message";
  };
  let rec;
  try {
    rec = new MediaRecorder(stream);
  } catch (_) {
    // no recorder here, or none for this microphone: the microphone is let go
    idle();
    note("composeNote", "The microphone isn't available.", true);
    return;
  }
  recorder = rec;
  rec.addEventListener("dataavailable", (e) => chunks.push(e.data));
  rec.addEventListener("stop", async () => {
    const type = rec.mimeType || "audio/webm";
    idle();
    const blob = new Blob(chunks, { type });
    if (blob.size > 10 * 1024 * 1024) return note("composeNote", "That recording is over 10 MB.", true);
    note("composeNote", "Transcribing…");
    try {
      await api("voice?conv=" + encodeURIComponent(conv), { method: "POST", headers: { "content-type": type }, body: blob });
      note("composeNote", "");
    } catch (err) {
      if (!(err instanceof SignedOut)) note("composeNote", err.message, true);
    }
  });
  try {
    rec.start();
  } catch (_) {
    idle();
    note("composeNote", "The microphone isn't available.", true);
    return;
  }
  $("micBtn").setAttribute("aria-pressed", "true");
  $("micBtn").setAttribute("aria-label", "Stop recording");
  $("micBtn").title = "Stop recording";
  // two minutes at most, as for Telegram's voice notes; dropped when the
  // recording ends sooner, so it never stops the next one
  limit = setTimeout(() => rec.state === "recording" && rec.stop(), 120000);
});

// ---- the avatar ----

/**
 * The chosen avatar when its pack is there; otherwise (none chosen, its
 * folder gone, or it won't load) the empty stage: an outline and the way
 * to add a portrait. Tried once per name; runFit asks again.
 */
async function ensureAvatar() {
  const name = (S.settings.avatars || []).includes(S.settings.avatar) ? S.settings.avatar : "";
  if (S.avatarName === name) return;
  const gen = ++S.avatarGen;
  if (S.avatar) S.avatar.dispose && S.avatar.dispose();
  S.avatar = null;
  S.avatarName = name;
  S.avatarError = "";
  $("avatar").textContent = "";
  emptyStage(!name);
  avatarNote();
  if (!name) return;
  try {
    const av = await createAvatar($("avatar"), "/desk/avatars/" + encodeURIComponent(name) + "/", { reducedMotion });
    // another load started meanwhile (another choice, or a fit's reload)
    if (gen !== S.avatarGen) {
      if (av.dispose) av.dispose();
      return;
    }
    S.avatar = av;
    S.avatar.setState(stateNow());
    $("emptyStage").hidden = true;
  } catch (e) {
    if (gen !== S.avatarGen) return;
    S.avatar = null;
    $("avatar").textContent = "";
    emptyStage(true);
    const why = String((e && e.message) || e);
    S.avatarError = /^The avatar didn't load/.test(why) ? why : "The avatar didn't load: " + why;
  }
  avatarNote();
}

/** Why the chosen avatar isn't drawn, or is drawn as its portrait only. */
function avatarNote() {
  const text = S.avatarError || (S.avatar && S.avatar.problem) || "";
  $("avatarNote").textContent = text;
  $("avatarNote").hidden = !text;
}

/** The outline shows until an avatar draws; the button once there is none. */
function emptyStage(none) {
  $("emptyStage").hidden = false;
  $("addPortraitBtn").hidden = !none;
}

// ---- loading and the long-poll ----

function take(d) {
  S.data = d;
  S.items = d.items || [];
  S.alerts = d.alerts || 0;
  S.runs = d.runs || [];
  S.quiet = d.quiet || { now: false, hours: "" };
  S.convs = d.conversations || [];
  S.settings = d.settings || S.settings;
  S.offset = d.utc_offset || 0;
  if (!S.convs.some((c) => c.name === S.conv)) S.conv = "main";
  // an urgent item or alert that wasn't there: the desk app asks for attention once
  const ids = new Set(S.items.map((it) => it.id));
  if (S.seenItems) {
    const fresh = S.items.filter((it) => !S.seenItems.has(it.id));
    if (fresh.length && S.avatar) S.avatar.arrive();
    if (fresh.some((it) => it.urgent) || S.alerts > S.lastAlerts) bridge({ attention: "urgent" });
  }
  S.seenItems = ids;
  S.lastAlerts = S.alerts;
}

async function loadState() {
  try {
    const d = await api("state");
    const was = S.conv;
    take(d);
    // the open conversation is gone (archived elsewhere): main's messages,
    // not the gone one's under main's name
    const moved = S.conv !== was;
    if (moved) {
      S.msgs = [];
      try {
        history.replaceState(null, "", "#" + encodeURIComponent(S.conv));
      } catch (_) {}
    }
    if (!S.seq) S.seq = d.seq;
    renderHeader();
    renderNeeds();
    renderTopics();
    renderLately();
    renderApps();
    renderChat();
    renderCard();
    renderSettings();
    ensureAvatar();
    if (moved) loadHistory().then(markSeen);
  } catch (_) {}
}

let stateTimer = 0;
function soon() {
  clearTimeout(stateTimer);
  stateTimer = setTimeout(loadState, 150);
}

function onEvent(ev) {
  switch (ev.type) {
    case "message": {
      const m = ev.msg;
      // already here (the history was loaded after it was written)
      if (ev.conv === S.conv && S.msgs.some((x) => x.id === m.id)) break;
      if (ev.conv === S.conv) {
        S.msgs.push(m);
        if (S.msgs.length > 50) S.msgs.shift();
        renderChat();
        if (!document.hidden) markSeen();
      } else {
        const c = S.convs.find((x) => x.name === ev.conv);
        if (c && m.from === "harness") {
          c.news = true;
          renderTopics();
        }
      }
      if (m.urgent) bridge({ attention: "urgent" });
      if (speakable(m, true) && (ev.conv === S.conv || m.urgent)) {
        m.conv = ev.conv;
        S.speakQueue.push(m);
        speakNext();
      }
      break;
    }
    case "edit": {
      // a message's outcome in place of its buttons
      const i = ev.conv === S.conv ? S.msgs.findIndex((x) => x.id === ev.msg.id) : -1;
      if (i >= 0) {
        S.msgs[i] = ev.msg;
        renderChat();
      }
      break;
    }
    case "runs":
      S.runs = ev.runs || [];
      renderCard();
      break;
    case "moment":
      if (S.avatar && (ev.moment === "smile" || ev.moment === "concern")) S.avatar.moment(ev.moment);
      break;
    case "items":
    case "topics":
    case "facts":
      soon();
      break;
  }
}

async function poll() {
  for (;;) {
    try {
      const r = await api("events?after=" + S.seq + "&wait=25");
      if (r.reset) {
        S.seq = r.seq;
        await loadState();
        await loadHistory();
        continue;
      }
      S.seq = r.seq;
      for (const ev of r.events || []) onEvent(ev);
    } catch (e) {
      if (e instanceof SignedOut) return;
      await new Promise((ok) => setTimeout(ok, 2000));
    }
  }
}

// ---- settings ----

const AVATAR_NAME = /^[a-z0-9-]{1,32}$/;

function renderSettings() {
  const box = $("avatarChoices");
  box.textContent = "";
  $("avatarNone").hidden = (S.settings.avatars || []).length > 0;
  for (const name of S.settings.avatars || []) {
    const lab = el("label", "choice");
    const r = el("input");
    r.type = "radio";
    r.name = "avatar";
    r.value = name;
    r.checked = name === S.settings.avatar;
    r.addEventListener("change", () => setSetting({ avatar: name }, "upOutcome"));
    lab.append(r, el("span", null, name === "butler" ? "The butler (built in)" : name));
    box.append(lab);
  }
  const sel = $("speakSel");
  sel.textContent = "";
  for (const v of S.settings.speak_choices || ["off"]) {
    const o = el("option", null, v === "off" ? "Off" : v === "browser" ? "Browser" : v);
    o.value = v;
    o.selected = v === S.settings.speak;
    sel.append(o);
  }
  speakWhere();
  fitFiles();
  gateUploads();
}

/** Without the fit files a photo can't be fitted: said, with their folder, and the upload off. */
function fitFiles() {
  const fit = S.settings.fit_files !== false;
  $("fitMissing").hidden = fit;
  $("fitDir").textContent = S.settings.fit_dir || "desk-assets/";
  $("upControls").disabled = !fit;
  $("closedControls").disabled = !fit;
}

/**
 * A provider reads replies aloud: where they go (or the key it lacks), its
 * model and voice with the kind's defaults greyed in, and, whenever a
 * Gemini-format voice is offered, its free tier's data use, all inline.
 */
function speakWhere() {
  const v = $("speakSel").value || S.settings.speak;
  const sp = (S.settings.speakers || []).find((x) => x.name === v);
  const p = $("speakWhere");
  const all = S.settings.speakers || [];
  // where replies would go (the provider and its host) is said before a
  // provider is chosen: choosing applies at once
  const at = (x) => x.name + (x.host ? " (" + x.host + ")" : "");
  const before = all.length === 0 ? "" : "Choosing " + (all.length === 1 ? at(all[0]) : "a provider (" + all.map(at).join(", ") + ")") + " sends replies to it to be read aloud.";
  p.textContent = !sp ? before : sp.key ? "Replies are sent to " + at(sp) + " to be read aloud." : "No " + v + " key is stored (harness secret add " + sp.secret + ").";
  p.hidden = !p.textContent;
  $("speakTune").hidden = !sp;
  if (sp) {
    // what's written is the chosen provider's; another shows its defaults
    const mine = v === S.settings.speak;
    for (const [id, key, def] of [["speakModel", "speak_model", sp.model], ["speakVoice", "speak_voice", sp.voice]]) {
      const input = $(id);
      input.placeholder = def;
      // never under the owner's typing
      if (document.activeElement !== input) input.value = mine ? S.settings[key] || "" : "";
    }
  }
  // seen before choosing, not only once chosen
  $("speakFree").hidden = !(S.settings.speakers || []).some((x) => x.api === "gemini");
}

async function setSetting(change, outcomeId) {
  try {
    await post("settings", change);
    note(outcomeId, "");
    await loadState();
  } catch (e) {
    if (!(e instanceof SignedOut)) note(outcomeId, e.message, true);
    renderSettings();
  }
}

$("speakSel").addEventListener("change", () => {
  speakWhere();
  setSetting({ speak: $("speakSel").value }, "speakOutcome");
});

for (const [id, key] of [["speakModel", "speak_model"], ["speakVoice", "speak_voice"]]) {
  $(id).addEventListener("change", () => setSetting({ [key]: $(id).value.trim() }, "speakOutcome"));
}

function targetName() {
  const typed = $("upName").value.trim();
  if (typed) return AVATAR_NAME.test(typed) && typed !== "butler" ? typed : "";
  return S.settings.avatar !== "butler" ? S.settings.avatar : "";
}

/** Uploads need the consent line ticked, a name of the owner's own, and a photo. */
function gateUploads() {
  const name = targetName();
  const ticked = $("upConsent").checked;
  $("upDir").textContent = "avatars/" + (name || "NAME") + "/";
  $("upBtn").disabled = !(ticked && name && $("upName").value.trim() && $("upFile").files.length === 1);
  $("closedBtn").disabled = !(ticked && name && $("closedFile").files.length === 1);
}
for (const id of ["upName", "upFile", "upConsent", "closedFile"]) {
  $(id).addEventListener("input", gateUploads);
  $(id).addEventListener("change", gateUploads);
}

function checkPhoto(file) {
  if (!file) return "Choose a photo.";
  if (!/^image\/(jpeg|png)$/.test(file.type)) return "A photo is a JPEG or PNG.";
  if (file.size > 10 * 1024 * 1024) return "That photo is over 10 MB.";
  return "";
}

async function uploadPart(name, part, data, type) {
  const q = "upload?avatar=" + encodeURIComponent(name) + "&part=" + part + (part === "still" || part === "closed" ? "&consent=yes" : "");
  return api(q, { method: "POST", headers: { "content-type": type || "application/octet-stream" }, body: data });
}

let lastPhoto = null;
let lastClosed = null;
let lastName = "";
// lastPhoto isn't in avatars/NAME/ yet: it goes there once the fit takes it
let unsaved = false;

function asBlob(v) {
  if (!v) return null;
  if (v instanceof Blob) return v;
  return new Blob([v]);
}

/**
 * Runs the fit (fit.js) and keeps what it made; says what it found. A new
 * portrait is fitted here first and saved only when the fit takes it, so a
 * refused one never reaches harness.
 */
async function runFit(name) {
  $("fitBtn").hidden = true;
  note("fitOutcome", "Fitting…");
  let res;
  try {
    const mod = await import("/desk/static/fit.js");
    res = await mod.fit(lastPhoto, lastClosed);
  } catch (e) {
    note("fitOutcome", (e && e.message) || "It couldn't be fitted.", true);
    if (unsaved) note("upOutcome", "Not saved.", true);
    $("fitBtn").hidden = !lastPhoto;
    return;
  }
  try {
    if (unsaved) {
      await uploadPart(name, "still", lastPhoto, lastPhoto.type);
      unsaved = false;
      note("upOutcome", "Uploaded.");
    }
    for (const k of ["head", "eyes", "eyemask"]) {
      const v = asBlob((res && res[k]) || (res && res.files && res.files[k]));
      if (v) await uploadPart(name, k, v, k === "head" ? "application/octet-stream" : "image/png");
    }
    // the eyes-closed photo is kept only once the fit has taken it, so a refused one never reaches the pack
    if (res && res.closed === true && lastClosed) await uploadPart(name, "closed", lastClosed, lastClosed.type);
  } catch (e) {
    note("fitOutcome", e.message, true);
    return;
  }
  const lines = [];
  const width = (res && res.face && res.face.width) || (res && res.faceWidth);
  if (width) lines.push("The face is " + Math.round(width) + " px wide.");
  const warns = [].concat((res && (res.warnings || res.warning)) || []);
  for (const w of warns) lines.push(w);
  const closed = res && (res.closed === true || res.closedUsed === true || (lastClosed && res.closed !== false));
  lines.push(closed ? "An eyes-closed version is in use." : "No eyes-closed version: closed eyes are drawn.");
  note("fitOutcome", lines.join(" "), warns.length > 0);
  await setSetting({ avatar: name }, "upOutcome");
  S.avatarName = null;
  ensureAvatar();
}

$("upBtn").addEventListener("click", async () => {
  const name = targetName();
  const file = $("upFile").files[0];
  const why = !$("upConsent").checked ? "Tick the line first." : checkPhoto(file);
  if (why || !name) return note("upOutcome", why || "Give it a name: a-z, 0-9 and -.", true);
  $("upBtn").disabled = true;
  note("upOutcome", "Checking…");
  try {
    // an eyes-closed photo chosen for another avatar isn't this one's
    if (lastClosed && lastName !== name) lastClosed = null;
    lastPhoto = file;
    lastName = name;
    unsaved = true;
    await runFit(name);
  } catch (e) {
    if (!(e instanceof SignedOut)) note("upOutcome", e.message, true);
  }
  gateUploads();
});

$("closedBtn").addEventListener("click", async () => {
  const name = targetName();
  const file = $("closedFile").files[0];
  const why = !$("upConsent").checked ? "Tick the line first." : checkPhoto(file);
  if (why || !name) return note("fitOutcome", why || "Choose your own avatar first.", true);
  $("closedBtn").disabled = true;
  try {
    lastClosed = file; // saved after the fit accepts it (runFit)
    if (!lastPhoto || lastName !== name || unsaved) {
      // the portrait as harness keeps it, for the line-up check
      const ini = await fetch("/desk/avatars/" + encodeURIComponent(name) + "/avatar.ini", { credentials: "same-origin", cache: "no-cache" }).then((r) => (r.ok ? r.text() : ""));
      const still = (ini.match(/^still\s*=\s*(\S+)/m) || [])[1];
      if (still) {
        lastPhoto = await fetch("/desk/avatars/" + encodeURIComponent(name) + "/" + still, { credentials: "same-origin", cache: "no-cache" }).then((r) => r.blob());
        unsaved = false;
      }
      lastName = name;
    }
    await runFit(name);
  } catch (e) {
    if (!(e instanceof SignedOut)) note("fitOutcome", e.message, true);
  }
  gateUploads();
});

$("fitBtn").addEventListener("click", () => {
  if (lastPhoto && lastName) runFit(lastName);
});

// the "i" bubbles
for (const b of document.querySelectorAll(".info > button")) {
  b.addEventListener("click", () => {
    const bubble = $(b.getAttribute("aria-controls"));
    bubble.hidden = !bubble.hidden;
    b.setAttribute("aria-expanded", String(!bubble.hidden));
  });
}

function openSettings() {
  renderSettings();
  if (!$("settings").open) $("settings").showModal();
  // a folder put in avatars/ since the page loaded is among the choices
  loadState();
}

$("settingsBtn").addEventListener("click", openSettings);

// the avatar part of Settings, ready for a photo (or saying what's missing)
$("addPortraitBtn").addEventListener("click", () => {
  openSettings();
  const fit = S.settings.fit_files !== false;
  const at = fit ? $("ownAvatar") : $("fitMissing");
  at.scrollIntoView({ block: "start", behavior: reducedMotion ? "auto" : "smooth" });
  (fit ? $("upName") : $("fitMissing")).focus({ preventScroll: true });
});
$("settingsClose").addEventListener("click", () => $("settings").close());

$("workBtn").addEventListener("click", () => {
  const work = S.convs.find((c) => c.subject === "work");
  if (work) openConv(work.name);
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) markSeen();
});

// ---- start ----

(async () => {
  // a hash that doesn't decode opens main
  let want = "";
  try {
    want = decodeURIComponent((location.hash || "").slice(1));
  } catch (_) {}
  if (want) S.conv = want;
  await loadState();
  await loadHistory();
  markSeen();
  poll();
  setInterval(renderCard, 30000);
})();
