# EasyWarCrates

Tracks War Supply Crate drops in Midnight and predicts where the transport is
going to let one go, while it is still in the air.

Built for raids that farm crates on a rotation, and built around one idea: the
addon should tell you what it actually knows, and say so when it does not.

## What it does

**Predicts the landing spot from a moving transport.** It reads the
transport's heading as it flies and works out which catalogued drop point it is
aimed at, then drops a map pin. Live accuracy so far is a median of about 0.1%
of the map, and the call usually lands within five samples of the transport
appearing.

**Answers two questions per zone**, in two columns: when the transport will
appear, and when the crate will be on the ground. Both rest on measurements
this client took, not on figures shipped with the addon.

**Times the crate lifecycle instead of assuming it.** The flight from the spawn
to the parachute, the fall under the parachute, and the cycle between drops are
all measured per zone. Where a zone's readings disagree with each other, the
figure is borrowed from every zone pooled and the readout says so rather than
presenting a borrowed number as a measured one.

**Keeps timers per zone AND shard, and tells you when you are on the wrong
one.** This is the commonest reason a raid flies somewhere the timer says is
due and no transport comes: a timer belongs to a copy of the zone, and entering
a zone hands you a copy you did not choose. The crate is still there, its cycle
is simply at another point. A row whose timer came from another shard is marked
and explained.

**Listens to other players, including ones running other addons.** RCT
announces flying crates to raid chat in plain text and WarCrateTracker
broadcasts its sightings in the clear, so both are read with nothing installed
and nothing decoded. What other people report is held for the session only,
carries who said it, and is never written to disk. It is promoted into your own
timers at one moment: when you confirm the crate yourself.

**Anchors on the NPC who announces the cycle.** Vidious, Ziadan and Ruffious
announce a crate as it spawns. That is earlier than the transport becomes
visible and needs no addon on anybody else's machine. English and Russian
clients both.

**Lets you correct what it has learned.** Every measurement, timer and drop
point is listed in a panel and can be removed. Evidence that can only be
corrected from a command line does not get corrected.

## Using it

`/ewc` on its own says where you are and what the addon thinks about it.

| command | what it is for |
| --- | --- |
| `/ewc window` | show or hide the tracker |
| `/ewc config` | the settings panel |
| `/ewc data` | timers, measurements and the route, with a way to remove any of it |
| `/ewc route ZA HA SR VS` | set the rotation |
| `/ewc predict` | the live heading fit and what it resolves to |
| `/ewc points` | catalogued drop spots for this zone |
| `/ewc timers` | every timer held |
| `/ewc airtime` | measured parachute times |
| `/ewc interval` | measured gaps between drops |
| `/ewc comm` | what other players and their addons are broadcasting |
| `/ewc yells` | what the crate announcer said, and whether it counted |
| `/ewc scan` | every vignette in range, raw. Use this first after a patch |
| `/ewc shard` | cross-check the shard against a creature's GUID |

The settings panel holds eight switches and one button. Everything that is a
list of records lives behind that button.

## What it deliberately does not do

**It does not tell you when to set off.** That needed a table of capital-to-zone
flight times which were estimates by their own admission, and which drop point
a crate picks moves the number as much as which zone does. It was advice
wearing a number. You get when the transport arrives and when the crate is
lootable; the flying is yours.

**It does not keep other people's data.** No library is bundled, nothing is
synced to disk from strangers, and an evening's farming does not leave a wall
of rows for shards nobody will stand in again.

**It does not present a guess as a measurement.** A timer seeded from a crate
found already on the ground is marked. A descent borrowed from other zones is
marked. A countdown for another shard is marked. A prediction that is not firm
says so and names what else is still in the running.

## Building on it

```
.venv/Scripts/python.exe tests/run.py
```

264 specs, a syntax pass and a linter, run under a real Lua interpreter. Every
module that can be tested outside the game is: the heading fit, the prediction,
the timers, the measurements, the wire protocol and everything the window
draws. The files that create frames are kept as thin as they can be, because
nothing in them can be tested at all.

The linter exists for one bug this addon shipped: in Lua, calling a `local
function` declared further down the file is not an error, it is a nil call the
moment that line runs, which for an addon means in game, in combat, once.

Every check here has been shown red against the bug it guards and green again
afterwards. A check that has only ever passed has not been tested.

## Credits

The drop point catalogue is built from Wowhead's recorded spawns for object
290129. Vignette ids were cross-checked against RCT, WarCrateTracker and
CrateTrackerZK. Russian announcer phrasings come from CrateTrackerZK's locale.
Zone abbreviations follow WarCrateTracker (MIT, Copyright 2024 Samuel Colburn),
except that Eversong and Harandar are ES and HA here, because that is what
raids call out.

## License

MIT. Use it, fork it, ship it -- keep the copyright notice.
