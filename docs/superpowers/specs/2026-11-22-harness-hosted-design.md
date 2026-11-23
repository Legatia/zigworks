# harness hosted: one design from the three hosted notes

For the owner, from the Windows session (item 8 of
`harness/HANDOFF-windows-platform.md`). It joins the hosted notes at the
end of the agents (gap 1), file roles (gap 3) and environments (gap 2)
specs, the apps spec's hosted part (gap 8), and what omnigate already is,
into one design. No code. Binding where it repeats the overview
(`2026-11-22-harness-platform-overview.md`); new decisions are marked
**Proposed** and listed for the owner at the end.

## What the hosted version is

The same harness, run for a customer who has no machine to keep it on:
their agent answers in Telegram and in a browser, runs its schedules,
triggers and workflows, keeps its files, and never sees another
customer's. It is sold the way the owner decided on 2026-11-18: hosted
credit for individuals (paid through omnigate, like model use), licences
for companies who run it themselves. The harness binary stays free.

What stays from the local version: one gate, one log, plain files the
customer can download, the owner's answer for anything that matters, the
same settings files. What changes: where it runs (a VM per customer), how
its turns survive a restart (a journal), where its files live (a
customer's own filesystem), how commands run (sandboxes and cloned VMs,
never the instance's own host), and how it is reached (https, sign-in).

## The parts

```
 Telegram, browser ──https──▶ front (TLS, sign-in, routing) ──▶ customer VM
                                   │                              ├ harness (actors per agent instance)
                                   │                              ├ sandboxes (environments)
                                   ▼                              └ filesystem mount
                      control plane (Elixir, beside omnigate's)
                       accounts · billing · VMs · snapshots · secrets
                                   │
             omnigate (models, budgets) · object storage · metadata DB · secret store (keygate)
```

### The control plane

An Elixir/OTP application beside omnigate's control plane, sharing its
accounts, ledger and payments (Solana USDC credit today). It owns:

- Customers and their instances: create, upgrade, suspend, delete, export.
- One VM per customer instance (below): start, stop, snapshot, clone,
  remove, at harness's request over https with the instance's token, kept
  in the instance's key store.
- Spend: model calls already go through omnigate with a key per customer
  and its budget; VM time, cloned VMs and storage are counted the same
  way, and a spent budget refuses new clones and runs as omnigate answers
  402 today.
- The secret store: keygate's model (the agent gets placeholders, the
  value is added on the way out) for API keys, login values and folder
  variables; never in the customer's files.
- The front: TLS for `NAME.<hosted domain>`, sign-in, routing to the VM,
  Telegram webhooks (no polling), trigger webhooks (`POST /hooks/NAME`).

### One VM per customer instance

Harness and its data folder run in a VM of the customer's own
(Firecracker microVM or a cloud VM), so one customer's code, files and
memory never share a kernel with another's. Inside, `[default] env = box`:
every command runs in a sandbox (gap 2's bubblewrap backend), and runs
aren't offered `host`, so no command sees the instance's data folder,
keys or log. This answers the overview's question 3 for the hosted
version: sandbox by default, nothing to choose.

**Proposed:** start with cloud VMs from one provider in the EU (the
owner is in Poland; customers' data stays there), a small fixed size per
instance; move to Firecracker on rented machines once there are enough
instances to fill them.

### Agent instances as actors, with journaled turns

From the agents note. In the instance, a supervision tree:

- One process per agent instance (customer × definition × conversation),
  started on its first input and asleep when idle: a `Registry` keyed
  `{definition, conversation}`, a `DynamicSupervisor` of instances, a
  `Task.Supervisor` for delegated runs (helpers), linked to the parent's
  turn. A crash ends only that instance's turn.
- One log writer per customer (the hash chain needs one writer).
- Durable turns: each step (a model call; a tool call with the gate's
  decision) is written to the instance's journal before it is acted on,
  and its result after. A restarted instance replays the journal and
  redoes no finished step. A step begun and not finished runs again only
  if it is a model call or a read-only tool (read_file, search, fetch,
  recall, skill); any other is not run again, and the model and the owner
  are told it may have happened, as money calls are counted today. The
  journal holds masked output only.
- An open question is an inbox item (gap 5); the instance sleeps until
  its answer resumes the turn, across restarts.
- A turn keeps the definition version it began with; a new version that
  crashes 3 times in 10 minutes is rolled back and the owner told.

The Zig code stays the one implementation of the gate, the tools and the
log. First, one harness process per customer under a supervisor, as
today (instances are threads); then a `harness step` command (one gated
action from a JSON request; its result and log line out) driven by the
Elixir instance processes. The actors decide when; harness decides
whether, and does it.

### The customer's filesystem

From the file roles note. One filesystem per customer, shared by every
agent instance, sandbox and cloned VM of that customer:

- Contents in object storage (one bucket prefix and one encryption key
  per customer), the tree in a metadata database, mounted as POSIX where
  commands run (a JuiceFS-like FUSE mount), reached through a gateway by
  harness's file tools and apps.
- Roles move to the filesystem's front: each run gets a short-lived
  credential naming the customer, its definition, what started it and the
  run; the gateway checks `folders.ini` (kept by the control plane) on
  every open, create, rename and delete. A sandbox mounts only what its
  credential may read or write, read-only where it may only read, and
  can't widen it inside.
- Snapshots keep their format, on object storage: objects shared by a
  customer's snapshots, indexes in the metadata database. The gateway sees
  every write, a shell command's too, so the written-files list and
  snapshots become exact.
- Code, skills and agent definitions in a git repository per customer
  (history and review); files and apps in folders shared by `folders.ini`
  sections, shown in apps.
- Between instances: close-to-open consistency, the last writer wins,
  POSIX locks where tools need them.

### Environments: sandboxes and cloned VMs

From the environments note. Sandboxes run inside the customer's VM (gap
2). For work that wants a machine of its own, a new kind `cloud`: a
sibling VM made from a snapshot (a template, or another VM's checkpoint)
that the control plane makes, snapshots and removes at harness's request,
reached like `remote` (SSH with its own key), the customer's filesystem
mounted in it. N agents on M VMs. A cloud VM's own snapshots (`env clone
NAME ID`) are the machine's; the workspace's versions stay file roles'
snapshots. Each cloned VM's time is counted against the customer's
budget, and a spent budget refuses clones.

Machines at home behind NAT (the customer's own PC, with headdesk for a
desktop) need a connector that dials out to the front; it is the same
`remote` kind once connected. **Proposed:** after the rest.

### Apps

From the apps spec: an https address per instance; the customer signs in
(a passkey, or Telegram's login) and gets a session cookie instead of a
token in the link. Each app gets its own origin (`APP--INSTANCE` under a
separate apps domain), so the frame and CSP stay as they are locally.
Telegram: the bot's menu button opens the shell as a Mini App, and
`{app:NAME}` becomes a `web_app` button that opens the app in the chat;
the Mini App's `initData` is checked with the bot token's HMAC and the
owner's id. The front ends TLS and forwards to the app server on the VM's
127.0.0.1. This answers the overview's question 4 for the hosted version:
apps work on the phone.

### Models

Unchanged from today: every model call goes through omnigate with the
customer's key, routes and budget. Hosted credit is omnigate credit; the
VM, clones and storage draw on the same balance (**Proposed**), so a
customer sees one number.

## Isolation and what the operator sees

- A customer's code runs in sandboxes inside their own VM; their data is
  in their own bucket prefix under their own key, their secrets in the
  secret store, their models behind their own omnigate key.
- The operator can stop, start, snapshot and remove a customer's VM, and
  sees spend and health. **Proposed:** the operator does not read a
  customer's files, log or memory without the customer's explicit,
  logged permission for that support case; the control plane enforces it
  (a support grant with an expiry, written to the customer's log).
- Export: a customer downloads their data folder whole (files, settings,
  memory, log with its chain) and can run it on their own machine with the
  free binary.

## Failure and recovery

- A VM that dies is started again from its disk; actors replay their
  journals; open questions stay open; a turn's finished steps aren't redone.
- The filesystem's metadata database and object storage are the durable
  state; a VM's disk holds caches and the journal, which is replicated
  (**Proposed:** to object storage, a segment per minute and at each
  step's end).
- A crash loop in a definition rolls it back (above); a crash loop in the
  instance itself suspends it and tells the customer.
- Backups: object storage versioning for a customer's prefix, kept 30
  days (**Proposed**).

## Build order

Each step is usable alone.

1. **One instance per VM, no new code.** The control plane starts a VM
   with harness, its data folder on the VM's disk, Telegram by webhook
   through the front, models through omnigate. Sandboxes by default.
   Export and delete.
2. **Spend and suspension.** VM time on the omnigate balance; a spent
   balance suspends the instance and says so.
3. **Apps over https** with sign-in and the Telegram Mini App.
4. **The customer's filesystem** (gateway, roles at its front, snapshots
   on object storage), replacing the VM's disk for the data folder.
5. **Actors with journaled turns** (`harness step`), so a restart loses
   nothing and idle instances cost nothing.
6. **Cloned VMs** (`kind = cloud`), then the home connector.

## Questions for the owner

1. VMs: cloud VMs first (simple, more per instance) or Firecracker on
   rented machines from the start (cheaper at scale, more to run)?
   Proposed: cloud VMs first.
2. Where: the EU only at first? Proposed: yes.
3. One balance for models, VM time and storage, or separate prices?
   Proposed: one balance.
4. Support access: no access to a customer's files without a logged,
   expiring permission from them? Proposed: yes, enforced.
5. The home connector (a customer's own machine as an environment):
   build it, and when? Proposed: after cloned VMs.
