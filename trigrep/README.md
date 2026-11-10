# trigrep

Indexed code search for large repositories and coding agents. ripgrep-compatible output, a trigram index so a search only reads files that can match, and a freshness check so edits since indexing are never missed.

```sh
trigrep spin_lock_irqsave            # first run in a repo builds the index
trigrep -i 'todo|fixme' src/
trigrep -w mutex_lock -t c -C 2     # C files only, 2 lines of context
trigrep -o 'EXPORT_SYMBOL\w*'       # print only the matched text
trigrep --json 'fo+' src/            # ripgrep's JSON Lines format
trigrep index                        # rebuild from scratch
trigrep index --update               # re-index only files that changed
trigrep status                       # how many files changed since indexing
trigrep watch &                      # optional: searches skip the freshness walk
```

Output is `path:line:text`, like `rg -n --no-heading`. Exit status is 0 if something matched, 1 if not, 2 on error.

## MCP server

`trigrep mcp` speaks the Model Context Protocol over stdio, so agents can call it as a tool. To register it with Claude Code:

```sh
claude mcp add trigrep -- /absolute/path/to/trigrep mcp
```

Tools:

- `trigrep_search` takes `pattern`, plus optional `path`, `ignore_case`, `fixed_strings`, `word`, `glob` (array), `output` (`lines`, `files` or `count`), `max_results` (default 200), `max_per_file`, `context` (lines around each match), `type` (array of file types, e.g. `["rust"]`) and `only_matching`. It returns `path:line:text` lines, and says so when it stopped at `max_results`.
- `trigrep_index` rebuilds the index for `path`.
- `trigrep_status` shows the index and how many files changed since it was built.

Paths are relative to the server's working directory, which is the project when Claude Code starts it. A bad pattern comes back as a tool error with the reason.

The MCP server watches every repository it has searched (see below), so after the first search in a repo, later searches cost tens of milliseconds and still see every edit, including files written a moment before the search.

## Standing in for ripgrep

Coding agents already search with ripgrep (Claude Code's Grep tool runs `rg`), and in tests they rarely pick an extra search tool on their own. So trigrep can also answer as `rg`:

```sh
trigrep install-rg-shim              # creates ~/.local/share/trigrep/bin/rg -> trigrep
USE_BUILTIN_RIPGREP=0 PATH="$HOME/.local/share/trigrep/bin:$PATH" claude
```

Invoked as `rg`, trigrep handles the searches it can reproduce exactly (Claude Code's `-l --null`, `--json -n`, `-c -H --null`, context, `--glob`, `--max-columns`, `-i/-w/-F/-o/-m/-t`) and hands everything else to the real ripgrep, which must be on PATH (or set `TRIGREP_REAL_RG`). It stays out of the way where ripgrep is already fast:

- No index yet: the real ripgrep answers. If that took 300 ms or more (`TRIGREP_RG_MIN_MS`), an index is built in the background for next time.
- A search in a subtree with fewer than 3,000 indexed files (`TRIGREP_RG_MIN_FILES`), or of a single file, goes to ripgrep.
- Otherwise trigrep searches, and starts `trigrep watch --idle-exit 30` for the repository if none is running, so later searches skip the freshness walk. The watcher exits after 30 minutes without queries.
- Any error before output is written falls back to ripgrep.

On a 389k-file monorepo (four Linux trees), Claude Code-style searches gave output identical to ripgrep 15.2 (sorted lines, JSON records, exit codes) and took 0.05–0.84 s instead of 2.9–10.6 s. Running Claude Code (Sonnet) on four code-exploration tasks there, 3 runs each, total search time went from 38.8 s to 7.3 s. End-to-end time fell 7% on average and 20% on the most search-heavy task, because most of an agent's time is spent in the model. On the Linux kernel alone (97k files), end-to-end time didn't change.

## Keeping the index current

The index has a base and a small *delta*: files that changed, appeared or were deleted since the base was built. A search that finds 300 or more changed files folds them into the delta afterwards (on the Linux kernel, 500 changed files took 84 ms), so the next search uses the index for them again instead of reading them all. `trigrep index --update` does the same on demand. When the delta would hold more than a quarter of the files, the base is rebuilt instead.

## Watching

`trigrep watch [PATH]` keeps a list of files changed since indexing, from FSEvents (macOS) or inotify (Linux), and serves it over a Unix socket in `/tmp/trigrep-$UID/`. While it runs, searches under that root re-check only those files instead of walking the whole tree. It updates the index delta on its own after a burst of 300 or more changes (a branch switch, say) once things are quiet for a second. `trigrep mcp` does the same in-process.

Results stay correct when the watcher can't vouch for its list: dropped events, a changed `.gitignore`, an index rebuilt by someone else, or a filesystem without events all make the next search walk the tree and re-seed the watcher. On macOS, each search first writes a cookie file (in `.git` when there is one) and waits for its event, as Watchman does, so an edit made just before the search is never missed. On Linux, inotify queues events synchronously, so draining the queue is enough.

## Benchmarks

Apple M-series, 10 cores, warm page cache, median of 5 runs, wall time including process start. Results are byte-identical to ripgrep 15.2 for every pattern below (`scripts/compare.sh`).

Linux kernel (96,771 files, 1.7 GB; index 146 MB, built in 4.5 s). ripgrep varied between 1.4 and 1.8 s across runs; the column is from the same run as the `watch` column:

| pattern | rg | trigrep | trigrep with `watch` | `--trust-index` |
|---|---:|---:|---:|---:|
| `spin_lock_irqsave` | 1432 ms | 200 ms | 45 ms | 26 ms |
| `EXPORT_SYMBOL_GPL\(kmalloc` | 1434 ms | 131 ms | 12 ms | 4 ms |
| `zzzqqqxxx` (no match) | 1406 ms | 133 ms | 12 ms | 3 ms |
| `^static int __init \w+_init\(void\)` | 1464 ms | 183 ms | 55 ms | 38 ms |
| `TODO\|FIXME\|XXX` | 1388 ms | 370 ms | 160 ms | 141 ms |
| `struct \w+_ops \w+ = \{` | 1625 ms | 280 ms | 135 ms | 118 ms |

Zig standard library (18,100 files, 171 MB; index 20 MB, built in 0.7 s):

| pattern | rg | trigrep | trigrep --trust-index |
|---|---:|---:|---:|
| `ArrayList` | 189 ms | 31 ms | 8 ms |
| `pub fn \w+\(self` | 199 ms | 29 ms | 5 ms |
| `TODO\|FIXME` | 187 ms | 41 ms | 17 ms |
| `\w+_\w+_\w+` (no literal to index) | 274 ms | 232 ms | 215 ms |

Without a watcher, about 130 ms of each search is the freshness check (walking and stat-ing every file). `trigrep watch` replaces it with a ~10 ms query and stays correct; `--trust-index` skips it entirely and is only safe right after `trigrep index`.

Reproduce: `zig build -Doptimize=ReleaseFast`, then `python3 scripts/bench.py DIR PATTERN...` and `scripts/compare.sh DIR PATTERN [flags]`.

## How it works

- **Index.** Every distinct trigram (3 bytes, ASCII-lowercased, never spanning a newline) of every text file, with a posting list of file ids (varint deltas). One file per indexed root under `$TRIGREP_INDEX_DIR`, `$XDG_CACHE_HOME/trigrep` or `~/.cache/trigrep`, read through mmap.
- **Query.** The regex is parsed and turned into a trigram query (AND within literals, OR across alternation, nothing for optional parts), as in Russ Cox's [codesearch](https://swtch.com/~rsc/regexp/regexp4.html). Lowercased trigrams mean one index serves case-sensitive and `-i` searches.
- **Freshness.** Before searching, trigrep asks the watcher for changed paths, or, without one, walks the tree (in parallel, honouring ignore files) and compares sizes and mtimes with the index. Changed and new files are searched directly; deleted ones are dropped. Results are always correct, the index only decides how much has to be read.
- **Matching.** Its own regex engine (Zig's standard library has none): a parser, a Thompson NFA, a lazy DFA, and a Pike VM fallback for word boundaries. A required literal from the query (or a set of literals for alternations) skips straight to candidate lines.
- **Walking.** ripgrep's defaults: `.gitignore`, `.ignore` and `.git/info/exclude` are honoured, hidden files and `.git` skipped, symlinks not followed, binary files (a NUL byte in the first 8 KB) skipped.

## Options

`-i` `-F` `-w` `-l` `-c` `-o` `-m N` `-A N` `-B N` `-C N` `-t TYPE` `-T TYPE` `--type-list` `--json` `-g GLOB` (repeatable, `!GLOB` excludes) `-e PATTERN` `--hidden` `--no-index` `--trust-index` `-j N` `--stats`. `-n`, `-H`, `--no-heading` and `--color` are accepted and ignored. `trigrep --help` has the full list.

## Known differences from ripgrep

- `\w`, `\d`, `\s`, `\b`, `.` and classes like `[α-ω]` are Unicode-aware (tables generated from Unicode 16 by `scripts/gen_unicode.py`), and `-i` folds non-ASCII letters (`É` matches `é`, `Σ` matches `σ`). ASCII letters fold only to ASCII, so `-i k` doesn't match the Kelvin sign `K`; ripgrep's does. This keeps `-i` searches on the fast literal path.
- No lookaround, backreferences or `\p{..}`; these are rejected with an error rather than mis-matched.
- One PATH per search; no colour or `--sort` options.
- Patterns with no literal of three or more bytes (e.g. `\d{4}-\d{2}-\d{2}`) can't use the index and scan every file; there trigrep is about as fast as ripgrep (0.8–1.2× on the Zig standard library), not faster.
- Multi-line patterns aren't supported (matching is per line, like ripgrep's default).

## Next

- Faster scans for patterns the index can't narrow (a reverse-DFA "inner literal" search, as ripgrep's regex engine does).
- Multiple PATH arguments.

## Building

Zig 0.15.1. `zig build -Doptimize=ReleaseFast` puts the binary in `zig-out/bin/trigrep`; `zig build test` runs the tests. No dependencies beyond the Zig standard library and libc (and CoreServices on macOS, for FSEvents).

## License

MIT
