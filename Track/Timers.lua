local ADDON, ns = ...

-- The crate timers. Pure table maths, no WoW API, so tests/ covers it.
--
-- Keyed zone THEN shard. RCT keeps one row per zone and loses the others,
-- which is why it needs a second bundled addon (HGLog) to hold per-shard
-- timers and a suggestion row to copy them back. WarCrateTracker and
-- CrateTrackerZK both key by zone+shard. Doing it here from the start means
-- there is nothing to bolt on later.

local Timers = {}
ns.Timers = Timers

-- How well a sighting pins the moment the crate actually spawned. Catching the
-- transport is the real anchor; finding a crate already on the ground says
-- only that one spawned some minutes ago. Nothing here corrects for that yet
-- and no timer pretends otherwise -- Entry.precise is what the UI reads to
-- decide whether to show a countdown or a "~" estimate.
local PRECISION = {
    flying   = 3,   -- the transport, caught in the air
    falling  = 2,   -- under its parachute
    ground   = 1,   -- found already landed
    claimed  = 1,   -- found already looted
    manual   = 0,   -- typed in by hand
}
Timers.PRECISION = PRECISION

-- Two sightings closer together than this are the same crate seen twice, not
-- two drops. Well under the ~1100s cycle, well over the time a crate spends
-- visible going flying -> parachute -> ground.
local SAME_CRATE = 300
Timers.SAME_CRATE = SAME_CRATE

local function rank(source)
    return PRECISION[source or "manual"] or 0
end

function Timers.New()
    return {}
end

function Timers.Get(db, zoneID, shardID)
    local z = db and db[zoneID]
    return z and z[shardID] or nil
end

-- Returns one of "new", "refined", "duplicate", "stale", "invalid", plus the
-- entry. Callers key off the verdict: only "new" and "refined" are worth
-- redrawing or announcing for.
function Timers.Record(db, zoneID, shardID, ts, source)
    if type(db) ~= "table" then return "invalid" end
    if not zoneID or not shardID then return "invalid" end
    ts = tonumber(ts)
    if not ts then return "invalid" end

    db[zoneID] = db[zoneID] or {}
    local zone = db[zoneID]
    local entry = zone[shardID]

    if not entry then
        zone[shardID] = { ts = ts, source = source or "manual", precise = rank(source) >= 2, seen = 1 }
        return "new", zone[shardID]
    end

    local gap = ts - entry.ts

    if gap < -SAME_CRATE then
        -- News about a crate older than the one we already hold.
        return "stale", entry
    end

    if gap <= SAME_CRATE then
        entry.seen = (entry.seen or 1) + 1
        -- The same crate, sighted again. Only a better-anchored sighting may
        -- move the timestamp; otherwise a late "found it on the ground" would
        -- drag a good flying-catch forward by minutes.
        if rank(source) > rank(entry.source) then
            entry.ts = ts
            entry.source = source
            entry.precise = rank(source) >= 2
            return "refined", entry
        end
        return "duplicate", entry
    end

    entry.ts = ts
    entry.source = source or "manual"
    entry.precise = rank(source) >= 2
    entry.seen = 1
    return "new", entry
end

function Timers.NextSpawn(entry, interval, now)
    if type(entry) ~= "table" or not entry.ts then return nil end
    interval = tonumber(interval)
    if not interval or interval <= 0 then return nil end
    local cycles = math.floor((now - entry.ts) / interval)
    if cycles < 0 then cycles = -1 end
    return entry.ts + (cycles + 1) * interval
end

function Timers.Remaining(entry, interval, now)
    local next_ = Timers.NextSpawn(entry, interval, now)
    return next_ and (next_ - now) or nil
end

-- Drops that happened since this entry was recorded and that nobody saw. A
-- high count means the timer is a guess carried forward, not an observation.
function Timers.MissedCycles(entry, interval, now)
    if type(entry) ~= "table" or not entry.ts then return nil end
    interval = tonumber(interval)
    if not interval or interval <= 0 then return nil end
    local cycles = math.floor((now - entry.ts) / interval)
    return cycles > 0 and cycles or 0
end

-- Every tracked entry, flattened, soonest first. The UI wants a list, not a
-- nested table.
function Timers.Sorted(db, intervalOf, now)
    local out = {}
    for zoneID, shards in pairs(db or {}) do
        local interval = intervalOf(zoneID)
        for shardID, entry in pairs(shards) do
            out[#out + 1] = {
                zoneID = zoneID,
                shardID = shardID,
                entry = entry,
                remaining = Timers.Remaining(entry, interval, now),
                missed = Timers.MissedCycles(entry, interval, now),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.remaining == b.remaining then
            if a.zoneID == b.zoneID then return tostring(a.shardID) < tostring(b.shardID) end
            return a.zoneID < b.zoneID
        end
        if not a.remaining then return false end
        if not b.remaining then return true end
        return a.remaining < b.remaining
    end)
    return out
end
