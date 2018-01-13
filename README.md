# L4D Save Weapon
A Left 4 Dead (L4D1 only) SourceMod plugin that overcomes the original game's limit of saving more than four survivors' player states.

## Synopsis
This is the L4D1 version of [Merudo's Save Weapon 4.3](https://forums.alliedmods.net/showthread.php?p=2403402#post2403402) L4D2 plugin.

When playing a co-operative game with more than four survivors, you would be quick to realise that during chapter map transitions, the game only saves the player states for the first four survivors, while forgetting the states for any remaining survivors. This means survivors (besides the first four) will lose their current equipment and reset their health to 100 after chapter map transitions.

This SourceMod plugin rectifies that by allowing more than four survivors to retain their player states after chapter map changes, player/bot takeovers, and player re-joins. It saves (only in co-operative campaign game mode) survivors’ health, equipment, ammo, revive count, black & white status, survivor character, and survivor model.

**Note that this plugin alone does not add additional survivors.** [Merudo's Superversus 1.8.15.5](https://forums.alliedmods.net/showthread.php?p=2393931#post2393931) L4D(2) plugin has been tested and is recommended to be used with this plugin.

## Installation
This plugin requires at least SourceMod 1.7.

Put the plugin file `l4d-saveweapon.smx` into the server’s or game’s SourceMod plugins directory (usually `left4dead\addons\sourcemod\plugins\`).

Verify the plugin is running by typing into the server or game console `l4d_saveweapon`.

## Usage
The plugin automatically saves and loads player states during chapter map transitions in co-operative games.

### Cvars
- `l4d_saveweapon`: L4D Save Weapon version

## History
### Added or modified features to Merudo’s original plugin
- Saving and loading gas cans, oxygen tanks and propane tanks
- Remembering active weapons
- Giving primary weapons to resurrected survivors after chapter map transitions (depends on `survivor_respawn_with_guns` ConVar)
- Correctly restoring pistol(s) magazine ammo
- Correctly counting number of revives for incapacitated survivors during chapter map transitions
- Replaced several hard-coded constants with ConVar queries so the plugin will work with different ConVar values
### Removed features from Merudo's original plugin
- Left 4 Dead 2 specific features (for example, melee weapons and ammunition upgrades)
- Giving SMGs to survivors at the beginning of the campaign
- Saving player states at the end of the campaign and loading it on another campaign
- SourceMod admin commands to save and load player states

## FAQ
### Is there a Left 4 Dead 2 version?
The plugin was not developed for and will not work with Left 4 Dead 2. Use [Merudo's plugin](https://forums.alliedmods.net/showthread.php?p=2403402#post2403402) or [Mak’s plugin](https://forums.alliedmods.net/showthread.php?t=263860) instead.
### Which version of Metamod:Source and SourceMod are required?
The plugin was developed and tested with the newest versions of Metamod:Source and SourceMod at the time (1.10 - build 961 and 1.8 - build 6039 respectively), so assume they are the minimum recommended versions. The plugin uses the _SourcePawn Transitional Syntax_ which **requires at least SourceMod 1.7**.

## Credits
- Harry (RedAndBlueEraser) - _Author_
- Merudo - _Developer of fork of original L4D2 plugin in which this plugin is forked from_
- Electr000999 - _Developer of fork of original L4D2 plugin_
- maks - _Developer of original L4D2 plugin_
- AlliedModders forums for plenty of answers and for SourceMod Scripting API Reference
