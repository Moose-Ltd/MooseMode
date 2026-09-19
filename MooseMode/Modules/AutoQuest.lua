-------------------------------------------------------------------------------
-- MooseMode -- AutoQuest
--
-- Accepts quests automatically from quest detail windows, quest greeting
-- lists and gossip windows. Low-level (trivial) quests are skipped unless
-- the sub-option is on. Hold SHIFT while talking to an NPC to skip it all.
--
-- Options (account-wide):
--   autoQuest           Auto accept quests
--   autoQuestLowLevel   Include low-level quests (sub-option)
--   autoGossip          Auto select gossip when it is the only option
-------------------------------------------------------------------------------

local ADDON, ns = ...

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Enabled(key)
    return ns.db and ns.db[key] and not IsShiftKeyDown()
end

-- True when a quest is below the trivial (grey) threshold for the player.
local function IsTrivial(questID)
    if not questID or not C_QuestLog or not C_QuestLog.IsQuestTrivial then return false end
    local ok, trivial = pcall(C_QuestLog.IsQuestTrivial, questID)
    if not ok or ns.IsSecret(trivial) then return false end
    return trivial and true or false
end

local function WantQuest(isTrivial)
    if ns.IsSecret(isTrivial) then return false end
    if isTrivial and not ns.db.autoQuestLowLevel then return false end
    return true
end

-------------------------------------------------------------------------------
-- Quest accepting
-------------------------------------------------------------------------------

-- QUEST_DETAIL: the "Accept / Decline" window for a single quest.
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
    if not WantQuest(IsTrivial(questID)) then return end
    AcceptQuest()
end

-- QUEST_GREETING: the old-style list of available and active quests on an
-- NPC without gossip text. Pick the first eligible available quest; the
-- greeting fires again for the next one once that quest is dealt with.
local function OnQuestGreeting()
    if not Enabled("autoQuest") then return end
    if not GetNumAvailableQuests or not SelectAvailableQuest then return end

    local n = GetNumAvailableQuests()
    if ns.IsSecret(n) or not n then return end
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

-- GOSSIP_SHOW: gossip windows can list available quests alongside options.
-- Returns true if it picked a quest (so the caller stops there).
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
-- Gossip
-------------------------------------------------------------------------------

local function CountTable(t)
    return type(t) == "table" and #t or 0
end

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

local function OnGossipShow()
    if AcceptGossipQuest() then return end
    SelectOnlyGossipOption()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_GREETING")
frame:RegisterEvent("GOSSIP_SHOW")
frame:SetScript("OnEvent", function(self, event)
    if not ns.db then return end
    if event == "QUEST_DETAIL" then
        OnQuestDetail()
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
        { key = "autoGossip", label = "Auto select gossip", default = true,
          tooltip = "When an NPC offers exactly one gossip option and no quests, pick it automatically. Menus with several choices are never touched. Hold Shift to skip." },
    },
})
