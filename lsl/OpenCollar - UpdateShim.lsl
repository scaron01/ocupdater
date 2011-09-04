integer iStartParam;

// a strided list of all scripts in inventory, with their names,versions,uuids
// built on startup
list lScripts;

// list where we'll record all the settings and local settings we're sent, for replay later.
// they're stored as strings, in form "<cmd>|<data>", where cmd is either HTTPDB_SAVE or
// LOCALSETTING_SAVE
list lSettings;

// Return the name and version of an item as a list.
list GetNameParts(string name) {
    list nameparts = llParseString2List(name, [" - "], []);
    string shortname = llDumpList2String(llDeleteSubList(nameparts, -1, -1), " - ");
    string version;
    if (llGetListLength(nameparts) > 1) {
        version = llList2String(nameparts, -1);
    } else {
        version = "";
    }
    return [shortname, version];
}

// Given the name (but not version) of a script, look it up in our list and return the key
// returns "" if not found.
key GetScriptFullname(string name) {
    integer idx = llListFindList(lScripts, [name]);
    if (idx == -1) {
        return (key)"";
    }
    
    string version = llList2String(lScripts, idx + 1);
    return llDumpList2String([name, version], " - ");
}

integer COMMAND_NOAUTH = 0;

integer HTTPDB_SAVE = 2000;//scripts send messages on this channel to have settings saved to httpdb
//str must be in form of "token=value"
integer HTTPDB_REQUEST = 2001;//when startup, scripts send requests for settings on this channel
integer HTTPDB_RESPONSE = 2002;//the httpdb script will send responses on this channel
integer HTTPDB_DELETE = 2003;//delete token from DB
integer HTTPDB_EMPTY = 2004;//sent when a token has no value in the httpdb
integer HTTPDB_REQUEST_NOCACHE = 2005;

integer LOCALSETTING_SAVE = 2500;
integer LOCALSETTING_REQUEST = 2501;
integer LOCALSETTING_RESPONSE = 2502;
integer LOCALSETTING_DELETE = 2503;
integer LOCALSETTING_EMPTY = 2504;

default
{
    state_entry()
    {
        iStartParam = llGetStartParameter();
        
        // build script list
        integer n;
        integer stop = llGetInventoryNumber(INVENTORY_SCRIPT);
        for (n = 0; n < stop; n++) {
            string name = llGetInventoryName(INVENTORY_SCRIPT, n);
            // add to script list
            lScripts += GetNameParts(name);
        }
        
        // listen on the start param channel
        llListen(iStartParam, "", "", "");
        
        // let mama know we're ready
        llWhisper(iStartParam, "reallyready");
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (llGetOwnerKey(id) == llGetOwner()) {
            list parts = llParseString2List(msg, ["|"], []);
            if (llGetListLength(parts) == 4) {
                string type = llList2String(parts, 0);
                string name = llList2String(parts, 1);
                key uuid = (key)llList2String(parts, 2);
                string mode = llList2String(parts, 3);
                string cmd;
                if (mode == "INSTALL" || mode == "REQUIRED") {
                    if (type == "SCRIPT") {
                        // see if we have that script in our list.
                        integer idx = llListFindList(lScripts, [name]);
                        if (idx == -1) {
                            // script isn't in our list.
                            cmd = "GIVE";
                        } else {
                            // it's in our list.  Check UUID.
                            string script_name = GetScriptFullname(name);
                            key script_id = llGetInventoryKey(script_name);
                            if (script_id == uuid) {
                                // already have script.  skip
                                cmd = "SKIP";
                            } else {
                                // we have the script but it's the wrong version.  delete and get new one.
                                llRemoveInventory(script_name);
                                cmd = "GIVE";
                            }
                        }
                    } else if (type == "ITEM") {
                        if (llGetInventoryType(name) != INVENTORY_NONE) {
                            // item exists.  check uuid.
                            if (llGetInventoryKey(name) != uuid) {
                                // mismatch.  delete and report
                                llRemoveInventory(name);
                                cmd = "GIVE";
                            } else {
                                // match.  Skip
                                cmd = "SKIP";
                            }
                        } else {
                            // we don't have item. get it.
                            cmd = "GIVE";
                        }
                    }                
                } else if (mode == "REMOVE") {
                    if (type == "SCRIPT") {
                        string script_name = GetScriptFullname(name);
                        if (llGetInventoryType(script_name) != INVENTORY_NONE) {
                            llRemoveInventory(script_name);
                        }
                    } else if (type == "ITEM") {
                        if (llGetInventoryType(name) != INVENTORY_NONE) {
                            llRemoveInventory(name);
                        }
                    }
                    cmd = "OK";
                }
                llRegionSayTo(id, channel, llDumpList2String([type, name, cmd], "|"));                                                                
            } else {
                if (llSubStringIndex(msg, "CLEANUP") == 0) {
                    // set the new version
                    list msgparts = llParseString2List(msg, ["|"], []);
                    string newversion = llList2String(msgparts, 1);
                    // look for a version in the name and change if present
                    list nameparts = llParseString2List(llGetObjectName(), [" - "], []);
                    if (llGetListLength(nameparts) == 2 && (integer)llList2String(nameparts, 1)) {
                        // looks like there's a version in the name
                        nameparts = llListReplaceList(nameparts, [newversion], 1, 1);
                        string newname = llDumpList2String(nameparts, " - ");
                        llSetObjectName(newname);
                    }
                    
                    // look for a version in the desc and change if present
                    list descparts = llParseString2List(llGetObjectDesc(), ["~"], []);                                      if (llGetListLength(descparts) > 1 && (integer)llList2String(descparts, 1)) {
                        descparts = llListReplaceList(descparts, [newversion], 1, 1);
                        string newdesc = llDumpList2String(descparts, "~");
                        llSetObjectDesc(newdesc);
                    }
                    
                    //restore settings 
                    integer n;
                    integer stop = llGetListLength(lSettings); 
                    for (n = 0; n < stop; n++) {
                        string item = llList2String(lSettings, n);
                        list parts = llParseString2List(item, ["|"], []);
                        integer cmd = (integer)llList2String(parts, 0);
                        string setting = llList2String(parts, 1);
                        // cmd will be stored as either HTTPDB_SAVE or LOCALSETTING_SAVE.  Just 
                        // trust what's in the list.
                        llMessageLinked(LINK_SET, cmd, setting, "");
                    }
                    
                    // tell scripts to rebuild menus (in case plugins have been removed)
                    llMessageLinked(LINK_SET, COMMAND_NOAUTH, "refreshmenu", llGetOwner());
                    
                    // remove the script pin
                    llSetRemoteScriptAccessPin(0);
                    
                    // celebrate
                    llOwnerSay("Update complete!");
                    
                    // delete shim script
                    llRemoveInventory(llGetScriptName());
                }
            }
        }
    }
    
    link_message(integer sender, integer num, string str, key id) {
        // The settings script will dump all its settings when an inventory change happens, so listen for that and remember them 
        // so they can be restored when we're done.
        if (num == HTTPDB_RESPONSE || num == LOCALSETTING_RESPONSE) {
            if (str != "settings=sent") {
                integer type = HTTPDB_SAVE;
                if (num == LOCALSETTING_RESPONSE) {
                    type = LOCALSETTING_SAVE;
                }
                string setting = llDumpList2String([type, str], "|");
                if (llListFindList(lSettings, [setting]) == -1) {
                    lSettings += [setting];
                }
            }
        }
    }
}