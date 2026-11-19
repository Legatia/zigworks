# zigworks

Open-source tools written in Zig, mostly infrastructure for coding agents. Each folder is a standalone project with its own README, tests and MIT license, and no dependencies beyond the Zig standard library (and libc where noted).

| Project | What it does |
|---|---|
| [trigrep](trigrep/) | Indexed code search. ripgrep-compatible output; on the Linux kernel, with its file watcher running (`trigrep watch`, or built into the MCP server), searches take 12–160 ms against ripgrep's 1.4 s, and still see every edit. CLI and MCP server; macOS, Linux and Windows. |
| [headterm](headterm/) | Headless terminal for agents. Runs a program in a pseudo-terminal and gives the screen as text, row diffs, key input and waits, and which text is highlighted (inverse, bold, colours), so agents can drive vim, less, REPLs, menus and installers. CLI and MCP server; macOS, Linux and Windows 10 or later (ConPTY). |
| [headsight](headsight/) | Sight for agents without a stream of screenshots. Waits until a region of the screen, a window or the camera changes, goes still or shows some text, and prints one line with a small crop; reads text on the device; compares with a reference. CLI; macOS 14+ (Apple's capture and text recognition frameworks); on Linux, the camera only (V4L2). |
| [headsound](headsound/) | Audio checks and repairs in one line per answer: loudness, loudness range and true peak; clicks, clipping, dropouts, hum, "p" pops, harsh s, DC offset and phase, marked for GoldWave, Audition, Reaper, Audacity or DaVinci Resolve, or as subtitles; what is heard when (on the Mac); declick, dehum, cut pauses, trim, normalize, convert; and on the Mac, record from the microphone until you stop talking. CLI; macOS 14+, Linux and Windows (WAV only, no microphone or sound classifier off the Mac, so far). |
| [headdesk](headdesk/) | A headless desktop for agents: its own Wayland display server, with no monitor and no GPU. Lists windows, takes pictures of the desktop or of one window, clicks and types without permission prompts, waits until apps have stopped drawing and says what area changed, freezes apps and lets single frames through. With `--sandbox`, apps run in a box of Linux namespaces: they read the system, write only into the box, and what they changed can be listed, snapshotted and thrown away. A run can be recorded (pictures, inputs, log, a page to look at them) and its inputs replayed; a frozen desktop draws only when stepped, on a clock that counts frames. Where apps describe themselves (AT-SPI), buttons and fields can be found, clicked and filled by name. One process per desktop, about 9 MB at 1280x800: 300 ran at once on one machine. CLI; Linux. 0.1.0 is an experiment: its tests use its own test client, and GTK 4, Qt 6, Chrome and Firefox have each been started on it by hand and opened a menu. |
| [llmcheck](llmcheck/) | Checks a served language model through its OpenAI-style API (vLLM, llama.cpp, Ollama, gateways): whether the interface does what it accepts (output formats, tool calls, context length, limits, seeds, the key), whether token probabilities match a reference server or a recording of one, speed, and a one-line probe for cron. CLI; macOS, Linux and Windows. 0.1.0 is tested only against its own stand-in server, not yet against a real model server. |
| [keygate](keygate/) | Lets an agent use API keys it never sees: the agent gets a placeholder and a local URL; keygate keeps the key in the system's keychain, checks each request against your rules (host, method, path prefix, expiry), adds the key on the way out, masks it in what comes back, and logs every request. A weaker `run` mode puts a key in one command's environment and masks its output. CLI; macOS, Linux and Windows. 0.1.0 is tested by its own tests and by hand over https with a dummy key; the Windows store has only been compiled. |
| [harness](harness/) | A personal agent you talk to in Telegram or the terminal: research, a morning brief from your feeds and searches, scheduled tasks, and memory ranked by how often and how recently you bring things up. Every tool call passes one gate (rules, approvals as buttons, grants that expire, `/stop`) and goes into a hash-chained log. Models only through omnigate. CLI; macOS, Linux and Windows. 0.1.0 is tested by its own tests and an end-to-end script against stand-in services; not yet run against a real omnigate or Telegram bot. |

## Install

Download a binary for Linux (x86_64, arm64) or macOS (Apple Silicon; headsight on Linux watches cameras only, headdesk is Linux only) from [Releases](https://github.com/Legatia/zigworks/releases), or build from source below. All but headsight also come as a zip for Windows (x86_64). Linux binaries are static and run on any distribution.

`site/` is the project page at https://zig.legatia.solutions (static HTML, no build step).

## Building

Zig 0.17.1:

```sh
cd trigrep && zig build -Doptimize=ReleaseFast && zig build test
```

Binaries go to `zig-out/bin/` in each project. CI runs `zig build test` for every project on Linux and macOS (headdesk on Linux x86_64 and arm64 only), and for all but headsight and headdesk on Windows too (on Linux, headsight's camera path is tested against virtual cameras with `headsight/scripts/live-linux.sh`, not in CI).

## License

MIT, see each project's `LICENSE`.
