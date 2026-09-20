local ns, t = ...
local Route, Timers = ns.Route, ns.Timers

local ZA, HA, SR, VS = 2437, 2413, 2444, 2405
local T0 = 1000000
local INTERVAL = 1100

local function intervalOf() return INTERVAL end

local function db(...)
    local d = Timers.New()
    for _, e in ipairs({ ... }) do
        Timers.Record(d, e[1], e[2], e[3], e[4] or "falling")
    end
    return d
end

t.test("route text is parsed from the abbreviations raids actually use", function()
    local zones, bad = Route.Parse("ZA Hd SR VS")
    t.eq(#zones, 4)
    t.eq(zones[1], ZA)
    t.eq(zones[2], HA)
    t.eq(zones[3], SR)
    t.eq(zones[4], VS)
    t.eq(#bad, 0)
end)

t.test("parsing forgives case, punctuation and the ES spelling", function()
    local zones = Route.Parse("za, ci / es")
    t.eq(#zones, 3)
    t.eq(zones[3], 2395, "ES and EW both mean Eversong")
end)

t.test("a word it does not know is reported, not silently dropped", function()
    local zones, bad = Route.Parse("ZA Orgrimmar VS")
    t.eq(#zones, 2)
    t.eq(#bad, 1)
    t.eq(bad[1], "Orgrimmar")
end)

t.test("a zone named twice appears once", function()
    local zones = Route.Parse("ZA VS ZA")
    t.eq(#zones, 2)
end)

t.test("the freshest shard is the one shown for a zone", function()
    local d = db({ ZA, 100, T0 }, { ZA, 200, T0 + 300 })
    local entry, shard = Route.FreshestForZone(d, ZA)
    t.eq(shard, 200, "the raid re-rolls its shard each time it flies back in")
    t.eq(entry.ts, T0 + 300)
end)

-- Timestamps are always in the past here. A stamp ahead of the clock is bogus
-- data and Timers treats it as the next drop, which makes a route scenario
-- built on one mean something other than it reads -- spec_timers pins that.
t.test("the soonest drop comes first and is the one to act on", function()
    local d = db({ ZA, 1, T0 - 600 }, { VS, 2, T0 - 1000 }, { HA, 3, T0 - 100 })
    local plan = Route.Plan(d, { ZA, VS, HA }, intervalOf, nil, T0)
    t.eq(plan[1].zoneID, VS, "1000 seconds into a 1100 cycle")
    t.eq(plan[2].zoneID, ZA)
    t.eq(plan[3].zoneID, HA)
    t.eq(Route.Next(plan).zoneID, VS)
end)

-- Route used to answer when to set off, from a table of capital-to-zone
-- times. Those were coarse by their own admission and the spread within a zone
-- was as large as the spread between zones, so the advice was guesswork
-- wearing a number. The window says when the transport appears and when the
-- crate is lootable instead, both measured.
t.test("nothing in a plan claims to know where the player is", function()
    local plan = Route.Plan(db({ ZA, 1, T0 }), { ZA }, intervalOf, nil, T0)
    t.eq(plan[1].leaveIn, nil)
    t.eq(plan[1].travel, nil)
    t.notOk(plan[1].knownShard, "no shard was offered, so none is claimed")
    t.eq(plan[1].status, "wait", "a timer exists, and that is all this says")
end)

t.test("a zone with no timer is carried as unknown rather than dropped", function()
    local d = db({ ZA, 1, T0 })
    local plan = Route.Plan(d, { ZA, SR }, intervalOf, nil, T0)
    t.eq(#plan, 2, "the route keeps its shape even where nothing is known")
    t.eq(plan[2].zoneID, SR)
    t.eq(plan[2].status, "unknown")
    t.eq(plan[2].dropIn, nil)
end)

t.test("an empty route plans nothing without complaining", function()
    t.eq(#Route.Plan(db(), {}, intervalOf, nil, T0), 0)
    t.eq(#Route.Plan(db(), nil, intervalOf, nil, T0), 0)
    t.eq(Route.Next(nil), nil)
end)

-- Not a literal round trip: parsing is forgiving and Describe is canonical, so
-- whatever spelling went in comes back the one way the addon writes it.
t.test("Describe normalises whatever spelling was typed", function()
    t.eq(Route.Describe(Route.Parse("ZA HA SR VS")), "ZA HA SR VS")
    -- The two zones whose canonical spelling changed to match what raids call
    -- out. Both of the older ones must keep parsing: a route dictated over
    -- voice is typed by whoever heard it.
    t.eq(Route.Describe(Route.Parse("za hd sr vs")), "ZA HA SR VS")
    t.eq(Route.Describe(Route.Parse("ew")), "ES")
    t.eq(Route.Describe(Route.Parse("zulaman, harandar / slay void")), "ZA HA SR VS")
end)
