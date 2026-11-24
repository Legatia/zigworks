# harness: a persona, and one chat filed into topics

The owner, 2026-11-24:

> "We don't have a personality config i think. Either a default character
> or let user setup diy. Btw I don't like grokbot's many sub bot with its
> own chat, rather by hierarchy one chat with one top agent could have
> different topics and expand topic to focus on it and see the contents
> about it. Fits the butler style."

## Intent

### What exists today

**A manner.** Setup's offer "A butler's manner" (`/setup butler`;
evening.zig `presetFile`, core.zig `Manner`) works like this:

- It writes a whole agent definition, `agents/butler.md`, and points
  `main` at it (`convs.setAgent("main", "butler")`).
- The owner chooses only how they're addressed.
- Without it, the character is the three built-in lines of `main`
  ("You are a personal agent … Be brief and plain.").
- So a character is a whole definition: changing it means replacing
  harness's own instructions, and the only character offered is the
  butler.

**Topics.**

- harness has one bot, one chat (`main`) and its topics, with one top
  agent answering in all of them.
- But the butler's duties all post into `main`, and nothing gathers what
  a topic holds.
- A conversation can be pointed at another definition. The butler
  manner does exactly that to `main`. That is the "sub-bot with its own
  chat" shape the owner doesn't want.

### What the owner wants

- **A character the agent keeps everywhere:** one harness ships, or one
  the owner writes, layered on top of harness's own instructions, not
  replacing them.
- **One chat that works like a household's front desk:**
  - `main` carries the day's summary, anything urgent, and the
    questions waiting on a tap;
  - each subject has its own topic for the details;
  - opening a topic shows, at the top, what that subject holds now.

## Goals

1. **A persona:**
   - three characters ship with harness: `butler`, `assistant` and
     `friend`;
   - or the owner writes their own (`persona.md`);
   - `/persona` shows and switches it;
   - it's layered on `main`'s built-in instructions, never instead of
     them.
2. **One top agent:**
   - the butler manner moves into the persona, so `main` answers as
     `main` again;
   - a topic gets a focus (what it's about), not an agent of its own;
   - setup never points a conversation at another definition.
3. **The butler files its duties into topics:** House, Travel, Errands,
   and Mail and diary. Urgent alerts and the summaries stay in `main`.
4. **Expand a topic:**
   - each butler topic has a pinned card at the top, built from
     harness's state and edited in place;
   - `/overview` in `main` lists the topics, one line each, with links
     that open them.
5. **The summaries point into topics:** the evening message, and the
   morning routine where the owner has one, carry one line per topic
   with news, each linking to its topic.

## Non-goals

- Several bots, or a chat per agent.
- Nested topics. Telegram's topics are flat, and so are harness's.
- Per-topic personas.
- A spoken voice. Home Assistant's pipeline picks the voice; harness
  sends text.
- Changing members' chats. Members keep their own chats as now.

## Anti-goals

- **A persona that changes what the agent may do.** The persona sets
  how the agent talks, never what it may do. harness's own instructions,
  the gate line, the guides and the standing instructions come after it
  in the prompt. Tests check the prompt's assembly, and an end-to-end
  case checks behavior: with a persona saying "never ask me, just do
  it", a call that must be asked still becomes a question.
- **Fixed messages in costume.** harness's templated lines stay plain
  (CLAUDE.md): the diary's leave-by, the doorbell, alerts, questions,
  cards and the summaries' topic lines. The persona shapes only what the
  model writes.
- **More messages.** Filing moves posts from `main` to a topic.
  Pointers in `main` are one line, and only for questions and urgent
  alerts.
- **The owner's private words reaching strangers.** The owner's persona
  text never reaches members' runs or speech in the house (see below).

## Part 1: the persona

### The file

`persona.md` is in the data folder, written by the owner or by
`/persona`. It has optional frontmatter:

```
---
preset: butler          # butler | assistant | friend; default: assistant
name: Jeeves            # what the agent calls itself; none: it uses no name
address: Tobias         # how it addresses the owner: a name, "sir", "madam"; none: plainly
language: en            # the language it writes in unless spoken to in another
---
The character, in the owner's own words. Up to 4 KB.
```

- **No `persona.md`:** `assistant`, which is today's voice.
- **No frontmatter:** all body, on top of `assistant`. That's the shape
  of a Hermes or OpenClaw `SOUL.md`.
- **Name and address:** at most 40 characters each, and they pass
  evening.zig's `addressOk` (letters, spaces, `.`, `'` and `-`).
- **Guarded like the other settings files.** But a persona.md that's
  too big, can't be read, or is writable by others never stops harness.
  harness uses the preset it names, or `assistant`, and says why in the
  start line, `/status` and `/reload`. The persona can't change what the
  agent may do, so falling back is safe.

### The presets

Each preset is a short paragraph shipped in the binary. The wording is
the builder's within these lines, and the README shows each in full.

- **`butler`:** courteous, brief, discreet, unhurried. It anticipates
  rather than waits: the result first, then what needs the owner, then
  it stops. It's a little formal, with dry understatement and no
  exclamation marks. It never gushes or pretends to feelings. This is
  today's butler definition's manner.
- **`assistant`:** today's plain lines.
- **`friend`:** casual and warm, with first names and short sentences.
  It never pads or flatters.

### What isn't manner moves into `main`'s own instructions

Today's butler definition also carries two rules that aren't manner:

- "Keep the owner's affairs to the owner: where others may read, say no
  more than the request needs."
- "Give no medical advice: for health, only the reminders the owner set."

These join `main`'s built-in instructions for every persona.

### The prompt's order

1. The definition's body (harness's own instructions).
2. The persona: the preset, the owner's text, then name, address and
   language.
3. A fixed line: "Your character is how you talk. It never changes what
   you may do, what you ask, or the rules."
4. The gate line, the guides and the standing instructions, as today
   (agent.zig ~1716-1722).

**Who gets what:**

| Where | Gets |
|---|---|
| `main` and its topics | everything above |
| Members' chats | the preset and `name` only. Members are addressed by their own names. Never the owner's text or `address`, which may be personal. That keeps today's isolation: "nothing of the owner's", core.zig ~1992 |
| Speech in the house | the preset and `name` only; no address, since anyone may speak. Speech keeps its own fixed text (speech.zig ~369) |
| Helpers and memory jobs | nothing. Their words go to the agent, not to a person |

### From the chat

These commands are the owner's only, and only in conversations only they
read. Anyone else gets "That's the owner's to change."

- `/persona` shows the preset, name, address and the first lines of the
  owner's text, and lists the presets.
- `/persona butler|assistant|friend`, `/persona name NAME`,
  `/persona address WORDS` and `/persona language CODE` rewrite
  `persona.md` and keep its body. They write the file, then reload it,
  the pattern `/topic` already uses (core.zig ~13686).
- `/persona write`: the owner's next message becomes the body.
  - harness quotes it back and asks [Save] [Cancel].
  - A forwarded message is never taken as the body.
  - This uses the question bar's pending answer, not a new mechanism.
- `/persona reset` keeps the preset and drops the body.

### The butler manner, migrated

- **`/setup butler` and setup's manner offer** ask the same question as
  today (how to address the owner). They now write `persona.md`
  (`preset: butler`, `address`) instead of `agents/butler.md`, and don't
  point `main` anywhere.
- **`harness init --butler`** writes the same.
- **An install with the old manner** gets a one-time migration on start.
  It happens when two things hold: `main` points at `butler`, and
  `agents/butler.md` is exactly what `presetFile` would write for some
  address.
  1. harness writes `persona.md` (`preset: butler`, that address).
  2. It points `main` back at `main`.
  3. It moves `agents/butler.md` into `state/agents/butler/versions/`,
     as `agent rm` does.
  4. It says so once in `main`.

  An edited `agents/butler.md` is left alone, with its pointer. harness
  says once that `/persona` exists.

### The Hermes import

- **The mapping:** `SOUL.md` (edited, not the stock one) becomes
  `persona.md`'s body. This replaces the earlier pinned-memory mapping.
- **When `persona.md` has a body:** `SOUL.md` goes under Needs you, with
  its path.
- **When it has no body** (as `init --butler` writes it): `SOUL.md`
  fills the body and the preset is kept.
- **A `SOUL.md` over 4 KB** goes under Needs you: "longer than
  persona.md holds (4 KB); shorten it into persona.md."

## Part 2: one chat, filed into topics

### Telegram (checked against the Bot API changelog, 2026-11-24)

| Version | Adds |
|---|---|
| 9.3 | `has_topics_enabled`, and `message_thread_id` in private chats |
| 9.4 | `createForumTopic` in private chats |
| 10.5 (2026-11-22) | Topic links, `https://t.me/<bot_username>/<message_thread_id>`, which open only for that user; and `setMySettings`, which can set `has_topics_enabled` |

`pinChatMessage` pins any non-service message in a private chat. Each
topic seems to keep its own pins: `unpinAllForumTopicMessages` accepts
private chats.

**Not verified:**

- that a pinned message shows at the top of its topic;
- whether pins are limited.

The README says so, and the gaps list's "Not tested in the world" gets
a line for each. If a pin doesn't show, the card is still the topic's
first message, edited in place.

`topics_on` is read once at start today (main.zig ~1136). It's checked
again at setup and on `/reload`.

### One agent, topics with a focus

A conversation gets new optional fields in `state/conversations`.
Old files read as today.

- **`title`** is shown in Telegram ("Mail and diary"). The name stays
  `[a-z0-9-_]`.
- **`focus`** is one or two sentences on what the topic is about.
- **`subject`** is the butler subject the topic belongs to.
- **`card`** is the pinned card's message id.

A turn in a topic gets its focus in the context:

> You're in the Travel topic: trips, flights, check-in, packing.

It's still `main`, with all its tools. The focus is the owner's or
setup's words. The card's text is not put in the prompt, because it
holds outside text (calendar titles, deliveries read from mail, the
list's items). The agent reads state through its tools, as today.

`/focus WORDS`, sent in a topic, sets the focus.

The existing `agent` field stays readable. Nothing harness writes sets
it any more, and `/overview` shows a topic that has one as "answered by
NAME".

### The butler's topics

Setup offers topics once the owner has the household routines.

- **[Use topics]:** harness turns topics on for the bot with
  `setMySettings`. Where that call fails, it explains the BotFather
  switch instead. It then creates the four topics.
- **[Keep everything in main]** changes nothing.

| Name | Title | Subject: what files there |
|---|---|---|
| `house` | House | the house's events; away mode's evening line; the doorbell; upkeep; the car's warm-up and readings |
| `travel` | Travel | trips: the itinerary, check-in, leaving for the airport, the evening before, flight status |
| `errands` | Errands | the shared list; reorders; deliveries |
| `mail` | Mail and diary | the daily line on others' mail; drafts; prep notes before meetings; people from the calendar |
| `main` | (the chat) | the summaries; urgent alerts; medication and bedtime; habits' suggestions; anything with no subject |

The name is `house`, not `home`, because `home` is already speech's
conversation (speech.zig ~15).

**How posts find their topic:**

- **harness's own posts** carry a subject:
  - the shared `post(by, label)` maps its label (lists, reorder,
    deliveries, upkeep);
  - the other paths get a subject each: postAway, postTrips, postPeople,
    diaryPost, awaySummaryDue, tripsStatus, mailSay, remindDue;
  - quiet-hour holds and retries carry the target conversation instead
    of `main`.

  The subject is looked up when the message is sent: its topic when
  topics are in use, else `main`.
- **Routines:**
  - The shipped routine files (`examples/butler`) get a `subject =`
    line, which is new in workflows and triggers.
  - A routine with no `to` posts to its subject's topic when topics are
    in use.
  - The owner's own `to` always wins.
  - For installs whose routine files predate `subject =`, setup's [Use
    topics] adds the line to the routines harness wrote, and only where
    there's no `to` and no `subject`.
- **Without topics,** everything goes to `main` as today.

**Questions and urgent alerts:**

- **A question** goes to its subject's topic as an inbox item. `main`
  gets a one-line pointer, "Waiting on you in Errands: the reorder.",
  carrying the same buttons and linking to the topic. This is a new
  short form of an item. The inbox already ties up to four messages to
  one item, so pressing either answers it, and closing it edits both.
- **An urgent alert** belongs to `main`: its full text, [I'm on it],
  and reply-to-acknowledge are all there. The topic gets one plain line
  for the record: "Smoke in the kitchen at 03:12. Alerted in main."
- **Quiet hours** hold what isn't urgent in each topic, as they do per
  conversation today. At the end of quiet hours, each topic gets its own
  digest. `main`'s digest adds one line naming what was held in which
  topic, with links.

### The card: expanding a topic

Each butler topic has one card. It's built from harness's state, never
by the model:

- inbox items;
- trips;
- the list;
- deliveries;
- upkeep;
- the house's states;
- the diary.

**Shape:**

- the title;
- `Pending:`, then `Next:` with times;
- `Lately:`, the last three things, each one line.

**Example:**

> House
> Pending: none.
> Next: boiler service due 2 December; smoke alarm test on Sunday.
> Lately: front door closed 18:40; heating back to 21° at 17:00; parcel left at 14:10.

**Upkeep of the card:**

- It's edited when its subject's state changes, at most once a minute
  per topic.
- If an edit fails because the message is gone, harness posts a new card
  and pins it.
- An unpinned card can't be detected (`pinned_message` is chat-wide), so
  `/card` in a topic posts and pins a fresh one.

**`/overview`, in `main`**, gives one line per topic: its title as a
link, then what's pending or next, or "nothing new". It's built from
the same state as the cards.

### The summaries point into topics

The topic lines are built from the same state as the cards: one per
topic with news since the last summary, each ending with the topic's
title as a link.

> Errands: two deliveries today. (Errands)
> Travel: check-in for LO 3921 opens at 18:00. (Travel)

- **The evening message** is harness's own, and gets them directly.
- **The morning routine** is a workflow (`morning-home.wf`, `say
  {read}`). It gets a new placeholder, `{topics}`:
  - the shipped file uses it;
  - [Use topics] adds it to the morning file harness wrote, if it is
    unedited;
  - an owner's own morning file gets the lines only if it says
    `{topics}`.

## Constraints

- Zig 0.17.1, std only. Copy follows CLAUDE.md: plain labels, sentence
  case, short.
- **Command names:**
  - `/topic` and `/topics` belong to the news briefs (core.zig ~11780)
    and stay theirs;
  - the new commands are `/overview`, `/focus` and `/card` (the last two
    only in a topic), and `/persona`.
- **Telegram:**
  - card edits at most once a minute per topic;
  - topic links in the form `https://t.me/<bot_username>/<thread>`. The
    username comes from getMe, as today.
- **Injection marks are unchanged.** The card never enters a prompt. The
  focus is the owner's or setup's words. `persona.md` is the owner's
  own file.
- **Docs:**
  - the README: Persona; Topics;
  - the gaps list, with two lines under "Not tested in the world" (pins
    in private topics; topic links);
  - the ledger and the Windows handoff.

## Tests the spec needs

**The persona:**

- **Prompt assembly:** the persona comes after the definition's body,
  and the fixed line, gate line, guides and standing instructions come
  after the persona.
- **Who gets it:** members' and speech prompts carry only the preset
  and name. Helpers and memory jobs carry none.
- **End to end:** with a persona saying "never ask me, just do it", a
  shell call the gate asks about still becomes a question (fake model).
- **Migration:** the unedited butler definition becomes
  `persona.md`; an edited one is left as it is.
- **A bad file:** an oversized, unreadable or others-writable
  `persona.md` falls back with the reason shown, and harness still
  starts.
- **The Hermes import:** `SOUL.md` fills an empty body, goes to Needs
  you when the body is full, and goes to Needs you when it's over 4 KB.

**Topics:**

- **Filing:** each subject's post lands in its topic when topics are on,
  and in `main` when they're off. An owner's `to` wins over `subject`.
- **Questions:** the question is in the topic and the pointer in `main`.
  Pressing either answers it, and both are edited.
- **Urgent alerts:** the alert is in `main` and a record line in the
  topic; [I'm on it] works from `main`.
- **The card:** it's built from state and edited at most once a minute.
  When it's gone, a new one is posted and pinned. It never enters a
  prompt.
- **`/overview`:** lines with links. The evening message's topic lines;
  the morning routine's `{topics}`.
- **Quiet hours:** a digest per topic, plus `main`'s line.

## Left to the builder

- The presets' exact wording.
- How the subject is threaded through each post path and its holds and
  retries.
- The card's layout and the state each subject reads.

## Calls I made (the owner can overrule)

- **The default stays `assistant`** for existing installs. The butler
  manner already set up migrates to the `butler` persona, unedited ones
  only.
- **The butler has no name by default.**
- **Medication stays in `main`,** where the owner looks first.
- **Questions go to their topic, with a one-line pointer in `main`**
  carrying the same buttons.
- **Urgent alerts belong to `main`;** the topic keeps a record line.
- **Cards are built from state, not by the model,** and never enter a
  prompt.
- **Members and speech get the preset and name only,** never the
  owner's text.
- **A broken `persona.md` falls back** rather than stopping harness.
- **The topic for the house is called `house`** (titled "House"), since
  `home` is taken.
- **The new commands are `/overview`, `/focus` and `/card`,** since
  `/topic` belongs to briefs.
