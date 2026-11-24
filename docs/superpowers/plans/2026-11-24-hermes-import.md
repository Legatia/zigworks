# harness: importing a Hermes setup, and `harness skill` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `harness import hermes [--from DIR] [--profile NAME] [--dry-run] [--yes] [--bundled]` reads a Hermes v0.23.4 home and brings over memory, `SOUL.md`, user skills, cron jobs, MCP servers, deny patterns and the model, writing only what maps (narrowing, never widening), copying every harness file it changes first and leaving a report; `harness skill add|list|show|update|rm` installs agentskills.io skills from a folder, a GitHub repo (codeload tar.gz, pinned to the archive's commit) or a link to a `SKILL.md`, keeping each one's source and hash.

**Architecture:** New files hold the work: `yaml.zig` (the block subset Hermes writes), `zones.zig` (an IANA zone's offset on a day, from TZif files and their POSIX footer), `hermes.zig` (finding and reading a Hermes home into a `Setup`), `hermes_import.zig` (the plan, its text, writing it, the report, the command), `targz.zig` (gzip + tar reading with limits and the pax commit; a stored-deflate writer for tests and harness-fake), `skillsrc.zig` (shared by both commands: `skills/.sources`, a skill's hash, frontmatter facts, installing a folder), `skill_cmd.zig` (the `harness skill` commands), `taskfiles.zig` (`do_file` and the guarded `tasks/` folder). Small local edits: `main.zig` (dispatch, usage, init's notice), `mcp.zig` (`env =`), `triggers.zig`/`config.zig` (`do_file`), `core.zig` (two hook lines in settings loading, one in MCP start, `Paths.tasks_dir`), `skills.zig` (a closing fence with trailing spaces), `memory.zig` (one read-only `repeatOf`), `fake.zig` (a codeload route), `fake_mcp.zig` (echo of a plain env value), `smoke.sh` (one block of its own).

**Tech Stack:** Zig 0.17.1, std only (`std.json`, `std.tar`, `std.compress.flate`, `std.tz`, `std.crypto.hash`); macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-hermes-import-design.md` (binding; its "Calls I made" are decided, its tables are the expected outcomes). Hermes's own source at v0.23.4 for shapes: `cron/jobs.py`, `tools/memory_tool_store.py`, `hermes_cli/default_soul.py`, `hermes_cli/config_defaults.py`, `hermes_cli/config_providers.py`, `tools/skills_hub*.py`, `tools/skills_sync.py`, `tools/mcp_tool_registration.py`, `tools/mcp_tool_common.py`, `tools/cronjob_tools.py`, `hermes_constants.py`, `agent/skill_utils.py`, `tools/skills_tool_setup.py`.

## Global Constraints

- Another builder (`platform/inject`) works at the same time on gate.zig, agent.zig's call path, core.zig's memory writer, conversations' state, telegram.zig, smoke.sh, README, the gaps list, the ledger and HANDOFF's top: code in new files; edits to main.zig, config.zig, core.zig, mcp.zig, skills.zig small and local; smoke checks in one block of their own; README section "Coming from Hermes" of its own; docs appended, not rewritten.
- No secret is copied, printed or logged: fixtures use obvious fakes (`sk-fixture-…`); every import and skill test checks no fixture secret value appears in any harness file, the output or the log. The real `~/.hermes` and the owner's harness folder are never read.
- An import narrows, never widens: deny patterns and excluded tools become deny rules; `command_allowlist` becomes a suggestions file of commented lines; `allowed-tools` is shown and ignored.
- Copy (CLAUDE.md): plain labels, sentence case, short lines, no slogans.
- Files written whole (`util.writeReplace`); settings files 0600; `tasks/` and `skills/` created 0700 like `workflows/`; harness's own memory store API for items.
- Windows: Hermes's home is `%LOCALAPPDATA%\hermes`; joined paths `std.fs.path.sep_str` in tests; dirs that are listed opened `.iterate = true`; no executable bit; the tar reader refuses names Windows can't hold; text reads the same with `\r\n`; POSIX-only tests skip on Windows.
- Baseline: harness 1198 pass, 22 skipped (unit binary run directly); smoke 109 (142 with the stand-ins). Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc > FILE 2>&1`, `-Dtest-filter=NAME` while iterating, Debug and ReleaseSafe, with and without `HOMEMCP_BIN`, `CARCLOUD_BIN`, `CALMCP_BIN`, `MAILMCP_BIN`; cross builds (`zig build` and `unit-build`, x86_64-windows, x86_64-linux-musl, aarch64-linux-musl) into scratch.

## Review Focus

The inputs most likely to bite someone switching, each pinned by a test in the task that owns it:

1. **A secret in an unexpected place**: a literal key in an MCP server's `env`, a `headers` value, a provider's `api_key`, a memory entry or a cron prompt holding a `.env` value. Nothing of it reaches a harness file, the plan, the report or the log (masked as `[secret:NAME]` in text the owner should see). (`no_secret_value_reaches_any_file_output_or_log`, Task 6.)
2. **A prompt `tasks.ini` would cut**: a prompt with ` ;`, ` #`, a newline, or leading spaces. It goes whole into `tasks/NAME.md`, and the task run sends it whole. (`a_prompt_tasks_ini_would_cut_goes_to_its_own_file`, Task 5; `a_task_with_do_file_runs_its_file`, Task 1.)
3. **An `at` time across midnight**: a job at 00:30 in UTC+2 for a harness at +00:00 becomes 22:30 the day before, and its days move with it. (`a_converted_time_moves_its_days`, Task 5.)
4. **Running the import twice, or while `harness run` holds the folder**: nothing is added twice; a real import refuses while harness runs, `--dry-run` works. (`running_it_again_adds_nothing_twice`, `the_import_refuses_while_harness_runs_but_dry_run_works`, Task 6.)
5. **A hostile archive**: a link, `..`, an absolute path, a name Windows can't hold, too many files or bytes. Refused before anything is written. (`hostile_entries_are_refused`, `limits_stop_an_archive`, Task 7.)

---

### Task 1: The small format changes: `do_file`, `env =`, the fence

**Files:** create `harness/src/taskfiles.zig`; modify `triggers.zig` (taskSection, Trigger, tasksOf), `config.zig` (Task.do_file, clone), `core.zig` (Paths.tasks_dir; loadSettings and settingsProblemWith one call each; MCP start: env vs stored secrets), `mcp.zig` (ServerConfig.env, parse, reason, start), `skills.zig` (readHeader), `fake_mcp.zig` (echo `plain=`).

**Produces:** `config.Task.do_file: []const u8 = ""`; `taskfiles.resolve(io, a, dir, tasks: []config.Task) !?[]const u8` (fills `do` from `dir/NAME.md`, whole; returns the problem or null); `taskfiles.validFile(name) bool` (`NAME.md`, NAME by triggers' name rule); `mcp.EnvVar{ name, value }`, `ServerConfig.env: []const EnvVar`, `mcp.secretLike(name) bool` (TOKEN, KEY, SECRET, PASSWORD, AUTH, any case), `mcp.envHoldsSecret(cfg, secrets) ?[]const u8` (the env name).

- [ ] Tests: skills `a_closing_fence_with_trailing_spaces_reads`; mcp `env_lines_give_a_program_plain_values` (two lines kept in order; `env = GITHUB_TOKEN=x` → `error.SecretEnv`; on a url server → `error.EnvWithUrl`; a bad name or no `=` → BadConfig; the started fake's `env` echo says `plain=VALUE`), `an_env_value_equal_to_a_stored_secret_is_named`; triggers `do_file_names_a_file_in_tasks` (`do_file = brief.md` reads; `do` and `do_file` both, `do_file = ../x.md`, `do_file = x.txt` refused with their reasons); taskfiles `do_file_is_read_whole`, `a_missing_do_file_is_a_settings_problem`, `a_tasks_folder_others_can_write_is_refused` (POSIX); core `a_task_with_do_file_runs_its_file` (the model request holds every line, ` ;` and ` #` included).
- [ ] Run: they fail (no key `do_file`, no key `env`, the fence).
- [ ] Implement; core edits are one line each in `loadSettings`/`settingsProblemWith` and three in the MCP start loop.
- [ ] Green (filters, then the whole unit suite); commit.

### Task 2: `yaml.zig`

**Produces:** `Value = union(enum) { null, str: Str, seq: []const Value, map: []const Entry }`, `Str{ text, quoted }`, `Entry{ key, value: Value, line }`; `parse(a, text, diag: *Diag) Error!Value`; `topBlocks(a, text) []Block` (`Block{ key, first, last }`, line numbers of each top-level key's lines) and `parseBlock(a, text, block, diag)`; helpers `get(v, key) ?Value`, `str(v) ?[]const u8`, `list(v) []const Value`, `boolish(v, default) bool` (Hermes's true/false words).

Reads: block maps and sequences (`- k: v` items), plain, single- and double-quoted scalars (`\n`, `\t`, `\"`, `\\`, `\uXXXX`), `|`/`>` with `-`/`+`, flow `[a, "b"]` and `{k: v}` on one line, comments, `---`, `\r\n`. Anchors, aliases, tags and multi-line flow are errors at their line.

- [ ] Tests: `block_maps_sequences_and_scalars`, `quoted_scalars_and_escapes`, `literal_and_folded_blocks`, `flow_lists_and_maps`, `crlf_reads_the_same`, `an_unreadable_part_says_its_line`, `top_level_blocks_are_read_apart` (an alias in `plugins:` stops nothing in `mcp_servers:`).
- [ ] Fail, implement, green, commit.

### Task 3: `zones.zig`

**Produces:** `offsetAt(io, a, dirs: []const []const u8, zone, at_s) ?i32` (minutes east of UTC; zone "" = this computer's, from `TZ` or `/etc/localtime`); `default_dirs` (`TZDIR`, `/usr/share/zoneinfo`, `/var/db/timezone/zoneinfo`, `/etc/zoneinfo`); `footerOffset(footer, at_s) ?i32` (POSIX TZ: `std offset [dst [offset] [,start[/time],end[/time]]]`, `Mm.w.d`, `Jn`, `n`, `<+02>` names).

- [ ] Tests (TZif files built by a test helper, so they run on Windows): `a_fixed_zone_reads_from_its_footer`, `daylight_saving_from_the_footer` (CET-1CEST,M3.5.0,M10.5.0/3: +60 in January, +120 in July), `transitions_before_the_footer_count`, `a_missing_zone_is_null`, `zone_names_cannot_leave_the_folder` (`../x`).
- [ ] Fail, implement, green, commit.

### Task 4: `hermes.zig`: finding and reading a Hermes home

**Produces:** `Home{ root, dir, profile }`; `locate(io, a, env: Env, from: ?[]const u8, profile: ?[]const u8) !Home` (`--from`, else `HERMES_HOME`, else `~/.hermes` / `%LOCALAPPDATA%\hermes`; `active_profile` followed unless `--profile`; `default` is the root; a HERMES_HOME under `profiles/` is that profile); `read(io, a, home, opts) !Setup` with: `env: []EnvLine{ name, value, line }`; `soul: ?[]const u8`; `memory: []Entry{ file: .memory|.user, text }`; `skills: []SkillDir{ rel, category, name, hermes_name, bundled: ?Bundled{ edited, known }, hub: ?Hub{ source, identifier }, disabled, files, bytes, too_big: ?[]const u8 }`; `jobs: []Job` (std.json, unknown fields ignored, `{"jobs":[…]}` or a bare list); `config: Config{ model, providers, mcp, deny, allowlist, disabled, external_dirs, skill_config, timezone, problems: []Problem{ line, key } }`; `present: []Other` (state.db, sessions/, plugins/, kanban…, workspace/, pairing). Helpers: `splitEntries(text)`, `isStockSoul(text) bool`, `bundledHash(io, a, dir, with_cache) [32]u8` (Hermes's MD5 over Path-sorted relative paths and bytes), `envRef(value) ?[]const u8` (`${VAR}`).

- [ ] Tests (fixture homes written by `fixtures.zig`-style helpers in the test section): `the_home_follows_active_profile_and_the_profile_flag`, `the_default_home_on_each_system`, `env_lines_names_and_values` (export, quotes, comments, `\r\n`), `memory_entries_split_on_the_section_sign` (`\r\n§\r\n` too, empty ones dropped), `stock_souls_are_known` (five texts; one edited character is not), `jobs_read_every_schedule_kind`, `skills_are_found_with_category_hub_and_bundled_facts` (unedited bundled by its manifest hash, edited, hub github, hub clawhub, `.hub`/`.git`/`scripts/x/SKILL.md` not skills), `config_yaml_keys_are_read` (model as a string and as a map, providers, custom_providers, mcp_servers of each shape, approvals.deny, command_allowlist, skills.*, timezone; an unreadable `mcp_servers` names its line and the rest still reads).
- [ ] Fail, implement, green, commit.

### Task 5: The plan (`hermes_import.zig`, pure)

**Consumes:** `hermes.Setup`; harness's current files (`Harness{ config_text, cfg, tasks_text, mcp_text, rules_text, memory: *memory.Store, skills: []name, sources }`).

**Produces:** `Plan` (`items: []Item{ group: .will|.needs|.not, kind, name, line, detail }` and what to write: `memory: []NewItem{ body, pinned, source }`, `skills: []NewSkill`, `tasks_ini: []const u8` appended block, `task_files: []File`, `mcp_ini` block, `rules` block, `suggested` text, `config_edits`, `secrets: []SecretLine{ name, where }`); `makePlan(a, setup, harness, opts{ now_s, utc_offset, zone dirs, bundled }) !Plan`; `planText(a, plan, scrub) []const u8` (Will import: counts then a line each; Needs you; Not imported).

- [ ] Tests: `entries_become_items_dated_60_days_back`, `a_long_entry_is_split_at_paragraphs_never_cut`, `entries_already_in_memory_are_already_there`, `a_stock_soul_is_skipped_an_edited_one_pinned_a_long_one_listed`, `skills_are_flattened_renamed_and_filtered` (`my.skill_x` → `my-skill-x` with its `name` rewritten; over 64 KB with sizes; disabled; name taken; bundled unedited skipped, `--bundled` brings it; github hub keeps its source, clawhub doesn't), `every_schedule_form_maps_or_says_why` (interval 30 → `every = 30m`, 120 → `2h`, 3 → not; once → not; `0 9 * * 1-5` → `at = 09:00`, `days = mon,…,fri`; `0 */4 * * *` → `every = 4h` with the clock note; `*/15 * * * *` → not; paused → commented; script and no_agent → not; repeat, model, workdir, enabled_toolsets, context_from… each named; skills → "Use the skills a and b."), `a_prompt_tasks_ini_would_cut_goes_to_its_own_file`, `a_converted_time_moves_its_days`, `deliveries_main_or_commented`, `a_task_name_taken_gets_hermes`, `every_mcp_server_shape_maps` (stdio args quoted, env plain/literal secret/`${VAR}`, url headers, bearer → `token =`, oauth → `login = oauth`, `X-API-Key` → commented, sse → not, include listed, exclude → `deny mcp S/T *`, disabled → commented, name taken → skipped), `deny_patterns_narrow_only` (`?` and `[…]` → `*`, `[all]` and `# from Hermes`, the case note), `the_allowlist_is_only_suggested`, `providers_map_to_presets_and_sections`, `the_model_is_kept_when_harness_has_a_provider`, `telegram_is_explained_not_moved`, `external_dirs_and_skill_config_are_listed`, `other_hermes_parts_are_named_with_their_paths`, `the_plan_has_three_groups_in_order`.
- [ ] Fail, implement, green, commit.

### Task 6: Writing it, the report, the command

**Files:** `hermes_import.zig` (apply, report, `run`), `main.zig` (`import` dispatch, badArgs, usage, init's notice), `memory.zig` (`Store.repeatOf`).

**Produces:** `run(ctx: Ctx, args) !u8` (`Ctx{ io, gpa, arena, home, env, out, err, stdin, tty, now_s, zone_dirs }`); exit 0 done or dry run, 1 refused, 2 no terminal and no `--yes`; `state/imports/hermes-TIME/{before/, rules.suggested, report.md}`; a log line (`config`, event `import`, counts only); `hermes.noticeFor(io, a, env) ?[]const u8` for init.

- [ ] Tests: `import_writes_what_maps_and_leaves_a_report` (before copies, tasks/ 0700 POSIX, memory ids and undo lines in the report), `running_it_again_adds_nothing_twice`, `the_import_refuses_while_harness_runs_but_dry_run_works`, `without_a_terminal_or_yes_it_exits_2`, `a_terminal_answer_of_no_writes_nothing`, `fifty_imported_entries_leave_the_owners_top_items`, `a_profile_and_windows_line_endings_import`, `no_secret_value_reaches_any_file_output_or_log`; main `import_takes_its_options`, `init_notices_a_hermes_setup`.
- [ ] Fail, implement, green, commit.

### Task 7: `harness skill`

**Files:** create `targz.zig`, `skillsrc.zig`, `skill_cmd.zig`; modify `fake.zig` (`GET /codeload/OWNER/REPO/tar.gz/REF` from `repos/OWNER/REPO/`, commit from `repos/OWNER/REPO.commit`, each request in `codeload-requests.jsonl`), `main.zig` (dispatch, badArgs, usage), `hermes_import.zig` (installs through `skillsrc.install`).

**Produces:** `targz.read(a, gz, opts{ path, max_files, max_bytes, max_skill_md, max_file, max_total }) !Archive{ commit, files: []File{ rel, data, exec } }`; `targz.write(a, top, commit, files) ![]u8` (stored deflate); `skillsrc.Source` (`folder`, `github{ owner, repo, path, ref }`, `link`), `parseSource`, `Facts{ name, description, license, compatibility, allowed_tools, platforms, env_vars }`, `facts(a, skill_md) !Facts`, `hash(files) [64]u8 hex`, `Line{ name, source, pin, hash, time }`, `readSources`/`writeSources`, `install(io, a, skills_dir, name, files)`, `harnessName(hermes_name) ?[]const u8`; `skill_cmd.run(ctx, args) !u8`.

- [ ] Tests: targz `an_archive_reads_its_commit_and_the_files_under_a_path`, `hostile_entries_are_refused`, `limits_stop_an_archive`, `an_archive_without_a_commit_is_refused`; skillsrc `sources_are_told_apart` (folder, `o/r`, `o/r/p@v1`, `https://github.com/o/r/tree/main/p`, `…/blob/main/p/SKILL.md`, a raw link, `http://` refused unless to this machine), `sources_lines_round_trip`, `facts_shows_what_the_skill_asks_for`; skill_cmd `add_from_a_folder_shows_then_installs`, `add_from_github_pins_the_commit` (fake codeload), `add_from_a_link_fetches_one_file` (fake `/page/`), `a_name_already_installed_is_refused_naming_update`, `update_shows_changed_files_and_asks`, `an_edited_skill_needs_force`, `rm_removes_the_folder_and_its_line`, `list_shows_each_source`, `scripts_keep_their_executable_bit` (POSIX); main `skill_takes_its_commands`.
- [ ] Fail, implement, green, commit.

### Task 8: Docs, smoke, full runs

- [ ] smoke.sh, one block at the end: a fixture Hermes home (a memory entry, a job, an MCP server, a deny pattern, a key in `.env`); `import hermes --dry-run` prints the three groups and changes nothing; `--yes` writes them, the fixture key in no file; `skill add OWNER/REPO --yes` against the fake codeload; `skill list` names the source; `skill rm`.
- [ ] README "Coming from Hermes" and the `harness skill` commands; help text; gaps list (built line, the `utc_offset` gap); ledger entry; HANDOFF's Hermes section → what was built.
- [ ] Full runs (Debug and ReleaseSafe, with and without stand-ins), cross builds; Done section; commit.

## Rulings

(Each: what — why — cost if wrong. Added to as they are made.)

## Done
