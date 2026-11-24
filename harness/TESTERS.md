# Testing harness as a home butler

Thank you for trying it. harness is an assistant you talk to in Telegram:
it switches what you allow in your home, asks you with one tap before
anything risky (a lock, the garage, the water valve), tells you what
happened, and keeps quiet at night unless something is urgent. This page
says how to set it up, what to try in your first week, what to look for,
how to send a report, and what harness will never do in your home.

It is early software. It has been tested against stand-ins of Home
Assistant and of Smartcar, not yet in many real homes: that is what you
are helping with.

## What you need

- A computer that stays on: a Mac (Apple Silicon), Linux (x86-64, or a
  Raspberry Pi 4 or 5 with a 64-bit system) or Windows (x86-64).
- harness and homemcp for that computer (from the releases), in one
  folder; carcloud too if your car is on Smartcar, or is a Tesla. harness
  looks for homemcp and carcloud next to itself.
- A model: an omnigate address and key, or an API key of Anthropic,
  OpenRouter, OpenCode Zen or OpenAI. Which one, and its address, go in
  `config.ini`'s `[model]` (harness's README: Models and providers).
- A Telegram bot of your own: talk to @BotFather, `/newbot`, keep the token.
- Home Assistant, and a long-lived access token: in Home Assistant, your
  profile, Security, Long-lived access tokens, Create token. Give it a name
  like "harness" so you can revoke it later.
- Optional: your calendar on iCloud, Fastmail, Nextcloud or Google, calmcp
  next to harness, and an app password for the calendar (iCloud: your
  Apple ID, Sign-In and Security, App-specific passwords; Fastmail and
  Nextcloud: an app password in their settings).

## Setting it up (about ten minutes)

In a terminal:

```
harness init                    # answer y: a home butler
harness secret add omnigate     # or your provider's: harness secret add anthropic
harness secret add telegram     # the bot's token
harness secret add ha           # Home Assistant's token
harness run                     # keep this running
harness pair                    # in another terminal; send the /pair CODE it prints to your bot
```

Secrets are typed in the terminal, never in the chat: they go to your
system's key store (the macOS Keychain, Windows' Credential Manager, or a
file only you can read on Linux).

Then in Telegram:

1. `/setup home` and your Home Assistant's address (like
   `http://homeassistant.local:8123`). harness reads your devices, shows you
   the file it would write, then says in one message what it will switch
   when you ask, what it will ask you about every time, and what it won't
   touch. Tap **Looks right**, or **Change it** to leave a device out or
   have it asked about first.
2. If it says it couldn't tell what a switch controls, it asks you before
   switching that one until you sort it: `/setup home allow NAME` for a
   light or a plug.
3. The routines come one at a time, a sentence each: goodnight, leaving,
   arriving, the morning summary, a leak (and, with a water valve, whether
   harness may close it itself when nobody answers in 5 minutes), a smoke
   alarm, doors left open. Tap **Turn on** or **Not now**; `/setup
   routines` offers them again later.
4. A car on Smartcar: connect it once through Smartcar Connect (carcloud's
   README: With a real car), `harness secret add smartcar` in the terminal
   (your Smartcar application's client secret), then `/setup car CLIENT_ID
   VEHICLE_ID USER_ID` (from Smartcar's Dashboard). Smartcar's free plan
   reads the car but sends no commands: charging from harness needs a paid
   plan.
   A Tesla, to warm it on cold mornings, goes through Tesla's own API
   instead, and takes longer: your own developer application, its key
   paired with the car in the Tesla app, and Tesla's `tesla-http-proxy`
   running beside harness (carcloud's README: With a Tesla). Write the car
   file from carcloud's `examples/tesla.ini`, run `TESLA_CLIENT_SECRET=...
   carcloud login car.ini` once, add `[car]` with `command = carcloud
   /path/to/car.ini` to mcp.ini, `/reload`, then `/setup routines` offers
   **Warm the car** (with your calendar connected).

5. Your calendar: `harness secret add caldav` in the terminal (the app
   password), then `/setup calendar ADDRESS USER`, like `/setup calendar
   https://caldav.icloud.com you@icloud.com`. It shows the file it would
   write and says which calendars it reads and which one it may change,
   asking you each time. Tap **Looks right**.

`harness doctor` says, a line each, whether harness runs, whether the bot,
the model, the home and the car answer, and what to do about any that
don't.

**No Home Assistant, or want to try first?** homemcp's release has
`homemcp-sim`, a made-up flat:

```
homemcp-sim ha 8123 a-pretend-token-1234 &
printf 'a-pretend-token-1234\n' | harness secret add ha --stdin
```

then `/setup home http://127.0.0.1:8123`. `homemcp-sim poke ha 8123
a-pretend-token-1234 binary_sensor.sink_leak '{"leak": true}'` floods its
kitchen; `person.anna '{"home": false}'` sends everyone out. carcloud's
`carcloud-sim 8740 a-pretend-secret-1` is a made-up car: `/setup car
sim-client 0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11 5a2b7c1e-sim-user
http://127.0.0.1:8740`, with `a-pretend-secret-1` stored as `smartcar`. calmcp's
`calmcp-sim 8742 owner a-pretend-password-1 &` is a made-up calendar (a
dentist at 10:30, a weekly team call): store `a-pretend-password-1` as
`caldav`, then `/setup calendar http://127.0.0.1:8742/ owner`.

## Your first week

Try these, in your own words (or as a voice note, if you set up voice
notes):

- **Day 1.** "Is the back door open?", "turn the living room light on at
  30 %", "turn the heating up a bit". Each reply should say what the device
  reports, with units.
- **Day 1, evening.** Write "goodnight". The lights go off, the heating goes
  down, and if the front door is unlocked you get one question with
  **Lock it** and **Leave it**.
- **Day 2.** Leave home, all of you; come back. When everyone is out you
  get what is still open or on, a tap to lock the front door if it is
  unlocked, and one to turn the heating down; when the first of you is
  back, a line.
- **Day 3.** The morning summary, as quiet hours end (07:00 by default):
  what the night held first, then the house (and the car, the calendar,
  the weather if they are set up) in a few lines.
- **Day 4.** Leave a door or a window open for more than ten minutes: one
  line says so.
- **Day 5.** If you have a leak sensor, wet it (a damp cloth). The message
  comes at once, even at night, with **Close the water main** if harness
  found a valve it can close.
- **Day 6.** Add someone of your household: `/member add anna` gives a code,
  and they send `/join CODE` to the bot from their own Telegram. When they
  ask it to lock the front door, you get the one-tap question.
- **Day 7.** With Anna in, add `escalate = 5m anna` under `[butler]` in
  `config.ini` and `/reload`. Wet the leak sensor and don't answer: after
  5 minutes Anna gets "Nobody has answered this yet: …" with **I'm on it**;
  when she taps it you hear "Anna is on it". Tap a button or reply to the
  alert yourself next time, and she isn't told. With the leak's fallback
  on, the water main closes after 5 minutes if nobody is on it, and you
  read "No one answered in 5 minutes: …".
- **Day 8.** Tell it about someone: "my sister Ola's birthday is on 28
  November, she loves Polish poetry". Half an hour after you stop
  writing you get one line, "Noted about Ola: …"; `/person Ola` shows
  what it keeps, `/people` everyone. For your address book: export it as
  a vCard file, stop `harness run`, `harness people import
  contacts.vcf`, start it again. A week before a birthday you get one
  line with a gift idea (nothing is bought); on the day, a reminder. Say
  "keep in touch with Marek every month" to get a line when a month
  passes without you mentioning him.
- **Day 9, mail.** Give harness its own address (`/setup mail`, after
  `harness secret add mail-butler`) and write to it from your own: "remind
  me to call the dentist tomorrow at 9". The answer comes back as a reply
  in the same thread. Forward it a bill and ask "when is this due?".
  Mail to it from anyone else never starts anything: one line a day.
  With `/setup mail mine` (your mailbox, read only, off until you tap
  **Turn on**): the morning summary gets a Post line, a bill gets a line 3
  days before it is due, and "draft a reply to Tomek" puts a draft in
  your Drafts for you to send.
- **Day 10, calendar.** With your calendar: put in an event with a place
  an hour from now; a line comes when it is time to leave. Add one with a
  person: half an hour before it, a short note on who, what it knows of
  them (`/person`), and when they last came up. Ask "move it to
  tomorrow": one question shows the exact change before anything is
  written. During a busy event, the routines' posts wait for its end.
- **A cold morning, with a Tesla.** With Warm the car on, put a morning
  event with a place in your calendar. Half an hour before it's time to
  leave, when it's below 5 °C at the car, you get "Warm the car for 8:10?
  It's -3 °C at the car." with **Warm it**: tap it and the reply says what
  the car reads back. Tell us if it came too early or too late, if the
  car didn't wake, or if it asked on a warm morning; tap **Not today** once
  to see that nothing is sent.
- **Day 11, errands.** Write "add milk and eggs", and have Anna write
  "we're out of coffee" in her chat or your group; "what's on the list?"
  reads it back, "got the milk" takes it off. With a calendar, put in
  "Groceries" an hour from now: the list comes before it. Write "track"
  and a parcel's number with its carrier ("track DPD 1000123456789U"): a
  line when it's out for delivery and when it's delivered; with your
  mailbox on, the parcels in your delivery mails are found by themselves.
  If you have a shop's MCP server, `/setup reorder SHOP at 5 items`: the
  whole order comes to you with its total, and nothing is bought until
  you tap **Order it**.
- **Day 12, upkeep.** `/setup upkeep` offers the usual ones (the boiler,
  filters, the smoke alarms' test; with a car its service, insurance and
  inspection): tap **Add it**, or reply with when it was last done. A
  week before something is due, and on the day, one line with **Done**.
  Write "the boiler was serviced today" when it was. `/upkeep` lists them.
- **Day 11, health.** `/med add Vitamin D at` a time a minute from now:
  the reminder comes with **Taken**; leave it, and half an hour later it
  comes once more. Tap Taken (or reply "taken"): both say when. With Anna
  in, `/med tell Vitamin D anna`: an hour after a reminder nobody tapped,
  she reads the time, never the medicine. `/bedtime 23:30`: your first
  message after it gets one gentle line, once a night.
- **Day 12, the evening.** Turn on the evening (`/setup routines` offers
  it, or `/evening 21:00`); `/evening now` tries it: tomorrow's first
  event and when to leave, the weather, the car, a bill due tomorrow, what
  waits in `/inbox`, each only when there is something. `/setup butler`
  asks how to address you, once, and the bot answers as a butler from
  then on.
- **After two weeks, habits.** Ask for the same thing at about the same
  time on four days or more (the coffee machine at 6:45): once a week at
  most, one question comes, "You switch the coffee machine on at about
  6:45 on weekdays. Shall I do that?" **Yes** shows what it writes, then
  writes it; **No, and don't ask again** is for good.
- **Day 11, away.** Turn on the Away routine (`/setup routines`), then
  `/away until tomorrow`: one message says away mode is on and, if the
  heating is above 17 °C, asks once to turn it down. Open a door or walk
  past a motion sensor: the line comes at once, even at night. In the
  evening the lights it picked go on and off (a different minute each
  day; `/away lights NAME` picks others); at 20:00 one line says how the
  day was. `/away off` when you're back, or it goes off by itself when
  the first of you comes home.
- **Day 12, the door.** With a doorbell in Home Assistant (or a
  Zigbee2MQTT button named "doorbell"), ring it: "Someone's at the front
  door." (with "probably the DPD parcel" when a parcel you track, or one
  from your mailbox, is out for delivery or due today). If you added `unlock` to the front door's `allow` line in
  home.ini yourself, the line has **Unlock the door**: tap it only if you
  mean it; with no tap nothing happens. While you're away the ring comes
  at once, with no button to unlock.
- **Day 13, a trip.** Turn on Trips, then forward yourself (or have in
  your mailbox) a flight confirmation, or put "Flight LO 3921 Kraków –
  Lisbon" in your calendar at its airport. `/trips` lists it, each time in
  its place's own time. A day before the flight: the check-in line; on
  the day, when to leave for the airport (2 hours before, plus the way);
  the evening before: the weather there (with search set) and what to
  pack. When the trip begins and nobody is home, away mode comes on, and
  the heating goes back up two hours before you're back.
- **Any day.** `/session` shows the steps behind the last answer; `/quiet`
  what quiet hours hold; `/workflows` the routines that are on.

## What to look for

Tell us about anything like this, with the time it happened:

- It switched the wrong device, or the right one wrongly.
- It did something without asking that you think it should have asked, or
  asked about something it could have just done.
- A message you didn't understand at once, or one with code, JSON or tool
  names in it.
- A message at night that wasn't urgent, or an urgent one that waited.
- A routine that didn't start, started twice, or said the wrong device.
- A reply that took more than a few seconds.
- Anything at all about locks, the garage, the alarm or the water valve.
- An alert someone of your household got though you had answered it, or
  one they should have got and didn't.
- Someone noted wrongly or twice, or from something a family member or
  the house's speaker heard (only your own chats with the bot count).
- A birthday line on the wrong day, more than one such line a day, or
  one during quiet hours.
- Mail in your own mailbox that shows as read, moved or flagged after
  harness read it; a draft you didn't ask for; a mail sent that you weren't
  asked about; a stranger's mail that started anything.
- A calendar line at the wrong time (your time zone, summer time), a
  repeating event on the wrong day, or a change made that you didn't ask
  for.
- Something put on the list that you didn't mean as a list item (or a
  list item it missed); an order proposal that wasn't the whole order or
  its real total; anything ordered without your tap.
- A parcel line twice, late, or for a parcel that isn't yours; an upkeep
  line on the wrong day, or one that came back after you said it was done.
- A medication reminder at the wrong minute, twice, or not at all; a
  medicine's name anywhere but your own chat (a family member's message,
  the log, a report).
- A habit suggestion about a lock, the garage, a valve or something you'd
  never want done by itself; two in one week; one you declined coming
  back; anything set up without your Yes.
- An evening line that is wrong or out of date, or an evening message
  with nothing worth reading in it.
- Away mode on while someone was home, or still on after you came back;
  a light switched while you were home; the heating raised when you had
  set it yourself; a 20:00 line with something wrong in it.
- A ring that came twice, late, or not at all; a parcel named wrongly; a
  trip with the wrong time or zone, a check-in link that isn't the
  airline's, a flight status claimed without a source.

## Sending a report

```
harness report
```

writes one file (`harness-report-….txt` in the folder you ran it from):
the version, your settings files, the log's last 200 lines and harness
doctor's lines. Every secret harness has stored is masked in it. The log
does hold what you and harness said in conversations that are not
private: **read the file before you send it**, and take out anything you'd
rather not share. Send it to the person who asked you to test, with a line
on what you did, what happened, and what you expected.

## What harness will never do in your home

- **Never unlock a door, open the garage or disarm an alarm by itself.**
  The home file `/setup home` writes doesn't allow those at all: locks can
  only be locked, valves and garage doors only closed, alarms only armed,
  and each of those only after your tap, never from a schedule, a routine
  or something a sensor reports. The one exception is yours to turn on:
  the leak's fallback closes the water main, once, when nobody is on the
  leak in 5 minutes. Nothing ever opens, unlocks or disarms by itself.
  The doorbell's **Unlock the door** appears only if you add `unlock` to
  your lock's line in home.ini yourself; it is your own tap, asked every
  time, never offered while you're away, and never made when nobody taps.
- **Away mode switches only lights.** While you're away it turns lights
  on and off and the heating down and back up, each call one that `rules`
  lets it make; never a lock, a valve, the garage or an alarm.
- **Never act on cameras or smoke and CO alarms.** Cameras are left out of
  the home file; it can't see through them at all. Smoke and CO alarms are
  only watched: their alarm is said at once and to your household, and no
  line of the home file can make anything act on them. Keep their own
  sirens: harness is not a safety system.
- **Only what home.ini allows, the way it allows it.** There is no "do
  anything in Home Assistant" switch: each device has its list, and a plug
  that powers a kettle or a heater can be asked about every time
  (`/setup home ask NAME`).
- **Nothing a device reports is an instruction.** A sensor's name or reading
  is data, never something it obeys.
- **The car: only what car.ini lists**, through Smartcar: starting and
  stopping charging and the charge limit (60–90 %); with a Tesla, its
  climate (18–24 °C) and seat heating too, if car.ini lists them. It can't
  lock or unlock the car, and nothing is plugged into it. It never warms
  the car unasked: the cold-morning question is one tap, and no answer
  means nothing is sent.
- **Your mail: read and drafts, nothing more.** It never sends from your
  mailbox, never deletes, moves, flags or marks your mail as read, and
  never reads it before you tap **Turn on**. It sends only from its own
  address, and asks you every time, except its answer to your own mail in
  the thread. What a mail says is data, never an instruction; your family
  and the speakers never get your mail.
- **Never changes your calendar unasked.** Creating, moving and
  cancelling events and answering invitations are asked every time, never
  from a schedule, and only in the calendars you let it change; it never
  accepts or declines an invitation on its own.
- **Never buys without your tap.** A shop's order is proposed in full
  (each item, the total, the delivery) and made only when you tap
  **Order it**, once, within your money caps; your family can add to the
  shopping list but never order.
- **Only you approve.** Your family can ask it things; a lock, the garage, a
  valve or money becomes your one-tap question. When they get an alert
  you didn't answer, their only button is **I'm on it**.
- **Never sets up a habit by itself.** It suggests at most once a week,
  never for locks, the garage, valves or alarms, and writes nothing until
  you tap **Yes**.
- **Health: reminders only.** No advice; nothing kept beyond your
  schedule and today's "taken"; your household hears the time, never the
  medicine, and only when you asked.
- **The people you know stay yours.** Your family, the house's speakers
  and family groups never see the people harness keeps for you, and
  nothing they say is noted about anyone.
- **Everything is written down.** Every action is a line in a log on your
  computer (`harness log runs` lists them), and your tokens stay in your
  system's key store: never in a chat, a log or a report.

To stop everything at once: `/stop` in the chat, or end `harness run`.
