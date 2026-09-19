-------------------------------------------------------------------------------
-- MooseMode -- QuestRewards
--
-- Prints each quest reward choice's vendor sell value on its button and puts
-- a gold border on the most valuable one(s). Works in the quest hand-in
-- window (QUEST_COMPLETE) and in the quest log / map details, since Blizzard
-- lays both out through the same code.
--
-- How Blizzard builds it (Blizzard_UIPanels_Game/Mainline/QuestInfo.lua,
-- live branch):
--   * QuestInfo_ShowRewards() (line 603) lays out every reward. The frame is
--     QuestInfoFrame.rewardsFrame: QuestInfoRewardsFrame for the quest
--     frame / log, MapQuestInfoRewardsFrame for the map details (lines 57-60).
--   * Buttons live in rewardsFrame.RewardButtons (QuestInfo_GetRewardButton,
--     line 442). Choice buttons have button.type == "choice" (line 774) and
--     button:SetID(choiceIndex) (line 526). Regions: Icon, Name, NameFrame,
--     Count, IconBorder, IconOverlay (QuestInfo.xml lines 38-90, 253-310).
--   * Item links: GetQuestItemLink("choice", id) at the NPC, or
--     GetQuestLogItemLink("choice", id) when QuestInfoFrame.questLog is set,
--     exactly as Blizzard's own tooltip does (lines 1284-1287). Counts come
--     from GetQuestItemInfo / GetQuestLogChoiceInfo (third return).
--
-- Options (account-wide):
--   rewardValues     Show vendor value on rewards
--   rewardHighlight  Highlight the most valuable (sub-option)
--
-- Sell prices arrive from the server on first sight of an item. When one is
-- missing the pass asks the client to load it and re-runs on
-- GET_ITEM_INFO_RECEIVED, so the values fill in a moment later.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local GOLD_R, GOLD_G, GOLD_B = 1, 0.82, 0

local frame = CreateFrame("Frame")
local pendingItems = {}     -- [itemID] = true while waiting for item data
local rerunQueued = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ValuesEnabled()
    return ns.db and ns.db.rewardValues and true or false
end

local function HighlightEnabled()
    return ValuesEnabled() and ns.db.rewardHighlight and true or false
end

-- Item link and stack count for a choice button, from whichever data set the
-- reward frame is currently showing.
local function ChoiceLinkAndCount(button)
    local id = button:GetID()
    if not id or id == 0 then return nil end
    local link, count
    if QuestInfoFrame and QuestInfoFrame.questLog then
        link = GetQuestLogItemLink and GetQuestLogItemLink("choice", id)
        if GetQuestLogChoiceInfo then
            local _, _, n = GetQuestLogChoiceInfo(id)
            count = n
        end
    else
        link = GetQuestItemLink and GetQuestItemLink("choice", id)
        if GetQuestItemInfo then
            local _, _, n = GetQuestItemInfo("choice", id)
            count = n
        end
    end
    if ns.IsSecret(link) or ns.IsSecret(count) then return nil end
    if not link then return nil end
    return link, (type(count) == "number" and count > 0) and count or 1
end

-- Vendor value of one stack, or nil when the item's data is not cached yet.
local function StackValue(link, count)
    if not C_Item or not C_Item.GetItemInfo then return nil end
    local sellPrice = select(11, C_Item.GetItemInfo(link))
    if ns.IsSecret(sellPrice) then return nil end
    if sellPrice == nil then
        local itemID = ns.ItemIDFrom(link)
        if itemID and C_Item.RequestLoadItemDataByID then
            pendingItems[itemID] = true
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return nil
    end
    return sellPrice * count
end

-------------------------------------------------------------------------------
-- Overlays (our own children on Blizzard's buttons, never their regions)
-------------------------------------------------------------------------------

local function EnsureOverlays(button)
    if not button.MooseValue then
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("RIGHT")
        fs:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 3)
        fs:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        button.MooseValue = fs
    end
    if not button.MooseGlow then
        local icon = button.Icon
        local glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(GOLD_R, GOLD_G, GOLD_B)
        if icon then
            -- The border art has a wide transparent margin; overhang the icon
            -- so the visible ring sits just outside it.
            local w, h = icon:GetSize()
            glow:SetPoint("CENTER", icon, "CENTER", 0, 0)
            glow:SetSize((w or 39) * 1.7, (h or 39) * 1.7)
        else
            glow:SetPoint("TOPLEFT", button, "TOPLEFT", -12, 12)
            glow:SetSize(66, 66)
        end
        button.MooseGlow = glow
    end
end

local function ClearOverlays(button)
    if button.MooseValue then button.MooseValue:SetText("") end
    if button.MooseGlow then button.MooseGlow:Hide() end
end

-------------------------------------------------------------------------------
-- The pass
-------------------------------------------------------------------------------

local function Choices(rewardsFrame)
    local out = {}
    local buttons = rewardsFrame and rewardsFrame.RewardButtons
    if type(buttons) ~= "table" then return out end
    for _, button in ipairs(buttons) do
        if button:IsShown() and button.type == "choice" and button.objectType == "item" then
            out[#out + 1] = button
        end
    end
    return out
end

local function UpdateRewards()
    if not QuestInfoFrame then return end
    local rewardsFrame = QuestInfoFrame.rewardsFrame
    if not rewardsFrame or not rewardsFrame:IsShown() then return end

    local choices = Choices(rewardsFrame)
    for _, button in ipairs(choices) do
        EnsureOverlays(button)
        ClearOverlays(button)
    end
    if not ValuesEnabled() or #choices == 0 then return end

    wipe(pendingItems)
    local best, values = 0, {}
    for i, button in ipairs(choices) do
        local link, count = ChoiceLinkAndCount(button)
        local value = link and StackValue(link, count) or nil
        values[i] = value
        if value and value > 0 then
            button.MooseValue:SetText(ns.Coins(value))
            if value > best then best = value end
        end
    end

    if HighlightEnabled() and #choices > 1 and best > 0 then
        for i, button in ipairs(choices) do
            if values[i] == best then button.MooseGlow:Show() end
        end
    end

    if next(pendingItems) then
        frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    else
        frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    end
end

-- Blizzard also re-lays rewards on QUEST_ITEM_UPDATE and after any
-- QuestInfo_Display, all of which end in QuestInfo_ShowRewards, so hooking it
-- once covers the NPC window, the quest log and the map details.
local function ScheduleRerun()
    if rerunQueued then return end
    rerunQueued = true
    C_Timer.After(0, function()
        rerunQueued = false
        UpdateRewards()
    end)
end

if QuestInfo_ShowRewards then
    hooksecurefunc("QuestInfo_ShowRewards", ScheduleRerun)
end

frame:SetScript("OnEvent", function(self, event, itemID, success)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if ns.IsSecret(itemID) then return end
        if itemID and pendingItems[itemID] then
            pendingItems[itemID] = nil
            ScheduleRerun()
        end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "questRewardsModule",
    label = "Quest Rewards",
    options = {
        { key = "rewardValues", label = "Show vendor value on rewards", default = true,
          tooltip = "Prints each reward choice's sell price on its button.",
          onChange = function() ScheduleRerun() end },
        { key = "rewardHighlight", label = "Highlight the most valuable", default = true, parent = "rewardValues",
          tooltip = "Gold border on the reward choice that vendors for the most. Ties are all highlighted.",
          onChange = function() ScheduleRerun() end },
    },
})
