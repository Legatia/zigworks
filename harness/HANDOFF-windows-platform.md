# Handoff to the Windows session: platform work (gaps 2 and 8, Windows items, hosted notes)

From the Mac session, 2026-11-22. The owner asked to spec the gaps between
harness and the "Agent platform of 2027" blueprint and to share the work
with you. Eight specs are written and reconciled; you own apps (gap 8),
environments (gap 2), the open Windows items and the hosted design notes.

## For you: 0.4.0 was run from its release on macOS; 0.4.1 follows (2026-11-27, evening)

- The owner: "Just do everything necessary to make sure this product works well." The released macOS harness and desk app were downloaded and run (the smoke against the released binary: 183 ok); the Linux arm64 archive was only read. Nobody has run the released Windows or Linux packages yet: still yours if you have a moment, a line here is enough.
- The proxy met two real agents. Claude Code 2.1.322 connected to 0.4.0 as it is. Hermes 0.21.3 was refused: the MCP Python SDK sends `MCP-Protocol-Version: 2025-11-25` on `initialize` itself. `mcpserve.zig` now judges that header after the method is known and lets `initialize` through (the answer names the version harness speaks); every other method with a foreign version is 400 as before. Codex was not tried.
- Two changes in the desk page, files you also build on (`src/desk/index.html`, `desk.js`, `desk.css`):
  - Send is `disabled` in the page as served and `desk.js` enables it once the form's handler is there. If a smoke of yours clicks Send or submits the form right after the page shows, wait for the button to be enabled (or for the page's first message to the shell, as the macOS smoke does).
  - The conversation may be 34vh tall (22vh before; your "five lines"), and `.chat` shrinks before the stage does. Your shells need nothing for it; say so here if it looks wrong at your window sizes.
- `web.zig`'s test fixture has `f.session()` in place of `f.web.s.?`: a browser test whose browser is gone fails with "no browser session; the last action answered: …" and no longer crashes on null. A new test of yours in that file: use `try f.session()`.
- With a bot token stored and nobody paired, a message written on the desk was answered as a "Not delivered" item. Now, once the owner has written on the desk in this run (`Core.desk_written`), a post Telegram refuses with `error.NotPaired` in a conversation the desk shows is delivered to the desk (`DeskTee.unpaired` in `core.zig`), a reply with buttons as its text without them (`sendWithButtons`). Files and approvals are as before. All in `core.zig`; nothing for the shells.
- `test (windows-latest, calmcp)` failed on `main` for 7b10e54: "The hosted runner lost communication with the server", no log. If you see it again on your side, say so here.
- The README says the binary is "about 8 MB stripped" (it said 1.9 and 2.3 MB).
- 0.4.1 is these fixes; the version in both `build.zig.zon` files is 0.4.1 with the next commit. Take `main` into `platform/money` before its pull request.

## For you: harness 0.4.0 is tagged (2026-11-27, after the browser job)

- `harness-v0.4.0` is on 7dd2031, on `main`; the release is on GitHub with the four harness archives and the three desk packages. Your pull requests 2 and 3 are in it. Take `main` into `platform/money` before its pull request; the version in both `build.zig.zon` files is 0.4.0 now.
- One test changed after the browser job: `core.test.a_scheduled_run_waits_for_its_definitions_place` holds its first answer 2500 ms (800 before). It failed once on a slow macOS runner; if you saw it fail on Windows, that was this.
- Nobody has downloaded and run the released Windows or Linux desk package yet. If you do on your machine, a line here on what happened (the unsigned-app warning, WebView2, first run) is what the owner lacks.
- `git fetch --tags` says "would clobber existing tag" for `headdesk-v0.1.0` in a clone that has the older one: the tag names another commit on GitHub than in the Mac's clone. Nothing of harness's; left for the owner.

## For you: the browser tests are a CI job of their own (2026-11-27, late night)

- `zig build test` on your machine is as it was: the browser tests run with the rest.
- New: `zig build test -Dbrowser-tests=false` skips every test that starts a browser, and `zig build browser-test` runs only those (52 tests: all of `web.zig`, four of `cdp.zig`, three of `page.zig`, one of `agent.zig`). CI's `test` job does the first for harness; the new job `harness-browser` does the second on Linux, macOS and Windows, in Debug and ReleaseSafe. A failed browser test now fails that job alone and is run again in minutes.
- A new test of yours that starts a browser: get the browser from `cdp.testBrowser(a)` (null: `return error.SkipZigTest`), and add the test's name to `browser_filters` in `build.zig` (`FILE.test.NAME`; a test in `web.zig` is already covered). `scripts/check-browser-tests.sh` runs before the browser tests and fails the step, naming the file and line, when a test that calls `testBrowser` is not in the list.
- The script runs through `sh` with `awk`, as the smoke does; on Windows it has only run in CI. If it fails there for a reason of the shell's, that is where to look.
- `release.yml` builds without the browser tests now; a tag goes on a commit CI has passed.

## For you: harness is an MCP server for other agents (2026-11-27, night)

- Built and on `main`: the gate as an MCP proxy (README, "MCP", "For other agents (the proxy)"; spec `docs/superpowers/specs/2026-11-27-harness-mcp-proxy-design.md`). `harness run` serves MCP over HTTP on `[proxy] listen` (127.0.0.1:8766) to the agents named in `[client NAME]` sections; each of their calls passes the gate as `client:NAME` and is asked in `main` like any approval, its text starting `[client:NAME] `.
- Nothing for the desk shells or the page to do: the approvals arrive as inbox items like the others. The settings page doesn't offer clients; they are set in `config.ini` or with `harness config set client NAME.servers "github, notes"`.
- New in files you also build on: `mcpserve.zig` (new); `sock.zig` has `ended` (has the other side closed: an end, not more bytes), with a `peek` of its own for Windows (`recv` with `MSG_PEEK` on a non-blocking check). It cross-builds for Windows and its unit tests build there; it has only run on macOS and in CI. If a Windows run shows a client's hang-up not withdrawing its approval, that is where to look.
- Words that changed, in case a smoke or test of yours compares them whole: `/access` without a who now ends "…, /access app:NAME or /access client:NAME."; `/status` has one more line, `Proxy: …`, only when config.ini has a `[client NAME]` section. `/stop` counts a client's waiting call among what it stopped (it answered "Nothing was running." before).
- One change that reaches every run, yours too: an MCP call that was allowed while its run was being stopped is no longer sent; its result is "not called: its run stopped" (`agent.callMcp`).
- `who.zig` has a kind `client`; `agent.Run` has `client_money`; `Core` has the fields `proxy`, `proxy_active`, `proxy_key`, `proxy_mutex`, `proxy_note`, `proxy_warned`, `proxy_wait_ms`, `mcp_names` (each set in `open`: `open` starts from `undefined`, so a field of yours needs its line there too).

## For you: your pull request #3 is merged (2026-11-27, evening)

- `platform/trial` (b434984) is on `harness-logins` and `main`, fast-forward, with one commit of mine after it. Take `main` into `platform/money` before its pull request.
- macOS, which you couldn't run: harness's suite in Debug and ReleaseSafe on b434984, 1647 passed, 25 skipped in each, and the three cross builds with their unit-test builds. The one failed check on your pull request was `test (macos-15, harness)` in `web_waits_for_a_load_under_way_when_the_page_is_read` (web.zig:1872), the crash noted further down; nothing of yours.
- Your four rulings stand.
- Two changes on top of yours, in `core.zig` and the README's "Schedules":
  - A one-day schedule whose message could not be sent no longer stays in triggers.ini for good: its section goes when the message arrives (`oneDayRan`, called by the run and by `resendItem`). One whose sending was given up keeps its section.
  - `on` with a day already past is refused before it is added, by the tool and by `/trigger add`: "on = 2025-11-28 is already past (today is 2026-11-27)". Today's date is taken, also when its time has passed. If a test or smoke of yours adds a one-day schedule through the tool or `/trigger add`, give it today's date or a later one (writing triggers.ini directly is unchanged).
- Still yours to decide or the owner's: the desk's conversation at five lines; a release with pull requests 2 and 3 waits for the owner's word.

## For you: private conversations have a model of their own (2026-11-27, later still)

- Built and on `main`: `[model] private_model = PROVIDER:MODEL` (README, "Private conversations"; spec `docs/superpowers/specs/2026-11-27-harness-private-model-design.md`). While a conversation is private, every model call of a run in it goes there and nowhere else; after `/private off`, what was said while private is left out of what the other models are sent.
- Nothing for the desk shells or the page to do. The setup screen doesn't offer the setting; it is set in `config.ini` or with `harness config set model.private_model local:llama3.1:8b`.
- `/private on` and `/private off` answer with longer lines now (where the words still go; what is left out). If a smoke or test of yours compares those answers whole, compare their start: "Private here: nothing from this conversation is written to memory" and "Private is off here."
- One change that reaches every settings file: an error is named at the line that is wrong when an earlier line names what it is in (a mistake inside `[provider local]` is no longer reported at `[model] provider = local` or `private_model = local:…` above it). Files without such a reference are reported as before.
- `ModelCfg` (agent.zig) has a new field, `private`, and `Run` a new one, `on_private`; `Conversation.messagesFor(arena, leave_private)` is new and `messages` calls it. If `platform/money` builds a `ModelCfg` or reads a conversation's messages for a model, take `main` first.
- After the review (same day): `Conversation.Turn` has `on_private` (the private model answered it; `messagesFor(…, true)` leaves out exactly those turns, whatever the setting is later). The core's `Queued` has `private` (the conversation was private when the message came), and `chatTurnWith`, `voiceTurn` and `memberTurn` take a last argument `said_private`; a queued message's turn is private also after `/private off`. A brief for a private conversation is written by the private model. If `platform/money` calls one of those three functions or appends to the chat queue, take `main` first.

## For you: your pull request #2 is merged (2026-11-27, later)

- `platform/desk-win-linux` (c7960a3) is merged as a2c3a03, on `harness-logins` and `main`. Take `main` into `platform/money` before its pull request.
- macOS, which you couldn't run: harness's suite in Debug and ReleaseSafe (1618 passed, 25 skipped), the three cross builds, the desk app's unit tests (115 passed, 1 skipped) and the macOS smoke with the real harness and the stand-in model (137 checks, 0 failed). Your changes to the shared files (`desk-app/src/main.zig`, `testhooks.zig`, `mac/desk.h`, `test/fake_harness.py`) change nothing there.
- Your three rulings stand (the unsandboxed start where bubblewrap can't make a namespace, the access list skipped on volumes without them, headterm's 4 s hold).
- Your guess about the macOS smoke was right; it is the section below, fixed in baaf66e.
- Being built here next: a model of their own for private conversations (`docs/superpowers/specs/2026-11-27-harness-private-model-design.md`): `[model] private_model = PROVIDER:MODEL`. It touches `config.zig`, `agent.zig`, `core.zig`, `main.zig` and the README; nothing in the desk shells or the page. The setup screen won't offer the setting yet.

## For you: a finished load isn't the desk's script having run (2026-11-27)

- Seen on the macOS runner about one run in five: WKWebView said `finish …/desk` with the page still `interactive` and `desk.js` not yet run. A message typed then goes nowhere: the form has no handler yet and the page's `form-action 'none'` drops the plain submit. The text stays in the field; harness never sees it.
- `smoke.sh` now waits for the page's first message, `message desk {"badge":` in the app's log, before it types the message for the model. When `smoke-other.sh` gets its model-answer part, wait for the same line; WebView2 and WebKitGTK may or may not do this, and the wait costs nothing.
- When that check fails it prints the page's address, field, note and messages, the page's `readyState` and age when the message was typed, whether the page took the submit, the app's loads in order, the stand-in's requests and harness's own log.
- Seen once on `test (macos-15, harness)`, not understood: `web.test.web_waits_for_a_load_under_way_when_the_page_is_read` aborted with "attempt to use null value" at web.zig:1872. The same commit's other run passed.

## For you: harness 0.3.0 is released (2026-11-26)

- Tag `harness-v0.3.0` is on 90b54b5 (`main`). CI there: 34/34. The release run (45895040798) passed first time and published your two packages as you built them: `harness-desk-0.3.0-windows.zip` and `harness-desk-0.3.0-linux-x86_64.tar.gz`, beside the macOS zip and the four harness archives, each with a `.sha256`.
- `release.yml` changed before the tag: its Linux jobs install bubblewrap and openssh-server and allow user namespaces, as `ci.yml` does, so harness's sandbox and remote tests run there too.
- `package-macos.sh` changed: the zip is made without extended attributes and is checked by unpacking it with `unzip` and verifying the signature. Nothing of yours is touched; if `package-windows.sh` or `package-linux.sh` are ever run on a Mac, the same `._` files would end up in their archives.
- Still open with you: `DESK_SMOKE_FAKE` in `smoke-other.sh` (below), the headterm Windows smoke, the browser sign-in test.

## For you: `main` has it all, the day's earlier note (2026-11-26)

The owner said "Merge. Tag release when the app is functioning". `main`
was fast-forwarded to `harness-logins`; the tag will be `harness-v0.3.0`
(`release.yml`: archives, and the desk app for macOS, Windows and Linux).

One thing you may want in `smoke-other.sh`: the macOS smoke now takes
`DESK_SMOKE_FAKE=PATH` (harness-fake) beside `DESK_SMOKE_HARNESS`. The
real harness's provider is then the stand-in, with one answer in
`model/001.json`, and a message typed in the desk must come back with the
stand-in's words; the request must name `smoke-model` and carry the key
from the sheet (`scripts/smoke.sh`, "a message typed in the desk is
answered by the model"). Before this no smoke had a model answer through
the app. The Windows and Linux smokes still use the dead address; adding
the same there is yours, if you think it worth it.

## For you: your pull request #1 is merged; three things from its CI (2026-11-26)

`platform/desk-win-linux` (2ec1fa0) is merged into `harness-logins`
(merge d7d2b9b, then 0c76627). The only conflict was the ledger, where
both sides had appended; both are kept. Merge `harness-logins` back into
your branch before more work: it carries e2b1335 (the section below).

The https cause was checked against Zig 0.17.1's own `tls.Client` and
holds (the ledger has the arithmetic). Still true, as you wrote: no test
sends a request of that size over https.

1. **headterm's smoke check failed again on the Windows runner, and this
   time your change made it say why** (run 45850475103 on 0c76627,
   `test (windows-latest, headterm)`):

   ```
   FAIL: run with keys sent before the first output: exit 1: started run-8428 pid=4028
   1 send ok
   2 wait FAILED: failed(timeout) 10015ms
   screen at failure: ready
   ```

   So the keys went out before the program's flush: "ready" is on the
   screen and "got early" never came. Not looked into further; a guess
   only, from reading `run.zig:105` and `server.zig:725`: the hold before
   the first send ends after 2 s at most, and Python on a busy runner may
   take longer than that to start, sleep 0.4 s and flush. If that is it,
   the check has a time bound the runner can miss, and a program that is
   slow to start and flushes what was typed ahead loses keys in real use
   too. Yours to confirm or rule out.

2. **`agent.test.web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log`
   failed on the Linux runner** (2ec1fa0, run 45834721746), the test seen
   failing on Windows before. What it printed on failure was the request's
   tail, which is the tools' descriptions. From 0c76627 it prints from the
   last tool result on, which is the page as the model saw it. Cause still
   not known; if you see it fail again, the page's text will be there.

3. **Runner trouble, no test failure:** the Windows harness job lost its
   runner during the ReleaseSafe pass once more (run 45835095223, 70
   minutes in), and `test (macos-15, llmcheck)` was twice never given a
   runner.

## For you: the audit's second pass — what changed in shared code, and the Windows and Linux findings that are yours (2026-11-26)

The owner's instruction after the audit: "Fix everything not specifically
about windows or Linux. And add the windows and Linux ones in handoff for
windows session". So the shared Zig core, the macOS layer, harness and
the desk page are fixed on `harness-logins`; `windows/desk.c` and
`linux/desk.c` are untouched. Three lists follow: what waits on you in
the native layers, what changed under you, and what your smoke may trip
on.

### Yours: findings in the Windows and Linux layers (not fixed)

Most severe first. None was run here (no Windows or Linux machine); each
is from reading the code.

1. **Linux: the web process's sandbox is never turned on in code**
   (`linux/desk.c:447-468`: no `webkit_web_context_set_sandbox_enabled`),
   while `ci.yml:178-182` says the web process runs under bubblewrap and
   turns Ubuntu's userns restriction off for the smoke. One of two is
   true: the sandbox is off (app pages an agent wrote render unsandboxed),
   or it is on and a stock Ubuntu 24.04 with the restriction left on
   shows a blank window. Needs one run on stock 24.04 without the sysctl,
   then the call and the README's line to match.
2. **Linux: the microphone decision ignores which frame asked**
   (`linux/desk.c:395-407`): every user-media request is judged by the
   window's URL with `main_frame = 1`, and a request that is neither audio
   nor video is taken as the microphone. Only the iframe's attributes stop
   a framed app today. The same file passes `1` as `main_frame` to
   `hdesk_on_message` (`:386`). Windows tells frames apart
   (`windows/desk.c:497-500`).
3. **Both: the web view's own context menu is left on**
   (`windows/desk.c:584-614`: no
   `put_AreDefaultContextMenusEnabled(FALSE)`; `linux/desk.c:477-482`: no
   `context-menu` handler). Right-click offers Print, Save as, Open link
   in new window, Download linked file. New windows and downloads are
   refused already; the print and save dialogs are reachable.
4. **Windows: the declared minimum WebView2 runtime (86.0.616.0,
   `windows/desk.c:674`) lacks interfaces the policy needs.** Download
   blocking and the per-frame permission use `ICoreWebView2_4` and
   `Frame3` (`:497-500`, `:623-627`), and a failed `QueryInterface` is
   skipped silently: on an old fixed runtime downloads go through and a
   frame's microphone request arrives as the main frame's. Raise the
   minimum to the first runtime that has both, or refuse to start without
   them.
5. **Windows: children inherit handles.** Zig's spawn calls
   `CreateProcessW` with `bInheritHandles = TRUE` and no handle list, and
   Winsock sockets are inheritable by default; the comment at
   `desk-app/src/alive.zig` ("sockets are not inherited") is wrong for
   Windows. Scenario: Start harness is clicked while the check's socket is
   open, and the long-lived `harness.exe` keeps a copy. Impact
   unconfirmed. (`alive.zig`'s Winsock path changed in this pass, see
   below; the socket is still created the same way.)
6. **Linux: the release's baseline floats.** `release.yml` builds the
   Linux package on `ubuntu-latest`, `package-linux.sh:65` links the
   runner's glibc and WebKitGTK, and the README promises Ubuntu 24.04.
   Pin `ubuntu-24.04`.
7. **Windows: `hdesk_post_main` ignores a `PostMessageW` failure**
   (`windows/desk.c:946-948`): a job finishing after the window is
   destroyed is leaked and never delivered. Only at exit.
8. **Windows: `state\desk-code` is protected by the folder's ACL only.**
   macOS and Linux write it mode 600 in a 700 folder. Under
   `%LOCALAPPDATA%` the inherited ACL is the owner's; a `--home` outside
   it (another drive, a shared folder) was not examined. Either set an
   owner-only ACL on the file, or refuse a folder others can read.
9. **Not confirmed, worth a look:** Windows judges a message as the main
   frame's by URL equality (`windows/desk.c:411-414`); Linux's display
   capture mapping; Linux GStreamer packages for sound and the
   microphone.

### Shared code changed under you: the native halves to do

The rule kept here: no edit to your two files. Where the core needed
something new from the native layer, it got a NEW export that only
`mac/desk.m` calls, and the old export behaves as before for you.

- **Outside links open only on a person's click** (`policy.decide(url,
  port, frame, by)`, `By{ click, app }`). New export
  `hdesk_on_navigate_from(url, frame, clicked)`; the old
  `hdesk_on_navigate(url, frame)` counts every navigation as a click, so
  on Windows and Linux a script's `location =` or `window.open` to
  another site still opens the system browser. Switch to the new one
  with a real flag: WebView2 `NavigationStartingEventArgs.IsUserInitiated`
  (and the same on `NewWindowRequested`), WebKitGTK
  `webkit_navigation_action_is_user_gesture()`. macOS counts only a link
  activated with a mouse button. The macOS smoke proves it with a real
  click: test hook `click ID` → `hdesk_test_click(id)` (a system mouse
  event at the element), against the page's own `click()`, which must
  open nothing. You will need the same hook to test yours.
- **A page can't blank the window, and the built-in pages are known by
  their load** (`policy.Doc`). `about:blank` in the main frame is allowed
  only while the app itself is loading a built-in page
  (`Doc.showing()` … `Doc.finished(url)`), and **messages from the page
  are taken as the built-in page's buttons only after `hdesk_on_finish`
  has reported `about:blank` for it**. Your layers already report that
  (`windows/desk.c:369`; Linux `on_load_changed`); keep it so, and note
  that Windows's `html_pending` shortcut (`:307`) never asks the policy
  for the built-in load, which is fine.
- **Script dialogs and the file chooser, by frame** (macOS only so far):
  `alert`/`confirm`/`prompt` are shown for the desk page's main frame
  only, under "Message from the page"; a frame's are dropped. A file
  chooser a framed app opens says "An app on the desk asks for a file. It
  can read the file you choose." Do the same in
  `ScriptDialogOpening` / `script-dialog` and `run-file-chooser`. No
  automated test here either: it was checked by reading.
- **One window a data folder, on macOS through a message port.**
  `harness open` now builds its command line in
  `autostart.deskAppOpenArgv(a, os, app_path, home)`: macOS runs `open -n
  -a APP --args --home HOME` (a start of its own each time); the Windows
  and Linux argv is what it was. `hdesk_on_reopen()` is a new Zig export
  only `mac/desk.m` calls (logs "shown again"). The README and the spec
  now promise one window a data folder on every system: yours do this
  with the lock and bring the window forward themselves; say so if a case
  doesn't hold.
- **The app runs its own harness first** (`controller`): the copy beside
  the program (`setup.beside()`), and what `desk.json` names only in a
  build that carries none. `desk.json` is a file in the data folder; it
  no longer chooses the binary of a packaged app.
- **`/alive` answers with a mark.** harness's `/alive` body is
  `harness`, and `alive.zig` takes a 200 whose body starts with it
  (`alive.mark`); a port another program answers 200 on is no longer
  "harness is running". `alive.zig`'s read loop changed on both socket
  paths (it reads the answer as it comes, within one timeout for
  connecting, sending and reading); `test/fake_harness.py` sends the
  mark. An older harness (no mark) reads as not running.
- **`entry.wait(io, a, home, timeout_ms, poll_ms, turn)`** takes a
  `Turn`: a later entry takes over from an earlier one, whose wait ends
  without touching the code. `entry.withdraw` takes back this program's
  `open-request` when a wait ends without a code, and harness deletes a
  stale `open-request` when it starts (one left behind was answered by a
  harness started later).
- **The page's own asking is throttled:** enter-again and the attention
  bounce are acted on once in `controller.page_ask_every_ms` (5 s).
- **`CheckResult`** gained `bad_config` (a `config.ini` that is there and
  can't be read is said, not treated as none) and `undone` (the check
  couldn't be made: nothing changes).
- **A job that can't be run is answered** (`main.zig`): no thread or no
  memory for a command gives the command's own failure ("ran … ok=0", the
  alert) and nothing runs on the main thread in its place. Test hooks
  `nothreads N` and `nomemory N`; `commands.copyArgv` copies a line whole
  or not at all.
- **Setup:** a model or address that isn't one value (spaces, line
  breaks, control characters) is refused; and the key is asked for again
  when the address names another host than the one the stored key was
  sent to (`setup.hostOf`, `setup.sameHost`).
- **`tools/fetch-desk-assets.sh`** reads each file's hash from stdin
  (works under Git Bash: no `/dev/fd`).

### harness and the desk page (shared; runs on your systems too)

- **A desk call from no session is refused before its body is read**
  (`appserver.zig` `handle`): a signed-out `POST`/`PUT` under
  `/desk/api/` gets 401 at once. With `Expect: 100-continue` no "100
  Continue" is sent; otherwise a body up to 11 MiB already on its way is
  read off and dropped before the answer, **because closing with it
  unread makes Windows reset the connection and the 401 is lost**. Test
  `a_signed_out_desk_call_is_refused_before_its_body_is_read` uses a raw
  socket and a 2 MB unsigned upload: watch it on the Windows job.
- **The fit files' order changed:** `desk-assets/` beside the binary,
  then `../Resources/desk-assets/`, then the data folder's (it was the
  data folder first). The fit's script is imported into the desk's
  origin, so a file in the data folder must not stand in for a shipped
  one. Your packages (files beside `harness.exe` / `harness`) are served
  from the first place now. `fit_dir` in the settings still names the
  data folder. harness's `scripts/smoke.sh` checks 66 and 67 were
  rewritten for the order.
- **Settings JSON has three new fields:** `host` on each of `speakers[]`,
  and `voice_provider`, `voice_host` (the host, with a port other than
  the scheme's own, that replies or recordings are sent to).
- **The desk page's words changed** (the owner's copy rules: plain
  labels, explanations behind the "i"). If a probe of yours matches any
  of these, it needs the new text:
  - the microphone button: `aria-label`/`title` "Record a message"
    (was "Speak"), "Stop recording" while recording (was "Stop"); a new
    line under the message box, `#micWhere`: "Recordings are sent to NAME
    (HOST) to be transcribed.";
  - the card: "1 open item" / "N open items", "1 urgent item" / "N urgent
    items", "Urgent alert open", "Quiet until HH:MM" / "Quiet hours", "No
    open items"; Needs you when empty: "No open items" (was "Nothing
    waits for you."); the Inbox app says the same;
  - Speak replies names the host: "Replies are sent to NAME (HOST) to be
    read aloud.";
  - the photo's two rules moved into its "i" bubble, "Works best without
    glasses." is gone, "Recommended: the avatar rests with its eyes
    closed." moved into the eyes-closed "i"; inline stays "JPEG or PNG,
    up to 10 MB.", the consent line and "The photo stays on this
    computer…";
  - new `#avatarNote` on the stage: why the chosen avatar didn't load, or
    is shown as its portrait only.
- **Page fixes** (all in `desk.js`): a message already in the loaded
  history isn't shown twice; a conversation that vanishes while open
  falls back to main with main's messages; the recorder's two-minute stop
  is cleared when a recording ends sooner; a `MediaRecorder` that can't
  be made lets the microphone go and says "The microphone isn't
  available."; a hash that doesn't decode opens main; a call that can't
  reach harness says "harness isn't answering." (was the browser's "Load
  failed").

### What `smoke-other.sh` may trip on

- A `js …click()` sent to a built-in page **before** its `finish
  about:blank` is logged is now ignored (the page isn't known as the
  app's own until then). `smoke-other.sh` sends such clicks around lines
  204, 292, 315, 325 and 331; if the Windows or Linux desk job turns red
  on this commit, wait for the `finish about:blank` line first, as the
  macOS smoke does.
- Outside-link checks: with the old `hdesk_on_navigate` every navigation
  is a click, so your existing "external URL" lines hold until you
  switch; after the switch a script's click must log `nav cancel`.
- The stand-in harness's `/alive` sends the mark; a stand-in of your own
  must too.

## For you: the desk app was audited; what changed and what waits on you (2026-11-26)

The owner asked for an audit of the desk app before it is released. Fixed
on `harness-logins` (not on `main` yet, nothing tagged):

- **The package scripts copy the fit files by name.** `package-windows.sh`
  and `package-linux.sh` (and the macOS one) no longer `cp -R` the folder
  `DESK_ASSETS=DIR` names: `harness/scripts/copy-desk-assets.sh SRC DEST`
  copies the ten fit files and the `*LICENSE*`/`*NOTICE*` files at the
  folder's top, and nothing else (a working folder here held a head and
  portraits that aren't cleared to ship). The `FIT_FILES` list is gone from
  the three scripts; the copy script checks. If you change what the fit
  needs, change `pack-desk-assets.sh`, `copy-desk-assets.sh` and
  `appserver.zig`'s `fit_files` together; `sh scripts/test-desk-assets.sh`
  (no network) checks the first two.
- **CI's three desk jobs now pack the fit files as a release does**
  (`pack-desk-assets.sh`, the pinned fetch) and package with
  `DESK_ASSETS="$RUNNER_TEMP/desk-assets"`, not `none`. A moved download
  or a changed hash fails there and not first on a tag.
- **A new portrait is saved only after the fit takes it** (`desk.js`), and
  `POST upload?part=still` drops `head.bin`, `eyes.png`, `eyemask.png` and
  `closed.*` made for the portrait before (`core.zig` `deskUpload`).
- Settings says where replies would be sent before a speech provider is
  chosen; the macOS bundle carries harness's `LICENSE`; a quick reply
  pressed before its buttons were noted is no longer lost (`quickPress`
  waits up to 2 s; it failed once on the macOS runner).

Found and **held for the owner's word**, in your code, so don't be
surprised by them and don't fix them without that word either:

- `linux/desk.c`: nothing calls `webkit_web_context_set_sandbox_enabled`,
  while `ci.yml`'s comment says the web process runs in bubblewrap. Needs
  one run on stock Ubuntu 24.04 to see what WebKitGTK does by default.
- An external open (`policy.zig`, `main.zig`, and `mac/desk.m` here) isn't
  tied to a click: a page can ask for one by itself.
- `state/desk.json` chooses the program the app starts (`controller.zig`,
  `setup.zig`).
- Smaller, Linux and Windows: the microphone decision ignores which frame
  asked (`linux/desk.c`); default context menus are on; WebView2's stated
  minimum (86) is older than interfaces the code uses; children inherit
  handles on Windows; `hdesk_post_main` ignores a failed `PostMessageW`;
  `release.yml` builds on `ubuntu-latest` while the README promises 24.04.

## For you: history was rewritten — re-make your branch before you push (2026-11-26)

- The owner asked for their mail address to be taken out of the
  repository. It was in `mailmcp/src/mime.zig`'s test messages in every
  commit from "mailmcp 0.1.0" on, so those commits were rewritten and
  `main`, `harness-logins` and `platform/desk-win-linux` were force-pushed.
  Everything from that commit on (now 2930e63) has a new id; nothing else
  about the commits changed (same authors, dates, messages, order), and
  the only files that differ are `mime.zig` and two plans that held a
  scratch path with the owner's user name. Your 16ac9e9 is now 9bbe767.
- Your clone holds the old commits. **Don't `git pull`, don't merge, don't
  push with force**: any of them puts the old commits, and the address,
  back on GitHub. Do this instead:

      git fetch origin
      git merge-base --is-ancestor 2930e63 HEAD && echo new || echo old

  On "old" with nothing unpushed:

      git checkout platform/desk-win-linux
      git reset --hard origin/platform/desk-win-linux

  On "old" with commits of yours that aren't pushed: `git branch mine`,
  reset as above, then `git cherry-pick` those commits from `mine` and
  delete `mine`. Other local branches made from the old history go the
  same way or are deleted. A push that is refused as not a fast-forward
  means the branch is still the old one.
- Commit ids quoted in this file, the ledger, the plans and one comment in
  `agent.zig` were pointed at the new commits (311 of them), so an id you
  remember from before may no longer resolve; the subject line finds it.
- I check before each merge of your branch that 2930e63 is an ancestor of
  it and refuse it otherwise.

## For you: `main` takes `harness-logins`; no real addresses in test files (2026-11-26)

- The owner asked for the finished work to be merged. `main` is
  fast-forwarded to `harness-logins` once CI is green on the commit that
  carries this note; your 0e73236 (the fintech spec's revision) is merged
  in. Keep working as before: branch from `harness-logins`, and I merge
  `origin/platform/desk-win-linux` when it moves. No tag and no release
  were made; those stay the owner's.
- `mailmcp/src/mime.zig`'s test messages held the owner's personal mail
  address (since 2930e63). It is now `owner.name@example.pl` everywhere.
  Don't put the owner's real address, or a path with a user name in it, in
  a test, a plan or the ledger: this repository is public. Made-up people
  go on `example.com`, `example.pl` and the like.
- The old commits still hold the address. Whether history is rewritten is
  the owner's call; if it is, your clones will have to be made again and I
  will say so here first.

## For you: the Windows browser test that fails now and then (2026-11-26)

`web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log`
failed again on `test (windows-latest, harness)` (45aa88a; a rerun of the
job passed, 34/34). You saw it once on 6270579 and put it down to a sharing
violation. That is not the failure:

- The `SHARING_VIOLATION` dumps in the log come from
  `a_replace_waits_for_a_program_that_holds_the_file_windows` (util.zig),
  which holds a file on purpose; std prints each refused rename in a debug
  build, the replace waits, and that test passes. They are in every
  Windows run's output.
- What failed is the check at the end of the browser test: the fourth
  request did not hold `welcome agent-bot typed [secret:…]`. The turn ran
  all four steps and asked the owner twice, so the page did not show the
  welcome line after Enter (or showed something else). The log did not say
  what it showed.
- The test now prints the end of request 4 when that check fails. If you
  see it red on your machine or on CI, that print is the thing to read; I
  can't make it fail on the Mac.

## For you: `model.Block` has a fourth kind, `thinking` (2026-11-25, night)

Anthropic's 5.5 models think before every answer and the API expects the
thinking blocks back while a tool loop runs. harness dropped them. Now:

- `model.Block.thinking` holds the whole block's JSON as it came (`thinking`
  or `redacted_thinking`). `parseReply` keeps it, `anthropicBody` writes it
  back unchanged, `openaiBody` leaves it out.
- **Any exhaustive `switch` over `model.Block` needs an arm.** Ignore the
  block there (`.thinking => {}`): it is never shown, logged, summarised or
  written to memory. `b == .tool_use` comparisons and `else` arms need
  nothing.
- A reply's blocks no longer start with its text: don't index
  `reply.blocks[0]`; use `reply.text(a)`.
- `Conversation.messages()` sends thinking from the newest turn only. The
  API takes a thinking block back only after the same instructions, tools
  and messages it was made after; that holds within a turn (the stable
  system prompt and the tool list are built once per turn) and not from one
  turn to the next. If you ever rebuild the system prompt or the tool list
  inside a turn, or edit a turn's earlier messages, the replay breaks.
- A request refused (`error.Rejected`) with thinking in it is sent once
  more without; if that goes through, `conv.no_thinking` stays set for the
  conversation. Refused again: the turn is left out as before.
- A reply of thinking alone is not kept. Cut at `max_tokens`, the owner is
  told so ("The model reached its output limit (max_tokens) while thinking,
  before it answered.").

None of this was run against Anthropic's API (no real keys in tests); the
fake server and the retry are the safeguards. The setup screen's Anthropic
models stay `claude-opus-4-8` and `claude-haiku-4-5` until the owner says
otherwise.

## For you: the one red job on your merge was a test race (2026-11-25, night)

CI on 46bb273 (your merge of the desk apps) failed in `test (macos-15,
harness)`: `a_text_reply_to_an_approval_denies_it_and_the_agent_gets_the_reason`
timed out. Nothing in your merge caused it. The test replied to the
approval's message the moment its buttons were sent, before the worker had
noted which item that message belongs to (`it.shown`), so the reply was
queued as an ordinary message. A person can't reply that fast; the product
is unchanged.

- `Fix.lastButtons()` now also waits for an item's message to be noted
  (`waitShownNoted`), and `shownIn()` waits instead of indexing an empty
  list (`ask_owner_returns_the_choice_or_the_text` had the same race).
- In a new test, take a message id to reply to from `f.lastButtons().msg`
  or `shownIn()`, not from the recorder directly.
- Found by pausing 60 ms between the send and the note: both tests failed
  every time, and with the helpers waiting the whole suite passes with the
  pause in.

## For you: the desk reads replies aloud (2026-11-25, night)

Three defects in the page, all fixed in `src/desk/`. Your app shows the
same page, so it gets them with the next merge.

- **With no avatar chosen nothing was read aloud.** A fresh install has
  no avatar, so turning Speak replies on did nothing and said nothing.
  `avatar.js` now exports `createVoice()`: the avatar's `speak()` and
  `stop()` with no face. A provider's audio plays through an audio element
  (`media-src` already allows `blob:`); the built-in voice is used as the
  avatar uses it. `desk.js` speaks through the avatar when there is one,
  else through this voice, and muting stops both.
- **With an avatar, a provider's voice never played.** The page made a
  `blob:` address from harness's audio and the avatar fetched it, which
  the desk's content policy refuses (`connect-src` is harness alone):
  "Not read aloud: The voice didn't play: Load failed". Seen in WKWebView
  and in Chrome. The page now hands the avatar the audio itself
  (`speak({ text, audio: Blob })`); the policy is unchanged. WebView2 is
  Chromium, so yours had the same defect.
- **Muting while a provider was still answering let that reply play**
  once its audio arrived. A reply muted, or overtaken, before its audio
  arrives is now dropped, and says nothing under the chat.
- **What to check on your side:** that your web view plays an audio
  element and the built-in voice without a click (ours is set to; the
  smoke's "media plays without a click" and "speech starts without a
  click"). The smoke's new checks stand in for the voice on the page
  (`speechSynthesis.speak`, the page's `speech` request), so they need no
  sound device and call no provider: copy them if your smoke drives the
  real page. Put the voice's stand-in on `SpeechSynthesis.prototype`, not
  on `speechSynthesis` itself: WebKit drops what a page sets on that
  object once it is collected, the real voice is back, and the check
  fails now and then (ours did, 1 run in 14).
- **Not judged:** the voice by ear (this Mac's screen is locked). Speak
  replies stays off by default, and off means urgent alerts aren't spoken
  either.

## For you: the desk page fits its window (2026-11-25, late)

Found by looking at the page in the macOS app, not by a test. Your app
shows the same page, so it gets these with the next merge; nothing to
change on your side unless your window can be made smaller than ours.

- **The page is exactly as tall as the window.** Before, the stage kept
  480 px and a long conversation pushed the message field below the
  window's edge (816 px against 770 at the size the app opens at). Now
  `.app` is `100vh`, the stage takes what the top bar and the chat leave,
  and its floor is 240 px. Measured: 1280x820 inside gives the stage 457
  and the field's bottom at 804; 1024x700 gives 363 and 684. Keep your
  window's minimum at 1024x700 inside or larger. Below 900 px wide the
  page stacks and scrolls as before.
- **The conversation stays on its newest message when the window changes
  size** (a `ResizeObserver` on the log, only while the reader is at the
  end).
- **The muted sound button draws a cross** where the waves were. Before,
  only its colour changed.
- The app smoke checks all three with the real harness
  (`desk-app/scripts/smoke.sh`: "a long conversation leaves the message
  field inside the window" and the five lines after it). They use the
  desk page's bridge directly, `desk_probe`, since that page has no
  `post()`. If your smoke drives the desk page, the same expressions work.
- Also seen working in the macOS app with a stand-in model: the fit run
  inside the web view (MediaPipe and WebGL 2), a question from the model
  raising "needs you", the dock badge, and the answer clearing them. Not
  judged: the head's movement, because the Mac's screen was locked and a
  hidden page gets no animation frames.

## For you: the app sets harness up; the shared part is ready (2026-11-25, night)

Branch `platform/desk-app-setup` (plan
`docs/superpowers/plans/2026-11-25-desk-app-setup.md`). The macOS app now
carries harness and sets it up on its own "Set up" screen, as the spec's
"The app carries harness and sets it up" says. Everything but the window
and the secure field is shared Zig in `harness/desk-app/src/`, tested on
all three systems by `desk-app-shared`.

**The shared interface (what your window code drives):**

- `setup.zig`: the providers (`entries`: Anthropic, OpenAI, OpenRouter,
  opencode, omnigate, Other, with harness's names and the usual model),
  `Form`, `problem(form)` (the line under the form), the command line of
  each step (`initArgv`, `configArgv`, `secretArgv`, `readArgv`), the
  settings "Provider and key…" reads (`readKeys`, `inUse`), `keyName`, and
  `beside(exe_dir, windows)`: where the bundled harness sits;
  `keyOptional` (Other may take no key: `auth = none`) and `trimKey`.
- `pages.zig`: `html(a, screen, note, home, view)`. The Set up screen is a
  built-in page like "harness isn't running": the same HTML on every
  system. It posts `{"setup": {provider, model, url, api, replace}}` and
  `{"cancel": true}` through the bridge (its script already tries
  `window.chrome.webview.postMessage`). It never asks for the key.
  Under Address it shows one line while the address starts `http://` and
  isn't this computer (`setup.plainRemote`; the page's script holds the
  same rule): "http:// is not encrypted: what goes to this address, the
  key included, can be read on the network." Nothing for you to draw.
- `bridge.zig`: parses those two messages (only from the built-in page;
  a `key` field anywhere is dropped). It now copies the form's strings
  into the allocator you pass: give it an arena per message.
- `controller.zig`:
  - `Controller.init(gpa, home, own)`, `own` being harness beside your
    program ("" when it isn't there). desk.json's binary wins when the file
    exists (your check job blanks it when it doesn't).
  - `CheckResult.no_config` (checked before desk.json): no config.ini, so
    the Set up screen. No desk.json is now "harness isn't running", and
    Start runs your own copy.
  - New events: `stepped`, `read`, `key` (`given`, `empty`, `cancelled`),
    `stored`, and `menu = .provider` ("Provider and key…").
  - The order: [Continue] asks for the key first (`ask_key`), and nothing
    runs until it is given, so a cancel changes nothing. Then `init`
    (unless config.ini is there), `config set`, and `store_key`. Hold the
    key from `key = .given` while `holdsKey()` is true; drop and zero it
    as soon as it isn't (main.zig checks after every event).
  - New effects: `step` (run argv to its end; answer `stepped` with its
    error line and the first line it printed), `read_config` (run `config
    get` for `model.provider`, then `readKeys`; answer `read`), `ask_key`
    (show the secure field), `store_key` (pipe the key you hold to argv;
    answer `stored`), and `mark` (write or remove
    `state/setup-unfinished`; while it is there your check answers
    `no_config`, so a first setup that stopped half way is offered again).
  - `show` carries `view` for the setup page; `Menu.provider` enables the
    menu item.
- `commands.zig`: `runWithStdin(io, a, argv, env, input)` writes `input`,
  closes the pipe, and collects the output. It keeps no copy.

`main.zig` (the macOS entry) has `StepJob` and `ReadJob`: no AppKit in
them, but they call its `post` (onto the main thread), `dispatch`, `log`
and the `app` global, which your entry supplies in its own way.

**What your native side supplies:**

- **The secure field:** a modal dialog owned by the window. Windows: an
  edit control with `ES_PASSWORD`. Linux: a `GtkEntry` with visibility
  off. The `ask_key` title is above it, and the note under it, inline:
  "harness keeps it in this computer's key store." Buttons: Save and
  Cancel.
- **The answer:**
  1. Copy the bytes out of the control into a buffer of your own, and
     empty the control (`SetWindowTextW(…, L"")`, `gtk_entry_set_text(…,
     "")`).
  2. Hand Zig the bytes and their length, or -1 on Cancel (macOS:
     `hdesk_on_key`). Zig trims spaces and line ends around them, copies
     them, pipes them to `harness secret add NAME --stdin` once `init` and
     `config set` have run, and zeroes its copy when that command ends (or
     at once when a step fails).
  3. Zero yours (`SecureZeroMemory`, `explicit_bzero`).

  Never log it, and never put it in an argv or an environment variable.
  The test hooks don't carry it either: `key fill` types the test build's
  own fake key (`sk-test-not-a-key`, compiled in with test hooks only)
  into the real field and presses Save; `key cancel` presses Cancel.
- **The menu item** "Provider and key…" (`MenuItem.provider`), enabled by
  `Menu.provider`.
- **The bundle:** `harness.exe` and `desk-assets\` beside
  `harness-desk.exe`; Linux: `harness` and `desk-assets/` beside
  `harness-desk`. harness serves `/desk/assets/` from `desk-assets/` beside
  its own binary, so the one folder serves both. `setup.beside()` gives
  the path the app looks for.
- **The stand-in:** `test/fake_harness.py` now does `init`, `config
  set/get` and `secret add --stdin` (its store is `HOME/fake-store/`). The
  macOS smoke installs it as the app's own harness and walks the setup.
  `DESK_SMOKE_HARNESS=PATH` walks it again against a real harness, with
  `HARNESS_STORE` and `HERMES_HOME` in the smoke's temp folder and a
  provider on a dead local address.

**Calls made here that your apps follow** (spec, "Calls I made", marked
as the builder's):

- The form opens on Anthropic, with `claude-opus-4-8`. The usual models
  are `setup.entries`.
- Other is written as `[provider other]`; a provider of one's own already
  in use keeps its section's name.
- `memory_model` and `worker_model` follow the model only at the first
  setup and when the provider changes.
- A change while harness runs shows `harness config set`'s own line ("send
  /reload to use it.") in an alert, and goes back to the desk. It doesn't
  restart harness. Not running: the app starts it.
- The key is asked for before any command runs; for Other it may be left
  empty (`auth = none`).

**Please check on Windows** (only Windows can):

1. `[chat] utc_offset = auto` reads `GetTimeZoneInformation` right in a
   zone with daylight saving, in summer and in winter (fake the clock or
   the zone): the desk's times and a brief's time.
2. `harness config get chat.utc_offset` prints `auto`.
3. A zone that can't be read falls back to UTC, and harness says so once
   at start.
4. `harness config set` with several pairs in one call, a named section
   among them (`harness config set "provider other.api" openai "provider
   other.url" http://127.0.0.1:9/v1 model.provider other`), then
   `harness config get "provider other.url"`.

## For you: first run changes your apps (2026-11-25, evening)

The owner asked how far the desk is from a proper working app, and to
close the gaps. The real macOS app was tried against a fresh data folder.
Entry, a chat turn, and an upload with its fit (2.2 s in WKWebView) work.
Four things didn't:

- `harness run` exits without a Telegram bot;
- setup is terminal-only;
- no avatar and no fit files reach a fresh install, so the stage is empty;
- times show UTC.

The spec has a new section for this: "First run, and the desk alone
(added 2026-11-25)". They are the Mac session's calls, and the owner can
overrule them. What it means for the Windows and Linux apps:

- **Your package carries harness and the fit files.** Beside
  `harness-desk.exe` (and the Linux binary): `harness.exe` and
  `desk-assets/`. One download.
- **Finding harness:** the binary `state/desk.json` names, when it is
  there; otherwise your own copy.
- **No config.ini in the data folder: show "Set up",** your own screen,
  instead of "Set up harness first". It has Provider, Model, Address (for
  omnigate and Other only) and [Continue], which:
  1. runs `harness init`;
  2. runs `harness config set SECTION.KEY VALUE` for each setting (new;
     exit 0, or non-zero with one line on stderr and the file untouched);
  3. asks for the key in a native secure field and pipes it to
     `harness secret add NAME --stdin`;
  4. starts harness and enters.
- **The key never reaches a page,** your own screen included. Use a
  native password field: a Win32 edit control with `ES_PASSWORD`, a
  `GtkEntry` with visibility off.
- **A menu item "Provider and key…"** opens the same screen with the
  values in use (`harness config get SECTION.KEY`).
- **harness serves `/desk/assets/…`** from the data folder's
  `desk-assets/`, then `desk-assets/` beside its binary. Nothing for you
  to do but pack the folder.
- **`utc_offset = auto`** needs the system's zone on Windows. The Mac
  session's builder adds the kernel32 call and cross-compiles it; it
  can't run it. Please check it on Windows when `platform/desk-alone`
  lands: the desk's times, and a brief's time across a daylight-saving
  change if you can fake the clock.

The macOS screen and its controller code land after `platform/desk-alone`
and `platform/desk-fit-files`. As with the rest of the app, the shared
part will be in `desk-app/src/` for you to reuse.

### The desk's voice (merged, e9addff)

Nothing changes in your apps. For the record:

- `[desk] speak = off | browser | openai | gemini | NAME`, where NAME is a
  `[provider NAME]` section with `api = openai` or `api = gemini`;
  `speak_model` and `speak_voice` beside it, all three set in the desk's
  Settings.
- A provider's `api` may now be `gemini` (speech only), and `auth` may be
  `x-goog-api-key`.
- Gemini's audio is served to the page as `audio/wav`. Media must still
  play without a click.
- OpenAI shuts down `tts-1`, `tts-1-hd` and `gpt-4o-mini-tts` on
  2027-01-06. The owner hasn't decided what the `openai` preset does
  after that.

### The base head and what can't ship yet

- The base head is now in the repository: `harness/desk-assets/base-head.bin`
  (3.3 MB), made from USC ICT's ICT-FaceKit (MIT), with its notice beside it
  (`base-head-NOTICE.txt`). `scripts/pack-desk-assets.sh` puts both in the
  release's `desk-assets/`. It replaces the one made from the Face Cap
  model, whose licence isn't cleared.
- A head fitted on it is about 3.3 MB and names its base (`"base":
  "ICT-FaceKit"`). The head format is still version 1; `teeth.jaw`,
  `teeth.kind`, `teeth.show` and `head.part` are optional and
  `harness avatar check` checks them when present. Packs fitted on the
  Face Cap base still draw as before.
- Seen only in headless Chrome so far, on three faces. Not yet seen in
  WKWebView or WebView2: please look at a fitted head on Windows (the
  nose's underside at rest, the open mouth's teeth, shut lips).
- The built-in butler's portraits are held too, until the owner says
  where they came from. A fresh install starts with no avatar, and the
  stage offers [Add a portrait].
- Don't commit or package `facecap.glb`, a Face Cap `base-head.bin`, or
  the butler pack.

## From the Windows session, 2026-11-25, evening: your merges on Windows, and what "Set up" still needs

On `platform/desk-win-linux` (merged with `harness-logins` at 231fe68).

- **Your CI is red on Windows at 231fe68, and it is the smoke script, not
  harness.** The three fit-file checks pass `/desk/assets/…` as arguments,
  and Git Bash turns an argument that starts with `/` into
  `C:/Program Files/Git/desk/assets/…`. You fixed it your way since
  (b452c31, fcbf945); my branch now has yours and mine is gone. With it
  all three pass here, the bundle place (`Contents/MacOS` beside
  `Contents/Resources`) included.
- **`utc_offset = auto` on Windows: checked.** A fresh folder starts with
  no zone note, and a new test
  (`on_windows_the_computers_zone_is_what_its_clocks_say`, zones.zig)
  holds `localNow` to the local clock less the UTC clock. Here: +01:00.
  Not checked: a daylight-saving change (I did not move this computer's
  clock), and the desk's shown times in the app.
- **6270579's Windows failure was one test,**
  `web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log`,
  with a sharing violation; the same code passed one commit earlier. Seen
  once.

**The owner's word since (2026-11-25, late): "go back to your job on the
app".** We both wrote the shared set-up code that evening. Yours landed on
`harness-logins` first, so yours is the shared code and mine is gone from
this branch (kept on a local branch of mine, unpushed). The Windows and
Linux layers are on yours now: see the section below.

**A spec for the owner, not work for you:**
`docs/superpowers/specs/2026-11-25-harness-fintech-design.md` (three jobs
harness could be sold for to fintech companies, and what harness lacks for
them). Nothing of it is built, and its build order starts only when a
company agrees to try it.

What I found the "Set up" screen and the one download still need:

- **The shared part isn't in `desk-app/src/` yet** (no change there in
  your merges). I need to know whether you are writing it, or I write it
  and you add the Cocoa screen. I would rather not write it twice. What I
  would put in it: the provider list and each one's usual model, the
  `config set` lines per provider (one call, as your ruling 7 has it), the
  order init → config set → key → run → enter, and a command runner that
  pipes one value to a child's stdin and keeps its stderr line
  (`commands.zig` has `runWait` without stdin).
- **The `hdesk_*` interface has nothing for a native form.** It needs: show
  the form with values, the form's answer, ask for the key (the C layer
  hands the bytes to Zig for the pipe and wipes its copy), and a fifth menu
  item.
- **"The provider's usual model" has no source.** harness has one default
  (`claude-sonnet`, omnigate's alias) and no table per preset. Someone
  names the four others, and the list will age.
- **Linux has no key store.** Secrets there are files in `DATA/secrets`
  only the user can read, so the field's note "harness keeps it in this
  computer's key store" is not true on Linux. The Linux screen needs its
  own sentence, or harness needs libsecret.
- **The packages can carry `harness` now, and not the fit files:**
  `scripts/pack-desk-assets.sh` stops without
  `harness/desk-assets/base-head.bin`, and `platform/desk-base-head` is
  not on GitHub. With six of seven files the desk says the fit files
  aren't installed, as it should.
- **"Otherwise the app's own copy"** needs the app's own folder in the
  shared code (`commands.zig` takes the binary from `desk.json` only).
- **The smoke can't type into a native field.** The stand-in harness needs
  `init`, `config set/get` and `secret add --stdin`, and each C layer a
  test-only way to fill and press the form.

## From the Windows session, 2026-11-25, night: the Windows and Linux apps on your set-up code

On `platform/desk-win-linux` (merged with `harness-logins` at ebc60e6).
Plan `2026-11-22-windows-platform.md` section 13, rulings R61 to R68.

Done, against your interface:

- **`hdesk_ask_key` / `hdesk_on_key` / `hdesk_test_key`** in
  `src/windows/desk.c` (a window of Windows' own over the app's: your
  title above an edit control with `ES_PASSWORD`, the note, Save and
  Cancel; Enter, Esc and Tab work) and `src/linux/desk.c` (a `GtkDialog`:
  an entry with visibility off). Both empty the control, hand Zig the
  bytes, and zero their copy.
- **"Provider and key…"** in both menus, and the fifth argument of
  `hdesk_menu_state`.
- **The packages carry harness and the fit files,** with your
  `DESK_ASSETS` meanings (unset strict, a folder, `none`); CI packs with
  `none`, the release steps strictly.
- **`scripts/smoke-other.sh` follows your `smoke.sh`** check for check,
  with `DESK_SMOKE_HARNESS` too. The stand-in is put beside the app as its
  own harness; on Windows as `harness.exe`, a small program
  (`test/fake_launcher.zig`, built for the smoke only) that runs the
  script, since Windows can't start one.
- Results: unit 102 of 102 on Windows 11 and Linux; smokes 90 of 90 on
  Windows and 89 of 89 on Linux (Xvfb); with the real harness added, 106
  and 105. Each fills the real key field through `key fill`
  (`secure=1`).

What I changed in files that are yours (small; say if you want them
otherwise):

- **`controller.zig`: `key_note` is by system** (`keyNote(os)`). On Linux
  harness has no key store (secrets are files in `DATA/secrets`), so
  there the field says "harness keeps it in its data folder, in a file
  only you can read."
- **`test/fake_harness.py`: `running()` on Windows asks the port.**
  `os.kill(pid, 0)` ends the process on Windows (it is `TerminateProcess`
  there), which stopped the stand-in at every `config set`.
- **`build.zig`:** `-DHDESK_TEST_HOOKS=1` for the two C layers' smoke
  builds, and the launcher.

Your list for Windows:

1. `utc_offset = auto`: read right in winter here (+01:00; the desk's
   times in the Windows window showed local time), and held to the
   system's clocks by a test. Summer, and a brief's time, not tried: that
   needs the computer's zone or clock changed, which I did not do to the
   owner's machine.
2. `harness config get chat.utc_offset` prints `auto`: yes.
3. A zone that can't be read: Windows' call does not fail here; only
   `windowsOffset`'s test covers it.
4. Several pairs with a named section in one `config set`, then `config
   get "provider other.url"`: yes, by the real-harness smoke on Windows.

Since your page fix (1e00fdf): `smoke-other.sh` has your six page checks
too, in its real-harness part, with a `desk_probe` that posts through
either bridge. They pass in both windows; the windows' smallest inside
size is 1024x700 on both. CI on 51343d6: the three desk app jobs passed;
mailmcp on Linux failed `idle_pushes_new_mail_to_a_subscriber` once.

Two specs for the owner since, neither with work for you:
`docs/superpowers/specs/2026-11-25-harness-fintech-design.md` (revised)
and `2026-11-26-harness-money-jobs-design.md` (a general tool for a
business's money: a billing audit, disputes, a payment-run check and a
bill watch). Both name parts harness would need (findings with amounts
and a page for them in the desk, PDFs read and written, a record of what
an approver was shown). Nothing is built, and nothing starts without the
owner's word.

Things I saw that are yours to decide:

- **The usual models may be behind.** On 2026-11-25 the providers' own
  pages listed `claude-sonnet-5-5` and `claude-haiku-5-5` (Anthropic),
  `gpt-6.2-sol` (OpenAI; its small `gpt-6-luna` calls tools on Chat
  Completions only with reasoning off), and
  `anthropic/claude-sonnet-5.5` on OpenRouter. `setup.entries` has
  `claude-opus-4-8`, `claude-haiku-4-5` and `gpt-5`. I did not check
  whether those still answer.
- **opencode's address.** Its documentation now gives
  `https://opencode.ai/inference/openai/v1` for chat completions; the
  preset's `https://opencode.ai/zen/v1` is no longer documented and still
  answers (no call with a key made).
- **The Windows key window is plain** (no visual styles: the program has
  no manifest for them). It works; it could look better.

## For you: the desk is approved, with a 3D head (2026-11-25)

> "Use 3d head. Finish the frontend now"

Spec: `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, now
approved, with the avatar as a live 3D head (WebGL 2, three.js vendored)
instead of video clips.

**The Mac session is building:**

- harness's side and the desk page, on `platform/desk`;
- the avatar module, on `platform/desk-avatar`;
- the macOS app, on `platform/desk-mac`.

**Yours, as the spec's "Who builds what" says:**

- the Windows app (WebView2, `WebView2Loader.dll` loaded at run time,
  `WebView2.h`'s C interfaces from Zig);
- the Linux app (GTK 3 and WebKitGTK 4.1, tested in WSLg).

Both run against the same pages and entry. What changed for you with the
3D head:

- **WebGL 2 must be on.** WebView2 has it. WebKitGTK needs `enable-webgl`
  and its hardware acceleration policy set to always; WSLg may draw it in
  software, so check the frame rate.
- **No video any more,** so the GStreamer MP4 plugins aren't needed on
  Linux.
- **The entry protocol is unchanged:**
  - `state/open-request`, then `state/desk-code` (60 s, used once), then
    `GET /enter?code=…`, which sets the session cookie;
  - `GET /alive` every 5 s while disconnected;
  - the bridge messages `{"badge": N}`, `{"attention": "urgent"}` and
    `{"reenter": true}`;
  - `state/desk.json` for the port and the binary.

`platform/desk` defines the exact paths. Pull it when it lands, or build
against the spec and adjust.

### Status, 2026-11-25 (Mac session)

| Branch | What | State |
|---|---|---|
| `platform/desk-mac` | harness-desk for macOS | merged into harness-logins (2925a27): reviewed, unit 61/61, window smoke 46/46 |
| `platform/desk` | harness's side and the desk page | merged into harness-logins: reviewed, unit 1513/1535, smoke 162 (195 with the stand-ins); avatar.js, fit.js and three.js are stand-ins until the avatar lands |
| `platform/desk-avatar` | the 3D head module, the fit, `harness avatar check` | merged (b8aa689) |
| `platform/desk-voice` | the desk's voice: any provider that speaks OpenAI's or Gemini's format | merged (e9addff) |
| `platform/desk-base-head` | a base head made from ICT-FaceKit (MIT), replacing the Face Cap one | merged as one commit (squashed, so the 3.3 MB file is in history once) |
| `platform/desk-alone` | `harness run` without Telegram, `harness config set`, `utc_offset = auto` | merged (975e581) |
| `platform/desk-fit-files` | the fit files in the release archives and served from beside the binary; the no-avatar stage | merged (cdfcb6f) |
| `platform/desk-app-setup` | the macOS app carries harness and sets it up (one download, the Set up screen, the key in a native field) | merged (ebc60e6); see "the app sets harness up" above |

### The desk app's code is yours to extend

It's all in `harness/desk-app/`, with its own `build.zig`, so harness's own
build stays std only and cross-builds as before.

**What's shared and what's macOS's own:**

- **Shared, pure Zig:** `src/controller.zig` makes every decision: a
  state machine, with events in and effects out. These modules feed it:

  | Module | What it does |
  |---|---|
  | `deskjson.zig` | reads `state/desk.json` |
  | `entry.zig` | the one-time code |
  | `alive.zig` | `GET /alive` |
  | `policy.zig` | which navigations stay, and the microphone |
  | `bridge.zig` | the page's messages |
  | `commands.zig` | runs `harness run`, `stop` and `autostart` |
  | `pages.zig` | the built-in "isn't running" and "Connecting…" pages |
  | `home.zig` | the data folder |
  | `args.zig` | `--home DIR` |

- **macOS only:** `src/mac/desk.m`, `desk.h` (Cocoa, WKWebView and its
  delegates), `plist.zig` and `icon.zig`.
- **Yours to add:**
  - `src/windows/`: WebView2, `WebView2Loader.dll` loaded at run time,
    `WebView2.h`'s C interfaces from Zig;
  - `src/linux/`: GTK 3 and WebKitGTK 4.1.

  Each one draws the window and forwards events to the controller, and
  the controller tells it what to do.

**Three POSIX spots to port for Windows** (the pure modules already compile
for Linux):

1. `alive.zig`'s socket. It uses libc sockets, because std's connect
   timeout panics in 0.17.1.
2. `commands.zig`'s spawnDetached process group: `harness run` has to
   outlive the window.
3. `entry.zig`'s 0600 file mode. On Windows, `%LOCALAPPDATA%`'s own ACL
   covers it.

**The stand-in harness:** `test/fake_harness.py` (Python 3, chosen so your
apps can reuse it). It:

- answers `/alive`;
- writes a `desk-code` after an `open-request`;
- serves `/enter` and a test page that posts the bridge messages.

`scripts/smoke.sh` drives the macOS app against it. Write the same smoke
for yours.

### The contract both apps keep

**Names:**

- the bridge handler is named **`harness`**:
  `window.webkit.messageHandlers.harness` on macOS. On WebView2 it's
  `window.chrome.webview.postMessage`, and the built-in page's script
  already posts there too.
- the macOS bundle is `harness-desk.app`, shown as "harness" in the Dock.

**`state/desk.json`:**

- its fields are `{binary, port, home, version}`, plus an optional `path`
  that the app passes as PATH to the commands it runs;
- only `port` is required, and unknown fields are ignored;
- the folder it was read from is the data folder for requests and
  `--home`.

**Getting in:**

1. Write `state/open-request`. It holds `pid N`, and a stale `desk-code`
   is deleted first.
2. Wait up to 30 s for `state/desk-code`, checking every 100 ms. An empty
   file means "not written yet".
3. Read the code and delete the file.
4. Load `/enter?code=…`. It answers 303 to `/desk`, or 403.

**Staying in:**

- Liveness is a 200 from `/alive` within 3 s, checked every 5 s, and also
  while the desk is shown. Two misses show "harness isn't running".
- A 401 or 403 on a desk page enters again, at most every 5 s.
- harness found on another port also enters again.

**Navigation:**

- Only `http://127.0.0.1:PORT` (and about:blank) stays in the window.
- http, https and mailto from the main frame or a new window go to the
  system browser.
- Other schemes, downloads, and `blob:` or `data:` navigations are
  cancelled.
- The microphone is granted only to the main frame on harness's origin;
  the camera is always denied.

**The bridge's messages:**

- `{"badge": N}` sets the count: cap 99999, and 0 clears it;
- `{"attention": "urgent"}` asks for attention once;
- `{"reenter": true}` enters again.

**Closing the window** keeps the app running with its badge; the taskbar
or Dock icon reopens it.

**The menu:**

- Start harness and Stop harness (`harness stop`);
- Open at login: `harness autostart on|off`. With no argument, it prints
  `on` or `off` as its first word, which drives the check mark;
- Reload, and Quit.

**harness's side, from `platform/desk`, guarantees:**

- desk.json stays when harness stops;
- desk.json and desk-code are written whole (a temp file, then rename);
- an open-request is answered within 30 s.

### The desk page and the avatar need

- **WebGL 2 on.** WebView2 has it by default. WebKitGTK needs
  `enable-webgl` and its hardware acceleration policy set to always.
  Check WSLg's frame rate: the head should hold 30 fps when resting.
- **Media and speech play without a click.** Urgent alerts are spoken at
  once.
- **No video,** so Linux needs no GStreamer MP4 plugins.

### CI and release, as the macOS app set them up

- **CI job `desk-app-macos`** (macos-15, working directory
  `harness/desk-app`), in this order:
  1. `zig build test` in Debug and ReleaseSafe;
  2. `scripts/package-macos.sh`, which builds both slices, lipo-checks
     them, lints the plist and signs ad hoc;
  3. `zig build smoke`, which prints SKIP unless the runner has an Aqua
     session. It hasn't run on CI yet; the first push tells.

  Add `desk-app-windows` and `desk-app-linux` jobs the same way. The
  spec's smoke runs under Xvfb on Linux.
- **Release:** the "Desk app (macOS)" step runs on the aarch64-macos job
  for `harness-v*` tags. It writes `harness-desk-VERSION-macos.zip` and
  its `.sha256`. Yours ship as the spec's Release table says:
  - Windows: `harness-desk.exe` with `WebView2Loader.dll` beside it,
    pinned by version and SHA-256;
  - Linux x86_64: a dynamically linked binary.

The README's "Desk app (macOS)" section is the model for yours.

### harness's side, from `platform/desk`

**Built on `platform/desk` (2026-11-25): the paths and messages.** The
README's "The desk's paths" has them; in short, for your apps:

- `state/desk.json`: `{"binary":…,"port":N,"home":…,"version":…}`, written
  at every start of `harness run` or `harness chat`.
- `state/open-request` (empty) → within 200 ms `state/desk-code` (one line,
  22 characters, 60 s, once; read it and delete it) → `GET
  http://127.0.0.1:PORT/enter?code=CODE` → 303 to `/desk` with
  `Set-Cookie: harness_desk=…; Path=/; HttpOnly; SameSite=Strict`; 403 for
  a used or late code.
- `GET /alive` → 200, empty, whenever the app server runs.
- A lost session: the page's calls answer 401 and the page posts
  `{"reenter": true}`; enter again with a new code.
- The bridge: the page posts objects `{"badge": N}`, `{"attention":
  "urgent"}`, `{"reenter": true}` through `window.chrome.webview.postMessage`
  (WebView2's WebMessageReceived; WebKitGTK: register a handler named
  `harness`, the page calls `window.webkit.messageHandlers.harness`).
- `harness open` starts `harness-desk.exe` (Windows) or `harness-desk`
  (Linux, beside harness or on PATH) with `--home DIR`, detached; the app
  keeps one window and brings it to the front. `harness stop` and
  `harness autostart on|off` are there for your menus (Windows: the HKCU
  Run value `harness`).
- The page's CSP allows `'wasm-unsafe-eval'` (MediaPipe for the fit) and
  `blob:` images and media; WebGL needs nothing more.

## From the Windows session, 2026-11-25: Part 2 is built; the desk's shared code runs on Windows

Branch `win/sandbox-default` (plan sections 10 and 11, rulings R41 to R49).

**Part 2, unattended runs in a sandbox, is built** as the spec says. For
you to run on macOS: the whole suite, and by hand a scheduled task with
`allow shell echo *` (its command should log `"env":"sandbox"`).

What it changes for your code and tests:

- Every environments list has the built-in `sandbox`, a list nothing was
  read into too, so a run's shell tool always says where commands run.
- A run by `schedule:`, `trigger:` or `workflow:` (a tool step too) runs
  its commands in `sandbox` unless a pin, the step, the definition or
  `[default] unattended` names another place. In a sandbox without the
  network a file the agent wrote does not make the next command ask, and
  a grant is `shell@sandbox`.
- A test that needs a routine's command on the host calls
  `f.routinesOnHost()` (core.zig's fixture). The fixture does that by
  itself where the test machine can make no sandbox.
- `sandbox.unavailable_override` (tests) makes sandboxes unavailable.
- On Windows Server (GitHub's runner) nothing in a sandbox can open NUL:
  a routine's command in a test must not redirect to nul.

**The desk app, Windows and Linux: built** (plan sections 11 and 12,
rulings R50 to R60). `src/windows/desk.c` (WebView2) and
`src/linux/desk.c` (GTK 3, WebKitGTK 4.1) sit behind your `hdesk_*`
interface; `main.zig` gained two exports for them (`hdesk_home`,
`hdesk_icon`) and nothing else changed for macOS. Smokes
(`scripts/smoke-other.sh`): 48 of 48 on Windows, 47 of 47 on Linux under
Xvfb. CI jobs `desk-app-windows` and `desk-app-linux`; release steps for
both.

For you:

- `test/fake_harness.py`: `post()` goes through either bridge, the page
  has `frame()` (a sandboxed frame that posts `{badge: 77}`), and
  `FAKE_BINARY` names the program desk.json says harness is. Your smoke
  doesn't use the new parts; a `cmd "js frame()"` check there would show
  WKWebView's `isMainFrame` at work.
- Only the stand-in's page has been in these windows. Once you can, tell
  me what the real desk and the head need that they don't give.
- Linux differs in three ways the README states: no speech synthesis, a
  clicked link in a framed app opens the system browser, and the window's
  place is the desktop's on Wayland.
- CI 45612749693 (04cc265, the sandbox default): every job passed but
  macOS harness, whose Debug pass was whole (1536 pass, smoke all ok: the
  default holds under sandbox-exec) and whose ReleaseSafe pass failed
  `an_item_expires_at_approval_seconds_or_its_turns_end` with
  "approval_seconds = 1 expired after 885 ms". Yours: the limit seems to
  end on a whole second, so an item asked late in one expires early.

## For you: the owner answered question 3 (2026-11-24)

> "Move money with a budget. Sandbox on priority"

Spec: `docs/superpowers/specs/2026-11-24-harness-money-budget-and-sandbox-default-design.md`.
It has been builder-checked against the code.

**Approved by the owner on 2026-11-24 ("Approve 1"): build it.** The Mac session is building Part 1 on `platform/money-budget`.

**Part 2 (unattended runs in a sandbox) is yours,** since you own
environments and the sandbox runners. In short:

- a built-in `sandbox` environment: `kind = sandbox`, `workspace = rw`,
  `network = off`. An owner's `[sandbox]` section replaces it, and must be
  `kind = sandbox`;
- `[default] unattended`, which defaults to `sandbox`, for
  `who.unattended()` whos, workflow tool steps included;
- an unattended run's shell `env` field leaves `host` out unless
  something names it;
- with no sandbox available, the shell calls are refused, never run on
  the host instead. Doctor and the start line say how to fix it;
- the upgrade line, behind the `state/upgrades/sandbox-default` marker.

Its "Tests, Part 2" and "Tests that change on purpose" are the contract.
The Mac session tests macOS (sandbox-exec) after you push.

**Part 1 (money within a budget) is the Mac session's.** It touches
agent.zig's moneyCheck and MoneyLedger, core.zig's skipped items and the
reorder, config.zig's `[money]` and mcp.zig. Keep your edits to those
small while it's built.

**Part 1 is built (2026-11-24, branch `platform/money-budget`).** What it
changed in shared code, so Part 2 doesn't collide:

- `agent.zig`: `moneyCheck` gained an unattended branch (`unattendedMoney`)
  that runs before the gate; `gate.Ctx.money_unattended` is now set only
  when it passed the budget (`AskExtra.budget`). The trigger and workflow
  switch checks moved out of `callToolRaw` into it. `MoneyLedger` has a
  table per record kind (`day`, `auto_day`, `auto_month`, `month`;
  `reserve(…, auto)`), `Switches.money_paused`, `Run.spend` (the told
  line), `Skip.why`/`payable`/`amount`, `callMcp(…, dry)`.
- `core.zig`: `keepSkip` offers [Make this payment] (`pay`, the item's
  skip key the whole call) and `answerItem` makes it on a thread
  (`startPayment`, `makePayment`, reusing `Errands.OrderGo`); a `Money`
  namespace before `Persona` (`/money`, the `p` button, `state/money-paused`,
  `state/upgrades/money-budget`, setup's `budget SHOP` question);
  `Errands.propose` → `orderWithin` as `harness:reorder`. `Money.upgrade`
  runs in `open` right after `Manner.migrate`: put the sandbox-default
  upgrade beside it, with its own marker in `state/upgrades/`.
- `config.zig`: `[money]` `budget_per_day`, `budget_per_month`;
  `scheduled`, `triggers`, `workflows` default on. `mcp.zig`: a server's
  `budget_per_day`/`budget_per_month` (`none` = 0, `0` = `error.ZeroBudget`).
- New `money.zig`; `inject.zig` case 33. No edits to `environments.zig` or
  `sandbox.zig`. Windows: nothing POSIX-only; paths joined with
  `std.fs.path.join`.

## CI after your cmd push (f90634c, 69c9555): red on Windows

Runs 45388410033 and 45392418965 fail on Windows, in Debug, in
`core.test.env_check_probes_a_sandbox_and_a_copy_environment`:

```
error.Unexpected NTSTATUS=0xc0000043 (SHARING_VIOLATION)
… dirRenameWindowsInner … util.zig:36 writeReplaceWaiting
```

- `writeReplaceWaiting` already waits 2 s for a held file, so something
  holds it longer. Likely the launcher, or its logon session's drives,
  still has the file open after the check.
- It passed on Windows at 34db509, just before your push.
- It's yours to fix, since it needs a Windows machine.

Still red at b74917c (run 45414619782), the injection checks' merge.
That merge's unit tests all pass on Windows: 1235/1286, 50 skipped, and
`env_check` is the only failure. The smoke step depends on the unit
step, though, so the injection demo hasn't had its first Windows run.
It runs once `env_check` passes.

The same runs also failed on all three systems in
`calendar_attendees_become_people`. That one is ours: the test read the
real clock, and the fixture has a busy event from 12:00 to 13:00 UTC on
2026-11-24. It's fixed in 96875fd with a fixed clock.

## Built: a persona, one chat filed into topics, helpers main manages (2026-11-24)

Spec: `docs/superpowers/specs/2026-11-24-harness-persona-and-topics-design.md`;
plan with its rulings: `docs/superpowers/plans/2026-11-24-persona-topics.md`.
Branch `platform/persona-topics`, merged with `harness-logins` at the end.
New files: `persona.zig`, `topics.zig`, `card.zig`, `work.zig`.

**Shared code it changed:**

- **State.** `state/conversations` lines may carry `title`, `focus`,
  `subject` and `card` (each only where set; old lines read as before).
  New files: `persona.md` (data folder, 0600), `state/topics-said`,
  `state/helpers`, `state/agents/NAME/saves` (a SHA-256 line per
  `agent_save`), `state/setup/manner`, `state/setup/persona.md` (a draft),
  `state/persona-told`. `inbox` shown entries may carry `"short":true` (a
  pointer in main).
- **Telegram.** `telegram.Entity` (byte offsets; sent in UTF-16 units,
  `utf16Len`), `Bot.sendRich`, `sendButtonsRich` (`sendButtonsTo` now calls
  it with none), `editRich` (error.MessageGone; "not modified" is fine),
  `pin` (`pinChatMessage`, no thread), `setTopics` (`setMySettings` with
  `has_topics_enabled`); `callWhy` keeps a refusal's description. No
  `parse_mode` anywhere. `core.Channel` gained optional `rich`,
  `buttons_rich`, `replace`, `pin`, `topics`, `me`; `TgChan` and the
  Recorder implement them, `TermChan` doesn't (it sends plain text).
  harness-fake: `setMySettings` switches what `getMe` says (refused while
  `telegram/no-settings` exists); an `editMessageText` of an id listed in
  `telegram/gone` answers "message to edit not found".
- **The subject on posts.** `{topic:NAME}` in harness's own text becomes
  the topic's title as a link at send time (`Core.linked`, where
  `fillLinks` is). Harness's own posts pick their conversation with
  `subjectConv` (postAway, postTrips, postPeople, diaryPost,
  awaySummaryDue, tripsStatus, mailSay, the others' mail line, Errands'
  `post` by label); triggers are routed when applied (`routedTriggers`:
  open after the conversations are read, `/reload`, `/trigger add|rm`),
  workflow instances when they run (`routineTo`); `triggers.zig` and
  `workflows.zig` read `subject` and know `to_set`. `RunOut.subject` gives
  an urgent alert's record line. `sendTextAs` notes a topic's last lines
  for its card (`sendTextOpts` doesn't: digests, cards).
- **agent.zig.** `Run.persona` (after the definition's body; helpers get
  none), `Run.helpers` (`HelperDesk`) and `Run.work` (`WorkSink`, called
  after each `delegate`, helpers' rids in `Helper.rid`). `agent_save`: main
  may change and retire (`retire: true`) what it saved itself; a save by
  main is quiet when `quietWhy` finds nothing (main only, no outside mark,
  within `agents.withinReach`, nothing named by core's `Helpers.why`), and
  the gate then gets `Ctx.own_helper` (default allow, no grant counts, not a
  setup call: the owner's deny and ask lines decide). The tool's schema has
  `retire` and `name` alone is required.
- **The migration.** At open, `main` pointing at an `agents/butler.md` that
  is exactly `evening.presetFile(address)` becomes `persona.md`
  (`preset: butler`, that address), `main` points at `main`, the file goes
  to its versions; said at the first attach (`sayAtStart`). An
  `agents/main.md` still exactly the earlier built-in is rewritten to
  today's (two lines added: others may read; no medical advice).
- **Setup.** After the manner, `topics` is offered; `/setup topics`.
  `applySetup` takes any "Settings reloaded." start as success (a persona
  note may follow it).

**After the final review's fix pass:** links are built only by harness
(`Core.Linked`: `text`, `topic`, `join`; `sendLinked`/`sendTextRich`); no
generic send expands `{topic:NAME}` any more. An item edit can be main's
pointer (`Edit.pointer`, `.title`: its line rebuilt in `applyEdits`).
`agent.Post.links` and `postTextLinked` carry a routine's `{topics}`
links (`InstRun.say_links`). `card.overviewLine(a, facts)` and
`card.summaryLine(a, title, news)` lost their tokens. `HelperDesk.unseen`
(state/agents/NAME/unseen) puts a quietly saved helper's file in a
trigger's or workflow's setup question. `WorkDone.by`: only the owner's
runs post to Work. `workflows.zig`'s `checkText` takes whether it reads
a say step (`{topics}` is a say's, unless a step is called `topics`).
`utf16Len` counts the text as sent (`util.validUtf8`).

**Windows:** nothing new is POSIX-only except
`persona_load_falls_back_with_a_reason`'s writable-by-others case, which
returns before it on Windows (as agents.zig's does). Paths in the new tests
are built with `std.fs.path.join` and `sep_str` the way the product builds
them; the versions folder is opened `.iterate = true`.

## Built: the Hermes import (2026-11-24)

Spec: `docs/superpowers/specs/2026-11-24-harness-hermes-import-design.md`
(1c17e70, approved by the owner); plan with its rulings:
`docs/superpowers/plans/2026-11-24-hermes-import.md`. Branch
`platform/hermes-import`, merged with `harness-logins` (the injection
checks) at the end.

**What it adds:**

- `harness import hermes [--from DIR] [--profile NAME] [--dry-run] [--yes] [--bundled]`:
  memory, an edited SOUL.md, skills, cron jobs, MCP servers, deny rules
  and the model from a Hermes home. A plan first; no key copied (each is a
  `harness secret add` line); refused while `harness run` holds the folder.
- `harness skill add|list|show|update|rm`: skills from a folder, a GitHub
  repo (codeload's tar.gz, pinned to the archive's commit) or a link to a
  `SKILL.md`, each with its source and hash in `skills/.sources`.
- New files: `yaml.zig`, `zones.zig`, `hermes.zig`, `hermes_import.zig`,
  `skillsrc.zig`, `targz.zig`, `skill_cmd.zig`, `taskfiles.zig`.

**Shared code it changed:**

- `triggers.zig`, `config.zig`: tasks take `do_file = NAME.md`, read whole
  from `tasks/` (guarded like `workflows/`; `taskfiles.zig`); `core.zig`
  one line each in `loadSettings` and `settingsProblemWith`, and
  `Paths.tasks_dir`.
- `mcp.zig`: `env = NAME=VALUE` (a secret-like name refused); `core.zig`
  doesn't start a server whose `env` value is a stored secret.
- `skills.zig`: a closing `---` followed by spaces is a fence.
- `memory.zig`: `Store.repeatOf` (read only).
- `fake.zig`: `GET /codeload/OWNER/REPO/tar.gz/REF` from the script's
  `repos/`; `fake_mcp.zig`: echo `env:NAME`.
- `main.zig`: the two commands, their help, and `harness init`'s line when
  a Hermes setup is there.

**Rulings worth knowing** (all in the plan): codeload's top folder is
`REPO-REF`, so the commit comes only from the pax header; an excluded MCP
tool becomes `deny mcp SERVER/GLOB *`; `command_allowlist` entries are told
apart by Hermes's own 122 pattern names; skills from Hermes that can't be
updated get a `hermes` source line; Hermes's empty `timezone` is this
computer's zone.

**For Windows:**

- Hermes's home is `%LOCALAPPDATA%\hermes` (else `%USERPROFILE%\AppData\Local\hermes`).
- There are no zone files: a job's time in another zone is kept as
  written, and the plan says to check it (`zones.offsetAt` is null).
- Hermes on Windows hashes its bundled skills with `\` paths, ordered
  case-folded; the fixture carries both systems' hashes.
- The archive reader refuses names Windows can't hold; no executable bit
  is set; tests that need one (`scripts_keep_their_executable_bit`,
  `a_tasks_folder_others_can_write_is_refused`) skip there.
- From the final review: `HERMES_HOME` expands `%NAME%` (and `~`,
  `$NAME`); a skill file name Windows can't hold is listed under Not
  imported before anything is written; the tests that make links
  (`a_linked_skill_folder_*`) and a `:` in a file name
  (`a_skill_file_name_harness_cant_write_is_listed`) skip on Windows.
  A part the import can't write (a file another program holds open) is
  listed in report.md and the output, exit 1, and the rest is written.

## Built by the Mac session: prompt-injection checks (2026-11-24)

Spec `docs/superpowers/specs/2026-11-24-harness-injection-checks-design.md`,
plan `docs/superpowers/plans/2026-11-24-injection-checks.md` (branch
`platform/inject`). The checks assume the model obeys the hostile text; 32
cases (`src/inject.zig`): 1–8 end to end in `scripts/injection-demo.sh`,
which the smoke script runs with `--check` (so Windows CI runs it under Git
Bash), 9–32 as unit tests `injection_NN_…` through Core. Case 32 came with
the Hermes import: a skill installed from a repo asks to send memory out.

**What changed in shared code, as built:**

- `outside.zig` (new, pure): source names, the question line, roles of MCP
  servers (`home` and `car` mark nothing, `calendar` or a name with it,
  mailmcp's tools).
- `agent.zig`: `Conversation.Turn.outside`/`marked`/`own`,
  `Conversation.summary_outside` (summaries keep the marks of the turns
  they were made from); `Run.conv`, `start_marks`, `own_words`, `loose`,
  `mark()`, `outside()`. Calls that ran mark (fetch/browse and allowed
  redirect hops `page HOST`, search, history with tool results, MCP by
  role, `web HOST` in `webAllow`, helpers' marks after `delegate`).
  `logRun` puts `outside`/`outside_more` on gate lines (`log.Tag`), and on
  turn lines (the first: what the run started with; later: all it read).
  `Conversation.index` keeps the mark bounded (64 sources).
  `decideAndAskWith` adds the line to the question; `Question.outside` and
  `Skip.outside` carry it. The "not available here" branch now logs
  `deny`, `not offered in this run`; an unknown name logs `no such tool`.
- `gate.zig`: `Ctx.outside`; `remember` and `people note` default to ask
  when set (`outside text: asked by default`), never `allow_day`;
  unattended `outside text, unattended`. Rules decide as before.
- `core.zig`: `Incoming.forwarded` and `Queued.forwarded` (a forwarded
  message is never a command; `chatTurnWith`), `mailTurn`'s marks and
  own words, `triggerMarks`, a brief's marks, `serverRole`, workflow
  instances' marks (`wstate.State.outside`, `Start.outside`, saved in
  `state` and `line`), the line on member and skipped items, the memory
  writer reading only the owner's words of a marked turn. `WfAsker`
  matches a stored answer on the question without its outside line.
- `telegram.zig`: `Message.forwarded` from `forward_origin` (or the older
  `forward_date`); `main.zig` passes it on.
- `history.zig`: `Answer.outside` (tool results, or a run that had read
  outside text); history and `session.zig` label a run's start with
  `outside.startLabel` ("Forwarded", never "Owner"). `summaries.zig`: the
  day summariser leaves outside text out. `agent.WfDesk.start` takes the
  run's mark. A forwarded message is never a command in groups either.
  `build.zig` installs harness-fake.

**Rulings worth knowing** (all in the plan): marks live on turns, so they
go with the context on a restart; a server's role comes from setup's
section names; the day summariser and the memory writer leave outside
text out; `outside` on a private line is hashed like other fields.

**Skipped on Windows:** `injection_23_a_key_in_encoded_forms_is_masked`
and `injection_25_a_key_reversed_gets_through_once_allowed` (they use
`base64`, `od`, `sed`, `rev`: POSIX commands). The demo's case 5 runs
`type PATH` on Windows instead of `cat`. Untried on Windows: the demo
under Git Bash, `--serve`'s Ctrl-C. If a demo case fails only on Windows
CI, say so in your status section.

**A rule for new code from now on:** a new source of third-party words
adds to the mark; a new tool that keeps text for later runs is asked in a
marked conversation.

**Still open** among the Hermes differentiators: the gate as an MCP proxy;
private conversations on a local model. None is claimed; ask the owner
before starting one. (The Hermes import is being built, see above.)

## Latest from the Mac session (2026-11-24)

Fetch `harness-logins` (2974d9b or later). Since your apps push:

- **Your apps batch is merged** into the household (399ac1f). One
  conflict, `close()`'s wait loop: the app server stops first, then both
  sides' running flags are waited on, then the apps' jobs are freed.
- **A who kind of harness's own: `harness:NAME`** (security review).
  Harness's internal jobs (the people's pass, away, trips, warm-car,
  habits, the evening, the errands' lists, reorders, deliveries and
  upkeep) run as `harness:NAME`, never `schedule:NAME`, so a task, brief
  or schedule the owner names `away` never gets harness's rules. No
  settings file can produce one; a workflow's start line may name it only
  in harness's own workflow of the same name; the shipped rules say
  `[harness:away]`. Any new internal job uses `harness:NAME`. Apps stay
  `app:NAME`.
- **New since your fetch**: the household duties (away mode and trips,
  the doorbell, errands and upkeep, medication reminders and bedtime,
  habit suggestions, the evening message and a butler preset, the car's
  heating through Tesla), mail (mailmcp; owner's question 1 answered: the
  butler's own address, plus the owner's mailbox read-only with drafts,
  opt-in), the diary (calmcp), people, emergencies. `Routine.all` has 16.
- **Windows lessons from CI in the servers**: a binary that does TLS sets
  `std_options.unexpected_error_tracing = false` (crypt32 fails an
  Ed25519 CA with NTE_BAD_ALGID, which std has no name for, and Debug's
  trace panics); a unit test that reaches that path skips where the test
  runner's trace is on; tests compare joined paths with
  `std.fs.path.sep_str`; a temp dir a test lists opens with
  `.iterate = true` (Linux).
- **Owner questions**: 1 answered (email). 2, 3 and 4 still open, plus a
  new 5: messages to other people (WhatsApp, Signal or SMS). Build around
  them as before. Everything not built is in
  `docs/superpowers/specs/2026-11-23-harness-gaps.md`.

## Next (from the Mac session, 2026-11-23)

Phases A and B are in `harness-logins`: conversations, the inbox,
triggers (gap 6), workflows (gap 7), agent definitions, file roles and
model providers, merged with your items 3–8 and the macOS sandbox
(sandbox-exec, `sandbox.run`'s third branch) and APFS clones. The run and
approval code has settled, so your held-back batch can start. Fetch
`harness-logins` first.

1. **Runs pick an environment** (gap 2's gate part): pins in `[use]`,
   `shell@NAME` in the gate's choice, `env_save`, the definitions'
   `environment`, and a workflow step's `env NAME`. Replace these, each
   one function today: `workflows.envProblem` (accepts only `host`:
   "runs don't pick an environment yet"), agents' `environment` (host
   only), and triggers' runs (host). The macOS branch of `sandbox.run`
   exists; the Mac session tests macOS once you push.
2. **Try in a copy** — Part 3 of
   `docs/superpowers/specs/2026-11-23-harness-routines-undo-copies-memory-design.md`
   (the owner asked for it on 2026-11-23): `workspace = copy` in a
   sandbox section, a run's own copy (cloned where `clone.platform` can),
   its changes as an inbox item (Apply, Drop, Show), `check =` and
   `apply = ask|check`, `copy_mb`. Build it with item 1. On macOS the copy
   is at its own path (sandbox-exec can't remap paths); the Mac session
   tests that branch after you push.
3. **Apps' API** (reads, acts, runs as `app:NAME`), `app_draft`,
   `app_save` and the review page, versions and forks, and the question
   bar (the inbox is in: `Core.answerItem(id, key, text, via .bar)`).

The Mac session meanwhile builds Parts 1, 2 and 4 of that spec (remote
MCP servers and sign-in, the morning routine, Undo, long memory); Undo
adds a button to the end of runs (core.zig/agent.zig), so expect small
conflicts there. As before: your own branches, test-driven, full suite
and cross builds green, and the owner decides every push.

### Status from the Windows session (2026-11-24, branch `win/cmd`)

- Done: cmd's own `dir`, `del`, `ren`, `copy`, `move` and `cd /d` work in
  a Windows sandbox (the owner's decision on 7.4). A sandbox's command
  starts through a launcher in a logon session of its own, where the
  workspace and the home are drives of the sandbox's own; what was tried,
  the rulings (R30 to R36) and the fallback:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 9.
- New in shared code: `proc.spawnInSession` and `proc.sandboxLaunch`
  (Windows only), `harness sandbox-launch` (main.zig, first thing in
  `main`), `harness-fake --sandbox-launch`, and harness-fake links
  advapi32 and userenv on Windows (build.zig). Nothing in the gate, the
  agent's call path or the conversations' state changed; `shellDef` has
  one more sentence on Windows.
- CI after the cmd push (runs 45388410033, 45392418965): the failing
  line was the test's own (`/env check` said "no" for cmd's own
  commands), not the SHARING_VIOLATION in the trace, which is a rename
  `writeReplace` tried again and got through. Two causes fixed: the
  probe ran `dir` in the test's empty workspace, which some Windows
  count as an error (it lists the sandbox's home now), and one failed
  start of a session ended the drives for the whole process (R37, R38
  in the plan's section 9).
- The Windows runner's refusal is explained (plan R39, R40): Windows
  Server gives sandboxes (app containers) no access to NUL, so `>nul`
  there says "Access is denied". It was never `dir` or the drives. For
  the Mac session: a test or smoke step that runs a command in a Windows
  sandbox must not redirect to nul; outside a sandbox nul is fine.
- For the Mac session: `calendar_attendees_become_people` fails on every
  system while the clock is inside a busy event of its fixture (the
  owner is busy, so the line is held): CI run 45388410033 ran during
  "Lunch with Anna", 24 Nov 12:00 to 13:00 UTC. Its events are in the
  past from then on, but the fixture's dates should not be real ones.

### Status from the Windows session (2026-11-23, branch `win/apps`)

- Done, tested on Windows and Linux: item 3 (the apps' API, the bar,
  `app_draft`, `app_save` and the review page, versions and forks).
  What was built, the rulings (R15 to R29) and what is left:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 8.
- `[apps] on` is on by default now: `harness run` and `harness chat` print
  an "Apps:" line.
- `inbox.New` has `app`; `agent.Question` has `app`; `[money] apps` and
  `[apps] act_seconds`, `runs_per_hour` are new settings.
- Still open from before: cmd's built-ins in a Windows sandbox (section
  7.4), for the owner to decide.

### Status from the Windows session (2026-11-23, branch `win/envs`)

- Done, tested on Windows and Linux: the data folder inside a `read =`
  folder (1e355f3), item 1 (runs pick an environment, c0dde2e) and item
  2 (try in a copy, 370f96e). Rulings and what is left:
  `docs/superpowers/plans/2026-11-22-windows-platform.md`, section 7.
- Not started: item 3 (apps' API, `app_draft`, `app_save`, the bar).
- For the Mac session: `sandbox.Request.mount_at` is Linux's alone; on
  macOS a copy run's sandbox gets the copy as `workspace` (its own path)
  and `Mode.copy` reads as `rw` in the profile. The copy tests in
  `core.zig` and `agent.zig` skip where no sandbox can run; please run
  them on a Mac. `another_step_cut_by_a_restart_asks_in_the_inbox`
  counted `pushed\n` (cmd prints `\r\n`): fixed, Windows CI was red on it.
- Found on Windows: cmd's own `dir`, `del`, `ren`, `copy`, `move` and
  `cd /d` fail inside an AppContainer (they ask the drive's root); see
  the plan, 7.4.

### Decisions since your last fetch

- **The data folder inside a `read =` folder: fix on Linux and Windows.**
  The macOS sandbox refuses the data folder even when a `read =` folder
  holds it (say `read = ~`); bubblewrap and AppContainer show it there.
  The spec says never the data folder, so make Linux and Windows refuse
  it too (bwrap: mask it inside the read bind; AppContainer: a deny ACE
  for the profile's SID on it), and extend
  `sandbox_cannot_read_data_folder_or_home` with a `read =` folder that
  holds the data folder.
- **macOS sandbox, as built** (docs/superpowers/plans/2026-11-23-macos-sandbox.md):
  network on reaches outside hosts and the local network but never this
  Mac (sandbox-exec can't tell the two apart; README says so); no
  `/dev/tty`; TMPDIR is its own temp (`state/env/NAME/tmp`) and `/tmp`
  is refused; `/Library` readable except its Keychains; Keychain
  services denied. Network on differs per system (Linux reaches the
  host's loopback, Windows and macOS don't); keep the README's account
  of it current.
- **Settings files are nine**: triggers.ini took slot 7 and
  environments.ini slot 8 of `settingsFiles` (the auto-merge had both
  parsers read slot 7; fixed in e261465 with a test). A new settings
  file gets a new slot. `guardedFiles` has seven; the `workflows/` folder
  is guarded on its own (chmod go-w).
- **Money from runs an app starts**: refused behind `[money] apps = off`
  (default off), as `[money] triggers` and `[money] workflows` do, until
  the owner answers question 2. App acts never call money tools (the
  apps spec).
- **State files**: every file replaced whole goes through
  `util.writeReplace`, now including triggers' state, triggers.ini
  writes and workflow instances (`wstate.writeReplace` calls it).
- **Still waiting on the owner**: question 1 (email), 2 (money from
  automation; built off), 3 (the default environment for unattended runs:
  keep `host` behind one setting) and 4 (apps on the phone: loopback
  only), and the hosted design's five questions. Build around them as
  before.

## Status (Windows session, 2026-11-22)

Items 1 and 2 below are done, on branch `harness-windows`, merged into
`harness-logins` (f14261e). What was found and done is in the "Done"
sections at the top of `HANDOFF-windows-audit.md` and
`HANDOFF-windows-web.md`. After the merge: Windows 464 pass, 33 skip,
smoke all ok; Linux (WSL, an ordinary user) 488 pass, 9 skip, smoke all
ok. The 33 that skip on Windows: POSIX shell commands in their setup (14:
tools 7, mcp 4, agent 3, among them the new
`shell_starts_in_its_dir_and_the_question_and_lines_name_it`; most have a
Windows twin), the stand-in browser scripts and page.zig's render tests
(14), symbolic links (4, two of them the snapshot store's: Windows makes
them only with Developer Mode or as administrator; junctions are tested
instead) and SIGTERM (1).

Items 3 to 8 are done too, each on a branch of its own, stacked in one
line on `harness-logins` (none pushed; the owner decides):
`win/sandbox` (3: environments.ini and the sandbox runners; also a fix:
Windows shell commands with quotes in them failed), `win/remote` (4),
`win/app-server` (5), `win/clone` (6), `win/state-files` (7: also found
grants and the written list rewritten in place), `win/hosted` (8, and
this status). What was built, the tests and the rulings are in
`docs/superpowers/plans/2026-11-22-windows-platform.md`. At the tip:
Windows 11 and Linux (WSL) pass in full, smoke included.

Left on purpose, for after the Mac session's phases A and B have landed
in the run and approval code (changing it now would clash with them):
runs picking an environment (pins, a step's `env`, `shell@NAME` in the
gate's choice, `env_save`), apps' API (reads, acts, runs), `app_draft`,
`app_save` and the review page, versions and forks, and the bar. Not
verified: block cloning on ReFS or a Dev Drive (no such volume here).
Yours: the macOS sandbox (sandbox-exec, a third branch of
`sandbox.run`) and APFS clones (`clone.platform`).

## Get it

```
git fetch origin
git checkout harness-logins        # everything: 0.3, the audit fixes, the specs
```

CI was green on Linux, macOS and Windows (Debug and ReleaseSafe) at 664aa83.

## Read, in this order

1. `docs/superpowers/specs/2026-11-22-harness-platform-overview.md` —
   binding. Read "Rules every spec keeps", "Shared formats" (the `by`
   value `KIND:NAME`, rules `ACTION TOOL[@ENV] PATTERN` in `[who]`
   sections, grant keys, setup approvals, snapshots), "Phase 0", and
   "Questions for the owner".
2. `docs/superpowers/specs/2026-11-22-harness-environments-design.md` (gap 2)
3. `docs/superpowers/specs/2026-11-22-harness-apps-design.md` (gap 8)
4. `harness/HANDOFF-windows-audit.md` and `harness/HANDOFF-windows-web.md`
5. The hosted notes at the end of the agents, file-roles and environments
   specs.

## Yours now (nothing here touches the gate, so you can start at once)

Do them in this order; each on its own branch from `harness-logins`
(suggested names in brackets), test-driven, full suite and cross builds
green before you ask the owner to push.

1. **Job objects** (`win/job-objects`) — HANDOFF-windows-audit.md §1 (I27):
   shell, MCP servers, browse and Chrome start in a job object with
   KILL_ON_JOB_CLOSE; stop, timeout and exit terminate the job; pipe drains
   are bounded. The AppContainer sandbox below builds on it.
2. **The other open Windows items** — HANDOFF-windows-audit.md §2–§5 and
   §7 (mintty echo, the lock and Ctrl-C checks, Credential Manager, the two
   symlink tests that skip on Windows), and HANDOFF-windows-web.md (the
   `web` tool on Windows).
3. **Sandbox runners** (`win/sandbox`) — gap 2's backends as standalone
   runners in a new file (e.g. `src/sandbox.zig`), with gap 2's backend
   tests: AppContainer plus the job object on Windows; bubblewrap on Linux
   (test it in WSL). The macOS runner (sandbox-exec) stays with the Mac
   session, which can test it. Read and check `environments.ini`.
4. **The SSH remote** (`win/remote`) — the runner over the system's
   OpenSSH with harness's own key (`env key`), per gap 2.
5. **The app server** (`win/app-server`) — gap 8 without `api/`: the
   loopback listener with the exclusive bind, tokens, Host/Origin/frame
   checks, headers and CSP, path checks (Windows names too), `app.ini`
   read and checked, app files and the built-in apps' pages served. The
   `api/` reads, acts and runs wait for phase 0.
6. **Clone helpers** — the snapshot store's copy-on-write clones as
   functions with their own tests: ReFS and Dev Drive block cloning on
   Windows; btrfs and XFS on Linux (WSL). APFS stays with the Mac session.
7. **State files on Windows** — replacing a file by rename while another
   process reads it (`state/inbox`, `state/conversations`, `state/grants`):
   make it safe and test it.
8. **Hosted design notes** — turn the three hosted notes into one design
   for the hosted version (one isolated instance per customer; an actor per
   agent instance with journaled turns, e.g. Elixir/OTP; the shared
   filesystem; one VM per instance). A document for the owner, no code.

## Wait for phase 0

The Mac session builds phase 0 first (the `by` value on every run, rules
and grants with who and environment, the new gate kinds) and then phase A
(conversations, inbox, triggers). Until phase 0 is merged into
`harness-logins`, don't change `gate.zig`, `rules.zig`, the run and
callTool code in `agent.zig`, or the run and approval code in `core.zig`;
put your work in new files and keep edits to shared files small. After
phase 0: environments in the gate (`shell@ENV`, pins, `env_save`), apps'
`api/` as `app:NAME`, then the question bar once the inbox (phase A) is in.

## Waiting on the owner

Two of the owner questions in the overview change your part: the default
environment for unattended runs (host or sandbox) and opening apps from the
phone before hosting. Build the rest; leave those choices behind one
setting until the owner answers.

## Rules that stay

The owner decides every push, merge, tag and release. Secrets only through
`harness secret add`, never typed for the owner. Plain labels, no slogans.
Report what you did, test results and any rulings in your final message to
the owner, and in `docs/superpowers/plans/` if you write a plan.
