# zigworks

Open-source tools written in Zig, mostly infrastructure for coding agents. Each folder is a standalone project with its own README, tests and MIT license, and no dependencies beyond the Zig standard library (and libc where noted).

| Project | What it does |
|---|---|
| [trigrep](trigrep/) | Indexed code search. ripgrep-compatible output; on the Linux kernel, with its file watcher running (`trigrep watch`, or built into the MCP server), searches take 12–160 ms against ripgrep's 1.4 s, and still see every edit. CLI and MCP server. |
| [headterm](headterm/) | Headless terminal for agents. Runs a program in a pseudo-terminal and gives the screen as text, row diffs, key input and waits, and which text is highlighted (inverse, bold, colours), so agents can drive vim, less, REPLs, menus and installers. CLI and MCP server; macOS and Linux. |

## Building

Zig 0.15.1:

```sh
cd trigrep && zig build -Doptimize=ReleaseFast && zig build test
```

Binaries go to `zig-out/bin/` in each project. CI runs `zig build test` for both projects on Linux and macOS.

## License

MIT, see each project's `LICENSE`.
