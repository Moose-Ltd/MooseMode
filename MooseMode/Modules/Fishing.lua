-------------------------------------------------------------------------------
-- MooseMode -- Fishing
--
-- One toggle in and out of "fishing mode":
--
--   in   remembers your main hand and off hand, equips the best fishing pole
--        in your bags, remembers what sits on action button 1 and puts the
--        Fishing spell there, and switches on the soft-target interact that
--        lets a key reach the bobber.
--   out  puts the weapons back, puts the old button back, and undoes the key
--        and soft-target changes.
--
-- The toggle is /mm fish, the "MooseFish" macro this module writes (drag it
-- onto a bar), or the button in the settings dialog.
--
-- Catching: the client has no event for the bite, so nothing can catch for
-- you. Press 1 to cast. While the bobber is out the button-1 key is an
-- override binding to "Interact With Target", so pressing 1 again when the
-- bobber splashes loots it; after the cast it casts again. The bobber is
-- reachable through the game's soft-target interact, which this module
-- switches on for the duration. (An earlier ` key option, fishingTilde, is
-- gone: button 1 covers it.)
--
-- Weapon swaps are checked, not assumed: the server drops an equip without a
-- word while an item is locked, a cast is running, the cursor holds
-- something or you are in combat. So the toggle ignores presses while a swap
-- is in flight, waits out those blockers (chat says what it waits on) and
-- retries, and forgets the saved weapons only once they are back in your
-- hands; a swap back that never lands is retried by the next toggle. The
-- direction follows what you hold: with fishing mode off and a pole in hand,
-- the toggle puts the last weapons it saw back on. A fishing pole is never
-- remembered as the weapon to return to.
--
-- State survives /reload and a restart: it is written into ns.db under a
-- per-character key, which Core mirrors into the settings backup, next to
-- the last non-pole weapons seen on the character.
--
-- Options (account-wide):
--   fishingMacro    Keep a MooseFish macro that toggles fishing mode
--   fishingSlot1    Put Fishing on action button 1 while fishing, and let
--                   its key catch while the bobber is out
--
-- Commands:
--   /mm fish        toggle fishing mode
--   /mm fishmacro   write or refresh the MooseFish macro
--   /mm fishdebug   chat trace of what the module sees
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local MACRO_NAME   = "MooseFish"
local MACRO_ICON   = "INV_Fishingpole_02"
local MACRO_BODY   = "/mm fish"
local INTERACT_CMD = "INTERACTTARGET"

local SLOT_MAIN, SLOT_OFF = 16, 17
local CLASS_WEAPON  = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local SUB_FISHPOLE  = (Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole) or 20

-- Fishing spell IDs seen on the Retail line and the Vanilla ranks Forever
-- uses (Apprentice .. Artisan). First known one wins.
local FISHING_SPELLS = { 131474, 7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410 }

-- Soft-target interact CVars, set while fishing so the interact key reaches
-- the bobber.
local SOFT_TARGET_CVARS = {
    { name = "SoftTargetInteract",       value = "3",  dbKey = "fishingPrevSTInteract" },
    { name = "SoftTargetInteractArc",    value = "2",  dbKey = "fishingPrevSTArc" },
    { name = "SoftTargetInteractRange",  value = "45", dbKey = "fishingPrevSTRange" },
    { name = "SoftTargetIconGameObject", value = "1",  dbKey = "fishingPrevSTIcon" },
}

local frame = CreateFrame("Frame", "MooseModeFishingFrame")

-- Timings for re-initialising the soft-target picker (see Reinit).
local REINIT_GAP      = 0.4   -- seconds interact stays off during a re-init
local KICK_DELAY      = 1.0   -- after the cast starts: the bobber has landed

local IsActive   -- forward
local Debug      -- forward

-- The soft-target picker takes its range, arc and icon settings when
-- interact is switched on, and ignores later changes to them until it is
-- switched off and on again. Setting the values while interact was already
-- on is why fishing mode used to work only after a second toggle. Reinit
-- does what that second toggle did: interact and the object icon off, the
-- other values written, then the icon and interact back on, interact last.
local reinitSerial = 0
local function Reinit(reason)
    if not ns.CVar.Exists("SoftTargetInteract") then return end
    reinitSerial = reinitSerial + 1
    local mine = reinitSerial
    ns.CVar.Set("SoftTargetInteract", "0")
    if ns.CVar.Exists("SoftTargetIconGameObject") then ns.CVar.Set("SoftTargetIconGameObject", "0") end
    C_Timer.After(REINIT_GAP, function()
        if mine ~= reinitSerial or not IsActive() then return end
        for i = #SOFT_TARGET_CVARS, 1, -1 do   -- the table lists interact first; write it last
            local c = SOFT_TARGET_CVARS[i]
            if ns.CVar.Exists(c.name) then ns.CVar.Set(c.name, c.value) end
        end
        if Debug then Debug("soft target re-initialised (" .. tostring(reason) .. ")") end
    end)
end

-------------------------------------------------------------------------------
-- State (one string per character in ns.db, so it rides the settings backup)
--
-- lv:1 marks "on the way out": button and keys are already restored and only
-- the weapons are still to go back. That state is not "fishing mode on".
-------------------------------------------------------------------------------

local function CharKey()
    local name = UnitName("player") or "char"
    local realm = GetRealmName and GetRealmName() or ""
    return ((name .. realm):gsub("[^%w]", ""))
end

local function StateKey()   return "fishing_"  .. CharKey() end
local function WeaponsKey() return "fishingW_" .. CharKey() end

local function LoadState()
    local raw = ns.db and ns.db[StateKey()]
    if type(raw) ~= "string" or raw == "" then return nil end
    local st = {}
    for k, v in raw:gmatch("([%w]+):([^|]*)") do st[k] = v end
    st.mh   = tonumber(st.mh)
    st.oh   = tonumber(st.oh)
    st.slot = tonumber(st.slot)
    st.id   = tonumber(st.id) or st.id
    st.leaving = st.lv == "1"
    st.lv = nil
    if st.kind == "" then st.kind = nil end
    if st.name == "" then st.name = nil end
    return st
end

local function SaveState(st)
    if not ns.db then return end
    if not st then
        ns.db[StateKey()] = nil
    else
        local name = (st.name or ""):gsub("[|:]", "")
        ns.db[StateKey()] = ("mh:%s|oh:%s|slot:%s|kind:%s|id:%s|name:%s|lv:%s"):format(
            st.mh or "", st.oh or "", st.slot or "", st.kind or "", st.id or "", name,
            st.leaving and "1" or "")
    end
    ns.SaveSettings()
end

-- Fishing mode on (not merely waiting for the weapons to go back).
IsActive = function()
    local st = LoadState()
    return st ~= nil and not st.leaving
end

-------------------------------------------------------------------------------
-- Lookups
-------------------------------------------------------------------------------

local function IsKnown(spellID)
    local known
    if IsSpellKnownOrOverridesKnown then known = IsSpellKnownOrOverridesKnown(spellID)
    elseif IsPlayerSpell then known = IsPlayerSpell(spellID)
    elseif IsSpellKnown then known = IsSpellKnown(spellID) end
    return known and not ns.IsSecret(known) and true or false
end

local function FishingSpellID()
    for _, id in ipairs(FISHING_SPELLS) do
        if IsKnown(id) then return id end
    end
    -- Fall back to a spellbook walk by name (covers an ID this list lacks).
    local want = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(7620)
    if not want or not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then return nil end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    for line = 1, (C_SpellBook.GetNumSpellBookSkillLines() or 0) do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info and info.numSpellBookItems and info.itemIndexOffset then
            for i = 1, info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(info.itemIndexOffset + i, bank)
                if item and item.spellID and item.name == want and not item.isPassive then
                    return item.spellID
                end
            end
        end
    end
    return nil
end

local function IsFishingPole(itemID)
    if not itemID or not C_Item or not C_Item.GetItemInfoInstant then return false end
    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    if ns.IsSecret(classID) or ns.IsSecret(subclassID) then return false end
    return classID == CLASS_WEAPON and subclassID == SUB_FISHPOLE
end

-- Best fishing pole in the bags by item level. Returns itemID or nil.
local function FindPole()
    if not C_Container then return nil end
    local bestID, bestLevel = nil, -1
    for bag = 0, ns.NumBags() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID and not ns.IsSecret(itemID) and IsFishingPole(itemID) then
                local level = 0
                if C_Item.GetDetailedItemLevelInfo then
                    local ok, lvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
                    if ok and type(lvl) == "number" then level = lvl end
                end
                if level > bestLevel then bestID, bestLevel = itemID, level end
            end
        end
    end
    return bestID
end

local function EquippedID(slot)
    local id = GetInventoryItemID("player", slot)
    if ns.IsSecret(id) then return nil end
    return id
end

-- True when every bag copy of `itemID` is locked (mid-move, in a trade ...).
-- An item that is not in the bags at all is not "locked".
local function BagItemLocked(itemID)
    if not itemID or not C_Container or not C_Container.GetContainerItemInfo then return false end
    local found, free = false, false
    for bag = 0, ns.NumBags() do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and not ns.IsSecret(id) and id == itemID then
                found = true
                local info = C_Container.GetContainerItemInfo(bag, slot)
                local locked = info and info.isLocked
                if not locked or ns.IsSecret(locked) then free = true end
            end
        end
    end
    return found and not free
end

-- Whether the character still has `itemID` (bags or hands). Unknown = yes.
local function Owned(itemID)
    if EquippedID(SLOT_MAIN) == itemID or EquippedID(SLOT_OFF) == itemID then return true end
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not fn then return true end
    local ok, n = pcall(fn, itemID)
    if not ok or ns.IsSecret(n) or type(n) ~= "number" then return true end
    return n > 0
end

local function CastingNow()
    local ok, name = pcall(UnitCastingInfo, "player")
    return ok and name ~= nil and not ns.IsSecret(name)
end

local function ChannelNow()
    local ok, name = pcall(UnitChannelInfo, "player")
    return ok and name ~= nil and not ns.IsSecret(name), name
end

-- The last real (non-pole) weapons seen in the hands, kept per character as
-- the fallback for "what to put back" when the pole is already in hand.
local function LoadLastWeapons()
    local raw = ns.db and ns.db[WeaponsKey()]
    if type(raw) ~= "string" then return nil, nil end
    return tonumber(raw:match("mh:(%d+)")), tonumber(raw:match("oh:(%d+)"))
end

local function RememberWeapons(mh, oh)
    if not ns.db or not mh or IsFishingPole(mh) then return end
    local v = ("mh:%s|oh:%s"):format(mh, oh or "")
    if ns.db[WeaponsKey()] ~= v then
        ns.db[WeaponsKey()] = v
        ns.SaveSettings()
    end
end

-- The action slot behind the first button of the main bar as it is shown
-- right now (stance and page aware); plain slot 1 if the bar is not there.
local function VisibleSlot1()
    local b = _G.ActionButton1
    local slot = b and (b.action or (b.GetAttribute and b:GetAttribute("action")))
    if type(slot) == "number" and slot > 0 then return slot end
    return 1
end

-------------------------------------------------------------------------------
-- Action button 1
-------------------------------------------------------------------------------

local function CursorKind()
    local kind = GetCursorInfo()
    if ns.IsSecret(kind) then return nil end
    return kind
end

-- Lifts the current content of `slot` onto the cursor and drops it.
local function EmptySlot(slot)
    ClearCursor()
    if HasAction(slot) then
        pcall(PickupAction, slot)
        ClearCursor()
    end
end

local function PlaceCursorInto(slot)
    if not CursorKind() then return false end
    local ok = pcall(PlaceAction, slot)
    ClearCursor()
    return ok
end

local function PlaceSpell(slot, spellID)
    ClearCursor()
    if C_Spell and C_Spell.PickupSpell then pcall(C_Spell.PickupSpell, spellID)
    elseif PickupSpell then pcall(PickupSpell, spellID) end
    if CursorKind() ~= "spell" then ClearCursor() return false end
    return PlaceCursorInto(slot)
end

-- What is on `slot` now, in a form that can be put back later.
local function RememberSlot(slot)
    local kind, id, sub = GetActionInfo(slot)
    if ns.IsSecret(kind) or not kind then return { slot = slot } end
    local st = { slot = slot, kind = kind, id = id }
    if kind == "macro" and GetMacroInfo and id then
        local okN, name = pcall(GetMacroInfo, id)
        if okN and type(name) == "string" then st.name = name end
    elseif kind == "spell" and sub and not ns.IsSecret(sub) then
        st.name = tostring(sub)  -- subType ("spell", "pet", ...) for the record
    end
    return st
end

-- Puts the remembered content back. Returns true, or false with a reason.
local function RestoreSlot(st)
    local slot = st.slot or VisibleSlot1()
    if not st.kind then
        EmptySlot(slot)
        return true
    end
    ClearCursor()
    if st.kind == "spell" and st.id then
        if C_Spell and C_Spell.PickupSpell then pcall(C_Spell.PickupSpell, st.id)
        elseif PickupSpell then pcall(PickupSpell, st.id) end
    elseif st.kind == "macro" then
        local ref = st.name
        if ref and GetMacroIndexByName and (GetMacroIndexByName(ref) or 0) == 0 then ref = nil end
        pcall(PickupMacro, ref or st.id)
    elseif st.kind == "item" and st.id then
        if C_Item and C_Item.PickupItem then pcall(C_Item.PickupItem, st.id)
        elseif PickupItem then pcall(PickupItem, st.id) end
    elseif st.kind == "equipmentset" and C_EquipmentSet and C_EquipmentSet.PickupEquipmentSet then
        pcall(C_EquipmentSet.PickupEquipmentSet, st.id)
    end
    if not CursorKind() then
        EmptySlot(slot)
        return false, ("could not pick up the %s that was on button 1; drag it back yourself"):format(tostring(st.kind))
    end
    if not PlaceCursorInto(slot) then
        return false, "the client refused to place the old button"
    end
    return true
end

-------------------------------------------------------------------------------
-- Button-1 catch and soft-target interact
-------------------------------------------------------------------------------

Debug = function(msg)
    if ns.db and ns.db.fishingDebug then ns.Print("|cff88ccff[fish]|r " .. tostring(msg)) end
end

-- What the Interact key would act on right now (Retail soft targeting).
local function SoftInteractName()
    local ok, exists = pcall(UnitExists, "softinteract")
    if not ok or not exists or ns.IsSecret(exists) then return nil end
    local okN, name = pcall(UnitName, "softinteract")
    return (okN and type(name) == "string" and not ns.IsSecret(name)) and name or "(unnamed)"
end

-- Keys bound to action button 1, so they can be turned into "catch" while
-- the bobber is out. Read once per toggle-in.
local function Slot1Keys()
    local keys = {}
    if GetBindingKey then
        local a, b = GetBindingKey("ACTIONBUTTON1")
        if a then keys[#keys + 1] = a end
        if b then keys[#keys + 1] = b end
    end
    return keys
end

local channelling = false

-- The button-1 keys catch only while the Fishing channel is running (the
-- bobber is out); the rest of the time they cast as usual. Override bindings
-- win over normal ones and are cleared as a set.
local function ApplyKeys()
    if not ClearOverrideBindings or not SetOverrideBinding then return end
    pcall(ClearOverrideBindings, frame)
    if channelling and ns.db.fishingSlot1 then
        for _, key in ipairs(Slot1Keys()) do pcall(SetOverrideBinding, frame, true, key, INTERACT_CMD) end
    end
end

-- Soft-target interact on (fishing mode in) or back to what it was (out),
-- plus the catch keys that depend on it.
local function ApplyBobberKey(on)
    if on then
        if not ns.CVar.Exists("SoftTargetInteract") then
            ns.Print("Fishing: this client has no soft-target interact, so the bobber must be clicked.")
            return
        end
        for _, c in ipairs(SOFT_TARGET_CVARS) do
            if ns.CVar.Exists(c.name) then
                ns.CVar.ApplyWithSnapshot(c.name, c.value, c.dbKey, true)
                Debug(c.name .. " = " .. tostring(ns.CVar.Get(c.name)))
            end
        end
        Reinit("fishing mode on")
        ApplyKeys()
    else
        channelling = false
        reinitSerial = reinitSerial + 1   -- cancel a re-init still waiting to switch interact back on
        if ClearOverrideBindings then pcall(ClearOverrideBindings, frame) end
        for _, c in ipairs(SOFT_TARGET_CVARS) do
            if ns.CVar.Exists(c.name) then ns.CVar.ApplyWithSnapshot(c.name, c.value, c.dbKey, false) end
        end
    end
end

-- Swap jobs in flight (see Enter / leave); declared here for StatusDump.
local entering = nil   -- pole on its way in:        { pole, tries, timer }
local restore  = nil   -- weapons on their way back: { mh, oh, slot, tries, timer, waiting, since, said }

local function StatusDump()
    local mh = EquippedID(SLOT_MAIN)
    local st = LoadState()
    ns.Print(("fish: active=%s leaving=%s pole=%s slot1=%s channelling=%s"):format(
        tostring(IsActive()), tostring(st and st.leaving or false), tostring(IsFishingPole(mh)),
        tostring((GetActionInfo(VisibleSlot1()))), tostring(channelling)))
    local lmh, loh = LoadLastWeapons()
    ns.Print(("fish: saved mh=%s oh=%s, last weapons mh=%s oh=%s, swap=%s"):format(
        tostring(st and st.mh), tostring(st and st.oh), tostring(lmh), tostring(loh),
        entering and "equipping pole" or restore and (restore.waiting and "waiting" or "restoring") or "idle"))
    local vals = {}
    for _, c in ipairs(SOFT_TARGET_CVARS) do vals[#vals + 1] = c.name:gsub("SoftTarget", "") .. "=" .. tostring(ns.CVar.Get(c.name)) end
    ns.Print("fish: " .. table.concat(vals, " "))
    local keys = Slot1Keys()
    ns.Print(("fish: button1 keys [%s] -> %s, softinteract=%s"):format(
        table.concat(keys, ","), keys[1] and tostring(GetBindingAction(keys[1], true)) or "-",
        tostring(SoftInteractName() or "none")))
end

-------------------------------------------------------------------------------
-- Enter / leave
--
-- EquipItemByName only asks the server, and a refused request (item locked,
-- casting, cursor busy, combat) fails without a word. So each swap checks the
-- blockers first, checks afterwards that the hand really changed, and tries
-- again a few times. While a swap is in flight the toggle does not start
-- another one, and the weapons to put back stay saved until they are back.
-------------------------------------------------------------------------------

local VERIFY_DELAY = 0.6   -- seconds from an equip to the check that it landed
local ENTER_STEPS  = 5     -- checks for the pole before giving up (about 3 s)
local EQUIP_TRIES  = 4     -- equips sent per weapon on the way back
local WAIT_LIMIT   = 30    -- seconds to wait on a lock or a cast (combat waits it out)
local WAIT_QUIET   = 1.5   -- a blocker this young is our own swap settling; say nothing

local function Equip(itemID, slot)
    if not itemID then return false end
    local fn = (C_Item and C_Item.EquipItemByName) or EquipItemByName
    if not fn then return false end
    return (pcall(fn, itemID, slot))
end

-- Why a weapon swap would be dropped right now, or nil. Channelling is not a
-- blocker: an equip ends the Fishing channel, which is fine on the way out.
local function SwapBlocker(itemID)
    if InCombatLockdown() then return "in combat" end
    if CursorKind() then return "the cursor is holding something" end
    if CastingNow() then return "casting" end
    if IsInventoryItemLocked then
        for _, s in ipairs({ SLOT_MAIN, SLOT_OFF }) do
            local ok, locked = pcall(IsInventoryItemLocked, s)
            if ok and locked and not ns.IsSecret(locked) then return "a weapon slot is locked" end
        end
    end
    if itemID and BagItemLocked(itemID) then return ns.ItemNameByID(itemID) .. " is locked" end
    return nil
end

-- Pole on its way in: confirm it landed, resend while it has not.
local function StepEnter()
    local e = entering
    if not e then return end
    e.timer = nil
    if IsFishingPole(EquippedID(SLOT_MAIN)) then
        entering = nil
        Debug("pole equipped")
        return
    end
    if not IsActive() then entering = nil return end
    e.tries = e.tries + 1
    if e.tries > ENTER_STEPS then
        entering = nil
        ns.Print("Fishing: the pole did not equip (bags full, still casting or items locked?). Toggle again to turn fishing mode off, then retry.")
        return
    end
    local why = SwapBlocker(e.pole)
    if why then
        Debug("pole waits: " .. why)
    else
        Debug("pole resend " .. e.tries)
        Equip(e.pole, SLOT_MAIN)
    end
    e.timer = C_Timer.NewTimer(VERIFY_DELAY, StepEnter)
end

local function Enter()
    local db = ns.db
    local spellID = FishingSpellID()
    if not spellID then
        ns.Print("Fishing: you do not know Fishing yet.")
        return
    end

    local st = {}
    local mh, oh = EquippedID(SLOT_MAIN), EquippedID(SLOT_OFF)
    local pole
    if IsFishingPole(mh) then
        -- Already holding a pole (equipped by hand, or an earlier swap back
        -- that never landed). The pole is never the weapon to return to:
        -- the last real weapons seen on this character are.
        st.mh, st.oh = LoadLastWeapons()
        Debug("pole already in hand; will return to " .. tostring(st.mh))
    else
        pole = FindPole()
        if not pole then
            ns.Print("Fishing: no fishing pole in your bags.")
            return
        end
        local why = SwapBlocker(pole)
        if why then
            ns.Print(("Fishing: cannot swap weapons right now (%s). Try again in a moment."):format(why))
            return
        end
        st.mh, st.oh = mh, oh
        RememberWeapons(mh, oh)
    end
    -- Weapons are remembered before anything else can fail, so a second
    -- toggle always knows what to put back.
    SaveState(st)

    if pole then
        if not Equip(pole, SLOT_MAIN) then
            SaveState(nil)
            ns.Print("Fishing: could not equip " .. ns.ItemNameByID(pole) .. ".")
            return
        end
        entering = { pole = pole, tries = 0 }
        entering.timer = C_Timer.NewTimer(VERIFY_DELAY, StepEnter)
    end

    if db.fishingSlot1 then
        local slot = VisibleSlot1()
        local remembered = RememberSlot(slot)
        if PlaceSpell(slot, spellID) then
            st.slot, st.kind, st.id, st.name = remembered.slot, remembered.kind, remembered.id, remembered.name
        else
            ns.Print("Fishing: could not put Fishing on button 1 (drag it there from the spellbook).")
        end
    end

    ApplyBobberKey(true)
    if ns.FishingStartWatch then ns.FishingStartWatch() end

    SaveState(st)
    local parts = { "Fishing mode on" }
    if st.slot then
        parts[#parts + 1] = "press 1 to cast and 1 again when the bobber splashes"
    else
        parts[#parts + 1] = "cast Fishing and use your Interact key on the bobber when it splashes"
    end
    if not st.mh and not st.oh then parts[#parts + 1] = "No weapon is on record, so the pole stays in your hands afterwards" end
    ns.Print(table.concat(parts, ". ") .. ". Use the toggle again to put your weapons back.")
end

-- Weapons on their way back. One weapon at a time (main hand first, so a
-- two-hander does not knock the off hand out again); each equip is checked
-- VERIFY_DELAY later and resent up to EQUIP_TRIES times. Blockers are waited
-- out: a one-second recheck plus the events that end them.
local StepRestore

local function StopRestore()
    if restore and restore.timer then restore.timer:Cancel() end
    restore = nil
end

local function RestoreLater(delay)
    if restore.timer then restore.timer:Cancel() end
    restore.timer = C_Timer.NewTimer(delay, StepRestore)
end

local function RestoreDone()
    StopRestore()
    SaveState(nil)
    local mh = EquippedID(SLOT_MAIN)
    RememberWeapons(mh, EquippedID(SLOT_OFF))
    if IsFishingPole(mh) then
        ns.Print("Fishing mode off. No weapon was on record, so the pole stays in your hands.")
    else
        ns.Print("Fishing mode off. Weapons back in your hands.")
    end
end

-- The saved weapons stay (state marked as leaving), so the next toggle
-- starts the swap back again.
local function RestoreFailed(why)
    StopRestore()
    ns.Print(("Fishing: could not put your weapons back (%s). Toggle again to retry."):format(why))
end

StepRestore = function()
    local r = restore
    if not r then return end
    -- An event can get here before the pending recheck; one step at a time.
    if r.timer then r.timer:Cancel() end
    r.timer, r.waiting = nil, false

    local needMH = r.mh and EquippedID(SLOT_MAIN) ~= r.mh
    local needOH = r.oh and EquippedID(SLOT_OFF) ~= r.oh
    if not needMH and not needOH then return RestoreDone() end
    local id, slot = r.mh, SLOT_MAIN
    if not needMH then id, slot = r.oh, SLOT_OFF end
    if r.slot ~= slot then r.slot, r.tries = slot, 0 end

    if not Owned(id) then
        ns.Print("Fishing: " .. ns.ItemNameByID(id) .. " is no longer in your bags; skipping it.")
        if slot == SLOT_MAIN then r.mh = nil else r.oh = nil end
        SaveState({ mh = r.mh, oh = r.oh, leaving = true })
        return StepRestore()
    end

    local why = SwapBlocker(id)
    if why then
        local now = GetTime()
        r.since = r.since or now
        if why ~= "in combat" and now - r.since > WAIT_LIMIT then
            return RestoreFailed(why .. " for too long")
        end
        if r.said ~= why and (why == "in combat" or now - r.since >= WAIT_QUIET) then
            r.said = why
            ns.Print(("Fishing: waiting to put your weapons back (%s)."):format(why))
        end
        Debug("restore waits: " .. why)
        r.waiting = true
        return RestoreLater(1)
    end
    r.since = nil

    if r.tries >= EQUIP_TRIES then
        return RestoreFailed(ns.ItemNameByID(id) .. " did not equip")
    end
    r.tries = r.tries + 1
    Debug(("equip %s into %d (try %d)"):format(ns.ItemNameByID(id), slot, r.tries))
    if not Equip(id, slot) then
        return RestoreFailed("the client refused to equip " .. ns.ItemNameByID(id))
    end
    RestoreLater(VERIFY_DELAY)
end

local function StartRestore(mh, oh)
    StopRestore()
    -- Never "restore" a pole (old saved data or a swap that raced).
    if mh and IsFishingPole(mh) then mh, oh = LoadLastWeapons() end
    -- Nothing on record (state from before this was tracked) but a pole in
    -- hand: the last real weapons seen are the best guess.
    if not mh and not oh and IsFishingPole(EquippedID(SLOT_MAIN)) then mh, oh = LoadLastWeapons() end
    restore = { mh = mh, oh = oh, tries = 0 }
    StepRestore()
end

local function Leave(st)
    st = st or LoadState() or {}
    if ns.FishingStopWatch then ns.FishingStopWatch() end
    ApplyBobberKey(false)   -- safe to repeat: snapshots are restored once

    if st.slot then
        local ok, why = RestoreSlot(st)
        if not ok then ns.Print("Fishing: " .. tostring(why) .. ".") end
    end

    -- Button and keys are done; the weapons stay on record until they are
    -- verified back in the hands.
    SaveState({ mh = st.mh, oh = st.oh, leaving = true })
    StartRestore(st.mh, st.oh)
end

local function Toggle()
    if not ns.db then return end
    if entering then
        ns.Print("Fishing: still equipping the pole; one moment.")
        return
    end
    if restore then
        if restore.waiting then
            StepRestore()   -- recheck now; says what it still waits on
        else
            ns.Print("Fishing: still putting your weapons back; one moment.")
        end
        return
    end
    if InCombatLockdown() then
        ns.Print("Fishing: not in combat.")
        return
    end
    if CursorKind() then
        ns.Print("Fishing: put down what you are dragging first.")
        return
    end

    local st = LoadState()
    if st then
        -- On, or half-way out: go out (also when the pole never landed).
        Leave(st)
    elseif IsFishingPole(EquippedID(SLOT_MAIN)) then
        -- Off, but a pole in hand: the state and the hands disagree. Put the
        -- last real weapons back rather than starting fishing mode again.
        local mh, oh = LoadLastWeapons()
        if mh then
            ns.Print("Fishing: you hold a pole but fishing mode was off; putting your weapons back.")
            Leave({ mh = mh, oh = oh })
        else
            Enter()
        end
    else
        Enter()
    end
end

-------------------------------------------------------------------------------
-- Macro
-------------------------------------------------------------------------------

local function WriteMacro(announce)
    if not (CreateMacro and EditMacro and GetMacroIndexByName) then
        if announce then ns.Print("Macro functions are not available on this client.") end
        return
    end
    if InCombatLockdown() then
        if announce then ns.Print("Cannot edit macros in combat.") end
        return
    end
    local index = GetMacroIndexByName(MACRO_NAME) or 0
    if index > 0 then
        if (GetMacroBody(index) or "") ~= MACRO_BODY then
            EditMacro(index, MACRO_NAME, MACRO_ICON, MACRO_BODY)
            if announce then ns.Print("Updated the " .. MACRO_NAME .. " macro.") end
        elseif announce then
            ns.Print("The " .. MACRO_NAME .. " macro is already there. Drag it onto a bar.")
        end
        return
    end
    local account = GetNumMacros() or 0
    if account >= (MAX_ACCOUNT_MACROS or 120) then
        ns.Print("Fishing: no free account macro slot for " .. MACRO_NAME .. ".")
        return
    end
    CreateMacro(MACRO_NAME, MACRO_ICON, MACRO_BODY, false)
    ns.Print("Created the " .. MACRO_NAME .. " macro. Open the macro window and drag it onto a bar; it toggles fishing mode.")
end

-------------------------------------------------------------------------------
-- Login: re-apply the transient parts if a session ended mid-fishing, and
-- finish a swap back that a /reload or logout cut short
-------------------------------------------------------------------------------

local function ApplyAtLogin()
    if not ns.db then return end
    local st = LoadState()
    if st and not st.leaving then
        ApplyBobberKey(true)
        if ns.FishingStartWatch then ns.FishingStartWatch() end
    elseif st and st.leaving then
        -- Items are not reliably equippable right at login; give it a moment.
        C_Timer.After(3, function()
            local now = LoadState()
            if now and now.leaving and not restore and not entering then
                ns.Print("Fishing: putting your weapons back (unfinished from last session).")
                StartRestore(now.mh, now.oh)
            end
        end)
    else
        RememberWeapons(EquippedID(SLOT_MAIN), EquippedID(SLOT_OFF))
    end
end

-- The macro list is not readable right at login; write the macro a little
-- later, and only when it is missing (no chat line in the normal case).
local macroChecked = false
local function EnsureMacroLater()
    if macroChecked then return end
    macroChecked = true
    C_Timer.After(6, function()
        if ns.db and ns.db.fishingMacro and GetMacroIndexByName
           and (GetMacroIndexByName(MACRO_NAME) or 0) == 0 then
            WriteMacro(false)
        end
    end)
end

-------------------------------------------------------------------------------
-- Bobber out / bobber in
--
-- Key 1 is "catch" while the Fishing channel runs and for a short hold after
-- it ends (on this server the channel can end at the bite), then "cast"
-- again. Closing the loot window re-arms "cast" at once. The state is read
-- from UnitChannelInfo four times a second; the channel events are used too
-- but were not reliable on Forever. The soft-target picker is re-initialised
-- (see Reinit) when fishing mode starts and once per cast after the bobber
-- lands. Nothing here listens to the keyboard: a key-listening frame on this
-- client swallowed every key instead of passing it on.
-------------------------------------------------------------------------------

local HOLD_AFTER_CHANNEL = 1.5

local rearmTimer, kickSerial, watchTicker = nil, 0, nil
local awaitIdle = false   -- after a loot, ignore the still-running channel until it is seen idle

local function Rearm()
    if rearmTimer then rearmTimer:Cancel(); rearmTimer = nil end
    channelling = false
    if IsActive() then ApplyKeys() end
end

-- One full re-init per cast, once the bobber is in the water.
-- Repeating it does not rescue a cast the client refuses and drops the
-- highlight on one it accepted (the softinteract unit does not report the
-- highlighted bobber on this client, so there is nothing to condition on).
local function StartKicks()
    if not ns.CVar.Exists("SoftTargetInteract") then return end
    kickSerial = kickSerial + 1
    local mine = kickSerial
    C_Timer.After(KICK_DELAY, function()
        if mine ~= kickSerial or not (IsActive() and channelling) then return end
        Reinit("cast")
    end)
end

local function OnChannel(started)
    if not IsActive() then return end
    if started then
        if rearmTimer then rearmTimer:Cancel(); rearmTimer = nil end
        channelling = true
        ApplyKeys()
        StartKicks()
    else
        kickSerial = kickSerial + 1
        if rearmTimer then rearmTimer:Cancel() end
        rearmTimer = C_Timer.NewTimer(HOLD_AFTER_CHANNEL, Rearm)
    end
end

local function StartWatch()
    if watchTicker then return end
    watchTicker = C_Timer.NewTicker(0.25, function()
        if not IsActive() or InCombatLockdown() then return end
        local now, name = ChannelNow()
        if not now then awaitIdle = false end
        if now and not channelling and not awaitIdle then
            Debug("channel started: " .. tostring(name))
            OnChannel(true)
        elseif not now and channelling and not rearmTimer then
            Debug("channel ended")
            OnChannel(false)
        end
    end)
end
local function StopWatch()
    if watchTicker then watchTicker:Cancel(); watchTicker = nil end
    kickSerial = kickSerial + 1
    if rearmTimer then rearmTimer:Cancel(); rearmTimer = nil end
    channelling, awaitIdle = false, false
end
ns.FishingStartWatch, ns.FishingStopWatch = StartWatch, StopWatch

-- Events that can end whatever a waiting swap back is blocked on.
local WAKE_EVENTS = {
    PLAYER_REGEN_ENABLED        = true,
    ITEM_LOCK_CHANGED           = true,
    PLAYER_EQUIPMENT_CHANGED    = true,
    UNIT_SPELLCAST_STOP         = true,
    UNIT_SPELLCAST_FAILED       = true,
    UNIT_SPELLCAST_INTERRUPTED  = true,
    UNIT_SPELLCAST_CHANNEL_STOP = true,
}

frame:RegisterEvent("PLAYER_LOGIN")
ns.SafeRegisterEvent(frame, "UNIT_SPELLCAST_CHANNEL_START")
ns.SafeRegisterEvent(frame, "LOOT_CLOSED")
for event in pairs(WAKE_EVENTS) do ns.SafeRegisterEvent(frame, event) end
frame:SetScript("OnEvent", function(self, event, unit)
    if WAKE_EVENTS[event] then
        local mine = unit == "player" or not event:find("^UNIT_")
        if mine and restore and restore.waiting then StepRestore() end
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            -- Track the real weapons while nothing of ours is in flight.
            if not entering and not restore and not LoadState() then
                RememberWeapons(EquippedID(SLOT_MAIN), EquippedID(SLOT_OFF))
            end
        end
        if event ~= "UNIT_SPELLCAST_CHANNEL_STOP" then return end
    end
    if event == "PLAYER_LOGIN" then
        if not (ns.SettingsRestorePending and ns.SettingsRestorePending()) then ApplyAtLogin() end
        EnsureMacroLater()
    elseif event == "LOOT_CLOSED" then
        if channelling and IsActive() and not InCombatLockdown() then
            awaitIdle = ChannelNow()
            Rearm()
        end
    elseif unit == "player" and IsActive() and not InCombatLockdown() then
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            awaitIdle = false
            if not channelling then OnChannel(true) end
        elseif channelling and not rearmTimer then
            OnChannel(false)
        end
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "fishingModule",
    label = "Fishing",
    icon  = "Interface\\Icons\\Trade_Fishing",
    group = "Professions",
    beta  = "fishing mode is still being tuned on WoW Forever. The client does not always pick up the bobber, so pressing 1 can do nothing on some casts. If it does, click the bobber or cast again.",
    reinitSafe = true,   -- OnInit only re-applies state from ns.db
    options = {
        { key = "fishingMacro", label = "Fishing macro", default = true,
          tooltip = "Keeps an account macro called MooseFish that toggles fishing mode: pole in, Fishing on button 1, and the button-1 key catches the bobber while it is out. Toggle again to get your weapons back. Drag it onto a bar.",
          onChange = function(checked) if checked then WriteMacro(true) end end },
        { key = "fishingSlot1", label = "Put Fishing on button 1", default = true, parent = "fishingMacro",
          tooltip = "While fishing mode is on, the first button of the main bar casts Fishing, and while the bobber is out the same key catches it. Whatever was on the button comes back when you toggle out." },
        { type = "button", label = "Toggle fishing mode now", buttonText = "Toggle",
          tooltip = "Same as /mm fish or the MooseFish macro.", onClick = function() Toggle() end },
        { type = "note", text = "Nothing can catch for you: the game gives addons no signal when a fish bites. Press 1 to cast, then 1 again when you hear the splash." },
    },
    OnInit = function()
        if IsLoggedIn and IsLoggedIn() then ApplyAtLogin() end
    end,
    commands = {
        fish      = function() Toggle() end,
        fishmacro = function() WriteMacro(true) end,
        fishdebug = function()
            ns.db.fishingDebug = not ns.db.fishingDebug
            ns.SaveSettings()
            ns.Print("Fishing debug " .. (ns.db.fishingDebug and "on" or "off") .. ".")
            StatusDump()
        end,
    },
})
