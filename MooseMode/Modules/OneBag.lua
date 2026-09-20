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
--   (the sort always packs from the top of the combined bag)
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
    -- A plain switch: ticked = combined, unticked = separate bags. (An earlier
    -- version restored the character's previous value on untick, which on a
    -- character that already had combined bags on meant unticking did
    -- nothing.)
    ns.db.oneBagPrevCVar = nil
    local want = enabled and "1" or "0"
    local current = ns.CVar.Get(CVAR)
    if current ~= want then
        ns.CVar.Set(CVAR, want)
        -- Closing and re-opening the bags is enough for the client to re-lay
        -- them out in the new mode; no reload needed.
        RelayoutBags()
        if announce then ns.Print(enabled and "One Bag on." or "One Bag off.") end
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

-- Where the sort packs items. Observed live on Forever's combined bag:
-- SetSortBagsRightToLeft(true) packs items from the TOP-left with no strays;
-- false packs toward the bottom and leaves a stray. So "top" = true,
-- "bottom" = false. The insert-direction setting is left alone.
--
-- Any bag flagged "ignore this bag when sorting" is skipped by the sort and
-- strands whatever is in it; sorting on open only makes sense when no bag is
-- ignored, so the flags are cleared here.
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

-- The sort always packs from the top of the combined bag. On Forever's
-- combined bag that is the right-to-left sort (observed live: it packs from
-- the top-left with no stray items; the other direction packs to the bottom
-- and can strand an item).
local function ApplyPack()
    if C_Container and C_Container.SetSortBagsRightToLeft then
        pcall(C_Container.SetSortBagsRightToLeft, true)
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
            ApplyPack()
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
          tooltip = "Use the client's own combined-bag mode, so clicking, dragging and selling items all keep working. Applied to every character you log in with.",
          onChange = function(checked) ApplyOneBag(checked, true) end },
        { key = "oneBagAutoCleanup", label = "Sort bags on open", default = false, parent = "oneBag",
          tooltip = "Run the bag sort when the combined bag opens. Items pack from the top. At most once every 10 seconds, never in combat, never at a vendor or the bank." },
    },
    OnInit = function()
        local db = ns.db
        -- Stale keys: the old direction options and the removed Grey Sort module.
        db.oneBagReverse, db.oneBagPack = nil, nil
        db.greySortEnabled, db.greySortReport, db.oneBagLastSorted = nil, nil, nil
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then
            ApplyOneBag(db.oneBag and true or false, false)
            ApplyPack()
            HookCombinedBags()
        end
    end,
    commands = {
        cleanup = function() Cleanup(true) end,
        sort    = function() Cleanup(true) end,
    },
})
