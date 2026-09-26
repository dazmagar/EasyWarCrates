local ADDON, ns = ...

-- What the window should show, as plain data.
--
-- Pure, so tests/ covers it. The frame code that draws these rows cannot be
-- tested at all, so as little as possible is decided there: it receives a list
-- and paints it.

local Model = {}
ns.Model = Model

-- A row whose timer has missed this many cycles is drawn dimmed. It is still
-- shown -- the zone and shard are worth knowing -- but the countdown is
-- extrapolation from an observation nobody has confirmed in over an hour, and
-- it should not sit there looking like the live ones. RCT shows a stale timer
-- exactly like a fresh one, which is how its Eversong countdown keeps promising
-- drops that do not come.
local STALE_CYCLES = 2
Model.STALE_CYCLES = STALE_CYCLES

-- The crate currently in the air or on the ground in a zone, as the window
-- needs it, or nil. Split out so the row builder stays testable: the scanner
-- this reads from cannot run outside the game.
function Model.LiveFor(zoneID, now)
    local S = ns.Scanner
    local live = S and S.LiveCrate and S.LiveCrate(zoneID)
    if live then
        if live.phase == "ground" then
            -- A claimed crate is still lootable and the question is how
            -- long for. Counted down when the readings say so and counted up
            -- when they do not, because an invented countdown is worse than
            -- an honest stopwatch.
            local toGone, held
            if live.mine and live.claimedAt then
                held = now - live.claimedAt
                local lasts = ns.Airtime.Linger(ns.db and ns.db.linger, zoneID)
                if lasts then toGone = math.max(0, lasts - held) end
            end
            return { phase = "ground", since = live.groundAt, rank = 1,
                     mine = live.mine, held = held, toGone = toGone,
                     x = live.x, y = live.y }
        end
        local eta = ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, nil, nil, live.since, now)
        return { phase = "falling", toGround = eta and eta.toGround or nil,
                 since = live.since, rank = 2, x = live.x, y = live.y }
    end
    -- Still in the air. Worth a row of its own: a transport on its way is the
    -- reason to stay put, and until now the only sign of one was a line of
    -- text that says nothing about which zone it is in unless you are stood
    -- in it.
    if S and S.HasTransport and S.HasTransport(zoneID) then
        local r = S.Prediction and S.Prediction(zoneID)
        local eta = r and r.committed
            and ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, r.fit, r.committed, nil, now,
                ns.db and ns.db.release)
        local aim = r and (r.committed or (r.aim and r.aim.spot))
        return { phase = "inbound", toGround = eta and eta.toGround or nil, rank = 3,
                 x = aim and aim.x, y = aim and aim.y }
    end

    -- Nothing visible from here, but somebody else may be standing in it. A
    -- report ranks exactly as the same sighting of our own would, so a
    -- parachute a scout can see outranks a transport this client can.
    local report = ns.Remote and ns.Remote.For(ns.remote, zoneID, now)
    if report and not Model.StillTrue(report, now) then report = nil end
    if report then
        local phase = report.stage == "flying" and "inbound" or report.stage
        local eta = report.stage == "falling"
            and ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, nil, nil, report.at, now)
        return {
            phase = phase, rank = ns.Remote.RANK[report.stage] or 99,
            since = report.at, toGround = eta and eta.toGround or nil,
            x = report.x, y = report.y,
            from = report.from, via = report.via,
        }
    end
    return nil
end

-- Which copy of a zone applies: this client's own reading first, then whoever
-- in the raid is standing there. nil when nobody knows, which is different
-- from knowing and finding nothing.
local function shardHere(zoneID, now)
    local mine = ns.Scanner and ns.Scanner.CurrentShard
        and ns.Scanner.CurrentShard(zoneID, now)
    if mine then return mine, "you" end
    if ns.Remote then return ns.Remote.ShardFor(ns.remote, zoneID, now) end
    return nil
end

-- Spawn to lootable. Both legs are measured now, so this is arithmetic on two
-- observations rather than a guess: the transport's flight from the moment the
-- cycle starts, and the fall under the parachute.
local function groundAt(zoneID, remaining)
    if not remaining then return nil end
    local flight = ns.Airtime.Flight(ns.db and ns.db.flight, zoneID)
    local descent = ns.Airtime.Descent(ns.db and ns.db.descent, zoneID)
    return remaining + flight + descent
end

-- Whether a report still describes what is happening.
--
-- A sighting is about a moment, and moments pass. Nobody retracts one, so an
-- "in the air" from four minutes ago went on saying inbound long after the
-- crate had landed and somebody had taken it -- the row looked like knowledge
-- and was a memory.
--
-- The measured legs say how long each stage can still be true for: a transport
-- is in the air for one flight, a parachute is up for one descent. Past that
-- the report is not evidence of anything happening now, and the row falls back
-- to the timer rather than guessing at what became of it.
function Model.StillTrue(report, now)
    if type(report) ~= "table" or not report.at then return false end
    local elapsed = now - report.at
    if report.stage == "flying" then
        return elapsed <= ns.Airtime.Flight(ns.db and ns.db.flight, report.zoneID)
    end
    if report.stage == "falling" then
        return elapsed <= ns.Airtime.Descent(ns.db and ns.db.descent, report.zoneID)
    end
    return true
end

-- Rows for the window, in the order they should be drawn.
--
-- With a route set, its zones come first, planned -- because "when do I leave"
-- is the question a rotation asks and a bare countdown does not answer. Any
-- other zone with a timer follows, so nothing the addon knows is hidden just
-- because it is off the route.
--
--   abbr, zoneID, shardID
--   remaining   seconds until the transport appears, nil when nothing is known
--   onGround    seconds until the crate can be picked up
--   status      go | wait | missed | unknown   (route rows only)
--   fraction    0..1 through the cycle, for the bar
--   missed      cycles that passed unobserved
--   precise     false when seeded from a crate found already on the ground
--   stale       too many missed cycles to present as live
--   newShard    the copy of the zone is known and nothing is timed in it
--   guessedShard the copy is not known, so this timer may be another one's
--   shardFrom   who said which copy it is: "you", or a raid member's name
--   inRoute     whether this zone is part of the rotation
--   live        a crate down or falling in that zone now: { phase, toGround }
--   next        the one row worth acting on
function Model.BuildRows(db, route, now)
    local rows, seen = {}, {}

    local function add(zoneID, entry, shardID, planned, known, shardFrom)
        local interval = ns.GetZoneInterval(zoneID)
        local remaining = entry and ns.Timers.Remaining(entry, interval, now)
        local missed = entry and ns.Timers.MissedCycles(entry, interval, now) or 0
        -- A crate that is in the air or lying there right now outranks the
        -- countdown to the next one. The timer resets the instant a crate is
        -- released, so without this the row reads "18:10" at the exact moment
        -- there is one on the ground to go and collect.
        local live = ns.Model.LiveFor(zoneID, now)
        -- A timer belongs to a shard, and entering a zone hands you one you
        -- did not choose. Landing on a different copy of the zone than the
        -- timer was learned on is why a raid flies out, waits, and no
        -- transport comes: the crate is there, its cycle is simply in another
        -- phase. Saying so is the difference between twenty wasted minutes and
        -- knowing to move on.
        -- Two different facts and they were sharing one message. A zone with
        -- no timers at all has never been watched; a zone with timers but
        -- none for this copy has been watched somewhere else. Harandar read
        -- "new shard" on a profile that had never timed Harandar at all.
        local timedBefore = next((db or {})[zoneID] or {}) ~= nil
        rows[#rows + 1] = {
            -- The copy is known, the zone has been watched, and this copy has
            -- not. Blank on purpose: another copy's countdown here would look
            -- like knowledge and send a raid out on the strength of it.
            newShard   = (known and not entry and timedBefore) or nil,
            -- The shard is not known, so this timer may be for another copy.
            guessedShard = (not known and entry ~= nil) or nil,
            shardFrom  = shardFrom,
            live      = live,
            -- A second object in the same zone, not a stage of the first. It
            -- rides on the row instead of taking one of its own because a zone
            -- can have both, and two rows for one place is the RCT complaint.
            spectral  = (ns.Scanner and ns.Scanner.Spectral and ns.Scanner.Spectral(zoneID)) or nil,
            zoneID    = zoneID,
            abbr      = ns.GetZoneAbbr(zoneID),
            shardID   = shardID,
            remaining = remaining,
            onGround  = groundAt(zoneID, remaining),
            status    = planned and planned.status or nil,
            fraction  = (remaining and interval > 0) and (1 - remaining / interval) or 0,
            missed    = missed,
            precise   = entry and entry.precise or false,
            stale     = missed > STALE_CYCLES,
            inRoute   = planned ~= nil,
        }
        seen[zoneID] = true
        return rows[#rows]
    end

    local nextRow
    if route and #route > 0 then
        local plan = ns.Route.Plan(db, route, ns.GetZoneInterval,
            function(zoneID) return (shardHere(zoneID, now)) end, now)
        local best = ns.Route.Next(plan)
        for _, planned in ipairs(plan) do
            local _, from = shardHere(planned.zoneID, now)
            local row = add(planned.zoneID, planned.entry, planned.shardID, planned,
                planned.knownShard, from)
            if planned == best then nextRow = row end
        end
    end

    local others = {}
    for zoneID, shards in pairs(db or {}) do
        if not seen[zoneID] then
            local here, from = shardHere(zoneID, now)
            local entry, shardID, known = ns.Route.EntryFor(db, zoneID, here)
            -- A zone with a timer for a copy nobody is in has nothing to say
            -- until somebody goes there, so it does not take a row.
            if entry or known then
                others[#others + 1] = { zoneID = zoneID, entry = entry, shardID = shardID,
                                        known = known, from = from }
            end
        end
    end
    table.sort(others, function(a, b)
        local ra = ns.Timers.Remaining(a.entry, ns.GetZoneInterval(a.zoneID), now) or math.huge
        local rb = ns.Timers.Remaining(b.entry, ns.GetZoneInterval(b.zoneID), now) or math.huge
        if ra == rb then return a.zoneID < b.zoneID end
        return ra < rb
    end)
    for _, o in ipairs(others) do
        add(o.zoneID, o.entry, o.shardID, nil, o.known, o.from)
    end

    -- A zone with something happening but no timer would otherwise have no row
    -- at all, which is the case whenever you fly somewhere new or return on a
    -- shard you have not seen -- exactly when you most want to know whether
    -- there is anything there.
    for zoneID in pairs((ns.Scanner and ns.Scanner.ActiveZones and ns.Scanner.ActiveZones()) or {}) do
        if not seen[zoneID] then add(zoneID, nil, nil, nil) end
    end

    -- Anything live floats to the top, most urgent first: a crate on the
    -- ground can be taken now, one under a parachute shortly, a transport
    -- eventually. Everything else keeps the order it was built in.
    local order = {}
    -- A chest gets its own row as soon as the zone has a crate to report too.
    --
    -- On a quiet zone it rides on the zone's row, which is right: one place,
    -- one line, and the row has nothing else to say. But once a transport is in
    -- the air or a crate is coming down there, one row is being asked to carry
    -- two things that are collected separately and at different times -- and a
    -- click on it can only mean one of them. Split, each row says one thing and
    -- a click on it does what the row says.
    local split = {}
    for _, r in ipairs(rows) do
        split[#split + 1] = r
        if r.spectral and r.live then
            split[#split + 1] = {
                zoneID = r.zoneID,
                abbr = r.abbr,
                shardID = r.shardID,
                spectral = r.spectral,
                spectralOnly = true,
                -- Ranked with a crate already on the ground: both are there to
                -- be collected now, which is the only thing this ordering says.
                live = { phase = "ground", rank = 1, since = r.spectral.since,
                         x = r.spectral.x, y = r.spectral.y, spectral = true },
                fraction = 1,
            }
            r.spectral = nil
        end
    end
    rows = split

    for i, r in ipairs(rows) do order[r] = i end
    table.sort(rows, function(a, b)
        local ra = a.live and a.live.rank or 99
        local rb = b.live and b.live.rank or 99
        if ra ~= rb then return ra < rb end
        return order[a] < order[b]
    end)

    return rows, nextRow
end

-- The line above the rows while a transport is in the air, or nil.
--
--   text     what to show
--   ready    the call is committed and worth acting on
function Model.Headline(zoneID, now)
    if not zoneID then return nil end
    local r = ns.Scanner and ns.Scanner.Prediction and ns.Scanner.Prediction(zoneID)
    if not r then return nil end

    if r.committed then
        local where = ("%.1f, %.1f"):format(r.committed.x * 100, r.committed.y * 100)
        if r.arrived then
            return { text = ("dropped at %s"):format(where), ready = true }
        end
        local eta = ns.Airtime.ETA(ns.db.descent, zoneID, r.fit, r.committed, nil, now, ns.db.release)
        return {
            text = eta and ("incoming to %s, down in %s"):format(where, ns.FormatClock(eta.toGround))
                or ("incoming to %s"):format(where),
            ready = true,
        }
    end

    -- Not committed. The leading candidate is still worth showing, greyed:
    -- a Zul'Aman flight held the correct spot in first place for a full minute
    -- before the margin cleared, and saying nothing for that minute is worse
    -- than saying "probably here, not sure". The waypoint still waits.
    if r.aim then
        local eta = ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, r.fit, r.aim.spot,
            nil, now, ns.db and ns.db.release)
        return {
            text = ("probably %.1f, %.1f (%d%%)%s"):format(
                r.aim.spot.x * 100, r.aim.spot.y * 100,
                math.floor((r.aim.p or 0) * 100 + 0.5),
                eta and (", down in " .. ns.FormatClock(eta.toGround)) or ""),
            ready = false,
        }
    end
    if r.best then
        return { text = ("nothing certain -- %s"):format(tostring(r.reason)), ready = false }
    end
    if r.reason == "gathering" then
        return { text = ("transport spotted, reading its heading (%d)"):format(r.samples or 0),
                 ready = false }
    end
    return { text = "transport in the air, not going anywhere", ready = false }
end

-- One line a raid can act on, for the row somebody clicked.
--
-- Pure, so the wording is pinned by tests rather than discovered in a raid.
-- Core/Comm.lua adds the clickable pin and decides where to send it.
--
-- nil when the row has nothing worth saying: announcing "nothing is known
-- about this zone" to forty people is noise, and the one thing an announcement
-- must never do is waste the channel it is asking for.
function Model.Announcement(row, now)
    if type(row) ~= "table" or not row.zoneID then return nil end
    local where = ns.GetZoneName(row.zoneID)
    local shard = row.shardID and ("  shard %s"):format(tostring(row.shardID)) or ""
    local live = row.live

    local function clock(seconds)
        return (ns.FormatClock(seconds):gsub("^%s+", ""))
    end

    -- Coordinates spelled out, unlike a crate's. A crate line leans on the pin
    -- that travels with it, and the pin can fail to produce a link -- the game
    -- only hands one back when the waypoint readback agrees about the map. A
    -- crate is still findable after that: it has a countdown and a zone. This
    -- has neither. It lasts a minute or two, so a line that says only "in
    -- Slayer's Rise" has told a reader nothing they can act on in time.
    local spectralLine = nil
    if row.spectral then
        local age = (now and row.spectral.since)
            and (" (%s so far)"):format(clock(now - row.spectral.since)) or ""
        local at = (row.spectral.x and row.spectral.y)
            and (" at %.1f, %.1f"):format(row.spectral.x * 100, row.spectral.y * 100) or ""
        spectralLine = ("%s: SPECTRAL CHEST on the ground%s%s%s"):format(
            where, at, age, shard)
    end

    -- Never echo the raid back at itself. A report carried by RCT arrived as a
    -- raid warning, so everyone has already read it; repeating it is spam
    -- dressed as help. Reports that came over an addon channel are invisible
    -- to anyone without that addon, so those are worth saying out loud.
    --
    -- The chest is not that report and is on the ground now, so it survives the
    -- silence the crate gets.
    if live and live.via == "RCT" then
        if spectralLine then return spectralLine, "spectral" end
        return nil
    end

    -- Ranked by what can be taken now, not by which object is worth more.
    --
    -- A crate on the ground outranks the chest: both are there to collect and
    -- the crate is why anyone is in the zone. A transport in the air does not,
    -- and saying it did was wrong -- it means "in three minutes", while the
    -- chest is on the ground and gone in one or two. Dmitrii clicked the
    -- Slayer's Rise row with a chest lying in it and the raid was told about a
    -- transport instead.
    -- A row that is only the chest says so and nothing else. Its live entry is
    -- there to rank and draw it, not to be described as a crate.
    if row.spectralOnly then
        if spectralLine then return spectralLine, "spectral" end
        return nil
    end

    if live and live.phase ~= "ground" and spectralLine then
        return spectralLine, "spectral"
    end

    if live then
        -- No coordinates. The pin that goes with this points at the exact
        -- spot, so a pair of numbers beside it is the same fact twice. Time is
        -- the thing the reader is actually weighing.
        if live.phase == "ground" then
            -- The one state that carried no time at all, and the one where it
            -- decides the answer: a raid will cross a zone for a crate that
            -- landed five seconds ago and not for one that landed two minutes
            -- ago.
            local age = (now and live.since) and (" (%s so far)"):format(clock(now - live.since))
                or ""
            if live.mine then
                local left = live.toGone and (", %s left"):format(clock(live.toGone)) or age
                return ("%s: crate ON THE GROUND, ours%s%s"):format(where, left, shard), "crate"
            end
            return ("%s: crate ON THE GROUND%s%s"):format(where, age, shard), "crate"
        end
        if live.phase == "falling" then
            return ("%s: crate landing in %s%s"):format(where,
                live.toGround and clock(live.toGround) or "moments", shard), "crate"
        end
        return ("%s: transport in the air%s%s"):format(where,
            live.toGround and (", down in " .. clock(live.toGround)) or "", shard), "crate"
    end

    if spectralLine then return spectralLine, "spectral" end

    if row.remaining then
        return ("%s: transport in %s, lootable in %s%s"):format(where,
            clock(row.remaining),
            row.onGround and clock(row.onGround) or "?", shard), "crate"
    end
    return nil
end
