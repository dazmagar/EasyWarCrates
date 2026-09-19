local ADDON, ns = ...

-- How long until the crate is on the ground.
--
-- Pure maths, so tests/ covers it.
--
-- Two legs. The transport flies to its drop point and releases; the crate then
-- falls under a parachute. Only the second has to be learned.
--
-- The first is arithmetic: the heading fit already reports the transport's
-- speed, and the prediction already knows which spot it is flying at, so the
-- time to release is the distance between them divided by that speed. RCT
-- learns this leg per drop point with a running mean and will not trust it
-- until four crates have been timed there, which means a zone it has not seen
-- much of says "Learning" instead of a number. Dividing works on the first
-- flight, in a zone nobody has ever visited.
--
-- The descent genuinely cannot be computed -- nothing observable says how high
-- the crate was released -- so it is measured. Per zone rather than per drop
-- point: RCT splits it by point, which is defensible but collects data an
-- order of magnitude more slowly, and whether the spread within a zone even
-- justifies it is a question the samples will answer later.

local Airtime = {}
ns.Airtime = Airtime

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
function Airtime.NoteDescent(store, zoneID, seconds, overlapped)
    if type(store) ~= "table" or not zoneID then return nil end
    seconds = tonumber(seconds)
    if not seconds or seconds < DESCENT_MIN or seconds > DESCENT_MAX then return nil end

    local list = store[zoneID]
    if type(list) ~= "table" or list.n then
        -- Either nothing yet, or the old running-sum shape. Start clean rather
        -- than mixing two shapes in one table.
        list = {}
        store[zoneID] = list
    end
    list[#list + 1] = { secs = seconds, overlapped = overlapped or nil }
    while #list > 40 do table.remove(list, 1) end
    return list[#list]
end

-- mean, n, min, max, overlappedCount -- or the guess with n = 0 when nothing
-- has been measured.
function Airtime.Descent(store, zoneID)
    local list = store and store[zoneID]
    if type(list) ~= "table" or #list == 0 then return DESCENT_GUESS, 0 end
    local sum, lo, hi, over = 0, nil, nil, 0
    for _, d in ipairs(list) do
        sum = sum + d.secs
        if not lo or d.secs < lo then lo = d.secs end
        if not hi or d.secs > hi then hi = d.secs end
        if d.overlapped then over = over + 1 end
    end
    return sum / #list, #list, lo, hi, over
end

-- The individual readings, for inspection.
function Airtime.DescentSamples(store, zoneID)
    local list = store and store[zoneID]
    return (type(list) == "table" and not list.n) and list or nil
end

-- How wrong the raw release estimate runs, pooled across zones.
--
-- Measured, not assumed: the first two flights it ran on promised release in 8
-- seconds and took 30 and 37. Both late, by 22 and 29, which is a systematic
-- bias rather than noise -- most likely the transport slowing on approach
-- while the heading fit reports an average over its whole window, though the
-- cause does not matter for correcting it.
--
-- Pooled rather than kept per zone because the cause is not zone-specific and
-- there are very few samples; a per-zone split would just be slower to learn
-- the same number. Applied only once there are at least this many, so a single
-- odd flight cannot swing it.
local BIAS_MIN_N = 2
Airtime.BIAS_MIN_N = BIAS_MIN_N

function Airtime.ReleaseBias(store)
    local n, sum = 0, 0
    for _, acc in pairs(store or {}) do
        n = n + (acc.n or 0)
        sum = sum + (acc.sum or 0)
    end
    if n < BIAS_MIN_N then return 0, n end
    return sum / n, n
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
    local descent, n = Airtime.Descent(store, zoneID)

    if fallingSince then
        local left = descent - (now - fallingSince)
        return {
            phase = left > 0 and "falling" or "down",
            toGround = left > 0 and left or 0,
            descentN = n,
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
    }
end
