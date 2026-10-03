local ADDON, ns = ...

-- Minimap button, drawn by LibDBIcon.
--
-- Hand-rolled in 107 lines until 2 Oct, on the argument that four libraries
-- for one button is the kind of weight this addon exists to avoid. What that
-- argument missed is written up in Libs/README.md: the libraries are not
-- bought for square minimaps, they are bought for the name. Every button
-- organiser in the ecosystem decides what to leave alone by looking for
-- "LibDBIcon" in a frame's name, and Leatrix Plus hides anything without it
-- and stands its own proxy in the place -- which costs the tooltip, and the
-- tooltip is the only reason to hover a minimap button.

local NAME = "EasyWarCrates"

local ldb = LibStub("LibDataBroker-1.1")
local icon = LibStub("LibDBIcon-1.0")

-- Unchanged from the hand-rolled button: the next zone, the wait for the
-- transport, and the wait before it can be looted. LibDBIcon owns the tooltip
-- frame and where it anchors, so this only fills it.
local function describe(tip)
    tip:AddLine("EasyWarCrates")
    local now = GetServerTime()
    local list, nextRow = ns.Model.BuildRows(ns.db.crates, ns.db.route, now)
    if nextRow then
        tip:AddLine(("next: %s, transport in %s"):format(
            nextRow.abbr, ns.FormatClock(nextRow.remaining):gsub("^%s+", "")), 1, 1, 1)
        if nextRow.onGround then
            tip:AddLine(("lootable in %s"):format(
                ns.FormatClock(nextRow.onGround):gsub("^%s+", "")), 1, 0.82, 0)
        end
    elseif #list == 0 then
        tip:AddLine("no timers yet", 0.6, 0.6, 0.6)
    else
        tip:AddLine("nothing on the route is timed yet", 1, 0.4, 0.4)
    end
    tip:AddLine(" ")
    tip:AddLine("Left-click: show or hide the window", 0.6, 0.6, 0.6)
    tip:AddLine("Right-click: settings", 0.6, 0.6, 0.6)
end

local object = ldb:NewDataObject(NAME, {
    type = "launcher",
    -- A supply crate. Generic enough to survive an art pass, unlike a spell
    -- icon. Required: Register refuses an object without one.
    icon = "Interface\\Icons\\INV_Crate_03",
    OnClick = function(_, pressed)
        if pressed == "RightButton" then
            Settings.OpenToCategory(ns.settingsCategoryID)
        else
            ns.ToggleWindow()
        end
    end,
    OnTooltipShow = describe,
})

function ns.SetMinimapShown(show)
    ns.db.minimap = show and true or false
    -- LibDBIcon reads hide once, when it builds the button, and its Show and
    -- Hide do not write it back. Kept in step here so the stored state and the
    -- button on screen cannot disagree.
    local held = ns.db.minimapIcon
    if held then held.hide = not ns.db.minimap end
    if not icon:IsRegistered(NAME) then return end
    if ns.db.minimap then icon:Show(NAME) else icon:Hide(NAME) end
end

-- Named rather than left inline in the event handler so the harness can drive
-- it. Registering is the whole of the new code here and firing PLAYER_LOGIN is
-- not something tools/firstrun.py can do.
function ns.SetupMinimap()
    local held = ns.db.minimapIcon
    -- Nobody's button should move because the library under it changed. Both
    -- stores are degrees around the minimap, so a dragged angle moves across
    -- as it is, and a player who never dragged one keeps the spot the
    -- hand-rolled button defaulted to -- clear of the clock and the tracking
    -- icon, where LibDBIcon's own default of 225 is not. Runs once, because
    -- after it LibDBIcon has a position of its own.
    if held.minimapPos == nil then
        held.minimapPos, ns.db.minimapAngle = ns.db.minimapAngle or 200, nil
    end
    held.hide = ns.db.minimap == false
    if not icon:IsRegistered(NAME) then
        icon:Register(NAME, object, held)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", ns.SetupMinimap)
