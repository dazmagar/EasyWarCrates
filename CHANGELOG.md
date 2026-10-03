# EasyWarCrates

## [v0.2.0](https://github.com/dazmagar/EasyWarCrates/tree/v0.2.0) (2026-10-02)
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
