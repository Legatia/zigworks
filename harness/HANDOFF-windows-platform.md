# Handoff to the Windows session: platform work (gaps 2 and 8, Windows items, hosted notes)

From the Mac session, 2026-11-22. The owner asked to spec the gaps between
harness and the "Agent platform of 2027" blueprint and to share the work
with you. Eight specs are written and reconciled; you own apps (gap 8),
environments (gap 2), the open Windows items and the hosted design notes.

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

### The desk's voice (merged, aea003e)

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

On `platform/desk-win-linux` (merged with `harness-logins` at e5a743c).

- **Your CI is red on Windows at e5a743c, and it is the smoke script, not
  harness.** The three fit-file checks pass `/desk/assets/…` as arguments,
  and Git Bash turns an argument that starts with `/` into
  `C:/Program Files/Git/desk/assets/…`. You fixed it your way since
  (2057083, 3f97af9); my branch now has yours and mine is gone. With it
  all three pass here, the bundle place (`Contents/MacOS` beside
  `Contents/Resources`) included.
- **`utc_offset = auto` on Windows: checked.** A fresh folder starts with
  no zone note, and a new test
  (`on_windows_the_computers_zone_is_what_its_clocks_say`, zones.zig)
  holds `localNow` to the local clock less the UTC clock. Here: +01:00.
  Not checked: a daylight-saving change (I did not move this computer's
  clock), and the desk's shown times in the app.
- **354a8cb's Windows failure was one test,**
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

On `platform/desk-win-linux` (merged with `harness-logins` at 8c4130a).
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

Since your page fix (3edebbc): `smoke-other.sh` has your six page checks
too, in its real-harness part, with a `desk_probe` that posts through
either bridge. They pass in both windows; the windows' smallest inside
size is 1024x700 on both. CI on 7476686: the three desk app jobs passed;
mailmcp on Linux failed `idle_pushes_new_mail_to_a_subscriber` once.

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
| `platform/desk-mac` | harness-desk for macOS | merged into harness-logins (d252816): reviewed, unit 61/61, window smoke 46/46 |
| `platform/desk` | harness's side and the desk page | merged into harness-logins: reviewed, unit 1513/1535, smoke 162 (195 with the stand-ins); avatar.js, fit.js and three.js are stand-ins until the avatar lands |
| `platform/desk-avatar` | the 3D head module, the fit, `harness avatar check` | merged (2ec85ec) |
| `platform/desk-voice` | the desk's voice: any provider that speaks OpenAI's or Gemini's format | merged (aea003e) |
| `platform/desk-base-head` | a base head made from ICT-FaceKit (MIT), replacing the Face Cap one | merged as one commit (squashed, so the 3.3 MB file is in history once) |
| `platform/desk-alone` | `harness run` without Telegram, `harness config set`, `utc_offset = auto` | merged (453b522) |
| `platform/desk-fit-files` | the fit files in the release archives and served from beside the binary; the no-avatar stage | merged (99463fd) |
| `platform/desk-app-setup` | the macOS app carries harness and sets it up (one download, the Set up screen, the key in a native field) | merged (8c4130a); see "the app sets harness up" above |

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
- CI 45612749693 (7e4fa7f, the sandbox default): every job passed but
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

## CI after your cmd push (772c8c4, dfb489f): red on Windows

Runs 45388410033 and 45392418965 fail on Windows, in Debug, in
`core.test.env_check_probes_a_sandbox_and_a_copy_environment`:

```
error.Unexpected NTSTATUS=0xc0000043 (SHARING_VIOLATION)
… dirRenameWindowsInner … util.zig:36 writeReplaceWaiting
```

- `writeReplaceWaiting` already waits 2 s for a held file, so something
  holds it longer. Likely the launcher, or its logon session's drives,
  still has the file open after the check.
- It passed on Windows at 2d3c3d2, just before your push.
- It's yours to fix, since it needs a Windows machine.

Still red at 615d9f3 (run 45414619782), the injection checks' merge.
That merge's unit tests all pass on Windows: 1235/1286, 50 skipped, and
`env_check` is the only failure. The smoke step depends on the unit
step, though, so the injection demo hasn't had its first Windows run.
It runs once `env_check` passes.

The same runs also failed on all three systems in
`calendar_attendees_become_people`. That one is ours: the test read the
real clock, and the fixture has a busy event from 12:00 to 13:00 UTC on
2026-11-24. It's fixed in ed34e74 with a fixed clock.

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
(91a62e0, approved by the owner); plan with its rulings:
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

Fetch `harness-logins` (123eadd or later). Since your apps push:

- **Your apps batch is merged** into the household (11946c5). One
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
