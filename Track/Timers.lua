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

    -- A genuinely later drop on the same zone and shard. The gap to the
    -- previous one is the only direct measurement of the respawn interval
    -- anybody gets, so it is kept before the timestamp is overwritten.
    entry.prevTs = entry.ts
    entry.gap = gap
    entry.ts = ts
    entry.source = source or "manual"
    entry.precise = rank(source) >= 2
    entry.seen = 1
    return "new", entry, gap
end

-- Sanity bounds on an observed gap, in seconds. Deliberately wide.
--
-- The three addons that ship an interval disagree -- 1095, 1098 and 1100 --
-- and HGLog only accepts an observation between 1090 and 1105, which means its
-- learning can confirm the figure it was given and can never discover a
-- different one. A band that narrow is not a measurement, it is an assumption
-- wearing a measurement's clothes. These bounds exist only to reject a gap
-- that is obviously not one cycle.
local GAP_MIN, GAP_MAX = 240, 7200
Timers.GAP_MIN, Timers.GAP_MAX = GAP_MIN, GAP_MAX

-- Files an observed gap. cycles says how many drops it spans: sitting in one
-- zone watching gives 1, and anything more is a gap across drops that were
-- missed, which still measures the interval but less sharply.
--
-- Raw observations are kept rather than folded into a running mean. The point
-- of collecting these is to find out what the interval IS, and a mean cannot
-- show whether the values cluster tightly or scatter.
function Timers.NoteGap(store, zoneID, gap, expected)
    if type(store) ~= "table" or not zoneID then return nil end
    gap = tonumber(gap)
    if not gap or gap < GAP_MIN or gap > GAP_MAX then return nil end

    expected = tonumber(expected) or 1100
    local cycles = math.max(1, math.floor(gap / expected + 0.5))

    store[zoneID] = store[zoneID] or {}
    local list = store[zoneID]
    list[#list + 1] = { gap = gap, cycles = cycles, per = gap / cycles }
    while #list > 50 do table.remove(list, 1) end
    return list[#list]
end

-- count, mean, min, max over the single-cycle observations for a zone, or nil.
function Timers.GapStats(store, zoneID)
    local list = store and store[zoneID]
    if not list or #list == 0 then return nil end
    local sum, lo, hi, n = 0, nil, nil, 0
    for _, g in ipairs(list) do
        n = n + 1
        sum = sum + g.per
        if not lo or g.per < lo then lo = g.per end
        if not hi or g.per > hi then hi = g.per end
    end
    return n, sum / n, lo, hi
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

-- A timer this many cycles stale is not worth keeping. The shard re-rolls
-- every time you leave a zone and fly back, so entries pile up for shards you
-- will never stand in again -- three different Zul'Aman shards inside one
-- evening's farming. An old entry still predicts that shard correctly; the
-- problem is that returning to it is chance, so what it really contributes is
-- a wall of dead rows to read past.
--
-- Generous on purpose: six cycles is nearly two hours, well past any raid's
-- interest, and pruning is about legibility rather than saving space.
local STALE_CYCLES = 6
Timers.STALE_CYCLES = STALE_CYCLES

-- Returns how many were dropped. intervalOf is passed in so this stays pure.
function Timers.Prune(db, intervalOf, now)
    local removed = 0
    for zoneID, shards in pairs(db or {}) do
        local interval = intervalOf(zoneID)
        for shardID, entry in pairs(shards) do
            local missed = Timers.MissedCycles(entry, interval, now)
            if missed and missed > STALE_CYCLES then
                shards[shardID] = nil
                removed = removed + 1
            end
        end
        if not next(shards) then db[zoneID] = nil end
    end
    return removed
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
