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
-- Options panel
-------------------------------------------------------------------------------

local PANEL_WIDTH   = 280
local PANEL_PAD     = 16
local ROW_HEIGHT    = 26
local HEADER_HEIGHT = 22
local TITLE_HEIGHT  = 36

local optionsFrame
local checkboxes = {}   -- CheckButtons, each with .option and .label
local SUB_INDENT = 20   -- extra x offset for options that declare parent = "<key>"

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

local function Checkbox_OnEnter(self)
    if not self.option.tooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.option.label, 1, 1, 1)
    GameTooltip:AddLine(self.option.tooltip, nil, nil, nil, true)
    GameTooltip:Show()
end

local function CreateCloseButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(32, 32)
    b:SetPoint("TOPRIGHT", -2, -2)
    b:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    b:SetScript("OnClick", function() parent:Hide() end)
    return b
end

local function BuildOptionsPanel()
    if optionsFrame then return optionsFrame end

    local f = CreateFrame("Frame", "MooseModeOptionsFrame", UIParent, "BackdropTemplate")
    f:SetWidth(PANEL_WIDTH)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    -- Escape closes it.
    tinsert(UISpecialFrames, "MooseModeOptionsFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("|cffb04cffMooseMode|r")

    CreateCloseButton(f)

    -- Content: one header per module, one checkbox per option.
    local y = -TITLE_HEIGHT
    for _, mod in ipairs(ns.modules) do
        if #mod.options > 0 then
            local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", PANEL_PAD, y - 4)
            header:SetTextColor(0.7, 0.3, 1.0)
            header:SetText(mod.label or mod.key)
            y = y - HEADER_HEIGHT

            for _, opt in ipairs(OrderedOptions(mod)) do
                local cb = CreateFrame("CheckButton", nil, f, "ChatConfigCheckButtonTemplate")
                cb:SetSize(26, 26)
                cb:SetPoint("TOPLEFT", PANEL_PAD + (opt.parent and SUB_INDENT or 0), y)
                cb.option = opt
                -- The template ships its own text region; we use our own label
                -- so layout does not depend on template internals.
                if cb.Text then cb.Text:SetText("") end
                local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
                label:SetPoint("RIGHT", f, "RIGHT", -PANEL_PAD, 0)
                label:SetJustifyH("LEFT")
                label:SetWordWrap(false)
                label:SetText(opt.label)
                cb.label = label

                cb:SetScript("OnClick", Checkbox_OnClick)
                cb:SetScript("OnEnter", Checkbox_OnEnter)
                cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

                checkboxes[#checkboxes + 1] = cb
                y = y - ROW_HEIGHT
            end
            y = y - 6
        end
    end
    if #checkboxes == 0 then
        local none = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        none:SetPoint("TOPLEFT", PANEL_PAD, y - 4)
        none:SetText("No options registered.")
        y = y - ROW_HEIGHT
    end
    f:SetHeight(-y + PANEL_PAD)

    f:SetScript("OnShow", function()
        for _, cb in ipairs(checkboxes) do Checkbox_Refresh(cb) end
    end)

    -- Initial anchor: just below the minimap button, else screen centre.
    local mb = ns.GetMinimapButton and ns.GetMinimapButton()
    if mb then
        f:SetPoint("TOPRIGHT", mb, "BOTTOMLEFT", 8, -4)
    else
        f:SetPoint("CENTER")
    end

    optionsFrame = f
    return f
end

function ns.ToggleOptions()
    if not ns.db then return end
    local f = BuildOptionsPanel()
    if f:IsShown() then f:Hide() else f:Show() end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function PrintHelp()
    ns.Print("/mm  opens the options panel.  /mm minimap  toggles the minimap button.")
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
