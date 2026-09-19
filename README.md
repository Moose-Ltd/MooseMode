# AutoLoot

A small addon for **World of Warcraft: Forever** that sells grey (junk) items automatically whenever you open a vendor, and loots corpses without the loot window delay.

## Features

- Sells every grey item in your bags as soon as a vendor window opens.
- Prints a one-line summary of what was sold and for how much.
- Hold **Shift** while talking to a vendor to skip selling for that visit.
- Keep list: mark an item so it is never sold, even if it is grey.
- Junk list: mark an item so it is always sold, whatever its quality.
- Fast loot: grabs everything from a corpse the moment the loot is ready.
- Stops cleanly if a vendor refuses to buy or the merchant window closes mid-sale.

## Install

The addon lives in the `AutoLoot` folder. It needs to end up at:

```
C:\Games\World of Warcraft\_classic_beta_\Interface\AddOns\AutoLoot
```

Run `install.ps1` from this folder to link it there (a directory junction, so edits in this repo show up in-game after `/reload`). Pass `-Copy` to copy the files instead of linking, or `-Path` to point at a different WoW install.

```powershell
.\install.ps1
.\install.ps1 -Copy
.\install.ps1 -Path "D:\World of Warcraft\_classic_beta_"
```

Then start the game, click **AddOns** on the character select screen and make sure AutoLoot is ticked.

## Commands

`/autoloot` or `/al`

| Command | What it does |
|---|---|
| `/al` | Show current settings |
| `/al sell` | Toggle auto-selling at vendors |
| `/al loot` | Toggle fast loot |
| `/al summary` | Toggle the chat summary line |
| `/al keep <item link>` | Never sell this item (toggle). Shift-click an item into the chat box to get a link. |
| `/al junk <item link>` | Always sell this item, any quality (toggle) |
| `/al list` | Show the keep and junk lists |
| `/al reset` | Clear both lists |
| `/al now` | Sell junk at the vendor that is currently open |
| `/al fast` | Use Blizzard's built-in sell-all-junk instead. Faster, but ignores the keep and junk lists. Off by default. |

## Notes on the Forever client

Forever (interface `16001`) runs the Retail 12.x UI code, not the Classic Era code. The old Classic globals such as `GetItemInfo` and `GetContainerItemInfo` do not exist, so the addon only uses the modern `C_Container`, `C_Item`, `C_CurrencyInfo` and `C_Timer` namespaces. The TOC also lists `120105`, so the same files load on Retail.

Item quality and sell price are not secret values on this client, but every read is guarded anyway so the addon fails quietly rather than throwing if that ever changes.
