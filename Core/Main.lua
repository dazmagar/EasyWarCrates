local ADDON, ns = ...

local DEFAULTS = {
    enabled   = true,
    waypoint  = true,   -- drop a map pin on a confident prediction
    verbose   = false,  -- narrate every scan; for diagnosing, not for playing
    -- Was on at 0.1.0 so the first flights could be watched at all. They have
    -- been, and it reports only on change now, but it is still a diagnostic.
    watch     = false,
    crates    = nil,    -- filled with ns.Timers.New()
    learned   = nil,    -- drop spots the shipped catalogue does not have
    gaps      = nil,    -- observed intervals between drops
    route     = nil,    -- the rotation, as zone ids in order
    -- Everything this addon says, kept so it can be read back after the fact.
    -- /chatlog does not capture it: that logs the CHAT_MSG_* stream, and an
    -- addon's output goes straight to the frame through AddMessage without
    -- ever becoming a chat message. WarCratePredict keeps its own log for the
    -- same reason. Written to disk on /reload, like everything else here.
    log       = nil,
    flight    = nil,    -- measured spawn-to-parachute times, per zone
    linger    = nil,    -- how long a claimed crate stayed lootable
    phase     = nil,    -- where each shard's cycle sits, outliving Prune
    descent   = nil,    -- measured parachute times, per zone
    release   = nil,    -- how wrong the release-time estimate runs, per zone
    -- Zone names heard in a chat alert that this client cannot resolve. RCT
    -- broadcasts the sender's own localised name, and the game will only tell
    -- us our locale's, so a German raider's "Leerensturm" is unreadable on an
    -- English client. Kept because they are the only source of the mapping
    -- there is: nothing ships these names and inventing them is worse than
    -- not having them.
    unknownZones = nil,
    -- Tell the group what this client sees. Receiving needs no switch:
    -- hearing costs nothing and never touches the saved timers.
    share       = true,
    -- Off by design. Leading a raid is not consent to have an addon speak
    -- in its chat, and only a leader or assistant can send at all.
    announce    = false,
    minimap     = true,   -- show the minimap button
    windowShown = true,   -- show the tracker window
    -- Deliberately absent: minimapAngle and window. They hold where the player
    -- dragged something, so "unset" is their real state until one is dragged,
    -- and every reader supplies its own fallback. A default of nothing is not
    -- a default and does not belong in this table.
}

ns.DEFAULTS = DEFAULTS

local PREFIX = "|cff33ddaa[EWC]|r "

-- Enough to cover a farming session several cycles long, and small enough
-- that nobody notices it in the saved variables.
local LOG_MAX = 400

local function remember(line)
    local log = ns.db and ns.db.log
    if not log then return end
    log[#log + 1] = { at = GetServerTime(), text = line }
    while #log > LOG_MAX do table.remove(log, 1) end
end

function ns.Print(...)
    local line = string.join(" ", tostringall(...))
    remember(line)
    print(PREFIX .. line)
end

function ns.Debug(...)
    if not (ns.db and ns.db.verbose) then return end
    local line = string.join(" ", tostringall(...))
    remember(line)
    print("|cff777777[EWC]|r " .. line)
end

local function applyDefaults(db)
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil and v ~= nil then db[k] = v end
    end
    -- Listed as nil in DEFAULTS above, which means the key does not exist in
    -- that table at all and the loop never sees it. Seeded explicitly, and
    -- every one of these has to be: a missing store is not an error anywhere
    -- downstream, it is a module that quietly stops working.
    db.crates  = db.crates or ns.Timers.New()
    db.learned = db.learned or {}
    db.gaps    = db.gaps or {}
    db.route   = db.route or {}
    db.descent = db.descent or {}
    db.flight  = db.flight or {}
    db.linger  = db.linger or {}
    db.phase   = db.phase or ns.Phase.New()
    db.release = db.release or {}
    db.unknownZones = db.unknownZones or {}
    db.log     = db.log or {}
    -- Deliberately not on db. db IS the saved table, so a store hung off
    -- it is a store written to disk, and what other players reported must
    -- not survive the session that heard it.
    ns.remote = ns.Remote.New()
    return db
end

-- What each zone was last told to expect, so a landing can be scored against
-- it. Neither RCT nor WarCrateTracker ever checks its own guess; CrateTrackerZK
-- does, and it is the only way to find out whether the model is actually any
-- good rather than merely plausible.
ns.lastPrediction = {}
local PREDICTION_MEMORY = 600  -- a guess older than this is not about this crate

-- Where the pin currently sits per zone, so a crate in view is not re-pinned
-- once a second for the whole of its fall.
local pinnedAt = {}

-- Far enough to be worth moving the pin for. A parachute drifts a little on
-- every sweep, and at the old hundredth of a percent every one of those counted
-- as a new place to point at.
local PIN_MOVED = 0.004

-- One gate for every pin this addon places by itself.
--
-- Only the vignette path had a gate. The two prediction paths pinned on every
-- sweep and announced each time, so a track holding one answer for a minute
-- printed six of those lines for two decisions. Where the pin went is on the
-- line above it either way, so it is said once per zone and then moved quietly.
--
-- `always` is for a landing: the one position nobody had to guess at re-pins
-- however small the drift.
local function pinCrate(zoneID, x, y, always)
    if not ns.db.waypoint then return end
    local prev = pinnedAt[zoneID]
    local moved = not prev
        or math.abs(prev.x - x) > PIN_MOVED or math.abs(prev.y - y) > PIN_MOVED
    if not (moved or always) then return end
    pinnedAt[zoneID] = { x = x, y = y }
    return ns.SetCratePin(zoneID, x, y, prev ~= nil)
end

-- Every sighting of a crate's own vignette. This is the truth the prediction
-- was only guessing at, so it scores the guess, files the landing spot, and
-- reports the timer -- but only the last of those depends on the timer having
-- actually moved. verdict is what Timers made of it.
function ns.OnCrateSighted(zoneID, shardID, stage, pos, verdict, backdated)
    if verdict == "new" or verdict == "refined" then
        ns.Print(string.format("%s |cffffffffshard %s|r -- crate %s at |cffffd100%.1f, %.1f|r%s",
            ns.GetZoneName(zoneID), tostring(shardID), stage, pos.x * 100, pos.y * 100,
            backdated and (" |cff777777(found lying there; timer set back %ds to the spawn)|r")
                :format(math.floor(backdated + 0.5)) or ""))
    else
        ns.Debug(("crate %s in %s shard %s -> %s (timer left alone)"):format(
            stage, ns.GetZoneName(zoneID), tostring(shardID), verdict))
    end

    -- Guarded, and the guard is the point. Everything below this line is the
    -- addon's core work, and a nil call here would stop all of it without
    -- saying so: no pin, no prediction score, no release measurement, no
    -- learned spot. Sharing is the newest and least important thing this
    -- function does, so it is the thing that gives way.
    if ns.Comm then ns.Comm.Report(zoneID, shardID, stage, pos) end

    -- Seeing it ourselves is what a report was waiting for. If a scout caught
    -- the transport and we have only found the crate on the ground, their
    -- anchor is the better one and this is where it is taken.
    if ns.Remote then
        local promoted, report = ns.Remote.Promote(ns.remote, ns.db.crates, zoneID, shardID)
        if promoted == "new" or promoted == "refined" then
            ns.Print(("  |cff777777timer taken from %s, who saw it %s (via %s)|r"):format(
                report.from, report.stage, tostring(report.via)))
        end
        -- Their account of this crate has been overtaken by seeing it. Kept
        -- any longer it would go on describing a stage the crate has left.
        ns.Remote.Supersede(ns.remote, zoneID, shardID, stage)
    end

    -- A crate in view beats a crate predicted, so this overrides any pin the
    -- prediction put down. Flying into a zone where one is already under its
    -- parachute used to leave the map bare: there is no transport left to
    -- predict from, and the one position nobody had to guess at -- printed on
    -- the line above -- was the one never pinned.
    if stage ~= "claimed" then
        pinCrate(zoneID, pos.x, pos.y, ns.LANDED_STAGE[stage])
    end

    local guess = ns.lastPrediction[zoneID]
    if guess and (GetServerTime() - guess.at) <= PREDICTION_MEMORY then
        local dx, dy = guess.x - pos.x, guess.y - pos.y
        local miss = math.sqrt(dx * dx + dy * dy) * 100
        local colour = miss <= 1 and "|cff33ff99" or (miss <= 3 and "|cffffd100" or "|cffff5555")
        ns.Print(string.format("  predicted %.1f, %.1f -- %smissed by %.2f%% of map|r",
            guess.x * 100, guess.y * 100, colour, miss))

        -- Score the timing as well as the place. The first flight this ran on
        -- promised release in 8 seconds and it took 30, which is the kind of
        -- bias that only shows up by checking rather than by reasoning about
        -- it -- the transport may well slow on approach, while the fit reports
        -- an average speed over its whole window.
        if stage == "falling" and guess.toRelease then
            local actual = GetServerTime() - guess.at
            local err = actual - guess.toRelease
            local acc = ns.db.release[zoneID] or { n = 0, sum = 0 }
            acc.n, acc.sum = acc.n + 1, acc.sum + err
            if not acc.lo or err < acc.lo then acc.lo = err end
            if not acc.hi or err > acc.hi then acc.hi = err end
            ns.db.release[zoneID] = acc
            ns.Print(("  release called at %ds, took %ds -- |cffffd100%+ds|r%s"):format(
                math.floor(guess.toRelease + 0.5), math.floor(actual + 0.5), math.floor(err + 0.5),
                acc.n > 1 and ("  |cff777777mean %+ds over %d|r"):format(
                    math.floor(acc.sum / acc.n + 0.5), acc.n) or ""))
        end
        ns.lastPrediction[zoneID] = nil
    end

    -- Only a landed crate says where crates land. A parachute position is
    -- somewhere it was passing over.
    if not ns.LANDED_STAGE[stage] then return end

    local learned = ns.Learn.Note(ns.db.learned, zoneID, pos.x, pos.y)
    if learned == "learned" then
        ns.Print(string.format(
            "  |cff33ff99new drop spot learned|r -- %.1f, %.1f was not in the catalogue",
            pos.x * 100, pos.y * 100))
    elseif learned == "full" then
        ns.Print("  |cffff8800this zone has hit its learned-spot cap|r")
    elseif learned == "invalid" then
        ns.Print(("  |cffff5555could not record this spot|r (store=%s, %.4f %.4f)"):format(
            type(ns.db.learned), pos.x, pos.y))
    end
end

-- An NPC announcing the cycle. The earliest anchor there is: it fires at the
-- spawn, before the transport is close enough to draw a vignette, which is the
-- whole reason for listening.
function ns.OnSpawnAnnounced(zoneID, shardID, npcName, verdict)
    if verdict == "new" or verdict == "refined" then
        ns.Print(("%s |cffffffffshard %s|r -- |cff33ff99%s announced a crate|r"):format(
            ns.GetZoneName(zoneID), tostring(shardID), npcName))
    else
        ns.Debug(("announcement in %s shard %s -> %s (timer left alone)"):format(
            ns.GetZoneName(zoneID), tostring(shardID), verdict))
    end
end

-- The transport has flown through the spot it was called for. Worth saying:
-- when the crate's own vignette never turns up -- out of range, or the drop
-- bugging out as one did in Coiled Isle -- this is the only word the player
-- gets about where it went.
function ns.OnTransportArrived(zoneID, spot)
    ns.Print(("|cff77dd77transport reached|r %.1f, %.1f in %s -- the crate should be there"):format(
        spot.x * 100, spot.y * 100, ns.GetZoneName(zoneID)))
end

-- A parachute timed from release to landing. The one leg of the flight that
-- cannot be computed and has to be measured.
function ns.OnDescentMeasured(zoneID, seconds, partial, dist)
    local mean, n, lo, hi, _, _, source = ns.Airtime.Descent(ns.db.descent, zoneID)
    -- How far away it was watched from is on the line because that is the
    -- open question, and a reading nobody can see the distance of is a
    -- reading that cannot answer it.
    ns.Print(("|cff33ff99descent measured|r in %s: |cffffd100%ds|r under the parachute%s%s"):format(
        ns.GetZoneName(zoneID), math.floor(seconds + 0.5),
        dist and (" |cffffd100from %.1f%% away|r"):format(dist) or "",
        partial and " |cffff8800(joined mid-fall -- a lower bound, not counted)|r" or ""))
    if n > 1 then
        ns.Print(("  %d %s: typically %ds, range %d-%d"):format(
            n, source == "pooled" and "across every zone, this one disagreeing with itself"
                or "measured here",
            math.floor(mean + 0.5), math.floor(lo + 0.5), math.floor(hi + 0.5)))
    end
end

-- Two drops seen in the same zone and shard. The gap between them is the only
-- direct measurement of the respawn interval anyone gets, and the three addons
-- that ship a figure disagree about it, so it is worth saying out loud.
function ns.OnGapObserved(zoneID, shardID, noted)
    local n, mean, lo, hi = ns.Timers.GapStats(ns.db.gaps, zoneID)
    ns.Print(("|cff33ff99interval measured|r in %s shard %s: |cffffd100%ds|r%s"):format(
        ns.GetZoneName(zoneID), tostring(shardID), math.floor(noted.gap + 0.5),
        noted.cycles > 1 and (" over %d cycles = %ds each"):format(
            noted.cycles, math.floor(noted.per + 0.5)) or ""))
    if n > 1 then
        ns.Print(("  %d observations here: mean %ds, range %d-%d  |cff777777(shipped %ds)|r"):format(
            n, math.floor(mean + 0.5), math.floor(lo + 0.5), math.floor(hi + 0.5),
            ns.GetShippedInterval(zoneID)))
    end
end

-- Place the pin, then read it back.
--
-- Clearing first is what RCT does and this did not: an existing waypoint --
-- the player's own, another addon's, or this addon's from the previous flight
-- -- can stop a new one taking, and nothing says so.
--
-- Whether the game permits a pin is no longer asked before placing one. RCT
-- never asks and RCT's pins appear; asking and refusing on a false meant
-- quietly declining to place a pin that would have worked. Attempting and then
-- checking what actually landed is both more reliable and the thing this addon
-- keeps telling itself to do -- look at the artefact, not the return code.
--
-- It is still worth asking to explain a failure, which is what ns.PinAllowed
-- is for. Guarded, because the name was wrong for as long as this code has
-- existed -- the API is CanSetUserWaypointOnMap -- and the only line that
-- called it was the one that runs when a pin has already failed. So the branch
-- written to say why nothing appeared threw a Lua error instead, and that went
-- unnoticed because pins kept taking. A diagnostic that throws is worse than
-- one that admits it cannot tell.
-- quiet suppresses the confirmation line, not the pin. A crate under its
-- parachute drifts, so the pin follows it for the whole descent, and saying so
-- each time filled the chat with forty identical lines in eighty seconds.
-- The first placement is worth one line; the rest are the same news.
-- true, false, or nil when this client will not answer.
function ns.PinAllowed(mapID)
    local ask = C_Map.CanSetUserWaypointOnMap
    if not (ask and mapID) then return nil end
    local ok, allowed = pcall(ask, mapID)
    if not ok then return nil end
    return allowed and true or false
end

function ns.SetCratePin(zoneID, x, y, quiet)
    C_Map.ClearUserWaypoint()
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(zoneID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)

    local set = C_Map.GetUserWaypoint()
    if set then
        if not quiet then
            ns.Print(("  |cff777777map pin set on %s|r"):format(ns.GetZoneName(zoneID)))
        end
        -- The hyperlink describes whatever waypoint is currently set, not a
        -- point of our choosing, so it is read here and only when the readback
        -- agrees about the map. Building the link by hand instead does not
        -- work: chat strips an untrusted |Hworldmap string to plain text on
        -- send, which WarCratePredict shipped and had to undo.
        local link
        if set.uiMapID == zoneID and C_Map.GetUserWaypointHyperlink then
            local ok, got = pcall(C_Map.GetUserWaypointHyperlink)
            if ok and type(got) == "string" and got ~= "" then link = got end
        end
        return true, link
    end
    local allowed = ns.PinAllowed(zoneID)
    ns.Print(("  |cffff8800the map pin did not take|r |cff777777(the game %s allow one on %s)|r"):format(
        allowed == nil and "will not say whether it would" or
            (allowed and "says it does" or "says it does not"),
        ns.GetZoneName(zoneID)))
    return false
end

-- A transport found circling its drop point. There is no release to time --
-- it is already there -- so this says only where, and how long the crate will
-- then take to come down.
function ns.OnHovering(zoneID, spot, dist)
    ns.lastPrediction[zoneID] = { x = spot.x, y = spot.y, at = GetServerTime() }
    local descent, n = ns.Airtime.Descent(ns.db.descent, zoneID)
    ns.Print(("|cffffd100circling|r |cffffd100%.1f, %.1f|r in %s -- dropping any moment,"
        .. " |cffffd100on the ground %ss later|r%s  |cff777777(%.1f%% off the spot)|r"):format(
        spot.x * 100, spot.y * 100, ns.GetZoneName(zoneID), math.floor(descent + 0.5),
        n == 0 and " |cff777777(descent not measured here yet)|r" or "", dist * 100))
    if not ns.db.waypoint then
        ns.Print("  |cff777777no map pin: turned off in settings|r")
    else
        pinCrate(zoneID, spot.x, spot.y)
    end
end

-- Called when there is a spot worth flying to, firm or not.
function ns.OnPrediction(zoneID, result, fit)
    local s = result.aim.spot
    local firm = result.ok
    ns.lastPrediction[zoneID] = { x = s.x, y = s.y, at = GetServerTime() }
    local eta = ns.Airtime.ETA(ns.db.descent, zoneID, fit, s, nil, GetServerTime(), ns.db.release)
    -- The RAW figure is remembered, because that is what the next measurement
    -- scores against. Storing the corrected one would drive the measured bias
    -- to zero and silently undo the correction that produced it.
    ns.lastPrediction[zoneID].toRelease = eta and eta.toReleaseRaw
    local when = ""
    if eta then
        when = (", |cffffd100on the ground in %s|r%s"):format(
            ns.FormatClock(eta.toGround):gsub("^%s+", ""),
            eta.descentN == 0 and " |cff777777(descent not measured here yet)|r"
            or eta.descentSource == "pooled"
                and " |cff777777(descent borrowed: this zone's own readings disagree)|r" or "")
    end

    -- An unfirm call names what else is on the line, because that is the whole
    -- reason it is safe to act on early: the runners-up are further along the
    -- same heading, so flying at this one is flying at them too.
    local rest = ""
    if not firm and result.contenders and #result.contenders > 1 then
        local others = {}
        for i = 2, #result.contenders do
            local o = result.contenders[i].spot
            others[#others + 1] = ("%.1f,%.1f"):format(o.x * 100, o.y * 100)
        end
        rest = ("  |cff777777then %s on the same line|r"):format(table.concat(others, ", "))
    end

    ns.Print(string.format(
        "%s |cffffd100%.1f, %.1f|r in %s%s  |cff777777(%d%% sure, %.1f deg off, %d samples)|r%s",
        firm and "incoming to" or "probably", s.x * 100, s.y * 100,
        ns.GetZoneName(zoneID), when,
        math.floor((result.aim.p or 0) * 100 + 0.5),
        math.deg(math.atan(result.aim.tan)), fit.n, rest))

    if not ns.db.waypoint then
        ns.Print("  |cff777777no map pin: turned off in settings|r")
    else
        -- Only a firm call is worth telling a raid about, and announcing sets
        -- the pin on the way, because the link it sends IS this client's
        -- waypoint. Pinning again afterwards would be the same call twice.
        local said = firm and ns.Comm and ns.Comm.Announce(zoneID, s.x, s.y)
        if said == "sent" then
            pinnedAt[zoneID] = { x = s.x, y = s.y }   -- announcing set it
        else
            pinCrate(zoneID, s.x, s.y)
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, name)
    if event ~= "ADDON_LOADED" or name ~= ADDON then return end
    EasyWarCratesDB = applyDefaults(EasyWarCratesDB or {})
    ns.db = EasyWarCratesDB
    -- Before pruning, never after. Prune clears the display list, and the
    -- display list was the only record of where each shard's cycle sits --
    -- which is why an evening's break left the addon blind in every zone it
    -- had already learned.
    local now = GetServerTime()
    ns.Phase.Absorb(ns.db.phase, ns.db.crates)
    ns.Phase.Forget(ns.db.phase, now)
    local dropped = ns.Timers.Prune(ns.db.crates, ns.GetZoneInterval, now)
    ns.Print("v" .. ns.version .. " loaded. |cffffffff/ewc|r for commands."
        .. (dropped > 0 and (" |cff777777(%d stale timer%s cleared)|r"):format(
            dropped, dropped == 1 and "" or "s") or ""))
end)
