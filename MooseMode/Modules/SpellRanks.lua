-------------------------------------------------------------------------------
-- MooseMode -- SpellRanks
--
-- Keeps action bar spell buttons on the highest rank you know. Forever has
-- Vanilla-style spell ranks on the Retail client: learning Demon Armor rank 3
-- does not change the button that still holds rank 2. This module swaps such
-- buttons for the new rank, out of combat.
--
-- Name-based macros ("/cast Demon Armor") already cast the top rank; this
-- covers plain spell buttons dragged from the spellbook.
--
-- Options (account-wide):
--   spellRanksUpgrade   Keep bars on highest spell rank
--   spellRanksReport    Report swaps in chat (sub-option)
--
-- Commands:
--   /mm ranks           scan and upgrade now, with a summary
-------------------------------------------------------------------------------

local ADDON, ns = ...

local DEBOUNCE      = 1.0    -- seconds after SPELLS_CHANGED before scanning
local LOGIN_DELAY   = 3.0    -- seconds after PLAYER_LOGIN before the first scan
local CURSOR_RETRY  = 2.0    -- seconds to wait when the cursor is busy

local pendingCombat = false  -- scan requested during combat
local pendingForce  = false
local scanTimer                -- debounce / retry timer
local placeBroken   = false  -- PlaceAction threw once; never try again this session

-------------------------------------------------------------------------------
-- Spell lookups
-------------------------------------------------------------------------------

local function NumActionSlots()
    return NUM_ACTIONBAR_SLOTS or 180
end

local function SpellName(spellID)
    if not spellID then return nil end
    if C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellID)
        if name and not ns.IsSecret(name) then return name end
    end
    local info = C_Spell.GetSpellInfo(spellID)
    local name = info and info.name
    if ns.IsSecret(name) then return nil end
    return name
end

local function RankNumber(spellID)
    if not spellID then return 0 end
    if C_Spell.GetSpellSkillLineAbilityRank then
        local ok, rank = pcall(C_Spell.GetSpellSkillLineAbilityRank, spellID)
        if ok and type(rank) == "number" and not ns.IsSecret(rank) and rank > 0 then
            return rank
        end
    end
    local sub = C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID)
    if sub and not ns.IsSecret(sub) then
        local n = tonumber(sub:match("(%d+)"))
        if n then return n end
    end
    return 0
end

local function IsKnown(spellID)
    if not spellID then return false end
    local known
    if IsSpellKnownOrOverridesKnown then
        known = IsSpellKnownOrOverridesKnown(spellID)
    elseif IsPlayerSpell then
        known = IsPlayerSpell(spellID)
    elseif IsSpellKnown then
        known = IsSpellKnown(spellID)
    end
    if ns.IsSecret(known) then return false end
    return known and true or false
end

-- Scans the player spellbook for every entry named `name` and returns the
-- spellID with the highest rank. Used when the by-name lookup is inconclusive.
local function HighestRankFromSpellbook(name)
    if not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then return nil end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1

    local bestID, bestRank = nil, -1
    local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for line = 1, lines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info and info.numSpellBookItems and info.itemIndexOffset then
            for i = 1, info.numSpellBookItems do
                local index = info.itemIndexOffset + i
                local item = C_SpellBook.GetSpellBookItemInfo(index, bank)
                if item and item.itemType == spellType and item.spellID and item.name == name
                   and not item.isOffSpec then
                    local lowRank = false
                    if C_SpellBook.IsSpellBookItemLowRank then
                        local ok, low = pcall(C_SpellBook.IsSpellBookItemLowRank, index, bank)
                        lowRank = ok and low and not ns.IsSecret(low) or false
                    end
                    local rank = RankNumber(item.spellID)
                    if not lowRank and rank >= bestRank then
                        bestID, bestRank = item.spellID, rank
                    elseif bestID == nil then
                        bestID, bestRank = item.spellID, rank
                    end
                end
            end
        end
    end
    return bestID
end

-- Returns the spellID the client would cast for "/cast <name>", i.e. the
-- highest known rank, or nil if it cannot be determined.
local function HighestRank(name, currentID)
    local best
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID and not ns.IsSecret(info.spellID) then
        best = info.spellID
    end
    -- The by-name lookup may hand back the same rank the button already holds
    -- (or nothing). Cross-check with the spellbook before trusting it.
    if not best or best == currentID or RankNumber(best) < RankNumber(currentID) then
        local fromBook = HighestRankFromSpellbook(name)
        if fromBook and RankNumber(fromBook) > RankNumber(best or currentID) then
            best = fromBook
        end
    end
    if best and best ~= currentID and SpellName(best) == name and IsKnown(best)
       and RankNumber(best) > RankNumber(currentID) then
        return best
    end
    return nil
end

-------------------------------------------------------------------------------
-- Swapping
-------------------------------------------------------------------------------

-- Places `spellID` into action `slot`. Returns true on success.
local function PlaceSpell(slot, spellID)
    ClearCursor()
    local okPick = pcall(C_Spell.PickupSpell, spellID)
    if not okPick then
        pcall(PickupSpell, spellID)
    end
    local kind = GetCursorInfo()
    if kind ~= "spell" then
        ClearCursor()
        return false
    end
    local ok, err = pcall(PlaceAction, slot)
    ClearCursor()
    if not ok then
        placeBroken = true
        ns.Print("Spell Ranks: the client refused to place a spell on the bar (" .. tostring(err) .. "). Stopping for this session.")
        return false
    end
    return true
end

local function Scan(force)
    local db = ns.db
    if not db then return end
    if not force and not db.spellRanksUpgrade then return end
    if placeBroken then
        if force then ns.Print("Spell Ranks: disabled for this session after a placement error.") end
        return
    end
    if InCombatLockdown() then
        pendingCombat = true
        pendingForce = pendingForce or force
        if force then ns.Print("Spell Ranks: will scan after combat.") end
        return
    end
    if GetCursorInfo() then
        -- The player is dragging something; try again shortly.
        if scanTimer then scanTimer:Cancel() end
        scanTimer = C_Timer.NewTimer(CURSOR_RETRY, function() scanTimer = nil; Scan(force) end)
        return
    end

    local report = force or db.spellRanksReport
    local swaps = {}        -- name -> { rank = n, count = c }
    local order = {}
    local swapped, scanned = 0, 0

    for slot = 1, NumActionSlots() do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id and not ns.IsSecret(id) then
            scanned = scanned + 1
            local name = SpellName(id)
            if name then
                local newID = HighestRank(name, id)
                if newID then
                    if PlaceSpell(slot, newID) then
                        swapped = swapped + 1
                        local entry = swaps[name]
                        if not entry then
                            entry = { rank = RankNumber(newID), count = 0 }
                            swaps[name] = entry
                            order[#order + 1] = name
                        end
                        entry.count = entry.count + 1
                    elseif placeBroken then
                        break
                    end
                end
            end
        end
    end

    if report then
        for _, name in ipairs(order) do
            local e = swaps[name]
            local rankText = e.rank > 0 and ("Rank %d"):format(e.rank) or "highest rank"
            ns.Print(("Spell Ranks: %s → %s (%d button%s)"):format(name, rankText, e.count, e.count == 1 and "" or "s"))
        end
    end
    if force then
        if swapped == 0 then
            ns.Print(("Spell Ranks: %d spell button%s checked, all on the highest rank."):format(scanned, scanned == 1 and "" or "s"))
        else
            ns.Print(("Spell Ranks: %d button%s upgraded."):format(swapped, swapped == 1 and "" or "s"))
        end
    end
end

local function ScheduleScan(delay, force)
    if scanTimer then scanTimer:Cancel() end
    scanTimer = C_Timer.NewTimer(delay, function()
        scanTimer = nil
        Scan(force)
    end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
-- Event names differ between client lines: LEARNED_SPELL_IN_TAB was renamed
-- LEARNED_SPELL_IN_SKILL_LINE in the Retail line that Forever runs. Register
-- whichever exist; SPELLS_CHANGED alone is enough to catch new ranks.
local function SafeRegister(f, event)
    return pcall(f.RegisterEvent, f, event)
end
SafeRegister(frame, "PLAYER_LOGIN")
SafeRegister(frame, "LEARNED_SPELL_IN_SKILL_LINE")
SafeRegister(frame, "LEARNED_SPELL_IN_TAB")
SafeRegister(frame, "SPELLS_CHANGED")
SafeRegister(frame, "PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if not ns.db then return end
    if event == "PLAYER_LOGIN" then
        ScheduleScan(LOGIN_DELAY, false)
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
        if ns.db.spellRanksUpgrade then ScheduleScan(DEBOUNCE, false) end
    elseif event == "PLAYER_REGEN_ENABLED" and pendingCombat then
        pendingCombat = false
        local force = pendingForce
        pendingForce = false
        ScheduleScan(0.5, force)
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "spellRanksModule",
    label = "Spell Ranks",
    group = "Combat",
    options = {
        { key = "spellRanksUpgrade", label = "Keep bars on highest spell rank", default = true,
          tooltip = "When you learn a new rank, buttons holding the old rank are swapped for the new one. Runs out of combat.",
          onChange = function(checked)
              if checked then ScheduleScan(0.2, false) end
          end },
        { key = "spellRanksReport", label = "Report swaps in chat", default = true, parent = "spellRanksUpgrade",
          tooltip = "Print a line for each spell that was moved to a higher rank." },
    },
    commands = {
        ranks = function() Scan(true) end,
    },
})
