local ADDON, ns = ...

-- Handing measurements to another player as a string they can paste.
--
-- Two of the stores travel and the rest do not. A parachute time and a drop
-- point are facts about the world: a second client standing at the same spot
-- measures the same fall. A timer belongs to one copy of one zone at one
-- moment, and a shard this client stood in means nothing on anybody else's
-- screen, so neither goes in. Nor do the measured cycle gaps -- an hour of
-- farming produces them anyway and every zone has landed within a few seconds
-- of 1090 -- and nor does the release bias, which is partly a property of how
-- fast this client sweeps rather than of the world.
--
-- Pure string and table work, so tests/ drives all of it.

local Share = {}
ns.Share = Share

-- Refusing a string written by a newer version is the point of the tag. The
-- alternative is reading four fields out of a five-field record and filing
-- somebody's measurements in the wrong place.
local TAG = "EWC1"
Share.TAG = TAG

-- Positions travel as tenths of a percent of the map, which is what the
-- descent store already rounds to and twenty times finer than the radius that
-- decides whether two readings describe the same spot.
local function fromFraction(v) return math.floor(v * 1000 + 0.5) end
local function fromPercent(v) return math.floor(v * 10 + 0.5) end

local function zonesInOrder()
    local ids = {}
    for id in pairs(ns.ZONES) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Returns the string. Always a string: an empty store exports a valid one
-- carrying nothing, which is a thing a player can be told apart from a failure.
function Share.Export(db)
    db = db or {}
    local learned, descent = db.learned or {}, db.descent or {}
    local out, n = { TAG }, 0

    -- Sorted, so two exports of the same store are the same string and the
    -- player can see at a glance whether anything changed.
    for _, zoneID in ipairs(zonesInOrder()) do
        for _, p in ipairs(learned[zoneID] or {}) do
            -- Learned points are kept as fractions and descent positions as
            -- percent to a tenth. Both leave here in the same unit.
            if type(p.x) == "number" and type(p.y) == "number" then
                n = n + 1
                out[#out + 1] = ("l:%d:%d:%d"):format(zoneID, fromFraction(p.x), fromFraction(p.y))
            end
        end
        for _, d in ipairs(descent[zoneID] or {}) do
            -- Partials are a lower bound on a fall somebody walked in on, and
            -- every figure here excludes them; sending them would be sending
            -- the half of the store that answers nothing. A reading with no
            -- position cannot be placed, and being placed is the whole value.
            if not d.partial and type(d.x) == "number" and type(d.y) == "number"
                and type(d.secs) == "number" then
                n = n + 1
                out[#out + 1] = ("d:%d:%d:%d:%d"):format(
                    zoneID, fromPercent(d.x), fromPercent(d.y), d.secs)
            end
        end
    end

    -- The count catches the failure a paste actually has: an edit box or a
    -- chat window that cut the end off. A string that stops cleanly between
    -- two records parses perfectly and is simply missing half the readings.
    out[#out + 1] = ("n:%d"):format(n)
    return table.concat(out, "~")
end

-- Returns true and a summary, or nil and a reason the player can act on.
--
-- All or nothing. Every record is read and checked before any of it is
-- written, because there is no undo for half an import.
function Share.Import(db, text, note)
    if type(db) ~= "table" then return nil, "nothing to import into" end
    if type(text) ~= "string" or text == "" then return nil, "nothing to read" end

    local body = text:match("^" .. TAG .. "~(.*)$")
    if not body then
        return nil, text:find("^EWC") and
            "that string was written by a newer version of this addon"
            or "that is not an EasyWarCrates string"
    end

    -- The count sits at the end, which is the part a cut paste loses, so it is
    -- read before the records. Otherwise a string that stops mid-record gets
    -- refused for the record -- true, and useless to the player holding it.
    local said = tonumber(body:match("~n:(%d+)$") or body:match("^n:(%d+)$"))
    if not said then
        return nil, "that string has no count on the end, so it may be cut short"
    end

    local records = {}
    for rec in body:gmatch("[^~]+") do
        if not rec:match("^n:%d+$") then
            local zone, x, y = rec:match("^l:(%d+):(%d+):(%d+)$")
            local secs
            if not zone then zone, x, y, secs = rec:match("^d:(%d+):(%d+):(%d+):(%d+)$") end
            if not zone then
                return nil, ("that string has something in it this cannot read: %s")
                    :format(rec:sub(1, 24))
            end
            records[#records + 1] = {
                zoneID = ns.ZONE_ALIAS[tonumber(zone)] or tonumber(zone),
                x = tonumber(x) / 1000, y = tonumber(y) / 1000, secs = tonumber(secs),
            }
        end
    end

    if said ~= #records then
        return nil, ("the count says %d and %d arrived, so the paste is truncated")
            :format(said, #records)
    end

    for _, r in ipairs(records) do
        if not ns.ZONES[r.zoneID] then
            return nil, ("that string has readings for map %d, where no crates drop")
                :format(r.zoneID)
        end
        if r.x > 1 or r.y > 1 then
            return nil, "that string has a position off the edge of the map in it"
        end
        if r.secs and (r.secs < ns.Airtime.DESCENT_MIN or r.secs > ns.Airtime.DESCENT_MAX) then
            return nil, ("that string claims a %ds fall, which is not one"):format(r.secs)
        end
    end

    db.descent, db.learned = db.descent or {}, db.learned or {}
    local got = { descent = 0, points = 0, full = 0, known = 0 }
    for _, r in ipairs(records) do
        if not r.secs then
            local verdict = ns.Learn.Note(db.learned, r.zoneID, r.x, r.y)
            if verdict == "learned" or verdict == "reinforced" then
                got.points = got.points + 1
            elseif verdict == "full" then
                got.full = got.full + 1
            else
                got.known = got.known + 1
            end
        else
            -- Room is counted before anything is written. The store drops its
            -- oldest reading to make room, and the oldest is one the player
            -- watched for themselves, so an import fills what is free and
            -- stops there rather than paying for itself with their work.
            local list = db.descent[r.zoneID]
            if list and #list >= ns.Airtime.MAX_READINGS then
                got.full = got.full + 1
            else
                ns.Airtime.NoteDescent(db.descent, r.zoneID, r.secs,
                    { pos = { x = r.x, y = r.y }, via = note })
                got.descent = got.descent + 1
            end
        end
    end
    return true, got
end
