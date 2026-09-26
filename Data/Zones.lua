local ADDON, ns = ...

-- Zones Midnight drops War Supply Crates in. Deliberately only these six for
-- now. Older expansions still drop crates and Data/DropPoints.lua already
-- catalogues them, but they are not the target yet; adding one here is all it
-- takes to turn it on.
--
-- interval is a FALLBACK, used only until a zone has been measured. 1100
-- across the board because that is what CrateTrackerZK ships for every 11.0
-- and 12.0 zone, with RCT's hand-tuned 1091-1100 inside the same band.
--
-- Measurement says otherwise. Harandar has been timed twice, once across four
-- drops and once across one, agreeing at 1086 and 1085; Voidstorm came out at
-- 1097 across four. So the figure everyone ships is not right, and the gap
-- between those two zones says it may not even be one figure. Assuming 1100
-- where the truth is 1086 puts the countdown a minute out over four cycles.
--
-- Hardcoding those numbers here would be the same mistake with better inputs.
-- GetZoneInterval prefers what this client has actually observed.
--
-- abbr is what crate farmers actually say, and what the route editor accepts as
-- input. Mostly from WarCrateTracker (MIT, Copyright 2024 Samuel Colburn), minus
-- its "MID:" prefix -- but Eversong and Harandar are ES and HA here, not its EW
-- and HD, because that is what Dmitrii's raids call out loud and the table only
-- exists to match what people say. Both spellings resolve either way.
--
local ZONES = {
    [2395] = { name = "Eversong Woods",  abbr = "ES", interval = 1100 },
    [2405] = { name = "Voidstorm",       abbr = "VS", interval = 1100 },
    [2413] = { name = "Harandar",        abbr = "HA", interval = 1100 },
    [2437] = { name = "Zul'Aman",        abbr = "ZA", interval = 1100 },
    [2444] = { name = "Slayer's Rise",   abbr = "SR", interval = 1100 },
    [2512] = { name = "The Coiled Isle", abbr = "CI", interval = 1100 },
}

-- Spellings a player might reasonably type for a zone. Deliberately forgiving:
-- this is parsed from a text box, and being strict about ES versus EW only
-- makes the route editor annoying.
local ABBR_ALIAS = {
    ES = 2395, EW = 2395, EVERSONG = 2395,
    VS = 2405, VOID = 2405, VOIDSTORM = 2405,
    HD = 2413, HA = 2413, HARANDAR = 2413,
    ZA = 2437, ZUL = 2437, ZULAMAN = 2437,
    SR = 2444, SLAY = 2444,
    CI = 2512, COIL = 2512, COILED = 2512,
}

ns.ZONE_BY_ABBR = ABBR_ALIAS

-- Returns a zone id for anything a player might type, or nil.
function ns.ResolveZoneInput(text)
    if type(text) ~= "string" then return nil end
    local key = text:upper():gsub("[^%u]", "")
    return ABBR_ALIAS[key]
end

function ns.GetZoneAbbr(zoneID)
    local z = ZONES[zoneID]
    return z and z.abbr or tostring(zoneID)
end

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

-- Zone names as other clients broadcast them.
--
-- RCT posts its chat alert using the sender's own localised name, and the game
-- will only ever tell a client the names in its own locale. So a German
-- raider's report is unreadable here unless the name is written down, and one
-- public raid dropped three of them.
--
-- Each was resolved from the wire, not translated. The name arrived carrying a
-- shard, and that shard was one this client had independently confirmed for a
-- zone in its own timers and phase memory at the same moment. The morphology
-- agrees separately -- Leeren+sturm against Void+storm, Schlaechter+anhoehe
-- against Slayer's+Rise -- which is two lines of evidence rather than one.
--
-- The weakness, stated because it is real: shard ids are not unique across
-- zones, and Slayer's Rise is nested inside Voidstorm, so the records of
-- untracked vignettes show both 45 and 63 under both names. What makes that
-- tolerable is the shape of the mistake it could cause. Confusing these two
-- sends somebody to a zone they are already standing in the parent of; the
-- same error between Eversong and Harandar would send them across a continent.
--
-- Anything not listed is still collected rather than discarded: /ewc comm
-- prints unresolved names with the shards they arrived with, which is how
-- these two got here.
local FOREIGN = {
    ["Leerensturm"]      = 2405,   -- deDE Voidstorm, shard 63, 26 Sep
    ["Schlächteranhöhe"] = 2444,   -- deDE Slayer's Rise, shard 45, 26 Sep
}

ns.ZONE_NAMES_FOREIGN = FOREIGN

ns.ZONES = ZONES
ns.ZONE_ALIAS = ALIAS

function ns.GetZone(zoneID)
    return ZONES[zoneID]
end

-- Enough cycles of evidence to prefer what was measured here over what was
-- shipped. A single one-cycle reading carries the whole detection error at
-- both ends; three is where the readings started agreeing with each other.
local MEASURED_MIN_CYCLES = 3

-- The shipped figure is a fallback now, not the answer.
--
-- Harandar has been measured twice -- once across four drops, once across one
-- -- and they agree at 1085 and 1086. Voidstorm measured 1097 across four.
-- Neither is the 1100 every addon ships, and the eleven seconds between them
-- suggests the interval is not even the same everywhere. Over four cycles,
-- assuming 1100 in a zone that runs 1086 puts the countdown almost a minute out.
function ns.GetZoneInterval(zoneID)
    local shipped = ZONES[zoneID] and ZONES[zoneID].interval or 1100
    if not (ns.db and ns.db.gaps and ns.Timers) then return shipped end
    -- The cluster first, because one bad pairing moves a mean and cannot move
    -- a cluster. Eversong's mean reads 1117 against a core of 1093.
    local typical, n = ns.Timers.GapCluster(ns.db.gaps, zoneID)
    if typical then return typical end

    local gaps, mean, _, _, cycles = ns.Timers.GapStats(ns.db.gaps, zoneID)
    if gaps and cycles and cycles >= MEASURED_MIN_CYCLES then
        return mean
    end
    return shipped
end

function ns.GetShippedInterval(zoneID)
    return ZONES[zoneID] and ZONES[zoneID].interval or 1100
end

function ns.GetZoneName(zoneID)
    local z = ZONES[zoneID]
    return z and z.name or ("Zone " .. tostring(zoneID))
end
