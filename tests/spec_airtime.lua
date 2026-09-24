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
    Airtime.NoteDescent(store, ZONE, 98, { overlapped = true })
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
    Airtime.NoteDescent(store, ZONE, 98, { overlapped = true })
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

-- Zul'Aman has produced descents of 83 and 129 seconds where four other zones
-- sit inside 84 to 87. Elevation is the obvious suspect -- lower ground under
-- the drop point means a longer fall -- but until each reading carried the
-- spot it came from, that could be argued and not settled.
t.test("a descent records where it was measured", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 129, { pos = { x = 0.469, y = 0.622 } })
    Airtime.NoteDescent(store, ZONE, 83, { pos = { x = 0.398, y = 0.275 } })
    local s = Airtime.DescentSamples(store, ZONE)
    t.near(s[1].x, 46.9, 1e-9)
    t.near(s[1].y, 62.2, 1e-9)
    t.near(s[2].x, 39.8, 1e-9)
    t.ok(s[1].x ~= s[2].x, "two spots, and now it is visible that they are two")
end)

t.test("a reading with no position is still kept", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 86)
    local s = Airtime.DescentSamples(store, ZONE)
    t.eq(s[1].x, nil, "unknown, not zero -- the readout says so rather than plotting it at 0,0")
    t.eq(select(2, Airtime.Descent(store, ZONE)), 1, "and it still counts towards the mean")
end)

-- Flying into a zone where a crate is already on its parachute times however
-- much of the fall you happened to catch. Seen live in Slayer's Rise: 115
-- seconds from arriving to the landing, with no way to know how long it had
-- already been coming down. That is a lower bound, and averaging lower bounds
-- with real readings pulls the answer down by an unknowable amount.
t.test("a descent joined mid-fall is kept out of the mean", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 86)
    Airtime.NoteDescent(store, ZONE, 115, { partial = true })
    local mean, n, lo, hi, _, partial = Airtime.Descent(store, ZONE)
    t.eq(n, 1, "only the complete reading counts")
    t.near(mean, 86, 1e-9)
    t.eq(hi, 86, "the partial one must not widen the range either")
    t.eq(partial, 1, "but it is counted, so the readout can show it")
end)

t.test("a partial reading is still stored and visible", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 115, { partial = true })
    local samples = Airtime.DescentSamples(store, ZONE)
    t.eq(#samples, 1)
    t.ok(samples[1].partial)
end)

t.test("with nothing but partial readings the guess still stands", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 115, { partial = true })
    local mean, n = Airtime.Descent(store, ZONE)
    t.eq(mean, Airtime.DESCENT_GUESS, "a lower bound is not a measurement")
    t.eq(n, 0)
end)

-- The two legs of a drop are measured separately now: how long the transport
-- circles before letting go, and how long the crate then falls. Zul'Aman
-- readings split 83/85 against 129/129 and Slayer's Rise gave 91 and 134 at
-- the same spot, so the fall alone does not explain the spread.
t.test("the circling leg is stored alongside the fall", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 86, { lag = 41.4 })
    local s = Airtime.DescentSamples(store, ZONE)[1]
    t.eq(s.secs, 86)
    t.eq(s.lag, 41, "rounded, and kept apart from the fall it is not part of")
    t.eq(select(2, Airtime.Descent(store, ZONE)), 1, "and it is still a full reading")
end)

-- Harandar's seven readings, as measured. Five agree on 86-87; the mean is 73,
-- which is not a time any crate there has ever taken. Both tails are genuine:
-- a crate can catch on a branch and be down early, and the game can leave the
-- parachute drawn for another half minute after it lands.
t.test("the figure is the middle reading, not one the data never produced", function()
    local store = {}
    for _, secs in ipairs({ 86, 86, 87, 61, 19, 86, 86 }) do
        Airtime.NoteDescent(store, ZONE, secs)
    end
    local typical, n, lo, hi = Airtime.Descent(store, ZONE)
    -- n counts what the figure rests on, not how many readings exist. Five of
    -- these seven agree; the 19 and the 61 are not evidence for 86 and are not
    -- counted as though they were.
    t.eq(n, 5)
    t.eq(typical, 86, "the mean of these is 73, which describes no drop here")
    t.eq(lo, 19, "the spread is still shown honestly")
    t.eq(hi, 87)
end)

t.test("an even count takes the middle pair", function()
    local store = {}
    for _, secs in ipairs({ 84, 86, 87, 89 }) do Airtime.NoteDescent(store, ZONE, secs) end
    t.eq(Airtime.Descent(store, ZONE), 86.5)
end)

t.test("readings out of order still find the middle", function()
    local store = {}
    for _, secs in ipairs({ 129, 44, 87, 83, 85 }) do Airtime.NoteDescent(store, ZONE, secs) end
    t.eq(Airtime.Descent(store, ZONE), 85, "Zul'Aman, as it stands")
end)

-- The tail became a table when distance joined it. These pin the shape so a
-- positional call cannot creep back in and silently land in the wrong field.
t.test("the diagnostics arrive as a table and are stored under their own names", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 86, {
        overlapped = true, partial = true, lag = 41.4, flip = 33.6,
        pos = { x = 0.489, y = 0.692 }, dist = 12.34,
    })
    local rec = store[ZONE][1]
    t.eq(rec.secs, 86)
    t.ok(rec.overlapped)
    t.ok(rec.partial)
    t.eq(rec.lag, 41)
    t.eq(rec.flip, 34)
    t.eq(rec.x, 48.9)
    t.eq(rec.y, 69.2)
    t.eq(rec.dist, 12.3)
end)

t.test("a reading with no diagnostics at all is still taken", function()
    local store = {}
    t.ok(Airtime.NoteDescent(store, ZONE, 86))
    t.ok(Airtime.NoteDescent(store, ZONE, 87, nil))
    t.eq(#store[ZONE], 2)
    t.eq(store[ZONE][1].dist, nil)
end)

-- Why distance is recorded at all: Eversong reads 14, 43 and 84 where four
-- other zones cluster on 86, and a parachute only drawn once it falls into
-- vignette range would truncate exactly the distant readings.
t.test("distance does not change what the reading counts as", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 86, { dist = 40 })
    Airtime.NoteDescent(store, ZONE, 86, { dist = 1 })
    local typical, n = Airtime.Descent(store, ZONE)
    t.eq(n, 2, "a far reading is recorded, not rejected")
    t.eq(typical, 86)
end)

-- Dmitrii's saved readings on 20 Sep, which is what this estimator was changed
-- for. Every zone holds a cluster near 86 and some contradictions around it;
-- two zones hold nothing but contradictions.

t.test("a zone that agrees with itself answers from its own readings", function()
    local store = {}
    for _, secs in ipairs({ 86, 86, 87, 61, 19, 86, 86 }) do
        Airtime.NoteDescent(store, ZONE, secs)
    end
    local typical, n, _, _, _, _, source = Airtime.Descent(store, ZONE)
    t.eq(source, "zone")
    t.eq(typical, 86)
    t.eq(n, 5)
end)

-- Eversong: 14, 43, 84, 92. Its own median is 64, a number no drop has ever
-- taken, and it was being used for the countdown.
t.test("a zone whose readings contradict each other borrows from the rest", function()
    local store = {}
    for _, secs in ipairs({ 14, 43, 84, 92 }) do Airtime.NoteDescent(store, "ES", secs) end
    for _, secs in ipairs({ 86, 86, 87, 86, 86 }) do Airtime.NoteDescent(store, "HA", secs) end

    local typical, n, lo, hi, _, _, source = Airtime.Descent(store, "ES")
    t.eq(source, "pooled")
    t.eq(typical, 86, "what every zone together says, not this zone's own contradiction")
    -- Seven, not five: Eversong's own 84 and 92 belong to the agreement. Only
    -- its 14 and 43 spoiled its median, and pooling does not discard the rest
    -- of what it measured.
    t.eq(n, 7)
    t.eq(lo, 14, "and its own spread is still reported honestly")
    t.eq(hi, 92)
end)

t.test("with nothing anywhere that agrees, it says so rather than inventing", function()
    local store = {}
    for _, secs in ipairs({ 14, 43, 84, 130 }) do Airtime.NoteDescent(store, "ES", secs) end
    local typical, n, _, _, _, _, source = Airtime.Descent(store, "ES")
    t.eq(source, "guess")
    t.eq(typical, Airtime.DESCENT_GUESS)
    t.eq(n, 0, "nothing here is evidence for anything")
end)

t.test("one or two readings are kept, because two cannot disagree", function()
    local store = {}
    Airtime.NoteDescent(store, ZONE, 84)
    local typical, n, _, _, _, _, source = Airtime.Descent(store, ZONE)
    t.eq(typical, 84)
    t.eq(n, 1)
    t.eq(source, "zone")

    Airtime.NoteDescent(store, ZONE, 88)
    t.eq(Airtime.Descent(store, ZONE), 86)
end)

t.test("a cluster is a cluster wherever it sits, not only near 86", function()
    local store = {}
    for _, secs in ipairs({ 120, 122, 125, 20 }) do Airtime.NoteDescent(store, ZONE, secs) end
    local typical, n, _, _, _, _, source = Airtime.Descent(store, ZONE)
    t.eq(source, "zone")
    t.eq(typical, 122, "the estimator finds agreement, it does not assume the answer")
    t.eq(n, 3)
end)

-- A crate found lying on the ground spawned a flight and a fall ago. Seeding
-- the timer at the moment somebody noticed it is late by that much, every
-- time, and both legs are measured now.
t.test("a grounded find is set back by the two measured legs", function()
    local flight, descent = {}, {}
    for _, secs in ipairs({ 70, 72, 74 }) do Airtime.NoteFlight(flight, ZONE, secs) end
    for _, secs in ipairs({ 86, 86, 87 }) do Airtime.NoteDescent(descent, ZONE, secs) end
    local back, n = Airtime.SpawnOffset(flight, descent, ZONE)
    t.eq(back, 158, "72 in the air and 86 under the parachute")
    t.eq(n, 6, "and it rests on six readings")
end)

-- Built from two guesses it would move every timer on the strength of nothing.
t.test("nothing is set back until both legs have actually been measured", function()
    local flight, descent = {}, {}
    t.eq(Airtime.SpawnOffset(flight, descent, ZONE), nil, "neither leg measured")

    for _, secs in ipairs({ 86, 86, 87 }) do Airtime.NoteDescent(descent, ZONE, secs) end
    t.eq(Airtime.SpawnOffset(flight, descent, ZONE), nil, "the fall alone is not enough")

    Airtime.NoteFlight(flight, ZONE, 72)
    t.ok(Airtime.SpawnOffset(flight, descent, ZONE), "one flight reading is still a reading")
end)

t.test("a leg borrowed from other zones still counts as measured", function()
    local flight, descent = {}, {}
    for _, secs in ipairs({ 14, 43, 130 }) do Airtime.NoteDescent(descent, "ES", secs) end
    for _, secs in ipairs({ 86, 86, 87 }) do Airtime.NoteDescent(descent, "HA", secs) end
    for _, secs in ipairs({ 70, 72, 74 }) do Airtime.NoteFlight(flight, "ES", secs) end
    local back = Airtime.SpawnOffset(flight, descent, "ES")
    t.eq(back, 158, "Eversong disagrees with itself, so it borrows 86 and says so elsewhere")
end)
