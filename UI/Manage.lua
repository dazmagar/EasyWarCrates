local ADDON, ns = ...

-- What the data panel lists, and what removing a row does.
--
-- Same split as UI/Model.lua: this decides the rows, UI/DataPanel.lua paints
-- them and cannot be tested at all. The stores arrive as arguments rather than
-- off ns.db, which is what lets tests/ drive this outside the game.
--
-- Every row carries a stamp of the record it stands for, and Remove refuses
-- when the stamp no longer matches. A row holds an index into a list that goes
-- on growing while the panel is open, so a descent reading landing between
-- painting a row and clicking its button would otherwise delete a different
-- reading than the one on screen, and say nothing about it.

local Manage = {}
ns.Manage = Manage

local SECTIONS = {
    {
        id = "timers", title = "Timers",
        note = "One per zone and shard. The shard re-rolls every time you fly "
            .. "out and back, so the old ones are for copies of a zone you will "
            .. "not stand in again.",
    },
    {
        id = "descent", title = "Descent",
        note = "How long a crate takes to come down, per zone. The middle "
            .. "reading is what gets used, so one bad one does not move the "
            .. "answer far, but it still does not belong here.",
    },
    {
        id = "interval", title = "Intervals",
        note = "Gaps between two drops on one shard. The only direct "
            .. "measurement of the cycle anybody gets.",
    },
    {
        id = "spots", title = "Drop points",
        note = "Landing spots the shipped catalogue did not have. The shipped "
            .. "ones are not listed and cannot be removed.",
    },
    {
        id = "route", title = "Route",
        note = "The rotation, in the order you fly it.",
    },
    {
        id = "travel", title = "Travel",
        note = "Seconds from the capital, for the zones where you have "
            .. "overridden the shipped estimate.",
    },
}
Manage.SECTIONS = SECTIONS

-- pairs() promises no order and in practice changes it between calls, which
-- would reshuffle the list under the cursor.
local function zonesIn(store)
    local out = {}
    for zoneID, list in pairs(store or {}) do
        if type(list) == "table" and next(list) then out[#out + 1] = zoneID end
    end
    table.sort(out, function(a, b) return ns.GetZoneName(a) < ns.GetZoneName(b) end)
    return out
end

local SOURCE_TEXT = {
    yell    = "announced by an NPC",
    flying  = "caught in the air",
    falling = "seen to drop",
    midfall = "joined mid-fall",
    ground  = "found on the ground",
    claimed = "found already looted",
    manual  = "typed in by hand",
}

local builders = {}

builders.timers = function(db, now)
    local rows = {}
    for _, t in ipairs(ns.Timers.Sorted(db.crates, ns.GetZoneInterval, now)) do
        local missed = t.missed or 0
        local note = SOURCE_TEXT[t.entry.source] or tostring(t.entry.source)
        if t.entry.via then
            note = ("%s, from %s"):format(note, t.entry.via)
        end
        if missed > 0 then
            note = ("%s, %d cycle%s unseen"):format(note, missed, missed == 1 and "" or "s")
        end
        rows[#rows + 1] = {
            section = "timers",
            zoneID  = t.zoneID,
            shardID = t.shardID,
            stamp   = t.entry.ts,
            label   = ("%s  shard %s"):format(ns.GetZoneAbbr(t.zoneID), tostring(t.shardID)),
            value   = t.remaining and ns.FormatClock(t.remaining) or "   --",
            note    = note,
            dim     = missed > ns.Model.STALE_CYCLES,
        }
    end
    return rows
end

builders.descent = function(db)
    local rows = {}
    for _, zoneID in ipairs(zonesIn(db.descent)) do
        local list = db.descent[zoneID]
        local mid, n, _, _, over, part = ns.Airtime.Descent(db.descent, zoneID)
        rows[#rows + 1] = {
            head = true, zoneID = zoneID, label = ns.GetZoneName(zoneID),
            value = n > 0 and ("median %.0fs over %d"):format(mid, n)
                or "no full readings yet",
            note = part > 0
                and ("%d partial, %d with the parachute still drawn"):format(part, over)
                or nil,
        }
        for i = 1, #list do
            local d = list[i]
            local bits = {}
            if d.x and d.y then bits[#bits + 1] = ("%.1f, %.1f"):format(d.x, d.y) end
            if d.partial then bits[#bits + 1] = "joined mid-fall, not counted" end
            if d.overlapped then bits[#bits + 1] = "parachute still drawn" end
            if d.dist then bits[#bits + 1] = ("%.1f%% away"):format(d.dist) end
            if d.lag then bits[#bits + 1] = ("circled %ds first"):format(d.lag) end
            if d.flip then bits[#bits + 1] = ("art changed at %ds"):format(d.flip) end
            rows[#rows + 1] = {
                section = "descent", zoneID = zoneID, index = i, stamp = d.secs,
                label = ("   %d."):format(i),
                value = ("%ds"):format(d.secs),
                note  = table.concat(bits, ", "),
                dim   = d.partial and true or false,
            }
        end
    end
    return rows
end

builders.interval = function(db)
    local rows = {}
    for _, zoneID in ipairs(zonesIn(db.gaps)) do
        local list = db.gaps[zoneID]
        local n, mean, _, _, cycles = ns.Timers.GapStats(db.gaps, zoneID)
        rows[#rows + 1] = {
            head = true, zoneID = zoneID, label = ns.GetZoneName(zoneID),
            value = n and ("%.0fs over %d cycle%s"):format(mean, cycles, cycles == 1 and "" or "s")
                or "nothing measured",
        }
        for i = 1, #list do
            local g = list[i]
            rows[#rows + 1] = {
                section = "interval", zoneID = zoneID, index = i, stamp = g.gap,
                label = ("   %d."):format(i),
                value = ("%.0fs"):format(g.per),
                note  = g.cycles > 1
                    and ("%ds across %d drops"):format(g.gap, g.cycles)
                    or "one drop to the next",
            }
        end
    end
    return rows
end

builders.spots = function(db)
    local rows = {}
    for _, zoneID in ipairs(zonesIn(db.learned)) do
        local list = db.learned[zoneID]
        rows[#rows + 1] = {
            head = true, zoneID = zoneID, label = ns.GetZoneName(zoneID),
            value = ("%d not in the catalogue"):format(#list),
        }
        for i = 1, #list do
            local s = list[i]
            local seen = s.n or 1
            rows[#rows + 1] = {
                section = "spots", zoneID = zoneID, index = i, stamp = s.x,
                label = ("   %d."):format(i),
                value = ("%.1f, %.1f"):format(s.x * 100, s.y * 100),
                note  = ("%d sighting%s"):format(seen, seen == 1 and "" or "s"),
                dim   = seen < 2,
            }
        end
    end
    return rows
end

builders.route = function(db)
    local rows, route = {}, db.route or {}
    for i = 1, #route do
        local zoneID = route[i]
        rows[#rows + 1] = {
            section = "route", zoneID = zoneID, index = i, stamp = zoneID,
            label = ("%d.  %s"):format(i, ns.GetZoneName(zoneID)),
            value = ("%ds out"):format(ns.GetZoneTravel(zoneID)),
            movable = true,
        }
    end
    return rows
end

builders.travel = function(db)
    local rows, store, ids = {}, db.travel or {}, {}
    for zoneID in pairs(store) do ids[#ids + 1] = zoneID end
    table.sort(ids, function(a, b) return ns.GetZoneName(a) < ns.GetZoneName(b) end)
    for _, zoneID in ipairs(ids) do
        local z = ns.GetZone(zoneID)
        rows[#rows + 1] = {
            section = "travel", zoneID = zoneID, stamp = store[zoneID],
            label = ns.GetZoneName(zoneID),
            value = ("%ds"):format(store[zoneID]),
            note  = ("shipped estimate %ds"):format(z and z.travel or 90),
        }
    end
    return rows
end

function Manage.Rows(db, sectionID, now)
    local build = builders[sectionID]
    if not build then return {} end
    return build(db or {}, now or 0)
end

-- Removable rows only, for the count beside a section's name.
function Manage.Count(db, sectionID, now)
    local n = 0
    for _, row in ipairs(Manage.Rows(db, sectionID, now)) do
        if not row.head then n = n + 1 end
    end
    return n
end

local function removeFromList(store, row, field)
    local list = store and store[row.zoneID]
    local rec = list and list[row.index]
    if not rec then return false, "gone" end
    if rec[field] ~= row.stamp then return false, "changed" end
    table.remove(list, row.index)
    if #list == 0 then store[row.zoneID] = nil end
    return true
end

local removers = {}

removers.timers = function(db, row)
    local shards = db.crates and db.crates[row.zoneID]
    local entry = shards and shards[row.shardID]
    if not entry then return false, "gone" end
    if entry.ts ~= row.stamp then return false, "changed" end
    shards[row.shardID] = nil
    if not next(shards) then db.crates[row.zoneID] = nil end
    return true
end

removers.descent  = function(db, row) return removeFromList(db.descent, row, "secs") end
removers.interval = function(db, row) return removeFromList(db.gaps, row, "gap") end
removers.spots    = function(db, row) return removeFromList(db.learned, row, "x") end

removers.route = function(db, row)
    local route = db.route
    if not route or not route[row.index] then return false, "gone" end
    if route[row.index] ~= row.stamp then return false, "changed" end
    table.remove(route, row.index)
    return true
end

removers.travel = function(db, row)
    local store = db.travel
    if not store or store[row.zoneID] == nil then return false, "gone" end
    if store[row.zoneID] ~= row.stamp then return false, "changed" end
    store[row.zoneID] = nil
    return true
end

-- true, or false plus a reason. "changed" is the stamp guard refusing to
-- delete something other than what the row was showing.
function Manage.Remove(db, row)
    if type(db) ~= "table" or type(row) ~= "table" or row.head then return false, "invalid" end
    local remove = removers[row.section]
    if not remove then return false, "invalid" end
    return remove(db, row)
end

local STORE_OF = {
    timers   = "crates",
    descent  = "descent",
    interval = "gaps",
    spots    = "learned",
    travel   = "travel",
}

local function sizeOf(v)
    if type(v) ~= "table" then return 1 end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n
end

-- A whole section, or one zone of it. Returns how many records went.
function Manage.Clear(db, sectionID, zoneID)
    if type(db) ~= "table" then return 0 end
    if sectionID == "route" then
        local n = #(db.route or {})
        db.route = {}
        return n
    end
    local key = STORE_OF[sectionID]
    local store = key and db[key]
    if type(store) ~= "table" then return 0 end

    if zoneID then
        if store[zoneID] == nil then return 0 end
        local n = sizeOf(store[zoneID])
        store[zoneID] = nil
        return n
    end

    local n = 0
    for _, v in pairs(store) do n = n + sizeOf(v) end
    db[key] = {}
    return n
end

-- delta is -1 to move a route entry earlier, 1 to move it later.
function Manage.Move(db, row, delta)
    local route = type(db) == "table" and db.route
    if type(route) ~= "table" or type(row) ~= "table" or row.section ~= "route" then
        return false, "invalid"
    end
    local i = row.index
    if route[i] ~= row.stamp then return false, "changed" end
    local j = i + delta
    if j < 1 or j > #route then return false, "edge" end
    route[i], route[j] = route[j], route[i]
    return true
end

function Manage.AddToRoute(db, zoneID)
    if type(db) ~= "table" or not ns.ZONES[zoneID] then return false, "invalid" end
    db.route = db.route or {}
    for i = 1, #db.route do
        if db.route[i] == zoneID then return false, "already" end
    end
    db.route[#db.route + 1] = zoneID
    return true
end
