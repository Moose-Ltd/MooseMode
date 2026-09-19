-------------------------------------------------------------------------------
-- MooseMode -- AutoRepair
--
-- Repairs all equipped and carried gear when a vendor that can repair opens.
-- Hold SHIFT while opening the vendor to skip repairing for that visit.
--
-- Options (account-wide):
--   autoRepair        Auto repair at vendors
--   autoRepairGuild   Use guild bank funds when allowed (sub-option)
--   repairSummary     Show repair cost in chat (sub-option)
--
-- Commands:
--   /mm repair        repair now at the currently open vendor
-------------------------------------------------------------------------------

local ADDON, ns = ...

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Say(msg)
    if ns.db.repairSummary then ns.Print(msg) end
end

-- Returns the repair cost and whether anything needs repairing, or nil if the
-- answer cannot be trusted (secret values, missing API).
local function RepairCost()
    if not GetRepairAllCost then return nil end
    local ok, cost, canRepair = pcall(GetRepairAllCost)
    if not ok or ns.IsSecret(cost) or ns.IsSecret(canRepair) then return nil end
    return cost or 0, canRepair and true or false
end

-- True when the guild bank may pay for this repair and has enough money
-- left in the player's daily withdrawal allowance (-1 means unlimited).
local function GuildCanPay(cost)
    if not CanGuildBankRepair or not GetGuildBankWithdrawMoney then return false end
    local ok, allowed = pcall(CanGuildBankRepair)
    if not ok or ns.IsSecret(allowed) or not allowed then return false end
    local okW, limit = pcall(GetGuildBankWithdrawMoney)
    if not okW or ns.IsSecret(limit) or limit == nil then return false end
    if limit < 0 then return true end
    return limit >= cost
end

-------------------------------------------------------------------------------
-- Repairing
-------------------------------------------------------------------------------

local function Repair(force)
    local db = ns.db
    if not db then return end
    if not force and not db.autoRepair then return end
    if not force and IsShiftKeyDown() then return end
    if not CanMerchantRepair or not CanMerchantRepair() then
        if force then ns.Print("This vendor cannot repair.") end
        return
    end

    local cost, canRepair = RepairCost()
    if cost == nil then return end
    if not canRepair or cost <= 0 then
        if force then ns.Print("Nothing needs repairing.") end
        return
    end

    if db.autoRepairGuild and GuildCanPay(cost) then
        RepairAllItems(true)
        Say(("Repaired all items for %s (guild funds)."):format(ns.Coins(cost)))
        return
    end

    local money = GetMoney and GetMoney()
    if ns.IsSecret(money) or not money then return end
    if money >= cost then
        RepairAllItems()
        Say(("Repaired all items for %s."):format(ns.Coins(cost)))
    else
        Say(("Not enough money to repair (%s needed)."):format(ns.Coins(cost)))
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        Repair(false)
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "autoRepairModule",
    label = "Auto Repair",
    group = "Vendors",
    options = {
        { key = "autoRepair", label = "Repair at vendors", default = true,
          tooltip = "Repair all your gear whenever a vendor that can repair opens." },
        { key = "autoRepairGuild", label = "Use guild funds when allowed", default = false, parent = "autoRepair",
          tooltip = "Pay from the guild bank when your rank allows it and the allowance covers the cost. Otherwise your own money is used." },
        { key = "repairSummary", label = "Show repair cost in chat", default = true, parent = "autoRepair",
          tooltip = "Print what the repair cost, or a warning if you could not afford it." },
    },
    commands = {
        repair = function()
            if MerchantFrame and MerchantFrame:IsShown() then
                Repair(true)
            else
                ns.Print("Open a vendor first.")
            end
        end,
    },
})
