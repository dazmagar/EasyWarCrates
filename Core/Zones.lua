local ADDON, ns = ...

-- Turning whatever map id the game hands us into one of the tracked crate
-- zones, or nil.
--
-- getInfo is injected so tests can hand this a fake map tree; it falls back to
-- C_Map.GetMapInfo in game. The fallback is resolved inside the function, not
-- at load, so this file still loads under a plain Lua interpreter.

local Zones = {}
ns.Zones = Zones

-- Enum.UIMapType.Zone. Read from the game when it is there so a renumbering
-- cannot silently break this, with the current value as the fallback tests use.
local ZONE_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

-- The map tree is shallow; anything deeper than this is not a map hierarchy.
local MAX_DEPTH = 8

-- Walks up to the FIRST Zone-type map containing this one, and stops there.
--
-- That single word is the whole difference from RCT, which keeps walking and
-- keeps overwriting its answer, so it ends up at the OUTERMOST zone instead.
-- That is why standing in Silvermoon City registers there as standing in
-- Eversong Woods, which then needs a sanctuary check, which then misfires on
-- the way out of the city and blinks the zone's row off the tracker. Stopping
-- at the innermost zone makes all of it unnecessary: Silvermoon resolves to
-- Silvermoon, which simply is not a tracked zone. A micro-dungeon or a delve
-- entrance is not Zone-type at all, so it still walks up to the zone holding
-- it, which is the behaviour we actually wanted from the walk.
function Zones.Normalize(mapID, getInfo)
    mapID = tonumber(mapID)
    if not mapID then return nil end

    getInfo = getInfo or function(id) return C_Map.GetMapInfo(id) end

    local aliased = ns.ZONE_ALIAS[mapID]
    if aliased then mapID = aliased end

    -- Already a tracked zone: no map lookup needed at all. This is the hot
    -- path, hit on every vignette scan.
    if ns.ZONES[mapID] then return mapID end

    local info, depth = getInfo(mapID), 0
    while info and depth < MAX_DEPTH do
        depth = depth + 1
        if info.mapType == ZONE_TYPE then
            local id = ns.ZONE_ALIAS[info.mapID] or info.mapID
            return ns.ZONES[id] and id or nil
        end
        local parent = info.parentMapID
        if not parent or parent == 0 then return nil end
        info = getInfo(parent)
    end

    return nil
end

function Zones.IsTracked(mapID)
    return ns.ZONES[tonumber(mapID) or -1] ~= nil
end

Zones.ZONE_TYPE = ZONE_TYPE
