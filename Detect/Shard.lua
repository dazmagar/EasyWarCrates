local ADDON, ns = ...

-- Reading the shard out of a GUID.
--
-- A creature GUID is Creature-0-<server>-<instance>-<shard>-<npc>-<spawn>.
-- Field five is really the zone UID, but it is what changes when the game
-- moves you between copies of a zone, so it is what everyone tracking crates
-- means by "shard".
--
-- Every read goes through a pcall. Midnight has started handing back "secret
-- strings": type() still says string, but any comparison, concat or pattern
-- op on one throws while tainted. So the only test allowed outside the pcall
-- is type(). RCT hit this as a Lua error spamming in populated zones.
--
-- Parsed with string.match rather than strsplit, which keeps this file plain
-- Lua and therefore testable outside the game. Matching five fields
-- positionally also survives an empty field, where splitting on "-" and
-- indexing would silently shift every field along.

local Shard = {}
ns.Shard = Shard

local GUID_HEAD = "^([^-]*)-([^-]*)-([^-]*)-([^-]*)-([^-]*)"

-- Returns shard, instance -- or nil, nil if the GUID is unreadable. Never
-- throws.
function Shard.FromGUID(guid)
    if type(guid) ~= "string" then return nil, nil end
    local ok, shard, instance = pcall(function()
        local _, _, _, inst, sh = string.match(guid, GUID_HEAD)
        return tonumber(sh), tonumber(inst)
    end)
    if not ok then return nil, nil end
    return shard, instance
end

-- Vignette GUIDs do not always follow the creature layout. Try it first, then
-- fall back to the last long run of digits, which is where the zone UID sits
-- in the shapes observed so far.
function Shard.FromVignetteGUID(guid)
    if type(guid) ~= "string" then return nil end
    local shard = Shard.FromGUID(guid)
    if shard then return shard end

    local ok, last = pcall(function()
        local found
        for run in string.gmatch(guid, "%d+") do found = run end
        return found
    end)
    if not ok or not last then return nil end
    local n = tonumber(last)
    return (n and n > 0) and n or nil
end

-- Safe for a debug print: tostring on a secret string can itself throw.
function Shard.Label(guid)
    local ok, s = pcall(tostring, guid)
    return ok and s or "<unreadable guid>"
end
