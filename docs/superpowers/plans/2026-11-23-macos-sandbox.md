# Mac session: the macOS sandbox and APFS clones (from 2026-11-23)

Branch `platform/macos` from 7f1504d (`harness-logins`). The Windows
session built the interfaces (`docs/superpowers/plans/2026-11-22-windows-platform.md`
§1 and §4); this adds the two macOS branches. Spec: gap 2,
`docs/superpowers/specs/2026-11-22-harness-environments-design.md`
("What crosses into a sandbox", "Backends", Tests). Test-driven; touches
only `sandbox.zig`, `clone.zig`, their tests, the README, one label in
`core.zig` and one comment in `snapshots.zig`.

## 1. The runner (`sandbox.zig`)

`run`'s third branch: `/usr/bin/sandbox-exec -p PROFILE /bin/sh -c
COMMAND` in its own process group (`pgid = 0`), then `tools.runChild`,
which ends the group on a stop, the time limit and the command's end.
Variables: PATH, HOME (`state/env/NAME/home`), TMPDIR
(`state/env/NAME/tmp`), LANG, TERM. `unavailable` is null on macOS, or a
plain line when `/usr/bin/sandbox-exec` is missing or can't apply the
profile (tried once).

The profile, written per command (SBPL `(version 1)(deny default)`; later
rules win over earlier ones; every path quoted, `\` and `"` escaped):

- Processes: fork, exec of what it may read, signals and process info
  within its own sandbox, sysctl reads. Set-id programs never run (the
  sandbox refuses them: ps, sudo).
- Read (and run, and map): `/usr`, `/bin`, `/sbin`, `/System`, `/Library`
  (not `/Library/Keychains`), `/opt/homebrew` (not its `var`, nor
  `/usr/local/var`, unless a `read =` folder names it), `/private/etc`,
  `/private/var/select` (which `/bin/sh` and xcode-select read), the time
  zones, the developer folder xcode-select names (Xcode's `.app` when it
  is in one); `/dev/null`, `/dev/zero`, `/dev/stdin|stdout|stderr`,
  `/dev/fd`, `/dev/random`, `/dev/urandom`.
- Services: user and group names (opendirectoryd libinfo) and notifications.
- Folders: `read =` folders read-only; the workspace as its mode says;
  its home and its temp read-write; their parent folders' metadata only
  (stat, never a listing), which git and realpath need.
- Never, even inside a `read =` folder: the data folder (but the
  workspace and the environment's own folder; refused again after a
  workspace that holds it), the workspace when `workspace = none`, the
  Keychains (`/Library/Keychains`, `~/Library/Keychains`).
- Network off: `(deny network*)`, loopback too. On: outbound to hosts
  other than this machine (`(remote ip "localhost:*")` refused, which
  covers all of its addresses), DNS (mDNSResponder's socket,
  `resolv.conf`), certificate checks (trustd), proxy and DNS settings
  (configd). No listening.
- The Keychain's services refused: `com.apple.SecurityServer`,
  `com.apple.securityd*`, `com.apple.security.*`, `com.apple.ctkd*`,
  `com.apple.secd`.
- Refused without a report in the system log: the owner's per-user temp
  (dirhelper, membership), logd, `/dev/tty`, `~/.CFUserTextEncoding`.

## 2. Tests

The six backend tests that skipped on macOS run there:
`sandbox_cannot_read_data_folder_or_home`, `sandbox_workspace_modes`,
`sandbox_network_off`, `sandbox_env_has_no_secrets`,
`sandbox_home_persists`, `sandbox_stop_and_limit_end_every_process`. New:
`macos_sandbox_cannot_reach_the_keychain` (a keychain of the test's own
in the workspace, one item: found outside, not inside),
`the_macos_profile_shows_only_what_the_environment_says`,
`a_path_cannot_break_out_of_the_profile`,
`macos_without_sandbox_exec_refuses_plainly`,
`macos_where_sandbox_exec_cannot_make_a_sandbox_it_says_why`, and
`an_apfs_clone_is_owner_only_and_an_unchangeable_file_is_copied_instead`.

## 3. Commands

`/env check NAME` and `harness env check NAME` name the backend
(sandbox-exec); `/envs` and `env list` say "ready" once `unavailable` is
null.

## 4. Clones (`clone.zig`)

`clonefile(src, dst, CLONE_NOFOLLOW)` through libc: true when cloned (the
new object made owner-only, like a copied one); false where the file
system can't (ENOTSUP, EOPNOTSUPP, EXDEV), leaving nothing; an existing
file is never overwritten (EEXIST is an error). A clone keeps its
source's flags, so a file made unchangeable (`chflags uchg`) is not
cloned (false: copied), since the store could neither rename nor delete
its clone. Both clone tests run on macOS;
`clones_share_blocks_on_copy_on_write_file_systems` uses its own
temporary folder when that is on APFS (statfs) and HARNESS_TEST_COW_DIRS
is unset.

## Rulings

- `/dev/tty` is not allowed (the task's list had it): a sandboxed command
  could write to, read from or push input into (TIOCSTI) the terminal
  harness runs in; bwrap's `--new-session` is there for the same reason on
  Linux. Cost if wrong: a tool that insists on `/dev/tty` fails at once
  instead of waiting for an answer nobody can give.
- TMPDIR is `state/env/NAME/tmp`, kept between commands and outside
  `env:NAME` snapshots; the owner's per-user temp (`/var/folders/...`) is
  refused by not letting the directory services compute it, so mktemp,
  xcrun and the like fall back to TMPDIR; `/tmp` is not reachable. Cost if
  wrong: a program that writes to `/tmp` by name fails (Apple's diff with
  process substitution does).
- `/Library` but its Keychains, and `/opt/homebrew` but its `var`: Ruby,
  Python, Java and Xcode's licence check need parts of `/Library`;
  Homebrew's tools on Apple silicon are where Intel Macs keep them in
  `/usr/local` (inside `/usr`), and its `var` holds services' databases
  and logs. Cost if wrong: a sandbox reads what other programs keep in
  `/Library` (most of it root-only by permissions).
- Network on reaches other machines on the local network too: SBPL tells
  this machine apart (all its addresses), not a LAN from the internet.
  `dig` and `host` don't work (they bind and listen for the answer);
  getaddrinfo, curl, git, Python and Go's resolver do. Cost if wrong: a
  networked sandbox can reach a router or printer.
- The data folder is refused even inside a `read =` folder (the spec's
  "never the rest of the data folder"), found as `state/env/NAME`'s
  grandparent's parent; Linux and Windows show it when a `read =` folder
  holds it. Cost if wrong: an owner who meant `read = ~/` to include the
  data folder doesn't get it.
- The stop test's macOS command has no `setsid` sleeper: macOS has no
  setsid command, and the spec lets a process that leaves the group
  survive. Cost if wrong: none for the test; such a process survives.
- The network test's "outside reached when on" half checks that a
  connection to 192.0.2.1 (TEST-NET-1, reaches no one) is not refused by
  the sandbox, instead of reaching a real host: no internet, no website,
  no skip offline. Cost if wrong: it would not notice DNS or TLS failing
  (checked by hand: `.invalid` names resolve to "not found", and
  certificates verify through trustd).
