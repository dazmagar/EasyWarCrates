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

    -- Two bare countdowns side by side are not self-explaining -- the first
    -- person to see this window asked what they meant, which is the answer.
    -- The column header above says which is which; this says the rest.
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        local d = self.data
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.GetZoneName(d.zoneID))
        GameTooltip:AddLine(("shard %s"):format(tostring(d.shardID or "?")), 0.7, 0.7, 0.7)
        if d.live then
            GameTooltip:AddLine(d.live.phase == "ground"
                and "a crate is on the ground here now"
                or "a crate is coming down here now", 0.2, 1, 0.2)
        end
        if d.remaining then
            GameTooltip:AddLine(("next crate drops in %s"):format(
                ns.FormatClock(d.remaining):gsub("^%s+", "")), 1, 1, 1)
        else
            GameTooltip:AddLine("never seen a crate here", 0.7, 0.7, 0.7)
        end
        if d.leaveIn then
            GameTooltip:AddLine(("%s -- %ds from the capital to this zone"):format(
                d.leaveIn <= 0 and "leave now" or ("leave in " .. ns.FormatClock(d.leaveIn):gsub("^%s+", "")),
                ns.GetZoneTravel(d.zoneID)), 1, 0.82, 0)
        end
        if not d.precise and d.remaining then
            GameTooltip:AddLine("~ the timer was seeded from a crate already on the ground, "
                .. "so the cycle is right but its phase is only as good as when it was spotted",
                1, 0.5, 0.3, true)
        end
        if (d.missed or 0) > 0 then
            GameTooltip:AddLine(("%d cycle%s have passed here unobserved. If the shard changed "
                .. "in that time this timer means nothing."):format(
                d.missed, d.missed == 1 and "" or "s"), 1, 0.5, 0.3, true)
        end
        GameTooltip:AddLine(("cycle %ds"):format(math.floor(ns.GetZoneInterval(d.zoneID) + 0.5)),
            0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)

    return r
end

local function paintRow(r, row, isNext)
    r.data = row
    local cr, cg, cb = colourFor(row.zoneID)
    r.bar:SetValue(row.fraction or 0)
    r.bar:SetStatusBarColor(cr, cg, cb, row.stale and 0.25 or 0.75)

    local mark = isNext and "|cff33ff99>|r " or "  "
    local shard = row.shardID and ("|cff777777%s|r"):format(row.shardID) or ""
    r.left:SetText(("%s|cffffffff%s|r %s"):format(mark, row.abbr, shard))

    if row.live then
        -- The crate that is there NOW, in place of the countdown to the next.
        -- The bar shows the descent rather than the cycle, so a row that is
        -- about to be worth flying to looks different from one that is not.
        if row.live.phase == "ground" then
            r.right:SetText("|cff33ff99ON THE GROUND|r")
            r.bar:SetValue(1)
        else
            r.right:SetText(row.live.toGround
                and ("|cffffd100landing %s|r"):format(ns.FormatClock(row.live.toGround):gsub("^%s+", ""))
                or "|cffffd100falling|r")
            r.bar:SetValue(0.5)
        end
        r.bar:SetStatusBarColor(cr, cg, cb, 1)
    elseif not row.remaining then
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
        -- The missed-cycle count lives in the tooltip now. On the row it was
        -- an unexplained "x2" next to two unexplained countdowns, and the
        -- dimming already says "do not trust this one" without jargon.
        r.right:SetText(("%s%s"):format(clock, leave))
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

    -- No route means no leave column, so the header should not claim one.
    frame.headRight:SetText((ns.db.route and #ns.db.route > 0) and "drop    leave" or "drop")
    frame:SetHeight(58 + math.max(shown, 3) * (ROW_H + ROW_GAP) + PAD)
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

    frame.header = CreateFrame("Frame", nil, frame)
    frame.header:SetPoint("TOPLEFT", PAD, -38)
    frame.header:SetPoint("TOPRIGHT", -PAD, -38)
    frame.header:SetHeight(12)
    local hl = frame.header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hl:SetPoint("LEFT", 4, 0)
    hl:SetText("zone")
    frame.headRight = frame.header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.headRight:SetPoint("RIGHT", -4, 0)
    frame.headRight:SetText("drop    leave")

    frame.body = CreateFrame("Frame", nil, frame)
    frame.body:SetPoint("TOPLEFT", 0, -54)
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
