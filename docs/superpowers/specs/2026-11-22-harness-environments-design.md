# harness environments (gap 2)

Gap 2 of `2026-11-22-harness-platform-overview.md` (binding); Windows
session, phase C (the backends as standalone runners first, before phase
0; the gate parts after it). Uses `by` (conversations spec), `who` on
grants (inbox), the overview's rules and grants with `@ENV` (phase 0),
`folders.view` and `dir` (file roles) and snapshots (file roles, for
checkpoints); on Windows it builds on the job-object helper of
`HANDOFF-windows-audit.md` section 1 (I27), first.

**Intent.** The post: agents work in sandboxes that are checkpointed and
cloned across providers, and on people's own computers: N agents on M
computers, set up by the agent. Here: every shell command runs in a named
environment (the host workspace as today, a sandbox on the owner's machine,
or a remote machine over SSH), chosen per run, through the same gate and
log, with the workspace checkpointed where the file system can.

## Goals

1. One layer that starts commands in an environment (`shell` now, MCP and
   the browser later): `host` (today, the default), `sandbox` (one backend
   per platform), `remote` (SSH).
2. A sandbox sees the workspace (rw, ro or not at all), a home of its own
   and the system's programs; not the data folder, the owner's home, any
   secret, nor the network unless switched on.
3. The owner pins environments by who started a run; definitions and steps
   set defaults; the agent may name another when not pinned and propose new
   ones (asked once, in full).
4. Rules and grants per environment; questions and log lines name it; stop
   and time limits end every process a command started; checkpoints are
   file roles' snapshots, cloned where the file system can.

## Non-goals (phase C)

VMs (Virtualization.framework, containers, WSL): second backends. Windows
Sandbox: not planned (Pro and Enterprise only, one at a time, slow start,
no channel for output). File tools on a remote; a workspace per environment;
Windows remotes; desktops (headdesk). MCP and the browser in a sandbox
(designed below, built after shell). Providers and clones: hosted.

## What the owner does

```ini
; environments.ini: optional; refused if others can write it; /reload applies
[default]
env = host               ; a run's environment unless named below
[box]
kind = sandbox
workspace = rw           ; rw | ro | none
network = off            ; off | on
read = /opt/tools, ~/go  ; more folders it may read; parallel = 2 by default
[buildbox]
kind = remote
host = agent@10.0.0.5    ; port = 22
dir = /home/agent/work   ; where its commands start
[use]                    ; pins: runs whose by matches always run here
app = box                ; every app (app:notes = box for one)
schedule = box
```

Names: a-z, 0-9, `-`, `_`, up to 32; `host` is built in.

```
harness env list               # kind, settings, backend found, home snapshots
harness env check box          # probes inside: what it can read, write, reach
harness env key buildbox       # its own SSH key; prints the line to authorize
harness env rm box             # its home and their snapshots, key, Windows ACEs
```

Chat: `/envs`, `/env check NAME`, `/env rm NAME`. Checkpoints are file
roles' snapshots: `/snapshot env:box`, `/snapshot /`, `/restore` (see
Checkpoints). Rules: `allow shell@box *`, `ask shell@host *`. Data:
`state/env/NAME/home/` (a sandbox's HOME, kept between commands);
`state/env/NAME/key`, `key.pub`, `known_hosts` (a remote's own key, 0600,
and pinned host key).

## Picking an environment

Per run, the first that applies: a `[use]` pin, a who pattern over the
run's `by` (the overview's Shared formats: `owner`, `schedule`,
`trigger:NAME`, `workflow:NAME/STEP`, `app:NAME`; a bare kind covers
every name, `*` as in rules); the workflow step's `env NAME` line (gap
7's modifier); the definition's `environment` (gap 1); `[default] env`.
Helpers take their parent's. `shell` takes an optional
`"env"`: an unpinned run may name any environment (the gate decides
`shell@THAT`); a pinned run naming another is refused before the gate. The
tool's description lists the run's environment and the others it may name,
with their settings.

## The gate and the log

`shell` keeps its kind and argument; the environment qualifies it. A rule
for `shell` matches everywhere, `shell@NAME` only there; a deny wins where
it matches; the default stays ask. A 24 h grant covers the command in that
environment only (`shell@NAME` in the grant's tool field, beside gap 5's
`who`; the overview's Grants). The question: `shell in box (sandbox;
workspace rw, no network): make test`. The written-files rule stays for
host and networked sandboxes, and is skipped in a sandbox with network
off (what the agent wrote reaches neither the data folder nor the
network) and on a remote (it doesn't see the workspace). Scheduled runs:
ask is deny, so `allow shell@box *` with `schedule = box` lets a task run
commands unattended.

New kind, with a tool of the same name: `env_save` (NAME) proposes a
section, shown in full and against the old one; a setup call (the
overview's Shared formats): asked every time (no 24 h, no allow rule lifts
it), offered only in runs the owner started from a conversation, never
`[default]`, `[use]` or `kind = host`. Checkpoints use file roles'
`snapshot` tool; no tool restores.

Shell's gate and tool lines carry `"env":"NAME"`. Kind `env`: `saved`
(name, settings, by, agent, item), `refused` (why), `removed`, `key made`
(fingerprint); snapshots log as file roles' `files` events.

## What crosses into a sandbox

The workspace at its own path (rw, ro or none); HOME = its home; its own
temp. PATH, HOME, LANG, TERM (Windows: the system's, with TEMP, TMP,
APPDATA, LOCALAPPDATA, USERPROFILE in its folder); never a secret or login
value (the overview's Secrets in commands). System programs and `read =`
folders, read-only. Network off: none, loopback included; on: outside
hosts (on Linux the host's loopback too).
Never the rest of the data folder, the owner's home or the key store. A
missing or refused backend is said by `env list`, `env check` and
`/status`; a run needing it is refused, never moved to the host.

## Backends

**Linux: bubblewrap.** On most desktops (Flatpak needs it), small, starts
in milliseconds, no daemon or root; it has mount, PID and network
namespaces, read-only binds, `--die-with-parent`. Containers' worth is
images and commits (later); docker's daemon is root; where Ubuntu's
AppArmor limits user namespaces, bwrap is allowed and our own code is not.
Started with today's small environment: `bwrap --unshare-all [--share-net]
--die-with-parent --new-session`, `--ro-bind` of `/usr`, `/bin`, `/lib`,
`/lib64`, `/sbin`, `/etc` as present, `--proc /proc --dev /dev --tmpfs
/tmp`, the workspace at its path, the home at `/home/agent` (HOME),
`--chdir`. The PID namespace ends with its first process: nothing outlives
a stop, `setsid` or not. No bwrap: "install bubblewrap".

**macOS: sandbox-exec.** Built in, nothing to download or sign, starts at
once, the owner's tools run as they are; browsers and coding agents use it,
so it stays despite "deprecated". A Virtualization.framework VM (Linux,
APFS-clone snapshots) is second: it needs an image, a binary signed with
the virtualization entitlement, and Objective-C calls from Zig.
`sandbox-exec -p PROFILE /bin/sh -c COMMAND` in its own process group, the
profile written per command: system paths readable; the owner's home and
the data folder not, except the workspace, its home and `read =`; writes
only to the workspace (if rw), its home and temp; `(deny network*)` when off,
outbound to non-local addresses when on; the Keychain's services denied. A
process that leaves the group survives a stop, as on host, inside the
profile.

**Windows: AppContainer and a job object.** Every edition since Windows 8,
nothing to install, starts at once; the same `CreateProcessW` with an
attribute list that I27 needs, plus one attribute; commands stay `cmd.exe
/c`; deny by default. WSL is second (`kind = wsl`): it must be installed, a
distribution made for harness with automount and interop off (or it reaches
every Windows file and program), bwrap inside for network off, the
workspace over slow 9P.

An AppContainer profile per environment (`CreateAppContainerProfile`, named
from the store id and NAME). Its SID gets inheritable ACEs: the workspace
(read and execute, or modify), its own folder (`GetAppContainerFolderPath`:
HOME, TEMP, APPDATA, ...), `read =` folders (read); adding one walks the
tree once, so it is done at first use and logged. Capabilities: none;
`network = on` adds `internetClient` (outside hosts, never loopback or LAN).
Spawn: `CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT |
CREATE_SUSPENDED | CREATE_NO_WINDOW`, attributes `SECURITY_CAPABILITIES`,
`JOB_LIST` (`KILL_ON_JOB_CLOSE`, no breakaway) and `HANDLE_LIST` (only its
pipes), then `ResumeThread`; stop, time limit, end: `TerminateJobObject`,
reads bounded as in I27. `env rm` removes ACEs and profile. Programs in the
user's profile (`%LOCALAPPDATA%\Programs`, nvm) need `read =`. Links
`userenv`.

## Remote

The system's OpenSSH (`ssh`; Windows `%SystemRoot%\System32\OpenSSH`);
harness doesn't speak SSH. `env key` runs `ssh-keygen -t ed25519` into
`state/env/NAME/` (the agent's own key, never the owner's), prints
`restrict ssh-ed25519 ... harness-NAME` for `authorized_keys`, fetches the
host key (`ssh-keyscan`) and keeps it once the owner confirms its
fingerprint in the terminal. Each
command: `ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -i KEY -o
UserKnownHostsFile=KH -o StrictHostKeyChecking=yes -p PORT HOST` and a POSIX
sh wrapper: `cd DIR`, the command single-quoted, its exit code reported;
sshd gives each session its own process group, which the wrapper kills when
the command ends or its stdin closes. harness closes stdin on stop or time
limit, then ends `ssh`. Remotes are POSIX shells (Linux, macOS, BSD).

## Checkpoints

Checkpoints are file roles' snapshots (the overview's Shared formats: one
mechanism, file roles owns it), so this spec keeps no store of its own. A
sandbox's home is the snapshot folder `env:NAME`; the workspace is
snapshotted as its folders. They are taken by hand (`/snapshot env:box`,
`/snapshot /`) or by the agent's `snapshot` tool (this spec's
`env_checkpoint`), and restored by the owner (`/restore`), which writes
files back in place, so Windows ACEs on the workspace and the home stay
and new files inherit them. The clones this spec chose (`clonefile` on
APFS, `FICLONE`/`copy_file_range` on btrfs and XFS, block cloning on ReFS
and Dev Drives) write the store's objects. One workspace serves all local
environments, so a restore restores it for all. VM backends add disk and
memory snapshots of their own.

## Later, other gaps, platforms

MCP: `env = NAME` per server in mcp.ini, its `state/mcp/NAME` bound instead
of the workspace, its named secrets crossing as today. Browser: `[browser]
env = NAME`; Chrome's own sandbox needs user namespaces in bwrap (or
`--no-sandbox`) and nests in sandbox-exec and AppContainer: test then.

Definitions (1): `environment`, helpers inherit. Roles (3): a sandbox
mounts `folders.view(who)` (each folder read-only or read-write) instead of
the whole workspace and starts in the call's `dir`; checkpoints are its
snapshots. Inbox (5): questions name the environment. Triggers (6),
workflows (7): pins, a step's `env` line. Apps (8): the `app` pins.

Windows is first-class: AppContainer and I27 land together; the host's
shell gets the job too (lifting README's "/stop ends a shell command but
not processes it started"), and MCP and browse use the same helper. Linux:
CI installs bubblewrap. macOS: the profile is tested on CI's oldest macOS.

## Hosted version

One VM per customer instance (Firecracker or a cloud VM) holds harness and
its data folder; inside, `[default] env = box` and runs aren't offered
`host`, so commands never see the instance's data or keys. Clones: kind
`cloud`, a sibling VM from a snapshot (a template or another's checkpoint)
that the hosted control plane (Elixir, beside omnigate) makes, snapshots
and removes at harness's request (https, the instance's token in its key
store), reached like `remote`, the workspace reaching them through the
customer's shared filesystem (file-roles spec): N agents on M VMs. A
cloud VM's own snapshots (`env clone NAME ID`) are the machine's; the
workspace's versions stay file roles' snapshots. The control plane
caps VM time as omnigate caps model spend (a spent budget refuses clones,
said like a 402). Home machines behind NAT need a connector that dials out
(with headdesk).

## Tests

- `environments_ini_refuses_bad_sections` (kinds, keys, values, a remote
  without host, pins or default naming nothing; names the line);
  `run_picks_pin_step_definition_default`;
  `pinned_run_cannot_name_another` (refused before the gate; unpinned: the
  gate decides).
- `shell_rules_and_grants_per_environment`: `allow shell@box *` allows in
  box, asks on host; `deny shell rm *` denies in both; a box grant doesn't
  cover host. `questions_and_log_lines_name_the_environment`.
- `written_files_rule_by_environment` (host, networked sandbox ask; offline
  sandbox, remote don't); `scheduled_task_runs_in_the_sandbox` (a host
  command is skipped and reported); `env_save_asked_in_full` (no 24 h;
  `[use]`, `[default]` and `kind = host` refused; not offered to
  scheduled, trigger, workflow, app or delegated runs).
- Each backend, skipped where missing:
  `sandbox_cannot_read_data_folder_or_home` (rules, log, `state/`,
  `secrets/`, a file in the owner's home);
  `sandbox_workspace_modes`; `sandbox_network_off` (a stand-in on
  127.0.0.1 and an outside address unreachable; on: outside reached);
  `sandbox_env_has_no_secrets`; `sandbox_home_persists`;
  `sandbox_stop_and_limit_end_every_process` (a background sleeper gone
  within 2.3 s; Linux after `setsid` too; Windows: the job is empty).
- `macos_sandbox_cannot_reach_the_keychain`;
  `windows_appcontainer_cannot_read_credentials` (`cmdkey /list`);
  `windows_aces_go_with_env_rm`; `linux_without_bwrap_refuses_plainly`.
- `remote_ssh_command_is_locked_down` (a stand-in `ssh` records the flags,
  the wrapper, a command with `'` quoted right);
  `remote_stop_ends_the_remote_command` (Linux CI, local sshd: no sleeper
  left; exit codes come back).
- Checkpoints: file roles' snapshot tests, and
  `a_restored_workspace_is_still_usable_in_the_sandbox` (Windows: the
  restored files keep the AppContainer's access; `env:NAME` round trip).

## Calls I made

- First: bubblewrap, sandbox-exec, AppContainer with a job object; VMs,
  containers and WSL second, for the reasons above.
- One workspace for all local environments; sandbox defaults: network off,
  workspace rw.
- `shell@NAME` in rules and grants, a plain `shell` rule covering all; the
  written-files rule skipped where a command reaches neither the network
  nor the data folder.
- Pins beat steps and definitions; the agent names other environments only
  unpinned; `env_save` never touches pins, the default or host.
- SSH through the system's OpenSSH, own key, `-F none`, pinned host key. A
  missing backend refuses the run, never falls back to the host.

Changed to fit the overview's Shared formats:

- Pins are who patterns over `by` (`app = box`, `trigger:mail = box`; was
  `app * = box`); `agent NAME` is no `by`, so pins don't name
  definitions: a definition's `environment` does.
- Checkpoints are file roles' snapshots: `checkpoints/`, `checkpoint.ini`,
  `[env] copy_mb`, `env checkpoint`, `env checkpoints`, `env restore`,
  `/env restore` and the `env_checkpoint` and `env_restore` tools are
  gone (the `snapshot` tool takes a checkpoint; only the owner restores,
  since a restore is refused while a run is going).
- `env_save` is a setup call, offered only in runs the owner started from
  a conversation; logged `saved` (was `created`, `changed`). `/env rm`
  added, so what the agent set up can be removed from chat (rule 2).

Settled (were questions for the owner):

- On Windows, AppContainer first (was question 2): every edition has it,
  nothing to install; WSL stays the second backend for Linux commands.
- POSIX remotes first (was question 3): Linux, macOS and BSD over the
  system's `ssh`; Windows remotes, with a cmd or PowerShell wrapper,
  later.

## Questions for the owner

Question 1 (where runs started by schedules, triggers, workflows and apps
run by default) is question 3 of the overview's "Questions for the
owner"; the others are settled above.
