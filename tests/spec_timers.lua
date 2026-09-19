local ns, t = ...
local Timers = ns.Timers

local T0 = 1000000
local INTERVAL = 1100

t.test("the first sighting of a zone and shard is new", function()
    local db = Timers.New()
    local verdict, entry = Timers.Record(db, 2444, 128, T0, "flying")
    t.eq(verdict, "new")
    t.eq(entry.ts, T0)
    t.ok(entry.precise, "a transport caught in the air anchors the spawn")
end)

-- The reason for keying on zone AND shard. RCT keeps one row per zone, so the
-- second shard overwrites the first and a raid rotating shards loses its
-- timers.
t.test("two shards of one zone are two independent timers", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    Timers.Record(db, 2444, 57, T0 + 400, "flying")
    t.eq(Timers.Get(db, 2444, 128).ts, T0)
    t.eq(Timers.Get(db, 2444, 57).ts, T0 + 400)
end)

t.test("the same crate sighted again does not move the timer", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    local verdict, entry = Timers.Record(db, 2444, 128, T0 + 90, "ground")
    t.eq(verdict, "duplicate")
    t.eq(entry.ts, T0, "a late ground sighting must not drag a flying catch forward")
    t.eq(entry.seen, 2)
end)

t.test("a better-anchored sighting of the same crate refines it", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0 + 120, "ground")
    t.notOk(Timers.Get(db, 2444, 128).precise)

    local verdict, entry = Timers.Record(db, 2444, 128, T0, "flying")
    t.eq(verdict, "refined")
    t.eq(entry.ts, T0, "the transport sighting is the better anchor")
    t.ok(entry.precise)
end)

t.test("news older than what we hold is dropped", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    local verdict, entry = Timers.Record(db, 2444, 128, T0 - 900, "flying")
    t.eq(verdict, "stale")
    t.eq(entry.ts, T0)
end)

t.test("a genuinely later drop replaces the entry", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "ground")
    local verdict, entry = Timers.Record(db, 2444, 128, T0 + INTERVAL, "flying")
    t.eq(verdict, "new")
    t.eq(entry.ts, T0 + INTERVAL)
    t.eq(entry.seen, 1, "a new crate starts its own sighting count")
end)

t.test("bad input is refused rather than stored", function()
    local db = Timers.New()
    t.eq(Timers.Record(db, nil, 128, T0, "flying"), "invalid")
    t.eq(Timers.Record(db, 2444, nil, T0, "flying"), "invalid")
    t.eq(Timers.Record(db, 2444, 128, "soon", "flying"), "invalid")
    t.eq(next(db), nil, "nothing should have been written")
end)

t.test("the next spawn lands one interval after the last one that passed", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    local e = Timers.Get(db, 2444, 128)
    t.eq(Timers.NextSpawn(e, INTERVAL, T0), T0 + INTERVAL)
    t.eq(Timers.NextSpawn(e, INTERVAL, T0 + 1), T0 + INTERVAL)
    t.eq(Timers.NextSpawn(e, INTERVAL, T0 + INTERVAL - 1), T0 + INTERVAL)
    t.eq(Timers.NextSpawn(e, INTERVAL, T0 + INTERVAL + 1), T0 + 2 * INTERVAL)
end)

t.test("a timer hours old still points at the next drop, not a past one", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    local e = Timers.Get(db, 2444, 128)
    local now = T0 + INTERVAL * 20 + 50
    t.eq(Timers.NextSpawn(e, INTERVAL, now), T0 + INTERVAL * 21)
    t.eq(Timers.Remaining(e, INTERVAL, now), INTERVAL - 50)
    t.eq(Timers.MissedCycles(e, INTERVAL, now), 20, "twenty drops nobody saw")
end)

t.test("a fresh timer has missed nothing", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    t.eq(Timers.MissedCycles(Timers.Get(db, 2444, 128), INTERVAL, T0 + 10), 0)
end)

t.test("an interval that makes no sense yields nothing, not a division blow-up", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0, "flying")
    local e = Timers.Get(db, 2444, 128)
    t.eq(Timers.NextSpawn(e, 0, T0), nil)
    t.eq(Timers.NextSpawn(e, nil, T0), nil)
    t.eq(Timers.Remaining(e, -5, T0), nil)
end)

t.test("sorted output puts the soonest drop first", function()
    local db = Timers.New()
    local now = T0 + 100
    -- Each dropped once, at a different point in the past, so each is a
    -- different distance into its cycle.
    Timers.Record(db, 2444, 128, T0,       "flying")  -- next T0+1100, 1000s out
    Timers.Record(db, 2437, 12,  T0 - 200, "ground")  -- next T0+900,   800s out
    Timers.Record(db, 2395, 77,  T0 - 900, "flying")  -- next T0+200,   100s out

    local list = Timers.Sorted(db, function() return INTERVAL end, now)
    t.eq(#list, 3)
    t.eq(list[1].zoneID, 2395)
    t.eq(list[2].zoneID, 2437)
    t.eq(list[3].zoneID, 2444)
    t.eq(list[1].remaining, 100)
    t.eq(list[2].remaining, 800)
    t.eq(list[3].remaining, 1000)
end)

-- A timestamp ahead of the clock is bogus data, not a crate. Timers is pure
-- maths and is not handed a "now", so it cannot police this -- it treats the
-- future stamp as the next drop and counts nothing missed, which is at least
-- harmless. Rejecting it belongs at the point data enters: the scanner, and
-- later anything arriving over the wire. Pinned here so that stays a decision
-- rather than something nobody noticed.
t.test("a timestamp from the future is carried, not corrected", function()
    local db = Timers.New()
    Timers.Record(db, 2444, 128, T0 + 500, "flying")
    local e = Timers.Get(db, 2444, 128)
    t.eq(Timers.NextSpawn(e, INTERVAL, T0), T0 + 500)
    t.eq(Timers.MissedCycles(e, INTERVAL, T0), 0)
end)

-- The respawn interval is the one number three separate addons disagree about
-- (1095, 1098, 1100) and none of them measured. The gap between two drops in
-- one zone on one shard is the only direct observation of it.
t.test("a second drop reports the gap to the first", function()
    local db = Timers.New()
    Timers.Record(db, 2512, 42, T0, "falling")
    local verdict, entry, gap = Timers.Record(db, 2512, 42, T0 + 1097, "falling")
    t.eq(verdict, "new")
    t.eq(gap, 1097)
    t.eq(entry.prevTs, T0, "the previous drop is kept, not just overwritten")
end)

t.test("a duplicate sighting is not a gap", function()
    local db = Timers.New()
    Timers.Record(db, 2512, 42, T0, "flying")
    local _, _, gap = Timers.Record(db, 2512, 42, T0 + 60, "ground")
    t.eq(gap, nil, "the same crate seen twice measures nothing")
end)

-- A timer seeded from a crate found already lying on the ground is dated to
-- when it was SEEN, which is any point after it landed. A gap measured against
-- that is not a cycle length. One such pair in Zul'Aman came to 1650 seconds,
-- which the cycle arithmetic read as two cycles of 825 -- a figure no zone has
-- and one that went straight into the countdown.
t.test("no gap is reported when either end was seeded from a crate on the ground", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 42, T0, "ground")               -- imprecise seed
    local _, _, gap = Timers.Record(db, 2437, 42, T0 + 1100, "falling")
    t.eq(gap, nil, "the first end says nothing about when that crate dropped")
end)

t.test("no gap when the LATER end is the imprecise one", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 42, T0, "falling")
    local _, _, gap = Timers.Record(db, 2437, 42, T0 + 1100, "ground")
    t.eq(gap, nil)
end)

t.test("two spawn-anchored ends do give a gap", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 42, T0, "falling")
    local _, _, gap = Timers.Record(db, 2437, 42, T0 + 1090, "falling")
    t.eq(gap, 1090)
end)

-- Real readings land within a few percent of a whole cycle. Something halfway
-- between is a pairing that means something else, and dividing it anyway
-- invents a per-cycle figure that looks like data.
t.test("a gap that is not close to a whole number of cycles is refused", function()
    local store = {}
    t.eq(Timers.NoteGap(store, 2437, 1650, 1100), nil, "1.5 cycles is not 2 cycles of 825")
    t.eq(Timers.NoteGap(store, 2437, 1925, 1100), nil, "nor is 1.75")
    t.eq(next(store), nil)
end)

t.test("a few percent off a whole cycle is still accepted", function()
    local store = {}
    -- The real spread measured live: 1054 to 1125 against an expected 1100.
    t.ok(Timers.NoteGap(store, 2437, 1054, 1100))
    t.ok(Timers.NoteGap(store, 2437, 1125, 1100))
    t.ok(Timers.NoteGap(store, 2437, 4344, 1100), "four cycles, a percent out")
    t.eq(#store[2437], 3)
end)

t.test("an observed gap is filed as it was seen", function()
    local store = {}
    local noted = Timers.NoteGap(store, 2512, 1097, 1100)
    t.eq(noted.gap, 1097)
    t.eq(noted.cycles, 1)
    t.eq(noted.per, 1097)
end)

-- The reason the bounds are wide. HGLog accepts an observation only between
-- 1090 and 1105, so its learning can confirm the figure it shipped with and
-- can never find a different one. A measurement that can only agree with the
-- assumption is not a measurement.
t.test("a gap outside the shipped interval is still recorded", function()
    local store = {}
    t.ok(Timers.NoteGap(store, 2512, 1042, 1100), "1042 must not be rejected for disagreeing")
    t.ok(Timers.NoteGap(store, 2512, 1160, 1100), "nor 1160")
    t.eq(#store[2512], 2)
end)

t.test("a gap that is obviously not one cycle is divided, not discarded", function()
    local store = {}
    local noted = Timers.NoteGap(store, 2512, 3300, 1100)
    t.eq(noted.cycles, 3, "three drops, two of them missed")
    t.eq(noted.per, 1100)
end)

t.test("nonsense gaps are refused", function()
    local store = {}
    t.eq(Timers.NoteGap(store, 2512, 30, 1100), nil, "half a minute is not a cycle")
    t.eq(Timers.NoteGap(store, 2512, 99999, 1100), nil)
    t.eq(Timers.NoteGap(store, 2512, nil, 1100), nil)
    t.eq(Timers.NoteGap(nil, 2512, 1100, 1100), nil)
    t.eq(next(store), nil)
end)

t.test("stats report the spread, not just an average", function()
    local store = {}
    Timers.NoteGap(store, 2512, 1095, 1100)
    Timers.NoteGap(store, 2512, 1100, 1100)
    Timers.NoteGap(store, 2512, 1105, 1100)
    local n, mean, lo, hi = Timers.GapStats(store, 2512)
    t.eq(n, 3)
    t.near(mean, 1100, 1e-9)
    t.eq(lo, 1095)
    t.eq(hi, 1105, "whether these cluster or scatter is the whole question")
end)

-- An observation spanning four drops carries a quarter of the detection error
-- of one spanning a single drop, so it is four times the evidence. Both of
-- these turned up live: a one-cycle Slayer's Rise gap of 1054s and a
-- four-cycle Harandar gap averaging 1086s.
t.test("a longer observation counts for more than a shorter one", function()
    local store = {}
    Timers.NoteGap(store, 2444, 1054, 1100)   -- one cycle
    Timers.NoteGap(store, 2444, 4344, 1100)   -- four cycles, 1086 each
    local n, mean, _, _, cycles = Timers.GapStats(store, 2444)
    t.eq(n, 2, "two observations")
    t.eq(cycles, 5, "but five cycles of evidence")
    t.near(mean, (1054 + 4344) / 5, 1e-9)
    t.ok(mean > 1075, "so the four-cycle figure pulls the mean towards itself")
    t.lt(mean, 1086, "without swamping the one-cycle reading entirely")
end)

t.test("a single-cycle observation is unweighted", function()
    local store = {}
    Timers.NoteGap(store, 2444, 1054, 1100)
    local _, mean = Timers.GapStats(store, 2444)
    t.near(mean, 1054, 1e-9)
end)

t.test("stats on a zone with nothing observed yield nothing", function()
    t.eq(Timers.GapStats({}, 2512), nil)
    t.eq(Timers.GapStats(nil, 2512), nil)
end)

-- The shard re-rolls every time you leave a zone and fly back, so entries pile
-- up for shards nobody will stand in again -- three Zul'Aman shards inside one
-- evening. They still predict their own shard correctly; the problem is that
-- returning to it is chance, so what they contribute is rows to read past.
t.test("timers too stale to matter are pruned", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 111, T0, "falling")
    Timers.Record(db, 2437, 222, T0, "falling")
    local now = T0 + INTERVAL * (Timers.STALE_CYCLES + 2)
    t.eq(Timers.Prune(db, function() return INTERVAL end, now), 2)
    t.eq(next(db), nil, "a zone left with no shards goes too")
end)

t.test("a timer still worth having survives the prune", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 111, T0, "falling")
    local now = T0 + INTERVAL * 2
    t.eq(Timers.Prune(db, function() return INTERVAL end, now), 0)
    t.ok(Timers.Get(db, 2437, 111), "two cycles stale is still usable")
end)

t.test("pruning mixed ages keeps the fresh and drops the dead", function()
    local db = Timers.New()
    Timers.Record(db, 2437, 111, T0, "falling")                              -- ancient
    Timers.Record(db, 2437, 222, T0 + INTERVAL * Timers.STALE_CYCLES, "falling")
    local now = T0 + INTERVAL * (Timers.STALE_CYCLES + 2)
    t.eq(Timers.Prune(db, function() return INTERVAL end, now), 1)
    t.eq(Timers.Get(db, 2437, 111), nil)
    t.ok(Timers.Get(db, 2437, 222))
end)

t.test("pruning an empty database is not an error", function()
    t.eq(Timers.Prune(Timers.New(), function() return INTERVAL end, T0), 0)
    t.eq(Timers.Prune(nil, function() return INTERVAL end, T0), 0)
end)

t.test("sorting an empty database is not an error", function()
    t.eq(#Timers.Sorted(Timers.New(), function() return INTERVAL end, T0), 0)
    t.eq(#Timers.Sorted(nil, function() return INTERVAL end, T0), 0)
end)

-- Zul'Aman reported a 989-second cycle against a true figure near 1090,
-- because both ends of the gap were crates already under their parachutes when
-- the player arrived. Each timestamp is late by however much of the fall had
-- already happened, and the gap inherits both errors.
t.test("a parachute joined partway through anchors no better than the ground", function()
    local d = Timers.New()
    local _, e = Timers.Record(d, 2437, 97, 1000, "midfall")
    t.notOk(e.precise, "it says a crate spawned some minutes ago, nothing more")

    local _, _, gap = Timers.Record(d, 2437, 97, 1000 + 989, "midfall")
    t.eq(gap, nil, "and two of them are not a cycle measurement")
end)

t.test("a parachute seen to leave the transport still measures the cycle", function()
    local d = Timers.New()
    local _, e = Timers.Record(d, 2437, 97, 1000, "falling")
    t.ok(e.precise)
    local _, _, gap = Timers.Record(d, 2437, 97, 1000 + 1090, "falling")
    t.eq(gap, 1090, "the case this must not break")
end)

t.test("a real sighting still overrides one joined mid-fall", function()
    local d = Timers.New()
    Timers.Record(d, 2437, 97, 1000, "midfall")
    local verdict, e = Timers.Record(d, 2437, 97, 1040, "falling")
    t.eq(verdict, "refined")
    t.eq(e.ts, 1040)
    t.ok(e.precise)
end)
