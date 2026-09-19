local ADDON, ns = ...

-- The one file that genuinely talks to the game, so it is kept thin: read
-- vignettes, hand the numbers to the modules that are already tested, store
-- the verdict. No maths lives here.

local Scanner = {}
ns.Scanner = Scanner

-- Two clocks on purpose. GetTime() is a monotonic client timer with sub-second
-- resolution, which is what a heading fit needs and what GetServerTime()'s
-- whole seconds would quantise into uselessness. GetServerTime() is wall time
-- that means the same thing to every player, which is what a crate timestamp
-- has to be if it is ever shared.
local function fitClock() return GetTime() end
local function stampClock() return GetServerTime() end

-- Transports currently in the air, by vignette GUID.
local tracks = {}
-- Last thing we told the player about, so a steady prediction is not repeated.
local announced = {}

local TRACK_STALE = 60  -- seconds a track may go unseen before it is dropped

-- VIGNETTES_UPDATED alone is not enough to fly a heading off. It is documented
-- as firing when the vignette SET changes, and a transport crossing a zone is
-- one unchanging vignette that merely moves -- so the event may fire a handful
-- of times across a 70-second flight, which is nowhere near the sample count a
-- regression needs. CrateTrackerZK does not trust the event either; it samples
-- on its own 0.25s ticker. So the event opens a track and this poll feeds it.
--
-- The ticker only runs while something is actually in the air.
local POLL_INTERVAL = 0.25
local ticker

local function playerMapID()
    return C_Map.GetBestMapForUnit("player")
end

-- Ask for a vignette's position on the ZONE's map, not on whatever map the
-- player happens to be standing on.
--
-- Two reasons, and the second is the one that bites. First, coordinates come
-- back in the space of the map you ask about, and Data/DropPoints.lua is in
-- zone-map space -- asking about a sub-map would return numbers that look fine
-- and mean something else. Second, a sub-map often has no position for a
-- vignette that lives in the zone around it and returns nil: seen live in
-- Harandar, standing on map 2576, where the transport came back with no
-- position at all. Falls back to the raw map so a zone whose sub-map IS the
-- right space still works.
local function vignettePosition(guid, zoneID, rawMap)
    if zoneID then
        local pos = C_VignetteInfo.GetVignettePosition(guid, zoneID)
        if pos then return pos, zoneID end
    end
    if rawMap and rawMap ~= zoneID then
        local pos = C_VignetteInfo.GetVignettePosition(guid, rawMap)
        if pos then return pos, rawMap end
    end
    return nil
end
Scanner.VignettePosition = vignettePosition

local function stopPolling()
    if ticker then ticker:Cancel(); ticker = nil end
end

local function startPolling()
    if not ticker then ticker = C_Timer.NewTicker(POLL_INTERVAL, function() Scanner.Poll() end) end
end

function Scanner.Reset()
    tracks = {}
    announced = {}
    stopPolling()
end

local function dropStaleTracks(now)
    for guid, tr in pairs(tracks) do
        if now - (tr.lastSeen or 0) > TRACK_STALE then
            tracks[guid] = nil
            announced[guid] = nil
        end
    end
end

-- Re-reads the position of every transport being tracked. Also the place a
-- track ends: when its vignette stops being "flying" it has either dropped its
-- crate or despawned, and either way there is nothing left to predict.
function Scanner.Poll()
    if not next(tracks) then return stopPolling() end

    local rawMap = playerMapID()
    if not rawMap then return end
    local zoneID = ns.Zones.Normalize(rawMap)
    local now = fitClock()

    for guid, tr in pairs(tracks) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        if not info or ns.VignetteStage(info.vignetteID) ~= "flying" then
            tracks[guid], announced[guid] = nil, nil
        else
            local pos = vignettePosition(guid, tr.zoneID or zoneID, rawMap)
            if pos then
                tr.lastSeen = now
                if tr.track:Add(now, pos.x, pos.y) then
                    Scanner.Evaluate(tr.zoneID, tr)
                end
            end
        end
    end

    dropStaleTracks(now)
    Scanner.Narrate(now)
    if not next(tracks) then stopPolling() end
end

-- /ewc watch. Without it the addon is silent until it is confident, and
-- silence cannot be told apart from "never saw the plane at all".
local lastNarrate = 0
function Scanner.Narrate(now)
    if not (ns.db and ns.db.watch) then return end
    if now - lastNarrate < 1 then return end
    lastNarrate = now

    for _, tr in pairs(tracks) do
        local fit = tr.track:Fit()
        if not fit then
            ns.Print(("|cff777777tracking|r %d samples, not enough to fit yet"):format(tr.track:Count()))
        else
            local r = ns.Predict.Evaluate(ns.GetDropPoints(tr.zoneID), fit)
            local where = r.best and ("%.1f,%.1f"):format(r.best.spot.x * 100, r.best.spot.y * 100) or "-"
            ns.Print(("|cff777777n=%d span=%.1fs err=%.2fdeg|r  %s -> %s"):format(
                fit.n, fit.span, math.deg(fit.err),
                r.ok and "|cff33ff99COMMIT|r" or ("|cffff8800" .. tostring(r.reason) .. "|r"),
                where))
        end
    end
end

-- Raw sweep of everything the game currently reports, classified but not
-- filtered. /ewc scan prints this; it is the instrument for finding out
-- whether the vignette ids still hold on a new patch.
function Scanner.Sweep()
    local out = {}
    local rawMap = playerMapID()
    if not rawMap then return out, nil end
    local zoneID = ns.Zones.Normalize(rawMap)

    local guids = C_VignetteInfo.GetVignettes()
    if type(guids) ~= "table" then return out, rawMap, zoneID end

    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        if info then
            local pos, posMap = vignettePosition(guid, zoneID, rawMap)
            out[#out + 1] = {
                guid    = guid,
                id      = info.vignetteID,
                name    = info.name,
                atlas   = info.atlasName,
                stage   = ns.VignetteStage(info.vignetteID),
                x       = pos and pos.x,
                y       = pos and pos.y,
                shard   = ns.Shard.FromVignetteGUID(guid),
                posMap  = posMap,
            }
        end
    end
    return out, rawMap, zoneID
end

-- Current best guess for the zone, or nil. Exposed so the UI and the slash
-- commands read the same answer the scanner acted on.
function Scanner.Prediction(zoneID)
    local best
    for _, tr in pairs(tracks) do
        if tr.zoneID == zoneID then
            local fit = tr.track:Fit()
            if fit then
                local r = ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
                r.fit, r.guid = fit, tr.guid
                if r.ok and (not best or not best.ok) then best = r
                elseif not best then best = r end
            end
        end
    end
    return best
end

function Scanner.OnVignettesUpdated()
    local db = ns.db
    if not db or not db.enabled then return end
    if IsInInstance() then return end

    local rawMap = playerMapID()
    if not rawMap then return end
    local zoneID = ns.Zones.Normalize(rawMap)
    if not zoneID then return end

    local tNow, stamp = fitClock(), stampClock()
    dropStaleTracks(tNow)

    local guids = C_VignetteInfo.GetVignettes()
    if type(guids) ~= "table" then return end

    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        local stage = info and ns.VignetteStage(info.vignetteID)
        if stage then
            local pos = vignettePosition(guid, zoneID, rawMap)
            if pos then
                local shard = ns.Shard.FromVignetteGUID(guid)

                if stage == "flying" then
                    local tr = tracks[guid]
                    if not tr then
                        tr = { track = ns.Heading.NewTrack(guid), guid = guid, zoneID = zoneID }
                        tracks[guid] = tr
                        ns.Print(("|cffffd100transport spotted|r in %s -- tracking"):format(
                            ns.GetZoneName(zoneID)))
                    end
                    tr.zoneID = zoneID
                    tr.lastSeen = tNow
                    tr.track:Add(tNow, pos.x, pos.y)
                    startPolling()
                    Scanner.Evaluate(zoneID, tr)
                else
                    -- The crate is down, or on its way down. Its own position
                    -- is the answer, so any guess about it is now worthless.
                    tracks[guid] = nil
                    announced[guid] = nil
                    if not shard then
                        ns.Debug("crate seen but its GUID carried no shard; not recorded")
                    else
                        local verdict = ns.Timers.Record(db.crates, zoneID, shard, stamp, stage)
                        if verdict == "new" or verdict == "refined" then
                            ns.OnCrateRecorded(zoneID, shard, stage, pos)
                        else
                            -- Silence here is a real possibility and reads as a
                            -- bug: the same crate seen as "falling" and then as
                            -- "ground" a minute later is one crate, and the
                            -- second sighting is correctly a duplicate. Say so
                            -- under verbose rather than leaving nothing.
                            ns.Debug(("crate %s in %s shard %s -> %s (timer left alone)"):format(
                                stage, ns.GetZoneName(zoneID), tostring(shard), verdict))
                        end
                    end
                end
            end
        end
    end
end

-- Decides whether this track has become worth telling the player about.
function Scanner.Evaluate(zoneID, tr)
    local fit = tr.track:Fit()
    if not fit then return end
    local result = ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
    if not result.ok then return end

    -- Only speak when the answer changes. A steady prediction held for thirty
    -- seconds is one message, not thirty.
    local spot = result.best.spot
    local key = string.format("%.4f:%.4f", spot.x, spot.y)
    if announced[tr.guid] == key then return end
    announced[tr.guid] = key

    ns.OnPrediction(zoneID, result, fit)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("VIGNETTES_UPDATED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event)
    if event == "VIGNETTES_UPDATED" then
        Scanner.OnVignettesUpdated()
    else
        Scanner.Reset()
    end
end)

Scanner.frame = frame
