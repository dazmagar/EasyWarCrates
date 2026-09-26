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
    -- Left-click says this row to the group. A row is the smallest thing a
    -- raid actually talks about -- "crate on the ground in ZA" -- so it is the
    -- thing worth making one click long.
    r:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or not self.data or not ns.Comm then return end
        local what = ns.Comm.AnnounceRow(self.data)
        if what == "alone" then
            ns.Print("|cff777777not in a group, so there is nobody to tell|r")
        elseif what == "nothing" then
            ns.Print("|cff777777nothing is known about that zone worth announcing|r")
        end
    end)

    r:SetScript("OnEnter", function(self)
        local d = self.data
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.GetZoneName(d.zoneID))
        if d.spectralOnly then
            local since = d.spectral and d.spectral.since or GetServerTime()
            GameTooltip:AddLine(("Spectral Battle Chest, on the ground for %s."):format(
                (ns.FormatClock(GetServerTime() - since):gsub("^%s+", ""))), 0.8, 0.55, 1, true)
            if d.spectral and d.spectral.x then
                GameTooltip:AddLine(("  at %.1f, %.1f"):format(
                    d.spectral.x * 100, d.spectral.y * 100), 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Not a war crate: no transport, no parachute, and it stays "
                .. "a minute or two. This zone's crate is on its own row.", 0.6, 0.6, 0.6, true)
            GameTooltip:AddLine(" ")
            local _, chestWhere = ns.Comm and ns.Comm.RowChannel()
            GameTooltip:AddLine(chestWhere and ("Left-click to post this to " .. chestWhere)
                or "Left-click to post this -- you are not in a group", 0.6, 0.6, 0.6)
            GameTooltip:Show()
            return
        end
        local said = d.shardFrom == "you" and "you are in it"
            or d.shardFrom and ("%s is in it"):format(tostring(d.shardFrom)) or nil
        GameTooltip:AddLine(("shard %s%s"):format(tostring(d.shardID or "?"),
            said and (" -- " .. said) or ""), 0.7, 0.7, 0.7)
        if d.newShard then
            GameTooltip:AddLine("This zone has been timed, but not this copy of it. "
                .. "A timer belongs to one copy, and entering a zone hands you one you did "
                .. "not choose, so another copy's countdown here would look like knowledge "
                .. "and send a raid out on the strength of it.", 1, 0.5, 0.3, true)
        elseif d.guessedShard then
            GameTooltip:AddLine("Which copy of the zone you are in is not known, so this "
                .. "countdown may belong to another one. Anyone in the raid standing there "
                .. "settles it.", 1, 0.5, 0.3, true)
        end
        if d.live then
            GameTooltip:AddLine(
                d.live.phase == "ground" and "a crate is on the ground here now"
                or d.live.phase == "falling" and "a crate is coming down here now"
                or "a transport is in the air here", 0.2, 1, 0.2)
            if d.live.from then
                -- Its own clock: this runs from a tooltip, not from the
                -- refresh that holds one.
                local seen = d.live.since
                    and (" %ds ago"):format(math.floor(GetServerTime() - d.live.since)) or ""
                GameTooltip:AddLine(("%s saw this%s, through %s. Nobody here has, and it "
                    .. "is about the copy of the zone they are in."):format(
                    tostring(d.live.from), seen, tostring(d.live.via or "this addon")),
                    0.6, 0.8, 0.7, true)
            end
        end
        if d.remaining then
            GameTooltip:AddLine(("transport appears in %s"):format(
                ns.FormatClock(d.remaining):gsub("^%s+", "")), 1, 1, 1)
        else
            GameTooltip:AddLine("never seen a crate here", 0.7, 0.7, 0.7)
        end
        if d.onGround then
            GameTooltip:AddLine(("lootable in %s"):format(
                ns.FormatClock(d.onGround):gsub("^%s+", "")), 1, 0.82, 0)
        end
        if not d.precise and d.remaining then
            GameTooltip:AddLine("~ the timer was seeded from a crate already on the ground, "
                .. "so the cycle is right but its phase is only as good as when it was spotted",
                1, 0.5, 0.3, true)
        end
        if d.spectral then
            local ago = GetServerTime() - (d.spectral.since or GetServerTime())
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("A Spectral Battle Chest has been on the ground here for %s.")
                :format((ns.FormatClock(ago):gsub("^%s+", ""))), 0.8, 0.55, 1, true)
            if d.spectral.x then
                GameTooltip:AddLine(("  at %.1f, %.1f"):format(
                    d.spectral.x * 100, d.spectral.y * 100), 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Not a war crate: it arrives without a transport and stays "
                .. "a minute or two, so it is worth reaching only from inside the zone.",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(" ")
        -- Only when there is something to post. A row can exist for the chest
        -- alone, and a click on that has nothing to say -- promising one is the
        -- same fault as not naming the channel was.
        local sayable = ns.Model.Announcement and ns.Model.Announcement(d, GetServerTime())
        local _, where = sayable and ns.Comm and ns.Comm.RowChannel()
        if sayable then
            GameTooltip:AddLine(where and ("Left-click to post this to " .. where)
                or "Left-click to post this -- you are not in a group", 0.6, 0.6, 0.6)
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
    -- Beside the shard rather than in the countdown column: the chest is a
    -- separate thing that happens to be in the same copy of the same zone, and
    -- the countdown belongs to the crate.
    local spectral = row.spectral and " |cffcc88ffspectral|r" or ""
    r.left:SetText(("%s|cffffffff%s|r %s%s"):format(mark, row.abbr, shard, spectral))

    if row.spectralOnly then
        -- Its own row, so it says its own thing. The live entry it carries is
        -- there to rank it and fill the bar, not to be read as a crate.
        local held = (row.spectral and row.spectral.since)
            and (" " .. (ns.FormatClock(GetServerTime() - row.spectral.since):gsub("^%s+", "")))
            or ""
        r.right:SetText(("|cffcc88ffCHEST ON THE GROUND%s|r"):format(held))
        r.bar:SetValue(1)
        r.bar:SetStatusBarColor(0.8, 0.53, 1, 1)
    elseif row.live then
        -- The crate that is there NOW, in place of the countdown to the next.
        -- The bar shows the descent rather than the cycle, so a row that is
        -- about to be worth flying to looks different from one that is not.
        --
        -- A dot marks what somebody else saw rather than what this client did.
        -- It matters: a report is about the copy of the zone THEY are in, and
        -- flying to it is a decision about somebody else's word.
        local said = row.live.from and "|cff33ddaa.|r" or ""
        if row.live.phase == "ground" then
            -- Claimed by your own side is not finished with: the marker says
            -- who captured it, and yours captured it, so it is still yours to
            -- go and take.
            local held = ""
            if row.live.toGone then
                held = (" %s"):format((ns.FormatClock(row.live.toGone):gsub("^%s+", "")))
            elseif row.live.held then
                -- Counting up, because how long one lasts has never been
                -- measured. It becomes a countdown once the readings agree.
                held = (" %s so far"):format((ns.FormatClock(row.live.held):gsub("^%s+", "")))
            end
            r.right:SetText(said .. (row.live.mine
                and ("|cff33ff99OURS%s|r"):format(held)
                or "|cff33ff99ON THE GROUND|r"))
            r.bar:SetValue(1)
        elseif row.live.phase == "falling" then
            r.right:SetText(said .. (row.live.toGround
                and ("|cffffd100landing %s|r"):format(ns.FormatClock(row.live.toGround):gsub("^%s+", ""))
                or "|cffffd100falling|r"))
            r.bar:SetValue(0.6)
        else
            r.right:SetText(said .. (row.live.toGround
                and ("|cffffd100inbound %s|r"):format(ns.FormatClock(row.live.toGround):gsub("^%s+", ""))
                or "|cffffd100inbound|r"))
            r.bar:SetValue(0.3)
        end
        r.bar:SetStatusBarColor(cr, cg, cb, 1)
    elseif not row.remaining then
        -- Blank has two meanings and they are not the same news. Never seen is
        -- a gap; a fresh shard is a fact about right now.
        r.right:SetText(row.newShard and "|cffff8800new shard|r" or "|cff777777-- : --|r")
    else
        -- A tilde says the timer was seeded from a crate found already on the
        -- ground, so the cycle is right but the phase is only as good as the
        -- moment it happened to be spotted.
        -- A ? says which copy of the zone this countdown belongs to is not
        -- known, which is a different doubt from the ~ above.
        local mark = row.guessedShard and "|cffff8800?|r" or (row.precise and "" or "~")
        local plane = mark .. ns.FormatClock(row.remaining):gsub("^%s+", "")
        -- Two moments in one crate's life, which is what a farmer is actually
        -- deciding between: when to be in the zone, and when it is worth
        -- landing on. Telling anybody when to set off was guesswork dressed as
        -- advice, and it needed a table of travel times to produce.
        local ground = row.onGround
            and ("  |cffffd100%s|r"):format(ns.FormatClock(row.onGround):gsub("^%s+", ""))
            or ""
        -- The missed-cycle count lives in the tooltip. On the row it was an
        -- unexplained "x2" next to two unexplained countdowns.
        r.right:SetText(plane .. ground)
    end
    r:Show()
end

local function refresh()
    if not frame or not frame:IsShown() then return end
    local now = GetServerTime()
    local list, nextRow = ns.Model.BuildRows(ns.db.crates, ns.db.route, now)

    -- Shown only when there is something to say. It used to read "no
    -- transport in the air" the rest of the time, which is the normal state
    -- and tells nobody anything -- and the rows carry the same news now, with
    -- the zone attached. What this still adds is the coordinates and how sure
    -- the call is, so it stays for that and gets out of the way otherwise.
    local head = ns.Model.Headline(ns.Zones.Normalize(C_Map.GetBestMapForUnit("player")), now)
    if head then
        frame.head:SetText(((head.ready and "|cffffd100" or "|cff777777") .. head.text .. "|r"))
        frame.head:Show()
    else
        frame.head:Hide()
    end

    local shown = math.min(#list, MAX_ROWS)
    for i = 1, MAX_ROWS do
        rows[i] = rows[i] or makeRow(frame.body, i)
        if i <= shown then paintRow(rows[i], list[i], list[i] == nextRow) else rows[i]:Hide() end
    end

    if shown == 0 then
        -- An empty database is the normal state for someone who has just
        -- installed this, and silence would read as broken. Say what to do.
        -- The weakest moment this addon has: everything it knows is
        -- learned, so a fresh install is blind in every zone. Saying what
        -- will fill it in is worth more than saying it is empty, and two
        -- of the three cost the player nothing but standing still.
        frame.empty:SetText("Nothing timed yet. Three things fill this in:\n"
            .. "|cff33ff99-|r an NPC announcing a cycle where you stand\n"
            .. "|cff33ff99-|r a crate you see, in the air or on the ground\n"
            .. "|cff33ff99-|r anyone in your raid running Hated Crate Tracker\n"
            .. "A cycle is about 18 minutes.")
        frame.empty:Show()
    else
        frame.empty:Hide()
    end

    frame.headRight:SetText("plane    drop")

    -- The headline only takes room when it has something in it.
    local headRoom = head and 16 or 0
    frame.header:SetPoint("TOPLEFT", PAD, -(24 + headRoom))
    frame.header:SetPoint("TOPRIGHT", -PAD, -(24 + headRoom))
    frame.body:SetPoint("TOPLEFT", 0, -(40 + headRoom))
    frame:SetHeight(44 + headRoom + math.max(shown, 3) * (ROW_H + ROW_GAP) + PAD)
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
    local function rememberWhereItLanded()
        frame:StopMovingOrSizing()
        local point, _, rel, x, y = frame:GetPoint()
        ns.db.window = { point = point, rel = rel, x = x, y = y }
    end
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", rememberWhereItLanded)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -6)
    title:SetText("EasyWarCrates")

    -- A button over the title, because a FontString takes no clicks. It has to
    -- forward dragging as well: the title is the natural place to grab a window
    -- by, and swallowing that to gain a click would be a poor trade.
    --
    -- Shift held, for the same reason the row click is deliberate: this speaks
    -- to everyone in the group, and grabbing a window to move it must not.
    local nameplate = CreateFrame("Button", nil, frame)
    nameplate:SetPoint("TOPLEFT", title, "TOPLEFT", -2, 2)
    nameplate:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT", 2, -2)
    nameplate:RegisterForDrag("LeftButton")
    nameplate:SetScript("OnDragStart", function() frame:StartMoving() end)
    nameplate:SetScript("OnDragStop", rememberWhereItLanded)
    nameplate:SetScript("OnClick", function()
        if not IsShiftKeyDown() or not ns.Comm then return end
        local what, channel = ns.Comm.AnnounceAddon()
        if what == "alone" then
            ns.Print("|cff777777not in a group, so there is nobody to tell|r")
        elseif what == "too-soon" then
            ns.Print("|cff777777said that recently -- give it a minute|r")
        elseif what == "sent" then
            ns.Print(("|cff777777named the addon in %s|r"):format(
                channel == "RAID" and "raid chat" or "party chat"))
        end
    end)
    nameplate:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("EasyWarCrates")
        local _, where = ns.Comm and ns.Comm.RowChannel()
        GameTooltip:AddLine(where and ("Shift-click to name this addon in "
            .. (where == "a raid warning" and "raid chat" or where))
            or "Shift-click to name this addon to your group", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Drag to move the window.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    nameplate:SetScript("OnLeave", GameTooltip_Hide)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() ns.ToggleWindow(false) end)

    frame.head = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.head:SetPoint("TOPLEFT", PAD, -22)
    frame.head:SetPoint("TOPRIGHT", -PAD, -22)
    frame.head:SetJustifyH("LEFT")

    frame.header = CreateFrame("Frame", nil, frame)
    frame.header:SetPoint("TOPLEFT", PAD, -24)
    frame.header:SetPoint("TOPRIGHT", -PAD, -24)
    frame.header:SetHeight(12)
    local hl = frame.header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hl:SetPoint("LEFT", 4, 0)
    hl:SetText("zone")
    frame.headRight = frame.header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.headRight:SetPoint("RIGHT", -4, 0)
    frame.headRight:SetText("drop    leave")

    frame.body = CreateFrame("Frame", nil, frame)
    frame.body:SetPoint("TOPLEFT", 0, -40)
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
