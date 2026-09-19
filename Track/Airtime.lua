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

function Airtime.NoteDescent(store, zoneID, seconds)
    if type(store) ~= "table" or not zoneID then return nil end
    seconds = tonumber(seconds)
    if not seconds or seconds < DESCENT_MIN or seconds > DESCENT_MAX then return nil end

    local acc = store[zoneID]
    if not acc then acc = { n = 0, sum = 0, min = nil, max = nil }; store[zoneID] = acc end
    acc.n = acc.n + 1
    acc.sum = acc.sum + seconds
    if not acc.min or seconds < acc.min then acc.min = seconds end
    if not acc.max or seconds > acc.max then acc.max = seconds end
    return acc
end

-- mean, n, min, max -- or the guess with n = 0 when nothing has been measured.
function Airtime.Descent(store, zoneID)
    local acc = store and store[zoneID]
    if not acc or acc.n == 0 then return DESCENT_GUESS, 0 end
    return acc.sum / acc.n, acc.n, acc.min, acc.max
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
function Airtime.ETA(store, zoneID, fit, target, fallingSince, now)
    local descent, n = Airtime.Descent(store, zoneID)

    if fallingSince then
        local left = descent - (now - fallingSince)
        return {
            phase = left > 0 and "falling" or "down",
            toGround = left > 0 and left or 0,
            descentN = n,
        }
    end

    local toRelease = Airtime.ToRelease(fit, target)
    if not toRelease then return nil end
    return {
        phase = "inbound",
        toRelease = toRelease,
        toGround = toRelease + descent,
        descentN = n,
    }
end
