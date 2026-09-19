-------------------------------------------------------------------------------
-- MooseMode -- AutoSell
--
-- Sells grey (junk) items automatically when a vendor window opens.
-- Hold SHIFT while opening the vendor to skip selling for that visit.
--
-- Two paths, chosen automatically:
--   Fast:     Blizzard's own sell-all-junk (C_MerchantFrame.SellAllJunkItems),
--             one call, no throttle. Used whenever the keep and junk lists are
--             empty and the client reports sell-all as available.
--   Per-item: our own scan + UseContainerItem on a ticker. Used when the
--             player has keep/junk list entries (Blizzard's sell-all cannot
--             honour them) or when sell-all is unavailable at this vendor.
-- The chat summary always comes from our own bag scan, so the count and gold
-- figure are the same on either path.
--
-- Options (account-wide):
--   autoSell      Sell grey items at vendors
--   sellSummary   Show sale summary in chat (sub-option)
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
local SELL_INTERVAL = 0.15   -- seconds between per-item vendor sells

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

local function ListsEmpty()
    return next(ns.db.keep) == nil and next(ns.db.junk) == nil
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

-- Scans the bags into sellQueue. Returns the number of entries and the total
-- vendor value of everything queued.
local function BuildQueue()
    wipe(sellQueue)
    local total = 0
    for bag = 0, NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info, quality, sellPrice = SlotInfo(bag, slot)
            if info and ShouldSell(bag, slot, info, quality) then
                local count = info.stackCount or 1
                sellQueue[#sellQueue + 1] = {
                    bag = bag, slot = slot,
                    itemID = info.itemID,
                    count = count,
                    price = sellPrice or 0,
                }
                total = total + (sellPrice or 0) * count
            end
        end
    end
    return #sellQueue, total
end

local function PrintSummary(count, total)
    if count <= 0 or not ns.db.sellSummary then return end
    if total > 0 then
        ns.Print(("Sold %d junk item%s for %s."):format(count, count == 1 and "" or "s", ns.Coins(total)))
    else
        ns.Print(("Sold %d junk item%s."):format(count, count == 1 and "" or "s"))
    end
end

local function StopSelling(reason)
    if sellTicker then
        sellTicker:Cancel()
        sellTicker = nil
    end
    PrintSummary(sellCount, sellTotal)
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

-- True when Blizzard's sell-all can be used at this vendor right now and the
-- player has no list entries that it would ignore.
local function CanUseSellAll()
    if not ListsEmpty() then return false end
    if not C_MerchantFrame or not C_MerchantFrame.SellAllJunkItems then return false end
    if C_MerchantFrame.IsSellAllJunkEnabled then
        local ok, v = pcall(C_MerchantFrame.IsSellAllJunkEnabled)
        if not ok or ns.IsSecret(v) or not v then return false end
    end
    if C_MerchantFrame.GetNumJunkItems then
        local ok, n = pcall(C_MerchantFrame.GetNumJunkItems)
        if not ok or ns.IsSecret(n) or not n or n <= 0 then return false end
    end
    return true
end

local function StartSelling(force)
    local db = ns.db
    if not db then return end
    if not force and not db.autoSell then return end
    if not force and IsShiftKeyDown() then return end
    if sellTicker then StopSelling() end
    sellCount, sellTotal = 0, 0

    -- Our own scan drives the summary on both paths.
    local count, total = BuildQueue()
    if count == 0 then
        wipe(sellQueue)
        return
    end

    if CanUseSellAll() then
        C_MerchantFrame.SellAllJunkItems()
        PrintSummary(count, total)
        wipe(sellQueue)
        return
    end

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
    group = "Vendors",
    options = {
        { key = "autoSell", label = "Sell grey items at vendors", default = true,
          tooltip = "Uses the game's sell-all for speed. If you have keep or junk list entries it sells item by item so they are honoured." },
        { key = "sellSummary", label = "Show sale summary in chat", default = true, parent = "autoSell",
          tooltip = "Print how many items were sold and for how much." },
    },
    OnInit = function()
        ns.db.keep = ns.db.keep or {}
        ns.db.junk = ns.db.junk or {}
        ns.db.sellBlizzardFast = nil   -- retired option
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
