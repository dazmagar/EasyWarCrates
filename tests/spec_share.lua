local ns, t = ...
local Share, Airtime, Learn = ns.Share, ns.Airtime, ns.Learn

local ZA, SR = 2437, 2444

-- Two stores are worth handing to another player and the rest are not. A
-- parachute time and a drop point are facts about the world; a timer belongs
-- to one copy of one zone at one moment, and a shard this client stood in is
-- worth nothing to anybody else. So the string carries descents and points,
-- and Export is given the whole db deliberately: the test that matters is that
-- it takes only those two out of it.
local function store()
    local db = { descent = {}, learned = {}, crates = {}, phase = {}, gaps = {} }
    Airtime.NoteDescent(db.descent, ZA, 129, { pos = { x = 0.469, y = 0.622 } })
    Airtime.NoteDescent(db.descent, ZA, 129, { pos = { x = 0.470, y = 0.623 } })
    -- Twice, because one reading at a spot does not answer for it: Zul'Aman
    -- really has produced 65 and 65 here, 7% of the map from the 129s spot.
    Airtime.NoteDescent(db.descent, ZA, 65, { pos = { x = 0.369, y = 0.679 } })
    Airtime.NoteDescent(db.descent, ZA, 65, { pos = { x = 0.370, y = 0.680 } })
    db.crates[ZA] = { [44] = { ts = 1792020394, gap = 1088 } }
    return db
end

t.test("the string carries the readings and says how many", function()
    local text = Share.Export(store())
    t.ok(text:find("^EWC1~"), "a version this client will refuse to read is worse than none")
    t.eq(select(2, text:gsub("~d:", "")), 4, "four descents")
    t.ok(text:find("~n:4"), "the count is the only thing that catches a truncated paste")
end)

t.test("a timer and a shard are not somebody else's business", function()
    local text = Share.Export(store())
    t.notOk(text:find("1792020394"), "no timestamps")
    t.notOk(text:find(":44:"), "no shards")
end)

t.test("what goes out comes back the same", function()
    local text = Share.Export(store())
    local into = { descent = {}, learned = {} }
    local ok, got = Share.Import(into, text, "Rdy")
    t.ok(ok, tostring(got))
    t.eq(got.descent, 4)
    local secs, n = Airtime.Descent(into.descent, ZA, { x = 0.469, y = 0.622 })
    t.eq(n, 2, "both readings for that spot survived the trip")
    t.eq(secs, 129)
    t.eq(Airtime.Descent(into.descent, ZA, { x = 0.369, y = 0.679 }), 65,
        "and the spot 7% away is still its own fall")
end)

-- A reading nobody can place is no use to anybody: the whole value of the
-- descent store is that it is keyed on where the crate came down.
t.test("readings without a position are left at home", function()
    local db = { descent = {}, learned = {} }
    Airtime.NoteDescent(db.descent, ZA, 100, {})
    t.ok(Share.Export(db):find("~n:0"), "nothing to send")
end)

-- Partials are lower bounds on a fall somebody walked in on. They are counted
-- and shown here, and every figure excludes them, so sending them would be
-- sending the half of the store that answers nothing.
t.test("partial readings are left at home too", function()
    local db = { descent = {}, learned = {} }
    Airtime.NoteDescent(db.descent, ZA, 40,
        { pos = { x = 0.469, y = 0.622 }, partial = true, why = "arrived late" })
    t.ok(Share.Export(db):find("~n:0"))
end)

t.test("a drop point this addon does not ship is carried", function()
    local db = { descent = {}, learned = {} }
    t.eq(Learn.Note(db.learned, SR, 0.4940, 0.5248), "learned")
    local text = Share.Export(db)
    t.eq(select(2, text:gsub("~l:", "")), 1)

    local into = { descent = {}, learned = {} }
    t.ok(Share.Import(into, text, "Rdy"))
    local merged = Learn.Merged(into.learned, SR)
    local found
    for _, p in ipairs(merged) do
        if math.abs(p.x - 0.494) < 0.002 and math.abs(p.y - 0.525) < 0.002 then found = p end
    end
    t.ok(found, "the point arrived where it was sent from")
end)

t.test("a truncated paste is refused whole", function()
    local text = Share.Export(store())
    local cut = text:sub(1, #text - 12)
    local into = { descent = {}, learned = {} }
    local ok, why = Share.Import(into, cut, "Rdy")
    t.notOk(ok)
    t.ok(tostring(why):find("count") or tostring(why):find("truncat"), tostring(why))
    t.eq(#(into.descent[ZA] or {}), 0, "and nothing of it was kept")
end)

t.test("a string from another addon, or from nowhere, is refused", function()
    local into = { descent = {}, learned = {} }
    t.notOk(Share.Import(into, "!WA:2!abcdef", "Rdy"))
    t.notOk(Share.Import(into, "EWC9~d:2437:469:622:129~n:1", "Rdy"))
    t.notOk(Share.Import(into, "", "Rdy"))
    t.notOk(Share.Import(into, nil, "Rdy"))
end)

t.test("a record that is not a record refuses the whole string", function()
    local into = { descent = {}, learned = {} }
    local ok, why = Share.Import(into,
        "EWC1~d:2437:469:622:129~d:2437:nonsense~n:2", "Rdy")
    t.notOk(ok, tostring(why))
    t.eq(#(into.descent[ZA] or {}), 0,
        "a half-import cannot be undone, so there is no such thing")
end)

t.test("a zone with no crates in it is refused", function()
    local into = { descent = {}, learned = {} }
    t.notOk(Share.Import(into, "EWC1~d:84:500:500:100~n:1", "Rdy"), "Stormwind")
end)

t.test("an impossible fall is refused", function()
    local into = { descent = {}, learned = {} }
    t.notOk(Share.Import(into, "EWC1~d:2437:469:622:9000~n:1", "Rdy"))
end)

-- The one way an import could do real damage. The store keeps 40 readings per
-- zone and drops the oldest to make room, so 40 imported readings would push
-- out every reading the player watched for themselves.
t.test("an import never pushes out a reading of your own", function()
    local mine = { descent = {}, learned = {} }
    for i = 1, 40 do
        Airtime.NoteDescent(mine.descent, ZA, 90 + (i % 3), { pos = { x = 0.398, y = 0.275 } })
    end
    t.eq(#mine.descent[ZA], 40, "full")

    local theirs = Share.Export(store())
    local ok, got = Share.Import(mine, theirs, "Rdy")
    t.ok(ok, tostring(got))
    t.eq(got.descent, 0)
    t.eq(got.full, 4, "all four had nowhere to go")
    t.eq(#mine.descent[ZA], 40)
    t.eq(Airtime.Descent(mine.descent, ZA, { x = 0.398, y = 0.275 }), 91,
        "and the spot they were watching still reads what they measured")
end)

-- Provenance, because a figure that came out of a stranger's string and one
-- the player timed themselves are not the same evidence, and /ewc airtime is
-- the place that has to be able to say which is which.
t.test("an imported reading says whose it was", function()
    local into = { descent = {}, learned = {} }
    Share.Import(into, Share.Export(store()), "Rdy")
    t.eq(into.descent[ZA][1].via, "Rdy")
    t.notOk(into.descent[ZA][1].partial)
end)

t.test("an empty store still exports a string that imports cleanly", function()
    local text = Share.Export({ descent = {}, learned = {} })
    local into = { descent = {}, learned = {} }
    local ok, got = Share.Import(into, text, "Rdy")
    t.ok(ok)
    t.eq(got.descent, 0)
    t.eq(got.points, 0)
end)
