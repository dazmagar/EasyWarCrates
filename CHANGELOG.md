# 0.1.0

First release.

Tracks War Supply Crate drops in Midnight and predicts where the transport is
going to release one, while it is still in the air.

- **Predicts the drop point** from the transport's heading, commits to a call
  once one candidate clears the others, and pins it. Median error against where
  crates actually landed is about 0.1% of the map.
- **Two columns per zone**: when the transport appears, and when the crate is
  lootable. Both from measurements taken on your own client.
- **Knows about shards.** A timer belongs to one copy of a zone, and a
  countdown for a different copy is shown blank rather than confidently wrong.
  A shard you have stood in before is remembered for a week.
- **Reads other addons.** Sightings broadcast by Hated Crate Tracker,
  WarCrateTracker and CrateTrackerZK are picked up and used, ranked below what
  you saw yourself and labelled with who reported it.
- **Marks Spectral Battle Chests** in Slayer's Rise with their coordinates and
  how long they have been lying there.
- **Says what it does not know.** An unmeasured cycle, an unseen shard and a
  single-reading parachute time each say so instead of presenting a number.
