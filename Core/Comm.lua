local ADDON, ns = ...

-- Talking to other players, and listening to addons that are not this one.
--
-- Thin on purpose: Track/Remote.lua decodes and decides, this registers
-- prefixes, guards what comes in and hands it over.
--
-- Nothing is ever sent on another addon's prefix. Their traffic is read where
-- it is already being broadcast to everyone in the channel, and their clients
-- never hear anything from us that they did not expect.

local Comm = {}
ns.Comm = Comm

local OURS = "EWC1"
Comm.OURS = OURS

-- Everything worth registering. Decodable ones turn into sightings; the rest
-- are here so /ewc comm can show that an addon is alive in this group at all,
-- which is the difference between "nobody is broadcasting" and "we cannot read
-- what they broadcast".
local PREFIXES = {
    OURS,
    "WarCrateTracker",  -- plain text, decoded
    "HGLOG1",           -- RCT's log companion, plain text, not decoded yet
    "RCT", "RCTUPD",    -- serialised and deflated; unpacked with borrowed libraries
    "WCP1",             -- WarCratePredict
    "CTKZK_SYNC", "CTKZK_PSYNC",
}
Comm.PREFIXES = PREFIXES

-- CHAT_MSG_ADDON is a client-wide event, not a per-addon one: registering a
-- prefix turns on delivery for the whole client, so this handler is also
-- handed every prefix any other addon registered. Without this set the log
-- fills with Details! and whatever else is installed, and the one line that
-- matters is buried.
local WANTED = {}
for _, prefix in ipairs(PREFIXES) do WANTED[prefix] = true end

-- Our own protocol stays inside the group. Another addon's traffic is taken
-- from the guild too, because that is where WarCrateTracker and HGLog
-- broadcast and refusing it would throw away most of what there is to hear.
local OUR_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }
local THEIR_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true, GUILD = true }

-- A whisper is never a legitimate transport for any of this. Without that
-- rule anyone on the realm can hand you a crafted message and move a timer,
-- needing no group, no guild and no acquaintance.
local RX_PER_WINDOW, RX_WINDOW = 20, 5
local rxRate = {}

local SEND_COOLDOWN = 20
local lastSent = {}

-- What has been heard lately, for /ewc comm. Includes traffic we cannot read.
local HEARD_MAX = 20
local heard = {}
Comm.heard = heard
Comm.handshakes = 0

local zoneByName

local function nameOnly(sender)
    return (tostring(sender or "")):match("^([^-]+)") or sender
end

local function inGroupNow(sender)
    local ok, yes = pcall(function()
        return UnitInRaid(sender) or UnitInParty(sender)
            or UnitInRaid(nameOnly(sender)) or UnitInParty(nameOnly(sender))
    end)
    return ok and yes and true or false
end

-- Whether whoever sent this leads the group. Worth knowing because the game
-- gathers party members onto the leader's shard when they join, so between
-- two people reporting different copies of a zone, the leader's is the one the
-- raid converges on.
local function leads(sender)
    local ok, yes = pcall(function()
        return UnitIsGroupLeader(sender) or UnitIsGroupLeader(nameOnly(sender))
    end)
    return (ok and yes) and true or false
end

local function isSelf(sender)
    local me = UnitName("player")
    return me ~= nil and nameOnly(sender) == me
end

local function rateOK(sender)
    local now, r = GetTime(), rxRate[sender]
    if not r or (now - r.at) > RX_WINDOW then
        rxRate[sender] = { n = 1, at = now }
        return true
    end
    r.n = r.n + 1
    return r.n <= RX_PER_WINDOW
end

local function log(entry)
    entry.at = GetServerTime()
    table.insert(heard, 1, entry)
    while #heard > HEARD_MAX do table.remove(heard) end
end

-- The six zones by the name this client calls them, so a name in a chat alert
-- resolves. Built from the game rather than from Data/Zones.lua, whose names
-- are English: a Russian client has to match a Russian name.
local function zoneNames()
    if zoneByName then return zoneByName end
    zoneByName = {}
    for zoneID in pairs(ns.ZONES) do
        local info = C_Map.GetMapInfo(zoneID)
        if info and info.name then zoneByName[info.name] = zoneID end
        -- The shipped English name too, for a raid on mixed locales.
        zoneByName[ns.GetZoneName(zoneID)] = zoneID
    end
    return zoneByName
end

local function take(report, channel)
    report.leader = report.leader or leads(report.from) or nil
    local verdict = ns.Remote.Note(ns.remote, report, GetServerTime())
    log({ via = report.via, from = report.from, channel = channel,
          text = ("%s in %s shard %s"):format(report.stage,
              ns.GetZoneAbbr(report.zoneID), tostring(report.shardID)),
          verdict = verdict })
    if verdict == "new" or verdict == "refresh" then
        if ns.RefreshWindow then ns.RefreshWindow() end
    end

    -- Said out loud the first time, and only for a crate somebody can act on.
    -- Until now every one of these went to a ring buffer in memory that never
    -- reached disk, so after the fact there was no way to tell "nobody is
    -- broadcasting" from "we heard them and did nothing". A refresh of the
    -- same crate stays quiet; so does a player merely reporting where they
    -- stand, which is bookkeeping rather than news.
    if verdict == "new" and ns.Remote.RANK[report.stage] then
        ns.Print(("|cff33ddaa%s|r says a crate is %s in |cffffd100%s|r"
            .. " |cff777777(shard %s, heard through %s)|r"):format(
            tostring(report.from), report.stage, ns.GetZoneName(report.zoneID),
            tostring(report.shardID), tostring(report.via)))
    elseif verdict == "new" then
        ns.Debug(("%s is in %s shard %s"):format(tostring(report.from),
            ns.GetZoneAbbr(report.zoneID), tostring(report.shardID)))
    end
    return verdict
end

-- Half-received messages, by sender. AceComm splits anything over a packet,
-- and RCT's bulk sync is three or four pieces.
local partial = {}

function Comm.OnAddonMessage(prefix, text, channel, sender)
    if not WANTED[prefix] then return end
    if not ns.db or not ns.db.enabled then return end
    local allowed = (prefix == OURS) and OUR_CHANNELS or THEIR_CHANNELS
    if not allowed[channel] then return end
    if isSelf(sender) then return end
    if channel ~= "GUILD" and not inGroupNow(sender) then return end
    if not rateOK(sender) then return end

    -- Put a split message back together before anything is asked to read it.
    -- A piece on its own is not a refusal, it is a wait.
    local whole, framing = ns.Remote.Reassemble(partial, text, sender, GetServerTime())
    if not whole then
        if framing ~= "partial" then
            log({ via = prefix, from = sender, channel = channel,
                  text = ("%d bytes"):format(#tostring(text)), verdict = framing })
        end
        return
    end
    text = whole

    local report = ns.Remote.Decode(prefix, text, sender)
    if report then return take(report, channel) end

    -- HGLog shares a batch of anchors rather than one sighting, so it has its
    -- own way in. Logged as one line: a chunk can carry dozens of rows and a
    -- line each would push everything else out of the log.
    local anchors = ns.Remote.DecodeAnchors(prefix, text, sender)
    if #anchors > 0 then
        local taken = 0
        for _, anchor in ipairs(anchors) do
            local verdict = ns.Remote.Note(ns.remote, anchor, GetServerTime())
            if verdict == "new" or verdict == "refresh" then taken = taken + 1 end
        end
        return log({ via = "HGLog", from = sender, channel = channel,
                     text = ("%d anchor%s"):format(#anchors, #anchors == 1 and "" or "s"),
                     verdict = ("%d recent enough to keep"):format(taken) })
    end

    -- RCT's own prefix, unpacked with libraries borrowed from whatever else
    -- is installed rather than bundled. The reason it failed is logged,
    -- because "nobody has LibDeflate" and "that was a token handshake" are
    -- different answers and both used to read as "not decoded".
    if prefix == "RCT" then
        local spot, why = ns.Remote.DecodeRCT(text, sender)
        if spot then return take(spot, channel) end
        -- Counted rather than logged. One client sent seventeen token
        -- requests in ten seconds, which would have pushed every real
        -- sighting out of a twenty-line log before anybody could read it. The
        -- count still proves the channel is alive, which is all a handshake
        -- was ever evidence of.
        if why == "handshake" then
            Comm.handshakes = (Comm.handshakes or 0) + 1
            return
        end
        return log({ via = "RCT", from = sender, channel = channel,
                     text = ("%d bytes"):format(#tostring(text)),
                     verdict = why or "not decoded" })
    end

    -- Unreadable, and that is the normal case for the rest. Logged without its
    -- payload: it is compressed binary and printing it would fill the log with
    -- nothing.
    log({ via = prefix, from = sender, channel = channel,
          text = ("%d bytes, not decoded"):format(#tostring(text)), verdict = "heard" })
end

function Comm.OnChat(text, sender, channel)
    if not ns.db or not ns.db.enabled then return end
    if isSelf(sender) then return end
    if not rateOK(sender) then return end

    local report, unresolved = ns.Remote.FromAlert(text, sender, zoneNames(), GetServerTime())
    if report then return take(report, channel) end
    if unresolved then
        log({ via = "RCT", from = sender, channel = channel, verdict = "unknown zone",
              text = ("said a crate is flying in %q, which is not a zone this client knows")
                  :format(unresolved) })
    end
end

-- Tell the group what this client just saw. Never a prediction on its own: a
-- guess travelling as news is how one wrong call becomes everyone's.
function Comm.Report(zoneID, shardID, stage, pos)
    if not ns.db or not ns.db.enabled or not ns.db.share then return end
    if not ns.Remote.RANK[stage] then return end
    if not IsInGroup() then return end

    local key = ("%s:%s:%s"):format(zoneID, tostring(shardID), stage)
    local now = GetTime()
    if (now - (lastSent[key] or -math.huge)) < SEND_COOLDOWN then return end
    lastSent[key] = now

    local payload = ns.Remote.Encode({
        stage = stage, zoneID = zoneID, shardID = shardID, at = GetServerTime(),
        x = pos and pos.x or nil, y = pos and pos.y or nil,
    })
    local channel = IsInRaid() and "RAID" or "PARTY"
    pcall(C_ChatInfo.SendAddonMessage, OURS, payload, channel)
end

-- Put the call in raid chat, with a pin the raid can click.
--
-- Leader and assistant only, and that is the whole reason role is read at all.
-- Setting a pin is private -- one waypoint per client, nobody else's ever
-- reaches you -- so every client should set its own and none of that needs
-- permission. Sending is the opposite: five members running this would post
-- the same link five times, which is how RCT's announce came to be gated the
-- same way.
--
-- The link has to come from this client's own waypoint, so announcing moves
-- your pin. That is not a side effect to work around; the pin and the link are
-- one object.
local ANNOUNCE_COOLDOWN = 240
local lastAnnounced = {}

function Comm.Announce(zoneID, x, y)
    if not ns.db or not ns.db.announce then return "off" end
    local role = Comm.Role()
    if role ~= "leader" and role ~= "assist" then return "not-privileged" end

    local now = GetServerTime()
    if (now - (lastAnnounced[zoneID] or -math.huge)) < ANNOUNCE_COOLDOWN then
        return "too-soon"
    end

    local ok, link = ns.SetCratePin(zoneID, x, y)
    if not ok then return "no-pin" end
    lastAnnounced[zoneID] = now

    local text = ("War crate incoming: %s %.1f, %.1f%s"):format(
        ns.GetZoneName(zoneID), x * 100, y * 100, link and (" " .. link) or "")
    pcall(SendChatMessage, text, IsInRaid() and "RAID_WARNING" or "PARTY")
    return "sent"
end

-- Say which copy of the zone this client is standing in.
--
-- The one thing nobody can find out about a zone they are not in, and the
-- thing that decides whether a stored timer is worth flying to. A scout parked
-- in Zul'Aman knows its shard now; everyone else finds out on arrival, which
-- is too late to have chosen.
--
-- Sent on arriving somewhere and then rarely, because it only changes when
-- somebody moves.
local HERE_COOLDOWN = 240
local lastHere = {}

function Comm.ReportHere()
    if not ns.db or not ns.db.enabled or not ns.db.share then return "off" end
    if not IsInGroup() then return "alone" end

    local zoneID = ns.Zones.Normalize(C_Map.GetBestMapForUnit("player"))
    if not zoneID then return "not-tracked" end
    local shard = ns.Scanner and ns.Scanner.CurrentShard and ns.Scanner.CurrentShard(zoneID)
    if not shard then return "no-shard" end

    local key = ("%s:%s"):format(zoneID, shard)
    local now = GetTime()
    if (now - (lastHere[key] or -math.huge)) < HERE_COOLDOWN then return "too-soon" end
    lastHere[key] = now

    pcall(C_ChatInfo.SendAddonMessage, OURS, ns.Remote.Encode({
        stage = "here", zoneID = zoneID, shardID = shard, at = GetServerTime(),
    }), IsInRaid() and "RAID" or "PARTY")
    return "sent"
end

-- Say a row out loud, because somebody clicked it.
--
-- Gated far more loosely than the automatic announce, and on purpose. That one
-- fires by itself on every client running this addon, so five of them would
-- say the same thing five times and it is held to the leader. This is one
-- person choosing, once, so a raid warning is fair where the game allows one
-- and plain raid chat where it does not. RCT reached the same conclusion about
-- its own click-to-announce.
--
-- The pin has to come from this client's own waypoint, which moving is the
-- price of a link the chat will keep clickable. SetCratePin says so on screen.
local CLICK_COOLDOWN = 15
local lastClick = {}

-- Where a click would put it, and the phrase for saying so before it is
-- clicked. One function, because the tooltip promising one thing and the send
-- doing another is worse than either.
--
-- The click is deliberately not gated on db.announce or on being privileged,
-- unlike the automatic announce: the setting governs an addon speaking by
-- itself, and a click is the player choosing to. Which is exactly why the
-- tooltip has to name the channel. "Your group" reads mild and RAID chat in
-- somebody else's raid is twenty strangers.
function Comm.RowChannel()
    if not IsInGroup() then return nil, "you are not in a group" end
    if not IsInRaid() then return "PARTY", "party chat" end
    local role = Comm.Role()
    if role == "leader" or role == "assist" then
        return "RAID_WARNING", "a raid warning"
    end
    return "RAID", "raid chat"
end

function Comm.AnnounceRow(row)
    if type(row) ~= "table" then return "nothing" end
    local text = ns.Model.Announcement(row, GetServerTime())
    if not text then return "nothing" end
    if not IsInGroup() then return "alone" end

    local now = GetTime()
    if (now - (lastClick[row.zoneID] or -math.huge)) < CLICK_COOLDOWN then
        return "too-soon"
    end
    lastClick[row.zoneID] = now

    local live = row.live
    if live and live.x and live.y then
        local ok, link = ns.SetCratePin(row.zoneID, live.x, live.y)
        if ok and link then text = text .. " " .. link end
    end

    local channel = Comm.RowChannel()
    pcall(SendChatMessage, text, channel)
    return "sent", channel
end

function Comm.Role()
    if not IsInGroup() then return "solo" end
    if UnitIsGroupLeader("player") then return "leader" end
    if UnitIsGroupAssistant("player") then return "assist" end
    return "member"
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
for _, event in ipairs({ "CHAT_MSG_RAID_WARNING", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
                         "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" }) do
    frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        for _, prefix in ipairs(PREFIXES) do
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        Comm.OnAddonMessage(prefix, text, channel, sender)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        -- Not immediately: the shard is read from whatever the game draws
        -- first, and on arrival it has drawn nothing yet.
        C_Timer.After(8, Comm.ReportHere)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Out of the group, out of the reports. They were never yours and the
        -- shards they name are not ones you will be on again.
        if not IsInGroup() then ns.Remote.Clear(ns.remote) end
    else
        local text, sender = ...
        Comm.OnChat(text, sender, event:gsub("^CHAT_MSG_", ""))
    end
end)

-- Rarely, and only to say a thing that rarely changes. Someone who never
-- crosses a zone border still confirms they are there, which is what stops a
-- report ageing out under a scout who has not moved.
C_Timer.NewTicker(HERE_COOLDOWN, function() Comm.ReportHere() end)

Comm.frame = frame
