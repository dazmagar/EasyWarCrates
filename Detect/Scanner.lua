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
-- When a transport was last seen to reach its drop point, per zone. The gap
-- between that and the parachute appearing is the leg nobody has measured.
local arrivedAt = {}
-- Keys whose parachute was already in the air when we first saw it.
local partialFall = {}
local partialWhy = {}
local releaseLag = {}
-- The art the parachute vignette was drawn with, and when it first changed.
-- Dmitrii reports crates sitting on the ground with the parachute still shown
-- for 30 to 54 seconds, which is the size of the unexplained excess in the
-- long readings. If the art flips to the crate while the id stays 2967, the
-- real landing moment is observable and the bug becomes something to measure
-- around rather than something that silently inflates a mean.
local fallAtlas, atlasFlip = {}, {}

-- When this zone was last swept, in SERVER time, and which crates were falling
-- in it then. Server time because that is what the vignette stamps use, and
-- this held GetTime() for one build: the comparison was then between seconds
-- since the client started and a unix timestamp, so it was never satisfied and
-- every descent in every zone came out flagged as a fragment.
-- Together they answer the only question that matters for a descent reading:
-- did we watch this fall BEGIN. A parachute present in the first sweep of a
-- zone was already in the air before we arrived.
local lastSweptStamp, lastFalling = {}, {}

-- Last complaint about a vignette the game would not place, per zone. A crate
-- whose position cannot be resolved is skipped, and skipping it silently is
-- the failure this addon exists to prevent -- so it says so, once a minute at
-- most rather than once a second.
local noPosWarned = {}
-- When continuous observation of a zone began. Reset clears it, so it restarts
-- at every zone change and every reload.
local zoneWatchSince = {}
-- Watching a zone for less than this before a parachute appears proves nothing:
-- longer than any fall, so a crate that appears sooner came into vignette range
-- rather than into the air. Eversong recorded 14 seconds as a whole descent
-- because two sweeps had happened before the parachute drifted into range.
local MIN_WATCH = 150
-- How long a watched arrival vouches for a fall. One cycle is ~1090s, so this
-- cannot reach across to the next crate.
local ARRIVED_RECENT = 300
local NO_POS_COOLDOWN = 60
-- A previous sweep older than this is not evidence of having been watching.
local SWEEP_FRESH = 60

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

-- The Spectral Battle Chest on the ground, per zone. Kept apart from liveCrate
-- because the two share nothing: no stages, no transport, no descent. Declared
-- here because Scanner.ActiveZones reads it a few lines below, and a local read
-- above its own declaration is a nil global -- which is how this shipped once.
local liveSpectral = {}

-- Stop showing a crate nobody has seen for this long while standing in its
-- zone. It has been taken, or it was never really there.
local LIVE_STALE = 90

-- How long a crate must go unseen, while the player stands in its zone, before
-- it counts as gone rather than as one quiet sweep.
local GONE_GRACE = 15

-- Is a transport being tracked here right now? A crate that has not been
-- released yet is still something happening in the zone, and the window has
-- nothing else to learn it from.
function Scanner.HasTransport(zoneID)
    return tracks[zoneID] ~= nil
end

-- Every zone with something going on: a transport up, or a crate falling or
-- down. The window needs this to give such a zone a row even when it has no
-- timer at all -- which is exactly the case when you fly somewhere new, or
-- back into a zone on a shard you have not seen.
function Scanner.ActiveZones()
    local out = {}
    for zoneID in pairs(tracks) do out[zoneID] = true end
    for zoneID in pairs(liveCrate) do
        if Scanner.LiveCrate(zoneID) then out[zoneID] = true end
    end
    -- A chest with no crate timer beside it still earns the zone a row. It
    -- lasts a minute or two, so a row that appears only once something else
    -- happens to be timed there would miss most of them.
    for zoneID in pairs(liveSpectral) do
        if Scanner.Spectral(zoneID) then out[zoneID] = true end
    end
    return out
end

-- The Spectral Battle Chest on the ground in this zone, or nil.
--
-- A short grace, unlike a crate's: this vignette is drawn zone-wide rather
-- than by proximity, so it not being there is a real answer rather than the
-- player having flown out of range.
function Scanner.Spectral(zoneID)
    local live = liveSpectral[zoneID]
    if not live then return nil end
    if GetServerTime() - (live.seen or 0) > GONE_GRACE then
        liveSpectral[zoneID] = nil
        return nil
    end
    return live
end

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
-- Coordinates from one map, expressed in another's space.
--
-- A position comes back in the space of whatever map it was asked about, and
-- everything downstream -- the catalogue, the prediction, the waypoint --
-- speaks zone-map space. Standing in The Den, a sub-zone of Harandar, the two
-- are wildly different, so a fallback reading handed straight on puts the
-- crate somewhere it is not. Round-tripping through world coordinates is the
-- only honest conversion.
local function toZoneSpace(pos, fromMap, zoneID)
    if not pos or not fromMap or not zoneID or fromMap == zoneID then return pos end
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, fromMap, pos)
    if not ok or not continent or not world then return nil end
    local ok2, _, zonePos = pcall(C_Map.GetMapPosFromWorldPos, continent, world, zoneID)
    if not ok2 then return nil end
    return zonePos
end

-- Returns the position and the map it is expressed in. A caller that speaks
-- zone-map space must check the second value; the scan command is the only one
-- that may show a reading from anywhere else, because it prints which map.
local function vignettePosition(guid, zoneID, rawMap)
    if zoneID then
        local pos = C_VignetteInfo.GetVignettePosition(guid, zoneID)
        if pos then return pos, zoneID end
    end
    if rawMap and rawMap ~= zoneID then
        local pos = C_VignetteInfo.GetVignettePosition(guid, rawMap)
        if pos then
            local moved = toZoneSpace(pos, rawMap, zoneID)
            if moved then return moved, zoneID end
            return pos, rawMap
        end
    end
    return nil
end
Scanner.VignettePosition = vignettePosition

-- How far the player stood from a landing, in percent of map. nil when the
-- game will not say where the player is, which it does during a loading
-- screen. Declared here because the lint rule refuses a call to a local
-- defined below its use, which is a bug this addon has already shipped once.
local function distanceFromPlayer(zoneID, pos)
    if not pos then return nil end
    local ok, me = pcall(C_Map.GetPlayerMapPosition, zoneID, "player")
    if not ok or not me then return nil end
    local px, py = me:GetXY()
    if not px or not py then return nil end
    local dx, dy = px - pos.x, py - pos.y
    return math.sqrt(dx * dx + dy * dy) * 100
end

-- Which shard this client is standing in, per zone.
--
-- Needed because the announcer's chat event carries no GUID at all -- not a
-- secret string, nil -- so the one thing that would have given the shard for
-- free is not there. Confirmed live: "shard=nil from guid nil".
--
-- A creature GUID and a crate vignette GUID give the SAME number. That was
-- doubted for an hour on 20 Sep, on the strength of Voidstorm holding 68, 69
-- and 207300 at once, and /ewc shard settled it: a creature said 207300 and
-- the crate vignette beside it said 207300. The three rows were three visits,
-- not three namespaces, and the shard re-rolling between them is what Prune
-- exists for. Recording which source a number came from is kept anyway,
-- because it is what made the question answerable.
--
-- Held with a timestamp because the shard re-rolls when you leave and come
-- back, and one remembered from the last visit would anchor a timer to a copy
-- of the zone nobody is standing in.
-- When this client's own faction was last seen to claim a crate in a zone.
--
-- The game draws only your own side's claimed marker, so the marker appearing
-- means your side took it, and the marker never appearing means the other side
-- did. The second half is the useful one: without it a crate taken by the
-- enemy simply vanishes, and the window goes on saying ON THE GROUND to
-- somebody who would cross a zone for it.
local claimedByUs = {}
local CLAIM_MEMORY = 120

local shardSeen = {}
local SHARD_FRESH = 300

-- When this zone was last observed to be a different copy of itself. A
-- measurement that spans a re-shard is not a measurement of one crate.
local shardChangedAt = {}

-- Standing in a shard this client has stood in before, with no timer for it.
--
-- The cycle is period-locked, so an anchor from that shard still says where
-- its cycle sits -- and Prune had been deleting exactly that for legibility,
-- leaving the addon blind in zones it had already learned. Recall refuses once
-- the extrapolation has drifted past being worth showing.
local function restoreFromMemory(zoneID, shardID, stamp)
    local db = ns.db
    if not db or not db.phase then return end
    if ns.Timers.Get(db.crates, zoneID, shardID) then return end

    local interval = ns.GetZoneInterval(zoneID)
    local drift = ns.Phase.Drift(db.gaps, zoneID, ns.Timers.GapCluster)
    local ts, why, cycles, err = ns.Phase.Recall(db.phase, zoneID, shardID,
        interval, stamp, drift)
    if not ts then
        if why == "drifted too far" then
            ns.Debug(("%s shard %s was known, but %d cycles of drift puts it %ds out")
                :format(ns.GetZoneAbbr(zoneID), tostring(shardID), cycles, err))
        end
        return
    end

    local verdict = ns.Timers.Record(db.crates, zoneID, shardID, ts, "memory")
    if verdict == "new" or verdict == "refined" then
        ns.Print(("%s |cffffffffshard %s|r -- |cff33ff99seen before|r"
            .. " |cff777777(its cycle recalled across %d, give or take %ds)|r"):format(
            ns.GetZoneName(zoneID), tostring(shardID), cycles, math.floor(err + 0.5)))
        if ns.RefreshWindow then ns.RefreshWindow() end
    end
end

local function noteShard(zoneID, shard, stamp, from)
    if not zoneID or not shard then return end
    shardSeen[zoneID] = shardSeen[zoneID] or {}
    local was = shardSeen[zoneID][from]
    if was and was.shard ~= shard then shardChangedAt[zoneID] = stamp end
    shardSeen[zoneID][from] = { shard = shard, at = stamp }

    -- Only when the answer is new: this runs on every sweep otherwise.
    if not was or was.shard ~= shard then
        restoreFromMemory(zoneID, shard, stamp)
    end
end

-- Whether this client has been in THIS copy of the zone long enough for a fall
-- to have started in front of it.
--
-- Vignettes with an id this addon does not know, filed as they appear.
--
-- Read rather than guessed, which is the same reason /ewc scan exists: a new
-- object's zones, its cycle and whether it has more than one id are all things
-- an evening of sightings answers and no amount of reasoning does.
--
-- Deduplicated by GUID, because a vignette stays drawn for minutes and every
-- poll would otherwise count as another spawn. The shard rides along with each
-- sighting so an interval can be paired within one copy of a zone.
local STRANGER_IDS, STRANGER_SEEN = 30, 16
local strangerGUID = {}

local function noteStranger(info, guid, zoneID, pos, stamp)
    local held = ns.db and ns.db.strangers
    if not held or not zoneID or not info or not info.vignetteID then return end
    if strangerGUID[guid] then return end
    strangerGUID[guid] = stamp

    local rec = held[info.vignetteID]
    if not rec then
        local kinds = 0
        for _ in pairs(held) do kinds = kinds + 1 end
        if kinds >= STRANGER_IDS then return end
        rec = { n = 0, first = stamp, zones = {} }
        held[info.vignetteID] = rec
    end
    rec.name = info.name or rec.name
    rec.atlas = info.atlasName or rec.atlas
    rec.n, rec.last = rec.n + 1, stamp

    local where = rec.zones[zoneID]
    if not where then where = { n = 0, seen = {} }; rec.zones[zoneID] = where end
    where.n = where.n + 1
    -- Only a position that resolved on this zone's own map, the same guard the
    -- crate path uses: a vignette can report against a different map and the
    -- coordinates then point somewhere the player is not.
    if pos then where.x, where.y = pos.x, pos.y else where.noPos = (where.noPos or 0) + 1 end
    where.seen[#where.seen + 1] = { at = stamp, shard = ns.Shard.FromVignetteGUID(guid) }
    while #where.seen > STRANGER_SEEN do table.remove(where.seen, 1) end
end

-- The watch that decides whether a parachute was caught from the start is kept
-- per zone, while the reading it guards is keyed per zone AND shard. Re-shard
-- in the middle of a fall and the key is new, so "this parachute was not there
-- a moment ago" is trivially true -- the key was not there a moment ago -- and
-- a fall that was half over is recorded as though it were watched throughout.
--
-- That is the last explanation standing for the short readings. It is not the
-- drop point: Zul'Aman measured 85s and 44s at one spot. It is not the
-- distance: Eversong measured 87s from 17.2% of the map away on 20 Sep, which
-- killed that idea outright. It is not the overlap flag, which is set on 31
-- readings out of 33. Re-sharding fits what is left, and Voidstorm went
-- through three shards in one evening.
local function reshardedRecently(zoneID, stamp)
    local changed = shardChangedAt[zoneID]
    return changed ~= nil and (stamp - changed) < MIN_WATCH
end

local function heldShard(zoneID, from, now)
    local held = shardSeen[zoneID] and shardSeen[zoneID][from]
    if not held then return nil end
    if (now or stampClock()) - held.at > SHARD_FRESH then return nil end
    return held.shard
end

-- The freshest of the two, since they agree. A crate vignette is the more
-- direct evidence when there is one; a creature is what there is at the moment
-- a cycle is announced, before any vignette exists.
function Scanner.CurrentShard(zoneID, now)
    now = now or stampClock()
    local seen = shardSeen[zoneID]
    if not seen then return nil end
    local best
    for _, held in pairs(seen) do
        if (now - held.at) <= SHARD_FRESH and (not best or held.at > best.at) then
            best = held
        end
    end
    return best and best.shard or nil
end

function Scanner.UnitShard(zoneID, now)
    return heldShard(zoneID, "unit", now)
end

-- Read every creature already on screen, rather than waiting to be told about
-- a new one.
--
-- Asking the game to pick a target would be the obvious way and is not
-- available: TargetNearestEnemy and its relatives are protected and run only
-- from a keypress, so an addon calling one gets ADDON_ACTION_BLOCKED. Nothing
-- here needs it. Nameplates are already in memory and reading them is free.
--
-- This exists for the case the events cannot cover: right after a reload the
-- plates are up but NAME_PLATE_UNIT_ADDED fired before this addon loaded, so
-- nothing would arrive until something new wandered past. An announcer spoke
-- into exactly that gap on 20 Sep and could not be timed.
local function sweepForShard(zoneID, stamp)
    if not zoneID then return nil end
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()
    for _, plate in ipairs(plates or {}) do
        local token = plate and plate.namePlateUnitToken
        local shard = token and ns.Shard.FromGUID(UnitGUID(token))
        if shard then
            noteShard(zoneID, shard, stamp, "unit")
            return shard
        end
    end
    -- A pet is a creature too, and so is whatever happens to be targeted.
    for _, unit in ipairs({ "target", "mouseover", "pet", "focus" }) do
        local shard = ns.Shard.FromGUID(UnitGUID(unit))
        if shard then
            noteShard(zoneID, shard, stamp, "unit")
            return shard
        end
    end
    return nil
end

local function noteShardFromUnit(unit)
    local zoneID = ns.Zones.Normalize(playerMapID())
    if not zoneID then return end
    local stamp = stampClock()
    local held = shardSeen[zoneID] and shardSeen[zoneID].unit
    if held and (stamp - held.at) < 30 then return end
    local shard = ns.Shard.FromGUID(UnitGUID(unit))
    if shard then noteShard(zoneID, shard, stamp, "unit") end
end

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
    arrivedAt = {}
    partialFall = {}
    partialWhy = {}
    releaseLag = {}
    fallAtlas, atlasFlip = {}, {}
    strangerGUID = {}
    liveSpectral = {}
    lastSweptStamp, lastFalling = {}, {}
    noPosWarned = {}
    zoneWatchSince = {}
    -- Both, and forgetting the shard itself is the point. Reset runs on a zone
    -- change, and entering a zone re-shards you, so the first reading back in
    -- a zone you had been in before differed from the remembered one and was
    -- filed as the shard moving under you. It had not moved, you had.
    --
    -- That mistake cost real measurements: thirteen descent readings refused
    -- on 24 Sep for a re-shard, eight of them squarely in the 83 to 94 band
    -- every zone agrees on. The guard is meant for a shard changing while you
    -- stand still, which this keeps it to.
    shardSeen = {}
    shardChangedAt = {}
    claimedByUs = {}
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
            local pos, posMap = vignettePosition(tr.guid, trackZone, rawMap)
            if pos and posMap == trackZone then
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
                -- Same condition, opposite meanings. A track that has fitted
                -- before and stopped covering ground has arrived and is
                -- circling; one that never has is simply still gathering its
                -- first few readings, and calling that "circling its drop
                -- point" two seconds after the plane appears is wrong.
                state = "still:" .. tostring(tr.everFit)
                line = tr.everFit
                    and ("|cff777777%d samples, but it has stopped moving -- circling its drop point|r"):format(n)
                    or ("|cff777777tracking|r %d samples, not far enough yet to read a heading"):format(n)
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
            local c = r.aim or r.best
            local where = c and ("%.1f,%.1f"):format(c.spot.x * 100, c.spot.y * 100) or "-"
            -- The sample count belongs in the line, not in the key. It moves
            -- every tick as readings roll through the window, so including it
            -- made every resample look like a new decision: one ambiguous
            -- track narrated sixty identical lines in a minute on 24 Sep.
            state = ("%s:%s"):format(r.ok and "ok" or tostring(r.reason), where)
            line = ("|cff777777n=%d span=%.1fs err=%.2fdeg p=%d%%|r  %s -> %s"):format(
                fit.n, fit.span, math.deg(fit.err), math.floor((r.p or 0) * 100 + 0.5),
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
-- Whatever is known about the transport in this zone, or nil if there is none.
--
-- Returning nil for a track that has no usable heading conflated two different
-- things and the window said "no transport in the air" while one was plainly
-- in it. A heading is missing for the first few seconds after a transport
-- appears and again once it reaches its drop point and starts circling --
-- which is the beginning and the end of every flight, and both are moments
-- someone looks at the window.
function Scanner.Prediction(zoneID)
    local tr = tracks[zoneID]
    if not tr then return nil end

    local fit, why = tr.track:Fit()
    local r = fit and ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
        or { ok = false, reason = why == "still" and "not-moving" or "gathering" }
    r.fit, r.committed, r.arrived, r.aimed = fit, tr.committed, tr.arrived, tr.aim
    r.samples = tr.track:Count()
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

    -- A crate that stopped being drawn while you were standing in its zone,
    -- without anybody being seen to take it.
    --
    -- Dmitrii watched one land in Slayer's Rise, flew over, and found nothing
    -- there. Two very different things look identical from a distance:
    -- somebody looted it, which is ordinary, and the zone re-shard under him,
    -- which means the crate is still there in a copy he is no longer in. The
    -- claimed vignette separates them, and its absence is the interesting
    -- case. Only reported for the zone the player is actually in, because
    -- flying out of range of a crate is not news.
    -- Noticed sooner than LIVE_STALE would, because a crate that vanished is
    -- news while the player is still standing where it was, and because a
    -- reading of how long it lingered is worthless if it cannot be taken until
    -- ninety seconds after the fact. Long enough that one sweep missing a
    -- vignette does not count as it going away.
    -- Two graces, because the vignette going away means different things.
    --
    -- A crate nobody claimed: gone quickly, because the window saying ON THE
    -- GROUND at somebody about to cross a zone is the expensive mistake.
    --
    -- A crate our own side claimed: given the long grace, because the marker
    -- stops being drawn before the crate stops being lootable -- Dmitrii
    -- watched the row vanish while he was still standing in the zone with it
    -- in front of him. Whether the marker tracks lootability at all is what
    -- the linger readings are being collected to answer.
    local lost = liveCrate[zoneID]
    local grace = (lost and lost.mine) and LIVE_STALE or GONE_GRACE
    if lost and lost.phase == "ground" and (stamp - (lost.seen or 0)) > grace then
        liveCrate[zoneID] = nil
        local moved = shardChangedAt[zoneID]
            and (stamp - shardChangedAt[zoneID]) < LIVE_STALE * 2
        -- How long it stayed after our side claimed it. Nobody has measured
        -- this, so it is collected before it is ever shown.
        --
        -- Dated from the last sighting throughout, and that "throughout" is
        -- the fix. The grace above is this client waiting, not the crate lying
        -- there, and asking from now instead cost this store every reading it
        -- was built to hold: a claimed crate is not believed gone for
        -- LIVE_STALE (90s) and the claim was only allowed to be CLAIM_MEMORY
        -- (120s) old, so a marker had to vanish within thirty seconds of the
        -- claim to count at all -- while whether it outlasts the claim is the
        -- entire question. Empty for days, and nothing said so.
        local lingered = claimedByUs[zoneID] and ((lost.seen or stamp) - claimedByUs[zoneID])
        local ours = lingered ~= nil and lingered < CLAIM_MEMORY
        if ours then
            if ns.Airtime.NoteLinger(db.linger, zoneID, lingered) then
                ns.Debug(("claimed crate in %s lasted %ds"):format(
                    ns.GetZoneAbbr(zoneID), math.floor(lingered + 0.5)))
            end
        end
        -- No claim of our own drawn and the zone did not move: what is left is
        -- the other side taking it. That is the case worth naming, because it
        -- is the one where the window would otherwise go on saying ON THE
        -- GROUND to somebody about to cross a zone for nothing.
        local why = moved and "|cffff5555this zone re-sharded under you|r"
            or ours and "your side had already claimed it"
            or "|cffff8800no claim of ours was drawn, so the other side took it|r"
        ns.Print(("|cffff8800the crate in %s is no longer there|r |cff777777-- %s|r"):format(
            ns.GetZoneName(zoneID), why))
    end

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

    local prevSweep, prevFalling = lastSweptStamp[zoneID], lastFalling[zoneID] or {}
    if not prevSweep then zoneWatchSince[zoneID] = stamp end
    lastSweptStamp[zoneID], lastFalling[zoneID] = stamp, fallingNow

    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)

        -- Any vignette at all gives the shard, not only a crate's. A rare
        -- elite standing about is the difference between knowing which copy of
        -- the zone this is and having to ask the player to mouse over
        -- something. Voidstorm's elites read 207300 beside a creature GUID
        -- saying 207300, so they are the same number.
        --
        -- This matters most right after a reload with nothing targeted and no
        -- nameplates up, which is exactly when an announcer spoke on 20 Sep
        -- and could not be timed.
        if info then
            local anyShard = ns.Shard.FromVignetteGUID(guid)
            if anyShard then noteShard(zoneID, anyShard, stamp, "vignette") end
        end

        local stage = info and ns.VignetteStage(info.vignetteID)
        if info and not stage then
            local sPos, sMap = vignettePosition(guid, zoneID, rawMap)
            local usablePos = sMap == zoneID and sPos or nil
            -- Filed whether or not it is recognised: the record is what
            -- measures its cycle, and being able to draw a marker for it is no
            -- reason to stop learning when it comes back.
            noteStranger(info, guid, zoneID, usablePos, stamp)
            if ns.IsSpectral(info.vignetteID) then
                local live = liveSpectral[zoneID] or { zoneID = zoneID, since = stamp }
                live.seen, live.shard = stamp, ns.Shard.FromVignetteGUID(guid) or live.shard
                if usablePos then live.x, live.y = usablePos.x, usablePos.y end
                if not liveSpectral[zoneID] then
                    ns.Print(("|cffcc88ff%s -- %s on the ground|r%s"):format(
                        ns.GetZoneName(zoneID), tostring(info.name or "spectral chest"),
                        usablePos and (" |cffffd100at %.1f, %.1f|r"):format(
                            usablePos.x * 100, usablePos.y * 100) or ""))
                end
                liveSpectral[zoneID] = live
            end
        end
        if stage then
            local pos, posMap = vignettePosition(guid, zoneID, rawMap)
            local usable = pos and posMap == zoneID
            if not usable and (tNow - (noPosWarned[zoneID] or -math.huge)) > NO_POS_COOLDOWN then
                noPosWarned[zoneID] = tNow
                ns.Print(("|cffff8800a %s crate in %s has no position on the zone map|r"
                    .. " |cff777777-- not tracking it; /ewc scan for detail|r"):format(
                    stage, ns.GetZoneName(zoneID)))
            end
            if usable then
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
                            -- Ours, by the only premise that explains seeing
                            -- the marker at all. Read off the player rather
                            -- than off which of the two ids arrived: that
                            -- mapping is a guess and has been contradicted.
                            local okF, mine = pcall(UnitFactionGroup, "player")
                            local side = (okF and type(mine) == "string" and mine ~= "")
                                and mine or "your side"
                            claimedByUs[zoneID] = stamp

                            -- Not gone. The marker flags which side captured
                            -- it, and a crate captured by your own side is
                            -- still there to be looted -- Dmitrii watching it
                            -- happen, and WarCratePredict saying the same:
                            -- the atlas can show while the crate is on the
                            -- ground, which is why their claim used to fire
                            -- at drop time. Clearing the row here told the
                            -- player it was over while they could still go
                            -- and take it.
                            local live = liveCrate[zoneID] or { zoneID = zoneID }
                            if not live.mine then
                                ns.Print(("|cff33ff99the crate in %s is %s|r"
                                    .. " |cff777777-- still there to take|r"):format(
                                    ns.GetZoneName(zoneID), side .. "'s"))
                            end
                            live.mine, live.seen = true, stamp
                            live.claimedAt = live.claimedAt or stamp
                            live.shard = live.shard or shard
                            live.phase = live.phase or "ground"
                            live.groundAt = live.groundAt or stamp
                            live.x, live.y = pos.x, pos.y
                            liveCrate[zoneID] = live
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
                            if not fallingSince[key] then
                                -- We watched this fall begin only if we had
                                -- already swept this zone recently and this
                                -- parachute was not in it then.
                                --
                                -- Two earlier tests failed here. "Is a track
                                -- open in this zone" counted a fragment as a
                                -- whole fall, because a transport keeps
                                -- circling after it drops and someone flying
                                -- in mid-fall opens a fresh track on it. "Did
                                -- that track reach its drop point" then threw
                                -- away perfectly good readings, including
                                -- Voidstorm's 86s -- the most accurate figure
                                -- in the set -- because arrival needs a live
                                -- heading fit and a transport circling its
                                -- point has no baseline to fit.
                                -- Watching the transport reach its point is
                                -- the only unambiguous evidence, because it is
                                -- the moment the crate was let go.
                                --
                                -- Failing that, a parachute that was not there
                                -- a moment ago MIGHT have just appeared, or
                                -- might have drifted into vignette range -- the
                                -- two look identical. Only a watch longer than
                                -- any possible fall tells them apart, and even
                                -- then only because the player has not moved.
                                -- Why a reading was refused, kept because
                                -- three different things refuse one and they
                                -- are not equally likely to be right. A fall
                                -- watched from three tenths of a percent away
                                -- came back flagged, and nothing recorded
                                -- which of the three had done it.
                                local sawItStart, refusedBy
                                local arrived = arrivedAt[zoneID]
                                if reshardedRecently(zoneID, stamp) then
                                    -- A different copy of the zone since this
                                    -- fall could have begun. Whatever is under
                                    -- this parachute, we did not watch it go.
                                    refusedBy = "the zone re-sharded"
                                    sawItStart = false
                                elseif arrived and (stamp - arrived) <= ARRIVED_RECENT then
                                    sawItStart = true
                                elseif prevSweep and (stamp - prevSweep) <= SWEEP_FRESH
                                    and not prevFalling[key]
                                    and zoneWatchSince[zoneID]
                                    and (stamp - zoneWatchSince[zoneID]) >= MIN_WATCH then
                                    sawItStart = true
                                end
                                if not sawItStart and not refusedBy then
                                    refusedBy = (arrived and "the arrival was too long ago")
                                        or (not prevSweep and "nothing had been swept yet")
                                        or (prevFalling[key] and "the parachute was already up")
                                        or "the zone had not been watched long enough"
                                end
                                fallingSince[key] = stamp
                                partialFall[key] = not sawItStart or nil
                                partialWhy[key] = refusedBy

                                -- The first leg, timed rather than computed.
                                -- Only an announcement is really the spawn;
                                -- catching the transport in the air says when
                                -- it came into range, which is a lower bound
                                -- by however long it had already been flying.
                                local anchor = ns.Timers.Get(db.crates, zoneID, shard)
                                if anchor and anchor.ts then
                                    ns.Airtime.NoteFlight(db.flight, zoneID,
                                        stamp - anchor.ts, anchor.source ~= "yell")
                                end
                                releaseLag[key] = sawItStart and arrivedAt[zoneID]
                                    and (stamp - arrivedAt[zoneID]) or nil
                                fallAtlas[key] = info.atlasName
                            elseif fallAtlas[key] and not atlasFlip[key]
                                and info.atlasName and info.atlasName ~= fallAtlas[key] then
                                atlasFlip[key] = stamp
                            end
                        elseif stage == "ground" and fallingSince[key] then
                            local secs = stamp - fallingSince[key]
                            local flip = atlasFlip[key] and (atlasFlip[key] - fallingSince[key]) or nil
                            fallingSince[key] = nil
                            local overlapped, partial = fallingNow[key], partialFall[key]
                            local why = partialWhy[key]
                            partialWhy[key] = nil
                            local lag = releaseLag[key]
                            partialFall[key], releaseLag[key] = nil, nil
                            partialWhy[key] = nil
                            fallAtlas[key], atlasFlip[key] = nil, nil
                            local dist = distanceFromPlayer(zoneID, pos)
                            if secs <= DESCENT_PAIR_MAX
                                and ns.Airtime.NoteDescent(db.descent, zoneID, secs, {
                                    overlapped = overlapped, partial = partial,
                                    pos = pos, lag = lag, flip = flip, dist = dist,
                                    why = why,
                                }) then
                                ns.OnDescentMeasured(zoneID, secs, partial, dist)
                            end
                        elseif stage == "claimed" then
                            fallingSince[key], partialFall[key] = nil, nil
                            releaseLag[key], fallAtlas[key], atlasFlip[key] = nil, nil, nil
                        end

                        -- A parachute we joined partway through anchors the
                        -- timer no better than finding the crate on the ground.
                        local source = (stage == "falling" and partialFall[key])
                            and "midfall" or stage

                        -- A crate already lying there spawned a flight and a
                        -- fall ago. Dating it to the moment it was noticed is
                        -- two and a half minutes late for nothing; both legs
                        -- are measured, so the known part of that error comes
                        -- off. What is left is how long it lay there, which is
                        -- why the reading is still not called precise.
                        local anchorAt, backdated = stamp, nil
                        if ns.LANDED_STAGE[stage] then
                            backdated = ns.Airtime.SpawnOffset(db.flight, db.descent, zoneID)
                            if backdated then anchorAt = stamp - backdated end
                        end

                        local verdict, _, gap =
                            ns.Timers.Record(db.crates, zoneID, shard, anchorAt, source)
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
                        ns.OnCrateSighted(zoneID, shard, stage, pos, verdict, backdated)
                    end
                end
            end
        end
    end
end

-- Decides whether this track has become worth telling the player about.
function Scanner.Evaluate(zoneID, tr)
    local fit, why = tr.track:Fit()
    if not fit then
        -- No baseline is not the same as no information. A transport that has
        -- stopped covering ground has reached its drop point and is circling
        -- it, which is the exact case of flying into a zone and finding one
        -- already orbiting: the addon had six samples of it and said only
        -- "not far enough yet to read a heading" while the answer was directly
        -- underneath.
        if why == "still" and not tr.committed then
            local cx, cy = tr.track:Centre()
            local r = cx and ns.Predict.Hovering(ns.GetDropPoints(zoneID), cx, cy)
            if r and r.ok then
                tr.committed = { x = r.spot.x, y = r.spot.y }
                ns.OnHovering(zoneID, r.spot, r.distance)
            end
        end
        return
    end

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
                arrivedAt[zoneID] = GetServerTime()
                ns.OnTransportArrived(zoneID, tr.committed)
            end
        end
        return
    end

    -- A leader that is not yet firm is still the best answer there is, and
    -- holding it back is expensive. A Zul'Aman flight had the correct spot in
    -- first place from its fifth sample and said nothing for 62 seconds,
    -- because the only thing that ever separated it from a rival 7% short on
    -- the same line was the transport physically flying past that rival --
    -- twenty seconds before the drop. The answer is given as soon as there is
    -- one, redrawn if the evidence moves it, and settled when it goes firm.
    local result = ns.Predict.Evaluate(ns.GetDropPoints(zoneID), fit)
    if not result.leading then return end

    local spot = result.aim.spot
    local moved = not (tr.aim and tr.aim.x == spot.x and tr.aim.y == spot.y)
    if result.ok then tr.committed = { x = spot.x, y = spot.y } end
    if moved or result.ok then
        tr.aim = { x = spot.x, y = spot.y }
        ns.OnPrediction(zoneID, result, fit)
    end
end

-- An NPC announcing the cycle. Data/Announcers.lua decides what counts.
--
-- The shard comes from the speaker's own GUID, which the chat event hands over
-- as its twelfth argument. RCT and WarCratePredict both reach instead for a
-- shard they read off a mouseover or a nameplate, and WarCratePredict wrote
-- down what that cost: a mob GUID is a different namespace from the crate
-- vignette's, and gating on it left Zul'Aman eight minutes out. The announcer
-- is a creature standing in the same copy of the zone as the crate, so its own
-- GUID is the answer with nothing to reconcile.
local heard = {}
Scanner.heard = heard
local HEARD_MAX = 6

function Scanner.OnAnnouncement(text, npcName, guid)
    local db = ns.db
    if not db or not db.enabled then return end
    if IsInInstance() then return end
    -- Kept to lines from a known announcer. Everything else in the zone is
    -- chatter, and a log of it would bury the one line worth reading.
    if not ns.IsAnnouncer(npcName) then return end

    local zoneID = ns.Zones.Normalize(playerMapID())
    local matched = ns.IsSpawnAnnouncement(npcName, text)
    local stamp = stampClock()

    -- The raw GUID is kept because the shard has to be read out of it and the
    -- first live announcement produced none. Whatever the game really sends is
    -- the only thing that can explain that, and it is not worth waiting for
    -- another cycle to find out.
    local note = { npc = npcName, text = text, matched = matched, guid = ns.Shard.Label(guid),
                   zoneID = zoneID, at = stamp }
    table.insert(heard, 1, note)
    while #heard > HEARD_MAX do table.remove(heard) end

    if not zoneID then return end
    if not matched then
        -- A known announcer whose wording is not in the list. Either an idle
        -- line or a phrasing nobody has catalogued, and only one of those is a
        -- bug -- which is why it is recorded instead of anchoring.
        return ns.Debug(("%s said something unrecognised in %s -- /ewc yells"):format(
            npcName, ns.GetZoneName(zoneID)))
    end

    -- The speaker's own GUID first, which would be exact. It has been nil on
    -- every announcement seen so far, so the shard this client is standing in
    -- is the working answer: the announcer is in the zone with the player.
    -- The speaker's own GUID would be exact, and has been nil every time, so
    -- the shard this client is standing in is the answer: the announcer is in
    -- the zone with the player.
    local shard = ns.Shard.FromGUID(guid)
        or Scanner.CurrentShard(zoneID, stamp)
        or sweepForShard(zoneID, stamp)
    note.shard = shard
    if not shard then
        return ns.Print(("|cffff8800%s announced a crate in %s, but nothing here will say"
            .. " which shard it is|r |cff777777-- not timed; no vignette, no nameplate,"
            .. " nothing targeted|r"):format(npcName, ns.GetZoneName(zoneID)))
    end

    -- Set only once the timer has actually moved. Reporting the phrase match
    -- as an anchor told the player a crate had been timed when none had.
    note.anchored = true
    local verdict, _, gap = ns.Timers.Record(db.crates, zoneID, shard, stamp, "yell")
    if gap then
        local noted = ns.Timers.NoteGap(db.gaps, zoneID, gap, ns.GetZoneInterval(zoneID))
        if noted then ns.OnGapObserved(zoneID, shard, noted) end
    end
    ns.OnSpawnAnnounced(zoneID, shard, npcName, verdict)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("VIGNETTES_UPDATED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Say is what the announcers have been observed using and is all RCT listens
-- for. Yell costs one line and covers the same NPC raising its voice.
frame:RegisterEvent("CHAT_MSG_MONSTER_SAY")
frame:RegisterEvent("CHAT_MSG_MONSTER_YELL")
-- Three ways to be handed a creature GUID without asking the player for
-- anything. Nameplates alone cover a populated zone; the other two cover
-- standing somewhere empty with one thing targeted.
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "VIGNETTES_UPDATED" then
        Scanner.OnVignettesUpdated()
    elseif event == "CHAT_MSG_MONSTER_SAY" or event == "CHAT_MSG_MONSTER_YELL" then
        local text, npcName = ...
        Scanner.OnAnnouncement(text, npcName, select(12, ...))
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        noteShardFromUnit(...)
    elseif event == "PLAYER_TARGET_CHANGED" then
        noteShardFromUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        noteShardFromUnit("mouseover")
    else
        Scanner.Reset()
        -- Entering a zone re-shards you, so whatever was known is now wrong.
        -- Read the plates already on screen rather than waiting for one to
        -- wander past.
        local zoneID = ns.Zones.Normalize(playerMapID())
        if zoneID then sweepForShard(zoneID, stampClock()) end
    end
end)

Scanner.frame = frame
