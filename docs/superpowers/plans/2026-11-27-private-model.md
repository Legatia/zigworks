# A model of their own for private conversations: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `[model] private_model = PROVIDER:MODEL` makes every model call of a run in a private conversation go to that model, with no fallback, and keeps what was said while private away from the other models.

**Architecture:** The choice is made once, where a turn starts (`agent.turn`): a run that is private while `ModelCfg.private` is set opens its own client for the turn and marks itself `on_private`. `Run.modelClient` and `Run.providerOf` substitute the private value while that mark is set, which carries helpers (they are copies of their parent's run) and the summary. `Conversation.messagesFor` leaves the turns marked private out of a request that is not going to the private model. The core only passes the setting in and says where things go.

**Tech Stack:** Zig 0.17.1; the stand-in model server of the tests (`model.TestEnv`).

**Spec:** `docs/superpowers/specs/2026-11-27-harness-private-model-design.md`

## Global Constraints

- The stand-in line, exactly: `(a private part of this conversation is left out here)`.
- Without `private_model`, the requests harness sends are byte for byte what they were.
- No other model is tried when the private model's provider fails.
- Tests use the stand-in server only; no real provider, no real harness home.
- Copy: plain statements; what leaves the machine is said inline in `/private on`'s answer.
- Every behaviour change is tested first (the test is seen failing).

## Review Focus

1. `/private on` arrives while a turn runs: that turn finishes on the model it started with, its helpers too, and it is not left out of its own requests (the newest turn is always sent).
2. A private turn that ended with tool results, followed by an ordinary turn: the request to the usual model is still valid (results and calls stay paired; the stand-in line is in a user message).
3. The default provider has no key and the private provider needs none: a private turn still runs.
4. Two stretches of private turns with ordinary turns between: the stand-in line once for each stretch.
5. `private_model = llama3.1:8b` (no provider's name): refused, never read as a model of the default provider.

---

### Task 1: the setting

**Files:** `harness/src/config.zig` (the `Model` struct, `parse`'s checks, `ParseError`, `reason`, `defaults_ini`, tests)

**Produces:** `cfg.model.private_model: []const u8 = ""`; `error.BadPrivateModel`.

- [ ] Test `private_model_names_its_provider`: `[provider local]` (api openai, url, auth none) with `private_model = local:llama3.1:8b` parses and keeps the value; `private_model = llama3.1:8b`, `= nowhere:x`, `= local:` and `= gemini:x` each give `error.BadPrivateModel` (the last may stay `SpeechOnlyModel`: assert which), and `reason(error.BadPrivateModel)` is not null. Unset: `""`.
- [ ] Run: fails (no such field).
- [ ] Add the field, the check after the speech-only loop (the part before the first `:` must be a provider `providerApi` knows with `api` anthropic or openai, and the part after it not empty), the error and its reason: `[model] private_model = PROVIDER:MODEL, where PROVIDER is a preset or a [provider NAME] section with api = anthropic or openai (the provider's name is required here, so that a mistyped one is never read as a model of the default provider)`. A commented line in `defaults_ini`: `; private_model = local:llama3.1:8b  ; the model of private conversations (/private on): PROVIDER:MODEL; unset: the same models as elsewhere`.
- [ ] Run: passes. Commit.

### Task 2: the agent loop

**Files:** `harness/src/agent.zig` (`ModelCfg`, `Run`, `Conversation.messages`, `turn`, tests)

**Produces:** `ModelCfg.private: []const u8 = ""`; `Run.on_private: bool = false`; `pub const private_gap = "(a private part of this conversation is left out here)"`; `Conversation.messagesFor(c, arena, leave_private: bool)` (`messages` calls it with `false`).

- [ ] Tests (each seen failing first), with `local` resolved as in `a_helper_runs_on_the_provider_its_value_names`:
  - `a_private_turn_is_asked_of_the_private_model`: `f.run.private = true`, `model_cfg.private = "local:gpt-private"`; request 1 has target `/v1/chat/completions` and model `gpt-private`; with `f.run.private = false` the next turn's request has target `/v1/messages`.
  - `a_private_turns_helpers_are_on_the_private_model`: a `strong` task and a task for a definition with `model: omnigate:other` both arrive at `/v1/chat/completions` with model `gpt-private`.
  - `a_private_turns_summary_is_asked_of_the_private_model`: a conversation long enough to be summarised in a private turn; the summary request's model is `gpt-private`.
  - `the_private_model_failing_ends_the_turn_there`: the stand-in answers 500 to the private request; the turn's `ended_by` names `local`; the server saw no request on `/v1/messages`.
  - `private_turns_are_left_out_of_what_another_model_is_sent`: turn 1 ordinary ("alpha"), turns 2 and 3 private ("bravo secret", one with a tool call and its result), turn 4 ordinary: its request holds "alpha", neither private text nor the tool result, and `private_gap` exactly once; turn 5 private: its request holds "bravo secret" and no gap line.
  - `two_private_stretches_leave_two_lines`.
  - `without_a_private_model_private_turns_are_sent_as_before`: `model_cfg.private = ""`, a private turn then an ordinary one: the second request holds the private turn's text and no gap line.
  - `a_turn_made_private_while_it_runs_is_still_sent_whole` (`messagesFor(a, true)` on a conversation whose newest turn is marked private returns that turn).
- [ ] `messagesFor`: every turn but the newest that is marked private is skipped when `leave_private`; the first kept message after a skipped stretch (a turn starts with a user message) gets `.{ .text = private_gap }` as its first block.
- [ ] `turn`: for a run that is not a helper, `r.on_private = r.isPrivate() and cfg.private.len > 0` from one reading of `isPrivate()` (the same reading marks the turn); when set, open `r.modelClient(cfg.private, r.client.max_tokens)`, point `r.client` at it for the turn and put the old pointer back when the turn ends. The request's messages are `conv.messagesFor(a, cfg.private.len > 0 and !r.on_private)`.
- [ ] `Run.modelClient` and `providerOf`: while `on_private`, the value is `cfg.private`.
- [ ] Run the agent tests: pass. Commit.

### Task 3: the core

**Files:** `harness/src/core.zig` (`baseRun`, `/private`, `/status`, tests), `harness/src/main.zig` (start notes, `harness secret`'s list)

**Consumes:** Task 1's `cfg.model.private_model`, Task 2's `ModelCfg.private`.

- [ ] Tests:
  - `a_private_conversations_turn_goes_to_the_private_model`: config with `[provider local]` at the stand-in and `private_model`; `/private on`, a message: the request's target is the local one; `/private off`, a message: omnigate's, without the private words, with the gap line.
  - `a_task_in_a_private_conversation_runs_on_the_private_model` (a run started through the core's task path reporting to `main` while it is private).
  - `private_on_says_where_its_words_go`: the four answers of the spec (with and without `private_model`; with `[voice] provider`; with `[desk] speak` a provider), and `/private off`'s line when `private_model` is set.
  - `a_private_turn_runs_when_the_default_provider_has_no_key`.
- [ ] `baseRun`: `model_cfg` is set when the chat's provider has its key or `private_model` is set (**Ruling** to ledger: with no key at the default provider and a private model, `delegate` is offered outside private conversations too and fails there with the missing key's message); `.private = c.cfg.model.private_model`.
- [ ] `/private`: the answers of the spec, built by `fn privateSays(c, a, conv, on) ![]const u8`. The usual model named in them is the conversation's agent's (`its definition's model, else [model] model`).
- [ ] `/status`, the start notes and `harness secret`'s provider list: `private_model` joins the values whose providers are listed.
- [ ] Run the whole suite (Debug and ReleaseSafe) and the cross builds. Commit.

### Task 4: the words

**Files:** `harness/README.md` ("Models and providers": a "Private conversations" part; the `/private` line in the memory section), `docs/superpowers/specs/2026-11-23-harness-gaps.md` (the item marked built), the ledger (rulings), `harness/HANDOFF-windows-platform.md` (a note: nothing for the desk shells to do; the setup screen doesn't offer the setting yet).

- [ ] Write them. Commit, push, watch CI.
