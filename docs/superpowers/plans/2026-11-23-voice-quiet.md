# harness: voice notes, quiet hours and the digest (Parts 4 and 5 of the butler spec) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (Part 4) A Telegram voice or audio message of up to 2 minutes is fetched from Telegram (getFile, then the file; 20 MB at most), sent as multipart/form-data to an OpenAI-compatible `POST {url}/audio/transcriptions` of the provider `[voice] provider` names (a preset or a `[provider NAME]`: Groq, OpenAI, a local whisper.cpp server) with `[voice] model` and `language`; the transcript is shown in one quoted line, then the turn runs on it as if typed. (Part 5) `[butler] quiet = 22:00-07:00` (the owner's time; off until set): during quiet hours the posts and questions of runs nobody waits on (schedules, briefs, triggers, workflows) are held unless the trigger or workflow says `urgent = yes`, kept across restarts, and sent as one digest per conversation when quiet hours end; `/quiet`, `/quiet on|off`, `/quiet HH:MM-HH:MM`.

**Architecture:** `telegram.zig` reads `voice` and `audio` into `Message.voice` (a `voice.Note`) and gets `getFile`/`download`; `fake.zig` serves getFile, the file download (`/file/bot…`) and `…/audio/transcriptions` (scripted `transcribe/NNN.json`, requests kept in `transcribe-requests/`). A new `voice.zig` holds the note, the transcription call (multipart, the provider's auth and headers, errors in words, the key masked) and the quoted line. `core.zig` gets `Incoming.voice` and `Channel.file`; a voice note goes into the chat queue (`Queued.voice`) and the chat worker fetches, transcribes, shows and runs the turn; a voice reply to an item's message is transcribed on a thread of its own and answers the item. A new `quiet.zig` holds the hours, the held list (`state/quiet`) and the digest's text. `core.zig` holds posts in `postShaped`, `sendRunEnd` and `showItem`, releases them in `tick`, and takes `/quiet`. `agent.zig` gets the delivery status `digest`. `triggers.zig` and `workflows.zig` read `urgent = yes`. `config.zig` reads `[voice]` and `[butler]`. `main.zig` passes voice notes in and fetches files for core.

**Tech Stack:** Zig 0.17.1, std only; macOS, Linux, Windows.

**Spec:** `docs/superpowers/specs/2026-11-23-harness-butler-design.md` (UX rules, What it looks like, Parts 4, 5, 9's voice line, Tests); `harness/research/smart-home-voice.md` §5; the overview (`2026-11-22-harness-platform-overview.md`, binding) and the ledger's APIs (RunOut, Outbox, postReply, the inbox, providers).

## Global Constraints

- Work in `telegram.zig`, `fake.zig`, `model.zig`/`config.zig` (the transcription provider, `[voice]`, `[butler]`), the new `voice.zig` and `quiet.zig`, small self-contained edits in `core.zig` (Incoming/Channel/Queued fields, handleIncoming's voice branch, the worker's voice turn, postShaped/sendRunEnd/showItem holds, tick's release, `/quiet`, help), one status in `agent.zig`, `urgent` in `triggers.zig`/`workflows.zig`, `main.zig` (poll loop, TgChan.file, test imports), `smoke.sh`, README. Another builder changes the gate, who values, pairing and a `[member]` rules section at the same time; one more homemcp.
- Every new Core field is set in `Core.open` (it sets `c.* = undefined`). Secrets never in logs, model requests or output; files replaced whole go through `util.writeReplace`. Audio is never written to disk or logged.
- Existing tests change only where behaviour changes on purpose (listed under Done).
- Baseline: 798 pass, 19 skipped, smoke all ok (85 checks).
- Tests from `harness/`: `zig build test --summary all --cache-dir $SCRATCH/zc-voice > FILE 2>&1`; `-Dtest-filter=NAME` while iterating; the full suite per task; `-Doptimize=ReleaseSafe` and the cross builds (x86_64-windows, x86_64-linux-musl, aarch64-linux-musl; `zig build` and `unit-build`, `-p` into a scratch folder) at the end.

## Rulings

Voice notes:

1. **A voice note waits in the chat queue like a typed message and is transcribed when its turn comes.** What: `Queued.voice` holds the note; the chat worker fetches and transcribes it right before the turn (under a run flag of its own, so `/stop` cuts a download or transcription under way and drops queued notes like queued messages), sends the quoted transcript, then runs the turn. Why: the order of the owner's messages is kept (a typed correction sent after a voice note comes after it), `/reload` waits for it, no new thread. Cost if wrong: behind a long turn, the transcript shows only when its turn starts (the owner gets "Queued" at once, as for text).
2. **A voice note in reply to one of an item's messages is that item's text answer.** What: transcribed at once on a thread of its own (counted in `bg_active`, so `/reload` and close wait for it), the transcript shown, then answered as a typed reply is (`replyAnswer`). Why: the turn that asked blocks the chat worker; queued, the answer would come after the question expired. Cost if wrong: a second path for a rare case.
3. **A transcript is always a message, never a command.** Why: commands are typed; a misheard word must not run one. Cost if wrong: the owner types `/stop`.
4. **The transcript is one line in straight quotes, sent without a sound, whole; the turn gets a context note** ("This message is a voice note, transcribed: a word may be misheard."). Line breaks become spaces; an empty transcript says "The voice note had no words in it." and runs nothing. Why: the transcript is shown before anything is done (Part 9) and the reply carries the sound; the model may ask about a word that looks wrong. Cost if wrong: one notification more or less.
5. **Over 2 minutes (Telegram's `duration`) or over 20 MB (its `file_size`, else getFile's, else the download's) is refused in one plain line before anything is downloaded or sent.** Cost if wrong: none.
6. **`[voice]`: `provider` (a preset or a `[provider NAME]` section whose api is openai), `model` (required with a provider), `language` (optional, 2–3 lowercase letters).** config.ini refuses a provider that is not one, doesn't speak OpenAI's format, or has no model, named at start and /reload. No default model. Why: transcription exists only in OpenAI's format and model names differ per service. Cost if wrong: one line more to write.
7. **Errors in the providers' words, with "Voice notes are refused" for keys and urls and "Transcription …" for the rest, always naming the provider; the key masked as `[secret:NAME]`; no retry on 429.** Cost if wrong: a 429 a second try would have passed (the owner sends again).
8. **The audio stays in memory** (the run's arena, freed after the call). The log: a `chat` line `voice note` (conversation, seconds, bytes, provider, model, ms, chars), or `voice note not transcribed` (why); the transcript is the turn's text (private conversations: sizes and hashes, as every turn). Cost if wrong: none.
9. **Files are fetched through a Bot made for that note** (getFile, then `GET {api}/file/bot{token}/{path}`), never the send bot. Why: a download never holds up sends or presses. Cost if wrong: one more connection per note.

Quiet hours and the digest:

10. **Held: the posts of runs started by `schedule:`, `trigger:` or `workflow:`** — their sends and replies (`postShaped`), harness's own line when such a run ended early (`sendRunEnd`), and the inbox items they make (skipped calls, a workflow's approve/review and tool-step approvals, failed steps, a paused trigger, a delivery that failed for good). Not held: the owner's runs (replies, their questions), command replies, harness's own instance lines (settings changed, a task paused for its budget), memory notices. Why: "replies to the owner's own messages always go at once"; the rest is rare. Cost if wrong: a rare harness line at night.
11. **Urgency is the section's `urgent = yes`** (triggers.ini: event triggers and schedules; a workflow's head), looked up by the post's `by` in a list core refreshes at start and at each tick (under the scheduler's lock). A workflow started by an urgent trigger is urgent only when it says so; tasks.ini and briefs.ini have no `urgent`. Cost if wrong: an urgent trigger added and fired within 5 s is held (it is in the digest).
12. **The hours: `[butler] quiet = HH:MM-HH:MM`, the owner's time (`[chat] utc_offset`), start included, end not, may wrap midnight; off until set.** `/quiet on|off` is kept in `state/quiet`; `/quiet HH:MM-HH:MM` sets hours there (and on); `/quiet on` with no hours set anywhere uses 22:00–07:00. Cost if wrong: two places for the hours (`/quiet` names the hours that apply).
13. **The digest: at the first tick outside quiet hours with something held, one message per conversation:** "During quiet hours (22:00–07:00):" and a line each, oldest first: `HH:MM` and the post's first line (cut at 160 bytes, `…`). A post that doesn't fit its line (more lines, cut) or has buttons (quick replies, Undo), and each held question, follow the digest whole, as they would have been sent, without a sound; their lines end "(below)". Why: one notification and one short line each, nothing lost, and one tap still decides. Cost if wrong: a long post shows twice (its first line, then whole).
14. **A held question stays an open inbox item; its expiry moves on by the time from its hold to the end of quiet hours**, so a workflow's `timeout` counts from when the owner sees it; `/inbox` lists it meanwhile, and one shown with Show is not shown again after the digest. Cost if wrong: a workflow waits longer than its timeout.
15. **A post with files is not held: it goes at once without a sound.** Why: files are not copied into state. Cost if wrong: a silent message at night.
16. **`state/quiet`**: `{"v":1,"switch":null|"on"|"off","hours":null|"HH:MM-HH:MM","next":N,"held":[{id,at,conv,by,agent,rid,text,buttons,undo,item,listed,private}]}`, written whole, owner-only, texts masked. A post is written before its run is told it is held; a digest's lines are marked `listed` (written) before what follows it is sent; each follower leaves the list once sent, or becomes a delivery item when it can't be. A digest that fails is tried again a minute later. Cost if wrong: a crash between a follower's send and its removal sends it twice.
17. **A held post's delivery status is `digest`** (agent.Delivery.Status): the send line's event; the model is told "held for the digest at 07:00 (quiet hours)", not an error; a brief's links count as seen, a page trigger's value moves on, a workflow's `say` goes on, a task logs `done` with why. Cost if wrong: none.
18. **Log lines:** the send line (event `digest`); `chat` `held` (id, conversation, by, item) for every hold; `chat` `digest` (conversation, lines, message) per digest; `chat` `released` (id, item or message) per follower; `config` `quiet` for `/quiet`. No texts in them.

Made while building:

19. **What the owner asked for now is never held:** `/brief` (its job's key `brief-now:`), `/trigger run` (a by-hand poll), and one-off commands run by hand (`harness task run`, `brief`, `trigger run`, `workflow start`: the core's role). Why: "replies to the owner's own messages always go at once", and the terminal prints them now. Cost if wrong: a by-hand run at night wakes the owner, who asked for it.
20. **A workflow's head takes `urgent yes`** (its lines are `KEY VALUE`) and also `urgent = yes`, as triggers.ini writes it. Cost if wrong: none.
21. **A held post that can't be written to `state/quiet` goes at once** (logged `not held`): better a sound at night than a lost post. Cost if wrong: a rare sound at night.
22. **A task's reply outcome keeps its own copy of `why`** (`Sched.why_buf`): a final `send` is posted in its turn's arena, freed before the task reads how it went (a use-after-free the digest's `why` showed in a full run; the hourly limit's `why` had it before). Cost if wrong: none.
23. **The voice service's key shows in `harness secret list`, and a missing one is said at start** (`note: no groq key stored …; voice notes will be refused`), as a model provider's is. Cost if wrong: none.

## Files

- Create `harness/src/voice.zig`, `harness/src/quiet.zig`.
- Modify `harness/src/telegram.zig`, `fake.zig`, `config.zig`, `core.zig`, `agent.zig` (one status), `triggers.zig`, `workflows.zig`, `main.zig`, `harness/scripts/smoke.sh`, `harness/README.md`.

---

### Task 1: Telegram voice notes and files; the stand-in

**Produces:** `voice.Note{kind, file_id, seconds, size, mime, name}`; `telegram.Message.voice: ?voice.Note`; `Bot.getFile(arena, file_id) !File{path, size}`, `Bot.download(arena, path, max) ![]u8` (error.TooLarge past `max`). fake.zig: `getFile` answers `telegram/files/ID` as `voice/ID.oga` (400 when missing), `GET /file/bot<token>/<path>` the file (recorded as `{"method":"download",…}` in out.jsonl), `POST …/audio/transcriptions` answers `transcribe/NNN.json` (`{"text":…}`, `{"status":N}`, `delay_ms`), each request kept in `transcribe-requests/NNN.json` with its headers and body.

- [x] **Step 1: failing tests** (telegram.zig): `a_voice_note_and_an_audio_file_are_read` (voice: file_id, duration, file_size, mime; audio: file_name, mime; a text message has none); `a_voice_file_is_fetched_by_its_path` (getFile then download: the bytes; a missing id: TelegramRefused; over `max`: TooLarge; the token is in no recorded line but the request path).
- [x] **Step 2:** run: compile errors.
- [x] **Step 3:** implement.
- [x] **Step 4:** whole suite.
- [x] **Step 5:** commit.

### Task 2: The transcription call and `[voice]`

**Produces:** `voice.Transcriber{gpa, io, provider: model.Provider, model, language}`, `transcribe(arena, audio, name, stop) Error![]const u8`, `failure(arena, e) []const u8`, `fileName(note)`, `quoted(arena, text)`, `max_seconds`, `max_bytes`. `config.Config.voice{provider, model, language}`; `parse` refuses a voice provider that is unknown, not api openai, or without a model (`error.BadVoice`, `reason`).

- [x] **Step 1: failing tests:** voice.zig `a_note_goes_as_multipart_with_model_and_language` (the fake gets `file` named `voice.ogg` with the bytes, `model`, `language`, `response_format=json`, Bearer key; the text back); `each_status_is_said_in_the_providers_words` (401 echoing the key: masked, names the secret; 402, 429 once, 400, 500; no key: NoKey without a request; auth none sends no header); `a_note_name_follows_its_kind_and_mime`; `the_quoted_line_is_one_line`. config.zig `voice_settings_read_and_checked`.
- [x] **Step 2–5:** as above; commit.

### Task 3: Voice notes in core and main

**Produces:** `core.Incoming.voice`, `core.Channel.file`, `Queued.voice`; `handleIncoming` → `voiceIn`; the worker's `voiceTurn`; `voiceAnswer` thread; main's poll loop and `TgChan.file`.

- [x] **Step 1: failing tests** (core.zig, Recorder gets `file`): `a_voice_note_is_shown_quoted_then_answered` (the quiet quoted line, then the reply; the model got the transcript and the context note; the log has `voice note` with seconds and bytes, no audio, and the turn's text; the transcription request had the key, the log hasn't); `a_voice_note_over_two_minutes_or_without_voice_set_is_refused_plainly` (no download, no request); `a_failed_transcription_is_said_and_runs_nothing` (401: the provider's words); `a_voice_reply_to_a_question_answers_it` (a turn asks ask_owner; the owner's voice reply to its message answers it while the turn waits); `a_voice_note_and_a_message_typed_after_it_keep_their_order`; `a_private_conversations_voice_note_logs_no_words`. main.zig: `a_voice_note_from_telegram_is_transcribed_end_to_end` (TgChan against the fake: getFile, download, transcription, the quoted line and the reply in out.jsonl).
- [x] **Step 2–5:** as above; commit.

### Task 4: Quiet hours: hours, the held list, urgent

**Produces:** quiet.zig: `Hours{start,end}`, `parseHours`, `Hours.inside(minute)`, `endAfter(hours, now_s, utc_offset)`, `Store` (load/save `state/quiet`, `hold`, `listed`, `remove`, `switch`, `hours`, `urgent` list), `digestText`. config: `[butler] quiet`. triggers.zig: `Trigger.urgent`; workflows.zig: `Workflow.urgent`.

- [x] **Step 1: failing tests:** quiet.zig `hours_read_and_wrap_midnight`, `the_held_list_survives_a_restart`, `the_digest_has_a_line_each_oldest_first`; config `butler_quiet_reads_hours_or_off`; triggers `urgent_is_read_for_triggers_and_schedules`; workflows `urgent_is_read_in_the_head`.
- [x] **Step 2–5:** as above; commit.

### Task 5: Holding and the digest in core

**Produces:** `Delivery.Status.digest`; holds in `postShaped`, `sendRunEnd`, `showItem`; `quietDue` in `tick`; `/quiet`; help line.

- [x] **Step 1: failing tests** (core.zig, a fixed clock): `a_non_urgent_post_in_quiet_hours_waits_for_the_digest` (a task's reply at 03:00: nothing sent; `/quiet` lists it; 07:00 tick: one digest line; log held and digest); `an_urgent_trigger_goes_at_once_in_quiet_hours`; `a_reply_to_the_owner_goes_at_once_in_quiet_hours`; `held_posts_survive_a_restart`; `a_long_post_or_one_with_buttons_follows_the_digest_whole`; `a_held_question_waits_and_follows_the_digest_with_its_buttons` (workflow approve step: no message at night, expiry moved; after: digest line then the item, a press answers it); `quiet_off_sends_what_is_held_and_quiet_on_holds_again`; `a_brief_held_for_the_digest_counts_its_links_as_seen`.
- [x] **Step 2–5:** as above; commit.

### Task 6: README, smoke, final checks

- [x] README: Voice notes (setup for Groq, OpenAI, whisper.cpp; cost an hour; Polish), Quiet hours and the digest, `urgent`, `/quiet`, `state/quiet`, the State line.
- [x] smoke.sh: a voice note end to end against harness-fake (the quoted line, the reply, the audio in no log); `/quiet` says off.
- [x] Debug and ReleaseSafe suites, cross builds; commit.

## Done

Branch `platform/voice-quiet` (on f193599): 7e0472f plan, 4f8d45d Telegram voice notes and the transcription call, b014214 `[voice]` and `[butler]`, 3a64e34 voice notes in core and main, 05e6ee6 quiet.zig and `urgent`, 8264643 holding and the digest in core, then README and smoke.

- Debug and ReleaseSafe: 830/849 (19 skipped: Windows or Linux only), smoke all ok (88 checks; baseline 798/817 and 85). Cross builds (`zig build`, `unit-build`) for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl compile.
- New tests (32): telegram 3 (voice and audio read, a file fetched by its path, a quiet document), voice 4, config 2, quiet 4, triggers 1, workflows 1, core 15 (6 voice notes, 9 quiet hours), main 2 (a voice note end to end through TgChan, the voice service's start note); smoke 3.
- Tests changed on purpose: none. Test helpers grew: core's Recorder fetches a voice note's file (`audio`, `fetched`, `file_fail`) and finds a line's place (`indexOf`).
- core.zig edits: `Incoming.voice`, `Channel.file`, `Queued.voice`; handleIncoming's voice branch (one line); `queueTo` → `queueItem`; the worker's voice turn (one line); the voice and quiet sections (new functions); `Core.quiet` (open, close); `noteUrgent` at /reload, a change at once and tick; `quietDue` in tick; `RunOut.asked`; `Sched` (`digest`, `why_buf`) and `postOut`; `postShaped`'s hold and hush; `sendFile`'s and `sendWithButtons`' quiet; `sendRunEnd`'s hold; `showItem` → hold, then `showItemHow`; briefs, `triggerDo`/`triggerSay` and `sayStep` with `digest`; `/quiet` and its help line.
- A full run found a use-after-free (Ruling 22): the digest's `why` of a task's final `send` was read after its turn's arena was freed; fixed, the test now checks the task's logged why.
- Left out: spoken replies; the day's informational posts gathered into the morning digest; harness's own lines, memory notices and a workflow's "Failed at step" line held at night; files kept for the digest (they go at once, quietly); voice notes in a group or from members (Part 6); `/status` lines for voice and quiet; `/quiet` going back to config.ini's hours (set them again); a real transcription service, Telegram bot and Polish accuracy checked by hand.
