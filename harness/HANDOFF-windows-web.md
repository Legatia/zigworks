# Handoff: the `web` tool on Windows

`web` (harness 0.3) drives headless Chrome over the DevTools protocol
through a pipe, never a network port. On macOS and Linux that pipe is file
descriptors 3 (commands in) and 4 (replies out). Windows needs its own way
to hand Chrome the two pipe ends; until then `agent.Run.allows(.web)` is
false on Windows and `cdp.Session.open` returns `error.Unsupported`.

## What Chrome does on Windows (to verify first)

With `--remote-debugging-pipe`, Chrome on Windows still wants "fd 3 and
fd 4", but Windows has no inherited file descriptors beyond the handles in
`STARTUPINFO`. Two ways are known; neither was tried here:

- The C runtime's fd inheritance: the parent passes a table of handles in
  `STARTUPINFO.lpReserved2`/`cbReserved2` (the format the MSVC runtime
  reads at start-up), and Chrome's runtime maps entries 3 and 4 to fds.
  This is what Node's `child_process` (libuv) does when Puppeteer passes
  `stdio: [..., 'pipe', 'pipe']`.
- A switch naming the handles, `--remote-debugging-io-pipes=READ,WRITE`
  (decimal handle values), present in recent Chromium sources.

Read `content/browser/devtools/devtools_pipe_handler.cc` of the Chrome
version in use and try the simpler one first.

## How harness spawns today (POSIX)

`cdp.Session.openPosix` runs

    /bin/sh -c 'exec "$@" 3<&0 4>&1 0</dev/null 1>/dev/null' sh CHROME ARGS...

with stdin and stdout as pipes, stderr ignored, in a new process group
(`pgid = 0`), so our stdin pipe becomes Chrome's fd 3 and our stdout pipe
its fd 4. Framing is JSON plus one NUL byte both ways (`cdp.Inbox`); a
reader thread polls the reply pipe every 50 ms and kills the process group
when the run's stop flag is set. `close` sends `Browser.close`, waits up to
3 s for the pipe to close (cookies get written), then kills the group and
reaps.

## What a Windows session needs to do

1. Create two anonymous pipes (`CreatePipe`) and mark the child's ends
   inheritable (`std.process.SpawnOptions.inherit_files` makes handles
   inheritable in Zig 0.17); hand them over by one of the two ways above.
   `std.process.spawn` has no `lpReserved2`, so the first way needs a
   direct `CreateProcessW` call.
2. Keep our ends non-inheritable; read with a blocking read in the reader
   thread (no `poll` on Windows), and end it by closing the handle.
3. Put Chrome in a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so
   its helper processes end with it (Windows has no process groups to
   kill), and on stop terminate the job.
4. Replace the POSIX-only parts of `cdp.zig`: `Pid`, `killGroup`, the
   `poll` in `readLoop`, and `close`.
5. Profiles: `web.setPrivate` is a no-op on Windows; the data folder's ACL
   is what protects `profiles\`.
6. Lift the Windows guard in `agent.Run.allows(.web)` and in
   `web.Web.runRaw`.

## Tests to enable

They skip on Windows now (`cdp.testBrowser` returns null there):

- `cdp.zig`: `chrome_over_a_pipe_evaluates_and_closes_without_leftovers`
  (on Windows: the job is empty after close), `chrome_ends_when_harness_goes_away`,
  `a_stop_ends_chrome_at_once`.
- `web.zig`: all `web_*` tests (the profile permission check in
  `web_fills_a_login_on_its_site` is POSIX only).
- `agent.zig`: `web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log`,
  and in `web_is_offered_only_with_a_browser_and_never_to_helpers` the
  Windows branch expects `web` to be offered.

The Windows key store (Credential Manager) limits a credential blob to
2560 bytes; `login-NAME-passkeys` holds about 300 bytes per passkey, so
more than about eight passkeys per login need splitting there.
