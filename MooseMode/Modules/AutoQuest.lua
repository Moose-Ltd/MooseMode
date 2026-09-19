-------------------------------------------------------------------------------
-- MooseMode -- AutoQuest
--
-- Accepts quests automatically from quest detail windows, quest greeting
-- lists and gossip windows, hands in completed quests, and picks up the
-- follow-up quests that hand-ins unlock. Low-level quests (the client says
-- trivial, or the quest level is at or below the grey threshold) are
-- skipped unless the sub-option is on. Hold SHIFT while talking to an NPC
-- to skip it all.
--
-- Options (account-wide):
--   autoQuest           Auto accept quests
--   autoQuestLowLevel   Include low-level quests (sub-option)
--   autoQuestSkipBelowLevel  Also skip quests below the player's level (sub-option)
--   autoQuestTurnIn     Auto complete quest hand-ins (sub-option)
--   autoGossip          Auto select gossip when it is the only option
--   autoQuestDebug      Log every event and decision to chat (sub-option)
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

-- The client's own trivial flag for a quest, or nil when unavailable.
local function ApiTrivial(questID)
    if not questID or ns.IsSecret(questID) then return nil end
    local trivial = C_QuestLog.IsQuestTrivial(questID)
    if ns.IsSecret(trivial) then return nil end
    return trivial and true or false
end

local function PlayerLevel()
    local lvl = UnitLevel("player")
    if ns.IsSecret(lvl) or type(lvl) ~= "number" then return nil end
    return lvl
end

-- Quest level as the client reports it; nil when unknown or level-scaling
-- (0 / -1), which is never treated as low level.
local function QuestLevel(questID)
    if not questID or ns.IsSecret(questID) then return nil end
    if not C_QuestLog.GetQuestDifficultyLevel then return nil end
    local lvl = C_QuestLog.GetQuestDifficultyLevel(questID)
    if ns.IsSecret(lvl) or type(lvl) ~= "number" or lvl <= 0 then return nil end
    return lvl
end

-- How many levels below the player a quest turns grey. The client answers
-- via UnitQuestTrivialLevelRange; the Classic formula is the fallback.
local function TrivialRange(playerLevel)
    if UnitQuestTrivialLevelRange then
        local r = UnitQuestTrivialLevelRange("player")
        if not ns.IsSecret(r) and type(r) == "number" and r > 0 then return r end
    end
    if not playerLevel then return nil end
    if playerLevel <= 5 then return playerLevel end          -- nothing is grey yet
    if playerLevel <= 39 then return 5 + math.floor(playerLevel / 10) end
    return 1 + math.floor(playerLevel / 5)
end

-- Low level = the client says trivial, OR the quest level is at or below
-- the player's grey threshold. The API flag alone proved unreliable on
-- Forever, so the level check is a second opinion.
local function IsLowLevel(questID, apiFlag)
    if apiFlag == nil then apiFlag = ApiTrivial(questID) end
    if not ns.IsSecret(apiFlag) and apiFlag then return true end
    local qlvl, plvl = QuestLevel(questID), PlayerLevel()
    if not qlvl or not plvl then return false end
    local range = TrivialRange(plvl)
    if range and qlvl <= plvl - range then return true end
    -- Stricter rule: anything below the player's level (green) counts too.
    if ns.db.autoQuestSkipBelowLevel and qlvl < plvl then return true end
    return false
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

local function WantQuest(questID, apiFlag)
    if ns.IsSecret(apiFlag) then return false end
    if ns.db.autoQuestLowLevel then return true end
    return not IsLowLevel(questID, apiFlag)
end

local function CountTable(t)
    return type(t) == "table" and #t or 0
end

-- Debug logging: short chat lines describing each event and decision.
local function Debug(fmt, ...)
    if not ns.db or not ns.db.autoQuestDebug then return end
    local ok, msg = pcall(string.format, fmt, ...)
    ns.Print("|cff888888[quest]|r " .. (ok and msg or tostring(fmt)))
end

local function Str(v)
    if ns.IsSecret(v) then return "<secret>" end
    return tostring(v)
end

local function SkipReason()
    return IsShiftKeyDown() and "shift held" or "option off"
end

-- One debug fragment describing why a quest is (or is not) low level:
-- the API flag, quest level, player level, grey threshold and the verdict.
local function LevelInfo(questID, apiFlag)
    if apiFlag == nil then apiFlag = ApiTrivial(questID) end
    local qlvl, plvl = QuestLevel(questID), PlayerLevel()
    local range = TrivialRange(plvl)
    local greyAt = (plvl and range) and (plvl - range) or nil
    return ("trivial=%s qlvl=%s plvl=%s grey<=%s low=%s"):format(
        Str(apiFlag), Str(qlvl), Str(plvl), Str(greyAt), Str(IsLowLevel(questID, apiFlag)))
end

-- When a list window (greeting or gossip) re-opens within a whisker of our
-- last accept / reward call, the client can still be tearing down the
-- previous quest frame and a select issued right now can be dropped. In that
-- case the list handler is re-run once, 0.2 s later, instead of acting now.
local RETRY_WINDOW = 0.1
local RETRY_DELAY  = 0.2
local lastActionAt = 0

local function NoteAction()
    lastActionAt = GetTime()
end

-- Returns true if the handler was deferred (caller should return).
local function DeferIfMidTransition(name, handler, isStillShown)
    if (GetTime() - lastActionAt) >= RETRY_WINDOW then return false end
    lastActionAt = 0   -- one retry only
    Debug("%s arrived mid-transition; retrying in %.1fs", name, RETRY_DELAY)
    C_Timer.After(RETRY_DELAY, function()
        if not ns.db then return end
        if isStillShown and not isStillShown() then Debug("%s retry: window gone", name) return end
        Debug("%s retry", name)
        xpcall(handler, function(err) ns.Print("AutoQuest error: " .. tostring(err)) end)
    end)
    return true
end

local function GreetingStillShown()
    return QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown() or false
end

local function GossipStillShown()
    return GossipFrame and GossipFrame:IsShown() or false
end

-------------------------------------------------------------------------------
-- Quest accepting
-------------------------------------------------------------------------------

-- QUEST_DETAIL: the "Accept / Decline" window for a single quest. This is
-- also how chained follow-ups arrive right after a hand-in.
local function OnQuestDetail()
    local questID = GetQuestID()
    local autoAccept = QuestGetAutoAccept()
    Debug("QUEST_DETAIL quest %s %s autoAccept=%s onQuest=%s %s",
        Str(questID), Str(GetTitleText and GetTitleText() or nil), Str(autoAccept), Str(IsOnQuest(questID)), LevelInfo(questID))
    if not Enabled("autoQuest") then Debug("skipped: %s", SkipReason()) return end

    if autoAccept then
        -- Auto-accept quests (area triggers etc.) are already in the log;
        -- the window only needs dismissing.
        Debug("acknowledging auto-accept quest")
        AcknowledgeAutoAcceptQuest()
        return
    end

    if ns.IsSecret(questID) then Debug("skipped: secret quest id") return end
    if IsOnQuest(questID) then Debug("skipped: already on quest") return end
    if not WantQuest(questID, ApiTrivial(questID)) then Debug("skipped: low level") return end
    Debug("accepting")
    NoteAction()
    AcceptQuest()
end

-- QUEST_GREETING available-quest half. Pick the first eligible available
-- quest; the greeting fires again for the next one once that quest is dealt
-- with. Returns true if it selected something.
local function AcceptGreetingQuest()
    local n = GetNumAvailableQuests()
    Debug("greeting: %s available", Str(n))
    if ns.IsSecret(n) or not n then return false end
    -- GetAvailableQuestInfo(i) -> isTrivial, frequency, isRepeatable,
    -- isLegendary, questID, ... (Blizzard QuestFrame.lua)
    for i = 1, n do
        local isTrivial, _, _, _, questID = GetAvailableQuestInfo(i)
        Debug("  available %d: quest %s %s %s", i, Str(questID), Str(GetAvailableTitle(i)), LevelInfo(questID, isTrivial))
    end
    if not Enabled("autoQuest") then Debug("skipped: %s", SkipReason()) return false end
    for i = 1, n do
        local isTrivial, _, _, _, questID = GetAvailableQuestInfo(i)
        if WantQuest(questID, isTrivial) then
            Debug("selecting available quest %d", i)
            SelectAvailableQuest(i)
            return true
        end
    end
    if n > 0 then Debug("skipped: all available quests low level") end
    return false
end

-- GOSSIP_SHOW available-quest half. Returns true if it picked a quest.
local function AcceptGossipQuest()
    local quests = C_GossipInfo.GetAvailableQuests()
    Debug("gossip: %d available", CountTable(quests))
    if type(quests) ~= "table" then return false end
    for i, q in ipairs(quests) do
        Debug("  available %d: quest %s %s %s", i, Str(q.questID), Str(q.title), LevelInfo(q.questID, q.isTrivial))
    end
    if not Enabled("autoQuest") then Debug("skipped: %s", SkipReason()) return false end
    for _, q in ipairs(quests) do
        if q.questID and not ns.IsSecret(q.questID) then
            if WantQuest(q.questID, q.isTrivial) then
                Debug("selecting available quest %s", Str(q.questID))
                C_GossipInfo.SelectAvailableQuest(q.questID)
                return true
            end
        end
    end
    if #quests > 0 then Debug("skipped: all available quests low level") end
    return false
end

-------------------------------------------------------------------------------
-- Quest hand-ins
-------------------------------------------------------------------------------

-- QUEST_PROGRESS: the "Continue" window listing required items. Only move on
-- when the server says the quest can actually be completed.
local function OnQuestProgress()
    local completable = IsQuestCompletable()
    Debug("QUEST_PROGRESS quest %s completable=%s", Str(GetQuestID()), Str(completable))
    if not TurnInEnabled() then Debug("skipped: hand-ins off or shift held") return end
    if ns.IsSecret(completable) or not completable then Debug("skipped: not completable") return end
    Debug("completing")
    CompleteQuest()
end

-- QUEST_COMPLETE: the reward window. Blizzard's own Complete button calls
-- GetQuestReward(itemChoice) where itemChoice is 0 when there is nothing to
-- choose. With exactly one choice the answer is obvious; with several the
-- window is left open for the player to decide.
local function OnQuestComplete()
    local n = GetNumQuestChoices()
    Debug("QUEST_COMPLETE quest %s choices=%s", Str(GetQuestID()), Str(n))
    if not TurnInEnabled() then Debug("skipped: hand-ins off or shift held") return end
    if ns.IsSecret(n) or not n then return end
    if n == 0 then
        Debug("taking reward")
        NoteAction()
        GetQuestReward(0)
    elseif n == 1 then
        Debug("taking the only reward choice")
        NoteAction()
        GetQuestReward(1)
    else
        Debug("left open: %d reward choices", n)
    end
end

-- QUEST_GREETING active-quest half: select the first quest that is ready to
-- hand in. Returns true if it selected something.
local function TurnInGreetingQuest()
    local n = GetNumActiveQuests()
    Debug("greeting: %s active", Str(n))
    if ns.IsSecret(n) or not n then return false end
    for i = 1, n do
        local questID = GetActiveQuestID(i)
        Debug("  active %d: quest %s %s complete=%s", i, Str(questID), Str(GetActiveTitle(i)), Str(IsQuestComplete(questID)))
    end
    if not TurnInEnabled() then return false end
    for i = 1, n do
        local questID = GetActiveQuestID(i)
        if IsQuestComplete(questID) then
            Debug("selecting active quest %d for hand-in", i)
            SelectActiveQuest(i)
            return true
        end
    end
    return false
end

-- GOSSIP_SHOW active-quest half. Returns true if it selected something.
local function TurnInGossipQuest()
    local quests = C_GossipInfo.GetActiveQuests()
    Debug("gossip: %d active", CountTable(quests))
    if type(quests) ~= "table" then return false end
    for i, q in ipairs(quests) do
        Debug("  active %d: quest %s %s complete=%s", i, Str(q.questID), Str(q.title), Str(q.isComplete))
    end
    if not TurnInEnabled() then return false end
    for _, q in ipairs(quests) do
        if q.questID and not ns.IsSecret(q.questID) then
            local complete = q.isComplete
            if complete == nil then complete = IsQuestComplete(q.questID) end
            if not ns.IsSecret(complete) and complete then
                Debug("selecting active quest %s for hand-in", Str(q.questID))
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
    local options = C_GossipInfo.GetOptions()
    Debug("gossip: %d options", CountTable(options))
    if type(options) == "table" then
        for i, o in ipairs(options) do
            Debug("  option %d: %s (id %s, order %s)", i, Str(o.name), Str(o.gossipOptionID), Str(o.orderIndex))
        end
    end
    if not Enabled("autoGossip") then Debug("gossip skipped: %s", SkipReason()) return false end

    local active = C_GossipInfo.GetNumActiveQuests()
    if ns.IsSecret(active) or (active or 0) > 0 then Debug("gossip skipped: active quests present") return false end

    local available = C_GossipInfo.GetNumAvailableQuests()
    if ns.IsSecret(available) or (available or 0) > 0 then Debug("gossip skipped: available quests present") return false end

    if CountTable(options) ~= 1 then Debug("nothing to do") return false end

    local opt = options[1]
    if not opt then return false end
    if opt.orderIndex and not ns.IsSecret(opt.orderIndex) and C_GossipInfo.SelectOptionByIndex then
        Debug("selecting the only gossip option (order %s)", Str(opt.orderIndex))
        C_GossipInfo.SelectOptionByIndex(opt.orderIndex)
        return true
    end
    local id = opt.gossipOptionID
    if not id or ns.IsSecret(id) then return false end
    Debug("selecting the only gossip option (id %s)", Str(id))
    C_GossipInfo.SelectOption(id)
    return true
end

-------------------------------------------------------------------------------
-- Window handlers: hand-ins first, then pick-ups, then gossip
-------------------------------------------------------------------------------

local function HandleGreeting()
    if TurnInGreetingQuest() then return end
    if AcceptGreetingQuest() then return end
    Debug("nothing to do")
end

local function HandleGossip()
    if TurnInGossipQuest() then return end
    if AcceptGossipQuest() then return end
    SelectOnlyGossipOption()
end

local function OnQuestGreeting()
    Debug("QUEST_GREETING")
    if DeferIfMidTransition("QUEST_GREETING", HandleGreeting, GreetingStillShown) then return end
    HandleGreeting()
end

local function OnGossipShow()
    Debug("GOSSIP_SHOW")
    if DeferIfMidTransition("GOSSIP_SHOW", HandleGossip, GossipStillShown) then return end
    HandleGossip()
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
        { key = "autoQuest", label = "Accept quests", default = true,
          tooltip = "Accept quests from quest givers automatically. Grey quests are skipped unless you include them below." },
        { key = "autoQuestLowLevel", label = "Include low-level quests", default = false, parent = "autoQuest",
          tooltip = "Also accept quests that are grey for your level." },
        { key = "autoQuestSkipBelowLevel", label = "Also skip quests below my level", default = false, parent = "autoQuest",
          tooltip = "Skip green quests too, not just grey ones. Does nothing while low-level quests are included." },
        { key = "autoQuestTurnIn", label = "Complete quest hand-ins", default = true, parent = "autoQuest",
          tooltip = "Hand in finished quests and pick up any follow-up. When there is a choice of rewards, the window stays open for you to pick." },
        { key = "autoGossip", label = "Pick the only gossip option", default = true,
          tooltip = "When an NPC has exactly one gossip option and no quests, choose it for you. Menus with several options are left alone." },
        { key = "autoQuestDebug", label = "Debug log to chat", default = false, parent = "autoQuest",
          tooltip = "Print every quest event and decision to chat. Same as /mm questdebug." },
    },
    commands = {
        questdebug = function()
            ns.db.autoQuestDebug = not ns.db.autoQuestDebug
            ns.Print("Quest debug logging " .. (ns.db.autoQuestDebug and "|cff00ff00on|r" or "|cffff0000off|r"))
        end,
    },
})
