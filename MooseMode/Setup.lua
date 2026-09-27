-------------------------------------------------------------------------------
-- MooseMode -- Setup
--
-- The welcome window, shown once on the first login after install, in the
-- spirit of ElvUI's installer: click Recommended and be done, or step
-- through three quick choices (questing, chat, minimap). Every choice is
-- applied the moment it is clicked through ns.SetOptionByKey, so nothing
-- needs a reload, and any page can be left alone with Continue. Closing the
-- window counts as finishing, so it never nags. /mm setup, or the Setup link
-- in the options window, brings it back.
--
-- Completion is stored account-wide as ns.db.setupDone (the addon version
-- that finished it), in the same backed-up settings table as every other
-- option. The window waits for the late settings restore before deciding
-- whether it has been seen, so a reload on the beta client never shows it
-- a second time.
-------------------------------------------------------------------------------

local ADDON, ns = ...
if ns.disabled then return end   -- the other copy of MooseMode is running (see Core.lua)

local UI = ns.UI
local C  = UI.C

local W, H      = 560, 460
local TITLE_H   = 50
local PAD       = 24
local CHOICE_H  = 54
local CHOICE_GAP = 8
local FOOT_BTN_W, FOOT_BTN_H = 110, 26
local BAR_W     = W - 2 * PAD - 2 * FOOT_BTN_W - 2 * 20

local frame
local ui   = {}
local page = 1

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------

-- A choice: label, one-line blurb, and the settings it applies in order
-- (parents before children so the module actions see a consistent state).
local function Choice(label, blurb, settings)
    return { label = label, blurb = blurb, settings = settings }
end

local function Action(label, blurb, fn)
    return { label = label, blurb = blurb, action = fn }
end

local pages
local ShowPage, MarkDone

local function ApplySettings(settings)
    for _, kv in ipairs(settings) do ns.SetOptionByKey(kv[1], kv[2]) end
end

local function Matches(settings)
    if not ns.db then return false end
    for _, kv in ipairs(settings) do
        if ns.db[kv[1]] ~= kv[2] then return false end
    end
    return true
end

local function ApplyRecommended()
    for _, p in ipairs(pages) do
        if p.choices and p.recommended then ApplySettings(p.choices[p.recommended].settings) end
    end
end

pages = {
    {
        title = "Welcome to MooseMode",
        text  = "MooseMode is a bag of quality-of-life tools for WoW: Forever: auto sell and repair, fast loot, "
             .. "quest automation, a swing timer, map and minimap extras, and more.\n\n"
             .. "Pick Recommended to apply the settings most players want, or step through three quick choices. "
             .. "Everything can be changed later in the settings window (/mm).",
        items = {
            Action("Recommended", "Apply the recommended settings and finish. Best for most players.",
                function() ApplyRecommended(); ShowPage(#pages) end),
            Action("Step by step", "Three quick choices: questing, chat, and the minimap.",
                function() ShowPage(2) end),
            Action("Skip", "Keep the current settings. /mm setup brings this window back any time.",
                function() frame:Hide() end),
        },
    },
    {
        title = "Questing",
        text  = "How much of the questing should MooseMode handle at NPCs?",
        recommended = 1,
        choices = {
            Choice("Full auto", "Accepts quests, hands in completed ones, and picks the only gossip option.",
                { { "autoQuest", true }, { "autoQuestTurnIn", true }, { "autoGossip", true } }),
            Choice("Accept only", "Picks up quests for you; you hand them in and talk to NPCs yourself.",
                { { "autoQuest", true }, { "autoQuestTurnIn", false }, { "autoGossip", false } }),
            Choice("Off", "Quest windows behave exactly as the game does.",
                { { "autoQuest", false }, { "autoGossip", false } }),
        },
    },
    {
        title = "Chat",
        text  = "How much should MooseMode say in chat?",
        recommended = 1,
        choices = {
            Choice("Normal", "Sale and repair totals, spell rank swaps, and quest progress lines to your party.",
                { { "sellSummary", true }, { "repairSummary", true }, { "spellRanksReport", true }, { "questAnnounce", true } }),
            Choice("Quiet", "No summaries in your chat and nothing sent to your party.",
                { { "sellSummary", false }, { "repairSummary", false }, { "spellRanksReport", false }, { "questAnnounce", false } }),
        },
    },
    {
        title = "Minimap",
        text  = "How should the minimap look?",
        recommended = 1,
        choices = {
            Choice("Classic", "The round minimap with its zoom buttons and addon buttons, as the game draws it.",
                { { "minimapSquare", false }, { "minimapHideZoom", false }, { "minimapHideButtons", false } }),
            Choice("Clean", "A square minimap with a purple border, no zoom buttons, and addon buttons that appear when you hover it.",
                { { "minimapSquare", true }, { "minimapHideZoom", true }, { "minimapHideButtons", true } }),
        },
    },
    {
        title = "All set",
        text  = "Your choices are saved and already in effect. The settings window (/mm) has every option, "
             .. "and /mm setup brings this back.",
        items = {
            Action("Open settings", "See every option in the settings window.",
                function() frame:Hide(); ns.OpenOptions() end),
            Action("Finish", "Close this window and get on with the game.",
                function() frame:Hide() end),
        },
    },
}

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

local function PaintChoice(b)
    local on = b.selected
    if on then
        b.bg:SetColorTexture(C.cardOn[1], C.cardOn[2], C.cardOn[3], b.hover and 0.10 or C.cardOn[4])
        UI.SetBorderColor(b, C.brand, 0.85)
    else
        b.bg:SetColorTexture(1, 1, 1, b.hover and 0.06 or C.card[4])
        UI.SetBorderColor(b, b.hover and C.brand or C.hairline, b.hover and 0.45 or C.hairline[4])
    end
    if b.tag then b.tag:SetShown(on) end
end

local function CreateChoice(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(W - 2 * PAD, CHOICE_H)
    b.bg = UI.Solid(b, "BACKGROUND", 1, 1, 1, C.card[4])
    b.bg:SetAllPoints()
    UI.Border(b, C.hairline)
    b.label = UI.Text(b, 13, C.text)
    b.label:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -10)
    b.blurb = UI.Text(b, 11, C.muted)
    b.blurb:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -29)
    UI.Wrap(b.blurb, W - 2 * PAD - 28 - 60)
    b.tag = UI.Text(b, 10, C.brand)
    b.tag:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -12)
    b.tag:SetJustifyH("RIGHT")
    b.tag:SetText("CURRENT")
    b.tag:Hide()
    b:SetScript("OnEnter", function(self) self.hover = true; PaintChoice(self) end)
    b:SetScript("OnLeave", function(self) self.hover = false; PaintChoice(self) end)
    b:SetScript("OnClick", function(self)
        local item = self.item
        if not item then return end
        if item.settings then
            ApplySettings(item.settings)
            ShowPage(page + 1)
        elseif item.action then
            item.action()
        end
    end)
    PaintChoice(b)
    return b
end

local function BuildTitleBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetHeight(TITLE_H)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local bg = UI.SolidC(bar, "BACKGROUND", C.titleBar)
    bg:SetAllPoints()
    local line = UI.Solid(bar, "ARTWORK", C.brand[1], C.brand[2], C.brand[3], 0.45)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")

    local logo = bar:CreateTexture(nil, "ARTWORK")
    logo:SetSize(26, 26)
    logo:SetPoint("LEFT", bar, "LEFT", PAD - 8, 0)
    logo:SetTexture(UI.LOGO_TEX)

    local name = UI.Text(bar, 17, C.brand)
    name:SetPoint("LEFT", logo, "RIGHT", 10, 0)
    name:SetText("MooseMode")

    local sub = UI.Text(bar, 12, C.muted)
    sub:SetPoint("LEFT", name, "RIGHT", 10, -1)
    sub:SetText("Setup  " .. (UI.AddonVersion() or ""))

    local close = UI.CreateCloseButton(bar, f)
    close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    return bar
end

local function BuildFrame()
    if frame then return frame end

    local f = CreateFrame("Frame", "MooseModeSetupFrame", UIParent)
    f:SetSize(W, H)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:Hide()
    local bg = UI.SolidC(f, "BACKGROUND", C.window)
    bg:SetAllPoints()
    UI.Border(f, C.brand, 0.55)
    frame = f

    -- Escape closes it, which counts as finishing.
    tinsert(UISpecialFrames, "MooseModeSetupFrame")

    BuildTitleBar(f)

    ui.title = UI.Text(f, 20, C.brand)
    ui.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TITLE_H + 22))

    ui.body = UI.Text(f, 12, C.text)
    ui.body:SetPoint("TOPLEFT", ui.title, "BOTTOMLEFT", 0, -10)
    UI.Wrap(ui.body, W - 2 * PAD)
    ui.body:SetSpacing(3)

    ui.choices = {}
    local prev
    for i = 1, 3 do
        local b = CreateChoice(f)
        if prev then
            b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -CHOICE_GAP)
        else
            b:SetPoint("TOPLEFT", ui.body, "BOTTOMLEFT", 0, -20)
        end
        ui.choices[i] = b
        prev = b
    end

    -- Footer: Back, progress, Continue.
    ui.back = UI.CreateFlatButton(f, "Back", FOOT_BTN_W, FOOT_BTN_H)
    ui.back:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 18)
    ui.back:SetScript("OnClick", function() ShowPage(page - 1) end)

    ui.next = UI.CreateFlatButton(f, "Continue", FOOT_BTN_W, FOOT_BTN_H)
    ui.next:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 18)
    ui.next:SetScript("OnClick", function()
        if page >= #pages then frame:Hide() else ShowPage(page + 1) end
    end)

    ui.bar = UI.Solid(f, "ARTWORK", 1, 1, 1, C.hairline[4])
    ui.bar:SetSize(BAR_W, 3)
    ui.bar:SetPoint("BOTTOM", f, "BOTTOM", 0, 24)
    ui.fill = UI.Solid(f, "OVERLAY", C.brand[1], C.brand[2], C.brand[3], 0.9)
    ui.fill:SetHeight(3)
    ui.fill:SetPoint("LEFT", ui.bar, "LEFT", 0, 0)

    ui.step = UI.Text(f, 10, C.faint)
    ui.step:SetPoint("BOTTOM", ui.bar, "TOP", 0, 5)
    ui.step:SetJustifyH("CENTER")

    f:SetScript("OnShow", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
    end)
    f:SetScript("OnHide", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
        MarkDone()
    end)
    return f
end

ShowPage = function(n)
    page = math.max(1, math.min(#pages, n or 1))
    local p = pages[page]
    ui.title:SetText(p.title)
    ui.body:SetText(p.text)
    local items = p.choices or p.items or {}
    for i, b in ipairs(ui.choices) do
        local item = items[i]
        b.item = item
        if item then
            b.label:SetText(item.label)
            b.blurb:SetText(item.blurb)
            b.selected = item.settings and Matches(item.settings) or false
            b.hover = false
            PaintChoice(b)
            b:Show()
        else
            b:Hide()
        end
    end
    ui.back:SetEnabled(page > 1)
    ui.next.label:SetText(page >= #pages and "Finish" or "Continue")
    ui.step:SetText(("Step %d of %d"):format(page, #pages))
    ui.fill:SetWidth(math.max(1, math.floor(BAR_W * page / #pages + 0.5)))
end

MarkDone = function()
    if not ns.db then return end
    local v = UI.AddonVersion()
    if type(v) ~= "string" or v == "" then v = "done" end
    if ns.db.setupDone ~= v then
        ns.db.setupDone = v
        ns.SaveSettings()
    end
end

function ns.OpenSetup()
    if not ns.db then return end
    local f = BuildFrame()
    ShowPage(1)
    f:Show()
end

-------------------------------------------------------------------------------
-- First login
-------------------------------------------------------------------------------

-- Wait for the settings to be final (the beta client's late restore can
-- take a while), then show the window once if nobody has finished it.
-- Never during combat; give up after 90 s and try again next login.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    local tries = 0
    local function check()
        if not ns.db or ns.db.setupDone then return end
        if not (ns.SettingsSettled and ns.SettingsSettled()) then
            tries = tries + 1
            if tries < 90 then C_Timer.After(1, check) end
            return
        end
        if InCombatLockdown() then
            C_Timer.After(5, check)
            return
        end
        ns.OpenSetup()
    end
    C_Timer.After(2, check)
end)
