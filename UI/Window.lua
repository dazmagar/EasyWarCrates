local ADDON, ns = ...

-- The tracker window. Deliberately thin: UI/Model.lua decides what to show and
-- this paints it, because a frame cannot be tested and a table can.

local ROW_H, ROW_GAP, PAD = 18, 2, 8
local WIDTH = 260
local MAX_ROWS = 8

-- One fixed colour per zone so a row is recognisable before it is read.
local ZONE_COLOUR = {
    [2395] = { 0.35, 0.70, 0.35 },  -- Eversong Woods
    [2405] = { 0.45, 0.35, 0.75 },  -- Voidstorm
    [2413] = { 0.75, 0.50, 0.25 },  -- Harandar
    [2437] = { 0.75, 0.35, 0.35 },  -- Zul'Aman
    [2444] = { 0.70, 0.30, 0.60 },  -- Slayer's Rise
    [2512] = { 0.25, 0.60, 0.60 },  -- The Coiled Isle
}
local function colourFor(zoneID)
    local c = ZONE_COLOUR[zoneID]
    return c and c[1] or 0.5, c and c[2] or 0.5, c and c[3] or 0.5
end

local frame, rows, ticker

local function makeRow(parent, index)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(WIDTH - PAD * 2, ROW_H)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -(index - 1) * (ROW_H + ROW_GAP))

    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetAllPoints()
    r.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    r.bar:SetMinMaxValues(0, 1)

    r.bg = r.bar:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(0, 0, 0, 0.45)

    r.left = r.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.left:SetPoint("LEFT", 4, 0)
    r.left:SetJustifyH("LEFT")

    r.right = r.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -4, 0)
    r.right:SetJustifyH("RIGHT")

    return r
end

local function paintRow(r, row, isNext)
    local cr, cg, cb = colourFor(row.zoneID)
    r.bar:SetValue(row.fraction or 0)
    r.bar:SetStatusBarColor(cr, cg, cb, row.stale and 0.25 or 0.75)

    local mark = isNext and "|cff33ff99>|r " or "  "
    local shard = row.shardID and ("|cff777777%s|r"):format(row.shardID) or ""
    r.left:SetText(("%s|cffffffff%s|r %s"):format(mark, row.abbr, shard))

    if not row.remaining then
        r.right:SetText("|cff777777-- : --|r")
    else
        -- A tilde says the timer was seeded from a crate found already on the
        -- ground, so the cycle is right but the phase is only as good as the
        -- moment it happened to be spotted.
        local clock = (row.precise and "" or "~") .. ns.FormatClock(row.remaining):gsub("^%s+", "")
        local leave = ""
        if row.leaveIn then
            leave = row.status == "missed" and " |cffff5555miss|r"
                or (row.leaveIn <= 0 and " |cff33ff99GO|r"
                or (" |cffffd100%s|r"):format(ns.FormatClock(row.leaveIn):gsub("^%s+", "")))
        end
        local missed = (row.missed or 0) > 0 and ("|cff777777x%d|r "):format(row.missed) or ""
        r.right:SetText(("%s%s%s"):format(missed, clock, leave))
    end
    r:Show()
end

local function refresh()
    if not frame or not frame:IsShown() then return end
    local now = GetServerTime()
    local list, nextRow = ns.Model.BuildRows(ns.db.crates, ns.db.route, now)

    local head = ns.Model.Headline(ns.Zones.Normalize(C_Map.GetBestMapForUnit("player")), now)
    frame.head:SetText(head and ((head.ready and "|cffffd100" or "|cff777777") .. head.text .. "|r")
        or "|cff777777no transport in the air|r")

    local shown = math.min(#list, MAX_ROWS)
    for i = 1, MAX_ROWS do
        rows[i] = rows[i] or makeRow(frame.body, i)
        if i <= shown then paintRow(rows[i], list[i], list[i] == nextRow) else rows[i]:Hide() end
    end

    if shown == 0 then
        -- An empty database is the normal state for someone who has just
        -- installed this, and silence would read as broken. Say what to do.
        frame.empty:SetText("No timers yet.\nFly to any crate zone and wait -- up to 18 minutes.\n"
            .. "A crate already on the ground counts too.")
        frame.empty:Show()
    else
        frame.empty:Hide()
    end

    frame:SetHeight(46 + math.max(shown, 3) * (ROW_H + ROW_GAP) + PAD)
end
ns.RefreshWindow = refresh

local function build()
    if frame then return frame end
    frame = CreateFrame("Frame", "EasyWarCratesWindow", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, 160)
    frame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        ns.db.window = { point = point, rel = rel, x = x, y = y }
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -6)
    title:SetText("EasyWarCrates")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() ns.ToggleWindow(false) end)

    frame.head = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.head:SetPoint("TOPLEFT", PAD, -24)
    frame.head:SetPoint("TOPRIGHT", -PAD, -24)
    frame.head:SetJustifyH("LEFT")

    frame.body = CreateFrame("Frame", nil, frame)
    frame.body:SetPoint("TOPLEFT", 0, -42)
    frame.body:SetPoint("BOTTOMRIGHT", 0, PAD)

    frame.empty = frame.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.empty:SetPoint("TOPLEFT", PAD, -4)
    frame.empty:SetPoint("TOPRIGHT", -PAD, -4)
    frame.empty:SetJustifyH("LEFT")

    rows = {}
    local pos = ns.db.window
    frame:ClearAllPoints()
    frame:SetPoint(pos and pos.point or "CENTER", UIParent, pos and pos.rel or "CENTER",
        pos and pos.x or 0, pos and pos.y or 120)
    return frame
end

function ns.ToggleWindow(show)
    build()
    if show == nil then show = not frame:IsShown() end
    ns.db.windowShown = show and true or false
    if show then
        frame:Show()
        refresh()
        ticker = ticker or C_Timer.NewTicker(1, refresh)
    else
        frame:Hide()
        if ticker then ticker:Cancel(); ticker = nil end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    if ns.db and ns.db.windowShown ~= false then ns.ToggleWindow(true) end
end)
