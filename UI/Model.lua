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
            return { phase = "ground", since = live.groundAt, rank = 1 }
        end
        local eta = ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, nil, nil, live.since, now)
        return { phase = "falling", toGround = eta and eta.toGround or nil,
                 since = live.since, rank = 2 }
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
        return { phase = "inbound", toGround = eta and eta.toGround or nil, rank = 3 }
    end

    -- Nothing visible from here, but somebody else may be standing in it. A
    -- report ranks exactly as the same sighting of our own would, so a
    -- parachute a scout can see outranks a transport this client can.
    local report = ns.Remote and ns.Remote.For(ns.remote, zoneID, now)
    if report then
        local phase = report.stage == "flying" and "inbound" or report.stage
        local eta = report.stage == "falling"
            and ns.Airtime.ETA(ns.db and ns.db.descent, zoneID, nil, nil, report.at, now)
        return {
            phase = phase, rank = ns.Remote.RANK[report.stage] or 99,
            since = report.at, toGround = eta and eta.toGround or nil,
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
        rows[#rows + 1] = {
            -- The shard is known and nothing has been timed in it. Blank on
            -- purpose: another copy's countdown here would look like
            -- knowledge and send a raid somewhere on the strength of it.
            newShard   = (known and not entry) or nil,
            -- The shard is not known, so this timer may be for another copy.
            guessedShard = (not known and entry ~= nil) or nil,
            shardFrom  = shardFrom,
            live      = live,
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
