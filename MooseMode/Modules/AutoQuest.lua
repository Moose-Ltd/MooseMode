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
--
-- API usage mirrors Blizzard's own 12.x UI code (Blizzard_UIPanels_Game):
--   GossipFrameShared.lua  C_GossipInfo.SelectAvailableQuest(questID)
--                          C_GossipInfo.SelectActiveQuest(questID)
--                          C_GossipInfo.SelectOptionByIndex(orderIndex)
--                          GetAvailableQuests()/GetActiveQuests() entries carry
--                          questID, title, isTrivial, isComplete, isIgnored
--   QuestFrame.lua         SelectAvailableQuest(index) / SelectActiveQuest(index)
--                          GetAvailableQuestInfo(i) -> isTrivial, frequency, ...
--                          GetQuestReward(itemChoice), CompleteQuest(), AcceptQuest()
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
    if not questID or ns.IsSecret(questID) then return false end
    local trivial = C_QuestLog.IsQuestTrivial(questID)
    if ns.IsSecret(trivial) then return false end
    return trivial and true or false
end

-- True when the quest is in the log with all objectives done.
local function IsQuestComplete(questID)
    if not questID or ns.IsSecret(questID) then return false end
    local complete = C_QuestLog.IsComplete(questID)
    if ns.IsSecret(complete) then return false end
    return complete and true or false
end

-- True when the quest is already in the log (accepting again would error).
local function IsOnQuest(questID)
    if not questID or ns.IsSecret(questID) then return false end
    local on = C_QuestLog.IsOnQuest(questID)
    if ns.IsSecret(on) then return false end
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

    if QuestGetAutoAccept() then
        -- Auto-accept quests (area triggers etc.) are already in the log;
        -- the window only needs dismissing.
        AcknowledgeAutoAcceptQuest()
        return
    end

    local questID = GetQuestID()
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

    local n = GetNumAvailableQuests()
    if ns.IsSecret(n) or not n then return false end
    for i = 1, n do
        local isTrivial = GetAvailableQuestInfo(i)
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

    local quests = C_GossipInfo.GetAvailableQuests()
    if type(quests) ~= "table" then return false end
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
    local completable = IsQuestCompletable()
    if ns.IsSecret(completable) or not completable then return end
    CompleteQuest()
end

-- QUEST_COMPLETE: the reward window. Blizzard's own Complete button calls
-- GetQuestReward(itemChoice) where itemChoice is 0 when there is nothing to
-- choose. With exactly one choice the answer is obvious; with several the
-- window is left open for the player to decide.
local function OnQuestComplete()
    if not TurnInEnabled() then return end
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

    local n = GetNumActiveQuests()
    if ns.IsSecret(n) or not n then return false end
    for i = 1, n do
        local questID = GetActiveQuestID(i)
        if IsQuestComplete(questID) then
            SelectActiveQuest(i)
            return true
        end
    end
    return false
end

-- GOSSIP_SHOW active-quest half. Returns true if it selected something.
local function TurnInGossipQuest()
    if not TurnInEnabled() then return false end

    local quests = C_GossipInfo.GetActiveQuests()
    if type(quests) ~= "table" then return false end
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
-- Selection goes through SelectOptionByIndex(orderIndex), the call Blizzard's
-- own GossipFrame makes; SelectOption(gossipOptionID) is the fallback.
local function SelectOnlyGossipOption()
    if not Enabled("autoGossip") then return false end

    local active = C_GossipInfo.GetNumActiveQuests()
    if ns.IsSecret(active) or (active or 0) > 0 then return false end

    local available = C_GossipInfo.GetNumAvailableQuests()
    if ns.IsSecret(available) or (available or 0) > 0 then return false end

    local options = C_GossipInfo.GetOptions()
    if CountTable(options) ~= 1 then return false end

    local opt = options[1]
    if not opt then return false end
    if opt.orderIndex and not ns.IsSecret(opt.orderIndex) and C_GossipInfo.SelectOptionByIndex then
        C_GossipInfo.SelectOptionByIndex(opt.orderIndex)
        return true
    end
    local id = opt.gossipOptionID
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

local handlers = {
    QUEST_DETAIL   = OnQuestDetail,
    QUEST_PROGRESS = OnQuestProgress,
    QUEST_COMPLETE = OnQuestComplete,
    QUEST_GREETING = OnQuestGreeting,
    GOSSIP_SHOW    = OnGossipShow,
}

-- Errors inside a handler would otherwise vanish unless the player has Lua
-- errors displayed; print them so a broken NPC interaction is never silent.
local function OnHandlerError(err)
    ns.Print("AutoQuest error: " .. tostring(err))
end

local frame = CreateFrame("Frame")
for event in pairs(handlers) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent", function(self, event)
    if not ns.db then return end
    local fn = handlers[event]
    if fn then xpcall(fn, OnHandlerError) end
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
