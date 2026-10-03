local ns, t = ...

-- The art named in Data/Vignettes.lua as never being a crate. Read off the 60
-- samples db.strangers collected before it jammed, so these are strings the
-- game really sent rather than guesses.
t.test("furniture art is recognised as furniture", function()
    for _, art in ipairs({
        "VignetteKill", "VignetteKillElite", "Quartermaster", "Class",
        "AncientMana", "loreobject-32x32", "housing-decor-vendor_32",
        "dragon-rostrum", "QuestObjective", "AllianceSymbol", "HordeSymbol",
        "poi-prey", "Ammunition", "Vehicle-TempleofKotmogu-PurpleBall",
    }) do
        t.ok(ns.IsSceneryArt(art), art .. " should not be filed")
    end
end)

-- Every warfront icon, and there are many: the full names carry faction, map
-- and size, so the stem is what is matched.
t.test("every warfront icon is furniture, whatever the rest of the name says", function()
    for _, art in ipairs({
        "Warfront-AllianceHero",
        "Warfronts-BaseMapIcons-Alliance-Heroes-Minimap-small",
        "Warfronts-BaseMapIcons-Horde-Heroes-Minimap-small",
        "Warfronts-FieldMapIcons-Alliance-Banner-Minimap-small",
    }) do
        t.ok(ns.IsSceneryArt(art), art .. " should not be filed")
    end
end)

-- The whole point of the list. VignetteLootElite is what the Spectral Battle
-- Chest wears, and that chest is why this store exists -- so the loot art is
-- kept however much of it is ordinary treasure.
t.test("loot art is kept, because the chest this store exists for wears it", function()
    t.eq(ns.IsSceneryArt("VignetteLootElite"), false, "Spectral Battle Chest")
    t.eq(ns.IsSceneryArt("VignetteLoot"), false, "and its ordinary cousins")
    t.eq(ns.IsSceneryArt("Vehicle-Air-Occupied"), false, "the transport itself")
end)

t.test("anything unrecognised is kept, which is what the store is for", function()
    t.eq(ns.IsSceneryArt("SomeAtlasNobodyHasSeenYet"), false)
    t.eq(ns.IsSceneryArt(nil), false)
    t.eq(ns.IsSceneryArt(""), false)
    t.eq(ns.IsSceneryArt(7149), false, "a number is not an atlas name")
end)
