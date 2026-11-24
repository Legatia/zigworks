# Windows session: platform work (from 2026-11-22)

Owner: "Start and finish everything doesn't require me." Handoff:
`harness/HANDOFF-windows-platform.md`. Each piece on its own branch from
`harness-logins`, test-driven; suites on Windows 11 and Linux (WSL,
an ordinary user), cross builds; the owner decides every push.

## 1. Sandbox runners and environments.ini (branch `win/sandbox`)

Built:

- `environments.zig`: environments.ini read and checked (sandbox: kind,
  workspace, network, read, parallel; remote: kind, host, port, dir,
  parallel; `[default] env`; `[use] WHO = NAME` pins), the line of an
  error named by `/reload` and at start like the other settings files,
  guarded like them, written as comments by `harness init`.
  `Environments.pick(by, step, definition)` and `pinFor(by)` for the gate
  to use.
- `sandbox.zig`: `run(tools.Env, arena, Request)` runs a command in a
  sandbox under the shell's limits (output, masking, time, stop) through
  `tools.runChild`, which the host shell now uses too. Linux: bubblewrap
  (`--unshare-all`, `--die-with-parent`, `--new-session`, the system's
  folders read-only, links kept as links, `/etc/resolv.conf`'s target
  bound when the network is on). Windows: an AppContainer profile per
  environment (`harness-<16 hex of the data folder's path>-NAME`), ACEs
  for its SID on the workspace (modify or read), its home (modify) and
  `read =` folders (read), started suspended through `proc.spawnRaw` with
  SECURITY_CAPABILITIES and a HANDLE_LIST, in a job object. macOS:
  `unavailable` says it is not built; the Mac session adds sandbox-exec
  as one more branch of `run`'s switch.
- `/envs`, `/env check NAME` (probes: workspace read and write, the data
  folder, your home, example.com), `/env rm NAME` (home, `env:NAME`
  snapshots through the new `snapshots.Store.drop`, Windows profile and
  ACEs; refused while a run is going); `harness env list|check|rm`.
- Tests: gap 2's backend tests (`sandbox_cannot_read_data_folder_or_home`,
  `sandbox_workspace_modes`, `sandbox_network_off`,
  `sandbox_env_has_no_secrets`, `sandbox_home_persists`,
  `sandbox_stop_and_limit_end_every_process`,
  `windows_appcontainer_cannot_read_credentials`,
  `windows_aces_go_with_env_rm`, `linux_without_bwrap_refuses_plainly`)
  and `environments_ini_refuses_bad_sections` pass on Windows 11 and on
  Linux (bubblewrap 0.9, an ordinary user). CI installs bubblewrap on
  Ubuntu.

Found on the way, fixed: on Windows the shell tool started `cmd.exe /c
COMMAND` through std.process.spawn, whose quoting (`\"` for a quote) is
not cmd's, so any command with a double quote in it (a path with spaces)
failed with "The filename, directory name, or volume label syntax is
incorrect". It now starts `cmd.exe /d /s /c "COMMAND"` with the command
line as is (`proc.cmdLine`, `proc.spawnRaw`); /d skips AutoRun.

Rulings:

- `kind = host` is refused: host is built in, a section names a sandbox
  or a remote. `[host]` is refused too.
- A pin naming the run beats one with a `*`, which beats a kind alone;
  among equals the first in the file. A who given twice in `[use]` is an
  error.
- A header with nothing under it at the end of the file is not an error
  (and defines nothing), so the line of an error after it is named right.
- The Windows home is `state/env/NAME/home`, as on Linux (not the
  AppContainer's own folder), with TEMP, TMP, APPDATA, LOCALAPPDATA and
  USERPROFILE in it, so `env:NAME` snapshots are the same folder
  everywhere.
- Grants are kept in `state/env/NAME/aces`; a folder's tree is walked
  only when its grant changes. A file moved into the workspace from
  elsewhere keeps its own ACL (Windows doesn't re-inherit on a move), so
  a sandbox may not reach it until it is copied instead.
- Runs don't pick an environment yet: the gate's part (`shell@ENV` is
  already in phase 0's rules and grants) is the next step; `/envs` and
  the README say so.

For the Mac session: the macOS runner is `run`'s third branch (spawn
`sandbox-exec -p PROFILE /bin/sh -c COMMAND` in its own process group,
then `tools.runChild`), and `unavailable` returns null once it is in.

## 2. The SSH remote (branch `win/remote`, on `win/sandbox`)

Built: `remote.zig`. `run` starts the system's ssh (`-F none -T`, batch
mode, this environment's key alone, no agent, no password, no
forwarding, no control socket, the kept host key alone, global known
hosts pointed at it too) with a POSIX sh wrapper as the one remote
command: it starts where `dir` says (125 when the folder isn't there),
runs the command with /dev/null as input, ends the whole session's
process group when ssh's input closes (a stop or the time limit ends ssh
here; the connection closing ends the remote side), ends what the command
left at its end, and exits with the command's code. `harness env key NAME`
makes the key (ed25519, `harness-NAME`), prints the `restrict` line for
authorized_keys, gets the host key and keeps it once the owner types yes.
`/envs` says whether a remote is ready; `/env check NAME` runs one command
there; `/env rm NAME` removes the key and the kept host key.

Tests: `remote_ssh_command_is_locked_down`, the wrapper run by a local sh
(quoting, exit codes, the folder; its input closing ends the group, its
end ends what the command left), `remote_stop_ends_the_remote_command`
against a sshd of the test's own on 127.0.0.1 (Linux, when sshd is
there: key made, host key got and kept, exit code and folder, a stop
leaves nothing, another host key refused). By hand: harness on Windows
(Windows' ssh.exe) against a sshd in WSL: env key, env check, env rm.

Rulings:

- The host key is got with ssh itself, accept-new into a scratch file,
  not ssh-keyscan: Windows' ssh-keyscan fails the key exchange OpenSSH
  9.6 servers offer ("unsupported KEX method sntrup761x25519"). Only the
  key type ssh agrees on is kept, which is the one it checks.
- Paths in ssh's -o values are quoted, with forward slashes on Windows
  (OpenSSH reads `\` as an escape there; a user name with a space would
  split the value).
- A remote's login shell must be POSIX: the remote command is single
  quoted for one.
- `env key` writes to the log (key made, host key kept) through Core, so
  it can't run while `harness run` holds the folder, like the other
  commands that open it.

## 3. The app server (branch `win/app-server`, on `win/remote`)

Built: `apps.zig` (app.ini and the folder checked; approval by digest in
`state/apps/NAME/approved`, a new version when the files changed),
`appserver.zig` (127.0.0.1 alone on an exclusive port; per-start key and
shell token, apps' tokens as HMACs of name and version; Host, Origin and
frame checks; the headers and both CSPs; the sandboxed frame; paths mapped
to files, never passed through; 32 connections; a stop within 2 s), the
built-ins inbox, log and files, `[apps] on|port`, `harness run`/`chat`
printing the link, `/apps`, `/app approve|rm`, `harness app
list|approve|rm`, log kind `app`.

Tests: the spec's server tests (manifests, paths over names and HTTP,
loopback alone, Host/token/Origin, tokens per start and version, HTML
only into a frame, headers and CSP, changed outside harness, built-ins,
stop within 2 s) and the chat commands. By hand, headless Chrome on
Windows over the DevTools pipe: the frame runs its own script and not an
inline one, can't read the shell, storage or cookies, can't fetch another
port or site or open a window, reaches its own `api/`, origin `null`.

Rulings:

- `[apps] on` is off by default (the spec has on): until the API is in,
  apps read nothing and the built-ins say so.
- The built-ins live in `src/apps/` (`@embedFile` reaches only the
  module's folder), not `harness/apps/`.
- Not built here (each needs the gate's app parts, phase 0 is in but the
  inbox is not): the API (reads, acts, runs), `app_draft`/`app_save` and
  the review page, versions, fork and revert, the bar.
- On Windows a second bind on the exclusive port fails with access denied
  (WSAEACCES) when it asks for SO_REUSEADDR, address in use otherwise;
  both are refusals.
- The desktop app's browser pane blocks frames to local servers
  (ERR_BLOCKED_BY_CLIENT), so the frame was checked in headless Chrome;
  `app_frame_cannot_get_out` as a unit test needs cdp.zig to attach to
  frame targets, which it doesn't yet.

## 4. Clone helpers (branch `win/clone`, on `win/app-server`)

Built: `clone.zig`, plugged in as `snapshots.platform_clone`. Linux:
FICLONE into a new file (btrfs; XFS with reflink). Windows: block cloning
(FSCTL_DUPLICATE_EXTENTS_TO_FILE) a cluster-aligned range at a time, the
new file sized first and given the source's integrity setting, only where
the volume counts block references. Where the file system can't, the
helper says false and leaves no file behind, and the store copies as
before. macOS (clonefile on APFS) is the Mac session's: `platform` is null
there.

Tests: `a_clone_is_whole_where_the_file_system_can_and_nothing_where_it_cannot`
(everywhere: ext4 and NTFS say false and leave nothing; an existing file
is never overwritten) and `clones_share_blocks_on_copy_on_write_file_systems`
(folders named in HARNESS_TEST_COW_DIRS): passed on XFS (reflink) and
btrfs made on loop files in WSL. Not run: ReFS or a Dev Drive, which this
machine doesn't have (making one needs an administrator and a new disk);
set HARNESS_TEST_COW_DIRS to a folder on one to run it.

## 5. State files replaced safely (branch `win/state-files`, on `win/clone`)

Found: `state/grants` and `state/written` were rewritten in place
(truncate, then write): a crash, or a reader at the wrong moment, got a
cut file. The others (conversations, the money ledger, skills, the
sandbox's ACE record, kept host keys, approved apps) wrote a `.tmp` and
renamed it, but on Windows a program that holds the file open without
sharing deletion (a virus scanner, an editor, a backup) makes that rename
fail with a sharing violation, which std reports as error.Unexpected.

Built: `util.writeReplace(io, path, data)`: a new file beside it (random
name, owner-only, synced), renamed over it; on Windows, while another
program holds it, tried again for up to 2 s, then the error with the old
file kept and no temporary one left. Harness's own readers open files
sharing deletion (std does), so they never hold a replace up. All the
writers above use it now. For the Mac session: `state/inbox` (phase A)
should be written with it too.

Tests: `a_replaced_file_is_the_old_or_the_new_never_a_part` (a reader
thread against 60 replaces of 200 to 256 KiB: every read is one version
whole), `a_replace_waits_for_a_program_that_holds_the_file_windows` (a
handle sharing reads only, let go after 0.4 s: the replace waits and
succeeds; one never let go: an error, the old content, nothing left).

## 6. The hosted design (branch `win/hosted`, on `win/state-files`)

`docs/superpowers/specs/2026-11-22-harness-hosted-design.md`: the three
hosted notes (agents, file roles, environments) and the apps spec's
hosted part joined into one design for the owner, grounded in omnigate
(its control plane, keys, budgets and credit): a VM per customer instance
with sandboxes by default; actors per agent instance with journaled
turns; the customer's filesystem with roles at its front; cloned VMs;
apps over https with the Telegram Mini App; isolation and what the
operator sees; failure and recovery; a build order; five questions for
the owner, each with a proposal. No code.

## Integration (branch `win/platform`)

`win/hosted` merged with `harness-logins` at 7cb14ec (providers, agent
definitions, the inbox): 6a3dff6, conflicts kept both sides. Then
02f9c47 (state/inbox and agents/NAME.md written with util.writeReplace)
and 28ff1d6 (a race in a test fixture: helpers asking at once lost a
count now and then; 1 run in 30 failed, 100 in 100 pass after). At
28ff1d6: Windows 11 594 pass, 41 skip, smoke ok; Linux (WSL) 621 pass,
14 skip, smoke ok; macOS type-checks. `harness-logins` fast-forwards to
it.

## 7. The held-back batch (2026-11-23, branch `win/envs`, on `harness-logins` 0980012)

From the handoff's "Next" section. Three commits; item 3 of that section
(apps' API, app_draft, app_save, the bar) is not started.

### 7.1 The data folder inside a `read =` folder (1e355f3)

The handoff's decision: Linux and Windows refuse it as macOS does.
bubblewrap: `read =` folders are bound first, then an empty folder
(`--tmpfs`) over the data folder, then the workspace and the home (bound
before, a `read =` folder above the workspace also covered the workspace's
own bind with a read-only one). AppContainer: **Windows ignores a deny
entry for an AppContainer's SID** (tried: the entry was there, the file
was read), so the data folder's access list stops inheriting (its
inherited entries become its own, as `icacls /inheritance:d` does) and the
SID's entries are taken out; the workspace and the home keep their own.
Ruling: it stays so after `env rm` (who may use the folder is unchanged;
undoing it would leave doubled entries). Test
`sandbox_cannot_read_the_data_folder_inside_a_read_folder`.

### 7.2 Runs pick an environment (c0dde2e)

As the environments spec's "Picking an environment" and "The gate and the
log". `agent.Run.picked()`: a `[use]` pin over `by`, the step's `env`, the
definition's `environment`, `[default] env`; a delegated run takes its
starter's. `shell` takes `env`; the tool's description says where the run's
commands run and which others it may name. Refused before the gate: a
pinned run naming another, a name environments.ini lacks, a sandbox or
remote that can't run here, `dir` where the workspace isn't seen. The gate
gets the environment (`ctx.env`), so rules, grants and skipped items are
per environment. `env_save` (tool, `EnvDesk`, `Core.checkEnv`/`saveEnv`):
checked, asked in full with the section it replaces, written in place
under `; saved by agent:NAME DATE (item N)`, applied at once.
`workflows.envProblem` and agents' `environment` take any environment's
name.

Rulings:

- R1. Lines of commands on the host carry no `env` field; lines of
  commands elsewhere carry `"env":"NAME"` (the spec says shell's lines
  carry it; the host is its absence, and the lines every earlier test and
  log reader knows stay as they are).
- R2. A definition's `environment` counts only when its file has the line
  (`environment_given`): a definition without it follows `[default] env`.
- R3. Whether a step's or a definition's environment exists is seen when
  its command runs (refused, never the host), not when the file loads: an
  `env_save` can add it later without a reload of the others.
- R4. `parallel` is held per environment through the helper pool
  (`env:NAME` places); a command waits for a place until the turn's end.
- R5. `env_save` changes one section and never touches the others; an
  at-once change is read into its own arena, kept until the next /reload,
  since runs going hold the list before it.
- R6. A remote and a sandbox without the workspace take no `dir`.

Tests: `run_picks_pin_step_definition_default`,
`pinned_run_cannot_name_another`,
`shell_rules_and_grants_per_environment_and_questions_and_log_lines_name_it`,
`written_files_rule_by_environment`, `env_save_asked_in_full`,
`env_save_writes_the_section_and_applies_it_at_once`,
`a_workflow_steps_env_line_runs_its_command_there`,
`a_section_is_swapped_in_place_or_added_at_the_end`.

Also fixed there: the Mac session's
`another_step_cut_by_a_restart_asks_in_the_inbox` counted `pushed\n`,
which cmd prints as `pushed\r\n`: Windows CI was red from 763d052 on.

### 7.3 Try in a copy (370f96e)

Part 3 of `2026-11-23-harness-routines-undo-copies-memory-design.md`.
`copies.zig` (make, changes, listText, diffText, apply, drop),
`environments.zig` (`workspace = copy`, `check`, `apply`, `copy_mb`),
`agent.zig` (`CopyRun`, made at the first call that reads or changes
files; `endCopy` runs the check and hands the changes to the keeper),
`core.zig` (the `copy` inbox item with Show, Apply, Drop; `applyCopy`).

Rulings:

- R7. The copy is made at the run's first `read_file`, `write_file`,
  `shell` or `send` (a run that touches no file makes none). A workspace
  over `copy_mb` refuses those calls, each with the reason, where the spec
  says the run is refused before it starts: nothing has run by then.
- R8. A file is the same when its size and time are. Windows' clock ticks
  (up to 16 ms): a file rewritten in the tick it was copied in keeps both,
  so a file written within 2 s before the copy is told by its SHA-256 too
  (kept in `COPY.base`), in the copy and when applying.
- R9. Paths: the gate keeps deciding on the workspace's own paths; the
  file tools take paths inside the workspace, and an absolute path is
  refused in a copy run (the tool says so in its description).
- R10. Everything a copy run does acts on the copy: a command it sends to
  `host` or another sandbox starts in the copy too.
- R11. Linux sees the copy at the workspace's path (`Request.mount_at`);
  Windows and macOS at the copy's own. Windows grants the SID the
  `copies` folder once, not each copy (a run's sandbox can read another
  run's copy of the same environment).
- R12. Apply snapshots `/` when folders.ini keeps snapshots there, and is
  done in harness, not in the sandbox. Links the run made are never
  applied, and nothing is written through a link in the workspace
  (`gate.confine`).
- R13. Show leaves the item open (the terminal then says it is still
  open). Copies older than 8 days go when a newer one is kept.
- R14. The item carries its copy in `skip` (`copy<TAB>ENV<TAB>RUN`): the
  inbox format has no other free field.

Tests: `a_runs_writes_stay_in_its_copy`,
`apply_writes_only_files_unchanged_since`, `copy_mb_refuses_before_the_run`,
`a_link_the_run_made_is_never_followed_into_the_workspace`,
`copy_is_a_clone_where_it_can_be` (XFS and btrfs in WSL: cloned),
`a_runs_writes_stay_in_its_copy_until_the_owner_applies_them` (two runs,
two copies; Show, Apply, Drop; a file changed since is left),
`apply_check_applies_when_the_check_passes`,
`env_check_probes_a_sandbox_and_a_copy_environment`.

### 7.4 Found: cmd's built-ins in a Windows sandbox

Inside an AppContainer, cmd's `dir`, `del`, `ren`, `copy`, `move` and
`cd /d` fail with "Access is denied": they call GetVolumeInformation on
the drive's root (robocopy says "Getting File System Type"), which the
sandbox may not open, and a drive root's access list can't be changed
without an administrator. Creating, reading and overwriting files work,
as do programs that don't ask the drive. Tried: with the workspace as a
drive's root (`subst Q:`), all of them work in the sandbox. A fix is a
drive letter of the process's own (its device map), not built: README
says the limit, `/env check` no longer uses those commands, and
`sandbox_changes_files_the_owner_made` holds it down. For the owner to
decide whether it is worth building.

### 7.5 Left

- Apps' API, `app_draft`, `app_save` and the review page, versions and
  forks, the bar: not started.
- macOS: the copy at its own path and `mount_at` unused there are written
  but not run on a Mac; the Mac session tests that branch.
- `scheduled_task_runs_in_the_sandbox` of the spec has no test by that
  name: its parts are tested (a pin over `schedule`, `allow shell@box`,
  the sandbox run), not one task end to end.
- folders.ini's `skip` in a copy is every section's patterns, matched by
  name or by path from the workspace, not per section.

At 370f96e: Windows 11 708 pass, 47 skip; Linux (WSL, user tester) 736
pass, 19 skip, smoke ok. One Linux run failed the Mac session's
`an_item_expires_at_approval_seconds_or_its_turns_end` while the Windows
suite ran beside it; alone it passed 5 of 5.

## 8. Apps: the API, the bar, app_save, versions and forks (2026-11-23, branch `win/apps`, on `harness-logins` 1bd8dbe)

Item 3 of the handoff's "Next" section: the rest of gap 8
(`docs/superpowers/specs/2026-11-22-harness-apps-design.md`).

Built:

- `apps.zig`: built-in manifests; `fileListed`/`fileAbove`/`actListed`;
  an app's data (`dataGet`/`dataPut`/`dataDelete`/`dataKeys`); `stage`
  (the folder checked and copied to `state/apps/pending/ID/`, the version
  it would get written, what changes), `describe` (what the owner is
  asked), `install` (`approved` first, then renames; `installing` marks
  it), `finishInstalls` (at a start), `versions`, `revert`, `fork`,
  `draft`, `hasInline`.
- `appserver.zig`: POST, PUT, DELETE and OPTIONS on a token's `api/` paths
  (bodies up to 1 MiB, the preflight a frame's JSON call needs), a `Host`
  the core implements (`api`, `shell`, `opened`), the bar on every page of
  harness's own (`apps/common/shell.js`), `/s/SHELL/review/ID` (every file
  in full, the draft in a frame under its own token, its API answering
  403), `appUrl`/`reviewUrl`.
- `core.zig`: `appApi` (info, memory, inbox, log, log/runs,
  log/session/RID, log/verify, files, data, act, run), `appShellApi`
  (`GET inbox`, `POST answer` through `answerItem(.bar)`), acts and runs
  as jobs on threads of their own (`AppJob`, `AppAsk`), `appDesk` for the
  agent's tools, `fillLinks`, `/app fork|versions|revert`,
  `noteChangedApps` at a start.
- `agent.zig`: `app_draft`, `app_save` (`AppDesk`, a setup call), `ask_owner`
  takes `app`; no money from `app:` (`[money] apps`).
- The built-in inbox, log and files read through the API.

Rulings:

- R15. `[apps] on` is on by default now, as the spec has it (it was off
  until the API was in).
- R16. A read the gate would ask about is refused: reads are never asked
  (the spec gives reads allow or deny). Files pass `read_file` for
  `app:NAME`; a folder on the way to a listed path can be listed and
  shows only the entries that lead on.
- R17. `api/log` reads the log's last 4 MiB (a viewer wants its newest
  lines); `log/runs` and `log/session` read all of it, as the CLI does.
- R18. `api/data` values come back as they were put, unmasked (they are
  the app's own bytes); every other answer is masked. A built-in keeps no
  data (its name has no folder in `apps/`).
- R19. An act's `who` is `app:NAME` with no definition (as a workflow's
  tool step): rules written for a definition don't apply to it. Its
  question's deadline is `act_seconds`; a shell act's time is capped by
  it too. A job is kept 10 minutes after it ended; only the app that
  started it reads it.
- R20. A run an app starts has no outbox (it can't `send`), takes a place
  among `concurrent_runs` like a task, and holds its definition's place.
- R21. Money: an app's act never (also refused before the gate when the
  MCP tool is a money tool); a run it starts under `[money] apps`
  (default off), as triggers and workflows.
- R22. `app_draft` is offered where `app_save` is (runs the owner started
  from a conversation). A draft under another name gets that name and
  `forked_from`.
- R23. The question is `describe` within 9 KB: files that changed first,
  the rest counted ("and N more files, on the review page").
- R24. Install: the app's `data/` moves into the new folder; the folder
  replaced goes to `versions/N` by its own app.ini's version; saves that
  were being asked are dropped at a start (their questions are void).
- R25. `{app:NAME}`, `{app:NAME/VIEW}` and `{app-review:ID}` are filled
  where text leaves for the owner (`sendTextAs`, `sendWithButtons`,
  `showItemHow`); with no app server running the text says so. The log,
  the inbox file and the model hold the placeholder.
- R26. An item with `app` is shown with "In the NAME app: LINK" (view
  `item-ID`) under it.
- R27. The bar asks `api/inbox` every 2 s and ignores a click within 0.5 s
  of drawing its buttons.
- R28. `/app fork` approves the copy as the owner's at once: the owner
  ran the command.
- R29. Fixed on the way: `apps.approve` wrote a second `version` line
  into an app.ini that had one after `[app]`, and the app then no longer
  read (`/app approve` twice in a row failed). Test added.

Tests (spec names where it has them): `app_save_installs_what_was_shown`,
`a_long_file_list_is_cut_to_the_question`,
`an_install_cut_by_a_crash_ends_at_the_next_start`,
`app_versions_fork_revert`, `an_apps_data_is_its_own_keys`,
`an_apps_files_and_acts_follow_its_manifest` (apps.zig);
`app_api_calls_reach_the_host_from_the_apps_own_paths`,
`the_bars_calls_need_the_shell_token_and_no_app_path_reaches_them`,
`the_review_page_shows_a_save_in_full_and_its_draft_reads_nothing`
(appserver.zig); `app_reads_follow_the_manifest`,
`app_log_waits_for_a_new_line`, `app_answers_are_masked`,
`app_files_follow_the_manifest_and_the_file_rules`,
`an_apps_data_through_its_api`, `app_act_passes_the_gate_as_the_app`,
`app_grants_cover_one_app_only`, `stop_ends_app_acts_and_runs`,
`app_run_within_limits`,
`bar_shows_every_open_item_and_answers_each_once`,
`app_save_asks_every_time_and_installs_what_was_shown`,
`app_save_denied_or_unreadable_installs_nothing`,
`app_placeholder_filled_only_when_sent`,
`the_app_commands_fork_list_versions_and_revert`,
`an_item_with_an_app_carries_its_link`,
`an_app_reads_and_acts_over_http_and_the_bar_answers` (core.zig);
`app_save_is_offered_only_in_runs_the_owner_started_from_a_conversation`,
`app_save_asked_every_time`, `an_apps_acts_and_runs_move_no_money`
(agent.zig).

By hand, in Chrome (headless, from the command line) against a running
harness: an app in its frame could not reach the parent page, storage,
cookies, a popup, another host or harness's own paths; a script written
into its page did not run; an unlisted read and a file outside its
`files` got 403; its listed file, its inbox read (no token) and a PUT to
its data worked. In the desktop app's browser pane: the bar showed the
waiting question and "Allow once" answered it (`via bar`, the command
ran). That pane does not load frames from a local server, so apps
themselves can't be looked at there.

Left:

- The two headless-Chrome tests of the spec (`app_frame_cannot_get_out`,
  `builtin_apps_show_their_data`) are not unit tests: what they cover was
  checked by hand as above.
- `/reload` does not look for apps changed outside harness; a start,
  `/apps` and the serving of an app's page do.
- The end-to-end script (`scripts/smoke.sh`) has no step for apps.
- macOS: nothing here is per-system, but none of it ran on a Mac (it
  type-checks for aarch64-macos).

Also fixed there: `scripts/smoke.sh` ran `harness report` from another
folder with the relative path Windows' build hands it; the check failed
and left the model's replies one off for the four checks after it. The
binary's path is absolute now.

Merged with `harness-logins` 5e4d0d4: Windows 11 971 pass, 48 skip,
smoke all ok; Linux (WSL, user tester) 999 pass, 19 skip, smoke all ok
run alone, and the one failure this machine's WSL always has
(`mcp_list_says_each_servers_kind_sign_in_and_tools`).

## 9. cmd's own commands in a Windows sandbox (2026-11-24, branch `win/cmd`, on `harness-logins` 2d3c3d2)

The owner's decision on 7.4: fix it.

What it is: cmd's `dir`, `del`, `ren`, `copy`, `move` and `cd /d` call
GetVolumeInformation on the root of a path's drive, which an AppContainer
may not open. On a drive whose root is a folder the sandbox may read,
they work. So a sandbox gets drives of its own: the workspace (the copy,
for `workspace = copy`; the home, where it doesn't see the workspace) as
`W:`, its home as `V:` (the first two letters from W down to L that are
no drive of the machine); its command starts there, and USERPROFILE,
APPDATA, LOCALAPPDATA, TEMP, TMP and HOME name the home's drive.

How the drives are the sandbox's own:

- **Tried first, and not kept: a device map on the process**
  (NtSetInformationProcess, ProcessDeviceMap, with an object directory
  holding the links). The first process sees the drive; what it starts
  does not (with LUID device maps on, as they are everywhere, a process's
  map is not inherited): a nested cmd and `more` could not open `W:\`.
- **Kept: a logon session of its own.** DOS device names belong to a
  logon session. `proc.spawnInSession` starts a launcher with
  CreateProcessWithLogonW and LOGON_NETCREDENTIALS_ONLY (the Secondary
  Logon service, as `runas /netonly`: the same user here, a new session,
  a name and password that are never checked). The launcher
  (`proc.sandboxLaunch`: `harness sandbox-launch`, a command nobody
  types; `harness-fake --sandbox-launch` in the unit tests) names the
  drives with DefineDosDevice, starts the AppContainer's cmd with its own
  stdin, stdout and stderr, waits and ends with its exit code. Every
  process the sandbox starts is in that session and sees the drives; no
  other session does; they end with the session's last process, a killed
  one too.

Rulings:

- R30. The launcher is started suspended and goes in the command's job
  like any child; the AppContainer's cmd is its child, so `/stop` and the
  time limit end both.
- R31. What to start travels in the launcher's variables
  (`HARNESS_SBX_APP`, `_LINE`, `_PROFILE`, `_NET`, `_DRIVES`), which it
  takes out of what the sandbox gets. Run without them it starts nothing
  (exit 125).
- R32. The launcher starts in the home by its real path (this process
  checks that folder before the drives exist); the command line is
  `cd /d "W:\DIR"||exit 1&COMMAND`: a command is not run where its drive
  can't be reached.
- R33. Where the service refuses (switched off, or policy),
  `error.NoSession`: that sandbox and every later one in this start run
  as before by their real paths (`sandbox.hasDriveLetters()` is false
  from then). `/env check` has a line for it; the shell tool's
  description tells the agent of the drives only while they are there.
- R34. Windows gives an AppContainer's processes LOCALAPPDATA and TEMP
  under the one they were started with (`Packages\PROFILE\AC[\Temp]`);
  harness makes that folder (before, this process's CreateProcess could
  see the path; now it is on the sandbox's drive).
- R35. The new session's credentials toward the network are the unchecked
  ones: integrated sign-in to a file share or proxy from a sandbox would
  fail. An AppContainer without the enterprise capability had none
  before either.
- R36. The gate, grants and the log keep the workspace's own paths; only
  what a command prints may show `W:\`.

Measured here: a sandboxed `echo` takes about 35 ms more (142 ms against 109).

Tests: `sandbox_changes_files_the_owner_made` (dir, copy, ren, md, move,
cd /d, del in the workspace, the home and the temporary folder; a nested
cmd, findstr and more; the real path still reads; `subst` inside reaches
nothing; a real drive's root still refused),
`windows_sandbox_without_a_session_of_its_own_runs_by_its_real_paths`,
`a_sandboxes_drive_letters_are_none_of_the_machines`,
`the_sandbox_launcher_starts_nothing_it_was_not_told_to`,
`env_check_probes_a_sandbox_and_a_copy_environment` (its new line).

Left: GitHub's Windows runners were not tried before the push; if the
service is off there, the tests that need the drives say so in CI.
