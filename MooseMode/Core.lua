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

-- Two copies can sit side by side: the CurseForge release in
-- AddOns\\MooseMode and a development link in AddOns\\MooseModeDev (see
-- install.ps1). Only one may run, or both would sell, loot and bind keys at
-- once. The release loads first (alphabetical), so it checks for the dev
-- copy: when that is enabled, the release stays off for the session. This
-- file and every module return straight away when ns.disabled is set.
local DEV_ADDON = "MooseModeDev"
if ADDON ~= DEV_ADDON then
    local isLoadable = (C_AddOns and C_AddOns.IsAddOnLoadable) or IsAddOnLoadable
    local ok, loadable = false, false
    if isLoadable then ok, loadable = pcall(isLoadable, DEV_ADDON) end
    if ok and loadable then
        ns.disabled = true
        local note = CreateFrame("Frame")
        note:RegisterEvent("PLAYER_LOGIN")
        note:SetScript("OnEvent", function()
            print("|cffb04cffMooseMode|r: the dev copy (MooseModeDev) is enabled, so the CurseForge copy stays off this session.")
        end)
        return
    end
end

ns.modules = {}          -- ordered list of registered modules
ns.db = nil              -- MooseModeDB once ADDON_LOADED has fired

local CORE_DEFAULTS = {
    minimap = { angle = 220, hide = false, iconDX = 0, iconDY = 0 },
    optionsPos = { x = 0, y = 0 },   -- dialog centre offset from screen centre
    ui = { group = "Vendors", allClasses = false },   -- dialog: selected group, "Other classes" switch
    uiExpanded = {},                  -- dialog: [moduleKey] = true for open cards
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
--   group    = "Vendors",             -- heading the section sits under:
--                                     -- Vendors, Quests, Loot, Combat, Interface
--   options  = { { key, label, tooltip, default, onChange, parent }, ... },
--              -- parent = "<optionKey>" makes this a sub-option: rendered
--              -- indented under that option and greyed out while it is off;
--              -- sub-options may themselves have sub-options
--              -- { type = "button", label, buttonText, tooltip, onClick }
--              -- buttonText may be a function(opt) returning the text; it is
--              -- re-read whenever the dialog refreshes (ns.RefreshOptionsDialog)
--              -- is a one-off action row (no key, nothing saved); a second
--              -- button with pair = true shares the previous button's row
--              -- { type = "choice", key, label, tooltip, default, parent,
--              --   values = { { value = "a", text = "A" }, ... }, onChange }
--              -- is a segmented switch; ns.db[key] holds the chosen value
--              -- { type = "note", text } is help text; the dialog shows it
--              -- in the module header's tooltip
--              -- Any option may also carry
--              --   hidden  = true | function(opt) -> bool (row not shown)
--              --   classes = { "HUNTER", ... }   (shown only on those)
--   OnInit   = function(mod) end,     -- called once ns.db exists (optional)
--   commands = { sub = function(rest) end, ... },  -- /mm <sub> (optional)
--
--   Dialog metadata, all optional:
--   summary  = "One line under the name in the dialog.",
--              -- default: first sentence of the master option's tooltip
--   icon     = "Interface\\Icons\\INV_Misc_Coin_02",  -- default: group icon
--   classes  = { "HUNTER", "WARLOCK" },
--              -- class file tokens (second return of UnitClass). The card
--              -- is hidden on every other class unless the dialog's
--              -- "Other classes" switch is on. nil = every class. Display
--              -- only: modules still check the class at run time.
--   beta     = "Disclaimer shown in the card's tooltip." | true,
--              -- adds an amber BETA badge beside the name
--   classesOverride = "<optionKey>",
--              -- while this option is on, the module counts as meant for
--              -- every class (e.g. a "Show on every class" option)
--   master   = "<optionKey>" | false,
--              -- the switch shown in the card header. Default: the first
--              -- top-level option when it is a checkbox with sub-options,
--              -- or the module's only control. false = none.
--   available = function(mod) return false, "Reason." end,
--              -- false dims the card and shows the reason as its summary
--              -- (e.g. a skill the character lacks); still editable
--   hidden   = true | function(mod) -> bool  (hide the whole card)
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
            -- Button rows carry no setting and no key.
            if opt.key and db[opt.key] == nil then db[opt.key] = opt.default end
        end
    end
end

-------------------------------------------------------------------------------
-- Shared helpers for modules
-------------------------------------------------------------------------------

-- CVar access, pcall-wrapped, C_CVar first with the globals as fallback.
ns.CVar = {}

function ns.CVar.Exists(name)
    local getInfo = (C_CVar and C_CVar.GetCVarInfo) or GetCVarInfo
    if not getInfo then return false end
    local ok, value = pcall(getInfo, name)
    return ok and value ~= nil
end

function ns.CVar.Get(name)
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, value = pcall(get, name)
    if not ok then return nil end
    return value
end

function ns.CVar.Set(name, value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not set then return false end
    local ok = pcall(set, name, tostring(value))
    return ok
end

-- Drive a per-character CVar from an account-wide option. Enabling remembers
-- the current value under ns.db[dbKey] (always, even when it already equals
-- the target, so disabling later restores exactly what the character had)
-- and writes the target. Disabling restores the remembered value and forgets
-- it; with nothing remembered it leaves the CVar alone. Returns true when the
-- CVar was written.
function ns.CVar.ApplyWithSnapshot(name, target, dbKey, enabled)
    local db = ns.db
    if not db then return false end
    target = tostring(target)
    local current = ns.CVar.Get(name)
    if enabled then
        if db[dbKey] == nil and current ~= nil then db[dbKey] = current end
        if current ~= target then return ns.CVar.Set(name, target) end
        return false
    end
    local restore = db[dbKey]
    db[dbKey] = nil
    if restore ~= nil and current ~= tostring(restore) then
        return ns.CVar.Set(name, restore)
    end
    return false
end

-- Screen-centre guides for anything the player drags (the swing bar, the
-- loot window placeholder). Begin(frame) when the drag starts shows two
-- hairlines through the middle of the screen; each lights up while the
-- frame's centre is within SNAP of it, with a label saying which. End()
-- hides them. Snap(dx, dy) pulls a drop offset onto a lit line; holding
-- Shift turns snapping (and the lighting) off.
--
-- Extra lines: Begin(frame, extras) and Snap(dx, dy, extras) also take a
-- list of { axis = "x" or "y", label = "...", get = function() return
-- offset end }, where get returns the line's offset from screen centre in
-- UIParent units (or nil to skip it). An "x" line is vertical and lines up
-- centres left to right; a "y" line is horizontal. Screen centre wins ties.
ns.CentreGuides = { SNAP = 8 }
do
    local G = ns.CentreGuides
    local IDLE = { 1, 1, 1, 0.18 }
    local HOT  = { 0.69, 0.30, 1.00, 0.95 }
    local guides, target, extras

    -- A frame's centre relative to the screen's centre, in UIParent units.
    function ns.CentreOffset(frame)
        local x, y = frame:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if not (x and ux) then return nil end
        local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
        return x * scale - ux, y * scale - uy
    end

    function G.Snapping()
        return not (IsShiftKeyDown and IsShiftKeyDown())
    end

    local function ExtraValue(e)
        local ok, v = pcall(e.get)
        return ok and type(v) == "number" and v or nil
    end

    function G.Snap(dx, dy, list)
        if not G.Snapping() then return dx, dy end
        local snappedX, snappedY = false, false
        if math.abs(dx) <= G.SNAP then dx, snappedX = 0, true end
        if math.abs(dy) <= G.SNAP then dy, snappedY = 0, true end
        for _, e in ipairs(list or {}) do
            local v = ExtraValue(e)
            if v then
                if e.axis == "x" and not snappedX and math.abs(dx - v) <= G.SNAP then dx, snappedX = v, true end
                if e.axis == "y" and not snappedY and math.abs(dy - v) <= G.SNAP then dy, snappedY = v, true end
            end
        end
        return dx, dy
    end

    local function Paint(tex, hot, vertical)
        local c = hot and HOT or IDLE
        tex:SetColorTexture(c[1], c[2], c[3], c[4])
        local w = hot and 2 or 1
        if vertical then tex:SetWidth(w) else tex:SetHeight(w) end
    end

    local function Update()
        if not target then return end
        local dx, dy = ns.CentreOffset(target)
        if not dx then return end
        local snap = G.Snapping()
        local onX = math.abs(dx) <= G.SNAP
        local onY = math.abs(dy) <= G.SNAP
        Paint(guides.v, onX and snap, true)
        Paint(guides.h, onY and snap, false)
        local text = ""
        if not snap then text = "|cff999999Snapping off (Shift)|r"
        elseif onX and onY then text = "|cffb04cffDead centre|r"
        elseif onX then text = "|cffb04cffCentred horizontally|r"
        elseif onY then text = "|cffb04cffCentred vertically|r" end
        -- Extra lines, each with its own label beside it when lit.
        for i, e in ipairs(extras or {}) do
            local line = guides.extra[i]
            local v = ExtraValue(e)
            if not v then
                line:Hide(); line.label:Hide()
            else
                local vertical = e.axis == "x"
                local hot = snap and math.abs((vertical and dx or dy) - v) <= G.SNAP
                    and not (vertical and onX or (not vertical and onY))
                line:ClearAllPoints()
                line.label:ClearAllPoints()
                if vertical then
                    line:SetPoint("TOP", UIParent, "TOP", v, 0)
                    line:SetPoint("BOTTOM", UIParent, "BOTTOM", v, 0)
                    line.label:SetPoint("BOTTOMLEFT", UIParent, "CENTER", v + 6, dy + 24)
                else
                    line:SetPoint("LEFT", UIParent, "LEFT", 0, v)
                    line:SetPoint("RIGHT", UIParent, "RIGHT", 0, v)
                    line.label:SetPoint("BOTTOMLEFT", UIParent, "CENTER", dx + 24, v + 4)
                end
                Paint(line, hot, vertical)
                line.label:SetText(hot and ("|cffb04cff" .. tostring(e.label) .. "|r") or "")
                line:Show(); line.label:Show()
            end
        end
        guides.label:SetText(text)
    end

    local function Build()
        if guides then return end
        guides = CreateFrame("Frame", nil, UIParent)
        guides:SetAllPoints(UIParent)
        guides:SetFrameStrata("TOOLTIP")
        guides:EnableMouse(false)
        guides.v = guides:CreateTexture(nil, "OVERLAY")
        guides.v:SetPoint("TOP", UIParent, "TOP", 0, 0)
        guides.v:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
        guides.h = guides:CreateTexture(nil, "OVERLAY")
        guides.h:SetPoint("LEFT", UIParent, "LEFT", 0, 0)
        guides.h:SetPoint("RIGHT", UIParent, "RIGHT", 0, 0)
        guides.label = guides:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        guides.label:SetPoint("BOTTOMLEFT", UIParent, "CENTER", 6, 6)
        guides.extra = {}
        guides:SetScript("OnUpdate", Update)
        guides:Hide()
    end

    function G.Begin(frame, list)
        Build()
        target, extras = frame, list
        for i = 1, #(list or {}) do
            if not guides.extra[i] then
                local t = guides:CreateTexture(nil, "OVERLAY")
                t.label = guides:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                guides.extra[i] = t
            end
        end
        for i = #(list or {}) + 1, #guides.extra do
            guides.extra[i]:Hide(); guides.extra[i].label:Hide()
        end
        Update()
        guides:Show()
    end

    function G.End()
        target, extras = nil, nil
        if guides then guides:Hide() end
    end
end

-- Event names differ between client lines; register only those that exist.
function ns.SafeRegisterEvent(frame, event)
    local ok = pcall(frame.RegisterEvent, frame, event)
    return ok
end

-- Highest bag ID of the ordinary bags (backpack is 0). The combined bag
-- window ignores a reagent bag, so every module counts the same way.
function ns.NumBags()
    if Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumBagSlots then
        return Constants.InventoryConstants.NumBagSlots
    end
    return NUM_BAG_SLOTS or 4
end

-- Placeholders; the minimap button and options panel sections replace these.
ns.ToggleOptions = ns.ToggleOptions or function() ns.Print("Options panel not available.") end
ns.ToggleMinimap = ns.ToggleMinimap or function() ns.Print("Minimap button not available.") end
ns.OnInitCallbacks = {}   -- core-level hooks run after ns.db exists

-------------------------------------------------------------------------------
-- Settings backup in account macros
--
-- The Forever beta client writes SavedVariables on logout but never reads
-- them back at launch (Blizzard bug, confirmed with a pre-seeded file), so
-- every session would start from defaults. Macros made with CreateMacro do
-- survive a cold start, so every setting that differs from its default is
-- also written into one or more account macros named MMcfg1, MMcfg2, ... and
-- read back when the saved table arrives empty.
--
-- Payload: "v1;key=value;key.sub=value;..." with typed values: b1/b0 for
-- booleans, n<number>, s<string> (';', '=', '%' and newlines percent-escaped).
-- Each macro body is "/mm cfg" on the first line and a slice of the payload
-- on the second, so clicking one by accident only prints a note.
-------------------------------------------------------------------------------

local SV_TAG          = "v1"
local SV_MACRO_PREFIX = "MMcfg"
local SV_MACRO_ICON   = "INV_MISC_QUESTIONMARK"
local SV_MACRO_HEAD   = "/mm cfg\n"
local SV_CHUNK_MAX    = 255 - #SV_MACRO_HEAD
local SV_DEBOUNCE     = 2

local svPending, svScheduled, svWarned, svRestored = false, false, false, false
local svDirty, svMacrosReady, svAbsentConfirmed = false, false, false
local svHadKeysAtLoad = false

-- True while a late settings restore is still possible: the saved table was
-- empty at load and neither a restore nor a confirmed "no backup" has
-- happened yet. Modules that push settings into per-character client state
-- at login wait for the restore instead of applying defaults first.
function ns.SettingsRestorePending()
    return (not svHadKeysAtLoad) and (not svRestored) and (not svAbsentConfirmed)
end

-- Second backup channel: a registered CVar. On this client a registered CVar
-- survives /reload (but not a restart) and is readable at ADDON_LOADED, while
-- account macros are server-synced and a reload can hand back a stale copy.
-- Reload restores from the CVar; a cold start falls back to the macros.
local SV_CVAR = "MooseModeCfg"
local svCvarReady = false

local function SvCvarInit()
    if svCvarReady then return true end
    if not (C_CVar and C_CVar.RegisterCVar) then return false end
    local ok = pcall(C_CVar.RegisterCVar, SV_CVAR, "")
    svCvarReady = ok and true or false
    return svCvarReady
end

local function SvCvarRead()
    if not SvCvarInit() then return nil end
    local ok, v = pcall(C_CVar.GetCVar, SV_CVAR)
    if not ok or type(v) ~= "string" or v == "" then return nil end
    return v
end

local function SvCvarWrite(payload)
    if not SvCvarInit() then return false end
    local ok = pcall(C_CVar.SetCVar, SV_CVAR, payload or "")
    return ok and true or false
end

local function OptionByKey(key)
    for _, mod in ipairs(ns.modules) do
        for _, opt in ipairs(mod.options) do
            if opt.key == key then return opt end
        end
    end
    return nil
end

local function SvEscape(s)
    return (s:gsub("[%%;=\n]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

local function SvUnescape(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function SvEncodeValue(v)
    local t = type(v)
    if t == "boolean" then return v and "b1" or "b0" end
    if t == "number" then return "n" .. tostring(v) end
    if t == "string" then return "s" .. SvEscape(v) end
    return nil
end

local function SvDecodeValue(s)
    local tag, rest = s:sub(1, 1), s:sub(2)
    if tag == "b" then return rest == "1" end
    if tag == "n" then return tonumber(rest) end
    if tag == "s" then return SvUnescape(rest) end
    return nil
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

-- Every scalar in ns.db (and every scalar one level down in a sub-table)
-- whose value differs from its default. Option keys default to the option's
-- default; core sub-tables to CORE_DEFAULTS; anything else to nil. A false
-- default is a real default, distinct from "no default".
local function DefaultFor(key)
    local opt = OptionByKey(key)
    local default
    if opt then default = opt.default end
    return default
end

local function SubDefaultFor(tableKey, key)
    local defaults = CORE_DEFAULTS[tableKey]
    local default
    if type(defaults) == "table" then default = defaults[key] end
    return default
end

local function SvSerialize()
    local parts = { SV_TAG }
    local db = ns.db
    for _, k in ipairs(SortedKeys(db)) do
        local v = db[k]
        if type(v) == "table" then
            for _, k2 in ipairs(SortedKeys(v)) do
                local v2 = v[k2]
                if type(v2) ~= "table" then
                    local enc = (v2 ~= SubDefaultFor(k, k2)) and SvEncodeValue(v2) or nil
                    if enc then parts[#parts + 1] = k .. "." .. k2 .. "=" .. enc end
                end
            end
        else
            local enc = (v ~= DefaultFor(k)) and SvEncodeValue(v) or nil
            if enc then parts[#parts + 1] = k .. "=" .. enc end
        end
    end
    return table.concat(parts, ";")
end

-- Write a payload into db. With `preserve`, keys the user has already moved
-- away from their default this session are left alone, so a late restore
-- never undoes a click that happened before the macros became readable.
local function SvApply(db, payload, preserve)
    if not payload or payload:sub(1, #SV_TAG + 1) ~= SV_TAG .. ";" and payload ~= SV_TAG then
        return 0
    end
    local n = 0
    for entry in payload:gmatch("[^;]+") do
        local k, raw = entry:match("^([%w_%.]+)=(.*)$")
        if k then
            local v = SvDecodeValue(raw)
            if v ~= nil then
                local a, b = k:match("^([%w_]+)%.([%w_]+)$")
                if a then
                    if type(db[a]) ~= "table" then db[a] = {} end
                    local keep = preserve and db[a][b] ~= nil and db[a][b] ~= SubDefaultFor(a, b)
                    if not keep then db[a][b] = v; n = n + 1 end
                else
                    local keep = preserve and db[k] ~= nil and db[k] ~= DefaultFor(k)
                    if not keep then db[k] = v; n = n + 1 end
                end
            end
        end
    end
    return n
end

local function SvMacrosAvailable()
    return type(GetMacroIndexByName) == "function" and type(CreateMacro) == "function"
       and type(EditMacro) == "function" and type(GetMacroBody) == "function"
end

-- Every MMcfgN account macro, found by walking the macro list rather than
-- asking by name (name lookups proved unreliable while the list was still
-- filling). Returns { [n] = macroIndex }, count.
local function SvFindSlices()
    local found, count = {}, 0
    local okN, account = pcall(GetNumMacros)
    account = okN and tonumber(account) or 0
    if type(GetMacroInfo) == "function" then
        for idx = 1, account do
            local okI, name = pcall(GetMacroInfo, idx)
            if okI and type(name) == "string" then
                local n = name:match("^" .. SV_MACRO_PREFIX .. "(%d+)$")
                if n then found[tonumber(n)] = idx; count = count + 1 end
            end
        end
    end
    if count == 0 then
        for n = 1, 40 do
            local okI, idx = pcall(GetMacroIndexByName, SV_MACRO_PREFIX .. n)
            if not okI or not idx or idx == 0 then break end
            found[n] = idx; count = count + 1
        end
    end
    return found, count
end

local svSlicesSeen = 0   -- slices in the last complete read

-- Concatenate the payload slices of MMcfg1..N. Returns nil if MMcfg1 is
-- absent, or if the set looks incomplete: slices must be contiguous and
-- every slice but the last must be full, since the writer cuts the payload
-- at fixed boundaries. A partial read is never applied.
local function SvReadMacros()
    if not SvMacrosAvailable() then return nil end
    local found, count = SvFindSlices()
    if count == 0 or not found[1] then return nil end
    local pieces = {}
    for n = 1, count do
        local idx = found[n]
        if not idx then return nil end
        local okB, body = pcall(GetMacroBody, idx)
        if not okB or type(body) ~= "string" then return nil end
        local nl = body:find("\n", 1, true)
        local piece = nl and body:sub(nl + 1) or ""
        if n < count and #piece < SV_CHUNK_MAX then return nil end
        pieces[n] = piece
    end
    svSlicesSeen = count
    return table.concat(pieces)
end

local function SvWriteMacros()
    local payload = SvSerialize()
    SvCvarWrite(payload)
    if not SvMacrosAvailable() then return false end
    local chunks = {}
    for i = 1, #payload, SV_CHUNK_MAX do
        chunks[#chunks + 1] = payload:sub(i, i + SV_CHUNK_MAX - 1)
    end
    if #chunks == 0 then chunks[1] = "" end

    -- A bare tag over a backup that holds real values is only ever right when
    -- the user deliberately reset things this session.
    if payload == SV_TAG and not svDirty then
        local existing = SvReadMacros()
        if existing and existing ~= SV_TAG and existing ~= "" then return true end
    end

    local maxAccount = MAX_ACCOUNT_MACROS or 120
    for i, chunk in ipairs(chunks) do
        local name = SV_MACRO_PREFIX .. i
        local body = SV_MACRO_HEAD .. chunk
        local idx = GetMacroIndexByName(name) or 0
        if idx > 0 then
            if GetMacroBody(idx) ~= body then
                EditMacro(idx, name, SV_MACRO_ICON, body)
            end
        else
            local account = GetNumMacros and GetNumMacros() or 0
            if account >= maxAccount then return false end
            CreateMacro(name, SV_MACRO_ICON, body, false)
        end
    end
    -- Drop slices no longer needed, but only ones this session has read in
    -- full: a slice that was never read may hold values the restore missed.
    if DeleteMacro then
        local found, count = SvFindSlices()
        if count <= svSlicesSeen or svDirty then
            for n = count, #chunks + 1, -1 do
                local idx = found[n]
                if idx then pcall(DeleteMacro, idx) end
            end
        end
    end
    return true
end

-- Pull the backup into the saved table. Returns true when applied. Once the
-- macro list is known to be loaded, a missing MMcfg1 is taken as "no backup".
local function SvTryRestore(db, preserve)
    if svRestored then return true end
    local payload = SvReadMacros()
    if not payload then
        if svMacrosReady then svAbsentConfirmed = true end
        return false
    end
    local n = SvApply(db, payload, preserve)
    svRestored = true
    ns.Print(("settings restored from backup (the beta client does not load saved variables yet), %d value%s."):format(n, n == 1 and "" or "s"))
    return true
end

-- Writing is allowed once the backup has been restored, or once the macro
-- list is known to be loaded and holds no backup, or when the user changed
-- something this session (their intent wins; a pending restore is merged
-- underneath first so nothing they did not touch is lost).
local function SvMayWrite()
    return svRestored or svAbsentConfirmed or svDirty
end

local function SvFlush()
    svScheduled = false
    if not svPending or not ns.db then return end
    if InCombatLockdown and InCombatLockdown() then
        -- PLAYER_REGEN_ENABLED re-schedules.
        return
    end
    if not SvMayWrite() then
        -- Leave it pending; a later restore or confirmation re-schedules.
        return
    end
    if svDirty and not svRestored and not svAbsentConfirmed then
        SvTryRestore(ns.db, true)
        if svRestored and ns.RefreshAfterRestore then ns.RefreshAfterRestore() end
    end
    svPending = false
    local ok, done = pcall(SvWriteMacros)
    if (not ok or not done) and not svWarned then
        svWarned = true
        ns.Print("Could not write the settings backup macro" .. (ok and " (macro slots full?)." or (": " .. tostring(done))))
    end
end

local function SvSchedule()
    if not ns.db then return end
    svPending = true
    if svScheduled then return end
    svScheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(SV_DEBOUNCE, SvFlush)
    else
        SvFlush()
    end
end

-- Modules and the dialog call this after the user changed ns.db. Debounced.
function ns.SaveSettings()
    svDirty = true
    SvSchedule()
end

-- Late restore: the saved table was empty at ADDON_LOADED and the macros were
-- not readable yet. Re-apply defaults and refresh what is already built.
local function SvLateRestore()
    if svRestored or svAbsentConfirmed or not ns.db then return end
    if SvTryRestore(ns.db, true) then
        ApplyDefaults(ns.db)
        -- Re-applies reinit-safe modules and refreshes what is already built.
        if ns.RefreshAfterRestore then ns.RefreshAfterRestore() end
    end
    if (svRestored or svAbsentConfirmed) and svPending and not svScheduled then SvSchedule() end
end

-------------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
pcall(loader.RegisterEvent, loader, "UPDATE_MACROS")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")

        MooseModeDB = MooseModeDB or {}
        ns.db = MooseModeDB
        svHadKeysAtLoad = next(ns.db) ~= nil
        if next(ns.db) == nil then
            -- Nothing loaded: either a fresh install or the client bug.
            -- The macro API may not answer this early; later events retry.
            local cv = SvCvarRead()
            if cv then
                local n = SvApply(ns.db, cv, false)
                svRestored = true
                ns.Print(("settings restored after reload, %d value%s."):format(n, n == 1 and "" or "s"))
            else
                SvTryRestore(ns.db, false)
            end
        else
            -- The client loaded the saved table; the backup is a mirror only.
            svRestored = true
        end
        ApplyDefaults(ns.db)

        for _, mod in ipairs(ns.modules) do
            if mod.OnInit then mod.OnInit(mod) end
        end
        for _, fn in ipairs(ns.OnInitCallbacks) do fn() end

    elseif event == "UPDATE_MACROS" then
        svMacrosReady = true
        SvLateRestore()

    elseif event == "PLAYER_LOGIN" then
        if not ns.db then return end
        if ns.dev then
            ns.Print("|cffffcc00dev build|r running from " .. tostring(ns.devPath or "the linked repo") .. " (not the CurseForge copy).")
        end
        SvLateRestore()
        -- Keep the backup current once it is safe to write it.
        if svRestored or svAbsentConfirmed then SvSchedule() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not ns.db then return end
        SvLateRestore()
        -- Retry for a while after entering the world. The macro list is only
        -- treated as loaded once GetNumMacros reports any macro at all (or
        -- UPDATE_MACROS fired); only then can a missing MMcfg1 mean "no
        -- backup". After the last try, give up and allow writes.
        if not svRestored and not svAbsentConfirmed and C_Timer and C_Timer.After then
            local tries = 0
            local function retry()
                if svRestored or svAbsentConfirmed then return end
                tries = tries + 1
                local okN, account, perChar = pcall(GetNumMacros)
                if okN and ((tonumber(account) or 0) + (tonumber(perChar) or 0)) > 0 then
                    svMacrosReady = true
                end
                if tries >= 12 then svMacrosReady = true end
                SvLateRestore()
                if not svRestored and not svAbsentConfirmed then C_Timer.After(5, retry) end
            end
            C_Timer.After(5, retry)
        end

    elseif event == "PLAYER_LOGOUT" then
        if svPending then
            svScheduled = false
            SvFlush()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if svPending and not svScheduled then SvSchedule() end
    end
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

local ICON_CENTER_X, ICON_CENTER_Y = 16.5, -15

local function MinimapButton_UpdateIconOffset(b)
    b = b or minimapButton
    if not b or not b.icon then return end
    local dx = (ns.db and ns.db.minimap.iconDX) or 0
    local dy = (ns.db and ns.db.minimap.iconDY) or 0
    b.icon:ClearAllPoints()
    b.icon:SetPoint("CENTER", b, "TOPLEFT", ICON_CENTER_X + dx, ICON_CENTER_Y + dy)
    b.background:ClearAllPoints()
    b.background:SetPoint("CENTER", b, "TOPLEFT", ICON_CENTER_X + dx, ICON_CENTER_Y + dy)
end

-- /mm icon <dx> <dy>  (or /mm icon reset) nudges the icon inside the ring.
function ns.NudgeMinimapIcon(rest)
    if not ns.db then return end
    rest = (rest or ""):lower()
    if rest == "reset" then
        ns.db.minimap.iconDX, ns.db.minimap.iconDY = 0, 0
    else
        local dx, dy = rest:match("^(-?%d+%.?%d*)%s+(-?%d+%.?%d*)$")
        if dx then
            ns.db.minimap.iconDX = tonumber(dx) or 0
            ns.db.minimap.iconDY = tonumber(dy) or 0
        elseif rest ~= "" then
            ns.Print("Usage: /mm icon <dx> <dy>  (e.g. /mm icon 0.5 -1) or /mm icon reset")
            return
        end
    end
    MinimapButton_UpdateIconOffset()
    ns.SaveSettings()
    ns.Print(("Minimap icon offset: %s, %s"):format(tostring(ns.db.minimap.iconDX), tostring(ns.db.minimap.iconDY)))
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

    -- The tracking border ring (53x53 hung from the button TOPLEFT) has its
    -- centre at about (16.5, -15) from that corner. Both the dark backing disc
    -- and the icon are anchored by CENTER to that point so they sit in the
    -- ring; /mm icon <dx> <dy> nudges them if a client renders the ring off.
    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(21, 21)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetVertexColor(0.12, 0.05, 0.18)
    b.background = background

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21)
    icon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\media\\icon.tga")
    icon:SetTexCoord(0, 1, 0, 1)
    icon:SetVertexColor(1, 1, 1)
    b.icon = icon
    MinimapButton_UpdateIconOffset(b)

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", MinimapButton_OnDragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        ns.SaveSettings()
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
    ns.SaveSettings()
end

table.insert(ns.OnInitCallbacks, function()
    if not ns.db.minimap.hide then
        CreateMinimapButton():Show()
    end
end)

-- After a late settings restore (PLAYER_LOGIN), bring the minimap button
-- in line with the restored values; the dialog part is added further down.
local function MinimapRefreshAfterRestore()
    if ns.db.minimap.hide then
        if minimapButton then minimapButton:Hide() end
    else
        local b = CreateMinimapButton()
        MinimapButton_UpdatePosition()
        MinimapButton_UpdateIconOffset(b)
        b:Show()
    end
end

-------------------------------------------------------------------------------
-- Options dialog
--
-- A fixed-size window built lazily from the module registry on first open:
--
--   title bar ...... logo, name, version, close; drag to move
--   sidebar ........ search box, one entry per group, "Other classes" switch,
--                    tips
--   content ........ group title and blurb, Expand all / Collapse all, then
--                    a scrolling list of cards, one card per module
--
-- A card header shows the module's icon, name, one-line summary and its
-- master switch, so a collapsed card is still useful. The master is the
-- module's first top-level switch when that switch has sub-options, or its
-- only control (mod.master overrides this). The chevron opens the other rows.
-- Sub-options indent under their parent with a guide line and grey out
-- while it is off. Help text (tooltips and note rows) shows in a tooltip
-- beside the window. Modules and options that name other classes are hidden
-- unless the sidebar's "Other classes" switch is on.
--
-- UI state: ns.db.ui.group (selected group), ns.db.ui.allClasses,
-- ns.db.uiExpanded[moduleKey] = true for open cards, ns.db.optionsPos.
-------------------------------------------------------------------------------

local DIALOG_W        = 800
local DIALOG_H        = 580
local DIALOG_MIN_H    = 380
local MAX_SCREEN_FRAC = 0.85
local TITLE_H         = 50
local SIDEBAR_W       = 196
local PAD             = 16
local SIDE_PAD        = 12
local SEARCH_H        = 26
local NAV_H           = 30
local CONTENT_HEAD_H  = 62
local SCROLLBAR_W     = 5
local SCROLLBAR_GAP   = 8
local CARD_GAP        = 8
local CARD_HEADER_H   = 50
local CARD_PAD        = 14
local CARD_ICON       = 28
local ROW_H           = 30
local SUB_INDENT      = 20
local SWITCH_W        = 34
local SWITCH_H        = 18
local CHOICE_H        = 20
local CHOICE_MIN_W    = 64
local BUTTON_W        = 84
local BUTTON_H        = 22
local BUTTON_GAP      = 6
local HEADING_H       = 28
local SCROLL_STEP     = 60

local CONTENT_W = DIALOG_W - SIDEBAR_W - 2 * PAD - SCROLLBAR_GAP - SCROLLBAR_W
local INNER_W   = CONTENT_W - 2 * CARD_PAD

local GROUP_ORDER = { "Vendors", "Quests", "Loot", "Professions", "Combat", "Interface" }
local GROUP_OTHER = "Other"
local GROUP_BLURB = {
    Vendors   = "What happens when a merchant window opens.",
    Quests    = "Quest givers, hand-ins and reward choices.",
    Loot      = "Looting, and what you pick up along the way.",
    Professions = "Gathering and trade skills.",
    Combat    = "Your bars, spells and pets in a fight.",
    Interface = "Bags, bars, camera and client clean-up.",
    Other     = "Everything else.",
}
local GROUP_ICON = {
    Vendors   = "Interface\\Icons\\INV_Misc_Coin_01",
    Quests    = "Interface\\Icons\\INV_Misc_Note_01",
    Loot      = "Interface\\Icons\\INV_Misc_Bag_10",
    Professions = "Interface\\Icons\\INV_Pick_02",
    Combat    = "Interface\\Icons\\Ability_DualWield",
    Interface = "Interface\\Icons\\INV_Misc_Gear_01",
}
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Gear_01"
local BETA_COLOUR  = { 1.00, 0.72, 0.20 }   -- amber BETA badge and tooltip line
local CHEVRON_TEX  = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local CIRCLE_MASK  = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SEARCH_ICON  = "Interface\\Common\\UI-Searchbox-Icon"
local CLEAR_ICON   = "Interface\\FriendsFrame\\ClearBroadcastIcon"
local LOGO_TEX     = "Interface\\AddOns\\" .. ADDON .. "\\media\\icon.tga"

-- Palette. The brand purple is #B04CFF.
local C = {
    brand     = { 0.69, 0.30, 1.00 },
    window    = { 0.047, 0.035, 0.071, 0.97 },
    titleBar  = { 0.10, 0.055, 0.155, 1 },
    sidebar   = { 0.030, 0.022, 0.047, 0.85 },
    card      = { 1, 1, 1, 0.030 },
    cardOn    = { 0.69, 0.30, 1.00, 0.045 },
    hairline  = { 1, 1, 1, 0.07 },
    edgeOn    = { 0.69, 0.30, 1.00, 0.30 },
    text      = { 0.95, 0.93, 0.97 },
    muted     = { 0.64, 0.60, 0.70 },
    faint     = { 0.43, 0.40, 0.48 },
    warn      = { 1.00, 0.62, 0.30 },
    switchOff = { 0.23, 0.20, 0.29 },
    knob      = { 0.97, 0.95, 1.00 },
}

local BASE_FONT = (GameFontHighlight and GameFontHighlight.GetFont and GameFontHighlight:GetFont())
    or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local optionsFrame
local controls    = {}   -- live controls: { option, Refresh(self, animate) }
local cards       = {}   -- one per module, in display order
local optionByKey = {}   -- option key -> option, for walking parent chains
local ui          = {}   -- frame references filled in by BuildOptionsDialog
local searchText  = ""   -- lower-cased, trimmed

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

-- Solid colour texture; no file dependency.
local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function SolidC(parent, layer, c, a)
    return Solid(parent, layer, c[1], c[2], c[3], a or c[4] or 1)
end

-- Text colour for font strings, vertex colour for textures.
local function Color(target, c, a)
    if target.SetTextColor then
        target:SetTextColor(c[1], c[2], c[3], a or c[4] or 1)
    else
        target:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
    end
end

local function Mix(a, b, t)
    return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

-- A font string at an explicit size. Single line unless the caller wraps it.
local function Text(parent, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlight")
    local path = fs:GetFont() or BASE_FONT
    fs:SetFont(path, size, "")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if color then Color(fs, color) end
    return fs
end

local function Wrap(fs, width)
    fs:SetWidth(width)
    fs:SetWordWrap(true)
    fs:SetNonSpaceWrap(false)
    fs:SetJustifyV("TOP")
end

-- 1px hairline border drawn inside a frame.
local function Border(f, c, a)
    local r, g, b, alpha = c[1], c[2], c[3], a or c[4] or 1
    local top    = Solid(f, "BORDER", r, g, b, alpha)
    local bottom = Solid(f, "BORDER", r, g, b, alpha)
    local left   = Solid(f, "BORDER", r, g, b, alpha)
    local right  = Solid(f, "BORDER", r, g, b, alpha)
    top:SetPoint("TOPLEFT");        top:SetPoint("TOPRIGHT");       top:SetHeight(1)
    bottom:SetPoint("BOTTOMLEFT");  bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1)
    left:SetPoint("TOPLEFT");       left:SetPoint("BOTTOMLEFT");    left:SetWidth(1)
    right:SetPoint("TOPRIGHT");     right:SetPoint("BOTTOMRIGHT");  right:SetWidth(1)
    f.edges = { top, bottom, left, right }
end

local function SetBorderColor(f, c, a)
    if not f.edges then return end
    for _, t in ipairs(f.edges) do t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
end

-- Round a texture with a circular mask where the client supports masks.
local function Round(tex, owner)
    if not (owner.CreateMaskTexture and tex.AddMaskTexture) then return end
    local ok = pcall(function()
        local m = owner:CreateMaskTexture()
        m:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(tex)
        tex:AddMaskTexture(m)
    end)
    return ok
end

-- Right-pointing arrow; expanded rotates it 90 degrees clockwise with an
-- 8-value tex coord, so no SetRotation is needed.
local function SetChevron(tex, expanded)
    if expanded then
        tex:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0)
    else
        tex:SetTexCoord(0, 0, 0, 1, 1, 0, 1, 1)
    end
end

local function Sound(on)
    if not (PlaySound and SOUNDKIT) then return end
    local id = on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
    if id then pcall(PlaySound, id) end
end

local function Evaluate(v, ...)
    if type(v) == "function" then
        local ok, r = pcall(v, ...)
        return ok and r
    end
    return v
end

local function Lower(s)
    return type(s) == "string" and s:lower() or ""
end

local function FirstSentence(s)
    if type(s) ~= "string" or s == "" then return nil end
    return s:match("^(.-[%.!?])%s") or s
end

local function DropFocus()
    if ui.search and ui.search:HasFocus() then ui.search:ClearFocus() end
end

-------------------------------------------------------------------------------
-- Classes and visibility
-------------------------------------------------------------------------------

local playerClass
local function PlayerClass()
    if not playerClass and UnitClass then
        local _, token = UnitClass("player")
        playerClass = token
    end
    return playerClass
end

-- nil or an empty list means every class.
local function ClassListed(list)
    if type(list) ~= "table" or #list == 0 then return true end
    local mine = PlayerClass()
    if not mine then return true end
    for _, token in ipairs(list) do
        if token == mine then return true end
    end
    return false
end

local function ClassColorCode(token)
    local c
    if C_ClassColor and C_ClassColor.GetClassColor then c = C_ClassColor.GetClassColor(token) end
    if not c and RAID_CLASS_COLORS then c = RAID_CLASS_COLORS[token] end
    if c and c.r then
        return ("|cff%02x%02x%02x"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
    end
    return "|cffcccccc"
end

local function ClassName(token)
    local n = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
    return n or (token:sub(1, 1) .. token:sub(2):lower())
end

local function ClassListText(list)
    local parts = {}
    for _, token in ipairs(list) do
        parts[#parts + 1] = ClassColorCode(token) .. ClassName(token) .. "|r"
    end
    return table.concat(parts, ", ")
end

local function ShowAllClasses()
    return ns.db and ns.db.ui and ns.db.ui.allClasses and true or false
end

-- mod.classesOverride = "<optionKey>": while that option is on, the module
-- counts as meant for every class (e.g. Swing Timer's "Show on every class").
local function ModuleForThisClass(mod)
    if ClassListed(mod.classes) then return true end
    local o = mod.classesOverride
    return type(o) == "string" and ns.db and ns.db[o] and true or false
end

local function ModuleShown(mod)
    if Evaluate(mod.hidden, mod) then return false end
    return ModuleForThisClass(mod) or ShowAllClasses()
end

local function OptionHidden(opt)
    if Evaluate(opt.hidden, opt) then return true end
    if opt.classes and not ClassListed(opt.classes) and not ShowAllClasses() then return true end
    return false
end

-- mod.available may return false, "reason" (for example a missing skill).
-- The card stays usable; it is dimmed and the reason replaces the summary.
local function ModuleAvailability(mod)
    if type(mod.available) ~= "function" then return true end
    local ok, avail, reason = pcall(mod.available, mod)
    if not ok or avail ~= false then return true end
    return false, reason
end

-------------------------------------------------------------------------------
-- Option state
-------------------------------------------------------------------------------

local function IsToggle(opt)
    return opt.key ~= nil and (opt.type == nil or opt.type == "toggle" or opt.type == "checkbox")
end

-- A sub-option (opt.parent = "<optionKey>") is greyed out and unclickable
-- while its parent is off. Parents may nest, so every ancestor has to be on.
-- A parent that no longer exists (an option a module dropped) never blocks.
local function FirstOffAncestor(opt)
    local parent, guard = opt.parent, 0
    while parent and guard < 8 do
        local p = optionByKey[parent]
        if not p then return nil end
        if not ns.db[parent] then return p end
        parent = p.parent
        guard = guard + 1
    end
    return nil
end

local function AncestorsOn(opt)
    return FirstOffAncestor(opt) == nil
end

-- Save first, then run the option action under pcall: an error inside a
-- module action must never stop the setting itself from being persisted.
local function RunOnChange(opt, value)
    if not opt.onChange then return end
    local ok, err = pcall(opt.onChange, value, opt)
    if not ok then ns.Print("error applying \"" .. tostring(opt.label) .. "\": " .. tostring(err)) end
end

local UpdateAll, Relayout   -- defined further down

local function SetOption(opt, value)
    ns.db[opt.key] = value
    ns.SaveSettings()
    RunOnChange(opt, value)
    UpdateAll(true)
    Relayout()   -- hidden() functions may depend on the new value
end

local function ToggleOption(opt)
    DropFocus()
    if not AncestorsOn(opt) then return end
    local value = not ns.db[opt.key]
    Sound(value)
    SetOption(opt, value)
end

-- Options in display order: each top-level option followed by its children
-- (recursively), so a sub-option always sits directly under its parent
-- whatever order the module listed them in. Children of unknown parents go
-- at the end at the top level. Entries: { opt, depth, root }.
local function OrderedOptions(mod)
    local ordered, placed = {}, {}
    local function add(opt, depth, root)
        ordered[#ordered + 1] = { opt = opt, depth = depth, root = root or opt }
        placed[opt] = true
        -- opt.key is nil for button and note rows; never adopt children then.
        if opt.key then
            for _, child in ipairs(mod.options) do
                if child.parent == opt.key and not placed[child] then
                    add(child, depth + 1, root or opt)
                end
            end
        end
    end
    for _, opt in ipairs(mod.options) do
        if not opt.parent then add(opt, 0) end
    end
    for _, opt in ipairs(mod.options) do
        if not placed[opt] then add(opt, 0) end
    end
    return ordered
end

-- The switch shown in the card header. See the section comment.
local function ChooseMaster(mod, ordered)
    if mod.master == false then return nil end
    if type(mod.master) == "string" then
        local o = optionByKey[mod.master]
        if o and IsToggle(o) and not o.parent then return o end
        return nil
    end
    local tops, first = 0, nil
    for _, e in ipairs(ordered) do
        if e.depth == 0 and e.opt.type ~= "note" and not e.opt.pair then
            tops = tops + 1
            first = first or e.opt
        end
    end
    if not first or not IsToggle(first) or first.parent or first.hidden or first.classes then return nil end
    if tops == 1 then return first end
    for _, e in ipairs(ordered) do
        if e.opt.parent == first.key then return first end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Tooltips, placed beside the window level with the hovered row
-------------------------------------------------------------------------------

local function TooltipBeside(owner)
    local f = optionsFrame
    local fr, fl = f and f:GetRight(), f and f:GetLeft()
    local or_, ol = owner:GetRight(), owner:GetLeft()
    local screenR = UIParent:GetRight() or 0
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    if fr and or_ and fr + 300 < screenR then
        GameTooltip:SetPoint("TOPLEFT", owner, "TOPRIGHT", fr - or_ + 8, 0)
    elseif fl and ol then
        GameTooltip:SetPoint("TOPRIGHT", owner, "TOPLEFT", -(ol - fl) - 8, 0)
    else
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    end
end

local function HideTooltip()
    GameTooltip:Hide()
end

-- A button's text: a string, or a function(opt) for text that follows state.
local function ButtonText(opt)
    local t = opt.buttonText
    if type(t) == "function" then
        local ok, v = pcall(t, opt)
        t = ok and v or nil
    end
    return t
end

local function OptionTooltip(owner, opt)
    local title = opt.label
    if not title or title == "" then title = ButtonText(opt) end
    if not opt.tooltip and not title then return end
    TooltipBeside(owner)
    GameTooltip:AddLine(title or "", 1, 1, 1)
    if opt.tooltip then GameTooltip:AddLine(opt.tooltip, C.muted[1] + 0.2, C.muted[2] + 0.2, C.muted[3] + 0.2, true) end
    if opt.classes then GameTooltip:AddLine(ClassListText(opt.classes) .. " only.", 1, 1, 1, true) end
    local blocker = FirstOffAncestor(opt)
    if blocker then
        GameTooltip:AddLine("Turn on \"" .. tostring(blocker.label) .. "\" first.", 1, 0.45, 0.45, true)
    end
    GameTooltip:Show()
end

local function CardTooltip(card)
    local mod = card.mod
    TooltipBeside(card.header)
    GameTooltip:AddLine(mod.label or mod.key, 1, 1, 1)
    if mod.beta then
        local text = type(mod.beta) == "string" and ("Beta: " .. mod.beta) or "Beta: still being tested."
        GameTooltip:AddLine(text, BETA_COLOUR[1], BETA_COLOUR[2], BETA_COLOUR[3], true)
    end
    if mod.classes and #mod.classes > 0 then
        GameTooltip:AddLine(ClassListText(mod.classes) .. " only.", 1, 1, 1, true)
    end
    local avail, reason = ModuleAvailability(mod)
    if not avail and reason then GameTooltip:AddLine(reason, C.warn[1], C.warn[2], C.warn[3], true) end
    if card.master and card.master.tooltip then
        GameTooltip:AddLine(card.master.tooltip, C.muted[1] + 0.2, C.muted[2] + 0.2, C.muted[3] + 0.2, true)
    elseif mod.summary then
        GameTooltip:AddLine(mod.summary, C.muted[1] + 0.2, C.muted[2] + 0.2, C.muted[3] + 0.2, true)
    end
    for _, note in ipairs(card.notes) do
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(note, C.muted[1], C.muted[2], C.muted[3], true)
    end
    if card.expandable and searchText == "" then
        GameTooltip:AddLine(" ")
        local open = ns.db.uiExpanded[mod.key]
        GameTooltip:AddLine(open and "Click to hide the settings." or "Click to show the settings.", C.faint[1] + 0.1, C.faint[2] + 0.1, C.faint[3] + 0.1)
    elseif not card.expandable and card.master then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to turn it " .. (ns.db[card.master.key] and "off." or "on."), C.faint[1] + 0.1, C.faint[2] + 0.1, C.faint[3] + 0.1)
    end
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Widgets
-------------------------------------------------------------------------------

-- Switch: a pill track with a round knob that slides over 0.12 s.
local function Switch_Paint(s)
    local p = s.pos or 0
    local r, g, b = Mix(C.switchOff, C.brand, p)
    if not s.enabled then
        r, g, b = Mix({ r, g, b }, C.window, 0.6)
    elseif s.hover then
        r, g, b = math.min(1, r + 0.07), math.min(1, g + 0.07), math.min(1, b + 0.07)
    end
    for _, t in ipairs(s.track) do t:SetColorTexture(r, g, b, 1) end
    local k = s.enabled and 1 or 0.45
    s.knob:SetColorTexture(C.knob[1] * k, C.knob[2] * k, C.knob[3] * k, 1)
    s.knob:ClearAllPoints()
    s.knob:SetPoint("LEFT", s, "LEFT", 3 + p * (SWITCH_W - SWITCH_H), 0)
end

local function Switch_OnUpdate(s, elapsed)
    local step = elapsed / 0.12
    if s.pos < s.target then
        s.pos = math.min(s.target, s.pos + step)
    else
        s.pos = math.max(s.target, s.pos - step)
    end
    Switch_Paint(s)
    if s.pos == s.target then s:SetScript("OnUpdate", nil) end
end

local function Switch_Set(s, on, enabled, animate)
    s.target = on and 1 or 0
    s.enabled = enabled and true or false
    if animate and s:IsVisible() then
        s:SetScript("OnUpdate", Switch_OnUpdate)
    else
        s.pos = s.target
        s:SetScript("OnUpdate", nil)
    end
    Switch_Paint(s)
end

local function CreateSwitch(parent)
    local s = CreateFrame("Button", nil, parent)
    s:SetSize(SWITCH_W, SWITCH_H)
    s:SetHitRectInsets(-6, -6, -6, -6)
    local capL = s:CreateTexture(nil, "ARTWORK")
    capL:SetSize(SWITCH_H, SWITCH_H)
    capL:SetPoint("LEFT")
    Round(capL, s)
    local capR = s:CreateTexture(nil, "ARTWORK")
    capR:SetSize(SWITCH_H, SWITCH_H)
    capR:SetPoint("RIGHT")
    Round(capR, s)
    local mid = s:CreateTexture(nil, "ARTWORK")
    mid:SetPoint("TOPLEFT", SWITCH_H / 2, 0)
    mid:SetPoint("BOTTOMRIGHT", -SWITCH_H / 2, 0)
    s.track = { capL, mid, capR }
    s.knob = s:CreateTexture(nil, "OVERLAY")
    s.knob:SetSize(SWITCH_H - 6, SWITCH_H - 6)
    Round(s.knob, s)
    s.pos, s.target, s.enabled = 0, 0, true
    Switch_Paint(s)
    return s
end

-- Flat action button in the brand colour.
local function FlatButton_Paint(b)
    local a = (not b:IsEnabled()) and 0.10 or (b.down and 0.55) or (b.hover and 0.42) or 0.26
    b.bg:SetColorTexture(C.brand[1], C.brand[2], C.brand[3], a)
    SetBorderColor(b, C.brand, b:IsEnabled() and 0.75 or 0.25)
    Color(b.label, b:IsEnabled() and C.text or C.faint)
end

local function CreateFlatButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or BUTTON_W, height or BUTTON_H)
    b.bg = Solid(b, "BACKGROUND", 0, 0, 0, 0)
    b.bg:SetAllPoints()
    Border(b, C.brand, 0.75)
    b.label = Text(b, 11, C.text)
    b.label:SetPoint("CENTER", 0, 0)
    b.label:SetJustifyH("CENTER")
    b.label:SetText(text or "")
    b:HookScript("OnEnter", function(self) self.hover = true; FlatButton_Paint(self) end)
    b:HookScript("OnLeave", function(self) self.hover = false; self.down = false; FlatButton_Paint(self) end)
    b:HookScript("OnMouseDown", function(self) self.down = true; FlatButton_Paint(self) end)
    b:HookScript("OnMouseUp", function(self) self.down = false; FlatButton_Paint(self) end)
    b:HookScript("OnEnable", FlatButton_Paint)
    b:HookScript("OnDisable", FlatButton_Paint)
    FlatButton_Paint(b)
    return b
end

-- Plain text link ("Expand all").
local function CreateTextButton(parent, text)
    local b = CreateFrame("Button", nil, parent)
    b.label = Text(b, 11, C.muted)
    b.label:SetPoint("CENTER")
    b.label:SetText(text)
    b:SetSize(math.ceil((b.label:GetStringWidth() or 40) + 8), 18)
    b:SetScript("OnEnter", function(self) Color(self.label, C.brand) end)
    b:SetScript("OnLeave", function(self) Color(self.label, C.muted) end)
    return b
end

-- Row hover highlight across the whole card width, plus a guide line per
-- nesting level so sub-options read as a tree.
local function RowChrome(row, depth)
    local indent = depth * SUB_INDENT
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetColorTexture(1, 1, 1, 0.035)
    hl:SetPoint("TOPLEFT", row, "TOPLEFT", -(CARD_PAD + indent) + 1, 0)
    hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", CARD_PAD - 1, 0)
    hl:Hide()
    row.hl = hl
    for d = 1, depth do
        local g = Solid(row, "ARTWORK", C.brand[1], C.brand[2], C.brand[3], 0.28)
        local x = -indent + (d - 1) * SUB_INDENT + 6
        g:SetWidth(1)
        g:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
        g:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
    end
end

local function RowHover(row, opt)
    return function()
        row.hl:Show()
        OptionTooltip(row, opt)
    end
end

local function RowLeave(row)
    return function()
        row.hl:Hide()
        HideTooltip()
    end
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------

local function NewToggleControl(opt, switch, label)
    local c = { option = opt, switch = switch, label = label }
    function c:Refresh(animate)
        local enabled = AncestorsOn(opt)
        Switch_Set(switch, ns.db[opt.key] and true or false, enabled, animate)
        if self.label then Color(self.label, enabled and C.text or C.faint) end
    end
    controls[#controls + 1] = c
    return c
end

local function BuildToggleRow(body, opt, depth)
    local w = INNER_W - depth * SUB_INDENT
    local row = CreateFrame("Button", nil, body)
    row:SetWidth(w)
    row:RegisterForClicks("LeftButtonUp")

    local label = Text(row, 12, C.text)
    Wrap(label, w - SWITCH_W - 16)
    label:SetText(opt.label or "")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row:SetHeight(math.max(ROW_H, (label:GetStringHeight() or 12) + 12))

    local sw = CreateSwitch(row)
    sw:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    RowChrome(row, depth)
    NewToggleControl(opt, sw, label)

    local enter, leave = RowHover(row, opt), RowLeave(row)
    row:SetScript("OnClick", function() ToggleOption(opt) end)
    row:SetScript("OnEnter", enter)
    row:SetScript("OnLeave", leave)
    sw:SetScript("OnClick", function() ToggleOption(opt) end)
    sw:SetScript("OnEnter", function(self) self.hover = true; Switch_Paint(self); enter() end)
    sw:SetScript("OnLeave", function(self) self.hover = false; Switch_Paint(self); leave() end)
    return row
end

-- Segmented switch: one segment per value, the chosen one filled purple.
local function Choice_Paint(c)
    local current = ns.db[c.option.key]
    local on = c.enabled
    for _, b in ipairs(c.segments) do
        local selected = (b.value == current)
        if selected then
            b.bg:SetColorTexture(C.brand[1], C.brand[2], C.brand[3], on and 0.85 or 0.30)
            Color(b.text, on and C.text or C.faint)
        else
            b.bg:SetColorTexture(1, 1, 1, (on and b.hover) and 0.08 or 0)
            Color(b.text, on and C.muted or C.faint)
        end
    end
    SetBorderColor(c.frame, C.brand, on and 0.55 or 0.2)
    if c.label then Color(c.label, on and C.text or C.faint) end
end

local function BuildChoiceRow(body, opt, depth)
    local w = INNER_W - depth * SUB_INDENT
    local row = CreateFrame("Frame", nil, body)
    row:SetWidth(w)
    row:EnableMouse(true)

    local seg = CreateFrame("Frame", nil, row)
    seg:SetHeight(CHOICE_H)
    seg:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    Border(seg, C.brand, 0.55)

    local c = { option = opt, segments = {}, enabled = true, frame = seg }
    local total, prev = 0, nil
    for i, v in ipairs(opt.values or {}) do
        local b = CreateFrame("Button", nil, seg)
        b:SetHeight(CHOICE_H - 2)
        b.value = v.value
        b.bg = Solid(b, "BACKGROUND", 0, 0, 0, 0)
        b.bg:SetAllPoints()
        b.text = Text(b, 11, C.muted)
        b.text:SetPoint("CENTER")
        b.text:SetJustifyH("CENTER")
        b.text:SetText(v.text or tostring(v.value))
        local bw = math.max(CHOICE_MIN_W, math.ceil((b.text:GetStringWidth() or 0) + 18))
        b:SetWidth(bw)
        if prev then
            local line = Solid(seg, "ARTWORK", C.brand[1], C.brand[2], C.brand[3], 0.35)
            line:SetSize(1, CHOICE_H - 2)
            line:SetPoint("LEFT", prev, "RIGHT", 0, 0)
            b:SetPoint("LEFT", prev, "RIGHT", 1, 0)
            total = total + 1
        else
            b:SetPoint("LEFT", seg, "LEFT", 1, 0)
        end
        total = total + bw
        prev = b
        b:SetScript("OnClick", function(self)
            DropFocus()
            if not c.enabled or ns.db[opt.key] == self.value then return end
            Sound(true)
            SetOption(opt, self.value)
        end)
        b:SetScript("OnEnter", function(self)
            self.hover = true
            Choice_Paint(c)
            row.hl:Show()
            OptionTooltip(row, opt)
        end)
        b:SetScript("OnLeave", function(self)
            self.hover = false
            Choice_Paint(c)
            row.hl:Hide()
            HideTooltip()
        end)
        c.segments[i] = b
    end
    seg:SetWidth(math.max(1, total + 2))

    local label = Text(row, 12, C.text)
    Wrap(label, math.max(40, w - total - 18))
    label:SetText(opt.label or "")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    c.label = label
    row:SetHeight(math.max(ROW_H, (label:GetStringHeight() or 12) + 12))

    RowChrome(row, depth)
    row:SetScript("OnEnter", RowHover(row, opt))
    row:SetScript("OnLeave", RowLeave(row))

    function c:Refresh()
        self.enabled = AncestorsOn(opt)
        for _, b in ipairs(self.segments) do
            if self.enabled then b:Enable() else b:Disable() end
        end
        Choice_Paint(self)
    end
    controls[#controls + 1] = c
    return row
end

-- Adds one action button to a button row, right-aligned: the first button
-- hugs the row's right edge, each further one sits to the left of the last.
local function AddRowButton(row, opt)
    local b = CreateFlatButton(row, ButtonText(opt) or opt.label or "Go")
    if row.lastButton then
        b:SetPoint("RIGHT", row.lastButton, "LEFT", -BUTTON_GAP, 0)
    else
        b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    end
    b:SetScript("OnClick", function()
        DropFocus()
        if opt.onClick then
            local ok, err = pcall(opt.onClick, opt)
            if not ok then ns.Print("error running \"" .. tostring(ButtonText(opt) or opt.label) .. "\": " .. tostring(err)) end
        end
        UpdateAll(true)
    end)
    b:HookScript("OnEnter", function() row.hl:Show(); OptionTooltip(row, opt) end)
    b:HookScript("OnLeave", function() row.hl:Hide(); HideTooltip() end)
    b:SetMotionScriptsWhileDisabled(true)
    row.lastButton = b
    row.buttonCount = (row.buttonCount or 0) + 1
    if opt.parent or type(opt.buttonText) == "function" then
        local c = { option = opt }
        function c:Refresh()
            if opt.parent then b:SetEnabled(AncestorsOn(opt)) end
            if type(opt.buttonText) == "function" then b.label:SetText(ButtonText(opt) or "") end
        end
        controls[#controls + 1] = c
    end
    -- Shrink the label so it never runs under the buttons.
    if row.label then
        local avail = row:GetWidth() - row.buttonCount * (BUTTON_W + BUTTON_GAP) - 8
        row.label:SetWidth(math.max(40, avail))
        row:SetHeight(math.max(ROW_H, (row.label:GetStringHeight() or 12) + 12))
    end
    return b
end

local function BuildButtonRow(body, opt, depth)
    local w = INNER_W - depth * SUB_INDENT
    local row = CreateFrame("Frame", nil, body)
    row:SetWidth(w)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)
    if opt.label and opt.label ~= "" then
        local label = Text(row, 12, C.text)
        Wrap(label, w - BUTTON_W - 8)
        label:SetText(opt.label)
        label:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.label = label
    end
    RowChrome(row, depth)
    row:SetScript("OnEnter", RowHover(row, opt))
    row:SetScript("OnLeave", RowLeave(row))
    AddRowButton(row, opt)
    return row
end

-------------------------------------------------------------------------------
-- Cards
-------------------------------------------------------------------------------

local function SearchBlob(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if type(s) == "string" then parts[#parts + 1] = s:lower() end
    end
    return table.concat(parts, "\n")
end

local function OptionSearchBlob(opt)
    local blob = SearchBlob(opt.label, opt.tooltip, ButtonText(opt))
    for _, v in ipairs(opt.values or {}) do blob = blob .. "\n" .. Lower(v.text) end
    return blob
end

local function UpdateCardHeader(card)
    local mod = card.mod
    local on = true
    if card.master then on = ns.db[card.master.key] and true or false end
    local avail, reason = ModuleAvailability(mod)

    Color(card.title, on and C.text or C.muted)
    card.icon:SetDesaturated(not on)
    card.icon:SetAlpha(on and 1 or 0.55)
    if not avail and reason then
        card.summary:SetText(reason)
        Color(card.summary, C.warn)
    else
        card.summary:SetText(card.summaryText or "")
        Color(card.summary, on and C.muted or C.faint)
    end

    if card.status then
        local n, total = 0, 0
        for _, r in ipairs(card.rows) do
            if r.depth == 0 and IsToggle(r.opt) and not OptionHidden(r.opt) then
                total = total + 1
                if ns.db[r.opt.key] then n = n + 1 end
            end
        end
        card.status:SetText(total > 0 and ("%d of %d on"):format(n, total) or "")
        on = n > 0
    end

    local active = on and avail
    card.bg:SetColorTexture(unpack(active and C.cardOn or C.card))
    SetBorderColor(card, active and C.edgeOn or C.hairline)
    card.accent:SetShown(active and true or false)
    card:SetAlpha(ModuleForThisClass(mod) and 1 or 0.6)
end

local function BuildCard(parent, mod, groupName)
    local ordered = OrderedOptions(mod)
    local master = ChooseMaster(mod, ordered)

    local card = CreateFrame("Frame", nil, parent)
    card:SetWidth(CONTENT_W)
    card:SetHeight(CARD_HEADER_H)
    card.mod, card.master, card.groupName = mod, master, groupName
    card.rows, card.notes = {}, {}
    card.bg = SolidC(card, "BACKGROUND", C.card)
    card.bg:SetAllPoints()
    Border(card, C.hairline)
    card.accent = SolidC(card, "ARTWORK", C.brand)
    card.accent:SetWidth(2)
    card.accent:SetPoint("TOPLEFT", 0, 0)
    card.accent:SetPoint("BOTTOMLEFT", 0, 0)

    -- Header
    local h = CreateFrame("Button", nil, card)
    h:SetPoint("TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", 0, 0)
    h:SetHeight(CARD_HEADER_H)
    h:RegisterForClicks("LeftButtonUp")
    h.hl = Solid(h, "BACKGROUND", 1, 1, 1, 0.03)
    h.hl:SetAllPoints()
    h.hl:Hide()
    card.header = h

    local chev = h:CreateTexture(nil, "ARTWORK")
    chev:SetTexture(CHEVRON_TEX)
    chev:SetSize(12, 12)
    chev:SetPoint("LEFT", h, "LEFT", 12, 0)
    chev:SetVertexColor(C.muted[1], C.muted[2], C.muted[3])
    SetChevron(chev, false)
    card.chevron = chev

    local iconBack = Solid(h, "ARTWORK", 0, 0, 0, 0.7)
    iconBack:SetSize(CARD_ICON + 2, CARD_ICON + 2)
    iconBack:SetPoint("LEFT", h, "LEFT", 32, 0)
    local icon = h:CreateTexture(nil, "ARTWORK", nil, 1)
    icon:SetSize(CARD_ICON, CARD_ICON)
    icon:SetPoint("CENTER", iconBack, "CENTER")
    icon:SetTexture(mod.icon or GROUP_ICON[groupName] or DEFAULT_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.icon = icon

    local textLeft = 32 + CARD_ICON + 2 + 10
    local rightArea = SWITCH_W + 2 * CARD_PAD

    local title = Text(h, 13, C.text)
    title:SetPoint("TOPLEFT", h, "TOPLEFT", textLeft, -10)
    title:SetText(mod.label or mod.key)
    card.title = title

    if mod.classes and #mod.classes > 0 then
        local tag = Text(h, 10, C.text)
        tag:SetPoint("LEFT", title, "RIGHT", 8, 0)
        tag:SetText(ClassListText(mod.classes))
        card.tag = tag
    end

    if mod.beta then
        local badge = Text(h, 10, BETA_COLOUR)
        badge:SetPoint("LEFT", card.tag or title, "RIGHT", 8, 0)
        badge:SetText("BETA")
        card.beta = badge
    end

    local summary = Text(h, 11, C.muted)
    summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    summary:SetWidth(CONTENT_W - textLeft - rightArea)
    card.summary = summary

    if master then
        local sw = CreateSwitch(h)
        sw:SetPoint("RIGHT", h, "RIGHT", -CARD_PAD, 0)
        sw:SetFrameLevel(h:GetFrameLevel() + 2)
        NewToggleControl(master, sw, nil)
        sw:SetScript("OnClick", function() ToggleOption(master) end)
        sw:SetScript("OnEnter", function(self)
            self.hover = true; Switch_Paint(self); h.hl:Show(); CardTooltip(card)
        end)
        sw:SetScript("OnLeave", function(self)
            self.hover = false; Switch_Paint(self); h.hl:Hide(); HideTooltip()
        end)
        card.switch = sw
    else
        local status = Text(h, 11, C.faint)
        status:SetPoint("RIGHT", h, "RIGHT", -CARD_PAD, 0)
        status:SetJustifyH("RIGHT")
        card.status = status
    end

    -- Body
    local body = CreateFrame("Frame", nil, card)
    body:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, 0)
    body:SetWidth(CONTENT_W)
    body:SetHeight(1)
    local sep = SolidC(body, "ARTWORK", C.hairline)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", CARD_PAD, 0)
    sep:SetPoint("TOPRIGHT", -CARD_PAD, 0)
    body:Hide()
    card.body = body

    local rowByKey, lastButtonRow, lastEntry = {}, nil, nil
    for _, e in ipairs(ordered) do
        local opt = e.opt
        if opt == master then
            lastButtonRow = nil
        elseif opt.type == "note" then
            if opt.text and opt.text ~= "" then card.notes[#card.notes + 1] = opt.text end
        elseif opt.type == "button" and opt.pair and lastButtonRow then
            -- Second action on the same row, to the left of the first.
            AddRowButton(lastButtonRow, opt)
            lastEntry.search = lastEntry.search .. "\n" .. OptionSearchBlob(opt)
        else
            local depth = e.depth
            if master and e.root == master and depth > 0 then depth = depth - 1 end
            local frame
            if opt.type == "button" then
                frame = BuildButtonRow(body, opt, depth)
            elseif opt.type == "choice" then
                frame = BuildChoiceRow(body, opt, depth)
            else
                frame = BuildToggleRow(body, opt, depth)
            end
            frame:Hide()
            local entry = { frame = frame, opt = opt, depth = depth, search = OptionSearchBlob(opt) }
            -- Rows for the option's ancestors inside this card, for search
            -- context and for hiding a subtree whose parent is hidden.
            entry.ancestors = {}
            local p, guard = opt.parent, 0
            while p and guard < 8 do
                if rowByKey[p] then entry.ancestors[#entry.ancestors + 1] = rowByKey[p] end
                local po = optionByKey[p]
                p = po and po.parent or nil
                guard = guard + 1
            end
            if opt.key then rowByKey[opt.key] = entry end
            card.rows[#card.rows + 1] = entry
            lastEntry = entry
            lastButtonRow = (opt.type == "button") and frame or nil
        end
    end

    card.summaryText = mod.summary or FirstSentence(master and master.tooltip)
        or FirstSentence(ordered[1] and ordered[1].opt.tooltip) or ""
    card.search = SearchBlob(mod.label, mod.summary, card.summaryText,
        master and master.label, master and master.tooltip, table.concat(card.notes, "\n"))

    h:SetScript("OnEnter", function() h.hl:Show(); Color(chev, C.text); CardTooltip(card) end)
    h:SetScript("OnLeave", function() h.hl:Hide(); chev:SetVertexColor(C.muted[1], C.muted[2], C.muted[3]); HideTooltip() end)
    h:SetScript("OnClick", function()
        DropFocus()
        if card.expandable then
            if searchText ~= "" then return end
            local open = not ns.db.uiExpanded[mod.key]
            ns.db.uiExpanded[mod.key] = open or nil
            ns.SaveSettings()
            Sound(open)
            Relayout()
            if h:IsMouseOver() then CardTooltip(card) end
        elseif master then
            ToggleOption(master)
            if h:IsMouseOver() then CardTooltip(card) end
        end
    end)

    UpdateCardHeader(card)
    return card
end

local function RowHidden(r)
    if OptionHidden(r.opt) then return true end
    for _, a in ipairs(r.ancestors) do
        if OptionHidden(a.opt) then return true end
    end
    return false
end

-- Positions a card's rows. rowsShown = nil shows every row that is not
-- hidden; a set limits it to those rows (search).
local function LayoutCardBody(card, expanded, rowsShown)
    local anyRow = false
    for _, r in ipairs(card.rows) do
        if not RowHidden(r) then anyRow = true break end
    end
    card.expandable = anyRow
    card.chevron:SetShown(anyRow)
    SetChevron(card.chevron, expanded and anyRow)

    local by, shown = -6, false
    for _, r in ipairs(card.rows) do
        local show = expanded and not RowHidden(r) and (rowsShown == nil or rowsShown[r])
        if show then
            r.frame:ClearAllPoints()
            r.frame:SetPoint("TOPLEFT", card.body, "TOPLEFT", CARD_PAD + r.depth * SUB_INDENT, by)
            r.frame:Show()
            by = by - r.frame:GetHeight()
            shown = true
        else
            r.frame:Hide()
        end
    end
    if shown then
        card.body:SetHeight(-by + 6)
        card.body:Show()
        card:SetHeight(CARD_HEADER_H + card.body:GetHeight())
    else
        card.body:Hide()
        card:SetHeight(CARD_HEADER_H)
    end
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

-- Modules with options, bucketed by group in display order: the fixed
-- GROUP_ORDER first, then any group a module named that is not in it, then
-- "Other" for modules that named none.
local function GroupedModules()
    local byName, names = {}, {}
    local function bucket(name)
        if not byName[name] then
            byName[name] = {}
            names[#names + 1] = name
        end
        return byName[name]
    end
    for _, name in ipairs(GROUP_ORDER) do bucket(name) end
    local other = {}
    for _, mod in ipairs(ns.modules) do
        if #mod.options > 0 then
            if mod.group then
                table.insert(bucket(mod.group), mod)
            else
                other[#other + 1] = mod
            end
        end
    end
    if #other > 0 then
        local b = bucket(GROUP_OTHER)
        for _, mod in ipairs(other) do b[#b + 1] = mod end
    end
    local groups = {}
    for _, name in ipairs(names) do
        if #byName[name] > 0 then groups[#groups + 1] = { name = name, mods = byName[name] } end
    end
    return groups
end

local function GroupExists(name)
    for _, b in ipairs(ui.nav or {}) do
        if b.group == name then return true end
    end
    return false
end

local function SelectedGroup()
    local g = ns.db.ui.group
    if g and GroupExists(g) then return g end
    return ui.nav and ui.nav[1] and ui.nav[1].group or nil
end

-- Anything for another class, so the "Other classes" switch has a purpose.
local function AnyOtherClassContent()
    for _, mod in ipairs(ns.modules) do
        if not ModuleForThisClass(mod) then return true end
        for _, opt in ipairs(mod.options) do
            if opt.classes and not ClassListed(opt.classes) then return true end
        end
    end
    return false
end

function Relayout()
    if not optionsFrame then return end
    local q = searchText
    local searching = q ~= ""
    local selected = SelectedGroup()
    local y = 0
    local shown, matches, lastGroup = 0, {}, nil
    local shownPerGroup = {}

    for _, hd in pairs(ui.headings) do hd:Hide() end

    for _, card in ipairs(cards) do
        local mod = card.mod
        local visible = ModuleShown(mod)
        if visible then shownPerGroup[card.groupName] = (shownPerGroup[card.groupName] or 0) + 1 end
        local rowsShown, expanded
        if visible and searching then
            if not card.search:find(q, 1, true) then
                rowsShown = {}
                local any = false
                for _, r in ipairs(card.rows) do
                    if not RowHidden(r) and r.search:find(q, 1, true) then
                        any = true
                        rowsShown[r] = true
                        for _, a in ipairs(r.ancestors) do rowsShown[a] = true end
                    end
                end
                visible = any
            end
            expanded = true
        elseif visible then
            visible = (card.groupName == selected)
            expanded = ns.db.uiExpanded[mod.key] and true or false
        end

        if visible then
            if searching then
                matches[card.groupName] = (matches[card.groupName] or 0) + 1
                if card.groupName ~= lastGroup then
                    local hd = ui.headings[card.groupName]
                    if hd then
                        hd:ClearAllPoints()
                        hd:SetPoint("TOPLEFT", ui.child, "TOPLEFT", 2, y - (lastGroup and 6 or 0))
                        hd:Show()
                        y = y - HEADING_H - (lastGroup and 6 or 0)
                    end
                    lastGroup = card.groupName
                end
            end
            LayoutCardBody(card, expanded, rowsShown)
            UpdateCardHeader(card)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", ui.child, "TOPLEFT", 0, y)
            card:Show()
            y = y - card:GetHeight() - CARD_GAP
            shown = shown + 1
        else
            card:Hide()
        end
    end
    ui.child:SetHeight(math.max(1, -y))

    -- Empty state.
    if shown == 0 then
        if searching then
            ui.empty:SetText(("Nothing matches \"%s\"."):format(ui.search:GetText() or ""))
        elseif AnyOtherClassContent() and not ShowAllClasses() then
            ui.empty:SetText("Nothing here for your class.\nTurn on Other classes in the sidebar to set up your alts.")
        else
            ui.empty:SetText("Nothing to set up here.")
        end
        ui.empty:Show()
    else
        ui.empty:Hide()
    end

    -- Content heading.
    if searching then
        ui.groupTitle:SetText("Search")
        ui.groupBlurb:SetText(shown == 1 and "1 feature matches." or (shown .. " features match."))
    else
        ui.groupTitle:SetText(selected or "")
        ui.groupBlurb:SetText(GROUP_BLURB[selected or ""] or "")
    end
    local anyExpandable = false
    if not searching then
        for _, card in ipairs(cards) do
            if card:IsShown() and card.expandable then anyExpandable = true break end
        end
    end
    ui.expandAll:SetShown(anyExpandable)
    ui.collapseAll:SetShown(anyExpandable)

    -- Sidebar.
    for _, b in ipairs(ui.nav) do
        local sel = (not searching) and b.group == selected
        b.bg:SetShown(sel)
        b.accent:SetShown(sel)
        local n = matches[b.group] or 0
        if searching then
            Color(b.label, n > 0 and C.text or C.faint)
            b.count:SetText(n > 0 and tostring(n) or "")
        else
            Color(b.label, sel and C.text or ((shownPerGroup[b.group] or 0) > 0 and C.muted or C.faint))
            b.count:SetText("")
        end
    end
    if ui.classRow then
        ui.classRow:SetShown(AnyOtherClassContent() or ShowAllClasses())
        ui.classControl:Refresh(false)
    end
    if ui.scroll then ui.scroll.UpdateThumb() end
end

function UpdateAll(animate)
    for _, c in ipairs(controls) do c:Refresh(animate) end
    for _, card in ipairs(cards) do UpdateCardHeader(card) end
end

local function SelectGroup(name)
    DropFocus()
    ns.db.ui.group = name
    ns.SaveSettings()
    if ui.search:GetText() ~= "" then
        ui.search:SetText("")   -- OnTextChanged relayouts
    else
        Relayout()
    end
    ui.scroll.ScrollTo(0)
end

local function SetAllExpanded(open)
    for _, card in ipairs(cards) do
        if card:IsShown() and card.expandable then
            ns.db.uiExpanded[card.mod.key] = open or nil
        end
    end
    ns.SaveSettings()
    Sound(open)
    Relayout()
end

-------------------------------------------------------------------------------
-- Scroll area: plain ScrollFrame, slim draggable thumb, smooth wheel
-------------------------------------------------------------------------------

local function CreateScrollArea(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetSize(width, height)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, 1)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(SCROLLBAR_W)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", SCROLLBAR_GAP, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", SCROLLBAR_GAP, 0)
    local track = Solid(bar, "BACKGROUND", 1, 1, 1, 0.05)
    track:SetAllPoints()

    local thumb = CreateFrame("Button", nil, bar)
    thumb:SetWidth(SCROLLBAR_W)
    thumb:SetHitRectInsets(-4, -4, 0, 0)
    thumb.tex = Solid(thumb, "ARTWORK", C.brand[1], C.brand[2], C.brand[3], 0.5)
    thumb.tex:SetAllPoints()

    local function Range()
        return math.max(0, scroll:GetVerticalScrollRange() or 0)
    end

    local function UpdateThumb()
        local range, view = Range(), scroll:GetHeight()
        if range < 1 then bar:Hide() return end
        bar:Show()
        local th = math.max(24, view * view / (view + range))
        local off = (view - th) * (scroll:GetVerticalScroll() / range)
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", bar, "TOP", 0, -off)
    end

    local function ScrollTo(v)
        v = math.max(0, math.min(Range(), v or 0))
        scroll:SetVerticalScroll(v)
    end

    local target
    local function Smooth(self, elapsed)
        if not target then self:SetScript("OnUpdate", nil) return end
        local cur = self:GetVerticalScroll()
        local d = target - cur
        if math.abs(d) < 0.5 then
            ScrollTo(target)
            target = nil
            self:SetScript("OnUpdate", nil)
            return
        end
        ScrollTo(cur + d * math.min(1, elapsed * 16))
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        target = math.max(0, math.min(Range(), (target or self:GetVerticalScroll()) - delta * SCROLL_STEP))
        self:SetScript("OnUpdate", Smooth)
    end)
    scroll:SetScript("OnVerticalScroll", UpdateThumb)
    scroll:SetScript("OnScrollRangeChanged", function(self)
        ScrollTo(self:GetVerticalScroll())
        UpdateThumb()
    end)

    local function StopDrag(self)
        self:SetScript("OnUpdate", nil)
        self.dragging = false
    end
    thumb:SetScript("OnEnter", function(self) self.tex:SetColorTexture(C.brand[1], C.brand[2], C.brand[3], 0.9) end)
    thumb:SetScript("OnLeave", function(self)
        if not self.dragging then self.tex:SetColorTexture(C.brand[1], C.brand[2], C.brand[3], 0.5) end
    end)
    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        target = nil
        scroll:SetScript("OnUpdate", nil)
        local _, cy = GetCursorPosition()
        self.dragY = cy / self:GetEffectiveScale()
        self.dragStart = scroll:GetVerticalScroll()
        self.dragging = true
        self:SetScript("OnUpdate", function(s)
            local _, y = GetCursorPosition()
            y = y / s:GetEffectiveScale()
            local travel = scroll:GetHeight() - s:GetHeight()
            if travel <= 0 then return end
            ScrollTo(s.dragStart + (s.dragY - y) * Range() / travel)
        end)
    end)
    thumb:SetScript("OnMouseUp", function(self)
        StopDrag(self)
        if not self:IsMouseOver() then self.tex:SetColorTexture(C.brand[1], C.brand[2], C.brand[3], 0.5) end
    end)
    thumb:SetScript("OnHide", StopDrag)

    scroll.ScrollTo = ScrollTo
    scroll.UpdateThumb = UpdateThumb
    return scroll, child
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

-- Close button. Parented to the title bar and lifted well above it in frame
-- level so the bar's drag region can never swallow the click, with a hit
-- rect a few pixels larger than the artwork so the X is easy to land on.
local function CreateCloseButton(titleBar, dialog)
    local b = CreateFrame("Button", nil, titleBar)
    b:SetSize(28, 28)
    b:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    b:SetHitRectInsets(-6, -6, -6, -6)
    b:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    local hl = b:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 0.45, 0.45) end
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function() dialog:Hide() end)
    return b
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

local function BuildTitleBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetHeight(TITLE_H)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() DropFocus(); f:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        -- Remember where it was left, as an offset from the screen centre.
        local cx, cy = f:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux then
            ns.db.optionsPos.x = math.floor(cx - ux + 0.5)
            ns.db.optionsPos.y = math.floor(cy - uy + 0.5)
            ns.SaveSettings()
        end
    end)

    local bg = SolidC(bar, "BACKGROUND", C.titleBar)
    bg:SetAllPoints()
    local line = Solid(bar, "ARTWORK", C.brand[1], C.brand[2], C.brand[3], 0.45)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")

    local logo = bar:CreateTexture(nil, "ARTWORK")
    logo:SetSize(26, 26)
    logo:SetPoint("LEFT", bar, "LEFT", PAD, 0)
    logo:SetTexture(LOGO_TEX)

    local name = Text(bar, 17, C.brand)
    name:SetPoint("LEFT", logo, "RIGHT", 10, 0)
    name:SetText("MooseMode")

    local version = Text(bar, 10, C.muted)
    version:SetPoint("LEFT", name, "RIGHT", 10, -1)
    version:SetText(AddonVersion())

    if ns.dev then
        local pill = CreateFrame("Frame", nil, bar)
        pill:SetPoint("LEFT", version, "RIGHT", 8, 0)
        local t = Text(pill, 9, { 1, 0.82, 0.2 })
        t:SetPoint("CENTER")
        t:SetText("DEV")
        pill:SetSize(math.ceil((t:GetStringWidth() or 20) + 10), 14)
        local pbg = Solid(pill, "BACKGROUND", 1, 0.82, 0.2, 0.12)
        pbg:SetAllPoints()
        Border(pill, { 1, 0.82, 0.2 }, 0.5)
    end

    local close = CreateCloseButton(bar, f)
    close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)

    local hint = Text(bar, 11, C.faint)
    hint:SetPoint("RIGHT", close, "LEFT", -10, 0)
    hint:SetJustifyH("RIGHT")
    hint:SetText("/mm  or  /moose")
    return bar
end

local function BuildSearchBox(parent)
    local sb = CreateFrame("EditBox", nil, parent)
    sb:SetSize(SIDEBAR_W - 2 * SIDE_PAD, SEARCH_H)
    sb:SetAutoFocus(false)
    sb:EnableMouse(true)
    sb:SetMaxLetters(40)
    sb:SetFontObject(GameFontHighlight)
    pcall(sb.SetFont, sb, (GameFontHighlight:GetFont()) or BASE_FONT, 12, "")
    sb:SetTextColor(C.text[1], C.text[2], C.text[3])
    sb:SetTextInsets(24, 22, 0, 0)
    local bg = Solid(sb, "BACKGROUND", 0, 0, 0, 0.35)
    bg:SetAllPoints()
    Border(sb, C.hairline, 0.12)

    local icon = sb:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(SEARCH_ICON)
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", 6, -1)
    icon:SetVertexColor(C.muted[1], C.muted[2], C.muted[3])

    local placeholder = Text(sb, 12, C.faint)
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText("Search settings")

    local clear = CreateFrame("Button", nil, sb)
    clear:SetSize(16, 16)
    clear:SetPoint("RIGHT", -4, 0)
    local ct = clear:CreateTexture(nil, "ARTWORK")
    ct:SetAllPoints()
    ct:SetTexture(CLEAR_ICON)
    ct:SetAlpha(0.6)
    clear:SetScript("OnEnter", function() ct:SetAlpha(1) end)
    clear:SetScript("OnLeave", function() ct:SetAlpha(0.6) end)
    clear:SetScript("OnClick", function() sb:SetText(""); sb:ClearFocus() end)
    clear:Hide()

    local function Visuals()
        local has = (sb:GetText() or "") ~= ""
        placeholder:SetShown(not has and not sb:HasFocus())
        clear:SetShown(has)
        SetBorderColor(sb, sb:HasFocus() and C.brand or C.hairline, sb:HasFocus() and 0.8 or 0.12)
    end
    sb:SetScript("OnEditFocusGained", Visuals)
    sb:SetScript("OnEditFocusLost", Visuals)
    sb:SetScript("OnTextChanged", function(self)
        local t = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        searchText = t:lower()
        Visuals()
        Relayout()
        if ui.scroll then ui.scroll.ScrollTo(0) end
    end)
    sb:SetScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then self:SetText("") else self:ClearFocus() end
    end)
    sb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Visuals()
    return sb
end

local function BuildSidebar(f, groups, height)
    local side = CreateFrame("Frame", nil, f)
    side:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -(1 + TITLE_H))
    side:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
    side:SetWidth(SIDEBAR_W)
    local bg = SolidC(side, "BACKGROUND", C.sidebar)
    bg:SetAllPoints()
    local edge = SolidC(side, "ARTWORK", C.hairline)
    edge:SetWidth(1)
    edge:SetPoint("TOPRIGHT")
    edge:SetPoint("BOTTOMRIGHT")

    ui.search = BuildSearchBox(side)
    ui.search:SetPoint("TOPLEFT", side, "TOPLEFT", SIDE_PAD, -SIDE_PAD)

    ui.nav = {}
    local y = -(SIDE_PAD + SEARCH_H + 12)
    for _, g in ipairs(groups) do
        local b = CreateFrame("Button", nil, side)
        b:SetSize(SIDEBAR_W - 2 * (SIDE_PAD - 4), NAV_H)
        b:SetPoint("TOPLEFT", side, "TOPLEFT", SIDE_PAD - 4, y)
        b.group = g.name
        b.bg = Solid(b, "BACKGROUND", C.brand[1], C.brand[2], C.brand[3], 0.16)
        b.bg:SetAllPoints()
        b.bg:Hide()
        b.hl = Solid(b, "BACKGROUND", 1, 1, 1, 0.04)
        b.hl:SetAllPoints()
        b.hl:Hide()
        b.accent = SolidC(b, "ARTWORK", C.brand)
        b.accent:SetWidth(3)
        b.accent:SetPoint("TOPLEFT")
        b.accent:SetPoint("BOTTOMLEFT")
        b.accent:Hide()
        b.label = Text(b, 13, C.muted)
        b.label:SetPoint("LEFT", 14, 0)
        b.label:SetText(g.name)
        b.count = Text(b, 11, C.brand)
        b.count:SetPoint("RIGHT", -10, 0)
        b.count:SetJustifyH("RIGHT")
        b:SetScript("OnEnter", function(self) self.hl:Show() end)
        b:SetScript("OnLeave", function(self) self.hl:Hide() end)
        b:SetScript("OnClick", function(self)
            if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
            SelectGroup(self.group)
        end)
        ui.nav[#ui.nav + 1] = b
        y = y - NAV_H - 2
    end

    -- Tips at the bottom.
    local tips = Text(side, 10, C.faint)
    Wrap(tips, SIDEBAR_W - 2 * SIDE_PAD)
    tips:SetSpacing(2)
    tips:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", SIDE_PAD, SIDE_PAD)
    tips:SetText("Settings are shared by every character on the account.\n\nHold Shift at an NPC or vendor to skip automation once.")

    -- "Other classes" switch, above the tips.
    local row = CreateFrame("Button", nil, side)
    row:SetSize(SIDEBAR_W - 2 * SIDE_PAD, 26)
    row:SetPoint("BOTTOMLEFT", tips, "TOPLEFT", 0, 14)
    local label = Text(row, 12, C.muted)
    label:SetPoint("LEFT")
    label:SetText("Other classes")
    local sw = CreateSwitch(row)
    sw:SetPoint("RIGHT")
    local rule = SolidC(row, "ARTWORK", C.hairline)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 8)
    rule:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", 0, 8)
    local ctl = {}
    function ctl:Refresh(animate)
        Switch_Set(sw, ShowAllClasses(), true, animate)
    end
    local function flip()
        DropFocus()
        ns.db.ui.allClasses = not ShowAllClasses()
        ns.SaveSettings()
        Sound(ns.db.ui.allClasses)
        ctl:Refresh(true)
        Relayout()
    end
    local function enter(owner)
        TooltipBeside(owner)
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", -(SIDE_PAD + 8), 0)
        GameTooltip:AddLine("Other classes", 1, 1, 1)
        GameTooltip:AddLine("Also show settings that only apply to other classes, so you can set them up for your alts. Settings are shared by the whole account.", C.muted[1] + 0.2, C.muted[2] + 0.2, C.muted[3] + 0.2, true)
        GameTooltip:Show()
    end
    row:SetScript("OnClick", flip)
    row:SetScript("OnEnter", function(self) Color(label, C.text); enter(self) end)
    row:SetScript("OnLeave", function() Color(label, C.muted); HideTooltip() end)
    sw:SetScript("OnClick", flip)
    sw:SetScript("OnEnter", function(self) self.hover = true; Switch_Paint(self); Color(label, C.text); enter(row) end)
    sw:SetScript("OnLeave", function(self) self.hover = false; Switch_Paint(self); Color(label, C.muted); HideTooltip() end)
    ui.classRow, ui.classControl = row, ctl
    return side
end

local function BuildOptionsDialog()
    if optionsFrame then return optionsFrame end

    -- Parent chains are resolved by key when greying out sub-options.
    for _, mod in ipairs(ns.modules) do
        for _, opt in ipairs(mod.options) do
            if opt.key then optionByKey[opt.key] = opt end
        end
    end

    local height = math.floor(math.min(DIALOG_H, (UIParent:GetHeight() or DIALOG_H) * MAX_SCREEN_FRAC))
    height = math.max(DIALOG_MIN_H, height)

    local f = CreateFrame("Frame", "MooseModeOptionsFrame", UIParent)
    f:SetSize(DIALOG_W, height)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:Hide()
    local bg = SolidC(f, "BACKGROUND", C.window)
    bg:SetAllPoints()
    Border(f, C.brand, 0.55)
    f:SetScript("OnMouseDown", DropFocus)
    optionsFrame = f

    -- Escape closes it.
    tinsert(UISpecialFrames, "MooseModeOptionsFrame")

    BuildTitleBar(f)
    local groups = GroupedModules()
    BuildSidebar(f, groups, height)

    -- Content column.
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 1 + SIDEBAR_W + PAD, -(1 + TITLE_H))
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 1)

    ui.groupTitle = Text(content, 15, C.text)
    ui.groupTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -16)
    ui.groupBlurb = Text(content, 11, C.muted)
    ui.groupBlurb:SetPoint("TOPLEFT", ui.groupTitle, "BOTTOMLEFT", 0, -5)
    ui.groupBlurb:SetWidth(CONTENT_W - 170)

    ui.collapseAll = CreateTextButton(content, "Collapse all")
    ui.collapseAll:SetPoint("TOPRIGHT", content, "TOPLEFT", CONTENT_W, -18)
    ui.collapseAll:SetScript("OnClick", function() DropFocus(); SetAllExpanded(false) end)
    ui.expandAll = CreateTextButton(content, "Expand all")
    ui.expandAll:SetPoint("RIGHT", ui.collapseAll, "LEFT", -6, 0)
    ui.expandAll:SetScript("OnClick", function() DropFocus(); SetAllExpanded(true) end)

    local viewH = height - 2 - TITLE_H - CONTENT_HEAD_H - PAD
    local scroll, child = CreateScrollArea(content, CONTENT_W, viewH)
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -CONTENT_HEAD_H)
    ui.scroll, ui.child = scroll, child

    ui.empty = Text(content, 12, C.muted)
    Wrap(ui.empty, CONTENT_W - 40)
    ui.empty:SetJustifyH("CENTER")
    ui.empty:SetPoint("TOP", scroll, "TOP", 0, -60)
    ui.empty:Hide()

    -- Group headings for search results, and the cards themselves.
    ui.headings = {}
    for _, g in ipairs(groups) do
        local hd = Text(child, 10, C.brand)
        hd:SetText(string.upper(g.name))
        hd:SetHeight(HEADING_H - 8)
        hd:SetJustifyV("MIDDLE")
        hd:Hide()
        ui.headings[g.name] = hd
        for _, mod in ipairs(g.mods) do
            cards[#cards + 1] = BuildCard(child, mod, g.name)
        end
    end

    f:SetScript("OnShow", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
        UpdateAll(false)
        Relayout()
    end)
    f:SetScript("OnHide", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
        HideTooltip()
        if ui.search:GetText() ~= "" then ui.search:SetText("") end
        ui.search:ClearFocus()
    end)

    local pos = ns.db.optionsPos or {}
    f:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
    return f
end

function ns.OpenOptions()
    if not ns.db then return end
    BuildOptionsDialog():Show()
end

function ns.ToggleOptions()
    if not ns.db then return end
    local f = BuildOptionsDialog()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- A page on the AddOns tab of Blizzard's Settings panel that opens the
-- dialog. Guarded: older or trimmed clients simply skip it.
local function RegisterSettingsStub()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local panel = CreateFrame("Frame")
    local title = Text(panel, 20, C.brand)
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("MooseMode")
    local desc = Text(panel, 12, C.muted)
    Wrap(desc, 520)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("MooseMode has its own settings window. Open it here, with /mm or /moose, or from the purple star on the minimap.")
    local open = CreateFlatButton(panel, "Open settings", 140, 26)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then
            if HideUIPanel then pcall(HideUIPanel, SettingsPanel) else SettingsPanel:Hide() end
        end
        ns.OpenOptions()
    end)
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, "MooseMode")
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
        ns.settingsCategory = category
    end
end
table.insert(ns.OnInitCallbacks, function()
    local ok, err = pcall(RegisterSettingsStub)
    if not ok and ns.dev then ns.Print("settings page not registered: " .. tostring(err)) end
end)

-- Redraw the dialog's controls after a module changed a setting itself.
function ns.RefreshOptionsDialog()
    if optionsFrame then UpdateAll(false) end
end

function ns.RefreshAfterRestore()
    -- Modules that push settings into per-character client state (CVars)
    -- may have applied defaults before the restore landed; those flagged
    -- reinitSafe have an idempotent OnInit, so run it again on the real
    -- values.
    for _, mod in ipairs(ns.modules) do
        if mod.OnInit and mod.reinitSafe then
            local ok, err = pcall(mod.OnInit, mod)
            if not ok then ns.Print("error re-applying " .. tostring(mod.label) .. ": " .. tostring(err)) end
        end
    end
    MinimapRefreshAfterRestore()
    if optionsFrame then
        UpdateAll(false)
        Relayout()
        local pos = ns.db.optionsPos or {}
        optionsFrame:ClearAllPoints()
        optionsFrame:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function PrintHelp()
    ns.Print("/mm or /moose  opens the options dialog.  /mm minimap  toggles the minimap button.  /mm icon <dx> <dy>  nudges the icon.")
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
    elseif cmd == "icon" then
        ns.NudgeMinimapIcon(rest)
        return
    elseif cmd == "help" then
        PrintHelp()
        return
    elseif cmd == "cfg" then
        ns.Print("MooseMode settings backup macro. Leave the MMcfg macros alone; they are rewritten automatically.")
        return
    elseif cmd == "backup" then
        local okI, idx = pcall(GetMacroIndexByName, SV_MACRO_PREFIX .. "1")
        local okN, account, perChar = pcall(GetNumMacros)
        local payload = SvReadMacros()
        local keys = 0
        if payload then for _ in payload:gmatch("[^;]+=") do keys = keys + 1 end end
        ns.Print(("backup: restored=%s absent=%s macrosReady=%s dirty=%s hadKeysAtLoad=%s"):format(
            tostring(svRestored), tostring(svAbsentConfirmed), tostring(svMacrosReady), tostring(svDirty), tostring(svHadKeysAtLoad)))
        ns.Print(("backup: MMcfg1 index=%s, macros account=%s char=%s, payload=%s chars, %d keys"):format(
            okI and tostring(idx) or "err", okN and tostring(account) or "err", okN and tostring(perChar) or "err",
            payload and tostring(#payload) or "none", keys))
        ns.Print(("backup: petAttackMacros=%s autoQuestLowThreshold=%s"):format(
            tostring(ns.db and ns.db.petAttackMacros), tostring(ns.db and ns.db.autoQuestLowThreshold)))
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
