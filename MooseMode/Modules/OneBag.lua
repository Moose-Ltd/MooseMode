-------------------------------------------------------------------------------
-- MooseMode -- OneBag
--
-- Shows every bag as a single window, Bagnon/Baganator style. Forever runs
-- the Retail client, which already ships a combined-bag mode behind the
-- "combinedBags" CVar. Driving that CVar (instead of building our own bag
-- frame) keeps every item click, drag, shift-link, right-click, vendor sell
-- and in-combat use on Blizzard's secure item buttons, and Blizzard's own
-- sort keeps working.
--
-- The CVar is per character; the option is per account, so the CVar is
-- re-applied at every login to match the option.
--
-- Options (account-wide):
--   oneBag             One bag: show all bags as a single window
--   oneBagAutoCleanup  Auto cleanup when the bag opens (sub-option)
--   oneBagPack         Pack items: "top" (default) or "bottom" (sub-option)
--
-- Commands:
--   /mm cleanup        sort bags now (alias: /mm sort)
-------------------------------------------------------------------------------

local ADDON, ns = ...

local CVAR = "combinedBags"
local CLEANUP_DEBOUNCE = 10  -- seconds between automatic sorts

local function AnyBagOpen()
    if IsAnyBagOpen then
        local ok, open = pcall(IsAnyBagOpen)
        if ok then return open and true or false end
    end
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then return true end
    if ContainerFrame1 and ContainerFrame1:IsShown() then return true end
    return false
end

-- Close and re-open the bags so Blizzard's container code re-lays them out
-- for the new mode. Re-opening happens on the next frame.
local function RelayoutBags()
    if InCombatLockdown() then return end
    local wasOpen = AnyBagOpen()
    if CloseAllBags then pcall(CloseAllBags) end
    if wasOpen and OpenAllBags then
        C_Timer.After(0, function()
            if not InCombatLockdown() then pcall(OpenAllBags) end
        end)
    end
end

-- Make the client's CVar match the account-wide option. The character's own
-- value is remembered in db.oneBagPrevCVar and put back exactly on disable.
local function ApplyOneBag(enabled, announce)
    if not ns.db then return end
    if not ns.CVar.Exists(CVAR) then
        if announce then
            ns.Print("This client has no combined-bag mode (CVar '" .. CVAR .. "' missing); One bag cannot be applied.")
        end
        return
    end
    if ns.CVar.ApplyWithSnapshot(CVAR, "1", "oneBagPrevCVar", enabled) then
        RelayoutBags()
        -- The client only rebuilds its bag frames for the new mode on a UI
        -- reload; closing them above avoids a half-switched window meanwhile.
        if announce then ns.Print("One Bag: the bag layout changes after /reload.") end
    end
end

-------------------------------------------------------------------------------
-- Cleanup (Blizzard sort)
-------------------------------------------------------------------------------

local lastCleanup = 0

local function Cleanup(force)
    if not C_Container or not C_Container.SortBags then
        if force then ns.Print("Bag sorting is not available on this client.") end
        return false
    end
    if InCombatLockdown() then
        if force then ns.Print("Cannot sort bags in combat.") end
        return false
    end
    local now = GetTime()
    if not force and (now - lastCleanup) < CLEANUP_DEBOUNCE then return false end
    lastCleanup = now
    pcall(C_Container.SortBags)
    return true
end

local hookedCombined = false

local function HookCombinedBags()
    if hookedCombined then return end
    if not ContainerFrameCombinedBags or not ContainerFrameCombinedBags.HookScript then return end
    ContainerFrameCombinedBags:HookScript("OnShow", function()
        if not (ns.db and ns.db.oneBag and ns.db.oneBagAutoCleanup) then return end
        -- Never sort over a Grey Sort pass (the two would interleave), and
        -- never when the bag opened for a vendor or the bank (Auto Sell may
        -- be selling, and Blizzard's own bank sort is a different thing).
        if MerchantFrame and MerchantFrame:IsShown() then return end
        if BankFrame and BankFrame:IsShown() then return end
        Cleanup(false)
    end)
    hookedCombined = true
end

-- Where the sort packs items. The combined bag displays the backpack first
-- (top rows) and the last bag at the bottom, and Blizzard's sort packs bags
-- left to right (backpack first) unless SetSortBagsRightToLeft(true). So
-- "top" = false (backpack first), "bottom" = true. New items follow the same
-- direction via SetInsertItemsLeftToRight.
--
-- Both directions looked bottom-packed on a live bag because the backpack
-- carried the "ignore this bag when sorting" flag, which makes the sort skip
-- it entirely and strands whatever is in it. Sorting on open only makes sense
-- when no bag is ignored, so the flags are cleared here.
local warnedIgnored = false
local function ClearIgnoreFlags()
    if not C_Container then return end
    local wasIgnored = false
    if C_Container.GetBackpackAutosortDisabled and C_Container.SetBackpackAutosortDisabled then
        local ok, disabled = pcall(C_Container.GetBackpackAutosortDisabled)
        if ok and disabled and not ns.IsSecret(disabled) then
            wasIgnored = true
            pcall(C_Container.SetBackpackAutosortDisabled, false)
        end
    end
    local flag = Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort
    if flag and C_Container.GetBagSlotFlag and C_Container.SetBagSlotFlag then
        for bag = 1, ns.NumBags() do
            local ok, set = pcall(C_Container.GetBagSlotFlag, bag, flag)
            if ok and set and not ns.IsSecret(set) then
                wasIgnored = true
                pcall(C_Container.SetBagSlotFlag, bag, flag, false)
            end
        end
    end
    if wasIgnored and not warnedIgnored then
        warnedIgnored = true
        ns.Print("One Bag: a bag was set to be ignored by sorting; cleared so the sort covers every bag.")
    end
end

local function ApplyPack(pack)
    local bottom = (pack == "bottom")
    if C_Container and C_Container.SetSortBagsRightToLeft then
        pcall(C_Container.SetSortBagsRightToLeft, bottom)
    end
    if C_Container and C_Container.SetInsertItemsLeftToRight then
        pcall(C_Container.SetInsertItemsLeftToRight, not bottom)
    end
    ClearIgnoreFlags()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- CVars are per character; the option is per account. While a late
        -- settings restore is still pending, ns.db holds defaults, so wait:
        -- Core re-runs OnInit (reinitSafe) once the real values land.
        if ns.db and not (ns.SettingsRestorePending and ns.SettingsRestorePending()) then
            ApplyOneBag(ns.db.oneBag and true or false, false)
            ApplyPack(ns.db.oneBagPack)
        end
        HookCombinedBags()
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "oneBagModule",
    label = "One Bag",
    group = "Interface",
    reinitSafe = true,   -- OnInit only applies state from ns.db; safe to run again after a late restore
    options = {
        { key = "oneBag", label = "Combine bags into one window", default = true,
          tooltip = "Use the client's own combined-bag mode, so clicking, dragging and selling items all keep working. Applied to every character you log in with. The bag layout changes after /reload.",
          onChange = function(checked) ApplyOneBag(checked, true) end },
        { key = "oneBagAutoCleanup", label = "Sort bags on open", default = false, parent = "oneBag",
          tooltip = "Run the bag sort when the combined bag opens. At most once every 10 seconds, never in combat, never at a vendor or the bank." },
        { key = "oneBagPack", type = "choice", label = "Pack items", default = "top", parent = "oneBag",
          values = { { value = "top", text = "Top" }, { value = "bottom", text = "Bottom" } },
          tooltip = "Where the sort packs items in the combined bag. Top fills from the top-left and leaves free slots at the bottom.",
          onChange = function(value) ApplyPack(value) end },
    },
    OnInit = function()
        local db = ns.db
        -- One-time migration from the old "Sort from the last slot" tick,
        -- which (when on) produced the top-left packing.
        if db.oneBagReverse ~= nil then
            db.oneBagPack = db.oneBagReverse and "top" or "bottom"
            db.oneBagReverse = nil
        end
        if db.oneBagPack ~= "top" and db.oneBagPack ~= "bottom" then db.oneBagPack = "top" end
        -- Stale keys from the removed Grey Sort module.
        db.greySortEnabled, db.greySortReport, db.oneBagLastSorted = nil, nil, nil
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then
            ApplyOneBag(db.oneBag and true or false, false)
            ApplyPack(db.oneBagPack)
            HookCombinedBags()
        end
    end,
    commands = {
        cleanup = function() Cleanup(true) end,
        sort    = function() Cleanup(true) end,
    },
})
