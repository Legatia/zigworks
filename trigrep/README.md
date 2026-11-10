# trigrep

Indexed code search for large repositories and coding agents. ripgrep-compatible output, a trigram index so a search only reads files that can match, and a freshness check so edits since indexing are never missed.

```sh
trigrep spin_lock_irqsave            # first run in a repo builds the index
trigrep -i 'todo|fixme' src/
trigrep -w mutex_lock -g '*.c'
trigrep index                        # rebuild after big changes (branch switch, pull)
trigrep status                       # how many files changed since indexing
```

Output is `path:line:text`, like `rg -n --no-heading`. Exit status is 0 if something matched, 1 if not, 2 on error.

## MCP server

`trigrep mcp` speaks the Model Context Protocol over stdio, so agents can call it as a tool. To register it with Claude Code:

```sh
claude mcp add trigrep -- /absolute/path/to/trigrep mcp
```

Tools:

- `trigrep_search` takes `pattern`, plus optional `path`, `ignore_case`, `fixed_strings`, `word`, `glob` (array), `output` (`lines`, `files` or `count`), `max_results` (default 200) and `max_per_file`. It returns `path:line:text` lines, and says so when it stopped at `max_results`.
- `trigrep_index` rebuilds the index for `path`.
- `trigrep_status` shows the index and how many files changed since it was built.

Paths are relative to the server's working directory, which is the project when Claude Code starts it. A bad pattern comes back as a tool error with the reason.

## Benchmarks

Apple M-series, 10 cores, warm page cache, median of 5 runs, wall time including process start. Results are byte-identical to ripgrep 15.2 for every pattern below (`scripts/compare.sh`).

Linux kernel (96,771 files, 1.7 GB; index 146 MB, built in 4.5 s):

| pattern | rg | trigrep | trigrep --trust-index |
|---|---:|---:|---:|
| `spin_lock_irqsave` | 1467 ms | 159 ms | 26 ms |
| `EXPORT_SYMBOL_GPL\(kmalloc` | 1398 ms | 179 ms | 10 ms |
| `zzzqqqxxx` (no match) | 1340 ms | 154 ms | 2 ms |
| `^static int __init \w+_init\(void\)` | 1388 ms | 246 ms | 56 ms |
| `TODO\|FIXME\|XXX` | 1425 ms | 366 ms | 140 ms |
| `struct \w+_ops \w+ = \{` | 1351 ms | 488 ms | 370 ms |

Zig standard library (18,100 files, 171 MB; index 20 MB, built in 0.7 s):

| pattern | rg | trigrep | trigrep --trust-index |
|---|---:|---:|---:|
| `ArrayList` | 189 ms | 31 ms | 8 ms |
| `pub fn \w+\(self` | 199 ms | 29 ms | 5 ms |
| `TODO\|FIXME` | 187 ms | 41 ms | 17 ms |
| `\w+_\w+_\w+` (no literal to index) | 274 ms | 232 ms | 215 ms |

Most of the default-mode time is the freshness check (walking and stat-ing every file, about 150 ms on Linux). `--trust-index` skips it and is only safe right after `trigrep index`. A watcher that keeps the index fresh is the next step, see below.

Reproduce: `zig build -Doptimize=ReleaseFast`, then `python3 scripts/bench.py DIR PATTERN...` and `scripts/compare.sh DIR PATTERN [flags]`.

## How it works

- **Index.** Every distinct trigram (3 bytes, ASCII-lowercased, never spanning a newline) of every text file, with a posting list of file ids (varint deltas). One file per indexed root under `$TRIGREP_INDEX_DIR`, `$XDG_CACHE_HOME/trigrep` or `~/.cache/trigrep`, read through mmap.
- **Query.** The regex is parsed and turned into a trigram query (AND within literals, OR across alternation, nothing for optional parts), as in Russ Cox's [codesearch](https://swtch.com/~rsc/regexp/regexp4.html). Lowercased trigrams mean one index serves case-sensitive and `-i` searches.
- **Freshness.** Before searching, trigrep walks the tree (in parallel, honouring ignore files) and compares sizes and mtimes with the index. Changed and new files are searched directly; deleted ones are dropped. Results are always correct, the index only decides how much has to be read.
- **Matching.** Its own regex engine (Zig's standard library has none): a parser, a Thompson NFA, a lazy DFA, and a Pike VM fallback for word boundaries. A required literal from the query (or a set of literals for alternations) skips straight to candidate lines.
- **Walking.** ripgrep's defaults: `.gitignore`, `.ignore` and `.git/info/exclude` are honoured, hidden files and `.git` skipped, symlinks not followed, binary files (a NUL byte in the first 8 KB) skipped.

## Options

`-i` `-F` `-w` `-l` `-c` `-m N` `-g GLOB` (repeatable, `!GLOB` excludes) `-e PATTERN` `--hidden` `--no-index` `--trust-index` `-j N` `--stats`. `-n`, `-H`, `--no-heading` and `--color` are accepted and ignored. `trigrep --help` has the full list.

## Known differences from ripgrep

- `-i` and `(?i)` fold ASCII only, and `\w` counts every non-ASCII character as a word character (ripgrep uses Unicode tables), so a pattern like `\w+` can match a few more lines in text with non-ASCII symbols.
- No lookaround, backreferences, `\p{..}`, or non-ASCII ranges in classes (`[α-ω]`); these are rejected with an error rather than mis-matched.
- One PATH per search; no `--type`, context lines (`-A/-B/-C`), `-o`, `--json` or colour yet.
- Multi-line patterns aren't supported (matching is per line, like ripgrep's default).

## Next

- `trigrep watch`: FSEvents/inotify keeps a list of changed files, so searches skip the walk (target: Linux searches in tens of milliseconds without `--trust-index`).
- Incremental index updates instead of full rebuilds.
- `--json` output.
- Unicode classes, context lines, `-o`, `--type`.

## Building

Zig 0.15.1. `zig build -Doptimize=ReleaseFast` puts the binary in `zig-out/bin/trigrep`; `zig build test` runs the tests. No dependencies beyond the Zig standard library.

## License

MIT
