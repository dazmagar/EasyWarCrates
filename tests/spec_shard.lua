local ns, t = ...
local Shard = ns.Shard

-- Creature-0-<server>-<instance>-<shard>-<npc>-<spawn>
local REAL = "Creature-0-3299-2444-128-231088-00003AB2C1"

t.test("a creature GUID gives up its shard and instance", function()
    local shard, instance = Shard.FromGUID(REAL)
    t.eq(shard, 128, "field five is the shard")
    t.eq(instance, 2444, "field four is the instance")
end)

t.test("a different shard on the same zone reads differently", function()
    t.eq(Shard.FromGUID("Creature-0-3299-2444-57-231088-00003AB2C1"), 57)
end)

t.test("other GUID kinds parse by position, not by prefix", function()
    t.eq(Shard.FromGUID("GameObject-0-3299-2437-91-410156-0000ABCDEF"), 91)
    t.eq(Shard.FromGUID("Vignette-0-3299-2512-204-0-00004F1A22"), 204)
end)

t.test("a GUID with no shard field yields nothing", function()
    t.eq(Shard.FromGUID("Player-3299-0A1B2C3D"), nil)
end)

t.test("an empty field shifts nothing", function()
    -- Splitting on "-" and indexing would read 77 here and call it the shard.
    local shard = Shard.FromGUID("Creature-0--2444-77-231088-0000")
    t.eq(shard, 77, "field five is still field five when field three is empty")
end)

t.test("junk is refused without throwing", function()
    t.eq(Shard.FromGUID(nil), nil)
    t.eq(Shard.FromGUID(12345), nil)
    t.eq(Shard.FromGUID({}), nil)
    t.eq(Shard.FromGUID(""), nil)
    t.eq(Shard.FromGUID("nonsense"), nil)
end)

-- Midnight hands back strings that throw on any operation while tainted. The
-- addon has to fail quiet: RCT shipped this as a Lua error spamming in
-- populated zones.
t.test("a string that throws when touched fails quietly", function()
    local secret = setmetatable({}, {
        __index = function() error("secret string value") end,
        __concat = function() error("secret string value") end,
        __tostring = function() error("secret string value") end,
    })
    -- type() is the only test allowed before the pcall, and this is not a
    -- string, so it is refused outright rather than reaching string.match.
    t.eq(Shard.FromGUID(secret), nil)
    t.eq(Shard.Label(secret), "<unreadable guid>", "even the debug label must not throw")
end)

t.test("Label round-trips a normal GUID", function()
    t.eq(Shard.Label(REAL), REAL)
end)

t.test("a vignette GUID falls back to its last numeric run", function()
    -- Too few fields for the creature layout, so the fallback answers.
    t.eq(Shard.FromVignetteGUID("Vignette-999"), 999)
    t.eq(Shard.FromVignetteGUID(REAL), 128, "the creature layout still wins when it fits")
end)

t.test("the vignette fallback refuses a zero or absent number", function()
    t.eq(Shard.FromVignetteGUID("Vignette-0"), nil)
    t.eq(Shard.FromVignetteGUID("Vignette"), nil)
    t.eq(Shard.FromVignetteGUID(nil), nil)
end)
