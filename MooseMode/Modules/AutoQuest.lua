-------------------------------------------------------------------------------
-- MooseMode -- AutoQuest
--
-- Accepts quests automatically from quest detail windows, quest greeting
-- lists and gossip windows, hands in completed quests, and picks up the
-- follow-up quests that hand-ins unlock. Low-level (trivial) quests are
-- skipped unless the sub-option is on. Hold SHIFT while talking to an NPC
-- to skip it all.
--
-- Options (account-wide):
--   autoQuest           Auto accept quests
--   autoQuestLowLevel   Include low-level quests (sub-option)
--   autoQuestTurnIn     Auto complete quest hand-ins (sub-option)
--   autoGossip          Auto select gossip when it is the only option
--
-- Flow at an NPC: hand in anything complete first, then accept anything
-- available, then (gossip windows only) pick the sole gossip option. After a
-- hand-in the server re-opens the NPC (QUEST_DETAIL for a chained follow-up,
-- or QUEST_GREETING / GOSSIP_SHOW again), so follow-ups are accepted by the
-- same handlers with no extra plumbing.
-------------------------------------------------------------------------------

local ADDON, ns = ...

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Enabled(key)
    return ns.db and ns.db[key] and not IsShiftKeyDown()
end

-- Hand-ins need the parent option and the sub-option both on.
local function TurnInEnabled()
    return Enabled("autoQuest") and ns.db.autoQuestTurnIn
end

-- True when a quest is below the trivial (grey) threshold for the player.
local function IsTrivial(questID)
    if not questID or not C_QuestLog or not C_QuestLog.IsQuestTrivial then return false end
    local ok, trivial = pcall(C_QuestLog.IsQuestTrivial, questID)
    if not ok or ns.IsSecret(trivial) then return false end
    return trivial and true or false
end

-- True when the quest is in the log with all objectives done.
local function IsQuestComplete(questID)
    if not questID or ns.IsSecret(questID) then return false end
    if not C_QuestLog or not C_QuestLog.IsComplete then return false end
    local ok, complete = pcall(C_QuestLog.IsComplete, questID)
    if not ok or ns.IsSecret(complete) then return false end
    return complete and true or false
end

-- True when the quest is already in the log (accepting again would error).
local function IsOnQuest(questID)
    if not questID or ns.IsSecret(questID) then return false end
    if not C_QuestLog or not C_QuestLog.IsOnQuest then return false end
    local ok, on = pcall(C_QuestLog.IsOnQuest, questID)
    if not ok or ns.IsSecret(on) then return false end
    return on and true or false
end

local function WantQuest(isTrivial)
    if ns.IsSecret(isTrivial) then return false end
    if isTrivial and not ns.db.autoQuestLowLevel then return false end
    return true
end

local function CountTable(t)
    return type(t) == "table" and #t or 0
end

-------------------------------------------------------------------------------
-- Quest accepting
-------------------------------------------------------------------------------

-- QUEST_DETAIL: the "Accept / Decline" window for a single quest. This is
-- also how chained follow-ups arrive right after a hand-in.
local function OnQuestDetail()
    if not Enabled("autoQuest") then return end

    if QuestGetAutoAccept and QuestGetAutoAccept() then
        -- Auto-accept quests (area triggers etc.) are already in the log;
        -- the window only needs dismissing.
        if AcknowledgeAutoAcceptQuest then AcknowledgeAutoAcceptQuest() end
        return
    end

    local questID = GetQuestID and GetQuestID()
    if ns.IsSecret(questID) then return end
    if IsOnQuest(questID) then return end
    if not WantQuest(IsTrivial(questID)) then return end
    AcceptQuest()
end

-- QUEST_GREETING available-quest half. Pick the first eligible available
-- quest; the greeting fires again for the next one once that quest is dealt
-- with. Returns true if it selected something.
local function AcceptGreetingQuest()
    if not Enabled("autoQuest") then return false end
    if not GetNumAvailableQuests or not SelectAvailableQuest then return false end

    local n = GetNumAvailableQuests()
    if ns.IsSecret(n) or not n then return false end
    for i = 1, n do
        local isTrivial = false
        if GetAvailableQuestInfo then
            local ok, trivial = pcall(GetAvailableQuestInfo, i)
            if ok then isTrivial = trivial end
        end
        if WantQuest(isTrivial) then
            SelectAvailableQuest(i)
            return true
        end
    end
    return false
end

-- GOSSIP_SHOW available-quest half. Returns true if it picked a quest.
local function AcceptGossipQuest()
    if not Enabled("autoQuest") then return false end
    if not C_GossipInfo or not C_GossipInfo.GetAvailableQuests then return false end

    local ok, quests = pcall(C_GossipInfo.GetAvailableQuests)
    if not ok or type(quests) ~= "table" then return false end
    for _, q in ipairs(quests) do
        if q.questID and not ns.IsSecret(q.questID) then
            local trivial = q.isTrivial
            if trivial == nil then trivial = IsTrivial(q.questID) end
            if WantQuest(trivial) then
                C_GossipInfo.SelectAvailableQuest(q.questID)
                return true
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Quest hand-ins
-------------------------------------------------------------------------------

-- QUEST_PROGRESS: the "Continue" window listing required items. Only move on
-- when the server says the quest can actually be completed.
local function OnQuestProgress()
    if not TurnInEnabled() then return end
    if not IsQuestCompletable or not CompleteQuest then return end
    local ok, completable = pcall(IsQuestCompletable)
    if not ok or ns.IsSecret(completable) or not completable then return end
    CompleteQuest()
end

-- QUEST_COMPLETE: the reward window. Blizzard's own Complete button calls
-- GetQuestReward(itemChoice) where itemChoice is 0 when there is nothing to
-- choose. With exactly one choice the answer is obvious; with several the
-- window is left open for the player to decide.
local function OnQuestComplete()
    if not TurnInEnabled() then return end
    if not GetNumQuestChoices or not GetQuestReward then return end
    local n = GetNumQuestChoices()
    if ns.IsSecret(n) or not n then return end
    if n == 0 then
        GetQuestReward(0)
    elseif n == 1 then
        GetQuestReward(1)
    end
end

-- QUEST_GREETING active-quest half: select the first quest that is ready to
-- hand in. Returns true if it selected something.
local function TurnInGreetingQuest()
    if not TurnInEnabled() then return false end
    if not GetNumActiveQuests or not GetActiveQuestID or not SelectActiveQuest then return false end

    local n = GetNumActiveQuests()
    if ns.IsSecret(n) or not n then return false end
    for i = 1, n do
        local ok, questID = pcall(GetActiveQuestID, i)
        if ok and IsQuestComplete(questID) then
            SelectActiveQuest(i)
            return true
        end
    end
    return false
end

-- GOSSIP_SHOW active-quest half. Returns true if it selected something.
local function TurnInGossipQuest()
    if not TurnInEnabled() then return false end
    if not C_GossipInfo or not C_GossipInfo.GetActiveQuests or not C_GossipInfo.SelectActiveQuest then return false end

    local ok, quests = pcall(C_GossipInfo.GetActiveQuests)
    if not ok or type(quests) ~= "table" then return false end
    for _, q in ipairs(quests) do
        if q.questID and not ns.IsSecret(q.questID) then
            local complete = q.isComplete
            if complete == nil then complete = IsQuestComplete(q.questID) end
            if not ns.IsSecret(complete) and complete then
                C_GossipInfo.SelectActiveQuest(q.questID)
                return true
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Gossip
-------------------------------------------------------------------------------

-- Auto-select a gossip option only when it is the sole thing on offer: no
-- quests to pick up or hand in, and exactly one option. Multi-option menus
-- (vendors, trainers, flight masters with extra choices) are left alone.
local function SelectOnlyGossipOption()
    if not Enabled("autoGossip") then return false end
    if not C_GossipInfo or not C_GossipInfo.GetOptions or not C_GossipInfo.SelectOption then return false end

    local okA, active = pcall(C_GossipInfo.GetNumActiveQuests)
    if not okA or ns.IsSecret(active) or (active or 0) > 0 then return false end

    local okQ, available = pcall(C_GossipInfo.GetAvailableQuests)
    if not okQ or CountTable(available) > 0 then return false end

    local okO, options = pcall(C_GossipInfo.GetOptions)
    if not okO or CountTable(options) ~= 1 then return false end

    local opt = options[1]
    local id = opt and opt.gossipOptionID
    if not id or ns.IsSecret(id) then return false end
    C_GossipInfo.SelectOption(id)
    return true
end

-------------------------------------------------------------------------------
-- Window handlers: hand-ins first, then pick-ups, then gossip
-------------------------------------------------------------------------------

local function OnQuestGreeting()
    if TurnInGreetingQuest() then return end
    AcceptGreetingQuest()
end

local function OnGossipShow()
    if TurnInGossipQuest() then return end
    if AcceptGossipQuest() then return end
    SelectOnlyGossipOption()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_PROGRESS")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("QUEST_GREETING")
frame:RegisterEvent("GOSSIP_SHOW")
frame:SetScript("OnEvent", function(self, event)
    if not ns.db then return end
    if event == "QUEST_DETAIL" then
        OnQuestDetail()
    elseif event == "QUEST_PROGRESS" then
        OnQuestProgress()
    elseif event == "QUEST_COMPLETE" then
        OnQuestComplete()
    elseif event == "QUEST_GREETING" then
        OnQuestGreeting()
    elseif event == "GOSSIP_SHOW" then
        OnGossipShow()
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "autoQuestModule",
    label = "Auto Quest",
    options = {
        { key = "autoQuest", label = "Auto accept quests", default = true,
          tooltip = "Accept quests automatically from quest givers. Low-level (grey) quests are skipped unless the sub-option below is on. Hold Shift while talking to an NPC to skip." },
        { key = "autoQuestLowLevel", label = "Include low-level quests", default = false, parent = "autoQuest",
          tooltip = "Also accept quests that are trivial (grey) for your level." },
        { key = "autoQuestTurnIn", label = "Auto complete quest hand-ins", default = true, parent = "autoQuest",
          tooltip = "Hand in completed quests automatically and pick up any follow-up. If a quest offers more than one reward to choose from, the window stays open so you can pick." },
        { key = "autoGossip", label = "Auto select gossip", default = true,
          tooltip = "When an NPC offers exactly one gossip option and no quests, pick it automatically. Menus with several choices are never touched. Hold Shift to skip." },
    },
})
