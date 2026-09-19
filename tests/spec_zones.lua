local ns, t = ...
local Zones = ns.Zones

-- The real Midnight map tree, read out of the live client with /ewc map on
-- 18 Sep 2026 rather than invented. mapType: 0 Cosmic, 1 World, 2 Continent,
-- 3 Zone, 4 Dungeon, 5 Micro.
--
-- Two rows carry the whole design. Silvermoon City is mapType 3 sitting under
-- Eversong Woods, also mapType 3 -- so a walk that does not stop at the first
-- Zone reports a sanctuary as a crate zone. The Den is mapType 5 under
-- Harandar, so the same walk has to keep going for a sub-area. Getting both
-- right at once is why the rule is "stop at the first Zone" and not a table of
-- special cases.
local TREE = {
    [946]  = { mapID = 946,  parentMapID = 0,    mapType = 0 },  -- Cosmic
    [947]  = { mapID = 947,  parentMapID = 946,  mapType = 1 },  -- Azeroth
    [13]   = { mapID = 13,   parentMapID = 947,  mapType = 2 },  -- Eastern Kingdoms
    [2537] = { mapID = 2537, parentMapID = 13,   mapType = 2 },  -- Quel'Thalas, a continent
    [2395] = { mapID = 2395, parentMapID = 2537, mapType = 3 },  -- Eversong Woods
    [2437] = { mapID = 2437, parentMapID = 2537, mapType = 3 },  -- Zul'Aman
    [2413] = { mapID = 2413, parentMapID = 2537, mapType = 3 },  -- Harandar
    [2393] = { mapID = 2393, parentMapID = 2395, mapType = 3 },  -- Silvermoon City
    [2576] = { mapID = 2576, parentMapID = 2413, mapType = 5 },  -- The Den, housing in Harandar
    [9001] = { mapID = 9001, parentMapID = 2395, mapType = 4 },  -- a delve in Eversong
    [9002] = { mapID = 9002, parentMapID = 2393, mapType = 5 },  -- a building in Silvermoon
    [9500] = { mapID = 9500, parentMapID = 0,    mapType = 4 },  -- orphan
}

local calls
local function getInfo(id)
    calls = calls + 1
    return TREE[id]
end
local function fresh() calls = 0 end

t.test("a tracked zone resolves without consulting the map tree", function()
    fresh()
    t.eq(Zones.Normalize(2395, getInfo), 2395)
    t.eq(calls, 0, "the hot path runs on every vignette scan; it must not call the API")
end)

t.test("every Midnight zone resolves to itself", function()
    for zoneID in pairs(ns.ZONES) do
        t.eq(Zones.Normalize(zoneID, getInfo), zoneID, "zone " .. zoneID)
    end
end)

-- The bug this whole design avoids. RCT keeps walking past the first Zone-type
-- map and takes the outermost, so standing in Silvermoon registers as standing
-- in Eversong Woods -- a zone where crates really do drop, on a shard reading
-- taken inside a sanctuary.
t.test("Silvermoon City does not become Eversong Woods", function()
    t.eq(Zones.Normalize(2393, getInfo), nil,
        "a sanctuary city is its own Zone-type map and simply is not tracked")
end)

t.test("somewhere inside Silvermoon does not become Eversong Woods either", function()
    t.eq(Zones.Normalize(9002, getInfo), nil)
end)

t.test("a delve inside a tracked zone resolves to that zone", function()
    t.eq(Zones.Normalize(9001, getInfo), 2395,
        "a non-Zone map should walk up to the zone containing it")
end)

-- The other half of the rule. Midnight put housing inside the crate zones, and
-- a player standing in one is still in the zone for crate purposes -- the
-- transport flies over it. The Den reports its own map id, so without the walk
-- the addon would go blind in every housing area.
t.test("a housing sub-area resolves to the zone around it", function()
    t.eq(Zones.Normalize(2576, getInfo), 2413,
        "The Den is mapType 5 under Harandar, so the walk must not stop there")
end)

t.test("the continent above the zones is not itself a crate zone", function()
    t.eq(Zones.Normalize(2537, getInfo), nil,
        "Quel'Thalas is mapType 2, the continent holding Eversong, Zul'Aman, Harandar "
        .. "and Coiled Isle. RCT tracks it as a crate zone; it is not one")
end)

t.test("GUID-embedded ids alias onto the real zone", function()
    t.eq(Zones.Normalize(3135, getInfo), 2512, "Coiled Isle as it appears inside GUIDs")
    t.eq(Zones.Normalize(2536, getInfo), 2437, "second map id for Zul'Aman")
end)

t.test("an unknown map is refused rather than guessed at", function()
    t.eq(Zones.Normalize(9500, getInfo), nil, "orphan map")
    t.eq(Zones.Normalize(424242, getInfo), nil, "map the tree has never heard of")
end)

t.test("junk input is refused without throwing", function()
    t.eq(Zones.Normalize(nil, getInfo), nil)
    t.eq(Zones.Normalize("", getInfo), nil)
    t.eq(Zones.Normalize({}, getInfo), nil)
    t.eq(Zones.Normalize("2395", getInfo), 2395, "a numeric string is still a map id")
end)

t.test("a cycle in the map tree terminates", function()
    local loop = {
        [1] = { mapID = 1, parentMapID = 2, mapType = 4 },
        [2] = { mapID = 2, parentMapID = 1, mapType = 4 },
    }
    t.eq(Zones.Normalize(1, function(id) return loop[id] end), nil,
        "a malformed tree must not hang the client")
end)

t.test("IsTracked agrees with the zone table", function()
    t.ok(Zones.IsTracked(2444))
    t.notOk(Zones.IsTracked(2393))
    t.notOk(Zones.IsTracked(2537), "Quel'thalas is not a crate zone")
    t.notOk(Zones.IsTracked(nil))
end)

t.test("every tracked zone has drop points catalogued", function()
    for zoneID, z in pairs(ns.ZONES) do
        local spots = ns.ShippedDropPoints(zoneID)
        t.ok(spots and #spots > 0, z.name .. " has no drop points, so prediction there is dead")
        t.ok(z.interval > 0, z.name .. " needs an interval")
    end
end)
