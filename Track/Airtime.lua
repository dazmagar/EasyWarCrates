local ADDON, ns = ...

-- How long until the crate is on the ground.
--
-- Pure maths, so tests/ covers it.
--
-- Two legs. The transport flies to its drop point and releases; the crate then
-- falls under a parachute.
--
-- The second cannot be computed -- nothing observable says how high the crate
-- was released -- so it is measured, per zone. Readings so far: 86, 86, 87 in
-- three zones, and 98 and 129 in Zul'Aman at the SAME drop point. Thirty-one
-- seconds apart at one spot means splitting by drop point, as RCT does, would
-- not fix it; either the descent really varies that much or the measurement
-- does.
--
-- The first was built as arithmetic, on the reasoning that the heading fit
-- already knows the transport's speed and the prediction already knows where
-- it is going, so the time to release is a division that works on the first
-- flight in a zone nobody has visited -- where RCT would still say "Learning".
--
-- That reasoning has not survived contact. Errors of +16, +22, +29, +31 and
-- +54 seconds say the transport neither flies straight to its drop point nor
-- holds its speed, and an estimate that can be out by a factor of three is
-- worse than a warm-up. Measuring the leg vignette to vignette, which is what
-- RCT does, has neither problem by construction. Left as it is for now because
-- the bias correction below keeps it usable and the position prediction --
-- which is what the addon is actually for -- does not depend on it, but this
-- is the part to replace next.

local Airtime = {}
ns.Airtime = Airtime

-- The descent is measured from the crate's own on-ground vignette, and
-- deliberately not inferred from the parachute vignette going away.
--
-- RCT infers it: if the parachute has not been seen for sixty seconds it
-- decides the crate landed, and dates the landing to the last sighting plus
-- fifteen. That fires whenever the player simply moves out of range of a crate
-- still in the air, so every such flight teaches its model a descent shorter
-- than the real one. Watched side by side, RCT's countdown reached "on the
-- ground" with about thirty seconds of falling left -- short, which is the
-- direction that inference biases.
--
-- The on-ground vignette is supposedly a brief blip that is easy to miss, and
-- that is the reason they infer. It has not been a problem here: every descent
-- so far was captured, and one checked against a player watching the crate
-- land agreed to a second. Do not add the inference without first showing that
-- readings are actually being lost.
--
-- Sanity bounds on a measured descent, seconds. Wide: an observed drop took
-- about 1.5 to 2 minutes, and RCT clamps its own descent at 200, so anything
-- inside this range is plausible and anything outside is a mis-paired reading.
local DESCENT_MIN, DESCENT_MAX = 5, 240
Airtime.DESCENT_MIN, Airtime.DESCENT_MAX = DESCENT_MIN, DESCENT_MAX

-- Used before a zone has been measured, so the readout can show a number with
-- a caveat rather than nothing at all. Midway through the observed range.
local DESCENT_GUESS = 100
Airtime.DESCENT_GUESS = DESCENT_GUESS

-- Below this many samples the mean is shown but flagged as provisional.
local CONFIDENT_N = 3
Airtime.CONFIDENT_N = CONFIDENT_N

-- overlapped says the parachute and on-ground vignettes were live in the same
-- sweep. The game does that: a crate can be down while its parachute is still
-- drawn, seen live in Zul'Aman. When it happens the landing moment is
-- ambiguous, so the reading may run long.
--
-- Flagged rather than rejected. Whether an overlapped reading is actually
-- biased is a question the samples can answer and guessing cannot, and
-- throwing away every reading from a lifecycle that misbehaves regularly would
-- leave very little data.
--
-- Samples are kept individually rather than folded into a running sum, for the
-- same reason the interval gaps are: with one reading per zone a mean is not a
-- measurement, and the spread is the thing worth seeing.
-- info carries the diagnostics, as a table, because another one joined and the
-- eighth positional argument was already one too many:
--
--   overlapped  parachute and on-ground vignettes were live in the same sweep
--   partial     the parachute was already in the air when we first saw it
--   pos         where it landed
--   dist        how far the player stood from it, percent of map
--   lag         how long the transport circled before letting go
--   flip        when the parachute's art changed, if it did
function Airtime.NoteDescent(store, zoneID, seconds, info)
    if type(store) ~= "table" or not zoneID then return nil end
    seconds = tonumber(seconds)
    if not seconds or seconds < DESCENT_MIN or seconds > DESCENT_MAX then return nil end
    info = info or {}
    local pos = info.pos

    local list = store[zoneID]
    if type(list) ~= "table" or list.n then
        -- Either nothing yet, or the old running-sum shape. Start clean rather
        -- than mixing two shapes in one table.
        list = {}
        store[zoneID] = list
    end
    -- Where it landed, rounded to a tenth of a percent of the map. Zul'Aman
    -- has produced descents of 83 and 129 seconds where four other zones sit
    -- inside 84-87, and elevation is the obvious suspect: lower ground under
    -- the drop point means a longer fall. Whether that is really it can only
    -- be answered by knowing which spot each reading came from, and until now
    -- it was not recorded -- so the question could be argued but not settled.
    list[#list + 1] = {
        secs = seconds,
        overlapped = info.overlapped or nil,
        partial = info.partial or nil,
        lag = info.lag and math.floor(info.lag + 0.5) or nil,
        flip = info.flip and math.floor(info.flip + 0.5) or nil,
        -- Eversong reads 14, 43 and 84 against a 86 cluster in four other
        -- zones. If a parachute is only drawn once it has fallen into
        -- vignette range then every distant reading is truncated, and how far
        -- away the player stood is the number that would show it.
        dist = info.dist and math.floor(info.dist * 10 + 0.5) / 10 or nil,
        x = pos and math.floor(pos.x * 1000 + 0.5) / 10 or nil,
        y = pos and math.floor(pos.y * 1000 + 0.5) / 10 or nil,
    }
    while #list > 40 do table.remove(list, 1) end
    return list[#list]
end

-- typical, n, min, max, overlappedCount, partialCount -- or the guess, n = 0.
--
-- The middle reading, not the mean. Harandar has measured 86, 86, 87, 61, 19,
-- 86, 86: five of seven agree on 86-87 and the mean is 73, which describes no
-- drop that has ever happened there. Both tails are real and neither is
-- symmetric -- a crate can catch on a branch and be down early, and the game
-- can hold its parachute on screen for another half minute after it lands --
-- so the middle is the only summary that survives them.
--
-- Partial readings are counted and shown but kept out of the mean. Timing a
-- descent from a parachute that was already in the air when the player arrived
-- measures however much of the fall they happened to catch, which is a lower
-- bound on the real figure; averaged in with complete readings it pulls the
-- answer down by an unknowable amount every time.
-- Readings this close together are describing the same thing.
local CLUSTER_WINDOW = 10
-- Below this, a cluster is a coincidence rather than an agreement.
local CLUSTER_MIN = 3
Airtime.CLUSTER_WINDOW, Airtime.CLUSTER_MIN = CLUSTER_WINDOW, CLUSTER_MIN

local function median(sorted, from, to)
    local n = to - from + 1
    if n % 2 == 1 then return sorted[from + (n - 1) / 2] end
    return (sorted[from + n / 2 - 1] + sorted[from + n / 2]) / 2
end

-- The densest run of readings that agree, as first and last index into a
-- sorted list. nil when nothing agrees with anything.
--
-- A plain median cannot survive this data. Eversong holds 14, 43, 84 and 92
-- and its median is 64, which describes no drop that has ever happened there;
-- Slayer's Rise reads 103 the same way. The tails are not the descent varying.
-- Zul'Aman measured 85 and 44 at one drop point and Slayer's Rise 91 and 134
-- at another, so the same crate falling on the same spot reads forty seconds
-- apart -- that is the measurement, not the fall. Both tails have a mechanism:
-- a parachute seen late reads short, an on-ground vignette seen late reads
-- long. What is left when they are set aside is a cluster near 86 in every
-- zone measured so far.
local function densest(sorted)
    local bestFrom, bestTo, bestN
    local from = 1
    for to = 1, #sorted do
        while sorted[to] - sorted[from] > CLUSTER_WINDOW do from = from + 1 end
        local n = to - from + 1
        if not bestN or n > bestN then bestFrom, bestTo, bestN = from, to, n end
    end
    if not bestN or bestN < CLUSTER_MIN then return nil end
    return bestFrom, bestTo, bestN
end

local function fullReadings(store, zoneID)
    local list = store and store[zoneID]
    if type(list) ~= "table" then return {}, 0, 0 end
    local full, over, part = {}, 0, 0
    for _, d in ipairs(list) do
        if d.partial then part = part + 1 else full[#full + 1] = d.secs end
        if d.overlapped then over = over + 1 end
    end
    table.sort(full)
    return full, over, part
end

-- typical, n, min, max, overlappedCount, partialCount, source.
--
-- source says where the figure came from: "zone" when this zone's own readings
-- agree, "pooled" when they do not and every zone's readings were used
-- instead, "guess" when there is nothing. n counts what the figure rests on,
-- not how many readings exist, because a figure resting on three agreeing
-- readings out of eleven is worth three.
-- The shared estimator. Both legs are a pile of readings with one-sided
-- contamination at each end, so they are summarised the same way.
local function describe(store, zoneID, guess)
    local full, over, part = fullReadings(store, zoneID)
    if #full == 0 then return guess, 0, nil, nil, over, part, "guess" end

    local from, to, n = densest(full)
    if from then
        return median(full, from, to), n, full[1], full[#full], over, part, "zone"
    end

    -- Too few readings to have disagreed. Two cannot form a cluster and two
    -- cannot contradict each other either, so the plain middle of what there
    -- is remains the best available answer -- and it is what a zone nobody has
    -- measured much would otherwise lose.
    if #full < CLUSTER_MIN then
        return median(full, 1, #full), #full, full[1], full[#full], over, part, "zone"
    end

    -- This zone has not agreed with itself. Every zone's readings together
    -- still cluster, and a figure from that beats a median of this zone's
    -- contradictions: Eversong would otherwise report 64 seconds.
    local pooled = {}
    for id in pairs(store or {}) do
        for _, secs in ipairs((fullReadings(store, id))) do pooled[#pooled + 1] = secs end
    end
    table.sort(pooled)
    local pf, pt, pn = densest(pooled)
    if pf then
        return median(pooled, pf, pt), pn, full[1], full[#full], over, part, "pooled"
    end
    return guess, 0, full[1], full[#full], over, part, "guess"
end

function Airtime.Descent(store, zoneID)
    return describe(store, zoneID, DESCENT_GUESS)
end

-- The individual readings, for inspection.
function Airtime.DescentSamples(store, zoneID)
    local list = store and store[zoneID]
    return (type(list) == "table" and not list.n) and list or nil
end

-- The first leg, measured rather than computed.
--
-- From the spawn to the moment the parachute opens. The addon has always
-- computed this from the fitted speed and the distance left to run, and it is
-- wrong by +16 to +64 seconds depending on the zone, because the transport
-- slows on approach and circles before letting go. An average speed cannot
-- know that; a stopwatch does not have to.
--
-- Only measurable from an anchor that really is the spawn. A yell is: the NPC
-- announces the cycle starting. Catching the transport in the air is not -- it
-- says when the transport came into range, which is a lower bound by however
-- long it had already been flying. Those are kept and flagged, the way a
-- parachute joined mid-fall is, and left out of the figure.
local FLIGHT_MIN, FLIGHT_MAX = 10, 400
Airtime.FLIGHT_MIN, Airtime.FLIGHT_MAX = FLIGHT_MIN, FLIGHT_MAX

-- Until a zone has been measured. Between the shortest and longest seen live.
local FLIGHT_GUESS = 90
Airtime.FLIGHT_GUESS = FLIGHT_GUESS

function Airtime.NoteFlight(store, zoneID, seconds, partial)
    if type(store) ~= "table" or not zoneID then return nil end
    seconds = tonumber(seconds)
    if not seconds or seconds < FLIGHT_MIN or seconds > FLIGHT_MAX then return nil end
    local list = store[zoneID]
    if type(list) ~= "table" then list = {}; store[zoneID] = list end
    list[#list + 1] = { secs = seconds, partial = partial or nil }
    while #list > 40 do table.remove(list, 1) end
    return list[#list]
end

-- Same shape and same estimator as the descent: the densest run of readings
-- that agree, falling back to every zone pooled when a zone contradicts
-- itself. Returns typical, n, min, max, unused, partialCount, source.
function Airtime.Flight(store, zoneID)
    local typical, n, lo, hi, over, part, source = describe(store, zoneID, FLIGHT_GUESS)
    return typical, n, lo, hi, over, part, source
end

-- How long ago a crate found lying on the ground actually spawned.
--
-- Both legs are measured now, so a crate on the ground is known to have left
-- its transport a descent ago and to have spawned a flight before that.
-- Seeding the timer at the moment somebody noticed it throws all of that away
-- and dates the spawn two and a half minutes late, every time.
--
-- What this cannot know is how long it lay there before anybody looked. So the
-- reading stays imprecise: the adjustment removes the part of the error that
-- is known and leaves the part that is not. RCT does the same thing and calls
-- it a spawn offset.
--
-- nil unless both legs rest on readings rather than the shipped guess. Built
-- from two guesses the correction would be a guess in a correction's clothes,
-- and it would move every timer without anybody having measured anything.
function Airtime.SpawnOffset(flightStore, descentStore, zoneID)
    local flight, fn, _, _, _, _, fsrc = Airtime.Flight(flightStore, zoneID)
    local descent, dn, _, _, _, _, dsrc = Airtime.Descent(descentStore, zoneID)
    if fsrc == "guess" or dsrc == "guess" then return nil end
    return flight + descent, fn + dn
end

-- How wrong the raw release estimate runs, pooled across zones.
--
-- This started as a correction for what looked like a constant bias: the first
-- flights promised release in 8 seconds and took 30 and 37. More flights have
-- made it clear it is not constant. The errors so far run +16, +22, +29, +31
-- and +54 -- a three-and-a-half-fold spread, which a mean cannot represent.
--
-- The cause is that ToRelease assumes the transport flies straight to its drop
-- point at the speed it has been holding, and it evidently does neither
-- reliably. RCT measures this leg vignette to vignette instead, which by
-- construction has neither the bias nor the spread; the reason given here for
-- computing it instead -- that measuring needs a warm-up -- bought an estimate
-- that can be out by a factor of three. That was the wrong trade.
--
-- The correction stays, since a late estimate corrected by its mean error is
-- better than a late one, but it applies only with enough observations to mean
-- anything, and the spread is reported so nobody reads the countdown as precise.
local BIAS_MIN_N = 5
Airtime.BIAS_MIN_N = BIAS_MIN_N

-- mean, n, spread (max error minus min) -- the spread is what says how much to
-- trust the mean.
function Airtime.ReleaseBias(store)
    local n, sum, lo, hi = 0, 0, nil, nil
    for _, acc in pairs(store or {}) do
        n = n + (acc.n or 0)
        sum = sum + (acc.sum or 0)
        if acc.lo and (not lo or acc.lo < lo) then lo = acc.lo end
        if acc.hi and (not hi or acc.hi > hi) then hi = acc.hi end
    end
    if n < BIAS_MIN_N then return 0, n, nil end
    return sum / n, n, (lo and hi) and (hi - lo) or nil
end

-- Seconds until the transport reaches the spot it was called for. nil when the
-- fit cannot support it. Never negative: a transport past its target is at it.
function Airtime.ToRelease(fit, target)
    if type(fit) ~= "table" or type(target) ~= "table" then return nil end
    if not fit.speed or fit.speed <= 0 then return nil end
    local dx, dy = target.x - fit.x, target.y - fit.y
    local along = dx * fit.hx + dy * fit.hy
    if along < 0 then along = 0 end
    return along / fit.speed
end

-- The whole readout, or nil when there is nothing to say.
--
--   toRelease  seconds until the crate is let go     (nil once it is falling)
--   toGround   seconds until it can be picked up
--   descentN   how many descents this zone has behind it; 0 means the
--              toGround figure rests on a guess and should be shown as such
--   phase      "inbound" | "falling" | "down"
--
-- fallingSince is when the parachute was first seen, if it has been.
-- releaseStore is the measured bias; pass nil to get the uncorrected figure.
-- toReleaseRaw is always the uncorrected value, because that is what the next
-- measurement has to be scored against -- scoring a corrected estimate would
-- drive the bias to zero and quietly remove the correction that earned it.
function Airtime.ETA(store, zoneID, fit, target, fallingSince, now, releaseStore)
    local descent, n, _, _, _, _, source = Airtime.Descent(store, zoneID)

    if fallingSince then
        local left = descent - (now - fallingSince)
        return {
            phase = left > 0 and "falling" or "down",
            toGround = left > 0 and left or 0,
            descentN = n,
            descentSource = source,
        }
    end

    local raw = Airtime.ToRelease(fit, target)
    if not raw then return nil end
    local bias, biasN = Airtime.ReleaseBias(releaseStore)
    local toRelease = raw + bias
    if toRelease < 0 then toRelease = 0 end
    return {
        phase = "inbound",
        toRelease = toRelease,
        toReleaseRaw = raw,
        bias = bias,
        biasN = biasN,
        toGround = toRelease + descent,
        descentN = n,
        descentSource = source,
    }
end
