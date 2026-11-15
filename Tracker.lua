-- LevelScout Tracker: an on-screen leveling/quest tracker built from the live quest log,
-- the game's real XP rewards, and (optionally) Questie's database.
--
--   /scout ui       toggle the window
--   /scout lock     lock/unlock moving & resizing
--   /scout compact  hide/show objective lines for quests outside your zone
--   /scout resetui  reset position/size
--
-- Left-click a quest: set a waypoint to its turn-in (or giver). TomTom if present, else map pin.
-- Hover: tooltip with objectives, description and the follow-up chain.

local LS = LevelScout
if not LS then return end
local S, try, msg, now, round = LS.S, LS.try, LS.msg, LS.now, LS.round

-------------------------------------------------------------------------------
-- settings
-------------------------------------------------------------------------------
local ui -- LevelScoutDB.ui (account-wide)

local DEFAULTS = {
    shown = true, locked = false, compact = true, alpha = 0.85,
    w = 320, h = 460,
    collapsed = { other = true, abandon = true },
    maxPickups = 8,
    -- options (see Options.lua)
    hideBlizzTracker = true,  -- hide the default objective/quest tracker
    splitCompleted = true,    -- two "completed" groups (turn in here / elsewhere)
    showPickups = true,
    showDungeon = true,
    showOther = true,
    showAbandon = true,
    showZones = true,
    progressFirst = true,
    -- chat (Chat.lua)
    chatMarkup = true,        -- tag linked quests in chat
    chatMarkAvailable = false,-- also tag quests you could pick up
    chatMarkDone = false,     -- also tag quests already done / complete in log
    chatSound = false,        -- ready-check sound when a linked quest is one you're on     -- quests with objective progress sort above untouched ones
    autoScan = true,          -- Questie scan on login / level up
}
LS.DEFAULTS = DEFAULTS

local function initUI()
    LevelScoutDB = LevelScoutDB or {}
    LevelScoutDB.ui = LevelScoutDB.ui or {}
    ui = LevelScoutDB.ui
    for k, v in pairs(DEFAULTS) do
        if ui[k] == nil then
            ui[k] = type(v) == "table" and CopyTable and CopyTable(v) or v
        end
    end
    if type(ui.collapsed) ~= "table" then ui.collapsed = { other = true, abandon = true } end
    -- one-time: re-show the window after upgrading (0.2.0 could leave it hidden)
    if ui.seenVersion ~= "0.2.1" then ui.shown = true; ui.seenVersion = "0.2.1" end
end

-------------------------------------------------------------------------------
-- formatting
-------------------------------------------------------------------------------
local function kfmt(n)
    if type(n) ~= "number" then return "?" end
    if n >= 10000 then return ("%.0fk"):format(n / 1000) end
    if n >= 1000 then return ("%.1fk"):format(n / 1000) end
    return tostring(n)
end

local function hex(r, g, b)
    return ("ff%02x%02x%02x"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local GRAY, GREEN, YELLOW, ORANGE, RED = "ff808080", "ff40c040", "ffffff00", "ffff8040", "ffff2020"
local DIM, WHITE, CYAN, GOLD = "ffa0a0a0", "ffffffff", "ff66ccff", "ffffd100"

local function color(c, s) return "|c" .. c .. s .. "|r" end

local function playerLevel() return S(UnitLevel("player")) or 1 end

local function trivialRange()
    local r = S(try(GetQuestGreenRange))
    if type(r) == "number" then return r end
    if C_QuestLog then
        r = S(try(C_QuestLog.GetTrivialRange))   -- reported 6 at lvl 28 on Forever
        if type(r) == "number" then return r end
    end
    local L = playerLevel()
    return L <= 5 and 5 or (math.floor(L / 10) + 5)
end

-- returns color, category ("trivial","standard","difficult","verydifficult","impossible")
local function levelColor(qlvl)
    if type(qlvl) ~= "number" or qlvl <= 0 then return WHITE, "standard" end
    local d = qlvl - playerLevel()
    if d >= 5 then return RED, "impossible"
    elseif d >= 3 then return ORANGE, "verydifficult"
    elseif d >= -2 then return YELLOW, "difficult"
    elseif -d <= trivialRange() then return GREEN, "standard"
    else return GRAY, "trivial" end
end

local DUNGEON_TAGS = { Dungeon = true, Raid = true, Heroic = true }
local GROUP_TAGS = { Elite = true, Group = true }

-------------------------------------------------------------------------------
-- waypoints
-------------------------------------------------------------------------------
local function uiMapFor(areaId)
    local Q = LS.Q
    if Q and Q.Zone and Q.Zone.GetUiMapIdByAreaId then
        local m = try(Q.Zone.GetUiMapIdByAreaId, Q.Zone, areaId)
        if m then return m end
    end
    return nil
end

local function setWaypoint(loc, title)
    if not (loc and loc.areaId and loc.x and loc.y) then
        msg("no known location for " .. tostring(title))
        return
    end
    local mapId = uiMapFor(loc.areaId)
    if not mapId then msg("can't resolve map for " .. tostring(loc.zone)) return end
    local label = ("%s: %s"):format(title or "?", loc.name or "")
    if TomTom and TomTom.AddWaypoint then
        try(TomTom.AddWaypoint, TomTom, mapId, loc.x / 100, loc.y / 100,
            { title = label, persistent = false, minimap = true, world = true, from = "LevelScout" })
        msg(("TomTom -> %s (%s %.1f, %.1f)"):format(label, loc.zone or "?", loc.x, loc.y))
        return
    end
    if C_Map and C_Map.SetUserWaypoint and UiMapPoint then
        local pt = try(UiMapPoint.CreateFromCoordinates, mapId, loc.x / 100, loc.y / 100)
        if pt then try(C_Map.SetUserWaypoint, pt) end
        msg(("map pin -> %s (%s %.1f, %.1f)"):format(label, loc.zone or "?", loc.x, loc.y))
    end
end

-------------------------------------------------------------------------------
-- model
-------------------------------------------------------------------------------
local chainCache = {}

-- XP of the follow-up chain after questId (Questie estimates), and next quest name
local function chainInfo(questId)
    if chainCache[questId] then return chainCache[questId] end
    local res = { xp = 0, steps = {} }
    if LS.questieReady() then
        local id, guard = LS.qField(questId, "nextQuestInChain"), 0
        while type(id) == "number" and id > 0 and guard < 10 do
            guard = guard + 1
            local name = LS.qField(id, "name")
            local lvl = LS.qField(id, "questLevel")
            local xp = LS.questXP(id) or 0
            res.xp = res.xp + xp
            res.steps[#res.steps + 1] = { id = id, name = name, level = lvl, xp = xp }
            id = LS.qField(id, "nextQuestInChain")
        end
    end
    chainCache[questId] = res
    return res
end

local enderCache = {}
local function enderLoc(questId)
    if enderCache[questId] == nil then
        enderCache[questId] = (LS.questieReady() and LS.enderFor(questId)) or false
    end
    return enderCache[questId] or nil
end

local function readQuestLog()
    local list, headerZone = {}, nil
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then return list end
    local n = S(try(C_QuestLog.GetNumQuestLogEntries)) or 0
    for i = 1, n do
        local info = try(C_QuestLog.GetInfo, i)
        if type(info) == "table" then
            if info.isHeader then
                headerZone = S(info.title)
            elseif info.questID and not info.isHidden then
                local id = info.questID
                local q = {
                    id = id,
                    title = S(info.title) or ("Quest " .. id),
                    level = S(info.difficultyLevel) or S(info.level),
                    header = headerZone,
                    complete = S(try(C_QuestLog.IsComplete, id)) and true or false,
                    failed = S(try(C_QuestLog.IsFailed, id)) and true or false,
                    xp = S(try(GetQuestLogRewardXP, id)) or 0,
                    objectives = try(C_QuestLog.GetQuestObjectives, id),
                    suggestedGroup = S(info.suggestedGroup) or 0,
                }
                local tag = try(C_QuestLog.GetQuestTagInfo, id)
                q.tag = type(tag) == "table" and S(tag.tagName) or nil
                q.dungeon = q.tag and DUNGEON_TAGS[q.tag] or false
                q.group = (q.tag and GROUP_TAGS[q.tag]) or q.suggestedGroup > 1 or false
                q.pvp = q.tag == "PvP"
                q.color, q.diff = levelColor(q.level)
                list[#list + 1] = q
            end
        end
    end
    return list
end

local function xpRate()
    local cdb = LS.GetCharDB()
    local sess = LS.GetSession()
    if not (cdb and sess) then return nil end
    local t = now()
    local window = math.min(3600, math.max(60, t - (sess.start or t)))
    local sum = 0
    for i = #cdb.xpLog, 1, -1 do
        local e = cdb.xpLog[i]
        if e[1] < t - window then break end
        sum = sum + (e[2] or 0)
    end
    return sum * 3600 / window, sum, window
end

local function buildModel()
    local m = {}
    m.level = playerLevel()
    m.xp = S(UnitXP("player")) or 0
    m.xpMax = S(UnitXPMax("player")) or 1
    m.rested = S(try(GetXPExhaustion)) or 0
    m.zone = S(try(GetRealZoneText)) or "?"
    m.rate = xpRate()
    local maxQ = C_QuestLog and S(try(C_QuestLog.GetMaxNumQuestsCanAccept))

    local quests = readQuestLog()
    m.logCount, m.logMax = #quests, maxQ

    local readyHere, readyElse, here, dungeon, other, abandon = {}, {}, {}, {}, {}, {}
    local readyHereXP, readyElseXP, hereXP, dungeonXP = 0, 0, 0, 0
    local minUseful = m.xpMax * 0.02
    for _, q in ipairs(quests) do
        q.ender = enderLoc(q.id)
        q.chain = chainInfo(q.id)
        local qZone = LS.questieReady() and (LS.questZone(q.id)) or nil
        local endZone = q.ender and q.ender.zone
        q.isHere = (q.header == m.zone) or (qZone == m.zone) or (endZone == m.zone)
        if q.complete then
            -- for completed quests "here" means: the turn-in NPC is in this zone
            local turnInHere
            if endZone then turnInHere = (endZone == m.zone) else turnInHere = q.isHere end
            if turnInHere then
                readyHere[#readyHere + 1] = q; readyHereXP = readyHereXP + q.xp
            else
                readyElse[#readyElse + 1] = q; readyElseXP = readyElseXP + q.xp
            end
        elseif q.pvp or (q.diff == "trivial" and q.chain.xp < minUseful and not q.dungeon)
            or (q.xp < minUseful and q.chain.xp < minUseful and not q.dungeon) then
            abandon[#abandon + 1] = q
        elseif q.dungeon then
            dungeon[#dungeon + 1] = q; dungeonXP = dungeonXP + q.xp
        elseif q.isHere then
            here[#here + 1] = q; hereXP = hereXP + q.xp
        else
            other[#other + 1] = q
        end
    end
    -- "started" = any objective has progress (n > 0) or is finished
    for _, q in ipairs(quests) do
        local started = false
        if type(q.objectives) == "table" then
            for _, o in ipairs(q.objectives) do
                local n = S(o.numFulfilled)
                if S(o.finished) or (type(n) == "number" and n > 0) then started = true break end
            end
        end
        q.started = started
    end
    local progressFirst = ui.progressFirst
    local function startedFirst(a, b)
        if progressFirst and a.started ~= b.started then return true, a.started end
        return false
    end
    local byValue = function(a, b)
        local decided, r = startedFirst(a, b)
        if decided then return r end
        return (a.xp + a.chain.xp) > (b.xp + b.chain.xp)
    end
    local byXP = function(a, b) return a.xp > b.xp end
    table.sort(readyHere, byXP)
    table.sort(readyElse, function(a, b)
        local za, zb = a.ender and a.ender.zone or "", b.ender and b.ender.zone or ""
        if za ~= zb then return za < zb end
        return a.xp > b.xp
    end)
    table.sort(here, byValue); table.sort(dungeon, byValue)
    table.sort(other, function(a, b)
        if (a.header or "") ~= (b.header or "") then return (a.header or "") < (b.header or "") end
        local decided, r = startedFirst(a, b)
        if decided then return r end
        return a.xp > b.xp
    end)
    m.readyHere, m.readyElse, m.here, m.dungeon, m.other, m.abandon = readyHere, readyElse, here, dungeon, other, abandon
    m.readyHereXP, m.readyElseXP, m.hereXP, m.dungeonXP = readyHereXP, readyElseXP, hereXP, dungeonXP

    -- pickups from the Questie scan, filtered live
    m.pickups = {}
    local cdb = LS.GetCharDB()
    local scanRes = cdb and cdb.questieScan
    if scanRes and LS.questieReady() then
        local Q = LS.Q
        for _, c in ipairs(scanRes.quests) do
            if not c.inLog and c.doable then
                local st = c.starters and c.starters[1]
                local stZone = st and st.zone
                if (c.zone == m.zone or stZone == m.zone)
                    and not try(C_QuestLog.IsOnQuest, c.id)
                    and not try(C_QuestLog.IsQuestFlaggedCompleted, c.id)
                    and try(Q.DB.IsDoable, c.id) then
                    local ch = chainInfo(c.id)
                    m.pickups[#m.pickups + 1] = {
                        id = c.id, title = c.name, level = c.level, xp = c.estXP or 0,
                        chain = ch, starter = st, elite = c.elite,
                        color = (levelColor(c.level)),
                    }
                end
            end
        end
        table.sort(m.pickups, function(a, b) return (a.xp + a.chain.xp) > (b.xp + b.chain.xp) end)
        -- next zones: available XP, where most quests are not above us
        m.zones = {}
        for _, z in ipairs(scanRes.zoneSummary or {}) do
            if z.available >= 4 and z.minLevel <= m.level + 3 and z.zone ~= m.zone
                and not tostring(z.zone):find("^sort:") then
                m.zones[#m.zones + 1] = z
                if #m.zones >= 3 then break end
            end
        end
        m.scanLevel = scanRes.playerLevel
    end
    return m
end

-------------------------------------------------------------------------------
-- frame
-------------------------------------------------------------------------------
local F, scroll, child, xpBar, restBar, xpText, statText
local rows, rowCount = {}, 0
local ROW_H = 14

local function tooltipFor(row)
    local d = row.data
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    if d.kind == "quest" or d.kind == "pickup" then
        local q = d.q
        GameTooltip:AddLine(("[%s] %s"):format(tostring(q.level or "?"), q.title or "?"), 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Reward XP", kfmt(q.xp) .. (d.kind == "pickup" and " (Questie est.)" or ""), 1, 1, 1, 1, 1, 1)
        if q.tag then GameTooltip:AddDoubleLine("Type", q.tag, 1, 1, 1, 1, 0.5, 0.25) end
        if type(q.objectives) == "table" then
            for _, o in ipairs(q.objectives) do
                local t = S(o.text)
                if t then
                    if o.finished then GameTooltip:AddLine("  " .. t, 0.3, 0.9, 0.3)
                    else GameTooltip:AddLine("  " .. t, 0.85, 0.85, 0.85) end
                end
            end
        end
        local loc = (d.kind == "pickup") and q.starter or q.ender
        if loc and loc.name then
            GameTooltip:AddLine(((d.kind == "pickup") and "Giver: " or "Turn in: ") ..
                ("%s - %s %s,%s"):format(loc.name, loc.zone or "?", tostring(loc.x), tostring(loc.y)), 0.4, 0.8, 1)
        end
        if q.chain and #q.chain.steps > 0 then
            GameTooltip:AddLine(("Leads to (+%s xp):"):format(kfmt(q.chain.xp)), 1, 0.82, 0)
            for i, s in ipairs(q.chain.steps) do
                if i > 6 then break end
                GameTooltip:AddLine(("  %s (%s) %s"):format(tostring(s.name), tostring(s.level), kfmt(s.xp)), 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:AddLine("Click: waypoint", 0.5, 0.5, 0.5)
    elseif d.tip then
        GameTooltip:AddLine(d.tip, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function getRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, child)
    r:SetHeight(ROW_H)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", 2, 0)
    r.left:SetJustifyH("LEFT")
    r.left:SetWordWrap(false)
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -2, 0)
    r.right:SetJustifyH("RIGHT")
    r.left:SetPoint("RIGHT", r.right, "LEFT", -4, 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnEnter", tooltipFor)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
        local d = self.data
        if not d then return end
        if d.section then
            ui.collapsed[d.section] = not ui.collapsed[d.section]
            LS.RefreshTracker(true)
        elseif d.kind == "quest" then
            setWaypoint(d.q.ender, d.q.title)
        elseif d.kind == "pickup" then
            setWaypoint(d.q.starter, d.q.title)
        end
    end)
    rows[i] = r
    return r
end

local function addRow(left, right, data, indent)
    rowCount = rowCount + 1
    local r = getRow(rowCount)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", child, "TOPLEFT", indent or 0, -(rowCount - 1) * ROW_H)
    r:SetPoint("RIGHT", child, "RIGHT", 0, 0)
    r.left:SetText(left or "")
    r.right:SetText(right or "")
    r.data = data
    r:Show()
    return r
end

local function sectionRow(key, title, count, xp)
    local collapsed = ui.collapsed[key]
    local arrow = collapsed and "+ " or "- "
    addRow(color(GOLD, arrow .. title .. (count and (" (" .. count .. ")") or "")),
        xp and xp > 0 and color(GOLD, kfmt(xp) .. " xp") or "", { section = key })
    return not collapsed
end

local function questLine(q, showObjectives, showWhere)
    local tagTxt = ""
    if q.dungeon then tagTxt = color(ORANGE, " [D]")
    elseif q.group then tagTxt = color(ORANGE, " [G]") end
    local chainTxt = (q.chain and q.chain.xp > 0) and color(DIM, " +" .. kfmt(q.chain.xp)) or ""
    addRow(color(q.color, ("[%s] %s"):format(tostring(q.level or "?"), q.title)) .. tagTxt,
        color(WHITE, kfmt(q.xp)) .. chainTxt, { kind = "quest", q = q })
    if showWhere and q.ender and q.ender.name then
        addRow(color(CYAN, ("-> %s, %s %s,%s"):format(q.ender.name, q.ender.zone or "?",
            tostring(q.ender.x), tostring(q.ender.y))), "", { kind = "quest", q = q }, 10)
    end
    if showObjectives and type(q.objectives) == "table" then
        for _, o in ipairs(q.objectives) do
            local t = S(o.text)
            if t and t ~= "" then
                addRow(color(o.finished and GREEN or DIM, t), "", { kind = "quest", q = q }, 10)
            end
        end
    end
end

local function render(m)
    rowCount = 0
    -- header stats
    local pct = m.xp / math.max(1, m.xpMax)
    xpBar:SetMinMaxValues(0, m.xpMax); xpBar:SetValue(m.xp)
    restBar:SetMinMaxValues(0, m.xpMax); restBar:SetValue(math.min(m.xpMax, m.xp + m.rested))
    xpText:SetText(("Lvl %d  %s / %s  (%d%%)%s"):format(m.level, kfmt(m.xp), kfmt(m.xpMax), pct * 100,
        m.rested > 0 and ("  rested " .. kfmt(m.rested)) or ""))
    local need = m.xpMax - m.xp
    local rateTxt = ""
    if m.rate and m.rate > 0 then
        local eta = need / m.rate * 60
        rateTxt = ("  %s xp/h, lvl in %s"):format(kfmt(math.floor(m.rate)),
            eta >= 60 and ("%.1fh"):format(eta / 60) or ("%dm"):format(eta))
    end
    local covered = m.readyHereXP + m.hereXP
    statText:SetText(("Need %s.  Here (done+active): %s (%d%%)%s\nLog %d/%s  |  %s"):format(
        kfmt(need), kfmt(covered), math.min(999, covered * 100 / math.max(1, need)), rateTxt,
        m.logCount, tostring(m.logMax or "?"), m.zone))

    if ui.splitCompleted then
        if #m.readyHere > 0 and sectionRow("readyHere", "Completed - turn in here", #m.readyHere, m.readyHereXP) then
            for _, q in ipairs(m.readyHere) do questLine(q, false, true) end
        end
        if #m.readyElse > 0 and sectionRow("readyElse", "Completed - turn in elsewhere", #m.readyElse, m.readyElseXP) then
            for _, q in ipairs(m.readyElse) do questLine(q, false, true) end
        end
    else
        local n = #m.readyHere + #m.readyElse
        if n > 0 and sectionRow("ready", "Ready to turn in", n, m.readyHereXP + m.readyElseXP) then
            -- current-zone turn-ins first
            for _, q in ipairs(m.readyHere) do questLine(q, false, true) end
            for _, q in ipairs(m.readyElse) do questLine(q, false, true) end
        end
    end
    if sectionRow("here", "In " .. m.zone, #m.here, m.hereXP) then
        if #m.here == 0 then addRow(color(DIM, "  nothing active here"), "") end
        for _, q in ipairs(m.here) do questLine(q, true, false) end
    end
    if ui.showPickups and #m.pickups > 0 and sectionRow("pickups", "Pick up here", #m.pickups) then
        for i, p in ipairs(m.pickups) do
            if i > (ui.maxPickups or 8) then break end
            local chainTxt = p.chain.xp > 0 and color(DIM, " +" .. kfmt(p.chain.xp)) or ""
            addRow(color(p.color, ("[%d] %s"):format(p.level, p.title or "?")) .. (p.elite and color(ORANGE, " [G]") or ""),
                color(WHITE, "~" .. kfmt(p.xp)) .. chainTxt, { kind = "pickup", q = p })
            if p.starter and p.starter.name and not ui.compact then
                addRow(color(CYAN, ("@ %s %s,%s"):format(p.starter.name, tostring(p.starter.x), tostring(p.starter.y))),
                    "", { kind = "pickup", q = p }, 10)
            end
        end
    end
    if ui.showDungeon and #m.dungeon > 0 and sectionRow("dungeon", "Dungeon (group)", #m.dungeon, m.dungeonXP) then
        local lastHeader
        for _, q in ipairs(m.dungeon) do
            questLine(q, false, false)
        end
    end
    if ui.showOther and #m.other > 0 and sectionRow("other", "Other zones", #m.other) then
        local lastHeader
        for _, q in ipairs(m.other) do
            if q.header ~= lastHeader then
                addRow(color(DIM, "  " .. tostring(q.header)), "")
                lastHeader = q.header
            end
            questLine(q, not ui.compact, false)
        end
    end
    if ui.showAbandon and #m.abandon > 0 and sectionRow("abandon", "Low value (consider abandoning)", #m.abandon) then
        for _, q in ipairs(m.abandon) do questLine(q, false, false) end
    end
    if ui.showZones and m.zones and #m.zones > 0 and sectionRow("zones", "Next zones") then
        for _, z in ipairs(m.zones) do
            addRow(color(WHITE, ("%s (%d-%d)"):format(z.zone, z.minLevel, z.maxLevel)),
                color(DIM, ("%d q, ~%s"):format(z.available, kfmt(z.availableXP))),
                { tip = ("%d available, %d locked behind prereqs/level"):format(z.available, z.locked) })
        end
        if m.scanLevel and m.scanLevel ~= m.level then
            addRow(color(DIM, ("  (scan from lvl %d - /scout to refresh)"):format(m.scanLevel)), "")
        end
    end
    if not LS.questieReady() then
        addRow(color(DIM, "Questie not ready: no turn-in locations / pickups"), "")
    end

    for i = rowCount + 1, #rows do rows[i]:Hide(); rows[i].data = nil end
    child:SetHeight(math.max(1, rowCount * ROW_H))
    child:SetWidth(scroll:GetWidth())
    local maxScroll = math.max(0, rowCount * ROW_H - scroll:GetHeight())
    if scroll:GetVerticalScroll() > maxScroll then scroll:SetVerticalScroll(maxScroll) end
end

local function savePos()
    local p, _, rp, x, y = F:GetPoint(1)
    ui.point = { p, rp, x, y }
    ui.w, ui.h = F:GetWidth(), F:GetHeight()
end

local function applyLock()
    F.grip:SetShown(not ui.locked)
end

-------------------------------------------------------------------------------
-- Blizzard objective tracker visibility (same approach Questie uses on Forever:
-- hook OnShow, and defer while in combat if the frame is protected)
-------------------------------------------------------------------------------
local blizzHooked, weHidBlizz = false, false
local blizzEvents = CreateFrame("Frame")

local function blizzTracker()
    return ObjectiveTrackerFrame or QuestWatchFrame or WatchFrame
end

local function applyBlizzTracker()
    local T = blizzTracker()
    if not T then return end
    local wantHidden = ui and ui.hideBlizzTracker
    if InCombatLockdown() and T.IsProtected and T:IsProtected() then
        blizzEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    blizzEvents:UnregisterEvent("PLAYER_REGEN_ENABLED")
    if wantHidden then
        if T:IsShown() then T:Hide() end
        weHidBlizz = true
    elseif weHidBlizz then
        -- only undo what we did; don't fight Questie if it also hides it
        weHidBlizz = false
        T:Show()
    end
end
blizzEvents:SetScript("OnEvent", applyBlizzTracker)

function LS.ApplyBlizzTracker()
    local T = blizzTracker()
    if T and not blizzHooked then
        T:HookScript("OnShow", function()
            if ui and ui.hideBlizzTracker then applyBlizzTracker() end
        end)
        blizzHooked = true
    end
    applyBlizzTracker()
end

function LS.GetUI() return ui end
function LS.ApplyLock() if F then applyLock() end end
function LS.SetTrackerShown(v)
    if not F then return end
    ui.shown = v and true or false
    if not ui.shown then F.userHide = true end
    F:SetShown(ui.shown)
    if ui.shown then LS.RefreshTracker(true) end
end
function LS.SetAlpha(a)
    ui.alpha = a
    if F and F.SetBackdropColor then F:SetBackdropColor(0, 0, 0, a) end
end

local function createFrame()
    F = CreateFrame("Frame", "LevelScoutTracker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    F:SetSize(ui.w, ui.h)
    if ui.point then
        F:SetPoint(ui.point[1], UIParent, ui.point[2], ui.point[3], ui.point[4])
    else
        F:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    end
    F:SetFrameStrata("MEDIUM")
    F:SetClampedToScreen(true)
    F:SetMovable(true)
    F:SetResizable(true)
    if F.SetResizeBounds then F:SetResizeBounds(220, 160, 700, 1400)
    elseif F.SetMinResize then F:SetMinResize(220, 160) end
    if F.SetBackdrop then
        F:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        F:SetBackdropColor(0, 0, 0, ui.alpha)
        F:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    else
        local bg = F:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, ui.alpha)
    end

    -- title bar (drag handle)
    local title = CreateFrame("Button", nil, F)
    title:SetPoint("TOPLEFT", 4, -4); title:SetPoint("TOPRIGHT", -40, -4); title:SetHeight(16)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() if not ui.locked then F:StartMoving() end end)
    title:SetScript("OnDragStop", function() F:StopMovingOrSizing(); savePos() end)
    local tt = title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tt:SetPoint("LEFT", 2, 0); tt:SetText("LevelScout")

    local close = CreateFrame("Button", nil, F, "UIPanelCloseButton")
    close:SetSize(20, 20); close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        ui.shown = false
        F.userHide = true
        F:Hide()
        msg("tracker hidden - /scout ui (or the addon menu on the minimap) to show it again")
    end)

    -- refresh button sits next to the title, far from the close button
    local refresh = CreateFrame("Button", nil, F)
    refresh:SetSize(16, 16); refresh:SetPoint("LEFT", tt, "RIGHT", 6, 0)
    local rt = refresh:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); rt:SetPoint("CENTER"); rt:SetText("R")
    refresh:SetScript("OnClick", function() LS.Snapshot(true) end)
    refresh:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:AddLine("Re-scan Questie database"); GameTooltip:Show()
    end)
    refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- XP bar
    restBar = CreateFrame("StatusBar", nil, F)
    restBar:SetPoint("TOPLEFT", 6, -22); restBar:SetPoint("TOPRIGHT", -6, -22); restBar:SetHeight(14)
    restBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    restBar:SetStatusBarColor(0.25, 0.4, 0.9, 0.5)
    local rbg = restBar:CreateTexture(nil, "BACKGROUND"); rbg:SetAllPoints(); rbg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    xpBar = CreateFrame("StatusBar", nil, restBar)
    xpBar:SetAllPoints()
    xpBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    xpBar:SetStatusBarColor(0.6, 0.2, 0.8, 1)
    xpText = xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xpText:SetPoint("CENTER")

    statText = F:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statText:SetPoint("TOPLEFT", restBar, "BOTTOMLEFT", 0, -3)
    statText:SetPoint("TOPRIGHT", restBar, "BOTTOMRIGHT", 0, -3)
    statText:SetJustifyH("LEFT")

    -- scroll area
    scroll = CreateFrame("ScrollFrame", nil, F)
    scroll:SetPoint("TOPLEFT", 6, -66); scroll:SetPoint("BOTTOMRIGHT", -6, 10)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(ui.w - 12, 10)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, child:GetHeight() - self:GetHeight())
        local v = math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 3))
        self:SetVerticalScroll(v)
    end)
    scroll:SetScript("OnSizeChanged", function() child:SetWidth(scroll:GetWidth()) end)

    -- resize grip
    local grip = CreateFrame("Button", nil, F)
    grip:SetSize(14, 14); grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() if not ui.locked then F:StartSizing("BOTTOMRIGHT") end end)
    grip:SetScript("OnMouseUp", function() F:StopMovingOrSizing(); savePos(); LS.RefreshTracker(true) end)
    F.grip = grip
    applyLock()

    -- diagnostics: record any hide we didn't ask for (with a stack), and keep
    -- ui.shown so a /reload brings the window back
    F:SetScript("OnHide", function()
        local cdb = LS.GetCharDB()
        if F.userHide then F.userHide = nil return end
        if cdb then
            cdb.hideLog = cdb.hideLog or {}
            local stack = debugstack and try(debugstack, 2, 12, 0) or "?"
            cdb.hideLog[#cdb.hideLog + 1] = {
                now(), S(try(GetRealZoneText)), S(try(IsInInstance)) and true or false,
                InCombatLockdown and InCombatLockdown() or false,
                UIParent and UIParent:IsShown() or false, stack,
            }
            while #cdb.hideLog > 30 do table.remove(cdb.hideLog, 1) end
        end
    end)

    F:SetShown(ui.shown)
    if not ui.shown then
        C_Timer.After(10, function()
            msg("tracker is hidden - /scout ui to show it")
        end)
    end
end

-------------------------------------------------------------------------------
-- refresh (throttled)
-------------------------------------------------------------------------------
local pending, pendingAt = false, 0
function LS.RefreshTracker(immediate)
    if not F or not F:IsShown() then return end
    local function go()
        pending = false
        local ok, err = pcall(function() render(buildModel()) end)
        if not ok then
            local cdb = LS.GetCharDB()
            if cdb then
                cdb.errors = cdb.errors or {}
                cdb.errors[#cdb.errors + 1] = { now(), "tracker", tostring(err) }
                while #cdb.errors > 50 do table.remove(cdb.errors, 1) end
            end
        end
    end
    if immediate then go() return end
    -- if the client dropped our timer (Forever caps/resets addon timers), don't stay stuck
    if pending and (GetTime() - pendingAt) < 3 then return end
    pending, pendingAt = true, GetTime()
    C_Timer.After(0.4, go)
end

local ev = CreateFrame("Frame")
local EVENTS = {
    "PLAYER_LOGIN", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
    "UNIT_QUEST_LOG_CHANGED", "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION", "PLAYER_LEVEL_UP",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
}
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" then
        initUI()
        local ok, err = pcall(createFrame)
        if not ok then msg("tracker failed to build: " .. tostring(err)) return end
        pcall(LS.ApplyBlizzTracker)
        C_Timer.After(3, function() pcall(LS.ApplyBlizzTracker) end)
        -- refresh once Questie is up and the scan has had time to run
        C_Timer.After(2, function() LS.RefreshTracker(true) end)
        C_Timer.After(25, function() wipe(chainCache); wipe(enderCache); LS.RefreshTracker(true) end)
        if C_Timer.NewTicker then C_Timer.NewTicker(30, function() LS.RefreshTracker() end) end
        return
    end
    if e == "PLAYER_LEVEL_UP" then wipe(chainCache) end
    LS.RefreshTracker()
end)

-------------------------------------------------------------------------------
-- slash extensions
-------------------------------------------------------------------------------
function LS.SlashExtra(arg)
    if not F then return false end
    if arg == "ui" then
        LS.SetTrackerShown(not F:IsShown())
        return true
    elseif arg == "config" or arg == "options" then
        if LS.OpenOptions then LS.OpenOptions() end
        return true
    elseif arg == "lock" then
        ui.locked = not ui.locked
        applyLock()
        msg(ui.locked and "tracker locked" or "tracker unlocked")
        return true
    elseif arg == "compact" then
        ui.compact = not ui.compact
        LS.RefreshTracker(true)
        return true
    elseif arg == "resetui" then
        ui.point = nil; ui.w, ui.h = DEFAULTS.w, DEFAULTS.h
        F:ClearAllPoints(); F:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0); F:SetSize(ui.w, ui.h)
        LS.RefreshTracker(true)
        return true
    end
    return false
end

-- Addon compartment (the addon menu button by the minimap)
-- left-click: toggle window, right-click: options
function LevelScout_OnCompartmentClick(_, button)
    if button == "RightButton" and LS.OpenOptions then
        LS.OpenOptions()
    elseif LS.SlashExtra then
        LS.SlashExtra("ui")
    end
end
