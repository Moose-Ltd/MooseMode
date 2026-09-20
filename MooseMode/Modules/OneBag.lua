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
--   oneBagReverse      Cleanup fills bags from the last slot (sub-option)
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
        if ns.GreySort and ns.GreySort.IsBusy() then return end
        if MerchantFrame and MerchantFrame:IsShown() then return end
        if BankFrame and BankFrame:IsShown() then return end
        Cleanup(false)
    end)
    hookedCombined = true
end

local function ApplyReverse(enabled)
    if C_Container and C_Container.SetSortBagsRightToLeft then
        pcall(C_Container.SetSortBagsRightToLeft, enabled and true or false)
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- CVars are per character; the option is per account.
        if ns.db then
            ApplyOneBag(ns.db.oneBag and true or false, false)
            ApplyReverse(ns.db.oneBagReverse)
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
    options = {
        { key = "oneBag", label = "Combine bags into one window", default = true,
          tooltip = "Use the client's own combined-bag mode, so clicking, dragging and selling items all keep working. Applied to every character you log in with.",
          onChange = function(checked) ApplyOneBag(checked, true) end },
        { key = "oneBagAutoCleanup", label = "Sort bags on open", default = false, parent = "oneBag",
          tooltip = "Run the bag sort when the combined bag opens. At most once every 10 seconds, never in combat, never at a vendor or the bank." },
        { key = "oneBagReverse", label = "Sort from the last slot", default = false, parent = "oneBag",
          tooltip = "Pack items from the last bag slot backwards, leaving the backpack free.",
          onChange = function(checked) ApplyReverse(checked) end },
    },
    OnInit = function()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then
            ApplyOneBag(ns.db.oneBag and true or false, false)
            ApplyReverse(ns.db.oneBagReverse)
            HookCombinedBags()
        end
    end,
    commands = {
        cleanup = function() Cleanup(true) end,
        sort    = function() Cleanup(true) end,
    },
})
