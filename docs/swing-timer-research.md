# Swing timer research (Swing Timer module)

Notes behind `MooseMode/Modules/SwingTimer.lua`. Gathered September 2026.

## What the client offers

- **Native swing API.** The Forever client (1.60.1, build 69893) ships `C_SwingTimer`, the `PLAYER_SWING` event and Blizzard's own swing bar (`Blizzard_SwingTimer`, shown with `/console showSwingTimer 1` and placed in Edit Mode).
  - `PLAYER_SWING(swingDuration, swingType)` fires when the player swings. `swingType` is `Enum.PlayerSwingType`: MainHand = 0, OffHand = 1, Ranged = 2.
  - Blizzard's bar sets `endTime = GetTime() + swingDuration` on each event and clears itself when that time passes. It never invents a swing.
  - `C_SwingTimer.IsTargetWithinSwingRange(swingType)` returns true, false or nil. Nil means unknown, not out of range. `C_SwingTimer.EnableRangeCheck(swingType, on)` makes the client send `PLAYER_SWING_RANGE_UPDATE`. MooseMode only polls; it does not enable range checks, because that setting is shared with Blizzard's bar.
  - Blizzard's bar also listens to `WEAPON_SLOT_CHANGED`, `UNIT_ATTACK_SPEED` and `PLAYER_IN_COMBAT_CHANGED`.
  - Off-hand detection is the same as Blizzard's: the second return of `UnitAttackSpeed("player")` is non-nil and greater than 0.
- **The combat log is closed.** On 12.x-API clients (Midnight retail and Forever), registering `COMBAT_LOG_EVENT` or `COMBAT_LOG_EVENT_UNFILTERED` raises an error: both events are flagged `HasRestrictions` in the API docs. `CombatLogGetCurrentEventInfo` has moved to `C_CombatLogSecure` and `C_CombatLogInternal`, which addons cannot use. `COMBAT_LOG_MESSAGE` only delivers preformatted, `|K`-protected strings. `C_CombatLog.IsCombatLogRestricted()` exists.
- **`UNIT_COMBAT(unit, event, flagText, amount, schoolMask)`** still exists. With `unit == "player"` and `event == "PARRY"`, the player has just parried. Its values can be secret in restricted content, so check them before comparing.
- **Other helpers.** `UnitAttackSpeed` (flagged `SecretWhenUnitStatsRestricted`), `UNIT_SPELLCAST_START`, `UNIT_SPELLCAST_SUCCEEDED`, `UNIT_SPELLCAST_STOP`, `UNIT_SPELLCAST_FAILED` and `UNIT_SPELLCAST_INTERRUPTED` for the player, and `GetShapeshiftFormID` (Cat = 1, Bear = 5, Dire Bear = 8).

## How the Classic addons do it (LibClassicSwingTimerAPI, WeakAuras, WeaponSwingTimer)

- **Swings.** The Classic addons read `SWING_DAMAGE` and `SWING_MISSED` from `COMBAT_LOG_EVENT_UNFILTERED`, with the player as source. The `isOffHand` flag chooses the hand: it is argument 21 for `SWING_DAMAGE` and 13 for `SWING_MISSED`. Misses, dodges and parries count as swings.
- **Parry haste.** When the player parries, the main-hand end time moves 40% of weapon speed earlier, but never below 20% of speed remaining.
- **Haste changes.** On `UNIT_ATTACK_SPEED`, the remaining time is multiplied by `newSpeed / oldSpeed`.
- **Weapon swap.** A change to slots 16, 17 or 18 (`PLAYER_EQUIPMENT_CHANGED`) resets that hand.
- **Next-melee abilities.** Heroic Strike, Cleave, Raptor Strike and Maul replace the next white swing. They reach the combat log as spell events (`SPELL_CAST_SUCCESS`, `SPELL_DAMAGE`, `SPELL_MISSED`) rather than `SWING_*` events, so the addons treat them as a main-hand swing.
- **Casts.** Casting a spell with a cast time resets the swing timer when the cast finishes (Classic Era rule; the library keeps a reset list). The library pauses the swing during Slam from Wrath onwards; in Classic Era, Slam simply resets the swing when it lands.
- **Seal of Command.** Its procs are separate spell hits, not swings, so they must not reset the timer. The library also blocks attack-speed rescales briefly around druid form changes and Seal of the Crusader.
- **First off-hand swing.** On the first swing of combat, the off-hand starts half a swing behind the main hand.

## Choice for MooseMode

1. **Primary: `PLAYER_SWING`.** It is authoritative, and the server already covers misses, dodges, parries, extra attacks and the dual-wield offset. Everything is guarded: registration is wrapped in `pcall`, and secret payloads are refused rather than compared.
2. **Local corrections between swings.** These only matter until the next real event:
   - rescale on `UNIT_ATTACK_SPEED`
   - reset on a weapon swap
   - parry haste from `UNIT_COMBAT` PARRY
   - reset when a cast-time spell completes (including Slam)
   - Heroic Strike, Cleave, Raptor Strike and Maul from `UNIT_SPELLCAST_SUCCEEDED`, applied only when no native main-hand swing arrives within about 0.25 s. This avoids a double reset if the client already reports the swing.
   - Seal of Command is never treated as a swing.
3. **Fallback: `COMBAT_LOG_EVENT_UNFILTERED`.** Used only when `PLAYER_SWING` is missing, and only if registering it succeeds and `CombatLogGetCurrentEventInfo` exists. It follows the Classic rules above.
4. **Neither available.** The module says so once and shows nothing. It does not guess from `UNIT_COMBAT` damage on the target, which cannot tell who dealt it.

## Sources

- Gethe/wow-ui-source, forever branch at 4d5d706b: `SwingTimerDocumentation.lua`, `Blizzard_SwingTimer.lua`, `CombatLogDocumentation.lua`, `CombatLogSecureDocumentation.lua`, `UnitDocumentation.lua`
- ForeverSwing (tomqwu/wow_forever_addon_swingtimer, commit 88162e7 and later): the first third-party use of `PLAYER_SWING` on Forever
- Ralgathor/LibClassicSwingTimerAPI (parry haste, rescale, next-melee and reset lists)
- warcraft.wiki.gg: Patch 12.0.0/API changes, COMBAT_LOG_EVENT, COMBAT_LOG_MESSAGE
