# The desk app carries harness and sets it up: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One download (`harness-desk.app` with harness and the fit files inside) that sets harness up on its own "Set up" screen, the key typed in a native secure field.

**Architecture:** Every decision stays in shared Zig (`harness/desk-app/src/*.zig`): a new `setup.zig` holds the provider table, the form, its checks, the argv of each step and the step machine; `controller.zig` drives it with events in and effects out, as today; `pages.zig` renders the form as the app's own built-in page. The native side (`src/mac/desk.m`) adds one thing: a sheet with an `NSSecureTextField` whose text goes straight to Zig, which pipes it to `harness secret add NAME --stdin` and zeroes its copy.

**Tech Stack:** Zig 0.17.1 std only; Objective-C (AppKit, WebKit); POSIX sh for packaging and the smoke; Python 3 for the stand-in harness.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, "The desktop app and getting in" and "First run, and the desk alone (added 2026-11-25)", above all "The app carries harness and sets it up".

## Global Constraints

- harness stays std only; the desk app links only Cocoa and WebKit on macOS. No dependencies.
- Labels: "Set up", "Provider", "Model", "Address", "Continue", "Provider and key…". Provider choices: Anthropic, OpenAI, OpenRouter, opencode, omnigate, Other.
- The secure field's note, inline: "harness keeps it in this computer's key store."
- The key never reaches a page, an argv, a log, an environment variable or the test hooks.
- A failing step shows that command's own line; what was typed stays.
- No slogans, no explanation of what a key is; explanations behind a small "i" button; errors say what failed and don't apologise.
- Tests never touch the owner's data, key store or a provider: temp `HARNESS_HOME` and `HARNESS_STORE`, `HERMES_HOME` pointing nowhere; the fake key is `sk-test-not-a-key`, compiled into test-hook builds only.
- Release packaging stays strict: a missing fit file fails the release job with one line.

## Review Focus

1. Pressing Continue a second time after a failure: `harness init` must not run on a folder that has config.ini, and nothing set before is lost. Test: `continue_again_after_a_failure_skips_init_and_keeps_the_form` (Task 2).
2. Cancelling the key sheet, or saving it empty: nothing is stored, the screen says so, Continue asks again. Test: `a_cancelled_key_says_so_and_continue_asks_again` (Task 2).
3. The periodic check finding config.ini (after init) or a dead harness while the form is open must not swap the form for another screen. Test: `checks_while_the_form_is_open_leave_it` (Task 2).
4. A value with quotes, `<`, or `;` typed in Model or Address: escaped in the page, refused by harness with its own line if config.ini can't hold it. Tests: `form_values_are_escaped` (Task 3), and the argv test passes values as single argv words (Task 1).
5. "Provider and key…" on a data folder whose provider was set by hand as a `[provider NAME]` section: shown as Other with that section's format and address, saved back to the same section. Test: `a_hand_made_section_reads_as_other_and_saves_to_it` (Task 1).

---

### Task 1: `setup.zig`: the provider table, the form, the argv

**Files:** Create `harness/desk-app/src/setup.zig`; modify `src/tests.zig`.

**Interfaces (produces):**
- `pub const Provider = enum { anthropic, openai, openrouter, opencode, omnigate, other }`
- `pub const Api = enum { openai, anthropic }`
- `pub const Entry = struct { id: Provider, label: []const u8, name: []const u8, model: []const u8, helper: ?[]const u8, address: bool }` and `pub const entries: [6]Entry` in the order above.
- `pub const Form = struct { provider: Provider = .anthropic, model: []const u8 = "", url: []const u8 = "", api: Api = .openai, replace: bool = false }`
- `pub const InUse = struct { provider: []const u8, model: []const u8, url: []const u8, api: []const u8, key: []const u8 }` (what `harness config get` printed) and `pub fn formOf(u: InUse) Form`, `pub fn sectionOf(u: ?InUse) []const u8` ("other" unless the one in use is a hand-made section).
- `pub fn problem(f: Form) ?[]const u8` (the line under the form, or null).
- `pub fn initArgv(a, binary, home) ![]const []const u8`; `pub fn configArgv(a, binary, home, f: Form, before: ?InUse) ![]const []const u8`; `pub fn keyName(f: Form, before: ?InUse) []const u8`; `pub fn secretArgv(a, binary, home, name) ![]const []const u8`; `pub fn readKeys() []const []const u8` and `pub fn readArgv(a, binary, home, key) ![]const []const u8` for `config get`.

Values (from harness's own code, not invented): names and secrets from `model.zig`'s presets; models: omnigate `claude-sonnet` with helper `claude-haiku` (`harness init`'s routes); anthropic `claude-opus-4-8` with helper `claude-haiku-4-5` (see the plan's rulings: harness's Anthropic requests carry no thinking blocks); openai `gpt-5` (harness's OpenAI request test); openrouter `anthropic/claude-sonnet-4` (harness's Hermes-import tests); opencode and Other: none, the field is required.

- [ ] Tests first: `provider_table_matches_harness`, `config_argv_per_provider` (anthropic: `config set model.provider anthropic model.model M model.memory_model claude-haiku-4-5 model.worker_model claude-haiku-4-5 --home H`; omnigate adds `model.url U`; other adds `"provider other.api" A "provider other.url" U`), `helpers_follow_only_on_first_setup_or_a_new_provider`, `key_name_per_provider` (omnigate: `[model] key` in use; a preset: its section's key or its name; other: the section's key or its name), `problems_name_the_field`, `a_hand_made_section_reads_as_other_and_saves_to_it`, `values_are_single_argv_words`. Watch them fail, implement, pass, commit.

### Task 2: the controller drives the setup

**Files:** Modify `src/controller.zig`, `src/bridge.zig`, `src/commands.zig`.

**Interfaces:**
- `CheckResult` gains `no_config` (checked before desk.json).
- `Controller.init(gpa, home, own: []const u8)`: `own` is harness beside the app's program ("" when it isn't there). `binary()` is desk.json's when given, else `own`.
- `bridge.Message` gains `setup: ?setup.Form` and `cancel: bool`; `bridge.parse` copies strings into its allocator. A `key` field in a message is ignored.
- Events: `stepped: { gen, ok, text, out }`, `read: { gen, ok, text, in_use: ?setup.InUse }`, `key: enum { given, empty, cancelled }`, `stored: { gen, ok, text }`; `MenuItem.provider`.
- Effects: `step: { gen, argv, path }` (runWait), `read_config: { gen, binary, home, path }`, `ask_key: { title, note }`, `store_key: { gen, argv, path }`; `show` carries the form's view (`pages.View`).
- `Menu.provider: bool`.
- `commands.runWithStdin(io, a, argv, env, input) !Result`.

- [ ] Tests first: `no_config_shows_the_form`, `continue_runs_init_config_key_then_starts`, `a_failing_step_shows_its_line_and_keeps_the_form`, `continue_again_after_a_failure_skips_init_and_keeps_the_form`, `a_cancelled_key_says_so_and_continue_asks_again`, `checks_while_the_form_is_open_leave_it`, `provider_and_key_reads_the_values_in_use`, `a_change_while_harness_runs_says_config_sets_line_and_enters_again`, `the_key_is_asked_again_only_when_chosen_or_new`, `the_own_copy_runs_when_desk_json_names_none`, `run_with_stdin_feeds_and_closes_the_input`, `a_key_field_in_a_message_is_ignored`. Fail, implement, pass, commit.

### Task 3: the "Set up" page

**Files:** Modify `src/pages.zig`.

**Interfaces:** `pub const View = struct { mode: enum { first, change }, form: setup.Form, busy: bool, home: []const u8 }`; `html(a, screen, note, home, view: ?View)`.

- [ ] Tests first: `setup_page_has_the_fields_and_labels` (Provider select with the six labels, Model prefilled, Address only for omnigate and Other, Format only for Other, Continue; "Replace the key" and Cancel only when changing; no password input; no "http" load), `form_values_are_escaped`, `busy_disables_continue`, `the_i_button_opens_a_bubble`. Fail, implement, pass, commit.

### Task 4: the native secure field and the wiring

**Files:** Modify `src/main.zig`, `src/mac/desk.h`, `src/mac/desk.m`, `src/testhooks.zig`, `build.zig`, `test/fake_harness.py`, `scripts/smoke.sh`.

- `void hdesk_ask_key(const char *title, const char *note)`: a sheet with an `NSSecureTextField`, the note under it, [Save] [Cancel]; answers `hdesk_on_key(const char *buf, int len)` (`len < 0`: cancelled), after copying the text out of the field into a buffer it clears and zeroes after the call, and emptying the field.
- Zig copies the bytes into its own buffer, pipes them to `harness secret add NAME --stdin`, then `secureZero`s and frees it. The log says `key given` / `key cancelled`, never the text.
- `void hdesk_test_key(int action)` (test-hook builds only, `-DHDESK_TEST_HOOKS`): 1 fills the field with `sk-test-not-a-key` and presses Save, 0 presses Cancel. Hook commands `key fill`, `key cancel`.
- The fake harness learns `init`, `config set`, `config get`, `secret add NAME --stdin` (its store: `HOME/fake-store/NAME`).
- The smoke installs the fake as `Contents/MacOS/harness` in the smoke app and goes through: the form; a bad address refused; Continue; init, config set, the key sheet cancelled then filled; harness started and entered; `Provider and key…` with the values in use; the key never in the log, the app's output, the fake's log or any argv. `DESK_SMOKE_HARNESS=PATH` runs the same setup against a real harness (temp home and store).
- [ ] Testhooks unit test `key_commands_parse` first; then the smoke; commit.

### Task 5: one download

**Files:** Modify `scripts/package-macos.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`.

- Build harness ReleaseSafe, stripped, for aarch64-macos and x86_64-macos from `harness/`; `lipo` into `Contents/MacOS/harness`; check both are `x86_64 arm64`.
- Fit files: `DESK_ASSETS` unset: `harness/scripts/pack-desk-assets.sh` into `Contents/Resources/desk-assets` (its one line and exit 1 on a missing file); `DESK_ASSETS=DIR`: that folder, checked for the same files; `DESK_ASSETS=none`: left out, said on stdout.
- Sign the inner `harness` first, then the bundle; `codesign --verify --deep --strict`.
- CI's package step sets `DESK_ASSETS=none`; the release step uses the strict default.
- [ ] Run end to end with `DESK_ASSETS=none` and with a stand-in folder; run with `DESK_ASSETS` unset and see the one line; inspect the zip; commit.

### Task 6: docs

**Files:** `harness/HANDOFF-windows-platform.md` (a dated section: the shared interface, what the native side supplies, where harness and desk-assets sit, the Windows verification list), `harness/README.md` (Desk app (macOS)), the spec's "Calls I made" (the builder's calls only), the ledger.

## Rulings

Recorded in the ledger and the report as they are made (R1…).
