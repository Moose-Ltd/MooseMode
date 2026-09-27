-------------------------------------------------------------------------------
-- MooseMode -- ItemLevel
--
-- A small item level number, coloured by quality, in the bottom-right corner
-- of each equipped slot on the character window and of each weapon or piece
-- of armour in your bags and bank. (Gear never stacks, so the corner where
-- the stack count goes is always free.) The average item level is in Character Stats.
--
-- Hands off Blizzard's frames, for the same reason as CharacterStats: this
-- client's Blizzard code reads secret values, and any of it that runs with
-- our taint errors out. So nothing here is written into a Blizzard table or
-- frame, no Blizzard script, method or mixin is hooked or replaced, and no
-- region or child is added to a Blizzard button:
--   * Each number is a FontString on an overlay frame of our own, parented
--     to UIParent and anchored over the Blizzard button (SetAllPoints). It
--     never takes the mouse, so clicks, drags and right-click use still go
--     to Blizzard's (protected-action) button.
--   * Which button shows what is read from our own code only: IsVisible,
--     GetID, GetBagID (bags), GetBankTabID / GetContainerSlotID (bank), the
--     container frames' Items lists and the bank panel's button pool.
--     Nothing is kept on the buttons; our state is a table keyed by button.
--   * Updates come from our own event frame plus a light visibility poll.
--   * An overlay anchored to a protected button is restricted in combat, so
--     overlays are only created, scaled and layered out of combat; in combat
--     only our FontStrings' text and visibility change.
--
-- Options (account-wide):
--   itemLevel         Show item levels (master)
--   itemLevelChar     On the character window
--   itemLevelBags     In bags (and the bank)
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local POLL = 0.1            -- seconds between visibility checks
local RESYNC = 1.0          -- seconds between full refreshes while something is shown
local FONT_SIZE = 11
local MAX_CONTAINER_FRAMES = 13

local EQUIP_SLOTS = {       -- shirt (4), tabard (19) and ammo (0) left out
    { "CharacterHeadSlot", 1 }, { "CharacterNeckSlot", 2 }, { "CharacterShoulderSlot", 3 },
    { "CharacterBackSlot", 15 }, { "CharacterChestSlot", 5 }, { "CharacterWristSlot", 9 },
    { "CharacterHandsSlot", 10 }, { "CharacterWaistSlot", 6 }, { "CharacterLegsSlot", 7 },
    { "CharacterFeetSlot", 8 }, { "CharacterFinger0Slot", 11 }, { "CharacterFinger1Slot", 12 },
    { "CharacterTrinket0Slot", 13 }, { "CharacterTrinket1Slot", 14 },
    { "CharacterMainHandSlot", 16 }, { "CharacterSecondaryHandSlot", 17 }, { "CharacterRangedSlot", 18 },
}

-- Equip locations that are armour or weapon class but not gear worth a number.
local NOT_GEAR = {
    [""] = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BODY = true, INVTYPE_TABARD = true,
    INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_AMMO = true,
}
local CLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local CLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4

local function Plain(v)
    return v ~= nil and not ns.IsSecret(v)
end

local function Call(obj, method, ...)
    local f = obj and obj[method]
    if type(f) ~= "function" then return nil end
    local ok, a, b = pcall(f, obj, ...)
    if not ok then return nil end
    return a, b
end

local function Visible(frame)
    local v = Call(frame, "IsVisible")
    return Plain(v) and v and true or false
end

-------------------------------------------------------------------------------
-- Item data
-------------------------------------------------------------------------------

local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Is this a weapon or armour piece (rings, trinkets, cloaks, off-hands too)?
local function IsGear(link)
    if not GetInstant then return false end
    local ok, _, _, _, equipLoc, _, classID = pcall(GetInstant, link)
    if not ok or not Plain(classID) then return false end
    if classID ~= CLASS_WEAPON and classID ~= CLASS_ARMOR then return false end
    return equipLoc ~= nil and not NOT_GEAR[equipLoc]
end

-- Item level, or nil while the item's data is not cached yet.
local function ItemLevelOf(link)
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        local ok, lvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
        if ok and Plain(lvl) and type(lvl) == "number" and lvl > 0 then return lvl end
    end
    if GetInfo then
        local ok, _, _, _, lvl = pcall(GetInfo, link)
        if ok and Plain(lvl) and type(lvl) == "number" and lvl > 0 then return lvl end
    end
    return nil
end

local function QualityOf(link)
    if not GetInfo then return nil end
    local ok, _, _, q = pcall(GetInfo, link)
    if ok and Plain(q) then return q end
    return nil
end

local function QualityRGB(q)
    if not q then return 1, 1, 1 end
    if C_Item and C_Item.GetItemQualityColor then
        local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)
        if ok and type(r) == "number" then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-------------------------------------------------------------------------------
-- Overlays (ours, on UIParent, keyed by the Blizzard button)
-------------------------------------------------------------------------------

local overlays = {}          -- [blizzard button] = { frame, text, scale, level, strata }
local fontPath = (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
local wantCreate = false     -- a button needed an overlay during combat

local function Sync(entry, button)
    if InCombatLockdown() then return end
    local frame = entry.frame
    local okS, scale = pcall(function() return button:GetEffectiveScale() / UIParent:GetEffectiveScale() end)
    if okS and Plain(scale) and type(scale) == "number" and scale > 0 and scale ~= entry.scale then
        entry.scale = scale
        frame:SetScale(scale)
    end
    local strata = Call(button, "GetFrameStrata")
    if Plain(strata) and strata and strata ~= entry.strata then
        entry.strata = strata
        frame:SetFrameStrata(strata)
    end
    local level = Call(button, "GetFrameLevel")
    if Plain(level) and type(level) == "number" and level + 5 ~= entry.level then
        entry.level = level + 5
        frame:SetFrameLevel(entry.level)
    end
end

local function Overlay(button)
    local entry = overlays[button]
    if entry then return entry end
    if InCombatLockdown() then wantCreate = true return nil end
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:EnableMouse(false)
    frame:SetAllPoints(button)
    local text = frame:CreateFontString(nil, "OVERLAY")
    if not text:SetFont(fontPath, FONT_SIZE, "OUTLINE") then text:SetFontObject("NumberFontNormal") end
    text:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 3)
    text:SetJustifyH("RIGHT")
    text:Hide()
    entry = { frame = frame, text = text }
    overlays[button] = entry
    Sync(entry, button)
    return entry
end

-------------------------------------------------------------------------------
-- What each button shows
-------------------------------------------------------------------------------

local pending = false        -- some item data was not cached yet
local lit, nextLit = {}, {}  -- entries showing a number this tick / being built
local dirty = true
local freshPass = false      -- this pass re-reads item data and re-layers overlays
local gen = 0                -- bumped whenever item data may have changed
local memo = setmetatable({}, { __mode = "k" })   -- [button] = last lookup

-- Show ilvl (coloured by quality q) on button, alpha a.
local function Show(button, ilvl, q, alpha)
    local entry = Overlay(button)
    if not entry then return end
    if not entry.shown or freshPass then Sync(entry, button) end
    entry.shown = true
    local key = ilvl .. ":" .. (q or -1) .. ":" .. alpha
    if entry.key ~= key then
        entry.key = key
        entry.text:SetText(tostring(math.floor(ilvl + 0.5)))
        entry.text:SetTextColor(QualityRGB(q))
        entry.text:SetAlpha(alpha)
    end
    entry.text:Show()
    nextLit[entry] = true
end

local function EquipSlotValue(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link or not Plain(link) then return nil end
    local ilvl = ItemLevelOf(link)
    if not ilvl then pending = true return nil end
    local q = GetInventoryItemQuality and GetInventoryItemQuality("player", slot)
    if not Plain(q) then q = QualityOf(link) end
    return ilvl, q
end

local function DoCharacter()
    for _, pair in ipairs(EQUIP_SLOTS) do
        local button = _G[pair[1]]
        if button and Visible(button) then
            local ok, ilvl, q = pcall(EquipSlotValue, pair[2])
            if ok and ilvl then Show(button, ilvl, q, 1) end
        end
    end
end

-- bag, slot for a bag or bank item button, from its own getters.
local function BagSlot(button)
    local bag, slot
    if type(button.GetBankTabID) == "function" then
        bag, slot = Call(button, "GetBankTabID"), Call(button, "GetContainerSlotID")
    elseif type(button.GetBagID) == "function" then
        bag, slot = Call(button, "GetBagID"), Call(button, "GetID")
    end
    if Plain(bag) and Plain(slot) and type(bag) == "number" and type(slot) == "number" then return bag, slot end
    return nil
end

local function ContainerValue(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if type(info) ~= "table" then return nil end
    local link = info.hyperlink
    if not Plain(link) or not link or not IsGear(link) then return nil end
    local ilvl = ItemLevelOf(link)
    if not ilvl then pending = true return nil end
    local q = Plain(info.quality) and info.quality or QualityOf(link)
    local faded = (Plain(info.isFiltered) and info.isFiltered) or (Plain(info.isLocked) and info.isLocked)
    return ilvl, q, faded and 0.35 or 1
end

-- Looked up again only when the button moved to another bag slot or item
-- data may have changed (gen); otherwise the last answer is reused.
local function DoItemButton(button, bag, slot)
    if not Visible(button) then return end
    if not bag then bag, slot = BagSlot(button) end
    if not bag then return end
    local m = memo[button]
    if not m or m.gen ~= gen or m.bag ~= bag or m.slot ~= slot then
        m = m or {}
        memo[button] = m
        pending = false
        local ok, ilvl, q, alpha = pcall(ContainerValue, bag, slot)
        m.gen, m.bag, m.slot = gen, bag, slot
        if ok then m.ilvl, m.q, m.alpha = ilvl, q, alpha else m.ilvl = nil end
        if pending then m.gen = -1 end   -- not cached yet: look again next pass
    end
    if m.ilvl then Show(button, m.ilvl, m.q, m.alpha) end
end

local function DoContainer(frame)
    if not frame or not Visible(frame) then return end
    local items = frame.Items               -- read only
    if type(items) ~= "table" then return end
    for _, button in ipairs(items) do DoItemButton(button) end
end

local function DoBank()
    local panel = _G.BankPanel
    if panel and Visible(panel) then
        local pool = panel.itemButtonPool     -- read only
        if pool and type(pool.EnumerateActive) == "function" then
            local ok, iter, state, start = pcall(pool.EnumerateActive, pool)
            if ok and iter then
                for button in iter, state, start do DoItemButton(button) end
            end
        end
    end
    -- Older bank frame layout: BankFrameItem1..N in bag -1.
    if _G.BankFrame and Visible(_G.BankFrame) and _G.BankFrameItem1 then
        local bankBag = (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or -1
        for i = 1, 28 do
            local button = _G["BankFrameItem" .. i]
            if not button then break end
            local id = Call(button, "GetID")
            if Plain(id) and type(id) == "number" then DoItemButton(button, bankBag, id) end
        end
    end
end

local function DoBags()
    if not (C_Container and C_Container.GetContainerItemInfo) then return end
    DoContainer(_G.ContainerFrameCombinedBags)
    for i = 1, MAX_CONTAINER_FRAMES do
        local frame = _G["ContainerFrame" .. i]
        if frame then DoContainer(frame) end
    end
    DoBank()
end

-- One pass: light up every visible button that should show a number, and
-- hide the numbers of buttons that went away.
local function Update(fresh)
    if fresh then gen = gen + 1 end
    freshPass = fresh and true or false
    local db = ns.db
    if db and db.itemLevel then
        if db.itemLevelChar and _G.PaperDollFrame and Visible(_G.PaperDollFrame) then DoCharacter() end
        if db.itemLevelBags then DoBags() end
    end
    for entry in pairs(lit) do
        if not nextLit[entry] then
            entry.text:Hide()
            entry.shown = false
        end
    end
    lit, nextLit = nextLit, lit
    wipe(nextLit)
end

-------------------------------------------------------------------------------
-- Driver: our own events and a visibility poll
-------------------------------------------------------------------------------

-- Anything to watch right now? (cheap: a handful of IsVisible calls)
local function Watching()
    local db = ns.db
    if not (db and db.itemLevel) then return false end
    if db.itemLevelChar and _G.PaperDollFrame and Visible(_G.PaperDollFrame) then return true end
    if db.itemLevelBags then
        if Visible(_G.ContainerFrameCombinedBags) or Visible(_G.BankFrame) then return true end
        for i = 1, MAX_CONTAINER_FRAMES do
            if Visible(_G["ContainerFrame" .. i]) then return true end
        end
    end
    return false
end

local driver = CreateFrame("Frame")
local sincePoll, sinceFull = 0, 0

driver:SetScript("OnUpdate", function(_, elapsed)
    sincePoll = sincePoll + (elapsed or 0)
    if sincePoll < POLL then return end
    sinceFull = sinceFull + sincePoll
    sincePoll = 0
    local watching = Watching()
    if not watching and next(lit) == nil then return end
    -- Every tick while shown, so a button that appears or changes bag or
    -- slot (combined bag re-layout, bank tab switch) gets its number at
    -- once. Item data is only re-read after an event or once a second
    -- (fresh); other ticks reuse each button's last answer.
    local fresh = dirty or sinceFull >= RESYNC
    dirty = false
    if sinceFull >= RESYNC then sinceFull = 0 end
    do
        local ok, err = pcall(Update, fresh)
        if not ok and ns.Debug then ns.Debug("ItemLevel: " .. tostring(err)) end
    end
end)

local events = {
    "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "INVENTORY_SEARCH_UPDATE", "PLAYERBANKSLOTS_CHANGED",
    "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
}
for _, e in ipairs(events) do pcall(driver.RegisterEvent, driver, e) end
driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if not wantCreate then return end
        wantCreate = false
    end
    dirty = true
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

local function Refresh()
    pcall(Update, true)
end

ns:RegisterModule({
    key   = "itemLevelModule",
    label = "Item Level",
    group = "Interface",
    summary = "Item level numbers on your equipped gear and on gear in your bags.",
    icon    = "Interface\\Icons\\INV_Helmet_03",
    reinitSafe = true,
    options = {
        { key = "itemLevel", label = "Show item levels", default = true,
          tooltip = "A small item level number, coloured by quality, in the corner of each piece of gear.",
          onChange = function() Refresh() end },
        { key = "itemLevelChar", label = "On the character window", default = true, parent = "itemLevel",
          tooltip = "On each equipped slot of the character window (P). Shirts and tabards are left out. Your average item level is in Character Stats, under the character window.",
          onChange = function() Refresh() end },
        { key = "itemLevelBags", label = "In bags", default = true, parent = "itemLevel",
          tooltip = "On weapons and armour in your bags (combined or separate) and the bank. Dimmed while a search filters the item out or it is picked up.",
          onChange = function() Refresh() end },
    },
})
