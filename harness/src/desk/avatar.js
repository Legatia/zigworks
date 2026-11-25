// Stand-in for the avatar module (platform/desk-avatar replaces this file
// with the live 3D head). Same interface: the portrait, breathing by a
// 0.6% scale ease; the eyes-closed portrait while resting or quiet; the
// voice plays without lip-sync.
//
//   const av = await createAvatar(element, "/desk/avatars/NAME/", { reducedMotion });
//   av.setState("urgent" | "speaking" | "needs" | "working" | "quiet" | "resting");
//   av.moment("smile" | "concern"); av.arrive();
//   await av.speak({ text, audioUrl }) or av.speak({ text, browser: true });
//   av.stop(); av.destroy();

function readIni(text) {
  const out = {};
  for (const raw of text.split("\n")) {
    const line = raw.replace(/[;#].*$/, "").trim();
    const eq = line.indexOf("=");
    if (eq > 0) out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return out;
}

function picture(src) {
  const img = document.createElement("img");
  img.alt = "";
  img.decoding = "async";
  img.src = src;
  const s = img.style;
  s.position = "absolute";
  s.inset = "0";
  s.width = "100%";
  s.height = "100%";
  s.objectFit = "cover";
  s.objectPosition = "50% 22%";
  s.transition = "opacity 0.6s ease";
  return img;
}

export async function createAvatar(element, packUrl, options = {}) {
  const base = packUrl.endsWith("/") ? packUrl : packUrl + "/";
  let pack = {};
  try {
    const r = await fetch(base + "avatar.ini", { credentials: "same-origin" });
    if (r.ok) pack = readIni(await r.text());
  } catch (_) {}
  const holder = document.createElement("div");
  const hs = holder.style;
  hs.position = "absolute";
  hs.inset = "0";
  hs.transformOrigin = "50% 70%";
  hs.willChange = "transform";
  const open = picture(base + (pack.still || "still.jpg"));
  open.setAttribute("data-part", "still");
  holder.append(open);
  let closed = null;
  if (pack.closed) {
    closed = picture(base + pack.closed);
    closed.style.opacity = "0";
    holder.append(closed);
  }
  element.append(holder);

  let state = "resting";
  let audio = null;
  let utter = null;
  let raf = 0;
  const t0 = performance.now();
  const frame = (now) => {
    // slower, deeper breaths with the eyes closed
    const restful = state === "resting" || state === "quiet";
    const period = restful ? 5200 : 3800;
    const depth = restful ? 0.006 : 0.004;
    const k = (1 - Math.cos(((now - t0) / period) * Math.PI * 2)) / 2;
    hs.transform = "scale(" + (1 + depth * k).toFixed(5) + ")";
    raf = requestAnimationFrame(frame);
  };
  raf = requestAnimationFrame(frame);

  function stop() {
    if (audio) {
      audio.pause();
      audio = null;
    }
    if (utter && window.speechSynthesis) window.speechSynthesis.cancel();
    utter = null;
  }

  return {
    setState(next) {
      state = next;
      if (closed) closed.style.opacity = state === "resting" || state === "quiet" ? "1" : "0";
    },
    moment(_kind) {},
    arrive() {},
    speak({ text, audioUrl, browser }) {
      stop();
      return new Promise((resolve) => {
        if (audioUrl) {
          audio = new Audio(audioUrl);
          audio.addEventListener("ended", () => resolve(), { once: true });
          audio.addEventListener("error", () => resolve(), { once: true });
          audio.play().catch(() => resolve());
          return;
        }
        if (browser && window.speechSynthesis && text) {
          utter = new SpeechSynthesisUtterance(text);
          utter.onend = () => resolve();
          utter.onerror = () => resolve();
          window.speechSynthesis.speak(utter);
          return;
        }
        resolve();
      });
    },
    stop,
    destroy() {
      stop();
      cancelAnimationFrame(raf);
      holder.remove();
    },
  };
}
