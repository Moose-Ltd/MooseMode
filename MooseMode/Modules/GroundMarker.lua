-------------------------------------------------------------------------------
-- MooseMode -- GroundMarker
--
-- One key drops a world marker (the coloured ground flare your group sees)
-- under the mouse cursor; Ctrl + the same key clears your markers.
--
-- The key runs the game's own /wm [@cursor] and /cwm all through a secure
-- macro button (SecureActionButtonTemplate), bound with an override binding,
-- so it works in combat. Buttons and bindings are only changed out of
-- combat; a change made in combat is applied when it ends.
--
-- Options (account-wide):
--   groundMarker        on / off (master)
--   groundMarkerKey     BUTTON3 (middle, default), BUTTON4 or BUTTON5
--   groundMarkerColour  world marker index: 3 purple, 1 blue, 4 red, 5 yellow
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local owner = CreateFrame("Frame")
local placeButton, clearButton
local pending = false

local function MakeButton(name)
    local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
    b:SetAttribute("type", "macro")
    local keyDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
    b:RegisterForClicks(keyDown and "AnyDown" or "AnyUp")
    b:Hide()
    return b
end

local function Apply()
    if not ns.db then return end
    if InCombatLockdown() then pending = true return end
    pending = false
    if not placeButton then
        placeButton = MakeButton("MooseModeMarkerPlace")
        clearButton = MakeButton("MooseModeMarkerClear")
        clearButton:SetAttribute("macrotext", "/cwm all")
    end
    placeButton:SetAttribute("macrotext", "/wm [@cursor] " .. tostring(ns.db.groundMarkerColour or 3))
    ClearOverrideBindings(owner)
    if ns.db.groundMarker then
        local key = ns.db.groundMarkerKey
        if key ~= "BUTTON4" and key ~= "BUTTON5" then key = "BUTTON3" end
        SetOverrideBindingClick(owner, true, key, "MooseModeMarkerPlace", "LeftButton")
        SetOverrideBindingClick(owner, true, "CTRL-" .. key, "MooseModeMarkerClear", "LeftButton")
    end
end

owner:RegisterEvent("PLAYER_LOGIN")
owner:RegisterEvent("PLAYER_REGEN_ENABLED")
owner:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or pending then Apply() end
end)

ns:RegisterModule({
    key   = "groundMarkerModule",
    label = "Ground Marker",
    group = "Combat",
    summary = "One key drops a group-visible marker at your cursor.",
    icon    = "Interface\\Icons\\Spell_Fire_Flare",
    reinitSafe = true,
    options = {
        { key = "groundMarker", label = "Marker key", default = false,
          tooltip = "Press to drop a marker under the cursor; Ctrl+key clears them. Your party sees them.",
          onChange = function() Apply() end },
        { type = "choice", key = "groundMarkerKey", label = "Key", default = "BUTTON3", parent = "groundMarker",
          values = { { value = "BUTTON3", text = "Mouse 3" }, { value = "BUTTON4", text = "Mouse 4" },
                     { value = "BUTTON5", text = "Mouse 5" } },
          onChange = function() Apply() end },
        { type = "choice", key = "groundMarkerColour", label = "Colour", default = 3, parent = "groundMarker",
          values = { { value = 3, text = "Purple" }, { value = 1, text = "Blue" },
                     { value = 4, text = "Red" }, { value = 5, text = "Yellow" } },
          onChange = function() Apply() end },
    },
    OnInit = function()
        if IsLoggedIn and IsLoggedIn() then Apply() end
    end,
})
