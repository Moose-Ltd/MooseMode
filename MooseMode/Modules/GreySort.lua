-------------------------------------------------------------------------------
-- MooseMode -- GreySort
--
-- After a bag cleanup, moves every grey (poor quality) item into one block
-- right next to the free slots, ordered by vendor value with the cheapest
-- first. Blizzard's sort leaves greys scattered by type; this puts them
-- where they are easy to see and easy to ignore.
--
-- Display order of the combined bag (Blizzard_UIPanels_Game/Mainline/
-- ContainerFrame.lua, live branch): UpdateItemSlots (line 925) creates
-- buttons for bag 4 down to bag 0, slots N..1; UpdateItemLayout (line 941)
-- sorts them by bag descending then slot ascending (SortItemsByExtendedState,
-- line 878) and lays them out BottomRightToTopLeft from the frame's
-- BOTTOMRIGHT corner (lines 868-873). Read like text, top-left to
-- bottom-right, that is:
--
--     bag 0 slot N ... slot 1, bag 1 slot N ... slot 1, ..., bag 4 slot N ... 1
--
-- so "the end of the bag" is the highest bag's slot 1. Blizzard's sort with
-- SetSortBagsRightToLeft(false) packs items from the start of that order
-- and leaves free slots at the end; with it true (One Bag's "Sort from the
-- last slot") items pack from the end and free slots sit at the start. The
-- grey block always goes immediately beside the free region, so the bag
-- reads either
--
--     items ... greys (cheapest -> priciest) ... free
-- or  free ... greys (cheapest -> priciest) ... items
--
-- Moves are plain bag-to-bag swaps via C_Container.PickupContainerItem,
-- one per step, never in combat, never while a vendor or the bank is open.
--
-- Options (account-wide):
--   greySortEnabled   Greys at the end, cheapest first
--   greySortReport    Report moves in chat (sub-option)
--
-- Commands:
--   /mm greysort      run it now
-------------------------------------------------------------------------------

local ADDON, ns = ...

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

local STEP_DELAY    = 0.2    -- seconds between swaps
local LOCK_RETRIES  = 10     -- how many STEP_DELAYs to wait for a locked slot
local MAX_STEPS     = 200    -- hard cap on swaps per run
local AFTER_SORT    = 0.3    -- delay after BAG_UPDATE_DELAYED that follows a sort
local SORT_FALLBACK = 1.5    -- run anyway if no bag update follows a sort

-------------------------------------------------------------------------------
-- Bag reading
-------------------------------------------------------------------------------

local function NumBags()
    if Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumBagSlots then
        return Constants.InventoryConstants.NumBagSlots
    end
    return NUM_BAG_SLOTS or 4
end

local function SellPrice(link)
    if not link or not C_Item or not C_Item.GetItemInfo then return 0 end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(C_Item.GetItemInfo, link)
    if not ok or ns.IsSecret(price) then return 0 end
    return price or 0
end

-- Every bag slot in the combined bag's reading order. Each entry:
--   { bag, slot, info (nil when empty), grey (bool), value, sig }
-- Returns the list and true if any slot is locked (mid-move).
local function ReadBags()
    local list, locked = {}, false
    for bag = 0, NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = slots, 1, -1 do
            local entry = { bag = bag, slot = slot }
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                entry.info = info
                if info.isLocked then locked = true end
                local quality = info.quality
                if ns.IsSecret(quality) then quality = nil end
                if quality == POOR then
                    entry.grey = true
                    local count = info.stackCount or 1
                    if ns.IsSecret(count) then count = 1 end
                    entry.value = (info.hasNoValue and 0 or SellPrice(info.hyperlink)) * count
                    -- Items with the same id and stack size are interchangeable.
                    entry.sig = tostring(info.itemID) .. ":" .. tostring(count)
                end
            end
            list[#list + 1] = entry
        end
    end
    return list, locked
end

-- True when Blizzard's sort leaves free slots at the start of the display.
local function FreeAtStart(list)
    local flag
    if C_Container and C_Container.GetSortBagsRightToLeft then
        local ok, v = pcall(C_Container.GetSortBagsRightToLeft)
        if ok and not ns.IsSecret(v) then flag = v and true or false end
    end
    if flag == nil then flag = ns.db and ns.db.oneBagReverse and true or false end
    -- Sanity check against what the bag actually looks like.
    local leading, trailing = 0, 0
    for i = 1, #list do if list[i].info then break end leading = leading + 1 end
    for i = #list, 1, -1 do if list[i].info then break end trailing = trailing + 1 end
    if flag and trailing > 0 and leading == 0 then flag = false end
    if not flag and leading > 0 and trailing == 0 then flag = true end
    return flag
end

-- The planned layout: for each target position, the grey signature that
-- should sit there (cheapest first in display order). Returns the plan as
-- a list of { index = displayIndex, sig = ... , value = ... } and the greys.
local function Plan(list)
    local greys = {}
    for i, e in ipairs(list) do
        if e.grey then greys[#greys + 1] = e end
    end
    if #greys == 0 then return nil end
    table.sort(greys, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        if a.sig ~= b.sig then return a.sig < b.sig end
        return false
    end)

    local total = #list
    local freeStart = FreeAtStart(list)
    local free = 0
    if freeStart then
        for i = 1, total do if list[i].info then break end free = free + 1 end
    else
        for i = total, 1, -1 do if list[i].info then break end free = free + 1 end
    end

    local plan = {}
    for k, g in ipairs(greys) do
        local index
        if freeStart then
            index = free + k
        else
            index = total - free - #greys + k
        end
        if index >= 1 and index <= total then
            plan[#plan + 1] = { index = index, sig = g.sig, value = g.value }
        end
    end
    return plan, greys
end

-------------------------------------------------------------------------------
-- Moving
-------------------------------------------------------------------------------

local running   = false
local steps     = 0
local moved     = 0
local lockWaits = 0

local function Blocked(force)
    if InCombatLockdown() then
        if force then ns.Print("Grey Sort: not in combat.") end
        return true
    end
    if MerchantFrame and MerchantFrame:IsShown() then
        if force then ns.Print("Grey Sort: close the vendor first.") end
        return true
    end
    if BankFrame and BankFrame:IsShown() then
        if force then ns.Print("Grey Sort: close the bank first.") end
        return true
    end
    if GetCursorInfo and GetCursorInfo() then
        if force then ns.Print("Grey Sort: your cursor is holding something.") end
        return true
    end
    return false
end

local function Finish()
    running = false
    if moved > 0 and ns.db and ns.db.greySortReport then
        ns.Print(("Grey Sort: moved %d item%s."):format(moved, moved == 1 and "" or "s"))
    end
    steps, moved, lockWaits = 0, 0, 0
end

local Step

local function Later(fn)
    C_Timer.After(STEP_DELAY, fn)
end

-- One swap per call: find the first target position whose occupant is not
-- the intended grey, and swap the right grey into it.
Step = function()
    if not running then return end
    if Blocked(false) or steps >= MAX_STEPS then Finish() return end

    local list, locked = ReadBags()
    if locked then
        lockWaits = lockWaits + 1
        if lockWaits > LOCK_RETRIES then Finish() return end
        Later(Step)
        return
    end
    lockWaits = 0

    local plan = Plan(list)
    if not plan then Finish() return end

    for _, p in ipairs(plan) do
        local occupant = list[p.index]
        if not (occupant.grey and occupant.sig == p.sig) then
            -- Find a grey with this signature that is not already sitting
            -- on a satisfied target position.
            local satisfied = {}
            for _, q in ipairs(plan) do
                local o = list[q.index]
                if o.grey and o.sig == q.sig then satisfied[q.index] = true end
            end
            local src
            for i, e in ipairs(list) do
                if e.grey and e.sig == p.sig and not satisfied[i] then src = e break end
            end
            if not src then Finish() return end

            C_Container.PickupContainerItem(src.bag, src.slot)
            C_Container.PickupContainerItem(occupant.bag, occupant.slot)
            if GetCursorInfo and GetCursorInfo() then ClearCursor() end
            steps = steps + 1
            moved = moved + 1
            Later(Step)
            return
        end
    end
    Finish()
end

local function Run(force)
    if not ns.db then return end
    if not force and not ns.db.greySortEnabled then return end
    if running then return end
    if not C_Container or not C_Container.PickupContainerItem or not C_Container.GetContainerItemInfo then
        if force then ns.Print("Grey Sort: container API not available.") end
        return
    end
    if Blocked(force) then return end
    running = true
    steps, moved, lockWaits = 0, 0, 0
    Step()
end

-------------------------------------------------------------------------------
-- Trigger: after any bag sort
-------------------------------------------------------------------------------

local pendingSort = false
local sortSerial  = 0

local function ScheduleAfterSort(delay)
    sortSerial = sortSerial + 1
    local my = sortSerial
    C_Timer.After(delay, function()
        if my ~= sortSerial or not pendingSort then return end
        pendingSort = false
        Run(false)
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:SetScript("OnEvent", function(self, event)
    if event == "BAG_UPDATE_DELAYED" and pendingSort then
        ScheduleAfterSort(AFTER_SORT)
    end
end)

local hooked = false
local function HookSort()
    if hooked then return end
    if not C_Container or not C_Container.SortBags or not hooksecurefunc then return end
    hooksecurefunc(C_Container, "SortBags", function()
        if not ns.db or not ns.db.greySortEnabled then return end
        pendingSort = true
        ScheduleAfterSort(SORT_FALLBACK)
    end)
    hooked = true
end

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "greySortModule",
    label = "Grey Sort",
    group = "Interface",
    options = {
        { key = "greySortEnabled", label = "Greys at the end, cheapest first", default = true,
          tooltip = "After a cleanup, moves grey items next to the free slots, ordered by vendor value." },
        { key = "greySortReport", label = "Report moves in chat", default = true, parent = "greySortEnabled",
          tooltip = "Prints how many items Grey Sort moved." },
    },
    OnInit = function()
        HookSort()
    end,
    commands = {
        greysort = function() Run(true) end,
    },
})
