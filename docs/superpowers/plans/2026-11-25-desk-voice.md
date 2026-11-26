# harness: the desk's voice, any speaking provider — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `[desk] speak = off | browser | NAME`, where NAME is any provider that can speak: the presets `openai` and `gemini` (a stored key alone) or a `[provider NAME]` with `api = openai` or the new `api = gemini`. Gemini's `generateContent` audio is served to the page as WAV. Model and voice default per kind and are set in the desk. Gemini's free-tier data use is said inline.

**Architecture:** `model.zig` learns `Api.gemini` (speech only: a chat client refuses it), `Auth.x_goog_api_key` and a `gemini` preset. `config.zig` names the speaking providers once (`speakApi`, `speakers`), refuses a chat model on a Gemini-format provider, and leaves `speak_model`/`speak_voice` unset by default. `voice.zig`'s `Speaker` speaks both formats and returns bytes with their content type; it builds the WAV header. `core.zig`'s desk settings take model and voice and clear them when the kind changes. The page shows Model and Voice for a provider and the free-tier line for Gemini. `fake.zig` answers `…:generateContent`.

**Tech Stack:** Zig 0.17.1, std only; the desk page is plain JS/HTML/CSS in the binary.

**Spec:** `docs/superpowers/specs/2026-11-24-harness-desktop-app-design.md`, section "Speech" (as of dad9cea, binding).

## Global Constraints

- Zig 0.17.1, std only. Copy follows CLAUDE.md: plain labels ("Model", "Voice", "Off", "Browser", the provider's name); explanations behind the small "i"; the free-tier line inline, word for word: "On Gemini's free tier, Google may use the spoken text to improve its products. A key on a paid plan keeps it out."
- `[speech]` belongs to the Home Assistant agent: nothing here uses it.
- harness fetches the audio; no key reaches the page, and none is typed into it. Providers and keys stay in config.ini and `harness secret add`.
- Defaults (checked 2026-11-25): openai `tts-1`, `alloy`; gemini `gemini-3.8-flash-lite-tts`, voice `Schedar`. Gemini preset url `https://generativelanguage.googleapis.com/v1beta`, key in `x-goog-api-key`.
- Request: `POST {url}/models/MODEL:generateContent`, body `{"contents":[{"parts":[{"text":TEXT}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":VOICE}}}}}`.
- Never a real key, never Google's or OpenAI's real API: the stand-in only.
- Baseline (dad9cea): measured at the start (Done). From `harness/`: `.superpowers/suite.sh TAG [Debug|ReleaseSafe]` (stand-ins built into `.superpowers/bin`, `--cache-dir .superpowers/cache`); `-Dtest-filter=NAME` while iterating; cross builds `zig build` and `zig build unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl.

## Checked against Google's docs (2026-11-25)

- `aistudio.google.com/docs/speech-generation` (generateContent tab): the single-speaker example now sends `speechConfig.voiceConfig.voice`; the API reference and the multi-speaker example still use `voiceConfig.prebuiltVoiceConfig.voiceName`. **Kept as the spec says** (Ruling 1).
- The Gemini 3.8 TTS models answer a unary request with **WAV** (`audio/wav`, a RIFF header, 24 kHz mono 16-bit) by default; `gemini-3.1-flash-tts-preview` and earlier answered raw `audio/L16` PCM. **Changed from the spec:** a WAV part is passed through as it is, an L16/PCM part is wrapped (Ruling 2).
- Prebuilt voices are the 30 listed there (Zephyr … Sulafat).
- OpenAI's docs mark `tts-1`, `tts-1-hd` and `gpt-4o-mini-tts` deprecated, to shut down on 2027-01-06. The spec's defaults are kept; the README says so.

## Review Focus

1. **An install whose config.ini still has the old init's `speak_model = tts-1` and `speak_voice = alloy`**, switched to gemini in the desk: Gemini must not get `tts-1`. Choosing a provider of another kind clears both lines (`choosing_another_kind_clears_model_and_voice`, Task 4).
2. **A Gemini answer that is already WAV** (3.8's default) next to one that is L16 (older models, proxies): both play; a WAV is never wrapped twice (`gemini_wav_passes_through_and_pcm_is_wrapped`, Task 2).
3. **A Gemini answer with no audio** (`finishReason` OTHER or SAFETY, `promptFeedback.blockReason`, an empty part list, base64 that doesn't decode): one plain line naming the reason, no crash (`gemini_without_audio_says_why`, Task 2).
4. **Google or a gateway saying the key back in an error**: masked as `[secret:NAME]` in what the desk shows and logs (`gemini_errors_are_said_in_the_providers_words`, Task 2).
5. **A model or voice typed in the desk with a space, `;`, `#`, `[`, `=` or a line break**: refused before config.ini is written, which is left unchanged (`desk_model_and_voice_are_checked_then_written`, Task 4).

---

### Task 1: `api = gemini`, its key header, the preset, and chat refused

**Files:** `harness/src/model.zig`, `harness/src/config.zig`, `harness/src/hermes_import.zig`, `harness/src/main.zig` (secret list), tests in each.

**Interfaces — produces:**
- `model.Api.gemini`; `model.parseApi("gemini")`.
- `model.Auth.x_goog_api_key`; `model.parseAuth("x-goog-api-key")`.
- `model.keyHeader(auth: Auth) ?[]const u8` → `"x-api-key"`, `"x-goog-api-key"` or null (bearer and none). Client.post and voice.zig send the key through it.
- `model.defaultAuth(api: Api) Auth` → anthropic `x_api_key`, openai `bearer`, gemini `x_goog_api_key` (a new section's default).
- Preset `gemini`: api gemini, url `https://generativelanguage.googleapis.com/v1beta`, auth `x_goog_api_key`, cache false, key `gemini`.
- `model.chatPreset(name) bool`: a preset whose api isn't gemini.
- `model.Error.SpeechOnly`: `Client.sendSystem` returns it for `.gemini` before anything else; `Client.failure` says: "Model calls are refused: NAME has api = gemini, which harness uses for speech only for now; use a provider with api = anthropic or openai for this model."
- `Provider.apiName()` for gemini: "Gemini, speech only".
- `config.ParseError.SpeechOnlyModel`, reason: "api = gemini is for speech only for now ([desk] speak); a model needs a provider with api = anthropic or openai". Raised when `[model] provider`, or the provider any of `[model] model`, `worker_model`, `memory_model`, `[memory] summary_model`, `[triggers] check_model`, `[voice_agent] model` picks, has api gemini.
- `config.providerApi(cfg, name) ?model.Api` (today's `voiceApi`, renamed and public).
- `parseHeader` also refuses `x-goog-api-key`. BadProvider and ProviderNeedsApiAndUrl reasons name gemini and `x-goog-api-key`.

- [ ] **Step 1: failing tests.** model `gemini_is_a_preset_for_speech_only` (resolve with no sections: `find("gemini")` has the url, `.x_goog_api_key`, key name `gemini`; a section `[provider tts]` api gemini gets `.x_goog_api_key` and key name `tts`; `Client.open` on it then `send` → `error.SpeechOnly`, and the stand-in got no request; `failure` is the line above with NAME `tts`), model `key_headers_follow_auth` (`keyHeader` for each value). config `providers_take_api_gemini_and_its_key_header` (`api = gemini`, `auth = x-goog-api-key` read; `header = x-goog-api-key: k` → BadHeader), `a_chat_model_on_gemini_is_refused` (each of the six fields set to `gemini:x`, and `[model] provider = gemini`, and a section `[provider g]` api gemini with `model = g:x` → `error.SpeechOnlyModel`; `parseProblem` names the line and the reason), hermes `a_hermes_model_on_gemini_is_left_to_set_by_hand` (Hermes's `model.provider: gemini` writes no `[model]` change and says so).
- [ ] **Step 2:** run them (`-Dtest-filter=`): they fail to compile or fail.
- [ ] **Step 3: implement** as the interfaces say. `secret list` also lists the key of `[desk] speak`'s provider (as `[voice] provider`'s today). hermes_import uses `chatPreset` where it used `isPreset`.
- [ ] **Step 4:** the filtered tests pass; then the whole suite (`suite.sh t1`): only the reason-text tests that name the api list change, on purpose.
- [ ] **Step 5: commit** "harness: api = gemini (speech only), x-goog-api-key, the gemini preset".

### Task 2: The Speaker speaks Gemini's format; WAV for the page; the stand-in answers it

**Files:** `harness/src/voice.zig`, `harness/src/fake.zig` (route, doc comment, `gemini/` scripts and `gemini-requests/`), tests in voice.zig.

**Interfaces — consumes:** Task 1's `Api.gemini`, `keyHeader`. **Produces:**
- `voice.Audio = struct { bytes: []const u8, content_type: []const u8 }`; `Speaker.speak(sp, a, text, stop) Error!Audio` (openai: as today, `"audio/mpeg"`; gemini: `"audio/wav"`).
- `voice.Error.NoAudio`; `Speaker.failure` for it: "Speech failed at NAME: its answer had no audio." or "… had no audio (REASON)." with REASON `finishReason X` / `blockReason X` when the answer says one.
- `voice.SpeakDefaults = struct { model: []const u8, voice: []const u8 }`; `voice.speakDefaults(api: model.Api) ?SpeakDefaults` (openai `tts-1`/`alloy`, gemini `gemini-3.8-flash-lite-tts`/`Schedar`, anthropic null).
- `voice.wav(a, pcm: []const u8, rate: u32) ![]u8`: 44-byte RIFF header, PCM 1, mono, 16-bit, byte rate `rate*2`, block align 2; an odd last byte dropped.
- `voice.pcmRate(mime: []const u8) u32`: the `rate=` parameter, case-insensitive; missing or outside 8000–96000: 24000.
- Gemini path: `/models/` + the model percent-encoded (bytes outside `A-Za-z0-9-._~`) + `:generateContent`; `accept: application/json`; the key by `keyHeader(auth)` or bearer; the section's headers; `resend = false`; the answer read up to 16 MB. Statuses mapped as the openai kind's today (one shared function). Audio: every `candidates[0].content.parts[*].inlineData`; a part whose mimeType is `audio/wav`, `audio/x-wav`, `audio/wave` or whose bytes start `RIFF…WAVE` is served as it is (the first such part); `audio/L16…` or `audio/pcm…` parts are joined and wrapped with the first one's rate; nothing playable → NoAudio.
- Stand-in: `POST …:generateContent` records `gemini-requests/NNN.json` (target, headers, body) and answers `gemini/NNN.json` when there is one: `{"status":N[,"echo_key":true]}` → Google's error shape `{"error":{"code":N,"message":MSG,"status":"SCRIPTED"}}`; `{"answer":{…}}` → that JSON; `{"mime":"audio/wav"}` → the audio as a WAV part. Else: one part, `audio/L16;codec=pcm;rate=24000`, the PCM being the request's text bytes (padded to even). The key is read from `x-goog-api-key` too.

- [ ] **Step 1: failing tests** in voice.zig: `gemini_speech_posts_generate_content_and_wraps_pcm_as_wav` (path `/v1beta/models/gemini-3.8-flash-lite-tts:generateContent`; `x-goog-api-key: gm-test-key-1`, no Authorization; body equals the spec's JSON for text "Three flats match." and voice `Schedar`; the answer is `audio/wav`, 44 + 18 bytes, its data the text's bytes, rate 24000 at offset 24), `gemini_wav_passes_through_and_pcm_is_wrapped` (script `{"mime":"audio/wav"}`: the bytes as the stand-in sent them, one RIFF; an answer of two L16 parts at `rate=16000`: joined, rate 16000), `gemini_without_audio_says_why` (`{"answer":{"candidates":[{"finishReason":"OTHER"}]}}` → NoAudio, "Speech failed at gemini: its answer had no audio (finishReason OTHER)."; `promptFeedback.blockReason` SAFETY; a text-only part; data `!!!`), `gemini_errors_are_said_in_the_providers_words` (401 with echo_key → KeyRefused, the key masked in `lastError`; 429 → RateLimited; 400 → Rejected with "scripted error" in the line; 500 → Upstream; no key → NoKey before sending), `gemini_takes_auth_and_headers_as_its_section_says` (`auth = bearer` → `Authorization: Bearer …`, no `x-goog-api-key`; `auth = none` → neither; a `header =` line sent), `wav_header_is_mono_16_bit` (the 44 bytes for 4 bytes of PCM at 24000, exactly), `pcm_rate_reads_the_mime_type` (`audio/L16;codec=pcm;rate=16000` 16000, `audio/l16; RATE=8000` 8000, `audio/L16` 24000, `rate=5` 24000), `a_model_name_is_one_path_segment` (`a b/c` → `/models/a%20b%2Fc:generateContent`). `speaker_posts_json_and_returns_audio` changes on purpose: it reads `.bytes` and checks `content_type == "audio/mpeg"`.
- [ ] **Step 2:** run them: fail.
- [ ] **Step 3: implement** in voice.zig and fake.zig as above.
- [ ] **Step 4:** voice tests pass; core still compiles (deskSpeech takes `.bytes`, `.content_type`).
- [ ] **Step 5: commit** "harness voice: Gemini's generateContent speech, served as WAV; the stand-in answers it".

### Task 3: `[desk] speak` names any speaking provider; defaults per kind

**Files:** `harness/src/config.zig` (Desk, parse, reason, defaults_ini, tests), `harness/src/core.zig` (`deskSpeakers`, `deskSpeech`, the desk speech test).

**Interfaces — consumes:** Task 1's `providerApi`, Task 2's `Audio`, `speakDefaults`. **Produces:**
- `config.Config.Desk.speak_model = ""`, `.speak_voice = ""` ("": the kind's default).
- `config.speakApi(cfg, name) ?model.Api`: `openai` or `gemini` (their section's api if it sets one, else the preset's), or a `[provider NAME]` whose own `api` line says openai or gemini; anything else null.
- `config.speakers(a, cfg) ![]const []const u8`: `openai`, `gemini`, then those sections in file order.
- `[desk] speak` other than off/browser must have a `speakApi`, else BadDesk: "[desk] avatar = a folder name in avatars/ (a-z, 0-9, -); speak = off, browser, openai, gemini, or a [provider NAME] with api = openai or gemini; speak_model and speak_voice are that provider's (unset: its default)".
- defaults_ini `[desk]`: `speak = off ; replies read aloud: off, browser, openai, gemini, or a [provider NAME] with api = openai or gemini`, then commented `; speak_model = ` and `; speak_voice = ` lines naming each kind's default.
- `deskSpeech`: the provider's api from the resolved provider; model and voice from `[desk]` or `speakDefaults`; answers `audio.content_type`.

- [ ] **Step 1: failing tests.** config `desk_section_reads_and_checks` changes on purpose (defaults `""`; `speak = gemini` and a section `api = gemini` read; `speak = openrouter` and `speak = anthropic` → BadDesk); new `speakers_are_the_two_presets_and_speaking_sections` (order; a `[provider openrouter]` with `api = openai` is one, without it not). core `desk_speech_reads_aloud_through_gemini_as_wav` (section `[provider gem]` `api = gemini`, `url = STAND-IN/v1beta`, key `gem`; `speak = gem`; the answer `audio/wav` starting `RIFF`; the request has `gemini-3.8-flash-lite-tts`, `Schedar` and `x-goog-api-key`; the key not in the answer), `desk_speech_uses_each_kinds_defaults_and_the_desks_choice` (openai kind with nothing set: `tts-1`, `alloy`; with `speak_voice = onyx`: onyx).
- [ ] **Step 2:** run: fail.
- [ ] **Step 3: implement.**
- [ ] **Step 4:** pass; `suite.sh t3`.
- [ ] **Step 5: commit** "harness desk: speak names any speaking provider; model and voice default per kind".

### Task 4: The desk's settings take Model and Voice

**Files:** `harness/src/core.zig` (`deskSettings`, `deskSettingsJson`, tests), `harness/src/mail.zig` (`unsetKey`, test).

**Interfaces — consumes:** Task 3's `speakers`, `speakApi`; `speakDefaults`. **Produces:**
- `mail.unsetKey(a, text, section, key) ![]const u8`: the text without that section's `key = …` lines (comments and other sections kept).
- `POST settings {"speak_model":M}` / `{"speak_voice":V}`: M or V of 1–100 bytes of `A-Za-z0-9._-:/@+` is written; `""` removes the line (the default again); anything else → 400 "Model and voice use letters, digits and . _ - : / @ +, up to 100." and config.ini untouched.
- `POST settings {"speak":NAME}` to a provider whose kind isn't the kind of the provider chosen before (off and browser have none) also removes `speak_model` and `speak_voice`.
- Settings JSON adds `"speak_model"`, `"speak_voice"` (as written, "" for unset) and `"speakers":[{"name","api","model","voice","key"}]` (`model`/`voice` the kind's defaults; `key` true when stored or not needed).

- [ ] **Step 1: failing tests.** mail `unset_key_removes_only_that_key`. core `desk_model_and_voice_are_checked_then_written` (written and read back; `""` removes the line; `"a b"`, `"x;y"`, `"x\ny"`, `"[desk]"`, `"a=b"`, 101 bytes → 400, file unchanged), `choosing_another_kind_clears_model_and_voice` (config with `speak = openai`, `speak_model = tts-1`, `speak_voice = alloy`; `{"speak":"gemini"}` → both lines gone; a `[provider tts]` api openai, `speak_voice = onyx`, `{"speak":"openai"}` from `tts` → kept; `off` then `openai` → cleared), `desk_settings_list_every_speaker_with_its_defaults` (the JSON's speakers: openai `tts-1`/`alloy`, gemini `gemini-3.8-flash-lite-tts`/`Schedar`, key flags). `desk_settings_write_and_reload` holds.
- [ ] **Step 2:** run: fail.
- [ ] **Step 3: implement.**
- [ ] **Step 4:** pass.
- [ ] **Step 5: commit** "harness desk: Model and Voice in the settings; another kind clears them".

### Task 5: The page

**Files:** `harness/src/desk/index.html`, `harness/src/desk/desk.js`, `harness/src/desk/desk.css`, `harness/src/appserver.zig` (the page test).

- Speak replies: options "Off", "Browser", then each provider's name. For a provider: a row with visible labels **Model** and **Voice** (ids `speakModel`, `speakVoice`), placeholders the kind's defaults, values as written, each written on change through `setSetting` (write-then-reload). `speakWhere` keeps "Replies are sent to NAME to be read aloud."; with no key stored it says "No NAME key is stored (harness secret add KEY)." instead. For a Gemini-kind choice `speakFree` shows the free-tier line, inline.
- The "i" adds: Model and Voice are the chosen provider's, empty uses its default; providers and keys are added in config.ini and with harness secret add (README: Speech).
- A reply that couldn't be read aloud says why under the chat (`composeNote`): "Not read aloud: LINE".
- [ ] **Step 1: failing test.** appserver `the_desk_page_keeps_to_its_own_facts_and_says_where_speech_goes` gains: index.html has `id="speakModel"`, `id="speakVoice"`, `id="speakFree"` outside any `.bubble`, and the free-tier line word for word; desk.js has `"Not read aloud: "`.
- [ ] **Step 2:** fail. **Step 3:** implement; `node --check` on desk.js. **Step 4:** pass.
- [ ] **Step 5: checked by eye** in headless Chrome against a throwaway harness and the stand-in (`tools/headless.mjs`): the settings with gemini chosen (fields, placeholders, the inline line), with openai, with Off; a WAV made by `voice.wav` decoded by `decodeAudioData` (the avatar's path).
- [ ] **Step 6: commit** "harness desk page: Model and Voice, the Gemini free-tier line".

### Task 6: README, smoke, ledger

**Files:** `harness/README.md` (Models and providers: the gemini preset row; Desk's ini block; Speech), `harness/scripts/smoke.sh`, `harness/src/fake.zig` (`deskClient` asks for the reply's speech), `docs/superpowers/plans/2026-11-22-platform-build-ledger.md`, this plan's Done.

- README Speech: off/browser/NAME; both presets; a `[provider NAME]` for each kind; a gateway (LiteLLM with `api = openai`); the defaults and the date they were checked (2026-11-25), OpenAI's 2027-01-06 shutdown; the free-tier line; that Gemini's audio reaches the page as WAV (3.8 sends WAV, older models raw PCM that harness wraps); Model and Voice in the desk; another kind clears them.
- Smoke (desk block): `harness secret add gemini` with a stand-in value; `[provider gemini] url = $URL/v1beta`; `[desk] speak = gemini`. Checks: "the desk's reply is read aloud through Gemini's format, as WAV" (`speech 200 audio/wav RIFF`), "the key went as x-goog-api-key, never to the page", "harness secret list names the desk's voice key".
- [ ] Smoke red, then green. Full runs Debug and ReleaseSafe with the stand-ins; cross builds and unit-builds; Done; ledger; commit.
- [ ] Final review by a fresh reviewer over the branch; fixes test-first; merge origin/harness-logins; suites again.

## Rulings

- Ruling 1: the voice goes as `voiceConfig.prebuiltVoiceConfig.voiceName`, as the spec says, though Google's single-speaker example now shows `voiceConfig.voice`. The API reference and the multi-speaker example still use `prebuiltVoiceConfig`, older TTS models and Gemini-format proxies know only it, and sending both could trip a one-of check — cost if wrong: if 3.8 stops reading it, every Gemini call is a 400 whose message the desk shows; the fix is one line in voice.zig.
- Ruling 2: a WAV part (Gemini 3.8's default) is served as it is; only L16/PCM parts are wrapped. The spec assumed raw PCM, which 3.8 no longer sends by default; nothing asks for a format (`responseFormat` would trip older models) — cost if wrong: an answer in another format (μ-law, A-law) says "no audio" instead of playing.
- Ruling 3: Gemini's default voice is `Schedar` ("Even"): a male voice, steady and unhurried, for the built-in butler; Algieba ("Smooth") and Sadaltager ("Knowledgeable") were the others considered — cost if wrong: one string; the owner types another in Voice.
- Ruling 4: `speak` names `openai`, `gemini`, or a `[provider NAME]` whose own `api` line says openai or gemini. A chat preset with no section (`openrouter`, `opencode`), which config.ini took yesterday but the desk never offered, is refused: they have no speech endpoint — cost if wrong: an install with `speak = openrouter` (none known; the desk shipped yesterday) gets a config error naming the line.
- Ruling 5: choosing a provider of another kind than the one chosen before (off and browser count as none) clears `speak_model` and `speak_voice`, so an old init's `tts-1` never reaches Gemini; between two providers of one kind they're kept — cost if wrong: turning speech off and on again loses a typed model or voice, which the owner types again.
- Ruling 6 (overturned in the final review): ~~the free-tier line shows whenever a Gemini-kind provider is the chosen one~~. It shows whenever a Gemini-format voice is offered, so it's read before the pick: a reply in flight or an urgent alert could reach Google right after it — cost if wrong: one line always on screen in Speak replies.
- Ruling 7: Gemini's header is a new `auth = x-goog-api-key`, the default for `api = gemini`; `header = x-goog-api-key: …` is refused like the other key headers (keys are stored secrets) — cost if wrong: one more auth word to know.
- Ruling 8: a chat model on a Gemini-format provider is refused in config.ini for the fields it holds (`[model]`'s three, `summary_model`, `check_model`, `[voice_agent] model`) and at the call for the rest (agent definitions, workflow steps) — cost if wrong: a definition naming one finds out at its first turn, from a plain line.
- Ruling 9: OpenAI's defaults stay `tts-1`/`alloy` as the spec binds, though OpenAI shuts the Speech API's models down on 2027-01-06; the README says so — cost if wrong: in six weeks the openai preset's speech stops until a later change.
- Ruling 10: Model and Voice typed in the desk are 1–100 bytes of `A-Za-z0-9._-:/@+`; config.ini by hand takes any value, as every key — cost if wrong: a voice id with another character must be written by hand.
- Ruling 11: the two presets are always offered, as `openai` was; with no key stored the inline line names the command instead of saying where replies go — cost if wrong: a choice that can't work yet is in the list.
- Ruling 12: a reply that couldn't be read aloud now says why under the chat ("Not read aloud: …"); until now it failed silently — cost if wrong: one more line the owner sees when speech fails.
- Ruling 13 (Task 2): a part is WAV when its bytes start RIFF…WAVE, whatever its mimeType says; one labelled audio/wav without that header isn't played — cost if wrong: a mislabelled raw-PCM part says "no audio".
- Ruling 14 (Task 5): the state's voices carry `secret` (the key's secret name), so the missing-key line names the right command for a section with `key = OTHER` — cost if wrong: none.
- Ruling 15 (final review): an older init's `speak_model = tts-1` and `speak_voice = alloy` count as unset for a Gemini-format voice (config.parse), so a hand edit to `speak = gemini` works — cost if wrong: a Gemini-format proxy with a model named tts-1 or a voice named alloy can't be given them.

## Done

- Commits: the plan (6153f79); api = gemini, x-goog-api-key, the preset, chat refused (ab7cf34); the Speaker's Gemini format and WAV, the stand-in (3ff92d6); speak names any voice, defaults per kind (2a85881); Model and Voice in the settings (52665df); the page (570475b); README, smoke (0f304e8); review fixes (7cc2052).
- Base (6153f79 = dad9cea + the plan), Debug with the four stand-ins: unit 1536/1558 (22 skipped); smoke all ok, 197.
- Head (7cc2052; the merge of origin/harness-logins was "Already up to date"), Debug and ReleaseSafe with the four stand-ins: unit 1560/1582 (22 skipped); smoke all ok, 200 (the 3 new among them). Cross builds and unit-builds for x86_64-windows, x86_64-linux-musl and aarch64-linux-musl ok.
- origin/harness-logins had nothing past dad9cea at the end (fetched): the merge was "Already up to date".
- Tests changed on purpose: config `desk_section_reads_and_checks` (speak_model/speak_voice default ""; speak = gemini and api = gemini sections read; speak = openrouter refused); voice `speaker_posts_json_and_returns_audio` (reads `.bytes`, checks `audio/mpeg`); model `provider_presets_resolve_and_old_settings_still_reach_omnigate` (the gemini preset row). No other existing test changed.
- New tests: model `gemini_is_a_preset_for_speech_only`, `key_headers_follow_auth`; config `providers_take_api_gemini_and_its_key_header`, `a_chat_model_on_gemini_is_refused`, `speakers_are_the_two_presets_and_speaking_sections`, `an_old_inits_openai_lines_never_reach_gemini`, `a_preset_made_to_speak_another_format_is_no_voice`; hermes `a_hermes_model_on_gemini_is_left_to_set_by_hand`; voice `gemini_speech_posts_generate_content_and_wraps_pcm_as_wav`, `gemini_wav_passes_through_and_pcm_is_wrapped`, `gemini_without_audio_says_why`, `gemini_errors_are_said_in_the_providers_words`, `gemini_takes_auth_and_headers_as_its_section_says`, `a_model_name_is_one_path_segment`, `wav_header_is_mono_16_bit`, `pcm_rate_reads_the_mime_type`, `speak_defaults_per_kind`; mail `unset_key_removes_only_that_key`; core `desk_speech_reads_aloud_through_gemini_as_wav`, `desk_speech_uses_each_kinds_defaults_and_the_desks_choice`, `desk_model_and_voice_are_checked_then_written`, `choosing_another_kind_clears_model_and_voice`, `desk_settings_list_every_speaker_with_its_defaults`, `the_desk_state_reads_whatever_the_voices_are`; appserver's page test extended; smoke 3 checks.
- Checked by eye in headless Chrome against a throwaway harness and the stand-in (deleted after): gemini chosen (Model/Voice with gemini-3.8-flash-lite-tts and Schedar greyed in, where replies go, the free-tier line), openai (tts-1/alloy, "No openai key is stored (harness secret add openai)."), Off (fields hidden, the free-tier line shown); typing a voice writes it; a bad model is refused with the line; a reply's speech came back 200 `audio/wav` and `decodeAudioData` (the avatar's path) decoded it.
- Final review (fresh reviewer, opus): no Critical; 2 Important and one Minor re-graded Important, fixed test-first (7cc2052); 5 Minor deferred (the ledger's `Final: minor` lines).
- Seen once under load: core `a_text_reply_to_an_approval_denies_it_and_the_agent_gets_the_reason` timed out while the reviewer ran beside the suite; 6/6 alone and green in every later run; it touches nothing this branch changed.
- Left: OpenAI shuts its Speech API models down on 2027-01-06 (the spec's openai defaults stop then); the deferred minors; speech with the real Gemini and OpenAI APIs is untried (no key here, by rule).
