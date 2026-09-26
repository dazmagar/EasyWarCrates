local ADDON, ns = ...

-- Settings panel, on Blizzard's own Settings API.
--
-- No AceConfig and no AceGUI. RCT carries both, plus AceGUI's fifteen widget
-- files, to draw a list of checkboxes the game has drawn natively since 10.0.
--
-- Registered on PLAYER_LOGIN in its own frame rather than from the addon's
-- load handler, so if a future patch moves this API the failure is confined to
-- the settings panel instead of taking the tracker down with it.
--
-- Switches only. Anything that is a list of records -- timers, measurements,
-- the route -- lives behind the Manage data button, because this API draws
-- checkboxes, sliders and dropdowns and has nowhere to put a row with its own
-- remove button. RCT puts 39 controls on one page, including the warning
-- frame's font and a donation link, and the three settings that change how it
-- farms are lost among them.

local function build()
    local category, layout = Settings.RegisterVerticalLayoutCategory("EasyWarCrates")
    ns.settingsCategoryID = category:GetID()

    -- The default has to be the addon's own, not a hardcoded true. Passing
    -- true for every checkbox would have made "Narrate tracking" and "Verbose
    -- log" -- both diagnostics, both off by design -- default to on, which is
    -- how a fresh install would have started shouting at its owner.
    local function checkbox(key, name, tooltip, onChange)
        local default = ns.DEFAULTS[key]
        if default == nil then default = false end
        local setting = Settings.RegisterAddOnSetting(category,
            "EasyWarCrates_" .. key, key, ns.db, Settings.VarType.Boolean, name, default)
        Settings.CreateCheckbox(category, setting, tooltip)
        if onChange then
            Settings.SetOnValueChangedCallback("EasyWarCrates_" .. key, function(_, _, value)
                onChange(value)
            end)
        end
        return setting
    end

    local function header(text)
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end

    header("Tracking")

    checkbox("enabled", "Track crates",
        "Watch for transports and crates. Off stops the addon doing anything.")

    checkbox("waypoint", "Set a map pin",
        "Drop a waypoint on the predicted landing spot once the call is confident. "
        .. "Nothing is placed while the call is still uncertain -- a pin in the wrong "
        .. "place is worse than none.")

    checkbox("share", "Tell your group what you see",
        "Send your own sightings to your party or raid, so anyone else running this "
        .. "addon sees them. Listening needs no setting and is always on: what other "
        .. "players report is held for the session and never saved.")

    checkbox("announce", "Call it out in raid chat",
        "Post the landing spot and a clickable map pin to the raid when the call is "
        .. "firm. Only a leader or assistant can send, so one person speaks instead of "
        .. "everyone. Sending moves your own pin: the link the game will accept is the "
        .. "one made from your waypoint.")

    header("Window")

    checkbox("minimap", "Minimap button", "Show the button on the minimap.",
        function(value) ns.SetMinimapShown(value) end)

    checkbox("windowShown", "Show the window", "Show the tracker window.",
        function(value) ns.ToggleWindow(value) end)

    header("Data")

    -- A button is not a setting, and this initializer is newer than the rest
    -- of the API used here. Missing it must not take the whole panel down with
    -- it, and must not leave the player with no way in either.
    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            "Timers, measurements and the route",
            "Manage data",
            function() ns.ToggleDataPanel(true) end,
            "Everything the addon has learned: crate timers per zone and shard, "
            .. "measured descent and cycle times, drop points it found itself, and "
            .. "the rotation. Any of it can be removed.",
            true))
    else
        header("This build has no button widget -- use /ewc data")
    end

    header("Chat")

    checkbox("chatter", "Talk in chat",
        "Report sightings, measurements and pins in chat as they happen. Off by "
        .. "default: an addon that talks unprompted is one people route into a "
        .. "spare tab. Everything it would have said is written to its own log "
        .. "either way, and the /ewc commands always answer in full.")

    header("Diagnostics")

    checkbox("watch", "Narrate tracking",
        "Report each transport's heading fit and what it resolves to, as it flies. "
        .. "For diagnosing the prediction, not for playing.")

    checkbox("verbose", "Verbose log",
        "Report sightings the tracker decided not to act on.")

    Settings.RegisterAddOnCategory(category)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    if not (Settings and Settings.RegisterVerticalLayoutCategory) then
        return ns.Print("|cffff8800this build has no Settings API -- use /ewc instead|r")
    end
    build()
end)
