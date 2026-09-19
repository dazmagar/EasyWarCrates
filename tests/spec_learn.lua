local ns, t = ...
local Learn = ns.Learn

-- Voidstorm, the zone that made this module necessary. Shipped catalogue holds
-- six spots; RCT's farmed list has two more that Wowhead never recorded.
local ZONE = 2405
local SHIPPED_ONE = { x = 0.382, y = 0.568 }   -- in the shipped catalogue
local GAP_ONE     = { x = 0.595, y = 0.543 }   -- 12.5% of map from anything shipped
local GAP_TWO     = { x = 0.4933, y = 0.3553 } -- 24% away

-- Captured now, before any test has run. The shipped table is shared module
-- state, so a test that reads its size mid-file is measuring whatever earlier
-- tests left behind -- which is exactly how the guard below failed to notice
-- Merged appending into it.
local SHIPPED_COUNT = #ns.ShippedDropPoints(ZONE)

t.test("a landing on a shipped spot teaches nothing", function()
    local store = {}
    t.eq(Learn.Note(store, ZONE, SHIPPED_ONE.x, SHIPPED_ONE.y), "known")
    t.eq(next(store), nil, "the shipped catalogue must never be added to")
end)

t.test("a landing within scatter of a shipped spot is still that spot", function()
    local store = {}
    -- 0.8% of map off, inside the measured 0.86% worst-case scatter.
    t.eq(Learn.Note(store, ZONE, SHIPPED_ONE.x + 0.008, SHIPPED_ONE.y), "known")
    t.eq(next(store), nil)
end)

t.test("a landing nowhere near the catalogue is learned", function()
    local store = {}
    local verdict, spot = Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    t.eq(verdict, "learned")
    t.eq(spot.n, 1)
    t.ok(spot.learned, "learned spots stay distinguishable from shipped ones")
    t.eq(#store[ZONE], 1)
end)

t.test("seeing a learned spot again averages it in rather than duplicating it", function()
    local store = {}
    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    local verdict, spot = Learn.Note(store, ZONE, GAP_ONE.x + 0.004, GAP_ONE.y)
    t.eq(verdict, "reinforced")
    t.eq(#store[ZONE], 1, "one spot, not two")
    t.eq(spot.n, 2)
    t.near(spot.x, GAP_ONE.x + 0.002, 1e-9, "the spot moves to the mean of its sightings")
end)

t.test("two genuinely different gaps become two spots", function()
    local store = {}
    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    Learn.Note(store, ZONE, GAP_TWO.x, GAP_TWO.y)
    t.eq(#store[ZONE], 2)
end)

t.test("merged output is shipped plus learned", function()
    local store = {}
    t.eq(#Learn.Merged(store, ZONE), SHIPPED_COUNT, "nothing learned yet, nothing added")

    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    t.eq(#Learn.Merged(store, ZONE), SHIPPED_COUNT + 1)
end)

t.test("merging never mutates the shipped catalogue", function()
    local store = {}
    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    Learn.Merged(store, ZONE)
    Learn.Merged(store, ZONE)
    t.eq(#ns.ShippedDropPoints(ZONE), SHIPPED_COUNT,
        "the shipped table is shared and must survive repeated merges intact")
end)

-- The catalogue is what prediction runs on, so a bad reading getting in would
-- steer real waypoints at nothing.
t.test("coordinates off the map are refused", function()
    local store = {}
    t.eq(Learn.Note(store, ZONE, -0.1, 0.5), "invalid")
    t.eq(Learn.Note(store, ZONE, 0.5, 1.4), "invalid")
    t.eq(Learn.Note(store, ZONE, nil, 0.5), "invalid")
    t.eq(Learn.Note(store, nil, 0.5, 0.5), "invalid")
    t.eq(Learn.Note(nil, ZONE, 0.5, 0.5), "invalid")
    t.eq(next(store), nil)
end)

t.test("a zone cannot grow spots without bound", function()
    local store = {}
    -- Spread far enough apart that none of them merge.
    local placed = 0
    for i = 1, Learn.MAX_PER_ZONE + 5 do
        local x = 0.02 + (i % 12) * 0.08
        local y = 0.02 + math.floor(i / 12) * 0.08
        if Learn.Note(store, ZONE, x, y) == "learned" then placed = placed + 1 end
    end
    t.eq(#store[ZONE], Learn.MAX_PER_ZONE)
    t.lt(placed, Learn.MAX_PER_ZONE + 5)
end)

t.test("Count reports what is stored", function()
    local store = {}
    t.eq(Learn.Count(store), 0)
    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    Learn.Note(store, ZONE, GAP_TWO.x, GAP_TWO.y)
    Learn.Note(store, 2437, 0.10, 0.10)
    local spots, zones = Learn.Count(store)
    t.eq(spots, 3)
    t.eq(zones, 2)
end)

-- The whole point: once learned, the gap is predictable.
t.test("a learned spot becomes a prediction candidate", function()
    local store = {}
    local fit = { x = 0.30, y = 0.543, hx = 1, hy = 0, err = 0, n = 40, speed = 0.007 }

    local before = ns.Predict.Evaluate(Learn.Merged(store, ZONE), fit)
    t.notOk(before.ok, "nothing shipped lies along this heading")

    Learn.Note(store, ZONE, GAP_ONE.x, GAP_ONE.y)
    local after = ns.Predict.Evaluate(Learn.Merged(store, ZONE), fit)
    t.ok(after.ok, "the learned spot should now be found: " .. tostring(after.reason))
    t.near(after.best.spot.x, GAP_ONE.x, 1e-9)
end)
