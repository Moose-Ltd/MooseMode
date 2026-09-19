-------------------------------------------------------------------------------
-- MooseMode -- AutoSell
--
-- Sells grey (junk) items automatically when a vendor window opens.
-- Hold SHIFT while opening the vendor to skip selling for that visit.
--
-- Options (account-wide):
--   autoSell          Auto sell junk at vendors
--   sellSummary       Show sale summary in chat
--   sellBlizzardFast  Use Blizzard's sell-all-junk (ignores keep/junk lists)
--
-- Commands:
--   /mm keep <link>   never sell this item (toggle)
--   /mm junk <link>   always sell this item, any quality (toggle)
--   /mm list          show keep / junk lists
--   /mm reset         clear both lists
--   /mm now           sell junk at the currently open vendor
-------------------------------------------------------------------------------

local ADDON, ns = ...

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local SELL_INTERVAL = 0.15   -- seconds between vendor sells

local sellTicker
local sellQueue = {}
local sellTotal = 0
local sellCount = 0

-------------------------------------------------------------------------------
-- Bag reading
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

local function IsQuestItem(bag, slot)
    if not C_Container.GetContainerItemQuestInfo then return false end
    local ok, q = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
    return ok and q and q.isQuestItem or false
end

-------------------------------------------------------------------------------
-- Selling
-------------------------------------------------------------------------------

local function ShouldSell(bag, slot, info, quality)
    local db = ns.db
    local id = info.itemID
    if id and db.keep[id] then return false end
    if info.hasNoValue then return false end
    if IsQuestItem(bag, slot) then return false end
    if id and db.junk[id] then return true end
    return quality == POOR
end

local function BuildQueue()
    wipe(sellQueue)
    for bag = 0, NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info, quality, sellPrice = SlotInfo(bag, slot)
            if info and ShouldSell(bag, slot, info, quality) then
                sellQueue[#sellQueue + 1] = {
                    bag = bag, slot = slot,
                    itemID = info.itemID,
                    count = info.stackCount or 1,
                    price = sellPrice or 0,
                }
            end
        end
    end
    return #sellQueue
end

local function StopSelling(reason)
    if sellTicker then
        sellTicker:Cancel()
        sellTicker = nil
    end
    if sellCount > 0 and ns.db.sellSummary then
        if sellTotal > 0 then
            ns.Print(("Sold %d junk item%s for %s."):format(sellCount, sellCount == 1 and "" or "s", ns.Coins(sellTotal)))
        else
            ns.Print(("Sold %d junk item%s."):format(sellCount, sellCount == 1 and "" or "s"))
        end
    end
    if reason then ns.Print(reason) end
    sellCount, sellTotal = 0, 0
    wipe(sellQueue)
end

local function SellNext()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        StopSelling()
        return
    end
    local entry = table.remove(sellQueue, 1)
    if not entry then
        StopSelling()
        return
    end
    -- Re-check the slot: the player may have moved things since the scan.
    local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
    if not info or info.itemID ~= entry.itemID or info.isLocked then
        return
    end
    C_Container.UseContainerItem(entry.bag, entry.slot)
    sellCount = sellCount + 1
    sellTotal = sellTotal + (entry.price or 0) * (info.stackCount or entry.count or 1)
end

local function StartSelling(force)
    local db = ns.db
    if not db then return end
    if not force and not db.autoSell then return end
    if not force and IsShiftKeyDown() then return end
    if sellTicker then StopSelling() end
    sellCount, sellTotal = 0, 0

    -- Optional fast path: Blizzard's own sell-all-junk. Ignores keep/junk lists.
    if db.sellBlizzardFast and C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
        local enabled = true
        if C_MerchantFrame.IsSellAllJunkEnabled then
            local ok, v = pcall(C_MerchantFrame.IsSellAllJunkEnabled)
            enabled = ok and v and true or false
        end
        if enabled then
            local n = 0
            if C_MerchantFrame.GetNumJunkItems then
                local ok, v = pcall(C_MerchantFrame.GetNumJunkItems)
                if ok and v and not ns.IsSecret(v) then n = v end
            end
            if n > 0 then
                C_MerchantFrame.SellAllJunkItems()
                if db.sellSummary then
                    ns.Print(("Sold %d junk item%s (Blizzard sell-all)."):format(n, n == 1 and "" or "s"))
                end
            end
            return
        end
    end

    if BuildQueue() == 0 then return end
    sellTicker = C_Timer.NewTicker(SELL_INTERVAL, SellNext)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "MERCHANT_SHOW" then
        StartSelling(false)
    elseif event == "MERCHANT_CLOSED" then
        if sellTicker then StopSelling() end
    elseif event == "UI_ERROR_MESSAGE" then
        if sellTicker and arg2 and (arg2 == ERR_VENDOR_DOESNT_BUY or arg2 == ERR_TOO_MUCH_GOLD) then
            StopSelling("Vendor refused; stopped selling.")
        end
    end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local function ToggleList(list, other, label, arg)
    local id = ns.ItemIDFrom(arg)
    if not id then
        ns.Print("Usage: /mm " .. label .. " <item link or item ID>  (shift-click an item into chat)")
        return
    end
    if list[id] then
        list[id] = nil
        ns.Print(("Removed %s from the %s list."):format(ns.ItemNameByID(id), label))
    else
        list[id] = true
        other[id] = nil
        ns.Print(("Added %s to the %s list."):format(ns.ItemNameByID(id), label))
    end
end

local function ShowLists()
    local n = 0
    for id in pairs(ns.db.keep) do n = n + 1; ns.Print("keep: " .. ns.ItemNameByID(id) .. " (" .. id .. ")") end
    for id in pairs(ns.db.junk) do n = n + 1; ns.Print("junk: " .. ns.ItemNameByID(id) .. " (" .. id .. ")") end
    if n == 0 then ns.Print("Keep and junk lists are empty.") end
end

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "autoSellModule",
    label = "Auto Sell",
    options = {
        { key = "autoSell", label = "Sell grey items at vendors", default = true,
          tooltip = "Sell every grey item as soon as a vendor window opens." },
        { key = "sellSummary", label = "Show sale summary in chat", default = true,
          tooltip = "Print how many items were sold and for how much." },
        { key = "sellBlizzardFast", label = "Use Blizzard sell-all (ignores lists)", default = false,
          tooltip = "Use the client's own sell-all-junk instead of selling item by item. Faster, but your keep and junk lists are ignored." },
    },
    OnInit = function()
        ns.db.keep = ns.db.keep or {}
        ns.db.junk = ns.db.junk or {}
    end,
    commands = {
        keep  = function(rest) ToggleList(ns.db.keep, ns.db.junk, "keep", rest) end,
        junk  = function(rest) ToggleList(ns.db.junk, ns.db.keep, "junk", rest) end,
        list  = function() ShowLists() end,
        reset = function()
            wipe(ns.db.keep); wipe(ns.db.junk)
            ns.Print("Keep and junk lists cleared.")
        end,
        now = function()
            if MerchantFrame and MerchantFrame:IsShown() then
                StartSelling(true)
            else
                ns.Print("Open a vendor first.")
            end
        end,
    },
})
