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
local CLEANUP_DEBOUNCE = 2   -- seconds between automatic sorts

-------------------------------------------------------------------------------
-- CVar helpers
-------------------------------------------------------------------------------

local function CVarExists()
    local getInfo = (C_CVar and C_CVar.GetCVarInfo) or GetCVarInfo
    if not getInfo then return false end
    local ok, value = pcall(getInfo, CVAR)
    return ok and value ~= nil
end

local function GetCombined()
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, value = pcall(get, CVAR)
    if not ok then return nil end
    return value
end

local function SetCombined(value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not set then return false end
    local ok = pcall(set, CVAR, value)
    return ok
end

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

-- Make the client's CVar match the account-wide option.
local function ApplyOneBag(enabled, announce)
    local db = ns.db
    if not db then return end
    if not CVarExists() then
        if announce then
            ns.Print("This client has no combined-bag mode (CVar '" .. CVAR .. "' missing); One bag cannot be applied.")
        end
        return
    end

    local current = GetCombined()
    if enabled then
        if db.oneBagPrevCVar == nil and current ~= nil and current ~= "1" then
            db.oneBagPrevCVar = current
        end
        if current ~= "1" then
            SetCombined("1")
            RelayoutBags()
        end
    else
        local restore = db.oneBagPrevCVar or "0"
        db.oneBagPrevCVar = nil
        if current ~= restore then
            SetCombined(restore)
            RelayoutBags()
        end
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
        if ns.db and ns.db.oneBag and ns.db.oneBagAutoCleanup then
            Cleanup(false)
        end
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
    options = {
        { key = "oneBag", label = "One bag: show all bags as a single window", default = true,
          tooltip = "Uses the client's own combined-bag mode, so clicking, dragging and selling items all keep working. Applied to every character you log in with.",
          onChange = function(checked) ApplyOneBag(checked, true) end },
        { key = "oneBagAutoCleanup", label = "Auto cleanup when the bag opens", default = false, parent = "oneBag",
          tooltip = "Runs Blizzard's bag sort each time the combined bag opens (at most once every 2 seconds, never in combat)." },
        { key = "oneBagReverse", label = "Cleanup fills bags from the last slot", default = false, parent = "oneBag",
          tooltip = "Blizzard's reverse sort: items are packed from the last bag slot backwards, leaving the backpack free.",
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
