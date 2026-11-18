# Graphical desktops for AI agents on Linux servers, and whether a purpose-built "headless desktop for agents" exists (state: 18 November 2026)

Reading notes for the whole file:

- All repository metadata (stars, last push, licence, language) was read from the GitHub API on 2026-11-18. Commit counts marked "~" are sums of contributor contributions and are approximate.
- Each finding is labelled **[source code]** (read directly in the repository), **[author claim]** / **[vendor claim]** (stated by the project about itself, not checked by anyone else), **[user report]** (an issue or comment by a user), or **[secondary]** (a search-result summary of a page I did not open myself). Nothing in this file is an independent third-party measurement unless it says so; I found none.
- "Settle" means "the screen has finished updating after an action".

## KQ1. What do current agent products actually run for a Linux desktop?

### Takeaway
Every mainstream product checked runs X11: Xvfb (or TigerVNC/KasmVNC Xvnc) with XFCE or Mutter-as-X11-window-manager, input through xdotool / pyautogui / nut.js, capture through scrot / ImageMagick / x11vnc + noVNC, and fixed sleeps after actions. None of them runs a Wayland compositor by default, and none owns its display server.

### Cited Findings

**Anthropic computer-use reference container** (anthropics/claude-quickstarts: 21,098 stars, pushed 2026-11-06, MIT)
- [source code] Base `ubuntu:22.04`; packages xvfb, xterm, xdotool, scrot, imagemagick, mutter, x11vnc, tint2, plus firefox-esr, libreoffice, pcmanfm, gedit and others; noVNC v1.5.0 + websockify v0.12.0; defaults `WIDTH=1024 HEIGHT=768 DISPLAY_NUM=1` — [Dockerfile](https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-demo/Dockerfile)
- [source code] Start order: Xvfb, tint2, Mutter, x11vnc. Xvfb runs as `Xvfb $DISPLAY -ac -screen 0 ${WIDTH}x${HEIGHT}x24 -retro -dpi 96 -nolisten tcp -nolisten unix`; Mutter runs as an X11 window manager (`XDG_SESSION_TYPE=x11 mutter --replace --sm-disable`); x11vnc with `-forever -shared -wait 50 -rfbport 5900 -nopw` — [image scripts](https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-demo/image)
- [source code] The tool waits a fixed 2.0 s before every screenshot (`_screenshot_delay = 2.0`, comment "delay to let things settle before taking a screenshot"); screenshots via `gnome-screenshot -f {path} -p`, falling back to `scrot -p`; scaling with ImageMagick `convert ... -resize`; all input via `xdotool` (`TYPING_DELAY_MS = 12`, `TYPING_GROUP_SIZE = 50`) — [computer.py](https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-demo/computer_use_demo/tools/computer.py)

**OpenAI computer-use integration recipes** (API docs, read 2026-11-18)
- [vendor documentation] Two sample Dockerfiles, both `debian:bookworm-slim` with xfce4, dbus-x11, xvfb, xdotool, imagemagick, x11-utils, firefox-esr; the viewer variant adds x11vnc, novnc, websockify. Xvfb on `DISPLAY=:99` at 1280x800x24; readiness by polling `xdpyinfo` every 0.2 s and `xdotool search --sync` for the XFCE panel — [OpenAI computer-use integration guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)
- [vendor documentation] Screenshots with ImageMagick `import -window root png:-` through `docker exec`; all input through `xdotool` (`mousemove`, `click`, `key`, `type --delay 0`); the model's `wait` action is a fixed 2-second pause in the Docker and Playwright handlers; container limits in the sample are 2 GB memory, 2 CPUs, 512 MB shared memory, 256 processes — [OpenAI computer-use integration guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)
- [vendor documentation] The main guide's code-execution path uses `pyautogui.screenshot()` and gives no delay values — [OpenAI computer-use guide](https://developers.openai.com/api/docs/guides/tools-computer-use)

**E2B Desktop** (e2b-dev/desktop: 1,570 stars, pushed 2026-11-16, Apache-2.0)
- [source code] `ubuntu:22.04`; xserver-xorg, xvfb, xfce4, xfce4-goodies, xdotool, scrot, ffmpeg, x11vnc; noVNC (E2B fork) + websockify v0.12.0; firefox-esr, google-chrome-stable, VS Code, libreoffice. Start script: Xvfb, XFCE session, x11vnc, noVNC — [template.py](https://github.com/e2b-dev/desktop/blob/main/template/template.py)
- [vendor documentation] The docs example builds the template with 8 CPUs and 8192 MB and waits for port 6080 (noVNC) as the ready signal — [E2B desktop template docs](https://e2b.dev/docs/template/examples/desktop)

**Cua** (trycua/cua: 32,609 stars, pushed 2026-11-18, Rust, MIT)
- [source code] Default Linux image: "slim: Ubuntu 24.04 + XFCE on Xvfb (:1) + session D-Bus + AT-SPI + headless PipeWire ... + Chromium"; packages xfce4, xfwm4, xvfb, xdotool, wmctrl, xclip, imagemagick, pipewire; `ENV DISPLAY=:1 CUA_X_SERVER=xvfb` — [libs/images/linux/Dockerfile](https://github.com/trycua/cua/blob/main/libs/images/linux/Dockerfile)
- [source code] `start-desktop.sh`: default `CUA_RESOLUTION=1280x800`; X server is Xvfb (`Xvfb :1 -screen 0 1280x800x24 -dpi 96 -nolisten tcp +extension RANDR +extension GLX -noreset`) or TigerVNC Xvnc (`-rfbport 5901 -AlwaysShared -AcceptSetDesktopSize=1`) — [start-desktop.sh](https://github.com/trycua/cua/blob/main/libs/images/common/desktop/start-desktop.sh)
- [source code] Other images in the repo: XFCE on TigerVNC Xvnc ([ubuntu-xfce-vnc](https://github.com/trycua/cua/tree/main/libs/images/plain/ubuntu-xfce-vnc)) and a KasmVNC image `FROM kasmweb/core-ubuntu-jammy:1.17.0` ([libs/kasm/Dockerfile](https://github.com/trycua/cua/blob/main/libs/kasm/Dockerfile))
- [vendor claim] On a real Linux desktop the driver runs as `xvfb-run -a cua-driver serve` (experimental), uses AT-SPI2 + XTEST, and has a native Wayland preview behind `CUA_DRIVER_RS_ENABLE_WAYLAND=1` — [Cua blog: Inside Linux computer use](https://cua.ai/blog/inside-linux-computer-use)
- [secondary] Docker Hub lists `trycua/cua-xfce` at about 7.35 GB compressed for latest/0.3 (6.93 GB for 0.2.0, 1.36 GB for 0.1.14) — [Docker Hub tags](https://hub.docker.com/r/trycua/cua-xfce/tags)

**Bytebot** (bytebot-ai/bytebot: 11,071 stars, last push 2025-09-12, so stale for over a year; Apache-2.0)
- [source code] `ubuntu:22.04`, `DISPLAY=:0`; xvfb, x11vnc, xfce4, wmctrl, firefox-esr, thunderbird, noVNC + websockify; input via nut.js. supervisord runs `Xvfb :0 -screen 0 1280x960x24 -ac -nolisten tcp`, starts XFCE after `sleep 5`, `x11vnc -display :0 -N -forever -shared -rfbport 5900` — [packages/bytebotd](https://github.com/bytebot-ai/bytebot/tree/main/packages/bytebotd)

**OSWorld** (xlang-ai/OSWorld: 3,267 stars, pushed 2026-11-14, Apache-2.0)
- [source code] The Docker provider runs a full QEMU virtual machine inside the container image `happysixd/osworld-docker` with `DISK_SIZE 32G, RAM_SIZE 4G, CPU_CORES 4`; needs `/dev/kvm` (falls back to `KVM=N`, logged as slower); waits up to 300 s for the VM by polling the screenshot endpoint — [docker provider](https://github.com/xlang-ai/OSWorld/blob/main/desktop_env/providers/docker/provider.py)
- [source code] The guest is Ubuntu GNOME on X11: the in-guest server uses `pyautogui.screenshot()`, python-Xlib, wmctrl, gsettings, and ffmpeg `x11grab` for recording — [server/main.py](https://github.com/xlang-ai/OSWorld/blob/main/desktop_env/server/main.py)
- [source code] `def step(self, action, pause=2)` followed by `time.sleep(pause)`: a fixed 2 s pause after every action — [desktop_env.py](https://github.com/xlang-ai/OSWorld/blob/main/desktop_env/desktop_env.py)

**OpenBot by Synthetify** (nightly-labs/openbot: 8,946 stars, pushed 2026-11-18)
- [vendor documentation] The headless server is the desktop (Electron) app on two Xvfb displays, shipped as `ghcr.io/nightly-labs/openbot:latest`, run with a custom seccomp profile and `--shm-size 1g` — [openbot repository, docs/docker.md](https://github.com/nightly-labs/openbot)
- [user report] The remote-desktop stream showed an empty Xvfb display `:1` with no window manager while all windows were on `:0` (2026-11-16) — [openbot#10615](https://github.com/nightly-labs/openbot/issues/10615)

**Daytona** (daytonaio/daytona: 71,302 stars, pushed 2026-07-24)
- [secondary] The computer-use `start()` call "Start[s] all computer use processes (Xvfb, xfce4, x11vnc, novnc) in the Sandbox"; the VNC page lists xvfb, xfce4, xfce4-terminal, x11vnc as required packages — [Daytona computer-use docs](https://www.daytona.io/docs/en/computer-use), [Daytona VNC access](https://www.daytona.io/docs/vnc-access/)

**Hermes Agent** (NousResearch/hermes-agent: 264,481 stars, pushed 2026-11-18, MIT)
- [user report] Its computer-use backend is Cua's driver (issue title "computer_use element clicks refused on cua-driver 0.34"), so on Linux it inherits Cua's X11/AT-SPI path — [hermes-agent#135872](https://github.com/NousResearch/hermes-agent/issues/135872)

**Kasm**
- [secondary] Kasm's performance page lists the standard workspace as 1.5 cores and 2 GB RAM per session — [Kasm performance reference](https://docs.kasm.com/docs/reference/kasm-performance/index.html)
- [source code] kasmtech/workspaces-core-images: 559 stars, pushed 2026-11-13 — [repository](https://github.com/kasmtech/workspaces-core-images)

**Browser-only services (Steel, Browserbase, Hyperbrowser)**
- [secondary] All three sell a remote browser driven over the Chrome DevTools Protocol, not a general desktop; one comparison says Browserbase's September 2026 computer-use post scopes the capability to the web — [comparison article](https://www.decryptiondigest.com/blog/browserbase-vs-hyperbrowser-vs-steel-dev-ai-agent-browser-infrastructure), [Steel docs index](https://steel.dev/llms.txt)
- [source code] steel-dev/steel-browser: 7,986 stars, pushed 2026-11-18, Apache-2.0 — [repository](https://github.com/steel-dev/steel-browser)

### Inferences
- The de facto standard "agent desktop" in November 2026 is still: Ubuntu 22.04/24.04 or Debian 12 + Xvfb at 1024x768 to 1280x960 + XFCE (or Mutter + tint2) + xdotool + scrot/ImageMagick + x11vnc + noVNC. Five independent products converge on nearly the same package list.
- None of these stacks can know when a frame is finished: Xvfb gives no "frame done" signal to an outside tool, so each product substitutes a fixed wait (2 s Anthropic, 2 s OSWorld, 2 s OpenAI `wait`).
- Isolation is always by container or virtual machine, one desktop per container/VM. No mainstream product offers several isolated desktops inside one container.
- Images are large because they ship a whole distribution desktop plus browsers and office apps (about 7 GB compressed for Cua's XFCE image per Docker Hub).

### Gaps
- Codex cloud environments: I found no documentation of a graphical desktop in them; the only OpenAI material read is the API sample containers above.
- Scrapybara: a 2026 search returned no status news (shut down, acquired, or active); only a directory profile dated December 2024. Its stack was not checked.
- Kasm, Steel, Browserbase, Hyperbrowser, Daytona: details above come from search summaries, not from pages I opened. Steel/Browserbase/Hyperbrowser display stacks (headless Chrome vs headful on Xvfb) were not verified.
- Cua Lume/Lumier are macOS-host virtual machine tools; their Linux guest display stack was not checked.
- E2B per-sandbox default memory and start-up time: not found in the files read.
- Start-up time and idle memory per desktop are published by none of the products above except Cua's VM density note (see KQ4).

## KQ2. Does any project already ship a display server or compositor built specifically for agents or automation?

### Takeaway
Yes, but only as very small, very new projects: three Rust compositors on Smithay that match the idea closely (agentc, fakeland, vway) were all created between 20 October and 11 November 2026 and have 0 to 1 stars; the most-starred project in the wider class (kwin-mcp, 82 stars) wraps KWin rather than owning the display server. Nothing in Zig was found, and nothing in this class has adoption or independent testing.

### Cited Findings

**A. Own compositor: the tool is the display server**
- **agentc** — Rust (Smithay, calloop), MIT, 0 stars, created 2026-11-11, pushed 2026-11-17, ~7 commits. [author claim] "A headless Wayland compositor built for agents, with an MCP server and a human control panel in the same process." One 1280x720 virtual screen per window with window-local coordinates; screenshot copies the client's `wl_shm` buffer ("no GPU, no EGL, no dmabuf, no DRM"); "static-ish 3.7 MB binary whose only system dependency is libxkbcommon"; tools `wait_for_change`, `wait_for_idle {quiet_ms, grace_ms}` ("built on a 16x16 block hash diff, not on sleeps"), `wait_for_window`, `launch`, click/drag/type/key. Stated limits: software rendering only (no dmabuf), X11 apps need an external xwayland-satellite, GTK3 menus do not open, text-input protocol missing, "Experimental". Stated rationale: "Agentic computer use has a mature answer on X11 — Xvfb + xdotool — and nothing equivalent on Wayland... The geometry, the frame timing, and 'who is in control' only exist inside the compositor." — [lin-calvin/agentc](https://github.com/lin-calvin/agentc)
- **fakeland** — Rust (Smithay), no licence file, 1 star, created 2026-11-11, pushed 2026-11-15, ~9 commits. [author claim] "A headless Wayland compositor for benchmarking GUI apps and for driving them from scripts or AI agents." GPU rendering into dmabufs; configurable fake display (resolution, scale, refresh, variable refresh, vblank timer); timestamps taken inside the compositor (input sent, commit, GPU ready, latch, present); Perfetto/JSONL/CSV traces; per-session socket, private D-Bus, process group; CLI, control socket, MCP server, accessibility crate — [zortax/fakeland](https://github.com/zortax/fakeland)
- **vway** — Rust (Smithay), Apache-2.0, 1 star, created and last pushed 2026-10-20, ~7 commits, alpha. [author claim] "A headless Wayland compositor for testing and driving GUI apps"; "Honest synchronization. You can wait for a ready window, the next frame or an idle app, and screenshots wait for the app to settle first"; private XDG_RUNTIME_DIR/HOME/D-Bus per session; GLES rendering on GPU or CPU; CLI printing one JSON document per command; MCP server with an Anthropic-compatible `computer` tool — [chpr8/vway](https://github.com/chpr8/vway)
- **waymux** — Rust, Apache-2.0, 0 stars on the GitHub mirror, created 2026-05-03, pushed 2026-07-09, ~25 commits, 0.2.0-dev. [author claim] Each session is its own compositor process; named, headless, detachable sessions; screenshot, H.264 recording, synthetic input, browser viewer; `--json` on every verb; `waymux-mcp`; `waymux-run` described as "xvfb-run for Wayland"; can nest KWin/Plasma 6 and niri; waits for the frame stream to go idle — [tek-cat/waymux](https://github.com/tek-cat/waymux)
- **mcpvil** — Rust, a fork of Smithay's example compositor smallvil with MCP tools (launch_app, capture_screenshot, mouse_move, mouse_click, key_press, scroll), no licence, 2 stars, created 2026-02-12, pushed 2026-05-13, ~22 commits. No wait or settle tools — [derekjchow/mcpvil](https://github.com/derekjchow/mcpvil)
- **glasspane** — Rust library, MIT, 1 star, created 2026-09-17, pushed 2026-10-27, ~56 commits. [author claim] "A tenant Wayland compositor as a library": one GPU texture per client plus input injection, headless only, the caller drives the frame clock with `tick()`, events Mapped/Committed/Resized, Vulkan only. Built for a shell project, not for agents — [oneilltomhq/glasspane](https://github.com/oneilltomhq/glasspane)
- **vitrin-os** — Rust, Apache-2.0/MPL-2.0, 6 stars, created 2026-07-11, pushed 2026-11-12, ~602 commits. [author claim] "agent-first display server" with a small trusted core, a capability protocol, and legacy Wayland/X11 apps confined in per-app wlroots-headless shims. An operating-system-scale research project, not a small tool — [vitrin-os/vitrin-os](https://github.com/vitrin-os/vitrin-os)

**B. Wrappers: a private headless session of an existing compositor or X server, exposed to agents**
- **kwin-mcp** — Python, MIT, 82 stars, 27 forks, created 2026-02-20, pushed 2026-11-08, ~124 commits. [author claim] One `dbus-run-session` + `kwin_wayland --virtual` per session; 29 MCP tools; input through KWin's EIS D-Bus interface with no authorisation prompt; AT-SPI; states it is "not a filesystem or network sandbox" — [isac322/kwin-mcp](https://github.com/isac322/kwin-mcp), [PyPI](https://pypi.org/project/kwin-mcp/0.2.0/)
- **waydriver** — Rust, Apache-2.0, 17 stars, created 2026-04-06, pushed 2026-07-03, ~140 commits. [author claim] Headless Mutter per session, AT-SPI, PipeWire screenshots and WebM, Mutter RemoteDesktop input, `waydriver-mcp` — [BohdanTkachenko/waydriver](https://github.com/BohdanTkachenko/waydriver)
- **deskwright** — Python, Apache-2.0, 11 stars, created 2026-08-08, pushed 2026-11-09. [author claim] Optional invisible second GNOME session costing "about 200 MB of gnome-shell" (205 MB per session), default cap of 4 sessions; `wait_for` and `region_changed` tools "instead of sleeping a guessed number of seconds" — [tristanmuzzu/deskwright](https://github.com/tristanmuzzu/deskwright)
- **linux-use** — Go, MIT, 8 stars, created 2026-10-22, pushed 2026-10-23. [author claim] One static binary of about 10 MB driving wlroots (screencopy / ext-image-copy-capture, virtual pointer and keyboard), GNOME, KDE and X11; on servers an "agent desktop" = headless labwc + wayvnc + waybar + foot + Xwayland — [StivenKN/linux-use](https://github.com/StivenKN/linux-use)
- **agent-desktop (FilipNowakowicz)** — Python, MIT, 3 stars, pushed 2026-11-12, ~177 commits. [author claim] Persistent headless labwc sessions + grim; "A session starts in well under a second"; "do not provide a security sandbox"; reports an intermittent X11 window-mapping failure in stock wlroots 0.19.3 and 0.20.2 — [FilipNowakowicz/agent-desktop](https://github.com/FilipNowakowicz/agent-desktop)
- **agent-desktop (jonatanferm)** — Python, 0BSD, 1 star, 2026-10-20. [author claim] Headless sway + Xwayland + wayvnc; "most actions take 0.15–0.5 s including the screenshot"; `wait` "until the screen stops changing"; fixed 100 ms wait after modifier shortcuts — [jonatanferm/agent-desktop](https://github.com/jonatanferm/agent-desktop)
- **wayhand-mcp** — Rust, MIT, 1 star, pushed 2026-11-14. [author claim] Sandbox = private headless sway; every action takes `settle_ms` (default 150), a fixed delay — [TimLai666/wayhand-mcp](https://github.com/TimLai666/wayhand-mcp)
- **headless-computer-mcp** — Rust, MIT, 0 stars, 2026-10-07, ~4 commits. [author claim] Headless sway per session (`WLR_BACKENDS=headless`, `WLR_RENDERER=pixman`), grim, wf-recorder, persistent virtual pointer/keyboard — [UMCEKO/headless-computer-mcp](https://github.com/UMCEKO/headless-computer-mcp)
- **Wardian** — Rust, GPL-3.0, 0 stars, created 2026-11-17. [author claim] Private headless desktops (sway default; Wayfire, niri, i3, xfwm4), private audio, rolling recorder, "input that waits for pixels" — [ItzELECTR0/Wardian](https://github.com/ItzELECTR0/Wardian)
- **shotbox** — Python, MIT, 2 stars, ~689 commits, pushed 2026-11-18. [author claim] Sealed X11 (Xvfb) or Wayland (headless sway) session with AT-SPI and audio; criticises `xvfb-run` for leaking `WAYLAND_DISPLAY` and the session bus into the child — [mishan/shotbox](https://github.com/mishan/shotbox)
- **headless-wayland-harness** — Shell + C, MIT, 0 stars; headless sway, single instance only — [tidynest/headless-wayland-harness](https://github.com/tidynest/headless-wayland-harness)
- **Screenbox** — [secondary] Show HN, April 2026: self-hosted virtual desktops for agents, "Each environment runs as a Docker container using around 2 GB RAM", AGPL-3.0 — [summary page](https://news.ainauten.com/markdown/show-hn-screenbox-self-hosted-virtual-desktops-for-ai-agents)

**C. Largest related project that is not a headless desktop**
- agent-sh/computer-use-linux: 903 stars, pushed 2026-11-17, Rust, MIT; it drives the user's real desktop, not a private one — [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux)

**D. Search coverage**
- GitHub repository search terms tried (sorted by last update): "headless wayland compositor", "wayland compositor agents", "headless compositor MCP", "wayland compositor computer-use", "headless wayland agent", "compositor agentic", "virtual display agents headless", "headless desktop agents linux", "xvfb MCP computer use", "wayland MCP headless", "headless X server agents zig" (0 results), "compositor AI agents wayland", "wlroots headless agent"; plus name lookups for kwin-mcp, waydriver, deskwright, mcpvil — [GitHub search](https://github.com/search?q=headless+wayland+compositor&type=repositories&s=updated)
- Hacker News search (Algolia, stories since 2025-01-01): "Xvfb agent" 1 hit, "Wayland compositor agents" 3 hits, "headless desktop agents" 19 hits; none of the hits is a purpose-built agent compositor — [HN search](https://hn.algolia.com/?q=Wayland+compositor+agents)

### Inferences
- The idea "headterm for graphical apps" is not novel as of November 2026: agentc and vway describe almost the same product (own headless compositor, wait-for-idle instead of sleeps, per-window pixels, MCP/CLI). The timing matters: three such projects appeared within about three weeks, which suggests the idea is "in the air" and none has yet won.
- What exists is thin. By the authors' own statements: agentc has no GPU path, no X11 without a helper, broken GTK3 menus and no text-input protocol; vway is alpha; fakeland has no licence; mcpvil has no settle detection; all have 0 to 2 stars and under 30 commits. None publishes a test matrix of real applications (Chromium, Electron, GTK3/4, Qt, LibreOffice, Java, Wine).
- The wrappers (group B) inherit whatever the host compositor allows and need that compositor installed (KWin, Mutter, sway, labwc), so they are not single binaries and several still fall back to fixed delays (wayhand 150 ms, jonatanferm 100 ms).
- Still missing across everything found: (1) X11 applications handled inside the same binary (every Wayland project needs Xwayland or xwayland-satellite as a separate program); (2) a small static binary with no distribution dependencies beyond libxkbcommon that also has GPU rendering; (3) published settle-detection accuracy; (4) published memory per desktop and desktops per machine; (5) security isolation between desktops (several authors state they provide none); (6) input-method, clipboard and font handling; (7) adoption by any mainstream agent product; (8) any Zig implementation.
- All purpose-built compositors found are Rust on Smithay or wrappers around wlroots compositors; a Zig implementation would be the first, but would also lack an equivalent of Smithay unless it binds wlroots (C).

### Gaps
- Not read: SempreBurrasca/agent-os, kiki-os/wm, hertz-ai/HARTOS (52 stars, an "AI-native OS" with its own compositor), xuedi/pinchy, Anti-2k/mango-mcp, loplex/mcp-screenshotter, kanazawahere/NomanLand and several other 0–2 star repositories seen in search results; their claims are not included above.
- No project in this class has been tested by an independent party that I could find; every capability above is the author's statement.
- I did not search GitLab, Codeberg or SourceHut directly; waymux's home is GitLab, so other projects may live only there.
- Reddit was not consulted (per the brief).

## KQ3. What do users complain about with Xvfb + VNC + xdotool?

### Takeaway
The best-documented complaints are fixed waits (1 to 2 s added to every action), stale or black frames, slow VNC, and Wayland desktops where the X11 tool chain does not work; complaints about memory per desktop and no-GPU rendering are much less visible in the trackers I searched. Hacker News has little direct discussion of Xvfb pain for agents.

### Cited Findings

**Fixed sleeps and not knowing when the screen is done**
- [source code] Fixed waits are built in: 2.0 s before each screenshot in Anthropic's demo ([computer.py](https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-demo/computer_use_demo/tools/computer.py)); `pause=2` after every step in OSWorld ([desktop_env.py](https://github.com/xlang-ai/OSWorld/blob/main/desktop_env/desktop_env.py)); `sleep 5` before XFCE in Bytebot ([bytebotd](https://github.com/bytebot-ai/bytebot/tree/main/packages/bytebotd)); a fixed 2 s `wait` in OpenAI's sample ([guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)).
- [user report, measured by the reporter on one macOS app, 2026-09-18] With Cua Driver 0.28.2 the application state changed 25 to 85 ms after an action but the tool call returned after 1,103 to 1,900 ms, because of driver-side post-action waits; 10 comments, still open. The platform is macOS, but the complaint is the settle wait itself — [cua#3971](https://github.com/trycua/cua/issues/3971)
- [vendor-side RFC, 2026-09-23] "Every action tool ... polls for window changes for ~1 s after the action. A `click` returns in ~1,040 ms with the poll and ~14 ms without it on the prototype" — [cua#4055](https://github.com/trycua/cua/issues/4055)
- [maintainer issue, 2026-09-20] Cua has "no controlled fixture that records when the resulting surface update was actually presented by the compositor" on Linux/Wayland, so driver delay, app paint delay, compositor scheduling and "Driver-owned post-action waiting after the UI was already visible" look the same — [cua#4012](https://github.com/trycua/cua/issues/4012)
- [user report, 2026-08-12] "Linux/X11 type_text hardcodes a 10 ms per-character delay" — [cua#3093](https://github.com/trycua/cua/issues/3093)

**Stale, black or wrong frames; VNC**
- [user report, 2026-10-25] X11 window screenshots return a stale frame while the screen is locked — [cua#5964](https://github.com/trycua/cua/issues/5964)
- [user report, 2026-11-08] X11 window screenshots at device pixel ratio 2 return negative coordinates — [cua#6935](https://github.com/trycua/cua/issues/6935)
- [user report, 2026-11-16] OpenBot remote desktop is all black because it streams an empty Xvfb display — [openbot#10615](https://github.com/nightly-labs/openbot/issues/10615)
- [user report, 2025-10] Bytebot: "It is slow" and "Huge VNC delay" — [bytebot#150](https://github.com/bytebot-ai/bytebot/issues/150), [bytebot#158](https://github.com/bytebot-ai/bytebot/issues/158)
- [user report] OSWorld: screenshots fail after step 200+ (2026-01-04) and screenshot resolution changes with recording stopping (2025-08-25) — [OSWorld#411](https://github.com/xlang-ai/OSWorld/issues/411), [OSWorld#317](https://github.com/xlang-ai/OSWorld/issues/317)
- [user report, 2026-06-05] On reset the OSWorld guest shows a Snap Store "software updates available" popup that derails screenshot agents — [OSWorld#515](https://github.com/xlang-ai/OSWorld/issues/515)
- [user report, 2026-08-16, open] E2B: request to composite the remote cursor into the framebuffer (the cursor is missing from captures) — [e2b desktop#249](https://github.com/e2b-dev/desktop/issues/249)

**Start-up failures**
- [user report, 2025-10-20, open] E2B: "Failed to start Xvfb: context deadline exceeded" — [e2b desktop#129](https://github.com/e2b-dev/desktop/issues/129)
- [user report, 2025-04-04] OSWorld VM not ready within the timeout — [OSWorld#168](https://github.com/xlang-ai/OSWorld/issues/168)
- [user report] Anthropic demo: noVNC failed to connect (25 comments), scrot not found, glxtest/libpci missing — [claude-quickstarts#42](https://github.com/anthropics/claude-quickstarts/issues/42), [#79](https://github.com/anthropics/claude-quickstarts/issues/79), [#255](https://github.com/anthropics/claude-quickstarts/issues/255)

**Input, fonts, input methods, clipboard**
- [user report, 2025-01-10] Double-click fails in Firefox in Anthropic's demo — [claude-quickstarts#230](https://github.com/anthropics/claude-quickstarts/issues/230)
- [user report, 2026-10-03] Codex: window-targeted input does nothing in GTK 4 apps — [codex#50578](https://github.com/openai/codex/issues/50578)
- [user report] OpenBot: ship CJK fonts on servers; input-method candidate window misplaced on XWayland; server browser reports invalid language 'c'; live frames capped at 1280x800 JPEG quality 60 — [openbot#5612](https://github.com/nightly-labs/openbot/issues/5612), [#11754](https://github.com/nightly-labs/openbot/issues/11754), [#7734](https://github.com/nightly-labs/openbot/issues/7734), [#6952](https://github.com/nightly-labs/openbot/issues/6952)
- [user report] Claude Code: image paste through the X11 clipboard under Xvfb, and orphaned xclip processes — [claude-code#50322](https://github.com/anthropics/claude-code/issues/50322), [#80330](https://github.com/anthropics/claude-code/issues/80330)
- [author claim, pitfalls found while building on headless sway] Creating a virtual pointer per action makes clients drop the first press; wtype's keycode numbering breaks punctuation in Chromium; wf-recorder hangs on a still screen because no damage frames arrive — [headless-computer-mcp](https://github.com/UMCEKO/headless-computer-mcp)

**Wayland-only desktops and X11 removal**
- [user report] Hermes Agent on Wayland: diagnostics all green while captures find no windows (2026-10-01); GNOME/Mutter shell surfaces unclickable; no input on Sway/wlroots because there is no RemoteDesktop portal; capture failure on Hyprland; headed browser has no DISPLAY (2026-11-18) — [hermes-agent#130824](https://github.com/NousResearch/hermes-agent/issues/130824), [#135835](https://github.com/NousResearch/hermes-agent/issues/135835), [#127860](https://github.com/NousResearch/hermes-agent/issues/127860), [#74969](https://github.com/NousResearch/hermes-agent/issues/74969), [#157429](https://github.com/NousResearch/hermes-agent/issues/157429)
- [user report] Requests for native computer use on Linux in Claude Code (2026-10-17, open) and Codex — [claude-code#103071](https://github.com/anthropics/claude-code/issues/103071), [codex#42846](https://github.com/openai/codex/issues/42846), [codex#54817](https://github.com/openai/codex/issues/54817), [codex#52654](https://github.com/openai/codex/issues/52654)
- [user report] OpenBot: add Wayland and Linux ARM64 desktop control; idle GPU/renderer CPU on Wayland — [openbot#10621](https://github.com/nightly-labs/openbot/issues/10621), [openbot#6965](https://github.com/nightly-labs/openbot/issues/6965)
- [secondary] GNOME 50 (reported 2026-03-19) is Wayland-only: no X11 login session, but Xwayland stays so X11 apps still run — [The Register](https://www.theregister.com/2026/03/19/gnome_50/), [Linuxiac](https://linuxiac.com/gnome-50-ends-the-x11-era-after-decades/)
- [secondary] KDE Plasma 6.8 removes the X11 login session; the article (June 2026) expected release around 14 October 2026 — [It's FOSS](https://itsfoss.com/news/kde-plasma-to-drop-x11-support/), [GamingOnLinux](https://www.gamingonlinux.com/2026/06/kde-plasma-waves-goodbye-to-x11-for-plasma-6-8/comment_id=295706)

**Hacker News**
- [user comment, 2026-06-25] "Computer use is very useful for developing GUI applications ... I run it in a VM using a headless wayland compositor" — [HN 48671811](https://news.ycombinator.com/item?id=48671811)
- [user comment, 2026-07-15] A user stays on X11 because "with X11, I can at least add xvfb, xdotool, and other utils, and AI has no problem writing" automation for it, while Wayland input injection is unclear to them — [HN 48920055](https://news.ycombinator.com/item?id=48920055)
- [user comment, 2025-11-15] wayvnc needs a wlroots compositor, "so no GNOME" — [HN 45937561](https://news.ycombinator.com/item?id=45937561)

### Inferences
- The strongest, most quantified pain is latency from blind waits: roughly 1 to 2 s per action of which only tens of milliseconds are real work (Cua's own measurement). An exact "frame presented and screen idle" event addresses this directly, and Cua's maintainers say they lack exactly that signal on Linux.
- X11 is not disappearing from servers soon: Xvfb and Xwayland are separate from the GNOME/KDE sessions that were removed. What changed in 2026 is that the desktop environments agents are supposed to imitate are now Wayland-only, and Anthropic's demo uses Mutter as an X11 window manager, which newer Mutter releases no longer support. My inference from the GNOME 50 reports; I did not find a statement from Anthropic about it.
- Complaints about memory per desktop, concurrent desktops and software-rendering speed are rare in these trackers. Either users accept container/VM cost or they complain elsewhere (Reddit and Discord were not read).

### Gaps
- No search hit for complaints specifically about screenshot token/byte cost, no-GPU rendering speed, or Chromium/Electron on Xvfb in the trackers searched, apart from the items listed; I did not search each topic separately in every repository.
- Whether Plasma 6.8 actually shipped in October 2026 was not confirmed.
- The status of Xvfb itself (maintenance, distribution packaging in Fedora/Ubuntu late 2026) was not found.
- Hacker News search returned no thread focused on Xvfb pain for agents; comment search coverage is shallow (two queries returned 2 and 10 hits).

## KQ4. Is there any published measurement of memory per headless desktop, desktops per machine, time to first frame, capture latency, or settle-detection accuracy?

### Takeaway
No independent measurement was found for any of these. The only numbers are self-reported by authors or vendors, they use different methods, and nobody publishes settle-detection accuracy.

### Cited Findings
- [vendor measurement, 2026-10-20, Mac Studio M2 Max, 96 GB, QEMU on HVF, idle guests] Cua's slim Linux desktop image as a 1 vCPU / 1024 MiB virtual machine: about 1.2 GiB resident per VM when cold-booted (66 VMs before the memory cap); 318 MiB private per VM when all VMs restore one shared snapshot (96 VMs, stopped by the vCPU limit; 128 with higher overcommit, stopped by macOS's 128-VM hypervisor limit); exec p95 1.1 to 1.5 ms. This measures whole VMs on macOS, not desktops on a Linux host — [results-vm-density.md](https://github.com/trycua/cua/blob/main/libs/cua/bench/spaces-startup/results-vm-density.md)
- [vendor documentation] Cua's benchmark also has Linux/KVM phases (Firecracker, gVisor, density) and a nightly CI guard against a committed baseline — [bench README](https://github.com/trycua/cua/blob/main/libs/cua/bench/spaces-startup/README.md)
- [author claim] deskwright: a second headless GNOME session costs about 205 MB; default cap of 4 sessions — [deskwright](https://github.com/tristanmuzzu/deskwright)
- [author claim] agentc: 3.7 MB binary; live stream 30 frames/s at about 96 KB per frame; 1.3 ms PNG encode; idle CPU about 0.8% — [agentc](https://github.com/lin-calvin/agentc)
- [author claim] wayhand-mcp: headless sway sandbox start about 110 to 210 ms plus 60 to 300 ms for the accessibility bus; 1920x1080 headless screencopy to PNG about 20 to 35 ms empty and about 165 ms with a window; AT-SPI snapshot about 130 to 1,250 ms; desktop screenshot via portal about 510 to 670 ms at 2880x1800; uinput input about 1 ms — [wayhand-mcp](https://github.com/TimLai666/wayhand-mcp)
- [author claim] jonatanferm/agent-desktop: "most actions take 0.15–0.5 s including the screenshot" — [agent-desktop](https://github.com/jonatanferm/agent-desktop)
- [author claim] FilipNowakowicz/agent-desktop: a headless labwc session "starts in well under a second" — [agent-desktop](https://github.com/FilipNowakowicz/agent-desktop)
- [configured allocations, not measurements] OSWorld VM: 4 GB RAM, 4 cores, 32 GB disk ([provider.py](https://github.com/xlang-ai/OSWorld/blob/main/desktop_env/providers/docker/provider.py)); OpenAI sample container: 2 GB, 2 CPUs ([guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)); Kasm standard workspace: 1.5 cores, 2 GB ([Kasm performance, secondary](https://docs.kasm.com/docs/reference/kasm-performance/index.html)); Screenbox: about 2 GB per container ([secondary](https://news.ainauten.com/markdown/show-hn-screenbox-self-hosted-virtual-desktops-for-ai-agents)); E2B docs example: 8 CPUs, 8192 MB ([E2B docs](https://e2b.dev/docs/template/examples/desktop))
- [secondary, vendor test] Kasm: 1080p full-screen video with software H.264 used about 69% of one CPU core in the KasmVNC server at 24 frames/s — [Kasm performance](https://docs.kasm.com/docs/reference/kasm-performance/index.html)
- [user-measured, one app] Action-to-state-change 25 to 85 ms versus tool return 1.1 to 1.9 s on Cua (macOS) — [cua#3971](https://github.com/trycua/cua/issues/3971)

### Inferences
- The spread is about one order of magnitude: roughly 0.2 GB for an extra compositor session on a shared host (deskwright), 0.3 GB private for a snapshot-shared VM (Cua), 1 to 2 GB for a container or cold VM (Cua, OpenAI sample, Kasm, Screenbox), 4 GB for an OSWorld VM. A native headless compositor without a desktop environment should sit below the 0.2 GB figure before the application itself, but nobody has published that number; this is my estimate, not a measurement.
- "Settle detection accuracy" (how often a tool says "done" too early or too late) is an open measurement gap; a credible benchmark here would be new.

### Gaps
- No independent benchmark of any agent desktop stack was found.
- No published memory figure for bare Xvfb + window manager per display in an agent context, and none for agentc, vway or fakeland.
- No time-to-first-frame figure for Xvfb-based products (E2B, Anthropic demo, Daytona).
- Cua's Linux/KVM density baseline file exists (`baseline/linux-kvm-gha-ubuntu-24.04.json`) but was not read.

## KQ5. Is there evidence of demand for many isolated desktops per machine without VMs or containers?

### Takeaway
There is clear demand for many parallel desktops (evaluation harnesses, agent farms) and a visible push to make each one cheaper, but direct evidence that users want this specifically without VMs or containers is limited to small projects and one benchmark; large users currently solve density with snapshot-shared VMs and cloud fleets.

### Cited Findings
- [vendor claim] OSWorld-Verified moved to AWS to run environments in parallel and states evaluation time can drop to within 1 hour; secondary write-ups give "up to about 50" simultaneous environments (no primary statement of the number found) — [OSWorld repository](https://github.com/xlang-ai/OSWorld), [XLANG blog](https://xlang.ai/blog/osworld-verified)
- [user report, 2025-10-27] OSWorld on AWS hits `VcpuLimitExceeded` with fewer than 15 environments; a separate issue asks about running time on AWS (2025-11-11) — [OSWorld#366](https://github.com/xlang-ai/OSWorld/issues/366), [OSWorld#374](https://github.com/xlang-ai/OSWorld/issues/374)
- [source code] OSWorld ships providers for AWS, Azure, GCP, Aliyun, Daytona, Modal, fastvm, Docker and others, i.e. the harness is built around renting many machines — [providers directory](https://github.com/xlang-ai/OSWorld/tree/main/desktop_env/providers)
- [vendor measurement] Cua frames density as "256 concurrent rollouts need at least 2 Macs" and added admission control because hosts were being driven into swap; the target user is "a trainer" starting VMs in steps — [results-vm-density.md](https://github.com/trycua/cua/blob/main/libs/cua/bench/spaces-startup/results-vm-density.md), [bench README](https://github.com/trycua/cua/blob/main/libs/cua/bench/spaces-startup/README.md)
- [author claim] hyprbench, an OSWorld-style benchmark for Hyprland, runs "native (no VM)" and states "per-task reset costs ~1 second via nested compositor instances" — [crispwisp/hyprbench](https://github.com/crispwisp/hyprbench)
- [author claim] deskwright caps private GNOME sessions at 4 by default with a free-memory floor, showing a per-machine multi-session use case on a workstation — [deskwright](https://github.com/tristanmuzzu/deskwright)
- [user request, 2026-09-30, 24 upvotes, 14 comments] Codex users want to attach a headless Linux server as a task environment without a graphical desktop on it — [codex#49491](https://github.com/openai/codex/issues/49491)
- [launch posts] Commercial interest in desktops-as-a-service for agents: Launch HN Cua (2025-04-23, 172 points, 73 comments), Launch HN Coasty "An API for computer-use agents" (2026-07-15, 44 points), Show HN Cyberdesk (2025-05-20), Show HN pi agents API "with Linux desktop sandbox" (2026-11-15) — [HN 43773563](https://news.ycombinator.com/item?id=43773563), [HN 48922706](https://news.ycombinator.com/item?id=48922706), [HN 44040689](https://news.ycombinator.com/item?id=44040689), [HN 50507721](https://news.ycombinator.com/item?id=50507721)
- [repository creation dates] At least ten independent "private desktop for the agent" projects were created between September and November 2026 (agentc, fakeland, vway, linux-use, both agent-desktop projects, headless-computer-mcp, Wardian, glasspane, wayhand-mcp) — see the repositories listed under KQ2, e.g. [agentc](https://github.com/lin-calvin/agentc), [vway](https://github.com/chpr8/vway), [Wardian](https://github.com/ItzELECTR0/Wardian)

### Inferences
- Demand splits in two. (a) Hosted products and evaluation harnesses want strong isolation and reproducible images, so they accept VMs/containers and optimise them (snapshots, copy-on-write). (b) Individual developers running coding agents on their own Linux machine want a second, invisible desktop without a VM; this is where the many small projects sit, and it matches the "headterm for graphical apps" user.
- A native compositor without VM or container does not isolate the file system, network or processes; authors of kwin-mcp and agent-desktop say so explicitly. For group (a) it would have to run inside their sandbox anyway, where its benefit is exact frame events and lower memory, not replacing the sandbox.
- GUI-test CI is a plausible third audience (vway and fakeland name testing and benchmarking first, agents second), but I found no demand evidence from CI users.

### Gaps
- No numbers on how many concurrent desktops any hosted vendor runs per host.
- No survey or issue count showing users asking for "no container" specifically.
- The "about 50 parallel environments" figure for OSWorld on AWS comes from secondary sources only.
- GUI-test CI demand (for example GTK, Qt or Electron projects asking for a better xvfb-run) was not researched.

## KQ6. Adjacent, non-agent prior art

### Takeaway
The building blocks all exist and are mature (wlroots headless backend, virtual input protocols, screen-capture protocols with damage and presentation time, Mutter and KWin headless modes, xwfb-run, wayvnc), but each one covers only part of the job and they differ per compositor; for browser-only work no desktop is needed at all.

### Cited Findings
- [protocol documentation] `ext-image-copy-capture-v1` captures "image sources such as outputs and toplevels" into client buffers; each frame delivers `transform`, `damage` and `presentation_time` before `ready`; the first frame carries full damage; afterwards the compositor may wait indefinitely for the content to change before copying; cursor capture is a separate session; the protocol is in staging — [wayland.app: ext-image-copy-capture-v1](https://wayland.app/protocols/ext-image-copy-capture-v1)
- [conflict] Which compositors implement it is unclear from the support table: my read of the page lists COSMIC, Jay, labwc, Mango, Mir, phoc, river, Sway, Treeland as supporting and KWin, Mutter, Hyprland, niri, Weston, Cage as not; a search summary of the same page listed Weston, Hyprland, niri and Cage as supporting. The table has no legend, so treat both as unverified — [wayland.app: ext-image-copy-capture-v1](https://wayland.app/protocols/ext-image-copy-capture-v1)
- [protocol documentation] The older `wlr-screencopy-unstable-v1` has `copy_with_damage`, which waits for damage and avoids forced redraws — [wayland.app: wlr-screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1)
- [author reports from projects using it] wlroots headless is driven with `WLR_BACKENDS=headless` and `WLR_RENDERER=pixman`; known traps: a headless seat advertises no pointer/keyboard capability, cage in headless mode refuses virtual pointers, and an intermittent X11 mapping failure exists in wlroots 0.19.3 and 0.20.2 — [headless-computer-mcp](https://github.com/UMCEKO/headless-computer-mcp), [headless-wayland-harness](https://github.com/tidynest/headless-wayland-harness), [FilipNowakowicz/agent-desktop](https://github.com/FilipNowakowicz/agent-desktop)
- [upstream merge request, secondary] Mutter runs headless as `mutter --wayland --headless --virtual-monitor 1280x720`; the headless backend only works with virtual monitors; capture is through `org.gnome.Mutter.ScreenCast` (PipeWire streams, `RecordVirtual`) and input through `org.gnome.Mutter.RemoteDesktop` — [Mutter MR 1698](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/1698/pipelines), [ScreenCast interface XML](https://sources.debian.org/src/mutter/49.2-1/data/dbus-interfaces/org.gnome.Mutter.ScreenCast.xml), [GNOME wiki](https://live.gnome.org/Projects/Mutter/RemoteDesktop)
- [author claim, secondary] waydriver's notes: headless Mutter only composites and delivers frame callbacks while a ScreenCast consumer pulls frames (without a stream GTK4 apps render one frame and never repaint), and Mutter rejects `ScreenCast.Session.Start` on a linked session, so it must be started through RemoteDesktop — [waydriver-compositor-mutter source](https://docs.rs/crate/waydriver-compositor-mutter/0.2.8/source/src/lib.rs), [waydriver](https://github.com/BohdanTkachenko/waydriver)
- [upstream issue, secondary] Mutter has no D-Bus way to ask whether it is running headless (property requested, not confirmed) — [Mutter issue 1905](https://gitlab.gnome.org/GNOME/mutter/-/issues/1905)
- [author claim] KWin runs headless as `kwin_wayland --virtual` and accepts input through its EIS D-Bus interface without a prompt — [kwin-mcp](https://github.com/isac322/kwin-mcp)
- [man page, secondary] `xwfb-run` (xwayland-run) is the Wayland-era replacement for `xvfb-run`: it runs a rootful Xwayland on a headless Wayland compositor — [xwfb-run man page](https://www.mankier.com/1/xwfb-run)
- [user comments] wayvnc gives VNC access to a headless wlroots compositor but not to GNOME — [HN 45937561](https://news.ycombinator.com/item?id=45937561), [HN 46387865](https://news.ycombinator.com/item?id=46387865)
- [upstream documentation] Weston's test-suite page describes plugin tests and client tests and names Pixman and GL as example fixture settings, but the page read does not describe the headless backend or the test protocol — [Weston test suite](https://wayland.pages.freedesktop.org/weston/toc/test-suite.html)
- [release notes, secondary] Xpra forwards individual windows of a persistent headless X session; v7.0 adds Wayland server packages and wlroots 0.20 support — [Xpra man page](https://www.mankier.com/1/xpra), [Xpra v7.0 release notes](https://newreleases.io/project/github/Xpra-org/xpra/release/v7.0)
- [secondary] Chromium's new headless mode needs no X server, and Playwright uses it by default; headed runs on Linux still need Xvfb (`xvfb-run`); sources disagree on which binary Playwright launches in headless mode since 1.49/1.57 — [Playwright issue 33566](https://github.com/microsoft/playwright/issues/33566), [Currents](https://currents.dev/posts/when-tests-should-run-headless-vs-headed-in-playwright), [TestDino](https://testdino.com/blog/headless-vs-headed)
- [secondary] Cases that still need a display: extension toolbar popups (`chrome.action.openPopup`) are unreliable in new headless, and a headless Chrome WebGPU canvas does not reach the headless compositor so Xvfb is the workaround — [crxbox CI guide](https://tabox-ext.github.io/crxbox/guides/ci), [agent-browser WebGPU note](https://agent-browser.dev/webgpu)
- [author claim] `xvfb-run` lets `WAYLAND_DISPLAY` and the session bus through to the child process, so apps can escape to the real desktop — [shotbox](https://github.com/mishan/shotbox)

### Inferences
- A tool that owns the compositor does not need any capture protocol: it already holds each window's buffer, the damage region and the presentation time. The protocols above exist to export that information to outside clients, and every wrapper project in KQ2 is limited by what its host compositor chooses to export.
- For web pages alone, a headless desktop is unnecessary; the target for a graphical "headterm" is native toolkits (GTK, Qt, Electron shell behaviour, Java, Wine) and the browser cases that headless mode cannot do.
- The practical cost of the Wayland route is X11 applications: each project needs Xwayland or xwayland-satellite beside it, which breaks the single-binary property unless it is bundled or X11 apps are declared out of scope.

### Gaps
- Weston's headless backend and `weston-test` protocol (input injection, screenshot, repaint control) were not documented on the page read; I could not confirm their capabilities from a primary source.
- gamescope headless mode and KWin's `--virtual` documentation were not researched from primary sources.
- Xpra's headless X server choice (Xvfb vs Xdummy) and per-window damage model were not confirmed from its documentation.
- wlroots' own documentation for the headless backend was not opened; statements come from projects that use it.
- Compositor support for `ext-image-copy-capture-v1` is unresolved (see the conflict above).
