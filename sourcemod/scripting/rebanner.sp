#include <sourcemod>
#include <regex>
#include <filenetwork>
#include <sdktools_stringtables>
#undef REQUIRE_PLUGIN
#tryinclude <sourcebanspp>
#define REQUIRE_PLUGIN

#define DEFAULT_FINGERPRINT "materials/models/texture.vmt"
#define BAN_REASON "Alternative account detected, re-applying ban"
#define ANTITAMPER_ACTION_REASON "File tampering detected! Please download server files from scratch"
#define LOGFILE "logs/rebanner.log"
#define INVALID_USERID -1

enum QueueState
{
        QueueState_Ignore = 0,
        QueueState_Queued = 1
}

enum TableType
{
        TableType_Fingerprints = 0,
        TableType_SteamIDs = 1,
        TableType_IPs = 2
}

enum LogLevel
{
        LogLevel_None = 0,
        LogLevel_Bans,
        LogLevel_Associations,
        LogLevel_Debug
}

Database db;

StringMap bannedFingerprints; //contains all banned fingerprints
StringMap steamIDToFingerprintTable; //StringMap representation of rebanner_steamids table
StringMap ipToFingerprintTable;//StringMap representation of rebanner_ips table
StringMap fingerprintTable;//StringMap representation of rebanner_fingerprints table
StringMap loadedFingerprints; //used to keep track of all fingerprints so we can delete the datapacks that fingerprintTable contains at map end

ConVar rebanDuration;
ConVar antiTamperMode;
ConVar antiTamperAction;
ConVar shouldCheckIP;
ConVar logLevel;

Regex regex;

bool canMarkForScan[MAXPLAYERS + 1];
bool conVarQuerySuccessful = false;

char logFilePath[PLATFORM_MAX_PATH];
char fingerprintPath[PLATFORM_MAX_PATH];
char fingerprintDownloadPath[PLATFORM_MAX_PATH];
char rebanReason[256];
char antitamperKickReason[256];
static char logLevelDefinitions[4][32] = {"[NONE]", "[BAN EVENT]", "[ASSOCIATION]", "[DEBUG]"};

bool globalLocked = true;

int currentUserId = INVALID_USERID;
int fingerprintCounter = 0;

QueueState clientQueueState[MAXPLAYERS+1];

#include <include/bans.sp> //Everything related to ban forwards
#include <include/database.sp> //database creation and parsing

methodmap DataFragments
{
	public DataFragments(Address addr)
	{
		return view_as<DataFragments>(addr);
	}
	
	public void filename(char[] buffer, int length)
	{
		int offset = 0x4;
		for(int i = 0; i < length; i++)
		{
			buffer[i] = LoadFromAddress(view_as<Address>(view_as<int>(this) + offset + i), NumberType_Int8);
			if(buffer[i] == '\0') break;
		}
	}
}

methodmap CUtlVector //Borrowed from File Network by Batfoxkid
{
	public CUtlVector(Address addr)
	{
		return view_as<CUtlVector>(addr);
	}
	
	//Part of CUtlMemory
	public Address m_pMemory()
	{
		return LoadFromAddress(view_as<Address>(view_as<int>(this) + 0x0), NumberType_Int32);
	}
	
	public int m_nAllocationCount()
	{
		return LoadFromAddress(view_as<Address>(view_as<int>(this) + 0x4), NumberType_Int32);
	}
	
	public int m_nGrowSize()
	{
		return LoadFromAddress(view_as<Address>(view_as<int>(this) + 0x8), NumberType_Int32);
	}
	
	//Part of CUtlVector
	public int m_Size()
	{
		return LoadFromAddress(view_as<Address>(view_as<int>(this) + 0xC), NumberType_Int32);
	}
	
	public Address m_pElements()
	{
		return LoadFromAddress(view_as<Address>(view_as<int>(this) + 0x10), NumberType_Int32);
	}
	
	public DataFragments GetAt(int i)
	{
		return view_as<DataFragments>(LoadFromAddress(view_as<Address>(view_as<int>(this.m_pElements()) + 0x4 * i), NumberType_Int32));
	}
	
	public void SetAt(int i, DataFragments data)
	{
		StoreToAddress(view_as<Address>(view_as<int>(this.m_pElements()) + 0x4 * i), data, NumberType_Int32);
	}
	
}

methodmap CNetChan
{
	public CNetChan(Address addr)
	{
		return view_as<CNetChan>(addr);
	}
	
	public CUtlVector m_WaitingList(int idx = 0)
	{
		return view_as<CUtlVector>(view_as<int>(this) + 0x100 + 0x14 * idx);
	}
}

public Plugin myinfo =
{
        name = "SourceMod Re-Banner",
        author = "Nolo001",
        description = "Detects and re-bans alt accounts of banned players through client-side fingerprinting",
        url = "https://github.com/Nolo001-Aha/SourceMod-ReBanner",
        version = "1.0"
};

public void OnPluginStart()
{     
        bannedFingerprints = new StringMap();
        steamIDToFingerprintTable = new StringMap();
        ipToFingerprintTable = new StringMap();
        fingerprintTable = new StringMap();
        loadedFingerprints = new StringMap();

        for(int client = 1; client<=MaxClients; client++)
                clientQueueState[client] = QueueState_Ignore;

        RegAdminCmd("rb_unbansteam", Command_UnbanBySteamID, ADMFLAG_UNBAN, "Remove the ban flag on a fingerprint via a SteamID");
        RegAdminCmd("rb_unbanip", Command_UnbanByIP, ADMFLAG_UNBAN, "Remove the ban flag on a fingerprint via an IP address");

        logLevel = CreateConVar("rb_log_level", "1", "Logging level. 0 - disable. 1 - log alt account bans, 2 - also log associations, 3 - log everything(debug, lots of SPAM).")
        shouldCheckIP = CreateConVar("rb_check_ip", "1", "Should IP addresses be taken into account? 0 - no, 1 - yes (RECOMMENDED)");
        antiTamperAction = CreateConVar("rb_antitamper_action", "1", "Action taken when fingerprint tampering is detected. 0 - do nothing, 1 - kick");
        antiTamperMode = CreateConVar("rb_antitamper_mode", "1", "Anti-tamper mode. 0 - disable (DANGEROUS), 1 - check fingerprints for tampering, 2 - Also check if client fingerprint is known by the server");
        rebanDuration = CreateConVar("rb_reban_type", "0", "How long should alts be re-banned for? 1 - same duration as original ban, 0 - remaining duration of the original ban");
}

public void OnAllPluginsLoaded()
{
        ParseConfigFile();
}

public void OnMapStart()
{
        fingerprintCounter = 0;
        globalLocked = true;
        currentUserId = INVALID_USERID;
        Database.Connect(OnDatabaseConnected, "rebanner", 0);
        CreateTimer(5.0, Timer_ProcessQueue, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);
}

public void OnMapEnd()
{
        globalLocked = true;
        currentUserId = INVALID_USERID;
        for(int client = 1; client<=MaxClients; client++)
                clientQueueState[client] = QueueState_Ignore;

        for(int fingerprintIndex = 0; fingerprintIndex <= fingerprintCounter; fingerprintIndex++) //clean up existing datapacks
        {
                char key[16];
                IntToString(fingerprintIndex, key, sizeof(key));
                if(loadedFingerprints.ContainsKey(key))
                {
                        char fingerpint[128];
                        loadedFingerprints.GetString(key, fingerpint, sizeof(fingerpint));
                        DataPack pack;
                        fingerprintTable.GetValue(fingerpint, pack);
                        delete pack;
                }
        }
        bannedFingerprints.Clear();
        steamIDToFingerprintTable.Clear();
        ipToFingerprintTable.Clear();
        fingerprintTable.Clear();
        loadedFingerprints.Clear();
}

void ParseConfigFile()
{
        char config[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, config, sizeof(config), "configs/rebanner.cfg");
        if(!FileExists(config))
                GenerateConfigFile(config);

        char configFingerprint[PLATFORM_MAX_PATH], configRebanReason[256], configKickReason[256];
        KeyValues kv = new KeyValues("Settings");
        kv.ImportFromFile(config);
        kv.Rewind();
        kv.GetString("fingerprint path", configFingerprint, sizeof(configFingerprint));
        kv.GetString("ban reason", configRebanReason, sizeof(configRebanReason));
        kv.GetString("tampering kick reason", configKickReason, sizeof(configKickReason));

        strcopy(fingerprintPath, sizeof(fingerprintPath), configFingerprint);
        Format(configFingerprint, sizeof(configFingerprint), "download/%s", configFingerprint);
        strcopy(fingerprintDownloadPath, sizeof(fingerprintDownloadPath), configFingerprint);

        strcopy(rebanReason, sizeof(rebanReason), configRebanReason);
        strcopy(antitamperKickReason, sizeof(antitamperKickReason), configKickReason);
        delete kv;
}

void GenerateConfigFile(const char[] path)
{
        char randomDownloadPath[PLATFORM_MAX_PATH];
        int downloadTable = FindStringTable("downloadables");
        if(downloadTable == INVALID_STRING_TABLE)
                SetFailState("Unable to find downloadables stringtable. What?");

        KeyValues kv = new KeyValues("Settings");
        int downloadTableSize = GetStringTableNumStrings(downloadTable);
        if(downloadTableSize > 3)
        {
                ReadStringTable(downloadTable, GetRandomInt(3, downloadTableSize-1), randomDownloadPath, sizeof(randomDownloadPath));
                char explodedString[4][256];
                int explodeSize = ExplodeString(randomDownloadPath, ".", explodedString, 4, 256);
                Format(explodedString[explodeSize-2], 256, "%s1", explodedString[explodeSize-2]);
                char finalFingerprintPath[PLATFORM_MAX_PATH];
                for(int i = 0; i< explodeSize-1; i++)
                Format(finalFingerprintPath, sizeof(finalFingerprintPath), "%s%s", finalFingerprintPath, explodedString[i]);

                Format(finalFingerprintPath, sizeof(finalFingerprintPath), "%s.%s", finalFingerprintPath, explodedString[explodeSize-1]);
                kv.SetString("fingerprint path", finalFingerprintPath);
        }
        else
        {
                kv.SetString("fingerprint path", DEFAULT_FINGERPRINT);
        }
        kv.SetString("ban reason", BAN_REASON);
        kv.SetString("tampering kick reason", ANTITAMPER_ACTION_REASON);
        kv.Rewind();
        kv.ExportToFile(path);
        delete kv;
}

public void OnClientAuthorized(int client)
{
    if(!canMarkForScan[client])
    {
        canMarkForScan[client] = true;
        return;
    }
    BeginScan(client);
}

public void OnClientPutInServer(int client)
{
    if(!canMarkForScan[client])
    {
        canMarkForScan[client] = true;
        return;
    }
    BeginScan(client);
}

public void OnClientDisconnect(int client)
{
        clientQueueState[client] = QueueState_Ignore;
        canMarkForScan[client] = false;
        if(currentUserId == GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                globalLocked = false;
                conVarQuerySuccessful = false;
        }
}

void BeginScan(int client)
{
        canMarkForScan[client] = false;
        CreateTimer(3.0, Timer_AppendClientToQueue, client, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AppendClientToQueue(Handle tmr, int client)
{
        if(IsValidClient(client))
                clientQueueState[client] = QueueState_Queued;

        return Plugin_Continue;
}

public Action Timer_ProcessQueue(Handle tmr, any data)
{
        if(globalLocked)
                return Plugin_Continue;

        for(int client = 1; client<=MaxClients; client++)
        {
                if(!IsValidClient(client))
                        continue;
                
                if(clientQueueState[client] == QueueState_Queued)
                {
                        globalLocked = true;
                        currentUserId = GetClientUserId(client);
                        char logMessage[128];
                        Format(logMessage, sizeof(logMessage), "Processing queued client %N", client);
                        WriteLog(logMessage, LogLevel_Debug);
                        CheckClientConVar(client);
                        return Plugin_Continue;
                }
        }
        return Plugin_Continue;
}

void CheckClientConVar(int client)
{
        if(!IsValidClient(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;             
        }
        if(currentUserId != GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;
        }
        RemoveBanRecordIfExists(client); //if client got to this point, means they're not banned and we can reset is_banned if it's set to 1
        conVarQuerySuccessful = false;
        QueryClientConVar(client, "cl_allowupload", OnClientConVarQueried);
        CreateTimer(6.0, Timer_CheckForSuccessfulConVarQuery, client, TIMER_FLAG_NO_MAPCHANGE);

}

public Action Timer_CheckForSuccessfulConVarQuery(Handle tmr, int client)
{
        if(!IsValidClient(client))
                return Plugin_Continue;

        if(currentUserId != GetClientUserId(client))
                return Plugin_Continue;

        if(!conVarQuerySuccessful)
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return Plugin_Continue;             
        }
        return Plugin_Continue;
}

public void OnClientConVarQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
        conVarQuerySuccessful = true;
        WriteLog("Client ConVars dumped...", LogLevel_Debug);
        if(!IsValidClient(client))
        {
                clientQueueState[client] = QueueState_Ignore;
                currentUserId = INVALID_USERID;
                globalLocked = false;
                return;
        }
        if(currentUserId != GetClientUserId(client))
        {
                clientQueueState[client] = QueueState_Ignore;
                currentUserId = INVALID_USERID;
                globalLocked = false;
                return;
        }       

        if(result == ConVarQuery_Cancelled)
        {
                clientQueueState[client] = QueueState_Ignore;
                currentUserId = INVALID_USERID;
                globalLocked = false;
                return;
        }

        float value = StringToFloat(cvarValue);
        if(value == 1.0)
        {
                WriteLog("ConVar is 1. Proceeding...", LogLevel_Debug);
                FileNet_RequestFile(client, fingerprintPath, RequestClientFingerprint);
        }
        else
        {
                WriteLog("ConVar is 0. Aborting...", LogLevel_Debug);
                clientQueueState[client] = QueueState_Ignore;
                currentUserId = INVALID_USERID;
                globalLocked = false;
                return;              
        }
        

}

void RequestClientFingerprint(int client, const char[] file, int id, bool success)
{
        if(!IsValidClient(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;               
        }
        if(currentUserId != GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;
        }
        if(!success)
        {
                CreateOrResendClientFingerprint(client);
                return;
        }

        File fingerprintFile = OpenFile(fingerprintDownloadPath, "r");
        if(fingerprintFile == null)
                SetFailState("Could not find fingerprint file on disk! Should never happen?");

        char clientFingerprint[256];
        fingerprintFile.ReadLine(clientFingerprint, sizeof(clientFingerprint));
        fingerprintFile.Close();
        char logMessage[128];
        Format(logMessage, sizeof(logMessage), "Processing existing fingerprint %s of client %N", clientFingerprint, client);
        WriteLog(logMessage, LogLevel_Debug);
        while(FileExists(fingerprintDownloadPath))
                DeleteFile(fingerprintDownloadPath);

        clientQueueState[client] = QueueState_Ignore;
        globalLocked = false;
        
        ProcessReceivedClientFingerprint(client, clientFingerprint);
}

void ProcessReceivedClientFingerprint(int client, const char[] fingerprint)
{
        if(currentUserId != GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;
        }
        char ip[64], steamid[64], query[512];
        GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
        GetClientIP(client, ip, sizeof(ip));

        if(steamIDToFingerprintTable.ContainsKey(steamid) || ipToFingerprintTable.ContainsKey(ip)) // we recognize this client by IP or SteamID, we know their fingerprint. 
        {                                                                                               //Make sure to store their IP/SteamID if we don't have such a match
                if(steamIDToFingerprintTable.ContainsKey(steamid)) //if we matched by steamid
                {
                        char knownFingerprint[128];
                        steamIDToFingerprintTable.GetString(steamid, knownFingerprint, sizeof(knownFingerprint));

                        if(!ipToFingerprintTable.ContainsKey(ip)) //and if we haven't recorded this IP yet
                        {
                                Format(query, sizeof(query), "INSERT INTO rebanner_ips (ip, fingerprint) VALUES ('%s', '%s')", ip, knownFingerprint);
                                db.Query(OnFingerprintRelationSaved, query); //save new ip-fingerprint relation
                                char logMessage[128];
                                Format(logMessage, sizeof(logMessage), "Adding new IP (%s) association for client %N", ip, client);
                                WriteLog(logMessage, LogLevel_Associations);
                                UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(knownFingerprint, "", ip);
                        }

                        if(bannedFingerprints.ContainsKey(knownFingerprint)) //if this known fingerprint is banned, execute em
                                RebanClient(client, knownFingerprint);

                        currentUserId = INVALID_USERID;
                        clientQueueState[client] = QueueState_Ignore;
                        globalLocked = false;
                        return;
                }

                if(ipToFingerprintTable.ContainsKey(ip)) //if we matched by ip
                {
                        char knownFingerprint[128];
                        ipToFingerprintTable.GetString(ip, knownFingerprint, sizeof(knownFingerprint));

                        if(!steamIDToFingerprintTable.ContainsKey(steamid)) //and if we haven't recorded this SteamID yet
                        {
                                Format(query, sizeof(query), "INSERT INTO rebanner_steamids (steamid2, fingerprint) VALUES ('%s', '%s')", steamid, knownFingerprint);
                                db.Query(OnFingerprintRelationSaved, query); //save new steamid-fingerprint relation
                                char logMessage[128];
                                Format(logMessage, sizeof(logMessage), "Adding new SteamID (%s) association for client %N", steamid, client);
                                WriteLog(logMessage, LogLevel_Associations);
                                UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(knownFingerprint, steamid, "");
                        }
                        if(bannedFingerprints.ContainsKey(knownFingerprint)) //if this known fingerprint is banned, execute em
                                RebanClient(client, knownFingerprint);
                        currentUserId = INVALID_USERID;
                        clientQueueState[client] = QueueState_Ignore;
                        globalLocked = false;
                        return;
                }
                                
        }
        else //we do not recognize their IP and SteamID and can't find their fingerprint, but they have a fingerprint clientside. Grab their clientside fingerprint and match it with their steamid and ip
        {
                if(IsFingerprintTamperedWith(fingerprint))
                {
                        char log[512];
                        Format(log, sizeof(log), "Potential fingerprint tampering detected for client %N!", client);
                        WriteLog(log, LogLevel_Associations);
                        if(antiTamperAction.BoolValue) //kick client
                        {
                                clientQueueState[client] = QueueState_Ignore;
                                currentUserId = INVALID_USERID;
                                KickClient(client, ANTITAMPER_ACTION_REASON);
                                globalLocked = false;
                        }
                        return;
                }
                Format(query, sizeof(query), "INSERT INTO rebanner_steamids (steamid2, fingerprint) VALUES ('%s', '%s')", steamid, fingerprint);
                db.Query(OnFingerprintRelationSaved, query); //save new steamid-fingerprint relation
                steamIDToFingerprintTable.SetString(steamid, fingerprint);

                if(shouldCheckIP.BoolValue)
                {
                        Format(query, sizeof(query), "INSERT INTO rebanner_ips (ip, fingerprint) VALUES ('%s', '%s')", ip, fingerprint);
                        db.Query(OnFingerprintRelationSaved, query); //save new ip-fingerprint relation

                        UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(fingerprint, steamid, ip);
                }
                else
                {
                        UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(fingerprint, steamid);                        
                }
                        
                if(bannedFingerprints.ContainsKey(fingerprint)) //if this fingerprint is banned, execute em
                        RebanClient(client, fingerprint);

                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;     
        }
}

bool IsFingerprintTamperedWith(const char[] fingerprint)
{
        if(antiTamperMode.IntValue)
        {
                regex = new Regex("^[0-9]+$");
                if(regex.Match(fingerprint) == -1) //our regex detected tampering, the fingerprint string contains something other than numbers
                        return true;

                if(antiTamperMode.IntValue == 2)
                {
                        if(!fingerprintTable.ContainsKey(fingerprint)) //the fingerprint from the client is numeric only, but we don't recognize it = tampering.
                                return true;
                }
        }
        return false;
}

void UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(const char[] fingerprint, const char[] steamid = "", const char[] ip = "")
{
        char query[512];
        if(steamid[0])
        {
                steamIDToFingerprintTable.SetString(steamid, fingerprint);  
                char steamidString[256];
                DataPack pack;
                fingerprintTable.GetValue(fingerprint, pack);
                pack.Reset();
                pack.ReadString(steamidString, sizeof(steamidString));
                Format(query, sizeof(query), "UPDATE rebanner_fingerprints SET steamid2 = '%s;%s' WHERE fingerprint = '%s'", steamidString, steamid, fingerprint);
                db.Query(AppendFingerprintSteamIDOrIPCallback, query);             
        }
        if(ip[0])
        {
                ipToFingerprintTable.SetString(ip, fingerprint);
                char ipString[256];
                DataPack pack;
                fingerprintTable.GetValue(fingerprint, pack);
                pack.Reset();
                pack.ReadString(ipString, sizeof(ipString));
                pack.ReadCell();
                pack.ReadCell();
                pack.ReadCell();
                pack.ReadString(ipString, sizeof(ipString));

                Format(query, sizeof(query), "UPDATE rebanner_fingerprints SET ip = '%s;%s' WHERE fingerprint = '%s'", ipString, ip, fingerprint);
                db.Query(AppendFingerprintSteamIDOrIPCallback, query);             
        }

        
}


public void AppendFingerprintSteamIDOrIPCallback(Database dtb, DBResultSet results, const char[] error, any data)
{
               if(error[0])
                SetFailState("Failed to update fingerprint steamID or IP: %s", error);

}

bool ForceShiftFingerprintQueuePosition(int client)
{
        Address netChanAddress = FileNet_GetNetChanPtr(client);
        if(netChanAddress == Address_Null)
                return false;

        CNetChan netchan = CNetChan(netChanAddress);
	CUtlVector waitingList = netchan.m_WaitingList(1);
        if(waitingList.m_Size() <= 3)
                return false;


        DataFragments swapWith = waitingList.GetAt(waitingList.m_Size() - 1);
        char filename[PLATFORM_MAX_PATH];
        swapWith.filename(filename, sizeof(filename));

        DataFragments toSwap = waitingList.GetAt(1);
        waitingList.SetAt(1, swapWith);
	waitingList.SetAt(waitingList.m_Size() - 1, toSwap);
        return true;
}

void GenerateLocalFingerprintAndSendToClient(int client, const char[] existingFingerprint = "")
{
        if(currentUserId != GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;
        }
        char uniqueFingerprint[512], steamID2[128], ip[256], query[1024];

        if(!existingFingerprint[0]) //if existingFingerprint is empty (i.e. generate new fingerprint )
        {
                for(int i=1; i<=5; i++)
                        Format(uniqueFingerprint, sizeof(uniqueFingerprint), "%s%i", uniqueFingerprint, (GetURandomInt() % 988888889) + 11111111);
        }
        else //otherwise we're sending an existng fingerprint, so dont create a new one
        {
                strcopy(uniqueFingerprint, sizeof(uniqueFingerprint), existingFingerprint);
        }

        
        File file;
        file = OpenFile(fingerprintPath, "w+");
        file.WriteString(uniqueFingerprint, false);
        file.Flush();
        file.Close();
        DataPack pack = new DataPack();
        pack.WriteString(uniqueFingerprint);
        pack.WriteCell(client);

        WriteLog("Calling SendFile...", LogLevel_Debug);
        if(!FileNet_SendFile(client, fingerprintPath, OnFingerprintFirstSent, pack, true))
        { //we failed to queue the fingerprint for some reason, wtf?
                clientQueueState[client] = QueueState_Ignore;
                currentUserId = INVALID_USERID;
                globalLocked = false;
                return;       
        }
        ForceShiftFingerprintQueuePosition(client);
        if(!existingFingerprint[0])
        {
                GetClientAuthId(client, AuthId_Steam2, steamID2, sizeof(steamID2));
                GetClientIP(client, ip, sizeof(ip));
                Format(query, sizeof(query), "INSERT INTO rebanner_fingerprints (fingerprint, steamid2, is_banned, banned_duration, banned_timestamp, ip) VALUES ('%s', '%s', 0, 0, 0, '%s')", uniqueFingerprint, steamID2, ip);
                db.Query(OnFingerprintRelationSaved, query); //save new fingerprint
                DataPack fingerprintPack = new DataPack();
                fingerprintPack.WriteString(steamID2);
                fingerprintPack.WriteCell(0);
                fingerprintPack.WriteCell(0);
                fingerprintPack.WriteCell(0);
                fingerprintPack.WriteString(ip);
                fingerprintTable.SetValue(uniqueFingerprint, fingerprintPack);
                steamIDToFingerprintTable.SetString(steamID2, uniqueFingerprint);
                ipToFingerprintTable.SetString(ip, uniqueFingerprint);
                Format(query, sizeof(query), "INSERT INTO rebanner_steamids (steamid2, fingerprint) VALUES ('%s', '%s')", steamID2, uniqueFingerprint);
                db.Query(OnFingerprintRelationSaved, query); //save new steamid-fingerprint relation

                if(shouldCheckIP.BoolValue)
                {
                        Format(query, sizeof(query), "INSERT INTO rebanner_ips (ip, fingerprint) VALUES ('%s', '%s')", ip, uniqueFingerprint);
                        db.Query(OnFingerprintRelationSaved, query); //save new ip-fingerprint relation
                }

        }
}                      

void OnFingerprintFirstSent(int client, const char[] file, bool success, DataPack pack)
{
        if(!success)
        {
                WriteLog("OnFingerprintFirstSent failure!", LogLevel_Debug);
                return;
        }
        char logMessage[128];
        Format(logMessage, sizeof(logMessage), "Successfully sent fingerprint file of client %N. Success: %b", client, success);
        WriteLog(logMessage, LogLevel_Debug);
        //KillTimer(currentCheckFileTimer); //stop the timer, since we received success e.g. client returned the file that we sent them (i.e. they already have it client side)

        while(FileExists(fingerprintDownloadPath))
                DeleteFile(fingerprintDownloadPath);

        while(FileExists(fingerprintPath))
                DeleteFile(fingerprintPath);
    
        currentUserId = INVALID_USERID;
        clientQueueState[client] = QueueState_Ignore;
        globalLocked = false;

        pack.Reset();
        char fingerprint[128];
        pack.ReadString(fingerprint, sizeof(fingerprint));
        delete pack;
        if(bannedFingerprints.ContainsKey(fingerprint)) //client is banned
        {
                RebanClient(client, fingerprint);
        }
        else
        {
                currentUserId=INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
        }        
}

void RebanClient(int client, const char[] fingerprint, const char[] reason = BAN_REASON)
{
        char query[512];
        char logMessage[128];
        Format(logMessage, sizeof(logMessage), "Processing ban event of client %N", client);
        WriteLog(logMessage, LogLevel_Bans);
        Format(query, sizeof(query), "SELECT banned_duration, banned_timestamp FROM rebanner_fingerprints WHERE fingerprint = '%s'", fingerprint);
        DataPack pack = new DataPack();
        pack.WriteCell(client);
        pack.WriteString(fingerprint);
        pack.WriteString(reason);
        db.Query(RebanClientQueryResult, query, pack);
}

public void RebanClientQueryResult(Database dtb, DBResultSet results, const char[] error, DataPack pack)
{
        if(error[0])
                ThrowError("Failed to query banned fingerprint data: %s", error);

        if(results.FetchRow())
        {
                pack.Reset();
                int client = pack.ReadCell();
                if(currentUserId != GetClientUserId(client))
                {
                        currentUserId = INVALID_USERID;
                        clientQueueState[client] = QueueState_Ignore;
                        globalLocked = false;
                        return;
                }
                char fingerprint[128], reason[256];
                pack.ReadString(fingerprint, sizeof(fingerprint));
                pack.ReadString(reason, sizeof(reason));
                delete pack;
                int duration = results.FetchInt(0);
                int banned_timestamp = results.FetchInt(1);
                if(rebanDuration.BoolValue)
                {
                        BanClient(client, duration, BANFLAG_AUTO, reason, reason, "reban", client);
                }
                else
                {
                        int remainingDuration = duration - ((GetTime() - banned_timestamp)/60);
                        if(remainingDuration < 0)
                                remainingDuration = 0;

                        BanClient(client, remainingDuration, BANFLAG_AUTO, reason, reason, "reban", client);
                }
                bannedFingerprints.SetString(fingerprint, "", false);

                currentUserId = INVALID_USERID;
                globalLocked = false;
                clientQueueState[client] = QueueState_Ignore;

        }
}

void CreateOrResendClientFingerprint(int client)
{
        if(currentUserId != GetClientUserId(client))
        {
                currentUserId = INVALID_USERID;
                clientQueueState[client] = QueueState_Ignore;
                globalLocked = false;
                return;
        }
        char steamid2[64], query[512];
        GetClientAuthId(client, AuthId_Steam2, steamid2, sizeof(steamid2));
        char ip[64];
        GetClientIP(client, ip, sizeof(ip));
        if(steamIDToFingerprintTable.ContainsKey(steamid2)) //if we match a steamID to a fingerprint
        {
                char fingerprint[128];
                steamIDToFingerprintTable.GetString(steamid2, fingerprint, sizeof(fingerprint));
                if(!ipToFingerprintTable.ContainsKey(ip) && shouldCheckIP.BoolValue) //and if we haven't recorded this IP yet
                {
                        Format(query, sizeof(query), "INSERT INTO rebanner_ips (ip, fingerprint) VALUES ('%s', '%s')", ip, fingerprint);
                        db.Query(OnFingerprintRelationSaved, query); //save new ip-fingerprint relation
                        UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(fingerprint, "", ip);
                } 
                char logMessage[128];
                Format(logMessage, sizeof(logMessage), "Found existing fingerprint record (%s) by SteamID match (%s)", fingerprint, steamid2);
                WriteLog(logMessage, LogLevel_Associations);

                GenerateLocalFingerprintAndSendToClient(client, fingerprint);
        }
        else
        {
                if(ipToFingerprintTable.ContainsKey(ip) && shouldCheckIP.BoolValue) //if we match a steamID to an ip
                {
                        char fingerprint[128];
                        ipToFingerprintTable.GetString(ip, fingerprint, sizeof(fingerprint));
                        char logMessage[128];
                        Format(logMessage, sizeof(logMessage), "Found existing fingerprint record (%s) by IP match (%s)", fingerprint, ip);
                        WriteLog(logMessage, LogLevel_Associations);
                        GenerateLocalFingerprintAndSendToClient(client, fingerprint);
                        Format(query, sizeof(query), "INSERT INTO rebanner_steamids (steamid2, fingerprint) VALUES ('%s', '%s')", steamid2, fingerprint);
                        db.Query(OnFingerprintRelationSaved, query); //save new steamid-fingerprint relation
                        UpdateMainFingerprintRecordWithNewSteamIDAndOrIP(fingerprint, steamid2, "");        
                }
                else //if we're out of options and we don't recognize this client
                {
                        char logMessage[128];
                        Format(logMessage, sizeof(logMessage), "Generating new fingerprint for client %N", client);
                        WriteLog(logMessage, LogLevel_Debug);
                        GenerateLocalFingerprintAndSendToClient(client);
                }

        }
}

void WriteLog(const char[] message, LogLevel level)
{
        LogLevel currentLogLevel = view_as<LogLevel>(logLevel.IntValue);
        if(currentLogLevel >= level)
        {
                File logFile;
                BuildPath(Path_SM, logFilePath, PLATFORM_MAX_PATH, LOGFILE);
                logFile = OpenFile(logFilePath, "a");
                logFile.WriteLine("%s %s", logLevelDefinitions[level], message);
                logFile.Close();
        }

}

void OnFingerprintRelationSaved(Database dtb, DBResultSet results, const char[] error, any data)
{
        if(error[0])
                SetFailState("Failed to parse database: %s", error);  
}

public Action Command_UnbanBySteamID(int client, int args)
{
        if(args != 1)
        {
                PrintToChat(client, "You need to provide a SteamID (STEAM_X:X:XXXXXXXXX).");
                return Plugin_Handled;
        }
        char steamid[64];
        GetCmdArg(1, steamid, sizeof(steamid));
        if(TryUnbanBySteamIDOrIP(steamid))
        {
                PrintToChat(client, "Successfully removed ban record from SteamID %s.", steamid);
                return Plugin_Handled;
        }
        else
        {
                PrintToChat(client, "Failed to match %s to a known fingerprint or it's not banned. Aborting.", steamid);
                return Plugin_Handled;                
        }
}

public Action Command_UnbanByIP(int client, int args)
{
        if(args != 1)
        {
                PrintToChat(client, "You need to provide an IP address.");
                return Plugin_Handled;
        }
        char ip[64];
        GetCmdArg(1, ip, sizeof(ip));
        if(TryUnbanBySteamIDOrIP("", ip))
        {
                PrintToChat(client, "Successfully removed ban record from IP address %s.", ip);
                return Plugin_Handled;
        }
        else
        {
                PrintToChat(client, "Failed to match %s to a known fingerprint or it's not banned. Aborting.", ip);
                return Plugin_Handled;                
        }
}

bool TryUnbanBySteamIDOrIP(const char[] steamid="", const char[] ip="")
{
        if(steamid[0])
        {
                if(steamIDToFingerprintTable.ContainsKey(steamid))
                {
                        char fingerprint[128];
                        steamIDToFingerprintTable.GetString(steamid, fingerprint, sizeof(fingerprint));
                        if(bannedFingerprints.ContainsKey(fingerprint))
                        {
                                bannedFingerprints.Remove(fingerprint);
                                char logMessage[128];
                                Format(logMessage, sizeof(logMessage), "Removing ban flag from %s", steamid);
                                WriteLog(logMessage, LogLevel_Debug);
                                char query[512];
                                Format(query, sizeof(query), "UPDATE rebanner_fingerprints SET is_banned = 0, banned_duration = 0, banned_timestamp = 0 WHERE fingerprint = '%s'", fingerprint);
                                db.Query(ClientBanRecordRemoved, query);
                                return true;
                        }
                }
        }
        if(ip[0])
        {
                if(ipToFingerprintTable.ContainsKey(ip))
                {
                        char fingerprint[128];
                        ipToFingerprintTable.GetString(ip, fingerprint, sizeof(fingerprint));
                        if(bannedFingerprints.ContainsKey(fingerprint))
                        {
                                bannedFingerprints.Remove(fingerprint);
                                char logMessage[128];
                                Format(logMessage, sizeof(logMessage), "Removing ban flag from %s", ip);
                                WriteLog(logMessage, LogLevel_Debug);
                                char query[512];
                                Format(query, sizeof(query), "UPDATE rebanner_fingerprints SET is_banned = 0, banned_duration = 0, banned_timestamp = 0 WHERE fingerprint = '%s'", fingerprint);
                                db.Query(ClientBanRecordRemoved, query);
                                return true;
                        }
                }          
        }
        return false;
}


stock bool IsValidClient(int client, bool replaycheck=true, bool onlyrealclients=true) //stock that checks if the client is valid(not bot, connected, in game, authorized etc)
{
	if(client<=0 || client>MaxClients)
	{
		return false;
	}

	if(!IsClientInGame(client))
	{
		return false;
	}

	if(onlyrealclients)
	{
		if(IsFakeClient(client))
			return false;
	}

	if(replaycheck)
	{
		if(IsClientSourceTV(client) || IsClientReplay(client))
		{
			return false;
		}
	}
	
	return true;
}	
