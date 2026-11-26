# harness: the desktop app (the desk)

The owner, 2026-11-24, across one conversation:

> "App we do desktop first. Mobile will be using tg or WhatsApp for now.
> Also since we don't rent server for clients pc side is naturally the
> best place."

> "The app frontend itself should be majority taken by the avatar, chat on
> the bottom, topic and notification on the side."

> "Make it sharper. More cyberpunk and avatar more realistic."

> "Offer choice. And accept user upload as well." / "I want the avatar have
> some actions like blinking or lip moving at talking or other expressions."

> "Shouldn't be looping. One time informing is enough." / "Idle should
> still have some expressions like blinking and thinking and nodding." /
> "There shouldn't be any static moment. At least make him close eyes
> looping breathing if no tasks."

> "It should be an desktop app, not on web. Skip female for now."

2026-11-25:

> "What if we try to build the face with blender 3d? More flexible for
> expressions just user custom will be more complicated" / "Build it. Try
> your best to make it realistic"

> "Use 3d head. Finish the frontend now"

**Approved by the owner on 2026-11-25, with the avatar as a live 3D head**
(this revision) instead of video clips.

The references:

- **Look and layout:** the mockup, https://claude.ai/artifact/NnXy5J39fEoiQFwsmxavC1
  (Desktop app; the states sheet).
- **The avatar:** the 3D head prototype, https://claude.ai/artifact/KsZmbH6vXA6qLaPmSrVdW8.
  Its code and data are in `~/Downloads/butler-3d-head/` (README.txt
  there): `prototype.html`, the render and behaviour; `fit.html`, the fit;
  `head.bin`, `eyes.png` and `eyemask.png`, the fitted butler.

The design was builder-checked against the code, and its answers are
folded in.

## Intent

harness runs on the owner's computer; on the phone it is a chat. The
desk is the window on that computer:

- **The avatar** fills most of it, showing what harness is doing:
  - resting when there's nothing to do;
  - attentive and thinking when it works;
  - glancing over when something needs the owner;
  - speaking, once, when it has something to say.
- **Chat** runs along the bottom.
- **The side panel** holds what needs the owner, the topics, and what
  happened lately.

It's another face of the same agent and conversations, not a second
assistant.

## Goals

1. **The desk is a desktop app:** `harness-desk`, a small native program
   per system with its own window, icon, Dock or taskbar entry and badge.
   It shows harness's own desk pages (the app server's shell) in the
   system's web view: WKWebView on macOS, WebView2 on Windows, WebKitGTK on
   Linux. It's not a browser tab. The other apps stay framed and sandboxed,
   reachable from it.
2. **A chat that's a harness conversation.** Typing in the desk is the
   owner's turn in `main` or a topic. Replies show in the desk and in
   Telegram.
3. **The side panel:** Needs you, Topics and Lately.
4. **The avatar:**
   - a live 3D head: the portrait fitted onto a rigged head with the 52
     standard (ARKit) expression shapes;
   - a choice of the built-in butler or the owner's upload (female later);
   - motion generated live: blinks, gaze, breathing, nods, expressions and
     lip-sync;
   - states from harness's own state, never from the model.
5. **Speech:** the desk can speak replies; the mouth moves only while the
   voice does.
6. **The look:** the mockup's sharp dark style, with no outside hosts.

## Non-goals

- A mobile app. The phone is Telegram; WhatsApp is a separate open
  decision (gaps list).
- The hosted version, which is set aside.
- Drawing the interface natively per system: inside the window it's HTML
  in the system's web view, as in most desktop apps; no Electron, no
  bundled browser.
- Exact lip-sync on every sound. Mouth shapes are estimated from the
  reply's text, timed by the voice; exact timing is a later add-on.
- Head turns beyond what one photo shows. The head turns a few degrees at
  most (about ±4°).
- Making the eyes-closed portrait from inside harness. The owner makes it
  with an image tool, following the desk's guide; without it, the closed
  eyes are drawn.

## Anti-goals

- **Static moments.** The avatar is always in motion: breathing with eyes
  closed, or attentive with real blinks.
- **Looping speech.** One spoken message per reply, with talking motion
  only while the voice plays.
- **Fake blinks.** No swapping or cross-fading whole stills: the lid moves
  over the eye, and a full close lands on the eyes-closed portrait.
- **The model choosing the avatar's mood or the status text.** States and
  status lines come from harness's own facts.
- **Outside hosts.** Fonts, scripts, images and the avatar are all served by
  harness.
- **Tokens on disk.** The desk is entered without writing a reusable
  credential to a file (see "Getting in").

## What the apps design said, and what changes

The apps design kept two things out: "Settings edited from a page" and
"Chat beside an app … need a browser conversation". The owner's request
is exactly a page with chat and choices, so both are lifted **for the
desk only**, harness's own page, never for apps:

- **Apps** still can't answer items, send as the owner or change
  settings.
- **The desk** can, through shell-only API paths that refuse a framed app's
  `Origin: null`. That's today's rule for `answer` (appserver.zig ~355).
- **The desk can't be forked,** because it's the shell, not an app.

## The desktop app and getting in

`harness-desk` is a small program per system. It links only the system's
window and web-view libraries:

- **macOS:** Cocoa and WebKit. It uses Zig and one Objective-C `.m` file
  for the WebKit delegates. headsound already builds a `.m` the same way.
  Minimum macOS 12.
- **Windows:** WebView2, through `WebView2Loader.dll`. The DLL is loaded at
  run time. The C interfaces in Microsoft's `WebView2.h` are used from Zig,
  because the static loader is MSVC-only and releases are built with gnu.
- **Linux:** GTK 3 and WebKitGTK 4.1.

The harness binary is unchanged: std only, as it builds today. The desk app
is built natively in each system's release job, and CI gains a desk-app job
per system. It's a sizeable piece of work: WebView2's COM handlers by hand,
three systems' start, stop and login mechanics, and packaging. Who builds
what is below.

**Finding harness:**

- An app opened from the Dock sees neither `PATH` nor `HARNESS_HOME`. It
  looks in the default data folder, unless `harness open` launched it with
  `--home DIR`.
- At each start, harness writes `state/desk.json` there: its binary's
  path, the port, the data folder and harness's version. The app takes
  the port from it and runs its own copy of harness; the binary's path is
  used only by an app built without one (audit, 2026-11-26: a file in the
  data folder must not choose the program the app runs).
- Before harness has ever been set up, the app sets it up itself (see
  "First run, and the desk alone").

**Its own pages and the bridge:**

- **Two built-in screens,** shipped in the app because harness may not be
  running:
  - "harness isn't running", with [Start harness];
  - "Connecting…".
- **The page and the app talk over the web view's message bridge:**
  `WKScriptMessageHandler`, WebView2's `WebMessageReceived`, and WebKitGTK's
  `script-message-received`. Messages go one way, from the page to the app:
  - `{"badge": N}`: the number of items needing you;
  - `{"attention": "urgent"}`: an urgent item arrived;
  - `{"reenter": true}`: the session ended (harness restarted), so enter
    again.
- **Liveness:** while disconnected, the app checks every 5 s that harness
  answers on its port (`GET /alive`: a 200 and the word `harness`,
  nothing else; another program on the port isn't taken for harness). It
  enters as soon as harness does.

**Getting in (one-time code, a session cookie, nothing reusable on disk):**

1. The app writes `state/open-request`, which holds no secret.
2. The running harness writes a one-time code to `state/desk-code`. The
   code is used once and valid for 60 s, and the file sits in the data
   folder (on Windows, `%LOCALAPPDATA%`'s own ACL).
3. The app reads and deletes the file, and loads
   `http://127.0.0.1:PORT/enter?code=…`.
4. harness answers with a session cookie: HttpOnly, SameSite=Strict, no
   Expires. harness holds the session in memory only.

The web view uses a non-persistent store (`WKWebsiteDataStore
nonPersistent`, WebView2 InPrivate, WebKitGTK ephemeral), so nothing
reusable reaches disk. A restart of harness or of the app re-enters on its
own through the bridge's `reenter`; you don't notice.

**What the app server learns:**

- routes for `/alive`, `/enter` and `/desk/…`;
- the Cookie header, and Set-Cookie;
- POST on the desk paths;
- a 10 MB body limit for the voice and upload paths only;
- serving the avatar files from `avatars/` and the fit files from
  `desk-assets/` (up to 20 MB a file, for these paths only).

The new owner-acting desk paths answer only to the session cookie:

- sending as the owner;
- settings;
- upload;
- the run view.

**The old `/s/TOKEN/` shell link** keeps exactly what it has today: the
apps, and answering items through the bar. It gains nothing new. From the
desk, apps open in `/desk/apps/NAME`, which frames the app's own `/a/…`
token path as today.

**The web view is configured as an app:**

- no navigation away from `127.0.0.1:PORT`. A link to elsewhere that the
  owner clicked with the mouse opens in the system browser; any other
  navigation away (a script's, a redirect's, a frame's) is refused and
  opens nothing;
- media plays without a click;
- the app answers the page's microphone request for this origin only:
  - macOS: `requestMediaCapturePermissionFor…`, plus
    `NSMicrophoneUsageDescription` in Info.plist;
  - Windows: `PermissionRequested`;
  - Linux: `permission-request`, with `enable-media-stream` on.
- **macOS Info.plist** also needs `NSAllowsLocalNetworking`. Since macOS
  14, App Transport Security refuses plain HTTP to IP addresses by default.
- **Windows:** the web view's data folder is set explicitly, under
  `%LOCALAPPDATA%\harness\desk-webview`. If the WebView2 Runtime is
  missing (a few Windows 10 machines), the app says so and links
  Microsoft's installer. CI's smoke installs the runtime first.
- **WebGL 2 is on** in every web view, since the avatar draws with it.
  WebKitGTK needs `enable-webgl` and its hardware acceleration policy set to
  always.
- **Linux:** WebKitGTK has no speech synthesis, so `speak = browser` isn't
  offered on Linux; a provider, or off.

**Badge and attention:**

| System | Badge | Urgent attention |
|---|---|---|
| macOS | the Dock badge, a real count (`NSDockTile badgeLabel`) | `requestUserAttention` once |
| Windows | an overlay dot on the taskbar icon (ITaskbarList3), and the count in the window title, "harness (2)" | `FlashWindowEx` once |
| Linux | the count in the window title | the GTK 3 urgency hint |

There are no system notifications this round, because Telegram already
rings the phone.

**harness runs on its own, and the app doesn't own it:**

- [Start harness] runs `harness run` detached; it keeps running after the
  window closes.
- **Stop** is a new command, `harness stop`. It writes
  `state/stop-request`, and the running instance exits cleanly on its next
  tick. That works the same on all three systems, consoles or none.
- **Open at login** is a new command, `harness autostart on|off`, which
  starts `harness run` at login:
  - macOS: a LaunchAgent in `~/Library/LaunchAgents`;
  - Windows: the HKCU Run key;
  - Linux: an XDG autostart entry.

  The app's menu calls these commands. The app itself isn't started at
  login; you open it when you want the window.

**The fixed port.** `harness init` writes `[apps] port`, a free high port;
existing installs get one at the next start. If it's taken at start,
harness tries the next ten, writes the one it used back, and says so.

**A limit, stated in the README.** A program running as you on this
computer could read the code file within its 60 s, or talk to harness the
way the app does. That's the same as for any local app. harness's own
commands run sandboxed when unattended, and on the host only with your
approval.

**Release:**

| System | What ships |
|---|---|
| macOS | a `.app` bundle (arm64 and x86_64), ad-hoc signed in CI. Without the owner's Apple developer signing it opens through System Settings › Open Anyway on first run. |
| Windows | `harness-desk.exe` with `WebView2Loader.dll` beside it. The DLL comes from Microsoft's NuGet package, pinned by version and SHA-256 in CI, and is redistributable. |
| Linux x86_64 | a dynamically linked binary that needs `libwebkit2gtk-4.1-0` and the GStreamer plugins above |

Linux arm64 is left out this round. Proper signing, with an Apple
developer account and a Windows certificate, is the owner's decision at
release.

## The chat

- **The desk is an extra output, not a conversation `Kind`.** Core keeps
  its one channel (Telegram, or the terminal under `harness chat`) and
  fans out every post to the desk's listeners. That's an in-memory queue
  per open desk page.
- **A desk turn:**
  - The desk sends text through the same path as an owner's message
    (`handleTextIn(conversation, text)`), so the one-turn queue and
    commands work unchanged.
  - Telegram shows a quiet echo of the owner's words, then the reply as
    usual: "You, on the desk: Find me a two-bedroom near Kazimierz…" A bot
    can't post as you; the echo keeps the phone's thread readable.
  - `[desk] echo = off` turns the echo off.
- **History:**
  - The desk keeps the last 50 messages per conversation in memory,
    filled from the fan-out, and from the log at start for conversations
    that aren't private.
  - Private conversations' text is never written to disk, so after a
    restart their history starts empty: "Earlier messages aren't kept for
    private conversations."
- **Presses:** a press in the desk answers an inbox item through
  `answerItem(…, via .bar)`, the shell's path, keeping the shell's 0.5 s
  click guard.
- **Voice input:** the mic button ("Record a message"; "Stop recording"
  while it records) shows only when `[voice]` is set. Under the message
  box, inline while the button shows: "Recordings are sent to NAME (HOST)
  to be transcribed." (harness's settings give the provider and its
  host; Speak replies names its provider's host the same way).
  1. It records in the page (MediaRecorder); the desk app grants the
     microphone for this origin only.
  2. It posts the audio to a shell path (up to 10 MB, a larger body cap
     for that path only).
  3. harness transcribes it with `Transcriber.transcribe`. The transcript
     is shown quoted, as Telegram voice notes are, then it's a turn.

## Live updates

There's no SSE. The desk uses long-polling, as `api/log?wait=25` already
does:

- the shell path `desk/events?after=N&wait=25` answers at once when
  events are newer than N, else when one arrives, else empty after 25 s;
- events cover messages, item changes, state changes, card changes and
  speech;
- this fits the app server's 30 s idle limit and its stop deadline;
- one held request per open desk page.

## The side panel

- **Needs you:**
  - open inbox items, newest first, the full item with its buttons;
  - urgent items first, in the alert colour.

  An item is urgent when it comes from an urgent post or trigger. That's
  a new `urgent` field on inbox items, set where the post's urgency is
  known (core.zig ~3049–3086). An open alert record (escalation) counts
  too.
- **Topics:** one line per topic from the cards (topics design): the
  title, then pending or next, and a news dot.
  - The dot means news since the owner last opened that topic in the desk.
    A per-topic `seen` time is kept in state.
  - Clicking opens the topic in the chat and clears its dot.
- **Lately:** the cards' "Lately" lines, harness's own, newest first.

## The avatar

### States, from harness's facts

| State | When | Avatar |
|---|---|---|
| urgent | an urgent item or alert is open | eyes on you, brows raised, no nods; red frame |
| speaking | the voice is reading a reply | lip-sync while the voice plays; brows lift on long words; a small nod at each sentence's end |
| needs you | an inbox item is open | eyes on you, brows a little raised; one glance toward you when an item arrives; magenta frame |
| working | a run is in progress | thinking: gaze up and aside, brow drawn, a glance back now and then, a nod every 9–16 s; cyan frame |
| quiet | quiet hours | eyes closed, slow breathing, dimmed |
| resting | none of the above | eyes closed, breathing |

**Two moments, also from facts:**

- A run that ends with a reply gives a brief smile, 2 s.
- A run that ends in an error gives a brief concern.

**Always moving.** Each state keeps the live layer running: breathing, a
slight drift of the head, saccades with the lids following the gaze, and
blinks every 2.5–6 s (more often while speaking). With eyes closed there
are no blinks, but slower, deeper breathing. Nothing loops: the timings are
random within their ranges.

### The status card

The card shows only harness's own facts, never model text. Core gains a
live view of runs, which harness doesn't track today. For each run in
progress it has:

- **who started it,** and the conversation;
- **a label:** the first line of the owner's own message for an owner
  turn, or "Routine: NAME", "Trigger: NAME", "Workflow: NAME";
- **its start time;**
- **how many helpers are running now,** counted when `delegate` starts
  and ends each task.

The card reads, for example:

> Working: "Find me a two-bedroom near Kazimierz…" · 2 helpers · 1 min

When it's resting, the card shows the next thing coming, from the
cards. "See the work" opens the Work topic's latest post.

The card's other lines are plain counts and labels (2026-11-26): "1 open
item" / "N open items", "1 urgent item" / "N urgent items", "Urgent alert
open", "Quiet until HH:MM", and "No open items" at rest; Needs you, when
empty, says "No open items" too. When the chosen avatar can't be loaded,
or is drawn as its portrait only, the stage says why.

### How the head works

This is the prototype's method; its code is the reference.

- **The portrait is projected onto a rigged head.**
  - The base head is made from USC ICT's ICT-FaceKit (MIT): its neutral
    head with the 52 ARKit expression shapes (ICT's own, mapped), its
    teeth, gums and tongue. (It was three.js's Face Cap sample until
    2026-11-25; its license couldn't be verified.)
  - It's fitted to the portrait: face landmarks are found on the photo and
    on a render of the head (MediaPipe Face Landmarker), then a similarity
    transform and an RBF warp map the head onto the photo.
  - The photo becomes the texture by projection, so at rest the head looks
    exactly like the portrait.
- **The expression shapes are carried through the warp,** so every shape
  acts where the photo's features are.
- **Eyes:**
  - The eyeballs are spheres behind the eye openings, textured from a
    cleaned crop of the photo's eyes (the reflections removed). A
    reflection is drawn live, so it stays put as the eyes move.
  - The openings are cut by the photo's eye outline, and the eyeballs show
    only there (a stencil).
- **Blinks:** the lids close by the blink shapes. Near a full close, the
  eye region blends into the eyes-closed portrait, projected onto the
  closed lids. Without that portrait, the closed lid is drawn in the
  lid's own skin tone.
- **The mouth:**
  - The inside is the head's own mouth geometry, coloured dark: a roof, a
    tongue-coloured floor and the inner lips. It's found by what's hidden
    at rest.
  - The teeth, gums and tongue are the base head's own, both rows, each
    point moving with the jaw as it opens.
- **The rest of the portrait** (hair, neck, shoulders, background) is a
  backplate. It follows the head by the face's depth and rises with each
  breath.
- **Lighting:** a relight term shades the deformations against the
  photo's own light, so a smile or an open jaw reads in 3D.
- **Rendering:** WebGL 2 through three.js. three.js is pinned at r170,
  vendored in the binary, and its MIT notice is kept. The desk draws at 30
  frames a second when resting or quiet, and stops while the window is
  hidden. Without WebGL 2, the desk shows the still, breathing by a 0.6%
  scale ease.

### The avatar pack

An avatar is a folder, `avatars/NAME/`, with `avatar.ini` naming its files.

| File | What it is |
|---|---|
| `still` | the portrait, eyes open, facing the camera, mouth closed (JPEG or PNG) |
| `closed` | optional: the same portrait with the eyes closed, nothing else changed |
| `head` | the fitted head (`head.bin`): a JSON header and arrays (positions, normals, the two projections, the 52 shapes, teeth, eye and mouth data), versioned |
| `eyes` | the cleaned eye crop (PNG) |
| `eyemask` | where the eyes-closed portrait blends (PNG) |

A pack with only a still hasn't been fitted yet: it shows the still,
breathing, and the desk offers to fit it.

**Serving the pack** (the app server learns to):

- serve `avatars/` files to the desk, up to 20 MB a file, for this path
  only;
- with `Cache-Control: private, max-age=86400` and an ETag, not
  `no-store`, so the head isn't fetched again at every load.

**Checking a pack:** `harness avatar check NAME`, std only, checks:

- the files exist, with their types by magic bytes and their sizes;
- `avatar.ini`;
- the head's header: its version, vertex count, shape names, and that its
  arrays fit the file.

### Fitting a portrait

The fit runs in the desk, where the browser has WebGL and can run the
landmark model. It's the prototype's `fit.html` made into a step of the
Avatar settings.

**What it needs, the fit files** (`desk-assets/`, from the release archive,
not in the binary because of their size):

- MediaPipe's tasks-vision 0.10.14 module and WebAssembly, and its face
  landmarker model (Apache 2.0, pinned by SHA-256);
- the base head (`base-head.bin`): made from ICT-FaceKit (MIT), with the
  landmarks found on its render. It's committed in the repository
  (`harness/desk-assets/`, with `base-head-NOTICE.txt`) and made again by
  `tools/make-base-head.mjs` from ICT-FaceKit's files at a pinned commit,
  each checked by SHA-256.

The fitted butler stays out of the repository and out of releases until
its portraits are cleared (gaps list); the test suite uses a small made-up
head.

**What it checks first, refusing with the reason:**

| Check | Message |
|---|---|
| no face found | "No face found. Use a clear photo of one face." |
| more than one face | "There's more than one face. Use a photo of one person." |
| turned more than 8° | "The face is turned. Use a photo facing the camera." |
| mouth open | "The mouth is open. Use a photo with the mouth closed." |
| eyes closed | "The eyes are closed. Use a photo with the eyes open; add an eyes-closed version after." |
| face under 250 px wide | "The face is too small. Use a larger photo." |

It also warns without refusing:

- a face under 500 px wide: "This will look soft. A larger photo looks sharper.";
- a photo taller than wide: "A photo wider than tall fills the window; this one leaves bands at the sides."

**For the eyes-closed version:** it must line up with the still. The
landmarks outside the eyes may move by at most 12 px; the butler's pair
moved about 8. If not: "This eyes-closed photo doesn't line up with the
portrait. Change only the eyes."

**What it writes:** `head`, `eyes` and `eyemask` go into the avatar's
folder through the upload path, and the avatar switches to the fitted head.

### Built-in avatars

- **The butler** (male), made 2026-11-24/25:

  | Pack file | Source |
  |---|---|
  | `still` | `Neon Cyborg Officer (Clean Skin).jpg` |
  | `closed` | `Neon Cyborg Officer (Eyes Closed).jpg` |
  | `head`, `eyes`, `eyemask` | `~/Downloads/butler-3d-head/` (the prototype's fit) |

  These ship in the release archive under `avatars/`, which `harness init`
  copies to the data folder. That happens only after the owner clears the
  portraits' licensing. Until then, the build takes them
  from the owner's Downloads folder for local use.
- **The female avatar is skipped for now** (the owner, 2026-11-24).
- The old video clips are no longer used.

### Your own avatar

The Avatar settings in the desk:

- **Choose** the built-in butler or one of your own. The choice is written
  to `[desk] avatar` through harness's write-then-reload path, as
  `/persona` does.
- **Upload a photo,** JPEG or PNG, up to 10 MB.
  - **Shown inline beside the button:** "JPEG or PNG, up to 10 MB."
    (Amended 2026-11-26, the owner after the desk app's audit: what a
    photo should be is explanation, so it goes behind the "i"; a photo
    that doesn't fit is refused with the reason. "Works best without
    glasses." is dropped: the bubble's line on glasses says it.)
  - **Behind a small "i":**
    - Facing the camera, eyes open, mouth closed.
    - One face, head and shoulders, wider than tall.
    - The photo is fitted onto a 3D head and becomes the whole scene: its
      background, hair, shoulders and lighting.
    - These are refused, with the reason: a face turned more than about
      8°, an open mouth or teeth showing, closed eyes, more than one face,
      a face too small to find.
    - These fit but may look off: glasses (the eyes move behind frames
      drawn on the skin), hair over the eyes, cartoon or anime styles
      (which may not be found at all).
    - Every avatar gets the same teeth and mouth, and turns its head a few
      degrees at most.
  - **The upload requires one ticked line,** inline:

    > This is me, someone who agreed, or a made-up character.

  The photo stays on this computer, in `avatars/NAME/`.
- **Fitting runs at once,** taking a few seconds, and the head goes live.
  While it runs, the still breathes.
- **"Add an eyes-closed version"** takes a second photo.
  - Behind an "i" (all of it, since 2026-11-26):
    - Recommended: the avatar rests with its eyes closed.
    - Make one with an image tool: ask it to close the eyes and change
      nothing else. It's one image edit, not a video.
    - It must line up with the first photo, and the desk checks this.
    - Without it, closed eyes are drawn in the skin's tone.
- **After a fit,** the settings show what the fit found:
  - the face's size;
  - any warning;
  - whether an eyes-closed version is in use.

### The avatar module

The desk page and the avatar meet at one plain-JS module, so they can be
built apart:

- `createAvatar(element, packUrl, options)` loads a pack and starts
  drawing;
- `setState(state)` takes one of the six states above;
- `moment("smile" | "concern")` plays a brief expression;
- `arrive()` plays the glance for a new item;
- `speak({ text, audioUrl })`, or `speak({ text, browser: true })`, plays
  the voice and lip-syncs; it resolves when the voice ends;
- `stop()` ends speech;
- `fit(photo, closedPhoto)` returns the pack files.

## Speech

- **Off by default, and any provider can be swapped in** (the owner: "keep it
  configurable, user should be able to swap with their own api or provider
  preferred"). `[desk] speak = off | browser | NAME`. harness fetches the
  audio, and the key never reaches the page.
  - **`browser`:** the system's own voices, local and free; not on Linux.
  - **NAME, any speaking provider:**
    - Two presets work with a stored key alone: `openai` (OpenAI's API,
      key `openai`) and `gemini` (the Gemini API, key `gemini`).
    - Any `[provider NAME]` section works too, with the same lines
      providers take today: `url`, `key` (a stored secret's name),
      `auth` and `header`. That covers your own key, a proxy, a gateway
      such as LiteLLM or OpenRouter, or a local server. Its `api` says
      how to talk to it:
      - `api = openai`: OpenAI-format `POST {url}/audio/speech`, with MP3
        back;
      - `api = gemini`: Gemini-format `POST {url}/models/MODEL:generateContent`
        with audio output and a prebuilt voice, the key in
        `x-goog-api-key`, or as the section's `auth` and `header` say.
        Gemini returns raw 16-bit PCM (24 kHz, mono), which harness wraps
        in a WAV header for the page.
    - `api = gemini` is for speech only for now. A chat model set to one
      is refused with a plain reason.
  - **Model and voice:** `[desk] speak_model` and `speak_voice` apply to the
    chosen provider. When they're not set, each kind has its own default:
    - openai: `tts-1`, `alloy`;
    - gemini: `gemini-3.8-flash-lite-tts`, with a voice suited to a
      butler.
    Preview models retire, so the README names the date the defaults were
    checked.
  - **In the desk's settings,** Speak replies lists:
    - Off;
    - Browser, except on Linux;
    - every configured provider that can speak, by name.

    For a provider it also shows Model and Voice fields, with the kind's
    defaults as placeholders. Choices are written through
    write-then-reload. Adding a provider (its url and key) stays in
    config.ini and `harness secret add`, so keys are never typed into the
    page. The README shows both presets and a gateway example.
- **Gemini's free tier lets Google use the text** to improve its products;
  a paid key doesn't. harness can't tell which tier a key is on. So
  whenever the chosen provider is `api = gemini`, Speak replies shows
  inline, not behind an "i": "On Gemini's free tier, Google may use the
  spoken text to improve its products. A key on a paid plan keeps it
  out." It's a privacy disclosure the owner must see before choosing.
- **Section names:** `[speech]` already belongs to the Home Assistant
  agent's settings, so none of this uses it.
- **What's spoken:**
  - replies in the conversation the desk shows, up to 400 bytes (as
    speech.zig's `max_spoken`). Longer replies speak their first two
    sentences, then "The rest is on screen."
  - Urgent alerts are always spoken while the desk is open and not muted.
  - Quiet hours: urgent alerts only.
- **Lip-sync:**
  - The spoken text becomes a timeline of mouth shapes (visemes, mapped to
    the ARKit shapes).
  - With the browser's voice, its word boundaries keep the timeline in
    step.
  - With a provider's audio, the timeline is stretched to the audio's
    length, and the jaw follows the audio's loudness.
  - The mouth moves only while the voice plays.
- **No click needed:** the desk app's web view is set to play media and
  speech without one, so an urgent alert is spoken at once.
- **"Play the message"** replays the last spoken reply.

## The look

From the mockup:

- **Colours:**
  - near-black `#07070D`, with panels `#0B0B15` and `#0E0F1A`;
  - hairlines `#24263A` and `#3A3D5C`;
  - text `#E8E9F3` and `#9A9CB8`;
  - cyan `#22E5FF` (working), magenta `#FF2BD6` (needs you), red-orange
    `#FF4D3D` (urgent).
- **Shapes:** cut corners; HUD corner brackets in the state's colour; a
  faint scan-line texture; a sweep line while working.
- **Type:** Chakra Petch for the interface, JetBrains Mono for readouts.
  Both are OFL; the WOFF2 files are embedded.
- **Accessibility:** contrast at least 4.5:1, targets at least 44 px,
  visible focus. With reduced motion:
  - the sweep stops;
  - the head keeps blinking and breathing, but drops the drift and nods;
  - the mouth moves only when speaking.
- **Sizes:** layout from 1024 px wide. Under 900 px the side panel goes
  below the chat.

## Constraints

- Zig 0.17.1, std only, on harness's side, built as today. The desk is
  HTML, CSS and plain JS in the binary, with no build step. three.js r170
  (MIT) is vendored as one pinned file in the binary. The fit files are
  in the release archive.
- **The desk app is the one exception:** it links each system's own window
  and web-view libraries (Cocoa and WebKit; WebView2 and its loader; GTK
  and WebKitGTK 4.1). It's built on each system, not cross-built. The CI
  matrix gains a desk-app job per system.
- **The app server's rules hold:** loopback only, Host and Origin checks,
  and a CSP with every load on this server. Shell paths refuse
  `Origin: null`.
- **Names:**
  - the app is `harness-desk` ("harness" in the Dock), and `harness open`
    starts it or brings it to the front, on the data folder harness was
    given: one window a data folder on each system (a second start on a
    folder shows the first's window and ends; another folder is another
    window);
  - the page is at `/desk`;
  - code names must not clash with core's `desk`, `appDesk` or `wfDesk`;
  - `desk` joins `apps.reserved`.
- **Injection rules hold:** outside text is shown, never put in a prompt.
  Desk messages are the owner's words, and avatar files are the owner's.
- Copy follows CLAUDE.md.
- **Tests:**
  - the code-to-cookie entry: a code works once and an expired one is
    refused; the code file is readable only by you and is deleted when it's
    read or expires; no reusable credential is written to disk;
  - the desk app on each system: it starts, connects, shows the badge,
    keeps navigation on 127.0.0.1, and opens other links in the system
    browser (a smoke run per system in CI where a display exists; on
    Linux under Xvfb);
  - shell-only paths refuse a framed app;
  - a desk turn goes to the right conversation, with Telegram's echo and
    reply;
  - private history stays in memory only;
  - the long-poll;
  - urgent items;
  - the run view: label, helpers and start time;
  - the state table;
  - serving the avatar files with caching;
  - `avatar check` on good and bad packs, with the made-up head;
  - the smoke opens the desk over HTTP and drives one message.
- **Docs:**
  - the README: Desk; Avatar packs; Speech; the local-app limit;
  - the gaps list:
    - the portraits' licensing;
    - the female avatar;
    - exact lip-sync timing;
  - the ledger and the Windows handoff.

## First run, and the desk alone (added 2026-11-25)

On 2026-11-25 the real app was tried against a fresh data folder. Entry
and a chat turn worked. Four things stood between a download and a
working desk:

- `harness run` exits without a Telegram bot;
- setup is terminal-only, and the app only says to run `harness init`;
- the stage is empty: no avatar and no fit files reach a fresh install;
- times show UTC.

This section closes them. It is my call throughout, not the owner's (see
"Calls I made").

### harness runs with the desk alone

- `harness run` no longer needs Telegram. It runs with the desk as the
  only way in when `[chat] telegram = off`, or when it is on and no token
  is stored: the worker, the scheduler and the desk's server run, and no
  Telegram poller.
- It says which at start, on stderr and once on the desk:
  - "Telegram is off. The desk is the only way in."
  - "No bot token is stored under "NAME", so Telegram is off. The desk is
    the only way in."
- With neither Telegram nor the desk's server, it fails as before, with
  one line naming what to turn on.
- The desk needs no pairing: its entry is the one-time code.
- Everything meant for the owner goes to the desk: replies, briefs, task
  results, items needing you, urgent items, the digest. The echo to
  Telegram is skipped. Nothing may fail or be dropped because Telegram is
  missing.
- With a token stored, nothing changes, pairing included.
- `harness init`'s next steps name the desk first: the provider and its
  key, `harness run`, `harness open`. Telegram follows as optional, "for
  your phone".

### `harness config set`

- `harness config set SECTION.KEY VALUE` writes one setting in
  config.ini. Comments and order are kept. The result is parsed first: a
  change that doesn't parse is refused, and the file is untouched.
- `harness config get SECTION.KEY` prints the value in use.
- A named section is written `provider NAME.url`. A missing section is
  added at the end.
- It never takes a secret's value. A setting that names a secret (like
  `model.key`) is an ordinary setting.
- When harness is running, it says whether the change is in use or needs
  `/reload` or a restart.

### Local time

- `[chat] utc_offset = auto` is the default `harness init` writes: the
  computer's own zone at each use, daylight saving included.
- `+HH:MM` still means exactly that. Config files already written are
  unchanged.
- When the computer's zone can't be read, it is UTC, and harness says so
  once at start.

### The app carries harness and sets it up

- **One download.** `harness-desk.app` holds the harness binary
  (`Contents/MacOS/harness`) and the fit files
  (`Contents/Resources/desk-assets/`). The Windows and Linux packages
  hold the same, beside the app's program.
- **Finding harness:** the app's own copy. The binary `state/desk.json`
  names is used only by an app built without one.
- **No config.ini in the data folder:** the app shows its own screen,
  "Set up", instead of "Set up harness first":
  - Provider: Anthropic, OpenAI, OpenRouter, opencode, omnigate, or
    Other (an address that speaks OpenAI's or Anthropic's format);
  - Model, filled in with the provider's usual one;
  - Address, for omnigate and Other only. While it starts `http://`
    and isn't this computer (localhost, 127.x.x.x, ::1), one line under
    it says the key would cross the network unencrypted. It is on the
    page, not behind the "i": a risk to see before [Continue];
  - [Continue].
- **What [Continue] does,** in order:
  1. runs `harness init`;
  2. writes the provider, model and address with `harness config set`;
  3. asks for the key in a native secure field, and pipes it to
     `harness secret add NAME --stdin`;
  4. starts harness and enters the desk.
- **The key never reaches a page.** The setup screen is the app's own,
  and even it never holds the key. The secure field's note says where the
  key goes: "harness keeps it in this computer's key store."
- **A step that fails** shows the command's own line on the screen. What
  was typed stays.
- **Later changes:** the app's menu has "Provider and key…", which opens
  the same screen with the values in use. The key is asked for again only
  when the owner chooses to replace it.
- Telegram is optional, and still set up in a terminal
  (`harness secret add telegram`, `harness run`, `harness pair`).

### The fit files and an empty stage

- **harness's release archives hold `desk-assets/` beside the binary:**
  MediaPipe's files, fetched at their pinned hashes by
  `tools/fetch-desk-assets.sh` in the release job, and the base head.
  They are not committed (23 MB), apart from the base head.
- **harness serves `/desk/assets/…` from the first place that has the
  file:** `desk-assets/` beside its binary, then
  `../Resources/desk-assets/` (the app bundle), then the data folder's
  `desk-assets/`. (Amended 2026-11-26: the data folder was first. The
  fit's script is imported into the desk's own origin, so a file in the
  data folder must not stand in for a shipped one.)
- **No avatar** (none chosen, or its pack isn't there): the stage shows a
  plain outline of a head and shoulders, the status card as usual, and
  [Add a portrait], which opens Settings at the avatar part.
- **No fit files:** Settings says "The fit files aren't installed.",
  names the folder they go in, and turns the upload off.
- The built-in butler stays held until its portraits' licensing is
  cleared, so a fresh install starts with no avatar.

## Who builds what

- The Mac session: harness's side (the shell pages, the API, entry, the run
  view, serving, speech) and the macOS app.
- The Windows session: the Windows app (WebView2) and the Linux app
  (WebKitGTK, tested in WSLg), against the same pages and API.

## Left to the builder

- The event shapes and API paths, and the desk's JS structure.
- How each system's app is structured: the Objective-C runtime calls on
  macOS, the WebView2 COM interfaces on Windows, the GTK and WebKitGTK
  calls on Linux.
- How the fixed port is chosen at init, and what happens when it's taken
  at start: try the next one, write it back, and say so.

## Calls I made (the owner can overrule)

- **The desk is a native desktop app per system,** with the system's web
  view inside: no Electron, no browser tab. harness stays std only; the
  app links only the system's window and web-view libraries.
- **The app connects to harness and can start it, but doesn't own it.**
  Closing the window leaves the butler running.
- **A badge, plus one bounce or flash for urgent items.** No system
  notifications this round, because Telegram already rings the phone.
- **One agent, one set of conversations.** The desk is an extra output,
  and Telegram gets a quiet echo of what you type there.
- **Entry by a one-time code and a cookie,** with no reusable token in
  files or URLs. The same-user limit is stated plainly.
- **Settings and chat on a page are allowed for the desk only.** Apps
  stay as the apps design says.
- **Private conversations' desk history stays in memory only.**
- **States and the status card come from harness's facts,** never from
  model text.
- **The avatar is a live 3D head** fitted to the portrait (the owner's
  choice, 2026-11-25), not video clips:
  - three.js is vendored;
  - the fit runs in the desk;
  - the fit files ship beside the binary.
- **The built-in butler ships beside the binary,** once its licensing is
  cleared. Female comes later. Speech is off by default.
- **Uploads are fitted at once,** in the desk. The eyes-closed version is
  optional, and made with the owner's own image tool.
- **Upload requires the consent line.**
- **harness runs with the desk alone** (2026-11-25): Telegram is optional.
  A desktop app that can't start without a phone bot isn't a desktop app.
- **The app carries harness and sets it up** (2026-11-25): provider,
  model and address on the app's own screen, the key in a native secure
  field. The desk's page still adds no provider and takes no key; a
  speech provider is still added in config.ini.
- **`utc_offset = auto`** is the default for new data folders.
- **The fit files ship in the release archives,** fetched in the release
  job, not committed and not built into the binary.
- **The app's setup, as built** (2026-11-25, `platform/desk-app-setup`;
  the builder's calls, which the spec left open):
  - The Set up screen is a built-in page in the app's web view, the same
    HTML on all three systems. Only the key's field is native.
  - The form opens on Anthropic. The usual models come from harness's own
    code and README:
    - omnigate: `claude-sonnet` (helpers `claude-haiku`), as `harness init`
      writes them;
    - Anthropic: `claude-opus-4-8` (helpers `claude-haiku-4-5`). It is the
      newest Claude that answers without thinking when a request doesn't
      ask for it, and harness's requests don't carry thinking blocks;
    - OpenAI: `gpt-5`;
    - OpenRouter: `anthropic/claude-sonnet-4`;
    - opencode and Other: none named, so the owner types one.
  - Other is written as `[provider other]` (`api`, `url`), with
    `model.provider other`, in one `config set`. A provider of one's own
    already in use keeps its section's name.
  - `memory_model` and `worker_model` follow the model (or the provider's
    helper) at the first setup and when the provider changes, since the old
    ones belonged to the old provider. Otherwise they stay as the owner set
    them.
  - "Provider and key…" asks for the key again when Replace the key is
    ticked, when the provider's key is stored under another name, or when
    the Address names another host than the one in use (the stored key was
    that host's; it isn't sent to a new one unasked). A new port or path on
    the same host doesn't ask, and neither does a provider set to take no
    key.
  - A change while harness runs: `harness config set`'s own line ("send
    /reload to use it.") in an alert, then the desk again. The app doesn't
    restart harness, which would end the owner's turn in progress. When
    harness isn't running, the app starts it.
  - `harness init` runs only when the data folder has no config.ini.
  - [Continue] asks for the key before any command runs, so Cancel in the
    key's field changes nothing. The commands then run in this section's
    order: init, config set, then the key piped to secret add. A first
    setup that stopped after init leaves `state/setup-unfinished`, and the
    next start shows "Set up" again.
  - For Other the key may be left empty, for a server that takes none. Its
    section then gets `auth = none`, and nothing is stored.
  - The key is trimmed of spaces and line ends before it is stored.
  - The package's fit files come from `pack-desk-assets.sh`, strictly, in
    the release. `DESK_ASSETS=none` leaves them out, and says so, for CI.
