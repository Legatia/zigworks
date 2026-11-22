# Handoff: the 2026-11-21 audit, the Windows parts

What the audit (docs/superpowers/plans/2026-11-21-harness-audit-fixes.md)
left for a Windows machine: I27, the mintty echo, and checks of what the
runtime fixes changed on Windows without being run there. Line numbers are
those of branch `fix/runtime` (commit after e7be6f7); after the merge,
search for the function names given with them.

Run everything with `HARNESS_HOME` and `HARNESS_STORE` set to scratch
folders, except where a step says to use the Credential Manager.

## 1. I27: what a command starts must end with it (job objects)

Windows has no process groups. Today a stop or a time limit ends the one
process harness started, and the threads reading its output are joined
with no limit, so a grandchild that holds the pipe open hangs the call,
`/stop`, `/reload` and the exit.

Where:

- `tools.zig` `shell` (224-229): on Windows two `Collector.pump` threads
  (145) read with blocking reads and are joined before `child.wait`;
  `Watch.killAll` (187-190) calls `TerminateProcess` on the child only.
  `cmd /c start /b ping -n 60 127.0.0.1`, MSBuild, gradle and any `npx`
  (`npx.cmd` starts `node.exe`) keep stdout open after `cmd.exe` is gone.
- `mcp.zig` `Server.shutdown` (409-433): `killTree` (596-599) is
  `TerminateProcess` on the server only, then `th_out`/`th_err` are joined
  (427-428) with no limit; `ready` (497-500) returns true at once on
  Windows, so `readOut`/`readErr` sit in a blocking read. An MCP server
  started through `npx` leaves `node.exe` holding both pipes: `/reload`,
  `harness` exit and `endBySignal` hang there.
- `page.zig` `render` (1212-1215, `browse`): one blocking `Collector.pump`
  joined without a limit; `killAll` (1158-1164) ends Chrome's first
  process only, its helpers keep the pipe.

What to build (one helper, used by all three and by Chrome for `web`):

1. A job object per child: `CreateJobObjectW(null, null)`, then
   `SetInformationJobObject(job, JobObjectExtendedLimitInformation, ...)`
   with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. No `BREAKAWAY_OK`: a
   process created with `CREATE_BREAKAWAY_FROM_JOB` then fails instead of
   escaping.
2. The child must be in the job before it can start anything.
   `std.process.spawn` has no `CREATE_SUSPENDED`; either call
   `CreateProcessW` yourself with `CREATE_SUSPENDED | CREATE_NO_WINDOW`,
   `AssignProcessToJobObject`, then `ResumeThread`, or pass the job in a
   `PROC_THREAD_ATTRIBUTE_JOB_LIST` attribute (Windows 10+). Assigning
   right after `spawn` leaves a window in which `cmd /c start` can escape:
   don't.
3. Stop, time limit and the normal end (after `child.wait`, like the POSIX
   `kill(-pgid)` at tools.zig:243): `TerminateJobObject(job, 1)`, then
   `CloseHandle(job)`. If harness itself dies, the handle closes and the
   job's processes die with it (that is what KILL_ON_JOB_CLOSE is for).
4. Bounded drains: once the job is terminated every writer is gone and the
   reads see EOF. Still bound them, as POSIX does (`pumpUntil`, 2 s): read
   in a loop of `PeekNamedPipe` (bytes available, else sleep 20-50 ms and
   look at an `ended` flag) instead of a blocking `ReadFile`, or end a
   stuck read with `CancelSynchronousIo` on the reader thread. Then the
   joins at tools.zig:227-228, mcp.zig:427-428 and page.zig:1214 can't
   hang. In `mcp.zig` make `ready` (497) use the same peek loop, so
   `s.ended` works on Windows too (`shutdown` sets it only on POSIX,
   420-426: set it on both).
5. Lift the Limits line in README ("`/stop` ends a shell command but not
   processes it started") once this is done.

What to test (by hand, and as tests where they can be):

- `tools.zig` `shell_is_killed_on_stop_with_children` and
  `a_child_that_leaves_the_group_does_not_hang_the_command` skip on
  Windows: add Windows versions, e.g. `cmd /c start /b ping -n 30
  127.0.0.1 & ping -n 30 127.0.0.1` stopped after 300 ms returns in under
  2.3 s, and afterwards `tasklist /FI "IMAGENAME eq PING.EXE"` lists none;
  `cmd /c start /b ping -n 8 127.0.0.1 & echo started` returns "started"
  and exit code 0 in under 5 s.
- `mcp.zig` `deinit_leaves_no_process_behind` skips on Windows: a server
  started as `cmd /c "start /b ping -n 30 127.0.0.1 & harness-fake.exe
  --mcp"` (or through a `.cmd` file) leaves no `PING.EXE` after `deinit`,
  and `deinit` takes under 2 s.
- `browse` of a page in Chrome, then `/stop` mid-render: no `chrome.exe`
  of harness's left.
- With an `npx`-started MCP server in mcp.ini: `/reload` five times, then
  close: no `node.exe` left, nothing hangs.

Done: those tests pass on Windows in CI, the manual checks leave no
process behind, and nothing in shell, MCP or browse can make a call,
`/stop`, `/reload` or the exit wait longer than its time limit plus 2 s.

## 2. Hidden input echoes under mintty / MSYS (main.zig `Echo.off`, 931-943)

`Echo.off` ignores what `GetConsoleMode` and `SetConsoleMode` return.
Under mintty (Git Bash) and MSYS ptys stdin is a pipe, not a console: both
calls fail, echo stays on, and `secret add` / `login add` print "(not
shown)" while the value is shown as it is typed.

Fix: when `GetConsoleMode` fails, the input is not a console. Then refuse
to read a secret there ("type it in a Windows console (cmd, PowerShell,
Windows Terminal), or pipe it with --stdin"), unless it is a pipe that
`--stdin` was given for. `GetFileType(handle) == FILE_TYPE_PIPE` together
with `MSYSTEM` or `TERM_PROGRAM=mintty` in the environment tells the
mintty case apart from a real pipe; `--stdin` stays the way to pipe a
value. Only restore the mode in `restore` (945-951) when `off` changed it.

Test: in Git Bash (mintty) `harness secret add x` refuses with that
message and stores nothing; `printf 'abcdefgh12\n' | harness secret add x
--stdin` stores it; in cmd, PowerShell and Windows Terminal the value is
not shown and is stored. Done: no way left to type a secret that shows.

## 3. The folder lock (core.zig `takeLock` 1786, `lockHeld` 1814)

The lock is now an exclusive `LockFileEx`-style lock (std's
`createFile(.lock = .exclusive, .lock_nonblocking = true)`, which uses
`NtLockFile` on byte 0) held for the process's life, instead of a pid
file judged by the status file's age. `health` (core.zig `health`, 1827)
asks the lock (`tryLock(.shared)`) and counts only `harness run` (the
status file's `role run` line). On Windows the locked byte can't be read
by others: `type state\lock` failing while harness runs is expected.

Check:

- Two `harness chat` in two consoles: the second says "harness is already
  running".
- `harness run`, then `taskkill /F /PID <pid>`: a new `harness run` starts
  at once (no 90 s wait), `harness health` says "not running" right after
  the kill.
- While `harness run` runs: `harness health` exits 0; while only `harness
  chat` runs: "not running: harness chat holds the folder, not harness
  run", exit 1.
- smoke.sh skips "memory list works offline" on Windows because of the old
  90 s lock (its comment near the end); with the new lock it can run there
  too: enable it and see it pass.

Done: all four hold.

## 4. Ctrl-C and closing the console (main.zig `console`, 826-844; `catchSignals` 849; `watchSignals` 879)

`SetConsoleCtrlHandler` routes Ctrl-C, Ctrl-Break and the console's close,
logoff and shutdown events to the same path as SIGINT/SIGTERM on POSIX
(`Core.endBySignal`, core.zig 1142): what `/stop` does, the MCP servers
killed, "signal" and "stop" written to the log, the status, the lock let
go, exit 0. For close/logoff/shutdown the handler waits up to 4.5 s for
that (Windows ends the process when it returns). A second Ctrl-C exits at
once. None of it was run on Windows.

Check, in `harness chat` with an approved `ping -n 30 127.0.0.1` running:

- Ctrl-C: harness ends within 3 s; `harness log tail 3` shows
  `"event":"signal","signal":"Ctrl-C"` then `"event":"stop"`; `harness log
  verify` says intact; `harness memory list` works at once (lock free).
  After section 1 is done, no `PING.EXE` is left.
- The same with the console window closed instead (CTRL_CLOSE_EVENT): the
  log lines are there.
- A process started without a console (no handler fires): after `taskkill
  /F` the lock is free; with section 1 done its children die with it.

Done: the log shows the signal and the stop each time, the folder is free,
and nothing harness started keeps running.

## 5. Secrets in the Credential Manager (store.zig)

- Namespaces (I19): the built-in folder (`%LOCALAPPDATA%\harness`, no
  `--home`, no `HARNESS_HOME`) keeps targets `harness:NAME`, so secrets the
  Windows session stored before still work with nothing to do. Any other
  folder gets `harness-<16 hex>:NAME`, the prefix kept in
  `state\store-id`. Check with `cmdkey /list` (or the Credential Manager):
  the old secrets are found by `harness secret list` in the built-in
  folder; `harness --home C:\other secret add x` makes a target
  `harness-...:x`; `harness --home C:\other login rm NAME` leaves the
  built-in folder's `harness:login-NAME-*` alone.
- Targets are bounded (`targetName`, 256 UTF-16 units, printable ASCII
  only) and values capped at 2560 bytes (`wincred_max_value`):
  `secret add` refuses a longer value with that limit in the message.
  Check: a 3000-byte value piped to `secret add x --stdin` is refused, a
  2560-byte one is stored and read back whole by `secret list` / the
  server that uses it.
- `login-NAME-passkeys` holds about 300 bytes per passkey: from about
  eight passkeys a login's record no longer fits; `put` now says
  `error.ValueTooLong` instead of a vague failure. Split or compress the
  record when `web` comes to Windows (section 6).

## 6. The web tool

Follow HANDOFF-windows-web.md. Two things from this audit: put Chrome in a
job with the helper from section 1 (that document's point 3), and mind the
2560-byte passkey record (section 5). The audit's web findings (W's: I14,
I15, K3, K9-K16, K18) change cdp.zig, web.zig and page.zig: read them
after the merge before porting the pipe code.

## 7. CI on Windows after the audit (run 45008431071, 49725b9: all green)

Fixed from here and passing in CI on Windows (Debug and ReleaseSafe):
`write_file` failed with AccessDenied (Windows refuses to stat a handle
opened only to write; `writeNoFollow` now opens with read access); every
check of the turn's time is in milliseconds; a turn's end is rounded up to a
whole second (a 1 s turn begun late in a second used to get nothing — that,
not the socket wait, was the ReleaseSafe failure).

Still open on Windows: `write_file_never_writes_through_a_symlink` and
`a_symlink_whose_target_is_missing_is_refused_and_written_files_are_never_links`
skip there; make them run if Windows can make the links (junctions count),
and check that a fetch is cut at the turn's end and on /stop in a real run.

## Tests that skip on Windows (and their checks above)

- core.zig: `stop_ends_running_turn_and_reports`,
  `a_signal_stops_what_runs_logs_it_and_lets_go_of_the_folder` (section
  4), `mcp_servers_run_in_a_folder_of_their_own_not_the_workspace`,
  `mcp_servers_start_together_under_one_deadline`,
  `reload_holds_no_lock_while_servers_start_and_stop_cuts_it_short`,
  `a_value_added_while_a_turn_runs_is_masked_in_every_tool_from_then_on`
  (all use `/bin/sh`; cmd.exe versions would do: `cmd /c "cd >&2 & exit
  1"` prints the folder a server runs in, which must be
  `state\mcp\NAME`).
- main.zig: `sigterm_is_caught_and_noted_not_the_end_of_the_process`
  (section 4 by hand).
- tools.zig, mcp.zig, page.zig: see section 1.
