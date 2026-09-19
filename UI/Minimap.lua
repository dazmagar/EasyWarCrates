local ADDON, ns = ...

-- Minimap button.
--
-- Hand-rolled rather than pulled in with LibDBIcon, which would mean bundling
-- LibDataBroker and LibStub as well. Three libraries for one button is the kind
-- of weight this addon exists to avoid; the only thing they really buy is
-- handling square minimaps and other addons' layouts, and a dragged angle
-- covers the same ground in a dozen lines.

local BUTTON_SIZE = 31
local RADIUS = 80          -- distance from the minimap centre, in its own units
local DEFAULT_ANGLE = 200  -- degrees; away from the clock and the tracking icon

local button

local function place()
    local angle = math.rad(ns.db.minimapAngle or DEFAULT_ANGLE)
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

local function build()
    if button then return button end

    button = CreateFrame("Button", "EasyWarCratesMinimapButton", Minimap)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 7, -6)
    -- A supply crate. Generic enough to survive an art pass, unlike a spell icon.
    icon:SetTexture("Interface\\Icons\\INV_Crate_03")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Dragging stores an angle rather than a position, so the button stays on
    -- the minimap's edge wherever the minimap itself is.
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            place()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnClick", function(_, click)
        if click == "RightButton" then
            Settings.OpenToCategory(ns.settingsCategoryID)
        else
            ns.ToggleWindow()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EasyWarCrates")
        local now = GetServerTime()
        local list, nextRow = ns.Model.BuildRows(ns.db.crates, ns.db.route, now)
        if nextRow then
            GameTooltip:AddLine(("next: %s in %s"):format(
                nextRow.abbr, ns.FormatClock(nextRow.remaining):gsub("^%s+", "")), 1, 1, 1)
            if nextRow.leaveIn then
                GameTooltip:AddLine(nextRow.leaveIn <= 0 and "leave now"
                    or ("leave in %s"):format(ns.FormatClock(nextRow.leaveIn):gsub("^%s+", "")),
                    1, 0.82, 0)
            end
        elseif #list == 0 then
            GameTooltip:AddLine("no timers yet", 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine("nothing on the route is reachable", 1, 0.4, 0.4)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: show or hide the window", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Right-click: settings", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    place()
    return button
end

function ns.SetMinimapShown(show)
    build()
    ns.db.minimap = show and true or false
    if show then button:Show() else button:Hide() end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    ns.SetMinimapShown(ns.db and ns.db.minimap ~= false)
end)
