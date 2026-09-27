-------------------------------------------------------------------------------
-- MooseMode -- Map Reveal
--
-- Shows the unexplored parts of each zone on the world map, optionally with
-- a faint purple tint so explored and unexplored areas stay distinguishable.
--
-- What is drawn: ns.MapRevealData (MapRevealData.lua, generated from the
-- game's WorldMapOverlay / WorldMapOverlayTile DB2 tables) lists every
-- overlay of a zone. C_MapExplorationInfo.GetExploredMapTextures(mapID)
-- lists the ones this character has explored; Blizzard's exploration pin
-- draws those. This module draws the rest.
--
-- How, and why this way (secret values / taint):
--   Blizzard code that reads a secret value errors when its execution has
--   been tainted by addon code, so this module touches nothing of
--   Blizzard's. It owns one plain frame, parented to
--   WorldMapFrame.ScrollContainer.Child (the map canvas) and anchored to all
--   of it, which is exactly the rectangle Blizzard's exploration pin covers
--   (that pin sits at the canvas centre, is canvas-sized and ignores pin
--   scaling). The overlays go on the frame's own textures, laid out with
--   the same tile maths as MapExplorationPinMixin:RefreshOverlays.
--   There are no hooks at all: no hooksecurefunc, no data provider, no
--   pin-pool textures, no writes to Blizzard tables or globals. The frame's
--   OnUpdate (which only runs while the map is open) notices a change of
--   map or detail layer by polling, and MAP_EXPLORATION_UPDATED marks the
--   drawing dirty. Blizzard's own methods are only called to read state
--   (GetMapID, GetCurrentLayerIndex, EnumeratePinsByTemplate, the mask
--   getters), on this module's own call stack, inside pcall.
--   Nothing here is protected: the frame is not secure, calls no protected
--   API and is created outside of combat, so the map can be opened, changed
--   and redrawn in combat.
--
-- Options (account-wide):
--   mapReveal       Show unexplored areas
--   mapRevealTint   Tint unexplored areas (sub-option)
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local IsSecret = ns.IsSecret

-- MooseMode purple (B04CFF) mixed halfway towards white, at modest alpha:
-- a hint of colour, and the parchment beneath shows through a little.
local TINT = { 0.85, 0.65, 1.00, 0.75 }

local holder            -- our frame on the map canvas
local textures = {}     -- every texture we have made; the first `used` are live
local used = 0
local shownMapID, shownLayer, dirty
local explorationPin    -- Blizzard's exploration pin, only read (alpha, level)
local byArt             -- uiMapArtID -> zone entry, built on first use

local function Enabled()
    return ns.db and ns.db.mapReveal and true or false
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function Number(v)
    if v == nil or IsSecret(v) or type(v) ~= "number" then return nil end
    return v
end

-------------------------------------------------------------------------------
-- Reading the map's state (reads only)
-------------------------------------------------------------------------------

local function Map()
    local map = WorldMapFrame
    if map and map.ScrollContainer and map.ScrollContainer.Child then return map end
    return nil
end

local function CurrentMapID(map)
    return Number(Call(map.GetMapID, map))
end

local function CurrentLayer(map)
    local sc = map.ScrollContainer
    return Number(Call(sc.GetCurrentLayerIndex, sc)) or 1
end

local function FindExplorationPin(map)
    if explorationPin then return explorationPin end
    if type(map.EnumeratePinsByTemplate) ~= "function" then return nil end
    pcall(function()
        for pin in map:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
            explorationPin = pin
            break
        end
    end)
    return explorationPin
end

local function ZoneFor(mapID)
    local data = ns.MapRevealData
    if not data then return nil end
    local zone = data[mapID]
    -- The table is keyed by uiMapID; cross-check the art the client really
    -- uses for this map and follow it if it differs.
    local artID = Number(Call(C_Map and C_Map.GetMapArtID, mapID))
    if artID and not (zone and zone.art == artID) then
        if not byArt then
            byArt = {}
            for _, z in pairs(data) do byArt[z.art] = z end
        end
        zone = byArt[artID]
    end
    return zone
end

-- What the character has explored on this map: sets of "w:h:x:y" keys,
-- "x:y" offsets and fileDataIDs. An overlay matching any of the three counts
-- as explored, so a small drift in the data (a re-exported texture, a
-- resized overlay) never draws an explored area twice. Returns nil when the
-- answer cannot be read safely; then nothing is drawn.
local function Explored(mapID)
    local fn = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
    if type(fn) ~= "function" then return nil end
    local ok, list = pcall(fn, mapID)
    if not ok then return nil end
    local keys, offsets, files = {}, {}, {}
    if list == nil then return keys, offsets, files end   -- nothing explored
    if IsSecret(list) or type(list) ~= "table" then return nil end
    for _, info in ipairs(list) do
        if type(info) ~= "table" then return nil end
        local w, h = Number(info.textureWidth), Number(info.textureHeight)
        local x, y = Number(info.offsetX), Number(info.offsetY)
        if not (w and h and x and y) then return nil end
        keys[w .. ":" .. h .. ":" .. x .. ":" .. y] = true
        offsets[x .. ":" .. y] = true
        local ids = info.fileDataIDs
        if type(ids) == "table" and not IsSecret(ids) then
            for _, id in ipairs(ids) do
                if Number(id) then files[id] = true end
            end
        end
    end
    return keys, offsets, files
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local function ReleaseAll()
    for i = 1, used do
        local t = textures[i]
        t:Hide()
        t:ClearAllPoints()
        t:SetTexture(nil)
    end
    used = 0
end

local function Acquire()
    used = used + 1
    local t = textures[used]
    if not t then
        t = holder:CreateTexture(nil, "ARTWORK")
        textures[used] = t
    end
    return t
end

-- Keep our textures inside the canvas mask the same way Blizzard's are.
local function ApplyMask(map, t)
    local useMask = Call(map.GetUseMaskTexture, map)
    local mask = useMask and Call(map.GetMaskTexture, map) or nil
    if t.mmMask == mask then return end
    if t.mmMask then pcall(t.RemoveMaskTexture, t, t.mmMask) end
    t.mmMask = nil
    if mask and pcall(t.AddMaskTexture, t, mask) then t.mmMask = mask end
end

-- Size of the power-of-two texture file holding a partial tile.
local function FileSize(pixels)
    local size = 16
    while size < pixels do size = size * 2 end
    return size
end

local function DrawOverlay(map, o, tileW, tileH, tint)
    local width, height, offsetX, offsetY = o[1], o[2], o[3], o[4]
    local wide = math.ceil(width / tileW)
    local tall = math.ceil(height / tileH)
    for j = 1, tall do
        local pixelH, fileH = tileH, tileH
        if j == tall then
            pixelH = height % tileH
            if pixelH == 0 then pixelH = tileH end
            fileH = FileSize(pixelH)
        end
        for k = 1, wide do
            local fileID = o[4 + (j - 1) * wide + k]
            if fileID and fileID > 0 then
                local pixelW, fileW = tileW, tileW
                if k == wide then
                    pixelW = width % tileW
                    if pixelW == 0 then pixelW = tileW end
                    fileW = FileSize(pixelW)
                end
                local t = Acquire()
                t:SetSize(pixelW, pixelH)
                t:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                t:SetPoint("TOPLEFT", holder, "TOPLEFT",
                    offsetX + tileW * (k - 1), -(offsetY + tileH * (j - 1)))
                t:SetTexture(fileID, nil, nil, "TRILINEAR")
                if tint then
                    t:SetVertexColor(TINT[1], TINT[2], TINT[3], TINT[4])
                else
                    t:SetVertexColor(1, 1, 1, 1)
                end
                ApplyMask(map, t)
                t:Show()
            end
        end
    end
end

local function Redraw(map, mapID, layer)
    ReleaseAll()
    if not (Enabled() and mapID) then return end
    local zone = ZoneFor(mapID)
    if not zone then return end
    local keys, offsets, files = Explored(mapID)
    if not keys then return end

    local layers = Call(C_Map and C_Map.GetMapArtLayers, mapID)
    local info = type(layers) == "table" and not IsSecret(layers) and layers[layer] or nil
    if type(info) ~= "table" then return end
    local tileW, tileH = Number(info.tileWidth), Number(info.tileHeight)
    if not (tileW and tileH and tileW > 0 and tileH > 0) then return end

    -- Just below Blizzard's exploration pin, so explored art wins any overlap.
    local pin = FindExplorationPin(map)
    local level = pin and Number(Call(pin.GetFrameLevel, pin))
    if level and level > 1 then pcall(holder.SetFrameLevel, holder, level - 1) end

    local tint = ns.db.mapRevealTint and true or false
    for _, o in ipairs(zone) do
        local explored = keys[o[1] .. ":" .. o[2] .. ":" .. o[3] .. ":" .. o[4]]
            or offsets[o[3] .. ":" .. o[4]]
        if not explored then
            for i = 5, #o do
                if files[o[i]] then explored = true; break end
            end
        end
        if not explored then DrawOverlay(map, o, tileW, tileH, tint) end
    end
end

local function OnUpdate()
    local map = Map()
    if not map then return end
    -- Fade in and out with the exploration pin (it waits at alpha 0 until
    -- the map's textures have loaded).
    local pin = FindExplorationPin(map)
    local alpha = pin and Number(Call(pin.GetAlpha, pin))
    if alpha then holder:SetAlpha(alpha) end

    local mapID = CurrentMapID(map)
    local layer = CurrentLayer(map)
    if dirty or mapID ~= shownMapID or layer ~= shownLayer then
        dirty = false
        shownMapID, shownLayer = mapID, layer
        local ok = pcall(Redraw, map, mapID, layer)
        if not ok then ReleaseAll() end
    end
end

local function Build()
    if holder then return true end
    local map = Map()
    if not map then return false end
    holder = CreateFrame("Frame", nil, map.ScrollContainer.Child)
    holder:SetAllPoints(map.ScrollContainer.Child)
    holder:EnableMouse(false)
    holder:SetScript("OnUpdate", OnUpdate)
    holder:SetShown(Enabled())
    return true
end

-- Option changes and settings restores: show or hide and redraw next frame.
local function Refresh()
    if not holder then
        if not Enabled() then return end
        if InCombatLockdown and InCombatLockdown() then
            -- Our frame is plain, but create it outside of combat anyway.
            dirty = true
            return
        end
        if not Build() then return end
    end
    dirty = true
    holder:SetShown(Enabled())
    if not Enabled() then ReleaseAll() end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
ns.SafeRegisterEvent(events, "MAP_EXPLORATION_UPDATED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "MAP_EXPLORATION_UPDATED" then
        dirty = true
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_WorldMap" then Refresh() end
    else   -- PLAYER_LOGIN, PLAYER_REGEN_ENABLED (a build deferred by combat)
        if ns.db and not holder then Refresh() end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key     = "mapReveal",
    label   = "Map Reveal",
    group   = "Interface",
    summary = "Shows the parts of the world map you have not explored yet.",
    icon    = "Interface\\Icons\\Ability_Hunter_EagleEye",
    reinitSafe = true,   -- OnInit only redraws from ns.db; safe to run again after a late restore
    options = {
        { key = "mapReveal", label = "Show unexplored areas", default = true,
          tooltip = "Shows the parts of each zone you have not explored yet on the world map, so the whole zone is visible. Exploration itself is unchanged.",
          onChange = function() Refresh() end },
        { key = "mapRevealTint", parent = "mapReveal", label = "Tint unexplored areas", default = true,
          tooltip = "Gives the unexplored areas a faint purple tint, so you can still tell them apart from the places you have been.",
          onChange = function() Refresh() end },
    },
    OnInit = function()
        Refresh()
    end,
})
