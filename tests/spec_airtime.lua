local ns, t = ...
local Airtime = ns.Airtime

local ZONE = 2444
local T0 = 1000000

-- Roughly what a transport does: a bit under 1% of the map per second.
local function fit(x, y, hx, hy, speed)
    return { x = x, y = y, hx = hx, hy = hy, speed = speed or 0.007 }
end

-- The arithmetic itself, which is sound: distance along the heading over the
-- speed the fit reports. What the flights showed is that its INPUTS do not
-- hold -- the transport neither flies straight to its drop point nor keeps its
-- speed -- so the result runs late by anywhere from 16 to 54 seconds. These
-- tests pin the maths; the bias tests below carry the evidence about how far
-- it can be trusted.
t.test("time to release is computed, not learned", function()
    local secs = Airtime.ToRelease(fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 })
    t.near(secs, 0.35 / 0.007, 1e-6, "35% of map at 0.7% per second")
end)

t.test("only the distance along the heading counts", function()
    -- Target off to one side: the sideways part is not flown towards.
    local secs = Airtime.ToRelease(fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.70 })
    t.near(secs, 0.35 / 0.007, 1e-6)
end)

t.test("a transport past its target is treated as at it, never negative", function()
    t.eq(Airtime.ToRelease(fit(0.60, 0.50, 1, 0), { x = 0.40, y = 0.50 }), 0)
end)

t.test("a fit with no speed yields nothing rather than dividing by zero", function()
    t.eq(Airtime.ToRelease(fit(0.2, 0.5, 1, 0, 0), { x = 0.5, y = 0.5 }), nil)
    t.eq(Airtime.ToRelease(nil, { x = 0.5, y = 0.5 }), nil)
    t.eq(Airtime.ToRelease(fit(0.2, 0.5, 1, 0), nil), nil)
end)

t.test("an unmeasured zone falls back to a guess and says so", function()
    local mean, n = Airtime.Descent({}, ZONE)
    t.eq(mean, Airtime.DESCENT_GUESS)
    t.eq(n, 0, "zero samples is what tells the UI not to present this as measured")
end)

t.test("measured descents replace the guess", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 95)
    Airtime.NoteDescent(store, ZONE, 105)
    local mean, n, lo, hi = Airtime.Descent(store, ZONE)
    t.near(mean, 100, 1e-9)
    t.eq(n, 2)
    t.eq(lo, 95)
    t.eq(hi, 105)
end)

-- The game keeps drawing a parachute for a crate that is already down, seen
-- lingering eight to ten seconds in Zul'Aman.
--
-- The flag was added expecting those readings to run long. They do not,
-- measurably: Voidstorm's overlapped reading came in at 86 seconds, matching
-- Harandar's clean 87. So the flag has already earned its place by disproving
-- the reason it was added, and Zul'Aman's 98 and 129 need some other
-- explanation.
t.test("a reading taken with the parachute still drawn is flagged", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 87)
    Airtime.NoteDescent(store, ZONE, 98, true)
    local mean, n, lo, hi, over = Airtime.Descent(store, ZONE)
    t.eq(n, 2)
    t.eq(over, 1, "one of the two is suspect and the readout has to be able to say so")
    t.near(mean, 92.5, 1e-9, "flagged, not discarded")
    t.eq(lo, 87)
    t.eq(hi, 98)
end)

t.test("individual readings are kept, not just their summary", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 87)
    Airtime.NoteDescent(store, ZONE, 98, true)
    local samples = Airtime.DescentSamples(store, ZONE)
    t.eq(#samples, 2)
    t.eq(samples[1].secs, 87)
    t.eq(samples[1].overlapped, nil)
    t.eq(samples[2].overlapped, true)
end)

t.test("an implausible descent is refused", function()
    local store = {}
    t.eq(Airtime.NoteDescent(store, ZONE, 2), nil, "two seconds is not a parachute")
    t.eq(Airtime.NoteDescent(store, ZONE, 900), nil)
    t.eq(Airtime.NoteDescent(store, ZONE, nil), nil)
    t.eq(Airtime.NoteDescent(nil, ZONE, 100), nil)
    t.eq(next(store), nil)
end)

-- A drop was observed falling for about a minute and a half to two minutes,
-- which is the range these bounds have to admit.
t.test("the observed range of real descents is accepted", function()
    local store = {}
    t.ok(Airtime.NoteDescent(store, ZONE, 90))
    t.ok(Airtime.NoteDescent(store, ZONE, 120))
    t.eq(select(2, Airtime.Descent(store, ZONE)), 2)
end)

t.test("an inbound crate reports both legs", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 100)
    local eta = Airtime.ETA(store, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0)
    t.eq(eta.phase, "inbound")
    t.near(eta.toRelease, 50, 1e-6)
    t.near(eta.toGround, 150, 1e-6, "release plus the measured descent")
    t.eq(eta.descentN, 1)
end)

t.test("once falling, the release leg is done and only the descent remains", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 100)
    local eta = Airtime.ETA(store, ZONE, nil, nil, T0 - 40, T0)
    t.eq(eta.phase, "falling")
    t.eq(eta.toRelease, nil, "it has already been released")
    t.near(eta.toGround, 60, 1e-9)
end)

-- What the player sees as "on the ground any second": the estimate has run out
-- but the game has not confirmed the landing. Saying nothing would read as the
-- addon having lost track of it.
t.test("an overrun descent reports down rather than a negative countdown", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 100)
    local eta = Airtime.ETA(store, ZONE, nil, nil, T0 - 130, T0)
    t.eq(eta.phase, "down")
    t.eq(eta.toGround, 0)
end)

t.test("an unmeasured zone still gives a figure, flagged as a guess", function()
    local eta = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0)
    t.near(eta.toGround, 50 + Airtime.DESCENT_GUESS, 1e-6)
    t.eq(eta.descentN, 0, "the caller decides how to caveat it, but must be able to")
end)

-- Measured, not assumed -- and the measurement is what showed the correction
-- is weaker than it first looked. Five flights have run late by 16, 22, 29, 31
-- and 54 seconds. Late every time, which is why a correction is still applied,
-- but across a 38-second spread, which is why it takes five observations
-- before it applies at all and why the spread is reported alongside it.
t.test("the release estimate is corrected by the measured bias", function()
    local bias = { [ZONE] = { n = 5, sum = 5 * 25.5 } }
    local plain = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0)
    local fixed = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.near(plain.toRelease, 50, 1e-6, "no bias store, no correction")
    t.near(fixed.toRelease, 50 + 25.5, 1e-6)
    t.near(fixed.toReleaseRaw, 50, 1e-6, "the raw figure survives for scoring")
    t.near(fixed.toGround, 50 + 25.5 + Airtime.DESCENT_GUESS, 1e-6)
end)

t.test("too few samples is not enough to correct by", function()
    local bias = { [ZONE] = { n = Airtime.BIAS_MIN_N - 1, sum = 29 * (Airtime.BIAS_MIN_N - 1) } }
    local eta = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.near(eta.toRelease, 50, 1e-6, "a handful of odd flights must not swing it")
    t.eq(eta.biasN, Airtime.BIAS_MIN_N - 1)
end)

-- Pooled across zones: the cause is not zone-specific and the samples are few,
-- so splitting by zone would only be slower to learn the same number.
t.test("bias pools observations from every zone", function()
    local bias = {
        [2444] = { n = 3, sum = 22 + 29 + 31, lo = 22, hi = 31 },
        [2405] = { n = 2, sum = 16 + 54,      lo = 16, hi = 54 },
    }
    local mean, n, spread = Airtime.ReleaseBias(bias)
    t.eq(n, 5)
    t.near(mean, (22 + 29 + 31 + 16 + 54) / 5, 1e-9)
    -- The spread is the point. These five real errors range over 38 seconds,
    -- so the mean describes them poorly and the readout has to be able to say
    -- so rather than presenting a countdown as precise.
    t.eq(spread, 38)
end)

t.test("a correction cannot drive the estimate below zero", function()
    local bias = { [ZONE] = { n = 6, sum = -600 } }
    local eta = Airtime.ETA({}, ZONE, fit(0.50, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.eq(eta.toRelease, 0)
end)

t.test("nothing to say yields nil, not an empty shape", function()
    t.eq(Airtime.ETA({}, ZONE, nil, nil, nil, T0), nil)
end)
