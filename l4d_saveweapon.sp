/*
 * L4D1 Save Weapon (l4d_saveweapon.sp)
 *
 * L4D1 version of Merudo's Save Weapon 4.3 L4D2 plugin.
 *
 * Allows more than four survivors to retain their player states after chapter
 * map changes, player/bot takeovers, and player re-joins. It saves (only in
 * co-operative campaign game mode) survivors’ health, equipment, ammo, revive
 * count, black & white status, survivor character, and survivor model.
 *
 * Added or modified features to Merudo's original plugin include
 * saving/loading gas cans, oxygen tanks and propane tanks; remembering active
 * weapons; giving primary weapons to resurrected survivors after chapter map
 * transitions; correctly restoring pistol(s) magazine ammo; correctly counting
 * revives for incapacitated survivors during chapter map transitions; and
 * replaced several hard-coded constants with ConVar queries

 * Removed features from the original plugin include L4D2 specific
 * features, giving SMGs to survivors at the beginning of the campaign, saving
 * player states at the end of the campaign, and SourceMod admin commands.
 *
 * Version 20180113 (4.3)
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

#define SLOT_1_DEFAULT "weapon_pistol"
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

char onRescueSlot0[MAXPLAYERS + 1][MAX_ENTITY_CLASSNAME_LEN];
int onRescueSlot0ReserveAmmo[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "L4D Save Weapon",
	author = "MAKS, Electr0, Merudo, RedAndBlueEraser",
	description = "Save beyond 4 survivors' player states",
	version = PLUGIN_VERSION,
	url = "https://github.com/RedAndBlueEraser/l4d-saveweapon"
}

public void OnPluginStart()
{
	CreateConVar("l4d_saveweapon", PLUGIN_VERSION, "L4D Save Weapon version", FCVAR_NOTIFY);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_bot_replace", Event_PlayerBotReplace);
	HookEvent("bot_player_replace", Event_BotPlayerReplace);
	HookEvent("player_hurt", Event_PlayerHurt);
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
	DeleteAllOnRescueSlot0();

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
		FindAndAppropriateUnusedPlayerState(client);

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

// Remember a dead survivor's primary weapon to be resurrected with.
public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client != 0 && GetClientTeam(client) == TEAM_SURVIVORS && GetEventInt(event, "health") <= 0)
	{
		DeleteOnRescueSlot0(client);
		int areSurvivorsRespawnWithGuns = FindConVar("survivor_respawn_with_guns").IntValue;
		if (areSurvivorsRespawnWithGuns)
		{
			int item = GetPlayerWeaponSlot(client, 0);
			if (item > -1)
			{
				char itemClassname[MAX_ENTITY_CLASSNAME_LEN];
				GetEdictClassname(item, itemClassname, sizeof(itemClassname));
				if (StrEqual(itemClassname, "weapon_smg"))
				{
					strcopy(onRescueSlot0[client], sizeof(onRescueSlot0[]), itemClassname);
					onRescueSlot0ReserveAmmo[client] = GetEntProp(item, Prop_Send, "m_iClip1") + GetPlayerAmmo(client, item);
					int maxSlot0ReserveAmmo = FindConVar("ammo_smg_max").IntValue;
					if (onRescueSlot0ReserveAmmo[client] > maxSlot0ReserveAmmo)
						onRescueSlot0ReserveAmmo[client] = maxSlot0ReserveAmmo;
				}
				else if (StrEqual(itemClassname, "weapon_pumpshotgun"))
				{
					strcopy(onRescueSlot0[client], sizeof(onRescueSlot0[]), itemClassname);
					onRescueSlot0ReserveAmmo[client] = GetEntProp(item, Prop_Send, "m_iClip1") + GetPlayerAmmo(client, item);
					int maxSlot0ReserveAmmo = FindConVar("ammo_buckshot_max").IntValue;
					if (onRescueSlot0ReserveAmmo[client] > maxSlot0ReserveAmmo)
						onRescueSlot0ReserveAmmo[client] = maxSlot0ReserveAmmo;
				}
				else if (areSurvivorsRespawnWithGuns == 2)
				{
					strcopy(onRescueSlot0[client], sizeof(onRescueSlot0[]), itemClassname);
					onRescueSlot0ReserveAmmo[client] = GetEntProp(item, Prop_Send, "m_iClip1") + GetPlayerAmmo(client, item);
					int maxSlot0ReserveAmmo = 0;
					if (StrEqual(itemClassname, "weapon_rifle")) maxSlot0ReserveAmmo = FindConVar("ammo_assaultrifle_max").IntValue;
					else if (StrEqual(itemClassname, "weapon_hunting_rifle")) maxSlot0ReserveAmmo = FindConVar("ammo_huntingrifle_max").IntValue;
					else if (StrEqual(itemClassname, "weapon_autoshotgun")) maxSlot0ReserveAmmo = FindConVar("ammo_buckshot_max").IntValue;
					if (onRescueSlot0ReserveAmmo[client] > maxSlot0ReserveAmmo)
						onRescueSlot0ReserveAmmo[client] = maxSlot0ReserveAmmo;
				}
				else if (StrEqual(itemClassname, "weapon_rifle") || StrEqual(itemClassname, "weapon_hunting_rifle"))
				{
					strcopy(onRescueSlot0[client], sizeof(onRescueSlot0[]), "weapon_smg");
					onRescueSlot0ReserveAmmo[client] = FindConVar("ammo_smg_max").IntValue;
				}
				else if (StrEqual(itemClassname, "weapon_autoshotgun"))
				{
					strcopy(onRescueSlot0[client], sizeof(onRescueSlot0[]), "weapon_pumpshotgun");
					onRescueSlot0ReserveAmmo[client] = FindConVar("ammo_buckshot_max").IntValue;
				}
			}
		}
	}
}

// Find an unused player state and have it appropriated by the survivor.
void FindAndAppropriateUnusedPlayerState(int client)
{
	for (int srcClient = 1; srcClient <= MaxClients; srcClient++)
	{
		if (isActive[srcClient] && !IsClientConnected(srcClient))
		{
			TransferPlayerState(srcClient, client);
			return;
		}
	}
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
		if (onRescueSlot0[client][0] != '\0')
		{
			strcopy(slots[client][Slot_0], sizeof(slots[][]), onRescueSlot0[client]);
			slot0ReserveAmmo[client] = onRescueSlot0ReserveAmmo[client];
			activeSlot[client] = view_as<int>(Slot_0);
		}
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
		healthTempTime[client] = GetPlayerHealthTempTime(client);
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
	int item;
	for (int slot = view_as<int>(Slot_2); slot <= view_as<int>(Slot_4); slot++)
	{
		if (slots[client][slot][0] != '\0')
			GiveIfNotHasPlayerItemSlot(client, slot, slots[client][slot]);
		else
			RemovePlayerItemSlot(client, slot);
	}
	// Load slot 1 (secondary weapon, sidearm).
	char slot1[MAX_ENTITY_CLASSNAME_LEN] = SLOT_1_DEFAULT;
	if (slots[client][Slot_1][0] != '\0')
		strcopy(slot1, sizeof(slot1), slots[client][Slot_1]);
	item = GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_1), slot1);
	if (item > -1)
	{
		if (slot1IsDualWield[client])
		{
			if (!GetEntProp(item, Prop_Send, "m_hasDualWeapons"))
			{
				int commandFlags = GetCommandFlags("give");
				SetCommandFlags("give", commandFlags & ~FCVAR_CHEAT);
				FakeClientCommand(client, "give %s", slot1);
				SetCommandFlags("give", commandFlags);
			}
		}
		else if (GetEntProp(item, Prop_Send, "m_hasDualWeapons"))
		{
			RemovePlayerItem2(client, item);
			GivePlayerItem2(client, slot1);
		}
		if (slot1MagazineAmmo[client] > -1)
			SetEntProp(item, Prop_Send, "m_iClip1", slot1MagazineAmmo[client]);
	}
	// Load slot 0 (primary weapon).
	if (slots[client][Slot_0][0] != '\0')
	{
		item = GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_0), slots[client][Slot_0]);
		if (item > -1)
		{
			if (slot0MagazineAmmo[client] > -1)
				SetEntProp(item, Prop_Send, "m_iClip1", slot0MagazineAmmo[client]);
			if (slot0ReserveAmmo[client] > -1)
				SetPlayerAmmo(client, item, slot0ReserveAmmo[client]);
		}
	}
	else
	{
		RemovePlayerItemSlot(client, view_as<int>(Slot_0));
	}
	/* Load slot 5 (carried gas can, oxygen tank, or propane tank). Loaded last
	 * so it's the one yielded.
	 */
	if (slots[client][Slot_5][0] != '\0')
	{
		GiveIfNotHasPlayerItemSlot(client, view_as<int>(Slot_5), slots[client][Slot_5]);
	}
	else
	{
		item = GetPlayerWeaponSlot(client, view_as<int>(Slot_5));
		if (item > -1) RemoveEdict(item);
	}
	// Set active weapon, so it's the one yielded.
	if (activeSlot[client] > -1) SetPlayerActiveSlot(client, activeSlot[client]);

	// Load health.
	SetEntProp(client, Prop_Send, "m_iHealth", health[client]);
	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", healthTemp[client]);
	SetPlayerHealthTempTime(client, healthTempTime[client]);
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
	slot0MagazineAmmo[client] = -1;
	slot0ReserveAmmo[client] = -1;
	slot1MagazineAmmo[client] = -1;
	slot1IsDualWield[client] = false;
	activeSlot[client] = -1;
	health[client] = 0;
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

// Delete a survivor's remembered primary weapon to be resurrected with.
void DeleteOnRescueSlot0(int client)
{
	onRescueSlot0[client][0] = '\0';
	onRescueSlot0ReserveAmmo[client] = -1;
}

// Delete all survivors' remembered primary weapons to be resurrected with.
void DeleteAllOnRescueSlot0()
{
	for (int client = 1; client <= MaxClients; client++) DeleteOnRescueSlot0(client);
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
		else if (slot == view_as<int>(Slot_5)) RemoveEdict(existingItem);
		else RemovePlayerItem2(client, existingItem);
	}
	return GivePlayerItem2(client, item);
}

// Remove the item in the specified slot from a survivor.
void RemovePlayerItemSlot(int client, int slot)
{
	int item = GetPlayerWeaponSlot(client, slot);
	if (item > -1) RemovePlayerItem2(client, item);
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

// Set the survivor's active weapon by slot.
void SetPlayerActiveSlot(int client, int slot)
{
	if (IsFakeClient(client))
	{
		int item = GetPlayerWeaponSlot(client, slot);
		if (item > -1) SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", item);
	}
	else
	{
		ClientCommand(client, "slot%d", slot + 1);
	}
}

// Get a survivor's temporary health time relative to the game time.
float GetPlayerHealthTempTime(int client)
{
	return GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
}

// Set a survivor's temporary health time relative to the game time.
void SetPlayerHealthTempTime(int client, float time)
{
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime() - time);
}
