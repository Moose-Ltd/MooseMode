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
--   options  = { { key, label, tooltip, default, onChange }, ... },
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
