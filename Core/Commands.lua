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

    ns.Print("time under the parachute -- the middle reading, per zone:")
    local any = false
    for zoneID in pairs(ns.ZONES) do
        local mean, n, lo, hi, over, _, source = ns.Airtime.Descent(ns.db.descent, zoneID)
        if n > 0 then
            any = true
            ns.Print(("  %-3s %3ds  |cff777777%s%d drop%s, range %d-%d%s|r"):format(
                ns.GetZoneAbbr(zoneID), math.floor(mean + 0.5),
                -- A figure this zone borrowed must not read like one it
                -- measured. Eversong's own readings average out to 64s, which
                -- is not a time any crate there has ever taken.
                source == "pooled" and "its readings disagree, so this is every zone's " or "from ",
                n, n == 1 and "" or "s",
                math.floor(lo + 0.5), math.floor(hi + 0.5),
                ""))
            for i, d in ipairs(ns.Airtime.DescentSamples(ns.db.descent, zoneID) or {}) do
                -- The overlap flag is not shown: it fired on 19 readings out
                -- of 19, so it separates nothing. The release lag might.
                ns.Print(("   %2d. %3ds  %s%s%s%s%s"):format(i, math.floor(d.secs + 0.5),
                    d.x and ("|cff777777at %.1f, %.1f|r"):format(d.x, d.y) or "|cff777777spot not recorded|r",
                    -- The open question: does a fall watched from further away
                    -- read short because its parachute is drawn late.
                    d.dist and ("  |cffffd100%.1f%% away|r"):format(d.dist) or "",
                    d.lag and ("  |cff777777%ds circling first|r"):format(d.lag) or "",
                    d.flip and ("  |cff33ff99art changed at %ds|r"):format(d.flip) or "",
                    d.partial and ("  |cffff8800not counted: %s|r"):format(
                        d.why or "joined mid-fall") or ""))
            end
        else
            ns.Print(("  %-3s %3ds  |cff777777guess, nothing measured here|r"):format(
                ns.GetZoneAbbr(zoneID), math.floor(mean + 0.5)))
        end
    end
    if not any then
        ns.Print("|cff777777measured when a crate is watched from parachute to ground|r")
    end
    ns.Print("|cff777777the other leg -- transport to drop point -- is computed from its speed, not learned|r")
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
    ns.Print(("reports held: %d%s"):format(ns.Remote.Count(ns.remote, GetServerTime()),
        (ns.Comm.handshakes or 0) > 0
            and ("  |cff777777(%d token handshakes ignored -- somebody's RCT is talking)|r")
                :format(ns.Comm.handshakes)
            or ""))

    local heard = ns.Comm.heard
    if #heard == 0 then
        return ns.Print("|cff777777nothing heard yet. Addon traffic only reaches you from"
            .. " your own party, raid or guild, so alone you will see nothing.|r")
    end
    local now = GetServerTime()
    for i = 1, #heard do
        local h = heard[i]
        ns.Print(("|cff777777%3ds|r [%s] |cffffffff%s|r %s |cff777777(%s)|r"):format(
            now - h.at, tostring(h.via), tostring(h.from), tostring(h.text),
            tostring(h.verdict)))
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
    if #heard == 0 then
        return ns.Print("|cff777777none of them has said anything yet. They speak when a cycle"
            .. " starts, so this stays empty until you sit through one.|r")
    end

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

        local shards = {}
        for shardID in pairs(ns.db.phase[zoneID]) do shards[#shards + 1] = shardID end
        table.sort(shards, function(a, b) return tostring(a) < tostring(b) end)

        for _, shardID in ipairs(shards) do
            local held = ns.db.phase[zoneID][shardID]
            local ts, why, cycles, err, source = ns.Phase.Recall(
                ns.db.phase, zoneID, shardID, interval, now, drift)
            local age = now - held.ts
            local when = age >= 3600
                and ("%dh%02dm"):format(math.floor(age / 3600), math.floor((age % 3600) / 60))
                or ("%dm"):format(math.floor(age / 60))
            ns.Print(("   shard %-7s %8s ago, %d cycle%s   %s"):format(
                tostring(shardID), when, cycles or 0, (cycles == 1) and "" or "s",
                ts and ("|cff33ff99+/-%ds, from %s|r"):format(
                        math.floor((err or 0) + 0.5), source or "unknown")
                   or ("|cffff8800%s (+/-%ds)|r"):format(why, math.floor((err or 0) + 0.5))))
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
    local plan = ns.Route.Plan(ns.db.crates, ns.db.route, ns.GetZoneInterval, now)
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
        tostring(raw), tostring(raw and C_Map.CanSetUserWaypoint(raw)),
        tostring(zoneID), tostring(zoneID and C_Map.CanSetUserWaypoint(zoneID))))

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
    ns.Print("  /ewc window   -- show or hide the tracker window")
    ns.Print("  /ewc config   -- open the settings panel")
    ns.Print("  /ewc data     -- timers, measurements and the route, with a way to remove any")
    ns.Print("  /ewc pin      -- test placing a map pin where you stand")
    ns.Print("  /ewc status   -- what zone the addon thinks you are in")
    ns.Print("  /ewc map      -- the map chain above you, and what it resolves to")
    ns.Print("  /ewc geo      -- where the six zones sit relative to each other")
    ns.Print("  /ewc scan     -- every vignette in range, raw. Use this first on a new patch")
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
    ns.Print("  /ewc airtime  -- measured parachute times; 'drop ZONE N', 'reset [ZONE]'")
    ns.Print("  /ewc shard    -- cross-check the shard number against a creature GUID")
    ns.Print("  /ewc watch    -- toggle the live readout while a transport is tracked")
    ns.Print("  /ewc waypoint -- toggle the map pin on a prediction")
    ns.Print("  /ewc verbose  -- toggle scan narration")
    ns.Print("  /ewc wipe     -- clear timers")
end

SLASH_EASYWARCRATES1 = "/ewc"
SLASH_EASYWARCRATES2 = "/easywarcrates"
SlashCmdList.EASYWARCRATES = function(msg)
    local cmd, rest = tostring(msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    local handler = HANDLERS[cmd:lower()] or (cmd == "" and HANDLERS.status) or HANDLERS.help
    handler(rest)
end
