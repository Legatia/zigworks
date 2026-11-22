# harness: agent definitions (gap 1)

Follows `2026-11-22-harness-platform-overview.md` and builds on harness
0.3 (branch `harness-logins`). Mac session, phase B: it uses the who,
rules sections and grants phase 0 builds (the overview's Shared formats),
a run's `by` and conversation (gap 4), the inbox's items and `who` grants
(gap 5) and triggers' `agent` key (gap 6). The hosted note is for the
Windows session.

## Intent

The post: each agent should run on its own, so one agent can change itself
(write its own extensions) without reaching into another's state, and what
an agent is should be apart from its runs and sessions. For harness: an
agent is a file, a run one execution of it; each definition keeps its own
history and limits, and none widens its own powers without the owner.

## Goals

1. Definitions as files `agents/NAME.md`; built-in `main` (today's agent)
   and `helper` (today's helper), so without `agents/` harness is 0.3.
2. `delegate` names a definition per task and never passes on a tool its
   starter lacks; the owner picks the definition per conversation or
   message.
3. An agent can propose a new definition or a change to its own: asked
   every time, shown in full, widening first; never in unattended runs.
4. An instance (a definition in a conversation) has its own history and
   takes one input at a time; instances run side by side within today's
   limits; rules and grants can be per definition.

## Non-goals

- Hooks inside harness: code an agent writes runs only as `shell` calls
  through the gate; "when X happens, do Y" is a trigger (gap 6); running
  agent-written code unwatched belongs in a sandbox (gap 2).
- A memory store per definition; agents adding MCP servers (`mcp.ini`
  stays the owner's); resuming a run cut off by a restart (hosted note);
  process isolation on the owner's machine (threads, as helpers today).

## What the owner does

`harness init` writes `agents/main.md` and `agents/helper.md` with
today's instructions; without them the same built-ins apply. A definition:

```markdown
---
name: researcher
description: Research across several sources; answers with links.
model: claude-haiku
tools: search, fetch, browse, read_file, recall, skill, github/list_issues
memory: pinned
parallel: 4
---
Research one question at a time. Use at least two independent sources...
```

| Key | Means | Default |
|---|---|---|
| `name`, `description` | the file's name (a-z, 0-9, `-`, up to 64); one line: when to use it | required |
| `model` | an omnigate route | `[model] model`; delegated: `worker_model` |
| `tools` | tool names, `server/tool` or `server/*`, `*` all | helper's six |
| `skills` | skill names or patterns (`zig-*`), `*` all | `*` |
| `memory` | `shared` (pinned, top, recalled) or `pinned` | `shared` |
| `steps`, `tokens`, `seconds`, `answer_bytes` | per run (tokens: input, summed; answer: delegated runs) | `[limits]`; delegated: `[agents]` |
| `parallel` | most runs of it at once; 0: global limits only | 0 |
| `environment` | where its commands run unless a gap 2 pin applies; delegated runs take their parent's | `[default] env` (gap 2) |

The body is the instructions; at most 8 KB a file and 32 definitions.
Harness writes `saved: agent:NAME TIME (item N)` into one an agent saved.
Hand edits apply after `/reload`, as for `rules`; a file that doesn't
read is named with its line; on macOS and Linux `agents/` is refused if
other users can write it. `tasks.ini` gets `agent = NAME` per task
(default `main`).

Chat: `/agents` lists each definition (description, model, tools, where
used, who saved it, runs going, earlier versions). `/agent NAME` uses NAME
in this conversation from the next message on (`"agent"` in its line of
`state/conversations`, gap 4); `/agent` names the current one. `/ask NAME
text` sends one message to NAME's instance here, its answer marked
`[NAME]`. `/agent show NAME`; `/agent rm NAME` moves the file to
`state/agents/NAME/versions/`, refused for `main`, `helper` and a NAME a
task, trigger or workflow uses. `/stop NAME` stops NAME's runs. `/new`
gives every definition here a fresh history. CLI: `harness agent
list|show|rm`.

## Design

### Instances and runs

An instance is a definition in a conversation: its own context (gap 4's,
now one per definition in a conversation; gap 4's 16 kept count
instances) and a mailbox, taken one input at a time in arrival order.
Other instances run meanwhile, as the inbox lets several questions wait
(gap 5). A delegated task, a scheduled task, a trigger event (gap 6), a
workflow step (gap 7) and an app's run (gap 8) start a short-lived
instance: a clean context that ends with its answer, as helper and task
runs do today. A run loads its definition when it starts and keeps it.

Places to run extend today's slots and `Pool`: `[limits]
concurrent_runs` counts runs that are not delegated, one place always
kept for runs the owner started (today the chat keeps one); `[agents]
parallel` counts delegated runs; a definition's `parallel` caps its runs
of both kinds (a count per name in `Pool`, under its mutex).

### What a run may use

Tools: the definition's `tools`, within what the starter passes on. The
owner, a schedule, a trigger, a workflow, and an app for each `run:NAME`
its manifest lists (gap 8) pass all; an agent passes its own run's tools;
`tools` of a trigger, a workflow step (gaps 6, 7) or `delegate` narrow
further. Delegated runs never get `delegate`, `remember`, `skill_save`,
`send`, `ask_owner`, money tools, `web` or a setup tool (`agent_save` and
the others, overview), as helpers today and in gaps 4 and 5.

`delegate` takes `{"tasks":[{"task":"...","agent":"researcher",
"tools":[...],"strong":false}]}`; `agent` defaults to `helper`, `strong`
uses `[model] model`; its description lists the definitions (at most
4 KB); the gate's argument names each task's: `- [researcher] Find ...`.

The prompt's stable part: the body, harness's own lines (gate sentence,
scheduled-run note, delegate guide), skills per `skills`, memory per
`memory`; built-in bodies are today's prompts minus the gate sentence.

### Memory and other state

One memory, the owner's, shared by every definition: facts about the
owner and standing instructions must hold whoever acts. `memory:` decides
what a definition reads; writing needs `remember`; only the owner's
messages count as mentions. A definition's own state goes in workspace
files that roles (gap 3) can make its own. Per definition: grants, rules
section, roles; per run: version, tools, limits, browser session. Shared:
memory, skills (filtered), the Written list, money totals, MCP servers.

### Changes agents make

`agent_save` is a new tool, offered only in runs the owner started from a
conversation (as the `trigger` and `workflow` tools of gaps 6 and 7).
Input `{"name":"researcher","text":"<the whole file>"}`: a definition
that doesn't exist, or the run's own, never another. Checked first with
the same parser (name, keys, known tools, 8 KB); a file that fails goes
back to the agent, unasked. Gate kind `agent_save`, argument the name,
asked every time like money: no "Allow 24 h", no grant or `allow` rule
lifts it, a `deny` rule applies: a setup call (the overview's Shared
formats). The question (an inbox approval, gap 5)
says who asks, new or change, each header field that changes (old → new)
with those that widen first under "Widens:" (tools, MCP tools or skills
added; memory to `shared`; environment or model changed; steps, tokens,
seconds, parallel or answer_bytes raised), then the whole new file (12 KB
at most). On Allow the old file goes to `state/agents/NAME/versions/`
(the last 10, as apps keep theirs), the new one is written (temp file,
rename) with `saved: agent:NAME TIME (item N)`, and runs that start after
it use it, no `/reload` needed. `skill_save` keeps a replaced skill the
same way. So tools, model, memory and environment widen only by the
owner's answer, and rules and roles never: no tool writes those files
(an approved shell command on the host can: README "Same user, same
machine").

### Rules per definition or source

`rules` gets sections. Lines before the first header, or after `[all]`,
apply to every run, as today. A header is a who pattern (the overview's
Shared formats): `[agent:coder]`, `[owner]`, `[schedule:*]`,
`[trigger:mail]`, `[workflow:release]`, `[app:notes]`. For example
`[agent:coder]` then `allow shell zig build*`. For a call by definition
D, delegated by D1…Dk, in a run whose `by` is O (the same for the whole
chain):

1. hard limits, then roles (gap 3);
2. a matching `deny` in the shared part or in a section of D, D1…Dk or O;
3. listed sources (gap 6), money and setup calls (asked every time), as
   today's money;
4. a grant for this tool (and environment, gap 2) and key whose `who`
   (gap 5) is empty, `agent:D`, or matches O (the run's task, trigger,
   workflow or app);
5. the first matching `allow` or `ask` in D's section, then in O's, then
   in the shared part; a matching `ask` in a section of D1…Dk or O makes
   an allow from another section ask;
6. the tool's default; `ask` is deny where no one can answer.

D's own section may allow more for D, and O's for O's runs, as a grant
for O does; the sections of the definitions that delegated only narrow,
so none widens another by delegating. "Allow 24 h" now writes `who` =
`agent:D`, the definition that asked, as apps' grants carry `app:NAME`;
empty `who` (0.3's grants) covers any run.

### Data, code, log

`agents.zig` parses, checks and lists definitions, with the built-ins.
`Run` gets `def` and `who`, its tools computed when it starts. `Who`,
shared with gap 3 and built in phase 0: `{agent, by, parent: ?*const
Who}`, `by` the run's `by` (`owner`, `schedule:NAME`, `trigger:NAME`,
`workflow:NAME/STEP`, `app:NAME`; a delegated run's is its parent's).
`gate.Ctx` gets `who` (null: main started by the owner, so today's tests
stand); `rules.Rule` gets its section (both phase 0). In `core.zig`
mailboxes per conversation and definition replace the chat queue,
`baseRun` takes the definition, and `agents/*.md` join the watched and
guarded settings files. Log: a run's first line adds `agent` to gap 4's
`rid`, `run`, `by`, `conversation`; `gate` and `tool` lines add `agent`;
kind `agent`, events `saved` {name, by, agent, item, widens, sha256} and
`removed`.

### Other gaps

Gap 4: `by`, the conversation's `agent`, a context per instance; `send`
is a tool definitions can list (the conversation names its definition,
not the other way round). Gap 5: `agent_save` is an approval without
Allow 24 h, a setup call as gaps 2, 6, 7 and 8 have theirs (overview);
`who` on grants. Gap 6: a trigger's `agent` (default
`main`). Gap 7: an agent step names a definition. Gap 8: `run:NAME` in an
app's manifest. Gap 2: `environment`, after pins and workflow steps; its
`shell@NAME` rules and per-environment grants work in sections too. Gap
3: roles name `agent:NAME`.

## Platform notes

All three; definitions are threads, like helpers. `web` stays off on
Windows (`/agents` says so for a definition that lists it). Names are
lowercase, so volumes that ignore case change nothing.

## Tests

- `bad_definitions_are_named_with_their_line` (name not the file's,
  unknown key or tool, over 8 KB); `no_agents_folder_means_0_3`;
  `delegate_runs_the_named_definition` (prompt, model, tools, limits).
- `a_delegated_run_gets_no_tool_its_starter_lacks`, and never `delegate`,
  `remember`, `skill_save`, `agent_save`, `send`, `ask_owner`, money or
  `web`; `an_app_run_gets_the_definitions_tools`.
- `a_pinned_definition_sees_only_pinned_items`; skills per `skills`.
- `agent_save_asks_every_time_with_the_whole_file` (no day button; a
  grant and `allow agent_save *` don't lift it, a `deny` does);
  `agent_save_lists_what_widens_first`; it refuses another definition and
  a bad file (unasked), and is not offered to delegated, task, trigger,
  workflow or app runs.
- `an_allowed_change_keeps_the_old_file_and_applies_to_the_next_run`; a
  run already going keeps the version it started with.
- `a_definitions_section_allows_for_it_only`; a delegating definition's
  section denies and asks for its delegated runs but allows nothing for
  them; a `by` section (`[schedule:btc-watch]`) allows for that origin's
  runs; headers match the overview's who patterns.
- `a_day_grant_covers_the_definition_that_asked`; empty `who` covers all.
- `agent_command_switches_and_keeps_contexts_apart`; `/ask NAME` marks the
  answer; `one_instance_takes_one_input_at_a_time_in_order`;
  `owner_runs_keep_a_place_when_tasks_fill_the_rest`; `parallel` holds;
  `/stop NAME` stops only NAME; hand edits apply after `/reload`.
- smoke.sh: `/agent researcher`, a turn, `/agents`, an `agent_save` asked
  and allowed, the next run uses it, `log verify`.

## Calls I made

- Built-in `main` and `helper` reproduce 0.3; one shared owner memory, a
  definition's own state in files; instance = definition × conversation.
- A run's tools never exceed its starter's (no widening by delegating);
  delegated runs stay one level deep with today's exclusions.
- `agent_save` is asked every time like money, as gaps 2, 6, 7 and 8 ask
  for their parts (the overview's setup calls), and only from runs the
  owner started; replaced files kept. No hooks: code runs as `shell`
  calls.
- Rules sections: a definition's own may allow, and so may the run's `by`
  section; delegating definitions' only narrow. 24 h grants per
  definition, since every question names who asks.

Changed to fit the overview's Shared formats:

- `by` is the origin, the same down a delegation chain (a schedule is
  `schedule:NAME`, was `schedule:task/NAME`); `agent:NAME` names
  definitions and is never a `by`.
- A section matching `by` may allow (was: only D's could), as a grant for
  `by` already does; it still narrows D's allow with `ask`.
- Setup calls are approvals in every gap, so the note that gap 5 lists
  new definitions as setup items is gone; the log uses kind `agent`
  (`saved`, `removed`, was `config` events) and item numbers; the log
  field is `conversation` (was `conv`).

Settled (were questions for the owner):

- `main` may change its own definition and propose new ones (was question
  1): each change is asked in full, with what widens first.
- A definition that names no model uses `[model] model` when the owner, a
  schedule, a trigger, a workflow or an app starts it, `worker_model`
  when delegated (was question 2), as the key table says.
- `/ask NAME text` (was question 3; it was `@NAME text`): Telegram sends a
  message that starts with `@name` to a public inline bot of that name
  while it is typed, so `@researcher …` could reach a stranger's bot.

## Questions for the owner

None left: the three above are settled.

## Hosted note (sketch for the Windows session)

- Per customer a supervision tree: one process per instance (customer ×
  definition × conversation), started on its first input, asleep when
  idle; delegated runs as tasks linked to the parent's turn; one log
  writer per customer (the hash chain needs one). Elixir/OTP: a
  `Registry` keyed `{definition, conversation}`, a `DynamicSupervisor`
  of instances, a `Task.Supervisor` for delegated runs; a crash ends only
  that instance's turn. Durable Objects-like: an object per instance, its
  storage the journal, alarms for waits.
- Durable turns: each step (a model call; a tool call with the gate's
  decision) is journaled before it is acted on, its result after; a
  restarted instance replays the journal, redoing no finished step. One
  begun but not finished runs again if it is a model call or a read-only
  tool (read_file, search, fetch, recall, skill); any other is not run
  again, and model and owner are told it may have happened, as sent money
  calls count today. Masked output only. An open question is an inbox
  item (gap 5): the instance sleeps until its answer resumes the turn. A
  turn keeps the definition version it began with; a new version that
  crashes 3 times in 10 minutes is rolled back and the owner told.
- The Zig code: first one harness process per customer under a supervisor
  (instances stay threads); then `harness step` (one gated action from a
  JSON request; result and log line out) driven by the instance
  processes, so gate, tools and log stay one implementation.
