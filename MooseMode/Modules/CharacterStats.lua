-------------------------------------------------------------------------------
-- MooseMode -- CharacterStats
--
-- A strip under the character window (P) with the classic stats the screen
-- leaves out: your skill with each equipped weapon, attack speed, energy
-- or mana regen, and your average equipped item level.
-- It borrows the stats pane's own art (title bar, striped
-- rows, stone background) so it reads as part of the screen.
--
-- Hands off Blizzard's frames on purpose. On this client the character
-- screen reads secret values (health) that only untainted code may compare,
-- so adding rows to its stat tables or hooking its scripts breaks the whole
-- screen ("attempt to compare a secret number value"). This strip is its own
-- frame on UIParent: it only anchors to the character window, and a light
-- poll notices when the character tab is open. No Blizzard code ever runs
-- anything of ours.
--
-- Options (account-wide):
--   charStats         Show the strip (master)
--   charStatsSkills   Weapon skills column
--   charStatsSpeed    Attack speed row
--   charStatsRegen    Energy / mana regen row
--   charStatsGear     Average equipped item level row
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local SLOT_MAIN, SLOT_OFF, SLOT_RANGED = 16, 17, 18
local FERAL_SKILL, UNARMED_SKILL = 3014, 162
local POLL, REFRESH = 0.15, 0.5          -- seconds: visibility check, value refresh while shown
local COL_W, ROW_H, HEADER_H = 197, 17, 26
local PAD, GAP = 8, 12
local ROWS_PER_COL = 3
local BELOW_CAP = "|cffffd100"

-- Weapon subclass -> skill line, as in Blizzard's PaperDollFrameStats.lua.
local SKILL_FOR_SUBCLASS = {}
do
    local W = Enum and Enum.ItemWeaponSubclass
    if W then
        local map = {
            { W.Sword1H, 43 }, { W.Axe1H, 44 }, { W.Bows, 45 }, { W.Guns, 46 },
            { W.Mace1H, 54 }, { W.Sword2H, 55 }, { W.Staff, 136 }, { W.Mace2H, 160 },
            { W.Axe2H, 172 }, { W.Dagger, 173 }, { W.Thrown, 176 }, { W.Crossbow, 226 },
            { W.Wand, 228 }, { W.Polearm, 229 }, { W.Unarmed, 162 },
        }
        for _, pair in ipairs(map) do
            if pair[1] ~= nil then SKILL_FOR_SUBCLASS[pair[1]] = pair[2] end
        end
    end
end

local function Plain(v)
    return v ~= nil and not ns.IsSecret(v)
end

-------------------------------------------------------------------------------
-- Values
-------------------------------------------------------------------------------

local function SkillForSlot(slot)
    if slot == SLOT_MAIN then
        local _, class = UnitClass("player")
        if class == "DRUID" and GetShapeshiftForm and GetShapeshiftForm() ~= 0 then return FERAL_SKILL end
    end
    local itemID = GetInventoryItemID("player", slot)
    if not itemID then return slot == SLOT_MAIN and UNARMED_SKILL or nil end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInstant then return nil end
    local ok, _, _, _, _, _, classID, subclassID = pcall(getInstant, itemID)
    if not ok or not (Enum and Enum.ItemClass) or classID ~= Enum.ItemClass.Weapon then return nil end
    return SKILL_FOR_SUBCLASS[subclassID]
end

-- { label, value, tip, tip2 } for one weapon slot, or nil.
local function SkillRow(slot)
    if not (C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID) then return nil end
    local id = SkillForSlot(slot)
    if not id then return nil end
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, id)
    if not ok or type(info) ~= "table" or not Plain(info.rank) or not Plain(info.maxRank) then return nil end
    local rank, maxRank, mod = info.rank, info.maxRank, info.modifier or 0
    local text = (Plain(mod) and mod ~= 0) and (rank .. " (" .. mod .. ")/" .. maxRank) or (rank .. "/" .. maxRank)
    local below = rank < maxRank
    return {
        label = info.name or "?",
        value = below and (BELOW_CAP .. text .. "|r") or text,
        tip = (info.name or "") .. " " .. rank .. "/" .. maxRank,
        tip2 = below
            and "Below the cap for your level: you miss more and more of your hits are glancing blows. It rises as you fight with this weapon."
            or "At the cap for your level. The cap rises by 5 each level.",
    }
end

local function SpeedRow()
    local ok, mh, oh = pcall(UnitAttackSpeed, "player")
    if not ok or not Plain(mh) then return nil end
    local text = string.format("%.2f", mh)
    if Plain(oh) and oh then text = text .. " / " .. string.format("%.2f", oh) end
    return {
        label = WEAPON_SPEED or "Attack Speed",
        value = text,
        tip = (ATTACK_SPEED or "Attack speed") .. " " .. text,
        tip2 = "Seconds between swings, main hand / off hand, including haste.",
    }
end

local function RegenRow()
    local _, token = UnitPowerType("player")
    if token == "ENERGY" and GetPowerRegen then
        local ok, rate = pcall(GetPowerRegen)
        if ok and Plain(rate) then
            local text = string.format("%.1f", rate)
            return { label = STAT_ENERGY_REGEN or "Energy Regen", value = text,
                     tip = (STAT_ENERGY_REGEN or "Energy Regen") .. " " .. text, tip2 = "Energy per second." }
        end
    end
    local okMax, maxMana = pcall(UnitPowerMax, "player", (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0)
    if okMax and Plain(maxMana) and maxMana > 0 and GetManaRegen then
        local ok, base, casting = pcall(GetManaRegen)
        if ok and Plain(base) and Plain(casting) then
            local text = tostring(math.floor(casting * 5))
            return { label = MANA_REGEN or "Mana Regen", value = text,
                     tip = (MANA_REGEN or "Mana Regen") .. " " .. text,
                     tip2 = "Mana per 5 seconds while casting. Out of casting: " .. math.floor(base * 5) .. "." }
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Gear: average item level
-------------------------------------------------------------------------------

-- Equipped slots that count toward the average (no shirt 4, tabard 19,
-- ammo 0). The ranged slot counts only where the client shows one.
local AVG_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }

local function ItemInfo(link)
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not get then return nil end
    local ok, _, _, quality, ilvl, _, _, _, _, equipLoc = pcall(get, link)
    if not ok or not Plain(quality) or not Plain(ilvl) then return nil end
    return quality, ilvl, equipLoc
end

-- The item level the item actually has (upgrades, scaling), else its base.
local function EffectiveLevel(link, base)
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        local ok, lvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
        if ok and Plain(lvl) and type(lvl) == "number" and lvl > 0 then return lvl end
    end
    return base
end

local function RangedSlotShown()
    if C_PaperDollInfo and C_PaperDollInfo.IsRangedSlotShown then
        local ok, shown = pcall(C_PaperDollInfo.IsRangedSlotShown)
        if ok and Plain(shown) then return shown and true or false end
    end
    return GetInventoryItemLink("player", SLOT_RANGED) ~= nil
end

-- Average equipped item level the way Blizzard counts it: empty slots are
-- 0, and a two-hander counts twice while the off hand is empty. Returns
-- avg, complete (false while some item data is not cached yet).
local function ComputeAverage()
    local slots = {}
    for i, s in ipairs(AVG_SLOTS) do slots[i] = s end
    if RangedSlotShown() then slots[#slots + 1] = SLOT_RANGED end
    local total, complete, mainLvl, mainLoc = 0, true, nil, nil
    for _, slot in ipairs(slots) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local _, ilvl, loc = ItemInfo(link)
            if ilvl then
                local lvl = EffectiveLevel(link, ilvl)
                total = total + lvl
                if slot == SLOT_MAIN then mainLvl, mainLoc = lvl, loc end
            else
                complete = false
            end
        end
    end
    if mainLoc == "INVTYPE_2HWEAPON" and not GetInventoryItemLink("player", SLOT_OFF) then
        total = total + mainLvl
    end
    return total / #slots, complete
end

-- avgEquipped, avgBest, complete. GetAverageItemLevel's second return is
-- the equipped average; used when the client gives a sane number.
local function AverageItemLevel()
    local own, complete = ComputeAverage()
    if GetAverageItemLevel then
        local ok, best, equipped = pcall(GetAverageItemLevel)
        if ok and Plain(equipped) and type(equipped) == "number" and equipped > 0 and equipped < 10000 then
            local b = (Plain(best) and type(best) == "number" and best > 0) and best or equipped
            return equipped, b, true
        end
    end
    return own, own, complete
end

local function ItemLevelRow()
    local okA, avg, best, completeA = pcall(AverageItemLevel)
    if okA and avg then
        local text = string.format("%.1f", avg)
        local tip2 = "The average item level of what you are wearing. Empty slots count as 0 and a two-handed weapon counts twice while your off hand is empty, as Blizzard counts it."
        if best and math.floor(best * 10) ~= math.floor(avg * 10) then
            tip2 = tip2 .. string.format("\n\nWith the best gear in your bags: %.1f.", best)
        end
        return {
            label = STAT_AVERAGE_ITEM_LEVEL or "Item Level",
            value = text .. (completeA and "" or PENDING),
            tip = (STAT_AVERAGE_ITEM_LEVEL or "Item Level") .. " " .. text,
            tip2 = tip2,
        }
    end
    return nil
end

-------------------------------------------------------------------------------
-- The strip
-------------------------------------------------------------------------------

local strip, columns

local function Atlas(tex, atlas)
    local ok = pcall(tex.SetAtlas, tex, atlas, false)
    return ok
end

local function RowEnter(row)
    if not row.data then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(row.data.tip or row.data.label, 1, 1, 1)
    if row.data.tip2 then GameTooltip:AddLine(row.data.tip2, nil, nil, nil, true) end
    GameTooltip:Show()
end

local function NewColumn(parent, title)
    local col = CreateFrame("Frame", nil, parent)
    col:SetSize(COL_W, HEADER_H + ROWS_PER_COL * ROW_H)

    local header = col:CreateTexture(nil, "BACKGROUND")
    header:SetPoint("TOPLEFT")
    header:SetSize(COL_W, HEADER_H)
    if not Atlas(header, "UI-Character-Info-Title") then header:SetColorTexture(0.25, 0.18, 0.08, 0.9) end
    local titleText = col:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    titleText:SetPoint("CENTER", header, "CENTER", 0, 1)
    titleText:SetText(title)

    col.rows = {}
    for i = 1, ROWS_PER_COL do
        local row = CreateFrame("Frame", nil, col)
        row:SetSize(COL_W - 10, ROW_H)
        row:SetPoint("TOP", header, "BOTTOM", 0, -2 - (i - 1) * ROW_H)
        row:EnableMouse(true)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetPoint("CENTER")
        row.bg:SetSize(COL_W - 10, ROW_H)
        if not Atlas(row.bg, "UI-Character-Info-Line-Bounce") then row.bg:SetColorTexture(1, 1, 1, 0.05) end
        row.bg:SetShown(i % 2 == 0)
        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.label:SetPoint("LEFT", 11, 0)
        row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.value:SetPoint("RIGHT", -8, 0)
        row:SetScript("OnEnter", RowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        col.rows[i] = row
    end
    return col
end

local function Build()
    if strip then return end
    strip = CreateFrame("Frame", "MooseModeCharacterStats", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    strip:SetClampedToScreen(true)
    strip:Hide()

    local stone = strip:CreateTexture(nil, "BACKGROUND", nil, -1)
    stone:SetPoint("TOPLEFT", 4, -4)
    stone:SetPoint("BOTTOMRIGHT", -4, 4)
    if not Atlas(stone, "UI-Character-Info-Stat-StoneBG") then stone:SetColorTexture(0.08, 0.07, 0.06, 0.95) end
    if strip.SetBackdrop then
        strip:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
                            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        strip:SetBackdropBorderColor(0.75, 0.62, 0.35, 1)
    end

    columns = {
        skills = NewColumn(strip, "Weapon Skills"),
        other  = NewColumn(strip, "More Stats"),
    }
end

local function Fill(col, rows)
    for i, row in ipairs(col.rows) do
        local data = rows[i]
        row.data = data
        row.label:SetText(data and ((data.label or "") .. ":") or "")
        row.value:SetText(data and data.value or "")
        row:SetShown(data ~= nil)
    end
    return #rows
end

-- In combat the client hides some values from addons (they come back
-- secret), so a row would vanish mid-fight. Keep the last value read and
-- show it greyed until the real one is readable again.
local lastRow = {}
local STALE = "|cff9d9d9d"
local function Keep(key, row)
    if row then
        lastRow[key] = row
        return row
    end
    local old = lastRow[key]
    if not old then return nil end
    local plainValue = tostring(old.value or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return {
        label = old.label,
        value = STALE .. plainValue .. "|r",
        tip = old.tip,
        tip2 = (old.tip2 and (old.tip2 .. "\n\n") or "") .. "Hidden by the game during combat: this is the last value, updated when the fight ends.",
    }
end

local function Layout()
    local db = ns.db
    local skills = {}
    if db.charStatsSkills then
        for _, slot in ipairs({ SLOT_MAIN, SLOT_OFF, SLOT_RANGED }) do
            -- Only keep a skill for a slot that still holds a weapon.
            local r = SkillForSlot(slot) and Keep("skill" .. slot, SkillRow(slot)) or nil
            if r then skills[#skills + 1] = r end
        end
    end
    local other = {}
    if db.charStatsSpeed then other[#other + 1] = Keep("speed", SpeedRow()) end
    if db.charStatsRegen then other[#other + 1] = Keep("regen", RegenRow()) end
    if db.charStatsGear then other[#other + 1] = Keep("ilvl", ItemLevelRow()) end

    local shown = {}
    if Fill(columns.skills, skills) > 0 then shown[#shown + 1] = columns.skills end
    columns.skills:SetShown(#skills > 0)
    if Fill(columns.other, other) > 0 then shown[#shown + 1] = columns.other end
    columns.other:SetShown(#other > 0)

    local rows = math.max(#skills, #other)
    for i, col in ipairs(shown) do
        col:ClearAllPoints()
        col:SetPoint("TOPLEFT", strip, "TOPLEFT", PAD + (i - 1) * (COL_W + GAP), -PAD)
    end
    strip:SetSize(PAD * 2 + #shown * COL_W + math.max(0, #shown - 1) * GAP, PAD * 2 + HEADER_H + rows * ROW_H + 2)
    return #shown > 0
end

-- Is the character tab (paper doll) open right now?
local function CharacterTabOpen()
    local pd = _G.PaperDollFrame
    if not pd then return false end
    local ok, visible = pcall(pd.IsVisible, pd)
    return ok and visible and true or false
end

local function Place()
    local cf = _G.CharacterFrame
    if not cf then return end
    local okS, scale = pcall(function() return cf:GetEffectiveScale() / UIParent:GetEffectiveScale() end)
    if okS and type(scale) == "number" and scale > 0 then strip:SetScale(scale) end
    local okT, strata = pcall(cf.GetFrameStrata, cf)
    if okT and strata then strip:SetFrameStrata(strata) end
    strip:ClearAllPoints()
    strip:SetPoint("TOP", cf, "BOTTOM", 0, -2)
end

local sinceRefresh = 0
local driver = CreateFrame("Frame")
local elapsedPoll = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    elapsedPoll = elapsedPoll + (elapsed or 0)
    if elapsedPoll < POLL then return end
    local step = elapsedPoll
    elapsedPoll = 0

    local want = ns.db and ns.db.charStats and CharacterTabOpen()
    if not want then
        if strip and strip:IsShown() then strip:Hide() end
        return
    end
    Build()
    if not strip:IsShown() then
        Place()
        if Layout() then strip:Show() end
        sinceRefresh = 0
        return
    end
    sinceRefresh = sinceRefresh + step
    if sinceRefresh >= REFRESH then
        sinceRefresh = 0
        if not Layout() then strip:Hide() end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

local function Refresh()
    if strip and strip:IsShown() then
        if not Layout() then strip:Hide() end
    end
end

ns:RegisterModule({
    key   = "charStatsModule",
    label = "Character Stats",
    group = "Interface",
    summary = "Weapon skills, speed, regen and item level under the character window.",
    icon    = "Interface\\Icons\\INV_Chest_Chain_05",
    reinitSafe = true,
    options = {
        { key = "charStats", label = "Extra stats under the character window", default = true,
          tooltip = "A strip under the character window (P) with the classic stats it leaves out (weapon skills, speed, regen, item level), in the stats pane's own style.",
          onChange = function() Refresh() end },
        { key = "charStatsSkills", label = "Weapon skills", default = true, parent = "charStats",
          tooltip = "Your skill with each equipped weapon, in yellow while it is below the cap for your level.",
          onChange = function() Refresh() end },
        { key = "charStatsSpeed", label = "Attack speed", default = true, parent = "charStats",
          tooltip = "Seconds between swings, main hand / off hand, including haste.",
          onChange = function() Refresh() end },
        { key = "charStatsRegen", label = "Energy or mana regen", default = true, parent = "charStats",
          tooltip = "Energy per second for energy users, mana per 5 seconds while casting for mana users.",
          onChange = function() Refresh() end },
        { key = "charStatsGear", label = "Average item level", default = true, parent = "charStats",
          tooltip = "The average item level of what you are wearing, counted the way Blizzard counts it.",
          onChange = function() Refresh() end },
    },
})
