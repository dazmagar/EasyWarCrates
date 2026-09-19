local ns, t = ...

-- Core/Main.lua cannot be loaded out of game, so its defaults table is checked
-- by reading the file. Crude, but it catches the failure it was written for: a
-- store listed as `nil` in DEFAULTS is a key that does not exist, so the
-- pairs() loop never seeds it, and the module that reads it goes quietly dead.
-- Shipped exactly that with db.learned -- learning was wired up, tested, and
-- could not have worked once in game.

local function mainSource()
    local f = io.open(ns.__root .. "/Core/Main.lua", "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

t.test("Main.lua is readable for these checks", function()
    t.ok(mainSource(), "could not open Core/Main.lua")
end)

t.test("every store listed as nil in DEFAULTS is seeded explicitly", function()
    local src = mainSource()
    local defaults = src:match("local DEFAULTS = %{(.-)\n%}")
    t.ok(defaults, "could not find the DEFAULTS table")

    local seeded = {}
    for key in src:gmatch("db%.(%w+)%s*=%s*db%.%w+%s*or") do seeded[key] = true end

    local checked = 0
    for key in defaults:gmatch("(%w+)%s*=%s*nil") do
        checked = checked + 1
        t.ok(seeded[key], string.format(
            "DEFAULTS.%s is nil, so the defaults loop skips it -- it needs an explicit "
            .. "db.%s = db.%s or ... line, or it stays nil forever", key, key, key))
    end
    t.ok(checked > 0, "expected at least one nil-valued store in DEFAULTS")
end)

t.test("nothing reads a store that is never seeded", function()
    local src = mainSource()
    local defaults = src:match("local DEFAULTS = %{(.-)\n%}")
    local known = {}
    for key in defaults:gmatch("(%w+)%s*=") do known[key] = true end

    for key in src:gmatch("ns%.db%.(%w+)") do
        t.ok(known[key], string.format(
            "Main.lua reads ns.db.%s, which is not in DEFAULTS -- it will be nil "
            .. "on a fresh profile", key))
    end
end)

-- Learn treats a missing store as bad input rather than creating one, so the
-- seeding above is the only thing standing between it and silence. Pinned so
-- the contract is stated somewhere rather than assumed.
t.test("Learn refuses a nil store instead of inventing one", function()
    t.eq(ns.Learn.Note(nil, 2413, 0.5, 0.5), "invalid")
end)
