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
    return nil
end

-- Rows for the window, in the order they should be drawn.
--
-- With a route set, its zones come first, planned -- because "when do I leave"
-- is the question a rotation asks and a bare countdown does not answer. Any
-- other zone with a timer follows, so nothing the addon knows is hidden just
-- because it is off the route.
--
--   abbr, zoneID, shardID
--   remaining   seconds until the drop, nil when nothing is known
--   leaveIn     seconds until you must set off; nil off-route
--   status      go | wait | missed | unknown   (route rows only)
--   fraction    0..1 through the cycle, for the bar
--   missed      cycles that passed unobserved
--   precise     false when seeded from a crate found already on the ground
--   stale       too many missed cycles to present as live
--   inRoute     whether this zone is part of the rotation
--   live        a crate down or falling in that zone now: { phase, toGround }
--   next        the one row worth acting on
function Model.BuildRows(db, route, now)
    local rows, seen = {}, {}

    local function add(zoneID, entry, shardID, planned)
        local interval = ns.GetZoneInterval(zoneID)
        local remaining = entry and ns.Timers.Remaining(entry, interval, now)
        local missed = entry and ns.Timers.MissedCycles(entry, interval, now) or 0
        -- A crate that is in the air or lying there right now outranks the
        -- countdown to the next one. The timer resets the instant a crate is
        -- released, so without this the row reads "18:10" at the exact moment
        -- there is one on the ground to go and collect.
        local live = ns.Model.LiveFor(zoneID, now)
        rows[#rows + 1] = {
            live      = live,
            zoneID    = zoneID,
            abbr      = ns.GetZoneAbbr(zoneID),
            shardID   = shardID,
            remaining = remaining,
            leaveIn   = planned and planned.leaveIn or nil,
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
        local plan = ns.Route.Plan(db, route, ns.GetZoneInterval, ns.GetZoneTravel, now)
        local best = ns.Route.Next(plan)
        for _, planned in ipairs(plan) do
            local row = add(planned.zoneID, planned.entry, planned.shardID, planned)
            if planned == best then nextRow = row end
        end
    end

    local others = {}
    for zoneID, shards in pairs(db or {}) do
        if not seen[zoneID] then
            local entry, shardID = ns.Route.FreshestForZone(db, zoneID)
            if entry then others[#others + 1] = { zoneID = zoneID, entry = entry, shardID = shardID } end
        end
    end
    table.sort(others, function(a, b)
        local ra = ns.Timers.Remaining(a.entry, ns.GetZoneInterval(a.zoneID), now) or math.huge
        local rb = ns.Timers.Remaining(b.entry, ns.GetZoneInterval(b.zoneID), now) or math.huge
        if ra == rb then return a.zoneID < b.zoneID end
        return ra < rb
    end)
    for _, o in ipairs(others) do add(o.zoneID, o.entry, o.shardID, nil) end

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
    if r.best then
        return {
            text = ("probably %.1f, %.1f (%s)"):format(
                r.best.spot.x * 100, r.best.spot.y * 100, tostring(r.reason)),
            ready = false,
        }
    end
    return { text = "transport in the air", ready = false }
end
