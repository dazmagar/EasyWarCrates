local ns, t = ...
local Model, Timers = ns.Model, ns.Timers

local ZA, HD, SR, VS = 2437, 2413, 2444, 2405
local T0 = 1000000

local function db(...)
    local d = Timers.New()
    for _, e in ipairs({ ... }) do
        Timers.Record(d, e[1], e[2], e[3], e[4] or "falling")
    end
    return d
end

local function byZone(rows)
    local out = {}
    for _, r in ipairs(rows) do out[r.zoneID] = r end
    return out
end

t.test("with no route, every timer is shown soonest first", function()
    local rows = Model.BuildRows(db(
        { ZA, 1, T0 - 100 },   -- due in ~1000
        { VS, 2, T0 - 900 },   -- due in ~200
        { HD, 3, T0 - 500 }), nil, T0)
    t.eq(#rows, 3)
    t.eq(rows[1].zoneID, VS)
    t.eq(rows[2].zoneID, HD)
    t.eq(rows[3].zoneID, ZA)
    t.notOk(rows[1].inRoute)
    t.eq(rows[1].leaveIn, nil, "leave-in only means something for a rotation")
end)

t.test("a route is planned and comes first", function()
    local rows = Model.BuildRows(db(
        { ZA, 1, T0 - 900 },
        { VS, 2, T0 - 100 }), { VS }, T0)
    t.eq(rows[1].zoneID, VS, "the route zone leads even though its drop is later")
    t.ok(rows[1].inRoute)
    t.ok(rows[1].leaveIn, "a route row answers when to set off")
    t.ok(rows[1].status)
    t.eq(rows[2].zoneID, ZA, "and what is off-route is still shown")
    t.notOk(rows[2].inRoute)
end)

t.test("a route zone with no timer keeps its place", function()
    local rows = Model.BuildRows(db({ ZA, 1, T0 }), { ZA, SR }, T0)
    local by = byZone(rows)
    t.ok(by[SR], "the rotation keeps its shape where nothing is known")
    t.eq(by[SR].status, "unknown")
    t.eq(by[SR].remaining, nil)
    t.eq(by[SR].fraction, 0)
end)

t.test("the row worth acting on is identified", function()
    local _, nextRow = Model.BuildRows(db(
        { VS, 1, T0 - 1070 },   -- drops in 30s, too soon to reach
        { ZA, 2, T0 - 700 }), { VS, ZA }, T0)
    t.ok(nextRow)
    t.eq(nextRow.zoneID, ZA, "not the one that drops soonest, the one you can reach")
end)

t.test("nothing reachable means nothing is singled out", function()
    local _, nextRow = Model.BuildRows(db({ VS, 1, T0 - 1090 }), { VS }, T0)
    t.eq(nextRow, nil)
end)

-- RCT draws a timer nobody has confirmed for hours exactly like a live one,
-- which is how its Eversong countdown goes on promising drops that do not come.
t.test("a timer nobody has confirmed for cycles is marked stale", function()
    local fresh = Model.BuildRows(db({ ZA, 1, T0 }), nil, T0 + 100)
    t.notOk(fresh[1].stale)
    t.eq(fresh[1].missed, 0)

    local old = Model.BuildRows(db({ ZA, 1, T0 }), nil, T0 + 1100 * 6)
    t.ok(old[1].stale, "six missed cycles is extrapolation, not knowledge")
    t.eq(old[1].missed, 6)
end)

t.test("a timer seeded from a crate already down is marked imprecise", function()
    local rows = Model.BuildRows(db({ ZA, 1, T0, "ground" }), nil, T0 + 10)
    t.notOk(rows[1].precise, "its timestamp is when it was seen, not when it dropped")
end)

t.test("the bar fills across the cycle", function()
    local interval = ns.GetZoneInterval(ZA)
    local start = Model.BuildRows(db({ ZA, 1, T0 }), nil, T0)
    t.near(start[1].fraction, 0, 1e-6)

    local half = Model.BuildRows(db({ ZA, 1, T0 }), nil, T0 + interval / 2)
    t.near(half[1].fraction, 0.5, 1e-6)

    local nearly = Model.BuildRows(db({ ZA, 1, T0 }), nil, T0 + interval - 1)
    t.ok(nearly[1].fraction > 0.99)
end)

t.test("an empty database draws nothing rather than erroring", function()
    local rows, nextRow = Model.BuildRows(Timers.New(), nil, T0)
    t.eq(#rows, 0)
    t.eq(nextRow, nil)
    t.eq(#Model.BuildRows(nil, nil, T0), 0)
end)

t.test("a route with no timers at all still lists its zones", function()
    local rows = Model.BuildRows(Timers.New(), { ZA, HD }, T0)
    t.eq(#rows, 2)
    for _, r in ipairs(rows) do
        t.eq(r.status, "unknown")
        t.ok(r.inRoute)
    end
end)

t.test("the freshest shard is the one a zone shows", function()
    local rows = Model.BuildRows(db(
        { ZA, 111, T0 - 600 },
        { ZA, 222, T0 - 100 }), nil, T0)
    t.eq(#rows, 1, "a zone is one row, not one per shard it has ever been on")
    t.eq(rows[1].shardID, 222)
end)
