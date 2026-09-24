local ns, t = ...
local Model, Timers = ns.Model, ns.Timers

local ZA, HA, SR, VS = 2437, 2413, 2444, 2405
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
        { HA, 3, T0 - 500 }), nil, T0)
    t.eq(#rows, 3)
    t.eq(rows[1].zoneID, VS)
    t.eq(rows[2].zoneID, HA)
    t.eq(rows[3].zoneID, ZA)
    t.notOk(rows[1].inRoute)
    t.ok(rows[1].onGround, "every timed row says when the crate will be lootable")
end)

t.test("a route is planned and comes first", function()
    local rows = Model.BuildRows(db(
        { ZA, 1, T0 - 900 },
        { VS, 2, T0 - 100 }), { VS }, T0)
    t.eq(rows[1].zoneID, VS, "the route zone leads even though its drop is later")
    t.ok(rows[1].inRoute)
    t.ok(rows[1].onGround, "and says when the crate will be lootable")
    t.lt(rows[1].remaining, rows[1].onGround, "the transport comes first, the crate after")
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

-- It used to be "the soonest one you could still reach", worked out from a
-- table of capital-to-zone flight times. Those were coarse by their own
-- admission and the advice they produced was guesswork wearing a number, so
-- the row worth acting on is simply the next one due.
t.test("the row worth acting on is the next one due", function()
    local _, nextRow = Model.BuildRows(db(
        { VS, 1, T0 - 1070 },
        { ZA, 2, T0 - 700 }), { VS, ZA }, T0)
    t.ok(nextRow)
    t.eq(nextRow.zoneID, VS, "thirty seconds out and still the next thing to happen")
end)

t.test("a route with nothing timed singles out nothing", function()
    local _, nextRow = Model.BuildRows(Timers.New(), { VS }, T0)
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
    local rows = Model.BuildRows(Timers.New(), { ZA, HA }, T0)
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

-- The moment a crate is released the timer resets and starts counting the ~18
-- minutes to the next one, so without this the row reads "18:10" at exactly
-- the moment there is a crate lying there to go and collect.
local function withLive(live, fn)
    local prev = ns.Scanner
    ns.Scanner = { LiveCrate = function() return live end }
    local ok, err = pcall(fn)
    ns.Scanner = prev
    if not ok then error(err, 0) end
end

t.test("a crate on the ground now outranks the countdown to the next", function()
    withLive({ phase = "ground", groundAt = T0 - 30 }, function()
        local rows = Model.BuildRows(db({ ZA, 1, T0 - 30 }), nil, T0)
        t.ok(rows[1].live, "the row has to know there is one down right now")
        t.eq(rows[1].live.phase, "ground")
        t.ok(rows[1].remaining, "and still carries the countdown underneath it")
    end)
end)

t.test("a crate under its parachute reports how long until it can be taken", function()
    ns.db = { descent = {} }
    ns.Airtime.NoteDescent(ns.db.descent, ZA, 86)
    withLive({ phase = "falling", since = T0 - 20 }, function()
        local rows = Model.BuildRows(db({ ZA, 1, T0 - 20 }), nil, T0)
        t.eq(rows[1].live.phase, "falling")
        t.near(rows[1].live.toGround, 66, 1e-6, "86 measured, 20 of them gone")
    end)
    ns.db = nil
end)

t.test("no live crate leaves the row as it was", function()
    withLive(nil, function()
        local rows = Model.BuildRows(db({ ZA, 1, T0 - 100 }), nil, T0)
        t.eq(rows[1].live, nil)
        t.ok(rows[1].remaining)
    end)
end)

-- Flying into a zone whose timer you do not have -- a new zone, or one on a
-- shard you have not seen -- used to produce no row at all, so the window was
-- silent at exactly the moment something was happening there.
t.test("a zone with a live crate gets a row even with no timer", function()
    local prev = ns.Scanner
    ns.Scanner = {
        LiveCrate = function(z) return z == SR and { phase = "ground", groundAt = T0 } or nil end,
        ActiveZones = function() return { [SR] = true } end,
    }
    local rows = Model.BuildRows(Timers.New(), nil, T0)
    ns.Scanner = prev
    t.eq(#rows, 1)
    t.eq(rows[1].zoneID, SR)
    t.eq(rows[1].remaining, nil, "nothing is known about its cycle")
    t.eq(rows[1].live.phase, "ground", "but there is a crate there right now")
end)

t.test("a transport still in the air is reason enough for a row", function()
    local prev = ns.Scanner
    ns.Scanner = {
        LiveCrate = function() return nil end,
        HasTransport = function(z) return z == VS end,
        Prediction = function() return nil end,
        ActiveZones = function() return { [VS] = true } end,
    }
    local rows = Model.BuildRows(Timers.New(), nil, T0)
    ns.Scanner = prev
    t.eq(#rows, 1)
    t.eq(rows[1].live.phase, "inbound")
end)

t.test("live zones float above the countdowns, most urgent first", function()
    local prev = ns.Scanner
    local live = {
        [SR] = { phase = "falling", since = T0 - 10 },
        [VS] = { phase = "ground", groundAt = T0 - 5 },
    }
    ns.Scanner = {
        LiveCrate = function(z) return live[z] end,
        HasTransport = function() return false end,
        ActiveZones = function() return { [SR] = true, [VS] = true } end,
    }
    -- ZA drops soonest, so on countdown alone it would lead.
    local rows = Model.BuildRows(db({ ZA, 1, T0 - 1000 }, { SR, 2, T0 }, { VS, 3, T0 }), nil, T0)
    ns.Scanner = prev
    t.eq(rows[1].zoneID, VS, "one you can pick up now comes first")
    t.eq(rows[2].zoneID, SR, "then one about to land")
    t.eq(rows[3].zoneID, ZA, "then the soonest countdown")
end)

-- The window said "no transport in the air" while one plainly was, because
-- the prediction returned nothing whenever the heading could not be fitted --
-- which is the first seconds of a flight and again once it reaches its drop
-- point and circles. Both are moments someone looks at the window.
t.test("a transport with no usable heading is still reported", function()
    local prev = ns.Scanner
    ns.Scanner = { Prediction = function()
        return { ok = false, reason = "gathering", samples = 3 }
    end }
    local head = Model.Headline(ZA, T0)
    ns.Scanner = prev
    t.ok(head, "there is a transport, so there is something to say")
    t.notOk(head.ready)
    t.ok(head.text:find("3"), "and how far along reading it has got")
end)

t.test("a transport that has stopped moving says so", function()
    local prev = ns.Scanner
    ns.Scanner = { Prediction = function() return { ok = false, reason = "not-moving" } end }
    local head = Model.Headline(ZA, T0)
    ns.Scanner = prev
    t.ok(head)
    t.ok(head.text:find("not going anywhere"))
end)

t.test("no transport at all is still no headline", function()
    local prev = ns.Scanner
    ns.Scanner = { Prediction = function() return nil end }
    local head = Model.Headline(ZA, T0)
    ns.Scanner = prev
    t.eq(head, nil, "this is the one case the window should say nothing for")
end)

-- A timer belongs to one copy of a zone. Once the copy is known, the only
-- entry worth reading is that copy's, and its absence is an answer rather than
-- a gap: nothing has been timed here yet. Another copy's countdown in that
-- place is worse than blank, because it looks exactly like knowledge, and a
-- raid flies out on the strength of it and finds nothing.
local function standingOn(shard)
    ns.Scanner = { CurrentShard = function() return shard end }
end

local function scoutSays(zoneID, shard, who)
    ns.remote = ns.Remote.New()
    ns.Remote.Note(ns.remote, { zoneID = zoneID, shardID = shard, stage = "here",
                                at = T0, from = who or "Scout" }, T0)
end

local function clear()
    ns.Scanner, ns.remote = nil, nil
end

t.test("the timer shown is the one for the copy of the zone you are in", function()
    local d = db({ ZA, 7, T0 - 100 }, { ZA, 999, T0 - 700 })
    standingOn(999)
    local rows = Model.BuildRows(d, nil, T0)
    clear()
    t.eq(rows[1].shardID, 999, "not the freshest, the one that applies")
    t.ok(rows[1].remaining)
end)

t.test("a copy nobody has timed shows nothing rather than somebody else's", function()
    standingOn(12345)
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), nil, T0)
    clear()
    t.eq(#rows, 1)
    t.eq(rows[1].shardID, 12345)
    t.eq(rows[1].remaining, nil, "blank, because this copy has never been watched")
    t.ok(rows[1].newShard)
end)

t.test("not knowing the copy falls back to the freshest, and says it is a guess", function()
    clear()
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), nil, T0)
    t.eq(rows[1].shardID, 7)
    t.ok(rows[1].remaining)
    t.ok(rows[1].guessedShard)
    t.notOk(rows[1].newShard)
end)

-- For a zone nobody here is standing in, a scout parked in it is the only way
-- to know which copy the raid will land in before flying there rather than
-- after.
t.test("a scout's shard decides for a zone this client is not in", function()
    scoutSays(ZA, 999)
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), nil, T0)
    clear()
    t.eq(rows[1].shardID, 999)
    t.eq(rows[1].shardFrom, "Scout")
    t.ok(rows[1].newShard, "the raid is in 999 and 999 has never been timed")
end)

t.test("this client's own reading beats a scout's", function()
    standingOn(7)
    scoutSays(ZA, 999)
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), nil, T0)
    clear()
    t.eq(rows[1].shardID, 7)
    t.eq(rows[1].shardFrom, "you")
    t.ok(rows[1].remaining)
end)

t.test("a route zone keeps its row even when its copy has nothing timed", function()
    standingOn(999)
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), { ZA }, T0)
    clear()
    t.eq(#rows, 1, "the route keeps its shape")
    t.ok(rows[1].inRoute)
    t.ok(rows[1].newShard)
    t.eq(rows[1].remaining, nil)
end)

-- "new shard" and "never seen here" are different news and were sharing one
-- message: Harandar read "new shard" on a profile that had never timed
-- Harandar at all, which says the copy is the problem when the zone is.
t.test("a zone never timed at all is not called a new shard", function()
    standingOn(811)
    local rows = Model.BuildRows(db({ ZA, 7, T0 - 100 }), { HA }, T0)
    clear()
    t.eq(rows[1].zoneID, HA)
    t.eq(rows[1].remaining, nil)
    t.notOk(rows[1].newShard, "nothing was ever timed here, in any copy")
end)

t.test("a zone timed elsewhere but not in this copy is a new shard", function()
    standingOn(811)
    local rows = Model.BuildRows(db({ HA, 7, T0 - 100 }), { HA }, T0)
    clear()
    t.ok(rows[1].newShard, "Harandar has been timed, just not in copy 811")
    t.eq(rows[1].remaining, nil)
end)
