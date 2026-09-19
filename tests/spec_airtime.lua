local ns, t = ...
local Airtime = ns.Airtime

local ZONE = 2444
local T0 = 1000000

-- Roughly what a transport does: a bit under 1% of the map per second.
local function fit(x, y, hx, hy, speed)
    return { x = x, y = y, hx = hx, hy = hy, speed = speed or 0.007 }
end

-- The leg that needs no learning. RCT will not give a number for this until it
-- has timed four crates at that exact drop point; the speed is already in the
-- heading fit, so it is a division and works on the first flight in a zone
-- nobody has visited.
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
-- lingering eight to ten seconds in Zul'Aman. A reading taken then may run
-- long by about that much, which is the difference between the 98s measured
-- there and the 87s measured cleanly in Harandar -- quite possibly the same
-- descent twice rather than two different zones behaving differently.
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

-- Measured, not assumed. Two flights promised release in 8 seconds and took 30
-- and 37 -- both late, by 22 and 29, which is a bias rather than noise.
t.test("the release estimate is corrected by the measured bias", function()
    local bias = { [ZONE] = { n = 2, sum = 22 + 29 } }
    local plain = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0)
    local fixed = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.near(plain.toRelease, 50, 1e-6, "no bias store, no correction")
    t.near(fixed.toRelease, 50 + 25.5, 1e-6)
    t.near(fixed.toReleaseRaw, 50, 1e-6, "the raw figure survives for scoring")
    t.near(fixed.toGround, 50 + 25.5 + Airtime.DESCENT_GUESS, 1e-6)
end)

t.test("one sample is not enough to correct by", function()
    local bias = { [ZONE] = { n = 1, sum = 29 } }
    local eta = Airtime.ETA({}, ZONE, fit(0.20, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.near(eta.toRelease, 50, 1e-6, "a single odd flight must not swing it")
    t.eq(eta.biasN, 1)
end)

-- Pooled across zones: the cause is not zone-specific and the samples are few,
-- so splitting by zone would only be slower to learn the same number.
t.test("bias pools observations from every zone", function()
    local bias = { [2444] = { n = 1, sum = 22 }, [2405] = { n = 1, sum = 29 } }
    local mean, n = Airtime.ReleaseBias(bias)
    t.eq(n, 2)
    t.near(mean, 25.5, 1e-9)
end)

t.test("a correction cannot drive the estimate below zero", function()
    local bias = { [ZONE] = { n = 4, sum = -400 } }
    local eta = Airtime.ETA({}, ZONE, fit(0.50, 0.50, 1, 0), { x = 0.55, y = 0.50 }, nil, T0, bias)
    t.eq(eta.toRelease, 0)
end)

t.test("nothing to say yields nil, not an empty shape", function()
    t.eq(Airtime.ETA({}, ZONE, nil, nil, nil, T0), nil)
end)
