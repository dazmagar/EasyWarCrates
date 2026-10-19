local ns, t = ...
local Remote, Timers = ns.Remote, ns.Timers

local ZA, HA, VS = 2437, 2413, 2405
local T0 = 1000000

local function report(over)
    local r = { zoneID = HA, shardID = 4821, stage = "flying", at = T0, from = "Scout" }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

t.test("a well-formed report is taken", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, report(), T0), "new")
    t.eq(Remote.Count(store, T0), 1)
    local entry = Remote.For(store, HA, T0)
    t.eq(entry.stage, "flying")
    t.eq(entry.from, "Scout")
end)

t.test("a newer report about the same shard replaces the one held", function()
    local store = Remote.New()
    Remote.Note(store, report(), T0)
    t.eq(Remote.Note(store, report({ stage = "falling", at = T0 + 90 }), T0 + 90), "refresh")
    t.eq(Remote.For(store, HA, T0 + 90).stage, "falling")
    t.eq(Remote.Count(store, T0 + 90), 1, "still one crate, not two")
end)

t.test("an older report does not undo a newer one", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "ground", at = T0 + 100 }), T0 + 100)
    t.eq(Remote.Note(store, report({ at = T0 }), T0 + 100), "stale")
    t.eq(Remote.For(store, HA, T0 + 100).stage, "ground")
end)

t.test("a report is refused when it is not about anything we track", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, report({ zoneID = 99999 }), T0), "invalid")
    -- Built by hand: a nil in a table constructor is an absent key, so the
    -- override helper cannot express "this field is missing".
    t.eq(Remote.Note(store, { zoneID = HA, stage = "flying", at = T0, from = "Scout" }, T0),
        "invalid", "no shard")
    t.eq(Remote.Note(store, { zoneID = HA, shardID = 1, stage = "flying", from = "Scout" }, T0),
        "invalid", "no timestamp")
    t.eq(Remote.Note(store, report({ stage = "teatime" }), T0), "invalid")
    t.eq(Remote.Note(store, report({ at = "soon" }), T0), "invalid")
    t.eq(Remote.Note(store, report({ from = "" }), T0), "invalid")
    t.eq(Remote.Note(store, nil, T0), "invalid")
    t.eq(Remote.Count(store, T0), 0)
end)

-- A client whose clock is wrong does not send a late message, it sends a
-- wrong one, and every timer its timestamps touch inherits the error.
t.test("a timestamp from the future is refused", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, report({ at = T0 + 3600 }), T0), "invalid")
    t.eq(Remote.Note(store, report({ at = T0 + 30 }), T0), "new", "a little skew is normal")
end)

t.test("a report that arrives after its crate is over is not taken", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, report({ stage = "ground" }), T0 + 400), "stale")
    t.eq(Remote.Count(store, T0 + 400), 0)
end)

t.test("the most urgent live report wins, then the freshest", function()
    local store = Remote.New()
    Remote.Note(store, report({ shardID = 1, stage = "flying", at = T0 }), T0)
    Remote.Note(store, report({ shardID = 2, stage = "ground", at = T0 }), T0)
    Remote.Note(store, report({ shardID = 3, stage = "falling", at = T0 }), T0)
    local best, shard = Remote.For(store, HA, T0)
    t.eq(best.stage, "ground", "a crate you can pick up outranks one in the air")
    t.eq(shard, 2)
end)

-- Written against the lifetime rather than a number, because the right
-- lifetime is a judgement that has already changed once: ground was three
-- minutes until it was clear a raid takes a crate within seconds of it
-- landing, and the cost of the report outliving the crate falls on whoever
-- crosses a zone for it.
t.test("reports age out of the list without being cleared by hand", function()
    local store = Remote.New()
    local lasts = Remote.LIFETIME.ground
    Remote.Note(store, report({ stage = "ground" }), T0)
    t.ok(Remote.For(store, HA, T0 + lasts - 10))
    t.eq(Remote.For(store, HA, T0 + lasts + 10), nil, "nobody left it lying that long")
    t.eq(Remote.Count(store, T0 + lasts + 10), 0)
end)

t.test("expiring drops the aged entries and the zone with them", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "ground", at = T0 }), T0)
    Remote.Note(store, report({ zoneID = ZA, stage = "flying", at = T0 + 200 }), T0 + 200)
    t.eq(Remote.Expire(store, T0 + 250), 1)
    t.eq(store[HA], nil)
    t.ok(store[ZA])
end)

t.test("leaving the raid takes every report with it", function()
    local store = Remote.New()
    Remote.Note(store, report(), T0)
    Remote.Note(store, report({ zoneID = ZA }), T0)
    Remote.Clear(store)
    t.eq(Remote.Count(store, T0), 0)
    t.eq(next(store), nil)
end)

-- The point of the whole module. Until the raid confirms it, nothing a
-- stranger said is allowed near the saved timers.
t.test("a report on its own never reaches the saved timers", function()
    local store, db = Remote.New(), Timers.New()
    Remote.Note(store, report(), T0)
    Remote.Note(store, report({ zoneID = ZA, shardID = 9 }), T0)
    t.eq(next(db), nil)
end)

t.test("promotion files the scout's anchor, not ours", function()
    local store, db = Remote.New(), Timers.New()
    Remote.Note(store, report({ stage = "flying", at = T0 }), T0)

    -- We fly there and find it already on the ground four minutes later.
    Timers.Record(db, HA, 4821, T0 + 240, "ground")
    t.eq(db[HA][4821].ts, T0 + 240)
    t.notOk(db[HA][4821].precise, "found on the ground says nothing about when it spawned")

    local verdict = Remote.Promote(store, db, HA, 4821)
    t.eq(verdict, "refined")
    t.eq(db[HA][4821].ts, T0, "the transport was caught at T0, so that is the spawn")
    t.ok(db[HA][4821].precise)
    t.eq(db[HA][4821].via, "Scout", "and the row says whose reading it was")
end)

t.test("a report is promoted once, however often the crate is seen again", function()
    local store, db = Remote.New(), Timers.New()
    Remote.Note(store, report(), T0)
    t.ok(Remote.Promote(store, db, HA, 4821))
    t.eq(Remote.Promote(store, db, HA, 4821), nil)
end)

t.test("the crate moving on does not hand a promoted report a second go", function()
    local store, db = Remote.New(), Timers.New()
    Remote.Note(store, report({ stage = "flying", at = T0 }), T0)
    Remote.Promote(store, db, HA, 4821)
    Remote.Note(store, report({ stage = "ground", at = T0 + 120 }), T0 + 120)
    t.eq(Remote.Promote(store, db, HA, 4821), nil)
end)

t.test("there is nothing to promote when nobody reported anything", function()
    t.eq(Remote.Promote(Remote.New(), Timers.New(), HA, 4821), nil)
    t.eq(Remote.Promote(nil, Timers.New(), HA, 4821), nil)
end)

-- The wire.

local BY_NAME = { ["Harandar"] = HA, ["Zul'Aman"] = ZA, ["Харандар"] = HA }

t.test("our own message survives a round trip", function()
    local wire = Remote.Encode({ stage = "falling", zoneID = HA, shardID = 4821,
                                 at = T0, x = 0.489, y = 0.692 })
    local back = Remote.Decode("EWC1", wire, "Scout")
    t.eq(back.stage, "falling")
    t.eq(back.zoneID, HA)
    t.eq(back.shardID, 4821)
    t.eq(back.at, T0)
    t.near(back.x, 0.489, 1e-4)
    t.eq(back.from, "Scout")
    t.eq(back.via, "EWC")
end)

t.test("a message with no predicted landing still decodes", function()
    local back = Remote.Decode("EWC1", Remote.Encode(
        { stage = "flying", zoneID = ZA, shardID = 7, at = T0 }), "Scout")
    t.eq(back.zoneID, ZA)
    t.eq(back.x, nil)
end)

t.test("a message from a protocol we do not speak is refused", function()
    t.eq(Remote.Decode("EWC1", "9~flying~2413~1~1000000~~", "Scout"), nil)
    t.eq(Remote.Decode("EWC1", "", "Scout"), nil)
    t.eq(Remote.Decode("EWC1", "rubbish", "Scout"), nil)
    t.eq(Remote.Decode("NotOurs", "1~flying~2413~1~1000000~~", "Scout"), nil)
end)

-- SPOT_V2~vignetteID~ts~zoneID~spotter~shardID~guid, in the clear.
t.test("a WarCrateTracker sighting decodes into a report", function()
    local r = Remote.Decode("WarCrateTracker",
        "SPOT_V2~3689~1000000~2413~Someone~4821~Creature-0-1-2-3-4-5", "Sender")
    t.eq(r.stage, "flying", "vignette 3689 is the transport")
    t.eq(r.zoneID, HA)
    t.eq(r.shardID, 4821)
    t.eq(r.at, T0)
    t.eq(r.from, "Someone", "the spotter, not whoever relayed it")
    t.eq(r.via, "WCT")
end)

-- Their shard arrives as text and ours comes off a GUID as a number. Keyed
-- both ways the same zone grows a second row that looks like a second crate.
t.test("a shard from another addon keys the same as one of ours", function()
    local r = Remote.Decode("WarCrateTracker",
        "SPOT_V2~6066~1000000~2413~Someone~4821~x", "Sender")
    t.eq(type(r.shardID), "number")
end)

t.test("their older format carries no shard and is passed over", function()
    t.eq(Remote.Decode("WarCrateTracker",
        "SPOT~Flying~1000000~2413~2537~Harandar~Quel'thalas~Someone", "Sender"), nil)
end)

t.test("RCT's raid alert becomes a transport sighting", function()
    local r = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Harandar - Shard: 4821",
        "Leader", BY_NAME, T0)
    t.eq(r.stage, "flying")
    t.eq(r.zoneID, HA)
    t.eq(r.shardID, 4821)
    t.eq(r.from, "Leader")
    t.eq(r.via, "RCT")
end)

t.test("the alert reads a zone name in the sender's own language", function()
    local r = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Харандар - Shard: 12", "Leader", BY_NAME, T0)
    t.eq(r.zoneID, HA)
end)

-- A raid on mixed locales sends names this client cannot resolve. Saying which
-- name failed is the difference between a fixable gap and a silent one.
t.test("an unresolvable zone name is reported back, not swallowed", function()
    local r, name = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Nachtwald - Shard: 3", "Leader", BY_NAME, T0)
    t.eq(r, nil)
    t.eq(name, "Nachtwald")
end)

-- The shard outlives the name, and it is the only handle on which zone was
-- meant. One raid produced Leerensturm, Schlaechteranhoehe and a Russian name
-- besides; each of those senders' reports was dropped whole.
t.test("the shard comes back with a name this client cannot read", function()
    local r, name, shardID = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Leerensturm - Shard: 69", "Sender", BY_NAME, T0)
    t.eq(r, nil)
    t.eq(name, "Leerensturm")
    t.eq(shardID, 69, "so the name can be filed against the shards it arrived with")
end)

-- Deliberately not resolved from the shard on its own. Shard 39 has been seen
-- in Harandar, Slayer's Rise and Voidstorm on one account, so a low id matches
-- more than one zone and a wrong binding is worse than an unread name.
t.test("a readable name still wins, and a missing shard still refuses", function()
    local r = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Harandar - Shard: 39", "Sender", BY_NAME, T0)
    t.eq(r.zoneID, HA, "the name decides the zone, never the shard")

    local none, name2, shard2 = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Nachtwald - Shard: none", "Sender", BY_NAME, T0)
    t.eq(none, nil)
    t.eq(name2, "Nachtwald")
    t.eq(shard2, nil, "nothing to file it against, and it says so rather than inventing one")
end)

-- Measured from Dmitrii's /ewc comm on 2 Oct: three "falling in SR shard
-- 12561 (new)" twenty seconds apart, one parachute, one sender. Every one of
-- them printed a chat line about a crate he was standing under.
--
-- Supersede is why. It drops their report the moment this client sees the
-- crate for itself, so the next re-send lands in an empty slot and counts as
-- news. Note cannot tell that apart on its own -- the store really is empty --
-- so the test is whether this client can see the crate.
t.test("a crate this client can see makes their report redundant", function()
    local live = { zoneID = ZA, shard = 7, phase = "falling", since = T0 }
    t.ok(Remote.AlreadySeen(live, { zoneID = ZA, shardID = 7, stage = "falling" }),
        "same zone, same shard, so it is the crate in front of us")

    t.eq(Remote.AlreadySeen(live, { zoneID = ZA, shardID = 8, stage = "falling" }), false,
        "another shard is another copy of the zone and another crate")
    t.eq(Remote.AlreadySeen(nil, { zoneID = ZA, shardID = 7, stage = "falling" }), false,
        "nothing in view, so their report is the only thing there is")
    t.eq(Remote.AlreadySeen({ zoneID = ZA }, { zoneID = ZA, shardID = 7 }), false,
        "a sighting with no shard yet cannot be matched to one")
end)

-- The sequence from that log, start to finish, so the next person reading it
-- can see why a re-send comes back as new rather than as a refresh.
t.test("their re-send comes back as new once we have seen the crate", function()
    local store = Remote.New()
    local report = { stage = "falling", zoneID = ZA, shardID = 7, at = T0, from = "Scout" }
    t.eq(Remote.Note(store, report, T0), "new")

    t.ok(Remote.Supersede(store, ZA, 7, "falling"), "seeing it drops their account")

    local again = { stage = "falling", zoneID = ZA, shardID = 7, at = T0 + 20, from = "Scout" }
    t.eq(Remote.Note(store, again, T0 + 20), "new",
        "the store is empty, so Note is right and the caller has to be the one to stay quiet")
end)

-- Not a locale gap at all. Six reports of Zul'Aman were filed as a foreign
-- name because the sender's client writes the typographic apostrophe and a
-- plain table index is byte-exact.
t.test("a curly apostrophe still resolves to the zone this client knows", function()
    local r = Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Zul’Aman - Shard: 34020",
        "Sender", BY_NAME, T0)
    t.ok(r, "the name differs from ours by one character and means the same zone")
    t.eq(r.zoneID, ZA)
    t.eq(r.shardID, 34020)

    local c = Remote.FromCountdown(
        "Next Crate: Zul’Aman - 34020 in 02:46", "Sender", BY_NAME, T0, INTERVAL_OF)
    t.ok(c, "and the countdown line reads it too")
    t.eq(c.zoneID, ZA)
end)

t.test("ordinary raid chat is not an alert", function()
    t.eq(Remote.FromAlert("anyone got a summon", "Someone", BY_NAME, T0), nil)
    t.eq(Remote.FromAlert("Flying in Harandar", "Someone", BY_NAME, T0), nil)
    t.eq(Remote.FromAlert(nil, "Someone", BY_NAME, T0), nil)
    t.eq(Remote.FromAlert("War Crate Alert! Flying in Harandar - Shard: 1", "", BY_NAME, T0), nil)
end)

t.test("an alert with no shard number is not a timer", function()
    t.eq(Remote.FromAlert(
        "Hated Gaming - War Crate Alert! Flying in Harandar - Shard: N/A",
        "Leader", BY_NAME, T0), nil)
end)

t.test("a decoded foreign sighting goes through the same gate as our own", function()
    local store = Remote.New()
    local r = Remote.Decode("WarCrateTracker",
        "SPOT_V2~3689~1000000~2413~Someone~4821~x", "Sender")
    t.eq(Remote.Note(store, r, T0), "new")
    t.eq(Remote.Note(store, r, T0 + 9999), "stale", "age is judged the same either way")
end)

-- HGLog, the log RCT bundles. Plain text, so it is the one RCT-family source
-- that can be read without pulling in a serialiser and a compressor.
t.test("an HGLog batch decodes into one anchor per row", function()
    local rows = Remote.DecodeAnchors("HGLOG1",
        "1|FULL|1|2413,1000000,4821;2437,999500,2514", "Sender")
    t.eq(#rows, 2)
    t.eq(rows[1].zoneID, HA)
    t.eq(rows[1].at, T0)
    t.eq(rows[1].shardID, 4821)
    t.eq(rows[1].stage, "anchor")
    t.eq(rows[1].via, "HGLog")
    t.eq(rows[2].zoneID, ZA)
end)

t.test("protocol chatter carries no anchors", function()
    t.eq(#Remote.DecodeAnchors("HGLOG1", "1|HAVE|0|", "Sender"), 0)
    t.eq(#Remote.DecodeAnchors("HGLOG1", "1|PULL|0|", "Sender"), 0)
    t.eq(#Remote.DecodeAnchors("HGLOG1", "1|FULL|END|", "Sender"), 0, "the end marker")
    t.eq(#Remote.DecodeAnchors("HGLOG1", "2|FULL|1|2413,1000000,1", "Sender"), 0, "another version")
    t.eq(#Remote.DecodeAnchors("RCT", "1|FULL|1|2413,1000000,1", "Sender"), 0, "another addon")
    t.eq(#Remote.DecodeAnchors("HGLOG1", "1|FULL|1|2413,1000000,1", ""), 0, "no sender")
end)

-- The reason anchor is its own stage. A row from a quarter of an hour ago is
-- a timer, not a crate in the air, and a live row built from one would send
-- the raid to a zone where nothing is happening.
t.test("an anchor is held but never shown as something live", function()
    local store = Remote.New()
    local rows = Remote.DecodeAnchors("HGLOG1", "1|FULL|1|2413,1000000,4821", "Sender")
    t.eq(Remote.Note(store, rows[1], T0 + 900), "new", "still inside a cycle")
    t.eq(Remote.Count(store, T0 + 900), 1)
    t.eq(Remote.For(store, HA, T0 + 900), nil, "and not offered as a sighting")
end)

t.test("an anchor older than a cycle describes a drop already gone", function()
    local store = Remote.New()
    local rows = Remote.DecodeAnchors("HGLOG1", "1|FULL|1|2413,1000000,4821", "Sender")
    t.eq(Remote.Note(store, rows[1], T0 + 1500), "stale")
end)

t.test("a promoted anchor is ranked as weakly as it deserves", function()
    local store, db = Remote.New(), Timers.New()
    local rows = Remote.DecodeAnchors("HGLOG1", "1|FULL|1|2413,1000000,4821", "Sender")
    Remote.Note(store, rows[1], T0 + 60)
    t.eq(Remote.Promote(store, db, HA, 4821), "new")
    t.eq(db[HA][4821].ts, T0)
    t.notOk(db[HA][4821].precise, "nobody said how they came by it")
end)

t.test("an anchor does not overwrite a timer this client saw itself", function()
    local store, db = Remote.New(), Timers.New()
    Timers.Record(db, HA, 4821, T0 + 60, "flying")
    local rows = Remote.DecodeAnchors("HGLOG1", "1|FULL|1|2413,1000000,4821", "Sender")
    Remote.Note(store, rows[1], T0 + 60)
    Remote.Promote(store, db, HA, 4821)
    t.eq(db[HA][4821].ts, T0 + 60, "our own flying catch outranks their anchor")
    t.ok(db[HA][4821].precise)
end)

-- Seen live on 20 Sep: a report said a transport was flying in Eversong, the
-- crate landed and was looted, and the window went on saying "inbound" for the
-- rest of the report's five-minute window.
t.test("seeing the crate ourselves retires what we were told about it", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "flying" }), T0)
    t.ok(Remote.For(store, HA, T0 + 60))

    t.ok(Remote.Supersede(store, HA, 4821, "falling"))
    t.eq(Remote.For(store, HA, T0 + 60), nil)
    t.eq(store[HA], nil, "and the zone goes with its last report")
end)

t.test("a looted crate retires everything said about it", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "ground" }), T0)
    t.ok(Remote.Supersede(store, HA, 4821, "claimed"))
    t.eq(Remote.Count(store, T0), 0)
end)

-- A scout watching the parachute knows more than we do watching the transport
-- that dropped it, so our earlier stage must not silence their later one.
t.test("an earlier stage of our own does not retire a later report", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "falling" }), T0)
    t.notOk(Remote.Supersede(store, HA, 4821, "flying"))
    t.ok(Remote.For(store, HA, T0), "their parachute still stands")
end)

t.test("an anchor is retired by any sighting at all", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "anchor" }), T0)
    t.ok(Remote.Supersede(store, HA, 4821, "flying"))
end)

t.test("superseding something nobody reported is not an error", function()
    t.notOk(Remote.Supersede(Remote.New(), HA, 4821, "ground"))
    t.notOk(Remote.Supersede(nil, HA, 4821, "ground"))
end)

-- Standing somewhere is worth reporting on its own. Which copy of a zone the
-- raid is in cannot be found out about a zone you are not in, and a stored
-- timer is only worth flying to if its shard is the one you will land in.
t.test("a player standing in a zone reports which copy of it they are in", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, report({ stage = "here", shardID = 2514 }), T0), "new")
    local shard, who, age = Remote.ShardFor(store, HA, T0 + 60)
    t.eq(shard, 2514)
    t.eq(who, "Scout")
    t.eq(age, 60)
end)

t.test("standing somewhere is never drawn as a crate being there", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "here" }), T0)
    t.eq(Remote.For(store, HA, T0), nil)
end)

t.test("a crate sighting answers the shard question too", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "flying", shardID = 77 }), T0)
    t.eq(Remote.ShardFor(store, HA, T0), 77, "seeing a crate means being there")
end)

t.test("the freshest report wins when two people are in one zone", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "here", shardID = 1, from = "Early" }), T0)
    Remote.Note(store, report({ stage = "here", shardID = 2, from = "Late", at = T0 + 30 }), T0 + 30)
    t.eq(Remote.ShardFor(store, HA, T0 + 30), 2)
end)

t.test("a report from a player who has long since moved on is not used", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "here" }), T0)
    t.eq(Remote.ShardFor(store, HA, T0 + 1000), nil)
end)

-- RCT's own prefix. Their payload is AceSerializer over LibDeflate over
-- EncodeForPrint, read off their Sync/wire.lua. The unpacking is injected here
-- so the parsing is tested without either library being present.
local function inflated(tbl)
    return function() return tbl end
end

t.test("an RCT crate spot becomes a report", function()
    local r = Remote.DecodeRCT("SPOT~abc123~sig", "Relay", inflated({
        type = "SPOT", captureState = "Flying", ts = T0,
        zoneID = 2413, shardhist = "4821", spotter = "Someone",
    }))
    t.eq(r.stage, "flying")
    t.eq(r.zoneID, HA)
    t.eq(r.shardID, 4821, "their shard arrives as text and ours is a number")
    t.eq(r.at, T0)
    t.eq(r.from, "Someone", "the spotter, not whoever relayed it")
    t.eq(r.via, "RCT")
end)

t.test("their capture states map onto ours", function()
    local function stageOf(state)
        return Remote.DecodeRCT("SPOT~x~s", "Relay", inflated({
            captureState = state, ts = T0, zoneID = 2413, shardhist = "1" })).stage
    end
    t.eq(stageOf("Falling To Ground"), "falling")
    t.eq(stageOf("On Ground"), "ground")
    t.eq(stageOf("Claimed"), "claimed")
    t.eq(stageOf("Monster Say"), "flying", "their announcer catch is a crate in the air")
    t.eq(stageOf("Unknown"), "anchor", "a timer of unstated quality, and ranked as one")
end)

t.test("a spot with no spotter is credited to whoever sent it", function()
    local r = Remote.DecodeRCT("SPOT~x~s", "Relay", inflated({
        captureState = "Flying", ts = T0, zoneID = 2413, shardhist = "7" }))
    t.eq(r.from, "Relay")
end)

t.test("their handshakes and control messages are not crates", function()
    local _, why = Remote.DecodeRCT("TOKEN~deadbeef", "Relay", inflated({}))
    t.eq(why, "handshake")
    -- Nine bytes, no payload, and it arrived seventeen times in ten seconds.
    local _, why2 = Remote.DecodeRCT("TOKEN_REQ", "Relay", inflated({}))
    t.eq(why2, "handshake", "control traffic, even with nothing after the tag")
    local _, why3 = Remote.DecodeRCT("TOKEN_ACK~beef", "Relay", inflated({}))
    t.eq(why3, "handshake")
end)

-- AceComm's framing. RCT's bulk sync arrives in three or four pieces, so
-- refusing split messages threw away most of what there was to read.
t.test("an unsplit message passes straight through", function()
    local st = {}
    t.eq(Remote.Reassemble(st, "SPOT~x~s", "Relay", T0), "SPOT~x~s")
    t.eq(next(st), nil, "and nothing is held on to")
end)

t.test("an escaped message loses only its escape byte", function()
    t.eq(Remote.Reassemble({}, "odd", "Relay", T0), "odd")
end)

t.test("a split message is put back together in order", function()
    local st = {}
    t.eq(Remote.Reassemble(st, "one-", "Relay", T0), nil)
    t.eq(Remote.Reassemble(st, "two-", "Relay", T0), nil)
    t.eq(Remote.Reassemble(st, "three", "Relay", T0), "one-two-three")
    t.eq(next(st), nil, "and the run is let go once it completes")
end)

t.test("two senders splitting at once do not braid together", function()
    local st = {}
    Remote.Reassemble(st, "A1", "Alice", T0)
    Remote.Reassemble(st, "B1", "Bob", T0)
    Remote.Reassemble(st, "B2", "Bob", T0)
    t.eq(Remote.Reassemble(st, "A2", "Alice", T0), "A1A2")
end)

t.test("joining in the middle of somebody's sync is not an error", function()
    local _, why = Remote.Reassemble({}, "orphan", "Relay", T0)
    t.eq(why, "orphan")
end)

t.test("a run that stalls is abandoned rather than kept forever", function()
    local st = {}
    Remote.Reassemble(st, "start", "Relay", T0)
    local _, why = Remote.Reassemble(st, "end", "Relay", T0 + 120)
    t.eq(why, "orphan", "the beginning was too long ago to belong to this")
end)

t.test("an endless run is dropped instead of growing without bound", function()
    local st = {}
    Remote.Reassemble(st, "x", "Relay", T0)
    -- The first answer that is not "keep going" is the one that matters;
    -- pieces after the run is dropped are orphans, which is correct and not
    -- what this is about.
    local why
    for _ = 1, 20 do
        local _unused, reason = Remote.Reassemble(st, "x", "Relay", T0)
        if reason ~= "partial" then why = why or reason end
    end
    t.eq(why, "too long")
    t.eq(next(st), nil)
end)

t.test("with no library to unpack it, the message is refused and says why", function()
    local _, why = Remote.DecodeRCT("SPOT~x~s", "Relay", function() return nil end)
    t.eq(why, "no-library")
end)

t.test("a decoded RCT spot goes through the same gate as any other", function()
    local store = Remote.New()
    local r = Remote.DecodeRCT("SPOT~x~s", "Relay", inflated({
        captureState = "Flying", ts = T0, zoneID = 2413, shardhist = "4821" }))
    t.eq(Remote.Note(store, r, T0), "new")
    t.eq(Remote.Note(store, r, T0 + 9999), "stale")
end)


-- The line RCT posts every cycle, for every zone the raid is watching, taken
-- verbatim from Dmitrii's raid on 26 Sep. Only the "Flying in X" alert was
-- being read, so an hour of these kept none of his rows alive.
local INTERVAL_OF = function() return 1100 end

t.test("their countdown is a timer, and it is read", function()
    local r = Remote.FromCountdown(
        "Next Crate: Zul'Aman - 1258 in 02:46", "Loolara", BY_NAME, T0, INTERVAL_OF)
    t.eq(r.zoneID, ZA)
    t.eq(r.shardID, 1258)
    t.eq(r.stage, "anchor", "their arithmetic, not a crate anybody has seen")
    t.eq(r.via, "RCT")
    t.eq(r.from, "Loolara")
    -- 2:46 is 166 seconds off, so the spawn that puts the cycle in that phase
    -- was one interval before the drop being announced.
    t.eq(r.at, T0 + 166 - 1100)
end)

t.test("their last-call form counts too", function()
    local r = Remote.FromCountdown(
        "Next Crate: Harandar - 45 in - 20 s", "Loolara", BY_NAME, T0, INTERVAL_OF)
    t.eq(r.zoneID, HA)
    t.eq(r.shardID, 45)
    t.eq(r.at, T0 + 20 - 1100)
end)

t.test("a countdown for a zone this client cannot name hands back both", function()
    local r, name, shard = Remote.FromCountdown(
        "Next Crate: Leerensturm - 63 in 01:50", "Loolara", BY_NAME, T0, INTERVAL_OF)
    t.eq(r, nil)
    t.eq(name, "Leerensturm")
    t.eq(shard, 63, "so it can be filed against the shard it arrived with")
end)

t.test("ordinary raid chat is not a countdown", function()
    for _, line in ipairs({
        "we kill em. we strong",
        "Hated Gaming - War Crate Alert! Flying in Zul'Aman - Shard: 1258",
        "Next Crate: Zul'Aman - 1258",
        "Next Crate: Zul'Aman in 02:46",
    }) do
        t.eq(Remote.FromCountdown(line, "Someone", BY_NAME, T0, INTERVAL_OF), nil, line)
    end
    t.eq(Remote.FromCountdown(nil, "Someone", BY_NAME, T0, INTERVAL_OF), nil)
    t.eq(Remote.FromCountdown("Next Crate: Zul'Aman - 1258 in 02:46", "", BY_NAME, T0, INTERVAL_OF), nil)
end)

-- Their countdown has been seen reading a couple of minutes out. Past a whole
-- cycle it is not counting down to the next drop, and an anchor built from it
-- would put the phase somewhere it has never been.
t.test("a countdown longer than the cycle is refused", function()
    t.eq(Remote.FromCountdown(
        "Next Crate: Zul'Aman - 1258 in 25:00", "Loolara", BY_NAME, T0, INTERVAL_OF), nil)
    t.ok(Remote.FromCountdown(
        "Next Crate: Zul'Aman - 1258 in 18:00", "Loolara", BY_NAME, T0, INTERVAL_OF),
        "and one inside it is kept")
end)


-- A crate somebody watched land is the strongest anchor there is: the drop
-- time is known, which pins that shard's cycle for hours. It was being dropped
-- ninety seconds later, so a zone the raid had just farmed went blank -- while
-- the leader's own arithmetic, arriving as a countdown, was kept for twenty
-- minutes. Dmitrii watched Zul'Aman vanish after the raid looted it.
t.test("a landed sighting settles into an anchor instead of evaporating", function()
    local store = Remote.New()
    t.eq(Remote.Note(store, { stage = "ground", zoneID = ZA, shardID = 1258,
                              at = T0, from = "Loolara", via = "RCT" }, T0), "new")

    -- Inside its live window it is still a crate on the ground.
    t.eq(Remote.Settle(store, T0 + 30), 0)
    t.ok(Remote.For(store, ZA, T0 + 30), "a live row, because one is lying there")

    -- Past it, the sighting no longer supports "go now" and still supports
    -- where the cycle sits.
    t.eq(Remote.Settle(store, T0 + 200), 1)
    t.eq(Remote.For(store, ZA, T0 + 200), nil, "no live row: it has been looted")
    local anchor = Remote.AnchorFor(store, ZA, 1258, T0 + 200)
    t.ok(anchor, "but the cycle is still known")
    t.eq(anchor.at, T0, "and at the moment it actually landed")
    t.eq(anchor.from, "Loolara")
end)

t.test("a claimed crate settles the same way", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "claimed", zoneID = ZA, shardID = 1258,
                         at = T0, from = "Loolara", via = "RCT" }, T0)
    t.eq(Remote.Settle(store, T0 + 200), 1)
    t.ok(Remote.AnchorFor(store, ZA, 1258, T0 + 200))
end)

t.test("the copy of the zone you are in wins over another", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "anchor", zoneID = ZA, shardID = 41,
                         at = T0, from = "Someone", via = "HGLog" }, T0)
    Remote.Note(store, { stage = "anchor", zoneID = ZA, shardID = 1258,
                         at = T0 - 300, from = "Loolara", via = "RCT" }, T0)

    local _, shard = Remote.AnchorFor(store, ZA, 1258, T0)
    t.eq(shard, 1258, "even though the other is fresher")
    local _, any = Remote.AnchorFor(store, ZA, nil, T0)
    t.eq(any, 41, "and with no shard to prefer, the freshest")
end)

t.test("an anchor past its life is not offered", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "anchor", zoneID = ZA, shardID = 41,
                         at = T0, from = "Someone", via = "HGLog" }, T0)
    t.ok(Remote.AnchorFor(store, ZA, 41, T0 + 1100))
    t.eq(Remote.AnchorFor(store, ZA, 41, T0 + 1300), nil)
end)

-- CrateTrackerZK, two protocols, both pipe-separated. The shapes are read out
-- of their own source rather than guessed: two players in Dmitrii's group were
-- broadcasting 85 to 107 bytes an evening that this addon heard and could not
-- read a word of.
local CTKZK_GUID = "GameObject-0-3299-2405-63-527903-00004F1A22"

t.test("CrateTrackerZK's phase sync becomes an anchor", function()
    local r = Remote.Decode("CTKZK_PSYNC",
        "PHASE_AIRDROP|5|midnight|2405|63|" .. T0 .. "|" .. CTKZK_GUID .. "|npc_shout",
        "Reudi-Zuljin")
    t.ok(r, "their shout time is the spawn, the same anchor a yell gives us")
    t.eq(r.stage, "anchor")
    t.eq(r.zoneID, VS)
    t.eq(r.shardID, 63)
    t.eq(r.at, T0)
    t.eq(r.via, "CTKZK")
    t.eq(r.from, "Reudi-Zuljin")
end)

-- Their older protocol has no phase field, so the shard has to come out of the
-- object's GUID -- the same position this addon already reads one from.
t.test("their older sync has no phase field, so the GUID supplies the shard", function()
    local r = Remote.Decode("CTKZK_SYNC",
        "AIRDROP|3|2405|" .. T0 .. "|" .. CTKZK_GUID .. "|npc_shout", "Azuilan-Silvermoon")
    t.ok(r, "an anchor with no phase field is still an anchor")
    t.eq(r.zoneID, VS)
    t.eq(r.shardID, 63, "read out of the GUID")
    t.eq(r.at, T0)
end)

-- icon_detection stamps when somebody's client first drew an icon, which is
-- whatever stage the cycle had reached when they arrived. Taking it as a spawn
-- would move the row by minutes.
t.test("only their shout time is trusted, never their icon sighting", function()
    t.eq(Remote.Decode("CTKZK_PSYNC",
        "PHASE_AIRDROP|5|midnight|2405|63|" .. T0 .. "|" .. CTKZK_GUID .. "|icon_detection",
        "Reudi-Zuljin"), nil)
    t.eq(Remote.Decode("CTKZK_SYNC",
        "AIRDROP|3|2405|" .. T0 .. "|" .. CTKZK_GUID .. "|icon_detection",
        "Reudi-Zuljin"), nil)
end)

t.test("their other message types and versions are passed over", function()
    -- A protocol bump has to stop us reading a shape we no longer know.
    t.eq(Remote.Decode("CTKZK_PSYNC",
        "PHASE_AIRDROP|6|midnight|2405|63|" .. T0 .. "|" .. CTKZK_GUID .. "|npc_shout",
        "Reudi-Zuljin"), nil)
    t.eq(Remote.Decode("CTKZK_SYNC",
        "AIRDROP|4|2405|" .. T0 .. "|" .. CTKZK_GUID .. "|npc_shout", "Reudi-Zuljin"), nil)
    -- Their request and claim traffic says nothing about a crate.
    t.eq(Remote.Decode("CTKZK_PSYNC", "SYNC_REQUEST|5|abc|" .. T0, "Reudi-Zuljin"), nil)
    t.eq(Remote.Decode("CTKZK_SYNC",
        "PHASE_CLAIM|2|midnight|2405|63|" .. T0, "Reudi-Zuljin"), nil)
end)

-- Decode reads the wire and Note decides what is worth keeping, so a zone
-- this addon does not track is refused one step later rather than here.
t.test("a zone this addon does not track is refused by Note", function()
    local r = Remote.Decode("CTKZK_PSYNC",
        "PHASE_AIRDROP|5|midnight|84|1|" .. T0 .. "|" .. CTKZK_GUID .. "|npc_shout",
        "Reudi-Zuljin")
    t.ok(r, "the payload is readable")
    t.eq(r.zoneID, 84)
    t.eq(Remote.Note(Remote.New(), r, T0), "invalid", "Stormwind is not a crate zone")
end)

-- RCT's two lines with a map pin in them, which it posts to the raid while the
-- transport is still flying and again when the crate is out of it:
--
--   Hated Gaming War Supply Crate - Predicted Drop Location: Zul'Aman <pin>
--   Hated Gaming War Supply Crate Dropped - Location: Zul'Aman <pin>
--
-- The pin is the valuable part. It carries the map id and the position, so
-- unlike their "Flying in <zone>" alert neither depends on the sender's
-- language, and the position is the one thing none of their other lines has.
--
-- Neither line carries a shard, which is why Remote.SHARD_UNKNOWN exists.
local function pin(mapID, x, y)
    return ("|cffffff00|Hworldmap:%d:%d:%d|h[Map Pin Location]|h|r"):format(mapID, x, y)
end

local PREDICTED = "Hated Gaming War Supply Crate - Predicted Drop Location: Zul'Aman "
local DROPPED = "Hated Gaming War Supply Crate Dropped - Location: Zul'Aman "

t.test("a predicted drop location is read off the pin, not off the zone name", function()
    local r = Remote.FromPin(PREDICTED .. pin(ZA, 4690, 6220), "Rdy", T0)
    t.eq(r.stage, "flying")
    t.eq(r.zoneID, ZA)
    t.eq(r.via, "RCT")
    t.eq(r.from, "Rdy")
    t.eq(r.shardID, Remote.SHARD_UNKNOWN, "they do not send one")
    -- The link carries ten-thousandths; everything here speaks fractions.
    t.eq(r.x, 0.4690)
    t.eq(r.y, 0.6220)
end)

-- Their "Dropped" line fires on the parachute and on the landing alike -- both
-- are in the same instantMarkIDs table -- and the text is identical, so this
-- cannot tell them apart. Called falling, which is the earlier of the two: a
-- row saying "falling" about a crate already down costs a player nothing, and
-- "on the ground" about one still in the air sends them early.
t.test("a dropped crate is read as falling, the earlier of the two it could be", function()
    local r = Remote.FromPin(DROPPED .. pin(ZA, 3675, 6790), "Rdy", T0)
    t.eq(r.stage, "falling")
    t.eq(r.x, 0.3675)
end)

t.test("the pin resolves a map id this addon knows by another name", function()
    local r = Remote.FromPin(PREDICTED .. pin(2536, 5000, 5000), "Rdy", T0)
    t.eq(r.zoneID, ZA, "2536 is Atal'Aman, which is Zul'Aman")
end)

t.test("a pin on a map with no crates is not a crate report", function()
    t.eq(Remote.FromPin(PREDICTED .. pin(84, 5000, 5000), "Rdy", T0), nil)
end)

-- Their AppendWaypointLink adds nothing when the client has no waypoint set,
-- and the bare line then says only that something is happening in a zone it
-- names in the sender's language. Their own alert already says that better.
t.test("the same line without a pin carries nothing worth holding", function()
    t.eq(Remote.FromPin("Hated Gaming War Supply Crate - Predicted Drop Location: Zul'Aman",
        "Rdy", T0), nil)
end)

t.test("a map pin somebody posted for their own reasons is not a crate", function()
    t.eq(Remote.FromPin("meet me here " .. pin(ZA, 4690, 6220), "Rdy", T0), nil)
    t.eq(Remote.FromPin(pin(ZA, 4690, 6220), "Rdy", T0), nil)
end)

-- Our own announcements carry a pin too, and reading one back as somebody
-- else's sighting would turn this client into its own source.
t.test("our own announcement is not read as theirs", function()
    t.eq(Remote.FromPin("ZA  shard 44 -- crate landing in 1:20 " .. pin(ZA, 4690, 6220),
        "Dmitrii", T0), nil)
    t.eq(Remote.FromPin("War crate incoming: Zul'Aman 46.9, 62.2 " .. pin(ZA, 4690, 6220),
        "Dmitrii", T0), nil)
end)

t.test("a shardless report is held, and answers for the zone", function()
    local store = Remote.New()
    local r = Remote.FromPin(PREDICTED .. pin(ZA, 4690, 6220), "Rdy", T0)
    t.eq(Remote.Note(store, r, T0), "new")
    local entry = Remote.For(store, ZA, T0)
    t.eq(entry.stage, "flying")
    t.eq(entry.x, 0.4690)
    t.eq(entry.from, "Rdy")
end)

-- The regression this guard exists for. These lines come from the group
-- leader, and ShardFor prefers a leader's word over anybody else's, so an
-- entry filed with no shard would have been handed back as the shard the raid
-- is in -- a question it says nothing about.
t.test("a shardless report never answers which shard the zone is in", function()
    local store = Remote.New()
    local r = Remote.FromPin(PREDICTED .. pin(ZA, 4690, 6220), "Rdy", T0)
    r.leader = true
    Remote.Note(store, r, T0)
    t.eq(Remote.ShardFor(store, ZA, T0), nil, "nobody said which copy of the zone this is")

    -- And a real shard still answers, with the unreadable one alongside it.
    Remote.Note(store, { zoneID = ZA, shardID = 44, stage = "here", at = T0, from = "Scout" }, T0)
    t.eq(Remote.ShardFor(store, ZA, T0), 44)
end)

-- Asking the group who is running this addon. RCT has the same tool and it is
-- the one thing a leader cannot work out by watching: the addon is silent
-- until somebody sees a crate, so "nobody is reporting" and "nobody has it"
-- look identical until you ask.
--
-- A kind of message no older client reads as a sighting: its first field is a
-- letter where the sighting format has the wire version, so 0.2.0 clients
-- decode nothing and log a line they cannot read, which is exactly right.
t.test("a version query is not a sighting", function()
    local q = Remote.EncodeCheck()
    t.eq(Remote.Decode("EWC1", q, "Rdy"), nil, "not a crate")
    t.eq(Remote.DecodeCheck(q), "query")
end)

t.test("a reply carries the version and whether they are sharing", function()
    local r = Remote.EncodeCheck("0.2.0", true)
    local kind, version, sharing = Remote.DecodeCheck(r)
    t.eq(kind, "reply")
    t.eq(version, "0.2.0")
    t.eq(sharing, true)
    t.eq(Remote.Decode("EWC1", r, "Rdy"), nil, "still not a crate")
end)

t.test("sharing switched off comes across as off, not as missing", function()
    local kind, version, sharing = Remote.DecodeCheck(Remote.EncodeCheck("0.2.0", false))
    t.eq(kind, "reply")
    t.eq(version, "0.2.0")
    t.eq(sharing, false)
end)

-- The version is somebody else's string and it gets printed in this client's
-- chat frame. Anything that can colour text, open a link or run to a hundred
-- characters does not belong in a line this addon prints with its own name on
-- it.
t.test("a version is scrubbed before it can be printed", function()
    local _, version = Remote.DecodeCheck("V~!~|cffff0000|Hitem:1234|hclick me|h|r~1")
    t.notOk(tostring(version):find("|"), "no escapes: " .. tostring(version))
    local _, long = Remote.DecodeCheck("V~!~" .. string.rep("9", 80) .. "~1")
    t.ok(#long <= 16, "no essays: " .. tostring(#long))
end)

t.test("a reply with no version at all is still a yes", function()
    local kind, version = Remote.DecodeCheck("V~!")
    t.eq(kind, "reply")
    t.eq(version, "?", "they have it; which build is a separate question")
end)

t.test("anything else is not a check", function()
    t.eq(Remote.DecodeCheck("1~falling~2437~44~1000"), nil)
    t.eq(Remote.DecodeCheck("TOKEN~abc"), nil)
    t.eq(Remote.DecodeCheck(""), nil)
    t.eq(Remote.DecodeCheck(nil), nil)
end)

-- Who did not answer is the half of the answer the roster has to supply, and
-- the two halves meet here rather than in the command, so this is testable.
--
-- Ordered by what the asker has to do about it: the ones who may not have the
-- addon at all, then the ones on an older build, then the ones needing
-- nothing. The reader's own row leads, because a list of twenty names with
-- yours buried in it reads as a list about other people.
t.test("the roll call names who answered and who did not", function()
    local said = { ["Rdy-Whisperwind"] = { version = "0.2.0", sharing = true },
                   ["Scout"] = { version = "0.1.0", sharing = false } }
    local roll = Remote.RollCall({ "Dmitrii", "Rdy-Whisperwind", "Scout", "Silent" },
        said, "0.2.0", "Dmitrii")
    t.eq(#roll, 4)
    t.eq(roll[1].name, "Dmitrii")
    t.eq(roll[1].state, "you")
    t.eq(roll[2].state, "silent", "Silent, who may not have it at all")
    t.eq(roll[3].state, "behind", "Scout, on 0.1.0 against 0.2.0")
    t.eq(roll[3].sharing, false, "and not sharing either")
    t.eq(roll[4].state, "ok", "Rdy, who needs nothing")
end)

t.test("a member on a newer build than yours is not behind", function()
    local roll = Remote.RollCall({ "Ahead" },
        { ["Ahead"] = { version = "0.3.0", sharing = true } }, "0.2.0", "Me")
    t.eq(roll[1].state, "ok")
end)

-- Names arrive with a realm attached from some places and without it from
-- others, and the two must not come out as two people.
t.test("a reply from a realm-qualified name matches the bare roster name", function()
    local roll = Remote.RollCall({ "Scout" },
        { ["Scout-Blackhand"] = { version = "0.2.0", sharing = true } }, "0.2.0", "Me")
    t.eq(roll[1].state, "ok")
end)

-- One crate, three of their lines.
--
-- instantMarkIDs holds the parachute (2967), the crate on the ground (6066)
-- and the claimed crate (6067/6068), and every one of them announces in the
-- same words -- announcedVignettes is keyed by vignette guid, and those are
-- three different vignettes. So a crate that is spotted, lands and is looted
-- sends the identical "Dropped - Location" line three times.
--
-- Read as three sightings, the last one starts a fresh descent countdown for a
-- crate that is already in somebody's bags. Dmitrii's, 18 Oct: a Slayer's Rise
-- row still counted down to a landing after the raid had looted the crate and
-- flown to Eversong.
t.test("one crate announced three times is one crate", function()
    local store = Remote.New()
    local seen = Remote.FromPin(DROPPED .. pin(ZA, 3675, 6790), "Rdy", T0)
    t.eq(Remote.Note(store, seen, T0), "new")
    -- It lands: their 6066, same words.
    t.eq(Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 3675, 6790), "Rdy", T0 + 55),
        T0 + 55), "repeat")
    -- Somebody loots it: 6067, same words again.
    t.eq(Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 3676, 6791), "Rdy", T0 + 70),
        T0 + 70), "repeat")
    t.eq(Remote.For(store, ZA, T0 + 70).at, T0,
        "the fall is still dated to the only moment anybody saw it begin")
end)

-- The suppression may not outlive one crate: the next cycle is 18 minutes
-- later and it is a different crate falling.
t.test("the next cycle is a new crate and not a repeat", function()
    local store = Remote.New()
    Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 3675, 6790), "Rdy", T0), T0)
    t.eq(Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 4690, 6220), "Rdy", T0 + 1090),
        T0 + 1090), "refresh")
end)

-- Their prediction and their drop are different news, two or three minutes
-- apart, and the second is the one that says a crate is in the air now.
t.test("a fall is not suppressed by the prediction that came before it", function()
    local store = Remote.New()
    Remote.Note(store, Remote.FromPin(PREDICTED .. pin(ZA, 4690, 6220), "Rdy", T0), T0)
    t.eq(Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 4690, 6220), "Rdy", T0 + 90),
        T0 + 90), "refresh")
    t.eq(Remote.For(store, ZA, T0 + 90).stage, "falling")
end)

-- A scout running this addon sends the same stage again as the parachute comes
-- down, and that is a real second sighting: they can still see it, and their
-- figure for how long is left is newer than the last one.
t.test("a sighting from this addon still refreshes", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "falling", zoneID = ZA, shardID = 44, at = T0,
        from = "Scout", x = 0.46, y = 0.62, toGround = 60 }, T0)
    t.eq(Remote.Note(store, { stage = "falling", zoneID = ZA, shardID = 44, at = T0 + 30,
        from = "Scout", x = 0.46, y = 0.62, toGround = 30 }, T0 + 30), "refresh")
end)

-- Dmitrii's, 18 Oct: he watched the crate in Zul'Aman land, looted it, flew to
-- Eversong, and the Zul'Aman row was still counting down to a landing.
--
-- RCT announces the claimed crate in the same words as the parachute, so that
-- line arrived after the loot -- and with the store emptied by a reload there
-- was no earlier line of theirs for the repeat rule to recognise it against.
-- Personal observation has no such dependency: having watched a crate land and
-- picked it up cannot be overruled by anybody's account of it.
--
-- ADVANCE is the order a crate's life runs in, and Remote.Supersede already
-- drops a held report that this client's own eyes have overtaken. This is the
-- other half, for a report that has not been stored yet.
t.test("a crate this client watched being taken is not falling", function()
    local live = { phase = "ground", mine = true, claimedAt = T0, shard = 44, x = 0.46, y = 0.62 }
    t.ok(Remote.Behind(live, { stage = "falling", shardID = Remote.SHARD_UNKNOWN }),
        "their line about the crate we just looted is not news")
    t.ok(Remote.Behind(live, { stage = "flying", shardID = Remote.SHARD_UNKNOWN }),
        "nor is a transport in a zone where the crate is already on the ground")
end)

t.test("a report further along than our own sighting is news", function()
    local live = { phase = "falling", shard = 44 }
    t.eq(Remote.Behind(live, { stage = "ground", shardID = 44 }), false,
        "we see a parachute, they see it down -- theirs is the newer fact")
    t.eq(Remote.Behind(live, { stage = "falling", shardID = 44 }), false,
        "and the same stage still refreshes")
end)

t.test("another copy of the zone is not the crate we took", function()
    t.eq(Remote.Behind({ phase = "ground", shard = 44 }, { stage = "falling", shardID = 77 }),
        false, "77 is a zone we have not stood in")
end)

-- An anchor says a crate existed and dates the cycle. It is the one thing
-- worth having from a zone whose crate has just been taken, so the rule has to
-- leave it alone -- which RANK already decides, because an anchor draws no row.
t.test("an anchor is about the cycle, not about this crate", function()
    local live = { phase = "ground", shard = 44 }
    t.eq(Remote.Behind(live, { stage = "anchor", shardID = 44 }), false)
    t.eq(Remote.Behind(live, { stage = "here", shardID = 44 }), false)
end)

t.test("nothing seen here means there is nothing to outrank", function()
    t.eq(Remote.Behind(nil, { stage = "falling", shardID = 44 }), false)
    t.eq(Remote.Behind({ phase = "inbound", shard = 44 }, { stage = "falling", shardID = 44 }),
        false, "inbound is the window's word for a transport, not a stage of a crate")
end)

-- Seeing the crate for yourself is supposed to end everybody's account of it,
-- and for a report that named no shard it did not.
--
-- Dmitrii's Zul'Aman crate, 18 Oct: their map-pin line arrived at 20:27:19,
-- 54 seconds into an 87-second fall, because their parachute vignette is drawn
-- by proximity and they were far away. We dated the fall from the moment we
-- heard it, so the row counted down to 20:28:44. Our own eyes had the crate on
-- the ground at 20:27:52 and claimed at 20:28:02, and Supersede could not
-- reach their entry: it looks one up by shard number, and theirs is filed under
-- SHARD_UNKNOWN because their two lines carry no shard.
t.test("seeing the crate supersedes a report that named no shard", function()
    local store = Remote.New()
    Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 4020, 7830), "Rdy", T0), T0)
    t.ok(Remote.For(store, ZA, T0 + 10), "held while nobody has seen it land")
    t.ok(Remote.Supersede(store, ZA, 26055, "ground"),
        "and this client is standing in a numbered copy of that zone")
    t.eq(Remote.For(store, ZA, T0 + 10), nil, "their account of the fall is over")
end)

t.test("superseding leaves another copy of the zone alone", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "falling", zoneID = ZA, shardID = 77, at = T0,
        from = "Scout" }, T0)
    t.eq(Remote.Supersede(store, ZA, 26055, "ground"), false)
    t.ok(Remote.For(store, ZA, T0 + 10), "77 is not the copy we are standing in")
end)

-- Both at once, because a zone can hold one of each and the crate on the
-- ground in front of the player is the same crate as the shardless report.
t.test("the numbered copy and the shardless one go together", function()
    local store = Remote.New()
    Remote.Note(store, Remote.FromPin(DROPPED .. pin(ZA, 4020, 7830), "Rdy", T0), T0)
    Remote.Note(store, { stage = "falling", zoneID = ZA, shardID = 26055, at = T0,
        from = "Scout" }, T0)
    t.ok(Remote.Supersede(store, ZA, 26055, "ground"))
    t.eq(Remote.For(store, ZA, T0 + 10), nil)
end)

-- A report further along than what this client has seen outlives the sighting:
-- we have found the crate falling, they say it is already down.
t.test("a shardless report ahead of our own sighting survives", function()
    local store = Remote.New()
    Remote.Note(store, { stage = "ground", zoneID = ZA, shardID = Remote.SHARD_UNKNOWN,
        at = T0, from = "Rdy", via = "RCT" }, T0)
    t.eq(Remote.Supersede(store, ZA, 26055, "falling"), false)
    t.ok(Remote.For(store, ZA, T0 + 10), "theirs is the newer stage, not the stale one")
end)
