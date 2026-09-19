local ADDON, ns = ...

-- The farming rotation.
--
-- Pure table maths, so tests/ covers it.
--
-- Modelled on how raids actually run this, which is not how a sorted timer list
-- implies. A crate gets taken, the raid takes a mage portal to the capital, and
-- flies out from there to the next zone on a route agreed beforehand -- usually
-- three to five zones cycled round. Nobody flies zone to zone.
--
-- Two things follow, and both make this smaller than it looks. Travel is always
-- capital-to-zone, so it is one number per zone rather than a matrix over every
-- pair. And the route is a list the raid chose, not something to infer: the job
-- is not to work out where to go, it is to say when to leave.
--
-- That last part is what a plain sorted list gets wrong. A drop 40 seconds out
-- in a zone four minutes away is not "next" in any useful sense -- it is a drop
-- you will miss, sitting above the one you could actually catch.

local Route = {}
ns.Route = Route

-- Used when a zone has no measured capital-to-zone time yet. Deliberately a
-- single number and deliberately rough: it is a placeholder to be replaced by
-- measurement, not a figure anyone should trust.
local DEFAULT_TRAVEL = 60
Route.DEFAULT_TRAVEL = DEFAULT_TRAVEL

-- Leaving this late still counts as catchable. A crate sits on the ground a
-- while before anyone opens it, and arriving a few seconds after it lands is
-- normal farming, not a miss.
local GRACE = 20
Route.GRACE = GRACE

-- The timer to show for a zone when several shards are on record. The raid is
-- on one shard and re-rolls it every time it ports out and flies back, so no
-- stored shard is knowably the right one. The freshest is the best guess
-- available, and callers are expected to say so rather than imply certainty.
function Route.FreshestForZone(db, zoneID)
    local shards = db and db[zoneID]
    if not shards then return nil end
    local best, bestShard
    for shardID, entry in pairs(shards) do
        if not best or (entry.ts or 0) > (best.ts or 0) then best, bestShard = entry, shardID end
    end
    return best, bestShard
end

-- Builds the plan for a route.
--
--   zones        ordered list of zone ids, as the raid agreed them
--   intervalOf   f(zoneID) -> seconds between drops
--   travelOf     f(zoneID) -> seconds from the capital to that zone
--   now          server time
--
-- Returns a list ordered by drop time, each entry carrying:
--   dropIn    seconds until the crate drops there
--   leaveIn   seconds until you have to set off; negative means you are late
--   status    "go"      leave now, or you are inside the grace period
--             "wait"    there is time in hand
--             "missed"  cannot be reached even leaving this instant
--             "unknown" nothing has ever been timed in that zone
function Route.Plan(db, zones, intervalOf, travelOf, now)
    local out = {}
    for i = 1, #(zones or {}) do
        local zoneID = zones[i]
        local entry, shardID = Route.FreshestForZone(db, zoneID)
        local travel = travelOf(zoneID) or DEFAULT_TRAVEL

        local row = { zoneID = zoneID, shardID = shardID, entry = entry, travel = travel, order = i }
        if not entry then
            row.status = "unknown"
        else
            local dropIn = ns.Timers.Remaining(entry, intervalOf(zoneID), now)
            row.dropIn = dropIn
            row.missed = ns.Timers.MissedCycles(entry, intervalOf(zoneID), now)
            row.leaveIn = dropIn and (dropIn - travel) or nil
            if not dropIn then
                row.status = "unknown"
            elseif row.leaveIn >= 0 then
                row.status = "wait"
            elseif row.leaveIn >= -GRACE then
                row.status = "go"
            else
                row.status = "missed"
            end
        end
        out[#out + 1] = row
    end

    -- Chronological, with everything untimed at the end. A raid reads this
    -- top-down to decide where it is going next.
    table.sort(out, function(a, b)
        if a.dropIn and b.dropIn then
            if a.dropIn ~= b.dropIn then return a.dropIn < b.dropIn end
            return a.order < b.order
        end
        if a.dropIn then return true end
        if b.dropIn then return false end
        return a.order < b.order
    end)
    return out
end

-- The one row worth acting on: the soonest drop still reachable. nil when the
-- whole route is out of reach or untimed.
function Route.Next(plan)
    for i = 1, #(plan or {}) do
        local row = plan[i]
        if row.status == "go" or row.status == "wait" then return row end
    end
    return nil
end

-- Parses "ZA Hd SR VS" into zone ids. Returns the list plus anything that did
-- not resolve, so the caller can say which word it did not understand instead
-- of silently dropping it.
function Route.Parse(text)
    local zones, bad, seen = {}, {}, {}
    for word in tostring(text or ""):gmatch("[%a']+") do
        local zoneID = ns.ResolveZoneInput(word)
        if not zoneID then
            bad[#bad + 1] = word
        elseif not seen[zoneID] then
            seen[zoneID] = true
            zones[#zones + 1] = zoneID
        end
    end
    return zones, bad
end

function Route.Describe(zones)
    local parts = {}
    for i = 1, #(zones or {}) do parts[i] = ns.GetZoneAbbr(zones[i]) end
    return table.concat(parts, " ")
end
