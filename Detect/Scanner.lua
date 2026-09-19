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

-- The transport in the air, one per zone.
--
-- Keyed by zone rather than by vignette GUID, because the GUID churns: the
-- same plane's vignette disappears and comes back under a new id every few
-- seconds. Keying on it built a fresh track each time, with its own sample
-- count and its own idea of whether it had committed, so one track would
-- commit while a sibling sat at four samples and the readout alternated
-- between them. The GUID cooldown, the everFit guard and the empty-track
-- sweep were each treating a symptom of this.
--
-- A zone has one crate per cycle and therefore one transport, so a zone is the
-- honest key. The current GUID is carried on the track and replaced as it
-- moves.
local tracks = {}
-- When each zone last had a transport announced, keyed by zone rather than by
-- track. See the cooldown's use below for why that distinction matters.
local spotted = {}
-- Comfortably longer than a flight, so one plane is one announcement.
local SPOTTED_COOLDOWN = 180

-- When a zone last had a crate come down. Nothing is tracked there for a while
-- afterwards: the transport does not despawn when it drops its cargo, it
-- circles, so it goes on reporting itself as flying with nothing left to
-- predict. Its vignette GUID also churns, so each reappearance built a brand
-- new track with fresh state and narrated its own sample count from scratch.
-- The next crate is around eighteen minutes out, so two minutes of silence
-- costs nothing and removes the whole class of noise.
local recentDrop = {}
local DROP_COOLDOWN = 120

-- When the parachute was first seen, keyed by zone AND shard.
--
-- Keyed by zone alone it paired the wrong crates. Two drops landed in Slayer's
-- Rise ninety seconds apart on different shards -- a Horde raid's on one, an
-- Alliance one on the other, after the player was re-sharded out of a group --
-- and the descent came out as 154 seconds by timing one crate's parachute
-- against the other's landing. The true figure was 117. A mis-paired
-- measurement is worse than a missing one: it looks like data.
local fallingSince = {}

-- A parachute older than this cannot belong to the landing being timed. Longer
-- than any descent observed, shorter than the gap between drops.
local DESCENT_PAIR_MAX = 300

-- The crate that is in the air or on the ground RIGHT NOW, per zone.
--
-- Kept separately from the timer because they answer different questions. The
-- moment a crate is released the timer resets and starts counting the ~18
-- minutes to the next one, so the window jumps from 0:05 to 18:10 exactly when
-- there is a crate lying there to go and take. The countdown is right and
-- useless; this is what the player actually wants at that moment.
local liveCrate = {}

-- Stop showing a crate nobody has seen for this long while standing in its
-- zone. It has been taken, or it was never really there.
local LIVE_STALE = 90

function Scanner.LiveCrate(zoneID)
    local live = liveCrate[zoneID]
    if not live then return nil end
    if GetServerTime() - (live.seen or 0) > LIVE_STALE then
        liveCrate[zoneID] = nil
        return nil
    end
    return live
end

local function fallKey(zoneID, shard) return tostring(zoneID) .. ":" .. tostring(shard) end

local TRACK_STALE = 60  -- seconds a track may go unseen before it is dropped

-- VIGNETTES_UPDATED alone is not enough to fly a heading off: it fires when the
-- vignette SET changes, and a transport crossing a zone is one unchanging
-- vignette that merely moves. So the event opens a track and this poll feeds it.
--
-- How fast positions actually arrive varies a great deal, and not with the poll
-- rate. Two flights, both logged: one in Voidstorm yielded a new position about
-- every 5.5 seconds while polling at 4Hz, so five samples took 25 seconds; one
-- in Zul'Aman reached thirty samples in eighteen, roughly one a second. The
-- difference is the event, which also feeds the track and fires far more often
-- for some flights than others. So this poll is a floor under the sample rate,
-- not the thing that sets it, and raising it does not help the slow case.
--
-- Worth knowing before tuning Heading.MIN_SAMPLES: in the slow case the wait
-- for five samples IS the delay between spotting a transport and being able to
-- call its target, and a transport visible for less than that cannot be
-- predicted at all. That is what happened on the first Voidstorm flight.
local POLL_INTERVAL = 1.0
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
    spotted = {}
    recentDrop = {}
    fallingSince = {}
    liveCrate = {}
    stopPolling()
end

local function dropStaleTracks(now)
    for zoneID, tr in pairs(tracks) do
        if now - (tr.lastSeen or 0) > TRACK_STALE then
            tracks[zoneID] = nil
        end
    end
end

-- Forgets every transport being tracked in a zone. Called the moment a crate
-- vignette shows up there: the question the tracking existed to answer has
-- just been answered by the game.
function Scanner.EndTracks(zoneID)
    tracks[zoneID] = nil
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

    for trackZone, tr in pairs(tracks) do
        local info = C_VignetteInfo.GetVignetteInfo(tr.guid)
        -- A GUID that has gone quiet is not the end of anything: it churns
        -- constantly and the event hands the track its replacement. The track
        -- ends when a crate drops (EndTracks), when the vignette turns into
        -- something that is not a transport, or when it goes unseen for
        -- TRACK_STALE.
        if info and ns.VignetteStage(info.vignetteID) ~= "flying" then
            tracks[trackZone] = nil
        elseif info then
            local pos = vignettePosition(tr.guid, trackZone, rawMap)
            if pos then
                tr.lastSeen = now
                if tr.track:Add(now, pos.x, pos.y) then
                    Scanner.Evaluate(trackZone, tr)
                end
            end
        end
    end

    dropStaleTracks(now)
    Scanner.Narrate(now)
    if not next(tracks) then stopPolling() end
end

-- /ewc watch. Reports only when something actually changes.
--
-- The first cut printed once a second, which produced 47 identical COMMIT
-- lines for one flight -- the transport holds a steady prediction for as long
-- as it flies, so a per-second readout is one line of information and forty-six
-- of noise. What is worth saying is a new sample, or a changed verdict.
function Scanner.Narrate(now)
    if not (ns.db and ns.db.watch) then return end

    for _, tr in pairs(tracks) do
        local fit, why = tr.track:Fit()
        if fit then tr.everFit = true end
        local state, line
        if not fit then
            -- The waiting line belongs to acquiring a track, said once per
            -- count on the way up and never after the track has fitted even
            -- once. Samples age out of the window and arrive again, so the
            -- count oscillates across the threshold for the whole flight: a
            -- live transport otherwise alternates COMMIT with "not enough
            -- samples" every few seconds, which was half the log.
            local n = tr.track:Count()
            if why == "still" then
                state = "still"
                line = ("|cff777777%d samples, but it has stopped moving -- circling its drop point|r")
                    :format(n)
            elseif not tr.everFit and n >= (tr.peak or 0) then
                tr.peak = n
                state = "wait:" .. n
                line = ("|cff777777tracking|r %d sample%s, not enough to fit yet"):format(
                    n, n == 1 and "" or "s")
            end
        elseif tr.committed then
            -- Settled. Re-running the prediction here would report the plane
            -- drifting off its own answer once it has flown past.
            local where = ("%.1f,%.1f"):format(tr.committed.x * 100, tr.committed.y * 100)
            state = "committed:" .. where .. (tr.arrived and ":arrived" or "")
            line = ("|cff777777n=%d span=%.1fs|r  %s -> %s"):format(fit.n, fit.span,
                tr.arrived and "|cff77dd77ARRIVED|r" or "|cff33ff99COMMIT|r", where)
        else
            local r = ns.Predict.Evaluate(ns.GetDropPoints(tr.zoneID), fit)
            local where = r.best and ("%.1f,%.1f"):format(r.best.spot.x * 100, r.best.spot.y * 100) or "-"
            state = ("%d:%s:%s"):format(fit.n, r.ok and "ok" or tostring(r.reason), where)
            line = ("|cff777777n=%d span=%.1fs err=%.2fdeg|r  %s -> %s"):format(
                fit.n, fit.span, math.deg(fit.err),
                r.ok and "|cff33ff99COMMIT|r" or ("|cffff8800" .. tostring(r.reason) .. "|r"),
                where)
        end
        if line and tr.narrated ~= state then
            tr.narrated = state
            ns.Print(line)
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
    local tr = tracks[zoneID]
    local fit = tr and tr.track:Fit()
    if not fit then return nil end

    local r = ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
    r.fit, r.committed, r.arrived = fit, tr.committed, tr.arrived
    return r
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

    -- Which zone and shard currently show a parachute, gathered before acting
    -- on anything. The game will keep drawing one for a crate that is already
    -- down -- observed lingering eight to ten seconds in Zul'Aman -- so a
    -- landing recorded while its parachute is still up has an ambiguous
    -- moment, and the descent reading may run long by that much. Recorded as a
    -- flag on the reading rather than used to reject it: whether those
    -- readings are really biased is something the samples can show and a guess
    -- cannot.
    local fallingNow = {}
    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        if info and ns.VignetteStage(info.vignetteID) == "falling" then
            local sh = ns.Shard.FromVignetteGUID(guid)
            if sh then fallingNow[fallKey(zoneID, sh)] = true end
        end
    end

    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        local stage = info and ns.VignetteStage(info.vignetteID)
        if stage then
            local pos = vignettePosition(guid, zoneID, rawMap)
            if pos then
                local shard = ns.Shard.FromVignetteGUID(guid)

                if stage == "flying" and (tNow - (recentDrop[zoneID] or -math.huge)) <= DROP_COOLDOWN then
                    -- This zone's crate is already down. Whatever this
                    -- transport is doing now, it is not carrying one.
                elseif stage == "flying" then
                    local tr = tracks[zoneID]
                    if not tr then
                        tr = { track = ns.Heading.NewTrack(zoneID), zoneID = zoneID }
                        tracks[zoneID] = tr
                        -- Announced per zone, not per track. A transport's
                        -- vignette churns -- its GUID comes and goes, and each
                        -- reappearance builds a fresh track -- which printed
                        -- "transport spotted" twenty-five times in forty-five
                        -- seconds for a single plane.
                        if (tNow - (spotted[zoneID] or -math.huge)) > SPOTTED_COOLDOWN then
                            spotted[zoneID] = tNow
                            ns.Print(("|cffffd100transport spotted|r in %s -- tracking"):format(
                                ns.GetZoneName(zoneID)))
                        end
                    end
                    tr.guid = guid
                    tr.lastSeen = tNow
                    tr.track:Add(tNow, pos.x, pos.y)
                    startPolling()
                    Scanner.Evaluate(zoneID, tr)
                else
                    -- The crate is down, or on its way down. Its own position
                    -- is the answer, so every guess about this zone is now
                    -- worthless -- including the transport's.
                    --
                    -- The transport does not despawn when it drops its cargo,
                    -- it circles its drop point, so without this its track
                    -- survives and goes on reporting a heading for a plane
                    -- with nothing left to carry.
                    Scanner.EndTracks(zoneID)
                    recentDrop[zoneID] = tNow
                    -- The two parachute stages, before anything is recorded:
                    -- the descent is the gap between them, and it is the only
                    -- way to know how long a crate takes to come down.
                    if not shard then
                        ns.Debug("crate seen but its GUID carried no shard; not recorded")
                    else
                        local key = fallKey(zoneID, shard)
                        if stage == "claimed" then
                            liveCrate[zoneID] = nil
                        else
                            local live = liveCrate[zoneID] or { zoneID = zoneID }
                            live.shard, live.seen = shard, stamp
                            live.x, live.y = pos.x, pos.y
                            if stage == "falling" then
                                live.phase = "falling"
                                live.since = live.since or stamp
                            else
                                live.phase = "ground"
                                live.groundAt = live.groundAt or stamp
                            end
                            liveCrate[zoneID] = live
                        end

                        if stage == "falling" then
                            fallingSince[key] = fallingSince[key] or stamp
                        elseif stage == "ground" and fallingSince[key] then
                            local secs = stamp - fallingSince[key]
                            fallingSince[key] = nil
                            local overlapped = fallingNow[key]
                            if secs <= DESCENT_PAIR_MAX
                                and ns.Airtime.NoteDescent(db.descent, zoneID, secs, overlapped) then
                                ns.OnDescentMeasured(zoneID, secs, overlapped)
                            end
                        elseif stage == "claimed" then
                            fallingSince[key] = nil
                        end

                        local verdict, _, gap = ns.Timers.Record(db.crates, zoneID, shard, stamp, stage)
                        if gap then
                            local noted = ns.Timers.NoteGap(db.gaps, zoneID, gap,
                                ns.GetZoneInterval(zoneID))
                            if noted then ns.OnGapObserved(zoneID, shard, noted) end
                        end
                        -- Every sighting, not only the ones that move a timer.
                        -- Updating the countdown and learning where crates land
                        -- are separate jobs, and tying them together meant the
                        -- on-the-ground position -- the best evidence there is
                        -- -- was discarded whenever the parachute had already
                        -- been seen, which is the common case.
                        ns.OnCrateSighted(zoneID, shard, stage, pos, verdict)
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

    -- Once a transport has been called, that is the answer. It carries one
    -- crate and drops it once, so re-reading its heading afterwards is reading
    -- a plane that has finished its job -- which in Coiled Isle produced a
    -- confident call on 46.7, 73.8, held for a minute, followed by the tracker
    -- talking about 57.6, 77.5 the moment it flew past.
    --
    -- The only question left is whether it got there, and saying so is worth
    -- more than it sounds: when the crate's own vignette never appears -- out
    -- of range, or the drop bugging out as it did there -- this is the only
    -- word the player gets about where it went.
    if tr.committed then
        if not tr.arrived then
            local dx, dy = tr.committed.x - fit.x, tr.committed.y - fit.y
            if dx * fit.hx + dy * fit.hy <= 0 then
                tr.arrived = true
                ns.OnTransportArrived(zoneID, tr.committed)
            end
        end
        return
    end

    local result = ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
    if not result.ok then return end

    local spot = result.best.spot
    tr.committed = { x = spot.x, y = spot.y }
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
