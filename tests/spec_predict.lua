local ns, t = ...
local Predict = ns.Predict

local function spots(...)
    local out = {}
    for _, p in ipairs({ ... }) do out[#out + 1] = { x = p[1], y = p[2], n = p[3] or 1 } end
    return out
end

-- A fit good enough that the verdict is decided by geometry, not by noise.
local function fit(x, y, hx, hy, err)
    return { x = x, y = y, hx = hx, hy = hy, err = err or 0, speed = 0.007, n = 40 }
end

t.test("an uncatalogued zone is refused, not guessed at", function()
    t.eq(Predict.Evaluate(nil, fit(0.1, 0.5, 1, 0)).reason, "no-catalogue")
    t.eq(Predict.Evaluate({}, fit(0.1, 0.5, 1, 0)).reason, "no-catalogue")
end)

t.test("a missing fit is refused", function()
    t.eq(Predict.Evaluate(spots({ 0.5, 0.5 }), nil).reason, "no-fit")
end)

t.test("a ray aimed straight at a lone spot picks it", function()
    local s = spots({ 0.5, 0.5 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.ok(r.ok, "should commit: " .. tostring(r.reason))
    t.eq(r.best.spot, s[1])
    t.near(r.best.along, 0.4, 1e-9)
    t.near(r.best.tan, 0, 1e-9)
end)

t.test("the nearer of two spots on the same bearing still wins on angle", function()
    local s = spots({ 0.5, 0.5 }, { 0.9, 0.9 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.eq(r.best.spot, s[1], "the on-ray spot should rank first")
end)

t.test("spots behind the transport are not candidates", function()
    local s = spots({ 0.05, 0.5 })
    local r = Predict.Evaluate(s, fit(0.5, 0.5, 1, 0))
    t.notOk(r.ok)
    t.eq(r.reason, "nothing-ahead")
end)

t.test("a spot the transport has reached is the answer, not a spot to discard", function()
    -- 0.02 ahead and dead on the ray: the transport has arrived.
    local s = spots({ 0.52, 0.5 })
    local r = Predict.Evaluate(s, fit(0.5, 0.5, 1, 0))
    t.ok(r.ok, "should commit on arrival: " .. tostring(r.reason))
    t.ok(r.arriving)
    t.eq(r.best.spot, s[1])
end)

t.test("passing close to a spot but off to the side is not an arrival", function()
    -- 0.02 ahead but 3% of map to the side, well outside the landing scatter.
    local s = spots({ 0.52, 0.53 })
    local r = Predict.Evaluate(s, fit(0.5, 0.5, 1, 0))
    t.notOk(r.arriving, "arrival is proximity, and this is not near")
end)

-- Regression, from a flight logged in Zul'Aman on 18 Sep 2026.
--
-- The transport was heading for 46.9, 62.3 and that spot ranked first for a
-- solid minute. 48.9, 69.2 lies further along almost the same bearing, close
-- enough to hold the verdict at "ambiguous" the whole way in. Then the true
-- target came within the old MIN_AHEAD filter, was dropped from the candidate
-- list, and the decoy inherited first place with no rival left -- so the addon
-- committed, confidently, to a point 7.2% of the map from where the crate
-- actually landed.
t.test("nearing the true target does not hand the verdict to the spot behind it", function()
    local target = { 0.469, 0.623 }
    local decoy  = { 0.489, 0.692 }
    local s = spots(target, decoy)

    -- Heading aimed at the target, coming in at an angle that leaves the decoy
    -- roughly 3 degrees off the ray far out -- which is what the live log
    -- reported when it went wrong. Not perfectly collinear: that would put both
    -- spots at zero offset and make the ranking a coin toss rather than a test.
    local dx, dy = decoy[1] - target[1], decoy[2] - target[2]
    local len = math.sqrt(dx * dx + dy * dy)
    local a = math.rad(15)
    local hx = (dx * math.cos(a) - dy * math.sin(a)) / len
    local hy = (dx * math.sin(a) + dy * math.cos(a)) / len

    local function approachingBy(gap)
        return fit(target[1] - gap * hx, target[2] - gap * hy, hx, hy, 0)
    end

    -- Whether it is confident enough to speak far out is a separate question
    -- and the log does not settle it: the "2.9 degrees off" it reported was the
    -- decoy at the moment of the bad call, once the target had already been
    -- dropped, not the separation on the way in. What the log does establish is
    -- everything below -- the target must never stop being the front runner,
    -- and the decoy must never inherit the call.
    for _, gap in ipairs({ 0.30, 0.20, 0.10, 0.06, 0.03, 0.01 }) do
        local r = Predict.Evaluate(s, approachingBy(gap))
        t.eq(r.best.spot, s[1], string.format(
            "at %.2f out the true target must still rank first", gap))
        t.notOk(r.ok and r.best.spot == s[2], string.format(
            "at %.2f out it must never commit to the spot behind the target", gap))
    end

    -- And on arrival it commits to the right one.
    local arrived = Predict.Evaluate(s, approachingBy(0.02))
    t.ok(arrived.ok, "should commit once it is on top of the target")
    t.eq(arrived.best.spot, s[1])
    t.ok(arrived.arriving)
end)

t.test("a heading into empty space commits to nothing", function()
    -- Flying east; the only spot sits far to the north.
    local s = spots({ 0.5, 0.9 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.notOk(r.ok)
    t.eq(r.reason, "off-ray")
end)

-- The case that matters most. Roughly one geometry in six puts two spots on
-- nearly the same bearing, and no amount of further flying separates them.
-- Announcing the wrong spot is worse than announcing nothing, because a raid
-- acts on it.
t.test("two spots straddling the ray are reported as ambiguous", function()
    local s = spots({ 0.5, 0.505 }, { 0.5, 0.495 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.notOk(r.ok, "must not pick one of two equally plausible spots")
    t.eq(r.reason, "ambiguous")
    t.ok(r.best, "the ranking is still exposed for the UI")
    t.ok(r.second)
end)

t.test("a clearly better candidate beats a distant rival", function()
    local s = spots({ 0.5, 0.5 }, { 0.5, 0.75 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.ok(r.ok, "a 25%-of-map separation is not ambiguous: " .. tostring(r.reason))
    t.eq(r.best.spot, s[1])
end)

-- The landing scatter is a DISTANCE around the catalogued spot, so with a
-- trustworthy heading the test reduces to "does the ray pass within SCATTER of
-- it" and range drops out. Pinned because the cone is expressed in tangent
-- units, where that cancellation is easy to break by accident.
t.test("the landing-scatter allowance does not depend on range", function()
    local inside = 0.008   -- under SCATTER
    local beyond = 0.030   -- over it
    for _, along in ipairs({ 0.10, 0.80 }) do
        local near = Predict.Evaluate(spots({ 0.1 + along, 0.5 + inside }), fit(0.1, 0.5, 1, 0))
        t.ok(near.ok, string.format("%.2f sideways at range %.2f should be accepted", inside, along))

        local far = Predict.Evaluate(spots({ 0.1 + along, 0.5 + beyond }), fit(0.1, 0.5, 1, 0))
        t.notOk(far.ok, string.format("%.2f sideways at range %.2f should be refused", beyond, along))
    end
end)

-- A heading error, unlike the scatter, IS an angle: the same sideways offset
-- is well within a sloppy bearing at long range and plainly outside it up
-- close. This is the half of the cone that does move with range.
t.test("a sloppy heading forgives more sideways the further out the spot is", function()
    local err = 0.05                   -- ~3 degrees, a transport just spotted
    local near = Predict.Evaluate(spots({ 0.20, 0.53 }), fit(0.1, 0.5, 1, 0, err))
    local far  = Predict.Evaluate(spots({ 0.90, 0.53 }), fit(0.1, 0.5, 1, 0, err))
    t.notOk(near.ok, "3% sideways at 10% range is far off the bearing")
    t.eq(near.reason, "off-ray")
    t.ok(far.ok, "the same 3% sideways at 80% range is well inside a 3-degree error")
end)

-- A fit that admits it is uncertain must be believed. This is what stops a
-- freshly-spotted transport, or one that is turning, from being acted on.
t.test("an uncertain heading suppresses a call a precise one would make", function()
    local s = spots({ 0.5, 0.5 }, { 0.5, 0.54 })
    local sharp = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0, 0.0))
    local fuzzy = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0, 0.05))
    t.ok(sharp.ok, "a precise heading separates these two")
    t.notOk(fuzzy.ok, "the same geometry with a sloppy heading must not commit")
    t.eq(fuzzy.reason, "ambiguous")
end)

t.test("ranking is exposed in order for the UI to show runners-up", function()
    local s = spots({ 0.5, 0.60 }, { 0.5, 0.50 }, { 0.5, 0.75 })
    local r = Predict.Evaluate(s, fit(0.1, 0.5, 1, 0))
    t.eq(#r.ranked, 3)
    t.eq(r.ranked[1].spot, s[2], "closest to the ray first")
    t.ok(r.ranked[1].tan <= r.ranked[2].tan)
    t.ok(r.ranked[2].tan <= r.ranked[3].tan)
end)
