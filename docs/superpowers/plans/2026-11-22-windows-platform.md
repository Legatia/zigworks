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
