# Settings dialog: UI research notes

Notes behind the redesigned MooseMode settings dialog (1.3 cycle). The dialog
has to run on WoW: Forever (interface 16001), which uses the Retail 12.x API.

## What well-regarded addon settings UIs do

- **Plumber's control centre** (`Modules/ControlCenter/SettingsPanelNew.lua`)
  uses three columns: a left rail with a search box and a category list, a
  centre list of features (one row per feature: toggle, name, a gear button
  that only appears while the feature is on), and a right pane with a preview
  and description for the hovered row. Search is debounced (0.2 s), shows
  a match count on each category, and fades categories that have no matches.
  Sub-settings stay out of sight until the feature is on. Hover highlights
  fade in, and every toggle plays the checkbox on/off sound.
- **Leatrix Plus**: every feature is one plain toggle. Detail goes in the
  tooltip or in a separate settings panel for that feature, so the main page
  can be scanned quickly.
- **AceConfig-3.0** (the model most Ace addons follow): a tree, tab or select
  group for navigation. Each option has `desc` (shown as a tooltip),
  `hidden` / `disabled` (either a value or a function), and `order`. Hidden
  options stay available from the command line. This dialog borrows
  `hidden` as a function, plus the rule that help text belongs in a tooltip
  and not on the page.
- **Blizzard's Settings panel** (10.0+, `Settings.RegisterCanvasLayoutCategory`
  / `Settings.RegisterAddOnCategory`): a category list on the left and a
  vertical list of label and control rows on the right. Descriptions appear
  on hover. Addons with their own window usually register a small canvas
  page that opens it.
- **ElvUI, WeakAuras, Details!**: a sidebar tree, a fixed-size window with a
  scrolling content area, and grouping by feature and not by widget type.

## Principles applied

1. **Navigate, then scan.** A sidebar splits the settings by group (Vendors,
   Quests, Loot, Combat, Interface). Only one group is on screen at a time.
2. **One card per feature, collapsed by default.** The card header carries
   the feature's icon, name, a one-line summary and its master switch, so a
   collapsed card can still be used. A chevron opens the finer settings.
   Each card remembers whether it is open (`ns.db.uiExpanded`).
3. **Progressive disclosure.** Sub-options sit indented under their parent
   with a tree guide line, and are greyed out until the parent is on.
4. **Help on hover, not on the page.** Explanations and notes appear in a
   tooltip placed beside the window, level with the row being hovered, so
   the tooltip never covers the controls.
5. **Show what applies to this character.** Modules and options can declare
   `classes = { "HUNTER", ... }`. Anything for other classes is hidden unless
   "Other classes" is turned on in the sidebar. Settings are account-wide,
   so this switch lets you set things up for your alts.
6. **Search across everything.** Search checks labels, tooltips and
   summaries in every group. Results are grouped under group headings, each
   sidebar entry shows its match count, and parent rows are kept so every
   result has context.
7. **Fixed window size with smooth scrolling.** The window is a fixed size
   (clamped to 85% of the screen height), can be dragged, remembers its
   position, and closes on ESC (`UISpecialFrames`).
8. **Consistent visuals.** Spacing uses a 4/8 px grid. Type sizes are
   17/15/13/12/11/10. There is one accent colour (MooseMode purple,
   #B04CFF), flat surfaces with 1 px hairlines, hover states on every
   interactive row, animated switches, and the Blizzard checkbox sounds.

## API notes (12.x client)

- `ScrollBox` / `WowScrollBoxList` / `CreateScrollBoxListLinearView` plus
  `MinimalScrollBar` with `ScrollUtil.InitScrollBoxListWithScrollBar` are the
  modern list widgets. They recycle frames from a data provider and suit
  long uniform lists. This dialog has fewer than 60 rows, cards of different
  heights, and rows that show and hide on search. A plain `ScrollFrame` with
  a hand-drawn thumb (drag and smooth wheel) is simpler and depends on no
  template.
- `MenuUtil.CreateRadioMenu`, `WowStyle1DropdownTemplate` and
  `dropdown:SetupMenu` are the 11.0+ dropdown APIs. Two-value choices stay
  a segmented switch, which needs one click instead of two. A dropdown only
  pays off above three or four values.
- `Settings.RegisterCanvasLayoutCategory` and `Settings.RegisterAddOnCategory`
  register a stub page on the AddOns tab that opens the dialog. Both calls
  are guarded and wrapped in `pcall`.
- Textures: `SetColorTexture` for every surface, `CreateMaskTexture` with
  `TempPortraitAlphaMask` for the rounded switch caps and knob (guarded;
  square fallback), and `SetTexCoord` with 8 arguments to rotate the chevron.
  The rotation needs no `SetRotation`.
- Frame-level details: `EditBox` with `SetAutoFocus(false)`, so the search
  box never takes the keyboard by itself. `SetHitRectInsets` enlarges small
  targets. `GameTooltip:SetOwner(owner, "ANCHOR_NONE")` plus `SetPoint`
  places the tooltip beside the window.

## Sources

- Plumber source: https://github.com/Peterodox/Plumber (`Modules/ControlCenter/SettingsPanelNew.lua`)
- AceConfig-3.0 options tables: https://www.wowace.com/projects/ace3/pages/ace-config-3-0-options-tables
- Settings API: https://warcraft.wiki.gg/wiki/Settings_API
- Scroll frames and ScrollBox: https://warcraft.wiki.gg/wiki/Making_scrollable_frames
- Menu API guide: https://warcraft.wiki.gg/wiki/Blizzard_Menu_implementation_guide
- Leatrix Plus: https://www.curseforge.com/wow/addons/leatrix-plus
