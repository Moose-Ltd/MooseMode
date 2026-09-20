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

-- Make the client's auto-loot CVar match the account-wide option: off while
-- Fast Loot owns looting, restored to exactly what the character had when it
-- does not (ns.CVar.ApplyWithSnapshot keeps the previous value in
-- db.fastLootPrevAutoLoot).
local function ApplyFastLoot(enabled, announce)
    if not ns.db then return end
    if not ns.CVar.Exists(CVAR) then
        if announce then
            ns.Print("This client has no '" .. CVAR .. "' setting; Fast Loot will run alongside the game's own auto-loot.")
        end
        return
    end
    ns.CVar.ApplyWithSnapshot(CVAR, "0", "fastLootPrevAutoLoot", enabled)
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
