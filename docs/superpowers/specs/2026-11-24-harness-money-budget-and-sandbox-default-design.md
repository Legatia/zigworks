# harness: automation moves money within a budget; unattended runs in a sandbox

The owner's answers, 2026-11-24, to two open questions (the platform
overview's questions 2 and 3):

> "Move money with a budget. Sandbox on priority"

- **Question 2 (money from automation).** Today it's built switched off:
  `[money] scheduled`, `triggers`, `workflows` and `apps` are all `off`.
  The answer is yes, within a budget.
- **Question 3 (the default environment for unattended runs).** Today
  it's the host, unless a `[use]` line pins a sandbox the owner defined.
  The answer is a sandbox, first.

This design was builder-checked against the code, and its answers are
folded in below.

## Part 1: money from automation, within a budget

### Today (agent.zig moneyCheck, gate.zig, core.zig)

- **Attended money calls:** asked every time, never granted. A member's
  or a room's is a one-tap item for the owner.
- **Unattended money calls:** refused, unless a switch lets that run
  kind spend. `scheduled` is the master switch; `triggers` and
  `workflows` follow it.
- **A switched-on spend:**
  - needs a cap (`max_per_call` or `max_per_day`, from `[money]` or the
    server's `mcp.ini` line). With no cap, moneyCheck refuses.
  - is refused by moneyCheck before the gate sees it, with no skipped
    item.
- **Counting:** the ledger keeps one total per server per day, and
  doesn't tell who spent it.
- **App-started runs are not unattended:** they can ask the owner. With
  `apps = on`, their money calls are asked.
- **Workflow tool steps** wait in the inbox for the owner.
- **The reorder** isn't a model run. harness quotes through the shop
  server, and orders as the owner after the owner's tap.

### What changes

1. **A budget for automation, counted on its own.**
   - **The keys:** `[money] budget_per_day` and `budget_per_month`, in
     the tool's amount units, like the caps.
   - **What they mean:** automation may spend only when at least one of
     them is above 0. Each one set above 0 limits its own period. A key
     not set, or set to 0, limits nothing on its own.
   - **Per server:** a money server's `mcp.ini` section may say
     `budget_per_day = N` and `budget_per_month = N`, which override
     `[money]` for that server, for setups with more than one currency.
     `none` there means automation spends nothing at that server. `0` is
     refused, as for the caps there.
   - **What counts where:**
     - automated spending counts against the budget, and against
       `max_per_day` and `max_per_call`;
     - the owner's own spending counts only against `max_per_day`.
   - **The ledger:** it adds lines and never changes today's. It keeps
     one line of automation spending per server per day, and one per
     server per month. The month lines are kept apart from the 64 daily
     slots, so the daily records can't push them out.
     - Today's reader treats a fourth field as damage, and damage
       refuses all money, so the new lines take their own first word.
     - A ledger from before this change reads as it does today.
2. **What may spend unattended.** All of these must hold:
   - the run is unattended: started by a schedule, a trigger, a
     workflow's agent step, or harness's own job that spends (the
     reorder, below);
   - its switch is on (`scheduled`, plus `triggers` or `workflows` for
     those runs);
   - the tool names an amount, and the amount is within `max_per_call`,
     `max_per_day` and the budget, today and this month;
   - automation spending isn't paused;
   - the run's outside-text mark names no source other than that same
     money server (see point 4).

   Anything else is refused, and becomes a skipped item with [Make this
   payment] (see point 5).
3. **Never unattended, whatever the budget:**
   - a money tool with no amount (`amount = …:none`), such as
     `home_guarded`'s door unlock and water main;
   - `mail send`. The gate's mail check comes first and stays first.

   These are refused unattended, as today. No budget, rule or switch
   lifts that, and a test pins it.
4. **Outside text doesn't spend.**
   - **Refused, whatever the budget:** an unattended money call in a run
     whose mark names any source other than the money server it's paying
     through. That means a page, a feed, mail, the calendar, another
     server, a forwarded message or history.
   - **Allowed:** the server's own results, such as the shop's quote
     before its order. Without that, a routine could never price and
     then buy. The shop's own text steering spending at that same shop
     is the risk left, and the budget bounds it.
   - **Where it's checked:** in moneyCheck, which runs before the gate
     and has the run, `Run.outside()`.
   - **A new injection case:** a feed tells an unattended trigger run to
     pay. It's refused, and becomes a skipped item.
5. **The owner's tap: [Make this payment].** A refused unattended money
   call becomes a skipped item with that button. Refused means a marked
   run, no budget, over budget or paused.
   - The item shows the whole call (tool, every argument and the amount),
     and why it was refused.
   - Pressing it makes exactly that call as the owner. The tap is the
     owner's answer, so money is still asked every time.
   - It needs a new skipped-item action, like the reorder's OrderGo.
     Today a skipped money item offers only Dismiss.
6. **The reorder spends within the budget.** With a budget set, the
   reorder job runs as `harness:reorder` under the `scheduled` switch.
   - **Ordering:** when the quote's total is within the budget and the
     caps, it places the order through moneyCheck and the gate, then
     tells the owner.
   - **Over budget, or no budget:** it proposes the order for the
     owner's tap, as today.
7. **Every automated spend is told.** One line goes to `main`, not
   silently, and not held in quiet hours:

   > Spent 12.50 on shop/order for the weekly-groceries task. Today 12.50 of 30; this month 40 of 200.

   It has a [Pause automation spending] button.
8. **`/money` (the owner only, in their own conversations):**
   - `/money` shows the caps, the budgets, what's spent today and this
     month (by the owner, and by automation), the switches, and whether
     spending is paused.
   - `/money budget N a day` and `/money budget N a month` write
     `[money]` and reload.
   - `/money pause` and `/money resume` stop and restart all automation
     spending, kept in state across restarts. While paused, an
     unattended money call is refused with the reason, and becomes a
     skipped item.
9. **Switches:**
   - `scheduled`, `triggers` and `workflows` default to on. With no
     budget set nothing moves, so this changes nothing until the owner
     sets one.
   - `apps` stays as it is, off by default. App runs can ask the owner,
     so their money calls are asked when it's on, and no budget applies
     to them.
10. **Installs that spend today** (`scheduled = on` with a cap, no
    budget keys) get `budget_per_day` set from `max_per_day` at the
    first start after the upgrade. They're told once in `main`, so
    nothing that spent today stops without a word.

### Setup

- **`/setup` for a money server** asks once: "How much may routines
  spend without asking you, a day and a month?" The answers are [None],
  [Set an amount] and [Like this: 30 a day, 200 a month].
- **The butler's reorder** behaves as point 6 says.

## Part 2: unattended runs in a sandbox

### Today (environments.zig, agent.zig, core.zig)

- **The environment** is a `[use]` pin over the run's `by`, else the
  workflow step's environment, else the definition's, else
  `[default] env` (`host`).
- **The `env` field:** a run's shell tool offers it, listing every
  environment, `host` included, whenever environments exist. A rule
  `allow shell *` matches every environment.
- **harness's own `harness:` jobs** run no shell.
- **Workflow tool steps** pick a pin, else the step's `env`.

### What changes

1. **A built-in sandbox, `sandbox`:**
   - `kind = sandbox`, `workspace = rw`, `network = off`;
   - like every sandbox, it can't read the data folder or the home;
   - an owner's own `[sandbox]` section in `environments.ini` replaces
     it. It must be `kind = sandbox`, or the file is refused with that
     reason.
2. **`[default] unattended`**, a new key, defaults to `sandbox`. An
   unattended who is `schedule:`, `trigger:` or `workflow:`, workflow
   tool steps included; `who.unattended()` is what decides. Its run
   gets:
   - its environment from the same order, with `[default] unattended` in
     place of `[default] env`;
   - a shell tool whose `env` field leaves `host` out, unless a pin,
     the step, the definition or `[default] unattended` names `host`
     itself. The model can't choose the host for an unattended run.
3. **Runs keep `[default] env` (`host`):** the owner's, members',
   rooms' and app-started runs. Apps can ask the owner, so they aren't
   unattended.
4. **Where no sandbox can run here,** the shell calls of an unattended
   run whose environment is a sandbox are refused, never run on the host
   instead. Linux without bubblewrap is one case.
   - Each refused call says why, in the log and as a skipped item.
   - `harness doctor` and the start line say how to fix it: install
     bubblewrap, or set `[default] unattended = host`.
5. **The owner's shell tool:**
   - with the built-in sandbox there are always environments, so it now
     lists them, and its description changes (the test at agent.zig
     ~7104 changes on purpose);
   - its default stays `host`.
6. **Upgrading,** at the first start after it. A marker,
   `state/upgrades/sandbox-default`, is written once the line is said.
   - **When the line is said:** an install has a rule allowing `shell`
     under an unattended who's section, or `[all]` or the shared part;
     or a `shell@host` rule; or a host grant held by an unattended who.
   - **The line:**

     > Commands that routines run now run in a sandbox: no network, no
     > home folder.

     Then, for each kind found, how to keep it on this machine:
     `[use] schedule:NAME = host`, `trigger:NAME` or `workflow:NAME`.
     And when an owner's `[sandbox]` section already exists: "Your
     [sandbox] section is now what routines run in."
7. **Only shell runs in an environment.** Fetch, MCP tools and the rest
   are harness's own calls and are unchanged.

### Who builds what

The Windows session owns environments and the sandbox runners. Part 2
goes to them through the handoff. The Mac session builds Part 1, and
tests Part 2 on macOS (sandbox-exec) after they push.

## Constraints

- Zig 0.17.1, std only. Copy follows CLAUDE.md.
- Money stays the strictest path:
  - every unattended money decision is logged with the budget's
    numbers;
  - the ledger is written whole;
  - a ledger that can't be read or saved refuses money calls (today's
    rule).
- **Tests that change on purpose:**
  - config.zig ~1165, ~1378 and ~1396: the switches' defaults; ~1385 and
    ~1403 follow;
  - the agent.zig fixtures that build `Money` from struct literals with
    `false` defaults;
  - the shell tool's description test at agent.zig ~7104.
- **Tests, Part 1:**
  - **Budgets:** none refuses; a budget spends within it and refuses
    past it, per day and per month; a server's budget overrides
    `[money]`'s; `none` at a server; the owner's own spending counts
    only toward `max_per_day`.
  - **Never unattended:** a no-amount money tool (the door unlock) and
    `mail send` are refused unattended with a budget set.
  - **Outside text:** a run marked by a page is refused; a run marked
    only by the same shop's quote spends.
  - **The tap:** [Make this payment] makes exactly that call as the
    owner.
  - **The reorder:** it orders within the budget, and proposes over it.
  - **Telling and pausing:** pause and resume, kept across restarts;
    the told line, and its button pausing; `/money` and `/money budget`.
  - **Old installs:** the upgrade sets a budget from `max_per_day`; a
    ledger from before this change still reads.
  - **Injection:** the new case (a feed asking an unattended trigger
    run to pay); case 6 unchanged.
- **Tests, Part 2:**
  - **Defaults:** unattended whos default to `sandbox` (workflow tool
    steps included); the owner's, members', rooms' and apps' runs default
    to `host`.
  - **Who wins:** a pin, a step or a definition wins.
  - **The env field:** an unattended run's `env` field has no `host`
    unless named.
  - **No sandbox:** a refusal, never the host.
  - **The owner's section:** `[sandbox]` must be `kind = sandbox`, and
    it replaces the built-in.
  - **Upgrading:** the line, once per marker; its suggestions per kind.
- **Docs:** README (money; environments), the overview's questions 2 and
  3 marked answered, the gaps list, the ledger, the Windows handoff.

## Calls I made (the owner can overrule)

- **Budgets are separate from caps.** Automation spends only when a
  budget above 0 is set.
- **A money tool with no amount is never unattended,** whatever the
  budget: door unlock, water main and `mail send`.
- **Outside text doesn't spend.** The paying server's own results are
  the one exception, so price-then-buy works.
- **A refused payment becomes a tap** ([Make this payment]) that shows
  the whole call.
- **Every automated spend is told in `main`,** with a pause button, even
  in quiet hours.
- **Apps aren't budgeted.** They can ask, and their money stays asked.
- **Installs that spend today keep spending:** their budget comes from
  `max_per_day`, and they're told.
- **The built-in sandbox has network off.** The owner turns it on in
  their own `[sandbox]` section.
- **Unattended runs can't pick the host.** With no sandbox available,
  their shell calls are refused, never run on the host instead. Opting
  out is one line.
