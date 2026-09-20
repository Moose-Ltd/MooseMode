-------------------------------------------------------------------------------
-- MooseMode -- Graphics
--
-- A camera zoom-out beyond the settings slider, and an optional vivid-colour
-- tweak. Everything is a CVar write; nothing here touches gameplay.
--
-- The camera zoom factor is per character, so it is re-applied at every
-- login to match the account-wide option (same pattern as OneBag).
--
-- Options (account-wide):
--   graphicsMaxCamera     Max camera zoom distance
--   graphicsVivid         Vivid colours
--
-- An earlier version shipped an "ultra" graphics preset. It was removed; the
-- one-time migration in OnInit puts back the snapshot that preset saved, so
-- anyone who applied it gets their previous settings again.
-------------------------------------------------------------------------------

local ADDON, ns = ...

-- CVar access goes through ns.CVar (Core); previous values are remembered
-- per option by ns.CVar.ApplyWithSnapshot and restored exactly on untick.

-------------------------------------------------------------------------------
-- Camera zoom
-------------------------------------------------------------------------------

local CAMERA_CVAR = "cameraDistanceMaxZoomFactor"
local CAMERA_MAX  = "2.6"

local function ApplyCamera(enabled, announce)
    if not ns.db then return end
    if not ns.CVar.Exists(CAMERA_CVAR) then
        if announce then ns.Print("This client has no '" .. CAMERA_CVAR .. "' setting.") end
        return
    end
    ns.CVar.ApplyWithSnapshot(CAMERA_CVAR, CAMERA_MAX, "graphicsPrevCamera", enabled)
end

-------------------------------------------------------------------------------
-- Vivid colours
-------------------------------------------------------------------------------

-- Vivid sets contrast to a fixed value; untick puts back what the player had.
local VIVID_CVAR  = "Contrast"
local VIVID_VALUE = "75"

local vividWarned = false

local function ApplyVivid(enabled, announce)
    if not ns.db then return end
    if not ns.CVar.Exists(VIVID_CVAR) then
        if announce and not vividWarned then
            vividWarned = true
            ns.Print("This client has no Contrast setting; Vivid colours cannot be applied.")
        end
        return
    end
    ns.CVar.ApplyWithSnapshot(VIVID_CVAR, VIVID_VALUE, "graphicsPrevContrast", enabled)
end

-------------------------------------------------------------------------------
-- Migration: undo the removed ultra preset
--
-- The preset saved a snapshot of every CVar it changed in db.graphicsPrev.
-- If one is present, write it back once and clear the stale keys.
-------------------------------------------------------------------------------

local function MigrateUltra()
    local db = ns.db
    if not db then return end
    local snapshot = db.graphicsPrev
    local restored = 0
    if type(snapshot) == "table" and next(snapshot) ~= nil then
        for name, value in pairs(snapshot) do
            if ns.CVar.Exists(name) and ns.CVar.Set(name, value) then
                restored = restored + 1
            end
        end
    end
    db.graphicsPrev = nil
    db.graphicsKeepUltra = nil
    -- Older builds kept the vivid snapshot as a one-entry table.
    if type(db.graphicsPrevVivid) == "table" then
        if db.graphicsPrevContrast == nil then
            db.graphicsPrevContrast = db.graphicsPrevVivid[VIVID_CVAR]
        end
        db.graphicsPrevVivid = nil
    end
    if restored > 0 then
        ns.Print("Graphics: the ultra preset was removed; your previous graphics settings have been restored (anti-aliasing changes need a restart).")
    end
end

-------------------------------------------------------------------------------
-- Login enforcement
-------------------------------------------------------------------------------

local function ApplyAtLogin()
    local db = ns.db
    if not db then return end
    ApplyCamera(db.graphicsMaxCamera and true or false, false)
    if db.graphicsVivid then ApplyVivid(true, false) end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    -- While a late settings restore is pending, ns.db holds defaults: wait
    -- for Core to re-run OnInit (reinitSafe) on the real values.
    if event == "PLAYER_LOGIN" and not (ns.SettingsRestorePending and ns.SettingsRestorePending()) then
        ApplyAtLogin()
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "graphicsModule",
    label = "Graphics",
    group = "Interface",
    reinitSafe = true,   -- OnInit only migrates once and applies state from ns.db; safe to run again after a late restore
    options = {
        { key = "graphicsMaxCamera", label = "Max camera zoom distance", default = true,
          tooltip = "Lets you zoom the camera out further than the settings slider allows. Applied on every character.",
          onChange = function(checked) ApplyCamera(checked, true) end },
        { key = "graphicsVivid", label = "Vivid colours", default = false,
          tooltip = "Sets contrast to 75. Untick to return to your previous value.",
          onChange = function(checked) ApplyVivid(checked, true) end },
    },
    OnInit = function()
        MigrateUltra()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then ApplyAtLogin() end
    end,
})
