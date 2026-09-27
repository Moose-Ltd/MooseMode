-------------------------------------------------------------------------------
-- MooseMode -- Minimap
--
-- Small minimap comforts:
--   * Auto zoom out: after you zoom in, the map goes back to fully zoomed out
--     after 10, 20 or 30 seconds (it waits while the cursor is on the map).
--   * Hide addon buttons: other addons' minimap buttons fade out and come
--     back while the cursor is over the minimap or one of the buttons.
--   * Square minimap with a thin MooseMode-purple border.
--   * Hide the zoom + / - buttons (the mouse wheel still zooms).
--
-- Options (account-wide):
--   minimapAutoZoom        Auto zoom out
--   minimapAutoZoomDelay   10 / 20 / 30 seconds (sub-option)
--   minimapHideButtons     Hide addon buttons until you hover the minimap
--   minimapHideOwnButton   Include MooseMode's own button (sub-option)
--   minimapSquare          Square minimap
--   minimapHideZoom        Hide the zoom buttons
--
-- Taint rules (the client has secret values; Blizzard code that meets one
-- after addon code touched its execution path errors out), checked against
-- the Forever branch of Blizzard's UI source:
--   * MinimapCluster and Minimap are laid out by Edit Mode: this file never
--     moves, reparents, anchors or resizes them, and never SetScripts or
--     replaces a method on any Blizzard frame. No Blizzard table or global is
--     written, except GetMinimapShape (see below).
--   * Minimap:SetZoom(0) runs from our own timer. The MINIMAP_UPDATE_ZOOM
--     handlers it triggers (MinimapMixin:OnEvent, HybridMinimap) only compare
--     Minimap:GetZoom() and GetZoomLevels(), which the API documentation lists
--     without secret returns, so they are safe even when run from our call.
--     Zoom-ins are noticed through our own MINIMAP_UPDATE_ZOOM listener, not
--     a hook.
--   * Minimap:SetMaskTexture: nothing in the Forever source reads the mask
--     back; Blizzard only sets it (Camelot\Skin.lua, on the rotateMinimap
--     CVar). We re-apply the square mask after that CVar changes.
--   * The round art (MinimapCompassTexture, MinimapCompassTextureUnderlay,
--     MinimapCluster.DielFrame = the Forever day/night ring) and the zoom
--     buttons are only given SetAlpha (and EnableMouse for the zoom buttons).
--     Blizzard's code never reads their alpha; it only Shows/Hides them, which
--     leaves alpha alone, so our choice survives and restores exactly.
--   * GetMinimapShape is the addon convention LibDBIcon reads. No file on the
--     Forever branch of Blizzard's UI references it; it is installed only
--     while the square map is on and the previous value is put back after.
--   * Addon buttons: only frames that belong to other addons (LibDBIcon10_*
--     or names ending in MinimapButton, never Blizzard's), plus MooseMode's
--     own, get SetAlpha. The fade is our own OnUpdate, not UIFrameFade
--     (which would write into Blizzard's shared FADEFRAMES table).
--   * Everything is pcall-guarded, and Blizzard-frame changes wait for the
--     end of combat.
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local SQUARE_MASK = "Interface\\BUTTONS\\WHITE8X8"
-- What Camelot\Skin.lua sets for both the fixed and the rotating minimap.
local ROUND_MASK  = "ui-hud-minimap-frame-generic-mask"

local BORDER_SIZE = 2
local BRAND_R, BRAND_G, BRAND_B = 0xB0 / 255, 0x4C / 255, 0xFF / 255   -- #B04CFF

local FADE_TIME   = 0.25   -- seconds for a full fade in or out
local HOVER_HOLD  = 0.5    -- keep the buttons up this long after the cursor leaves
local SCAN_EVERY  = 2      -- seconds between looks for newly created buttons
local ZOOM_RECHECK = 3     -- cursor on the map when the timer fires: try again after this

local function Db() return ns.db end

local function Num(v)
    if v == nil or ns.IsSecret(v) or type(v) ~= "number" then return nil end
    return v
end

local function SafeAlpha(region)
    local ok, a = pcall(region.GetAlpha, region)
    a = ok and Num(a) or nil
    return a or 1
end

local function MouseOver(frame)
    if not frame then return false end
    local ok, over = pcall(frame.IsMouseOver, frame)
    if not ok or ns.IsSecret(over) then return false end
    return over and true or false
end

local function Visible(frame)
    local ok, v = pcall(frame.IsVisible, frame)
    if not ok or ns.IsSecret(v) then return false end
    return v and true or false
end

-- Blizzard-frame changes are deferred out of combat; see PLAYER_REGEN_ENABLED.
local pendingAfterCombat = false
local ApplyAll   -- defined below

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
end

-------------------------------------------------------------------------------
-- 1. Auto zoom out
-------------------------------------------------------------------------------

local zoomTimer

local function CancelZoomTimer()
    if zoomTimer then
        zoomTimer:Cancel()
        zoomTimer = nil
    end
end

local function CurrentZoom()
    if not Minimap then return nil end
    local ok, z = pcall(Minimap.GetZoom, Minimap)
    return ok and Num(z) or nil
end

local ScheduleZoomOut

local function ZoomOutNow()
    zoomTimer = nil
    local db = Db()
    if not db or not db.minimapAutoZoom then return end
    local z = CurrentZoom()
    if not z or z <= 0 then return end
    -- Still reading the map: leave it alone and look again shortly.
    if MouseOver(Minimap) then
        ScheduleZoomOut(ZOOM_RECHECK)
        return
    end
    pcall(Minimap.SetZoom, Minimap, 0)
end

function ScheduleZoomOut(delay)
    CancelZoomTimer()
    local db = Db()
    if not db or not db.minimapAutoZoom then return end
    local z = CurrentZoom()
    if not z or z <= 0 then return end
    delay = delay or tonumber(db.minimapAutoZoomDelay) or 20
    if C_Timer and C_Timer.NewTimer then
        zoomTimer = C_Timer.NewTimer(delay, ZoomOutNow)
    end
end

local function ApplyAutoZoom()
    local db = Db()
    if db and db.minimapAutoZoom then
        ScheduleZoomOut()
    else
        CancelZoomTimer()
    end
end

-------------------------------------------------------------------------------
-- 2. Hide addon buttons until the minimap is hovered
-------------------------------------------------------------------------------

-- Blizzard frames that could match the name patterns or sit on the minimap.
-- Never touched, whatever their name.
local BLIZZARD_NAMES = {
    ExpansionLandingPageMinimapButton = true,
    GarrisonLandingPageMinimapButton  = true,
    QueueStatusMinimapButton          = true,
    QueueStatusButton                 = true,
    LFGMinimapFrame                   = true,
    MiniMapLFGFrame                   = true,
    MiniMapBattlefieldFrame           = true,
    MiniMapTrackingButton             = true,
    MiniMapTracking                   = true,
    MiniMapMailFrame                  = true,
    MiniMapWorldMapButton             = true,
    MinimapZoomIn                     = true,
    MinimapZoomOut                    = true,
    MinimapBackdrop                   = true,
    GameTimeFrame                     = true,
    TimeManagerClockButton            = true,
    AddonCompartmentFrame             = true,
}

local OWN_BUTTON = "MooseModeMinimapButton"

local tracked = {}        -- [frame] = alpha it had before we took it over
local fadeAlpha = 1       -- the alpha every tracked button currently has
local hoverHold = 0
local scanClock = 0
local fader = CreateFrame("Frame")
fader:Hide()

local function IsBlizzardChild(f)
    if not Minimap then return true end
    return f == Minimap.ZoomIn or f == Minimap.ZoomOut or f == Minimap.ZoomHitArea
        or f == _G.MinimapBackdrop
end

-- A frame we may fade: named like an addon minimap button, not Blizzard's,
-- not protected, not managing its own mouse-over fade already.
local function IsAddonButton(f, name)
    if type(name) ~= "string" or BLIZZARD_NAMES[name] or name == OWN_BUTTON then return false end
    if name:find("^Blizzard") then return false end
    local libdb = name:find("^LibDBIcon10_") ~= nil
    if not libdb and not name:find("MinimapButton$") then return false end
    if IsBlizzardChild(f) then return false end
    local okP, prot = pcall(f.IsProtected, f)
    if not okP or ns.IsSecret(prot) or prot then return false end
    -- LibDBIcon's own "show on mouse-over" already does this fade.
    if f.showOnMouseover then return false end
    -- Second line of defence for the name-pattern case: a global set by
    -- Blizzard's own code is secure, one set by an addon is tainted.
    if not libdb and issecurevariable then
        local okS, secure = pcall(issecurevariable, name)
        if okS and secure == true then return false end
    end
    return true
end

local function Track(f)
    if not f or tracked[f] then return end
    tracked[f] = SafeAlpha(f)
    pcall(f.SetAlpha, f, fadeAlpha)
end

local function Untrack(f)
    local orig = tracked[f]
    if orig == nil then return end
    tracked[f] = nil
    pcall(f.SetAlpha, f, orig)
end

local function ScanChildren(parent)
    if not parent then return end
    local ok, kids = pcall(function() return { parent:GetChildren() } end)
    if not ok or type(kids) ~= "table" then return end
    for _, f in ipairs(kids) do
        local okN, name = pcall(f.GetName, f)
        if okN and not ns.IsSecret(name) and IsAddonButton(f, name) then Track(f) end
    end
end

local function ScanButtons()
    local db = Db()
    if not db then return end
    ScanChildren(Minimap)
    ScanChildren(_G.MinimapBackdrop)
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if lib and lib.GetButtonList and lib.GetMinimapButton then
        local ok, list = pcall(lib.GetButtonList, lib)
        if ok and type(list) == "table" then
            for _, n in ipairs(list) do
                local okB, b = pcall(lib.GetMinimapButton, lib, n)
                if okB and b then
                    local okN, name = pcall(b.GetName, b)
                    if okN and IsAddonButton(b, name) then Track(b) end
                end
            end
        end
    end
    local own = ns.GetMinimapButton and ns.GetMinimapButton()
    if own then
        if db.minimapHideOwnButton then Track(own) else Untrack(own) end
    end
end

local function Hovering()
    if MouseOver(Minimap) then return true end
    for f in pairs(tracked) do
        if Visible(f) and MouseOver(f) then return true end
    end
    return false
end

local function SetTrackedAlpha(a)
    fadeAlpha = a
    for f in pairs(tracked) do pcall(f.SetAlpha, f, a) end
end

fader:SetScript("OnUpdate", function(self, elapsed)
    scanClock = scanClock + elapsed
    if scanClock >= SCAN_EVERY then
        scanClock = 0
        ScanButtons()
    end
    if Hovering() then
        hoverHold = HOVER_HOLD
    elseif hoverHold > 0 then
        hoverHold = hoverHold - elapsed
    end
    local target = hoverHold > 0 and 1 or 0
    if fadeAlpha ~= target then
        local step = elapsed / FADE_TIME
        local a = target > fadeAlpha and math.min(1, fadeAlpha + step) or math.max(0, fadeAlpha - step)
        SetTrackedAlpha(a)
    end
end)

local function ApplyHideButtons()
    local db = Db()
    if db and db.minimapHideButtons then
        fadeAlpha, hoverHold, scanClock = 0, 0, 0
        ScanButtons()
        fader:Show()
    else
        fader:Hide()
        for f in pairs(tracked) do Untrack(f) end
        fadeAlpha = 1
    end
end

-------------------------------------------------------------------------------
-- 3. Square minimap
-------------------------------------------------------------------------------

local squareOn = false
local hiddenArt = {}      -- [region] = alpha before we hid it
local border
local prevShape
local function SquareShape() return "SQUARE" end

local function RoundArt()
    return {
        _G.MinimapCompassTexture,
        _G.MinimapCompassTextureUnderlay,
        _G.MinimapBorder,                      -- older clients only
        MinimapCluster and MinimapCluster.DielFrame,   -- Forever day/night ring
    }
end

local function MakeBorder()
    if border then return border end
    border = CreateFrame("Frame", nil, Minimap)
    border:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -BORDER_SIZE, BORDER_SIZE)
    border:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", BORDER_SIZE, -BORDER_SIZE)
    pcall(border.SetFrameLevel, border, (Minimap:GetFrameLevel() or 1) + 2)
    local function Edge(p1, p2, w, h)
        local t = border:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(BRAND_R, BRAND_G, BRAND_B, 1)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, BORDER_SIZE)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, BORDER_SIZE)
    Edge("TOPLEFT", "BOTTOMLEFT", BORDER_SIZE, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", BORDER_SIZE, nil)
    border:Hide()
    return border
end

-- LibDBIcon buttons and MooseMode's own button follow GetMinimapShape the
-- next time they are placed; nudge them now so a toggle needs no reload.
local function RefreshButtonPositions()
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if lib and lib.GetButtonList and lib.Refresh then
        local ok, list = pcall(lib.GetButtonList, lib)
        if ok and type(list) == "table" then
            for _, n in ipairs(list) do pcall(lib.Refresh, lib, n) end
        end
    end
    -- Needs Core to expose its placement function (see the report).
    if ns.UpdateMinimapButtonPosition then pcall(ns.UpdateMinimapButtonPosition) end
end

local function SetSquare(on)
    if not Minimap then return end
    if on then
        pcall(Minimap.SetMaskTexture, Minimap, SQUARE_MASK)
        for _, r in ipairs(RoundArt()) do
            if r and hiddenArt[r] == nil then
                hiddenArt[r] = SafeAlpha(r)
                pcall(r.SetAlpha, r, 0)
            end
        end
        MakeBorder():Show()
        if _G.GetMinimapShape ~= SquareShape then
            prevShape = _G.GetMinimapShape
            _G.GetMinimapShape = SquareShape
        end
    elseif squareOn then
        pcall(Minimap.SetMaskTexture, Minimap, ROUND_MASK)
        for r, a in pairs(hiddenArt) do pcall(r.SetAlpha, r, a) end
        wipe(hiddenArt)
        if border then border:Hide() end
        if _G.GetMinimapShape == SquareShape then
            _G.GetMinimapShape = prevShape
        end
        prevShape = nil
    end
    local changed = (squareOn ~= (on and true or false))
    squareOn = on and true or false
    if changed then RefreshButtonPositions() end
end

local function ApplySquare()
    local db = Db()
    if not db then return end
    if InCombat() then pendingAfterCombat = true return end
    SetSquare(db.minimapSquare and true or false)
end

-------------------------------------------------------------------------------
-- 4. Hide the zoom buttons
-------------------------------------------------------------------------------

local zoomHidden = false

local function ApplyZoomButtons()
    local db = Db()
    if not db or not Minimap then return end
    if InCombat() then pendingAfterCombat = true return end
    local want = db.minimapHideZoom and true or false
    if want == zoomHidden then return end
    -- Alpha and mouse only: Blizzard still Shows/Hides them on hover and
    -- Minimap_ZoomIn/Out (the mouse wheel) still Click() them.
    for _, b in ipairs({ Minimap.ZoomIn, Minimap.ZoomOut }) do
        if b then
            pcall(b.SetAlpha, b, want and 0 or 1)
            pcall(b.EnableMouse, b, not want)
        end
    end
    zoomHidden = want
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function ApplyAll()
    if not Db() then return end
    ApplyAutoZoom()
    ApplyHideButtons()
    ApplySquare()
    ApplyZoomButtons()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
ns.SafeRegisterEvent(events, "MINIMAP_UPDATE_ZOOM")
ns.SafeRegisterEvent(events, "CVAR_UPDATE")
events:SetScript("OnEvent", function(self, event, arg1)
    if not Db() then return end
    if event == "PLAYER_LOGIN" then
        -- While a late settings restore is pending, ns.db holds defaults:
        -- Core re-runs OnInit (reinitSafe) on the real values.
        if not (ns.SettingsRestorePending and ns.SettingsRestorePending()) then ApplyAll() end
    elseif event == "MINIMAP_UPDATE_ZOOM" or event == "PLAYER_ENTERING_WORLD" then
        ApplyAutoZoom()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingAfterCombat then
            pendingAfterCombat = false
            ApplySquare()
            ApplyZoomButtons()
        end
    elseif event == "CVAR_UPDATE" then
        -- Skin.lua puts the round mask back when rotateMinimap changes; run
        -- after its callback.
        if squareOn and type(arg1) == "string" and not ns.IsSecret(arg1)
            and arg1:lower() == "rotateminimap" and C_Timer then
            C_Timer.After(0, function()
                if squareOn and not InCombat() then pcall(Minimap.SetMaskTexture, Minimap, SQUARE_MASK) end
            end)
        end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key     = "minimapModule",
    label   = "Minimap",
    group   = "Interface",
    summary = "Auto zoom-out, tidy addon buttons and an optional square map.",
    icon    = "Interface\\Icons\\Ability_Tracking",
    master  = false,
    reinitSafe = true,   -- OnInit only applies state from ns.db; safe to run again after a late restore
    options = {
        { key = "minimapAutoZoom", label = "Auto zoom out", default = true,
          tooltip = "After you zoom the minimap in, it goes back to fully zoomed out on its own. It waits while the cursor is on the map.",
          onChange = function() ApplyAutoZoom() end },
        { type = "choice", key = "minimapAutoZoomDelay", label = "After", default = 20, parent = "minimapAutoZoom",
          values = { { value = 10, text = "10 s" }, { value = 20, text = "20 s" }, { value = 30, text = "30 s" } },
          tooltip = "How long the minimap stays zoomed in before it zooms back out.",
          onChange = function() ApplyAutoZoom() end },
        { key = "minimapHideButtons", label = "Hide addon buttons until you hover the minimap", default = false,
          tooltip = "Other addons' minimap buttons fade out and come back while the cursor is over the minimap or one of the buttons. Blizzard's own buttons (tracking, mail, clock, calendar, zoom) are never touched.",
          onChange = function() ApplyHideButtons() end },
        { key = "minimapHideOwnButton", label = "Include the MooseMode button", default = true, parent = "minimapHideButtons",
          tooltip = "Fade MooseMode's purple star along with the other addon buttons.",
          onChange = function() if Db() and Db().minimapHideButtons then ScanButtons() end end },
        { key = "minimapSquare", label = "Square minimap", default = false,
          tooltip = "A square map with a thin purple border instead of the round frame and day/night ring. Buttons that follow the minimap shape (LibDBIcon) move to the square edge. Turning it off brings the round map back straight away; /reload if any art looks out of place. Pinging only works inside the round area.",
          onChange = function() ApplySquare() end },
        { key = "minimapHideZoom", label = "Hide the zoom buttons", default = false,
          tooltip = "Hides the + and - buttons on the minimap. The mouse wheel still zooms.",
          onChange = function() ApplyZoomButtons() end },
    },
    OnInit = function()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then ApplyAll() end
    end,
})
