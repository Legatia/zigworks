# zigworks

Open-source tools written in Zig, mostly infrastructure for coding agents. Each folder is a standalone project with its own README, tests and MIT license, and no dependencies beyond the Zig standard library (and libc where noted).

| Project | What it does |
|---|---|
| [trigrep](trigrep/) | Indexed code search. ripgrep-compatible output; on the Linux kernel, with its file watcher running (`trigrep watch`, or built into the MCP server), searches take 12–160 ms against ripgrep's 1.4 s, and still see every edit. CLI and MCP server. |
| [headterm](headterm/) | Headless terminal for agents. Runs a program in a pseudo-terminal and gives the screen as text, row diffs, key input and waits, and which text is highlighted (inverse, bold, colours), so agents can drive vim, less, REPLs, menus and installers. CLI and MCP server; macOS and Linux. |
| [headsight](headsight/) | Sight for agents without a stream of screenshots. Waits until a region of the screen, a window or the camera changes, goes still or shows some text, and prints one line with a small crop; reads text on the device; compares with a reference. CLI; macOS 14+ (Apple's capture and text recognition frameworks). |

## Install

Download a binary for Linux (x86_64, arm64) or macOS (Apple Silicon; headsight is macOS only) from [Releases](https://github.com/Legatia/zigworks/releases), or build from source below. Linux binaries are static and run on any distribution.

`site/` is the project page at https://zig.legatia.solutions (static HTML, no build step).

## Building

Zig 0.15.1:

```sh
cd trigrep && zig build -Doptimize=ReleaseFast && zig build test
```

Binaries go to `zig-out/bin/` in each project. CI runs `zig build test` for every project on Linux and macOS (headsight builds on Linux but captures only on macOS).

## License

MIT, see each project's `LICENSE`.
