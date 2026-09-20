-------------------------------------------------------------------------------
-- MooseMode -- QuestLists
--
-- One job: when Auto Quest deliberately leaves a quest for you, say so at
-- the bottom of the NPC window, so nothing feels like it silently failed.
-- Blizzard's own quest text, colours and lists are never touched.
--
-- Three windows get a notice:
--   * Quest detail (single-quest offer, QuestFrameDetailPanel): a line in
--     the button row between Accept and Decline, "Skipped: green quest".
--   * Quest greeting list (QuestFrameGreetingPanel): a line on the bottom
--     bar to the left of the Goodbye button (QuestFrameGreetingGoodbyeButton),
--     "Skipped: Westfall Stew (green), Rat Catching (grey)", shortened to
--     "Skipped: 2 low-level quests" when it would not fit.
--   * Gossip window (GossipFrame): the same line to the left of
--     GossipFrame.GreetingPanel.GoodbyeButton (Blizzard_UIPanels_Game,
--     Shared/GossipFrameShared.xml line 51).
--
-- Reasons come from ns.AutoQuest.WouldSkip, so the notice always matches the
-- accept decision; the reason word is coloured with the difficulty colour
-- from ns.AutoQuest.DifficultyRGB (grey / green), the rest is gold.
--
-- Blizzard's quest UI loads after this file on the Forever client, so the
-- OnHide hooks are installed whenever the frames turn up. A pass runs on
-- QUEST_DETAIL / QUEST_GREETING / GOSSIP_SHOW / GOSSIP_UPDATE (0.05 s later)
-- and again on QUEST_LOG_UPDATE while one of the windows is open.
--
-- Option (account-wide):
--   questListSkipNote   Show why a quest was skipped
-------------------------------------------------------------------------------

local ADDON, ns = ...

local GOLD = "|cffffd100"
local GREY = "|cff808080"

local frame = CreateFrame("Frame")
local hooked = {}
local passQueued = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Enabled()
    return ns.db and ns.db.questListSkipNote and true or false
end

local function SafeRegister(f, event)
    return pcall(f.RegisterEvent, f, event)
end

-- "|cffrrggbb" for a difficulty name (grey/green/...), or grey when unknown.
local function ColourCodeFor(name)
    local aq = ns.AutoQuest
    if not name or not aq or not aq.DifficultyRGB then return GREY end
    local r, g, b = aq.DifficultyRGB(name)
    if type(r) ~= "number" then return GREY end
    return ("|cff%02x%02x%02x"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Why Auto Quest would leave an available quest alone, or nil if it would
-- take it. "off" is deliberately not reported: with Auto Quest disabled every
-- quest would carry it.
local function SkipReason(questID, apiTrivial)
    if not Enabled() then return nil end
    if not questID or ns.IsSecret(questID) then return nil end
    local aq = ns.AutoQuest
    if not aq or not aq.WouldSkip then return nil end
    local ok, skipped, reason = pcall(aq.WouldSkip, questID, apiTrivial)
    if not ok or not skipped then return nil end
    if reason == "off" or reason == nil then return nil end
    return reason
end

local function ReasonText(reason)
    if reason == "shift" then return GOLD .. "Shift held|r" end
    return ColourCodeFor(reason) .. reason .. "|r"
end

-- Creates a notice FontString on `parent`; `anchor(fs)` positions it.
local function MakeNote(parent, anchor)
    if not parent or not parent.CreateFontString then return nil end
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchor(fs)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(false)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:Hide()
    return fs
end

-- Width available to a note, from its anchors, or nil if not measurable.
local function NoteWidth(fs)
    local ok, w = pcall(function() return fs:GetRight() - fs:GetLeft() end)
    if ok and type(w) == "number" and w > 0 then return w end
    return nil
end

-- Builds "Skipped: A (green), B (grey)" for a list of {title, reason};
-- shortens to a count when the text is too wide for the note.
local function ListText(fs, skipped)
    local parts = {}
    for _, s in ipairs(skipped) do
        parts[#parts + 1] = GOLD .. s.title .. " (|r" .. ReasonText(s.reason) .. GOLD .. ")|r"
    end
    local long = GOLD .. "Skipped: |r" .. table.concat(parts, GOLD .. ", |r")
    fs:SetText(long)
    local width = NoteWidth(fs)
    local ok, sw = pcall(fs.GetStringWidth, fs)
    if width and ok and type(sw) == "number" and sw > width then
        local n = #skipped
        fs:SetText(GOLD .. "Skipped: " .. n .. " low-level quest" .. (n == 1 and "" or "s") .. "|r")
    end
end

local function ShowListNote(fs, skipped)
    if not fs then return end
    if #skipped == 0 then fs:Hide() return end
    ListText(fs, skipped)
    fs:Show()
end

-------------------------------------------------------------------------------
-- Quest detail window (single-quest NPC offer)
-------------------------------------------------------------------------------

local detailNote

local function DetailOfferShown()
    if not QuestFrameDetailPanel or not QuestFrameDetailPanel:IsShown() then return false end
    if QuestInfoFrame and QuestInfoFrame.questLog then return false end
    return true
end

-- The note sits in the button row itself, between Accept and Decline, so it
-- can never land on the parchment.
local function DetailNote()
    if detailNote then return detailNote end
    detailNote = MakeNote(QuestFrameDetailPanel, function(fs)
        if QuestFrameAcceptButton and QuestFrameDeclineButton then
            fs:SetPoint("LEFT", QuestFrameAcceptButton, "RIGHT", 8, 0)
            fs:SetPoint("RIGHT", QuestFrameDeclineButton, "LEFT", -8, 0)
        else
            fs:SetPoint("BOTTOM", QuestFrameDetailPanel, "BOTTOM", 0, 14)
            fs:SetWidth(200)
        end
    end)
    return detailNote
end

local function UpdateDetail()
    local note = DetailNote()
    if not note then return end
    if not DetailOfferShown() then note:Hide() return end
    local questID = GetQuestID and GetQuestID()
    local reason = SkipReason(questID, nil)
    if not reason then note:Hide() return end
    local text
    if reason == "shift" then
        text = GOLD .. "Skipped: |r" .. ReasonText(reason)
    else
        local width = NoteWidth(note)
        if width and width < 120 then
            text = GOLD .. "Skipped: |r" .. ReasonText(reason)
        else
            text = GOLD .. "Skipped: |r" .. ReasonText(reason) .. GOLD .. " quest|r"
        end
    end
    note:SetText(text)
    note:Show()
end

-------------------------------------------------------------------------------
-- Quest greeting list
-------------------------------------------------------------------------------

local greetingNote

local function GreetingNote()
    if greetingNote then return greetingNote end
    greetingNote = MakeNote(QuestFrameGreetingPanel, function(fs)
        if QuestFrameGreetingGoodbyeButton then
            fs:SetPoint("RIGHT", QuestFrameGreetingGoodbyeButton, "LEFT", -8, 0)
            fs:SetPoint("LEFT", QuestFrameGreetingPanel, "LEFT", 16, 0)
        else
            fs:SetPoint("BOTTOMLEFT", QuestFrameGreetingPanel, "BOTTOMLEFT", 16, 14)
            fs:SetWidth(300)
        end
    end)
    return greetingNote
end

local function UpdateGreeting()
    local note = GreetingNote()
    if not note then return end
    if not QuestFrameGreetingPanel or not QuestFrameGreetingPanel:IsShown() then note:Hide() return end
    local skipped = {}
    local n = GetNumAvailableQuests and GetNumAvailableQuests() or 0
    if ns.IsSecret(n) then note:Hide() return end
    for i = 1, n do
        local questID, apiTrivial
        if GetAvailableQuestInfo then
            local trivial, _, _, _, id = GetAvailableQuestInfo(i)
            apiTrivial, questID = trivial, id
        end
        local reason = SkipReason(questID, apiTrivial)
        if reason then
            local title = GetAvailableTitle and GetAvailableTitle(i)
            if not title or ns.IsSecret(title) then title = "quest " .. i end
            skipped[#skipped + 1] = { title = title, reason = reason }
        end
    end
    ShowListNote(note, skipped)
end

-------------------------------------------------------------------------------
-- Gossip window
-------------------------------------------------------------------------------

local gossipNote

local function GossipGoodbye()
    local panel = GossipFrame and GossipFrame.GreetingPanel
    if panel and panel.GoodbyeButton then return panel.GoodbyeButton end
    return GossipFrameGreetingGoodbyeButton
end

local function GossipNote()
    if gossipNote then return gossipNote end
    gossipNote = MakeNote(GossipFrame, function(fs)
        local goodbye = GossipGoodbye()
        if goodbye then
            fs:SetPoint("RIGHT", goodbye, "LEFT", -8, 0)
            fs:SetPoint("LEFT", GossipFrame, "LEFT", 16, 0)
        else
            fs:SetPoint("BOTTOMLEFT", GossipFrame, "BOTTOMLEFT", 16, 14)
            fs:SetWidth(300)
        end
    end)
    return gossipNote
end

local function UpdateGossip()
    local note = GossipNote()
    if not note then return end
    if not GossipFrame or not GossipFrame:IsShown() then note:Hide() return end
    local skipped = {}
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
        if ok and type(list) == "table" then
            for _, q in ipairs(list) do
                local reason = SkipReason(q.questID, q.isTrivial)
                if reason then
                    local title = q.title
                    if not title or ns.IsSecret(title) then
                        title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q.questID) or "quest"
                    end
                    skipped[#skipped + 1] = { title = title, reason = reason }
                end
            end
        end
    end
    ShowListNote(note, skipped)
end

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------

local function RunPass()
    if not ns.db then return end
    xpcall(function()
        UpdateGossip()
        UpdateGreeting()
        UpdateDetail()
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

local function HideAll()
    if detailNote then detailNote:Hide() end
    if greetingNote then greetingNote:Hide() end
    if gossipNote then gossipNote:Hide() end
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
            if greetingNote then greetingNote:Hide() end
        end)
        hooked.greetingHide = true
    end
    if not hooked.gossipUpdate and GossipFrame and type(GossipFrame.Update) == "function" then
        hooksecurefunc(GossipFrame, "Update", function() SchedulePass() end)
        hooked.gossipUpdate = true
    end
    if not hooked.gossipHide and GossipFrame and GossipFrame.HookScript then
        GossipFrame:HookScript("OnHide", function()
            if gossipNote then gossipNote:Hide() end
        end)
        hooked.gossipHide = true
    end
    if not hooked.detailHide and QuestFrameDetailPanel and QuestFrameDetailPanel.HookScript then
        QuestFrameDetailPanel:HookScript("OnHide", function()
            if detailNote then detailNote:Hide() end
        end)
        hooked.detailHide = true
    end
end

SafeRegister(frame, "ADDON_LOADED")
SafeRegister(frame, "PLAYER_LOGIN")
SafeRegister(frame, "GOSSIP_SHOW")
SafeRegister(frame, "GOSSIP_UPDATE")
SafeRegister(frame, "QUEST_GREETING")
SafeRegister(frame, "QUEST_DETAIL")
SafeRegister(frame, "QUEST_LOG_UPDATE")
frame:SetScript("OnEvent", function(self, event)
    if event == "ADDON_LOADED" or event == "PLAYER_LOGIN" then
        InstallHooks()
        return
    end
    if not ns.db then return end
    if not Enabled() then HideAll() return end
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
        { key = "questListSkipNote", label = "Show why a quest was skipped", default = true,
          tooltip = "A line at the bottom of NPC quest windows explains anything Auto Quest left for you.",
          onChange = function(checked) if checked then SchedulePass() else HideAll() end end },
    },
    OnInit = function()
        local db = ns.db
        -- Migration from the earlier two-option version (colour + tag).
        if db.questListSkipTag ~= nil then
            db.questListSkipNote = db.questListSkipTag and true or false
        end
        db.questListSkipTag = nil
        db.questListColour = nil
        InstallHooks()
    end,
})
