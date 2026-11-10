# zigworks

Open-source tools written in Zig, mostly infrastructure for coding agents. Each folder is a standalone project with its own README, tests and MIT license, and no dependencies beyond the Zig standard library (and libc where noted).

| Project | What it does |
|---|---|
| [trigrep](trigrep/) | Indexed code search. ripgrep-compatible output; on the Linux kernel 6–9× faster than ripgrep with results always up to date, and up to 600× faster when the index is known to be current. CLI and MCP server. |
| [headterm](headterm/) | Headless terminal for agents. Runs a program in a pseudo-terminal and gives the screen as text, row diffs, key input and waits, so agents can drive vim, less, REPLs and installers. CLI and MCP server; macOS and Linux. |

## Building

Zig 0.15.1:

```sh
cd trigrep && zig build -Doptimize=ReleaseFast && zig build test
```

Binaries go to `zig-out/bin/` in each project.

## License

MIT, see each project's `LICENSE`.
