local ADDON, ns = ...

-- The NPC who announces a crate cycle starting. The line is scripted to the
-- spawn, so it anchors the timer as well as catching the transport does and
-- arrives before the transport is near enough to draw a vignette, which is
-- what makes Eversong and Voidstorm work.
--
-- The name gates the phrases and both are required. Without the gate a boss
-- taunt anchors a cycle, which WarCratePredict hit as Decimus saying "I hunger
-- for the OPPORTUNITY"; without the phrases an announcer's idle line does.
--
-- Names are localised too, so every locale is matched at once and GetLocale is
-- never read. Russian from CrateTrackerZK's ruRU locale.

local NAMES = {
    ["Vidious"] = true, ["Ziadan"] = true, ["Ruffious"] = true,
    ["Видий"] = true,   ["Зиадан"] = true,
}

-- ASCII phrases are stored lower case. Cyrillic ones are stored as they appear
-- mid-sentence and matched against the raw text as well, because Lua's
-- string.lower only touches bytes below 128 and leaves Cyrillic alone.
local PHRASES = {
    "opportunit", "valuable resources", "treasure nearby", "cache of resources",
    "you like goods", "early advantage", "spoils",
    "ценности", "трофеи", "сокровище", "преимуществ",
}

ns.ANNOUNCER_NAMES = NAMES
ns.ANNOUNCER_PHRASES = PHRASES

function ns.IsAnnouncer(npcName)
    return type(npcName) == "string" and NAMES[npcName] == true
end

function ns.IsSpawnAnnouncement(npcName, text)
    if not ns.IsAnnouncer(npcName) or type(text) ~= "string" then return false end
    local lower = text:lower()
    for i = 1, #PHRASES do
        local p = PHRASES[i]
        if lower:find(p, 1, true) or text:find(p, 1, true) then return true end
    end
    return false
end
