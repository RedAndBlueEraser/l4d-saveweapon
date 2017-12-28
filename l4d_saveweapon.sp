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
 * the safe room, replacing a few hard-coded constants with Cvar queries,
 * giving gas cans, oxygen tanks and propane tanks, and remembering active
 * weapons.
 *
 * Version 20171224 (4.3-alpha2)
 * Originally written by MAKS, Electr0 and Merudo
 * Fork written by Harry Wong (RedAndBlueEraser)
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "4.3"

#define MAX_GAME_MODE_NAME_LEN 16
#define MAX_ENTITY_CLASSNAME_LEN 24
#define MAX_ENTITY_MODEL_NAME_LEN 40

#define TEAM_SURVIVORS 2
char SURVIVOR_NAMES[][] = { "Bill", "Zoey", "Francis", "Louis" };

bool arePlayerStatesSavable = false;
bool canBotsAppropriate = true;
bool hasMapTransitioned = false; // Whether a map transition has occurred before a map change.

bool isActive[MAXPLAYERS + 1]; // Whether the player state exists (that is, can be loaded from).
bool isLoaded[MAXPLAYERS + 1]; // Whether the player state has already been loaded.
enum Slot
{
	Slot_0, // Primary weapon.
	Slot_1, // Secondary weapon, sidearm. Usually only "weapon_pistol".
	Slot_2, // Grenade.
	Slot_3, // First aid kit.
	Slot_4, // Pain pills.
	Slot_5  // Carry item; gas cans, oxygen tanks, or propane tanks.
};
char slots[MAXPLAYERS + 1][Slot][MAX_ENTITY_CLASSNAME_LEN]; // Weapons.
int slot0MagazineAmmo[MAXPLAYERS + 1]; // Primary weapon magazine ammo.
int slot0ReserveAmmo[MAXPLAYERS + 1];  // Primary weapon reserve ammo.
int slot1MagazineAmmo[MAXPLAYERS + 1]; // Secondary weapon magazine ammo.
bool slot1IsDualWield[MAXPLAYERS + 1]; // Whether the survivor is dual wielding pistols.
int activeSlot[MAXPLAYERS + 1];        // Current weapon slot.
int health[MAXPLAYERS + 1];            // Permanent health.
float healthTemp[MAXPLAYERS + 1];      // Temporary health.
float healthTempTime[MAXPLAYERS + 1];  // Temporary health time.
int reviveCount[MAXPLAYERS + 1];       // Number of times revived since using a first aid kit.
bool isGoingToDie[MAXPLAYERS + 1];     // Whether the next incapacitation will kill the survivor.
int survivorCharacter[MAXPLAYERS + 1]; // Survivor character.
char survivorModel[MAXPLAYERS + 1][MAX_ENTITY_MODEL_NAME_LEN]; // Survivor model.

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
	char gameMode[MAX_GAME_MODE_NAME_LEN];
	FindConVar("mp_gamemode").GetString(gameMode, sizeof(gameMode));
	arePlayerStatesSavable = StrEqual(gameMode, "coop", false);

	/* Delete player states when starting a new campaign or not in co-operative
	 * campaign mode.
	 */
	if (!arePlayerStatesSavable || !hasMapTransitioned) DeleteAllPlayerStates();

	/* Reset flag in order to indicate any map changes between map start and
	 * map transition should delete saved player states.
	 */
	hasMapTransitioned = false;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	/* Reset player states' loaded status when a new round begins. (isLoaded is
	 * 1 if already loaded in current round).
	 */
	for (int client = 1; client <= MaxClients; client++) isLoaded[client] = false;
	canBotsAppropriate = true;
}

public Action Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	// Save player states during a map transition (after reaching a safe room).
	DeleteAllPlayerStates();
	SaveAllPlayerStates();

	/* Set flag in order to indicate that the next map change in map start
	 * should not delete saved player states.
	 */
	hasMapTransitioned = true;
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
	if (!arePlayerStatesSavable || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return;

	// Allow bots to appropriate another player state.
	if (canBotsAppropriate) CreateTimer(10.0, Timer_StopBotsAppropriate, TIMER_FLAG_NO_MAPCHANGE);

	/* If a player state for a bot doesn't exist, have the bot appropriate and
	 * load a state that has been abandoned (for example, from players
	 * disconnecting between map changes, bots being autokicked at the end of
	 * the map, etc).
	 */
	if (!isLoaded[client] && !isActive[client] && IsFakeClient(client) && canBotsAppropriate)
	{
		for (int client2 = 1; client2 <= MaxClients; client2++)
		{
			if (isActive[client2] && !IsClientConnected(client2))
			{
				TransferPlayerState(client2, client);
				break;
			}
		}
	}

	// If the player state has not been loaded in this round, load it.
	if (isActive[client] && !isLoaded[client]) LoadPlayerState(client);
}

/* Disable bot appropriation to prevent idle bots from loading a different
 * player state.
 */
public Action Timer_StopBotsAppropriate(Handle handle, int client)
{
	canBotsAppropriate = false;
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
	isActive[destClient] = isActive[srcClient];
	isLoaded[destClient] = isLoaded[srcClient];
	for (int slot = view_as<int>(Slot_0); slot <= view_as<int>(Slot_5); slot++)
		strcopy(slots[destClient][slot], sizeof(slots[][]), slots[srcClient][slot]);
	slot0MagazineAmmo[destClient] = slot0MagazineAmmo[srcClient];
	slot0ReserveAmmo[destClient] = slot0ReserveAmmo[srcClient];
	slot1MagazineAmmo[destClient] = slot1MagazineAmmo[srcClient];
	slot1IsDualWield[destClient] = slot1IsDualWield[srcClient];
	activeSlot[destClient] = activeSlot[srcClient];
	health[destClient] = health[srcClient];
	healthTemp[destClient] = healthTemp[srcClient];
	healthTempTime[destClient] = healthTempTime[srcClient];
	reviveCount[destClient] = reviveCount[srcClient];
	isGoingToDie[destClient] = isGoingToDie[srcClient];
	survivorCharacter[destClient] = survivorCharacter[srcClient];
	strcopy(survivorModel[destClient], sizeof(survivorModel[]), survivorModel[srcClient]);
	DeletePlayerState(srcClient);
}

// Save a survivor's player state.
void SavePlayerState(int client)
{
	DeletePlayerState(client);
	isActive[client] = true;

	survivorCharacter[client] = GetEntProp(client, Prop_Send, "m_survivorCharacter");
	GetClientModel(client, survivorModel[client], sizeof(survivorModel[]));

	// Resurrect dead survivors.
	if (!IsPlayerAlive(client))
	{
		health[client] = FindConVar("z_survivor_respawn_health").IntValue;
		return;
	}

	// Save equipment.
	int item;
	int activeItem = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

	item = GetPlayerWeaponSlot(client, view_as<int>(Slot_0));
	if (item > -1)
	{
		if (item == activeItem) activeSlot[client] = view_as<int>(Slot_0);
		GetEdictClassname(item, slots[client][Slot_0], sizeof(slots[][]));
		slot0MagazineAmmo[client] = GetEntProp(item, Prop_Send, "m_iClip1");
		slot0ReserveAmmo[client] = GetPlayerAmmo(client, item);
	}
	item = GetPlayerWeaponSlot(client, view_as<int>(Slot_1));
	if (item > -1)
	{
		if (item == activeItem) activeSlot[client] = view_as<int>(Slot_1);
		GetEdictClassname(item, slots[client][Slot_1], sizeof(slots[][]));
		slot1MagazineAmmo[client] = GetEntProp(item, Prop_Send, "m_iClip1");
		if (GetEntProp(item, Prop_Send, "m_hasDualWeapons")) slot1IsDualWield[client] = true;
	}
	for (int slot = view_as<int>(Slot_2); slot <= view_as<int>(Slot_5); slot++)
	{
		item = GetPlayerWeaponSlot(client, slot);
		if (item > -1)
		{
			if (item == activeItem) activeSlot[client] = slot;
			GetEdictClassname(item, slots[client][slot], sizeof(slots[][]));
		}
	}

	// Save health.
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
	{
		health[client] = 1;
		healthTemp[client] = FindConVar("survivor_revive_health").FloatValue;
		healthTempTime[client] = 0.0;
		reviveCount[client] = GetEntProp(client, Prop_Send, "m_currentReviveCount") + 1;
		if (reviveCount[client] >= FindConVar("survivor_max_incapacitated_count").IntValue)
			isGoingToDie[client] = true;
	}
	else
	{
		health[client] = GetClientHealth(client);
		healthTemp[client] = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
		healthTempTime[client] = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
		reviveCount[client] = GetEntProp(client, Prop_Send, "m_currentReviveCount");
		isGoingToDie[client] = GetEntProp(client, Prop_Send, "m_isGoingToDie") != 0;
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
	isLoaded[client] = true;

	SetEntProp(client, Prop_Send, "m_survivorCharacter", survivorCharacter[client]);
	SetEntityModel(client, survivorModel[client]);

	// If the client is a bot, set the correct survivor name.
	if (IsFakeClient(client)) SetClientName(client, SURVIVOR_NAMES[survivorCharacter[client]]);

	if (!IsPlayerAlive(client)) return;

	// Load equipment.
	for (int slot = view_as<int>(Slot_2); slot <= view_as<int>(Slot_4); slot++)
		if (slots[client][slot][0] != '\0')
			GiveIfNotHasPlayerItemSlot(client, slot, slots[client][slot]);
	// Load slot 1 (secondary weapon, sidearm).
	int item = GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_1), "weapon_pistol");
	if (item > -1)
	{
		SetEntProp(item, Prop_Send, "m_iClip1", slot1MagazineAmmo[client]);
		SetEntProp(item, Prop_Send, "m_hasDualWeapons", slot1IsDualWield[client] ? 1 : 0);
	}
	// Load slot 0 (primary weapon).
	if (slots[client][Slot_0][0] != '\0')
	{
		item = GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_0), slots[client][Slot_0]);
		if (item > -1)
		{
			SetEntProp(item, Prop_Send, "m_iClip1", slot0MagazineAmmo[client]);
			SetPlayerAmmo(client, item, slot0ReserveAmmo[client]);
		}
	}
	/* Load slot 5 (carried gas can, oxygen tank, or propane tank). Loaded last
	 * so it's the one yielded.
	 */
	if (slots[client][Slot_5][0] != '\0')
		GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_5), slots[client][Slot_5]);
	// Set active weapon, so it's the one yielded.
	if (activeSlot[client] > -1)
	{
		item = GetPlayerWeaponSlot(client, activeSlot[client]);
		if (item > -1) SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", item);
	}

	// Load health.
	SetEntProp(client, Prop_Send, "m_iHealth", health[client]);
	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", healthTemp[client]);
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime() - healthTempTime[client]);
	SetEntProp(client, Prop_Send, "m_currentReviveCount", reviveCount[client]);
	SetEntProp(client, Prop_Send, "m_isGoingToDie", isGoingToDie[client] ? 1 : 0);
}

// Delete a survivor's player state.
void DeletePlayerState(int client)
{
	isActive[client] = false;
	isLoaded[client] = false;
	for (int slot = view_as<int>(Slot_0); slot <= view_as<int>(Slot_5); slot++)
		slots[client][slot][0] = '\0';
	slot0MagazineAmmo[client] = 0;
	slot0ReserveAmmo[client] = 0;
	slot1MagazineAmmo[client] = 0;
	slot1IsDualWield[client] = false;
	activeSlot[client] = -1;
	health[client] = 100;
	healthTemp[client] = 0.0;
	healthTempTime[client] = 0.0;
	reviveCount[client] = 0;
	isGoingToDie[client] = false;
	survivorCharacter[client] = -1;
	survivorModel[client][0] = '\0';
}

// Delete all survivors' player states.
void DeleteAllPlayerStates()
{
	for (int client = 1; client <= MaxClients; client++) DeletePlayerState(client);
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
		char existingItemClassname[MAX_ENTITY_CLASSNAME_LEN];
		GetEdictClassname(existingItem, existingItemClassname, sizeof(existingItemClassname));
		if (StrEqual(existingItemClassname, item)) return existingItem;
		else if (slot != view_as<int>(Slot_5)) RemovePlayerItem2(client, existingItem);
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
