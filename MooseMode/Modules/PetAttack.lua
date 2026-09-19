-------------------------------------------------------------------------------
-- MooseMode -- PetAttack
--
-- Makes the pet charge the target the moment a damage spell starts casting.
--
-- Why macros: PetAttack(), PetAssistMode() and every other pet command are
-- protected on this client, so an addon cannot send the pet in from an
-- event handler. A macro can, because the keypress that runs it is the
-- hardware event the game requires. This module writes one macro per harmful
-- spell in the spellbook:
--
--     #showtooltip
--     /petattack [@target,harm,nodead]
--     /cast <Spell>
--
-- Drag the macros onto your bars in place of the spells.
--
-- Options (account-wide):
--   petAttackMacros           Pet-attack macros for damage spells
--   petAttackOnlyPetClasses   Only on pet classes (sub-option)
--
-- Commands:
--   /mm petmacros             build or refresh every macro now
--   /mm petmacro <Spell>      build or refresh one macro by spell name
-------------------------------------------------------------------------------

local ADDON, ns = ...

local MACRO_ICON      = "INV_MISC_QUESTIONMARK"
local MACRO_NAME_MAX  = 16
local OURS_PREFIX     = "#showtooltip\n/petattack"
local PET_CLASSES     = { HUNTER = true, WARLOCK = true }

local pending = false   -- generator requested during combat

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function MacroName(spellName)
    if #spellName > MACRO_NAME_MAX then
        return spellName:sub(1, MACRO_NAME_MAX), true
    end
    return spellName, false
end

local function MacroBody(spellName)
    return "#showtooltip\n/petattack [@target,harm,nodead]\n/cast " .. spellName
end

local function IsPetClass()
    local _, class = UnitClass("player")
    return class and PET_CLASSES[class] or false
end

local function MaxCharacterMacros()
    return MAX_CHARACTER_MACROS or 18
end

local function MaxAccountMacros()
    return MAX_ACCOUNT_MACROS or 120
end

-- Harmful, active, non-passive player spells from the spellbook, deduped by
-- name (Vanilla ranks are separate entries; "/cast Name" casts the top rank).
local function CollectHarmfulSpells()
    local names, seen = {}, {}
    if not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then return names end

    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1

    local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for line = 1, lines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info and info.numSpellBookItems and info.itemIndexOffset then
            for i = 1, info.numSpellBookItems do
                local index = info.itemIndexOffset + i
                local item = C_SpellBook.GetSpellBookItemInfo(index, bank)
                if item and item.itemType == spellType and item.spellID and item.name
                   and not item.isPassive and not item.isOffSpec then
                    local harmful = false
                    if C_Spell and C_Spell.IsSpellHarmful then
                        harmful = C_Spell.IsSpellHarmful(item.spellID)
                    elseif C_SpellBook.IsSpellBookItemHarmful then
                        harmful = C_SpellBook.IsSpellBookItemHarmful(index, bank)
                    end
                    if harmful and not ns.IsSecret(harmful) and not seen[item.name] then
                        seen[item.name] = true
                        names[#names + 1] = item.name
                    end
                end
            end
        end
    end
    table.sort(names)
    return names
end

-- Writes one macro. Returns "created", "updated", "skipped" or "full".
local function WriteMacro(spellName)
    local name, truncated = MacroName(spellName)
    local body = MacroBody(spellName)

    local index = GetMacroIndexByName(name) or 0
    if index > 0 then
        local existing = GetMacroBody(index) or ""
        if existing == body then
            return "updated", truncated, true    -- already current
        end
        if existing:sub(1, #OURS_PREFIX) ~= OURS_PREFIX then
            return "skipped", truncated
        end
        EditMacro(index, name, MACRO_ICON, body)
        return "updated", truncated
    end

    local accountCount, charCount = GetNumMacros()
    accountCount, charCount = accountCount or 0, charCount or 0
    if charCount < MaxCharacterMacros() then
        CreateMacro(name, MACRO_ICON, body, true)
        return "created", truncated
    elseif accountCount < MaxAccountMacros() then
        CreateMacro(name, MACRO_ICON, body, false)
        return "created", truncated
    end
    return "full", truncated
end

-------------------------------------------------------------------------------
-- Generator
-------------------------------------------------------------------------------

local function Generate(force)
    local db = ns.db
    if not db then return end
    if not force and not db.petAttackMacros then return end
    if not force and db.petAttackOnlyPetClasses and not IsPetClass() then
        return
    end
    if InCombatLockdown() then
        pending = true
        ns.Print("Pet-attack macros will be built after combat.")
        return
    end
    if not CreateMacro or not EditMacro or not GetMacroIndexByName then
        ns.Print("Macro functions are not available on this client.")
        return
    end

    local spells = CollectHarmfulSpells()
    if #spells == 0 then
        ns.Print("No damage spells found in your spellbook.")
        return
    end

    local created, updated, unchanged, skipped, full, truncated = 0, 0, 0, 0, 0, {}
    local skippedNames = {}
    for _, spellName in ipairs(spells) do
        local result, wasTruncated, same = WriteMacro(spellName)
        if wasTruncated then truncated[#truncated + 1] = spellName end
        if result == "created" then created = created + 1
        elseif result == "updated" then
            if same then unchanged = unchanged + 1 else updated = updated + 1 end
        elseif result == "skipped" then
            skipped = skipped + 1
            skippedNames[#skippedNames + 1] = spellName
        elseif result == "full" then full = full + 1 end
    end

    local parts = { ("Pet-attack macros: %d created, %d updated, %d unchanged"):format(created, updated, unchanged) }
    if skipped > 0 then parts[#parts + 1] = ("%d skipped"):format(skipped) end
    if full > 0 then parts[#parts + 1] = ("%d not made (no free macro slots)"):format(full) end
    ns.Print(table.concat(parts, ", ") .. ".")
    if #skippedNames > 0 then
        ns.Print("Skipped, you already have a macro with that name: " .. table.concat(skippedNames, ", "))
    end
    if #truncated > 0 then
        ns.Print("Name shortened to 16 characters: " .. table.concat(truncated, ", "))
    end
    if created + updated > 0 then
        ns.Print("Open the macro window and drag them onto your bars in place of the spells.")
    end
end

local function GenerateOne(spellName)
    spellName = (spellName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if spellName == "" then
        ns.Print("Usage: /mm petmacro <Spell Name>")
        return
    end
    if InCombatLockdown() then
        ns.Print("Cannot edit macros in combat.")
        return
    end
    local result, wasTruncated, same = WriteMacro(spellName)
    local name = MacroName(spellName)
    if result == "created" then
        ns.Print(("Created macro %s."):format(name))
    elseif result == "updated" then
        ns.Print(same and ("Macro %s is already up to date."):format(name)
                       or ("Updated macro %s."):format(name))
    elseif result == "skipped" then
        ns.Print(("Skipped: you already have a macro called %s that MooseMode did not make."):format(name))
    else
        ns.Print("No free macro slots.")
    end
    if wasTruncated then ns.Print("Name shortened to 16 characters.") end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" and pending then
        pending = false
        Generate(false)
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "petAttackModule",
    label = "Pet Attack",
    group = "Combat",
    options = {
        { key = "petAttackMacros", label = "Pet-attack macros for damage spells", default = false,
          tooltip = "Create a macro for each of your damage spells that sends your pet at the target before casting. Drag them onto your bars in place of the spells. Turning this off leaves the macros in place; delete them from the macro window if you no longer want them.",
          onChange = function(checked)
              if checked then Generate(false) end
          end },
        { key = "petAttackOnlyPetClasses", label = "Only on pet classes", default = true, parent = "petAttackMacros",
          tooltip = "Only build the macros on Hunters and Warlocks." },
        { type = "note", text = "Creates one macro per damage spell with /petattack in front, so your pet charges the moment you cast. Drag the macros onto your bars in place of the spells. Re-run after learning new spells." },
    },
    commands = {
        petmacros = function() Generate(true) end,
        petmacro  = function(rest) GenerateOne(rest) end,
    },
})
