# Changelog

## Unreleased

- One Bag: the tick is now a plain switch (ticked = combined, unticked = separate bags). It used to restore the character's earlier value on untick, which did nothing for a character that already had combined bags on.
- One Bag: unticking now takes effect (the game setting is re-applied after the settings restore) and the dialog says a reload is needed for the layout to change. Fast Loot and Graphics re-apply the same way.
- One Bag: the sort always packs from the top of the combined bag (the right-to-left sort, the direction that leaves no stray items on Forever); bags flagged "ignore when sorting" are un-flagged so the sort covers every bag.
- Grey Sort removed, and the "Sort from the last slot" tick with it: two sorters kept undoing each other. One Bag now runs the game's sort only.
- One Bag: sort-on-open never fires at a vendor or the bank, and runs at most once every 10 seconds.

## 1.2.0-forever

- Settings survive reloads and restarts on the beta: the backup is written to a registered console variable (restored on reload) and to account macros (restored on a cold start). A partial backup is never applied and unread backup slices are never deleted.
- Option actions run after the setting is saved, so a failing action cannot lose the click.
- Quest Lists no longer recolours Blizzard quest text. A "Skipped" line at the bottom of NPC windows names what Auto Quest left and why.
- Auto Quest classifies difficulty from level difference, matching the quest log; a quest exactly at the grey cutoff counts as green.
- Auto Sell is the game's sell-all only; keep and junk lists removed.
- Ultra graphics preset removed; max camera zoom and vivid colours remain.
- Custom minimap icon; grouped settings dialog with segmented switches, button rows and explainer notes; `/moose` alias.
- Grey Sort, Pet Attack, Spell Ranks, Quest Rewards, Quest Lists and Action Bars modules added since 1.1.0.

Fixes from the pre-release code review:

- Settings backup: the macro backup is never overwritten with defaults before a restore has been attempted with the macro list loaded; restores retry on UPDATE_MACROS, login and entering the world, and a change made before the restore is merged rather than lost. False option defaults are no longer written on every save.
- Fast Loot, One Bag, Graphics: the character's previous CVar value is remembered exactly when an option is enabled, so disabling it restores what the character had instead of a hardcoded default.
- Shared helpers in Core for CVars, safe event registration and the bag count, so every module counts bags the same way.
- Grey Sort: special containers (quiver, ammo pouch, soul bag, profession bags) are left out of the plan, and a swap the client refuses no longer counts or repeats; the pass stops after three refused swaps.
- Quest Rewards: item data the server refuses is not requested again, which removes a request loop while the reward window is open.
- Auto Quest: debug lines are built only when debug logging is on.
- Beta Client: removed an unobservable guard around hiding the Issue Reporter.
- Pet Attack: macro names are shortened on character boundaries (no split UTF-8), and two spells that shorten to the same name get distinct macros instead of overwriting each other.

## 1.1.0-forever

First public release for World of Warcraft: Forever (interface 16001).

### Vendors
- Auto Sell: every grey item is sold the moment a vendor opens, using the game's own sell-all. Optional chat summary with the gold earned.
- Auto Repair: repairs all gear at any repair vendor, with an option to use guild funds first and a cost line in chat.

### Quests
- Auto Quest: accepts quests from quest windows, greeting lists and gossip menus, hands in completed quests, picks up follow-ups, and picks the only gossip option when there is nothing else to choose. Low-level quests are skipped by default, with a grey-only or green-and-grey threshold. A debug log to chat explains each decision.
- Quest Rewards: each reward choice shows its vendor value, and the most valuable choice is framed in gold with a pulse while the others are dimmed.
- Quest Lists: a line at the bottom of NPC quest windows names anything Auto Quest left for you and why, including on the single-quest window.

### Loot
- Fast Loot: takes everything the instant loot is ready. Optional "leave grey items". Takes over the game's auto-loot setting while enabled.

### Combat
- Pet Attack: creates one macro per damage spell with /petattack in front, so a pet charges the moment a cast starts. Opt-in.
- Spell Ranks: swaps action bar buttons to the highest rank you know whenever you learn a new one.

### Interface
- One Bag: the client's combined bag window, with optional sort on open and reverse fill.
- Grey Sort: after a cleanup, greys are grouped next to the free slots, cheapest first.
- Action Bars: hides macro names under bar icons.
- Graphics: max camera zoom distance and a vivid-colours contrast tick.
- Beta Client: hides the beta Issue Reporter button.

### General
- Minimap button with a custom purple icon; left-click opens the settings dialog, drag to move, `/mm icon` to nudge.
- Settings dialog with grouped sections, sub-options, segmented switches and tooltips. Opens with `/mm`, `/moose` or `/moosemode`.
- Settings are account-wide. Because the Forever beta client does not yet load saved variables, non-default settings are also backed up in account macros named MMcfg1 and up, and restored from there at login. Do not delete those macros.
- Hold Shift while talking to an NPC or vendor to skip all automation once.
