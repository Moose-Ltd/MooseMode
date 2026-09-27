-------------------------------------------------------------------------------
-- MooseMode -- Map
--
-- World map helpers:
--   * /way x y [note] and /way reset (also /mm way ...): sets the game's own
--     user waypoint on the map you are in and super-tracks it, so the native
--     map pin and on-screen marker show. Accepts "45 67", "45,67", "45, 67"
--     and "45.5 67.2". The bare /way is only registered when no other addon
--     (TomTom and friends) already owns it.
--   * Coordinates bar, Leatrix Maps style: a thin band along the bottom of
--     the world map with your position and the position under the cursor,
--     live. Our own frame and font strings; positions are read from our own
--     code (C_Map.GetPlayerMapPosition, the scroll container's
--     GetNormalizedCursorPosition), so no game setting is written.
--   * Fade while moving (mapFade) as a three-way choice; the default "Game"
--     writes nothing. "On" / "Off" remember the character's value first
--     (ns.CVar.ApplyWithSnapshot) and going back to "Game" puts it back.
--   * Hide the reading emote when the map opens.
--   * Travel icons: classic-era boats, zeppelins and the Deeprun Tram on the
--     continent and zone maps, with a tooltip naming the destination.
--
-- How, and why this way (secret values / taint):
--   Blizzard code that reads a secret value errors once addon code has
--   tainted its execution, so nothing of Blizzard's is written to here.
--   * No data provider. MapCanvasMixin:AddDataProvider / AcquirePin would
--     store our provider, pin pool and pin template type in the canvas's own
--     tables (dataProviders, pinPools, pinTemplateTypes), queue our pins in
--     pinsToNudge and set the ScrollContainer dirty flag from addon code;
--     those are read every frame by the canvas code that also drives the
--     secret-aware providers (group members, vignettes, area POIs). Pins
--     also need an XML template. Instead the icons live on one plain frame
--     parented to WorldMapFrame.ScrollContainer.Child (the canvas), laid out
--     by this file (same maths as MapCanvasMixin:ApplyPinPosition), exactly
--     like MapReveal.lua. Its OnUpdate only runs while the map is open and
--     notices map / size / zoom changes by polling.
--   * Pins take mouse motion only (for the tooltip); clicks, drags and the
--     wheel fall through to the map. The tooltip is our own GameTooltip, so
--     Blizzard's shared GameTooltip is never driven from here.
--   * The reading emote: Blizzard calls C_ChatInfo.PerformEmote("READ") in
--     WorldMapMixin:OnShow. Leatrix post-hooks C_ChatInfo.PerformEmote;
--     that hook would run inside Blizzard's OnShow. Here a standalone frame
--     (not parented to anything of Blizzard's) polls WorldMapFrame:IsShown()
--     in its own OnUpdate and calls C_ChatInfo.CancelEmote() on the frame
--     after the map opens, from its own call stack. No hook at all.
--   * CVars are written with C_CVar.SetCVar through ns.CVar (as Graphics
--     does), only when the player picks On / Off, and only when the value
--     differs.
--   * Blizzard's methods are only called to read state (GetMapID, IsShown,
--     sizes, scales), inside pcall.
--
-- Options (account-wide):
--   mapTravel          Travel icons
--   mapTravelFaction   Only my faction (sub-option)
--   mapCoords          Coordinates bar
--   mapFadeChoice      Fade while moving: game / on / off  (mapFade)
--   mapNoEmote         Hide the reading emote
--   mapWaySlash        Register /way when free
-- Snapshots (ns.CVar.ApplyWithSnapshot): mapPrevFade. Earlier dev builds
-- also drove the native coordinate CVars (mapPrevPlayerCoords,
-- mapPrevCursorCoords); ApplyAll puts those values back once.
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

-- A plain, non-secret number, or nil.
local function Number(v)
    if v == nil or ns.IsSecret(v) or type(v) ~= "number" then return nil end
    return v
end

local function Map()
    local map = WorldMapFrame
    if map and map.ScrollContainer and map.ScrollContainer.Child then return map end
    return nil
end

local function PlayerFaction()
    local faction = Call(UnitFactionGroup, "player")
    if faction == nil or ns.IsSecret(faction) then return nil end
    return faction   -- "Alliance", "Horde" or "Neutral" (unchosen Pandaren)
end

-------------------------------------------------------------------------------
-- Waypoints (/way)
-------------------------------------------------------------------------------

local function MapName(mapID)
    local info = C_Map and Call(C_Map.GetMapInfo, mapID)
    local name = info and info.name
    if type(name) == "string" and not ns.IsSecret(name) then return name end
    return "map " .. tostring(mapID)
end

local function PlayerMapID()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    return Number(Call(C_Map.GetBestMapForUnit, "player"))
end

local WAY_USAGE = "/way x y [note] sets a waypoint on the map you are in (\"45 67\", \"45,67\" or \"45.5 67.2\"). /way reset clears it."

-- "45 67 note", "45,67 note", "45, 67", "45.5 67.2" -> x, y, note
local function ParseCoords(text)
    local x, y, rest = text:match("^(%d+%.?%d*)%s*[,%s]%s*(%d+%.?%d*)%s*(.-)$")
    x, y = tonumber(x), tonumber(y)
    if not (x and y) then return nil end
    return x, y, rest
end

local function ClearWaypoint(quiet)
    -- MooseMode's own pin (Waypoint Arrow module) and the game's, if any.
    local hadOwn = ns.NavClearPin and ns.NavClearPin() or false
    local hadGame = false
    if C_Map and C_Map.ClearUserWaypoint then
        hadGame = (C_Map.HasUserWaypoint and Call(C_Map.HasUserWaypoint)) and true or false
        pcall(C_Map.ClearUserWaypoint)
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
        end
    end
    if not quiet then
        ns.Print((hadOwn or hadGame) and "Waypoint cleared." or "No waypoint to clear.")
    end
end

-- The game's own pin, as a bonus: Forever can switch map pins off with a
-- game rule, so a refusal here is not an error.
local function TrySetGameWaypoint(mapID, x, y)
    if not (C_Map and C_Map.SetUserWaypoint) then return false end
    if C_Map.CanSetUserWaypointOnMap and Call(C_Map.CanSetUserWaypointOnMap, mapID) == false then return false end
    local point
    if UiMapPoint and UiMapPoint.CreateFromCoordinates then
        point = Call(UiMapPoint.CreateFromCoordinates, mapID, x, y)
    end
    if not point then return false end
    if not pcall(C_Map.SetUserWaypoint, point) then return false end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        local native = (not ns.NavWantsNativeMarker) or ns.NavWantsNativeMarker()
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, native and true or false)
    end
    return true
end

local function SetWaypoint(x, y, note)
    if x < 0 or x > 100 or y < 0 or y > 100 then
        ns.Print("Coordinates go from 0 to 100, e.g. /way 45.2 67.8")
        return
    end
    local mapID = PlayerMapID()
    if not mapID then
        ns.Print("Can't tell which map you are on here, so no waypoint was set.")
        return
    end
    local own = ns.NavSetPin and ns.NavSetPin(mapID, x / 100, y / 100) or false
    local game = (not own) and TrySetGameWaypoint(mapID, x / 100, y / 100)
    if not (own or game) then
        ns.Print("Couldn't set a waypoint on " .. MapName(mapID) .. ".")
        return
    end
    local msg = ("Waypoint set: %s %.1f, %.1f"):format(MapName(mapID), x, y)
    if note and note ~= "" then msg = msg .. " - " .. note end
    ns.Print(msg)
end

local function WayCommand(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = rest:lower()
    if lower == "" or lower == "help" then
        ns.Print(WAY_USAGE)
        return
    end
    if lower == "reset" or lower == "clear" or lower == "off" then
        ClearWaypoint(false)
        return
    end
    local x, y, note = ParseCoords(rest)
    if not x then
        ns.Print(WAY_USAGE)
        return
    end
    SetWaypoint(x, y, note)
end

-- The bare /way. Several addons (TomTom, and addons that bundle it) own it,
-- so it is only taken when nobody else has: no other SLASH_* global says
-- "/way", the chat hash has no entry for it, it is not a secure command,
-- and TomTom is not loaded. Checked at PLAYER_LOGIN, when every addon that
-- loads at start-up has registered its commands.
local WAY_CMD = "MOOSEMODEWAY"
local wayRegistered = false

local function WayOwnedElsewhere()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded and Call(isLoaded, "TomTom") then return "TomTom" end
    if IsSecureCmd and Call(IsSecureCmd, "/way") then return "the game" end
    if type(hash_SlashCmdList) == "table" and rawget(hash_SlashCmdList, "/WAY") then return "another addon" end
    local owner
    pcall(function()
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "string" and k:sub(1, 6) == "SLASH_"
               and k:sub(7, 6 + #WAY_CMD) ~= WAY_CMD and v:lower() == "/way" then
                owner = k:match("^SLASH_(.-)%d+$") or k
                break
            end
        end
    end)
    return owner
end

local function RegisterWaySlash(announce)
    if wayRegistered or not (ns.db and ns.db.mapWaySlash) then return end
    local owner = WayOwnedElsewhere()
    if owner then
        if announce then ns.Print("/way already belongs to " .. owner .. "; use /mm way instead.") end
        return
    end
    _G["SLASH_" .. WAY_CMD .. "1"] = "/way"
    SlashCmdList[WAY_CMD] = function(msg)
        if ns.db and ns.db.mapWaySlash then
            WayCommand(msg)
        else
            ns.Print("/way is switched off in MooseMode's Map options; /mm way still works.")
        end
    end
    wayRegistered = true
    if announce then ns.Print("/way is ready.") end
end

-------------------------------------------------------------------------------
-- Native map settings (CVars)
-------------------------------------------------------------------------------

local CVARS = {
    { opt = "mapFadeChoice",   cvar = "mapFade",                  snap = "mapPrevFade" },
}
-- Dropped in favour of the coordinates bar: put the character's own values
-- back if an earlier build changed them, then forget the options.
local RETIRED_CVARS = {
    { opt = "mapPlayerCoords", cvar = "worldMapShowPlayerCoords", snap = "mapPrevPlayerCoords" },
    { opt = "mapCursorCoords", cvar = "worldMapShowCursorCoords", snap = "mapPrevCursorCoords" },
}
local function RetireCoordCVars()
    for _, c in ipairs(RETIRED_CVARS) do
        if ns.db[c.snap] ~= nil and ns.CVar.Exists(c.cvar) then
            ns.CVar.ApplyWithSnapshot(c.cvar, nil, c.snap, false)
        end
        ns.db[c.snap], ns.db[c.opt] = nil, nil
    end
end
local CVAR_BY_OPT = {}
for _, c in ipairs(CVARS) do CVAR_BY_OPT[c.opt] = c end

-- "game": put back what the character had (if we changed it) and stop.
-- "on" / "off": remember the character's value once, then write 1 / 0.
local function ApplyCVarChoice(optKey)
    local c = CVAR_BY_OPT[optKey]
    if not (c and ns.db) or not ns.CVar.Exists(c.cvar) then return end
    local choice = ns.db[optKey]
    if choice == "on" then
        ns.CVar.ApplyWithSnapshot(c.cvar, "1", c.snap, true)
    elseif choice == "off" then
        ns.CVar.ApplyWithSnapshot(c.cvar, "0", c.snap, true)
    else
        ns.CVar.ApplyWithSnapshot(c.cvar, nil, c.snap, false)
    end
end

local CHOICES = {
    { value = "game", text = "Game" },
    { value = "on",   text = "On" },
    { value = "off",  text = "Off" },
}

-------------------------------------------------------------------------------
-- Coordinates bar
-------------------------------------------------------------------------------

local COORDS_POLL = 0.05
local coordsBar

local function PlainNumber(v)
    return type(v) == "number" and not ns.IsSecret(v)
end

local function Fmt(label, x, y)
    if not (PlainNumber(x) and PlainNumber(y)) or x <= 0 or y <= 0 or x >= 1 or y >= 1 then
        return label .. ": |cff9d9d9d-|r"
    end
    return string.format("%s: |cffffffff%.1f, %.1f|r", label, x * 100, y * 100)
end

-- Your position on the map being viewed (a zone or a continent), or nil.
local function PlayerXY(mapID)
    if not (C_Map and C_Map.GetPlayerMapPosition) or not PlainNumber(mapID) then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local okXY, x, y = pcall(pos.GetXY, pos)
    if okXY then return x, y end
    return nil
end

local function CursorXY(container)
    local okOver, over = pcall(container.IsMouseOver, container)
    if not okOver or not over or not container.GetNormalizedCursorPosition then return nil end
    local ok, x, y = pcall(container.GetNormalizedCursorPosition, container)
    if ok then return x, y end
    return nil
end

local function ViewedMapID()
    if not (WorldMapFrame and WorldMapFrame.GetMapID) then return nil end
    local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok then return id end
    return nil
end

local function BuildCoordsBar()
    if coordsBar or not (WorldMapFrame and WorldMapFrame.ScrollContainer) then return end
    local container = WorldMapFrame.ScrollContainer
    local bar = CreateFrame("Frame", nil, container)
    bar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    bar:SetHeight(18)
    bar:EnableMouse(false)
    local okLvl, lvl = pcall(container.GetFrameLevel, container)
    bar:SetFrameLevel(((okLvl and lvl) or 1) + 50)

    local band = bar:CreateTexture(nil, "BACKGROUND")
    band:SetAllPoints()
    band:SetColorTexture(0, 0, 0, 0.55)

    bar.player = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.player:SetPoint("LEFT", bar, "LEFT", 12, 0)
    bar.cursor = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.cursor:SetPoint("RIGHT", bar, "RIGHT", -12, 0)

    local since = COORDS_POLL
    bar:SetScript("OnUpdate", function(self, elapsed)
        since = since + (elapsed or 0)
        if since < COORDS_POLL then return end
        since = 0
        self.player:SetText(Fmt("Player", PlayerXY(ViewedMapID())))
        self.cursor:SetText(Fmt("Cursor", CursorXY(container)))
    end)
    coordsBar = bar
end

local function RefreshCoords()
    if not ns.db then return end
    if ns.db.mapCoords then
        BuildCoordsBar()
        if coordsBar then coordsBar:Show() end
    elseif coordsBar then
        coordsBar:Hide()
    end
end

-------------------------------------------------------------------------------
-- Reading emote
-------------------------------------------------------------------------------

local emoteWatch = CreateFrame("Frame")
local mapWasShown = false

local function EmoteWatch_OnUpdate()
    local map = WorldMapFrame
    local shown = map and Call(map.IsShown, map) and true or false
    if shown and not mapWasShown and C_ChatInfo and C_ChatInfo.CancelEmote then
        pcall(C_ChatInfo.CancelEmote)
    end
    mapWasShown = shown
end

local function ApplyNoEmote()
    local on = ns.db and ns.db.mapNoEmote and C_ChatInfo and C_ChatInfo.CancelEmote
    if on then
        local map = WorldMapFrame
        mapWasShown = map and Call(map.IsShown, map) and true or false
        emoteWatch:SetScript("OnUpdate", EmoteWatch_OnUpdate)
    else
        emoteWatch:SetScript("OnUpdate", nil)
    end
end

-------------------------------------------------------------------------------
-- Travel icons: data
--
-- Classic-era (1.12) routes only. Coordinates are percent on that uiMapID,
-- checked against in-game positions and HandyNotes: TravelGuide (Classic).
-- Not included, because they did not exist before later expansions: the
-- Stormwind Harbor boats, Auberdine-Azuremyst boat, Orgrimmar-Thunder Bluff
-- zeppelin (so Thunder Bluff and Orgrimmar city maps have no entries; the
-- Orgrimmar towers stand in Durotar) and every city portal. The Darnassus /
-- Rut'theran portal did exist but is left out until its position is verified.
--
-- { x, y, kind, faction, { destination, ... } }
--   kind:    "boat" | "zeppelin" | "tram"
--   faction: "Alliance" | "Horde" | "Neutral"
-------------------------------------------------------------------------------

local A, H, N = "Alliance", "Horde", "Neutral"

local TRAVEL = {
    -- Eastern Kingdoms (continent)
    [1415] = {
        { 47.5, 47.9, "boat",     A, { "Auberdine, Darkshore", "Theramore Isle, Dustwallow Marsh" } },
        { 43.8, 92.7, "boat",     N, { "Ratchet, The Barrens" } },
        { 44.7, 23.0, "zeppelin", H, { "Orgrimmar, Durotar", "Grom'gol, Stranglethorn Vale" } },
        { 44.9, 84.8, "zeppelin", H, { "Orgrimmar, Durotar", "Undercity, Tirisfal Glades" } },
        { 44.0, 67.4, "tram",     A, { "Ironforge" } },
        { 49.2, 52.4, "tram",     A, { "Stormwind City" } },
    },
    -- Kalimdor (continent)
    [1414] = {
        { 44.3, 25.3, "boat",     A, { "Menethil Harbor, Wetlands", "Rut'theran Village, Teldrassil" } },
        { 43.6, 17.3, "boat",     A, { "Auberdine, Darkshore" } },
        { 59.3, 68.5, "boat",     A, { "Menethil Harbor, Wetlands" } },
        { 56.8, 56.2, "boat",     N, { "Booty Bay, Stranglethorn Vale" } },
        { 59.0, 46.7, "zeppelin", H, { "Undercity, Tirisfal Glades", "Grom'gol, Stranglethorn Vale" } },
    },
    -- Wetlands: Menethil Harbor
    [1437] = {
        { 4.6, 57.1, "boat", A, { "Auberdine, Darkshore" } },
        { 5.0, 63.5, "boat", A, { "Theramore Isle, Dustwallow Marsh" } },
    },
    -- Darkshore: Auberdine
    [1439] = {
        { 32.4, 43.8, "boat", A, { "Menethil Harbor, Wetlands" } },
        { 33.2, 40.1, "boat", A, { "Rut'theran Village, Teldrassil" } },
    },
    -- Teldrassil: Rut'theran Village
    [1438] = {
        { 54.9, 96.8, "boat", A, { "Auberdine, Darkshore" } },
    },
    -- Dustwallow Marsh: Theramore Isle
    [1445] = {
        { 71.6, 56.5, "boat", A, { "Menethil Harbor, Wetlands" } },
    },
    -- The Barrens: Ratchet
    [1413] = {
        { 63.7, 38.6, "boat", N, { "Booty Bay, Stranglethorn Vale" } },
    },
    -- Stranglethorn Vale: Booty Bay and Grom'gol
    [1434] = {
        { 25.9, 73.1, "boat",     N, { "Ratchet, The Barrens" } },
        { 31.4, 30.2, "zeppelin", H, { "Orgrimmar, Durotar" } },
        { 31.6, 29.1, "zeppelin", H, { "Undercity, Tirisfal Glades" } },
    },
    -- Tirisfal Glades: the towers outside Undercity
    [1420] = {
        { 60.7, 58.8, "zeppelin", H, { "Orgrimmar, Durotar" } },
        { 61.9, 59.1, "zeppelin", H, { "Grom'gol, Stranglethorn Vale" } },
    },
    -- Durotar: the towers outside Orgrimmar
    [1411] = {
        { 50.6, 12.7, "zeppelin", H, { "Grom'gol, Stranglethorn Vale" } },
        { 50.8, 13.9, "zeppelin", H, { "Undercity, Tirisfal Glades" } },
    },
    -- Deeprun Tram
    [1453] = { { 63.9,  8.2, "tram", A, { "Ironforge" } } },        -- Stormwind City, Dwarven District
    [1429] = { { 29.2, 17.8, "tram", A, { "Ironforge" } } },        -- Elwynn Forest (Stormwind)
    [1455] = { { 77.0, 51.5, "tram", A, { "Stormwind City" } } },   -- Ironforge, Tinker Town
    [1426] = { { 63.4, 29.4, "tram", A, { "Stormwind City" } } },   -- Dun Morogh (Ironforge)
}

local KIND_TEXT = { boat = "Boat", zeppelin = "Zeppelin", tram = "Deeprun Tram" }

local FACTION_RGB = {
    Alliance = { 0.35, 0.60, 1.00 },
    Horde    = { 1.00, 0.30, 0.25 },
    Neutral  = { 1.00, 0.82, 0.00 },
}

-- Atlas candidates per kind and faction (first that exists wins); the
-- fallback is a classic taxi dot tinted in the faction colour.
local ATLASES = {
    boat = {
        Alliance = { "islands-allianceboat" },
        Horde    = { "islands-hordeboat" },
        Neutral  = { "islands-allianceboat", "islands-hordeboat" },
    },
    zeppelin = {
        Alliance = { "vehicle-air-alliance" },
        Horde    = { "vehicle-air-horde" },
        Neutral  = { "vehicle-air-horde" },
    },
    tram = {
        Alliance = { "vehicle-alliancecart", "vehicle-silvershardmines-minecart" },
        Horde    = { "vehicle-hordecart", "vehicle-silvershardmines-minecart" },
        Neutral  = { "vehicle-silvershardmines-minecart" },
    },
}
local FALLBACK_TEXTURE = "Interface\\TaxiFrame\\UI-Taxi-Icon-White"

local atlasCache = {}
local function AtlasFor(kind, faction)
    local key = kind .. faction
    if atlasCache[key] ~= nil then return atlasCache[key] or nil end
    local found = false
    local list = ATLASES[kind] and ATLASES[kind][faction] or {}
    if C_Texture and C_Texture.GetAtlasInfo then
        for _, name in ipairs(list) do
            if Call(C_Texture.GetAtlasInfo, name) then found = name; break end
        end
    end
    atlasCache[key] = found
    return found or nil
end

-------------------------------------------------------------------------------
-- Travel icons: drawing
-------------------------------------------------------------------------------

local PIN_SIZE = 24          -- UIParent units, whatever the zoom
local PIN_LEVEL_FALLBACK = 2020

local layer                  -- our frame on the canvas
local tooltip                -- our own GameTooltip
local pins = {}              -- pool of our pin frames
local shown = {}             -- active entries: { pin = frame, entry = data }
local dirty = true
local lastMapID, lastW, lastH, lastScale

local function TravelEnabled()
    return ns.db and ns.db.mapTravel and true or false
end

local function GetTooltip()
    if tooltip then return tooltip end
    local ok, tt = pcall(CreateFrame, "GameTooltip", "MooseModeMapTooltip", UIParent, "GameTooltipTemplate")
    if ok and tt then
        tt:SetFrameStrata("TOOLTIP")
        tooltip = tt
    end
    return tooltip
end

local function Pin_OnEnter(self)
    local e = self.entry
    local tt = GetTooltip()
    if not (e and tt) then return end
    tt:SetOwner(self, "ANCHOR_RIGHT")
    local rgb = FACTION_RGB[e[4]] or FACTION_RGB.Neutral
    local kind = KIND_TEXT[e[3]] or "Transport"
    for i, dest in ipairs(e[5]) do
        if i == 1 then
            tt:AddLine(kind .. " to " .. dest, rgb[1], rgb[2], rgb[3])
        else
            tt:AddLine("Also to " .. dest, rgb[1], rgb[2], rgb[3])
        end
    end
    tt:AddLine(e[4] == "Neutral" and "Both factions" or e[4], 0.8, 0.8, 0.8)
    tt:Show()
end

local function Pin_OnLeave()
    if tooltip then tooltip:Hide() end
end

local function PinLevel(map)
    local mgr = Call(map.GetPinFrameLevelsManager, map)
    local level = mgr and Number(Call(mgr.GetFrameLevelStart, mgr, "PIN_FRAME_LEVEL_FLIGHT_POINT"))
    return level or PIN_LEVEL_FALLBACK
end

local function NewPin()
    local pin = CreateFrame("Frame", nil, layer)
    pin:SetSize(PIN_SIZE, PIN_SIZE)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints()
    pin.glow = pin:CreateTexture(nil, "HIGHLIGHT")
    pin.glow:SetAllPoints()
    pin.glow:SetBlendMode("ADD")
    pin.glow:SetAlpha(0.35)
    -- Motion only, so clicks, drags and the wheel still reach the map.
    if pin.SetMouseMotionEnabled then
        pin:SetMouseMotionEnabled(true)
        if pin.SetMouseClickEnabled then pin:SetMouseClickEnabled(false) end
    else
        pin:EnableMouse(true)
    end
    pin:SetScript("OnEnter", Pin_OnEnter)
    pin:SetScript("OnLeave", Pin_OnLeave)
    return pin
end

local function PaintPin(pin, e)
    local kind, faction = e[3], e[4]
    local atlas = AtlasFor(kind, faction)
    local rgb = FACTION_RGB[faction] or FACTION_RGB.Neutral
    for _, tex in ipairs({ pin.icon, pin.glow }) do
        tex:SetDesaturated(false)
        tex:SetVertexColor(1, 1, 1)
        if atlas then
            tex:SetAtlas(atlas)
        else
            tex:SetTexture(FALLBACK_TEXTURE)
            tex:SetTexCoord(0, 1, 0, 1)
            tex:SetVertexColor(rgb[1], rgb[2], rgb[3])
        end
    end
    -- One atlas stands in for neutral boats: tint it gold.
    if atlas and faction == "Neutral" and kind == "boat" then
        pin.icon:SetDesaturated(true)
        pin.icon:SetVertexColor(rgb[1], rgb[2], rgb[3])
    end
end

local function ReleaseAll()
    for i = #shown, 1, -1 do
        local s = shown[i]
        s.pin:Hide()
        s.pin.entry = nil
        pins[#pins + 1] = s.pin
        shown[i] = nil
    end
    if tooltip then tooltip:Hide() end
end

local function Visible(e, faction)
    if not (ns.db and ns.db.mapTravelFaction) then return true end
    if e[4] == "Neutral" or not faction or faction == "Neutral" then return true end
    return e[4] == faction
end

local function Rebuild(map, mapID)
    ReleaseAll()
    local list = mapID and TRAVEL[mapID]
    if not list then return end
    local faction = PlayerFaction()
    local level = PinLevel(map)
    for _, e in ipairs(list) do
        if Visible(e, faction) then
            local pin = table.remove(pins) or NewPin()
            pin.entry = e
            PaintPin(pin, e)
            pin:SetFrameLevel(level)
            shown[#shown + 1] = { pin = pin, entry = e }
        end
    end
end

-- Same maths as MapCanvasMixin:ApplyPinPosition: a point on the canvas,
-- offsets divided by the pin's own scale. The scale keeps the icon at
-- PIN_SIZE UIParent units whatever the zoom.
local function Layout(w, h)
    if #shown == 0 then return end
    local ui = UIParent and UIParent:GetEffectiveScale() or 1
    local here = layer:GetEffectiveScale()
    if not here or here <= 0 then return end
    local scale = ui / here
    for _, s in ipairs(shown) do
        local pin, e = s.pin, s.entry
        pin:SetScale(scale)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", layer, "TOPLEFT", (w * e[1] / 100) / scale, -(h * e[2] / 100) / scale)
        pin:Show()
    end
end

local function Layer_OnUpdate()
    local map = Map()
    if not map then return end
    local canvas = map.ScrollContainer.Child
    local mapID = Number(Call(map.GetMapID, map))
    local w = Number(Call(canvas.GetWidth, canvas))
    local h = Number(Call(canvas.GetHeight, canvas))
    local scale = Number(Call(canvas.GetEffectiveScale, canvas))
    if not (w and h and scale) then return end
    if dirty or mapID ~= lastMapID then
        dirty = false
        lastMapID = mapID
        lastW = nil   -- force a layout below
        if not pcall(Rebuild, map, mapID) then ReleaseAll() end
    end
    if w ~= lastW or h ~= lastH or scale ~= lastScale then
        lastW, lastH, lastScale = w, h, scale
        if not pcall(Layout, w, h) then ReleaseAll() end
    end
end

local function BuildLayer()
    if layer then return true end
    local map = Map()
    if not map then return false end
    layer = CreateFrame("Frame", nil, map.ScrollContainer.Child)
    layer:SetAllPoints(map.ScrollContainer.Child)
    layer:EnableMouse(false)
    layer:SetScript("OnUpdate", Layer_OnUpdate)
    return true
end

-- Option changes, login, faction change: show or hide, redraw next frame.
local function RefreshTravel()
    if not layer then
        if not TravelEnabled() then return end
        if InCombatLockdown and InCombatLockdown() then dirty = true; return end
        if not BuildLayer() then return end
    end
    dirty = true
    layer:SetShown(TravelEnabled())
    if not TravelEnabled() then ReleaseAll() end
end

-------------------------------------------------------------------------------
-- Login / events
-------------------------------------------------------------------------------

local function ApplyAll()
    if not ns.db then return end
    RetireCoordCVars()
    for _, c in ipairs(CVARS) do ApplyCVarChoice(c.opt) end
    RefreshCoords()
    ApplyNoEmote()
    RefreshTravel()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
ns.SafeRegisterEvent(events, "NEUTRAL_FACTION_SELECT_RESULT")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_WorldMap" and ns.db then RefreshTravel(); RefreshCoords() end
    elseif event == "PLAYER_LOGIN" then
        -- While a late settings restore is pending, ns.db holds defaults:
        -- Core re-runs OnInit (reinitSafe) on the real values.
        if ns.db and not (ns.SettingsRestorePending and ns.SettingsRestorePending()) then
            ApplyAll()
        end
        RegisterWaySlash(false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if ns.db and not layer and TravelEnabled() then RefreshTravel() end
    else   -- NEUTRAL_FACTION_SELECT_RESULT
        dirty = true
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

local function CVarMissing(opt)
    local c = CVAR_BY_OPT[opt.key]
    return not (c and ns.CVar.Exists(c.cvar))
end

ns:RegisterModule({
    key     = "mapModule",
    label   = "Map",
    group   = "Interface",
    summary = "Coordinates, travel icons, waypoint arrow.",
    icon    = "Interface\\Icons\\INV_Misc_Map02",
    master  = false,
    reinitSafe = true,   -- OnInit only applies state from ns.db; safe to run again after a late restore
    options = {
        { key = "mapCoords", label = "Coordinates bar", default = true,
          tooltip = "Your position and the cursor's, along the bottom of the world map.",
          onChange = function() RefreshCoords() end },
        { key = "mapTravel", label = "Travel icons", default = true,
          tooltip = "Boats, zeppelins and the tram, with destinations.",
          onChange = function() RefreshTravel() end },
        { key = "mapTravelFaction", label = "Only my faction", default = true, parent = "mapTravel",
          onChange = function() dirty = true end },
        { key = "navArrow", label = "Waypoint arrow", default = true,
          tooltip = "Ctrl+click the map (or /way x y) to set a pin; Ctrl+click it to remove. Also follows a focused quest.",
          onChange = function() if ns.NavRefresh then ns.NavRefresh() end end },
        { key = "navAutoClear", label = "Clear pin on arrival", default = true, parent = "navArrow" },
        { key = "navLocked", label = "Lock arrow", default = false, parent = "navArrow",
          tooltip = "Or right-click the arrow." },
        { type = "button", label = "Arrow position", buttonText = "Reset", parent = "navArrow",
          onClick = function() if ns.NavResetPosition then ns.NavResetPosition() end end },
        { type = "choice", key = "mapFadeChoice", label = "Fade while moving", default = "game",
          values = CHOICES, hidden = CVarMissing,
          tooltip = "Game leaves your own setting alone.",
          onChange = function() ApplyCVarChoice("mapFadeChoice") end },
        { key = "mapNoEmote", label = "Hide reading emote", default = false,
          onChange = function() ApplyNoEmote() end },
        { key = "mapWaySlash", label = "/way command", default = true,
          tooltip = "Skipped if another addon owns /way; /mm way always works.",
          onChange = function(checked) if checked then RegisterWaySlash(true) end end },
    },
    commands = {
        way = function(rest) WayCommand(rest) end,
    },
    OnInit = function()
        -- PLAYER_LOGIN may already have fired if the addon was loaded late.
        if IsLoggedIn and IsLoggedIn() then
            ApplyAll()
            RegisterWaySlash(false)
        end
    end,
})
