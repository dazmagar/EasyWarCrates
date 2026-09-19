local ADDON, ns = ...

-- Adding drop spots the shipped catalogue does not know.
--
-- Not speculative: the catalogue is built from Wowhead's crowdsourced spawn
-- records, and Voidstorm proved those are incomplete -- RCT's own farmed list
-- has two spots there, 12% and 24% of the map away from anything we ship. A
-- crate heading for one of those would be mispredicted or refused. Patches
-- will move things too.
--
-- Pure table maths, so tests/ covers it. The store is passed in rather than
-- read from ns.db, which is what keeps it testable.

local Learn = {}
ns.Learn = Learn

-- A landing this close to a known spot IS that spot, scattered. Measured
-- worst-case scatter is 0.86% of the map, so 2% leaves room without being
-- loose enough to swallow a genuinely separate spot -- the closest pair in the
-- whole shipped catalogue is 1% apart and spec_droppoints pins that.
local MERGE_RADIUS = 0.02
Learn.MERGE_RADIUS = MERGE_RADIUS

-- A zone cannot really sprout this many drop points. If it looks like it has,
-- something is feeding junk in and the cap stops it growing without bound.
local MAX_PER_ZONE = 24
Learn.MAX_PER_ZONE = MAX_PER_ZONE

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function nearest(list, x, y)
    local best, bestD
    for i = 1, #(list or {}) do
        local s = list[i]
        local d = dist(s.x, s.y, x, y)
        if not bestD or d < bestD then best, bestD = s, d end
    end
    return best, bestD
end

-- Returns "known" | "reinforced" | "learned" | "full" | "invalid".
--
-- "known" means a shipped spot already covers it, and nothing is stored: the
-- shipped catalogue is never edited, so a bad reading cannot corrupt it.
function Learn.Note(store, zoneID, x, y)
    if type(store) ~= "table" or not zoneID then return "invalid" end
    if type(x) ~= "number" or type(y) ~= "number" then return "invalid" end
    if x < 0 or x > 1 or y < 0 or y > 1 then return "invalid" end

    local _, shippedD = nearest(ns.ShippedDropPoints(zoneID), x, y)
    if shippedD and shippedD <= MERGE_RADIUS then return "known" end

    store[zoneID] = store[zoneID] or {}
    local zone = store[zoneID]

    local hit, hitD = nearest(zone, x, y)
    if hit and hitD <= MERGE_RADIUS then
        -- Seen again. Average it in, so a spot converges on where crates
        -- really land instead of being pinned to whichever sighting was first.
        local n = hit.n + 1
        hit.x = (hit.x * hit.n + x) / n
        hit.y = (hit.y * hit.n + y) / n
        hit.n = n
        return "reinforced", hit
    end

    if #zone >= MAX_PER_ZONE then return "full" end
    zone[#zone + 1] = { x = x, y = y, n = 1, learned = true }
    return "learned", zone[#zone]
end

-- Shipped plus learned, for prediction. Built fresh rather than cached: it is
-- read once per prediction, not per frame, and a stale cache here would mean
-- silently predicting against a catalogue that no longer exists.
function Learn.Merged(store, zoneID)
    local shipped = ns.ShippedDropPoints(zoneID)
    local extra = store and store[zoneID]
    if not extra or #extra == 0 then return shipped end

    local out = {}
    for i = 1, #(shipped or {}) do out[#out + 1] = shipped[i] end
    for i = 1, #extra do out[#out + 1] = extra[i] end
    return out
end

function Learn.Count(store)
    local spots, zones = 0, 0
    for _, list in pairs(store or {}) do
        if #list > 0 then zones = zones + 1; spots = spots + #list end
    end
    return spots, zones
end

-- What the rest of the addon asks for. Data/DropPoints.lua owns the shipped
-- table and exposes it as ns.ShippedDropPoints; this is the only accessor that
-- includes what the player has learned since.
function ns.GetDropPoints(zoneID)
    return Learn.Merged(ns.db and ns.db.learned, zoneID)
end
