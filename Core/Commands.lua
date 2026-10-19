local ADDON, ns = ...

-- Diagnostics before features. Until a crate has actually been watched in
-- Midnight 12.2 these commands are the whole point of the addon: they report
-- what the game is really sending, so a wrong assumption shows up as a number
-- on screen instead of as silence.

local function fmtPct(v) return v and string.format("%.1f", v * 100) or "?" end

local HANDLERS = {}

HANDLERS.show = function() ns.ToggleWindow(true) end
HANDLERS.hide = function() ns.ToggleWindow(false) end
HANDLERS.window = function() ns.ToggleWindow() end
HANDLERS.config = function() Settings.OpenToCategory(ns.settingsCategoryID) end
HANDLERS.data = function() ns.ToggleDataPanel() end

HANDLERS.status = function()
    local rawMap = C_Map.GetBestMapForUnit("player")
    local zoneID = rawMap and ns.Zones.Normalize(rawMap)
    ns.Print("version " .. ns.Version() .. ", enabled=" .. tostring(ns.db.enabled)
        .. ", waypoint=" .. tostring(ns.db.waypoint) .. ", verbose=" .. tostring(ns.db.verbose))
    ns.Print(("map %s -> %s"):format(tostring(rawMap),
        zoneID and (ns.GetZoneName(zoneID) .. " (" .. zoneID .. ")") or "|cffff8800not a tracked crate zone|r"))
    if zoneID then
        local spots = ns.GetDropPoints(zoneID)
        ns.Print(("catalogue: %d drop spots, interval %ds"):format(spots and #spots or 0,
            ns.GetZoneInterval(zoneID)))
    end
end

-- The map chain. A crate zone can have sub-maps the tracker has to fold back
-- into it -- Harandar has a housing map (2576) that reports its own id and
-- refuses to give a position for a vignette out in the zone around it.
HANDLERS.map = function()
    local id = C_Map.GetBestMapForUnit("player")
    ns.Print("walking up from map " .. tostring(id))
    local depth = 0
    while id and id ~= 0 and depth < 10 do
        depth = depth + 1
        local info = C_Map.GetMapInfo(id)
        if not info then ns.Print(("  %d: |cffff5555no map info|r"):format(id)) break end
        local tracked = ns.ZONES[info.mapID] and "  |cff33ff99TRACKED CRATE ZONE|r" or ""
        ns.Print(("  %s%d %s |cff777777mapType=%s parent=%s|r%s"):format(
            string.rep("  ", depth - 1), info.mapID, tostring(info.name),
            tostring(info.mapType), tostring(info.parentMapID), tracked))
        id = info.parentMapID
    end
    local z = ns.Zones.Normalize(C_Map.GetBestMapForUnit("player"))
    ns.Print("resolves to: " .. (z and (ns.GetZoneName(z) .. " (" .. z .. ")")
        or "|cffff8800nothing -- the addon is blind here|r"))
    ns.Print("|cff777777mapType 3 is Zone; the walk stops at the first one it meets|r")
end

-- Groundwork for routing. A route has to know how long it takes to get from
-- one zone to the next, and before inventing a number it is worth finding out
-- whether the six zones even share a coordinate space -- Coiled Isle sounds
-- like somewhere you take a boat to. C_Map answers for any map id without
-- having to stand in it, so this asks about all six at once.
HANDLERS.geo = function()
    local rects = {}
    for zoneID in pairs(ns.ZONES) do
        local info = C_Map.GetMapInfo(zoneID)
        local parent = info and info.parentMapID
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, zoneID, parent or 0)
        ns.Print(("%-4s %-16s |cff777777parent=%s|r %s"):format(
            ns.GetZoneAbbr(zoneID), ns.GetZoneName(zoneID), tostring(parent),
            (ok and minX) and ("rect %.3f-%.3f, %.3f-%.3f"):format(minX, maxX, minY, maxY)
                or "|cffff8800no rect on parent|r"))
        if ok and minX then
            rects[zoneID] = { x = (minX + maxX) / 2, y = (minY + maxY) / 2, parent = parent }
        end
    end

    local ids = {}
    for zoneID in pairs(rects) do ids[#ids + 1] = zoneID end
    table.sort(ids)
    if #ids < 2 then
        return ns.Print("|cffff8800not enough zones share a parent map to measure between them|r")
    end
    ns.Print("centre-to-centre distance on the shared parent map:")
    for i = 1, #ids do
        for j = i + 1, #ids do
            local a, b = rects[ids[i]], rects[ids[j]]
            if a.parent == b.parent then
                local dx, dy = a.x - b.x, a.y - b.y
                ns.Print(("  %s <-> %s   %.3f"):format(
                    ns.GetZoneAbbr(ids[i]), ns.GetZoneAbbr(ids[j]), math.sqrt(dx * dx + dy * dy)))
            else
                ns.Print(("  %s <-> %s   |cffff8800different parent maps|r"):format(
                    ns.GetZoneAbbr(ids[i]), ns.GetZoneAbbr(ids[j])))
            end
        end
    end
end

-- The important one on a new patch. Prints every vignette the game reports,
-- whether or not we recognise it, so a renumbered crate id is visible at once.
-- Every vignette id seen that this addon does not track, and what it has done.
--
-- Answers for a new object the three questions that decide whether it can be
-- tracked at all: which zones, whether it repeats, and on what period. Read
-- off sightings rather than reasoned about, because nothing anywhere documents
-- these -- Spectral Battle Chest (6892) is tracked by none of the three
-- competitors and Dmitrii's own observation is that it simply appears on the
-- ground, which if it holds means there is no flight to predict and a spawn
-- catalogue plus a cycle is the whole of it.
local function strangerHistory()
    local ids = {}
    for id in pairs(ns.db.strangers or {}) do ids[#ids + 1] = id end
    if #ids == 0 then return end
    table.sort(ids)

    ns.Print(("|cff777777seen before and not tracked -- %d id%s:|r"):format(
        #ids, #ids == 1 and "" or "s"))
    if (ns.Scanner.sceneryRefused or 0) > 0 then
        ns.Print(("|cff777777%d sighting%s of art that is never a crate were not filed"
            .. " -- rares, vendors, lore objects. /ewc scan still shows them all.|r"):format(
            ns.Scanner.sceneryRefused, ns.Scanner.sceneryRefused == 1 and "" or "s"))
    end
    if #ids >= ns.Scanner.STRANGER_IDS then
        local evicted = ns.Scanner.strangersEvicted or 0
        local refused = ns.Scanner.strangersRefused or 0
        ns.Print(("|cffff8800that is the cap (%d). A new id displaces the oldest"
            .. " that was never seen twice; this session has dropped %d that way"
            .. " and refused %d with nothing cheap left. /ewc scan reset empties"
            .. " it.|r"):format(ns.Scanner.STRANGER_IDS, evicted, refused))
    end
    for _, id in ipairs(ids) do
        local rec = ns.db.strangers[id]
        ns.Print(("  id=|cffffd100%s|r %s |cff777777x%d, atlas %s|r"):format(
            tostring(id), tostring(rec.name), rec.n, tostring(rec.atlas)))

        for zoneID, where in pairs(rec.zones or {}) do
            -- Gaps only between consecutive sightings on the SAME shard: two
            -- copies of a zone run their own cycles, so pairing across them
            -- measures nothing.
            local gaps = {}
            for i = 2, #where.seen do
                local a, b = where.seen[i - 1], where.seen[i]
                if a.shard and b.shard and a.shard == b.shard then
                    gaps[#gaps + 1] = b.at - a.at
                end
            end
            table.sort(gaps)
            -- A cluster, and a figure that could be a cycle. Anything under the
            -- window in which two sightings count as one object is the poll
            -- rate wearing a decimal point: Slayer's Rise reported a set of
            -- remains "repeating about every 0s".
            local period, spread
            if #gaps >= 3 then
                local from, to, n = ns.DensestRun(gaps, 60)
                if n and n >= 3 then
                    local median = ns.MedianOf(gaps, from, to)
                    if median >= ns.Scanner.STRANGER_SAME then
                        period, spread = median, gaps[to] - gaps[from]
                    end
                end
            end

            local verdict
            if period then
                verdict = ("|cff33ff99about every %ds|r |cff777777(+/-%ds)|r"):format(
                    math.floor(period + 0.5), math.floor(spread / 2 + 0.5))
            elseif #gaps >= 3 then
                verdict = ("|cff777777%d gaps, none agreeing -- not a cycle yet|r"):format(#gaps)
            else
                verdict = ("|cff777777%d gap%s on one shard, needs 3|r"):format(
                    #gaps, #gaps == 1 and "" or "s")
            end
            ns.Print(("     %s x%d  last at %s,%s shard %s  %s"):format(
                ns.GetZoneName(zoneID), where.n, fmtPct(where.x), fmtPct(where.y),
                tostring(where.seen[#where.seen] and where.seen[#where.seen].shard),
                verdict))
        end
    end
end

HANDLERS.scan = function(rest)
    rest = tostring(rest or ""):lower()
    if rest == "reset" then
        ns.db.strangers = {}
        return ns.Print("record of untracked vignettes cleared.")
    end
    if rest == "seen" then
        if next(ns.db.strangers or {}) then return strangerHistory() end
        return ns.Print("nothing seen yet that this addon does not track.")
    end

    local list, rawMap, zoneID = ns.Scanner.Sweep()
    ns.Print(("scan on map %s -> %s -- %d vignettes"):format(
        tostring(rawMap),
        zoneID and (ns.GetZoneName(zoneID) .. " (" .. zoneID .. ")") or "|cffff8800untracked|r",
        #list))
    if #list == 0 then
        ns.Print("  nothing in range. Stand where you can see a crate or its plane.")
        return
    end
    for _, v in ipairs(list) do
        local tag = v.stage and ("|cff33ff99" .. v.stage .. "|r") or "|cff777777-|r"
        ns.Print(("  id=|cffffd100%s|r %s  %s  at %s,%s |cff777777(map %s)|r  shard=%s  atlas=%s"):format(
            tostring(v.id), tag, tostring(v.name),
            fmtPct(v.x), fmtPct(v.y), tostring(v.posMap), tostring(v.shard), tostring(v.atlas)))
    end
    ns.Print("|cff777777ids we watch for: 3689 flying, 2967 falling, 6066 ground, 6067/6068 claimed|r")
    local kinds = 0
    for _ in pairs(ns.db.strangers or {}) do kinds = kinds + 1 end
    if kinds > 0 then
        ns.Print(("|cff777777%d other id%s seen before and not tracked -- /ewc scan seen|r"):format(
            kinds, kinds == 1 and "" or "s"))
    end
end

HANDLERS.points = function()
    local zoneID = ns.Zones.Normalize(C_Map.GetBestMapForUnit("player"))
    if not zoneID then return ns.Print("not in a tracked crate zone.") end
    local spots = ns.GetDropPoints(zoneID)
    local learnedSpots, learnedZones = ns.Learn.Count(ns.db.learned)
    ns.Print(("%s -- %d drop spots (%d shipped + %d you learned here):"):format(
        ns.GetZoneName(zoneID), #spots,
        #(ns.ShippedDropPoints(zoneID) or {}),
        #((ns.db.learned or {})[zoneID] or {})))
    for i, s in ipairs(spots) do
        ns.Print(("  %2d. %s, %s   |cff777777(%d sighting%s)|r%s"):format(
            i, fmtPct(s.x), fmtPct(s.y), s.n, s.n == 1 and "" or "s",
            s.learned and "  |cff33ff99learned|r" or ""))
    end
    if learnedSpots > 0 then
        ns.Print(("|cff777777%d learned spot(s) across %d zone(s) in total|r"):format(
            learnedSpots, learnedZones))
    end
end

HANDLERS.predict = function()
    local zoneID = ns.Zones.Normalize(C_Map.GetBestMapForUnit("player"))
    if not zoneID then return ns.Print("not in a tracked crate zone.") end
    local r = ns.Scanner.Prediction(zoneID)
    if not r then return ns.Print("no transport being tracked right now.") end
    if r.committed then
        ns.Print(("|cff33ff99called|r -> %s, %s%s"):format(
            fmtPct(r.committed.x), fmtPct(r.committed.y),
            r.arrived and "  |cff77dd77transport has reached it|r" or " |cff777777(still inbound)|r"))
        ns.Print("|cff777777the call is final -- a transport drops once, so its heading afterwards means nothing|r")
    elseif not r.ok then
        ns.Print("|cffff8800holding|r -- " .. tostring(r.reason)
            .. (r.best and (", best is %s,%s"):format(fmtPct(r.best.spot.x), fmtPct(r.best.spot.y)) or ""))
    else
        ns.Print(("|cff33ff99committed|r -> %s, %s"):format(fmtPct(r.best.spot.x), fmtPct(r.best.spot.y)))
    end
    if r.fit then
        ns.Print(("  fit: %d samples over %.1fs, heading err %.2f deg, cross-track rms %.4f"):format(
            r.fit.n, r.fit.span, math.deg(r.fit.err), r.fit.rms))
        ns.Print(("  speed %.4f map/s -- crossing the zone takes ~%ds"):format(
            r.fit.speed, r.fit.speed > 0 and (1 / r.fit.speed) or 0))
    end
    for i, c in ipairs(r.ranked or {}) do
        if i > 3 then break end
        ns.Print(("  %d. %s,%s  %.2f deg off, %.1f%% ahead"):format(
            i, fmtPct(c.spot.x), fmtPct(c.spot.y), math.deg(math.atan(c.tan)), c.along * 100))
    end
end

-- The two legs of a crate's flight, and what is known about each.
HANDLERS.airtime = function(rest)
    local reset = tostring(rest or ""):lower():match("^reset%s*(.*)$")
    if reset then
        -- Scoped by zone, because one bad reading should not cost the other
        -- five zones their history.
        if reset ~= "" then
            local zoneID = ns.ResolveZoneInput(reset)
            if not zoneID then return ns.Print(("no zone called '%s'"):format(reset)) end
            ns.db.descent[zoneID] = nil
            return ns.Print(("parachute measurements cleared for %s."):format(
                ns.GetZoneName(zoneID)))
        end
        ns.db.descent = {}
        ns.db.release = {}
        return ns.Print("parachute and release measurements cleared.")
    end
    -- Drop one reading. A zone-wide reset costs every other reading there, and
    -- each one is a full crate cycle -- about eighteen minutes -- to replace.
    local dropZone, dropIdx = tostring(rest or ""):lower():match("^drop%s+(%S+)%s+(%d+)$")
    if dropZone then
        local zoneID = ns.ResolveZoneInput(dropZone)
        if not zoneID then return ns.Print(("no zone called '%s'"):format(dropZone)) end
        local list = ns.Airtime.DescentSamples(ns.db.descent, zoneID)
        local d = list and list[tonumber(dropIdx)]
        if not d then return ns.Print(("%s has no reading %s"):format(
            ns.GetZoneName(zoneID), dropIdx)) end
        table.remove(list, tonumber(dropIdx))
        return ns.Print(("dropped the %ds reading from %s -- %d left"):format(
            math.floor(d.secs + 0.5), ns.GetZoneName(zoneID), #list))
    end

    ns.Print("time under the parachute -- per drop point, where it is known:")
    local any = false
    for zoneID in pairs(ns.ZONES) do
        local mean, n, lo, hi, over, _, source = ns.Airtime.Descent(ns.db.descent, zoneID)
        if n > 0 then
            any = true
            -- The zone figure is the fallback now, so it says so: it answers
            -- for a spot with too few readings and for a crate whose spot is
            -- not known yet.
            ns.Print(("  %-3s |cff777777spot unknown: %ds from %s%d drop%s, range %d-%d|r"):format(
                ns.GetZoneAbbr(zoneID), math.floor(mean + 0.5),
                -- A figure this zone borrowed must not read like one it
                -- measured. Eversong's own readings average out to 64s, which
                -- is not a time any crate there has ever taken.
                source == "pooled" and "every zone's -- its own disagree -- " or "",
                n, n == 1 and "" or "s",
                math.floor(lo + 0.5), math.floor(hi + 0.5)))
            -- By spot, not by reading. Forty numbered lines per zone answered
            -- the question they were added for -- whether distance truncates a
            -- reading -- and the answer turned out to be that the spot decides
            -- the fall. What is worth reading now is each spot's own figure,
            -- which is what the countdown actually uses.
            local spots, unplaced = ns.Airtime.DescentSpots(ns.db.descent, zoneID)
            for _, s in ipairs(spots) do
                ns.Print(("      |cffffd100%3ds|r  %.1f, %.1f  |cff777777%d drop%s%s|r"):format(
                    math.floor(s.typical + 0.5), s.x, s.y, s.n, s.n == 1 and "" or "s",
                    s.n < ns.Airtime.SPOT_MIN and ", one is not enough -- the zone answers here"
                    or not s.agrees and (", but they span %d-%ds, so the zone answers here")
                        :format(s.lo, s.hi)
                    or ""))
            end
            if unplaced > 0 then
                ns.Print(("      |cff777777%d more not counted: joined mid-fall, or"
                    .. " measured before the spot was recorded|r"):format(unplaced))
            end
            -- Numbered, because 'airtime drop ZONE N' needs the N. Verbose
            -- only: forty lines a zone is what the per-spot view replaced.
            if ns.db.verbose then
                for i, d in ipairs(ns.Airtime.DescentSamples(ns.db.descent, zoneID) or {}) do
                    ns.Print(("   %2d. %3ds  %s%s%s"):format(i, math.floor(d.secs + 0.5),
                        d.x and ("|cff777777at %.1f, %.1f|r"):format(d.x, d.y)
                        or "|cff777777spot not recorded|r",
                        d.lag and ("  |cff777777%ds circling first|r"):format(d.lag) or "",
                        d.partial and ("  |cffff8800not counted: %s|r"):format(
                            d.why or "joined mid-fall") or ""))
                end
            end
        else
            ns.Print(("  %-3s %3ds  |cff777777guess, nothing measured here|r"):format(
                ns.GetZoneAbbr(zoneID), math.floor(mean + 0.5)))
        end
    end
    if not any then
        ns.Print("|cff777777measured when a crate is watched from parachute to ground|r")
    end
    -- That line used to say the other leg was computed from the transport's
    -- speed and not learned, which stopped being true the moment Airtime.Flight
    -- was written: db.flight held 145 readings while this printed the opposite,
    -- and UI/Model reads the measured figure for the second column.
    local legZones = {}
    for zoneID in pairs(ns.ZONES) do legZones[#legZones + 1] = zoneID end
    table.sort(legZones, function(a, b) return ns.GetZoneAbbr(a) < ns.GetZoneAbbr(b) end)

    local legs = {}
    for _, zoneID in ipairs(legZones) do
        local flight, n, lo, hi, _, part, source = ns.Airtime.Flight(ns.db.flight, zoneID)
        if n and n > 0 then
            legs[#legs + 1] = ("  %-3s %3ds  |cff777777%s%d reading%s, range %d-%d%s|r"):format(
                ns.GetZoneAbbr(zoneID), math.floor(flight + 0.5),
                source == "pooled" and "its readings disagree, so this is every zone's " or "from ",
                n, n == 1 and "" or "s", math.floor(lo + 0.5), math.floor(hi + 0.5),
                (part or 0) > 0 and (", %d caught mid-air and left out"):format(part) or "")
        end
    end
    if #legs > 0 then
        ns.Print("|cff777777the other leg -- spawn to parachute -- timed per zone:|r")
        for _, line in ipairs(legs) do ns.Print(line) end
        ns.Print("|cff777777only an announcer really marks the spawn; a transport caught in"
            .. " the air is a lower bound and is left out|r")
    else
        ns.Print("|cff777777the other leg -- spawn to parachute -- needs an announcer heard"
            .. " before the transport appears|r")
    end
end

HANDLERS.timers = function()
    local now = GetServerTime()
    local list = ns.Timers.Sorted(ns.db.crates, ns.GetZoneInterval, now)
    if #list == 0 then return ns.Print("no timers yet.") end
    for _, row in ipairs(list) do
        local m = math.floor((row.remaining or 0) / 60)
        local s = math.floor((row.remaining or 0) % 60)
        ns.Print(("%s |cffffffffshard %s|r  %s%02d:%02d  |cff777777(%s, %d missed)|r"):format(
            ns.GetZoneName(row.zoneID), tostring(row.shardID),
            row.entry.precise and "" or "~", m, s,
            row.entry.source, row.missed or 0))
    end
end

-- Cross-checks where the shard number really lives. The vignette-derived value
-- is the one the addon uses, but a vignette GUID need not share a creature
-- GUID's field layout, so this prints both side by side with every field
-- numbered. Target or mouseover any creature and run it.
-- Send the call by hand, and say why it did not go if it did not.
-- Previews the announcement lines in a language without that client being
-- installed. Without this the setting is unverifiable by anyone whose client
-- is already English, which is most people who would work on it: they would
-- tick the box, see no change, and have no way to tell a working feature from
-- a broken one.
HANDLERS.locale = function(which)
    local locales = ns.ANNOUNCE_LOCALES or {}
    if not which or which == "" then
        local names = {"enUS (English, the fallback)"}
        for code in pairs(locales) do names[#names + 1] = code end
        table.sort(names)
        ns.Print(("announcements go out in %s. Translated: %s"):format(
            ns.AnnounceLocale(), table.concat(names, ", ")))
        return ns.Print("  /ewc locale <code> -- preview the lines in that language")
    end

    if which ~= "enUS" and not locales[which] then
        return ns.Print(("no translation for %q; it would fall back to English."):format(which))
    end

    -- Restored whatever happens: a preview that leaked would change what goes
    -- into other people's chat.
    local was = ns.announcePreview
    ns.announcePreview = which
    local ok = pcall(function()
        ns.Print(("announcement lines in %s:"):format(which))
        ns.Print("  " .. ns.Phrase("INCOMING", "Zul'Aman", 44.2, 61.8, ""))
        ns.Print("  " .. ns.Phrase("TRANSPORT_IN", "Zul'Aman", "2:30", "4:10",
            ns.Phrase("SHARD", "63")))
        ns.Print("  " .. ns.Phrase("TRANSPORT_AIR", "Eversong Woods", "", ""))
        ns.Print("  " .. ns.Phrase("CRATE_LANDING", "Harandar", "0:48", ""))
        ns.Print("  " .. ns.Phrase("CRATE_GROUND", "Voidstorm", ns.Phrase("SO_FAR", "0:20"), ""))
        ns.Print("  " .. ns.Phrase("CRATE_GROUND_OURS", "Voidstorm", ns.Phrase("LEFT", "1:40"), ""))
        ns.Print("  " .. ns.Phrase("SPECTRAL", "Slayer's Rise",
            ns.Phrase("AT", 52.1, 38.4), ns.Phrase("SO_FAR", "0:15"), ""))
        ns.Print("  " .. ns.Phrase("ADDON_PLUG"))
    end)
    ns.announcePreview = was
    if not ok then ns.Print("that locale table is malformed; see tests/spec_locale.lua") end
end

HANDLERS.announce = function()
    local zoneID = ns.Zones.Normalize(C_Map.GetBestMapForUnit("player"))
    if not zoneID then return ns.Print("not standing in a tracked zone.") end
    local pos = C_Map.GetPlayerMapPosition(zoneID, "player")
    if not pos then return ns.Print("the game will not say where you are.") end

    local x, y = pos:GetXY()
    local result = ns.Comm.Announce(zoneID, x, y)
    local why = {
        ["off"] = "turned off in settings",
        ["not-privileged"] = ("you are %s; only a leader or assistant may send"):format(ns.Comm.Role()),
        ["too-soon"] = "this zone was announced within the last four minutes",
        ["no-pin"] = "the map pin did not take, so there is no link to send",
        ["sent"] = nil,
    }
    ns.Print(result == "sent" and "|cff33ff99sent to the group|r"
        or ("|cffff8800not sent|r |cff777777-- %s|r"):format(why[result] or tostring(result)))
end

-- Who is broadcasting what, including addons we cannot read.
--
-- The point is to tell three failures apart: nobody in the group runs anything
-- (the list is empty), somebody does but their payload is sealed (lines saying
-- "not decoded"), and somebody does and we took it (a zone and a shard).
HANDLERS.comm = function()
    ns.Print(("you are %s; sharing is %s"):format(
        ns.Comm.Role(), ns.db.share and "|cff33ff99on|r" or "|cffff8800off|r"))

    -- Anything since taught to this client is not unresolved any more, and
    -- saying it is sends the reader chasing a gap that has been closed.
    local learned = ns.Comm.ForgetResolved()
    if learned > 0 then
        ns.Print(("|cff777777%d name%s dropped from that list -- resolvable now.|r"):format(
            learned, learned == 1 and " was" or "s were"))
    end

    local unknown = {}
    for name, held in pairs(ns.db.unknownZones or {}) do
        local shards = {}
        for shardID, count in pairs(held.shards or {}) do
            shards[#shards + 1] = ("%s x%d"):format(tostring(shardID), count)
        end
        table.sort(shards)
        unknown[#unknown + 1] = ("%s (x%d, shard %s, last from %s)"):format(
            name, held.n, #shards > 0 and table.concat(shards, "/") or "unknown",
            tostring(held.from))
    end
    if #unknown > 0 then
        table.sort(unknown)
        ns.Print(("|cffff8800zone names heard that this client cannot resolve:|r %s"):format(
            table.concat(unknown, ", ")))
        ns.Print("|cff777777their reports are being dropped. Send this line on.|r")
    end
    -- Registration, checked rather than assumed. A client can hold only so
    -- many prefixes across every addon installed, so asking for one is not the
    -- same as having it, and a refusal is silent. Without this, "nobody is
    -- broadcasting" and "we never subscribed" look identical.
    local ok, missing = {}, {}
    for _, prefix in ipairs(ns.Comm.PREFIXES) do
        local registered = true
        if C_ChatInfo.IsAddonMessagePrefixRegistered then
            local got, yes = pcall(C_ChatInfo.IsAddonMessagePrefixRegistered, prefix)
            registered = got and yes and true or false
        end
        table.insert(registered and ok or missing, prefix)
    end
    ns.Print(("subscribed to %d of %d: |cff33ff99%s|r"):format(
        #ok, #ns.Comm.PREFIXES, table.concat(ok, ", ")))
    if #missing > 0 then
        ns.Print(("|cffff5555not subscribed: %s|r |cff777777-- the client caps how many"
            .. " prefixes all addons may hold between them|r"):format(
            table.concat(missing, ", ")))
    end
    ns.Print(("reports held: %d%s%s%s"):format(ns.Remote.Count(ns.remote, GetServerTime()),
        (ns.Comm.handshakes or 0) > 0
            and ("  |cff777777(%d token handshakes ignored -- somebody's RCT is talking)|r")
                :format(ns.Comm.handshakes)
            or "",
        -- Twenty messages per five seconds per sender. Worth saying out loud,
        -- because a real sighting arriving inside somebody's burst is dropped
        -- with it and this is the only place that would ever mention it.
        (ns.Comm.rateLimited or 0) > 0
            and ("  |cffff8800(%d dropped: one sender over 20 messages in 5s)|r")
                :format(ns.Comm.rateLimited)
            or "",
        -- The client refusing to name a sender is not a quiet channel, and
        -- without this line it would read as one.
        (ns.Comm.secretSenders or 0) > 0
            and ("  |cffff8800(%d dropped: the client would not let us read who sent them)|r")
                :format(ns.Comm.secretSenders)
            or ""))

    local heard = ns.Comm.heard
    if #heard == 0 then
        -- Two very different silences, and this used to report both as the
        -- first. Dmitrii saw "alone you will see nothing" on the same screen
        -- as 122 counted messages.
        local counted = (ns.Comm.handshakes or 0) + (ns.Comm.rateLimited or 0)
            + (ns.Comm.secretSenders or 0)
        if counted > 0 then
            return ns.Print(("|cff777777%d message%s arrived and none of them carried a"
                .. " sighting -- counted above rather than listed here. So the channel"
                .. " is alive and nobody on it is reporting crates.|r"):format(
                counted, counted == 1 and "" or "s"))
        end
        return ns.Print("|cff777777nothing heard yet. Addon traffic only reaches you from"
            .. " your own party, raid or guild, so alone you will see nothing.|r")
    end
    local now = GetServerTime()
    for i = 1, #heard do
        local h = heard[i]
        ns.Print(("|cff777777%3ds|r %s[%s] |cffffffff%s|r %s |cff777777(%s%s)|r"):format(
            now - h.at, h.sent and "|cff33ff99-> |r" or "", tostring(h.via),
            tostring(h.from), tostring(h.text),
            tostring(h.verdict), h.inView and ", in view -- not announced" or ""))
    end
end

-- What the announcer has been heard saying, and whether it counted.
--
-- The phrases and the NPC names are both localised, and a locale this client
-- speaks that the list does not is silent rather than wrong: nothing anchors
-- and nobody finds out. This is how it gets found out.
HANDLERS.yells = function()
    local names = {}
    for name in pairs(ns.ANNOUNCER_NAMES) do names[#names + 1] = name end
    table.sort(names)
    ns.Print("listening for: " .. table.concat(names, ", "))

    local heard = ns.Scanner.heard or {}
    -- Deliberately not a return. The unresolved speakers printed below are the
    -- explanation for an empty list on a locale whose announcer names are not
    -- written down -- and on those clients heard is empty for exactly that
    -- reason, so returning here withheld the diagnosis from the only players
    -- who needed it.
    if #heard == 0 then
        ns.Print("|cff777777none of them has said anything yet. They speak when a cycle"
            .. " starts, so this stays empty until you sit through one.|r")
    else
        local now = GetServerTime()
        for i = 1, #heard do
            local h = heard[i]
            local what = h.anchored and "|cff33ff99anchored the timer|r"
                or h.matched and "|cffff8800recognised but not timed|r"
                or "|cffff8800not recognised|r"
            ns.Print(("%s |cff777777%ds ago, %s|r"):format(what, now - h.at,
                h.zoneID and ns.GetZoneName(h.zoneID) or "not a tracked zone"))
            ns.Print(("   %s: %s"):format(tostring(h.npc), tostring(h.text)))
            -- The shard has to come out of the speaker's own GUID and the first
            -- live announcement gave none, so the GUID is shown whenever it did
            -- not yield one.
            if h.matched and not h.anchored then
                ns.Print(("   |cff777777shard=%s, guid=%s, a creature nearby says %s|r"):format(
                    tostring(h.shard), tostring(h.guid), tostring(h.unitShard)))
                ns.Print("   |cff777777a creature's number and a crate vignette's number are not"
                    .. " the same thing -- /ewc shard compares them|r")
            end
        end
        ns.Print("|cff777777not recognised is either idle chatter or wording this locale needs"
            .. " adding -- worth sending on if a cycle really started.|r")
    end

    -- The gap that would otherwise be invisible. Announcer names are localised
    -- as much as their lines are, and only English and Russian are written
    -- down; on any other client nothing above this line ever appears and there
    -- is no way to tell that from "nobody has spoken".
    local strangers = {}
    for name, held in pairs(ns.db.unknownSpeakers or {}) do
        strangers[#strangers + 1] = { name = name, held = held }
    end
    local heard = (ns.Scanner.StrangersHeard and ns.Scanner.StrangersHeard()) or 0
    if #strangers == 0 then
        -- Never silent. "Nobody has spoken" and "nobody spoke when a cycle
        -- started" are the two answers this command exists to separate, and
        -- printing nothing is the first of them.
        if heard > 0 then
            ns.Print(("|cff777777%d line%s from other NPCs heard in crate zones this"
                .. " session, none within %ds of a cycle starting.|r"):format(
                heard, heard == 1 and "" or "s", ns.Scanner.ANNOUNCER_LEAD))
        end
        return
    end
    table.sort(strangers, function(a, b) return a.held.n > b.held.n end)

    ns.Print(("|cffff8800%d NPC%s spoken as a cycle started here and %s not known"
        .. " announcers:|r"):format(#strangers, #strangers == 1 and " has" or "s have",
        #strangers == 1 and "is" or "are"))
    if #strangers >= ns.Scanner.UNKNOWN_SPEAKERS then
        ns.Print(("|cffff8800that is the cap (%d) -- any further name is being"
            .. " dropped.|r"):format(ns.Scanner.UNKNOWN_SPEAKERS))
    end
    for i = 1, math.min(#strangers, 6) do
        local e = strangers[i]
        -- Where in the cycle they spoke, because that is what separates an
        -- announcer from an NPC who happened to be talking: the real one is at
        -- the same point of every cycle.
        local lead = tonumber(e.held.lead) or 0
        ns.Print(("   %s |cff777777x%d in %s, %s|r"):format(
            e.name, e.held.n, ns.GetZoneName(e.held.zoneID),
            lead <= 0 and ("%ds before it started"):format(-lead)
                or ("%ds into it"):format(lead)))
        ns.Print(("      |cff777777%s|r"):format(tostring(e.held.text)))
    end
    if heard > #strangers then
        ns.Print(("|cff777777%d line%s heard in crate zones this session in all --"
            .. " the rest came nowhere near a cycle.|r"):format(
            heard, heard == 1 and "" or "s"))
    end
    ns.Print("|cff777777if a crate cycle started when one of those spoke, this addon cannot"
        .. " see it on your locale -- that line is what it needs.|r")
end

HANDLERS.shard = function()
    local unit = UnitExists("target") and "target" or (UnitExists("mouseover") and "mouseover")
    if not unit then
        return ns.Print("target or mouse over any creature first.")
    end

    local guid = UnitGUID(unit)
    ns.Print("unit GUID: " .. ns.Shard.Label(guid))
    if type(guid) == "string" then
        -- "[^-]*" matches the empty run between every pair of separators as
        -- well as the fields themselves, so counting its matches numbers the
        -- fields 1, 3, 5. Split on the separator instead and keep empties,
        -- which is the layout Shard.FromGUID reads positionally.
        local i = 0
        for field in (guid .. "-"):gmatch("([^-]*)-") do
            i = i + 1
            ns.Print(("  field %d = %s"):format(i, field == "" and "|cff777777(empty)|r" or field))
        end
    end
    local shard, instance = ns.Shard.FromGUID(guid)
    ns.Print(("creature GUID says shard=%s instance=%s"):format(tostring(shard), tostring(instance)))

    -- Height. UnitPosition is the only thing in the API that reports a z at
    -- all: vignettes carry x and y only, and there is no way to ask what the
    -- ground is doing at an arbitrary point. So the question of whether the
    -- descent could be computed instead of measured reduces to whether the
    -- transport can be referenced as a unit -- mouse over it and find out.
    local ok, y, x, z = pcall(UnitPosition, unit)
    if ok and z then
        ns.Print(("|cff33ff99%s has a world position|r: x=%.1f y=%.1f |cffffd100z=%.1f|r"):format(
            unit, x, y, z))
        local okP, py, px, pz = pcall(UnitPosition, "player")
        if okP and pz then
            ns.Print(("  you are at z=%.1f -- |cffffd100%.1f above or below you|r"):format(pz, z - pz))
        end
    else
        ns.Print(("|cffff8800%s reports no world position|r -- no height available for it"):format(unit))
    end

    local list = ns.Scanner.Sweep()
    for _, v in ipairs(list) do
        if v.stage then
            ns.Print(("crate vignette says shard=%s  (%s)"):format(tostring(v.shard), v.stage))
            break
        end
    end
    ns.Print("|cff777777the two should agree. If they do not, the vignette layout differs.|r")
end

-- Every gap between two drops this client has actually seen. The point of
-- sitting in one zone through two drops is to fill this in.
HANDLERS.interval = function(rest)
    -- Same shape as /ewc airtime: numbered, droppable one at a time, resettable
    -- per zone. An observation costs two full cycles on one shard to obtain.
    local dropZone, dropIdx = tostring(rest or ""):lower():match("^drop%s+(%S+)%s+(%d+)$")
    if dropZone then
        local zoneID = ns.ResolveZoneInput(dropZone)
        if not zoneID then return ns.Print(("no zone called '%s'"):format(dropZone)) end
        local list = (ns.db.gaps or {})[zoneID]
        local g = list and list[tonumber(dropIdx)]
        if not g then return ns.Print(("%s has no observation %s"):format(
            ns.GetZoneName(zoneID), dropIdx)) end
        table.remove(list, tonumber(dropIdx))
        return ns.Print(("dropped the %ds observation from %s -- %d left"):format(
            math.floor(g.gap + 0.5), ns.GetZoneName(zoneID), #list))
    end
    local reset = tostring(rest or ""):lower():match("^reset%s*(.*)$")
    if reset then
        if reset ~= "" then
            local zoneID = ns.ResolveZoneInput(reset)
            if not zoneID then return ns.Print(("no zone called '%s'"):format(reset)) end
            ns.db.gaps[zoneID] = nil
            return ns.Print(("interval measurements cleared for %s."):format(
                ns.GetZoneName(zoneID)))
        end
        ns.db.gaps = {}
        return ns.Print("interval measurements cleared.")
    end
    local any = false
    for zoneID in pairs(ns.ZONES) do
        local list = (ns.db.gaps or {})[zoneID]
        if list and #list > 0 then
            any = true
            local n, mean, lo, hi, cycles = ns.Timers.GapStats(ns.db.gaps, zoneID)
            local inUse = ns.GetZoneInterval(zoneID)
            ns.Print(("%s  %d observation%s over %d cycle%s, mean |cffffd100%ds|r, range %d-%d"):format(
                ns.GetZoneName(zoneID), n, n == 1 and "" or "s",
                cycles, cycles == 1 and "" or "s",
                math.floor(mean + 0.5), math.floor(lo + 0.5), math.floor(hi + 0.5)))
            local core, coreN, coreLo, coreHi = ns.Timers.GapCluster(ns.db.gaps, zoneID)
            if core then
                ns.Print(("   core: %d of %d agree within %d-%d, median |cffffd100%ds|r"):format(
                    coreN, n, math.floor(coreLo + 0.5), math.floor(coreHi + 0.5),
                    math.floor(core + 0.5)))
            end
            ns.Print(("   |cff777777shipped %ds; using %s%ds|r"):format(
                ns.GetShippedInterval(zoneID),
                math.abs(inUse - ns.GetShippedInterval(zoneID)) > 0.5 and "|cff33ff99measured " or "shipped ",
                math.floor(inUse + 0.5)))
            for i, g in ipairs(list) do
                ns.Print(("   %2d. %ds%s"):format(i, math.floor(g.gap + 0.5),
                    g.cycles > 1 and (" over %d cycles = %ds each"):format(
                        g.cycles, math.floor(g.per + 0.5)) or "  |cff777777single cycle|r"))
            end
        end
    end
    if not any then
        ns.Print("no intervals measured yet. Sit in one zone through two drops on the same shard.")
        ns.Print("|cff777777for reference: CrateTrackerZK ships 1100, RCT 1098-1099, WarCrateTracker 1095|r")
        return
    end

    -- Single-cycle readings have come in consistently below multi-cycle ones:
    -- 1054 and 1060 against 1086 and 1097, with no overlap between the groups.
    -- Likely because arriving in a zone mid-flight dates the first drop late
    -- while the second, waited for, is caught promptly -- which shortens the
    -- gap. Shown split so the pattern stays visible as more arrive, since if it
    -- holds, single-cycle readings should be excluded rather than merely
    -- weighted down.
    local oneN, oneSum, manyN, manySum, manyCycles = 0, 0, 0, 0, 0
    for _, list in pairs(ns.db.gaps or {}) do
        for _, g in ipairs(list) do
            if g.cycles > 1 then
                manyN, manySum, manyCycles = manyN + 1, manySum + g.gap, manyCycles + g.cycles
            else
                oneN, oneSum = oneN + 1, oneSum + g.gap
            end
        end
    end
    if oneN > 0 and manyN > 0 then
        ns.Print(("|cff777777across all zones: %d single-cycle mean %ds, %d multi-cycle mean %ds|r"):format(
            oneN, math.floor(oneSum / oneN + 0.5),
            manyN, math.floor(manySum / manyCycles + 0.5)))
    end
end

-- What the addon remembers about where each shard's cycle sits, and whether it
-- would still be believed. The error column is the whole point: a phase eight
-- cycles old in a zone whose interval is known to a second is worth showing,
-- and the same phase in a zone that has never been measured here is not.
HANDLERS.phase = function(rest)
    if tostring(rest or ""):lower():match("^reset$") then
        ns.db.phase = ns.Phase.New()
        return ns.Print("phase memory cleared.")
    end

    local now = GetServerTime()
    local zones = {}
    for zoneID, shards in pairs(ns.db.phase or {}) do
        if next(shards) then zones[#zones + 1] = zoneID end
    end
    if #zones == 0 then
        return ns.Print("nothing remembered yet. A spawn seen on a shard is filed against it.")
    end
    table.sort(zones, function(a, b) return ns.GetZoneName(a) < ns.GetZoneName(b) end)

    for _, zoneID in ipairs(zones) do
        local interval = ns.GetZoneInterval(zoneID)
        local drift = ns.Phase.Drift(ns.db.gaps, zoneID, ns.Timers.GapCluster)
        ns.Print(("%s |cff777777interval %ds, drift +/-%.2fs per cycle%s|r"):format(
            ns.GetZoneName(zoneID), math.floor(interval + 0.5), drift,
            drift >= ns.Phase.UNKNOWN_DRIFT and " -- never measured here" or ""))

        -- Split, because one of these lists is worth reading and the other is
        -- worth counting. Zul'Aman held eight records of which one could
        -- answer, and the seven that could not printed a cycle count each --
        -- "27 cycles" read against the zone like the addon had lost it.
        --
        -- Aged out is the only reason that gets collapsed. Any other refusal
        -- is a fault rather than time passing, so it keeps its own line.
        local live, spent, oldest = {}, 0, 0
        for shardID, held in pairs(ns.db.phase[zoneID]) do
            local ts, why, cycles, err, source = ns.Phase.Recall(
                ns.db.phase, zoneID, shardID, interval, now, drift)
            local age = now - held.ts
            if ts or why ~= "drifted too far" then
                live[#live + 1] = { shardID = shardID, age = age, cycles = cycles,
                                    err = err, source = source,
                                    why = (not ts) and why or nil }
            else
                spent = spent + 1
                if age > oldest then oldest = age end
            end
        end

        -- Freshest first: the copy of the zone the player is standing in is
        -- what they opened this to read.
        table.sort(live, function(a, b) return a.age < b.age end)
        for _, r in ipairs(live) do
            local when = r.age >= 3600
                and ("%dh%02dm"):format(math.floor(r.age / 3600), math.floor((r.age % 3600) / 60))
                or ("%dm"):format(math.floor(r.age / 60))
            ns.Print(("   shard %-7s %8s ago, %d cycle%s   %s"):format(
                tostring(r.shardID), when, r.cycles or 0, (r.cycles == 1) and "" or "s",
                r.why and ("|cffff8800%s (+/-%ds)|r"):format(
                        r.why, math.floor((r.err or 0) + 0.5))
                   or ("|cff33ff99+/-%ds, from %s|r"):format(
                        math.floor((r.err or 0) + 0.5), r.source or "unknown")))
        end

        -- Kept rather than deleted, and the line says why: Recall gives up
        -- when the drift this client currently believes in outgrows the
        -- tolerance, and that belief improves as the gaps get measured. A
        -- record refused today is not one that was never any use, and the rest
        -- of this addon flags a reading it cannot use instead of discarding it.
        if spent > 0 then
            ns.Print(("   |cff777777%d other shard%s remembered, drifted too far to use"
                .. " -- oldest %dh. Kept until %d days old, in case the interval here"
                .. " gets measured better.|r"):format(
                spent, spent == 1 and "" or "s", math.floor(oldest / 3600),
                math.floor(ns.Phase.KEEP / 86400)))
        end
        if #live == 0 and spent == 0 then
            ns.Print("   |cff777777nothing remembered here yet.|r")
        end
    end
end

-- The rotation. With no argument it plans; with one it sets the route.
HANDLERS.route = function(rest)
    if rest and rest ~= "" then
        local zones, bad = ns.Route.Parse(rest)
        for _, word in ipairs(bad) do
            ns.Print(("|cffff8800did not recognise|r %s"):format(word))
        end
        if #zones == 0 then
            return ns.Print("nothing usable in that. Try: /ewc route ZA Hd SR VS")
        end
        ns.db.route = zones
        ns.Print("route set: " .. ns.Route.Describe(zones))
    end

    if #ns.db.route == 0 then
        ns.Print("no route yet. Set one with |cffffffff/ewc route ZA Hd SR VS|r")
        return
    end

    local now = GetServerTime()
    local plan = ns.Route.Plan(ns.db.crates, ns.db.route, ns.GetZoneInterval, nil, now)
    local next_ = ns.Route.Next(plan)
    ns.Print("route: " .. ns.Route.Describe(ns.db.route))
    ns.Print("|cff777777         plane     lootable|r")
    for _, row in ipairs(plan) do
        local mark = (row == next_) and "|cff33ff99>|r" or " "
        if row.status == "unknown" then
            ns.Print(("%s %-3s |cff777777nothing timed here yet|r"):format(
                mark, ns.GetZoneAbbr(row.zoneID)))
        else
            local flight = ns.Airtime.Flight(ns.db.flight, row.zoneID)
            local descent = ns.Airtime.Descent(ns.db.descent, row.zoneID)
            ns.Print(("%s %-3s %s   |cffffd100%s|r  |cff777777shard %s%s|r"):format(
                mark, ns.GetZoneAbbr(row.zoneID),
                ns.FormatClock(row.dropIn),
                ns.FormatClock(row.dropIn + flight + descent),
                tostring(row.shardID),
                (row.missed or 0) > 0 and ("  x%d missed"):format(row.missed) or ""))
        end
    end
    if not next_ then
        ns.Print("|cffff5555nothing on this route has a timer yet|r")
    end
end

-- Are the zones' cycles offset from each other by a fixed amount?
--
-- Nobody knows, and it is worth knowing: raids rotate between three and five
-- zones and that only works because the drops do not coincide. If the offset
-- between two zones is CONSTANT, then catching one drop tells you when every
-- other zone is due, and the cold-start problem -- an hour of waiting to learn
-- six zones solo -- disappears without any player-to-player sync.
--
-- This prints the phase of each known timer within its cycle, and the gap
-- between each pair. Run it across sessions: if the same pair keeps showing
-- the same gap, the offset is fixed. If it wanders, it is not, and the idea is
-- dead for the price of looking.
HANDLERS.offsets = function()
    local now = GetServerTime()
    local rows = {}
    for zoneID, shards in pairs(ns.db.crates or {}) do
        local entry, shardID = ns.Route.FreshestForZone(ns.db.crates, zoneID)
        if entry then
            local interval = ns.GetZoneInterval(zoneID)
            rows[#rows + 1] = {
                zoneID = zoneID, shardID = shardID, interval = interval,
                due = ns.Timers.Remaining(entry, interval, now),
                missed = ns.Timers.MissedCycles(entry, interval, now),
                precise = entry.precise,
            }
        end
    end
    if #rows < 2 then
        return ns.Print("need timers in at least two zones to compare their phases.")
    end
    table.sort(rows, function(a, b) return a.due < b.due end)

    ns.Print("phase of each zone within its own cycle:")
    for _, r in ipairs(rows) do
        ns.Print(("  %-3s shard %-7s due in %s  |cff777777cycle %ds%s%s|r"):format(
            ns.GetZoneAbbr(r.zoneID), tostring(r.shardID), ns.FormatClock(r.due),
            math.floor(r.interval + 0.5),
            r.precise and "" or ", seeded from a crate already down",
            (r.missed or 0) > 0 and (", %d missed"):format(r.missed) or ""))
    end

    ns.Print("gap between pairs -- watch whether these repeat across sessions:")
    for i = 1, #rows do
        for j = i + 1, #rows do
            local a, b = rows[i], rows[j]
            ns.Print(("  %s -> %s   %s  |cff777777(shards %s / %s)|r"):format(
                ns.GetZoneAbbr(a.zoneID), ns.GetZoneAbbr(b.zoneID),
                ns.FormatClock(b.due - a.due), tostring(a.shardID), tostring(b.shardID)))
        end
    end
    ns.Print("|cff777777a shard number is per-zone, so equal numbers in two zones mean nothing|r")
end

-- Place a waypoint right here, right now, reporting every step.
--
-- The pin failed to appear twice with nothing on screen to say why, and the
-- prediction path cannot be re-run on demand -- it needs a transport in the
-- air. This takes the question away from crate timing entirely: run it
-- standing anywhere and the answer is on screen in five lines.
HANDLERS.pin = function()
    local raw = C_Map.GetBestMapForUnit("player")
    local zoneID = raw and ns.Zones.Normalize(raw)
    ns.Print(("setting enabled: %s"):format(tostring(ns.db.waypoint)))
    ns.Print(("standing on map %s, which resolves to %s"):format(
        tostring(raw), zoneID and (ns.GetZoneName(zoneID) .. " (" .. zoneID .. ")") or "nothing"))
    ns.Print(("game allows a pin -- on %s: %s | on %s: %s"):format(
        tostring(raw), tostring(ns.PinAllowed(raw)),
        tostring(zoneID), tostring(ns.PinAllowed(zoneID))))

    local pos = zoneID and C_Map.GetPlayerMapPosition(zoneID, "player")
    if not pos then
        return ns.Print("|cffff8800cannot read your position on the zone map -- nothing to test with|r")
    end
    local existing = C_Map.GetUserWaypoint()
    ns.Print(("a pin was already set: %s"):format(existing
        and ("yes, on map %s -- clearing it first"):format(tostring(existing.uiMapID)) or "no"))

    local x, y = pos:GetXY()
    ns.SetCratePin(zoneID, x, y)

    local back = C_Map.GetUserWaypoint()
    if not back then
        ns.Print("|cffff5555the pin did not take -- SetUserWaypoint was refused|r")
    else
        ns.Print(("|cff33ff99pin is set|r on map %s at %.1f, %.1f"):format(
            tostring(back.uiMapID), back.position.x * 100, back.position.y * 100))
        ns.Print(("supertracked: %s |cff777777(this is what puts the arrow on the minimap)|r"):format(
            tostring(C_SuperTrack.IsSuperTrackingUserWaypoint and
                C_SuperTrack.IsSuperTrackingUserWaypoint() or "?")))
        ns.Print("|cff777777it was placed where you are standing -- open the map and look|r")
    end
end

HANDLERS.watch = function()
    ns.db.watch = not ns.db.watch
    ns.Print("live tracking readout " .. (ns.db.watch and "on" or "off"))
end

HANDLERS.chatter = function()
    ns.db.chatter = not ns.db.chatter
    ns.Print(("chat narration is now %s"):format(
        ns.db.chatter and "|cff33ff99on|r" or "|cffff8800off|r"
        .. " |cff777777-- still written to the log, and commands still answer|r"))
end

HANDLERS.verbose = function()
    ns.db.verbose = not ns.db.verbose
    ns.Print("verbose " .. (ns.db.verbose and "on" or "off"))
end

HANDLERS.waypoint = function()
    ns.db.waypoint = not ns.db.waypoint
    ns.Print("waypoint on prediction " .. (ns.db.waypoint and "on" or "off"))
end

HANDLERS.wipe = function()
    ns.db.crates = ns.Timers.New()
    ns.Scanner.Reset()
    ns.Print("timers and tracks cleared.")
end

-- Handing the measurements to somebody else, and taking theirs.
--
-- A single-line edit box in a popup, because WoW's chat frame cannot be
-- selected from: a string printed there can be read and not copied, which for
-- a 1500-character string is the same as not having it. Everything about the
-- box is set explicitly -- the length cap above all, which defaults low enough
-- to cut a real export in half and would do it without a word.
local SHARE_POPUP = "EASYWARCRATES_SHARE"

local function shareBox(dialog)
    return dialog and (dialog.editBox
        or (dialog.GetName and dialog:GetName() and _G[dialog:GetName() .. "EditBox"]))
end

StaticPopupDialogs[SHARE_POPUP] = {
    text = "%s",
    button1 = OKAY,
    button2 = CANCEL,
    hasEditBox = true,
    editBoxWidth = 350,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, data)
        local box = shareBox(self)
        if not box then
            return ns.Print("|cffff8800this build of the game would not give us a text box|r")
        end
        pcall(function()
            box:SetMaxLetters(0)
            box:SetMaxBytes(0)
            box:SetAutoFocus(true)
            box:SetText((data and data.text) or "")
            if data and data.text then box:HighlightText() end
            box:SetFocus()
        end)
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        local data = dialog and dialog.data
        if data and data.onAccept then data.onAccept(self:GetText()) end
        dialog:Hide()
    end,
    OnAccept = function(self, data)
        local box = shareBox(self)
        if data and data.onAccept then data.onAccept(box and box:GetText() or "") end
    end,
}

HANDLERS.export = function()
    local text = ns.Share.Export(ns.db)
    local readings = select(2, text:gsub("~d:", ""))
    local points = select(2, text:gsub("~l:", ""))
    ns.Print(("%d parachute time%s and %d drop point%s of your own, ready to copy."):format(
        readings, readings == 1 and "" or "s", points, points == 1 and "" or "s"))
    -- Said because the omissions are deliberate and a player comparing this
    -- with what the data panel shows would otherwise think it lost something.
    ns.Print("|cff777777timers, shards and cycle gaps are left out: they belong to one copy"
        .. " of one zone at one moment, so they are no use on anybody else's screen.|r")
    StaticPopup_Show(SHARE_POPUP, "Ctrl+C to copy. This is yours to give away.",
        nil, { text = text })
end

local function report(ok, got)
    if not ok then
        return ns.Print(("|cffff8800nothing imported:|r %s"):format(tostring(got)))
    end
    ns.Print(("imported %d parachute time%s and %d drop point%s."):format(
        got.descent, got.descent == 1 and "" or "s",
        got.points, got.points == 1 and "" or "s"))
    if got.known > 0 then
        ns.Print(("  |cff777777%d point%s already known|r"):format(
            got.known, got.known == 1 and " was" or "s were"))
    end
    -- The one outcome worth explaining rather than counting: it means their
    -- readings were dropped to keep this client's own.
    if got.full > 0 then
        ns.Print(("  |cff777777%d reading%s nowhere to go: those zones hold %d each and"
            .. " yours are not thrown out to make room|r"):format(
            got.full, got.full == 1 and " had" or "s had", ns.Airtime.MAX_READINGS))
    end
    if ns.RefreshWindow then ns.RefreshWindow() end
end

HANDLERS.import = function(rest)
    if rest and rest ~= "" then
        return report(ns.Share.Import(ns.db, rest, "import"))
    end
    StaticPopup_Show(SHARE_POPUP, "Paste their string here, then Enter.", nil,
        { onAccept = function(text)
            report(ns.Share.Import(ns.db, (text or ""):gsub("%s", ""), "import"))
        end })
end

-- Who in the group is running this addon, which is the one thing a leader
-- cannot work out by looking: it says nothing until somebody sees a crate, so
-- an empty window means either nobody is reporting or nobody has it.
HANDLERS.check = function()
    if ns.Comm.AskCheck() == "alone" then
        return ns.Print("|cff777777you are not in a group, so there is nobody to ask.|r")
    end
    ns.Print(("asking the group... |cff777777(answers come in over %d seconds)|r"):format(
        ns.Comm.CHECK_WINDOW))

    C_Timer.After(ns.Comm.CHECK_WINDOW, function()
        local roll = ns.Remote.RollCall(ns.Comm.Roster(), ns.Comm.checkHeard,
            ns.Version(), UnitName("player"))
        local have = 0
        for _, r in ipairs(roll) do
            if r.state ~= "silent" then have = have + 1 end
        end
        ns.Print(("%d of %d in the group answered"):format(have, #roll))
        for _, r in ipairs(roll) do
            local name = r.state == "you" and "|cffffd100you|r" or r.name
            if r.state == "silent" then
                -- Not "does not have it". A client with the addon switched off
                -- does not answer either, and the two cannot be told apart
                -- from here, so the line says what was observed.
                ns.Print(("  |cffff5555%s|r |cff777777no answer: not installed, or"
                    .. " switched off|r"):format(name))
            else
                ns.Print(("  %s |cff777777%s%s|r"):format(name, r.version or "?",
                    r.state == "behind" and ", older than yours"
                        or (r.sharing == false and ", sharing off -- hears you, says nothing" or "")))
            end
        end
    end)
end

-- What the hour is paying, and a way to start the measurement over at the top
-- of a rotation.
HANDLERS.earn = function(rest)
    if rest == "reset" then
        ns.Earn.Reset(ns.earn, GetServerTime())
        ns.SampleEarnings()
        if ns.RefreshWindow then ns.RefreshWindow() end
        return ns.Print("counting from now.")
    end

    local honor, conquest, span = ns.Earn.Rate(ns.earn, GetServerTime())
    if not conquest then
        return ns.Print(("|cff777777%dm measured so far; a rate needs %dm.|r"):format(
            math.floor((span or 0) / 60), math.floor(ns.Earn.MIN_SPAN / 60)))
    end
    local got = ns.Earn.Session(ns.earn)
    ns.Print(("|cffffd100%d|r conquest and |cffffd100%d|r honor an hour"):format(
        conquest, honor))
    ns.Print(("  |cff777777%d conquest and %d honor in the last %dm|r"):format(
        got.conquest, got.honor, math.floor(got.span / 60)))
    ns.Print("  |cff777777'/ewc earn reset' starts over|r")
end

HANDLERS.help = function()
    ns.Print("commands:")
    ns.Print("  /ewc window   -- show or hide the tracker window")
    ns.Print("  /ewc config   -- open the settings panel")
    ns.Print("  /ewc data     -- timers, measurements and the route, with a way to remove any")
    ns.Print("  /ewc export   -- your parachute times and drop points as a string to hand over")
    ns.Print("  /ewc import   -- take somebody else's string, with a box to paste it into")
    ns.Print("  /ewc check    -- who in your group is running this, and on which version")
    ns.Print("  /ewc earn     -- conquest and honor an hour, with 'reset' to start over")
    ns.Print("  /ewc pin      -- test placing a map pin where you stand")
    ns.Print("  /ewc status   -- what zone the addon thinks you are in")
    ns.Print("  /ewc map      -- the map chain above you, and what it resolves to")
    ns.Print("  /ewc geo      -- where the six zones sit relative to each other")
    ns.Print("  /ewc scan     -- every vignette in range, raw. Use this first on a new patch")
    ns.Print("  /ewc scan seen-- ids seen before that this addon does not track; 'reset' clears")
    ns.Print("  /ewc yells    -- what the crate announcer said, and whether it counted")
    ns.Print("  /ewc comm     -- what other players and their addons are broadcasting")
    ns.Print("  /ewc announce -- post where you stand to the group, as a pin they can click")
    ns.Print("  /ewc predict  -- live heading fit and where it points")
    ns.Print("  /ewc points   -- catalogued drop spots for this zone")
    ns.Print("  /ewc route    -- the rotation, when each transport comes and when it lands")
    ns.Print("  /ewc timers   -- tracked crate timers")
    ns.Print("  /ewc interval -- measured gaps; 'drop ZONE N', 'reset [ZONE]'")
    ns.Print("  /ewc phase    -- remembered cycle positions per shard; 'reset'")
    ns.Print("  /ewc offsets  -- whether the zones' cycles sit at a fixed offset")
    ns.Print("  /ewc airtime  -- parachute times per drop point; 'reset [ZONE]',"
        .. " and 'drop ZONE N' for the numbers verbose lists")
    ns.Print("  /ewc shard    -- cross-check the shard number against a creature GUID")
    ns.Print("  /ewc watch    -- toggle the live readout while a transport is tracked")
    ns.Print("  /ewc waypoint -- toggle the map pin on a prediction")
    ns.Print("  /ewc chatter  -- toggle whether the addon talks in chat at all")
    ns.Print("  /ewc verbose  -- toggle scan narration")
    ns.Print("  /ewc locale   -- what language announcements go out in, and a preview")
    ns.Print("  /ewc wipe     -- clear timers")
end

SLASH_EASYWARCRATES1 = "/ewc"
SLASH_EASYWARCRATES2 = "/easywarcrates"
SlashCmdList.EASYWARCRATES = function(msg)
    local cmd, rest = tostring(msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    local handler = HANDLERS[cmd:lower()] or (cmd == "" and HANDLERS.status) or HANDLERS.help
    local ok, err = pcall(handler, rest)
    if not ok then
        ns.Print(("|cffff8800/ewc %s broke partway:|r %s"):format(
            cmd == "" and "status" or cmd, tostring(err)))
    end
end
