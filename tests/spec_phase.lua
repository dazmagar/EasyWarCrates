local ns, t = ...
local Phase, Timers = ns.Phase, ns.Timers

local ZA, HA = 2437, 2413
local T0 = 1000000
local INTERVAL = 1095

t.test("a spawn is filed against the shard it belonged to", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 6476, T0, "yell")
    local ts, why, cycles = Phase.Recall(store, ZA, 6476, INTERVAL, T0 + 100, 4)
    t.eq(ts, T0)
    t.eq(why, nil)
    t.eq(cycles, 0)
end)

t.test("a shard nobody has stood in has nothing to recall", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 6476, T0, "yell")
    local ts, why = Phase.Recall(store, ZA, 99999, INTERVAL, T0, 4)
    t.eq(ts, nil)
    t.eq(why, "nothing remembered")
    t.eq(Phase.Recall(Phase.New(), ZA, 1, INTERVAL, T0, 4), nil)
end)

t.test("the freshest anchor wins, because it is extrapolated the least", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0 + 500, "flying")
    Phase.Remember(store, ZA, 1, T0, "yell")
    t.eq(Phase.Recall(store, ZA, 1, INTERVAL, T0 + 600, 4), T0 + 500)
end)

-- The whole reason this is not simply "keep everything for ever". Zul'Aman's
-- gaps measure 1091 to 1099, so four seconds a cycle: a minute out after
-- fifteen cycles, five minutes out after a day.
t.test("a phase extrapolated too far is refused rather than shown", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0, "yell")

    local ts, why, cycles, err = Phase.Recall(store, ZA, 1, INTERVAL, T0 + INTERVAL * 10, 4)
    t.eq(ts, T0, "ten cycles at four seconds is forty out, which is still useful")
    t.eq(err, 40)

    ts, why, cycles, err = Phase.Recall(store, ZA, 1, INTERVAL, T0 + INTERVAL * 40, 4)
    t.eq(ts, nil)
    t.eq(why, "drifted too far")
    t.eq(cycles, 40)
    t.eq(err, 160, "and the refusal still says how far out it would have been")
end)

t.test("a shakier interval is trusted across fewer cycles", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0, "yell")
    local at = T0 + INTERVAL * 20
    t.ok(Phase.Recall(store, ZA, 1, INTERVAL, at, 4), "four seconds a cycle survives twenty")
    t.eq(Phase.Recall(store, ZA, 1, INTERVAL, at, 30), nil, "thirty does not")
end)

t.test("the drift is how well the cycle length is known, not how wide it spreads", function()
    local gaps = {}
    for _, per in ipairs({ 1091, 1095, 1099 }) do Timers.NoteGap(gaps, ZA, per, 1095) end
    -- Eight wide, so a standard deviation near two, over the root of three.
    t.near(Phase.Drift(gaps, ZA, Timers.GapCluster), 1.15, 0.05)
end)

t.test("more readings that agree make the drift smaller, not larger", function()
    local few, many = {}, {}
    for _, per in ipairs({ 1091, 1095, 1099 }) do Timers.NoteGap(few, ZA, per, 1095) end
    for _, per in ipairs({ 1091, 1093, 1095, 1096, 1097, 1099 }) do
        Timers.NoteGap(many, ZA, per, 1095)
    end
    t.lt(Phase.Drift(many, ZA, Timers.GapCluster), Phase.Drift(few, ZA, Timers.GapCluster))
end)

-- The mistake the first attempt made. Range grows with the worst pairing in
-- the pile, so evidence made the addon trust itself less: Zul'Aman came out at
-- nineteen seconds a cycle on gaps whose core spans eight.
t.test("one bad pairing does not widen the drift", function()
    local clean, dirty = {}, {}
    local core = { 1091, 1093, 1095, 1096, 1098 }
    for _, per in ipairs(core) do
        Timers.NoteGap(clean, ZA, per, 1095)
        Timers.NoteGap(dirty, ZA, per, 1095)
    end
    Timers.NoteGap(dirty, ZA, 1061, 1095)
    t.eq(Phase.Drift(dirty, ZA, Timers.GapCluster), Phase.Drift(clean, ZA, Timers.GapCluster))
end)

t.test("too few readings to see a cluster means assuming the worst", function()
    local gaps = {}
    Timers.NoteGap(gaps, ZA, 1095, 1095)
    Timers.NoteGap(gaps, ZA, 1094, 1095)
    t.eq(Phase.Drift(gaps, ZA, Timers.GapCluster), Phase.UNKNOWN_DRIFT)
    t.eq(Phase.Drift({}, ZA, Timers.GapCluster), Phase.UNKNOWN_DRIFT)
end)

t.test("nothing is recalled from the future", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0 + 5000, "yell")
    local ts, why = Phase.Recall(store, ZA, 1, INTERVAL, T0, 4)
    t.eq(ts, nil)
    t.eq(why, "in the future")
end)

-- Prune exists for legibility and always has. What it must not also do is
-- forget, which is what it was doing.
t.test("what the timers hold is absorbed before anything prunes it", function()
    local store, crates = Phase.New(), Timers.New()
    Timers.Record(crates, ZA, 6476, T0, "yell")
    Timers.Record(crates, HA, 45, T0 - 100, "flying")
    t.eq(Phase.Absorb(store, crates), 2)

    Timers.Prune(crates, function() return INTERVAL end, T0 + INTERVAL * 10)
    t.eq(next(crates), nil, "the display list is cleared")
    t.eq(Phase.Recall(store, ZA, 6476, INTERVAL, T0 + INTERVAL * 10, 4), T0,
        "and the phase survives it")
end)

t.test("absorbing twice does not lose the better anchor", function()
    local store, crates = Phase.New(), Timers.New()
    Timers.Record(crates, ZA, 1, T0 + 500, "yell")
    Phase.Absorb(store, crates)
    Phase.Absorb(store, crates)
    t.eq(Phase.Recall(store, ZA, 1, INTERVAL, T0 + 600, 4), T0 + 500)
end)

t.test("a phase older than a week is let go", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0, "yell")
    t.eq(Phase.Forget(store, T0 + 3600), 0)
    t.eq(Phase.Forget(store, T0 + Phase.KEEP + 1), 1)
    t.eq(next(store), nil)
end)

t.test("a recalled phase carries how it was anchored in the first place", function()
    local store = Phase.New()
    Phase.Remember(store, ZA, 1, T0, "yell")
    local _, _, _, _, source = Phase.Recall(store, ZA, 1, INTERVAL, T0 + 60, 4)
    t.eq(source, "yell")
end)
