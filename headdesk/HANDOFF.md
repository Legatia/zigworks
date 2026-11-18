# headdesk — handoff

Written 2026-11-18 on the Mac session, for the Windows session that takes over in WSL2.
`headdesk` is a working name; the owner has not confirmed it.

## What this is

A headless desktop for AI agents on Linux: one static binary that is its own
Wayland display server (compositor), with no monitor and no GPU. Graphical apps
run inside it; the agent drives and observes them. "headterm, but for graphical
apps." It is the next zigworks component, built **before** the agent harness.

The owner's motive is **deeper control of the machine than accessibility-layer
tools have — not speed.** Do not pitch or optimise for speed.

Planned commands (final names open):

| Command | What the agent gets |
|---|---|
| start, run | A private desktop with an app in it; many at once |
| windows | Every window, menu and popup with title and position |
| shot | Whole desktop or one window at full size, even when covered |
| click, key, type | Input with no permission prompts; text inserted directly, layout-independent |
| wait | Returns when apps have stopped drawing, and says which areas changed |
| step | Freezes apps and lets exactly one frame through |
| log | One ordered record of every input and every screen change |

It runs Linux apps only. On Windows it runs inside WSL2, on macOS inside a
Linux VM or container. It does not control the host's own Mac/Windows apps.

## What has been decided

- Pure Zig 0.17.1, no C libraries, static binary — **if** the experiment below passes.
- Skip the "wrapper around headless sway" stage the research report recommends;
  about ten such wrappers exist and they give none of the deeper control.
- No design document exists yet and no code has been written. The owner said
  "skip" to design questions and wants the experiment started.
- The second component (hardware KVM control as a headsight extension) is not
  part of this handoff.

## The first job: the deciding experiment

Question: do real apps start, draw and open a menu on a minimal pure-Zig
compositor that offers only shared-memory buffers (no GPU buffers)?

Build a throwaway-quality compositor that:

1. Listens on a Wayland socket in a private `XDG_RUNTIME_DIR`.
2. Speaks the wire protocol itself (no libwayland, no wlroots).
3. Implements, as a starting set (inferred, not verified):
   `wl_compositor`, `wl_subcompositor`, `wl_shm`, `wl_seat` (pointer + keyboard),
   `wl_output`, `wl_data_device_manager`, `xdg_wm_base` (toplevels and popups
   with grabs), `wp_viewporter`. Firefox aborts without `wl_subcompositor`.
4. Composites into a memory framebuffer and can write it out as an image.
5. Can inject one pointer click and one key press.

Test apps, each in its own `dbus-run-session`:

| App | Notes |
|---|---|
| Chromium | `--ozone-platform=wayland --disable-gpu`; has an shm buffer path |
| Firefox | `MOZ_ENABLE_WAYLAND=1` |
| a GTK 4 app | `GSK_RENDERER=cairo` forces software drawing |
| a Qt 6 app | `QT_QPA_PLATFORM=wayland` |

For each app record: connects / first frame drawn / window image correct /
menu (popup) opens after a click / which missing interface or request it
complained about. `WAYLAND_DEBUG=1` on the client shows what it asked for.

Result decides the route:

- All four pass → continue in pure Zig.
- Chromium or Electron need GPU buffers (`linux-dmabuf`) → fall back to
  zig-wlroots (needs wlroots 0.20; Ubuntu 26.04 ships 0.19.2) and first check
  whether a static wlroots build from `build.zig` works.

Known hard parts: popup positioning, input grabs, nested surfaces — not drawing.
A keyboard needs a keymap sent to clients; one fixed layout file is enough, and
text entry can later go through the input-method protocol instead.

Known limits to state in any README: "settled" never means "done" (an app
waiting on the network looks idle); no accessibility tree in the first version;
no sandboxing claim.

## After the experiment

Report the per-app table to the owner. A real version then needs a design the
owner approves before product code: settle detection from damage + frame
callbacks (classify periodic damage such as a blinking caret), stepping by
withholding frame callbacks, per-window capture, the event log, one process per
desktop with its own runtime dir and D-Bus session, no privileges.

## Repo conventions

- Monorepo: https://github.com/Legatia/zigworks, `main` at `437263a` when this
  was written. Siblings: trigrep, headterm, headsight, headsound, llmcheck.
- Each tool is a folder with `build.zig`, `build.zig.zon`
  (`.minimum_zig_version = "0.17.1"`), `src/`, `scripts/` (smoke tests),
  `README.md`, `LICENSE`. Copy headterm's layout.
- CI: `.github/workflows/ci.yml` runs a matrix of OS × tool. headdesk would be
  Linux-only (ubuntu x64 and arm64).
- Tests first: write the failing test, watch it fail, then the code. The wire
  protocol encoder/decoder is unit-testable without any app.
- User-facing text uses plain labels, no slogans.

## Owner's standing rules

- Commits, pushes, tags and releases are the owner's decision; ask each time.
- Ask before downloading anything (Zig toolchain, browsers, packages) and
  state name, source and size.
- `gh` is read-only: no comments, issues, stars or job re-runs.
- Never enter passwords, keys or tokens.
- Nothing that injects into other apps or gets around permission prompts.
- Refer to the owner as they/them.

## Reference material in `research/`

- `agent-headless-desktop-and-kvm.md` — the full report (rivals, three routes,
  risks). Its staged plan starts with a sway wrapper; that stage was dropped.
- `zig_headless_compositor_route.md` — notes on the Zig/Wayland stack.
- `agent_desktops_on_linux.md` — notes on existing agent desktops.

Nothing in the research was built or run; rival figures are self-reported and
size/time estimates are guesses.
