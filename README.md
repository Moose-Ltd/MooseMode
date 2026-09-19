# MooseMode

A growing bag of quality-of-life tools for **World of Warcraft: Forever**. It covers junk selling, fast looting, quest accepting and hand-ins, repairs and a single combined bag window, and is built so new features can be dropped in as modules.

## Features

- **Minimap button.** A glossy purple orb with a white sparkle on the minimap edge, drawn from the addon's own icon file. Left-click opens the options panel, drag it to move it around the minimap. If your client draws the ring slightly off, `/mm icon <dx> <dy>` nudges the icon.
- **Options panel.** A centred dialog with every module's settings grouped under Vendors, Quests, Loot, Combat and Interface headings: tick boxes, segmented switches for either/or choices, and button rows for one-off actions. Sub-options indent under their parent and grey out while it is off. Settings are saved per account, so every character shares them.
- **Auto Sell.** Sells every grey item as soon as a vendor window opens and prints what it earned. It uses the game's own sell-all-junk for speed whenever your keep and junk lists are empty, and falls back to selling item by item when a list has entries (so they are honoured) or a vendor does not support sell-all. The chat summary always comes from the addon's own bag scan, so the count and gold figure are the same either way. Hold **Shift** while talking to a vendor to skip selling that visit. Keep and junk lists let you protect a grey item or force-sell a non-grey one.
- **Fast Loot.** Grabs everything from a corpse the moment the loot is ready. Optionally leaves grey items behind; money and quest items are always taken. While it is on it takes over the game's own auto-loot setting (otherwise the client would loot every slot before the grey rule could apply) and restores it when turned off. Hold the game's auto-loot modifier key (Shift by default) when loot opens to get the normal loot window instead.
- **Pet Attack.** Sends your pet at the target the moment you start casting a damage spell, so a Voidwalker is already running in while Corruption is still on the cast bar. Every pet command (attack, assist, stances) is protected on this client and cannot be called by an addon, so this works through macros: tick the option and MooseMode writes one macro per damage spell in your spellbook (`#showtooltip`, `/petattack`, `/cast`), and you drag those onto your bars in place of the spells. It never overwrites a macro it did not create, and turning the option off leaves the macros alone.
- **Action Bars.** Hides the macro name text under the icon on every action bar button, so a bar of pet-attack macros looks like a bar of spells. Untick to bring the names back.
- **Spell Ranks.** Forever has Vanilla-style spell ranks on the Retail client, so learning Demon Armor rank 3 leaves any button that holds rank 2 casting rank 2. This module swaps such buttons to the highest rank you know, out of combat, whenever you learn a spell and once at login, and reports each swap in chat. Name-based macros (`/cast Demon Armor`) already cast the top rank; this covers plain spell buttons dragged from the spellbook.
- **Auto Quest.** Accepts quests automatically from quest givers, quest lists and gossip windows, hands in completed quests, and picks up the follow-ups that unlock. Low-level quests are skipped by default; the **Skip when** switch decides how low is low: **Grey only** (the client flags the quest trivial, or its level is at or below your grey threshold) or **Green and grey** (anything the game colours as easy, using the client's own difficulty colour). Untick **Skip low-level quests** to accept everything. The debug option logs each quest's level, your level, the grey threshold, its colour and the threshold in use so you can see why a quest was skipped. If a hand-in offers more than one reward to choose from, the window stays open so you can pick. Also picks the gossip option for you when an NPC offers exactly one and no quests. Hold **Shift** while talking to an NPC to skip all of it.
- **Quest Rewards.** When a quest lets you choose a reward, each choice shows its vendor sell value in gold text on the button and the most valuable one gets a gold border (ties all get it). Works in the hand-in window and in the quest log and map details, since Blizzard draws them all through the same reward frame. Prices the client has not seen yet fill in a moment later.
- **Auto Repair.** Repairs all your gear as soon as a vendor that can repair opens, and prints the cost. Optionally pays from the guild bank when your rank allows it. Warns you if you cannot afford it. Hold **Shift** while talking to the vendor to skip.
- **One Bag.** Shows every bag as a single window, Bagnon/Baganator style. It switches on the client's own combined-bag mode rather than drawing its own bag frame, so clicking to use items, dragging, shift-linking, selling to vendors and using items in combat all keep working on Blizzard's secure item buttons, and the built-in Clean Up sort keeps working too. Optional sub-options run the sort automatically each time the bag opens, or make it pack items from the last slot. The setting is per account; the client-side switch is per character, so it is re-applied at every login to match.
- **Graphics.** An **Apply** button sets every graphics slider to its maximum (view distance, environment and ground detail, shadows, liquid, particles, spell density, SSAO, depth and compute effects, outlines, texture resolution and filtering, physics, lighting, glow, weather, MSAA and CMAA anti-aliasing, and the same for the raid profile) after snapshotting what you had, and **Restore** puts that snapshot back exactly. Anti-aliasing and texture resolution only take effect after restarting the game; the addon says so when they change. View distance and shadows are the two heaviest on frame rate, so lower those in the game's settings if it stutters. A tick re-applies the preset every login. Separate ticks push the camera zoom-out past the settings slider (per character, re-applied at login) and nudge contrast up for more vivid colours.
- **Beta Client.** Hides the floating "Issue Reporter" widget (the blue beetle button) that the beta client parks on screen. Bug report and survey popups still work, and `/ptr` still opens the reporter. Does nothing on a client that has no issue reporter.

## Install

The addon lives in the `MooseMode` folder. It needs to end up at:

```
C:\Games\World of Warcraft\_classic_beta_\Interface\AddOns\MooseMode
```

Run `install.ps1` from this folder to link it there (a directory junction, so edits in this repo show up in-game after `/reload`). Pass `-Copy` to copy the files instead of linking, or `-Path` to point at a different WoW install.

```powershell
.\install.ps1
.\install.ps1 -Copy
.\install.ps1 -Path "D:\World of Warcraft\_classic_beta_"
```

Then start the game, click **AddOns** on the character select screen and make sure MooseMode is ticked.

## Commands

`/moosemode` or `/mm`

| Command | What it does |
|---|---|
| `/mm` | Open or close the options panel |
| `/mm minimap` | Hide or show the minimap button |
| `/mm icon <dx> <dy>` | Nudge the minimap icon inside its ring (`/mm icon reset` to centre it again) |
| `/mm help` | List every subcommand |
| `/mm keep <item link>` | Never sell this item (toggle). Shift-click an item into the chat box to get a link. |
| `/mm junk <item link>` | Always sell this item, any quality (toggle) |
| `/mm list` | Show the keep and junk lists |
| `/mm reset` | Clear both lists |
| `/mm now` | Sell junk at the vendor that is currently open |
| `/mm repair` | Repair all gear at the vendor that is currently open, whatever the option says |
| `/mm cleanup` (or `/mm sort`) | Sort your bags now with Blizzard's cleanup |
| `/mm ultra` | Apply the ultra graphics preset now |
| `/mm ultra restore` | Put back the graphics settings saved before the preset was applied |
| `/mm questdebug` | Toggle quest debug logging: every quest event, what the NPC offered and each decision, in chat |
| `/mm petmacros` | Build or refresh the pet-attack macros now, whatever the option says |
| `/mm petmacro <Spell Name>` | Build or refresh a single pet-attack macro for that spell, no damage-spell check |
| `/mm ranks` | Check every spell button now and move any old rank to the highest you know, with a summary |

## Options

The dialog groups sections under five headings, in this order. `↳` marks a sub-option (indented, greyed out while its parent is off); `↳↳` a sub-option's sub-option.

| Group | Module | Option | Default |
|---|---|---|---|
| Vendors | Auto Sell | Sell grey items at vendors | on |
| Vendors | Auto Sell | ↳ Show sale summary in chat | on |
| Vendors | Auto Repair | Repair at vendors | on |
| Vendors | Auto Repair | ↳ Use guild funds when allowed | off |
| Vendors | Auto Repair | ↳ Show repair cost in chat | on |
| Quests | Auto Quest | Accept quests | on |
| Quests | Auto Quest | ↳ Skip low-level quests | on |
| Quests | Auto Quest | ↳↳ Skip when: **Grey only** / Green and grey (switch) | Grey only |
| Quests | Auto Quest | ↳ Complete quest hand-ins (reward windows with several choices stay open) | on |
| Quests | Auto Quest | Pick the only gossip option | on |
| Quests | Auto Quest | ↳ Debug log to chat | off |
| Quests | Quest Rewards | Show vendor value on rewards | on |
| Quests | Quest Rewards | ↳ Highlight the most valuable | on |
| Loot | Fast Loot | Loot everything instantly | on |
| Loot | Fast Loot | ↳ Leave grey items | off |
| Combat | Pet Attack | Pet-attack macros for damage spells | off |
| Combat | Pet Attack | ↳ Only on pet classes (Hunter, Warlock) | on |
| Combat | Spell Ranks | Keep bars on highest spell rank | on |
| Combat | Spell Ranks | ↳ Report swaps in chat | on |
| Interface | One Bag | Combine bags into one window | on |
| Interface | One Bag | ↳ Sort bags on open (at most once every 2 s, never in combat) | off |
| Interface | One Bag | ↳ Sort from the last slot | off |
| Interface | Action Bars | Hide macro names on bars | on |
| Interface | Graphics | Ultra graphics preset (Apply / Restore buttons) | – |
| Interface | Graphics | Re-apply ultra at login | off |
| Interface | Graphics | Max camera zoom distance | on |
| Interface | Graphics | Vivid colours | off |
| Interface | Beta Client | Hide Issue Reporter button | on |

## Layout

```
MooseMode/
  MooseMode.toc
  Core.lua              module registry, saved variables, minimap button, options panel, /mm
  Modules/
    AutoSell.lua        vendor junk selling
    FastLoot.lua        fast corpse looting
    PetAttack.lua       /petattack macros for damage spells
    ActionBars.lua      hide macro names on action bar buttons
    SpellRanks.lua      keep spell buttons on the highest known rank
    AutoQuest.lua       quest accepting, hand-ins and gossip automation
    QuestRewards.lua    vendor value and best-choice highlight on quest rewards
    AutoRepair.lua      gear repair at vendors
    OneBag.lua          combined bag window and bag cleanup
    Graphics.lua        ultra graphics preset, camera zoom, vivid colours
    BetaTweaks.lua      beta client fixes (hide the Issue Reporter)
  media/
    icon.tga            minimap icon (generated, do not hand-edit)
tools/
  make_icon.js          renders media/icon.tga and two PNG previews; run `node tools/make_icon.js`
```

### Adding a module

Create `Modules\YourThing.lua`, add it to the TOC, and register it:

```lua
local ADDON, ns = ...

ns:RegisterModule({
    key   = "yourThingModule",
    label = "Your Thing",                      -- section header in the options dialog
    group = "Interface",                       -- heading it sits under: Vendors, Quests, Loot, Combat, Interface
    options = {
        { key = "yourThing", label = "Do the thing", default = true,
          tooltip = "Shown on hover.", onChange = function(checked) end },
        { key = "yourThingExtra", label = "Do it harder", default = false,
          parent = "yourThing" },              -- sub-option: indented, greyed out while parent is off
        { type = "choice", key = "yourThingMode", label = "Mode", default = "fast",
          values = { { value = "fast", text = "Fast" }, { value = "safe", text = "Safe" } },
          parent = "yourThing",                -- sub-options can nest; parent may itself be a sub-option
          tooltip = "A segmented switch; ns.db.yourThingMode holds the value." },
        { type = "button", label = "Do it once", buttonText = "Go",
          tooltip = "One-off action, nothing saved.", onClick = function() end },
    },
    OnInit   = function(mod) end,              -- ns.db exists here
    commands = { thing = function(rest) end }, -- /mm thing <rest>
})
```

Read settings with `ns.db.yourThing`. Helpers on `ns`: `Print`, `IsSecret`, `Coins`, `ItemIDFrom`, `ItemNameByID`.

## Notes on the Forever client

Forever (interface `16001`) runs the Retail 12.x UI code, not the Classic Era code. The old Classic globals such as `GetItemInfo` and `GetContainerItemInfo` do not exist, so the addon only uses the modern `C_Container`, `C_Item`, `C_CurrencyInfo`, `C_CVar` and `C_Timer` namespaces. The TOC also lists `120105`, so the same files load on Retail.

Item quality and sell price are not secret values on this client, but every read is guarded anyway so the addon fails quietly rather than throwing if that ever changes.
