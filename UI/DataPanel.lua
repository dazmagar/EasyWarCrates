local ADDON, ns = ...

-- The data panel: everything the addon has accumulated, and a way to remove
-- any of it. Reached from the settings panel, or /ewc data.
--
-- UI/Manage.lua decides every row; this paints them and wires the buttons, and
-- holds no rule of its own.
--
-- Deliberately not on a ticker, unlike the tracker window. The timers section
-- sorts by how soon each drops, so a one-second repaint would reorder the list
-- under a cursor that is on its way to a remove button. A stale countdown in a
-- management panel costs nothing; deleting the row below the one you aimed at
-- costs a measurement.

local WIDTH, HEIGHT = 660, 470
local NAV_W, ROW_H = 132, 20

local panel, rowPool, navButtons, addButtons
local current = "timers"

local function sectionByID(id)
    for _, s in ipairs(ns.Manage.SECTIONS) do
        if s.id == id then return s end
    end
    return ns.Manage.SECTIONS[1]
end

local refresh

StaticPopupDialogs["EASYWARCRATES_CLEAR"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local gone = ns.Manage.Clear(ns.db, data.section, data.zoneID)
        ns.Print(("cleared %d record%s."):format(gone, gone == 1 and "" or "s"))
        refresh()
        if ns.RefreshWindow then ns.RefreshWindow() end
    end,
}

local function confirmClear(sectionID, zoneID, what)
    StaticPopup_Show("EASYWARCRATES_CLEAR", what, nil,
        { section = sectionID, zoneID = zoneID })
end

-- Removing one record needs no confirmation: it is one reading, the panel
-- shows what went, and a dialog every time is how a list stops being usable.
local function removeRow(row)
    local ok, why = ns.Manage.Remove(ns.db, row)
    if not ok then
        ns.Print(why == "changed"
            and "|cffff8800that record changed while the panel was open -- nothing removed, look again|r"
            or "|cffff8800that record is already gone|r")
    end
    refresh()
    if ns.RefreshWindow then ns.RefreshWindow() end
end

local function makeRow(index)
    local r = CreateFrame("Frame", nil, panel.scrollChild)
    r:SetSize(WIDTH - NAV_W - 56, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)

    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.label:SetPoint("LEFT", 2, 0)
    r.label:SetWidth(118)
    r.label:SetJustifyH("LEFT")
    r.label:SetWordWrap(false)

    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.value:SetPoint("LEFT", r.label, "RIGHT", 4, 0)
    r.value:SetWidth(130)
    r.value:SetJustifyH("LEFT")
    r.value:SetWordWrap(false)

    r.note = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.note:SetPoint("LEFT", r.value, "RIGHT", 6, 0)
    r.note:SetPoint("RIGHT", r, "RIGHT", -70, 0)
    r.note:SetJustifyH("LEFT")
    r.note:SetWordWrap(false)

    r.remove = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.remove:SetSize(20, 18)
    r.remove:SetPoint("RIGHT", -2, 0)
    r.remove:SetText("x")
    r.remove:SetScript("OnClick", function(self) removeRow(self:GetParent().data) end)

    r.down = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.down:SetSize(20, 18)
    r.down:SetPoint("RIGHT", r.remove, "LEFT", -2, 0)
    r.down:SetText("v")
    r.down:SetScript("OnClick", function(self)
        ns.Manage.Move(ns.db, self:GetParent().data, 1)
        refresh()
        if ns.RefreshWindow then ns.RefreshWindow() end
    end)

    r.up = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.up:SetSize(20, 18)
    r.up:SetPoint("RIGHT", r.down, "LEFT", -2, 0)
    r.up:SetText("^")
    r.up:SetScript("OnClick", function(self)
        ns.Manage.Move(ns.db, self:GetParent().data, -1)
        refresh()
        if ns.RefreshWindow then ns.RefreshWindow() end
    end)

    -- Only on a zone heading, where it clears that zone rather than one row.
    r.clearZone = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.clearZone:SetSize(62, 18)
    r.clearZone:SetPoint("RIGHT", -2, 0)
    r.clearZone:SetText("clear")
    r.clearZone:SetScript("OnClick", function(self)
        local d = self:GetParent().data
        confirmClear(current, d.zoneID,
            ("Remove everything recorded for %s in %s?"):format(
                ns.GetZoneName(d.zoneID), sectionByID(current).title:lower()))
    end)

    rowPool[index] = r
    return r
end

local function paintRow(r, row)
    r.data = row
    r.label:SetText(row.label or "")
    r.value:SetText(row.value or "")
    r.note:SetText(row.note or "")

    if row.head then
        r.label:SetFontObject("GameFontNormal")
        r.value:SetFontObject("GameFontHighlightSmall")
        r.remove:Hide(); r.up:Hide(); r.down:Hide()
        r.clearZone:Show()
    else
        r.label:SetFontObject(row.dim and "GameFontDisableSmall" or "GameFontHighlightSmall")
        r.value:SetFontObject(row.dim and "GameFontDisableSmall" or "GameFontNormalSmall")
        r.clearZone:Hide()
        r.remove:Show()
        if row.movable then r.up:Show(); r.down:Show() else r.up:Hide(); r.down:Hide() end
    end
    r:Show()
end

-- One button per zone not yet on the route. A dropdown would be the obvious
-- widget and is the one that keeps being rewritten between expansions; six
-- buttons cannot break and are fewer clicks anyway.
local function paintRouteAdders()
    local shown = 0
    local onRoute, spare = {}, {}
    for _, zoneID in ipairs(ns.db.route or {}) do onRoute[zoneID] = true end
    for zoneID in pairs(ns.ZONES) do
        if not onRoute[zoneID] then spare[#spare + 1] = zoneID end
    end
    table.sort(spare, function(a, b) return ns.GetZoneAbbr(a) < ns.GetZoneAbbr(b) end)

    for _, zoneID in ipairs(spare) do
        shown = shown + 1
        local b = addButtons[shown]
        if not b then
            b = CreateFrame("Button", nil, panel.footer, "UIPanelButtonTemplate")
            b:SetSize(40, 20)
            addButtons[shown] = b
        end
        b:SetPoint("LEFT", (shown - 1) * 44, 0)
        b.zoneID = zoneID
        b:SetText(ns.GetZoneAbbr(zoneID))
        b:SetScript("OnClick", function(self)
            ns.Manage.AddToRoute(ns.db, self.zoneID)
            refresh()
            if ns.RefreshWindow then ns.RefreshWindow() end
        end)
        b:Show()
    end
    for i = shown + 1, #addButtons do addButtons[i]:Hide() end
    return shown
end

refresh = function()
    if not panel or not panel:IsShown() then return end
    local now = GetServerTime()
    local section = sectionByID(current)

    for _, b in ipairs(navButtons) do
        local n = ns.Manage.Count(ns.db, b.sectionID, now)
        b:SetText(n > 0 and ("%s (%d)"):format(b.title, n) or b.title)
        if b.sectionID == current then b:LockHighlight() else b:UnlockHighlight() end
    end

    panel.heading:SetText(section.title)
    panel.note:SetText(section.note)

    local rows = ns.Manage.Rows(ns.db, current, now)
    for i = 1, math.max(#rows, #rowPool) do
        local r = rowPool[i] or (i <= #rows and makeRow(i))
        if r then
            if rows[i] then paintRow(r, rows[i]) else r:Hide() end
        end
    end
    panel.scrollChild:SetHeight(math.max(1, #rows * ROW_H))

    panel.empty:SetShown(#rows == 0)
    panel.clearAll:SetShown(#rows > 0)
    panel.clearAll:SetText(("Clear %s"):format(section.title:lower()))

    -- The route is the one list you add to as well as remove from.
    panel.footer:SetShown(current == "route")
    if current == "route" then
        panel.footerLabel:SetText(paintRouteAdders() > 0 and "add a zone:" or "every zone is on the route")
    end
end

local function build()
    if panel then return panel end

    panel = CreateFrame("Frame", "EasyWarCratesDataPanel", UIParent,
        "BasicFrameTemplateWithInset")
    panel:SetSize(WIDTH, HEIGHT)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("HIGH")
    panel:SetToplevel(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    if panel.TitleText then panel.TitleText:SetText("EasyWarCrates - data") end
    tinsert(UISpecialFrames, "EasyWarCratesDataPanel")

    rowPool, navButtons, addButtons = {}, {}, {}

    local nav = CreateFrame("Frame", nil, panel)
    nav:SetPoint("TOPLEFT", 10, -30)
    nav:SetPoint("BOTTOMLEFT", 10, 12)
    nav:SetWidth(NAV_W)

    for i, section in ipairs(ns.Manage.SECTIONS) do
        local b = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
        b:SetSize(NAV_W, 22)
        b:SetPoint("TOPLEFT", 0, -(i - 1) * 25)
        b.sectionID, b.title = section.id, section.title
        b:SetText(section.title)
        b:SetScript("OnClick", function(self)
            current = self.sectionID
            refresh()
        end)
        navButtons[i] = b
    end

    panel.heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.heading:SetPoint("TOPLEFT", nav, "TOPRIGHT", 12, -2)
    panel.heading:SetJustifyH("LEFT")

    panel.note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.note:SetPoint("TOPLEFT", panel.heading, "BOTTOMLEFT", 0, -4)
    panel.note:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    panel.note:SetJustifyH("LEFT")
    panel.note:SetHeight(34)

    local scroll = CreateFrame("ScrollFrame", "EasyWarCratesDataScroll", panel,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel.note, "BOTTOMLEFT", 0, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 56)

    panel.scrollChild = CreateFrame("Frame", nil, scroll)
    panel.scrollChild:SetSize(WIDTH - NAV_W - 56, 1)
    scroll:SetScrollChild(panel.scrollChild)

    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 4, -4)
    panel.empty:SetText("Nothing recorded here yet.")

    panel.footer = CreateFrame("Frame", nil, panel)
    panel.footer:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT", 12, 28)
    panel.footer:SetSize(WIDTH - NAV_W - 40, 20)

    panel.footerLabel = panel.footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.footerLabel:SetPoint("BOTTOMLEFT", panel.footer, "TOPLEFT", 2, 2)
    panel.footerLabel:SetJustifyH("LEFT")

    panel.clearAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.clearAll:SetSize(150, 22)
    panel.clearAll:SetPoint("BOTTOMRIGHT", -32, 14)
    panel.clearAll:SetScript("OnClick", function()
        local section = sectionByID(current)
        confirmClear(current, nil,
            ("Remove everything under %s? This cannot be undone."):format(section.title:lower()))
    end)

    panel:SetScript("OnShow", refresh)
    return panel
end

function ns.ToggleDataPanel(show)
    build()
    if show == nil then show = not panel:IsShown() end
    if show then panel:Show(); refresh() else panel:Hide() end
end
