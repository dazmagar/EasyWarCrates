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
local LIFETIME = { flying = 300, falling = 200, ground = 180, claimed = 90, anchor = 1200 }
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

    local zoneID = zoneByName and zoneByName[zoneName]
    if not zoneID then return nil, zoneName end

    local shardID = tonumber(shard)
    if not shardID then return nil, zoneName end

    return {
        stage = "flying", zoneID = zoneID, shardID = shardID,
        at = tonumber(now) or 0, from = sender, via = "RCT",
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
