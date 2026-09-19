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
-- travel is seconds from the capital to a drop point in that zone, which is the
-- number the rotation planner needs. Silvermoon has portals to Harandar,
-- Voidstorm and Coiled Isle; Eversong and Zul'Aman are reached by mount, and
-- Eversong is the odd one out because Silvermoon sits inside it.
--
-- These are estimates, and coarse on purpose. The spread WITHIN a zone -- which
-- of its drop points the crate picks, relative to where the portal puts you --
-- is about as large as the spread between zones, so a precise per-zone figure
-- would be false precision. Nothing observed goes past two minutes.
--
-- Erring low is deliberate. Overstating travel makes the planner call a
-- reachable drop "missed" and the player skips a crate they would have caught;
-- understating it sends them on a flight they were going to make anyway, and
-- Route's grace period absorbs arriving a little late. /ewc travel overrides
-- any of these per zone.
local ZONES = {
    [2395] = { name = "Eversong Woods",  abbr = "ES", interval = 1100, travel = 45 },
    [2405] = { name = "Voidstorm",       abbr = "VS", interval = 1100, travel = 75 },
    [2413] = { name = "Harandar",        abbr = "HA", interval = 1100, travel = 75 },
    [2437] = { name = "Zul'Aman",        abbr = "ZA", interval = 1100, travel = 90 },
    [2444] = { name = "Slayer's Rise",   abbr = "SR", interval = 1100, travel = 90 },
    [2512] = { name = "The Coiled Isle", abbr = "CI", interval = 1100, travel = 75 },
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
    local n, mean, _, _, cycles = ns.Timers.GapStats(ns.db.gaps, zoneID)
    if n and cycles and cycles >= MEASURED_MIN_CYCLES then
        return mean
    end
    return shipped
end

function ns.GetShippedInterval(zoneID)
    return ZONES[zoneID] and ZONES[zoneID].interval or 1100
end

-- Seconds from the capital to a drop point here. A value the player has set
-- wins over the shipped estimate, which is what the estimates are for.
function ns.GetZoneTravel(zoneID)
    local override = ns.db and ns.db.travel and ns.db.travel[zoneID]
    if override then return override end
    local z = ZONES[zoneID]
    return z and z.travel or 90
end

function ns.GetZoneName(zoneID)
    local z = ZONES[zoneID]
    return z and z.name or ("Zone " .. tostring(zoneID))
end
