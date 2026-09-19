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
-- Eight positional arguments is one too many; if another diagnostic joins
-- them the tail should become a table.
function Airtime.NoteDescent(store, zoneID, seconds, overlapped, pos, partial, lag, flip)
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
    -- Where it landed, rounded to a tenth of a percent of the map. Zul'Aman
    -- has produced descents of 83 and 129 seconds where four other zones sit
    -- inside 84-87, and elevation is the obvious suspect: lower ground under
    -- the drop point means a longer fall. Whether that is really it can only
    -- be answered by knowing which spot each reading came from, and until now
    -- it was not recorded -- so the question could be argued but not settled.
    list[#list + 1] = {
        secs = seconds,
        overlapped = overlapped or nil,
        partial = partial or nil,
        lag = lag and math.floor(lag + 0.5) or nil,
        flip = flip and math.floor(flip + 0.5) or nil,
        x = pos and math.floor(pos.x * 1000 + 0.5) / 10 or nil,
        y = pos and math.floor(pos.y * 1000 + 0.5) / 10 or nil,
    }
    while #list > 40 do table.remove(list, 1) end
    return list[#list]
end

-- mean, n, min, max, overlappedCount, partialCount -- or the guess with n = 0.
--
-- Partial readings are counted and shown but kept out of the mean. Timing a
-- descent from a parachute that was already in the air when the player arrived
-- measures however much of the fall they happened to catch, which is a lower
-- bound on the real figure; averaged in with complete readings it pulls the
-- answer down by an unknowable amount every time.
function Airtime.Descent(store, zoneID)
    local list = store and store[zoneID]
    if type(list) ~= "table" or #list == 0 then return DESCENT_GUESS, 0 end
    local sum, n, lo, hi, over, part = 0, 0, nil, nil, 0, 0
    for _, d in ipairs(list) do
        if d.partial then
            part = part + 1
        else
            n = n + 1
            sum = sum + d.secs
            if not lo or d.secs < lo then lo = d.secs end
            if not hi or d.secs > hi then hi = d.secs end
        end
        if d.overlapped then over = over + 1 end
    end
    if n == 0 then return DESCENT_GUESS, 0, nil, nil, over, part end
    return sum / n, n, lo, hi, over, part
end

-- The individual readings, for inspection.
function Airtime.DescentSamples(store, zoneID)
    local list = store and store[zoneID]
    return (type(list) == "table" and not list.n) and list or nil
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
