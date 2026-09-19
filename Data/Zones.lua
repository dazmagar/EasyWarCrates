local ADDON, ns = ...

-- Zones Midnight drops War Supply Crates in. Deliberately only these six for
-- now. Older expansions still drop crates and Data/DropPoints.lua already
-- catalogues them, but they are not the target yet; adding one here is all it
-- takes to turn it on.
--
-- interval is seconds between drops on a given shard. 1100 across the board:
-- CrateTrackerZK ships exactly that for every 11.0 and 12.0 zone, RCT's
-- hand-tuned 1091-1100 spread sits inside the same band, and HGLog only ever
-- accepts an observed gap in 1090-1105. Nobody has pinned it finer than that,
-- so a per-zone table would be recording measurement noise as fact. The real
-- fix is to learn it per shard from consecutive drops, which this leaves room
-- for rather than pretending to already know.
local ZONES = {
    [2395] = { name = "Eversong Woods",  interval = 1100 },
    [2405] = { name = "Voidstorm",       interval = 1100 },
    [2413] = { name = "Harandar",        interval = 1100 },
    [2437] = { name = "Zul'Aman",        interval = 1100 },
    [2444] = { name = "Slayer's Rise",   interval = 1100 },
    [2512] = { name = "The Coiled Isle", interval = 1100 },
}

-- Ids that mean one of the zones above but are not it. Core/Zones.lua resolves
-- ordinary sub-zones by walking the map tree, so this is only for ids the tree
-- cannot explain.
--
-- Quel'thalas (2537) is deliberately absent. RCT tracks it as a crate zone,
-- but it is the continent map that Eversong Woods, Zul'Aman and The Coiled
-- Isle hang off. It carries no crate spawns of its own in Wowhead's data and
-- CrateTrackerZK does not list it either.
local ALIAS = {
    [3135] = 2512,  -- The Coiled Isle as embedded in creature / vignette GUIDs
    [2536] = 2437,  -- second map id seen for Zul'Aman
}

ns.ZONES = ZONES
ns.ZONE_ALIAS = ALIAS

function ns.GetZone(zoneID)
    return ZONES[zoneID]
end

function ns.GetZoneInterval(zoneID)
    local z = ZONES[zoneID]
    return z and z.interval or 1100
end

function ns.GetZoneName(zoneID)
    local z = ZONES[zoneID]
    return z and z.name or ("Zone " .. tostring(zoneID))
end
