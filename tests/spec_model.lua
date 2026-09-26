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

-- What a click says to the group. Pinned here rather than discovered in a raid.
local function announce(over)
    local row = { zoneID = ZA, shardID = 45675 }
    for k, v in pairs(over or {}) do row[k] = v end
    return Model.Announcement(row)
end

-- No coordinates anywhere: the pin that goes with the message points at the
-- exact spot, so numbers beside it are the same fact twice. Time is what the
-- reader is weighing.
t.test("a crate on the ground is announced with how long it has been there", function()
    local said = Model.Announcement(
        { zoneID = ZA, shardID = 45675,
          live = { phase = "ground", since = T0, x = 0.402, y = 0.783 } }, T0 + 35)
    t.ok(said:find("ON THE GROUND", 1, true), said)
    t.ok(said:find("0:35 so far", 1, true), said)
    t.notOk(said:find("40.2", 1, true), "the pin already says where")
    t.ok(said:find("45675", 1, true), "the raid needs to know which copy")
end)

t.test("a crate our side claimed says so, and how long is left when that is known", function()
    local mine = { phase = "ground", since = T0, mine = true }
    local said = Model.Announcement({ zoneID = ZA, shardID = 1, live = mine }, T0 + 20)
    t.ok(said:find("ours", 1, true), said)
    t.ok(said:find("0:20 so far", 1, true), said)

    mine.toGone = 75
    said = Model.Announcement({ zoneID = ZA, shardID = 1, live = mine }, T0 + 20)
    t.ok(said:find("1:15 left", 1, true), said)
end)

t.test("the other live states already carried a time and gained no numbers", function()
    local falling = Model.Announcement(
        { zoneID = ZA, shardID = 1,
          live = { phase = "falling", toGround = 42, x = 0.4, y = 0.7 } }, T0)
    t.ok(falling:find("landing in 0:42", 1, true), falling)
    t.notOk(falling:find("40.0", 1, true), "the pin says where")
end)

t.test("a falling crate is announced with how long is left", function()
    local said = announce({ live = { phase = "falling", toGround = 42 } })
    t.ok(said:find("landing in 0:42", 1, true), said)
end)

t.test("a transport still in the air says so", function()
    local said = announce({ live = { phase = "inbound", toGround = 130 } })
    t.ok(said:find("transport in the air", 1, true), said)
    t.ok(said:find("down in 2:10", 1, true), said)
end)

t.test("with no crate in sight, the two countdowns are announced", function()
    local said = announce({ remaining = 201, onGround = 374 })
    t.ok(said:find("transport in 3:21", 1, true), said)
    t.ok(said:find("lootable in 6:14", 1, true), said)
end)

t.test("a zone nothing is known about is not worth saying", function()
    t.eq(announce(), nil)
    t.eq(Model.Announcement(nil), nil)
    t.eq(Model.Announcement({}), nil)
end)

-- RCT announces its own sightings as raid warnings, so the raid has already
-- read anything that reached us that way.
t.test("what arrived as raid chat is not said back to the raid", function()
    t.eq(announce({ live = { phase = "ground", via = "RCT", from = "Someone" } }), nil)
    t.ok(announce({ live = { phase = "ground", via = "WCT", from = "Someone" } }),
        "an addon channel is invisible to anyone without that addon")
end)

-- A crate claimed by your own side is not finished with. The marker says which
-- faction captured it, not that somebody carried it off, so the row has to go
-- on saying it is there.
t.test("a crate our own side claimed is still shown as lootable", function()
    ns.Scanner = { LiveCrate = function() return
        { phase = "ground", groundAt = T0, mine = true, x = 0.4, y = 0.78 } end }
    local live = Model.LiveFor(ZA, T0 + 10)
    ns.Scanner = nil
    t.eq(live.phase, "ground")
    t.ok(live.mine, "and the row can say whose it is")
    t.eq(live.rank, 1, "still the most urgent thing on the list")
end)

t.test("the claiming side is never guessed from which marker arrived", function()
    -- Nothing in the model reads the vignette id for a faction. The two
    -- claimed ids both mean claimed, the game only draws your own side's
    -- marker, and a table mapping id to faction was contradicted live.
    t.eq(ns.VignetteStage(6067), "claimed")
    t.eq(ns.VignetteStage(6068), "claimed")
end)

t.test("a claimed crate is still a landing worth learning from", function()
    t.ok(ns.LANDED_STAGE.claimed, "it is lying where it landed")
    t.ok(ns.LANDED_STAGE.ground)
end)

-- What the row says about a crate our side has claimed: a countdown once the
-- readings agree, a stopwatch until then. An invented countdown would be worse
-- than an honest count up.
t.test("a claimed crate counts up while nobody knows how long they last", function()
    ns.db = { linger = {} }
    ns.Scanner = { LiveCrate = function() return
        { phase = "ground", groundAt = T0, mine = true, claimedAt = T0 } end }
    local live = Model.LiveFor(ZA, T0 + 45)
    ns.Scanner, ns.db = nil, nil
    t.eq(live.held, 45)
    t.eq(live.toGone, nil, "nothing measured, so nothing counted down")
end)

t.test("and counts down once they do", function()
    local linger = {}
    for _, secs in ipairs({ 118, 120, 122 }) do ns.Airtime.NoteLinger(linger, ZA, secs) end
    ns.db = { linger = linger }
    ns.Scanner = { LiveCrate = function() return
        { phase = "ground", groundAt = T0, mine = true, claimedAt = T0 } end }
    local live = Model.LiveFor(ZA, T0 + 45)
    ns.Scanner, ns.db = nil, nil
    t.eq(live.toGone, 75, "120 measured, 45 gone")
end)

t.test("a countdown that has run out shows nothing left rather than going negative", function()
    local linger = {}
    for _, secs in ipairs({ 118, 120, 122 }) do ns.Airtime.NoteLinger(linger, ZA, secs) end
    ns.db = { linger = linger }
    ns.Scanner = { LiveCrate = function() return
        { phase = "ground", groundAt = T0, mine = true, claimedAt = T0 } end }
    local live = Model.LiveFor(ZA, T0 + 500)
    ns.Scanner, ns.db = nil, nil
    t.eq(live.toGone, 0)
end)

-- A sighting is about a moment and moments pass. Nobody retracts one, so an
-- "in the air" from four minutes ago went on saying inbound long after the
-- crate had landed and somebody had taken it.
t.test("a transport report stops being true once the flight is over", function()
    local flight = {}
    for _, secs in ipairs({ 70, 72, 74 }) do ns.Airtime.NoteFlight(flight, ZA, secs) end
    ns.db = { flight = flight, descent = {} }
    local report = { zoneID = ZA, stage = "flying", at = T0 }
    t.ok(Model.StillTrue(report, T0 + 60), "still in the air")
    t.notOk(Model.StillTrue(report, T0 + 120), "it dropped its crate a while back")
    ns.db = nil
end)

t.test("a parachute report stops being true once the fall is over", function()
    local descent = {}
    for _, secs in ipairs({ 86, 86, 87 }) do ns.Airtime.NoteDescent(descent, ZA, secs) end
    ns.db = { flight = {}, descent = descent }
    local report = { zoneID = ZA, stage = "falling", at = T0 }
    t.ok(Model.StillTrue(report, T0 + 60))
    t.notOk(Model.StillTrue(report, T0 + 100), "it is on the ground, and whose is unknown")
    ns.db = nil
end)

t.test("a crate reported on the ground is governed by its own lifetime", function()
    ns.db = { flight = {}, descent = {} }
    t.ok(Model.StillTrue({ zoneID = ZA, stage = "ground", at = T0 }, T0 + 500),
        "Remote decides when that stops mattering, not the legs")
    ns.db = nil
end)

t.test("a stale report does not put a zone at the top of the window", function()
    local flight = {}
    for _, secs in ipairs({ 70, 72, 74 }) do ns.Airtime.NoteFlight(flight, ZA, secs) end
    ns.db = { flight = flight, descent = {}, linger = {} }
    ns.remote = ns.Remote.New()
    ns.Remote.Note(ns.remote, { zoneID = ZA, shardID = 5, stage = "flying",
                                at = T0, from = "Scout" }, T0)
    t.ok(Model.LiveFor(ZA, T0 + 30), "fresh enough to act on")
    t.eq(Model.LiveFor(ZA, T0 + 150), nil, "and nothing to say once it cannot be true")
    ns.db, ns.remote = nil, nil
end)


-- A second object in the same copy of the same zone, on the ground for one to
-- two minutes. Dmitrii saw one, the row marked it, and a click said "nothing is
-- known about that zone worth announcing" -- because nothing here produced a
-- line for it.
t.test("a chest with no crate beside it is worth announcing on its own", function()
    local said, subject = Model.Announcement(
        { zoneID = SR, shardID = 39, spectral = { since = T0, x = 0.53, y = 0.41 } }, T0 + 40)
    t.ok(said and said:find("SPECTRAL CHEST", 1, true), tostring(said))
    t.ok(said:find("0:40 so far", 1, true), said)
    t.eq(subject, "spectral", "so the pin goes on the chest and not somewhere else")
    t.eq(said:find("0.53", 1, true), nil, "no coordinates: the pin carries the spot")
end)

-- Ranked by what can be taken now. A transport in the air means three minutes
-- from now; the chest is on the ground and gone in one or two. Ranking the
-- transport first told a raid about a plane while a chest lay in the zone.
t.test("a transport in the air does not outrank a chest on the ground", function()
    for _, phase in ipairs({ "inbound", "falling" }) do
        local said, subject = Model.Announcement(
            { zoneID = SR, shardID = 45,
              live = { phase = phase, toGround = 183 },
              spectral = { since = T0, x = 0.692, y = 0.482 } }, T0 + 30)
        t.ok(said:find("SPECTRAL CHEST", 1, true), phase .. ": " .. said)
        t.eq(subject, "spectral", phase)
    end
end)

-- It lasts a minute or two and has no countdown and no second chance, so a
-- line saying only which zone has told the reader nothing they can use. A
-- crate can lean on its pin because it is still findable without one.
t.test("the chest is announced with its coordinates, not just its zone", function()
    local said = Model.Announcement(
        { zoneID = SR, shardID = 45, spectral = { since = T0, x = 0.692, y = 0.482 } }, T0 + 5)
    t.ok(said:find("69.2, 48.2", 1, true), said)

    local noPos = Model.Announcement(
        { zoneID = SR, shardID = 45, spectral = { since = T0 } }, T0 + 5)
    t.ok(noPos:find("SPECTRAL CHEST", 1, true), noPos)
    t.eq(noPos:find("at ", 1, true), nil, "and says nothing it does not have")
end)

t.test("a crate we can see outranks the chest", function()
    local said, subject = Model.Announcement(
        { zoneID = SR, shardID = 39,
          live = { phase = "ground", since = T0, x = 0.2, y = 0.2 },
          spectral = { since = T0, x = 0.53, y = 0.41 } }, T0 + 10)
    t.ok(said:find("crate ON THE GROUND", 1, true), said)
    t.eq(subject, "crate")
end)

-- The crate came as a raid warning everyone has read, so repeating it is spam.
-- The chest was not in that warning and is on the ground now.
t.test("a chest survives the silence an RCT-carried crate gets", function()
    local echo = { zoneID = SR, shardID = 39, live = { phase = "ground", since = T0, via = "RCT" } }
    t.eq(Model.Announcement(echo, T0 + 10), nil)

    echo.spectral = { since = T0, x = 0.53, y = 0.41 }
    local said, subject = Model.Announcement(echo, T0 + 10)
    t.ok(said and said:find("SPECTRAL CHEST", 1, true), tostring(said))
    t.eq(subject, "spectral")
end)

t.test("a chest on the ground outranks a countdown to one that is not", function()
    local row = { zoneID = SR, shardID = 39, remaining = 600, onGround = 700 }
    t.ok(Model.Announcement(row, T0):find("transport in", 1, true))

    row.spectral = { since = T0 - 15 }
    local said, subject = Model.Announcement(row, T0)
    t.ok(said:find("SPECTRAL CHEST", 1, true), said)
    t.eq(subject, "spectral")
end)
