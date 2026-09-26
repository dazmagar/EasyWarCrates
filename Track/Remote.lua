local ADDON, ns = ...

-- Sightings other players reported, from this session only.
--
-- Kept apart from db.crates on purpose, and this is the whole complaint
-- against RCT: it takes every sighting from every group and guild member into
-- its saved database and never cleans it, so an evening leaves a wall of rows
-- for shards nobody will stand in again. Here a report lives while the raid
-- does, carries who sent it, and never reaches disk.
--
-- One report moves into db.crates, at one moment: when this client confirms
-- the crate itself. Promote is what does it, and the reason is not sentiment.
-- A scout who caught the transport in the air holds a precision-3 anchor; this
-- client arriving to a crate already on the ground sees `ground`, precision 1.
-- Discarding the scout's reading at the moment it paid off trades a good
-- measurement for a poor one.
--
-- Pure table maths, so tests/ covers it.

local Remote = {}
ns.Remote = Remote

-- How long a report of each stage is worth acting on. A crate on the ground is
-- somebody else's within a couple of minutes; a transport still in the air has
-- its flight and the fall ahead of it.
-- anchor is not a sighting. It is "a crate spawned in this zone and shard at
-- this time", which is what HGLog shares, with nothing said about how well the
-- sender knew it. It lives about one cycle, because past that it describes a
-- drop that has already been and gone.
-- here is not a crate at all. It is a player saying which copy of a zone they
-- are standing in, which is the one thing nobody can find out about a zone
-- they are not in. A stored timer is only worth flying to if the shard it was
-- learned on is the shard the raid will land in, and a scout already sitting
-- there is the only source for that before you arrive.
--
-- Lives as long as somebody plausibly stays put. They re-shard when they leave
-- and come back, so it is not worth more than that.
-- ground was three minutes and that was far too generous. A raid takes a crate
-- within seconds of it landing, nobody retracts a sighting, and the cost of
-- being wrong falls entirely on whoever reads it: they cross a zone and find
-- nothing. Ninety seconds is still longer than most crates last.
local LIFETIME = { flying = 240, falling = 200, ground = 90, claimed = 90,
                   anchor = 1200, here = 900 }
Remote.LIFETIME = LIFETIME

-- Matches Model.LiveFor, because both feed the same sorted list and two
-- orderings would put a remote parachute above a local one or below it
-- depending on which built the row.
local RANK = { ground = 1, falling = 2, flying = 3 }
Remote.RANK = RANK

-- How far through its life a crate is, lower being further along. Ranking is
-- about urgency and this is about time, and they are not the same order:
-- claimed is the least urgent thing there is and the furthest along.
local ADVANCE = { claimed = 0, ground = 1, falling = 2, flying = 3, anchor = 4 }
Remote.ADVANCE = ADVANCE

-- A clock this far out of step is not a late message, it is a client whose
-- time is wrong, and its timestamps would poison every timer they touch.
local FUTURE_SLACK = 60
Remote.FUTURE_SLACK = FUTURE_SLACK

function Remote.New()
    return {}
end

-- report: zoneID, shardID, stage, at, from, and optionally x, y and via.
-- Returns "new" | "refresh" | "stale" | "invalid".
function Remote.Note(store, report, now)
    if type(store) ~= "table" or type(report) ~= "table" then return "invalid" end

    local zoneID = tonumber(report.zoneID)
    local at = tonumber(report.at)
    local stage = report.stage
    if not zoneID or not ns.ZONES[zoneID] then return "invalid" end
    if report.shardID == nil or not at or not LIFETIME[stage] then return "invalid" end
    if type(report.from) ~= "string" or report.from == "" then return "invalid" end

    now = tonumber(now) or 0
    if at > now + FUTURE_SLACK then return "invalid" end
    if (now - at) > LIFETIME[stage] then return "stale" end

    local shardID = report.shardID
    store[zoneID] = store[zoneID] or {}
    local held = store[zoneID][shardID]
    if held and held.at >= at then return "stale" end

    store[zoneID][shardID] = {
        stage = stage,
        at    = at,
        from  = report.from,
        via   = report.via,
        leader = report.leader or nil,
        x     = tonumber(report.x),
        y     = tonumber(report.y),
        -- Carried across a replacement: the raid acting on the first report is
        -- what promotion answers, and the crate progressing from parachute to
        -- ground must not hand it a second bite.
        promoted = held and held.promoted or nil,
    }
    return held and "refresh" or "new", store[zoneID][shardID]
end

local function alive(entry, now)
    return entry and (now - entry.at) <= (LIFETIME[entry.stage] or 0)
end

-- The report worth showing for a zone: the most urgent still alive, and the
-- freshest among equals. nil when nobody has said anything recent.
function Remote.For(store, zoneID, now)
    local shards = store and store[zoneID]
    if not shards then return nil end
    local best, bestShard
    for shardID, entry in pairs(shards) do
        -- Ranked stages only. An anchor says a crate existed, not that one is
        -- in the air now, and a row claiming otherwise would send the raid to
        -- a zone where nothing is happening.
        if RANK[entry.stage] and alive(entry, now) then
            local br = best and (RANK[best.stage] or 99) or 99
            local er = RANK[entry.stage] or 99
            if not best or er < br or (er == br and entry.at > best.at) then
                best, bestShard = entry, shardID
            end
        end
    end
    return best, bestShard
end

-- Drops what has aged out. Returns how many went.
function Remote.Expire(store, now)
    local removed = 0
    for zoneID, shards in pairs(store or {}) do
        for shardID, entry in pairs(shards) do
            if not alive(entry, now) then
                shards[shardID] = nil
                removed = removed + 1
            end
        end
        if not next(shards) then store[zoneID] = nil end
    end
    return removed
end

function Remote.Count(store, now)
    local n = 0
    for _, shards in pairs(store or {}) do
        for _, entry in pairs(shards) do
            if alive(entry, now) then n = n + 1 end
        end
    end
    return n
end

function Remote.Clear(store)
    for zoneID in pairs(store or {}) do store[zoneID] = nil end
end

-- This client has now seen the crate the report was about, so the report has
-- earned a place in the timers. Timers.Record settles which anchor wins; all
-- this has to do is offer the scout's, once.
--
-- Returns the verdict and the promoted report, or nil when there was nothing
-- to promote.
function Remote.Promote(store, db, zoneID, shardID)
    local entry = store and store[zoneID] and store[zoneID][shardID]
    if not entry or entry.promoted then return nil end
    entry.promoted = true

    local verdict, recorded = ns.Timers.Record(db, zoneID, shardID, entry.at, entry.stage)
    -- Provenance survives into the saved timer, so the data panel can say a
    -- row came from someone else rather than presenting it as your own work.
    if recorded and (verdict == "new" or verdict == "refined") then
        recorded.via = entry.from
    end
    return verdict, entry
end

-- The wire.
--
-- Parsing lives here rather than in Core/Comm.lua so tests/ can drive it. A
-- malformed message from another addon is normal traffic, not an error, and
-- the only way to be sure it is handled is to feed it one.
--
-- Fields are split with gmatch rather than strsplit, which keeps this file
-- plain Lua, and an empty field survives instead of shifting every field after
-- it along by one.
local WIRE = 1
Remote.WIRE = WIRE

local function fields(text)
    local out = {}
    for field in (tostring(text) .. "~"):gmatch("([^~]*)~") do out[#out + 1] = field end
    return out
end

-- Tilde, not a pipe: WoW treats a pipe as the start of a colour escape and
-- doubles it, so a pipe-separated payload is not the payload that was sent.
function Remote.Encode(report)
    return table.concat({
        WIRE, report.stage, report.zoneID, report.shardID, report.at,
        report.x and ("%.4f"):format(report.x) or "",
        report.y and ("%.4f"):format(report.y) or "",
    }, "~")
end

local function zoneOf(raw)
    local id = tonumber(raw)
    return id and (ns.ZONE_ALIAS[id] or id) or nil
end

-- A shard arrives as a string from another addon and as a number from our own
-- scanner. Both would key the same zone twice, and the second row would look
-- like a second crate. Numbers everywhere.
local function shardOf(raw)
    return tonumber(raw)
end

local decoders = {}

decoders.EWC1 = function(f, sender)
    if tonumber(f[1]) ~= WIRE then return nil end
    return {
        stage = f[2], zoneID = zoneOf(f[3]), shardID = shardOf(f[4]),
        at = tonumber(f[5]), x = tonumber(f[6]), y = tonumber(f[7]),
        from = sender, via = "EWC",
    }
end

-- WarCrateTracker, which broadcasts in the clear to GUILD and PARTY:
--   SPOT_V2~<vignetteID>~<ts>~<zoneID>~<spotter>~<shardID>~<guid>
--
-- Its older SPOT carries no shard at all, so it cannot key a timer and is
-- passed over. The vignette ids are the same ones Data/Vignettes.lua holds.
local WCT_KINDS = { SPOT_V2 = true, UPDATE_V2 = true, REQUEST_V2 = true }

decoders.WarCrateTracker = function(f, sender)
    if not WCT_KINDS[f[1]] then return nil end
    return {
        stage = ns.VignetteStage(tonumber(f[2])),
        at = tonumber(f[3]), zoneID = zoneOf(f[4]),
        shardID = shardOf(f[6]),
        from = (f[5] ~= "" and f[5]) or sender, via = "WCT",
    }
end

-- Returns a report ready for Note, or nil when the message is not one we can
-- read. nil is the ordinary case: most prefixes are listened to so /ewc comm
-- can show that they are alive, not because the payload can be understood.
function Remote.Decode(prefix, text, sender)
    local decode = decoders[prefix]
    if not decode or type(text) ~= "string" then return nil end
    local report = decode(fields(text), sender)
    if not report or not report.stage or not report.zoneID then return nil end
    if not report.shardID or not report.at then return nil end
    return report
end

Remote.DECODABLE = {}
for prefix in pairs(decoders) do Remote.DECODABLE[prefix] = true end

-- RCT's own raid alert, read out of chat.
--
-- Its group announce is assembled in English regardless of locale -- the
-- localised CRATE_ALERT_MESSAGE is only used for the sender's own on-screen
-- warning -- so the frame around the two values is fixed:
--
--   Hated Gaming - War Crate Alert! Flying in <zone> - Shard: <n>
--
-- Sent to RAID_WARNING, or PARTY in a party, by the group leader alone and at
-- most once per zone per seven minutes. So this yields a live transport
-- sighting from an RCT user with no addon installed here and nothing decoded,
-- but only while an RCT user is leading.
--
-- The zone arrives as a NAME, localised to the sender's client, which is why
-- zoneByName is injected: in game it is built from C_Map so it matches this
-- client's language, and a raid whose members run different locales will have
-- names that do not resolve. Those are reported rather than dropped quietly.
local ALERT = "War Crate Alert!%s*Flying in%s+(.-)%s*%-%s*Shard:%s*(%S+)"

-- Returns a report, or nil plus the zone name that did not resolve.
function Remote.FromAlert(text, sender, zoneByName, now)
    if type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return nil end
    local zoneName, shard = text:match(ALERT)
    if not zoneName then return nil end

    local shardID = tonumber(shard)

    -- The shard survives a name this client cannot read, and it is the only
    -- handle on which zone was meant: RCT broadcasts the sender's own localised
    -- name and the game will only tell us ours, so a German raider's
    -- "Leerensturm" is unresolvable here however many of them are in the raid.
    -- Handed back so the name can be filed against the shards it arrived with.
    -- Not resolved from the shard automatically: shard 39 has been seen in
    -- Harandar, Slayer's Rise and Voidstorm, so a low id matches more than one
    -- zone and a wrong binding is worse than an unread name.
    local zoneID = zoneByName and zoneByName[zoneName]
    if not zoneID then return nil, zoneName, shardID end
    if not shardID then return nil, zoneName end

    return {
        stage = "flying", zoneID = zoneID, shardID = shardID,
        at = tonumber(now) or 0, from = sender, via = "RCT",
        -- RCT sends this as a raid warning, and the game lets only a leader or
        -- an assistant send one. So the sender is privileged by construction,
        -- whatever this client can work out about the roster.
        leader = true,
    }
end

-- RCT's countdown line, posted to the raid every cycle:
--
--   Next Crate: Zul'Aman - 1258 in 02:46
--   Next Crate: Slayer's Rise - 45 in - 20 s
--
-- Zone, shard and time remaining -- a timer, handed over in plain text, from
-- whoever is leading. Only the "Flying in X" alert was being read, so a raid
-- broadcasting this every cycle for an hour kept none of Dmitrii's rows alive
-- while he sat in one zone and the rest aged out.
--
-- Turned into an anchor rather than a countdown, because that is what the rest
-- of this addon speaks: a spawn one interval before the drop being announced
-- puts the same cycle in the same phase, and everything downstream already
-- knows what to do with a spawn.
--
-- Ranked as an anchor: it is their arithmetic, not a crate anybody has seen.
local COUNTDOWN = "Next Crate:%s*(.-)%s*%-%s*(%d+)%s+in%s+(.+)$"

-- "02:46", "00:31", and the last-call form "- 20 s".
local function secondsFrom(text)
    local mm, ss = text:match("^(%d+):(%d%d)")
    if mm then return tonumber(mm) * 60 + tonumber(ss) end
    local n = text:match("^%-?%s*(%d+)%s*s")
    return n and tonumber(n) or nil
end

function Remote.FromCountdown(text, sender, zoneByName, now, intervalOf)
    if type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return nil end
    local zoneName, shard, rest = text:match(COUNTDOWN)
    if not zoneName then return nil end

    local zoneID = zoneByName and zoneByName[zoneName]
    if not zoneID then return nil, zoneName, tonumber(shard) end

    local shardID, left = tonumber(shard), secondsFrom(rest)
    if not shardID or not left then return nil end
    -- Their countdown has been seen reading a couple of minutes out; anything
    -- past one cycle is not a countdown to the next drop.
    local interval = intervalOf and intervalOf(zoneID) or 1100
    if left < 0 or left > interval then return nil end

    return {
        stage = "anchor",
        zoneID = zoneID,
        shardID = shardID,
        at = (tonumber(now) or 0) + left - interval,
        from = sender,
        via = "RCT",
    }
end

-- HGLog, the log RCT bundles, which shares in the clear on HGLOG1:
--
--   <ver>|<type>|<chunk>|<rows>      rows: zoneID,ts,shardID;zoneID,ts,shardID
--
-- Only FULL carries rows. PULL and HAVE are protocol chatter, and the final
-- chunk of a run is an empty END marker.
--
-- A batch of anchors is not one sighting, so this returns a list and is kept
-- apart from Decode. Conflating them would make a fifteen-minute-old row from
-- somebody's database look like a crate in the air.
local HG_VER, HG_FULL = 1, "FULL"

function Remote.DecodeAnchors(prefix, text, sender)
    if prefix ~= "HGLOG1" or type(text) ~= "string" then return {} end
    if type(sender) ~= "string" or sender == "" then return {} end

    local ver, kind, rows = text:match("^(%d+)|([^|]+)|[^|]*|(.*)$")
    if tonumber(ver) ~= HG_VER or kind ~= HG_FULL or rows == "" then return {} end

    local out = {}
    for zone, at, shard in rows:gmatch("(%d+),(%d+),(%d+)") do
        out[#out + 1] = {
            stage = "anchor", zoneID = zoneOf(zone), shardID = shardOf(shard),
            at = tonumber(at), from = sender, via = "HGLog",
        }
    end
    return out
end

-- This client has seen the same crate with its own eyes, so what somebody said
-- about it earlier is no longer the current state.
--
-- Without this a report outlives the crate it described. One said a transport
-- was flying in Eversong; the crate landed and was looted while the report sat
-- in its five-minute window, and the window went on offering "inbound" for a
-- zone that was already finished with. Seen live on 20 Sep.
--
-- Only retired by a stage at least as far along. A scout watching a parachute
-- knows more than this client watching the transport that dropped it.
function Remote.Supersede(store, zoneID, shardID, stage)
    local shards = store and store[zoneID]
    local entry = shards and shards[shardID]
    if not entry then return false end
    if (ADVANCE[stage] or 99) > (ADVANCE[entry.stage] or 99) then return false end

    shards[shardID] = nil
    if not next(shards) then store[zoneID] = nil end
    return true
end

-- Which copy of a zone the raid is in, as somebody standing there reports it.
-- Returns the shard, who said so, how long ago, and whether they lead.
--
-- The leader's word outranks anybody else's, and not by courtesy. The game
-- moves party members onto the leader's shard when they join, provided they
-- are in the leader's zone, which makes the leader the one point the group
-- converges on. Nothing does that on a zone change, so it is a strong hint
-- rather than a guarantee -- but between two members reporting different
-- copies of a zone, the leader's is the one the raid ends up in.
function Remote.ShardFor(store, zoneID, now)
    local shards = store and store[zoneID]
    if not shards then return nil end
    local best, bestShard
    for shardID, entry in pairs(shards) do
        if alive(entry, now) then
            local better
            if not best then
                better = true
            elseif entry.leader ~= best.leader then
                better = entry.leader and true or false
            else
                better = entry.at > best.at
            end
            if better then best, bestShard = entry, shardID end
        end
    end
    if not best then return nil end
    return bestShard, best.from, now - best.at, best.leader
end

-- RCT's own prefix, decoded without bundling anything.
--
-- The payload is AceSerializer, then LibDeflate, then EncodeForPrint. That is
-- their Sync/wire.lua, read from the copy on disk. Nothing is encrypted, and
-- the signature beside it is theirs to check rather than ours to satisfy:
-- reading a broadcast is not the same as claiming to be one of them.
--
-- The two libraries are not bundled and will not be -- between them they are
-- most of the weight this addon exists without. They are borrowed. LibStub
-- hands out whatever any installed addon has already loaded, and both are
-- everywhere: Details, BugSack and several others carry them. With neither
-- present the message stays undecoded and says so, exactly as before.
local RCT_STAGE = {
    ["Flying"]            = "flying",
    ["Monster Say"]       = "flying",
    ["Falling To Ground"] = "falling",
    ["On Ground"]         = "ground",
    ["Claimed"]           = "claimed",
}

local function borrowedInflate(encoded)
    if not LibStub then return nil end
    local okD, deflate = pcall(LibStub, "LibDeflate", true)
    local okS, serializer = pcall(LibStub, "AceSerializer-3.0", true)
    if not (okD and okS and deflate and serializer) then return nil end

    local ok, data = pcall(function()
        local blob = deflate:DecodeForPrint(encoded)
        if not blob then return nil end
        local raw = deflate:DecompressDeflate(blob)
        if not raw then return nil end
        local good, tbl = serializer:Deserialize(raw)
        return good and tbl or nil
    end)
    return ok and data or nil
end

-- Returns a report, or nil plus why it could not be read. inflate is injected
-- so tests can drive the parsing without either library present.
function Remote.DecodeRCT(text, sender, inflate)
    if type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return nil end

    -- The AceComm framing is already off by here; Core/Comm.lua reassembles
    -- a split message before anything is asked to read it.
    -- Their token traffic, which is control rather than content. TOKEN_REQ
    -- carries no payload at all, so it has to be recognised before a payload
    -- is required of it: nine bytes of it arrived seventeen times in ten
    -- seconds and were filed as "not theirs".
    if text:find("^TOKEN") then return nil, "handshake" end

    local tag, encoded = text:match("^([A-Z_]+)~([^~]+)")
    if not tag or not encoded then return nil, "not-theirs" end
    -- SYNC is their whole database being replayed at a new group member, and
    -- DELETE_ALL is housekeeping. Neither is anybody looking at a crate, and a
    -- historical row read as a live sighting is how a zone ends up saying
    -- "inbound" about a crate that landed ten minutes ago.
    if tag == "SYNC" or tag == "DELETE_ALL" then return nil, "their database, not a sighting" end

    local data = (inflate or borrowedInflate)(encoded)
    if type(data) ~= "table" then return nil, "no-library" end

    -- Their shard is "N/A" whenever they could not read one for the zone the
    -- crate is in, and plenty of their messages carry no zone at all. Refused
    -- here rather than passed on: a report with nothing to key it by is not a
    -- report, and letting it through only produced a line saying "invalid".
    local zoneID, shardID = zoneOf(data.zoneID), shardOf(data.shardhist)
    if not zoneID then return nil, "no zone" end
    if not shardID then return nil, "no shard" end

    local spotter = data.spotter
    return {
        stage   = RCT_STAGE[data.captureState] or "anchor",
        zoneID  = zoneID,
        shardID = shardID,
        at      = tonumber(data.ts),
        from    = (type(spotter) == "string" and spotter ~= "" and spotter) or sender,
        via     = "RCT",
    }
end

-- AceComm's framing, which every addon built on it inherits.
--
-- A message too long for one packet is split and each piece marked: \1 first,
-- \2 next, \3 last. A whole message whose own first byte would collide with
-- those is escaped with \4. Anything else arrived complete.
--
-- Worth more than it looks. RCT's bulk sync carries its entire crate database
-- and arrives in three or four pieces -- 145, 255 and 255 bytes from one
-- client in one burst -- so refusing split messages threw away most of what
-- there was to read.
--
-- The caller holds the state, keyed by sender. Returns the complete message,
-- or nil and why not.
local PART_MAX = 16      -- a sync this long is not one somebody meant to send
local PART_LIFE = 30     -- a run that stalls is abandoned rather than kept

function Remote.Reassemble(state, text, sender, now)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    if type(state) ~= "table" or type(sender) ~= "string" then return nil, "empty" end
    now = tonumber(now) or 0

    local mark = text:byte(1)
    if mark > 4 then return text end
    if mark == 4 then return text:sub(2) end

    local held = state[sender]
    if held and (now - held.at) > PART_LIFE then held = nil end

    if mark == 1 then
        state[sender] = { at = now, pieces = { text:sub(2) } }
        return nil, "partial"
    end

    -- A continuation with no beginning: this client started listening in the
    -- middle of somebody's sync, which is ordinary on login.
    if not held then
        state[sender] = nil
        return nil, "orphan"
    end

    held.pieces[#held.pieces + 1] = text:sub(2)
    held.at = now
    if #held.pieces > PART_MAX then
        state[sender] = nil
        return nil, "too long"
    end
    if mark == 2 then return nil, "partial" end

    state[sender] = nil
    return table.concat(held.pieces)
end
