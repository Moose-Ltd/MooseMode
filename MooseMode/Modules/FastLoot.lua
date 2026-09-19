-------------------------------------------------------------------------------
-- MooseMode -- FastLoot
--
-- Grabs everything from a corpse the moment LOOT_READY fires, before the
-- loot window has a chance to paint. Optionally leaves grey (poor) items
-- behind; money, currency and quest items are always taken.
--
-- Options (account-wide):
--   fastLoot            Loot everything instantly
--   fastLootSkipGreys   Leave grey items (sub-option)
-------------------------------------------------------------------------------

local ADDON, ns = ...

local POOR      = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local SLOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

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

local function FastLoot()
    if not ns.db or not ns.db.fastLoot then return end
    if not GetNumLootItems or not LootSlot then return end
    local n = GetNumLootItems()
    if ns.IsSecret(n) or not n or n == 0 then return end
    -- Skipped greys stay in the window Blizzard shows, so the player can
    -- still take them by hand; nothing here closes the loot frame.
    for i = n, 1, -1 do
        if not IsSkippedGrey(i) then
            LootSlot(i)
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_READY")
frame:SetScript("OnEvent", function(self, event)
    if event == "LOOT_READY" then
        FastLoot()
    end
end)

ns:RegisterModule({
    key   = "fastLootModule",
    label = "Fast Loot",
    options = {
        { key = "fastLoot", label = "Loot everything instantly", default = true,
          tooltip = "Take every item the moment loot is ready, without waiting for the loot window." },
        { key = "fastLootSkipGreys", label = "Leave grey items", default = false, parent = "fastLoot",
          tooltip = "Loots everything except grey (poor) items, which stay on the corpse." },
    },
})
