# harness: model providers (other LLM gateways) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model calls go to named providers, not only omnigate: built-in presets (omnigate, anthropic, openrouter, opencode, openai), `[provider NAME]` sections for any gateway speaking Anthropic Messages or OpenAI Chat Completions, and `PROVIDER:MODEL` wherever a model is named. A 0.3 `config.ini` reaches omnigate exactly as before.

**Architecture:** `model.zig` gets the provider layer: `Provider` (name, api, url, auth, headers, cache, key), the presets, `Providers.resolve` (presets + sections + keys) and `Providers.pick` (the one function that turns a model value into a provider and a model), `Client.open` for a provider, and the OpenAI request/reply translation; the Anthropic path stays today's code. `config.zig` reads `[model] provider` and `[provider NAME]`. `core.zig` resolves the providers at open and on `/reload` and makes every client (chat, tasks, briefs, memory writer) from them; `agent.zig` makes helper and summary clients from them; `main.zig` loads the providers' keys from the secret store and says at start which provider in use lacks its key. `fake.zig` answers `…/chat/completions` too.

**Tech Stack:** Zig 0.17.1, std only.

**Spec:** `docs/superpowers/specs/2026-11-22-harness-model-providers-design.md`; rules 4 and 7 of `2026-11-22-harness-platform-overview.md`.

## Global Constraints

- Zig 0.17.1, std only; macOS, Linux, Windows. At the end these compile: `zig build -Dtarget=x86_64-windows`, `-Dtarget=x86_64-linux-musl`, `-Dtarget=aarch64-linux-musl`, and `zig build unit-build -Dtarget=…` for each; `zig build test -Doptimize=ReleaseSafe` passes.
- No existing test is edited. Baseline: 483 pass, 2 skipped, `smoke: all ok` (54 checks).
- A 0.3 `config.ini` works unchanged: omnigate, POST `/v1/messages`, `x-api-key`, `anthropic-version: 2023-06-01`, cache marks as today. `model.Client.init(gpa, io, url, key, model, max_tokens)` and `agent.ModelCfg{url, key, main, worker, memory, max_tokens}` keep working as they are (tests use them).
- Keys are stored secrets (`harness secret add NAME`): never in a model request body, the log, output or config.ini; masked like every secret. A provider without its stored key refuses its calls with one line naming the secret to add.
- Errors map the same for every provider: 401/403 → key refused (provider and secret named); 402 → budget used up; 429 → wait as told, once, within the turn's time; 400/413 → turn dropped; 5xx → upstream; a timed-out call is never resent.
- Never contact a real provider: tests point every preset they use at the fake server. Test keys are fake values.
- Every new Core field is set in `Core.open`. Copy: plain labels, no slogans.
- Tests from `harness/`: `export PATH=~/.local/zig/zig-aarch64-macos-0.17.1:$PATH; zig build test --summary all --cache-dir $SCRATCH/cache > $SCRATCH/N.txt 2>&1`, read the tail; one test: `-Dtest-filter=NAME`.

## Rulings

1. **omnigate's url keeps 0.3's rule.** What: the path before an optional trailing `/v1`, then `/v1/messages` (`https://h/proxy` → `/proxy/v1/messages`); the spec says "+`/v1` when it has no path". Why: a 0.3 config with a path posts there today; the spec's rule would move it. Cost if wrong: for urls without a path or ending in `/v1` (the spec's cases) none; an omnigate behind a path without `/v1` is reached through a `[provider NAME]` section.
2. **`[model] url` and `key` stay omnigate's.** What: the presets table's reading (omnigate's url and key), not the example's comment "the default provider's address". Why: so a key is never sent to an address written for another provider; 0.3 means omnigate there. Cost if wrong: an owner who sets `provider = X` writes X's url in `[provider X]` (a new provider must anyway; presets need none).
3. **`[model] model` keeps its name.** What: the chat's model is `model =` (the spec's example writes `main =`); no alias. Why: 0.3 configs and the agents spec say `[model] model`. Cost if wrong: copying the spec's example names the `main =` line as an error.
4. **A prefix names a provider only when one has that name.** What: `local:llama3.1:8b` → provider local, model `llama3.1:8b`; `llama3.1:8b` (no provider `llama3.1`) → the default provider's model `llama3.1:8b`. Why: model names have colons (Ollama tags, OpenRouter's `:free`). Cost if wrong: a misspelt provider goes to the default provider as a model name, which refuses it (400, said in the turn).
5. **OpenAI usage: input = prompt_tokens − cached_tokens.** What: the log's `input_tokens` keeps 0.3's meaning (input not read from the cache), `cache_read` = cached_tokens. Why: OpenAI's prompt_tokens includes the cached ones; the helpers' token cap adds input and cache reads, which would count them twice. Cost if wrong: the log's input is below the provider's dashboard by the cached part.
6. **omnigate's messages stay word for word; other providers' name them.** What: "Model budget used up." for omnigate, "Model budget used up at openrouter." for others (each message gets " at NAME"); a task pauses on any message starting "Model budget used up". Why: 0.3's tests and the smoke script match omnigate's texts; with several providers the owner must know which one. Cost if wrong: one formula in `Client.failure`.
7. **The openai preset sends `max_completion_tokens`.** What: every other OpenAI-format provider sends `max_tokens`. Why: OpenAI refuses `max_tokens` for its reasoning models; OpenRouter, OpenCode Zen and local servers take `max_tokens`. Cost if wrong: a gateway wanting the other name refuses with 400, said in the turn.
8. **`header =` can't set Authorization, x-api-key, Host, Connection, Content-Length, Content-Type, Transfer-Encoding or anthropic-version.** Why: keys are stored secrets, masked (not config.ini text); the rest frame harness's request. Cost if wrong: none known; any other header passes.

## Review Focus

1. Model names with colons (`llama3.1:8b`, `…:free`) reach the right provider with the whole name (Task 1 test).
2. Local servers' tool calls: `arguments` `""` or an object, a missing `id`, `content` as text parts, `finish_reason` `stop` with calls — read, not refused; any other unparsable `arguments` string is a bad reply (Task 3 test).
3. A gateway that echoes the key in its 401 text: the key reaches neither the log, nor the owner, nor `lastError` (Task 2 and Task 4 tests).
4. A user message holding tool results and text (a final send, then the next message joins them): tool messages first, then one user message; an assistant turn with calls and no text sends `content: null` (Task 3 golden test).
5. `/reload` with a new `[provider NAME]` whose key was added after start: the key is read from the store then, and masked from then on (Task 5 test).

## Files

- Modify `model.zig` (provider layer, `Client.open`, `Client.failure`, `KeyRefused`, OpenAI format, TestEnv helpers), `config.zig` (`[model] provider`, `[provider NAME]`, `ParseError`, `reason`, `providerSettings`, defaults), `fake.zig` (`target` in saved requests, `…/messages` and `…/chat/completions`, `echo_key`, OpenAI error bodies), `agent.zig` (`ModelCfg.providers`, `Run.modelClient`, messages, `provider` on model lines), `brief.zig` (same two), `core.zig` (`providers`, `modelClient`, `/reload`, `/status`, `parseProblem` reasons, task pause), `main.zig` (provider keys, start notes, `secret list`, init text), `session.zig` (provider on model lines), `scripts/smoke.sh`, `harness/README.md`.

---

### Task 1: providers in config.ini, resolved and picked

**Files:** `model.zig`, `config.zig`, `core.zig` (`parseProblem` asks `config.reason`).

**Interfaces — Produces (model.zig):**
- `pub const Api = enum { anthropic, openai }`; `pub const Auth = enum { x_api_key, bearer, none }`; `pub fn parseApi(w) ?Api`, `pub fn parseAuth(w) ?Auth` (words `anthropic|openai`, `x-api-key|bearer|none`); `pub const Header = std.http.Header`; `pub const max_headers = 8`.
- `pub const Section = struct { name: []const u8, api: ?Api = null, url: ?[]const u8 = null, auth: ?Auth = null, key: ?[]const u8 = null, cache: ?bool = null, headers: []const Header = &.{} }` — what a `[provider NAME]` section says.
- `pub const Preset = struct { name, api, url, auth, cache, key, tokens_field = "max_tokens" }`; `pub const presets` in the spec's order with its values (omnigate's url and key come from `[model]`; openai's `tokens_field = "max_completion_tokens"`, Ruling 7); `pub fn isPreset(name) bool`; `pub fn validName(name) bool` (a-z, 0-9, `-`, `_`, 1–32, first a letter or digit); `pub fn validUrl(u) bool` (`http://` or `https://`, and `http.Target.parse` takes it).
- `pub const Provider = struct { name, api, url, auth, headers: []const Header = &.{}, cache: bool, key_name, key: []const u8 = "", tokens_field = "max_tokens"; pub fn hasKey(p) bool (auth none, or a key); pub fn format(p) []const u8 ("Anthropic Messages" | "OpenAI Chat Completions") }`.
- `pub const Settings = struct { default = "omnigate", omnigate_url = "", omnigate_key = "omnigate", sections: []const Section = &.{} }`.
- `pub const KeyLookup = struct { ctx: ?*anyopaque = null, get: *const fn (ctx: ?*anyopaque, a: Allocator, provider: []const u8, secret: []const u8) ?[]const u8 }`; `pub const no_keys: KeyLookup`.
- `pub const Choice = struct { provider: *const Provider, model: []const u8 }`.
- `pub const Providers = struct { list: []const Provider, default: usize; pub fn resolve(arena, s: Settings, keys: KeyLookup) !Providers; pub fn find(p, name) ?*const Provider; pub fn pick(p, value) Choice; pub fn used(p, arena, values: []const []const u8) ![]const *const Provider }` — resolve: the presets in order, each overridden field by field by its section, then the other sections in file order (auth default: x_api_key for anthropic, bearer for openai; cache default: on for anthropic, off for openai; key name default: the provider's name); omnigate's url through `omnigateUrl` (Ruling 1); keys looked up for auth ≠ none. pick: Ruling 4.
- `pub fn omnigateUrl(arena, url) ![]const u8` — "" stays ""; else trailing `/` dropped and `/v1` added unless it ends in `/v1`.

**config.zig:** `Model.provider: []const u8 = "omnigate"`; `Config.providers: []const model.Section = &.{}` (not a section name: `parse` skips it in its field loop); `pub const ParseError = Error || error{ BadProvider, BadHeader, ProviderNeedsApiAndUrl, UnknownProvider }`; `parse` returns `ParseError!Config` (`Error` itself unchanged: `lines` and the other parsers keep their sets); `pub fn reason(e: anyerror) ?[]const u8`; `pub fn providerSettings(cfg: Config) model.Settings`. `[provider NAME]` keys: api, url, auth, key (a secret's name), cache, header (`Name: value`, repeatable, ≤ 8, Ruling 8). Every `[provider NAME]` header counts, one with no keys too (read from the text, so `parseProblem` names the header line); a non-preset needs api and url; `[model] provider` must be a preset or a section. `defaults_ini` gets `provider = omnigate` with a comment (no address in it).

- [ ] **Step 1: Write the failing tests**
  - config.zig `a_provider_section_overrides_a_preset`: `[provider openrouter]` with `key = or-key`, `url = http://127.0.0.1:9/api/v1`, `header = HTTP-Referer: https://example.org`, `header = X-Title: harness`, `cache = off` → resolved openrouter: api openai, auth bearer (preset), url as written, key_name `or-key`, cache false, 2 headers in order; anthropic untouched (`https://api.anthropic.com/v1`, x_api_key, cache true, key `anthropic`); `parse(defaults_ini)` has no provider section and default `omnigate`.
  - config.zig `a_new_provider_needs_api_and_url`: `ProviderNeedsApiAndUrl` for `[provider local]` alone, with only `url`, with only `api`; with both: auth bearer, cache false, key_name `local` (api openai) / x_api_key, cache true (api anthropic); `[model]\nprovider = nowhere` → `UnknownProvider`, `provider = local` with the section → default `local`; `core.parseProblem(a, "config.ini", "[model]\nurl = http://127.0.0.1:1\n[provider local]\nurl = http://127.0.0.1:11434/v1\n", config.parse)` starts with `config.ini line 3 has an error: [provider local] (a provider that is not a preset needs api`.
  - config.zig `provider_sections_refuse_bad_values`: `BadProvider` for `api = grpc`, `auth = basic`, `cache = maybe`, `url = ftp://x`, `url = http://h/a b`, `key = Bad Key`, `colour = red`, `[provider Bad:Name]`, `[provider a/b]`; `BadHeader` for `header = NoColon`, `header = Authorization: Bearer x`, `header = x-api-key: y`, `header = Host: h`, `header = : v`, nine `header` lines; `reason` non-null for all four new errors.
  - model.zig `a_model_value_picks_its_provider_by_its_prefix`: sections local (openai, auth none) and default omnigate: `claude-sonnet` → omnigate/`claude-sonnet`; `openrouter:deepseek/deepseek-chat` → openrouter/`deepseek/deepseek-chat`; `local:llama3.1:8b` → local/`llama3.1:8b`; `llama3.1:8b` → omnigate/`llama3.1:8b`; `openrouter:meta-llama/llama-3.3-70b-instruct:free` → openrouter, the rest whole; default `local`: `qwen2:7b` → local/`qwen2:7b`; a lookup answering `or-test-key` gives openrouter that key and `hasKey`; local (auth none) is never looked up and `hasKey`; `used` of three values naming omnigate twice → 2 providers.
- [ ] **Step 2:** run; expect compile errors (no `model.Section`, `Providers`, `ParseError`).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+4).
- [ ] **Step 5:** commit `harness providers: [provider NAME] sections, presets and PROVIDER:MODEL`.

### Task 2: a client for a provider (Anthropic format, auth, errors)

**Files:** `model.zig`, `fake.zig`.

**Interfaces — Produces:**
- `Error` gains `KeyRefused` (401, 403; never retried).
- `Client` gains `provider: []const u8 = "omnigate"`, `key_name = "omnigate"`, `api = .anthropic`, `auth = .x_api_key`, `headers: []const Header = &.{}`, `cache = true`, `path = "/v1/messages"`, `tokens_field = "max_tokens"`. `Client.init` (0.3) keeps today's target and path.
- `pub fn open(gpa, io, p: Provider, model: []const u8, max_tokens: u32) http.Error!Client` — target's prefix is the url's path as written (trailing `/` dropped), path `/messages` or `/chat/completions`; "" url → calls refused (`NoUrl`).
- `Providers.client(p, gpa, io, value, max_tokens) http.Error!Client` = `open` of `pick(value)`.
- Requests: `x-api-key` for x_api_key, `Authorization: Bearer` (http's `key`) for bearer, nothing for none (no `NoKey` then); `anthropic-version: 2023-06-01` for api anthropic; then the provider's headers. Without `cache`, no marks at all: `anthropicBody(arena, model, max_tokens, system, messages, tools, marks: bool)`, `requestBody` = marks on.
- `note` replaces the client's own key in the error text by `[secret:KEY_NAME]`.
- `pub fn failure(c: *const Client, a: Allocator, e: anyerror) ![]const u8` — Ruling 6; with at = "" for omnigate, " at NAME" otherwise: BudgetSpent `Model budget used up{at}.`; RateLimited `The model is rate limited{at}; try again later.`; NoKey `Model calls are refused: no {P} key is stored (harness secret add {S}).`; NoUrl `Model calls are refused: no {P} url is set ([model] url in config.ini, then /reload).` (`[provider P] url` for others); KeyRefused `Model calls are refused: {P} refused the key stored as {S} ({lastError}); store the right key with harness secret add {S}.`; TimeUp `Time limit reached for this turn.`; Timeout `Model call failed{at}: Timeout {lastError}`; Rejected `The model API{at} refused the request: {lastError}`; others `Model call failed{at}: {name} {lastError}`.
- fake.zig: a saved request is `{"target":…,"headers":…,"body":…}`; POST to any route ending in `/messages` (Anthropic) or `/chat/completions` (OpenAI), not `/page/…` or `/bot…`, answers the next script; a script `{"status":N,"echo_key":true}` says the request's key in its error message.
- TestEnv: `pub fn provider(e, name, api: Api, auth: Auth, key) !Provider` (url `http://127.0.0.1:PORT/v1`, cache = api is anthropic, key_name = name), `pub fn clientFor(e, p: Provider, model) !Client` (max_retry_wait 1).

- [ ] **Step 1: Write the failing tests** in model.zig:
  - `provider_presets_resolve_and_old_settings_still_reach_omnigate`: `config.parse` of `[model]\nurl = http://127.0.0.1:PORT\nkey = omnigate\n` resolved with omnigate's key `og-test-key` → `client("claude-sonnet")` → request 1: target `/v1/messages`, `x-api-key` `og-test-key`, `anthropic-version` `2023-06-01`, model `claude-sonnet`, the last tool marked; url `…/v1` → `/v1/messages`; url `…/proxy` → `/proxy/v1/messages`; the five presets' api, url, auth, cache and key name as in the spec's table.
  - `bearer_and_none_auth_send_the_right_headers`: openai/bearer key `sk-bearer-test-1` with header `HTTP-Referer: https://example.org` → `Authorization` `Bearer sk-bearer-test-1`, `HTTP-Referer` there, no `x-api-key`, no `anthropic-version`, target `/v1/chat/completions`; anthropic/bearer → Bearer and `anthropic-version`, no `x-api-key`; openai/none with key "" → answered (no NoKey), no `Authorization`, no `x-api-key`; `{"status":401,"echo_key":true}` → `KeyRefused`, one request, `lastError` holds `[secret:local]` not the key, `failure` = `Model calls are refused: local refused the key stored as local (scripted error for key [secret:local]); store the right key with harness secret add local.`
- [ ] **Step 2:** run; expect compile errors (`Client.open`, `KeyRefused`).
- [ ] **Step 3:** implement (the OpenAI branch may return `BadReply` until Task 3).
- [ ] **Step 4:** whole suite green (+2).
- [ ] **Step 5:** commit `harness providers: a client per provider, x-api-key, bearer or none, 401 says the key was refused`.

### Task 3: the OpenAI Chat Completions format

**Files:** `model.zig`, `fake.zig` (OpenAI error body).

**Interfaces — Produces:**
- `pub fn openaiBody(arena, model, tokens_field, max_tokens: u32, system: System, messages: []const Message, tools: []const ToolDef, marks: bool) ![]u8` — `{"model","<tokens_field>","messages","tools"}`. System: none when empty; a string (`stable`, `\n\n`, `changing`), or with marks and `system.cache` text parts with `cache_control: {type: ephemeral}` on the stable part. A user message: its tool results as `{"role":"tool","tool_call_id","content"}` first, then its text blocks joined by `\n\n` as one user message. An assistant message: text joined (`null` when none) and `tool_calls: [{id, type: function, function: {name, arguments: <input JSON as a string>}}]`. Tools: `{type: function, function: {name, description, parameters}}`. `is_error` has no field: the text goes as is.
- `pub fn parseOpenAIReply(arena, body) ?Reply` — `choices[0].message`: content (string or text parts) → a text block; each tool call → tool_use (`arguments` "" → `{}`, an object → itself, another string must parse as a JSON object or the reply is bad; no id → `call_` + hex hash of body and index); `finish_reason` stop/length/tool_calls → end_turn/max_tokens/tool_use, others as given; usage per Ruling 5.
- fake.zig: the OpenAI route's errors are `{"error":{"message":…,"type":"scripted","code":N}}`.
- TestEnv: `pub fn oaTextReply(comptime s) []const u8`, `pub fn oaToolReply(a, id, name, input_json) ![]u8`.

- [ ] **Step 1: Write the failing tests** in model.zig:
  - `openai_requests_carry_system_messages_tools_and_tool_results`: golden `openaiBody` for system `sys stable`, user [`context`, `list two files`], assistant [`Checking.`, shell `{"command":"ls a"}` as tu_1, read_file `{"path":"b.txt"}` as tu_2], user [result tu_1 `a.txt`, result tu_2 `no such file` (error)], tools shell and read_file, `max_tokens` 1000, no marks: `{"model":"gpt-test","max_tokens":1000,"messages":[{"role":"system","content":"sys stable"},{"role":"user","content":"context\n\nlist two files"},{"role":"assistant","content":"Checking.","tool_calls":[{"id":"tu_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls a\"}"}},{"id":"tu_2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"b.txt\"}"}}]},{"role":"tool","tool_call_id":"tu_1","content":"a.txt"},{"role":"tool","tool_call_id":"tu_2","content":"no such file"}],"tools":[{"type":"function","function":{"name":"shell","description":"run","parameters":{"type":"object"}}},{"type":"function","function":{"name":"read_file","description":"read","parameters":{"type":"object"}}}]}`; with marks: system `[{"type":"text","text":"sys stable","cache_control":{"type":"ephemeral"}}]`; `max_completion_tokens` with that field; an assistant with only calls → `"content":null`; a user message [result, text] → the tool message, then `{"role":"user","content":"next"}`.
  - `openai_replies_become_text_and_tool_uses`: through the fake: text + call `call_1` shell `{"command":"ls -l"}`, `tool_calls` → [text `Let me check.`, tool_use call_1 shell with that input], stop `tool_use`; `finish_reason: length` → `max_tokens`; `arguments: "{\"command\":"` → `BadReply`; `parseOpenAIReply`: arguments "" → `{}`, an object → its JSON, no id → starts `call_`, content parts joined, usage 100/7/cached 60 → input 40, output 7, cache_read 60.
  - `each_status_maps_to_the_same_message_for_every_provider`: for an omnigate client and an openai client `local`: 401 → KeyRefused, 402 → BudgetSpent, 400 → Rejected, 500 → Upstream, 429 (retry_after 1) twice → RateLimited after 2 requests; omnigate's `failure` texts are 0.3's (`Model budget used up.`, `The model is rate limited; try again later.`, `The model API refused the request: scripted error`, `Model call failed: Upstream scripted error`); local's with " at local" removed equal them; local's 401 with `local` replaced by `omnigate` equals omnigate's.
- [ ] **Step 2:** run; expect compile errors / failures (`openaiBody`, `parseOpenAIReply`).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+3).
- [ ] **Step 5:** commit `harness providers: OpenAI Chat Completions requests and replies`.

### Task 4: runs through providers

**Files:** `agent.zig`, `brief.zig`.

**Interfaces — Consumes:** `Providers`, `Client.failure`, `Client.provider`. **Produces:**
- `ModelCfg.providers: ?*const model.Providers = null` (`url` and `key` only without it).
- `pub fn modelClient(r: *const Run, value: []const u8, max_tokens: u32) !model.Client` — helpers (`main`/`worker`) and summaries (`memory`) use it.
- The turn's messages come from `r.client.failure` (Rejected adds today's ". This turn is left out …"); every model line (turn, summary, brief) carries `provider` after `result`; brief's budget line is `failure(BudgetSpent)`.

- [ ] **Step 1: Write the failing tests** in agent.zig:
  - `a_turn_with_a_tool_call_works_through_an_openai_provider`: client openai/bearer `local`; scripts: `oaToolReply("call_1", "recall", {"query":"flats"})`, `oaTextReply("Nothing about flats yet.")` → the answer; request 2: target `/v1/chat/completions`, messages system, user, assistant whose `tool_calls[0].id` is `call_1`, tool with `tool_call_id` `call_1`; the log has the recall tool line.
  - `usage_and_cached_tokens_are_logged_per_provider`: the openai client's reply with usage 100/7/cached 60 → a model line with `"provider":"local"`, `"input_tokens":40`, `"output_tokens":7`, `"cache_read":60`; then the 0.3 client's turn → `"provider":"omnigate"`, `"input_tokens":10`.
  - `a_provider_without_its_key_refuses_calls_with_one_line`: provider `openrouter` (openai, bearer, key "") → answer exactly `Model calls are refused: no openrouter key is stored (harness secret add openrouter).` (no line break), 0 requests.
  - `a_refused_key_is_named_and_kept_out_of_the_log`: bearer key `sk-echoed-test-key-1`, `{"status":401,"echo_key":true}` → the answer names `local` and `harness secret add local`; neither answer nor log holds the key.
  - `a_helper_runs_on_the_provider_its_value_names`: `model_cfg.providers` = omnigate and `local` (openai) at the fake, `worker = "local:gpt-worker"`; a delegate → the helper's request goes to `/v1/chat/completions` with model `gpt-worker`, the parent's to `/v1/messages`.
- [ ] **Step 2:** run; expect failures (no `provider` field, 0.3 texts for other providers, helper on omnigate).
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+5).
- [ ] **Step 5:** commit `harness providers: helpers, summaries and briefs through providers; provider on model lines`.

### Task 5: providers in the instance

**Files:** `core.zig`, `main.zig`, `session.zig`.

**Interfaces — Produces:**
- `Core.providers: model.Providers` (resolved in `Core.open` before the chat client, `c.store = null` set before it, and on `/reload` into the new settings arena; kept until the chat client is made); `pub fn modelClient(c: *Core, value: []const u8, max_tokens: u32) !model.Client`; the key lookup: omnigate → `secrets.omnigate`, others → `secretValue` (start-loaded, else the store, then masked).
- Chat, tasks, briefs and the memory writer use `modelClient`; `baseRun` passes `providers = &c.providers` (model_cfg set when the chat model's provider `hasKey`); the memory writer's lines carry `provider`; a task pauses on any `Model budget used up…`; `parseProblem` asks `config.reason`.
- `/status` gets a line `Providers: NAME (FORMAT, key stored|key not stored: harness secret add S|no key needed[, no url: [model] url]); …` for the providers of `model`, `worker_model`, `memory_model`.
- main.zig: `App.secrets` loads omnigate's key by its resolved name and every other provider's key (auth ≠ none) into `named`; `pub fn startNotes(a, set: *const model.Providers, values) ![]const []const u8` — per provider in use: `note: no {P} key stored under "{S}"; model calls will be refused. Run: harness secret add {S}` and `note: no {P} url is set ([model] url in config.ini); model calls will be refused` (0.3's words for omnigate); `secret list` adds `S (P key): stored|not stored` for providers in use or with a section, other than omnigate.
- session.zig: a model line of a provider other than omnigate reads `Model (P): …`.

- [ ] **Step 1: Write the failing tests**
  - core.zig `a_model_value_can_name_a_provider_in_routes_definitions_and_steps`: config `model = local:gpt-chat`, `worker_model = openrouter:deepseek/deepseek-chat`, `memory_model = anthropic:claude-haiku-4-5`, `[provider local]` openai/none at `FAKE/v1`, `[provider openrouter] url = FAKE/api/v1`, `[provider anthropic] url = FAKE/v1`; keys `sk-or-test-key-1`, `sk-ant-test-key-1` put in a test store after start, then `/reload` → `Settings reloaded.`; `/status` has `Providers: local (OpenAI Chat Completions, no key needed); openrouter (OpenAI Chat Completions, key stored); anthropic (Anthropic Messages, key stored)`; a chat turn that delegates once: request 1 target `/v1/chat/completions`, model `gpt-chat`, no Authorization; request 2 `/api/v1/chat/completions`, `Bearer sk-or-test-key-1`, model `deepseek/deepseek-chat`; `writeMemories` → a request to `/v1/messages` with `x-api-key` `sk-ant-test-key-1`, model `claude-haiku-4-5`; `pick("openrouter:x/y")` and `modelClient("anthropic:claude-opus-4-1", 100)` (a definition's and a workflow step's value) give openrouter/`x/y` and anthropic/`claude-opus-4-1`; the log has provider local, openrouter and anthropic, neither key.
  - core.zig `a_task_pauses_when_any_provider_says_its_budget_is_spent`: task on `local` (openai/none) answered 402 → `Task NAME is paused`.
  - main.zig `start_notes_name_each_provider_in_use_without_its_key`: default settings, no keys → 0.3's two omnigate notes word for word; all three values on `openrouter:` with no key → only `note: no openrouter key stored under "openrouter"; model calls will be refused. Run: harness secret add openrouter`.
  - session.zig: `render` of a run whose model line has `"provider":"local"` shows `Model (local): 5 in, 2 out`; with `omnigate` or none, `Model: …` as today.
- [ ] **Step 2:** run; expect failures.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** whole suite green (+4).
- [ ] **Step 5:** commit `harness providers: the instance resolves providers at start and on /reload; /status, start notes and secret list name them`.

### Task 6: smoke, README, final checks

**Files:** `scripts/smoke.sh`, `harness/README.md`.

- [ ] **Step 1:** smoke, after "the model got the omnigate key": store `sk-local-smoke-key-1` as `local`, write a config with `model = local:gpt-smoke` and `[provider local]` (openai, `$URL/v1`, bearer), script an OpenAI reply; checks: `secret list` says `local (local key): stored`; `task run check` prints `[check] Price is up.`, its request's target is `/v1/chat/completions` with `Authorization: Bearer sk-local-smoke-key-1`, the log has `"provider":"local"` and not the key. Then the saved config.ini goes back.
- [ ] **Step 2:** README: "Models and providers" (presets table, `[provider NAME]` keys and defaults, `PROVIDER:MODEL` with Ruling 4's rule, keys via `harness secret add`, errors per provider, no Claude subscription logins: Anthropic's terms forbid third-party apps from using them; not yet: Responses API, Bedrock, Vertex, streaming, images); intro, quick start, config.ini row, helpers' cache note, tasks' budget note, State counts.
- [ ] **Step 3:** `zig build test` (Debug) and `-Doptimize=ReleaseSafe` green; cross builds and `unit-build` for x86_64-windows, x86_64-linux-musl, aarch64-linux-musl.
- [ ] **Step 4:** commit `harness providers: smoke check through an OpenAI-format provider; README: models and providers`.

## For the agent definitions builder (gap 1)

A definition's `model:` (and a workflow step's) is a model value: `PROVIDER:MODEL`, or a model of `[model] provider`. Resolve it with `model.Providers.pick(&core.providers, value) → Choice{ provider, model }`; make a client with `core.modelClient(value, max_tokens)` (or `run.modelClient(value, max_tokens)` inside a run: helpers pass `model_cfg.providers`). Keys of every preset and `[provider NAME]` are loaded at start (`App.secrets`) and on `/reload` (`secretValue`), so a definition may name any of them.
