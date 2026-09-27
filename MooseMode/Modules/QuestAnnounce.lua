-------------------------------------------------------------------------------
-- MooseMode -- QuestAnnounce
--
-- Questie-style quest announcements to group chat (Questie's
-- Modules/QuestieAnnounce.lua is the model):
--
--   * Objective finished: "8/8 Boar Flank for [Crown of the Earth]!"
--     Only for an objective seen incomplete earlier this session, so the
--     ones already done at login stay quiet.
--   * Quest-starting item looted: "Picked up [Item] which starts [Quest]!"
--     There is no quest database here; the bags are scanned with
--     C_Container.GetContainerItemQuestInfo, whose questID is set for an
--     item that begins a quest and isActive tells whether that quest is
--     already in the log. Only items that turn up shortly after a loot
--     event count, so bank or mail moves stay quiet. When the message is
--     not sent to a group it is printed to your own chat instead, as
--     Questie does.
--   * Quest accepted / abandoned / turned in (QUEST_TURNED_IN, not the
--     moment the objectives finish), all off by default.
--
-- Every message sent starts with "{rt3} MooseMode: " (the purple diamond).
-- A chat filter swaps that prefix for the MooseMode icon for anyone running
-- the addon. Identical messages go out once per session.
--
-- Channel: RAID in a raid, INSTANCE_CHAT in an instance group, PARTY
-- otherwise. Nothing is sent solo, in battlegrounds or arenas, or while the
-- client's chat messaging lockdown (C_ChatInfo.InChatMessagingLockdown,
-- 12.x) is on; a blocked message is printed locally instead.
--
-- Options (account-wide):
--   questAnnounce             master switch
--   questAnnounceChannel      "party" | "raid" | "both" | "disabled"
--   questAnnounceObjectives   finished objectives              (on)
--   questAnnounceItems        quest-starting items             (on)
--   questAnnounceAccepted     quest accepted                   (off)
--   questAnnounceAbandoned    quest abandoned                  (off)
--   questAnnounceCompleted    quest turned in                  (off)
--   questAnnounceLocal        also print each message locally  (off)
--
-- /mm announcetest prints sample messages locally.
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local PREFIX       = "{rt3} MooseMode: "
local PREFIX_MATCH = "{rt3} MooseMode%s?:%s?"
local ICON_TEX     = "Interface\\AddOns\\" .. ADDON .. "\\media\\icon.tga"
local ICON_TAG     = "|T" .. ICON_TEX .. ":0|t "
local DIAMOND_TAG  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t "
local SCAN_DELAY   = 0.3    -- coalesce quest-log bursts
local BAG_DELAY    = 0.2
local LOOT_WINDOW  = 10     -- seconds after a loot event a new starter item counts

local frame = CreateFrame("Frame")
local SafeRegister = ns.SafeRegisterEvent

local sent          = {}    -- [message] = true, once per session
local seenIncomplete = {}   -- ["questID:index"] = true
local announcedObj  = {}    -- ["questID:index"] = true
local titles        = {}    -- [questID] = title, for quests that left the log
local knownStarters = {}    -- [questID] = true for starter items seen in bags
local bagBaseline   = false
local lastLoot      = 0
local scanQueued, bagQueued = false, false
local abandonID

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Opt(key)
    return ns.db and ns.db.questAnnounce and ns.db[key] and true or false
end

local function Now()
    return (GetTime and GetTime()) or 0
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

local function Usable(v)
    return v ~= nil and not ns.IsSecret(v)
end

local function QuestTitle(questID)
    local t = C_QuestLog and Call(C_QuestLog.GetTitleForQuestID, questID)
    if type(t) == "string" and Usable(t) and t ~= "" then
        titles[questID] = t
        return t
    end
    return titles[questID]
end

-- A clickable quest link where the client builds one, else "[Title]".
local function QuestLink(questID)
    if not questID then return nil end
    local link = C_QuestLog and Call(C_QuestLog.GetQuestLink, questID)
    if not (type(link) == "string" and Usable(link) and link ~= "") then
        link = Call(GetQuestLink, questID)
    end
    if type(link) == "string" and Usable(link) and link ~= "" then return link end
    local title = QuestTitle(questID)
    return title and ("[" .. title .. "]") or nil
end

local function InPvPInstance()
    local _, kind = Call(IsInInstance)
    return kind == "pvp" or kind == "arena"
end

local function InstanceGroup()
    if not LE_PARTY_CATEGORY_INSTANCE then return false end
    return Call(IsInGroup, LE_PARTY_CATEGORY_INSTANCE) and true or false
end

-- The channel to use, or nil when the setting and group say not to send.
local function GroupChannel()
    local choice = ns.db and ns.db.questAnnounceChannel or "party"
    local raid  = Call(IsInRaid) and true or false
    local group = Call(IsInGroup) and true or false
    if not group then return nil end
    if choice == "party" and raid then return nil end
    if choice == "raid" and not raid then return nil end
    if choice ~= "party" and choice ~= "raid" and choice ~= "both" then return nil end
    if InPvPInstance() then return nil end
    if raid then return "RAID" end
    if InstanceGroup() then return "INSTANCE_CHAT" end
    return "PARTY"
end

local function ChatLocked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local locked = Call(C_ChatInfo.InChatMessagingLockdown)
        if locked == nil or ns.IsSecret(locked) then return false end
        return locked and true or false
    end
    return false
end

local function Send(text, channel)
    if ChatLocked() then return false end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then return false end
    local ok = pcall(send, PREFIX .. text, channel)
    return ok
end

-- selfNote: printed locally when the message does not reach a group
-- (Questie does this for quest-starting items).
local function Announce(text, selfNote)
    if not text or sent[text] then return end
    sent[text] = true
    local channel = GroupChannel()
    local delivered = channel and Send(text, channel) or false
    if ns.db.questAnnounceLocal then
        ns.Print(text)
    elseif not delivered and (selfNote or channel) then
        -- channel set but blocked (lockdown, error): keep it visible
        ns.Print(selfNote or text)
    end
end

-------------------------------------------------------------------------------
-- Objectives
-------------------------------------------------------------------------------

-- "Boar Flank: 3/8" or "3/8 Boar Flank" -> "Boar Flank"
local function ObjectiveName(text)
    text = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")
    text = text:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    return text
end

local function ScanObjectives()
    scanQueued = false
    if not (ns.db and C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo
            and C_QuestLog.GetQuestObjectives) then return end
    local n = Call(C_QuestLog.GetNumQuestLogEntries)
    if type(n) ~= "number" or ns.IsSecret(n) then return end
    for i = 1, n do
        local info = Call(C_QuestLog.GetInfo, i)
        local questID = type(info) == "table" and info.questID
        if questID and Usable(questID) and not info.isHeader then
            if type(info.title) == "string" and Usable(info.title) then titles[questID] = info.title end
            local objectives = Call(C_QuestLog.GetQuestObjectives, questID)
            if type(objectives) == "table" then
                for idx, o in ipairs(objectives) do
                    local have, need, text = o.numFulfilled, o.numRequired, o.text
                    if type(have) == "number" and type(need) == "number" and Usable(have) and Usable(need)
                            and type(text) == "string" and Usable(text) and need > 0 then
                        local key = questID .. ":" .. idx
                        if have < need then
                            seenIncomplete[key] = true
                        elseif have == need and seenIncomplete[key] and not announcedObj[key] then
                            announcedObj[key] = true
                            seenIncomplete[key] = nil
                            if Opt("questAnnounceObjectives") then
                                local link = QuestLink(questID)
                                if link then
                                    Announce(("%d/%d %s for %s!"):format(have, need, ObjectiveName(text), link))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function QueueScan()
    if scanQueued then return end
    scanQueued = true
    if C_Timer and C_Timer.After then C_Timer.After(SCAN_DELAY, ScanObjectives) else ScanObjectives() end
end

-------------------------------------------------------------------------------
-- Quest-starting items
-------------------------------------------------------------------------------

local function ScanBags()
    bagQueued = false
    if not (ns.db and C_Container and C_Container.GetContainerItemQuestInfo
            and C_Container.GetContainerNumSlots) then return end
    local recent = (Now() - lastLoot) <= LOOT_WINDOW
    for bag = 0, ns.NumBags() do
        local slots = Call(C_Container.GetContainerNumSlots, bag) or 0
        if ns.IsSecret(slots) then return end
        for slot = 1, slots do
            local q = Call(C_Container.GetContainerItemQuestInfo, bag, slot)
            local questID = type(q) == "table" and q.questID
            if questID and Usable(questID) and questID > 0 and not knownStarters[questID] then
                knownStarters[questID] = true
                if bagBaseline and recent and not q.isActive and Opt("questAnnounceItems") then
                    local item = Call(C_Container.GetContainerItemLink, bag, slot)
                    if not (type(item) == "string" and Usable(item)) then item = nil end
                    local quest = QuestLink(questID)
                    if item and quest then
                        Announce(("Picked up %s which starts %s!"):format(item, quest),
                                 ("You picked up %s which starts %s!"):format(item, quest))
                    elseif item and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
                        -- Quest data not cached yet: ask for it and try once more.
                        knownStarters[questID] = nil
                        Call(C_QuestLog.RequestLoadQuestByID, questID)
                        if C_Timer and C_Timer.After then C_Timer.After(1, ScanBags) end
                    end
                end
            end
        end
    end
    bagBaseline = true
end

local function QueueBags()
    if bagQueued then return end
    bagQueued = true
    if C_Timer and C_Timer.After then C_Timer.After(BAG_DELAY, ScanBags) else ScanBags() end
end

-------------------------------------------------------------------------------
-- Accept / abandon / turn in
-------------------------------------------------------------------------------

local function QuestEvent(label, key, questID)
    if not (questID and Usable(questID) and Opt(key)) then return end
    local link = QuestLink(questID)
    if link then Announce(("Quest %s: %s"):format(label, link)) end
end

local function HookAbandon()
    if not (C_QuestLog and hooksecurefunc) then return end
    if C_QuestLog.SetAbandonQuest and C_QuestLog.GetAbandonQuest then
        pcall(hooksecurefunc, C_QuestLog, "SetAbandonQuest", function()
            local id = Call(C_QuestLog.GetAbandonQuest)
            if id and Usable(id) and id > 0 then
                abandonID = id
                QuestTitle(id)   -- cache while the quest is still in the log
            end
        end)
    end
    if C_QuestLog.AbandonQuest then
        pcall(hooksecurefunc, C_QuestLog, "AbandonQuest", function()
            local id = abandonID or Call(C_QuestLog.GetAbandonQuest)
            abandonID = nil
            if id and Usable(id) and id > 0 then QuestEvent("Abandoned", "questAnnounceAbandoned", id) end
        end)
    end
end

-------------------------------------------------------------------------------
-- Logo filter: "{rt3} MooseMode: " -> MooseMode icon for anyone running it
-------------------------------------------------------------------------------

local function LogoFilter(self, event, msg, author, ...)
    if type(msg) ~= "string" or ns.IsSecret(msg) then return false end
    if not msg:find(PREFIX_MATCH) then return false end
    return false, (msg:gsub(PREFIX_MATCH, ICON_TAG, 1)), author, ...
end

local function InstallFilter(attempt)
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if type(add) ~= "function" then return end
    local ok = true
    for _, ev in ipairs({ "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
                          "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
        if not pcall(add, ev, LogoFilter) then ok = false; break end
    end
    -- The chat frame utilities can be unready this early; retry briefly.
    if not ok and (attempt or 0) < 5 and C_Timer and C_Timer.After then
        C_Timer.After(0.5, function() InstallFilter((attempt or 0) + 1) end)
    end
end

-------------------------------------------------------------------------------
-- /mm announcetest
-------------------------------------------------------------------------------

local function SampleQuest()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        local n = Call(C_QuestLog.GetNumQuestLogEntries) or 0
        if ns.IsSecret(n) then n = 0 end
        for i = 1, n do
            local info = Call(C_QuestLog.GetInfo, i)
            if type(info) == "table" and not info.isHeader and info.questID and Usable(info.questID) then
                local link = QuestLink(info.questID)
                if link then return link end
            end
        end
    end
    return "[Crown of the Earth]"
end

local function AnnounceTest()
    local quest = SampleQuest()
    local samples = {
        ("8/8 Boar Flank for %s!"):format(quest),
        ("Picked up [Sealed Letter] which starts %s!"):format(quest),
        ("Quest Accepted: %s"):format(quest),
        ("Quest Abandoned: %s"):format(quest),
        ("Quest Completed: %s"):format(quest),
    }
    local channel = GroupChannel()
    ns.Print(("announce test. Group chat now: %s%s."):format(
        channel or "none (not sent)", (channel and ChatLocked()) and ", locked down, printed locally" or ""))
    local out = DEFAULT_CHAT_FRAME or ChatFrame1
    out:AddMessage("As other players see it:")
    out:AddMessage("  " .. DIAMOND_TAG .. "MooseMode: " .. samples[1])
    out:AddMessage("With MooseMode installed:")
    for _, s in ipairs(samples) do out:AddMessage("  " .. ICON_TAG .. s) end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

frame:RegisterEvent("PLAYER_LOGIN")
SafeRegister(frame, "PLAYER_ENTERING_WORLD")
SafeRegister(frame, "QUEST_LOG_UPDATE")
SafeRegister(frame, "UNIT_QUEST_LOG_CHANGED")
SafeRegister(frame, "QUEST_WATCH_UPDATE")
SafeRegister(frame, "QUEST_ACCEPTED")
SafeRegister(frame, "QUEST_TURNED_IN")
SafeRegister(frame, "BAG_UPDATE_DELAYED")
SafeRegister(frame, "CHAT_MSG_LOOT")
SafeRegister(frame, "LOOT_OPENED")
SafeRegister(frame, "LOOT_CLOSED")
frame:SetScript("OnEvent", function(self, event, a, b)
    if event == "PLAYER_LOGIN" then
        InstallFilter(0)
        HookAbandon()
        return
    end
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        QueueScan()
        QueueBags()
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_UPDATE" then
        QueueScan()
    elseif event == "UNIT_QUEST_LOG_CHANGED" then
        if a == "player" then QueueScan() end
    elseif event == "QUEST_ACCEPTED" then
        -- Retail passes (questID); older clients (questLogIndex, questID).
        local questID = b or a
        QueueScan()
        QuestEvent("Accepted", "questAnnounceAccepted", questID)
    elseif event == "QUEST_TURNED_IN" then
        QuestEvent("Completed", "questAnnounceCompleted", a)
    elseif event == "CHAT_MSG_LOOT" or event == "LOOT_OPENED" or event == "LOOT_CLOSED" then
        lastLoot = Now()
        QueueBags()
    elseif event == "BAG_UPDATE_DELAYED" then
        QueueBags()
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "questAnnounceModule",
    label = "Quest Announce",
    group = "Quests",
    summary = "Tells your group about quest progress, Questie-style.",
    icon    = "Interface\\Icons\\INV_Misc_Horn_01",
    options = {
        { key = "questAnnounce", label = "Announce to group", default = true,
          tooltip = "Post quest progress to group chat. Messages start with a purple diamond; group members running MooseMode see the MooseMode icon instead. Each message goes out once per session." },
        { type = "choice", key = "questAnnounceChannel", label = "Send in", default = "party", parent = "questAnnounce",
          values = { { value = "party", text = "Party" }, { value = "raid", text = "Raid" },
                     { value = "both", text = "Both" }, { value = "disabled", text = "Off" } },
          tooltip = "Party: only in a 5-player group. Raid: only in a raid. Both: either. Off: nothing is sent to chat. Instance groups use instance chat; battlegrounds and arenas are never used." },
        { key = "questAnnounceObjectives", label = "Finished objectives", default = true, parent = "questAnnounce",
          tooltip = "\"8/8 Boar Flank for [Crown of the Earth]!\" Only for objectives you finish this session." },
        { key = "questAnnounceItems", label = "Quest-starting items", default = true, parent = "questAnnounce",
          tooltip = "\"Picked up [item] which starts [quest]!\" When you are not grouped, this one is printed to your own chat." },
        { key = "questAnnounceAccepted", label = "Quest accepted", default = false, parent = "questAnnounce",
          tooltip = "\"Quest Accepted: [quest]\"" },
        { key = "questAnnounceAbandoned", label = "Quest abandoned", default = false, parent = "questAnnounce",
          tooltip = "\"Quest Abandoned: [quest]\"" },
        { key = "questAnnounceCompleted", label = "Quest turned in", default = false, parent = "questAnnounce",
          tooltip = "\"Quest Completed: [quest]\", sent when you hand the quest in." },
        { key = "questAnnounceLocal", label = "Also show in my chat", default = false, parent = "questAnnounce",
          tooltip = "Print each announcement to your own chat as well. /mm announcetest shows sample messages." },
    },
    OnInit = function()
        local c = ns.db.questAnnounceChannel
        if c ~= "party" and c ~= "raid" and c ~= "both" and c ~= "disabled" then
            ns.db.questAnnounceChannel = "party"
        end
    end,
    commands = {
        announcetest = function() AnnounceTest() end,
    },
})
