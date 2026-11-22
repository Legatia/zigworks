# harness gap 3: roles on files and the snapshot store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `folders.ini` gives workspace folders roles per who (read, write, run), checked by the gate before rules (a refusal is final); a folder's `vars` give host commands started there variables from stored secrets; `shell` takes a start folder `dir`; the Written list names who wrote each file; folders marked `snapshots` are snapshotted around the runs that change them, by hand and by the agent's `snapshot` tool, into one content-addressed store with a plain copy and one clone hook, listed, compared and restored by the owner. Without `folders.ini` (or with the comment-only one `harness init` writes) every decision, question, tool list and log line stays as today.

**Architecture:** `folders.zig` parses `folders.ini` and answers `allows`, `varsFor`, `view`. `gate.zig` gets `Gate.folders`, `Ctx.dir`, and the roles step after the hard limits (`Decision.role`, `Decision.dir`). `tools.zig` starts `shell` in its `dir` with `Env.vars`. `agent.zig` passes `dir`, resolves vars (host only), records who wrote each file, takes snapshots before a run's first change of a folder and when the run ends, and offers the `snapshot` tool. `snapshots.zig` is the store (`snapshots/` in the data folder): take, list, changes, restore, prune, objects copied or cloned through `CloneFn`. `core.zig` loads, guards and watches `folders.ini`, owns the store, and adds the chat commands; `main.zig` adds `harness snapshot`.

**Tech Stack:** Zig 0.17.1, std only.

**Spec:** `docs/superpowers/specs/2026-11-22-harness-file-roles-design.md`; the overview's Shared formats (Who, Rules, Secrets in commands, Snapshots) in `2026-11-22-harness-platform-overview.md`; the environments spec's Checkpoints and "What crosses into a sandbox".

## Global Constraints

- Zig 0.17.1, std only; macOS, Linux, Windows. At the end these compile: `zig build -Dtarget=x86_64-windows`, `-Dtarget=x86_64-linux-musl`, `-Dtarget=aarch64-linux-musl`, and `zig build unit-build -Dtarget=…` for each; `zig build test -Doptimize=ReleaseSafe` passes.
- No existing test is edited. Baseline: 408 pass, 2 skipped, `smoke: all ok`.
- Without `folders.ini`, or with one that has no section, behaviour is exactly as today: `Gate.folders` stays null, the shell schema has no `dir`, no `snapshot` tool, no snapshot is taken, no line changes.
- Who (phase 0): `Who{ agent, by, parent }`; a list allows a call when the origin (`by`) is `owner` or `schedule:…` and an entry matches it (then any definition passes); otherwise each of D, D1…Dk must match an `agent:` entry, and so must the origin unless it is `owner` or `schedule:…`. `agent = ""` is a call with no definition (an app's own call, gap 8): only the origin is checked.
- A role refusal is final: no rule, grant or answer lifts it, nothing is asked, it is not listed as skipped. Its reason says what to change: `folders.ini [work/shop] write: agent:researcher is not listed` (`folders.ini [private] read: none` for `none`).
- Secret values (vars) never in model requests, logs, test output or snapshots; vars only for `host` commands.
- Every new Core field is set in `Core.open`. Copy: plain labels, no slogans.
- Run tests from `harness/`: `export PATH=~/.local/zig/zig-aarch64-macos-0.17.1:$PATH; zig build test --summary all --cache-dir $SCRATCH/zcache > $SCRATCH/out/N.txt 2>&1` and read the tail; for one file's tests run the unit step (`zig build unit --summary all …`) and grep the test name.

## Rulings

1. **Written entries name who wrote them unless that is the asker.** What: a question lists `notes/a.md (agent:helper, chat/h1)` for files another definition or run label wrote, `notes/a.md` for files the asking call's own definition and run label wrote, `x.py (who unknown)` for a 0.3 line. Why: the spec's `PATH (WHO, RUN)` for every entry would change the question 0.3's tests pin (`…since you last allowed a command: pkg/__init__.py, conftest.py`) for the chat agent's own files; the asker is already named (`[chat/h1] shell: …`), so only other writers need naming. Cost if wrong: an owner who wants the writer on every entry gets it by dropping one comparison.
2. **Snapshot lines carry the file's modification time.** What: `sha256 TAB size TAB exec TAB mtime_ns TAB path` (the spec has four fields), skipped entries `- TAB WHY TAB path`, paths with `\`, tab, CR, LF escaped. Why: "hashed again only if its size or modification time changed" needs the last snapshot's mtime per file; a separate index would be a second file to keep in step. Cost if wrong: one more field to read; nothing else depends on the count.
3. **A section is a relative folder or `/`.** What: `[work/shop]`, `[./notes/]`, `[notes\sub]` (Windows) read like file paths; `[/etc]`, `[C:\x]`, `[a/../b]`, `[*]` are bad lines. Why: "written as file rules write paths (`work/shop`)"; an absolute path can't be checked against the workspace when the file is read, and quietly matching nothing is worse than naming the line. Calls may still name a file by its absolute path (Confined does that). Cost if wrong: an owner who writes the workspace's absolute path gets the line named and writes it relative.
4. **The `snapshot` tool and shell's `dir` are offered only when `folders.ini` has a section.** What: `Run.allows(.snapshot)` needs the store and a folders.ini with a section; the shell schema gets `dir` then too (a `dir` sent anyway is still confined and used). Why: the constraint that behaviour without folders.ini stays as today (tool list included), and snapshots are opt-in ("no disk is used unless a folder asks"). Cost if wrong: an owner must write one section before the agent can snapshot; gap 2 may also offer it where environments exist (for `env:NAME`).
5. **A delegated run shares its parent's snapshots.** What: the top-level run (a chat turn, task, brief) keeps the list of folders it snapshotted; its helpers' first change of a folder takes the "before" snapshot (with the helper's rid, run and agent) once for the whole run, and the "after" ones are taken when the top-level run ends. Why: helpers run at once on the same folders; per-helper before/after pairs would interleave and multiply snapshots. Cost if wrong: one helper's changes aren't a snapshot pair of their own (`/changes` shows the whole run).
6. **Over `snapshot_mb`, each folder keeps its newest snapshot.** What: prune drops the oldest snapshots (any folder) while the objects named exceed the cap, but never a folder's newest. Why: dropping the snapshot just taken would leave a run with nothing to restore. Cost if wrong: the store can exceed the cap by the newest snapshots of folders that alone exceed it (each is under 1 GiB by the folder limit).

## Review Focus

1. A role refusal is final: despite `allow write_file *`, a 24 h grant and an owner who would say yes, nothing is asked and a scheduled run lists nothing as skipped (Task 3, Task 4 tests).
2. Secret values from `vars` never reach the model, the log or a snapshot; they cross only into host commands; PATH, HOME, LANG, TERM and Windows's system variables can't be set in any case (Task 1, Task 4 tests).
3. An object's name is the hash of the bytes stored (clone then hash the clone; copy while hashing), never of bytes read earlier; prune never runs while a take is under way (one store mutex) (Task 6).
4. `/restore` never writes through a symbolic link (the file or a folder on the way), deletes only files that neither the restored snapshot keeps nor skipped, is refused while a run is going, and snapshots first so it can be undone (Task 6, Task 9).
5. Without folders.ini, or with `harness init`'s comment-only one, nothing changes: same decisions, no `dir` in the shell schema, no `snapshot` tool, no snapshots (Task 3 test, Task 4 test, whole suite).

## Files

- Create `harness/src/folders.zig` (parse, reasons, example, `allows`, `varsFor`, `view`, `sees`, text for `/folders` and `/access`), `harness/src/snapshots.zig` (the store, `CloneFn`).
- Modify `gate.zig` (Gate.folders, Ctx.dir, roles step, Decision.role/dir, realFolders), `tools.zig` (Env.vars, shell `dir`, mainArg `.snapshot`), `agent.zig` (dir, vars, Written writers, snapshots around runs, `snapshot` tool), `log.zig` (kind `files`), `config.zig` (`stripComment` pub, `[limits] snapshot_mb`), `core.zig` (Paths, init, settings, store, commands), `main.zig` (`harness snapshot`, vars secrets at open, test imports), `scripts/smoke.sh`, `harness/README.md`.

---

### Task 1: folders.ini read and checked

**Files:** Create `harness/src/folders.zig`; modify `config.zig` (`pub fn stripComment`), `core.zig` (`parseProblem` asks `folders.reason`), `main.zig` (test import).

**Interfaces — Produces:**
- `pub const Access = enum { read, write, run };`
- `pub const Var = struct { name: []const u8, secret: []const u8, section: []const u8 = "" };`
- `pub const Section = struct { name: []const u8, folder: []const u8, line: usize, read: ?[]const []const u8 = null, write: ?[]const []const u8 = null, run: ?[]const []const u8 = null, vars: []const Var = &.{}, snapshots: ?u32 = null, skip: []const []const u8 = &.{} };` — `name` the header as written, `folder` "" for `[/]` else `a/b`; `snapshots` null no key, 0 off, N keep N (`on` = `default_keep` = 50).
- `pub const Folders = struct { sections: []const Section = &.{} };`
- `pub const Error = error{ BadFolderName, DuplicateFolder, BadFolderKey, BadWhoList, BadVar, ReservedVar, BadSnapshots, NestedSnapshots, BadSkip, OutOfMemory };`
- `pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Folders` — own line loop (headers are checked where they stand) with `config.stripComment`; keys read, write, run (who lists: `who.isPattern` entries, or `none` alone), vars (`NAME:secret`, NAME `[A-Za-z_][A-Za-z0-9_]*`, secret `mcp.validSecretName`, reserved names refused in any case on every platform), snapshots (`on`, `off`, 1…10000), skip (patterns); each key once; a folder twice (case ignored on macOS and Windows) refused; a `snapshots` key in a folder inside one with snapshots set (on or a number) refused, in either order.
- `pub fn reason(e: anyerror) ?[]const u8` — a sentence per error above.
- `pub fn inFolder(rel: []const u8, folder: []const u8) bool` — `folder` "" holds everything; else `rel == folder` or `rel` starts with `folder/`; case ignored on macOS and Windows.
- `pub const example: []const u8` — init's comment-only file.

- [ ] **Step 1: Write the failing tests** in folders.zig:
  - `folders_ini_reads_sections_lists_vars_snapshots_and_skip`: the spec's example gives 4 sections: [0] name `/`, folder "", write `{agent:main, agent:coder}`, read null; [1] write `{owner, agent:researcher, app:notes}`; [2] folder `work/shop`, read `{agent:main, agent:coder}`, write `{agent:coder}`, run `{agent:coder}`, vars `STRIPE_KEY:stripe-test` and `DATABASE_URL:shop-db` with section `work/shop`, snapshots 50, skip `{node_modules, *.log}`; [3] read `{owner}`. `[./notes/]`, `[notes//sub/.]` give `notes`, `notes/sub`; `snapshots = 7` → 7, `off` → 0; `read = owner ; a comment` reads; on Windows `[notes\sub]` → `notes/sub`; `parse(example)` has no section.
  - `folders_ini_refuses_bad_lines`: BadFolderName for `[*]`, `[notes/*]`, `[../x]`, `[a/../b]`, `[/etc]`, `[]`, `[notes`, and `read = owner` before any section; DuplicateFolder for `[notes]`…`[./notes]` (and `[Notes]`…`[notes]` where case is ignored); BadFolderKey for `colour = red` and `read` twice; BadWhoList for `read = agnet:x`, `read = none, owner`, `read =`, `write = owner,`; BadVar for `vars = X`, `vars = 1X:y`, `vars = X:Upper`, `vars = X:a/b`; ReservedVar for `vars = PATH:x`, `path:x`, `HOME:x`, `LANG:x`, `TERM:x`, `SystemRoot:x`, `temp:x`; BadSnapshots for `snapshots = maybe`, `0`, `10001`; NestedSnapshots for `[work]\nsnapshots = on\n[work/shop]\nsnapshots = off` and the reverse order and `[/]\nsnapshots = 3\n[x]\nsnapshots = on`; BadSkip for `skip =`, `skip = a,,b`; `reason` non-null for each.
  - `in_folder_is_the_folder_or_below`: (`notes/a`,`notes`), (`notes`,`notes`), (`x/y`,``) true; (`notes2/a`,`notes`), (`note`,`notes`) false; (`Notes/a`,`notes`) true only where case is ignored.
  - core.zig `a_bad_folders_line_is_named`: `parseProblem(a, "folders.ini", "[notes]\nwrite = agnet:x\n", folders.parse)` starts with `folders.ini line 2 has an error: write = agnet:x (read, write and run list who may`; `"[/etc]\nread = owner\n"` starts with `folders.ini line 1 has an error: [/etc] (a section is a folder inside the workspace`.
- [ ] **Step 2:** run; expect compile errors (no folders.zig functions).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+4).
- [ ] **Step 5:** commit `harness folders: folders.ini read and checked (gap 3)`.

### Task 2: who may, the view and the variables

**Files:** Modify `harness/src/folders.zig`.

**Interfaces — Produces:**
- `pub fn allows(f: Folders, arena: std.mem.Allocator, real: ?[]const []const u8, rel: []const u8, access: Access, w: who.Who) ?[]const u8` — null when allowed; else the reason. The deciding section is the deepest one holding `rel` that has the key (`real[i]` is section i's folder as the gate reads it, else `folder`); none: no limit. Who order in the reason: D, then D1…Dk, then the origin.
- `pub const Mount = struct { folder: []const u8, access: enum { none, read, write } };`
- `pub fn view(f: Folders, arena: std.mem.Allocator, w: who.Who) ![]const Mount` — the workspace (`""`) and each section's folder, outermost first; write = may read and write, read = may read only, none otherwise (gap 2 mounts it, deeper entries over outer ones).
- `pub fn sees(mounts: []const Mount, rel: []const u8) bool` — the deepest entry holding `rel` is not none (no entry: false).
- `pub fn varsFor(f: Folders, arena: std.mem.Allocator, real: ?[]const []const u8, dir: []const u8) ![]const Var` — vars of every section holding `dir`, outermost first; a nearer one replaces a variable of the same name (case ignored on Windows).

- [ ] **Step 1: Write the failing tests** (Who values from who.zig):
  - `a_list_limits_only_its_access`: `[notes]\nwrite = agent:coder`: main reads `notes/a` (null), writes it (`folders.ini [notes] write: agent:main is not listed`), runs in `notes` (null); coder writes (null); `notes2/a` written by main (null).
  - `the_nearest_folder_with_the_key_wins`: `[/]\nwrite = agent:main\n[work]\nwrite = agent:coder\n[work/shop]\nread = owner, agent:main`: main writes `notes/x` (null), `work/shop/x` (`folders.ini [work] write: agent:main is not listed`); coder writes `work/shop/x` (null); a trigger run's main reads `work/shop/x` (`folders.ini [work/shop] read: trigger:mail is not listed`).
  - `none_refuses_every_run`: `[private]\nread = none`: main, coder, a schedule run, an app's own call: each `folders.ini [private] read: none`.
  - `every_definition_in_the_chain_must_be_listed`: `[notes]\nwrite = agent:helper`: main's helper → `… agent:main is not listed`; `write = agent:helper, agent:main` → null; `write = agent:*` → null.
  - `owner_listed_lets_its_runs_through`: `write = owner`: main's helper in an owner run → null; by `schedule:x` → `… agent:main is not listed`; `write = owner, schedule:*` → null for it; `read = agent:*` lets `schedule:x` through, not `trigger:mail` (`… trigger:mail is not listed`).
  - `trigger_workflow_and_app_origins_must_be_listed`: `write = agent:main`: by `trigger:mail` refused naming it; `write = agent:main, trigger:mail` null; by `workflow:release/draft` with entry `workflow:release` null, with `workflow:other` refused; an app's own call (`.agent = ""`, `.by = "app:notes"`) with `write = app:notes` null, with `write = agent:main` `… app:notes is not listed`.
  - `a_view_lists_what_a_who_may_mount`: `[/]\nwrite = agent:main\n[private]\nread = owner\n[shared]\nwrite = trigger:mail, agent:main`: for main by owner: `{"",write}`, `{private,write}`, `{shared,write}`; for main by `trigger:mail`: `{"",read}`, `{private,none}`, `{shared,write}`; `sees` true for `notes/a`, false for `private/k` (second view), true for `shared/x`.
  - `vars_come_from_every_folder_down_to_the_start_folder`: `[/]\nvars = A:a-all, B:b-all\n[work]\nvars = B:b-work\n[work/shop]\nvars = C:c-shop`: for `work/shop/src`: A a-all, B b-work, C c-shop (section `work` for B); for `notes`: A, B b-all; for ``: A, B b-all.
- [ ] **Step 2:** run; expect compile errors.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+8).
- [ ] **Step 5:** commit `harness folders: who may read, write and run; a who's view; a folder's variables (gap 3)`.

### Task 3: the gate's roles step and shell's start folder

**Files:** Modify `harness/src/gate.zig`.

**Interfaces — Consumes:** `folders.allows`. **Produces:**
- `Gate.folders: ?*const folders_mod.Folders = null` — folders.ini with a section; null: none.
- `Ctx.dir: []const u8 = ""` — shell's start folder as the model gave it; "" the workspace.
- `Decision.role: bool = false` (refused by folders.ini: final); `Decision.dir: []const u8 = ""` (shell's start folder inside the workspace, `/` between parts; "" the workspace).
- `pub fn realFolders(g: *const Gate, arena: std.mem.Allocator, f: *const folders_mod.Folders) []const []const u8` — each section's folder through `confined` (symbolic links followed), as written where that fails.
- `decideRaw` (with a `dir` out-parameter): hard limits, then for shell a non-empty `ctx.dir` confined like a file path (`dir is outside the workspace`), then the roles step: read_file needs read on the subject, write_file write, shell run on the start folder; a refusal returns deny with `role = true`.

- [ ] **Step 1: Write the failing tests** in gate.zig:
  - `no_folders_ini_keeps_every_0_3_decision`: rules `deny shell rm *\nallow fetch https://a.com/*\nask write_file secret/*\n` and a grant; for 12 calls (shell, read_file, write_file incl. `.npmrc` and `../x`, fetch, web, money, skill_save, with and without `.scheduled`) the action and why are the same with `folders = null` and with `folders` = `parse(folders.example)`.
  - `folders_match_like_file_rules`: `[notes]\nwrite = agent:coder`: main's write_file refused for `notes/a`, `./notes/a`, `x/../notes/a`, the workspace's absolute path of `notes/a`, (`NOTES/a` where case is ignored), (`notes\a` on Windows), and through a link `ws/short → notes/sub` (`short/x`, POSIX); allowed for `notes2/a`; a section naming a link (`[short]` with `short → notes`, POSIX) holds `notes/x`.
  - `a_role_refusal_is_final`: rules `allow write_file *`, a grant for `notes/a.md`, `[notes]\nwrite = agent:coder`: write_file `notes/a.md` is deny, `role`, why `folders.ini [notes] write: agent:main is not listed`; the same with `.scheduled = true`; read_file allow.
  - `shell_dir_is_confined_and_needs_run`: `ctx.dir = "../x"` → deny `dir is outside the workspace`; `[work]\nrun = agent:coder`: `ls` with dir `work` and `work/sub` deny (role); coder's allowed by rule `allow shell ls`; dir `./work/../notes` → ask with `dir` `notes`; no dir → ask, `dir` "".
- [ ] **Step 2:** run; expect compile errors (no `folders`, `dir`, `role`).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+4).
- [ ] **Step 5:** commit `harness gate: roles on folders before the rules; shell's start folder confined (gap 3)`.

### Task 4: shell's dir and a folder's variables in a run

**Files:** Modify `harness/src/tools.zig`, `harness/src/agent.zig`.

**Interfaces — Produces:**
- `tools.Env.vars: []const util.Var = &.{}` — set on the command after the system's and before PATH, HOME, LANG, TERM.
- `tools.shell` starts in the input's `dir` (confined; missing or "" the workspace; `not a folder in the workspace: DIR` when it is none).
- agent: `shell_dir_def` (shell's schema with `dir`) instead of shell's plain def when `r.gate.folders != null`.
- `fn decideAndAskIn(r, a, tool, name, arg, detail, dir: []const u8, now_s) !?[]const u8`; `decideAndAsk` keeps its signature and calls it with "". The question for a dir: `shell: make test (in work/shop)`; gate and tool lines of a call that named a dir carry `dir` (as given).
- `fn folderVars(r: *Run, a, env: []const u8, dir: []const u8) !VarsFor` (`VarsFor = union(enum) { vars: []const util.Var, missing: []const u8 }`): none unless `env` is `host`; values from the mask list by name, else from `r.store` (then added to the mask list, or to this call's secrets when there is none). A missing one refuses the call before it is asked (a `gate` deny line): `folders.ini [work] vars: secret NAME is not stored (harness secret add NAME)`.

- [ ] **Step 1: Write the failing tests** in agent.zig:
  - `a_role_refusal_is_final_and_nothing_is_asked`: rules `allow write_file *`, a 24 h grant for `notes/a.md`, folders `[notes]\nwrite = agent:coder`, `f.answer = .once`: the model writes `notes/a.md` → request 2 has `refused by the gate: folders.ini [notes] write: agent:main is not listed`; asked 0; the file is not there; with `scheduled = true` and a Skipped list, its text is "".
  - `shell_starts_in_its_dir_and_the_question_and_lines_name_it` (POSIX): folders `[/]\nread = owner`, `ws/work` made; the model runs `pwd` with dir `work` → asked `shell: pwd (in work)`; request 2 has `ws/work`; the log's gate and tool lines have `"dir":"work"`; request 1's shell schema has `"dir"`. Without folders (a second Fix): request 1 has no `"dir"`.
  - `folder_vars_reach_a_host_command_masked`: a dir store with `stripe-test` = `sk_test_51Hq3vY2eZvKYlo2C`; rules `allow shell *`; folders `[work]\nvars = STRIPE_KEY:stripe-test\n[work/x]\nvars = MISSING_KEY:nope`: `echo k=$STRIPE_KEY` (Windows `%STRIPE_KEY%`) with dir `work` → request has `k=[secret:stripe-test]`, no request or log line has the value; `echo k=$STRIPE_KEY.` without dir → `k=.`; dir `work/x` → `refused by the gate: folders.ini [work/x] vars: secret nope is not stored (harness secret add nope)`, not asked; `folderVars(&f.run, a, "box", "work")` is empty.
- [ ] **Step 2:** run; expect failures (no dir in the schema, no vars).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+4: the schema without folders is a test of its own, `without_folders_ini_shell_offers_no_dir`).
- [ ] **Step 5:** commit `harness: shell starts in its dir; a folder's vars reach host commands, masked (gap 3)`.

### Task 5: the Written list names who wrote each file

**Files:** Modify `harness/src/agent.zig`.

**Interfaces — Produces:**
- `Written.Entry` gains `writer: []u8` (`WHO RUN`; "" for a 0.3 line).
- `pub fn addBy(w: *Written, rel: []const u8, who: []const u8, run: []const u8) void`; `add(rel)` = `addBy(rel, "", "")`.
- `pub const Writer = struct { who: []const u8, run: []const u8 };`
- `pub fn listFor(w: *Written, arena, asker: ?Writer, view: ?[]const folders.Mount) !?Listed` — Ruling 1's display; entries `view` doesn't see are left out (gap 2's networked sandbox); `list(arena)` = `listFor(arena, null, null)`.
- `state/written`: first line `# harness written 2: …`, then `PATH<TAB>WHO RUN` with `\`, tab, CR, LF escaped, and `/more N`; a file without the first line is 0.3's (a path a line).
- callToolRaw: `addBy(rel, "agent:" ++ D, r.label)`; decideAndAskIn lists for `{ agent:D, r.label }`.

- [ ] **Step 1: Write the failing tests:**
  - `written_entries_name_who_wrote_them`: a Written kept in a file: `addBy("notes/a.md","agent:helper","chat/h1")`, `addBy("b.py","agent:main","chat")`, `addBy("odd\tname\n.txt","agent:main","task build")`; `listFor` for `{agent:main, chat}` is `notes/a.md (agent:helper, chat/h1), b.py, odd?name?.txt (agent:main, task build)`; a new Written from the file says the same; a 0.3 file `x.py\nold dir/y.txt\n/more 2\n` lists `x.py (who unknown), old dir/y.txt (who unknown) and 2 more`.
  - `a_networked_sandbox_is_asked_only_about_files_it_can_see`: entries `private/k`, `notes/a`; view `{"",read}`, `{private,none}` → `notes/a (…)` only; view `{"",none}` → null.
  - `a_helpers_write_is_named_in_the_next_question`: rules `allow shell echo *`; main delegates a write_file task, the helper writes `notes/h.md`, main runs `echo x` → asked once, the question ends `…since you last allowed a command: notes/h.md (agent:helper, chat/h1)`.
- [ ] **Step 2:** run; expect compile errors (`addBy`, `listFor`).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+3); the two 0.3 Written tests pass unchanged.
- [ ] **Step 5:** commit `harness: the Written list names who wrote each file (gap 3)`.

### Task 6: the snapshot store

**Files:** Create `harness/src/snapshots.zig`; modify `log.zig` (`Kind.files`), `main.zig` (test import).

**Interfaces — Produces:**
- `pub const CloneFn = *const fn (io: Io, src: []const u8, dst: []const u8) anyerror!bool;` — makes `dst` (new) share `src`'s blocks; false where the file system can't (then the store copies). `pub const platform_clone: ?CloneFn = null;` — the per-file-system helpers (APFS, btrfs and XFS, ReFS and Dev Drives) plug in here.
- `pub const Skip = struct { under: []const u8, pattern: []const u8 };` and `pub fn skipsFor(f: folders.Folders, arena, folder: []const u8) ![]const Skip` — each section's `skip` holding or inside `folder`; a pattern matches an entry's name or its path from `under`.
- `pub const Source = struct { name: []const u8, path: []const u8, skip: []const Skip = &.{} };` — `/`, `work/shop` or `env:NAME`, its absolute path.
- `pub const When = enum { before, after, hand, tool };` `pub const By = struct { rid: u64 = 0, run: []const u8 = "", agent: []const u8 = "", by: []const u8 = "owner" };`
- `pub const Store = struct { gpa, io, dir, log: ?*log.Log = null, clone: ?CloneFn = platform_clone, total_mb: u32 = 5120, max_files: u32 = 20_000, max_bytes: u64 = 1 << 30, max_file: u64 = 100 << 20, mutex, refused (folder → why) }` with:
  - `take(s, arena, src, opts: Take) !Taken` (`Take = { when, label = "", by = .{}, must_exist = false }`; `Taken = { id, files, changed, bytes, refused: ?[]const u8 }`): walks without following links; `.git` folders, skip matches, links, files over `max_file` and other kinds named as skipped; over `max_files` or `max_bytes`: none (`refused`, logged `snapshot skipped`, kept for `/status`); a file is hashed again only if its size or mtime differ from the last snapshot's or its mtime is within 2 s of that snapshot's time; new content goes to `objects/ab/<sha256>` by `clone` then hashing the clone, else by copying while hashing, through a temporary name; the snapshot file is written whole then renamed to `folders/<key>/<id>` (`key` = first 16 hex of SHA-256 of the name, case-folded where volumes ignore case; `id` = last + 1); logs `files` `snapshot`.
  - `list(s, arena, name) ![]const Info` (`Info = { id, time, when, label, run, agent, by, files, changed }`), `folders(s, arena) ![]const []const u8`.
  - `changes(s, arena, name, id) !Changes` (`{ before: ?u64, added, changed, removed: []const []const u8 }`).
  - `restore(s, arena, src, id, by) !Restored` (`{ before_id, written, deleted, failed: []const Failed }`): takes a `hand` snapshot first (none possible: `error.CannotUndo`), deletes the files it has that the target neither keeps nor skipped, writes back each target file missing or different, in place (no rename), a link at the path replaced, never through a link on the way (named `a symbolic link on the way`), exec bit as kept; a file that can't be written is named and the rest go on; logs `files` `restore`.
  - `prune(s, arena, f: ?*const folders.Folders) !Pruned`: per folder the newest N (its section's `snapshots`, else 50), then the oldest while the objects named exceed `total_mb` (each folder's newest kept), then objects and temporary files nothing names; logs `files` `prune` when it deleted any.
  - `note(s, arena) ![]const u8` — `work/shop: none (over 20000 files)` lines for `/status`.

- [ ] **Step 1: Write the failing tests** in snapshots.zig (a tmp folder `src`, a store in `store`, a log):
  - `a_snapshot_keeps_each_content_once_and_unchanged_files_are_not_stored_again`: `a.txt` = `x`, `b/c.txt` = `x`, `d.sh` executable (POSIX): take → id 1, files 3, one object for `x`; take again → id 2, changed 0, bytes 0, same object count; list gives ids 1 and 2, `when` hand, label kept; the snapshot file's lines are `sha256\tsize\texec\tmtime\tpath`; the log has `"kind":"files","event":"snapshot","folder":"src","id":1,"when":"hand"`.
  - `the_2_s_rule`: write `n.txt` = `old`; take; rewrite `new` with the same mtime → taken again, the new hash recorded; set mtime 100 s back, take; rewrite `xyz` keeping size and that mtime → take keeps the old hash (not read again).
  - `skipped_files_are_named_and_a_huge_folder_gets_none`: `.git/config`, `node_modules/m.js`, `logs/a.log`, a link (POSIX), `big.bin` over `max_file = 8`, `keep.txt`; skips `node_modules`, `*.log`: files 1 and `-\tgit\t.git`, `-\tskip\tnode_modules`, `-\tskip\tlogs/a.log`, `-\tlink\tl`, `-\tbig\tbig.bin` in the file; with `max_files = 1` and two files: `refused` `over 1 files`, no new id, `note` has `src: none (over 1 files)`, the log `snapshot skipped`; a later good take clears the note.
  - `old_snapshots_and_their_objects_are_deleted`: folders `[src]\nsnapshots = 2`: three takes of different content; prune → ids 2 and 3 left, the first content's object gone, a stray temporary file gone, the log `prune` with `snapshots` 1; with `total_mb = 0` the oldest go but each folder's newest stays.
  - `restore_puts_back_deletes_added_files_and_can_be_undone`: take (`a` = 1, `b` = 2); then `a` = 9, `b` deleted, `c` added, `logs/x.log` skipped added; restore 1 → `a` = 1, `b` = 2, `c` gone, `logs/x.log` still there; written `{a, b}`, deleted `{c}`, before_id 2; restore 2 → `a` = 9, `c` back, `b` gone; the log `restore` lines.
  - `restore_never_writes_through_a_symbolic_link` (POSIX): take with `d/f` = 1; replace `d` with a link to an outside folder; restore → `f` not written outside, failed names `d/f`; a link at `g` where the snapshot had a file `g` is replaced by the file.
  - `objects_are_cloned_where_the_file_system_can`: a stand-in `CloneFn` that copies and counts: take stores through it (count = new objects); one that returns false: the copy is used; restored files match in both.
  - `changes_lists_added_changed_and_removed`: ids 1 (`a`, `b`), 2 (`a` changed, `b` gone, `c` new): changes 2 → before 1, added `{c}`, changed `{a}`, removed `{b}`; changes 1 → before null, added `{a, b}`.
- [ ] **Step 2:** run; expect compile errors.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+8).
- [ ] **Step 5:** commit `harness snapshots: the store, objects copied or cloned, list, changes, restore, prune (gap 3)`.

### Task 7: snapshots around runs, and the snapshot tool

**Files:** Modify `harness/src/agent.zig`, `harness/src/tools.zig` (`mainArg(.snapshot)` = `folder`).

**Interfaces — Produces:**
- `Run.snaps: ?*snapshots.Store = null`; `Run.snap_run: ?*SnapRun = null` (shared by a run and its helpers, Ruling 5).
- `pub const SnapRun = struct { gpa, mutex, taken: std.ArrayList([]u8) }` — folders snapshotted "before" in this run.
- Before a write_file in a folder with `snapshots`, or any shell call, once allowed: a `before` snapshot of each such folder not yet taken in the run (under SnapRun's lock, so a helper's change waits for it). At the end of the top-level `turn`: an `after` snapshot of each, then `prune`.
- `snapshot` tool (`folder`, `label`), offered when `r.snaps != null and r.gate.folders != null` (Ruling 4): a workspace folder (confined) or `env:NAME` (`state/env/NAME/home`); `when` tool; gate kind `snapshot`, argument the folder (default allow). No tool restores.

- [ ] **Step 1: Write the failing tests** in agent.zig:
  - `a_snapshot_is_taken_before_the_first_change_and_at_the_end`: folders `[notes]\nsnapshots = on`, `notes/old.txt`; rules `allow shell echo *`; the model writes `notes/a.txt`, writes `notes/b.txt`, runs `echo hi`, answers → 2 snapshots of `notes`: 1 `before` with `old.txt` only, 2 `after` with 3 files, run `chat`, agent main, by owner; the log has `"event":"snapshot","folder":"notes","id":1,"when":"before"` before the first write's tool line. A turn with no change takes none.
  - `the_snapshot_tool_takes_one_with_its_label`: folders `[notes]\nread = owner`; the tool for `notes` with label `before the edit` → `when` tool and the label in the list; for `env:box` with `state/env/box/home/h.txt` → one snapshot of `env:box`; for `env:nobox` → an error result; request 1 offers `snapshot`; a call to `restore` is `no such tool`; without folders (another Fix) `snapshot` is not offered.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+2).
- [ ] **Step 5:** commit `harness: snapshots before a run's first change and at its end; the snapshot tool (gap 3)`.

### Task 8: folders.ini in the instance

**Files:** Modify `harness/src/core.zig`, `harness/src/main.zig`, `harness/src/folders.zig` (`render`, `accessText`).

**Interfaces — Produces:**
- `Paths.folders` (`folders.ini`), `Paths.snapshots` (`snapshots`); `initHome` writes `folders.example` (0600).
- `guardedFiles` → 5 (folders.ini too), `settingsFiles` → 7; `loadSettings` parses folders.ini into `Core.folder_list` and points `gate.folders` at it when it has a section; `reload` keeps the old one on error; `settingsProblem` names its bad line; the messages that list the settings files name folders.ini.
- `folders.render(f, arena) ![]const u8` (`/folders`: a line a section, variable and secret names, never values); `folders.accessText(f, arena, real, w, label) ![]const u8` (`/access WHO [ORIGIN]`: `FOLDER: read, write, run` or `nothing` for `/` and each section).
- main.zig `namedSecrets` also reads the secrets folders.ini's vars name, so they are masked from the start.

- [ ] **Step 1: Write the failing tests** in core.zig:
  - `folders_ini_is_guarded_watched_and_applied_on_reload` (permissions part POSIX): init wrote a comment-only folders.ini and `gate.folders` is null; folders.ini `[notes]\nwrite = agent:coder\n` at 0644 → `/reload` says `Settings reloaded.`, `/folders` says `[notes] write = agent:coder`, `gate.folders` set; at 0666 → `/reload` says `folders.ini can be changed by other users`; a bad line → `folders.ini line 2 has an error`; the old roles stay.
  - `access_says_what_a_who_may_read_write_and_run`: `[/]\nwrite = agent:main\n[private]\nread = owner\n`: `/access agent:helper` → `/: read, run` and `private: read, run`; `/access trigger:mail` → `private: run`; `/access agent:x:y` → a usage line.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+2).
- [ ] **Step 5:** commit `harness: folders.ini guarded, watched and applied; /folders and /access (gap 3)`.

### Task 9: snapshots in the instance: commands, CLI, limits

**Files:** Modify `harness/src/core.zig`, `harness/src/main.zig`, `harness/src/config.zig`.

**Interfaces — Produces:**
- `[limits] snapshot_mb = 5120` (config.zig and init's config.ini).
- `Core.snaps: snapshots.Store` (set in `open`, `log = &c.log`, `total_mb` from config, refreshed on `/reload`); pruned at start when `snapshots/` exists; `baseRun` passes `.snaps`.
- Commands: `/snapshots [FOLDER]`, `/snapshot FOLDER [LABEL]`, `/changes FOLDER ID`, `/restore FOLDER ID` (refused while a run is going); `/status` adds the store's note; help lines.
- CLI: `harness snapshot list FOLDER | take FOLDER [LABEL] | changes FOLDER ID | restore FOLDER ID` through `Core.command`, as `harness memory`.

- [ ] **Step 1: Write the failing tests:**
  - core.zig `snapshots_by_hand_changes_and_restore_from_the_chat`: `ws/notes/a.md` = `one`: `/snapshot notes first` → `Snapshot 1 of notes: 1 file.`; `a.md` = `two`, `b.md` added; `/snapshot notes` → 2; `/snapshots notes` lists `1` with `first` and `2`; `/changes notes 2` → `Since 1: added b.md; changed a.md.`; `busy` set → `/restore notes 1` refused (`a run is going`); cleared → `Restored notes to 1: wrote a.md; deleted b.md. /restore notes 3 undoes it.` and the files say so; `/snapshot nosuch` → `No folder nosuch in the workspace.`; `/restore notes 99` → `No snapshot 99 of notes.`
  - core.zig `a_folder_too_big_for_snapshots_is_said_in_status`: `snaps.max_files = 1`, two files: `/snapshot notes` → `No snapshot of notes: over 1 files.`; `/status` has `Snapshots: notes: none (over 1 files)`.
  - main.zig `extra_or_unknown_arguments_are_refused` (unchanged) passes, and `snapshot_arguments_are_checked`: refused `{snapshot}`, `{snapshot,list}`, `{snapshot,take}`, `{snapshot,changes,n}`, `{snapshot,restore,n,1,x}`, `{snapshot,drop,n}`; accepted `{snapshot,list,n}`, `{snapshot,take,n}`, `{snapshot,take,n,a,label}`, `{snapshot,changes,n,2}`, `{snapshot,restore,n,1}`.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+3).
- [ ] **Step 5:** commit `harness: snapshots from the chat and the CLI; snapshot_mb; /status says why a folder has none (gap 3)`.

### Task 10: smoke, README, final checks

**Files:** Modify `harness/scripts/smoke.sh`, `harness/README.md`.

- [ ] **Step 1:** smoke.sh, after the dry-run part: folders.ini `[notes]\nwrite = agent:main\nsnapshots = on` (0600), `/reload`; the agent delegates a write in notes (refused: `refused by the gate: folders.ini [notes] write: agent:helper is not listed` in the helper's next request), then writes `notes/a.md` itself; `/snapshots notes` lists the run's before and after; `/changes notes 2` says `added a.md`; `/restore notes 1` deletes `notes/a.md` and says `/restore notes 3 undoes it`; after the run ends: `harness snapshot list notes` works offline. `log verify` (as today) at the end.
- [ ] **Step 2:** README: the data folder (folders.ini, snapshots/), guarded files, the gate's order (roles second), a "Folders" section (roles, who lists, nearest folder, none, the reason, `dir`, vars, snapshots, restore, commands, `[limits] snapshot_mb`), the Written list's who, the log (`files` kind, shell lines' `dir`), commands and CLI.
- [ ] **Step 3:** `zig build test --summary all` and `zig build test -Doptimize=ReleaseSafe --summary all`: all pass, smoke all ok; cross builds and `unit-build` for the three targets.
- [ ] **Step 4:** commit `harness README and smoke: folders.ini, shell's dir, vars, snapshots (gap 3)`.

## For the environments and agents builders

- `folders.view(f, arena, who)` lists `{folder, none|read|write}` for the workspace and each section, outermost first; a sandbox mounts them in that order, deeper entries over outer ones, and starts in the call's `Decision.dir`. `folders.sees(view, rel)` is what `Written.listFor(…, view)` uses for a networked sandbox.
- `agent.folderVars(r, a, env, dir)` gives nothing unless `env` is `host`: no secret crosses into a sandbox or a remote.
- Checkpoints are `snapshots.Store.take(arena, .{ .name = "env:NAME", .path = …/state/env/NAME/home }, .{ .when = .tool })`; `/snapshot env:NAME` and `/restore env:NAME ID` already resolve `state/env/NAME/home`. Clone helpers plug in as `snapshots.platform_clone` (a `CloneFn`: return false where the file system can't clone; the store hashes the clone it made, so a helper never needs to hash).
- Gap 1: `who.Who.agent` is the definition; folders.ini's `agent:NAME` entries already apply to any name; a definition's own state folder is a section it alone may write. Gap 8: an app's own call is `Who{ .agent = "", .by = "app:NAME" }`; `Written.addBy(rel, "app:NAME", "")`.
