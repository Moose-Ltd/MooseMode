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

-------------------------------------------------------------------------------
-- CVar helpers (pcall-wrapped, C_CVar first, globals as fallback)
-------------------------------------------------------------------------------

local function CVarExists(name)
    local getInfo = (C_CVar and C_CVar.GetCVarInfo) or GetCVarInfo
    if not getInfo then return false end
    local ok, value = pcall(getInfo, name)
    return ok and value ~= nil
end

local function GetVar(name)
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, value = pcall(get, name)
    if not ok then return nil end
    return value
end

local function SetVar(name, value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not set then return false end
    local ok = pcall(set, name, tostring(value))
    return ok
end

-------------------------------------------------------------------------------
-- Camera zoom
-------------------------------------------------------------------------------

local CAMERA_CVAR = "cameraDistanceMaxZoomFactor"
local CAMERA_MAX  = "2.6"

local function ApplyCamera(enabled, announce)
    local db = ns.db
    if not db then return end
    if not CVarExists(CAMERA_CVAR) then
        if announce then ns.Print("This client has no '" .. CAMERA_CVAR .. "' setting.") end
        return
    end
    local current = GetVar(CAMERA_CVAR)
    if enabled then
        if db.graphicsPrevCamera == nil and current ~= nil and current ~= CAMERA_MAX then
            db.graphicsPrevCamera = current
        end
        if current ~= CAMERA_MAX then SetVar(CAMERA_CVAR, CAMERA_MAX) end
    else
        local restore = db.graphicsPrevCamera or "1.9"
        db.graphicsPrevCamera = nil
        if current ~= restore then SetVar(CAMERA_CVAR, restore) end
    end
end

-------------------------------------------------------------------------------
-- Vivid colours
-------------------------------------------------------------------------------

-- Vivid sets contrast to a fixed value; untick puts back what the player had.
local VIVID_CVAR  = "Contrast"
local VIVID_VALUE = "75"

local vividWarned = false

local function ApplyVivid(enabled, announce)
    local db = ns.db
    if not db then return end
    if not CVarExists(VIVID_CVAR) then
        if announce and not vividWarned then
            vividWarned = true
            ns.Print("This client has no Contrast setting; Vivid colours cannot be applied.")
        end
        return
    end

    local current = GetVar(VIVID_CVAR)
    if enabled then
        -- Snapshot first so untick is always symmetric.
        if db.graphicsPrevVivid == nil and current ~= nil then
            db.graphicsPrevVivid = { [VIVID_CVAR] = current }
        end
        if current ~= VIVID_VALUE then SetVar(VIVID_CVAR, VIVID_VALUE) end
    else
        local prev = db.graphicsPrevVivid
        db.graphicsPrevVivid = nil
        if prev and prev[VIVID_CVAR] ~= nil and current ~= prev[VIVID_CVAR] then
            SetVar(VIVID_CVAR, prev[VIVID_CVAR])
        end
    end
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
            if CVarExists(name) and SetVar(name, value) then
                restored = restored + 1
            end
        end
    end
    db.graphicsPrev = nil
    db.graphicsKeepUltra = nil
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
    if event == "PLAYER_LOGIN" then ApplyAtLogin() end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "graphicsModule",
    label = "Graphics",
    group = "Interface",
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
