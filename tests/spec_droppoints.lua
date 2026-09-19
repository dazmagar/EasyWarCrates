local ns, t = ...

t.test("catalogue has the expected shape", function()
    local zones, spots = 0, 0
    for _, list in pairs(ns.DropPointsPct) do
        zones = zones + 1
        spots = spots + #list
    end
    t.eq(zones, 31, "zone count")
    t.eq(spots, 220, "spot count")
end)

-- The one unit conversion in the addon. Data/DropPoints.lua is authored in
-- percent because that is how the source data and players read coordinates,
-- and everything downstream speaks map fractions. Pinned for every entry
-- rather than a sample, since a half-converted table would still look sane.
t.test("percent table converts to fractions entry for entry", function()
    for mapID, pct in pairs(ns.DropPointsPct) do
        local frac = ns.DropPoints[mapID]
        t.ok(frac, "zone " .. mapID .. " missing from the fraction table")
        t.eq(#frac, #pct, "zone " .. mapID .. " length")
        for i = 1, #pct do
            t.near(frac[i].x, pct[i][1] / 100, 1e-12, "zone " .. mapID .. " spot " .. i .. " x")
            t.near(frac[i].y, pct[i][2] / 100, 1e-12, "zone " .. mapID .. " spot " .. i .. " y")
            t.eq(frac[i].n, pct[i][3], "zone " .. mapID .. " spot " .. i .. " n")
        end
    end
end)

t.test("every coordinate lands inside the map", function()
    for mapID, spots in pairs(ns.DropPoints) do
        for i, s in ipairs(spots) do
            t.ok(s.x >= 0 and s.x <= 1, "zone " .. mapID .. " spot " .. i .. " x out of range: " .. s.x)
            t.ok(s.y >= 0 and s.y <= 1, "zone " .. mapID .. " spot " .. i .. " y out of range: " .. s.y)
            t.ok(s.n >= 1, "zone " .. mapID .. " spot " .. i .. " has no observations behind it")
        end
    end
end)

-- Two spots inside one zone closer than this would be one spot recorded twice,
-- and would make Predict ambiguous forever between them.
t.test("no two spots in a zone sit within 1% of the map", function()
    for mapID, spots in pairs(ns.DropPoints) do
        for i = 1, #spots do
            for j = i + 1, #spots do
                local dx = spots[i].x - spots[j].x
                local dy = spots[i].y - spots[j].y
                local d = math.sqrt(dx * dx + dy * dy)
                t.ok(d >= 0.01, string.format(
                    "zone %d spots %d and %d are %.4f apart", mapID, i, j, d))
            end
        end
    end
end)

t.test("Azj-Kahet is present and readable", function()
    local spots = ns.ShippedDropPoints(2255)
    t.ok(spots, "2255 should be catalogued")
    t.eq(#spots, 5, "Azj-Kahet spot count")
end)

t.test("an untracked map returns nothing rather than an empty table", function()
    t.eq(ns.ShippedDropPoints(9999999), nil)
end)
