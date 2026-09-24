local ns, t = ...
local Remote, Timers = ns.Remote, ns.Timers

local ZA, HA = 2437, 2413
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

t.test("reports age out of the list without being cleared by hand", function()
    local store = Remote.New()
    Remote.Note(store, report({ stage = "ground" }), T0)
    t.ok(Remote.For(store, HA, T0 + 100))
    t.eq(Remote.For(store, HA, T0 + 500), nil, "nobody left it on the ground that long")
    t.eq(Remote.Count(store, T0 + 500), 0)
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
