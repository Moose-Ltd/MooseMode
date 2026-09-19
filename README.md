# MooseMode

A growing bag of quality-of-life tools for **World of Warcraft: Forever**. It covers junk selling, fast looting, quest accepting and hand-ins, repairs and a single combined bag window, and is built so new features can be dropped in as modules.

## Features

- **Minimap button.** A purple star on the minimap edge. Left-click opens the options panel, drag it to move it around the minimap.
- **Options panel.** Every module's settings as tick boxes. Settings are saved per account, so every character shares them.
- **Auto Sell.** Sells every grey item as soon as a vendor window opens and prints what it earned. Hold **Shift** while talking to a vendor to skip selling that visit. Keep and junk lists let you protect a grey item or force-sell a non-grey one.
- **Fast Loot.** Grabs everything from a corpse the moment the loot is ready.
- **Pet Attack.** Sends your pet at the target the moment you start casting a damage spell, so a Voidwalker is already running in while Corruption is still on the cast bar. Every pet command (attack, assist, stances) is protected on this client and cannot be called by an addon, so this works through macros: tick the option and MooseMode writes one macro per damage spell in your spellbook (`#showtooltip`, `/petattack`, `/cast`), and you drag those onto your bars in place of the spells. It never overwrites a macro it did not create, and turning the option off leaves the macros alone.
- **Action Bars.** Hides the macro name text under the icon on every action bar button, so a bar of pet-attack macros looks like a bar of spells. Untick to bring the names back.
- **Auto Quest.** Accepts quests automatically from quest givers, quest lists and gossip windows, hands in completed quests, and picks up the follow-ups that unlock. Low-level quests are skipped unless you tick the sub-option: a quest counts as low level when the client flags it trivial or its level is at or below your grey threshold, and a second sub-option extends that to anything below your level. The debug option logs each quest's level, your level and the grey threshold so you can see why a quest was skipped. If a hand-in offers more than one reward to choose from, the window stays open so you can pick. Also picks the gossip option for you when an NPC offers exactly one and no quests. Hold **Shift** while talking to an NPC to skip all of it.
- **Auto Repair.** Repairs all your gear as soon as a vendor that can repair opens, and prints the cost. Optionally pays from the guild bank when your rank allows it. Warns you if you cannot afford it. Hold **Shift** while talking to the vendor to skip.
- **One Bag.** Shows every bag as a single window, Bagnon/Baganator style. It switches on the client's own combined-bag mode rather than drawing its own bag frame, so clicking to use items, dragging, shift-linking, selling to vendors and using items in combat all keep working on Blizzard's secure item buttons, and the built-in Clean Up sort keeps working too. Optional sub-options run the sort automatically each time the bag opens, or make it pack items from the last slot. The setting is per account; the client-side switch is per character, so it is re-applied at every login to match.
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
| `/mm help` | List every subcommand |
| `/mm keep <item link>` | Never sell this item (toggle). Shift-click an item into the chat box to get a link. |
| `/mm junk <item link>` | Always sell this item, any quality (toggle) |
| `/mm list` | Show the keep and junk lists |
| `/mm reset` | Clear both lists |
| `/mm now` | Sell junk at the vendor that is currently open |
| `/mm repair` | Repair all gear at the vendor that is currently open, whatever the option says |
| `/mm cleanup` (or `/mm sort`) | Sort your bags now with Blizzard's cleanup |
| `/mm questdebug` | Toggle quest debug logging: every quest event, what the NPC offered and each decision, in chat |
| `/mm petmacros` | Build or refresh the pet-attack macros now, whatever the option says |
| `/mm petmacro <Spell Name>` | Build or refresh a single pet-attack macro for that spell, no damage-spell check |

## Options

| Module | Option | Default |
|---|---|---|
| Auto Sell | Sell grey items at vendors | on |
| Auto Sell | Show sale summary in chat | on |
| Auto Sell | Use Blizzard sell-all (ignores lists) | off |
| Fast Loot | Loot everything instantly | on |
| Pet Attack | Pet-attack macros for damage spells | off |
| Pet Attack | ↳ Only on pet classes (Hunter, Warlock) | on |
| Action Bars | Hide macro names on bars | on |
| Auto Quest | Accept quests | on |
| Auto Quest | ↳ Include low-level quests | off |
| Auto Quest | ↳ Also skip quests below my level (no effect while low-level quests are included) | off |
| Auto Quest | ↳ Complete quest hand-ins (reward windows with several choices stay open) | on |
| Auto Quest | Pick the only gossip option | on |
| Auto Quest | ↳ Debug log to chat | off |
| Auto Repair | Repair at vendors | on |
| Auto Repair | ↳ Use guild funds when allowed | off |
| Auto Repair | ↳ Show repair cost in chat | on |
| One Bag | Combine bags into one window | on |
| One Bag | ↳ Sort bags on open (at most once every 2 s, never in combat) | off |
| One Bag | ↳ Sort from the last slot | off |
| Beta Client | Hide Issue Reporter button | on |

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
    AutoQuest.lua       quest accepting, hand-ins and gossip automation
    AutoRepair.lua      gear repair at vendors
    OneBag.lua          combined bag window and bag cleanup
    BetaTweaks.lua      beta client fixes (hide the Issue Reporter)
```

### Adding a module

Create `Modules\YourThing.lua`, add it to the TOC, and register it:

```lua
local ADDON, ns = ...

ns:RegisterModule({
    key   = "yourThingModule",
    label = "Your Thing",                      -- header in the options panel
    options = {
        { key = "yourThing", label = "Do the thing", default = true,
          tooltip = "Shown on hover.", onChange = function(checked) end },
        { key = "yourThingExtra", label = "Do it harder", default = false,
          parent = "yourThing" },              -- sub-option: indented, greyed out while parent is off
    },
    OnInit   = function(mod) end,              -- ns.db exists here
    commands = { thing = function(rest) end }, -- /mm thing <rest>
})
```

Read settings with `ns.db.yourThing`. Helpers on `ns`: `Print`, `IsSecret`, `Coins`, `ItemIDFrom`, `ItemNameByID`.

## Notes on the Forever client

Forever (interface `16001`) runs the Retail 12.x UI code, not the Classic Era code. The old Classic globals such as `GetItemInfo` and `GetContainerItemInfo` do not exist, so the addon only uses the modern `C_Container`, `C_Item`, `C_CurrencyInfo`, `C_CVar` and `C_Timer` namespaces. The TOC also lists `120105`, so the same files load on Retail.

Item quality and sell price are not secret values on this client, but every read is guarded anyway so the addon fails quietly rather than throwing if that ever changes.
