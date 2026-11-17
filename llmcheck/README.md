# llmcheck

Checks a served language model through its OpenAI-style API (vLLM,
llama.cpp's `llama-server`, Ollama, TGI, LiteLLM and other gateways). Four
commands in one binary:

- `check`: does the server do what its interface accepts? Output formats
  dropped with HTTP 200, tool calls written into the text, prompts cut to
  the context without a word, limits and seeds ignored, no key needed.
- `fidelity`: does it give the same token probabilities as a reference
  server, or as a recording of one? Tells a difference in the model (other
  weights, quantization, build) from one in the chat template.
- `bench`: time to first token, time per request, gaps between tokens and
  tokens per second, at a fixed concurrency or a fixed request rate.
- `probe`: three requests and one line, for cron or a monitoring agent;
  with a recording as baseline it also reports drift.

Every answer is a line of `name key=value ...` (or JSON with `--json`) and an
exit code, so a script or an agent can act on it.

macOS, Linux (x86_64, arm64) and Windows (x86_64). Nothing beyond the Zig
standard library; one binary of about 1 MB, static on Linux. It talks only to
the addresses you give it.

**State: 0.1.0, tested only against the stand-in server that ships with it
(`llmcheck-fake`), on macOS. Not yet run against a real model server, and the
Windows binary has been compiled but not run.** See [Limits](#limits).

## Using it from an agent

Put llmcheck on PATH and add one line to the agent's instructions (for Claude Code, `CLAUDE.md`):

```
To check a model server use the llmcheck CLI: `llmcheck check URL` (interface), `llmcheck fidelity URL --ref URL` (same answers as a reference), `llmcheck bench URL` (speed), `llmcheck probe URL` (one-line health); exit 0 good, 1 a fault or difference, 4 not reached; `llmcheck help` has the details.
```

## Quick start

Real output, against `llmcheck-fake` (made-up words, the same every time);
only the addresses are changed.
First a server that does everything right, then one started with
`--fault drops_grammar --fault truncate_context`:

```
$ llmcheck check http://localhost:8000
check id=models status=pass detail="1 listed; using fake-1"
check id=chat status=pass detail="19 tokens in 0.00 s"
check id=auth status=warn detail="the server answers anyone: no key is needed"
check id=stream status=pass detail="19 pieces, the first after 0 ms"
check id=deterministic status=pass detail="the same request twice at temperature 0 gives the same text"
check id=max_tokens status=pass detail="stops at 5 tokens with finish_reason 'length'"
check id=stop status=pass detail="the answer ends before the stop string 'under'"
check id=json_schema status=pass detail="the answer is JSON that follows the schema"
check id=json_object status=pass detail="the answer is JSON"
check id=tools status=pass detail="get_weather is called with arguments that parse"
check id=tools_stream status=pass detail="get_weather is called with arguments that parse"
check id=context status=pass detail="a prompt of about 1026 tokens is refused: HTTP 400: This model's maximum context length is 512 tokens. However, your request has 1026 input tokens."
check id=sampling status=pass detail="the same seed repeats its text, another seed gives another"
check id=logprobs status=pass detail="8 tokens, each with 5 alternatives"
summary pass=13 fail=0 warn=1 skip=0 model=fake-1

$ llmcheck check http://localhost:8001 --only json_schema,context
check id=json_schema status=fail detail="asked for JSON by schema, got 'small water simple large and over moves the writes...' (response_format is ignored)"
check id=context status=fail detail="a prompt of about 1026 tokens is cut to 512 without a word (the context is smaller than the prompt)"
summary pass=0 fail=2 warn=0 skip=0 model=fake-1
```

The same model behind another chat template (`--fault template_differs`),
compared with the reference:

```
$ llmcheck fidelity http://localhost:8002 --ref http://localhost:8000
fidelity group=raw prompts=8 positions=128 mean_kl=0.0000 max_kl=0.0000 top1=1.000 diverged=0
fidelity group=chat prompts=8 positions=8 mean_kl=2.2511 max_kl=3.1238 top1=0.000 diverged=8
worst prompt=chat-3 position=0 kl=3.1238
noise mean_kl=0.0000 max_kl=0.0000 top1=1.000
verdict result=differs kl_limit=0.0100 min_top1=0.950 reason="raw text agrees but chat does not: the chat template (or an added system prompt) differs"
```

A recording of the reference, for later or for a place the reference cannot
be reached from:

```
$ llmcheck fidelity http://localhost:8000 --record reference.json
recorded file=reference.json model=fake-1 prompts=16 answered=16 noise_kl=0.0000

$ llmcheck fidelity https://llm.example.internal --against reference.json
```

Speed (the stand-in server at 3 ms per token) and a probe every half second
with the recording as baseline:

```
$ llmcheck bench http://localhost:8003 --requests 40 --concurrency 8
bench model=fake-1 requests=40 errors=0 concurrency=8 seconds=0.42 output_tokens=774 tokens_per_s=1838.3 requests_per_s=95.00
ttft_ms n=40 mean=4.4 min=3.5 p50=4.6 p90=5.0 p99=5.2 max=5.2
latency_ms n=40 mean=80.4 min=63.1 p50=81.1 p90=87.7 p99=91.0 max=92.2
token_gap_ms n=734 mean=4.1 min=3.0 p50=4.2 p90=4.5 p99=4.6 max=5.1
stream_tokens_per_s n=40 mean=241.9 min=229.2 p50=239.0 p90=254.3 p99=261.5 max=263.7

$ llmcheck probe http://localhost:8000 --baseline reference.json --every 0.5 --count 3
probe status=ok time=2026-11-17T18:45:16Z model=fake-1 models_ms=0.5 chat_ms=0.1 ttft_ms=0.1 drift_kl=0.0000 drift_top1=1.000
probe status=ok time=2026-11-17T18:45:16Z model=fake-1 models_ms=0.2 chat_ms=0.3 ttft_ms=0.3 drift_kl=0.0000 drift_top1=1.000
probe status=ok time=2026-11-17T18:45:17Z model=fake-1 models_ms=0.3 chat_ms=0.4 ttft_ms=0.3 drift_kl=0.0000 drift_top1=1.000

$ llmcheck probe http://localhost:9
probe status=down time=2026-11-17T18:45:17Z problem="could not connect"
```

## Commands

`URL` is the server's address, such as `http://localhost:8000`, with or
without `/v1` at the end. Every command takes:

| Option | |
|---|---|
| `--model M` | the model to ask (default: the first the server lists) |
| `--key K` | API key; or set `LLMCHECK_API_KEY` |
| `--timeout S` | seconds to wait for the server (default 120; 10 for `probe`) |
| `--insecure` | accept any https certificate |
| `--json` | one JSON object for the run (`probe`: one per line) |

`llmcheck help COMMAND` prints everything below in full.

### check

`llmcheck check URL [--ref URL] [--only a,b] [--skip a,b]`

A few dozen small requests. Status is `pass`, `fail`, `warn` or `skip`; only
`fail` changes the exit code.

| Check | Passes when |
|---|---|
| `models` | the server lists its models |
| `chat` | a short chat is answered, with finish_reason and token counts |
| `auth` | a request without the key is refused (a warning when no key is needed) |
| `stream` | a streamed answer is well formed and ends properly |
| `deterministic` | the same request twice at temperature 0 gives the same text |
| `max_tokens` | the answer stops at the limit, and says so |
| `stop` | the answer ends before a stop string |
| `json_schema` | output follows a JSON schema, not accepted and then ignored |
| `json_object` | JSON output is JSON |
| `tools` | a tool call comes back as `tool_calls` with arguments that parse |
| `tools_stream` | the same, streamed |
| `context` | a prompt longer than the context is refused, not cut silently |
| `sampling` | a seed repeats its text, another seed gives another |
| `logprobs` | token probabilities are returned (`fidelity` needs them) |
| `usage_match` | with `--ref`: prompts count the same tokens on both servers |

The context check sends prompts of 1,024 words, then twice that, up to
`--max-prompt-words` (default 8192), and compares the prompt tokens the
server reports with what was sent: a count far below it means the prompt was
cut. A model with a longer context passes with the length reached. It goes by
the server's own token counts, so a server that cuts the prompt and still
reports the full count is not caught.

### fidelity

```
llmcheck fidelity URL --ref URL
llmcheck fidelity URL --record FILE
llmcheck fidelity URL --against FILE
```

Both servers get the same prompts at temperature 0, and the probabilities
they give each token are compared. Half the prompts are raw text
(`/v1/completions`), half are chat messages. `mean_kl` is the KL divergence
per token (0 = identical), `top1` the share of positions where both have the
same most likely token. The verdict is `same`, `differs` or `unknown`
(no token probabilities to compare).

The reference is asked twice. If it differs from itself, three times that
noise is allowed instead of `--max-kl` (default 0.01); `--min-top1` defaults
to 0.95. `--tokens N` (default 16) and `--top K` (default 5) set how much is
compared, and `--prompts FILE` takes your own prompts, one to a line:
`raw: text` or `chat: text`.

### bench

`llmcheck bench URL [--concurrency N] [--requests N | --duration S] [--rate R]`

Streamed chat requests. Without `--rate`, N askers each send their next
request when the last is answered. With `--rate R`, requests start R times a
second whatever the server does, and a request's time counts from the moment
it was due, so a server that falls behind shows (`late=` in the output).
When the server sends no token counts, they are estimated from the stream
and the line says `token_counts=estimated`.

### probe

`llmcheck probe URL [--every S [--count N]] [--baseline FILE]`

The model list, a short chat, a short stream. Status is `ok`, `fail`
(reached, something does not work), `drift` (answers differ from the
baseline) or `down` (not reached).

## Exit codes

| | |
|---|---|
| 0 | all good |
| 1 | a check failed, the servers differ, some bench requests failed, a probe found a fault or drift |
| 2 | wrong usage |
| 4 | the server (or the reference) could not be reached, or the run could not be made: no token probabilities, every bench request failed, the probe found the server down |

Problems reaching a server go to stderr as `llmcheck: URL: reason`.

## Keys

The key is sent as `Authorization: Bearer`. It comes from `--key` or
`LLMCHECK_API_KEY`, and nowhere else: `OPENAI_API_KEY` is not read, so a key
for another service is never sent to the server being checked. A reference
has its own key (`--ref-key` or `LLMCHECK_REF_API_KEY`); the server's key is
never sent to it.

## The stand-in server

`llmcheck-fake` answers like a model server with made-up words, the same way
every time, and misbehaves on request:

```
llmcheck-fake [--port N] [--fault NAME]... [--key K] [--delay MS] [--context N]
```

Faults: `drops_grammar`, `tool_in_content`, `truncate_context`,
`ignore_max_tokens`, `ignore_stop`, `ignore_seed`, `nondeterministic`,
`hang`, `no_done`, `no_usage`, `no_logprobs`, `weights_differ`,
`template_differs`. It listens on 127.0.0.1 only and prints
`listening port=N`.

## Limits

- **Not yet run against a real model server.** Everything above is from the
  stand-in server, which was written from the API documentation by the same
  hand as the tool. Expect surprises on the first real run, most likely in
  the token probabilities: servers differ in whether and how they return them
  (stock `llama-server`, for one, is reported not to return them for
  prompt tokens).
- **The Windows and Linux binaries have been compiled, not run.**
- Each answer is compared only up to where the two texts part: the servers
  generate freely, so after the first different token they are no longer
  answering the same question. A server that differs early gives few
  positions (see `positions=` and `diverged=`).
- https uses the TLS in Zig 0.15.1's standard library. TLS 1.3 works
  (tested through a local proxy, and with a real certificate against a
  public site). TLS 1.2 fails against servers that pick a curve other than
  P-256 for the key exchange: seen with OpenSSL 3.6 limited to TLS 1.2.
- A certificate from a private authority is accepted only if that authority
  is in the system's store; there is no option for a CA file. `--insecure`
  accepts any certificate. Certificates issued to an IP address may be
  refused.
- HTTP/1.1 only; no proxy support.
- `bench` is a modest load generator: one thread per concurrent request, at
  most 256.

## Building

Zig 0.15.1:

```sh
zig build -Doptimize=ReleaseSafe      # zig-out/bin/llmcheck and llmcheck-fake
zig build test                        # unit tests, then scripts/smoke.sh against llmcheck-fake
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dstrip -p zig-out/windows
```

## License

MIT, see `LICENSE`.
