-------------------------------------------------------------------------------
-- MooseMode -- QuestLists
--
-- Decorates the quest lines in NPC dialogs (and the title of the single-quest
-- offer window): the level in front of the name,
-- the name in the game's own difficulty colour, "(complete)" in gold on
-- hand-ins that are ready, and a small grey "skipped: green" style tag on
-- quests Auto Quest chose to leave for you. Gossip option lines ("I need
-- to train") are never touched.
--
-- Two Blizzard windows show quest lists (Blizzard_UIPanels_Game, live):
--   * Gossip frame (Shared/GossipFrameShared.lua): GossipFrame:Update()
--     (line 241) fills a ScrollBox from C_GossipInfo.GetAvailableQuests()
--     and GetActiveQuests(). Each quest line is a button whose Setup()
--     calls self:SetID(questInfo.questID) then UpdateTitleForQuest(), which
--     writes the title with SetFormattedText(NORMAL_QUEST_DISPLAY, title)
--     (lines 27-57). Mainline/GossipFrame.lua re-runs the title write from a
--     QuestEventListener callback when quest data arrives late (lines 13-27).
--   * Greeting panel (Mainline/QuestFrame.lua): QuestFrameGreetingPanel_OnShow
--     (line 306) acquires QuestTitleButtonTemplate buttons from
--     titleButtonPool, writes the title with SetFormattedText, then SetID(i)
--     and isActive = 1/0 (lines 329-349, 374-394). questID comes from
--     GetActiveQuestID(i) or the fifth return of GetAvailableQuestInfo(i).
--
-- Hook points: every gossip quest button gets a one-time instance hook on
-- SetFormattedText, so whatever Blizzard writes (first fill, ScrollBox
-- re-acquire, late callback) is immediately rebuilt; the button's ID is the
-- questID by then. The greeting panel writes text before SetID, so it is
-- decorated after QuestFrameGreetingPanel_OnShow via hooksecurefunc, walking
-- the pool. A pass on GOSSIP_SHOW / QUEST_GREETING / QUEST_LOG_UPDATE
-- (0.05 s later) is the backstop for both.
--   * Quest detail window (Mainline/QuestInfo.lua): when an NPC has a single
--     quest the client skips the list and opens QuestFrameDetailPanel.
--     QuestInfo_ShowTitle() (line 148) writes QuestInfoTitleHeader:SetText
--     (GetTitleText()); QuestInfoFrame.questLog is nil for the NPC offer and
--     true for the quest log / map views (lines 50, 1111-1154). The header is
--     decorated after hooksecurefunc("QuestInfo_ShowTitle") and on
--     QUEST_DETAIL, NPC offers only (skip reason goes on its own line above
--     the Accept/Decline buttons, not in the title), rebuilt from GetTitleText() so a
--     follow-up quest in the same panel is re-read, never decorated twice.
--
-- The original title is kept on the button (MooseOriginalText) and the
-- text is always rebuilt from it, so nothing is decorated twice.
--
-- Options (account-wide):
--   questListColour   Colour quests by difficulty
--   questListSkipTag  Show why a quest was skipped (sub-option)
-------------------------------------------------------------------------------

local ADDON, ns = ...

local GOLD = "|cffffd100"
local GREY = "|cff808080"
local BLACK = "|cff000000"

local frame = CreateFrame("Frame")
local hooked = {}
local passQueued = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Enabled()
    return ns.db and ns.db.questListColour and true or false
end

local function TagsEnabled()
    return Enabled() and ns.db.questListSkipTag and true or false
end

local function SafeRegister(f, event)
    return pcall(f.RegisterEvent, f, event)
end

-- Quest level as the client reports it, or nil when unknown / scaling.
local function QuestLevel(questID)
    if not questID or ns.IsSecret(questID) then return nil end
    if not C_QuestLog or not C_QuestLog.GetQuestDifficultyLevel then return nil end
    local ok, lvl = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
    if not ok or ns.IsSecret(lvl) or type(lvl) ~= "number" or lvl <= 0 then return nil end
    return lvl
end

-- "|cffrrggbb" for the game's difficulty colour of a quest level, or nil.
local function LevelColourCode(level)
    if not level or not GetQuestDifficultyColor then return nil end
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if not ok or type(c) ~= "table" then return nil end
    local r, g, b = c.r, c.g, c.b
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    if ns.IsSecret(r) or ns.IsSecret(g) or ns.IsSecret(b) then return nil end
    return ("|cff%02x%02x%02x"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function IsComplete(questID)
    if not questID or ns.IsSecret(questID) then return false end
    if not C_QuestLog or not C_QuestLog.IsComplete then return false end
    local ok, complete = pcall(C_QuestLog.IsComplete, questID)
    if not ok or ns.IsSecret(complete) then return false end
    return complete and true or false
end

-- Why Auto Quest would leave an available quest alone, or nil if it would
-- take it. "off" is deliberately not tagged: with Auto Quest disabled every
-- line would carry it.
local function SkipReason(questID, apiTrivial)
    if not TagsEnabled() then return nil end
    local aq = ns.AutoQuest
    if not aq or not aq.WouldSkip then return nil end
    local ok, skipped, reason = pcall(aq.WouldSkip, questID, apiTrivial)
    if not ok or not skipped then return nil end
    if reason == "off" or reason == nil then return nil end
    return reason
end

-- Builds the decorated title. `kind` is "available" or "active". `noTag`
-- leaves the skip tag off (the detail window shows it separately).
local function Decorate(title, questID, kind, apiTrivial, isComplete, noTag)
    local level = QuestLevel(questID)
    local colour = LevelColourCode(level)
    local text
    if kind == "active" and (isComplete or IsComplete(questID)) then
        text = GOLD .. (level and ("[" .. level .. "] ") or "") .. title .. " (complete)|r"
    elseif level and colour then
        text = colour .. "[" .. level .. "] " .. title .. "|r"
    else
        text = BLACK .. title .. "|r"
    end
    if kind == "available" and not noTag then
        local reason = SkipReason(questID, apiTrivial)
        if reason then
            text = text .. "  " .. GREY .. "skipped: " .. reason .. "|r"
        end
    end
    return text
end

local function Resize(button)
    if button.Resize then
        pcall(button.Resize, button)
    elseif button.GetTextHeight and button.Icon then
        local h = button:GetTextHeight() or 0
        local ih = button.Icon.GetHeight and button.Icon:GetHeight() or 16
        button:SetHeight(math.max(h + 2, ih))
    end
end

-------------------------------------------------------------------------------
-- Gossip frame
-------------------------------------------------------------------------------

-- Fresh lookups of the quests the gossip window is showing, keyed by ID.
local function GossipQuestSets()
    local available, active = {}, {}
    if C_GossipInfo then
        local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
        if ok and type(list) == "table" then
            for _, q in ipairs(list) do
                if q.questID and not ns.IsSecret(q.questID) then available[q.questID] = q end
            end
        end
        ok, list = pcall(C_GossipInfo.GetActiveQuests)
        if ok and type(list) == "table" then
            for _, q in ipairs(list) do
                if q.questID and not ns.IsSecret(q.questID) then active[q.questID] = q end
            end
        end
    end
    return available, active
end

local applying = false

-- Rebuilds one gossip quest button from its stored original title.
local function DecorateGossipButton(button, available, active)
    if applying or not Enabled() then return end
    local questID = button.GetID and button:GetID()
    if not questID or questID == 0 or ns.IsSecret(questID) then return end
    local info, kind = available[questID], "available"
    if not info then info, kind = active[questID], "active" end
    if not info then return end
    local title = button.MooseOriginalText or info.title
        or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
    if not title or ns.IsSecret(title) then return end
    button.MooseOriginalText = title
    applying = true
    button:SetText(Decorate(title, questID, kind, info.isTrivial, info.isComplete))
    Resize(button)
    applying = false
end

-- One-time instance hook: whenever Blizzard writes the title, rebuild it.
local function HookGossipButton(button)
    if button.MooseHooked then return end
    button.MooseHooked = true
    hooksecurefunc(button, "SetFormattedText", function(self, fmt, title)
        if applying then return end
        if type(title) == "string" and not ns.IsSecret(title) then
            self.MooseOriginalText = title
        end
        local available, active = GossipQuestSets()
        DecorateGossipButton(self, available, active)
    end)
end

local function GossipButtons()
    local sb = GossipFrame and GossipFrame.GreetingPanel and GossipFrame.GreetingPanel.ScrollBox
    if not sb or not sb.GetFrames then return {} end
    local ok, frames = pcall(sb.GetFrames, sb)
    if not ok or type(frames) ~= "table" then return {} end
    return frames
end

local function DecorateGossip()
    if not GossipFrame or not GossipFrame:IsShown() then return end
    local available, active = GossipQuestSets()
    for _, button in ipairs(GossipButtons()) do
        if button.GetID and button.SetFormattedText then
            local id = button:GetID()
            if id and id ~= 0 and (available[id] or active[id]) then
                -- The stored title belongs to a previous quest if the
                -- ScrollBox re-used this frame; trust the fresh info.
                local info = available[id] or active[id]
                if info.title and not ns.IsSecret(info.title) then
                    button.MooseOriginalText = info.title
                end
                HookGossipButton(button)
                DecorateGossipButton(button, available, active)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Greeting panel
-------------------------------------------------------------------------------

local function GreetingButtons()
    local pool = QuestFrameGreetingPanel and QuestFrameGreetingPanel.titleButtonPool
    if not pool or not pool.EnumerateActive then return function() return nil end end
    return pool:EnumerateActive()
end

local function DecorateGreeting()
    if not Enabled() then return end
    if not QuestFrameGreetingPanel or not QuestFrameGreetingPanel:IsShown() then return end
    local numActive = GetNumActiveQuests and GetNumActiveQuests() or 0
    if ns.IsSecret(numActive) then return end
    for button in GreetingButtons() do
        local index = button.GetID and button:GetID()
        if index and index > 0 then
            local questID, title, kind, apiTrivial, isComplete
            if button.isActive == 1 then
                kind = "active"
                if GetActiveQuestID then questID = GetActiveQuestID(index) end
                if GetActiveTitle then title, isComplete = GetActiveTitle(index) end
            else
                kind = "available"
                if GetAvailableQuestInfo then
                    local trivial, _, _, _, id = GetAvailableQuestInfo(index)
                    apiTrivial, questID = trivial, id
                end
                if GetAvailableTitle then title = GetAvailableTitle(index) end
            end
            if questID and not ns.IsSecret(questID) and title and not ns.IsSecret(title) then
                button.MooseOriginalText = title
                applying = true
                button:SetText(Decorate(title, questID, kind, apiTrivial, isComplete))
                Resize(button)
                applying = false
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Quest detail window (single-quest NPC offer)
-------------------------------------------------------------------------------

local function DetailOfferShown()
    if not QuestFrameDetailPanel or not QuestFrameDetailPanel:IsShown() then return false end
    if QuestInfoFrame and QuestInfoFrame.questLog then return false end
    return QuestInfoTitleHeader and QuestInfoTitleHeader.SetText and true or false
end

-- The skip reason on the detail window lives in its own line in the dark
-- strip between the parchment and the Accept/Decline buttons, spanning
-- from the Accept button to the Decline button so it is centred. The
-- ornate title font made a tag appended there hard to read.
local detailNote

local function DetailNote()
    if detailNote then return detailNote end
    if not QuestFrameDetailPanel or not QuestFrameDetailPanel.CreateFontString then return nil end
    local fs = QuestFrameDetailPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if QuestFrameAcceptButton and QuestFrameDeclineButton then
        fs:SetPoint("BOTTOMLEFT", QuestFrameAcceptButton, "TOPLEFT", 0, 6)
        fs:SetPoint("BOTTOMRIGHT", QuestFrameDeclineButton, "TOPRIGHT", 0, 6)
    else
        fs:SetPoint("BOTTOM", QuestFrameDetailPanel, "BOTTOM", 0, 44)
        fs:SetWidth(300)
    end
    fs:SetJustifyH("CENTER")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:Hide()
    detailNote = fs
    return fs
end

local REASON_COLOUR = {
    grey  = "|cff9d9d9d",
    green = "|cff40bf40",
}

local function UpdateDetailNote(questID)
    local note = DetailNote()
    if not note then return end
    local reason = SkipReason(questID, nil)
    if not reason then note:Hide() return end
    local word = reason
    if reason == "shift" then word = "Shift held" end
    local colour = REASON_COLOUR[reason] or GREY
    note:SetText(GOLD .. "Auto Quest left this for you: " .. colour .. word .. "|r"
        .. (reason == "shift" and "" or GOLD .. " quest|r") .. "|r")
    note:Show()
end

local function DecorateDetail()
    if applying or not Enabled() or not DetailOfferShown() then return end
    local questID = GetQuestID and GetQuestID()
    if not questID or questID == 0 or ns.IsSecret(questID) then return end
    -- GetTitleText() is always the raw title, so a follow-up quest that
    -- reuses the panel is picked up and nothing is decorated twice.
    local title = GetTitleText and GetTitleText()
    if not title or title == "" or ns.IsSecret(title) then return end
    applying = true
    QuestInfoTitleHeader:SetText(Decorate(title, questID, "available", nil, nil, true))
    applying = false
    UpdateDetailNote(questID)
end

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------

local function RunPass()
    if not ns.db then return end
    xpcall(function()
        DecorateGossip()
        DecorateGreeting()
        DecorateDetail()
    end, function(err) ns.Print("QuestLists error: " .. tostring(err)) end)
end

local function SchedulePass()
    if passQueued then return end
    passQueued = true
    C_Timer.After(0.05, function()
        passQueued = false
        RunPass()
    end)
end

local function ClearStored(buttons)
    for _, button in ipairs(buttons) do button.MooseOriginalText = nil end
end

-- Blizzard's quest UI loads after this file on the Forever client, so the
-- hooks are installed whenever the frames turn up.
local function InstallHooks()
    if not hooked.greeting and type(QuestFrameGreetingPanel_OnShow) == "function" then
        hooksecurefunc("QuestFrameGreetingPanel_OnShow", function() SchedulePass() end)
        hooked.greeting = true
    end
    if not hooked.greetingHide and QuestFrameGreetingPanel and QuestFrameGreetingPanel.HookScript then
        QuestFrameGreetingPanel:HookScript("OnHide", function()
            for button in GreetingButtons() do button.MooseOriginalText = nil end
        end)
        hooked.greetingHide = true
    end
    if not hooked.gossipUpdate and GossipFrame and type(GossipFrame.Update) == "function" then
        hooksecurefunc(GossipFrame, "Update", function() SchedulePass() end)
        hooked.gossipUpdate = true
    end
    if not hooked.gossipHide and GossipFrame and GossipFrame.HookScript then
        GossipFrame:HookScript("OnHide", function() ClearStored(GossipButtons()) end)
        hooked.gossipHide = true
    end
    if not hooked.detailTitle and type(QuestInfo_ShowTitle) == "function" then
        hooksecurefunc("QuestInfo_ShowTitle", function()
            if applying then return end
            xpcall(DecorateDetail, function(err) ns.Print("QuestLists error: " .. tostring(err)) end)
        end)
        hooked.detailTitle = true
    end
    if not hooked.detailHide and QuestFrameDetailPanel and QuestFrameDetailPanel.HookScript then
        -- Blizzard rewrites the header from GetTitleText() on every show, so
        -- nothing needs restoring; the hook only exists so a stale decorated
        -- title is never left in the shared header for the quest log view.
        QuestFrameDetailPanel:HookScript("OnHide", function()
            if detailNote then detailNote:Hide() end
            if QuestInfoTitleHeader and GetTitleText then
                local raw = GetTitleText()
                if type(raw) == "string" and not ns.IsSecret(raw) then
                    applying = true
                    QuestInfoTitleHeader:SetText(raw)
                    applying = false
                end
            end
        end)
        hooked.detailHide = true
    end
end

SafeRegister(frame, "ADDON_LOADED")
SafeRegister(frame, "PLAYER_LOGIN")
SafeRegister(frame, "GOSSIP_SHOW")
SafeRegister(frame, "QUEST_GREETING")
SafeRegister(frame, "QUEST_DETAIL")
SafeRegister(frame, "QUEST_LOG_UPDATE")
frame:SetScript("OnEvent", function(self, event)
    if event == "ADDON_LOADED" or event == "PLAYER_LOGIN" then
        InstallHooks()
        return
    end
    if not ns.db or not Enabled() then return end
    if event == "QUEST_LOG_UPDATE" then
        local gossipShown = GossipFrame and GossipFrame:IsShown()
        local greetingShown = QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown()
        if not gossipShown and not greetingShown and not DetailOfferShown() then return end
    end
    InstallHooks()
    SchedulePass()
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "questListsModule",
    label = "Quest Lists",
    group = "Quests",
    options = {
        { key = "questListColour", label = "Colour quests by difficulty", default = true,
          tooltip = "Quest names in NPC dialogs and the quest offer window take the game's difficulty colour, with the level in front.",
          onChange = function() SchedulePass() end },
        { key = "questListSkipTag", label = "Show why a quest was skipped", default = true, parent = "questListColour",
          tooltip = "Adds a small tag such as 'skipped: green' beside quests Auto Quest left for you.",
          onChange = function() SchedulePass() end },
    },
    OnInit = function() InstallHooks() end,
})
