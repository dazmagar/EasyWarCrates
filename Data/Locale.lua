local ADDON, ns = ...

-- Only what goes into somebody else's chat window is translatable.
--
-- The window, the settings and every /ewc answer stay English on purpose.
-- Those are read by the person running the addon, and the /ewc output in
-- particular is what gets pasted into a bug report: translating it makes the
-- one artefact a maintainer needs unreadable to them.
--
-- An announcement is the opposite case. It is read by other people, and this
-- addon cannot know their language -- it can only know its own client's. So
-- the switch is off by default and English is the shared tongue; turning it on
-- is a bet that the raid speaks what this client speaks, which is right on a
-- single-language realm and wrong in a mixed group.
--
-- The input side stays locale-blind, as Data/Announcers.lua already records:
-- names and phrases arriving from other clients are matched in every locale at
-- once, and GetLocale is never consulted for them. This file is the only place
-- that reads it, and only for text this client sends.

local ENGLISH = {
    -- Fragments, appended to the lines below.
    SHARD        = "  shard %s",
    SO_FAR       = " (%s so far)",
    AT           = " at %.1f, %.1f",
    LEFT         = ", %s left",

    -- Whole sentences. A sentence is one translatable unit: assembling it from
    -- words would force every language into English word order.
    SPECTRAL          = "%s: SPECTRAL CHEST on the ground%s%s%s",
    CRATE_LANDING     = "%s: crate landing in %s%s",
    CRATE_GROUND      = "%s: crate ON THE GROUND%s%s",
    CRATE_GROUND_OURS = "%s: crate ON THE GROUND, ours%s%s",
    TRANSPORT_IN      = "%s: transport in %s, lootable in %s%s",
    TRANSPORT_AIR     = "%s: transport in the air%s%s",
    INCOMING          = "War crate incoming: %s %.1f, %.1f%s",
    ADDON_PLUG        = "Using EasyWarCrates for war crate timers and drop predictions.",
}

-- A locale is added only once somebody who speaks it has read the strings.
-- Machine translation in a published addon reads worse than English, and the
-- four languages in Data/Zones.lua are the languages of clients this addon
-- *hears from*, which is not evidence of a single user who wants them.
local LOCALES = {
    ruRU = {
        SHARD        = "  шард %s",
        SO_FAR       = " (уже %s)",
        AT           = " на %.1f, %.1f",
        LEFT         = ", осталось %s",

        SPECTRAL          = "%s: ПРИЗРАЧНЫЙ СУНДУК на земле%s%s%s",
        CRATE_LANDING     = "%s: ящик сядет через %s%s",
        CRATE_GROUND      = "%s: ящик НА ЗЕМЛЕ%s%s",
        CRATE_GROUND_OURS = "%s: ящик НА ЗЕМЛЕ, наш%s%s",
        TRANSPORT_IN      = "%s: самолёт через %s, ящик через %s%s",
        TRANSPORT_AIR     = "%s: самолёт в воздухе%s%s",
        INCOMING          = "Ящик на подходе: %s %.1f, %.1f%s",
        ADDON_PLUG        = "Использую EasyWarCrates: таймеры ящиков и предсказание точки сброса.",
    },
}

ns.ANNOUNCE_ENGLISH = ENGLISH
ns.ANNOUNCE_LOCALES = LOCALES

-- Set by /ewc locale to preview another language without that client
-- installed. Without it the feature is unverifiable by anybody whose client
-- is already English, which is most of the people who would work on it.
ns.announcePreview = nil

function ns.AnnounceLocale()
    if ns.announcePreview then return ns.announcePreview end
    if not (ns.db and ns.db.announceLocale) then return "enUS" end
    return (GetLocale and GetLocale()) or "enUS"
end

---Format an announcement string in the announcement locale. Returns a string;
---it sends nothing. Not Say: ns.Say prints to the chat frame and returns nil,
---and loads after this file, so the name would silently take this one over.
---Falls back to English per key, so a half-finished locale degrades a line at
---a time instead of erroring.
function ns.Phrase(key, ...)
    local locale = LOCALES[ns.AnnounceLocale()]
    local text = (locale and locale[key]) or ENGLISH[key]
    if not text then return "" end
    if select("#", ...) == 0 then return text end
    local ok, formatted = pcall(string.format, text, ...)
    -- A translation whose placeholders do not match English would throw here.
    -- tests/spec_locale.lua compares them so this cannot ship, and the
    -- fallback is still worth having: a bad line beats a broken announcement.
    if ok then return formatted end
    return (string.format(ENGLISH[key], ...))
end
