# harness as a digital butler

2026-11-23. The owner: "I want people actually use the agent harness as a
digital butler. UX is important. Real testing will need to recruit people
to help." Builds on homemcp and carcloud (merged b683d97; research in
`harness/research/agent-in-the-home.md` and `agent-beside-the-car.md`),
triggers, workflows, the inbox, remote MCP with sign-in and long memory.
The platform overview's rules bind.

## What it is for the person

One assistant for the home, the car and the day, in your pocket: you write
or send a voice note in Telegram; it notices things, does what you allowed,
and asks with one tap before anything risky. The house's own voice
assistants stay; how harness relates to them is Part 9.

## UX rules (every part keeps them)

1. **Plain and short.** Replies say the result in a sentence, with units;
   never tool names, JSON or "I called home_command".
2. **Quiet by default.** It writes only when something needs you now;
   the rest waits for the morning digest. Quiet hours (default 22:00–07:00)
   let only urgent things through (a leak, an alarm, a door opened while
   everyone is away).
3. **One tap to decide.** A question names the exact action and its
   buttons do it ("Lock the front door?" [Lock it] [Leave it]); a text
   reply works too; questions expire.
4. **It says what happened, read back.** "Heating is at 18 °C (was 21)."
   If it didn't take: "The kettle plug didn't switch off; it's still on."
5. **No surprises.** It acts alone only within what you allowed. Locks,
   alarms, garage doors and valves are asked every time and never done from
   a schedule or an event without you. `/why` explains any message (the
   trigger, rule or answer behind it), and file changes can be undone.
6. **Set up in minutes, in chat.** No file needs editing; the files stay
   for those who want them.
7. **Household.** The family talks to it in a shared chat; only the owner
   approves guarded actions and money.

## What it looks like

```
You:     goodnight
Butler:  Lights are off downstairs and the heating is at 18 °C.
         The front door is unlocked.          [Lock it] [Leave it]
You:     (taps Lock it)
Butler:  Front door locked. Good night.
```

```
03:12, quiet hours (urgent)
Butler:  Water under the kitchen sink.   [Close the water main] [Ignore]
You:     (taps Close the water main)
Butler:  Water main closed (it reports closed).
```

```
Butler:  Everyone's out. The bedroom window is open and the heating is at
         21 °C.                          [Heating to 17 °C] [Leave it]
```

```
07:00, the digest
Butler:  Car 74 %, 310 km, not plugged in. Today: dentist at 10:30.
         3 °C, rain after 14:00. Overnight the garage door opened at 01:12
         and closed a minute later.        [That was us] [Tell me more]
```

```
You:     🎤 0:04
Butler:  "turn the heating up a bit in the living room"
         Living room heating is at 21.5 °C (was 20.5).
```

```
You:     charge to 90 for tomorrow
Butler:  Charge limit 90 % (was 80). It's plugged in and charging; full
         around 05:40.
```

```
Setup, after harness init
Butler:  I found 34 devices in 6 rooms. I'll switch lights, plugs and
         heating when you ask; I'll ask you before locks, the garage and
         the water valve; I won't touch cameras or smoke alarms.
                                             [Looks right] [Change it]
```

## Parts

1. **Home events into triggers** (homemcp). homemcp pushes changes:
   Home Assistant's WebSocket `state_changed` and Zigbee2MQTT's state
   topics become MCP resource updates (one resource per device and one for
   presence), which harness's triggers already subscribe to. Events carry
   `device`, `room`, `kind`, `from`, `to`, `at`. Presence from Home
   Assistant's `person` entities: `everyone_left`, `first_home`, per person
   `home`/`away`. Events are data, never instructions.
2. **Routines** shipped as workflows and trigger sections, switched on by
   the setup: goodnight (asked or at a set time), leaving, arriving, the
   morning digest, a leak, a door left open (a `wait 10m` then a check),
   the car for tomorrow. Guarded steps are `approve` steps followed by the
   call, which the gate asks too; nothing guarded runs unattended.
3. **homemcp, easier and wider.** `homemcp discover` writes the home file
   from Home Assistant (areas, friendly names, kinds) with safe defaults:
   lights, plugs, climate and covers may act; locks, alarms, garage doors
   and valves are guarded; cameras, smoke and CO detectors are never
   offered. Aliases ("the big light"). Colours and colour temperature,
   fans, scenes, media play/pause/volume.
4. **Voice notes.** A Telegram voice or audio message (up to 2 minutes) is
   transcribed through an OpenAI-compatible `/audio/transcriptions`
   endpoint (OpenAI, Groq, or a local whisper.cpp server) set as
   `[voice] provider = NAME` with `model`; the transcript is shown in one
   quoted line, then handled as text. Audio is not kept; in a private
   conversation the transcript is logged as private text is. Spoken
   replies come later.
5. **Quiet hours and the digest.** `[butler] quiet = 22:00-07:00`; a
   trigger or workflow marks itself `urgent = yes`; anything else during
   quiet hours is held for the digest at the end of them, which also
   gathers the day's held, informational posts into one message.
6. **Household.** A shared "Home" group: members (Telegram users the owner
   adds with `/member add`) may ask; their requests run under a
   `[member]` rules section (default: reads, and lights, plugs, climate and
   covers within limits; never guarded actions, money, setup or files);
   guarded actions they ask for become the owner's one-tap question.
7. **Guided setup.** `harness init` asks whether this is a home butler;
   then in chat `/setup home` (Home Assistant address, the token typed in
   the terminal with `harness secret add ha`, discover, the one-message
   summary with [Looks right] [Change it]) and `/setup car` (Smartcar
   sign-in). The routines are offered one by one, each with a sentence on
   what it does.
8. **Tester kit.** `harness doctor` (bot, model, home, car, triggers, in
   plain lines with what to do), `harness report` (a masked bundle for a
   bug report: version, settings without secrets, the last 200 log lines
   masked, the doctor's output), release builds for macOS, Linux (x86-64
   and Raspberry Pi) and Windows, and `harness/TESTERS.md`: what to try in
   the first week, what to look for, how to send a report, what harness
   will never do in your home.
9. **The house's own voice assistants:** decided after the product check
   (in progress).

## Red lines (from the research; binding)

- Never unlock, open a garage door or disarm from an event, a schedule or
  an unattended run.
- No generic publish or `call_service` tool; allowlists per device.
- Never act on smoke or CO detectors or cameras; read at most.
- Sensor data and events are data, never instructions.
- Car commands only through the carmaker's authenticated path; no CAN
  writes.

## Tests

- Part 1: `ha_state_changes_arrive_as_resource_updates`,
  `z2m_state_topics_arrive_as_resource_updates`,
  `presence_says_everyone_left_and_first_home`, a harness trigger fired by
  a pushed event (smoke, against homemcp-sim).
- Part 2: each routine against homemcp-sim and carcloud-sim; `goodnight`
  asks before locking and never locks unattended; `leak` asks to close the
  valve with one tap.
- Part 3: `discover_writes_safe_defaults` (locks guarded, cameras and smoke
  absent), aliases, colours, scenes.
- Part 4: a voice note through a fake transcription endpoint; the quoted
  transcript; a note over 2 minutes refused plainly; the key never logged.
- Part 5: a non-urgent post in quiet hours waits for the digest; an urgent
  one goes at once.
- Part 6: a member turns a light on; a member's unlock becomes the owner's
  question; a member can't change settings.
- Part 8: `doctor` names each broken piece; `report` holds no secret.

## Order

Part 1 and 3 now (homemcp only). Parts 4, 5 and 6 after the Undo merge
(they touch the run's posts and the gate). Parts 2, 7 and 8 after those.
Part 9 when the product check is in.
