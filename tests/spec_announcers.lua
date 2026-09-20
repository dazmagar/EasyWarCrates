local ns, t = ...

-- The lines as the game actually sends them, from CrateTrackerZK's locale
-- files. The event hands the name and the text separately, so the "Vidious
-- says:" prefix those files carry is not part of what is matched.
local EN = {
    ["Ruffious"] = {
        "Opportunity's knocking! If you've got the mettle, there are valuables waiting to be won.",
        "I see some valuable resources in the area! Get ready to grab them!",
        "There's a cache of resources nearby. Find it before you have to fight over it!",
        "Looks like there's treasure nearby. And that means treasure hunters. Watch your back.",
    },
    ["Ziadan"] = {
        "Take the early advantage and get your spoils.",
        "That looks like a treasure out in the distance. Don't miss this opportunity!",
    },
    ["Vidious"] = {
        "Keep an eye out for opportunities for loot when they arise, like now!",
        "You like goods don't you? Then find them.",
    },
}

local RU = {
    ["Видий"] = {
        "Вы ведь любите всякие ценности? Вот и найдите их.",
        "Не забывайте добывать трофеи, когда появляется шанс. Как сейчас!",
    },
    ["Зиадан"] = {
        "Кажется, там вдалеке ждет сокровище. Не упустите эту возможность!",
        "Воспользуйтесь ранним преимуществом. Заберите трофеи.",
    },
}

t.test("every English announcement the game ships is recognised", function()
    for npc, lines in pairs(EN) do
        for _, line in ipairs(lines) do
            t.ok(ns.IsSpawnAnnouncement(npc, line), npc .. ": " .. line)
        end
    end
end)

t.test("every Russian announcement the game ships is recognised", function()
    for npc, lines in pairs(RU) do
        for _, line in ipairs(lines) do
            t.ok(ns.IsSpawnAnnouncement(npc, line), npc .. ": " .. line)
        end
    end
end)

-- string.lower leaves Cyrillic alone, so a Russian phrase has to be matched
-- against the raw text as well. Dropping that second match is invisible on an
-- English client and silently deaf on a Russian one.
t.test("a Russian line is matched without relying on lowercasing", function()
    t.ok(ns.IsSpawnAnnouncement("Видий", "Вот вам ЦЕННОСТИ и трофеи, берите."))
end)

t.test("English matching does not care about case", function()
    t.ok(ns.IsSpawnAnnouncement("Ziadan", "TAKE THE EARLY ADVANTAGE AND GET YOUR SPOILS."))
end)

-- The live false positive WarCratePredict hit. The phrase list is broad on
-- purpose and the name is what holds it back.
t.test("a mob that is not an announcer never anchors, whatever it says", function()
    t.notOk(ns.IsSpawnAnnouncement("Decimus", "I hunger for the OPPORTUNITY to crush you!"))
    t.notOk(ns.IsSpawnAnnouncement("Ruffious the Impostor", "I see some valuable resources!"))
    t.notOk(ns.IsSpawnAnnouncement("", "spoils"))
end)

t.test("an announcer saying something else does not anchor", function()
    t.notOk(ns.IsSpawnAnnouncement("Vidious", "Hah! Watch where you are going."))
    t.notOk(ns.IsSpawnAnnouncement("Видий", "Ну и погодка сегодня."))
end)

t.test("nothing at all is not an announcement", function()
    t.notOk(ns.IsSpawnAnnouncement(nil, nil))
    t.notOk(ns.IsSpawnAnnouncement("Vidious", nil))
    t.notOk(ns.IsSpawnAnnouncement(nil, "spoils"))
    t.notOk(ns.IsSpawnAnnouncement(42, "spoils"))
end)

t.test("IsAnnouncer knows the speakers apart from the words", function()
    t.ok(ns.IsAnnouncer("Vidious"))
    t.ok(ns.IsAnnouncer("Зиадан"))
    t.notOk(ns.IsAnnouncer("Decimus"))
    t.notOk(ns.IsAnnouncer(nil))
end)

t.test("an announcement is anchored as precisely as catching the transport", function()
    t.eq(ns.Timers.PRECISION.yell, ns.Timers.PRECISION.flying)
end)

-- Recording the announcement and then catching the transport minutes later is
-- one crate seen twice. The announcement came first and sits closer to the
-- spawn, so it must not be dragged forward by the later sighting.
t.test("a later flying catch does not move a timer the announcement anchored", function()
    local db, T0 = ns.Timers.New(), 1000000
    ns.Timers.Record(db, 2413, 7, T0, "yell")
    local verdict = ns.Timers.Record(db, 2413, 7, T0 + 120, "flying")
    t.eq(verdict, "duplicate")
    t.eq(db[2413][7].ts, T0)
    t.ok(db[2413][7].precise)
end)
