/*
 * L4D1 Save Weapon (l4d_saveweapon.sp)
 *
 * L4D1 version of Merudo's Save Weapon 4.3 L4D2 mod.
 *
 * Allows more than four survivors to retain their player states after chapter
 * map changes, player/bot takeovers, and player rejoins. The original game
 * only saves the player states for the first four survivors, forgetting the
 * states for any remaining survivors.
 *
 * This mod saves survivors' health, equipment, ammo, revive count, black &
 * white status, survivor character, and survivor model only in co-operative
 * campaign.
 *
 * Removed features from Merudo's original mod include L4D2 specific features,
 * giving SMGs to players at the start of the campaign, saving after the
 * campaign ends or changes, and SourceMod admin commands.
 *
 * Additions and changes to the original mod include correctly restoring
 * pistol(s) magazine ammo, correctly reviving incapacitated survivors inside
 * the safe room, replacing a few hard-coded constants with Cvar queries, and
 * giving gas cans, oxygen tanks and propane tanks.
 *
 * Version 20171218 (4.3-alpha1)
 * Originally written by MAKS, Electr0 and Merudo
 * Fork written by Harry Wong (RedAndBlueEraser)
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "4.3"

#define TEAM_SURVIVORS 2
char SURVIVOR_NAMES[][] = { "Bill", "Zoey", "Francis", "Louis" };

bool isSavable = false;
bool botsCanAppropriate = true;
bool isMapTransition = false;

enum weaps1
{
	slot0MagazineAmmo,
	slot0ReserveAmmo,
	slot1IsDualWield,
	slot1MagazineAmmo,
	health,
	healthTemp,
	healthTempTime,
	reviveCount,
	isGoingToDie,
	survivorCharacter,
	isActive,
	isLoaded
};
int weapons1[MAXPLAYERS + 1][weaps1];
enum weaps2
{
	slot0,
	slot1,
	slot2,
	slot3,
	slot4,
	slot5,
	survivorModel
};
char weapons2[MAXPLAYERS + 1][weaps2][64];

public Plugin myinfo =
{
	name = "L4D Save Weapon",
	author = "MAKS, Electr0, Merudo, RedAndBlueEraser",
	description = "Save beyond 4 survivors' player states",
	version = PLUGIN_VERSION,
	url = ""
}

public void OnPluginStart()
{
	CreateConVar("l4d_saveweapon", PLUGIN_VERSION, "L4D Save Weapon version", FCVAR_NOTIFY);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_bot_replace", Event_PlayerBotReplace);
	HookEvent("bot_player_replace", Event_BotPlayerReplace);
}

public void OnMapStart()
{
	// Player states should be saved only in co-operative campaign mode.
	char gameMode[16];
	FindConVar("mp_gamemode").GetString(gameMode, sizeof(gameMode));
	isSavable = StrEqual(gameMode, "coop", false);

	/* Delete player states when starting a new campaign or not in co-operative
	 * campaign mode.
	 */
	if (!isSavable || !isMapTransition) DeleteAllPlayerStates();

	/* Reset flag in order to indicate any map changes between map start and
	 * map transition should delete saved player states.
	 */
	isMapTransition = false;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	/* Reset player states' loaded status when a new round begins. (isLoaded is
	 * 1 if already loaded in current round).
	 */
	for (int client = 1; client <= MaxClients; client++) weapons1[client][isLoaded] = 0;
	botsCanAppropriate = true;
}

public Action Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	// Save player states during a map transition (after reaching a safe room).
	DeleteAllPlayerStates();
	SaveAllPlayerStates();

	/* Set flag in order to indicate that the next map change in map start
	 * should not delete saved player states.
	 */
	isMapTransition = true;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	// Load player state when a player spawns (with a small delay).
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client != 0) CreateTimer(0.1, Timer_LoadPlayerState, client, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LoadPlayerState(Handle handle, int client)
{
	// If the client isn't connected, or isn't a survivor, do nothing.
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVORS || !isSavable) return;

	// Allow bots to appropriate another player state.
	if (botsCanAppropriate) CreateTimer(10.0, Timer_StopAppropriate, TIMER_FLAG_NO_MAPCHANGE);

	/* If a player state for a bot doesn't exist, have the bot appropriate and
	 * load a state that has been abandoned (for example, from players
	 * disconnecting between map changes, bots being autokicked at the end of
	 * the map, etc).
	 */
	if (!weapons1[client][isLoaded] && !weapons1[client][isActive] && IsFakeClient(client) && botsCanAppropriate)
	{
		for (int client2 = 1; client2 <= MaxClients; client2++)
		{
			if (weapons1[client2][isActive] && !IsClientConnected(client2))
			{
				TransferPlayerState(client2, client);
				break;
			}
		}
	}

	// If the player state has not been loaded in this round, load it.
	if (weapons1[client][isActive] && !weapons1[client][isLoaded]) LoadPlayerState(client);
}

/* Disable bot appropriation to prevent idle bots from loading a different
 * player state.
 */
public Action Timer_StopAppropriate(Handle handle, int client)
{
	botsCanAppropriate = false;
}

// Transfer a bot's player state to the replacing player.
public Action Event_BotPlayerReplace(Handle event, char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(GetEventInt(event, "player"));
	int bot = GetClientOfUserId(GetEventInt(event, "bot"));

	/* Do nothing if a bot replaces another bot (by-product of creating
	 * survivor bots).
	 */
	if (IsFakeClient(player)) return;

	if (GetClientTeam(player) == TEAM_SURVIVORS) TransferPlayerState(bot, player);
}

// Transfer a player's player state to the replacing bot.
public Action Event_PlayerBotReplace(Handle event, char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(GetEventInt(event, "player"));
	int bot = GetClientOfUserId(GetEventInt(event, "bot"));

	/* Do nothing if a bot replaces another bot (by-product of creating
	 * survivor bots).
	 */
	if (IsFakeClient(player)) return;

	if (GetClientTeam(bot) == TEAM_SURVIVORS) TransferPlayerState(player, bot);
}

// Transfer a survivor's player state to another survivor.
void TransferPlayerState(int srcClient, int destClient)
{
	for (int i = 0; i < sizeof(weapons1[]) ; i++) weapons1[destClient][i] = weapons1[srcClient][i];
	for (int i = 0; i < sizeof(weapons2[]) ; i++) strcopy(weapons2[destClient][i], sizeof(weapons2[][]), weapons2[srcClient][i]);
	DeletePlayerState(srcClient);
}

// Save a survivor's player state.
void SavePlayerState(int client)
{
	DeletePlayerState(client);
	weapons1[client][isActive] = 1;

	weapons1[client][survivorCharacter] = GetEntProp(client, Prop_Send, "m_survivorCharacter");
	GetClientModel(client, weapons2[client][survivorModel], sizeof(weapons2[][]));

	// Resurrect dead survivors.
	if (!IsPlayerAlive(client))
	{
		weapons1[client][health] = FindConVar("z_survivor_respawn_health").IntValue;
		return;
	}

	// Save equipment.
	int item;
	item = GetPlayerWeaponSlot(client, 0);
	if (item > -1)
	{
		GetEdictClassname(item, weapons2[client][slot0], sizeof(weapons2[][]));
		weapons1[client][slot0MagazineAmmo] = GetEntProp(item, Prop_Send, "m_iClip1");
		weapons1[client][slot0ReserveAmmo] = GetPlayerAmmo(client, item);
	}
	item = GetPlayerWeaponSlot(client, 1);
	if (item > -1)
	{
		GetEdictClassname(item, weapons2[client][slot1], sizeof(weapons2[][]));
		if (GetEntProp(item, Prop_Send, "m_hasDualWeapons")) weapons1[client][slot1IsDualWield] = 1;
		weapons1[client][slot1MagazineAmmo] = GetEntProp(item, Prop_Send, "m_iClip1");
	}
	item = GetPlayerWeaponSlot(client, 2);
	if (item > -1) GetEdictClassname(item, weapons2[client][slot2], sizeof(weapons2[][]));
	item = GetPlayerWeaponSlot(client, 3);
	if (item > -1) GetEdictClassname(item, weapons2[client][slot3], sizeof(weapons2[][]));
	item = GetPlayerWeaponSlot(client, 4);
	if (item > -1) GetEdictClassname(item, weapons2[client][slot4], sizeof(weapons2[][]));
	item = GetPlayerWeaponSlot(client, 5);
	if (item > -1) GetEdictClassname(item, weapons2[client][slot5], sizeof(weapons2[][]));

	// Save health.
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
	{
		weapons1[client][health] = 1;
		weapons1[client][healthTemp] = FindConVar("survivor_revive_health").IntValue;
		weapons1[client][healthTempTime] = 0;
		weapons1[client][reviveCount] = GetEntProp(client, Prop_Send, "m_currentReviveCount") + 1;
		if (weapons1[client][reviveCount] >= FindConVar("survivor_max_incapacitated_count").IntValue) weapons1[client][isGoingToDie] = 1;
	}
	else
	{
		weapons1[client][health] = GetClientHealth(client);
		weapons1[client][healthTemp] = RoundToNearest(GetEntPropFloat(client, Prop_Send, "m_healthBuffer"));
		weapons1[client][healthTempTime] = RoundToNearest(GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime"));
		weapons1[client][reviveCount] = GetEntProp(client, Prop_Send, "m_currentReviveCount");
		weapons1[client][isGoingToDie] = GetEntProp(client, Prop_Send, "m_isGoingToDie");
	}
}

// Save all survivors' player states.
void SaveAllPlayerStates()
{
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVORS)
			SavePlayerState(client);
}

// Load a survivor's player state.
void LoadPlayerState(int client)
{
	weapons1[client][isLoaded] = 1;

	SetEntProp(client, Prop_Send, "m_survivorCharacter", weapons1[client][survivorCharacter]);
	SetEntityModel(client, weapons2[client][survivorModel]);

	// If the client is a bot, set the correct survivor name.
	if (IsFakeClient(client)) SetClientName(client, SURVIVOR_NAMES[weapons1[client][survivorCharacter]]);

	if (!IsPlayerAlive(client)) return;

	// Load equipment.
	if (weapons2[client][slot2][0] != '\0') GiveIfNotHasPlayerItemSlot(client, 2, weapons2[client][slot2]);
	if (weapons2[client][slot3][0] != '\0') GiveIfNotHasPlayerItemSlot(client, 3, weapons2[client][slot3]);
	if (weapons2[client][slot4][0] != '\0') GiveIfNotHasPlayerItemSlot(client, 4, weapons2[client][slot4]);
	// Load slot1 (secondary weapon, sidearm).
	int item = GiveIfNotHasPlayerItemSlot(client, 1, "weapon_pistol");
	if (item > -1)
	{
		if (weapons1[client][slot1IsDualWield]) SetEntProp(item, Prop_Send, "m_hasDualWeapons", 1);
		SetEntProp(item, Prop_Send, "m_iClip1", weapons1[client][slot1MagazineAmmo]);
	}
	/* Load slot0 (primary weapon). Loaded last so it's the one yielded if
	 * slot5 is empty.
	 */
	if (weapons2[client][slot0][0] != '\0')
	{
		item = GiveIfNotHasPlayerItemSlot(client, 0, weapons2[client][slot0]);
		if (item > -1)
		{
			SetEntProp(item, Prop_Send, "m_iClip1", weapons1[client][slot0MagazineAmmo]);
			SetPlayerAmmo(client, item, weapons1[client][slot0ReserveAmmo]);
		}
	}
	/* Load slot5 (carried gas can, oxygen tank, or propane tank). Loaded last
	 * so it's the one yielded.
	 */
	if (weapons2[client][slot5][0] != '\0') GiveIfNotHasPlayerItemSlot(client, 5, weapons2[client][slot5]);

	// Load health.
	SetEntProp(client, Prop_Send, "m_iHealth", weapons1[client][health]);
	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 1.0 * weapons1[client][healthTemp]);
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime() - 1.0 * weapons1[client][healthTempTime]);
	SetEntProp(client, Prop_Send, "m_currentReviveCount", weapons1[client][reviveCount]);
	SetEntProp(client, Prop_Send, "m_isGoingToDie", weapons1[client][isGoingToDie]);
}

// Delete a survivor's player state.
void DeletePlayerState(int client)
{
	weapons1[client][isActive] = 0;
	weapons1[client][isLoaded] = 0;
	weapons2[client][slot0][0] = '\0';
	weapons1[client][slot0MagazineAmmo] = 0;
	weapons1[client][slot0ReserveAmmo] = 0;
	weapons2[client][slot1][0] = '\0';
	weapons1[client][slot1IsDualWield] = 0;
	weapons1[client][slot1MagazineAmmo] = 0;
	weapons2[client][slot2][0] = '\0';
	weapons2[client][slot3][0] = '\0';
	weapons2[client][slot4][0] = '\0';
	weapons2[client][slot5][0] = '\0';
	weapons1[client][health] = 100;
	weapons1[client][healthTemp] = 0;
	weapons1[client][healthTempTime] = 0;
	weapons1[client][reviveCount] = 0;
	weapons1[client][isGoingToDie] = 0;
	weapons1[client][survivorCharacter] = -1;
	weapons2[client][survivorModel][0] = '\0';
}

// Delete all survivors' player states.
void DeleteAllPlayerStates()
{
	for (int i = 1; i <= MaxClients; i++) DeletePlayerState(i);
}

/* Give and equip a survivor with an item. */
int GivePlayerItem2(int client, const char[] item)
{
	int newItem = GivePlayerItem(client, item);
	if (newItem > -1) EquipPlayerWeapon(client, newItem);
	return newItem;
}

// Remove an item from a survivor.
void RemovePlayerItem2(int client, int item)
{
	if (RemovePlayerItem(client, item)) AcceptEntityInput(item, "Kill");
}

/* Give and equip a survivor with an item if they don't already have the item
 * in the specified slot, removing any mismatched item in the slot (if present).
 */
int GiveIfNotHasPlayerItemSlot(int client, int slot, const char[] item)
{
	int existingItem = GetPlayerWeaponSlot(client, slot);
	if (existingItem > -1)
	{
		char existingItemClassname[sizeof(weapons2[][])];
		GetEdictClassname(existingItem, existingItemClassname, sizeof(existingItemClassname));
		if (StrEqual(existingItemClassname, item)) return existingItem;
		else if (slot != 5) RemovePlayerItem2(client, existingItem);
		else RemoveEdict(existingItem);
	}
	return GivePlayerItem2(client, item);
}

// Get the reserve ammo carried for an item by a survivor.
int GetPlayerAmmo(int client, int item)
{
	return GetEntProp(client, Prop_Send, "m_iAmmo", _, GetEntProp(item, Prop_Send, "m_iPrimaryAmmoType"));
}

// Set the reserve ammo carried for an item by a survivor.
void SetPlayerAmmo(int client, int item, int amount)
{
	SetEntProp(client, Prop_Send, "m_iAmmo", amount, _, GetEntProp(item, Prop_Send, "m_iPrimaryAmmoType"));
}
