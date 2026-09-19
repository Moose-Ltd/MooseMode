-------------------------------------------------------------------------------
-- MooseMode -- AutoSell
--
-- Sells every grey (junk) item the moment a vendor window opens, using the
-- game's own sell-all-junk (C_MerchantFrame.SellAllJunkItems): one call, no
-- throttle, nothing to maintain. Hold SHIFT while opening the vendor to skip
-- selling for that visit.
--
-- The bags are scanned first purely for the chat summary, so the count and
-- gold figure reflect what the sell-all is about to do. If a vendor does not
-- support sell-all, nothing happens.
--
-- Options (account-wide):
--   autoSell      Sell grey items at vendors
--   sellSummary   Show sale summary in chat (sub-option)
--
-- Commands:
--   /mm now       sell grey items at the currently open vendor
-------------------------------------------------------------------------------

local ADDON, ns = ...

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

-------------------------------------------------------------------------------
-- Bag reading (summary only)
-------------------------------------------------------------------------------

local function NumBags()
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

-- Returns containerInfo, quality, sellPrice for a bag slot, or nil if the
-- slot is empty, locked, or unreadable.
local function SlotInfo(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.hyperlink then return nil end
    if info.isLocked then return nil end

    local quality, sellPrice = info.quality, nil
    if C_Item and C_Item.GetItemInfo then
        local ok, _, _, q, _, _, _, _, _, _, _, price = pcall(C_Item.GetItemInfo, info.hyperlink)
        if ok then
            if q ~= nil then quality = q end
            sellPrice = price
        end
    end
    if ns.IsSecret(quality) or ns.IsSecret(sellPrice) then return nil end
    return info, quality, sellPrice or 0
end

-- Counts the grey items with a sell value and totals their vendor value.
local function CountGreys()
    local count, total = 0, 0
    for bag = 0, NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info, quality, sellPrice = SlotInfo(bag, slot)
            if info and quality == POOR and not info.hasNoValue then
                count = count + 1
                total = total + (sellPrice or 0) * (info.stackCount or 1)
            end
        end
    end
    return count, total
end

-------------------------------------------------------------------------------
-- Selling
-------------------------------------------------------------------------------

local function SellAllAvailable()
    if not C_MerchantFrame or not C_MerchantFrame.SellAllJunkItems then return false end
    if C_MerchantFrame.IsSellAllJunkEnabled then
        local ok, v = pcall(C_MerchantFrame.IsSellAllJunkEnabled)
        if not ok or ns.IsSecret(v) or not v then return false end
    end
    return true
end

local function SellGreys(force)
    local db = ns.db
    if not db then return end
    if not force and not db.autoSell then return end
    if not force and IsShiftKeyDown() then return end
    if not SellAllAvailable() then return end

    local count, total = CountGreys()
    if count <= 0 then return end

    C_MerchantFrame.SellAllJunkItems()

    if db.sellSummary then
        if total > 0 then
            ns.Print(("Sold %d grey item%s for %s."):format(count, count == 1 and "" or "s", ns.Coins(total)))
        else
            ns.Print(("Sold %d grey item%s."):format(count, count == 1 and "" or "s"))
        end
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        SellGreys(false)
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "autoSellModule",
    label = "Auto Sell",
    group = "Vendors",
    options = {
        { key = "autoSell", label = "Sell grey items at vendors", default = true,
          tooltip = "Sells every grey item the moment a vendor opens, using the game's own sell-all." },
        { key = "sellSummary", label = "Show sale summary in chat", default = true, parent = "autoSell",
          tooltip = "Print how many items were sold and for how much." },
    },
    OnInit = function()
        -- Retired settings from the per-item era.
        ns.db.keep = nil
        ns.db.junk = nil
        ns.db.sellBlizzardFast = nil
    end,
    commands = {
        now = function()
            if MerchantFrame and MerchantFrame:IsShown() then
                SellGreys(true)
            else
                ns.Print("Open a vendor first.")
            end
        end,
    },
})
