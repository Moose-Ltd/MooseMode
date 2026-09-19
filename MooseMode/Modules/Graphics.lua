-------------------------------------------------------------------------------
-- MooseMode -- Graphics
--
-- One-click "ultra" graphics preset, a camera zoom-out beyond the settings
-- slider, and an optional vivid-colour tweak. Everything is a CVar write;
-- nothing here touches gameplay.
--
-- The ultra preset snapshots every value it is about to change the first
-- time it runs, so Restore can put the client back exactly as it was.
--
-- Graphics CVars are account-wide client settings; the camera zoom factor
-- is per character, so it is re-applied at every login to match the
-- account-wide option (same pattern as OneBag).
--
-- Options (account-wide):
--   (button)              Ultra graphics preset: Apply / Restore
--   graphicsKeepUltra     Re-apply ultra at login
--   graphicsMaxCamera     Max camera zoom distance
--   graphicsVivid         Vivid colours
--
-- Commands:
--   /mm ultra             apply the preset now
--   /mm ultra restore     put the snapshot back
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
-- Ultra preset
--
-- Names and maxima follow the Retail 12.x settings page, cross-checked
-- against the CVars this client writes to Config.wtf. Anything the client
-- does not know is skipped silently.
-------------------------------------------------------------------------------

local RESTART_REQUIRED = {
    MSAAQuality = true,
    ffxAntiAliasingMode = true,
    graphicsTextureResolution = true,
    raidGraphicsTextureResolution = true,
}

-- Per-slider maxima, applied to both the normal and the "raid" profile.
local SLIDERS = {
    ViewDistance       = 10,
    EnvironmentDetail  = 10,
    GroundClutter      = 10,
    ShadowQuality      = 5,
    LiquidDetail       = 3,
    PBRLiquidDetail    = 2,
    Sunshafts          = 2,
    ParticleDensity    = 5,
    SSAO               = 4,
    DepthEffects       = 3,
    ComputeEffects     = 4,
    OutlineMode        = 2,
    TextureResolution  = 2,
    SpellDensity       = 5,
    ProjectedTextures  = 1,
    TextureFiltering   = 5,
    PhysicsInteraction = 2,
    LightMode          = 2,
}

-- Settings without a raid twin.
local SINGLES = {
    MSAAQuality         = 3,
    ffxAntiAliasingMode = 3,
    ffxGlow             = 1,
    weatherDensity      = 3,
    renderScale         = 1,
}

local function BuildPreset()
    local preset = {}
    for name, value in pairs(SLIDERS) do
        preset["graphics" .. name] = value
        preset["raidGraphics" .. name] = value
    end
    for name, value in pairs(SINGLES) do
        preset[name] = value
    end
    return preset
end

local PRESET = BuildPreset()

local function ApplyUltra(announce)
    local db = ns.db
    if not db then return end
    if InCombatLockdown() then
        if announce then ns.Print("Cannot change graphics settings in combat.") end
        return
    end

    local snapshot = db.graphicsPrev
    local takeSnapshot = (snapshot == nil)
    if takeSnapshot then snapshot = {} end

    local set, changed, restart = 0, 0, false
    for name, value in pairs(PRESET) do
        if CVarExists(name) then
            local current = GetVar(name)
            if takeSnapshot and current ~= nil then snapshot[name] = current end
            if SetVar(name, value) then
                set = set + 1
                if tostring(current) ~= tostring(value) then
                    changed = changed + 1
                    if RESTART_REQUIRED[name] then restart = true end
                end
            end
        end
    end
    if takeSnapshot then db.graphicsPrev = snapshot end

    if announce then
        if set == 0 then
            ns.Print("No graphics settings could be applied on this client.")
        else
            ns.Print(("Ultra preset applied: %d settings set, %d changed."):format(set, changed))
            if restart then
                ns.Print("Anti-aliasing and texture resolution take effect after restarting the game.")
            end
        end
    end
end

local function RestoreUltra()
    local db = ns.db
    if not db then return end
    if InCombatLockdown() then
        ns.Print("Cannot change graphics settings in combat.")
        return
    end
    local snapshot = db.graphicsPrev
    if not snapshot then
        ns.Print("Nothing to restore; the ultra preset has not been applied.")
        return
    end
    local n, restart = 0, false
    for name, value in pairs(snapshot) do
        if CVarExists(name) and SetVar(name, value) then
            n = n + 1
            if RESTART_REQUIRED[name] then restart = true end
        end
    end
    db.graphicsPrev = nil
    ns.Print(("Graphics settings restored: %d values put back."):format(n))
    if restart then
        ns.Print("Anti-aliasing and texture resolution take effect after restarting the game.")
    end
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

local VIVID = {
    Contrast = "60",
}

local vividWarned = false

local function ApplyVivid(enabled, announce)
    local db = ns.db
    if not db then return end
    local any = false
    for name in pairs(VIVID) do
        if CVarExists(name) then any = true end
    end
    if not any then
        if announce and not vividWarned then
            vividWarned = true
            ns.Print("This client has no Contrast setting; Vivid colours cannot be applied.")
        end
        return
    end

    if enabled then
        if db.graphicsPrevVivid == nil then
            local prev = {}
            for name in pairs(VIVID) do
                if CVarExists(name) then prev[name] = GetVar(name) end
            end
            db.graphicsPrevVivid = prev
        end
        for name, value in pairs(VIVID) do
            if CVarExists(name) and GetVar(name) ~= value then SetVar(name, value) end
        end
    else
        local prev = db.graphicsPrevVivid
        db.graphicsPrevVivid = nil
        if prev then
            for name, value in pairs(prev) do
                if CVarExists(name) and GetVar(name) ~= value then SetVar(name, value) end
            end
        end
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
    if db.graphicsKeepUltra then ApplyUltra(false) end
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
    options = {
        { type = "button", label = "Ultra graphics preset", buttonText = "Apply",
          tooltip = "Sets every graphics slider to its highest value and view distance to maximum. Heaviest on frame rate: view distance and shadows; lower those two in the game's settings if it stutters. Anti-aliasing and texture resolution only change after a restart.",
          onClick = function() ApplyUltra(true) end },
        { type = "button", buttonText = "Restore", pair = true,
          tooltip = "Puts back the settings you had before the preset was applied.",
          onClick = function() RestoreUltra() end },
        { key = "graphicsKeepUltra", label = "Re-apply ultra at login", default = false,
          tooltip = "Applies the preset again every login so patches cannot reset it." },
        { key = "graphicsMaxCamera", label = "Max camera zoom distance", default = true,
          tooltip = "Lets you zoom the camera out further than the settings slider allows. Applied on every character.",
          onChange = function(checked) ApplyCamera(checked, true) end },
        { key = "graphicsVivid", label = "Vivid colours", default = false,
          tooltip = "Slightly higher contrast. Purely taste; untick to return to what you had.",
          onChange = function(checked) ApplyVivid(checked, true) end },
    },
    OnInit = function()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then ApplyAtLogin() end
    end,
    commands = {
        ultra = function(rest)
            rest = (rest or ""):lower()
            if rest == "restore" then
                RestoreUltra()
            else
                ApplyUltra(true)
            end
        end,
    },
})
