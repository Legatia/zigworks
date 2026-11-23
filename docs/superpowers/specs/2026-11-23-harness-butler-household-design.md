# harness butler: away and travel, the door, errands, upkeep, health, habits, the car, the evening

2026-11-23. The owner: "Proceed" — the butler's remaining duties from
`2026-11-23-harness-gaps.md`. The butler spec's UX rules and red lines,
the duties spec and the platform overview bind. Every new line the
butler writes follows the UX rules (plain, short, one tap, read back,
quiet by default).

## 1. Away and travel

**Away mode** turns on when everyone has left for more than
`[butler] away_after = 12h`, when a trip is in the diary (a flight or a
hotel from mail or the calendar), or on `/away until DATE`; it turns off
at `first_home` or `/away off`. While away:
- the heating goes to the away temperature (asked once, at the start);
- lights the owner picks go on and off in the evening at times that vary
  by up to 30 minutes, so the house looks lived in (non-guarded devices
  only);
- any door, window or motion is urgent (escalation and announcements as
  for emergencies);
- deliveries and the doorbell are noted;
- one summary at 20:00: "All quiet at home. A parcel was left at 14:10.";
- before coming home (the arrival time from the itinerary, plus travel),
  the heating goes back up.

**Travel**: an itinerary per trip in `state/trips/` from mail (flight,
train, hotel confirmations) and the calendar, shown with `/trips`.
- check-in reminder 24 hours before a flight, with the airline's link;
- leave-by for the airport (the diary's leave-by);
- the evening before: destination weather and a packing list from the
  trip's length and weather;
- flight status: when a flight-status MCP server or page is set, a change
  (delay, gate, cancellation) is urgent; otherwise nothing is claimed;
- times shown in the place's own zone where the itinerary has it.

## 2. The door

homemcp gains doorbells (Home Assistant `event` and `binary_sensor`
doorbells, Zigbee2MQTT button actions) as watched devices that push
`ring`. A `doorbell` routine: "Someone's at the front door." to the owner
(and announced in the house when someone is home), with "probably the
DHL parcel" when a delivery is expected today. While away it is urgent.
[Unlock the door] appears only when the home has a lock: the owner's tap
is the owner's own request, asked as every guarded call; nothing unlocks
unattended and no camera is used.

## 3. Errands

**Lists**: shared lists (`shopping` by default) in `state/lists/`; the
owner and members add and remove by message ("add milk", "we're out of
coffee"), `/list`, `/list clear`; a list is posted on request, and before
a planned shop (a calendar event or a routine).
**Reorders**: a `reorder` routine per shop the owner sets up (a shop's
MCP server or web login): when a list reaches its size or a date, the
order is proposed in full and bought only after the owner's tap; money
caps and the money gate apply (always asked).
**Deliveries**: tracking numbers and carriers from mail and from the
owner's messages, in `state/deliveries`; the carrier's tracking page read
on a schedule; "out for delivery" and "delivered" lines; the doorbell's
hint.

## 4. Upkeep

`state/upkeep`: things with an interval — boiler service yearly, filters
every 3 months, smoke alarm test monthly, the car's service by distance
(carcloud's odometer) or date — and documents with an end date
(warranties, insurance, registration). A line a week before, one on the
day; [Done] resets the interval; "the boiler was serviced today" in chat
does the same. `/upkeep`, and setup offers the usual ones.

## 5. Health (reminders, no advice)

**Medication**: `/med add NAME at 08:00, 20:00`; the reminder with
[Taken]; not taken after 30 minutes, once more; optionally a household
member told after an hour (opt-in per medication). Nothing beyond the
schedule and "taken" is kept. **Sleep**: `[butler] bedtime = 23:30`
(opt-in): after it, the first message of the night gets one gentle line
("It's past half eleven."), never more than once a night. No medical
advice, no health data from devices.

## 6. Habits

Weekly, harness looks at what the owner asked the home to do: the same
non-guarded action at about the same time (within 20 minutes) on at least
4 days of the last 14 becomes one suggestion: "You switch the coffee
machine on at about 6:45 on weekdays. Shall I do that?" [Yes] [No, and
don't ask again]. Yes writes a routine, shown first. Never guarded
devices, never turned on unasked, at most one suggestion a week.

## 7. The car's heating

carcloud gains a Tesla Fleet API backend (the owner's own developer
application, OAuth sign-in, the virtual key paired once): `car_climate`
(on, off, temperature within limits) and seat heating, allowlisted in the
car file and rate-limited like the other commands. A `warm-car` routine:
before a leave-by on a cold morning (below `[butler] warm_below = 5 °C`),
"Warm the car for 8:10?" [Warm it]; the owner's tap makes the call.
Smartcar stays for other makes (no climate there). calmcp refuses tool
fields it doesn't know.

## 8. The evening

At `[butler] evening = 21:00` (or before quiet hours), one message:
tomorrow's first event and when to leave, the weather, the car's charge,
bills due, what waits in the inbox. And a `butler` definition preset the
setup offers: courteous, brief, discreet, calling the owner as they like.

## Not now

Messages to other people through WhatsApp, Signal or SMS (owner
question 5: which, given WhatsApp has no personal API); phone calls;
health data from devices; buying without the owner's tap.

## Tests

Each part: its lines at the right minute (fake clock), its taps, its
opt-ins off by default, members' and speech's limits, nothing guarded
unattended, the red lines (no camera, no unlock unattended), quiet hours
holding non-urgent lines; Tesla's calls against a stand-in; calmcp
refusing an unknown field.
