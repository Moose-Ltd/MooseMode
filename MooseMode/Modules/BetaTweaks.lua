-------------------------------------------------------------------------------
-- MooseMode -- BetaTweaks
--
-- Small fixes for the WoW: Forever beta client. Currently: hides the floating
-- "Issue Reporter" widget (the draggable label with the blue beetle button)
-- that Blizzard_PTRFeedback parks in the middle of the screen.
--
-- How Blizzard builds it (Blizzard_PTRFeedback, live branch):
--   * PTR_IssueReporter is the floating widget itself: a DIALOG-strata frame
--     whose font string reads "Issue\nReporter". CreateMainView() sizes it,
--     adds PTR_IssueReporter.Body underneath, and the beetle button
--     (PTR_IssueReporter.ReportBug) is created as a child of it.
--   * Survey and report popups (PTRIssueReporterAlertFrame, the standalone
--     survey frame) are parented to UIParent, so hiding PTR_IssueReporter
--     leaves them working. Only the floating widget goes away.
--   * Init() -> CreateMainView() runs from Blizzard's own
--     PLAYER_ENTERING_WORLD handler, so we hook CreateMainView and Show, and
--     also retry shortly after entering the world.
--
-- Options (account-wide):
--   hideIssueReporter   Hide the beta Issue Reporter button
--
-- On a client without Blizzard_PTRFeedback this module does nothing.
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local hooked = false

local function Reporter()
    local f = _G.PTR_IssueReporter
    if type(f) == "table" and type(f.Hide) == "function" and type(f.Show) == "function" then
        return f
    end
    return nil
end

local function WantHidden()
    return ns.db and ns.db.hideIssueReporter and true or false
end

local function HideReporter()
    if not WantHidden() then return end
    local f = Reporter()
    if not f then return end
    pcall(f.Hide, f)
end

local function ShowReporter()
    local f = Reporter()
    if not f then return end
    -- Only bring it back if Blizzard has actually built it; before
    -- CreateMainView runs there is nothing to show.
    if f.ReportBug or f.Body then
        pcall(f.Show, f)
    end
end

-- Hook Blizzard's builder and the frame's own Show so the widget stays hidden
-- however it comes back (initial creation, a later Show from Blizzard code).
local function InstallHooks()
    if hooked then return end
    local f = Reporter()
    if not f then return end
    hooked = true
    if hooksecurefunc then
        if type(f.CreateMainView) == "function" then
            hooksecurefunc(f, "CreateMainView", function()
                HideReporter()
            end)
        end
        hooksecurefunc(f, "Show", function()
            if WantHidden() then
                HideReporter()
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        InstallHooks()
        HideReporter()
        -- Blizzard's own PLAYER_ENTERING_WORLD handler may run after ours.
        C_Timer.After(1, function()
            InstallHooks()
            HideReporter()
        end)
    end
end)

-------------------------------------------------------------------------------
-- Register
-------------------------------------------------------------------------------

ns:RegisterModule({
    key   = "betaTweaksModule",
    label = "Beta Client",
    group = "Interface",
    summary = "Hides beta-client clutter.",
    icon    = "Interface\\Icons\\Spell_Nature_InsectSwarm",
    options = {
        { key = "hideIssueReporter", label = "Hide Issue Reporter button", default = true,
          tooltip = "Hide the floating blue beetle the beta client puts on screen. Bug reports and surveys still work, and /ptr still opens the reporter.",
          onChange = function(checked)
              if checked then
                  InstallHooks()
                  HideReporter()
              else
                  ShowReporter()
              end
          end },
    },
    OnInit = function()
        InstallHooks()
        HideReporter()
    end,
})
