local ADDON, ns = ...

-- Settings panel, on Blizzard's own Settings API.
--
-- No AceConfig and no AceGUI. RCT carries both, plus AceGUI's fifteen widget
-- files, to draw a list of checkboxes the game has drawn natively since 10.0.
--
-- Registered on PLAYER_LOGIN in its own frame rather than from the addon's
-- load handler, so if a future patch moves this API the failure is confined to
-- the settings panel instead of taking the tracker down with it.

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

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Tracking"))

    checkbox("enabled", "Track crates",
        "Watch for transports and crates. Off stops the addon doing anything.")

    checkbox("waypoint", "Set a map pin",
        "Drop a waypoint on the predicted landing spot once the call is confident. "
        .. "Nothing is placed while the call is still uncertain -- a pin in the wrong "
        .. "place is worse than none.")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Interface"))

    checkbox("minimap", "Minimap button", "Show the button on the minimap.",
        function(value) ns.SetMinimapShown(value) end)

    checkbox("windowShown", "Show the window", "Show the tracker window.",
        function(value) ns.ToggleWindow(value) end)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Diagnostics"))

    checkbox("watch", "Narrate tracking",
        "Report each transport's heading fit and what it resolves to, as it flies. "
        .. "For diagnosing the prediction, not for playing.")

    checkbox("verbose", "Verbose log",
        "Report sightings the tracker decided not to act on.")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Rotation"))
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
        "Set with /ewc route ZA HD SR VS. Travel times: /ewc travel."))

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
