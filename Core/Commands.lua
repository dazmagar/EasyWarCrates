local ADDON, ns = ...

-- Diagnostics before features. Until a crate has actually been watched in
-- Midnight 12.2 these commands are the whole point of the addon: they report
-- what the game is really sending, so a wrong assumption shows up as a number
-- on screen instead of as silence.

local function fmtPct(v) return v and string.format("%.1f", v * 100) or "?" end

local HANDLERS = {}

HANDLERS.status = function()
    local rawMap = C_Map.GetBestMapForUnit("player")
    local zoneID = rawMap and ns.Zones.Normalize(rawMap)
    ns.Print("version " .. ns.version .. ", enabled=" .. tostring(ns.db.enabled)
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
HANDLERS.scan = function()
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
    if not r.ok then
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
HANDLERS.shard = function()
    local unit = UnitExists("target") and "target" or (UnitExists("mouseover") and "mouseover")
    if not unit then
        return ns.Print("target or mouse over any creature first.")
    end

    local guid = UnitGUID(unit)
    ns.Print("unit GUID: " .. ns.Shard.Label(guid))
    if type(guid) == "string" then
        local i = 0
        for field in string.gmatch(guid, "[^-]*") do
            i = i + 1
            if field ~= "" then ns.Print(("  field %d = %s"):format(i, field)) end
        end
    end
    local shard, instance = ns.Shard.FromGUID(guid)
    ns.Print(("creature GUID says shard=%s instance=%s"):format(tostring(shard), tostring(instance)))

    local list = ns.Scanner.Sweep()
    for _, v in ipairs(list) do
        if v.stage then
            ns.Print(("crate vignette says shard=%s  (%s)"):format(tostring(v.shard), v.stage))
            break
        end
    end
    ns.Print("|cff777777the two should agree. If they do not, the vignette layout differs.|r")
end

HANDLERS.watch = function()
    ns.db.watch = not ns.db.watch
    ns.Print("live tracking readout " .. (ns.db.watch and "on" or "off"))
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

HANDLERS.help = function()
    ns.Print("commands:")
    ns.Print("  /ewc status   -- what zone the addon thinks you are in")
    ns.Print("  /ewc map      -- the map chain above you, and what it resolves to")
    ns.Print("  /ewc geo      -- where the six zones sit relative to each other")
    ns.Print("  /ewc scan     -- every vignette in range, raw. Use this first on a new patch")
    ns.Print("  /ewc predict  -- live heading fit and where it points")
    ns.Print("  /ewc points   -- catalogued drop spots for this zone")
    ns.Print("  /ewc timers   -- tracked crate timers")
    ns.Print("  /ewc shard    -- cross-check the shard number against a creature GUID")
    ns.Print("  /ewc watch    -- toggle the live readout while a transport is tracked")
    ns.Print("  /ewc waypoint -- toggle the map pin on a prediction")
    ns.Print("  /ewc verbose  -- toggle scan narration")
    ns.Print("  /ewc wipe     -- clear timers")
end

SLASH_EASYWARCRATES1 = "/ewc"
SLASH_EASYWARCRATES2 = "/easywarcrates"
SlashCmdList.EASYWARCRATES = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    local handler = HANDLERS[cmd] or (cmd == "" and HANDLERS.status) or HANDLERS.help
    handler()
end
