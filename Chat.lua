-- LevelScout chat markup: when someone links a quest in chat, append a tag saying
-- whether you're on it (and your progress). Works with native quest links and with
-- Questie's rewritten links ([[34+] Quest Name]), since Questie's filter runs first.

local LS = LevelScout
if not LS then return end
local S, try = LS.S, LS.try

local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function ui() return LS.GetUI and LS.GetUI() end

local ICON_ON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"

-- progress text for a quest in the log, e.g. "2/15" or "2/15, 0/3"
local function progressText(id)
    local objs = try(C_QuestLog.GetQuestObjectives, id)
    if type(objs) ~= "table" then return nil end
    local parts = {}
    for _, o in ipairs(objs) do
        local have, need = S(o.numFulfilled), S(o.numRequired)
        if not S(o.finished) and type(have) == "number" and type(need) == "number" and need > 0 then
            parts[#parts + 1] = have .. "/" .. need
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- returns markup string (or "") for a quest id according to options
local function markupFor(id, u)
    local onQuest = try(C_QuestLog.IsOnQuest, id)
    if onQuest then
        local complete = try(C_QuestLog.IsComplete, id)
        if complete then
            if u.chatMarkDone then return " |cff808080[have it - complete]|r" end
            return ""
        end
        local prog = progressText(id)
        LS._chatHit = true
        return (" %s|cff40ff40[ON QUEST%s]|r"):format(ICON_ON, prog and (" " .. prog) or "")
    end
    if u.chatMarkDone and try(C_QuestLog.IsQuestFlaggedCompleted, id) then
        return " |cff808080[done]|r"
    end
    if u.chatMarkAvailable and LS.questieReady() then
        local Q = LS.Q
        if try(Q.DB.IsDoable, id) then return " |cffffff00[can pick up]|r" end
    end
    return ""
end

-- insert markup after each link matched by pat (pat captures the quest id)
local function annotate(msg, pat, u)
    local out, pos, changed = {}, 1, false
    while true do
        local s, e, idStr = msg:find(pat, pos)
        if not s then break end
        if msg:sub(e + 1, e + 2) == "|r" then e = e + 2 end
        local mark = markupFor(tonumber(idStr), u)
        if mark ~= "" then changed = true end
        out[#out + 1] = msg:sub(pos, e) .. mark
        pos = e + 1
    end
    if not changed then return msg, false end
    out[#out + 1] = msg:sub(pos)
    return table.concat(out), true
end

local QUESTIE_LINK = "|Hquestie:(%d+)[^|]*|h.-|h"
local NATIVE_LINK = "|Hquest:(%d+)[^|]*|h.-|h"

local lastSoundLine, lastSoundAt = nil, -1000

local function filter(_, event, msg, ...)
    local u = ui()
    if not (u and u.chatMarkup) then return false end
    if type(msg) ~= "string" or isSecret(msg) then return false end
    if not msg:find("|Hquest", 1, true) then return false end

    LS._chatHit = false
    local ok, newMsg, c1, c2 = pcall(function()
        local m, a = annotate(msg, QUESTIE_LINK, u)
        local m2, b = annotate(m, NATIVE_LINK, u)
        return m2, a, b
    end)
    if not ok or not (c1 or c2) then return false end

    if LS._chatHit and u.chatSound then
        local lineID = select(10, ...)
        if isSecret(lineID) then lineID = nil end
        local t = GetTime()
        if lineID ~= lastSoundLine and t - lastSoundAt > 10 then
            lastSoundLine, lastSoundAt = lineID, t
            if SOUNDKIT and SOUNDKIT.READY_CHECK then try(PlaySound, SOUNDKIT.READY_CHECK) end
        end
    end
    return false, newMsg, ...
end

local EVENTS = {
    "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
}

local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
if addFilter then
    for _, e in ipairs(EVENTS) do pcall(addFilter, e, filter) end
end

LS._chatFilter = filter -- exposed for testing
