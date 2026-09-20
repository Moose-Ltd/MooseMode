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
    for bag = 0, ns.NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        -- Special containers (quiver, ammo pouch, soul bag, profession bags)
        -- cannot hold greys, so they are neither sources nor targets and take
        -- no part in the display order used for planning.
        if slots > 0 and C_Container.GetContainerNumFreeSlots then
            local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
            if ok and type(family) == "number" and family ~= 0 then slots = 0 end
        end
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
                    entry.count = count
                    -- Items with the same id and stack size are interchangeable.
                    entry.sig = tostring(info.itemID) .. ":" .. tostring(count)
                end
            end
            list[#list + 1] = entry
        end
    end
    return list, locked
end

-- Position-independent content fingerprint of every bag: one entry per
-- occupied slot ("itemID:stackCount", locked slots included), sorted and
-- joined, then reduced to a short hash so it stays cheap to store in the
-- settings backup. Returns the fingerprint and true if any slot is locked.
local function Fingerprint()
    local parts, locked = {}, false
    for bag = 0, ns.NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                if info.isLocked then locked = true end
                local count = info.stackCount or 1
                if ns.IsSecret(count) then count = 1 end
                parts[#parts + 1] = tostring(info.itemID) .. ":" .. tostring(count)
            end
        end
    end
    table.sort(parts)
    local joined = table.concat(parts, ",")
    local h = 5381
    for i = 1, #joined do
        h = (h * 33 + joined:byte(i)) % 2147483647
    end
    return tostring(#parts) .. "-" .. tostring(h), locked
end

-- Read a single slot into the same entry shape ReadBags produces.
local function ReadSlot(bag, slot)
    local entry = { bag = bag, slot = slot }
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info and info.itemID then
        entry.info = info
        local quality = info.quality
        if ns.IsSecret(quality) then quality = nil end
        if quality == POOR then
            entry.grey = true
            local count = info.stackCount or 1
            if ns.IsSecret(count) then count = 1 end
            entry.value = (info.hasNoValue and 0 or SellPrice(info.hyperlink)) * count
            entry.count = count
            entry.sig = tostring(info.itemID) .. ":" .. tostring(count)
        end
    end
    return entry
end

-- Where Blizzard's sort leaves the free slots: true = at the start of the
-- display (reverse fill), false = at the end. Returns nil when the bag's
-- actual layout contradicts the sort direction, in which case the caller
-- must not guess.
local function FreeAtStart(list)
    local flag
    if C_Container and C_Container.GetSortBagsRightToLeft then
        local ok, v = pcall(C_Container.GetSortBagsRightToLeft)
        if ok and not ns.IsSecret(v) then flag = v and true or false end
    end
    if flag == nil then flag = ns.db and ns.db.oneBagReverse and true or false end
    local leading, trailing = 0, 0
    for i = 1, #list do if list[i].info then break end leading = leading + 1 end
    for i = #list, 1, -1 do if list[i].info then break end trailing = trailing + 1 end
    -- Reverse fill should leave empties at the start; forward fill at the
    -- end. Empties only on the wrong side means the sort has not run the way
    -- the flag says (or something moved things since), so refuse to plan.
    if flag and leading == 0 and trailing > 0 then return nil end
    if not flag and trailing == 0 and leading > 0 then return nil end
    return flag
end

-- The planned layout: for each target position, the grey signature that
-- should sit there (cheapest first in display order). Returns the plan as
-- a list of { index = displayIndex, sig = ... , value = ... } and the greys,
-- or nil when there is nothing to do, or false when the layout contradicts
-- the sort direction.
local function Plan(list)
    local greys = {}
    for i, e in ipairs(list) do
        if e.grey then greys[#greys + 1] = e end
    end
    if #greys == 0 then return nil end
    -- Fully deterministic: value, then item id, then stack size, all
    -- ascending, so two passes over the same contents agree on every slot
    -- and equal-value greys never trade places.
    table.sort(greys, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        local ai, bi = a.info.itemID or 0, b.info.itemID or 0
        if ai ~= bi then return ai < bi end
        if a.count ~= b.count then return (a.count or 0) < (b.count or 0) end
        return false
    end)

    local total = #list
    local freeStart = FreeAtStart(list)
    if freeStart == nil then return false end
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

local running    = false
local runSerial  = 0     -- bumped on cancel so stale step timers do nothing
local plan       = nil   -- computed once per pass
local snapshot   = nil   -- display list the plan was made from, kept current
local steps      = 0
local moved      = 0
local lockWaits  = 0
local lastMove   = nil   -- { srcIndex, dstIndex, itemID } of the last swap
local noops      = 0     -- consecutive swaps the client refused
local MAX_NOOPS  = 3
local warnedLayout = false

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

local function ResetState()
    running = false
    plan, snapshot = nil, nil
    steps, moved, lockWaits, lastMove, noops = 0, 0, 0, nil, 0
end

-- After a cleanup has fully finished, remember what the bag held so One Bag
-- does not sort it again on the next open unless the contents changed.
local function RecordCleanup()
    if not ns.db then return end
    local fp, locked = Fingerprint()
    if locked then return end
    if ns.db.oneBagLastSorted ~= fp then
        ns.db.oneBagLastSorted = fp
        if ns.SaveSettings then ns.SaveSettings() end
    end
end

-- `complete` is true when the pass ended because there was nothing left to
-- do (every grey in place, or nothing to move); a pass cut short by combat,
-- a vendor, a step cap or refused swaps does not count as a cleanup.
local function Finish(complete)
    if moved > 0 and ns.db and ns.db.greySortReport then
        ns.Print(("Grey Sort: moved %d item%s."):format(moved, moved == 1 and "" or "s"))
    end
    ResetState()
    if complete then RecordCleanup() end
end

-- Stop a running pass dead: pending step timers are invalidated by the
-- serial bump, anything on the cursor goes back, and no summary is printed.
local function Cancel()
    runSerial = runSerial + 1
    if running and GetCursorInfo and GetCursorInfo() and ClearCursor then ClearCursor() end
    ResetState()
end

local Step

-- Run fn after STEP_DELAY unless the pass was cancelled in the meantime.
local function Later(fn)
    local my = runSerial
    C_Timer.After(STEP_DELAY, function()
        if my == runSerial and running then fn() end
    end)
end

-- Make the plan from a fresh read. Returns true when a plan exists.
local function MakePlan()
    local list, locked = ReadBags()
    if locked then return nil, true end
    local p = Plan(list)
    if p == false then
        if not warnedLayout then
            warnedLayout = true
            ns.Print("Grey Sort: bag layout does not match the sort direction, skipped.")
        end
        return false
    end
    if not p then return false end
    plan, snapshot = p, list
    return true
end

-- One swap per call. The plan is fixed for the pass; only the two slots of
-- the previous swap are re-read to confirm it, and a full re-plan happens
-- only when that confirmation fails.
Step = function()
    if not running then return end
    if Blocked(false) or steps >= MAX_STEPS then Finish() return end

    if lastMove then
        local src = ReadSlot(snapshot[lastMove.srcIndex].bag, snapshot[lastMove.srcIndex].slot)
        local dst = ReadSlot(snapshot[lastMove.dstIndex].bag, snapshot[lastMove.dstIndex].slot)
        if (src.info and src.info.isLocked) or (dst.info and dst.info.isLocked) then
            lockWaits = lockWaits + 1
            if lockWaits > LOCK_RETRIES then Finish() return end
            Later(Step)
            return
        end
        lockWaits = 0
        local landed = dst.info and dst.info.itemID == lastMove.itemID
        lastMove = nil
        if landed then
            noops = 0
            moved = moved + 1
        else
            -- The client refused the swap or something else moved things.
            noops = noops + 1
            if noops >= MAX_NOOPS then Finish() return end
            local ok, locked = MakePlan()
            if locked then Later(Step) return end
            if not ok then Finish(true) return end
        end
        if landed then
            -- Keep the snapshot current without a full read.
            for i, e in ipairs(snapshot) do
                if e.bag == src.bag and e.slot == src.slot then snapshot[i] = src end
                if e.bag == dst.bag and e.slot == dst.slot then snapshot[i] = dst end
            end
        end
    end

    if not plan then Finish(true) return end

    for _, p in ipairs(plan) do
        local occupant = snapshot[p.index]
        if not (occupant.grey and occupant.sig == p.sig) then
            -- A grey with this signature that is not already sitting on a
            -- satisfied target position.
            local satisfied = {}
            for _, q in ipairs(plan) do
                local o = snapshot[q.index]
                if o.grey and o.sig == q.sig then satisfied[q.index] = true end
            end
            local srcIndex
            for i, e in ipairs(snapshot) do
                if e.grey and e.sig == p.sig and not satisfied[i] then srcIndex = i break end
            end
            if not srcIndex then Finish() return end
            local src = snapshot[srcIndex]

            lastMove = { srcIndex = srcIndex, dstIndex = p.index, itemID = src.info.itemID }
            C_Container.PickupContainerItem(src.bag, src.slot)
            C_Container.PickupContainerItem(occupant.bag, occupant.slot)
            if GetCursorInfo and GetCursorInfo() then ClearCursor() end
            steps = steps + 1
            Later(Step)
            return
        end
    end
    Finish(true)
end

-- Start a pass from a settled bag. A pass already running is cancelled so
-- two never interleave.
local function Run(force)
    if not ns.db then return end
    if not force and not ns.db.greySortEnabled then return end
    if running then Cancel() end
    if not C_Container or not C_Container.PickupContainerItem or not C_Container.GetContainerItemInfo then
        if force then ns.Print("Grey Sort: container API not available.") end
        return
    end
    if Blocked(force) then return end
    runSerial = runSerial + 1
    running = true
    steps, moved, lockWaits, lastMove, noops = 0, 0, 0, nil, 0

    local waits = 0
    local function start()
        if not running then return end
        local ok, locked = MakePlan()
        if locked then
            waits = waits + 1
            if waits > LOCK_RETRIES then ResetState() return end
            Later(start)
            return
        end
        if not ok then
            -- Nothing to move, or the layout contradicts the sort direction:
            -- either way the cleanup is over for this bag content.
            ResetState()
            RecordCleanup()
            return
        end
        Step()
    end
    start()
end

-- True when every grey already sits on its planned position (or there are
-- no greys), false when a pass would move something or the layout cannot
-- be planned. Read-only; nothing is moved.
local function IsTidy()
    if not ns.db or not C_Container or not C_Container.GetContainerItemInfo then return true end
    local list, locked = ReadBags()
    if locked then return false end
    local p = Plan(list)
    if p == nil then return true end
    if p == false then return false end
    for _, q in ipairs(p) do
        local o = list[q.index]
        if not (o.grey and o.sig == q.sig) then return false end
    end
    return true
end

ns.GreySort = {
    IsBusy = function() return running end,
    Cancel = Cancel,
    IsTidy = IsTidy,
}

-------------------------------------------------------------------------------
-- Trigger: after any bag sort
-------------------------------------------------------------------------------

local pendingSort = false
local sortSerial  = 0

-- Each BAG_UPDATE_DELAYED while a sort is pending pushes the start back, so
-- the pass begins AFTER_SORT seconds after the last update: a settled bag.
local function ScheduleAfterSort(delay)
    sortSerial = sortSerial + 1
    local my = sortSerial
    C_Timer.After(delay, function()
        if my ~= sortSerial or not pendingSort then return end
        pendingSort = false
        Run(false)
    end)
end

-- A new sort (Blizzard's, One Bag's, or the bag being re-shown) while a
-- pass is running: drop the pass and start over once the bag settles.
local function RestartAfterSort()
    if not ns.db or not ns.db.greySortEnabled then return end
    if running then Cancel() end
    pendingSort = true
    ScheduleAfterSort(SORT_FALLBACK)
end

-- Shared "wait until the bag settles" helper: fn runs AFTER_SORT seconds
-- after the last BAG_UPDATE_DELAYED, or SORT_FALLBACK seconds after the call
-- if no update arrives at all.
local settleWaiters = {}

local function Settle(fn)
    local w = { fn = fn, serial = 0 }
    function w.arm(delay)
        w.serial = w.serial + 1
        local my = w.serial
        C_Timer.After(delay, function()
            if my ~= w.serial or w.done then return end
            w.done = true
            for i, x in ipairs(settleWaiters) do
                if x == w then table.remove(settleWaiters, i) break end
            end
            fn()
        end)
    end
    settleWaiters[#settleWaiters + 1] = w
    w.arm(SORT_FALLBACK)
end

ns.Bags = {
    Fingerprint = Fingerprint,
    Settle      = Settle,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:SetScript("OnEvent", function(self, event)
    if event ~= "BAG_UPDATE_DELAYED" then return end
    if pendingSort then ScheduleAfterSort(AFTER_SORT) end
    for _, w in ipairs(settleWaiters) do w.arm(AFTER_SORT) end
end)

local hooked, hookedShow = false, false
local function HookSort()
    if not hooked and C_Container and C_Container.SortBags and hooksecurefunc then
        hooksecurefunc(C_Container, "SortBags", RestartAfterSort)
        hooked = true
    end
    if not hookedShow and ContainerFrameCombinedBags and ContainerFrameCombinedBags.HookScript then
        ContainerFrameCombinedBags:HookScript("OnShow", function()
            -- Re-shown mid-pass: Blizzard may lay the bag out again, and One
            -- Bag may sort it; start over from a settled state.
            if running then RestartAfterSort() end
        end)
        hookedShow = true
    end
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
        -- The combined bag frame may not exist until Blizzard's UI is up.
        local f = CreateFrame("Frame")
        ns.SafeRegisterEvent(f, "PLAYER_LOGIN")
        ns.SafeRegisterEvent(f, "PLAYER_ENTERING_WORLD")
        f:SetScript("OnEvent", HookSort)
    end,
    commands = {
        greysort = function() Run(true) end,
    },
})
