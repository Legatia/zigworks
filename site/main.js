// Copy buttons, tabs, and the search race in the hero. Without JavaScript the page
// shows the first tab of each set and a static race (copy buttons stay hidden).
document.documentElement.classList.remove("no-js");

for (const button of document.querySelectorAll("button[data-copy]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;
    const text = source.textContent.replace(/^\$ /, "");
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 1600);
  });
}

// Tabs: arrow keys move between tabs, as in the ARIA tabs pattern.
function selectTab(tabs, tab) {
  for (const t of tabs) {
    const on = t === tab;
    t.setAttribute("aria-selected", String(on));
    t.tabIndex = on ? 0 : -1;
    const panel = t.getAttribute("aria-controls");
    if (panel) document.getElementById(panel).hidden = !on;
  }
}
function wireTabs(list, onSelect) {
  const tabs = [...list.querySelectorAll('[role="tab"]')];
  for (const tab of tabs) {
    tab.addEventListener("click", () => { selectTab(tabs, tab); onSelect?.(tab); });
    tab.addEventListener("keydown", (e) => {
      const i = tabs.indexOf(tab);
      const next = e.key === "ArrowRight" ? tabs[(i + 1) % tabs.length]
        : e.key === "ArrowLeft" ? tabs[(i - 1 + tabs.length) % tabs.length] : null;
      if (!next) return;
      e.preventDefault();
      next.focus();
      selectTab(tabs, next);
      onSelect?.(next);
    });
  }
}
for (const box of document.querySelectorAll("[data-tabs]")) wireTabs(box.querySelector('[role="tablist"]'));

// The race: measured times on the Linux kernel (median of 5 runs). The bars grow
// in real time, so ripgrep's bar takes as long to fill as ripgrep took to search.
const race = document.querySelector("[data-race]");
if (race) {
  const queries = [
    { trigrep: 45, ripgrep: 1432 },
    { trigrep: 12, ripgrep: 1434 },
    { trigrep: 160, ripgrep: 1388 },
  ];
  const scale = 1500;
  const bars = [race.querySelector('[data-bar="0"]'), race.querySelector('[data-bar="1"]')];
  const labels = [race.querySelector('[data-time="0"]'), race.querySelector('[data-time="1"]')];
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  let current = 0;
  let frame = 0;
  const fmt = (ms) => `${Math.round(ms).toLocaleString("en-US")} ms`;

  function show(q) {
    const times = [q.trigrep, q.ripgrep];
    times.forEach((ms, i) => {
      bars[i].style.transition = "none";
      bars[i].style.width = `${(ms / scale) * 100}%`;
      labels[i].textContent = fmt(ms);
    });
  }

  function play() {
    const q = queries[current];
    cancelAnimationFrame(frame);
    if (still.matches) { show(q); return; }
    const times = [q.trigrep, q.ripgrep];
    bars.forEach((bar) => { bar.style.transition = "none"; bar.style.width = "0%"; });
    labels.forEach((l) => { l.textContent = "0 ms"; });
    void race.offsetWidth; // apply the reset before animating
    const start = performance.now();
    times.forEach((ms, i) => {
      bars[i].style.transition = `width ${ms}ms linear`;
      bars[i].style.width = `${(ms / scale) * 100}%`;
    });
    const tick = (now) => {
      const t = now - start;
      times.forEach((ms, i) => { labels[i].textContent = fmt(Math.min(t, ms)); });
      if (t < Math.max(...times)) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
  }

  wireTabs(race.querySelector('[role="tablist"]'), (tab) => {
    current = Number(tab.dataset.query);
    play();
  });
  race.querySelector("[data-replay]").addEventListener("click", play);

  // Play once when the race first scrolls into view.
  const seen = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting)) { seen.disconnect(); play(); }
  }, { threshold: 0.5 });
  seen.observe(race);
}

// headterm keys demo: an installer menu, reported the way headterm reports it.
const demo = document.querySelector("[data-demo]");
if (demo) {
  const screen = demo.querySelector("[data-demo-screen]");
  const cmd = demo.querySelector("[data-demo-cmd]");
  const items = ["stable 0.15.1", "nightly 0.16.0-dev", "skip for now"];
  const width = 22; // the menu draws each row padded to this width
  let selected = 1;
  let installed = null;

  const span = (cls, text) => {
    const s = document.createElement("span");
    s.className = cls;
    s.textContent = text;
    return s;
  };

  function render() {
    screen.textContent = "";
    if (installed !== null) {
      screen.append(`Install which toolchain?\n\nInstalling ${items[installed]}... done\n\n`);
      screen.append(span("dim", `[headterm] menu 34x8 cursor=4,0 exited=0`));
      return;
    }
    screen.append("Install which toolchain?\n\n");
    items.forEach((item, i) => {
      const row = `  ${item}`;
      if (i === selected) {
        screen.append(span("sel", row.padEnd(width)));
        screen.append("\n");
      } else {
        screen.append(`${row}\n`);
      }
    });
    const row = selected + 2;
    screen.append("\n");
    screen.append(span("dim", `[headterm] highlighted: row ${row} "${items[selected]}"\n[headterm] menu 34x8 cursor=${row},0 running`));
  }

  demo.addEventListener("click", (e) => {
    const key = e.target.closest("button[data-key]")?.dataset.key;
    if (!key) return;
    if (key === "reset") {
      selected = 1;
      installed = null;
      cmd.textContent = "headterm screen menu";
    } else if (installed === null) {
      if (key === "up") selected = Math.max(0, selected - 1);
      if (key === "down") selected = Math.min(items.length - 1, selected + 1);
      if (key === "enter") installed = selected;
      const name = key === "enter" ? "Enter" : key === "up" ? "Up" : "Down";
      cmd.textContent = `headterm send menu ${name}; headterm screen menu`;
    }
    render();
  });
}
