local ns, t = ...
local Route, Timers = ns.Route, ns.Timers

local ZA, HD, SR, VS = 2437, 2413, 2444, 2405
local T0 = 1000000
local INTERVAL = 1100

local function intervalOf() return INTERVAL end
local function travelOf() return 60 end

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
    t.eq(zones[2], HD)
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

-- The whole point of the module. A sorted timer list puts this drop first and
-- it is the one drop you are guaranteed to miss.
-- Timestamps are always in the past here. A stamp ahead of the clock is bogus
-- data and Timers treats it as the next drop, which makes a route scenario
-- built on one mean something other than it reads -- spec_timers pins that.
t.test("a drop you cannot reach in time is marked missed, not offered", function()
    local d = db({ ZA, 1, T0 - 1080 })          -- drops in 20 seconds
    local plan = Route.Plan(d, { ZA }, intervalOf, travelOf, T0)
    t.eq(plan[1].dropIn, 20, "20 seconds out")
    t.eq(plan[1].travel, 60, "and 60 seconds of flying away")
    t.eq(plan[1].status, "missed", "arriving 40 seconds after it lands is a miss")
    t.eq(Route.Next(plan), nil, "nothing in this route is worth setting off for")
end)

t.test("a drop with time in hand says wait", function()
    local d = db({ ZA, 1, T0 - 900 })           -- drops in 200 seconds
    local plan = Route.Plan(d, { ZA }, intervalOf, travelOf, T0)
    t.eq(plan[1].status, "wait")
    t.eq(plan[1].leaveIn, 140, "200 seconds out, 60 of flying")
end)

t.test("a drop you should set off for right now says go", function()
    local d = db({ ZA, 1, T0 - 1041 })          -- drops in 59 seconds
    local plan = Route.Plan(d, { ZA }, intervalOf, travelOf, T0)
    t.eq(plan[1].status, "go")
end)

-- Arriving a few seconds after a crate lands is ordinary farming, not a miss.
t.test("the grace period keeps a just-landed crate reachable", function()
    local inGrace = Route.Plan(db({ ZA, 1, T0 - 1055 }), { ZA }, intervalOf, travelOf, T0)
    t.eq(inGrace[1].status, "go", "arriving 15 seconds late is still worth flying")
    local tooLate = Route.Plan(db({ ZA, 1, T0 - 1075 }), { ZA }, intervalOf, travelOf, T0)
    t.eq(tooLate[1].status, "missed", "arriving 35 seconds late is not")
end)

t.test("the plan is ordered by drop time, not by the order they were typed", function()
    local d = db(
        { ZA, 1, T0 - 100 },   -- drops in 1000s
        { HD, 2, T0 - 500 },   -- drops in 600s
        { VS, 3, T0 - 900 })   -- drops in 200s
    local plan = Route.Plan(d, { ZA, HD, VS }, intervalOf, travelOf, T0)
    t.eq(plan[1].zoneID, VS)
    t.eq(plan[2].zoneID, HD)
    t.eq(plan[3].zoneID, ZA)
end)

t.test("Next skips what cannot be reached and offers what can", function()
    local d = db(
        { VS, 1, T0 - 1070 },  -- drops in 30s, too soon to fly to
        { ZA, 2, T0 - 700 })   -- drops in 400s, plenty
    local plan = Route.Plan(d, { VS, ZA }, intervalOf, travelOf, T0)
    t.eq(plan[1].zoneID, VS, "the unreachable one is still shown, and shown first")
    t.eq(plan[1].status, "missed")
    local next_ = Route.Next(plan)
    t.eq(next_.zoneID, ZA, "but it is not what you should fly to")
end)

t.test("a zone with no timer is carried as unknown rather than dropped", function()
    local d = db({ ZA, 1, T0 })
    local plan = Route.Plan(d, { ZA, SR }, intervalOf, travelOf, T0)
    t.eq(#plan, 2, "the route keeps its shape even where nothing is known")
    t.eq(plan[2].zoneID, SR)
    t.eq(plan[2].status, "unknown")
    t.eq(plan[2].dropIn, nil)
end)

t.test("per-zone travel times are respected", function()
    local d = db({ ZA, 1, T0 }, { VS, 2, T0 })
    local far = { [ZA] = 30, [VS] = 240 }
    local plan = Route.Plan(d, { ZA, VS }, intervalOf, function(z) return far[z] end, T0 + 1000)
    local byZone = {}
    for _, row in ipairs(plan) do byZone[row.zoneID] = row end
    t.eq(byZone[ZA].status, "wait", "100 seconds out and 30 away")
    t.eq(byZone[VS].status, "missed", "100 seconds out and 240 away")
end)

t.test("an empty route plans nothing without complaining", function()
    t.eq(#Route.Plan(db(), {}, intervalOf, travelOf, T0), 0)
    t.eq(#Route.Plan(db(), nil, intervalOf, travelOf, T0), 0)
    t.eq(Route.Next(nil), nil)
end)

t.test("Describe round-trips what was parsed", function()
    t.eq(Route.Describe(Route.Parse("ZA Hd SR VS")), "ZA Hd SR VS")
end)
