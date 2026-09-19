-------------------------------------------------------------------------------
-- MooseMode -- FastLoot
--
-- Grabs everything from a corpse the moment LOOT_READY fires, before the
-- loot window has a chance to paint. Optionally leaves grey (poor) items
-- behind; money, currency and quest items are always taken.
--
-- While the option is on, the module owns looting: Blizzard's own auto-loot
-- ("autoLootDefault" CVar) is switched off, otherwise the client loots every
-- slot on the same event and the grey rule can never take effect. The CVar is
-- per character; the option is per account, so it is re-applied at every
-- login. Turning the option off restores whatever the character had before.
--
-- Holding the game's auto-loot modifier key (Shift by default) when loot
-- opens inverts the behaviour, as it does in Blizzard's UI: the module stays
-- out of it and the ordinary loot window is shown.
--
-- Options (account-wide):
--   fastLoot            Loot everything instantly
--   fastLootSkipGreys   Leave grey items (sub-option)
-------------------------------------------------------------------------------

local ADDON, ns = ...

local POOR      = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local SLOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

local CVAR = "autoLootDefault"

-------------------------------------------------------------------------------
-- CVar helpers
-------------------------------------------------------------------------------

local function CVarExists()
    local getInfo = (C_CVar and C_CVar.GetCVarInfo) or GetCVarInfo
    if not getInfo then return false end
    local ok, value = pcall(getInfo, CVAR)
    return ok and value ~= nil
end

local function GetAutoLoot()
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, value = pcall(get, CVAR)
    if not ok then return nil end
    return value
end

local function SetAutoLoot(value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not set then return false end
    local ok = pcall(set, CVAR, value)
    return ok
end

-- Make the client's auto-loot CVar match the account-wide option: off while
-- Fast Loot owns looting, restored to the saved value when it does not.
local function ApplyFastLoot(enabled, announce)
    local db = ns.db
    if not db then return end
    if not CVarExists() then
        if announce then
            ns.Print("This client has no '" .. CVAR .. "' setting; Fast Loot will run alongside the game's own auto-loot.")
        end
        return
    end

    local current = GetAutoLoot()
    if enabled then
        if db.fastLootPrevAutoLoot == nil and current ~= nil and current ~= "0" then
            db.fastLootPrevAutoLoot = current
        end
        if current ~= "0" then
            SetAutoLoot("0")
        end
    else
        local restore = db.fastLootPrevAutoLoot or "1"
        db.fastLootPrevAutoLoot = nil
        if current ~= restore then
            SetAutoLoot(restore)
        end
    end
end

-------------------------------------------------------------------------------
-- Looting
-------------------------------------------------------------------------------

-- True when slot i holds a grey item that the player wants left on the corpse.
-- Money, currency and quest items are never skipped.
local function IsSkippedGrey(i)
    if not ns.db.fastLootSkipGreys then return false end
    if GetLootSlotType then
        local slotType = GetLootSlotType(i)
        if ns.IsSecret(slotType) then return false end
        if slotType ~= SLOT_ITEM then return false end
    end
    if not GetLootSlotInfo then return false end
    local _, _, _, _, quality, _, isQuestItem = GetLootSlotInfo(i)
    if ns.IsSecret(quality) or ns.IsSecret(isQuestItem) then return false end
    if isQuestItem then return false end
    return quality == POOR
end

-- The game's auto-loot modifier (Shift by default) inverts auto-loot in
-- Blizzard's UI; honour it here too by standing aside.
local function ModifierHeld()
    if not IsModifiedClick then return false end
    local ok, held = pcall(IsModifiedClick, "AUTOLOOTTOGGLE")
    return ok and held and true or false
end

local function FastLoot()
    if not ns.db or not ns.db.fastLoot then return end
    if not GetNumLootItems or not LootSlot then return end
    if ModifierHeld() then return end
    local n = GetNumLootItems()
    if ns.IsSecret(n) or not n or n == 0 then return end
    -- Highest slot first, so indices below stay valid as slots empty.
    -- Skipped greys stay in the window Blizzard shows, so the player can
    -- still take them by hand; nothing here closes the loot frame.
    for i = n, 1, -1 do
        if not IsSkippedGrey(i) then
            LootSlot(i)
        end
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_READY")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    if event == "LOOT_READY" then
        FastLoot()
    elseif event == "PLAYER_LOGIN" then
        -- CVars are per character; the option is per account.
        if ns.db then
            ApplyFastLoot(ns.db.fastLoot and true or false, false)
        end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "fastLootModule",
    label = "Fast Loot",
    group = "Loot",
    options = {
        { key = "fastLoot", label = "Loot everything instantly", default = true,
          tooltip = "Take every item the moment loot is ready, without waiting for the loot window. Takes over the game's auto-loot setting while on.",
          onChange = function(checked) ApplyFastLoot(checked, true) end },
        { key = "fastLootSkipGreys", label = "Leave grey items", default = false, parent = "fastLoot",
          tooltip = "Loots everything except grey (poor) items, which stay on the corpse." },
    },
    OnInit = function()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then
            ApplyFastLoot(ns.db.fastLoot and true or false, false)
        end
    end,
})
