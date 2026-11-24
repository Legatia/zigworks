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

The mockup from this conversation is the reference for look and layout:
https://claude.ai/artifact/NnXy5J39fEoiQFwsmxavC1 (Desktop app; the female
version; the states sheet). The clips and stills made for it are in the
owner's Downloads folder (named below). This design was builder-checked
against the code, and its answers are folded in.

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

1. **The desk is harness's own page:** the app server's shell, which
   today is the frame around the apps. The other apps stay framed and
   sandboxed, reachable from it.
2. **A chat that's a harness conversation.** Typing in the desk is the
   owner's turn in `main` or a topic. Replies show in the desk and in
   Telegram.
3. **The side panel:** Needs you, Topics and Lately.
4. **The avatar:**
   - a choice of built-in male or female, or the owner's upload;
   - motion from a clip pack;
   - states from harness's own state, never from the model.
5. **Speech:** the desk can speak replies; the avatar talks only while the
   voice does.
6. **The look:** the mockup's sharp dark style, with no outside hosts.

## Non-goals

- A mobile app. The phone is Telegram; WhatsApp is a separate open
  decision (gaps list).
- The hosted version, which is set aside.
- A native GUI toolkit.
- Exact lip-sync on every word. That's a later GPU add-on (LiveTalking).
- Generating avatar clips from inside harness. The owner makes them with
  a tool they have, following the desk's guide.

## Anti-goals

- **Static moments.** The avatar is always in motion: breathing with eyes
  closed, or attentive with real blinks.
- **Looping speech.** One spoken message per reply, with talking motion
  only while the voice plays.
- **Fake blinks.** No swapping stills; blinks come only from video.
- **The model choosing the avatar's mood or the status text.** States and
  status lines come from harness's own facts.
- **Outside hosts.** Fonts, scripts, images and clips are all served by
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

## Getting in

The app server stays on 127.0.0.1, with its Host and Origin checks.

- **A fixed port.** `harness init` picks a free high port and writes
  `[apps] port`. Existing installs get one at the next start. With port 0,
  each start was a new browser origin, so the browser forgot its
  microphone and autoplay permission every time.
- **One-time code, then a cookie.**
  - When harness opens the desk, it makes a one-time code: used once, and
    valid for 60 s.
  - It opens the browser at `http://127.0.0.1:PORT/enter?code=…`. The
    page trades the code for an HttpOnly, SameSite=Strict cookie, then
    moves to `/desk`.
  - The cookie is the shell's credential from then on, so no token sits in
    a URL, in history, or in a file.
  - A code that's already used, or expired, gets "This link was used.
    Open the desk again with `harness open`."
- **Who opens it:**
  - `harness run` and `harness chat` open the desk at start when
    `[desk] open = on`, which is the default.
  - `harness open` asks the running instance to open it. The request file
    (`state/open-request`) holds no secret. The instance itself opens the
    browser with a fresh code.
- **The browser:**
  - a Chromium-family browser in app mode, `--app=URL`, without an
    address bar;
  - the lookup is extended to Edge on macOS and Linux, and Brave
    (page.zig ~1040);
  - otherwise the system's default browser (`open`, `xdg-open`, `start`).
  - When harness launches app mode it adds
    `--autoplay-policy=no-user-gesture-required` for that window only, so
    the desk can speak an urgent alert without a click first.
- **A limit, stated in the README:** a program running as you on this
  computer could race for a fresh code, or read the browser's cookie.
  That's the same as for any local app. harness's own commands run
  sandboxed when unattended, and on the host only with your approval.

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
- **Voice input:** the mic button shows only when `[voice]` is set.
  1. It records in the page (MediaRecorder; the fixed port keeps the
     permission).
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
| urgent | an urgent item or alert is open | attentive loop, no nods; red frame |
| speaking | the voice is reading a reply | talking clip while the voice plays |
| needs you | an inbox item is open | attentive loop; the glance clip once when it arrives; magenta frame |
| working | a run is in progress | attentive loop, with a nod or thinking clip every 9–16 s; cyan frame |
| quiet | quiet hours | resting loop, dimmed |
| resting | none of the above | resting loop: eyes closed, breathing |

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

### The clip pack

An avatar is a folder, `avatars/NAME/`, with `avatar.ini` naming its
files. A still may be JPEG or PNG; uploads keep their own format, and
nothing is re-encoded.

| File | What it is |
|---|---|
| `still` | the portrait, eyes open |
| `closed` | the portrait, eyes closed |
| `rest.mp4` | eyes closed, breathing; starts and ends on `closed`; loops |
| `attentive.mp4` | eyes open, breathing, real blinks; starts and ends on `still`; back to back |
| `nod.mp4`, `glance.mp4`, `smile.mp4`, `concern.mp4` | expressions starting and ending on `still` |
| `talk.mp4` | speaking motion, starting and ending on `still` |
| `wake.mp4`, `sleep.mp4` | `closed` to `still`, and back |

**Playback:**

- One clip plays at a time, over the still.
- A change happens only at a clip's end, so joins are matching frames.
- A missing clip falls back: no `wake` means a cut; no `nod` means
  attentive only.
- A pack with only a still breathes by a 0.6% scale ease over 4 s.

**Serving the pack** (the app server learns to):

- serve `mp4`, `jpeg`, `png` and `woff2` from `avatars/` to the desk,
  with HTTP byte ranges (206; Safari needs them);
- up to 20 MB a file, for this path only;
- `Cache-Control: private, max-age=86400` with an ETag. Not `no-store`
  here, so clips aren't fetched again at every switch.

**Checking a pack:**

- `harness avatar check NAME` checks the structure, std only: the files
  exist, their types by magic bytes, their sizes, and `avatar.ini`.
- The frame match is checked in the desk, where the browser decodes video
  and images. "Check pack" in the avatar settings draws each clip's first
  and last frames and its still to a canvas, at the clip's size. It
  reports the mean difference per clip, and passes under about 4 out of
  255 (the samples measured about 2).

### Built-in avatars

- **Packs ship in the release archive** under `avatars/`, not in the
  binary (about 25 MB for both). `harness init` copies them to the data
  folder.
- **The male pack's files** (made 2026-11-24):

  | Pack file | Source |
  |---|---|
  | `still` | `Neon Cyborg Officer (Clean Skin).jpg` |
  | `closed` | `Neon Cyborg Officer (Eyes Closed).jpg` |
  | `talk` | `neon_cyberpunk_headshot.mp4` |
  | `nod` | `neon_male_performer.mp4` |
  | `attentive` | `neon host portrait.mp4` |
  | `rest` | `neon_suited_man.mp4` |

  Still to make: `wake`, `sleep`, `glance`, `smile` and `concern`.
- **The female pack** has only its still (`Neon Butler Portrait
  (Female).jpg`, 1920×1088). It needs a 2K still and its clips.
- **Shipping** the generated portraits publicly is the owner's call
  before a release, and is noted in the gaps list.

### Your own avatar

The Avatar settings in the desk:

- **Choose** male, female, or one of your own. The choice is written to
  `[desk] avatar` through harness's write-then-reload path, as `/persona`
  does.
- **Upload a photo**, JPEG or PNG, up to 10 MB. The upload requires one
  ticked line:

  > This is me, someone who agreed, or a made-up character.

  The photo stays on this computer, in `avatars/NAME/`.
- **An upload works at once** as a breathing still.
- **For full motion**, the desk's guide lists the clips to make:
  - each with its prompt, its first and last frame (`still` or `closed`)
    and its length (3–4 s);
  - a rough cost (about 600–850 credits a clip on Kling 4.0 through
    mitte.ai at today's prices);
  - and where to put each file.

  Then "Check pack" shows what passes, and what each missing clip falls
  back to.

## Speech

- **Off by default:** `[desk] speak = off | browser | PROVIDER`. A
  provider is an OpenAI-format text-to-speech endpoint from `[provider
  NAME]`, with its key in the store. harness fetches the audio, and the
  key never reaches the page.
- **Section names:** `[speech]` already belongs to the Home Assistant
  agent's settings, so none of this uses it.
- **What's spoken:**
  - replies in the conversation the desk shows, up to 400 bytes (as
    speech.zig's `max_spoken`). Longer replies speak their first two
    sentences, then "The rest is on screen."
  - Urgent alerts are always spoken while the desk is open and not muted.
  - Quiet hours: urgent alerts only.
- **Talking motion:** `talk.mp4` from its start, repeated while the voice
  still plays, ending on its last frame. Then back to the state's loop.
- **A browser opened without app mode** asks for one click per session
  before it may speak ("Click to let the desk speak").
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
  visible focus. With reduced motion, the sweep and the scale breathing
  stop, and clips play only when speaking.
- **Sizes:** layout from 1024 px wide. Under 900 px the side panel goes
  below the chat.

## Constraints

- Zig 0.17.1, std only, on harness's side. The desk is HTML, CSS and
  plain JS in the binary, with no build step.
- **The app server's rules hold:** loopback only, Host and Origin checks,
  and a CSP with every load on this server. Shell paths refuse
  `Origin: null`.
- **Names:**
  - the command is `harness open`;
  - the page is the desk, at `/desk`;
  - code names must not clash with core's `desk`, `appDesk` or `wfDesk`;
  - `desk` joins `apps.reserved`.
- **Injection rules hold:** outside text is shown, never put in a prompt.
  Desk messages are the owner's words, and avatar files are the owner's.
- Copy follows CLAUDE.md.
- **Tests:**
  - the code-to-cookie entry: a code works once, an expired one is
    refused, and nothing is written to disk;
  - shell-only paths refuse a framed app;
  - a desk turn goes to the right conversation, with Telegram's echo and
    reply;
  - private history stays in memory only;
  - the long-poll;
  - urgent items;
  - the run view: label, helpers and start time;
  - the state table;
  - serving with byte ranges and caching;
  - `avatar check` on good and bad packs;
  - the smoke opens the desk over HTTP and drives one message.
- **Docs:**
  - the README: Desk; Avatar packs; Speech; the local-app limit;
  - the gaps list: pack licensing, the female clips, the GPU add-on, clip
    generation by API;
  - the ledger and the Windows handoff.

## Left to the builder

- The event shapes and API paths, and the desk's JS structure.
- The browser lookup per system.
- How the fixed port is chosen at init, and what happens when it's taken
  at start: try the next one, write it back, and say so.

## Calls I made (the owner can overrule)

- **The desk is harness's own page** in an app-mode browser window, not
  an app and not a native GUI.
- **One agent, one set of conversations.** The desk is an extra output,
  and Telegram gets a quiet echo of what you type there.
- **Entry by a one-time code and a cookie,** with no reusable token in
  files or URLs. The same-user limit is stated plainly.
- **Settings and chat on a page are allowed for the desk only.** Apps
  stay as the apps design says.
- **Private conversations' desk history stays in memory only.**
- **States and the status card come from harness's facts,** never from
  model text.
- **Built-in packs ship beside the binary.** Speech is off by default.
- **Uploads work as a still at once.** Full motion comes from a pack you
  make with the guide.
- **Upload requires the consent line.**
