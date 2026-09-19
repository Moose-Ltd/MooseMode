-------------------------------------------------------------------------------
-- MooseMode -- ActionBars
--
-- Small action bar tweaks. Currently: hides the macro name text drawn under
-- the icon on action bar buttons, so a bar full of macros looks like a bar
-- full of spells.
--
-- How: every standard bar button has a "Name" font string
-- (ActionButton1Name, MultiBarBottomLeftButton3Name, ...). Blizzard's own
-- updates only ever SetText() it, never touch its alpha, so SetAlpha(0)
-- sticks across bar refreshes, page changes and combat. The same approach
-- Leatrix Plus uses on this client.
--
-- Options (account-wide):
--   hideMacroNames   Hide macro names on bars
-------------------------------------------------------------------------------

local ADDON, ns = ...

-- Bar button prefixes on the Retail-based client (8 bars x 12 buttons).
local PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

local NUM_BUTTONS = NUM_ACTIONBAR_BUTTONS or 12

local function NameRegion(prefix, i)
    local button = _G[prefix .. i]
    if not button then return nil end
    local region = button.Name or _G[prefix .. i .. "Name"]
    if region and type(region.SetAlpha) == "function" then
        return region
    end
    return nil
end

local function ApplyMacroNames()
    if not ns.db then return end
    local alpha = ns.db.hideMacroNames and 0 or 1
    for _, prefix in ipairs(PREFIXES) do
        for i = 1, NUM_BUTTONS do
            local region = NameRegion(prefix, i)
            if region then
                region:SetAlpha(alpha)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ApplyMacroNames()
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "actionBarsModule",
    label = "Action Bars",
    options = {
        { key = "hideMacroNames", label = "Hide macro names on bars", default = true,
          tooltip = "Show only the icon on action bar buttons that hold macros.",
          onChange = function()
              ApplyMacroNames()
          end },
    },
    OnInit = function()
        if IsLoggedIn and IsLoggedIn() then
            ApplyMacroNames()
        end
    end,
})
