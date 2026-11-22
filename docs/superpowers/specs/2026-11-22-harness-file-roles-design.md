# harness: roles on files (gap 3)

Follows `2026-11-22-harness-platform-overview.md` and gap 1
(`2026-11-22-harness-agents-design.md`: who does a call, who started its
run). Builds on harness 0.3 (branch `harness-logins`). Mac session, phase
B. The hosted note at the end is a sketch for the Windows session.

## Intent

The post: files should live apart from the computer that works on them,
with access attached to who acts (each agent with rights of its own, like
a person, or those of whoever started the turn), part code with history,
part documents and apps, each folder with its own settings and history.
For harness: workspace folders get roles per who (read, write, run),
checked by the gate on top of today's rules, and can carry their
commands' variables and keep snapshots, so agents' changes can be undone.

## Goals

1. Roles per folder in `folders.ini`, checked by the gate for `read_file`,
   `write_file` and a `shell` command's start folder, with who from gap 1:
   the definition doing the call, those that delegated it, and what
   started the run. Without `folders.ini`, file decisions are 0.3's.
2. A folder's `.env`: variables for host commands started there, from
   stored secrets, with no secret values in the workspace.
3. Snapshots of folders the owner marks, taken around the runs that change
   them, by hand and by the agent's `snapshot` tool; listed, compared and
   restored by the owner. The one way workspace versions are kept: gap
   2's checkpoints are these snapshots (the overview's Shared formats).
4. The Written-files rule names who wrote each file, and in a networked
   sandbox (gap 2) counts only files that sandbox can see.

## Non-goals

- A wall around shell commands on the host: a command runs as the owner
  and can leave its folder (README "Same user, same machine"); roles bind
  harness's file tools there and become a sandbox's mounts (gap 2).
- Roles on the data folder (settings, skills, definitions): no tool
  reaches it. Git as harness's versioning (an agent may still use git in
  any folder); an agent tool to restore; POSIX ACLs.

## What the owner does

`folders.ini` in the data folder (`harness init` writes comments only):

```ini
[/]
write = agent:main, agent:coder

[notes]
write = owner, agent:researcher, app:notes

[work/shop]
read = agent:main, agent:coder
write = agent:coder
run = agent:coder
vars = STRIPE_KEY:stripe-test, DATABASE_URL:shop-db
snapshots = on
skip = node_modules, *.log

[private]
read = owner
```

- A section is a workspace folder, written as file rules write paths
  (`work/shop`); `[/]` is the whole workspace; no `*`.
- `read`, `write`, `run` list who may. A folder without the key takes the
  nearest folder above that has it; with none, the key doesn't limit.
- Entries are who patterns (the overview's Shared formats): `agent:NAME`,
  `trigger:NAME`, `workflow:NAME/STEP`, `app:NAME`, `schedule:NAME`,
  `owner`; and `none`.
- `vars = VAR:secret, ...`: variables for host commands started in the
  folder or below (nearer folders win); values are stored secrets, masked
  in all output as stored secrets are. PATH, HOME, LANG, TERM and
  Windows's system variables can't be set.
- `snapshots = on` keeps 50, a number that many; `skip` patterns are not
  kept, nor `.git` folders; a folder inside a snapshotted one can't set
  its own.

Guarded like `rules`: refused if other users can write it (macOS, Linux),
a bad line is named, changes apply after `/reload`. Chat: `/folders`
(each section; variable names, never values); `/access WHO` (what WHO may
read, write, run: `/access agent:researcher`); `/snapshots FOLDER` (id,
time, label, run, agent, by, files changed); `/snapshot FOLDER [LABEL]`
(one now); `/changes FOLDER ID` (files added, changed, removed since the
snapshot before); `/restore FOLDER ID` (refused while a run is going;
snapshots now, then puts the folder back as at ID). FOLDER is a
workspace folder, or `env:NAME` for a sandbox's home (gap 2). CLI:
`harness snapshot list|take|changes|restore`, as `harness memory`.

## Design

### Who

From gap 1's `Who`: the definition doing the call (D, `agent:D`), those
that delegated it (D1…Dk), and the run's origin, its `by` (the same for
the whole chain): `owner`, `schedule:NAME`, `trigger:NAME`,
`workflow:NAME/STEP` or `app:NAME`. An app's own call, outside a run,
has no definition: its who is `app:NAME` alone. A list allows a call
when the origin is `owner` or `schedule:…` and an entry matches it (then
any definition passes); otherwise each of D, D1…Dk must match an entry,
and so must the origin unless it is `owner` or `schedule:…`.

So `write = agent:coder` lets coder write in runs the owner or a schedule
started (a trigger's runs of coder need `trigger:NAME` too); `read =
owner`, every run the owner started; `read = agent:*`, any definition in
no trigger, workflow or app run; `none`, nothing. The example's `[/]`
keeps trigger, workflow and app runs from writing where no folder names
them.

### The gate

`Gate.decide` gets one step: (1) hard limits, as today; (2) roles:
`read_file` needs `read` on the path, `write_file` `write`, `shell` `run`
on its start folder; (3) rules, grants, defaults, with gap 1's sections.
A role refusal is final: no rule, grant or answer lifts it, nothing is
asked, and it is not listed as "Skipped (needs approval)". The reason
says what to change: `folders.ini [work/shop] write: agent:researcher is
not listed`.

The path is the one file rules see (`Confined.rel`: inside the workspace,
symbolic links followed, `/` between parts, case ignored on macOS and
Windows); a section's folder is read the same way; a path is in a folder
when it is that folder or below it (`notes2/a` is not in `notes`). `Gate`
gets `folders`; `Ctx` gets `who` (gap 1) and `dir`. Other ways to
workspace files take the same check with their own who: an app's reads
and acts (gap 8: its manifest's `files` stays what the app asked for and
was approved with; `folders.ini` is what the owner shares; both must
allow), a file trigger's reads (gap 6, whose own rule that its runs don't
write where it watches stays), and environments (below).

### Where commands start, and their variables

`shell` gets an optional `dir`: a workspace folder (default the
workspace), confined like a file path (outside: refused), where the
command starts; the question shows it, rules still match the command, the
tool's log line has it. On the host the command gets the `vars` of every
folder from `[/]` down to `dir`, and can still `cd` out: `run` and `vars`
decide where it starts and what it gets, not what it reaches. In a
sandbox (gap 2) it is a wall: the sandbox mounts the folders its run's
who may read (read-only) and write, nothing else of the workspace, and
starts in `dir`; no `vars` cross (the overview's Secrets in commands).
A remote doesn't see the workspace: its commands start in its own
`dir`, and roles don't apply there. This spec gives
`folders.view(who)`, a list of (folder, read or write); gap 2 mounts it.

### The Written-files rule

Unchanged: after a file is written, a shell command a rule or grant
allows is asked first, naming the files, until the owner allows one;
unattended it is refused and listed. One list per instance stays, since
on the host a command can read any file. Each entry now names who wrote
it, `notes/a.md (agent:researcher, chat/h1)`: `PATH<TAB>WHO RUN` lines
in `state/written` (`app:NAME` for an app's; a 0.3 line: unknown). Gap 2
skips the rule in a sandbox with network off and on a remote; in a
networked sandbox a command is asked only about files that sandbox can
see (`folders.view`), since the rest can't change what it runs.
Snapshots show what changed afterwards; the rule still asks before.

### Snapshots

The store is `snapshots/` in the data folder, out of every file tool's
reach: `objects/ab/<sha256>` holds each content once; `folders/<key>/<id>`
(key: the first 16 hex digits of the folder path's SHA-256) is one
snapshot: a JSON header line (folder, time, label, rid, run, agent, by,
before, after or by hand), then `sha256 TAB size TAB exec TAB path`
lines. Objects are written by cloning where the file system can
(`clonefile` on APFS, `FICLONE` on btrfs and XFS, block cloning on ReFS
and Dev Drives; the Windows session writes these helpers), else copied.

- Taken for each folder with `snapshots` before a run's first call that
  can change it (a `write_file` in it, or any `shell` call, since harness
  can't see what a command changes) and when that run ends. A file is
  hashed again only if its size or modification time changed, or that
  time is within 2 s of the last snapshot.
- Also taken by hand (`/snapshot`, `harness snapshot take`) and by the
  agent's `snapshot` tool (`folder`, `label`; gate kind `snapshot`,
  argument the folder, default allow), which is gap 2's checkpoint: of
  any workspace folder, or of `env:NAME`, a sandbox's home
  (`state/env/NAME/home`), which only these take. They are kept with the
  folder's others.
- Not kept, and named in the snapshot: `.git` folders, `skip` matches,
  symbolic links, files over 100 MiB. A folder over 20,000 files or 1 GiB
  gets none, and `/status` says why.
- Kept: the newest N per folder, at most `[limits] snapshot_mb` (default
  5120) in all, oldest dropped first; objects no snapshot names are
  deleted at start and after each run.
- `/restore` snapshots first, writes back each file that differs (never
  through a symbolic link; in place, so a folder's Windows ACEs stay and
  new files inherit them), deletes files not in ID (skipped ones stay),
  and says what it wrote and deleted and the id that undoes it. Only the
  owner restores: no tool does.

Not git: harness stays std only and git is not on every machine; a
harness repository would collide with the agent's own `.git` folders; and
history kept in the workspace is history the agent's tools can rewrite.
Gap 2 keeps no store of its own: its checkpoints are these snapshots (its
`env_checkpoint` is the `snapshot` tool, an environment's home is
`env:NAME`, its clones write the objects), so one store, one set of
limits and one restore cover both.

### Data, code, log

`folders.zig`: parse (with `config.lines`), `allows(folders, rel,
access, who)`, `varsFor(dir)`, `view(who)`. `snapshots.zig`: take, list,
compare, restore, prune, with the clone helpers. `Paths` gets `folders`
and `snapshots`; `tools.Env` gets the command's extra variables;
`agent.zig` snapshots before a run's first changing call and at its end;
`folders.ini` joins the guarded and watched settings files. Log: a role
refusal is a `gate` line (`deny`, the reason, who from gap 1); `shell`
lines carry `dir`; a new kind `files`: `snapshot` {folder, id, when,
label, files, changed, bytes, rid, agent, by}, `snapshot skipped`
{folder, why}, `restore` {folder, id, before_id, written, deleted},
`prune` {snapshots, objects}.

### Other gaps

Gap 1: `agent:NAME` entries and the who chain; a definition's own state
is a folder only it may write. Gap 2: mounts from `folders.view` and
`dir`, no `vars`; its checkpoints are snapshots. Gap 4: the `by` values
entries match. Gap 6: `trigger:NAME`; a file trigger reads with its
roles. Gap 7: `workflow:NAME/STEP`. Gap 8: `app:NAME` and its `files`.
Gap 5: nothing to approve: `folders.ini` has no setup tool, only the
owner changes it; a role refusal is no approval.

## Platform notes

All three. Folders and paths compare as file rules do; `\` is accepted
in `folders.ini` on Windows. Snapshots keep the executable bit on macOS
and Linux (Windows has none); symbolic links are never kept or restored.
On Windows a file another program holds open can't be replaced:
`/restore` names it and goes on. Some file systems keep times to 2 s,
hence the 2 s rule. Windows `vars` names compare without case.

## Tests

- `no_folders_ini_keeps_every_0_3_decision` (gate.zig's cases);
  `a_list_limits_only_its_access`; `the_nearest_folder_with_the_key_wins`;
  `none_refuses_every_run`; bad lines named; others can't write it.
- `every_definition_in_the_chain_must_be_listed` (main delegates to
  researcher, main unlisted: refused); `owner_listed_lets_its_runs_through`
  (and `schedule:*`); trigger, workflow and app origins must be listed;
  an app's own call is checked as the app, with its manifest's `files`.
- `folders_match_like_file_rules`: `./`, the workspace's path, case on
  macOS and Windows, a link into the folder, `\`, `notes2` not `notes`.
- `a_role_refusal_is_final_and_nothing_is_asked`: despite `allow
  write_file *` and a grant; the asker is not called; nothing skipped.
- `shell_dir_is_confined_and_needs_run`; folder `vars` reach a host
  command masked, never a sandbox's, and can't set PATH, HOME, LANG, TERM
  or system variables.
- `written_entries_name_who_wrote_them` (0.3 lines read); a networked
  sandbox is asked only about files it can see (stand-in until gap 2).
- `a_snapshot_is_taken_before_the_first_change_and_at_the_end`; unchanged
  files are not stored again; the 2 s rule; skipped files named, a huge
  folder refused; old snapshots and their objects deleted;
  `restore_puts_back_deletes_added_files_and_can_be_undone`, not mid-run.
- `the_snapshot_tool_takes_one_with_its_label` (also of `env:NAME`, a
  sandbox's home; no tool restores);
  `objects_are_cloned_where_the_file_system_can` (APFS on macOS CI; a
  plain copy elsewhere; restored files match).
- smoke.sh: `folders.ini` limiting researcher; a delegated write refused
  with the reason; a snapshot, `/changes`, `/restore`; `log verify`.

## Calls I made

- A file of its own, not more `rules`: in rules a deny wins and nothing
  says "only these"; a folder lists who may, as a shared repository or
  Drive folder does. The nearest folder with the key decides.
- The whole chain must be listed (no definition gets another to do what
  it may not); owner and schedule origins are the owner's own. A role
  refusal is final; the owner changes `folders.ini`.
- `run` is a command's start folder (new `dir`), a wall only in a
  sandbox; a folder's `.env` is `vars =` naming stored secrets.
- Snapshots by harness, outside the workspace, opt-in per folder; one
  Written list per instance, now naming who wrote each file.

Changed to fit the overview's Shared formats:

- Entries are who patterns; a schedule is `schedule:NAME` (was
  `schedule:task/NAME`), and the origin is the run's `by`.
- Snapshots are the one mechanism for workspace versions: gap 2's
  checkpoints became snapshots taken by hand or by the new `snapshot`
  tool (its `env_checkpoint`), of a folder or a sandbox's home
  (`env:NAME`), with gap 2's clones as the store's fast path. CLI under
  `harness snapshot`; snapshots carry a label.

Settled (were questions for the owner):

- Snapshots stay opt-in per folder (was question 1): no disk is used
  unless a folder asks, and `[/]` with `snapshots = on` covers the whole
  workspace for an owner who wants it.
- One store for snapshots and checkpoints (was question 2), decided in
  the overview.
- Hosted: a customer's folders never leave that customer (was question
  3); folders shared between customers would be a design of their own,
  later.

## Questions for the owner

None left: the three above are settled.

## Hosted note (sketch for the Windows session)

- One filesystem per customer, shared by every instance and environment:
  contents in object storage (S3, R2), the tree in a metadata database,
  mounted as POSIX where commands run (JuiceFS-like FUSE) and reached
  through a gateway by harness's file tools and apps.
- Roles move from the machine to the filesystem's front: each run gets a
  short-lived credential naming the customer, its definitions, origin and
  run; the gateway checks `folders.ini` (kept by the control plane) on
  every open, create, rename and delete. A sandbox mounts only what its
  credential may read (read-only) or write, and can't widen it inside.
  Folder variables come from the secret store (keygate), never the files.
- Snapshots keep their format on object storage (objects shared by a
  customer's snapshots, indexes in the metadata database). The gateway
  sees every write, shell's too: the Written list and snapshots get exact.
- The GitHub part (code, extensions, definitions): a git repository per
  customer for `agents/`, skills and code folders, with history and
  review. The Drive part (files, apps): folders shared by `folders.ini`
  sections, shown in apps (gap 8). Between instances: close-to-open
  consistency, the last writer wins, POSIX locks where tools need them.
  One bucket prefix and encryption key per customer.
