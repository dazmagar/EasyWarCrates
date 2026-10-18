local ns, t = ...

-- The one way a translation breaks a working addon: the placeholders drift.
-- "%s: crate landing in %s%s" and a translation with two %s instead of three
-- hands string.format fewer slots than arguments, or more, and the line either
-- throws inside SendChatMessage or goes out with "%s" printed in it where a
-- zone name should be. No translator reading prose would notice.
--
-- So every locale is compared against English specifier by specifier, in
-- order. Order matters as much as the count: a language that wants the time
-- before the zone has to say so with %1$s, not by swapping two bare %s.

local function specifiers(text)
    local out = {}
    for spec in text:gmatch("%%[-+ #0-9.]*[a-zA-Z]") do
        out[#out + 1] = spec
    end
    return out
end

t.test("every key English has is a key the code can ask for", function()
    -- A missing English key is the only unrecoverable case: ns.Phrase falls back
    -- to English, and there is nothing behind English.
    for key, text in pairs(ns.ANNOUNCE_ENGLISH) do
        t.ok(type(text) == "string" and text ~= "", key .. " is a non-empty string")
    end
end)

t.test("no locale invents a key English does not have", function()
    for code, strings in pairs(ns.ANNOUNCE_LOCALES) do
        for key in pairs(strings) do
            t.ok(ns.ANNOUNCE_ENGLISH[key] ~= nil,
                ("%s has %s, which English does not"):format(code, key))
        end
    end
end)

t.test("every translated line carries the same placeholders as English", function()
    for code, strings in pairs(ns.ANNOUNCE_LOCALES) do
        for key, text in pairs(strings) do
            local want = specifiers(ns.ANNOUNCE_ENGLISH[key])
            local got = specifiers(text)
            t.eq(#got, #want, ("%s %s: %d placeholders against English's %d")
                :format(code, key, #got, #want))
            for i = 1, #want do
                t.eq(got[i], want[i], ("%s %s: placeholder %d is %s, English has %s")
                    :format(code, key, i, tostring(got[i]), tostring(want[i])))
            end
        end
    end
end)

t.test("a locale with no translation falls back to English, key by key", function()
    ns.db = ns.db or {}
    ns.announcePreview = "frFR"           -- real locale, nothing written for it
    t.eq(ns.Phrase("TRANSPORT_AIR", "Zul'Aman", "", ""),
         "Zul'Aman: transport in the air")
    ns.announcePreview = nil
end)

t.test("the switch decides, and off means English", function()
    -- The harness stubs no game API, so this test brings the one function it
    -- needs and puts it back: another spec reading GetLocale would otherwise
    -- inherit whatever this left behind.
    local was = GetLocale
    GetLocale = function() return "deDE" end
    ns.db = ns.db or {}
    ns.announcePreview = nil

    ns.db.announceLocale = false
    t.eq(ns.AnnounceLocale(), "enUS")

    ns.db.announceLocale = true
    t.eq(ns.AnnounceLocale(), "deDE")

    ns.db.announceLocale = false
    GetLocale = was
end)

t.test("Russian renders with its own words and the given numbers", function()
    ns.announcePreview = "ruRU"
    t.eq(ns.Phrase("CRATE_GROUND", "Зул'Аман", "", ""), "Зул'Аман: ящик НА ЗЕМЛЕ")
    t.eq(ns.Phrase("SHARD", "63"), "  шард 63")
    t.eq(ns.Phrase("AT", 52.1, 38.4), " на 52.1, 38.4")
    ns.announcePreview = nil
end)

t.test("clearing a preview returns the choice to the switch", function()
    -- The invariant /ewc locale leans on. The handler itself lives in
    -- Core/Commands.lua, which this harness only syntax-checks, so what is
    -- covered here is the mechanism and not the caller: a leaked preview would
    -- send the wrong language into other people's chat with the switch off.
    ns.db = ns.db or {}
    ns.db.announceLocale = false

    ns.announcePreview = "ruRU"
    t.eq(ns.AnnounceLocale(), "ruRU")

    ns.announcePreview = nil
    t.eq(ns.AnnounceLocale(), "enUS")
end)
