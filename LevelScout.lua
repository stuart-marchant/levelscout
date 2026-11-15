-- LevelScout: dump everything useful for leveling decisions into SavedVariables.
-- Data is written to disk by the client on /reload or logout:
--   _forever_/WTF/Account/<ACCOUNT>/SavedVariables/LevelScout.lua
--
-- Commands:
--   /scout            snapshot now (char, quest log, gear, bags) + Questie scan
--   /scout zones      print best zones by available quest XP (needs Questie scan)
--   /scout status     what has been captured so far
--   /scout reset      wipe this character's XP log
--
-- Everything is probed defensively: WoW Forever runs a Mainline-derived client and
-- some Classic globals are missing, some values can be "secret".

local ADDON = ...
local VERSION = "0.4.0"
local LS = {}
_G.LevelScout = LS

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------
local function isSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- strip secret values so we never compare/serialize them
local function S(v)
    if isSecret(v) then return nil end
    return v
end

-- call f safely; returns its results or nothing
local function try(f, ...)
    if type(f) ~= "function" then return end
    return (function(ok, ...)
        if ok then return ... end
    end)(pcall(f, ...))
end

local function msg(...)
    print("|cff66ccffLevelScout|r:", ...)
end

local function now() return time() end

local function round(x, n)
    if type(x) ~= "number" then return x end
    local m = 10 ^ (n or 1)
    return math.floor(x * m + 0.5) / m
end

-- deep-copy a table keeping only plain, non-secret, serializable values
local function clean(v, depth)
    depth = depth or 0
    if isSecret(v) then return nil end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    if t ~= "table" or depth > 6 then return nil end
    local out = {}
    for k, val in pairs(v) do
        local kt = type(k)
        if (kt == "string" or kt == "number") and not isSecret(k) then
            out[k] = clean(val, depth + 1)
        end
    end
    return out
end

local function charKey()
    local name = S(try(UnitName, "player")) or "Unknown"
    local guid = S(try(UnitGUID, "player"))
    return guid or name
end

local function areaName(areaId)
    if type(areaId) ~= "number" or areaId <= 0 then return nil end
    local n = C_Map and try(C_Map.GetAreaInfo, areaId)
    return S(n)
end

local function mapName(mapId)
    if not mapId or not C_Map then return nil end
    local info = try(C_Map.GetMapInfo, mapId)
    return info and S(info.name)
end

-------------------------------------------------------------------------------
-- DB
-------------------------------------------------------------------------------
local db, cdb

local function initDB()
    LevelScoutDB = LevelScoutDB or {}
    db = LevelScoutDB
    db.schema = 1
    db.characters = db.characters or {}
    local key = charKey()
    db.characters[key] = db.characters[key] or {}
    cdb = db.characters[key]
    cdb.xpLog = cdb.xpLog or {}          -- every XP gain: {t, amount, zone, source}
    cdb.turnIns = cdb.turnIns or {}      -- QUEST_TURNED_IN
    cdb.levelUps = cdb.levelUps or {}
    cdb.sessions = cdb.sessions or {}
    cdb.zoneXP = cdb.zoneXP or {}        -- zone -> {xp, kills?, quests, seconds}
end

local function trim(list, max)
    while #list > max do table.remove(list, 1) end
end

-------------------------------------------------------------------------------
-- capture: player
-------------------------------------------------------------------------------
local function capturePlayer()
    local p = {}
    p.name = S(try(UnitName, "player"))
    p.level = S(try(UnitLevel, "player"))
    local _, classFile = try(UnitClass, "player")
    p.class = S(classFile)
    local _, raceFile = try(UnitRace, "player")
    p.race = S(raceFile)
    p.faction = S(try(UnitFactionGroup, "player"))
    p.xp = S(try(UnitXP, "player"))
    p.xpMax = S(try(UnitXPMax, "player"))
    p.rested = S(try(GetXPExhaustion))
    p.money = S(try(GetMoney))
    p.health = nil -- often secret on Forever; skip
    p.zone = S(try(GetRealZoneText))
    p.subzone = S(try(GetSubZoneText))
    p.bind = S(try(GetBindLocation))
    p.isResting = S(try(IsResting))
    if C_Map then
        local mapId = S(try(C_Map.GetBestMapForUnit, "player"))
        p.mapId = mapId
        p.mapName = mapName(mapId)
        if mapId then
            local pos = try(C_Map.GetPlayerMapPosition, mapId, "player")
            if pos and pos.GetXY then
                local x, y = pos:GetXY()
                p.x, p.y = round(S(x) and x * 100, 1), round(S(y) and y * 100, 1)
            end
        end
    end
    -- quest difficulty ranges
    p.greenRange = S(try(GetQuestGreenRange))
    if C_QuestLog then
        p.trivialRange = S(try(C_QuestLog.GetTrivialRange))  -- may not exist
        p.maxQuests = S(try(C_QuestLog.GetMaxNumQuestsCanAccept))
    end
    -- professions
    local profs = {}
    if GetProfessions then
        local list = { try(GetProfessions) }
        for i = 1, 6 do
            local idx = list[i]
            if idx then
                local name, _, rank, maxRank = try(GetProfessionInfo, idx)
                profs[#profs + 1] = { name = S(name), rank = S(rank), max = S(maxRank) }
            end
        end
    end
    p.professions = profs
    p.played = cdb.played
    return p
end

-------------------------------------------------------------------------------
-- capture: gear + bags
-------------------------------------------------------------------------------
local function itemLevel(link)
    if not link then return nil end
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        return S(try(C_Item.GetDetailedItemLevelInfo, link))
    end
    if GetDetailedItemLevelInfo then return S(try(GetDetailedItemLevelInfo, link)) end
end

local SLOT_NAMES = {
    [1]="Head",[2]="Neck",[3]="Shoulder",[4]="Shirt",[5]="Chest",[6]="Waist",[7]="Legs",
    [8]="Feet",[9]="Wrist",[10]="Hands",[11]="Finger1",[12]="Finger2",[13]="Trinket1",
    [14]="Trinket2",[15]="Back",[16]="MainHand",[17]="OffHand",[18]="Ranged",[19]="Tabard",
}

local function captureGear()
    local gear = {}
    for slot = 1, 19 do
        local link = S(try(GetInventoryItemLink, "player", slot))
        if link then
            gear[SLOT_NAMES[slot] or tostring(slot)] = { link = link, ilvl = itemLevel(link) }
        end
    end
    return gear
end

local function captureBags()
    local bags = {}
    local C = C_Container
    local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    if not numSlots then return bags end
    for bag = 0, 4 do
        local n = S(try(numSlots, bag)) or 0
        for slot = 1, n do
            local link, count
            if C and C.GetContainerItemInfo then
                local info = try(C.GetContainerItemInfo, bag, slot)
                if type(info) == "table" then
                    link, count = S(info.hyperlink), S(info.stackCount)
                end
            elseif GetContainerItemLink then
                link = S(try(GetContainerItemLink, bag, slot))
            end
            if link then
                bags[#bags + 1] = { bag = bag, slot = slot, link = link, count = count }
            end
        end
    end
    return bags
end

-------------------------------------------------------------------------------
-- Questie bridge (optional)
-------------------------------------------------------------------------------
local Q = {}

local function questieReady()
    if not (QuestieLoader and Questie and Questie.started) then return false end
    if not Q.DB then
        Q.DB = try(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
        Q.Player = try(QuestieLoader.ImportModule, QuestieLoader, "QuestiePlayer")
        Q.XP = try(QuestieLoader.ImportModule, QuestieLoader, "QuestXP")
        Q.Zone = try(QuestieLoader.ImportModule, QuestieLoader, "ZoneDB")
    end
    return Q.DB ~= nil and Q.DB.QueryQuestSingle ~= nil
end

local function qField(questId, key)
    return try(Q.DB.QueryQuestSingle, questId, key)
end

-- first spawn location of an NPC/object: {name, zone, x, y, areaId}
local function entityInfo(kind, id)
    if not id then return nil end
    local e
    if kind == "npc" then
        e = try(Q.DB.GetNPC, Q.DB, id)
    elseif kind == "object" then
        e = try(Q.DB.GetObject, Q.DB, id)
    end
    if type(e) ~= "table" then return { id = id, kind = kind } end
    local out = { id = id, kind = kind, name = e.name }
    if type(e.spawns) == "table" then
        for areaId, coords in pairs(e.spawns) do
            if type(coords) == "table" and coords[1] then
                out.areaId = areaId
                out.zone = areaName(areaId)
                out.x = round(coords[1][1], 1)
                out.y = round(coords[1][2], 1)
                break
            end
        end
    end
    return out
end

local function startersFor(questId)
    local sb = qField(questId, "startedBy")
    if type(sb) ~= "table" then return nil end
    local out = {}
    if type(sb[1]) == "table" then
        for _, id in ipairs(sb[1]) do out[#out + 1] = entityInfo("npc", id); if #out >= 2 then break end end
    end
    if type(sb[2]) == "table" then
        for _, id in ipairs(sb[2]) do out[#out + 1] = entityInfo("object", id); if #out >= 3 then break end end
    end
    if type(sb[3]) == "table" then
        for _, id in ipairs(sb[3]) do
            out[#out + 1] = { kind = "item", id = id, name = try(Q.DB.QueryItemSingle, id, "name") }
        end
    end
    return out
end

local function enderFor(questId)
    local fb = qField(questId, "finishedBy")
    if type(fb) ~= "table" then return nil end
    if type(fb[1]) == "table" and fb[1][1] then return entityInfo("npc", fb[1][1]) end
    if type(fb[2]) == "table" and fb[2][1] then return entityInfo("object", fb[2][1]) end
end

local function questXP(questId)
    if Q.XP and Q.XP.GetQuestLogRewardXP then
        return S(try(Q.XP.GetQuestLogRewardXP, Q.XP, questId))
    end
end

local function questZone(questId)
    local zos = qField(questId, "zoneOrSort")
    if type(zos) == "number" and zos > 0 then return areaName(zos), zos end
    return nil, zos
end

-------------------------------------------------------------------------------
-- capture: quest log
-------------------------------------------------------------------------------
local function objectivesFor(questId)
    local objs = C_QuestLog and try(C_QuestLog.GetQuestObjectives, questId)
    return clean(objs)
end

local function captureQuestLog()
    local log = { header = nil, quests = {} }
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
        log.error = "C_QuestLog unavailable"
        return log
    end
    local prevSel = try(C_QuestLog.GetSelectedQuest)
    local n = S(try(C_QuestLog.GetNumQuestLogEntries)) or 0
    local header
    local collapsed = {}
    for i = 1, n do
        local info = try(C_QuestLog.GetInfo, i)
        if type(info) == "table" then
            if info.isHeader then
                header = S(info.title)
                if info.isCollapsed then collapsed[#collapsed + 1] = header end
            elseif info.questID and not info.isHidden then
                local id = info.questID
                local q = {
                    id = id,
                    title = S(info.title),
                    header = header,
                    level = S(info.level),
                    difficulty = S(info.difficultyLevel),
                    suggestedGroup = S(info.suggestedGroup),
                    frequency = S(info.frequency),
                    complete = S(try(C_QuestLog.IsComplete, id)),
                    failed = S(try(C_QuestLog.IsFailed, id)),
                    objectives = objectivesFor(id),
                    rewardXP = S(try(GetQuestLogRewardXP, id)),
                    rewardMoney = S(try(GetQuestLogRewardMoney, id)),
                }
                local tag = try(C_QuestLog.GetQuestTagInfo, id)
                if type(tag) == "table" then q.tag = S(tag.tagName) end
                -- description text needs the quest selected
                if C_QuestLog.SetSelectedQuest and GetQuestLogQuestText then
                    try(C_QuestLog.SetSelectedQuest, id)
                    local desc, objText = try(GetQuestLogQuestText)
                    q.objectiveText = S(objText)
                    q.description = S(desc)
                end
                if questieReady() then
                    q.questie = {
                        requiredLevel = qField(id, "requiredLevel"),
                        questLevel = qField(id, "questLevel"),
                        zone = (questZone(id)),
                        nextInChain = qField(id, "nextQuestInChain"),
                        ender = enderFor(id),
                        estXP = questXP(id),
                    }
                end
                log.quests[#log.quests + 1] = q
            end
        end
    end
    if prevSel then try(C_QuestLog.SetSelectedQuest, prevSel) end
    log.count = #log.quests
    log.collapsedHeaders = collapsed
    return log
end

local function captureCompleted()
    if not (C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs) then return nil end
    local ids = try(C_QuestLog.GetAllCompletedQuestIDs)
    if type(ids) ~= "table" then return nil end
    local out = {}
    for _, id in ipairs(ids) do
        local entry = { id = id }
        if questieReady() then
            entry.name = qField(id, "name")
            entry.level = qField(id, "questLevel")
            entry.zone = (questZone(id))
        end
        out[#out + 1] = entry
    end
    return out
end

-------------------------------------------------------------------------------
-- Questie scan: every quest around my level that I could do (or soon could)
-------------------------------------------------------------------------------
local scan = { running = false }
local SCAN_BELOW, SCAN_ABOVE = 8, 12   -- quest level window relative to player
local CHUNK = 120

local function finishScan()
    scan.running = false
    local res = scan.result
    res.finishedAt = now()
    res.durationSec = res.finishedAt - res.startedAt
    -- zone summary
    local zones = {}
    for _, q in ipairs(res.quests) do
        local z = q.zone or ("sort:" .. tostring(q.zoneOrSort))
        local s = zones[z] or { zone = z, available = 0, availableXP = 0, locked = 0, lockedXP = 0,
                                inLog = 0, minLevel = 999, maxLevel = 0, groupQuests = 0 }
        zones[z] = s
        if q.inLog then s.inLog = s.inLog + 1
        elseif q.doable then
            s.available = s.available + 1
            s.availableXP = s.availableXP + (q.estXP or 0)
        else
            s.locked = s.locked + 1
            s.lockedXP = s.lockedXP + (q.estXP or 0)
        end
        if q.level then
            s.minLevel = math.min(s.minLevel, q.level)
            s.maxLevel = math.max(s.maxLevel, q.level)
        end
        if q.elite then s.groupQuests = s.groupQuests + 1 end
    end
    local list = {}
    for _, s in pairs(zones) do list[#list + 1] = s end
    table.sort(list, function(a, b) return a.availableXP > b.availableXP end)
    res.zoneSummary = list
    cdb.questieScan = res
    if LS.RefreshTracker then pcall(LS.RefreshTracker, true) end
    msg(("Questie scan done: %d candidate quests in %d zones (%ds). /reload to write to disk.")
        :format(#res.quests, #list, res.durationSec))
end

local function scanStep()
    local level = scan.level
    local stop = math.min(scan.i + CHUNK - 1, #scan.ids)
    for k = scan.i, stop do
        local id = scan.ids[k]
        local qlvl = qField(id, "questLevel")
        local rlvl = qField(id, "requiredLevel")
        if type(qlvl) == "number" and qlvl > 0
            and qlvl >= level - SCAN_BELOW and qlvl <= level + SCAN_ABOVE
            and Q.Player.HasRequiredRace(qField(id, "requiredRaces"))
            and Q.Player.HasRequiredClass(qField(id, "requiredClasses"))
            and not (Questie.db.char.complete and Questie.db.char.complete[id])
        then
            local hidden = Questie.db.char.hidden and Questie.db.char.hidden[id]
            local doable = try(Q.DB.IsDoable, id) and true or false
            local inLog = C_QuestLog and try(C_QuestLog.IsOnQuest, id) and true or false
            local q = {
                id = id,
                name = qField(id, "name"),
                level = qlvl,
                requiredLevel = rlvl,
                doable = doable,
                inLog = inLog,
                userHidden = hidden or nil,
                estXP = questXP(id),
                preQuestSingle = clean(qField(id, "preQuestSingle")),
                preQuestGroup = clean(qField(id, "preQuestGroup")),
                nextInChain = qField(id, "nextQuestInChain"),
                exclusiveTo = clean(qField(id, "exclusiveTo")),
            }
            q.zone, q.zoneOrSort = questZone(id)
            local flags = qField(id, "questFlags")
            -- questFlags bit 0x40 = raid, tag lookup is costlier; use objectivesText for "elite"/"group" hints later
            q.questFlags = flags
            if not doable and not inLog then
                q.whyLocked = S(try(Q.DB.IsDoableVerbose, id, false, true, true))
            end
            if not inLog then
                q.starters = startersFor(id)
                q.ender = enderFor(id)
            end
            local txt = qField(id, "objectivesText")
            if type(txt) == "table" then q.objectivesText = table.concat(txt, " ") end
            if q.objectivesText and q.objectivesText:lower():find("group") then q.elite = true end
            scan.result.quests[#scan.result.quests + 1] = q
        end
    end
    scan.i = stop + 1
    if scan.i > #scan.ids then
        finishScan()
    else
        C_Timer.After(0, LS._scanStepSafe)
    end
end

function LS._scanStepSafe()
    local ok, err = pcall(scanStep)
    if not ok then
        scan.running = false
        cdb.errors = cdb.errors or {}
        cdb.errors[#cdb.errors + 1] = { now(), "scan", tostring(err) }
        msg("scan failed: " .. tostring(err))
    end
end

function LS.StartQuestieScan()
    if scan.running then msg("scan already running") return end
    if not questieReady() then
        msg("Questie not loaded/started yet - skipping database scan (snapshot still taken).")
        return
    end
    local pointers = Q.DB.QuestPointers
    if type(pointers) ~= "table" then msg("Questie QuestPointers unavailable") return end
    local ids = {}
    for id in pairs(pointers) do
        if type(id) == "number" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    scan.ids = ids
    scan.i = 1
    scan.level = S(UnitLevel("player")) or 1
    scan.running = true
    scan.result = {
        startedAt = now(),
        playerLevel = scan.level,
        window = { scan.level - SCAN_BELOW, scan.level + SCAN_ABOVE },
        dbQuestCount = #ids,
        quests = {},
    }
    msg(("scanning %d Questie quests..."):format(#ids))
    C_Timer.After(0, LS._scanStepSafe)
end

-------------------------------------------------------------------------------
-- snapshot
-------------------------------------------------------------------------------
function LS.Snapshot(withScan, quiet)
    local snap = {
        takenAt = now(),
        takenAtText = date("%Y-%m-%d %H:%M:%S"),
        addonVersion = VERSION,
    }
    local v, build, bdate, iface = try(GetBuildInfo)
    snap.client = { version = v, build = build, date = bdate, interface = iface,
                    projectId = WOW_PROJECT_ID }
    snap.questiePresent = QuestieLoader ~= nil
    snap.questieReady = questieReady()
    snap.player = capturePlayer()
    snap.gear = captureGear()
    snap.bags = captureBags()
    snap.questLog = captureQuestLog()
    snap.completed = captureCompleted()
    snap.completedCount = snap.completed and #snap.completed or nil
    -- guard: never overwrite a good snapshot with a zeroed one
    if (snap.player.xpMax or 0) == 0 and cdb.snapshot then return end
    cdb.snapshot = snap
    if quiet then return end
    msg(("snapshot: lvl %s, %d quests in log, %s completed."):format(
        tostring(snap.player.level), snap.questLog.count or 0, tostring(snap.completedCount)))
    if withScan then LS.StartQuestieScan() end
end

-------------------------------------------------------------------------------
-- XP tracking
-------------------------------------------------------------------------------
local lastXP, lastMax, lastLevel
local session

local function zoneNow() return S(try(GetRealZoneText)) or "?" end

local function addZoneXP(zone, amount, source)
    local z = cdb.zoneXP[zone] or { xp = 0, questXP = 0, otherXP = 0, quests = 0 }
    cdb.zoneXP[zone] = z
    z.xp = z.xp + amount
    if source == "quest" then
        z.questXP = z.questXP + amount
        z.quests = z.quests + 1
    else
        z.otherXP = z.otherXP + amount
    end
end

local pendingQuestXP = 0

local function onXPUpdate()
    local xp, max, lvl = S(UnitXP("player")), S(UnitXPMax("player")), S(UnitLevel("player"))
    if not (xp and max and lvl) then return end
    if lastXP then
        local delta
        if lvl > lastLevel then
            delta = (lastMax - lastXP) + xp
        else
            delta = xp - lastXP
        end
        if delta > 0 then
            local src = "other"
            if pendingQuestXP > 0 then src = "quest"; pendingQuestXP = 0 end
            local zone = zoneNow()
            local log = cdb.xpLog
            log[#log + 1] = { now(), delta, zone, src, lvl }
            trim(log, 3000)
            addZoneXP(zone, delta, src)
            if session then session.xp = session.xp + delta end
        end
    end
    lastXP, lastMax, lastLevel = xp, max, lvl
end

-------------------------------------------------------------------------------
-- events
-------------------------------------------------------------------------------
local f = CreateFrame("Frame")
local H = {}

function H.ADDON_LOADED(name)
    if name ~= ADDON then return end
    initDB()
end

function H.PLAYER_LOGIN()
    if not cdb then initDB() end
    lastXP, lastMax, lastLevel = S(UnitXP("player")), S(UnitXPMax("player")), S(UnitLevel("player"))
    session = { start = now(), startLevel = lastLevel, startXP = lastXP, xp = 0, zoneStart = zoneNow() }
    cdb.sessions[#cdb.sessions + 1] = session
    trim(cdb.sessions, 200)
    -- give Questie time to finish its own init, then snapshot + scan
    C_Timer.After(20, function()
        local ui = LevelScoutDB and LevelScoutDB.ui
        LS.Snapshot(not (ui and ui.autoScan == false))
    end)
    C_Timer.After(25, function() try(RequestTimePlayed) end)
    if C_Timer.NewTicker then
        C_Timer.NewTicker(300, function() pcall(LS.Snapshot, false, true) end)
    end
end

function H.PLAYER_XP_UPDATE() onXPUpdate() end

function H.QUEST_TURNED_IN(questId, xpReward, moneyReward)
    xpReward = S(xpReward) or 0
    -- XP_UPDATE may have fired first: re-tag that gain as quest XP
    local last = cdb.xpLog[#cdb.xpLog]
    if xpReward > 0 and last and last[4] == "other" and now() - last[1] <= 2 then
        last[4] = "quest"
        local z = cdb.zoneXP[last[3]]
        if z then
            z.otherXP = z.otherXP - last[2]
            z.questXP = z.questXP + last[2]
            z.quests = z.quests + 1
        end
    else
        pendingQuestXP = xpReward
    end
    local t = { now(), questId, S(xpReward), S(moneyReward), zoneNow(), S(UnitLevel("player")) }
    if questieReady() then t[7] = qField(questId, "name") end
    cdb.turnIns[#cdb.turnIns + 1] = t
    trim(cdb.turnIns, 1000)
end

function H.PLAYER_LEVEL_UP(level)
    local played = cdb.played and cdb.played.total
    cdb.levelUps[#cdb.levelUps + 1] = { now(), S(level), zoneNow(), played }
    C_Timer.After(5, function()
        local ui = LevelScoutDB and LevelScoutDB.ui
        LS.Snapshot(not (ui and ui.autoScan == false))
    end)
end

function H.TIME_PLAYED_MSG(total, thisLevel)
    cdb.played = { total = S(total), thisLevel = S(thisLevel), at = now() }
end

function H.PLAYER_LOGOUT()
    if session then
        session.stop = now()
        session.endLevel = S(UnitLevel("player"))
        session.endXP = S(UnitXP("player"))
    end
    -- NOTE: unit/quest APIs return zeros during logout/reload on Forever, so we do
    -- NOT re-snapshot here; snapshots are refreshed periodically and on level-up.
end

f:SetScript("OnEvent", function(_, event, ...)
    local h = H[event]
    if h then
        local ok, err = pcall(h, ...)
        if not ok then
            if cdb then
                cdb.errors = cdb.errors or {}
                cdb.errors[#cdb.errors + 1] = { now(), event, tostring(err) }
                trim(cdb.errors, 50)
            end
        end
    end
end)
for ev in pairs(H) do
    pcall(f.RegisterEvent, f, ev)
end

-------------------------------------------------------------------------------
-- slash
-------------------------------------------------------------------------------
SLASH_LEVELSCOUT1 = "/scout"
SLASH_LEVELSCOUT2 = "/levelscout"
SlashCmdList.LEVELSCOUT = function(arg)
    arg = (arg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "" or arg == "scan" then
        LS.Snapshot(true)
    elseif arg == "zones" then
        local res = cdb.questieScan
        if not res then msg("no scan yet - run /scout") return end
        msg(("best zones for level %d (by available quest XP):"):format(res.playerLevel))
        for i = 1, math.min(8, #res.zoneSummary) do
            local s = res.zoneSummary[i]
            print(("  %d. %s - %d quests, ~%d xp (lvl %d-%d), %d locked, %d in log")
                :format(i, s.zone, s.available, s.availableXP, s.minLevel, s.maxLevel, s.locked, s.inLog))
        end
    elseif arg == "status" then
        local s = cdb.snapshot
        msg(("snapshot: %s | scan: %s | xp events: %d | turn-ins: %d"):format(
            s and s.takenAtText or "none",
            cdb.questieScan and (#cdb.questieScan.quests .. " quests") or (scan.running and "running" or "none"),
            #cdb.xpLog, #cdb.turnIns))
    elseif arg == "reset" then
        cdb.xpLog, cdb.turnIns, cdb.levelUps, cdb.zoneXP, cdb.sessions = {}, {}, {}, {}, {}
        msg("XP history cleared for this character.")
    elseif LS.SlashExtra and LS.SlashExtra(arg) then
        -- handled by Tracker.lua
    else
        msg("/scout [scan|zones|status|reset|ui|config|lock|compact|resetui]")
    end
end

-------------------------------------------------------------------------------
-- exports for Tracker.lua
-------------------------------------------------------------------------------
LS.S, LS.try, LS.msg, LS.now, LS.round = S, try, msg, now, round
LS.areaName = areaName
LS.questieReady = questieReady
LS.qField = qField
LS.entityInfo = entityInfo
LS.enderFor = enderFor
LS.startersFor = startersFor
LS.questXP = questXP
LS.questZone = questZone
LS.Q = Q
function LS.GetCharDB() return cdb end
function LS.GetSession() return session end
