# EasyWarCrates

## [v0.3.0](https://github.com/dazmagar/EasyWarCrates/tree/v0.3.0) (2026-10-19)
[Full Changelog](https://github.com/dazmagar/EasyWarCrates/commits/v0.3.0) [Previous Releases](https://github.com/dazmagar/EasyWarCrates/releases)

The release where the addon stopped only listening to the other crate addons
and started reading the one line of theirs that carries a position, and where
what you watched yourself became the last word on it. Everything here came out
of evenings of farming, and most of it out of a disagreement between the window
and the ground.

## Reading the other crate addons

- **RCT's two map-pin lines are read, so a report arrives as a spot on the
  map.** Those are the only lines any rival sends that carry a position, and
  the pin carries the map id, so unlike their "Flying in" alert they cannot be
  lost to the sender's language. Six zones came in through them in one
  forty-minute session, and twice a timer this client had nothing for was taken
  from one of them.
- **One crate no longer arrives as three fresh ones.** RCT sends that line for
  the parachute, for the crate on the ground and again as somebody loots it, in
  identical words. The second and third used to start a new descent, which is
  why a row could still be counting down to a landing after the raid had the
  crate in their bags and flown on. Suppressed only for as long as that stage
  can last, because the next cycle is a different crate.
- **What you watched yourself is the last word on it.** Having seen a crate
  land and picked it up, nothing anybody else says can put that zone back to
  "landing". A report that is further along than your own sighting still counts
  -- you found it falling, they say it is already down -- and so does one about
  another copy of the zone.
- **Seeing the crate also ends a report that named no copy of the zone.** Their
  map-pin lines carry no shard, so the entry holding one sat under a key that
  the end-of-crate sweep was looking past. Measured on one Zul'Aman crate: the
  row counted 52 seconds past the landing.

## The window

- **The zone you are standing in always gets a row**, with the shard on it.
  Every row used to need something to have happened -- a timer of your own, a
  crate in the air, somebody's word, a zone on the route -- so after an evening
  away the one zone you are certainly interested in had nothing to put it on
  the list, and the shard, which is known from any vignette in sight, had
  nowhere to be shown. A row with nothing on it is still an answer: this is
  copy 44 of Zul'Aman and nothing is known about it.
- **What the hour is paying, along the bottom.**

      410 conquest/h  1240 honor/h   205 + 620 in 23m

  Read off the totals the game reports, so it is what the evening actually
  paid. Only rises count, because buying a piece of gear is not a negative
  wage; nothing under ten minutes gets a rate at all, because two crates in
  three minutes is one lucky sample wearing an hour's confidence; and a
  quarter of an hour without a sample ends the window, because an hour that
  contains a twenty-minute absence is not an hour of farming. The span is on
  the strip for the same reason: a four-figure rate over eleven minutes is one
  crate.

## Sharing with your group

- **`/ewc check` asks who is running this, and on which build.** The addon is
  silent until somebody sees a crate, so an empty window means either nobody is
  reporting or nobody has it installed, and that is not a question a leader can
  settle by looking. The roll call is ordered by what to do about each name:
  you, then who did not answer, then who is behind, then who is fine. Somebody
  with sharing switched off still answers and says so.
- **`/ewc export` and `/ewc import` hand the measurements to somebody else.**
  The parachute times per drop point as well as the points themselves, which is
  the part that takes dozens of observations to collect. Only world facts
  travel: timers and shards belong to one copy of a zone at one moment. An
  import never evicts readings you took yourself, and what arrives carries who
  it came from.

## Measuring

- **The parachute is timed at the drop point, not across the zone.** The file
  that does this carried a note saying the fall could not be predicted per
  spot, on the evidence of 98 and 129 seconds at what it believed was one
  place. Once the readings carried a position those two turned out to be 28% of
  the map apart, and every spot with more than one reading agrees to within
  three seconds. The variance was never in the fall, it was in the averaging.
  Zul'Aman's 46.9, 62.2 takes 129 seconds against a zone median of 92, so a
  per-zone figure was ending that countdown 37 seconds early.
- **`/ewc airtime` answers per drop point** where a spot has enough readings
  to answer with, and says which leg it measured where it has not.

## Announcements

- **Announce in the client's language, when your group wants it.** Off by
  default: an announcement is read by other people whose language this client
  cannot know. Nothing else moves -- the window, the settings and every `/ewc`
  answer stay English, because those are what a bug report is pasted from. A
  line nobody has translated falls back on its own rather than taking the
  message with it. `/ewc locale ruRU` previews the lot without installing that
  client.

## Midnight 12.1.5

- **A message whose sender the client will not let an addon read is refused,
  and counted.** 12.1.5 widens the secret-value mechanism, and one tainted
  sender used to kill the reader for all addon traffic in that event, not just
  for the message it arrived on. Counted because without a line saying "the
  client would not let us read who sent them", that reads as a quiet channel.
- Declares 120105 beside 120100. Nothing in the patch moves a crate: the Aqir
  invasions came to Eversong Woods and Zul'Aman, and the vignette ids and every
  rival addon's wire format are unchanged.

## Underneath

- **The addon's own log holds an evening instead of forty minutes.** A crate
  lying on the ground was writing the same line every two seconds, 221 of the
  420 lines it held, which is the difference between being able to answer a
  question about last night and not.
- **The store of announcer names this client cannot read keeps candidates, not
  every NPC who spoke.** It was 40 of 40 full of quest givers, which also means
  the name it exists for would have been dropped the day it finally spoke. A
  speaker now has to have spoken around the start of a cycle, and `/ewc yells`
  shows how far from the start each one was, which is what separates an
  announcer from somebody who happened to be talking.
- 454 specs, a syntax pass, a linter and a first-run harness that loads the
  whole addon under a stubbed client and runs every command.

## [v0.2.0](https://github.com/dazmagar/EasyWarCrates/tree/v0.2.0) (2026-10-03)
[Full Changelog](https://github.com/dazmagar/EasyWarCrates/commits/v0.2.0) [Previous Releases](https://github.com/dazmagar/EasyWarCrates/releases)

Mostly fixes, and two of them were stopping the addon doing the thing it is
for. Everything here was found by running it, not by reading it.

## The map pin

- **A drop point that repeats now gets a pin every time.** The game holds one
  map pin, and this addon was deciding whether to place one by remembering
  where it had last put one *per zone* -- so a pin placed in another zone since
  had quietly replaced it, and the next crate in the first zone went unmarked
  because the memory said a pin was already there. Voidstorm's drop point
  repeats, and three cycles running produced two pins. It asks the game where
  its pin actually is now.
- **No automatic pins while the tracker window is closed.** A closed window is
  you saying you are not doing this right now, and a pin takes the map marker
  and the minimap arrow with it. `/ewc pin` and clicking a row are you asking,
  and those still work with the window shut.

## The minimap button

- **Drawn by LibDBIcon.** It was hand-rolled, and any button organiser --
  Leatrix Plus, ElvUI, SexyMap -- hides a button whose name does not say
  LibDBIcon and stands its own in the place, which costs the tooltip. So the
  button vanished for anyone running one of those, and the countdown you hover
  it for went with it. It sits where it always did, and a position you dragged
  it to carries over.

## Sharing with your group

- **Where the transport is going goes out while it is still in the air.** Until
  now nothing left your client until the crate was already under its parachute,
  so somebody watching a transport cross a zone knew where it would land and
  said nothing -- the rest of the group first heard about the zone when the
  descent began. The predicted landing spot is shared the moment the call is
  firm, which is two to three minutes earlier, and it arrives as a row with a
  countdown that pins the spot when you click it. Only firm calls: a guess
  between two drop points on one line stays on the screen of whoever can watch
  it resolve.
- **A report says when the stage began, not when the message was sent.** Every
  re-send used to restart the receiver's descent countdown, so a parachute read
  as having just opened for the whole of its fall. Both clients need this
  version for it to help.
- **A crate you can see is not announced at you.** Somebody re-broadcasting the
  crate in front of you put a line in your chat every twenty seconds.
- **Reads CrateTrackerZK.** Its broadcasts were heard and not understood, so a
  group running it looked silent. Only the times it took from an NPC's shout
  are trusted, because its other timestamp is whenever somebody's client first
  drew an icon and that is not the start of a cycle.
- **Ten more spellings of the six zone names**, from German, French, Spanish
  and Russian clients, so their reports resolve instead of being dropped. One
  of those ten was not another language at all: a client that writes the
  curly apostrophe, which made `Zul'Aman` unreadable to this one.

## Measuring

- **How long a claimed crate stays lootable** is collected now. Nobody has
  published this, and the store that was meant to hold it had been empty since
  it was written: the sum needed the claim and the last sighting, and leaving
  the zone cleared both. Looting a crate and flying on now leaves a floor
  behind -- "at least this long" -- and standing until the marker goes gives
  the figure.

## Reading what it knows

- **`/ewc phase` lists the shards it can still answer with** and counts the
  rest in one line instead of printing a cycle count for each. One zone was
  showing eight records of which one was usable, which read like the zone had
  been lost.
- **`/ewc scan seen` keeps collecting.** Its record of untracked vignettes had
  filled with the ordinary contents of a Midnight zone -- rares, vendors, lore
  objects -- and was refusing everything new in silence. It no longer files
  those, says how many it skipped, and `/ewc scan` still shows every vignette
  in the zone whatever its art.
