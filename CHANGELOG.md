# EasyWarCrates

## [v0.1.0](https://github.com/dazmagar/EasyWarCrates/tree/v0.1.0) (2026-09-26)
[Full Changelog](https://github.com/dazmagar/EasyWarCrates/commits/v0.1.0) [Previous Releases](https://github.com/dazmagar/EasyWarCrates/releases)

First release.

Tracks War Supply Crate drops in Midnight and predicts where the transport is
going to release one, while it is still in the air.

## Predicting

- **Reads the transport's heading** as it flies, matches it against known drop
  points, commits once one candidate clears the others, and pins it. Median
  error against where crates actually landed is about 0.1% of the map.
- **Two columns per zone**: when the transport appears, and when the crate is
  lootable. Cycle lengths, parachute times and the bias in the release estimate
  are all measured on your own client, and each is reported with how far out it
  could be.

## Shards

- **A timer belongs to one copy of a zone.** A countdown for a different copy
  is shown blank rather than confidently wrong, and the row says `new shard`.
- **A shard you have stood in before is remembered for a week**, so an
  evening's break does not leave the addon blind in zones it had already
  learned.

## Your raid

- **Reads other addons.** Sightings broadcast by Hated Crate Tracker,
  WarCrateTracker and CrateTrackerZK are picked up and used, ranked below what
  you saw yourself and labelled with who reported it.
- **Reads the countdown a raid leader posts** every cycle for every zone the
  raid is watching, so zones nobody here has flown to still carry a countdown.
- **A crate somebody watched land keeps its cycle** after the crate is gone.
- **Left-click a row** to post it to your group with a clickable waypoint. The
  tooltip names the channel before you click.

## Spectral Battle Chests

- Marked in Slayer's Rise as they appear, with coordinates and how long they
  have been lying there. Takes a row of its own when the zone has a crate to
  report too, so a click on either does what that row says.

## Quiet by default

- **The addon does not talk in chat** unless you turn it on, and never announces
  to a raid on its own. Everything it would have said is still written to its
  own log, and the `/ewc` commands always answer in full.

## Says what it does not know

- An unmeasured cycle, an unseen shard and a single-reading parachute time each
  say so instead of presenting a number. Where a figure has no source, the
  addon says whose guess it is.
- Zone names come from your own game. Announcer phrases are known in English
  and Russian; on any other locale `/ewc yells` reports what it heard instead
  so the gap is visible rather than silent.
