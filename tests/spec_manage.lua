local ns, t = ...
local Manage, Timers, Airtime, Learn = ns.Manage, ns.Timers, ns.Airtime, ns.Learn

local ZA, HA, SR = 2437, 2413, 2444
local T0 = 1000000

local function freshDB()
    return {
        crates  = Timers.New(),
        descent = {},
        gaps    = {},
        learned = {},
        travel  = {},
        route   = {},
    }
end

local function removable(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if not r.head then out[#out + 1] = r end
    end
    return out
end

t.test("an empty database lists nothing anywhere", function()
    local db = freshDB()
    for _, section in ipairs(Manage.SECTIONS) do
        t.eq(#Manage.Rows(db, section.id, T0), 0, section.id .. " should be empty")
        t.eq(Manage.Count(db, section.id, T0), 0, section.id .. " count")
    end
end)

t.test("an unknown section is empty rather than an error", function()
    t.eq(#Manage.Rows(freshDB(), "nonsense", T0), 0)
    t.eq(#Manage.Rows(nil, "timers", T0), 0)
end)

t.test("a timer row names its zone and shard and can be removed", function()
    local db = freshDB()
    Timers.Record(db.crates, HA, 4821, T0 - 300, "flying")
    local rows = Manage.Rows(db, "timers", T0)
    t.eq(#rows, 1)
    t.eq(rows[1].zoneID, HA)
    t.eq(rows[1].shardID, 4821)
    t.ok(rows[1].label:find("4821", 1, true), "the shard is on the row: " .. rows[1].label)
    t.eq(rows[1].note, "caught in the air")

    t.ok(Manage.Remove(db, rows[1]))
    t.eq(#Manage.Rows(db, "timers", T0), 0)
    t.eq(db.crates[HA], nil, "the zone goes when its last shard does")
end)

t.test("a timer nobody has confirmed for cycles is dimmed", function()
    local db = freshDB()
    Timers.Record(db.crates, HA, 1, T0, "flying")
    Timers.Record(db.crates, ZA, 2, T0 - 1100 * 4, "flying")
    local rows = Manage.Rows(db, "timers", T0)
    local byZone = {}
    for _, r in ipairs(rows) do byZone[r.zoneID] = r end
    t.notOk(byZone[HA].dim, "a fresh timer is not dimmed")
    t.ok(byZone[ZA].dim, "four missed cycles is past the window")
    t.ok(byZone[ZA].note:find("unseen", 1, true), byZone[ZA].note)
end)

t.test("descent readings are grouped under a zone heading that carries the median", function()
    local db = freshDB()
    for _, s in ipairs({ 86, 86, 87 }) do Airtime.NoteDescent(db.descent, HA, s) end
    local rows = Manage.Rows(db, "descent", T0)
    t.eq(#rows, 4, "one heading plus three readings")
    t.ok(rows[1].head)
    t.ok(rows[1].value:find("86", 1, true), rows[1].value)
    t.eq(rows[2].value, "86s")
    t.eq(Manage.Count(db, "descent", T0), 3, "a heading is not a removable row")
end)

t.test("a partial descent reading says so and is dimmed", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    Airtime.NoteDescent(db.descent, HA, 19, { partial = true })
    local rows = removable(Manage.Rows(db, "descent", T0))
    t.eq(#rows, 2)
    t.notOk(rows[1].dim)
    t.ok(rows[2].dim, "a reading kept out of the median should look different")
    t.ok(rows[2].note:find("mid-fall", 1, true), rows[2].note)
end)

t.test("where a descent was measured is on its row", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, ZA, 85, { pos = { x = 0.489, y = 0.692 } })
    local row = removable(Manage.Rows(db, "descent", T0))[1]
    t.ok(row.note:find("48.9, 69.2", 1, true), row.note)
end)

t.test("removing a descent reading takes the one on the row", function()
    local db = freshDB()
    for _, s in ipairs({ 84, 85, 86 }) do Airtime.NoteDescent(db.descent, HA, s) end
    local rows = removable(Manage.Rows(db, "descent", T0))
    t.ok(Manage.Remove(db, rows[2]))
    t.eq(#db.descent[HA], 2)
    t.eq(db.descent[HA][1].secs, 84)
    t.eq(db.descent[HA][2].secs, 86, "85 went, not the one after it")
end)

t.test("the last reading in a zone takes the zone with it", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    local row = removable(Manage.Rows(db, "descent", T0))[1]
    t.ok(Manage.Remove(db, row))
    t.eq(db.descent[HA], nil)
end)

-- The reason every row carries a stamp. The panel is open, a reading arrives
-- mid-fall in another zone, the player clicks remove on a row painted before
-- it. Without the guard the index now points at a different record.
t.test("a row refuses to delete a record that changed under it", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    local row = removable(Manage.Rows(db, "descent", T0))[1]

    table.remove(db.descent[HA], 1)
    Airtime.NoteDescent(db.descent, HA, 129)

    local ok, why = Manage.Remove(db, row)
    t.notOk(ok)
    t.eq(why, "changed")
    t.eq(db.descent[HA][1].secs, 129, "and the record it would have hit is untouched")
end)

t.test("a row refuses to delete a record that is already gone", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    local row = removable(Manage.Rows(db, "descent", T0))[1]
    Manage.Clear(db, "descent")
    local ok, why = Manage.Remove(db, row)
    t.notOk(ok)
    t.eq(why, "gone")
end)

t.test("a timer refuses to be removed once it has moved on", function()
    local db = freshDB()
    Timers.Record(db.crates, HA, 7, T0 - 2000, "flying")
    local row = Manage.Rows(db, "timers", T0)[1]
    Timers.Record(db.crates, HA, 7, T0, "flying")
    local ok, why = Manage.Remove(db, row)
    t.notOk(ok)
    t.eq(why, "changed")
    t.ok(db.crates[HA][7], "the newer drop survives")
end)

t.test("a heading row cannot be removed", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    local head = Manage.Rows(db, "descent", T0)[1]
    t.ok(head.head)
    local ok, why = Manage.Remove(db, head)
    t.notOk(ok)
    t.eq(why, "invalid")
end)

t.test("an interval row reports the per-cycle figure, not the raw gap", function()
    local db = freshDB()
    Timers.NoteGap(db.gaps, HA, 4344, 1100)
    local row = removable(Manage.Rows(db, "interval", T0))[1]
    t.eq(row.value, "1086s")
    t.ok(row.note:find("4 drops", 1, true), row.note)
    t.ok(Manage.Remove(db, row))
    t.eq(db.gaps[HA], nil)
end)

-- Well clear of every shipped Zul'Aman spot, or Learn.Note answers "known"
-- and stores nothing: the shipped catalogue is never edited.
local NEW_SPOT_X, NEW_SPOT_Y = 0.80, 0.15

t.test("learned drop points are listed in percent and counted", function()
    local db = freshDB()
    Learn.Note(db.learned, ZA, NEW_SPOT_X, NEW_SPOT_Y)
    Learn.Note(db.learned, ZA, NEW_SPOT_X, NEW_SPOT_Y)
    local rows = Manage.Rows(db, "spots", T0)
    t.ok(rows[1].head)
    t.eq(rows[2].value, "80.0, 15.0")
    t.ok(rows[2].note:find("2 sighting", 1, true), rows[2].note)
    t.notOk(rows[2].dim, "two sightings is no longer a single guess")
end)

t.test("a drop point reinforced under the panel is not removed", function()
    local db = freshDB()
    Learn.Note(db.learned, ZA, NEW_SPOT_X, NEW_SPOT_Y)
    local row = removable(Manage.Rows(db, "spots", T0))[1]
    Learn.Note(db.learned, ZA, NEW_SPOT_X + 0.005, NEW_SPOT_Y + 0.002)
    local ok, why = Manage.Remove(db, row)
    t.notOk(ok)
    t.eq(why, "changed")
    t.eq(#db.learned[ZA], 1, "the averaged spot is still there")
end)

t.test("the route lists its zones in order and moves them", function()
    local db = freshDB()
    db.route = { ZA, HA, SR }
    local rows = Manage.Rows(db, "route", T0)
    t.eq(#rows, 3)
    t.eq(rows[1].zoneID, ZA)

    t.ok(Manage.Move(db, rows[2], -1))
    t.eq(db.route[1], HA)
    t.eq(db.route[2], ZA)
end)

t.test("a route entry cannot be moved off either end", function()
    local db = freshDB()
    db.route = { ZA, HA }
    local rows = Manage.Rows(db, "route", T0)
    local ok, why = Manage.Move(db, rows[1], -1)
    t.notOk(ok)
    t.eq(why, "edge")
    t.eq(db.route[1], ZA, "and nothing moved")
    t.notOk(Manage.Move(db, rows[2], 1))
end)

t.test("a zone joins the route once and only once", function()
    local db = freshDB()
    t.ok(Manage.AddToRoute(db, ZA))
    local ok, why = Manage.AddToRoute(db, ZA)
    t.notOk(ok)
    t.eq(why, "already")
    t.eq(#db.route, 1)
    t.notOk(Manage.AddToRoute(db, 99999), "a zone the addon does not track")
end)

t.test("only overridden travel times are listed, and removing one reverts it", function()
    local db = freshDB()
    t.eq(#Manage.Rows(db, "travel", T0), 0, "shipped estimates are not overrides")
    db.travel[HA] = 120
    local row = Manage.Rows(db, "travel", T0)[1]
    t.eq(row.value, "120s")
    t.ok(row.note:find("75", 1, true), row.note)
    t.ok(Manage.Remove(db, row))
    t.eq(db.travel[HA], nil)
end)

t.test("clearing one zone leaves the others alone", function()
    local db = freshDB()
    Airtime.NoteDescent(db.descent, HA, 86)
    Airtime.NoteDescent(db.descent, HA, 87)
    Airtime.NoteDescent(db.descent, ZA, 85)
    t.eq(Manage.Clear(db, "descent", HA), 2)
    t.eq(db.descent[HA], nil)
    t.eq(#db.descent[ZA], 1)
    t.eq(Manage.Clear(db, "descent", HA), 0, "clearing it again finds nothing")
end)

t.test("clearing a whole section counts every record in it", function()
    local db = freshDB()
    Timers.Record(db.crates, HA, 1, T0, "flying")
    Timers.Record(db.crates, HA, 2, T0, "flying")
    Timers.Record(db.crates, ZA, 3, T0, "flying")
    t.eq(Manage.Clear(db, "timers"), 3)
    t.eq(Manage.Count(db, "timers", T0), 0)
end)

t.test("clearing the route empties it without dropping the table", function()
    local db = freshDB()
    db.route = { ZA, HA }
    t.eq(Manage.Clear(db, "route"), 2)
    t.eq(type(db.route), "table")
    t.eq(#db.route, 0)
end)

t.test("zones keep a fixed order between two builds of the same data", function()
    local db = freshDB()
    for _, z in ipairs({ SR, ZA, HA }) do Airtime.NoteDescent(db.descent, z, 86) end
    local first = Manage.Rows(db, "descent", T0)
    local second = Manage.Rows(db, "descent", T0)
    for i = 1, #first do
        t.eq(second[i].zoneID, first[i].zoneID, "row " .. i .. " moved between paints")
    end
    t.eq(first[1].label, "Harandar", "and the order is by name, not by whatever pairs gave")
end)
