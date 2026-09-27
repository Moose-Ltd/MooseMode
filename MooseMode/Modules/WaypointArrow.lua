-------------------------------------------------------------------------------
-- MooseMode -- WaypointArrow
--
-- A small purple arrow that points to your map pin (or a focused quest) and
-- shows the distance in yards. Its settings live on the Map card.
--
-- Pin: MooseMode's own, per character. Ctrl+click the world map to place it,
-- Ctrl+click it to remove it, or /way x y and /way reset. It clears itself
-- within 10 yards. A layer of ours on the map takes the mouse only while Ctrl
-- is held, so other clicks go to the map.
--
-- Direction: the map's corners give north and east in world units
-- (C_Map.GetWorldPosFromMapPos); the pin's offset split along them is
-- compared with GetPlayerFacing. With no pin, a quest the game is guiding
-- you to is followed instead, using the same screen maths as Blizzard's edge
-- arrow (centre of screen to C_Navigation's frame).
--
-- Drag the arrow anywhere; right-click (or the Lock option) locks it.
-- Nothing of Blizzard's is written or hooked.
--
-- Options (on the Map card): navArrow, navAutoClear, navLocked
-- Saved: navPos { x, y }, navPins [character] = { m, x, y }
-- Commands: /mm arrow status | lock | unlock | reset
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local POLL         = 0.05
local ARRIVE_YARDS = 10
local SIZE         = 44
local DEFAULT_POS  = { x = 0, y = 220 }
local ARROW_TEX    = "Interface\\AddOns\\" .. ADDON .. "\\media\\arrow.tga"   -- tools/make_arrow.js
local PIN_SIZE     = 26
local PIN_ATLAS    = "Waypoint-MapPin-Tracked"

local arrow, layer
local lastArrival = 0

local function Plain(v)
    return type(v) == "number" and not ns.IsSecret(v)
end

local function On()
    return ns.db and ns.db.navArrow
end

-------------------------------------------------------------------------------
-- Positions
-------------------------------------------------------------------------------

local function WorldPos(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    if not (Plain(mapID) and Plain(x) and Plain(y)) then return nil end
    local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if not ok or not pos or not pos.GetXY then return nil end
    local okXY, wx, wy = pcall(pos.GetXY, pos)
    if not okXY or not Plain(wx) or not Plain(wy) then return nil end
    return continent, wx, wy
end

local axesCache = {}
local function MapAxes(mapID)
    if axesCache[mapID] then return axesCache[mapID] end
    local c1, ax, ay = WorldPos(mapID, 0, 0)
    local c2, bx, by = WorldPos(mapID, 1, 0)
    local c3, cx, cy = WorldPos(mapID, 0, 1)
    if not (c1 and c2 and c3) then return nil end
    local ex, ey, nx, ny = bx - ax, by - ay, ax - cx, ay - cy
    local el, nl = math.sqrt(ex * ex + ey * ey), math.sqrt(nx * nx + ny * ny)
    if el == 0 or nl == 0 then return nil end
    axesCache[mapID] = { ex = ex / el, ey = ey / el, nx = nx / nl, ny = ny / nl }
    return axesCache[mapID]
end

local function PlayerFacing()
    if not GetPlayerFacing then return nil end
    local ok, facing = pcall(GetPlayerFacing)
    if ok and Plain(facing) then return facing end
    return nil
end

local function PlayerMapPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local okM, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okM or not Plain(mapID) then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local okXY, x, y = pcall(pos.GetXY, pos)
    if not okXY or not Plain(x) or not Plain(y) then return nil end
    return mapID, x, y
end

-------------------------------------------------------------------------------
-- The pin
-------------------------------------------------------------------------------

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. ((GetRealmName and GetRealmName()) or "?")
end

local function OwnPin()
    local pins = ns.db and ns.db.navPins
    local pin = type(pins) == "table" and pins[CharKey()] or nil
    if type(pin) == "table" and Plain(pin.m) and Plain(pin.x) and Plain(pin.y) then
        return pin.m, pin.x, pin.y
    end
    return nil
end

local DrawPin   -- forward

-- Used by the Map module's /way. False when the arrow is off (the game's
-- own waypoint is used then).
function ns.NavSetPin(mapID, x, y)
    if not On() or not (Plain(mapID) and Plain(x) and Plain(y)) then return false end
    if type(ns.db.navPins) ~= "table" then ns.db.navPins = {} end
    ns.db.navPins[CharKey()] = { m = mapID, x = x, y = y }
    ns.SaveSettings()
    if DrawPin then DrawPin() end
    return true
end

function ns.NavClearPin()
    local had = OwnPin() ~= nil
    if ns.db and type(ns.db.navPins) == "table" then
        ns.db.navPins[CharKey()] = nil
        ns.SaveSettings()
    end
    if DrawPin then DrawPin() end
    return had
end

-- The Map module's /way asks whether to show the game's floating marker.
function ns.NavWantsNativeMarker()
    return not On()
end

-------------------------------------------------------------------------------
-- Bearing: distance (yards), turn (radians, counter-clockwise), kind
-------------------------------------------------------------------------------

local function PinBearing()
    local wMap, wx, wy = OwnPin()
    if not wMap then return nil end
    local pMap, px, py = PlayerMapPos()
    if not pMap then return nil end
    local cP, pwx, pwy = WorldPos(pMap, px, py)
    local cW, twx, twy = WorldPos(wMap, wx, wy)
    if not (cP and cW) or cP ~= cW then return nil end
    local dx, dy = twx - pwx, twy - pwy
    local dist = math.sqrt(dx * dx + dy * dy)
    local axes, facing = MapAxes(pMap), PlayerFacing()
    if not (axes and facing) then return dist, nil, "pin" end
    local north = dx * axes.nx + dy * axes.ny
    local east  = dx * axes.ex + dy * axes.ey
    local turn = math.atan2(-east, north) - facing
    turn = (turn + math.pi) % (2 * math.pi) - math.pi
    return dist, turn, "pin"
end

-- Whatever the game is guiding you to (a focused quest), while its marker shows.
local function NavBearing()
    if not (C_Navigation and C_Navigation.GetFrame and C_Navigation.GetDistance) then return nil end
    if C_SuperTrack and C_SuperTrack.GetHighestPrioritySuperTrackingType then
        local okT, kind = pcall(C_SuperTrack.GetHighestPrioritySuperTrackingType)
        if not okT or kind == nil then return nil end
    end
    local marker = _G.SuperTrackedFrame
    if type(marker) == "table" then
        local okV, visible = pcall(marker.IsVisible, marker)
        if not okV or not visible then return nil end
    end
    local ok, navFrame = pcall(C_Navigation.GetFrame)
    if not ok or type(navFrame) ~= "table" then return nil end
    local okN, nx, ny = pcall(navFrame.GetCenter, navFrame)
    local okW, cx, cy = pcall(WorldFrame.GetCenter, WorldFrame)
    local okD, dist = pcall(C_Navigation.GetDistance)
    if not (okN and okW and okD and Plain(nx) and Plain(ny) and Plain(cx) and Plain(cy) and Plain(dist)) then return nil end
    if dist <= 0 then return nil end
    local scale = UIParent:GetEffectiveScale() or 1
    local dx, dy = nx - cx / scale, ny - cy / scale
    local turn = (dx ~= 0 or dy ~= 0) and math.atan2(-dx, dy) or 0
    return dist, turn, "quest"
end

local function Bearing()
    local dist, turn, kind = PinBearing()
    if dist then return dist, turn, kind end
    return NavBearing()
end

-------------------------------------------------------------------------------
-- The arrow
-------------------------------------------------------------------------------

local function SavePosition()
    local dx, dy = ns.CentreOffset(arrow)
    if not dx then return end
    dx, dy = ns.CentreGuides.Snap(dx, dy)
    ns.db.navPos = { x = math.floor(dx + 0.5), y = math.floor(dy + 0.5) }
    ns.SaveSettings()
end

local function Place()
    local pos = type(ns.db.navPos) == "table" and ns.db.navPos or DEFAULT_POS
    arrow:ClearAllPoints()
    arrow:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
end

function ns.NavSetLocked(locked)
    ns.db.navLocked = locked and true or false
    ns.SaveSettings()
    if ns.RefreshOptionsDialog then ns.RefreshOptionsDialog() end
    ns.Print(locked and "Arrow locked." or "Arrow unlocked.")
end

function ns.NavResetPosition()
    ns.db.navPos = nil
    ns.SaveSettings()
    if arrow then Place() end
end

local function Build()
    if arrow then return end
    local f = CreateFrame("Frame", "MooseModeWaypointArrow", UIParent)
    f:SetSize(SIZE + 20, SIZE + 22)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetSize(SIZE, SIZE)
    f.tex:SetPoint("TOP")
    local okTex, loaded = pcall(f.tex.SetTexture, f.tex, ARROW_TEX)
    if not okTex or loaded == false then
        f.tex:SetTexture("Interface\\Minimap\\MinimapArrow")
        f.tex:SetVertexColor(0.69, 0.30, 1.00)
    end

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local font = f.text:GetFont()
    if font then f.text:SetFont(font, 12, "OUTLINE") end
    f.text:SetPoint("TOP", f.tex, "BOTTOM", 0, -2)
    f.text:SetTextColor(0.90, 0.80, 1.00)

    -- Turn smoothly towards the target every frame.
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self.targetRot then return end
        local cur = self.rot or self.targetRot
        local diff = (self.targetRot - cur + math.pi) % (2 * math.pi) - math.pi
        cur = cur + diff * math.min(1, (elapsed or 0) * 12)
        self.rot = cur
        self.tex:SetRotation(cur)
    end)
    f:SetScript("OnDragStart", function(self)
        if ns.db.navLocked then return end
        self.dragging = true
        self:StartMoving()
        ns.CentreGuides.Begin(self)
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.dragging = false
        ns.CentreGuides.End()
        SavePosition()
        Place()
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then ns.NavSetLocked(not ns.db.navLocked) end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(ns.db.navLocked and "Right-click to unlock" or "Drag to move, right-click to lock", 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:Hide()
    arrow = f
    Place()
end

local driver = CreateFrame("Frame")
local since = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    since = since + (elapsed or 0)
    if since < POLL then return end
    since = 0
    if not On() then
        if arrow and arrow:IsShown() then arrow:Hide() end
        return
    end
    local dist, turn, kind = Bearing()
    if not dist then
        if arrow and arrow:IsShown() and not arrow.dragging then arrow:Hide() end
        return
    end
    Build()
    if kind == "pin" and ns.db.navAutoClear and dist <= ARRIVE_YARDS then
        if GetTime() - lastArrival > 2 then
            lastArrival = GetTime()
            ns.NavClearPin()
            ns.Print("Arrived.")
        end
        arrow:Hide()
        return
    end
    if turn then
        arrow.targetRot = turn
        arrow.tex:SetAlpha(math.abs(turn) < 0.2 and 1 or 0.85)
    else
        arrow.targetRot = 0
        arrow.tex:SetAlpha(0.35)
    end
    arrow.text:SetText(string.format("%d yd", math.floor(dist + 0.5)))
    if not arrow:IsShown() then arrow:Show() end
end)

-------------------------------------------------------------------------------
-- The pin on the world map
-------------------------------------------------------------------------------

local function MapContainer()
    return WorldMapFrame and WorldMapFrame.ScrollContainer
end

local function ViewedMap()
    if not (WorldMapFrame and WorldMapFrame.GetMapID) then return nil end
    local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok and Plain(id) then return id end
    return nil
end

local function PinOnMap(viewMap)
    local m, x, y = OwnPin()
    if not m or not viewMap then return nil end
    if m == viewMap then return x, y end
    if not C_Map.GetMapPosFromWorldPos then return nil end
    local cont, wx, wy = WorldPos(m, x, y)
    if not cont then return nil end
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, CreateVector2D(wx, wy), viewMap)
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local okXY, px, py = pcall(pos.GetXY, pos)
    if okXY and Plain(px) and Plain(py) and px >= 0 and px <= 1 and py >= 0 and py <= 1 then return px, py end
    return nil
end

DrawPin = function()
    if not layer then return end
    local x, y = PinOnMap(ViewedMap())
    if not (x and On()) then layer.pin:Hide() return end
    local container = MapContainer()
    local okS, scale = pcall(container.GetCanvasScale, container)
    if not okS or not Plain(scale) or scale <= 0 then scale = 1 end
    local inv = 1 / scale
    local w, h = layer:GetSize()
    layer.pin:SetScale(inv)
    layer.pin:ClearAllPoints()
    layer.pin:SetPoint("BOTTOM", layer, "TOPLEFT", x * w / inv, -y * h / inv)
    layer.pin:Show()
end

local function MapClick(button)
    if button ~= "LeftButton" or not IsControlKeyDown() then return end
    local container = MapContainer()
    local ok, x, y = pcall(container.GetNormalizedCursorPosition, container)
    local view = ViewedMap()
    if not ok or not (Plain(x) and Plain(y)) or not view or x < 0 or x > 1 or y < 0 or y > 1 then return end
    local px, py = PinOnMap(view)
    if px and math.abs(px - x) < 0.02 and math.abs(py - y) < 0.03 then
        ns.NavClearPin()
        if SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_REMOVE then PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_REMOVE) end
        return
    end
    ns.NavSetPin(view, x, y)
    if SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK then PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK) end
end

local function BuildMapLayer()
    local container = MapContainer()
    if layer or not (container and container.Child) or InCombatLockdown() then return end
    local child = container.Child
    layer = CreateFrame("Frame", nil, child)
    layer:SetAllPoints(child)
    local okL, lvl = pcall(child.GetFrameLevel, child)
    layer:SetFrameLevel(((okL and lvl) or 1) + 400)

    local pin = CreateFrame("Frame", nil, layer)
    pin:SetSize(PIN_SIZE, PIN_SIZE)
    pin.tex = pin:CreateTexture(nil, "OVERLAY")
    pin.tex:SetAllPoints()
    local okA = pcall(pin.tex.SetAtlas, pin.tex, PIN_ATLAS, false)
    if not okA or not pin.tex:GetAtlas() then pin.tex:SetTexture("Interface\\Minimap\\ObjectIcons") end
    pin.tex:SetVertexColor(0.8, 0.55, 1)
    pin:Hide()
    layer.pin = pin

    layer:SetScript("OnMouseUp", function(_, button) MapClick(button) end)
    layer:EnableMouse(false)   -- after the mouse script, which switches it on
    local tick = 1
    layer:SetScript("OnUpdate", function(self, elapsed)
        -- Take the mouse only while Ctrl is held over the map.
        local okOver, over = pcall(container.IsMouseOver, container)
        local want = (IsControlKeyDown() and okOver and over and On()) and true or false
        local okM, enabled = pcall(self.IsMouseEnabled, self)
        if not okM or enabled ~= want then self:EnableMouse(want) end
        tick = tick + (elapsed or 0)
        if tick >= 0.1 then tick = 0; DrawPin() end
    end)
end

-------------------------------------------------------------------------------
-- Status
-------------------------------------------------------------------------------

local function Status()
    local function say(k, v) ns.Print("|cff88ccff[arrow]|r " .. k .. ": " .. tostring(v)) end
    local m, x, y = OwnPin()
    say("pin", m and string.format("map %d at %.1f, %.1f", m, x * 100, y * 100) or "none")
    local pm, px, py = PlayerMapPos()
    say("you", pm and string.format("map %d at %.1f, %.1f", pm, px * 100, py * 100) or "not available")
    say("facing", PlayerFacing() and string.format("%.2f", PlayerFacing()) or "not available")
    local dist, turn, kind = Bearing()
    say("target", dist and string.format("%s, %d yd, %s", kind, math.floor(dist + 0.5),
        turn and string.format("%.0f deg", math.deg(turn)) or "no direction") or "none")
end

-------------------------------------------------------------------------------
-- Events and registration
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event ~= "ADDON_LOADED" or arg1 == "Blizzard_WorldMap" then BuildMapLayer() end
end)

-- For the Map card's options.
function ns.NavRefresh()
    if DrawPin then DrawPin() end
end

ns:RegisterModule({
    key    = "navArrowModule",
    label  = "Waypoint Arrow",
    group  = "Interface",
    hidden = true,   -- settings are on the Map card
    commands = {
        arrow = function(rest)
            rest = (rest or ""):lower()
            if rest == "status" then Status()
            elseif rest == "reset" then ns.NavResetPosition()
            elseif rest == "lock" then ns.NavSetLocked(true)
            elseif rest == "unlock" then ns.NavSetLocked(false)
            else ns.Print("/mm arrow status | lock | unlock | reset") end
        end,
    },
})
