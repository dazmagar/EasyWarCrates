local ADDON, ns = ...

-- Where a shard's cycle sits, kept long after the timer for it was pruned.
--
-- The cycle is period-locked, so a spawn seen on Zul'Aman shard 6476 yesterday
-- still says exactly where that shard's cycle sits today. Prune throws the
-- entry away after six cycles, and rightly: a wall of rows for shards nobody
-- will stand in again is the whole complaint against RCT. But legibility is a
-- display problem, and deleting to tidy a list threw away the one thing that
-- makes landing on a known shard worth anything.
--
-- What genuinely degrades is the arithmetic. Extrapolating across n cycles
-- multiplies the interval's own uncertainty by n: Zul'Aman's gaps measure
-- 1091 to 1099, so four seconds a cycle, which is a minute after fifteen
-- cycles and five minutes after a day. Recall refuses once that error passes
-- what the answer is worth, rather than handing back a number with the error
-- hidden inside it.
--
-- Pure table maths, so tests/ covers it.

local Phase = {}
ns.Phase = Phase

-- How wrong a recalled phase may be and still be worth showing. A countdown
-- out by more than this is not a countdown, it is a direction.
local TOLERANCE = 90
Phase.TOLERANCE = TOLERANCE

-- Used when a zone's interval has never been measured here. The three addons
-- that ship a figure disagree by five seconds, and the measured gaps scatter
-- wider than that, so this is deliberately pessimistic.
local UNKNOWN_DRIFT = 8
Phase.UNKNOWN_DRIFT = UNKNOWN_DRIFT

-- A phase older than this is not kept at all. Well past the point where the
-- drift makes it useless, so nothing is discarded that could still have
-- answered; this only stops the store growing for ever.
local KEEP = 7 * 24 * 3600
Phase.KEEP = KEEP

-- How far the anchor itself may be out, before a single cycle is extrapolated.
-- Drift answers how well the cycle LENGTH is known; this answers how well its
-- STARTING POINT was, and the two are independent.
--
-- A mid-fall join is why this exists. It looks like a falling sighting and is
-- worth nothing like one: the crate left the transport an unknown time
-- earlier. Three of four descents on 24 Sep were mid-fall joins, so most of
-- what the memory holds is anchored this way, and every one of them was being
-- reported to two seconds.
--
-- The back-computed sources share a figure because they share a cause: each
-- subtracts an assumed descent from when it was found, and the descent
-- readings run 79 to 134, so the assumption can be most of a minute out.
local ANCHOR_ERROR = {
    yell     = 3,
    flying   = 5,
    falling  = 10,
    midfall  = 45,
    ground   = 45,
    claimed  = 45,
    anchor   = 45,   -- somebody else's, offered without saying how they got it
    manual   = 45,
}
local ANCHOR_UNKNOWN = 45
Phase.ANCHOR_ERROR = ANCHOR_ERROR
Phase.ANCHOR_UNKNOWN = ANCHOR_UNKNOWN

function Phase.AnchorError(source)
    return ANCHOR_ERROR[source] or ANCHOR_UNKNOWN
end

function Phase.New()
    return {}
end

-- Files a spawn against its shard. Keeps the freshest, because every cycle of
-- extrapolation costs accuracy and the newest anchor costs the fewest.
function Phase.Remember(store, zoneID, shardID, ts, source)
    if type(store) ~= "table" or not zoneID or shardID == nil then return nil end
    ts = tonumber(ts)
    if not ts then return nil end

    store[zoneID] = store[zoneID] or {}
    local held = store[zoneID][shardID]
    if held and held.ts >= ts then return held end
    store[zoneID][shardID] = { ts = ts, source = source or "unknown" }
    return store[zoneID][shardID]
end

-- How far a cycle's length is uncertain, per cycle, from what this client has
-- actually observed. The spread of the readings, not their mean: two
-- observations agreeing to a second say more than ten scattered over a minute.
-- Measured off the readings that agree, and then divided by how many agree.
--
-- The full range was the first attempt and it was badly wrong: it is set by
-- the worst pairing in the pile and grows wider the more readings arrive, so
-- more evidence made the addon trust itself less. Zul'Aman came out at 19
-- seconds a cycle on gaps whose core spans eight.
--
-- What matters is how well the cycle length itself is known, which improves as
-- readings accumulate. A quarter of the cluster's spread stands in for one
-- standard deviation; dividing by the root of the count is the standard error
-- of the figure actually being used.
function Phase.Drift(gapStore, zoneID, clusterOf)
    local _, n, lo, hi = clusterOf(gapStore, zoneID)
    if not n or n < 3 or not lo or not hi then return UNKNOWN_DRIFT end
    local sigma = (hi - lo) / 4
    local err = sigma / math.sqrt(n)
    return err > 0.25 and err or 0.25
end

-- The remembered spawn for this shard, or nil plus why not.
--
-- Returns the timestamp, how many cycles were extrapolated across, and how far
-- out the answer could be by the end of them.
function Phase.Recall(store, zoneID, shardID, interval, now, drift, tolerance)
    local held = store and store[zoneID] and store[zoneID][shardID]
    if not held then return nil, "nothing remembered" end

    interval = tonumber(interval)
    if not interval or interval <= 0 then return nil, "no interval" end

    local elapsed = (tonumber(now) or 0) - held.ts
    if elapsed < 0 then return nil, "in the future" end
    if elapsed > KEEP then return nil, "too old to keep" end

    local cycles = math.floor(elapsed / interval)
    local error = cycles * (tonumber(drift) or UNKNOWN_DRIFT)
        + Phase.AnchorError(held.source)
    if error > (tonumber(tolerance) or TOLERANCE) then
        return nil, "drifted too far", cycles, error
    end
    return held.ts, nil, cycles, error, held.source
end

-- Drops what has aged past keeping. Returns how many went.
function Phase.Forget(store, now)
    local removed = 0
    for zoneID, shards in pairs(store or {}) do
        for shardID, held in pairs(shards) do
            if (now - held.ts) > KEEP then
                shards[shardID] = nil
                removed = removed + 1
            end
        end
        if not next(shards) then store[zoneID] = nil end
    end
    return removed
end

-- Everything the timers currently hold, filed before anything prunes them.
-- Called where Prune is, because the one thing that must not happen is the
-- pruning running first.
function Phase.Absorb(store, crates)
    local kept = 0
    for zoneID, shards in pairs(crates or {}) do
        for shardID, entry in pairs(shards) do
            -- "memory" is skipped, not because it is worthless, but because
            -- it came from here: re-filing it would relabel whatever
            -- originally anchored it as something with no anchor error.
            if entry.ts and entry.source ~= "memory"
                and Phase.Remember(store, zoneID, shardID, entry.ts, entry.source) then
                kept = kept + 1
            end
        end
    end
    return kept
end
