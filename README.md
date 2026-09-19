# MooseMode

A growing bag of quality-of-life tools for **World of Warcraft: Forever**. It starts with automatic junk selling and fast looting, and is built so new features can be dropped in as modules.

## Features

- **Minimap button.** A purple star on the minimap edge. Left-click opens the options panel, drag it to move it around the minimap.
- **Options panel.** Every module's settings as tick boxes. Settings are saved per account, so every character shares them.
- **Auto Sell.** Sells every grey item as soon as a vendor window opens and prints what it earned. Hold **Shift** while talking to a vendor to skip selling that visit. Keep and junk lists let you protect a grey item or force-sell a non-grey one.
- **Fast Loot.** Grabs everything from a corpse the moment the loot is ready.

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

## Options

| Module | Option | Default |
|---|---|---|
| Auto Sell | Auto sell junk at vendors | on |
| Auto Sell | Show sale summary in chat | on |
| Auto Sell | Use Blizzard's sell-all-junk (ignores keep/junk lists) | off |
| Fast Loot | Fast loot corpses | on |

## Layout

```
MooseMode/
  MooseMode.toc
  Core.lua              module registry, saved variables, minimap button, options panel, /mm
  Modules/
    AutoSell.lua        vendor junk selling
    FastLoot.lua        fast corpse looting
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
    },
    OnInit   = function(mod) end,              -- ns.db exists here
    commands = { thing = function(rest) end }, -- /mm thing <rest>
})
```

Read settings with `ns.db.yourThing`. Helpers on `ns`: `Print`, `IsSecret`, `Coins`, `ItemIDFrom`, `ItemNameByID`.

## Notes on the Forever client

Forever (interface `16001`) runs the Retail 12.x UI code, not the Classic Era code. The old Classic globals such as `GetItemInfo` and `GetContainerItemInfo` do not exist, so the addon only uses the modern `C_Container`, `C_Item`, `C_CurrencyInfo` and `C_Timer` namespaces. The TOC also lists `120105`, so the same files load on Retail.

Item quality and sell price are not secret values on this client, but every read is guarded anyway so the addon fails quietly rather than throwing if that ever changes.
