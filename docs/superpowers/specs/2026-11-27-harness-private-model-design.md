# harness: a model of their own for private conversations

2026-11-27. From the gaps list (`2026-11-23-harness-gaps.md`, "Private
conversations on a local model", out of the fifteen-features list the owner
read on 2026-11-23). Builds on `2026-11-19-harness-design.md` (`/private`),
the providers (README, "Models and providers") and long memory
(`2026-11-23-harness-routines-undo-copies-memory-design.md`, Part 4).

The owner was not asked about the details here; they said to go on
building what doesn't need them. Every choice below that isn't in the gaps
line is the builder's call and is marked **Call**.

## Intent

`/private on` keeps a conversation out of memory and keeps only sizes and
hashes of it in the log. Its words are still sent to the model's provider,
like every other conversation's. Someone who runs a model on their own
machine (Ollama, llama.cpp, LM Studio, a server at home) should be able to
say: private conversations are answered by that model, and by no other.

## What it adds

One setting:

```ini
[model]
private_model = local:llama3.1:8b   ; PROVIDER:MODEL; unset: as before

[provider local]
api = openai
url = http://127.0.0.1:11434/v1
auth = none
```

While a conversation is private and `private_model` is set:

1. **Every model call of a run in it goes to `private_model`.** The
   agent's turn, the helpers it delegates to (also `strong` ones, and ones
   whose definition names a model), and the summary made when the
   conversation grows too long. This holds for whatever runs there: the
   owner's messages, a brief, a task, a trigger or a workflow step that
   reports to that conversation. An agent definition's own `model` does
   not apply while its conversation is private.
2. **Nothing falls back.** When the private model's provider can't be
   reached, has no key, or refuses, the turn ends with the usual error
   naming that provider. No other model is tried.
3. **What was said while private stays with the private model.** After
   `/private off`, the turns said while private are left out of what the
   other model is sent; one line stands in their place: "(a private part
   of this conversation is left out here)". They are sent again, whole,
   when the conversation is private again. They were never in memory, the
   log's text, the summaries or the desk's saved history, and still aren't.
4. **It starts with the next message.** The model is chosen when a turn
   starts. A turn already running when `/private on` arrives finishes on
   the model it started with (its log lines are private from then on, as
   before).

Without `private_model`, nothing changes except what `/private on` says
(below).

## The setting

- `private_model` is `PROVIDER:MODEL`, and the provider must exist: a
  preset or a `[provider NAME]` section, with `api = anthropic` or
  `openai`. Anything else is refused when the file is read, with the
  reason. **Call:** the provider's name is required here, unlike `model`
  and `worker_model`, where a value without a known provider's name is a
  model of the default provider. With that rule a typo in the provider's
  name would send private conversations to the default provider.
- harness does not check that the provider is on this machine. **Call:**
  "a model of their own" is the owner's to judge: a server at home, or a
  provider they have a no-retention contract with, are as valid as
  127.0.0.1. The name of the setting says what it is for, not where it is.
- `harness config set model.private_model local:llama3.1:8b` works like
  the other model settings (applies at `/reload`); `harness config set
  model.private_model ""` turns it off.
- `/status` and the notes at start list the private model's provider with
  the others, and say when its key isn't stored.
- The model needs tool calling: harness sends it the same tools as any
  other. A model that can't call tools answers in text only.

## What `/private on` says

It is the place where the owner decides what to say next, so what still
leaves the machine is said there, in one message:

- with `private_model`: "Private here: nothing from this conversation is
  written to memory, and the log keeps only sizes and hashes of what is
  said in it. From the next message its model is local:llama3.1:8b."
- without: the same first sentence, then "What is said here is still sent
  to the model's provider (omnigate)."
- when voice notes are set up (`[voice] provider`): "Voice notes are still
  sent to PROVIDER to be transcribed."
- when the desk reads replies aloud through a provider (`[desk] speak` is
  a provider, not `off` or `browser`): "Replies read aloud on the desk are
  still sent to PROVIDER."

**Call:** transcription and reading aloud are not moved or switched off in
a private conversation. They are separate services the owner set up, and
the message names them; refusing voice notes in private conversations is a
later choice if wanted.

`/private off` says, when `private_model` is set: "Private is off here.
What was said while it was on is left out of what MODEL is sent." (MODEL:
the conversation's usual model.)

## Not in this

- Tools are unchanged: a private conversation's agent can still fetch a
  page, call an MCP server or send mail where the gate allows it, and what
  it sends there is sent. The gate decides as before.
- No local model is installed, started or chosen by harness.
- Speech from Home Assistant (`[voice_agent]`) has its own conversation
  and model setting and isn't touched.
- The memory writer, long-memory summaries, the people notes and the other
  background calls already leave private conversations alone; they stay on
  their own models.

## Tests that must exist

With the stand-in model server standing for both providers (the request's
path and `model` field tell them apart):

1. A private turn's request goes to the private model; the next turn after
   `/private off` goes to the usual one.
2. A helper delegated in a private turn calls the private model, also when
   `strong` and when its definition names a model.
3. The summary made in a private turn is asked of the private model.
4. The private provider refusing or unreachable ends the turn with its
   error; no request reaches the other provider.
5. After `/private off`, the request to the usual model holds no word of
   the private turns and holds the stand-in line once; after `/private on`
   again, the request to the private model holds them.
6. Without `private_model`, requests are byte for byte what they were
   (private turns included, as before).
7. `private_model` without a provider's name, with an unknown provider or
   with a speech-only provider is refused with its reason.
8. `/private on` and `/private off` say the lines above in each case
   (with and without `private_model`, voice notes, the desk's speech).
9. A run started by a task in a private conversation calls the private
   model (through the core, not only the agent loop).
