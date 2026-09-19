local ns, t = ...
local Heading = ns.Heading

-- Roughly what a transport does: a bit under 1% of the map per second, which
-- crosses a zone in the 40-150s the flight actually takes.
local SPEED = 0.007

local function fly(track, opts)
    opts = opts or {}
    local n      = opts.n or 40
    local step   = opts.step or 0.25
    local hx     = opts.hx or 1
    local hy     = opts.hy or 0
    local x, y   = opts.x0 or 0.2, opts.y0 or 0.5
    local noise  = opts.noise
    local t0     = opts.t0 or 1000
    for i = 0, n - 1 do
        local time = t0 + i * step
        local px = x + hx * SPEED * i * step
        local py = y + hy * SPEED * i * step
        if noise then px = px + noise(); py = py + noise() end
        track:Add(time, px, py)
    end
    return track
end

t.test("a track too short to mean anything reports nothing", function()
    local tr = Heading.NewTrack("a")
    tr:Add(1, 0.5, 0.5)
    tr:Add(2, 0.51, 0.5)
    t.eq(tr:Fit(), nil)
end)

-- The two ways a fit can be refused look identical to a player unless they are
-- named. A live flight held thirty-five samples and reported "not enough
-- samples" because the transport had reached its drop point and begun
-- circling, which is a shortage of movement and not of data.
t.test("enough samples but no distance covered says so, and says why", function()
    local tr = Heading.NewTrack("b")
    -- Crawling: 20 samples that together cover far less than MIN_BASELINE.
    for i = 0, 19 do tr:Add(1000 + i, 0.5 + i * 0.0001, 0.5) end
    local fit, why = tr:Fit()
    t.eq(fit, nil, "a baseline under MIN_BASELINE has no usable direction")
    t.eq(why, "still", "and the reason is that it is not moving, not that it is unseen")
end)

t.test("too few samples is reported as too few samples", function()
    local tr = Heading.NewTrack("b2")
    tr:Add(1000, 0.2, 0.5)
    tr:Add(1001, 0.3, 0.5)
    local fit, why = tr:Fit()
    t.eq(fit, nil)
    t.eq(why, "samples")
end)

t.test("a clean straight run recovers heading and speed exactly", function()
    local fit = fly(Heading.NewTrack("c"), { hx = 1, hy = 0 }):Fit()
    t.ok(fit, "should produce a fit")
    t.near(fit.hx, 1, 1e-9, "hx")
    t.near(fit.hy, 0, 1e-9, "hy")
    t.near(fit.speed, SPEED, 1e-9, "speed")
    t.near(fit.err, 0, 1e-9, "a noiseless track has no heading error")
end)

t.test("heading is recovered on a diagonal too", function()
    local s = math.sqrt(0.5)
    local fit = fly(Heading.NewTrack("d"), { hx = s, hy = -s }):Fit()
    t.near(fit.hx, s, 1e-9, "hx")
    t.near(fit.hy, -s, 1e-9, "hy")
end)

t.test("the reported position is where the transport is now, not the mean", function()
    local fit = fly(Heading.NewTrack("e"), { n = 40, step = 0.25, x0 = 0.2, y0 = 0.5 }):Fit()
    -- 40 samples, 0.25s apart: the last sits 9.75s along the run.
    t.near(fit.x, 0.2 + SPEED * 9.75, 1e-9, "x at the newest sample")
    t.near(fit.y, 0.5, 1e-9, "y at the newest sample")
end)

t.test("noise perturbs the heading but the fit stays close", function()
    local g = t.gauss(t.rng(7))
    local fit = fly(Heading.NewTrack("f"), { noise = function() return g(0.0015) end }):Fit()
    t.ok(fit, "should still fit")
    -- The true heading is due east, so hy is the whole error.
    t.near(fit.hy, 0, 0.02, "heading should stay within ~1 degree of true")
    t.ok(fit.err > 0, "a noisy track must not claim zero error")
end)

-- The reason the fit regresses every sample instead of differencing two. Same
-- span and same noise, four times the samples: the error should fall as
-- 1/sqrt(n), so roughly halve.
t.test("denser sampling over the same span halves the heading error", function()
    local g1 = t.gauss(t.rng(11))
    local sparse = fly(Heading.NewTrack("g"), {
        n = 11, step = 1.0, noise = function() return g1(0.0015) end }):Fit()
    local g2 = t.gauss(t.rng(11))
    local dense = fly(Heading.NewTrack("h"), {
        n = 41, step = 0.25, noise = function() return g2(0.0015) end }):Fit()

    t.near(dense.span, sparse.span, 1e-9, "both runs must cover the same time span")
    t.lt(dense.err, sparse.err, "more samples must not report a worse error")
    local ratio = sparse.err / dense.err
    t.ok(ratio > 1.4 and ratio < 2.8,
        string.format("expected roughly a 2x improvement, got %.2fx", ratio))
end)

-- The test that actually defends the regression. A single seeded run proves
-- nothing here: differencing the first and last sample passes it whenever that
-- particular draw happens to be quiet. Averaged over many draws the two
-- approaches separate cleanly.
--
-- For n samples evenly spread over a baseline b with position noise sd, the
-- slope's standard error gives an angular error of sd*sqrt(12/n)/b, while
-- differencing the endpoints gives sd*sqrt(2)/b. At n=40 that is 0.012 rad
-- against 0.031 -- so a bound of 0.018 passes one and fails the other.
t.test("heading error over many runs stays below the two-sample bound", function()
    local NOISE, TRIALS = 0.0015, 200
    local sq, worst = 0, 0
    for seed = 1, TRIALS do
        local g = t.gauss(t.rng(seed * 7919))
        local fit = fly(Heading.NewTrack("rms" .. seed), {
            n = 40, step = 0.25, hx = 1, hy = 0,
            noise = function() return g(NOISE) end,
        }):Fit()
        t.ok(fit, "trial " .. seed .. " should fit")
        -- True heading is due east, so hy is the angular error in radians.
        sq = sq + fit.hy * fit.hy
        local a = fit.hy < 0 and -fit.hy or fit.hy
        if a > worst then worst = a end
    end
    local rms = math.sqrt(sq / TRIALS)
    t.lt(rms, 0.018, string.format(
        "rms heading error %.4f rad -- a two-sample difference would sit near 0.031", rms))
    t.lt(worst, 0.060, string.format("worst single run %.4f rad", worst))
end)

t.test("a repeated position is not counted as a second observation", function()
    local tr = Heading.NewTrack("i")
    t.eq(tr:Add(1000, 0.5, 0.5), true)
    t.eq(tr:Add(1001, 0.5, 0.5), false, "same place should be rejected")
    t.eq(tr:Count(), 1)
end)

t.test("a sample from the past is rejected", function()
    local tr = Heading.NewTrack("j")
    tr:Add(1000, 0.5, 0.5)
    tr:Add(1010, 0.6, 0.5)
    t.eq(tr:Add(1005, 0.7, 0.5), false, "out-of-order sample should be refused")
    t.eq(tr:Count(), 2)
end)

t.test("samples older than the window are dropped", function()
    local tr = Heading.NewTrack("k")
    fly(tr, { n = 200, step = 0.25 })
    -- 200 samples span 49.75s; only the last WINDOW_SECONDS may remain.
    t.lt(tr:Count(), 200)
    local fit = tr:Fit()
    t.ok(fit.span <= Heading.WINDOW_SECONDS + 0.26,
        string.format("span %.2f should sit inside the %ds window", fit.span, Heading.WINDOW_SECONDS))
end)

-- This test used to assert the opposite -- that trimming stops at MIN_SAMPLES
-- so a quiet transport keeps its heading. In game that let a landed transport
-- report a fit spanning 86 seconds against a 20-second window, because the
-- game yields a position only every five seconds and the track therefore sits
-- at exactly the minimum almost always, so nothing was ever dropped.
t.test("a stale track reports nothing rather than a heading from a minute ago", function()
    local tr = Heading.NewTrack("l")
    for i = 0, 5 do tr:Add(1000 + i * 100, 0.2 + i * 0.05, 0.5) end
    t.lt(tr:Count(), Heading.MIN_SAMPLES, "samples older than the window must be dropped")
    t.eq(tr:Fit(), nil, "and with too few left there is no honest heading to give")
end)

t.test("no fit ever spans more than the window", function()
    local tr = Heading.NewTrack("l2")
    -- One sample every 5s for two minutes, the cadence seen in game.
    for i = 0, 23 do tr:Add(1000 + i * 5, 0.2 + i * 0.01, 0.5) end
    local fit = tr:Fit()
    t.ok(fit, "a steadily-fed track should still fit")
    t.ok(fit.span <= Heading.WINDOW_SECONDS,
        string.format("span %.1fs must stay inside the %ds window", fit.span, Heading.WINDOW_SECONDS))
end)

t.test("a turning transport reports a larger cross-track residual", function()
    local straight = fly(Heading.NewTrack("m"), { n = 40 }):Fit()

    local turning = Heading.NewTrack("n")
    local x, y = 0.2, 0.5
    for i = 0, 39 do
        local a = i * 0.03           -- bending away as it goes
        x = x + SPEED * 0.25 * math.cos(a)
        y = y + SPEED * 0.25 * math.sin(a)
        turning:Add(1000 + i * 0.25, x, y)
    end
    local curved = turning:Fit()

    t.lt(straight.rms, curved.rms, "a curve must show more cross-track scatter than a straight run")
    t.lt(straight.err, curved.err, "and must report a larger heading error")
end)
