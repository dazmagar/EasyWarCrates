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
    travel    = nil,    -- per-zone capital-to-zone overrides
    route     = nil,    -- the rotation, as zone ids in order
    descent   = nil,    -- measured parachute times, per zone
    release   = nil,    -- how wrong the release-time estimate runs, per zone
    minimap     = true,   -- show the minimap button
    windowShown = true,   -- show the tracker window
    -- Deliberately absent: minimapAngle and window. They hold where the player
    -- dragged something, so "unset" is their real state until one is dragged,
    -- and every reader supplies its own fallback. A default of nothing is not
    -- a default and does not belong in this table.
}

ns.DEFAULTS = DEFAULTS

local PREFIX = "|cff33ddaa[EWC]|r "

function ns.Print(...)
    print(PREFIX .. string.join(" ", tostringall(...)))
end

function ns.Debug(...)
    if ns.db and ns.db.verbose then
        print("|cff777777[EWC]|r " .. string.join(" ", tostringall(...)))
    end
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
    db.travel  = db.travel or {}
    db.route   = db.route or {}
    db.descent = db.descent or {}
    db.release = db.release or {}
    return db
end

-- What each zone was last told to expect, so a landing can be scored against
-- it. Neither RCT nor WarCrateTracker ever checks its own guess; CrateTrackerZK
-- does, and it is the only way to find out whether the model is actually any
-- good rather than merely plausible.
ns.lastPrediction = {}
local PREDICTION_MEMORY = 600  -- a guess older than this is not about this crate

-- Every sighting of a crate's own vignette. This is the truth the prediction
-- was only guessing at, so it scores the guess, files the landing spot, and
-- reports the timer -- but only the last of those depends on the timer having
-- actually moved. verdict is what Timers made of it.
function ns.OnCrateSighted(zoneID, shardID, stage, pos, verdict)
    if verdict == "new" or verdict == "refined" then
        ns.Print(string.format("%s |cffffffffshard %s|r -- crate %s at |cffffd100%.1f, %.1f|r",
            ns.GetZoneName(zoneID), tostring(shardID), stage, pos.x * 100, pos.y * 100))
    else
        ns.Debug(("crate %s in %s shard %s -> %s (timer left alone)"):format(
            stage, ns.GetZoneName(zoneID), tostring(shardID), verdict))
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
function ns.OnDescentMeasured(zoneID, seconds, overlapped, partial)
    local mean, n, lo, hi, over = ns.Airtime.Descent(ns.db.descent, zoneID)
    ns.Print(("|cff33ff99descent measured|r in %s: |cffffd100%ds|r under the parachute%s"):format(
        ns.GetZoneName(zoneID), math.floor(seconds + 0.5),
        partial and " |cffff8800(joined mid-fall -- a lower bound, not counted)|r"
            or (overlapped and " |cffff8800(parachute still drawn)|r" or "")))
    if n > 1 then
        ns.Print(("  %d measured here: mean %ds, range %d-%d%s"):format(
            n, math.floor(mean + 0.5), math.floor(lo + 0.5), math.floor(hi + 0.5),
            over > 0 and ("  |cff777777%d overlapped|r"):format(over) or ""))
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

-- Called when a transport's heading has settled on one spot.
function ns.OnPrediction(zoneID, result, fit)
    local s = result.best.spot
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
            eta.descentN == 0 and " |cff777777(descent not measured here yet)|r" or "")
    end
    ns.Print(string.format(
        "incoming to |cffffd100%.1f, %.1f|r in %s%s  |cff777777(%.1f deg off, %d samples)|r",
        s.x * 100, s.y * 100, ns.GetZoneName(zoneID), when,
        math.deg(math.atan(result.best.tan)), fit.n))

    -- Say when the pin does not get placed, and why. It failed silently once
    -- in Zul'Aman: the call was right, announced and acted on by the player,
    -- and the only thing missing was the marker -- with nothing on screen to
    -- say whether the addon had chosen not to place one or had tried and been
    -- refused.
    if not ns.db.waypoint then
        ns.Print("  |cff777777no map pin: turned off in settings|r")
    elseif not C_Map.CanSetUserWaypoint(zoneID) then
        ns.Print(("  |cffff8800no map pin: the game will not allow one on %s|r"):format(
            ns.GetZoneName(zoneID)))
    else
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(zoneID, s.x, s.y))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        -- Read back rather than trusting the call. A pin that did not take is
        -- exactly as useful as no pin, and the point of saying so is to find
        -- out which happened.
        -- Success reported too. Staying quiet on success made "no message"
        -- mean either "it worked" or "you are running an older build", and
        -- those needed telling apart while the pin was not appearing.
        local set = C_Map.GetUserWaypoint()
        if not set then
            ns.Print("  |cffff8800the map pin did not take|r")
        else
            ns.Print(("  |cff777777map pin set on %s|r"):format(ns.GetZoneName(zoneID)))
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, name)
    if event ~= "ADDON_LOADED" or name ~= ADDON then return end
    EasyWarCratesDB = applyDefaults(EasyWarCratesDB or {})
    ns.db = EasyWarCratesDB
    local dropped = ns.Timers.Prune(ns.db.crates, ns.GetZoneInterval, GetServerTime())
    ns.Print("v" .. ns.version .. " loaded. |cffffffff/ewc|r for commands."
        .. (dropped > 0 and (" |cff777777(%d stale timer%s cleared)|r"):format(
            dropped, dropped == 1 and "" or "s") or ""))
end)
