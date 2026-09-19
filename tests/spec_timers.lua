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

t.test("sorting an empty database is not an error", function()
    t.eq(#Timers.Sorted(Timers.New(), function() return INTERVAL end, T0), 0)
    t.eq(#Timers.Sorted(nil, function() return INTERVAL end, T0), 0)
end)
