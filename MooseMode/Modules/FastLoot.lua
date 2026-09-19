-------------------------------------------------------------------------------
-- MooseMode -- FastLoot
--
-- Grabs everything from a corpse the moment LOOT_READY fires, before the
-- loot window has a chance to paint.
--
-- Options (account-wide):
--   fastLoot   Fast loot corpses
-------------------------------------------------------------------------------

local ADDON, ns = ...

local function FastLoot()
    if not ns.db or not ns.db.fastLoot then return end
    if not GetNumLootItems or not LootSlot then return end
    local n = GetNumLootItems()
    if ns.IsSecret(n) or not n or n == 0 then return end
    for i = n, 1, -1 do
        LootSlot(i)
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
        { key = "fastLoot", label = "Fast loot corpses", default = true,
          tooltip = "Loot every slot as soon as the loot is ready, skipping the loot window delay." },
    },
})
