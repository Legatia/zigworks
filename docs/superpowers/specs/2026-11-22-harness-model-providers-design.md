# harness: model providers (other LLM gateways)

The owner: "make sure the harness can plug in other LLM gateways, so for
example opencode or openrouter or straight using Claude auth token or
others." This changes an earlier rule ("models are reached only through
omnigate"): omnigate becomes one provider among several, and stays the
default, so existing settings keep working unchanged.

## Goals

- Any gateway or provider that speaks one of two request formats:
  **Anthropic Messages** (`…/messages`: omnigate, Anthropic's API,
  OpenRouter's Anthropic endpoint, OpenCode Zen for Claude-style models,
  Anthropic-compatible proxies) and **OpenAI Chat Completions**
  (`…/chat/completions`: OpenRouter, OpenCode Zen, OpenAI, and the many
  OpenAI-compatible gateways and local servers).
- Named providers in `config.ini`, built-in presets for the common ones,
  and a model value anywhere that can pick a provider: `PROVIDER:MODEL`.
- Everything that works today works with each provider: tool calls, the
  helpers' worker route, memory writing, summaries, prompt caching where the
  provider supports it, token counts in the log, the turn's time limit,
  the error messages (spent credits, rate limits, refused requests).

## Not in this spec

- Logging in with a Claude Free, Pro or Max subscription. Anthropic's terms
  reserve subscription (OAuth) credentials for its own apps and forbid
  third-party apps from routing requests through them; harness uses API
  keys, or a bearer token a gateway or proxy issues.
- OpenAI's Responses API (`/responses`, which OpenCode Zen uses for some
  GPT models), AWS Bedrock and Google Vertex sign-in, streaming, images.
  Each can come later as another `api =` value.

## What the owner writes

```ini
[model]
provider = omnigate            ; the default provider (a preset or a [provider NAME])
url = https://omnigate.example.com   ; the default provider's address (as today)
key = omnigate                 ; secret holding its key (as today)
main = claude-sonnet           ; a route or model of the default provider
worker_model = openrouter:deepseek/deepseek-chat   ; PROVIDER:MODEL picks another
memory_model = anthropic:claude-haiku-4-5

[provider openrouter]          ; optional: a preset needs no section
key = openrouter               ; secret name (default: the provider's name)
header = HTTP-Referer: https://legatia.solutions   ; extra headers, repeatable

[provider local]
api = openai                   ; anthropic | openai
url = http://127.0.0.1:11434/v1
auth = none                    ; x-api-key | bearer | none
```

Keys are stored like every secret: `harness secret add openrouter`. Keys are
masked in all output, never logged, and a provider whose key isn't stored
refuses its calls with one plain line naming the secret to add.

### Presets (no section needed)

| Name | api | url | auth | cache marks | key secret |
|---|---|---|---|---|---|
| `omnigate` | anthropic | `[model] url` (+`/v1` when it has no path) | x-api-key | yes | `[model] key` |
| `anthropic` | anthropic | `https://api.anthropic.com/v1` | x-api-key | yes | `anthropic` |
| `openrouter` | openai | `https://openrouter.ai/api/v1` | bearer | yes (passed to Anthropic models) | `openrouter` |
| `opencode` | openai | `https://opencode.ai/zen/v1` | bearer | no | `opencode` |
| `openai` | openai | `https://api.openai.com/v1` | bearer | no (automatic) | `openai` |

A `[provider NAME]` section with a preset's name overrides its fields; any
other name defines a new provider and must set `api` and `url`. `url` is the
prefix before `/messages` or `/chat/completions`. `auth = bearer` with
`api = anthropic` serves Anthropic-compatible gateways that take
`Authorization: Bearer` (the "auth token" kind of key), not subscription
logins. `cache = on|off` overrides the marks column.

## The design

- **model.zig gets a provider layer.** `Provider{name, api, url, auth,
  headers, cache, key}` resolved at start and on `/reload`; a `Client` is
  made for a provider and a model. The Anthropic path is today's code. The
  OpenAI path translates one request and one reply:
  - system text → a `system` message (the stable part first; with cache
    marks, OpenRouter's `cache_control` on that content part);
  - user and assistant turns → messages; `tool_use` blocks → assistant
    `tool_calls` (`id`, `function.name`, `function.arguments` as a JSON
    string); `tool_result` blocks → `tool` messages with `tool_call_id`;
  - tool definitions → `tools: [{type: function, function: {name,
    description, parameters}}]`;
  - reply `choices[0].message` → text and tool uses; `finish_reason`
    `stop`/`length`/`tool_calls` → `end_turn`/`max_tokens`/`tool_use`;
    arguments that don't parse as JSON are a bad reply (the call is not
    run);
  - usage `prompt_tokens`, `completion_tokens`,
    `prompt_tokens_details.cached_tokens` → the log's input, output and
    cache-read counts.
- **Errors** map as today for every provider: 401/403 → "the provider
  refused the key" (name the provider and the secret); 402 → credits or
  budget used up at that provider; 429 → wait as told, once, within the
  turn's time; 400/413 → the turn is dropped (as today); 5xx → upstream
  error; a timed-out call is never resent.
- **Model values** in `[model]`, in agent definitions (gap 1) and in
  workflow agent steps (gap 7) may be `PROVIDER:MODEL`; without a prefix
  they belong to `[model] provider`. `/status` lists each provider in use,
  its format and whether its key is stored.
- **The log** gets `provider` on model lines; usage per provider shows in
  `harness log` as today's token counts do.
- **Budgets**: omnigate keeps its budgets and spent-credit replies; for the
  other providers the budget is the provider's own (its dashboard and 402s);
  harness's token caps per helper and per turn apply as today.

## Tests

- `provider_presets_resolve_and_old_settings_still_reach_omnigate`: a 0.3
  `config.ini` (url without a path) posts to `/v1/messages` with
  `x-api-key`, as today.
- `a_provider_section_overrides_a_preset` and
  `a_new_provider_needs_api_and_url` (a bad section names its line).
- `openai_requests_carry_system_messages_tools_and_tool_results`: golden
  JSON for a turn with two tool calls and their results.
- `openai_replies_become_text_and_tool_uses`, including
  `finish_reason: length` → max_tokens and bad arguments → a bad reply.
- `a_turn_with_a_tool_call_works_through_an_openai_provider`: the fake
  server answers in OpenAI format (new `fake.zig` route); the agent calls a
  tool and answers.
- `bearer_and_none_auth_send_the_right_headers`, and the key is in no log
  line or test output.
- `each_status_maps_to_the_same_message_for_every_provider` (401, 402, 429
  with retry-after, 400, 500).
- `usage_and_cached_tokens_are_logged_per_provider`.
- `a_provider_without_its_key_refuses_calls_with_one_line`.
- `a_model_value_can_name_a_provider_in_routes_definitions_and_steps`.

## Calls I made

- Two formats now (Anthropic Messages, OpenAI Chat Completions); others
  later as more `api =` values.
- omnigate stays the default provider; old settings need no change.
- No subscription logins (Anthropic's terms); API keys and gateway tokens
  only.
- Presets for omnigate, Anthropic, OpenRouter, OpenCode Zen and OpenAI;
  every other gateway through a `[provider NAME]` section.
