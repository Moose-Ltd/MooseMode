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
-- Because Forever's copy of that code may differ, the pass is triggered
-- three ways (the QuestInfo_ShowRewards hook, the QUEST_COMPLETE /
-- QUEST_ITEM_UPDATE / QUEST_LOG_UPDATE events, and the reward panel's
-- OnShow), and buttons are found three ways (RewardButtons, the named
-- QuestInfoItemN buttons, then any shown child with an Icon). When no button
-- carries type == "choice", the first GetNumQuestChoices() shown item
-- buttons in layout order are taken as choices 1..N, which is how Blizzard
-- lays them out.
--
-- Options (account-wide):
--   rewardValues     Show vendor value on rewards
--   rewardHighlight  Highlight the most valuable (sub-option)
-- Command: /mm rewarddebug  toggles a chat log of every pass.
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
local logUpdateQueued = false
local hooked = {}           -- which triggers are installed

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Debug(msg)
    if ns.db and ns.db.rewardDebug then
        ns.Print("[rewards] " .. tostring(msg))
    end
end

local function ValuesEnabled()
    return ns.db and ns.db.rewardValues and true or false
end

local function HighlightEnabled()
    return ValuesEnabled() and ns.db.rewardHighlight and true or false
end

local function InQuestLog()
    return QuestInfoFrame and QuestInfoFrame.questLog and true or false
end

-- Number of reward choices for whatever the reward frame is showing.
local function NumChoices()
    local n
    if InQuestLog() then
        if GetNumQuestLogChoices then
            local questID = C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
            local ok, v = pcall(GetNumQuestLogChoices, questID)
            if ok then n = v end
        end
    elseif GetNumQuestChoices then
        n = GetNumQuestChoices()
    end
    if ns.IsSecret(n) or type(n) ~= "number" then return 0 end
    return n
end

-- Item link and stack count for choice index id, from whichever data set the
-- reward frame is currently showing.
local function ChoiceLinkAndCount(id)
    if not id or id == 0 then return nil end
    local link, count
    if InQuestLog() then
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

-- Sell price of one unit, or nil when the item's data is not cached yet.
local function SellPrice(link)
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
    return sellPrice
end

-------------------------------------------------------------------------------
-- Overlays (our own children on Blizzard's buttons, never their regions)
-------------------------------------------------------------------------------

local function EnsureOverlays(button)
    if not button.MooseValue then
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetDrawLayer("OVERLAY", 7)
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
            if not w or w == 0 then w = 39 end
            if not h or h == 0 then h = 39 end
            glow:SetPoint("CENTER", icon, "CENTER", 0, 0)
            glow:SetSize(w * 1.7, h * 1.7)
        else
            glow:SetPoint("TOPLEFT", button, "TOPLEFT", -12, 12)
            glow:SetSize(66, 66)
        end
        glow:Hide()
        button.MooseGlow = glow
    end
end

local function ClearOverlays(button)
    if button.MooseValue then button.MooseValue:SetText("") end
    if button.MooseGlow then button.MooseGlow:Hide() end
end

-------------------------------------------------------------------------------
-- Button discovery
-------------------------------------------------------------------------------

local function RewardsFrame()
    local f = QuestInfoFrame and QuestInfoFrame.rewardsFrame
    if f then return f end
    return QuestInfoRewardsFrame
end

-- Every shown candidate button on the rewards frame, plus how we found them.
local function CandidateButtons(rewardsFrame)
    local out = {}
    local buttons = rewardsFrame.RewardButtons
    if type(buttons) == "table" and #buttons > 0 then
        for _, b in ipairs(buttons) do
            if b:IsShown() then out[#out + 1] = b end
        end
        if #out > 0 then return out, "RewardButtons" end
    end

    local name = rewardsFrame:GetName()
    local prefixes = { name and (name .. "QuestInfoItem") or nil, "QuestInfoRewardsFrameQuestInfoItem" }
    for _, prefix in ipairs(prefixes) do
        local i = 1
        while _G[prefix .. i] do
            local b = _G[prefix .. i]
            if b:IsShown() then out[#out + 1] = b end
            i = i + 1
        end
        if #out > 0 then return out, "named" end
    end

    for _, child in ipairs({ rewardsFrame:GetChildren() }) do
        if child.Icon and child:IsShown() then out[#out + 1] = child end
    end
    return out, "children"
end

-- Sort top-to-bottom, then left-to-right: Blizzard's layout order.
local function LayoutOrder(a, b)
    local at, bt = a:GetTop() or 0, b:GetTop() or 0
    if math.abs(at - bt) > 1 then return at > bt end
    return (a:GetLeft() or 0) < (b:GetLeft() or 0)
end

-- Returns a list of { button = , id = } for the reward choices.
local function Choices(rewardsFrame)
    local candidates, how = CandidateButtons(rewardsFrame)
    local out = {}

    -- Preferred: buttons that say they are choices.
    for _, b in ipairs(candidates) do
        if b.type == "choice" and (b.objectType == nil or b.objectType == "item") then
            local id = b.GetID and b:GetID() or 0
            if id and id > 0 then out[#out + 1] = { button = b, id = id } end
        end
    end
    if #out > 0 then return out, how .. "/typed" end

    -- Fallback: the first N shown item buttons in layout order are the
    -- choices, N from the quest data.
    local n = NumChoices()
    if n == 0 then return out, how .. "/none" end
    local items = {}
    for _, b in ipairs(candidates) do
        if b.objectType == nil or b.objectType == "item" then items[#items + 1] = b end
    end
    table.sort(items, LayoutOrder)
    for i = 1, math.min(n, #items) do
        out[#out + 1] = { button = items[i], id = i }
    end
    return out, how .. "/ordered"
end

-------------------------------------------------------------------------------
-- The pass
-------------------------------------------------------------------------------

local function UpdateRewards(trigger)
    local rewardsFrame = RewardsFrame()
    if not rewardsFrame then
        Debug((trigger or "?") .. ": no rewards frame")
        return
    end
    if not rewardsFrame:IsShown() then
        Debug((trigger or "?") .. ": " .. (rewardsFrame:GetName() or "rewards frame") .. " hidden")
        return
    end

    local choices, how = Choices(rewardsFrame)
    Debug(("%s: %s, %d choice(s) via %s, log=%s"):format(trigger or "?",
        rewardsFrame:GetName() or "?", #choices, how, tostring(InQuestLog())))

    for _, c in ipairs(choices) do
        EnsureOverlays(c.button)
        ClearOverlays(c.button)
    end
    if not ValuesEnabled() or #choices == 0 then return end

    wipe(pendingItems)
    local best, values = 0, {}
    for i, c in ipairs(choices) do
        local b = c.button
        local link, count = ChoiceLinkAndCount(c.id)
        local price = link and SellPrice(link) or nil
        local value = price and price * count or nil
        values[i] = value
        if value and value > 0 then
            -- Zero-value items get no text rather than "0c".
            b.MooseValue:SetText(ns.Coins(value))
            if value > best then best = value end
        end
        Debug(("  #%d id=%s type=%s obj=%s shown=%s link=%s price=%s count=%s value=%s"):format(
            i, tostring(c.id), tostring(b.type), tostring(b.objectType), tostring(b:IsShown()),
            link and link:match("%[(.-)%]") or "nil", tostring(price), tostring(count), tostring(value)))
    end

    if HighlightEnabled() and #choices > 1 and best > 0 then
        local winners = {}
        for i, c in ipairs(choices) do
            if values[i] == best then
                c.button.MooseGlow:Show()
                winners[#winners + 1] = tostring(i)
            end
        end
        Debug("  winner(s): #" .. table.concat(winners, ", #") .. " at " .. ns.Coins(best))
    elseif best == 0 then
        Debug("  no priced choice yet" .. (next(pendingItems) and " (waiting for item data)" or ""))
    end

    if next(pendingItems) then
        frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    else
        frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    end
end

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------

-- Next-frame rerun, collapsed so a burst of item-data events runs once.
local function ScheduleRerun(trigger)
    if rerunQueued then return end
    rerunQueued = true
    C_Timer.After(0, function()
        rerunQueued = false
        UpdateRewards(trigger or "rerun")
    end)
end

-- Two delayed passes: one just after Blizzard's own event handler has laid
-- the panel out, one later in case the layout arrived late.
local function ScheduleDelayed(trigger)
    C_Timer.After(0.05, function() UpdateRewards(trigger .. "@0.05") end)
    C_Timer.After(0.3, function() UpdateRewards(trigger .. "@0.3") end)
end

local function InstallHooks()
    if not hooked.showRewards and QuestInfo_ShowRewards then
        hooksecurefunc("QuestInfo_ShowRewards", function() ScheduleRerun("hook") end)
        hooked.showRewards = true
    end
    if not hooked.rewardPanel and QuestFrameRewardPanel and QuestFrameRewardPanel.HookScript then
        QuestFrameRewardPanel:HookScript("OnShow", function() ScheduleDelayed("panel OnShow") end)
        hooked.rewardPanel = true
    end
    if hooked.showRewards and hooked.rewardPanel then
        frame:UnregisterEvent("ADDON_LOADED")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("QUEST_ITEM_UPDATE")
frame:RegisterEvent("QUEST_LOG_UPDATE")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" or event == "PLAYER_LOGIN" then
        InstallHooks()
    elseif event == "QUEST_COMPLETE" then
        ScheduleDelayed("QUEST_COMPLETE")
    elseif event == "QUEST_ITEM_UPDATE" then
        ScheduleRerun("QUEST_ITEM_UPDATE")
    elseif event == "QUEST_LOG_UPDATE" then
        if QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown() and not logUpdateQueued then
            logUpdateQueued = true
            C_Timer.After(0.05, function()
                logUpdateQueued = false
                UpdateRewards("QUEST_LOG_UPDATE")
            end)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if ns.IsSecret(arg1) then return end
        if arg1 and pendingItems[arg1] then
            pendingItems[arg1] = nil
            ScheduleRerun("item data")
        end
    end
end)

InstallHooks()

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "questRewardsModule",
    label = "Quest Rewards",
    options = {
        { key = "rewardValues", label = "Show vendor value on rewards", default = true,
          tooltip = "Prints each reward choice's sell price on its button.",
          onChange = function() ScheduleRerun("option") end },
        { key = "rewardHighlight", label = "Highlight the most valuable", default = true, parent = "rewardValues",
          tooltip = "Gold border on the reward choice that vendors for the most. Ties are all highlighted.",
          onChange = function() ScheduleRerun("option") end },
    },
    commands = {
        rewarddebug = function()
            if not ns.db then return end
            ns.db.rewardDebug = not ns.db.rewardDebug
            ns.Print("Reward debug " .. (ns.db.rewardDebug and "on" or "off") .. ".")
            if ns.db.rewardDebug then UpdateRewards("manual") end
        end,
    },
})
