-------------------------------------------------------------------------------
-- MooseMode -- Core
--
-- Module system, account-wide saved variables, shared helpers and the
-- /moosemode and /mm slash commands. Feature modules live in Modules\ and
-- register themselves with ns:RegisterModule().
--
-- Target: World of Warcraft: Forever (interface 16001). Forever runs the
-- Retail 12.x API without the old Classic globals, so everything goes
-- through the C_* namespaces.
-------------------------------------------------------------------------------

local ADDON, ns = ...

ns.modules = {}          -- ordered list of registered modules
ns.db = nil              -- MooseModeDB once ADDON_LOADED has fired

local CORE_DEFAULTS = {
    minimap = { angle = 220, hide = false },
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

function ns.Print(msg)
    (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffb04cffMooseMode|r: " .. tostring(msg))
end

-- Secret values (Midnight/Forever restriction) throw on comparison. A guard
-- costs nothing and keeps the addon quiet if item data ever becomes secret.
function ns.IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

function ns.Coins(copper)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    elseif GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    return tostring(copper) .. "c"
end

function ns.ItemIDFrom(text)
    if not text or text == "" then return nil end
    local id = tonumber(text)
    if id then return id end
    if GetItemInfoFromHyperlink then
        id = GetItemInfoFromHyperlink(text)
        if id then return id end
    end
    return tonumber(text:match("item:(%d+)"))
end

function ns.ItemNameByID(id)
    if C_Item and C_Item.GetItemNameByID then
        return C_Item.GetItemNameByID(id) or ("item:" .. id)
    end
    return "item:" .. id
end

-------------------------------------------------------------------------------
-- Module registry
--
-- mod = {
--   key      = "autoSell",            -- unique id
--   label    = "Auto Sell",           -- header in the options panel
--   options  = { { key, label, tooltip, default, onChange, parent }, ... },
--              -- parent = "<optionKey>" makes this a sub-option: rendered
--              -- indented under that option and greyed out while it is off
--   OnInit   = function(mod) end,     -- called once ns.db exists (optional)
--   commands = { sub = function(rest) end, ... },  -- /mm <sub> (optional)
-- }
-------------------------------------------------------------------------------

function ns:RegisterModule(mod)
    assert(type(mod) == "table" and mod.key, "MooseMode: module needs a key")
    mod.options = mod.options or {}
    mod.commands = mod.commands or {}
    table.insert(ns.modules, mod)
    return mod
end

local function ApplyDefaults(db)
    for k, v in pairs(CORE_DEFAULTS) do
        if type(v) == "table" then
            db[k] = db[k] or {}
            for k2, v2 in pairs(v) do
                if db[k][k2] == nil then db[k][k2] = v2 end
            end
        elseif db[k] == nil then
            db[k] = v
        end
    end
    for _, mod in ipairs(ns.modules) do
        for _, opt in ipairs(mod.options) do
            if db[opt.key] == nil then db[opt.key] = opt.default end
        end
    end
end

-- Placeholders; the minimap button and options panel sections replace these.
ns.ToggleOptions = ns.ToggleOptions or function() ns.Print("Options panel not available.") end
ns.ToggleMinimap = ns.ToggleMinimap or function() ns.Print("Minimap button not available.") end
ns.OnInitCallbacks = {}   -- core-level hooks run after ns.db exists

-------------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    MooseModeDB = MooseModeDB or {}
    ns.db = MooseModeDB
    ApplyDefaults(ns.db)

    for _, mod in ipairs(ns.modules) do
        if mod.OnInit then mod.OnInit(mod) end
    end
    for _, fn in ipairs(ns.OnInitCallbacks) do fn() end
end)

-------------------------------------------------------------------------------
-- Minimap button (purple star)
-------------------------------------------------------------------------------

local minimapButton

local function MinimapButton_UpdatePosition()
    if not minimapButton or not ns.db then return end
    local angle = math.rad(ns.db.minimap.angle or 220)
    local radius = (Minimap:GetWidth() / 2) + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function MinimapButton_OnDragUpdate(self)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    ns.db.minimap.angle = math.deg(math.atan2(py - my, px - mx))
    MinimapButton_UpdatePosition()
end

local function CreateMinimapButton()
    if minimapButton then return minimapButton end

    local b = CreateFrame("Button", "MooseModeMinimapButton", Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetMovable(true)
    b:EnableMouse(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetVertexColor(0.12, 0.05, 0.18)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    icon:SetTexCoord(0, 0.25, 0, 0.25)          -- the star
    icon:SetVertexColor(0.7, 0.25, 1.0)          -- dank purple
    icon:SetPoint("TOPLEFT", 7, -6)
    b.icon = icon

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", MinimapButton_OnDragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            ns.ToggleOptions()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffb04cffMooseMode|r")
        GameTooltip:AddLine("Left-click: options", 1, 1, 1)
        GameTooltip:AddLine("Drag: move", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton = b
    MinimapButton_UpdatePosition()
    return b
end

function ns.GetMinimapButton()
    return minimapButton
end

function ns.ToggleMinimap()
    if not ns.db then return end
    ns.db.minimap.hide = not ns.db.minimap.hide
    if ns.db.minimap.hide then
        if minimapButton then minimapButton:Hide() end
        ns.Print("Minimap button hidden. Type /mm minimap to show it again.")
    else
        CreateMinimapButton():Show()
        ns.Print("Minimap button shown.")
    end
end

table.insert(ns.OnInitCallbacks, function()
    if not ns.db.minimap.hide then
        CreateMinimapButton():Show()
    end
end)

-------------------------------------------------------------------------------
-- Options dialog
--
-- A centred settings window: title bar, two balanced columns of sections
-- (one per module, header + separator + rows), and a footer. Labels wrap
-- instead of truncating. Sub-options (opt.parent) indent and grey out with
-- their parent. Everything persists per account through ns.db.
-------------------------------------------------------------------------------

local DIALOG_WIDTH    = 640
local DIALOG_PAD      = 20
local COLUMN_GAP      = 24
local TITLE_HEIGHT    = 44
local FOOTER_HEIGHT   = 30
local SECTION_GAP     = 14
local HEADER_HEIGHT   = 20
local ROW_MIN_HEIGHT  = 24
local CHECK_SIZE      = 24
local SUB_INDENT      = 22
local LABEL_GAP       = 4
local BORDER_INSET    = 4
local MAX_SCREEN_FRAC = 0.8
local SCROLL_STEP     = 40

local PURPLE_R, PURPLE_G, PURPLE_B = 0.69, 0.3, 1.0

local optionsFrame
local checkboxes = {}   -- CheckButtons, each with .option and .label

-- A sub-option (opt.parent = "<optionKey>") is greyed out and unclickable
-- while its parent option is off.
local function Checkbox_UpdateEnabled(cb)
    local parent = cb.option.parent
    if not parent then return end
    if ns.db[parent] then
        cb:Enable()
        cb.label:SetTextColor(1, 1, 1)
    else
        cb:Disable()
        cb.label:SetTextColor(0.5, 0.5, 0.5)
    end
end

local function Checkbox_UpdateChildren(parentKey)
    for _, cb in ipairs(checkboxes) do
        if cb.option.parent == parentKey then Checkbox_UpdateEnabled(cb) end
    end
end

local function Checkbox_Refresh(cb)
    cb:SetChecked(ns.db[cb.option.key] and true or false)
    Checkbox_UpdateEnabled(cb)
end

local function Checkbox_OnClick(self)
    local checked = self:GetChecked() and true or false
    ns.db[self.option.key] = checked
    if self.option.onChange then
        self.option.onChange(checked, self.option)
    end
    Checkbox_UpdateChildren(self.option.key)
end

-- Options in display order: each top-level option followed by its children,
-- so a sub-option always sits directly under its parent whatever order the
-- module listed them in. Children of unknown parents are appended at the end.
local function OrderedOptions(mod)
    local ordered, placed = {}, {}
    for _, opt in ipairs(mod.options) do
        if not opt.parent then
            ordered[#ordered + 1] = opt
            placed[opt] = true
            for _, child in ipairs(mod.options) do
                if child.parent == opt.key and not placed[child] then
                    ordered[#ordered + 1] = child
                    placed[child] = true
                end
            end
        end
    end
    for _, opt in ipairs(mod.options) do
        if not placed[opt] then ordered[#ordered + 1] = opt end
    end
    return ordered
end

local function ShowOptionTooltip(owner, opt)
    if not opt.tooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(opt.label, 1, 1, 1)
    GameTooltip:AddLine(opt.tooltip, nil, nil, nil, true)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

-- Solid colour texture; no file dependency.
local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a)
    return t
end

local function CreateCloseButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(32, 32)
    b:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    b:SetScript("OnClick", function() parent:Hide() end)
    return b
end

-- One option: a row frame holding the checkbox and a wrapping label. The row
-- itself answers hover (tooltip) and click (toggle) so the label is live too.
local function CreateOptionRow(parent, opt, width)
    local indent = opt.parent and SUB_INDENT or 0

    local row = CreateFrame("Frame", nil, parent)
    row:SetWidth(width)
    row:EnableMouse(true)

    local cb = CreateFrame("CheckButton", nil, row, "ChatConfigCheckButtonTemplate")
    cb:SetSize(CHECK_SIZE, CHECK_SIZE)
    cb:SetPoint("TOPLEFT", row, "TOPLEFT", indent, 0)
    cb.option = opt
    -- The template ships its own text region; we use our own label so the
    -- layout does not depend on template internals.
    if cb.Text then cb.Text:SetText("") end

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetWidth(width - indent - CHECK_SIZE - LABEL_GAP)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetWordWrap(true)
    label:SetNonSpaceWrap(false)
    label:SetText(opt.label)
    cb.label = label

    local textHeight = label:GetStringHeight() or 0
    if textHeight <= 16 then
        -- Single line: centre it on the box.
        label:SetPoint("LEFT", cb, "RIGHT", LABEL_GAP, 0)
        row:SetHeight(ROW_MIN_HEIGHT)
    else
        -- Wrapped: hang from the top of the box and let the row grow.
        label:SetPoint("TOPLEFT", cb, "TOPRIGHT", LABEL_GAP, -4)
        row:SetHeight(math.max(ROW_MIN_HEIGHT, textHeight + 8))
    end

    cb:SetScript("OnClick", Checkbox_OnClick)
    cb:SetScript("OnEnter", function(self) ShowOptionTooltip(self, self.option) end)
    cb:SetScript("OnLeave", HideTooltip)

    row:SetScript("OnEnter", function(self) ShowOptionTooltip(self, opt) end)
    row:SetScript("OnLeave", HideTooltip)
    row:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and cb:IsEnabled() then cb:Click() end
    end)

    checkboxes[#checkboxes + 1] = cb
    return row
end

-- One module: purple header, hairline, then its option rows.
local function CreateSection(parent, mod, width)
    local sec = CreateFrame("Frame", nil, parent)
    sec:SetWidth(width)

    local header = sec:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetTextColor(PURPLE_R, PURPLE_G, PURPLE_B)
    header:SetText(mod.label or mod.key)

    local line = Solid(sec, "ARTWORK", PURPLE_R, PURPLE_G, PURPLE_B, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
    line:SetPoint("TOPRIGHT", 0, -HEADER_HEIGHT)

    local y = -(HEADER_HEIGHT + 6)
    for _, opt in ipairs(OrderedOptions(mod)) do
        local row = CreateOptionRow(sec, opt, width)
        row:SetPoint("TOPLEFT", 0, y)
        y = y - row:GetHeight()
    end
    sec:SetHeight(-y)
    return sec
end

-- Lays every module section into the shorter of two columns. Returns the
-- body frame and its natural height.
local function CreateBody(parent, bodyWidth)
    local body = CreateFrame("Frame", nil, parent)
    body:SetWidth(bodyWidth)

    local colWidth = (bodyWidth - COLUMN_GAP) / 2
    local heights = { 0, 0 }
    local placed = 0
    for _, mod in ipairs(ns.modules) do
        if #mod.options > 0 then
            local col = (heights[1] <= heights[2]) and 1 or 2
            local sec = CreateSection(body, mod, colWidth)
            sec:SetPoint("TOPLEFT", body, "TOPLEFT", (col - 1) * (colWidth + COLUMN_GAP), -heights[col])
            heights[col] = heights[col] + sec:GetHeight() + SECTION_GAP
            placed = placed + 1
        end
    end

    local height
    if placed == 0 then
        local none = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        none:SetPoint("TOPLEFT", 0, 0)
        none:SetText("No options registered.")
        height = ROW_MIN_HEIGHT
    else
        height = math.max(heights[1], heights[2]) - SECTION_GAP
    end
    body:SetHeight(height)
    return body, height
end

-- Wraps the body in a mouse-wheel scroll frame with a slim indicator when it
-- would not fit on screen.
local function CreateScroller(parent, body, bodyWidth, viewHeight)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetSize(bodyWidth, viewHeight)
    scroll:SetScrollChild(body)
    scroll:EnableMouseWheel(true)

    local track = Solid(parent, "ARTWORK", 1, 1, 1, 0.08)
    track:SetWidth(3)
    track:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
    track:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 0)

    local thumb = Solid(parent, "OVERLAY", PURPLE_R, PURPLE_G, PURPLE_B, 0.7)
    thumb:SetWidth(3)

    local function UpdateThumb()
        local range = scroll:GetVerticalScrollRange()
        local total = viewHeight + range
        local thumbHeight = math.max(16, viewHeight * (viewHeight / total))
        local offset = (range > 0) and ((viewHeight - thumbHeight) * (scroll:GetVerticalScroll() / range)) or 0
        thumb:SetHeight(thumbHeight)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -offset)
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local target = self:GetVerticalScroll() - delta * SCROLL_STEP
        target = math.max(0, math.min(self:GetVerticalScrollRange(), target))
        self:SetVerticalScroll(target)
    end)
    scroll:SetScript("OnVerticalScroll", UpdateThumb)
    scroll:SetScript("OnScrollRangeChanged", UpdateThumb)
    scroll:SetScript("OnShow", UpdateThumb)
    return scroll
end

local function AddonVersion()
    local v
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        v = C_AddOns.GetAddOnMetadata(ADDON, "Version")
    elseif GetAddOnMetadata then
        v = GetAddOnMetadata(ADDON, "Version")
    end
    return v and ("v" .. v) or ""
end

local function BuildOptionsDialog()
    if optionsFrame then return optionsFrame end

    local f = CreateFrame("Frame", "MooseModeOptionsFrame", UIParent, "BackdropTemplate")
    f:SetWidth(DIALOG_WIDTH)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 14,
        insets = { left = BORDER_INSET, right = BORDER_INSET, top = BORDER_INSET, bottom = BORDER_INSET },
    })
    f:SetBackdropColor(0.06, 0.04, 0.09, 0.95)
    f:SetBackdropBorderColor(0.55, 0.3, 0.9)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:Hide()

    -- Escape closes it.
    tinsert(UISpecialFrames, "MooseModeOptionsFrame")

    -- Title bar: tinted strip, title, version hint, close button. Dragging it
    -- moves the dialog.
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", BORDER_INSET, -BORDER_INSET)
    titleBar:SetPoint("TOPRIGHT", -BORDER_INSET, -BORDER_INSET)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local strip = Solid(titleBar, "BACKGROUND", 0.55, 0.3, 0.9, 0.25)
    strip:SetAllPoints()

    local stripLine = Solid(titleBar, "ARTWORK", PURPLE_R, PURPLE_G, PURPLE_B, 0.5)
    stripLine:SetHeight(1)
    stripLine:SetPoint("BOTTOMLEFT")
    stripLine:SetPoint("BOTTOMRIGHT")

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", DIALOG_PAD - BORDER_INSET, 0)
    title:SetTextColor(PURPLE_R, PURPLE_G, PURPLE_B)
    title:SetText("MooseMode")

    local subtitle = titleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 10, -1)
    local version = AddonVersion()
    subtitle:SetText(version ~= "" and (version .. "   /mm or /moose") or "/mm or /moose")

    local close = CreateCloseButton(f)
    close:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", 2, 6)

    -- Body, scrolled only when it would not fit on screen.
    local bodyWidth = DIALOG_WIDTH - 2 * DIALOG_PAD
    local body, bodyHeight = CreateBody(f, bodyWidth)
    local chrome = TITLE_HEIGHT + FOOTER_HEIGHT + 2 * DIALOG_PAD + 2 * BORDER_INSET
    local maxBody = math.floor(UIParent:GetHeight() * MAX_SCREEN_FRAC) - chrome
    local viewHeight = bodyHeight
    local bodyAnchor = body
    if bodyHeight > maxBody then
        viewHeight = maxBody
        bodyAnchor = CreateScroller(f, body, bodyWidth, viewHeight)
    end
    bodyAnchor:SetPoint("TOPLEFT", f, "TOPLEFT", DIALOG_PAD, -(BORDER_INSET + TITLE_HEIGHT + DIALOG_PAD))

    -- Footer.
    local footerLine = Solid(f, "ARTWORK", PURPLE_R, PURPLE_G, PURPLE_B, 0.35)
    footerLine:SetHeight(1)
    footerLine:SetPoint("BOTTOMLEFT", DIALOG_PAD, BORDER_INSET + FOOTER_HEIGHT)
    footerLine:SetPoint("BOTTOMRIGHT", -DIALOG_PAD, BORDER_INSET + FOOTER_HEIGHT)

    local footerLeft = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerLeft:SetPoint("BOTTOMLEFT", DIALOG_PAD, BORDER_INSET + (FOOTER_HEIGHT - 12) / 2)
    footerLeft:SetJustifyH("LEFT")
    footerLeft:SetText("Settings are saved for the whole account.")

    local footerRight = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerRight:SetPoint("BOTTOMRIGHT", -DIALOG_PAD, BORDER_INSET + (FOOTER_HEIGHT - 12) / 2)
    footerRight:SetJustifyH("RIGHT")
    footerRight:SetText("Hold Shift at an NPC or vendor to skip automation once.")

    f:SetHeight(chrome + viewHeight)

    f:SetScript("OnShow", function()
        for _, cb in ipairs(checkboxes) do Checkbox_Refresh(cb) end
    end)

    f:SetPoint("CENTER")

    optionsFrame = f
    return f
end

function ns.ToggleOptions()
    if not ns.db then return end
    local f = BuildOptionsDialog()
    if f:IsShown() then f:Hide() else f:Show() end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function PrintHelp()
    ns.Print("/mm or /moose  opens the options dialog.  /mm minimap  toggles the minimap button.")
    for _, mod in ipairs(ns.modules) do
        local names = {}
        for sub in pairs(mod.commands) do names[#names + 1] = sub end
        if #names > 0 then
            table.sort(names)
            ns.Print(mod.label .. ": " .. table.concat(names, ", "))
        end
    end
end

SLASH_MOOSEMODE1 = "/moosemode"
SLASH_MOOSEMODE2 = "/mm"
SLASH_MOOSEMODE3 = "/moose"
SlashCmdList.MOOSEMODE = function(msg)
    if not ns.db then return end
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ns.ToggleOptions()
        return
    elseif cmd == "minimap" then
        ns.ToggleMinimap()
        return
    elseif cmd == "help" then
        PrintHelp()
        return
    end

    for _, mod in ipairs(ns.modules) do
        local fn = mod.commands[cmd]
        if fn then
            fn(rest)
            return
        end
    end
    PrintHelp()
end
