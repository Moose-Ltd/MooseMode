-------------------------------------------------------------------------------
-- MooseMode -- SwingTimer
--
-- One main-hand melee swing bar for melee classes. By default it sits just
-- under the player frame (portrait) and follows it wherever that frame goes;
-- once dragged, the saved spot wins until /mm swing reset.
--
-- Where swings come from (see docs/swing-timer-research.md):
--   1. PLAYER_SWING (swingDuration, swingType). Forever's native swing event,
--      the same one Blizzard's own bar uses. The server has already applied
--      misses, dodges, parries and extra attacks.
--   2. Fallback when PLAYER_SWING is missing: COMBAT_LOG_EVENT_UNFILTERED
--      SWING_DAMAGE / SWING_MISSED with the player as source. Only used if
--      registering it succeeds (12.x clients refuse it).
--   Neither available: the module says so once and stays hidden.
--   Off-hand swings (PLAYER_SWING OffHand, or the combat log's isOffHand
--   flag) are recognised and ignored, so they never restart the main hand.
--
-- Corrections between swings, overwritten by the next real swing event:
--   - UNIT_ATTACK_SPEED rescales the time left by newSpeed / oldSpeed.
--   - Swapping the main-hand weapon while fighting restarts the swing.
--   - Parry haste (UNIT_COMBAT "PARRY" on the player): the swing ends 40% of
--     the weapon's speed sooner, but never with less than 20% of it left.
--   - A cast-time spell (Slam, heals, Lightning Bolt, ...) freezes the bar
--     while it casts and restarts the swing when it completes.
--   - Heroic Strike, Cleave, Maul and Raptor Strike replace the next swing.
--     They restart the bar on UNIT_SPELLCAST_SUCCEEDED, but only when no
--     real main-hand swing arrives within SWING_MATCH seconds, so a client
--     that reports them as swings too is not counted twice. Seal of Command
--     procs and other instant spells are not swings and never restart.
--
-- On by default for Rogues, Warriors, Paladins and Shamans, and for Druids
-- in Cat or Bear Form. "Show on every class" opts everyone else in.
--
-- Options (account-wide):
--   swingTimer              Swing timer bar
--   swingTimerShowOOC       Show out of combat (sub-option)
--   swingTimerParryHaste    Parry haste (sub-option)
--   swingTimerCastReset     Casts restart the swing (sub-option)
--   swingTimerAllClasses    Show on every class (sub-option)
--   swingTimerSize          Bar size: small / medium / large (choice)
--   swingTimerPos           { x, y, custom } set by dragging; without
--                           custom = true the bar sits under the player frame
--
-- Commands:
--   /mm swing               unlock / lock the bar for moving
--   /mm swing test          one demo swing
--   /mm swing reset         back under the player frame
--   /mm swing status        which swing source is in use, speed, state
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local MELEE_CLASSES = { ROGUE = true, WARRIOR = true, PALADIN = true, SHAMAN = true, DRUID = true }
local DRUID_MELEE_FORMS = { [1] = true, [5] = true, [8] = true }   -- Cat, Bear, Dire Bear

-- Spells that replace the next white swing, by id (names are looked up
-- in the client's language) plus English names for ranks the ids miss.
local NEXT_MELEE_IDS   = { 78, 845, 6807, 2973 }   -- Heroic Strike, Cleave, Maul, Raptor Strike
local NEXT_MELEE_NAMES = { "Heroic Strike", "Cleave", "Maul", "Raptor Strike" }

local SIZES = {
    small  = { w = 160, h = 10 },
    medium = { w = 200, h = 14 },
    large  = { w = 260, h = 20 },
}
-- Default spot: centred just under the player frame (portrait, name and
-- bars). Without a usable player frame, a spot below screen centre instead.
local PLAYERFRAME_OFFSET = { x = 0, y = 0 }
local FALLBACK_POS       = { x = 0, y = -180 }
local SWING_MATCH  = 0.25   -- seconds: a spell and a native swing this close are one swing
local FADE_SPEED   = 4      -- alpha per second
local RANGE_POLL   = 0.2
local OUT_OF_RANGE = 0.45
local BAR_COLOUR   = { 0.69, 0.30, 1.00 }   -- MooseMode purple
local IDLE_COLOUR  = { 0.45, 0.30, 0.60 }   -- the same, muted, when no swing is counting

local source        -- "native", "combatlog" or nil
local warnedNoSource = false
local playerGUID
local playerClass

local timer = {}               -- duration, endTime, speed, paused
local lastSwingAt = 0
local casting                  -- { guid = castGUID, done = bool } while a cast-time spell is going
local inCombat, autoAttacking = false, false
local unlocked, previewUntil = false, 0
local dragging = false

local host, bar
local alpha, rangeElapsed = 0, 0
local anchorKey                -- which anchor Layout last applied

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Now() return GetTime() end

local function Readable(v)
    return v ~= nil and not ns.IsSecret(v)
end

local function Opt(key)
    return ns.db and ns.db[key]
end

-- Main-hand speed, or nil when it cannot be read.
local function Speed()
    if not UnitAttackSpeed then return nil end
    local ok, mh = pcall(UnitAttackSpeed, "player")
    if not ok or not Readable(mh) or type(mh) ~= "number" or mh <= 0 then return nil end
    return mh
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and Readable(name) then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and Readable(info.name) then return info.name end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, id)
        if ok and Readable(name) then return name end
    end
    return nil
end

local nextMeleeNames
local function IsNextMelee(spellID)
    if not Readable(spellID) then return false end
    if not nextMeleeNames then
        nextMeleeNames = {}
        for _, n in ipairs(NEXT_MELEE_NAMES) do nextMeleeNames[n] = true end
        for _, id in ipairs(NEXT_MELEE_IDS) do
            local n = SpellName(id)
            if n then nextMeleeNames[n] = true end
        end
    end
    local name = SpellName(spellID)
    return name ~= nil and nextMeleeNames[name] == true
end

-- Shapeshift form id (nil in caster form), or false when it cannot be read.
local function CurrentForm()
    if not GetShapeshiftFormID then return false end
    local ok, form = pcall(GetShapeshiftFormID)
    if not ok or ns.IsSecret(form) then return false end
    return form
end
local lastForm

local function FormAllowed()
    if playerClass ~= "DRUID" or Opt("swingTimerAllClasses") then return true end
    local form = CurrentForm()
    if form == false then return true end
    return form ~= nil and DRUID_MELEE_FORMS[form] == true
end

-- The module is doing its job for this character right now.
local function Active()
    if not ns.db or not Opt("swingTimer") then return false end
    if not source then return false end
    if not (MELEE_CLASSES[playerClass] or Opt("swingTimerAllClasses")) then return false end
    return FormAllowed()
end

-------------------------------------------------------------------------------
-- Timer
-------------------------------------------------------------------------------

local Wake   -- forward

-- Start a full swing at time `at`.
local function StartSwing(duration, at)
    if type(duration) ~= "number" or duration <= 0 then return end
    at = at or Now()
    timer.duration = duration
    timer.endTime  = at + duration
    timer.speed    = Speed() or duration
    timer.paused   = nil
    lastSwingAt = at
    if Wake then Wake() end
end

local function ClearSwing()
    timer.duration, timer.endTime, timer.speed, timer.paused = nil, nil, nil, nil
    casting = nil
end

local function Running()
    return timer.endTime ~= nil and (timer.paused ~= nil or timer.endTime > Now())
end

-- Attack speed changed mid-swing: stretch or shrink what is left (and the
-- whole swing, so the bar keeps its fill) by newSpeed / oldSpeed.
local function Rescale()
    local new = Speed()
    local t = timer
    if not (t.endTime and t.speed and new) or math.abs(new - t.speed) <= 0.001 then return end
    local ratio = new / t.speed
    local now = Now()
    if t.paused then
        t.paused = t.paused * ratio
    elseif t.endTime > now then
        t.endTime = now + (t.endTime - now) * ratio
    end
    t.duration = t.duration * ratio
    t.speed = new
end

-- The player parried: the next swing comes round sooner (vanilla rule).
local function ParryHaste()
    if not Opt("swingTimerParryHaste") then return end
    local t = timer
    local now = Now()
    if not t.endTime or t.paused or t.endTime <= now then return end
    local speed = t.speed or t.duration
    local left = t.endTime - now
    local floor = 0.2 * speed
    if left <= floor then return end
    t.endTime = now + math.max(left - 0.4 * speed, floor)
end

-- A cast-time spell started: freeze the bar where it is.
local function PauseForCast(castGUID)
    casting = { guid = castGUID }
    local now = Now()
    if timer.endTime and not timer.paused and timer.endTime > now then
        timer.paused = timer.endTime - now
    end
end

-- The cast ended without landing: carry on from where the bar froze.
local function ResumeAfterCast()
    if timer.paused then
        timer.endTime = Now() + timer.paused
        timer.paused = nil
    end
end

-- The cast landed: the swing starts over.
local function RestartAfterCast()
    local speed = Speed()
    if timer.endTime and speed then StartSwing(speed, Now()) end
end

-- Heroic Strike and friends: count as a swing unless a real one turns up
-- at (nearly) the same moment.
local function NextMeleeLanded()
    local at = Now()
    local function apply()
        if math.abs(lastSwingAt - at) <= SWING_MATCH then return end
        local speed = Speed()
        if speed then StartSwing(speed, at) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(SWING_MATCH, apply) else apply() end
end

local function MainHandSwapped()
    if inCombat or autoAttacking then
        local speed = Speed() or timer.speed
        if speed then StartSwing(speed, Now()) end
    else
        timer.duration, timer.endTime, timer.speed, timer.paused = nil, nil, nil, nil
    end
end

-------------------------------------------------------------------------------
-- Bar
-------------------------------------------------------------------------------

local UpdateVisibility, Layout   -- forward

-- Saved spot, or nil when the bar should sit under the player frame.
local function CustomPos()
    local pos = ns.db and ns.db.swingTimerPos
    if type(pos) == "table" and pos.custom and type(pos.x) == "number" and type(pos.y) == "number" then
        return pos
    end
    return nil
end

-- The player frame, when it is something we can sit under.
local function PlayerFrameAnchor()
    local pf = _G.PlayerFrame
    if type(pf) ~= "table" or not pf.GetBottom then return nil end
    local ok, shown = pcall(pf.IsShown, pf)
    if not ok or not shown then return nil end
    local okB, bottom = pcall(pf.GetBottom, pf)
    if not okB or type(bottom) ~= "number" or ns.IsSecret(bottom) then return nil end
    return pf
end

-- The character portrait on the player frame (Mainline layout first, then
-- the classic global), or the player frame itself.
local function Portrait()
    local pf = _G.PlayerFrame
    local c = pf and pf.PlayerFrameContainer
    local p = (c and c.PlayerPortrait) or _G.PlayerPortrait or pf
    if type(p) ~= "table" or not p.GetCenter then return nil end
    local ok, shown = pcall(p.IsVisible, p)
    if not ok or not shown then return nil end
    return p
end

-- The portrait's centre as an offset from screen centre, in UIParent units.
local function PortraitOffset()
    local p = Portrait()
    if not p then return nil end
    local x, y = p:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not (x and ux) or ns.IsSecret(x) or ns.IsSecret(y) then return nil end
    local r = p:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * r - ux, y * r - uy
end

-- Extra drag guides through the portrait's centre: a vertical line to line
-- the bar up under it, a horizontal one to put it level with it.
local PORTRAIT_GUIDES = {
    { axis = "x", label = "In line with the portrait", get = function()
        local x = PortraitOffset()
        return x
    end },
    { axis = "y", label = "Level with the portrait", get = function()
        local _, y = PortraitOffset()
        return y
    end },
}

local function SavePosition()
    if not host or not ns.db then return end
    local dx, dy = ns.CentreOffset(host)
    if not dx then return end
    dx, dy = ns.CentreGuides.Snap(dx, dy, PORTRAIT_GUIDES)   -- onto a lit centre line, unless Shift is held
    ns.db.swingTimerPos = {
        x = math.floor(dx + 0.5),
        y = math.floor(dy + 0.5),
        custom = true,
    }
    anchorKey = nil
    ns.SaveSettings()
end

local function NewBar(parent)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetAllPoints(parent)
    b:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b:SetStatusBarColor(BAR_COLOUR[1], BAR_COLOUR[2], BAR_COLOUR[3], 0.9)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.03, 0.06, 0.8)

    -- 1px dark border just outside the bar.
    local function edge(a1, a2, b1, b2, horiz)
        local e = b:CreateTexture(nil, "BORDER")
        e:SetColorTexture(0, 0, 0, 0.9)
        e:SetPoint(a1, b, a2, horiz and -1 or 0, 0)
        e:SetPoint(b1, b, b2, horiz and 1 or 0, 0)
        if horiz then e:SetHeight(1) else e:SetWidth(1) end
    end
    edge("BOTTOMLEFT", "TOPLEFT", "BOTTOMRIGHT", "TOPRIGHT", true)    -- top
    edge("TOPLEFT", "BOTTOMLEFT", "TOPRIGHT", "BOTTOMRIGHT", true)    -- bottom
    edge("TOPRIGHT", "TOPLEFT", "BOTTOMRIGHT", "BOTTOMLEFT", false)   -- left
    edge("TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", false)   -- right

    -- Bright tick at the leading edge of the fill.
    local spark = b:CreateTexture(nil, "OVERLAY")
    spark:SetColorTexture(1, 1, 1, 0.8)
    spark:SetWidth(2)
    spark:SetPoint("TOP", b:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    spark:SetPoint("BOTTOM", b:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    spark:Hide()
    b.spark = spark

    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", b, "LEFT", 4, 0)
    b.label:SetJustifyH("LEFT")
    b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.time:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    b.time:SetJustifyH("RIGHT")
    return b
end

local function SetColour(idle)
    local c = idle and IDLE_COLOUR or BAR_COLOUR
    bar:SetStatusBarColor(c[1], c[2], c[3], 0.9)
end

local function RenderBar(now)
    local t = timer
    local speed = Speed() or t.speed
    bar.label:SetText(speed and ("%.2f"):format(speed) or "")

    if t.endTime then
        local left = t.paused or math.max(0, t.endTime - now)
        local frac = (t.duration and t.duration > 0) and (1 - left / t.duration) or 1
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        bar:SetValue(frac)
        SetColour(left <= 0)
        bar.spark:SetShown(frac > 0 and frac < 1)
        if t.paused then
            bar.time:SetFormattedText("|cffaaaaaa%.1f|r", left)
        elseif left > 0 then
            bar.time:SetFormattedText("%.1f", left)
        else
            bar.time:SetText("")
        end
    else
        -- Idle: a full, muted bar with the weapon speed.
        bar:SetValue(1)
        SetColour(true)
        bar.spark:Hide()
        bar.time:SetText(unlocked and "drag" or "")
    end
end

local function PollRange()
    if not (C_SwingTimer and C_SwingTimer.IsTargetWithinSwingRange and Enum and Enum.PlayerSwingType) then return end
    local ok, inRange = pcall(C_SwingTimer.IsTargetWithinSwingRange, Enum.PlayerSwingType.MainHand)
    -- nil means "cannot tell", never "out of range".
    local out = ok and Readable(inRange) and inRange == false and not unlocked
    bar:SetAlpha(out and OUT_OF_RANGE or 1)
end

-- 1 while fighting, moving, previewing, mid-swing or with "Show out of
-- combat" on; otherwise 0, and the frame fades out and hides.
local function TargetAlpha(now)
    if unlocked or now < previewUntil or inCombat or autoAttacking then return 1 end
    if Running() then return 1 end
    if Opt("swingTimerShowOOC") then return 1 end
    return 0
end

local function OnUpdate(self, elapsed)
    local now = Now()
    RenderBar(now)

    local target = TargetAlpha(now)
    if alpha ~= target then
        local step = FADE_SPEED * (elapsed or 0)
        if alpha < target then alpha = math.min(target, alpha + step)
        else alpha = math.max(target, alpha - step) end
        self:SetAlpha(alpha)
    end
    if alpha <= 0 and target <= 0 then self:Hide() end

    rangeElapsed = rangeElapsed + (elapsed or 0)
    if rangeElapsed >= RANGE_POLL then
        rangeElapsed = 0
        PollRange()
    end
end

local ToggleMove   -- forward: the save button under the bar locks it

local function Build()
    if host then return end
    host = CreateFrame("Frame", "MooseModeSwingTimer", UIParent)
    host:SetFrameStrata("MEDIUM")
    host:SetClampedToScreen(true)
    host:SetMovable(true)
    host:RegisterForDrag("LeftButton")
    host:SetScript("OnDragStart", function(self)
        if unlocked then dragging = true; self:StartMoving(); ns.CentreGuides.Begin(self, PORTRAIT_GUIDES) end
    end)
    host:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        dragging = false
        ns.CentreGuides.End()
        SavePosition()
        Layout()
    end)

    host.highlight = host:CreateTexture(nil, "BACKGROUND")
    host.highlight:SetPoint("TOPLEFT", -4, 4)
    host.highlight:SetPoint("BOTTOMRIGHT", 4, -4)
    host.highlight:SetColorTexture(0.69, 0.30, 1.00, 0.25)
    host.highlight:Hide()

    -- Save button under the bar while it is unlocked: the position is
    -- already stored on every drop, so this just locks the bar in place.
    local save = CreateFrame("Button", nil, host)
    save:SetSize(22, 22)
    save:SetPoint("TOP", host, "BOTTOM", 0, -6)
    save:SetNormalTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    save:SetHighlightTexture("Interface\\RaidFrame\\ReadyCheck-Ready", "ADD")
    save:SetScript("OnClick", function() ToggleMove() end)
    save:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Save position", 1, 1, 1)
        GameTooltip:AddLine("Lock the swing bar where it is.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    save:SetScript("OnLeave", function() GameTooltip:Hide() end)
    save:Hide()
    host.save = save

    host.hint = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    host.hint:SetPoint("TOP", save, "BOTTOM", 0, -4)
    host.hint:SetText("|cffb04cffMooseMode|r swing timer: drag to move (snaps to screen centre, Shift for free), click |TInterface\\RaidFrame\\ReadyCheck-Ready:14|t to save")
    host.hint:Hide()

    bar = NewBar(host)
    host:SetAlpha(0)
    host:Hide()
    host:SetScript("OnUpdate", OnUpdate)
end

-- Anchor the frame: the saved spot if the player dragged it, otherwise
-- under the player frame (following it when it moves), otherwise a fixed
-- spot below screen centre. Re-anchors only when the choice changes.
local function Anchor()
    if dragging then return end
    local pos = CustomPos()
    local pf = not pos and PlayerFrameAnchor() or nil
    local key
    if pos then key = "custom:" .. pos.x .. ":" .. pos.y
    elseif pf then key = "player"
    else key = "fallback" end
    if key == anchorKey then return end

    host:ClearAllPoints()
    local ok = false
    if pos then
        ok = pcall(host.SetPoint, host, "CENTER", UIParent, "CENTER", pos.x, pos.y)
    elseif pf then
        ok = pcall(host.SetPoint, host, "TOP", pf, "BOTTOM", PLAYERFRAME_OFFSET.x, PLAYERFRAME_OFFSET.y)
    end
    if not ok then
        host:ClearAllPoints()
        host:SetPoint("CENTER", UIParent, "CENTER", FALLBACK_POS.x, FALLBACK_POS.y)
        key = "fallback"
    end
    anchorKey = key
end

Layout = function()
    if not host then return end
    local size = SIZES[Opt("swingTimerSize") or "medium"] or SIZES.medium
    host:SetSize(size.w, size.h)
    Anchor()
    bar.label:SetShown(size.h >= 12)
    host:EnableMouse(unlocked)
    host.highlight:SetShown(unlocked)
    host.hint:SetShown(unlocked)
    host.save:SetShown(unlocked)
end

UpdateVisibility = function()
    if not Active() and not unlocked then
        if host then host:Hide(); alpha = 0; host:SetAlpha(0) end
        return
    end
    Build()
    Layout()
    local target = TargetAlpha(Now())
    if target > 0 or alpha > 0 then
        host:Show()
    end
end

Wake = function()
    if not Active() then return end
    UpdateVisibility()
end

-------------------------------------------------------------------------------
-- Move mode, preview, reset
-------------------------------------------------------------------------------

ToggleMove = function()
    if not ns.db then return end
    unlocked = not unlocked
    Build()
    if unlocked then
        alpha = 1; host:SetAlpha(1)
        Layout(); host:Show()
        ns.Print("Swing bar unlocked: drag it where you want, then click the green tick under it (or /mm swing) to save. /mm swing reset puts it back under your portrait.")
    else
        if dragging then host:StopMovingOrSizing(); dragging = false; SavePosition() end
        ns.CentreGuides.End()
        Layout()
        UpdateVisibility()
        ns.Print("Swing bar locked.")
    end
    if ns.RefreshOptionsDialog then ns.RefreshOptionsDialog() end
end

local function Preview()
    if not ns.db then return end
    if not source then
        ns.Print("Swing timer: this client reports no swings to addons, so there is nothing to show.")
    end
    local speed = Speed() or 2.6
    local now = Now()
    Build()
    StartSwing(speed, now)
    previewUntil = now + speed + 1
    alpha = 1; host:SetAlpha(1)
    Layout(); host:Show()
end

local function ResetPosition()
    if not ns.db then return end
    ns.db.swingTimerPos = {}
    anchorKey = nil
    ns.SaveSettings()
    if host then Layout() end
    ns.Print("Swing bar moved back under the player frame.")
end

local function Status()
    local speed = Speed()
    ns.Print(("swing: source=%s class=%s active=%s combat=%s attacking=%s"):format(
        tostring(source or "none"), tostring(playerClass), tostring(Active()),
        tostring(inCombat), tostring(autoAttacking)))
    ns.Print(("swing: speed=%s running=%s casting=%s anchor=%s"):format(
        speed and ("%.2f"):format(speed) or "-", tostring(Running()),
        tostring(casting ~= nil), tostring(anchorKey or (CustomPos() and "custom" or "default"))))
    if C_CombatLog and C_CombatLog.IsCombatLogRestricted then
        local ok, r = pcall(C_CombatLog.IsCombatLogRestricted)
        ns.Print("swing: combat log restricted=" .. (ok and tostring(r) or "error"))
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local function ChooseSource()
    if Enum and Enum.PlayerSwingType then
        local ok = pcall(frame.RegisterEvent, frame, "PLAYER_SWING")
        if ok and frame:IsEventRegistered("PLAYER_SWING") then return "native" end
    end
    if CombatLogGetCurrentEventInfo then
        local ok = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
        if ok and frame:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") then return "combatlog" end
    end
    return nil
end

-- Only main-hand swings count; off-hand and ranged are ignored.
local function OnNativeSwing(duration, kind)
    if not Readable(duration) or not Readable(kind) then return end
    if not Active() then return end
    if kind == Enum.PlayerSwingType.MainHand then StartSwing(duration) end
end

-- Fallback path, only reached when the client lets addons read the log.
local function OnCombatLog()
    -- Suffix args start at 12: isOffHand is 21 for SWING_DAMAGE, 13 for SWING_MISSED.
    local ok, _, sub, _, srcGUID, _, _, _, _, _, _, _, _, a13, _, _, _, _, _, _, _, a21 =
        pcall(CombatLogGetCurrentEventInfo)
    if not ok or not Readable(sub) or not Readable(srcGUID) then return end
    if srcGUID ~= playerGUID or not Active() then return end
    local flag
    if sub == "SWING_DAMAGE" then flag = a21
    elseif sub == "SWING_MISSED" then flag = a13
    else return end
    -- Off-hand swings never touch the bar; a secret flag is skipped too,
    -- rather than risk restarting it on an off-hand swing.
    if ns.IsSecret(flag) or flag == true then return end
    local speed = Speed()
    if speed then StartSwing(speed) end
end

local function OnSpellcast(event, unit, castGUID, spellID)
    if unit ~= "player" or not Active() then return end
    if event == "UNIT_SPELLCAST_START" then
        -- Only a readable cast id can be matched to its end later.
        if Opt("swingTimerCastReset") and Readable(castGUID) then PauseForCast(castGUID) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if casting and Readable(castGUID) and casting.guid == castGUID then
            casting = nil
            RestartAfterCast()
        elseif IsNextMelee(spellID) then
            NextMeleeLanded()
        end
    else   -- STOP / FAILED / INTERRUPTED
        if casting and (not Readable(castGUID) or casting.guid == castGUID) then
            -- Whether SUCCEEDED comes before or after STOP, a landed cast
            -- restarts from here; one that did not land resumes.
            local guid = casting.guid
            ResumeAfterCast()
            if event ~= "UNIT_SPELLCAST_STOP" then
                casting = nil
            else
                casting = { guid = guid, done = true }
            end
        end
    end
end

local function RefreshCombatState()
    local ok, v = pcall(UnitAffectingCombat, "player")
    inCombat = ok and Readable(v) and v and true or false
end

frame:SetScript("OnEvent", function(self, event, ...)
    if not ns.db then return end
    if event == "PLAYER_SWING" then
        OnNativeSwing(...)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "UNIT_COMBAT" then
        local unit, action = ...
        if unit == "player" and Readable(action) and action == "PARRY" and Active() then ParryHaste() end
    elseif event == "UNIT_ATTACK_SPEED" then
        local unit = ...
        if unit == "player" then Rescale() end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        if Readable(slot) and slot == 16 and Active() then MainHandSwapped() end
        UpdateVisibility()
    elseif event:sub(1, 15) == "UNIT_SPELLCAST_" then
        OnSpellcast(event, ...)
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        UpdateVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        casting = nil
        UpdateVisibility()
    elseif event == "PLAYER_ENTER_COMBAT" then
        autoAttacking = true
        UpdateVisibility()
    elseif event == "PLAYER_LEAVE_COMBAT" then
        autoAttacking = false
        UpdateVisibility()
    elseif event == "UPDATE_SHAPESHIFT_FORM" then
        -- Druids only (stances and stealth fire this too), and only on a
        -- real change: a new form brings a new speed and a fresh swing.
        if playerClass == "DRUID" then
            local form = CurrentForm()
            if form ~= lastForm then
                lastForm = form
                ClearSwing()
                UpdateVisibility()
            end
        end
    elseif event == "PLAYER_DEAD" then
        ClearSwing()
        UpdateVisibility()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ClearSwing()
        RefreshCombatState()
        autoAttacking = false
        anchorKey = nil   -- the player frame may have been placed by now
        UpdateVisibility()
    end
end)

local function RegisterEvents()
    for _, e in ipairs({
        "UNIT_ATTACK_SPEED", "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
        "PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT",
        "UPDATE_SHAPESHIFT_FORM", "PLAYER_DEAD", "PLAYER_ENTERING_WORLD",
    }) do
        ns.SafeRegisterEvent(frame, e)
    end
    local unitEvents = {
        "UNIT_COMBAT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
    }
    for _, e in ipairs(unitEvents) do
        local ok = frame.RegisterUnitEvent and pcall(frame.RegisterUnitEvent, frame, e, "player")
        if not ok then ns.SafeRegisterEvent(frame, e) end
    end
end

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

local function Refresh()
    if not ns.db then return end
    if not Opt("swingTimer") then ClearSwing() end
    UpdateVisibility()
end

ns:RegisterModule({
    key   = "swingTimerModule",
    label = "Swing Timer",
    group = "Combat",
    icon  = "Interface\\Icons\\Ability_MeleeDamage",
    classes = { "ROGUE", "WARRIOR", "PALADIN", "SHAMAN", "DRUID" }, classesOverride = "swingTimerAllClasses",   -- dialog only
    reinitSafe = true,   -- OnInit only reads ns.db and refreshes the bar
    options = {
        { key = "swingTimer", label = "Swing timer bar", default = true,
          tooltip = "A bar under your portrait that counts down to your next main-hand swing. On for Rogues, Warriors, Paladins and Shamans, and for Druids in Cat or Bear Form. /mm swing unlocks it for moving.",
          onChange = function() Refresh() end },
        { key = "swingTimerShowOOC", label = "Show out of combat", default = false, parent = "swingTimer",
          tooltip = "Keep the bar on screen outside combat, full, with your weapon speed. Off: it fades away when the fight ends.",
          onChange = function() Refresh() end },
        { key = "swingTimerParryHaste", label = "Parry haste", default = true, parent = "swingTimer",
          tooltip = "When you parry, your next swing comes sooner: 40% of the weapon's speed, never below 20% of it left. The bar follows. Turn off if Forever does not do this." },
        { key = "swingTimerCastReset", label = "Casts restart the swing", default = true, parent = "swingTimer",
          tooltip = "Casting a spell with a cast time (Slam, heals, Lightning Bolt) freezes the bar and restarts the swing when the cast lands, as in the original game. Instant spells and Seal of Command procs leave the swing alone." },
        { key = "swingTimerAllClasses", label = "Show on every class", default = false, parent = "swingTimer",
          tooltip = "Also show the bar on Hunters, casters, and Druids in any form. Off: only Rogues, Warriors, Paladins, Shamans and Druids in Cat or Bear Form.",
          onChange = function() Refresh() end },
        { type = "choice", key = "swingTimerSize", label = "Bar size", default = "medium", parent = "swingTimer",
          values = { { value = "small", text = "Small" }, { value = "medium", text = "Medium" }, { value = "large", text = "Large" } },
          tooltip = "Small is too thin for the speed label; the time left still shows.",
          onChange = function() Refresh() end },
        { type = "button", label = "Position",
          buttonText = function() return unlocked and "Save position" or "Move" end,
          tooltip = "Move unlocks the bar so you can drag it. While it is unlocked this button reads Save position: click it, the green tick under the bar, or /mm swing to lock the bar where it is.",
          onClick = function() ToggleMove() end },
        { type = "button", pair = true, buttonText = "Reset",
          tooltip = "Put the bar back under your portrait, following the player frame. Same as /mm swing reset.",
          onClick = function() ResetPosition() end },
        { type = "button", pair = true, buttonText = "Test",
          tooltip = "Run one demo swing. Same as /mm swing test.",
          onClick = function() Preview() end },
    },
    OnInit = function()
        playerGUID = UnitGUID and UnitGUID("player") or nil
        local _, token = UnitClass("player")
        playerClass = token
        lastForm = CurrentForm()
        if source == nil and not warnedNoSource then
            source = ChooseSource()
            RegisterEvents()
            if not source then
                warnedNoSource = true
                -- Only worth mentioning to someone the bar would be for.
                if MELEE_CLASSES[playerClass] and Opt("swingTimer") then
                    ns.Print("Swing timer: this client reports no melee swings to addons, so the bar stays off.")
                end
            end
        end
        -- Old settings: drop the off-hand and out-of-combat keys this module
        -- no longer uses. A position saved before "custom" existed was the
        -- old default, so it falls back to the player-frame anchor.
        ns.db.swingTimerOffHand = nil
        ns.db.swingTimerOutOfCombat = nil
        if type(ns.db.swingTimerPos) ~= "table" then ns.db.swingTimerPos = {} end
        anchorKey = nil
        RefreshCombatState()
        Refresh()
    end,
    commands = {
        swing = function(rest)
            rest = (rest or ""):lower()
            if rest == "test" then Preview()
            elseif rest == "reset" then ResetPosition()
            elseif rest == "status" then Status()
            else ToggleMove() end
        end,
    },
})
