-- LevelScout options: Esc > Options > AddOns > LevelScout (+ sub-pages).
-- Options are declared as data in PAGES; each entry maps to a key in LevelScoutDB.ui.
-- To add an option: add a default in Tracker.lua DEFAULTS, then an entry below.
--
-- Uses canvas-layout categories (the same Settings API pattern Questie uses on Forever)
-- with plain widgets, so it doesn't depend on Settings' newer data-driven templates.

local LS = LevelScout
if not LS then return end
local msg, try = LS.msg, LS.try

local function ui() return LS.GetUI and LS.GetUI() end
local function refresh() if LS.RefreshTracker then LS.RefreshTracker(true) end end

-------------------------------------------------------------------------------
-- option schema
-------------------------------------------------------------------------------
local PAGES = {
    {
        name = "LevelScout",
        intro = "Leveling tracker: quest log with real XP rewards, turn-in locations, "
            .. "Questie pickups and zone suggestions. Sub-pages below hold more options.",
        options = {
            { type = "header", label = "Window" },
            { type = "check", key = "shown", label = "Show the LevelScout window",
              tip = "Same as /scout ui or left-clicking LevelScout in the addon menu.",
              apply = function(v) LS.SetTrackerShown(v) end },
            { type = "check", key = "hideBlizzTracker", label = "Hide the default quest tracker",
              tip = "Only show LevelScout's window. Hides Blizzard's objective tracker and keeps it "
                .. "hidden (e.g. after Questie re-enables it). Does not touch Questie's own tracker.",
              apply = function() LS.ApplyBlizzTracker() end },
            { type = "check", key = "locked", label = "Lock window position and size",
              apply = function() LS.ApplyLock() end },
            { type = "slider", key = "alpha", label = "Background opacity", min = 0, max = 1, step = 0.05,
              fmt = function(v) return ("%d%%"):format(v * 100) end,
              apply = function(v) LS.SetAlpha(v) end },
            { type = "button", label = "Reset window position",
              run = function() LS.SlashExtra("resetui") end },
            { type = "text", label = "|cffa0a0a0Commands: /scout ui, /scout config, /scout zones, /scout status. "
                .. "Addon menu: left-click toggles the window, right-click opens these options.|r" },
        },
    },
    {
        name = "Tracker",
        intro = "What the tracker window shows.",
        options = {
            { type = "header", label = "Completed quests" },
            { type = "check", key = "splitCompleted", label = "Split completed quests by turn-in zone",
              tip = "On: two groups, 'turn in here' and 'turn in elsewhere'.\n"
                .. "Off: a single 'Ready to turn in' group, current-zone turn-ins listed first." },
            { type = "header", label = "Sections" },
            { type = "check", key = "showPickups", label = "Pick up here (Questie quests available in this zone)" },
            { type = "slider", key = "maxPickups", label = "Max pickups listed", min = 3, max = 25, step = 1,
              fmt = function(v) return tostring(v) end },
            { type = "check", key = "showDungeon", label = "Dungeon (group) quests" },
            { type = "check", key = "showOther", label = "Quests in other zones" },
            { type = "check", key = "showAbandon", label = "Low value quests (consider abandoning)" },
            { type = "check", key = "showZones", label = "Next zones suggestions" },
            { type = "header", label = "Sorting" },
            { type = "check", key = "progressFirst", label = "Quests with progress first",
              tip = "Quests where any objective has progressed (e.g. 2/15) sort above quests you haven't "
                .. "started, within each group. Ties keep the normal order (XP incl. follow-ups)." },
            { type = "header", label = "Detail" },
            { type = "check", key = "compact", label = "Compact: hide objectives for other-zone quests and giver locations" },
        },
    },
    {
        name = "Chat",
        intro = "When someone links a quest in chat (General, LFG, party, guild, whispers...), "
            .. "LevelScout tags the link so you can tell at a glance if it's relevant to you.",
        options = {
            { type = "check", key = "chatMarkup", label = "Tag quest links in chat",
              tip = "Quests you're on and haven't completed get a green check and [ON QUEST 2/15]. "
                .. "No tag means you don't have it (or it's already done)." },
            { type = "check", key = "chatMarkAvailable", label = "Also tag quests you could pick up (yellow)",
              tip = "Uses Questie's database: you meet the level/prerequisites but don't have the quest yet." },
            { type = "check", key = "chatMarkDone", label = "Also tag quests already done or complete (gray)" },
            { type = "check", key = "chatSound", label = "Play a sound when a linked quest is one you're on",
              tip = "Ready-check sound, at most once every 10 seconds." },
        },
    },
    {
        name = "Data",
        intro = "Data collection. Everything is saved to WTF/Account/<account>/SavedVariables/LevelScout.lua "
            .. "when you /reload or log out.",
        options = {
            { type = "check", key = "autoScan", label = "Scan the Questie database on login and level-up",
              tip = "Builds the 'Pick up here' and 'Next zones' data. Takes a few seconds in the background." },
            { type = "button", label = "Re-scan now", run = function() LS.Snapshot(true) end },
            { type = "button", label = "Clear XP history (this character)",
              run = function() SlashCmdList.LEVELSCOUT("reset") end },
        },
    },
}
LS.OPTION_PAGES = PAGES

-------------------------------------------------------------------------------
-- widgets
-------------------------------------------------------------------------------
local function label(parent, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function addTooltip(frame, title, tip)
    if not tip then return end
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        GameTooltip:AddLine(tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function setValue(opt, v)
    local u = ui()
    if not u then return end
    u[opt.key] = v
    if opt.apply then pcall(opt.apply, v) end
    refresh()
end

local function makeCheck(parent, opt)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    local text = label(cb, opt.label)
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    if type(cb.Text) == "table" and cb.Text.SetText then cb.Text:SetText("") end
    cb:SetScript("OnClick", function(self) setValue(opt, self:GetChecked() and true or false) end)
    addTooltip(cb, opt.label, opt.tip)
    cb.sync = function() local u = ui(); cb:SetChecked(u and u[opt.key] and true or false) end
    return cb, 30
end

local function makeSlider(parent, opt)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(420, 40)
    local title = label(holder, opt.label)
    title:SetPoint("TOPLEFT", 4, 0)
    local value = label(holder, "", "GameFontNormal")
    value:SetPoint("LEFT", title, "RIGHT", 8, 0)

    local s = CreateFrame("Slider", nil, holder, BackdropTemplateMixin and "BackdropTemplate" or nil)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(220, 16)
    s:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -6)
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(opt.min, opt.max)
    s:SetValueStep(opt.step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, d) self:SetValue(self:GetValue() + d * opt.step) end)
    local syncing = false
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / opt.step + 0.5) * opt.step
        value:SetText(opt.fmt and opt.fmt(v) or tostring(v))
        if not syncing then setValue(opt, v) end
    end)
    addTooltip(s, opt.label, opt.tip)
    holder.sync = function()
        local u = ui()
        syncing = true
        local v = (u and u[opt.key]) or opt.min
        s:SetValue(v)
        value:SetText(opt.fmt and opt.fmt(v) or tostring(v))
        syncing = false
    end
    return holder, 46
end

local function makeButton(parent, opt)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then
        b = CreateFrame("Button", nil, parent)
        local t = b:CreateFontString(nil, "ARTWORK", "GameFontNormal"); t:SetAllPoints()
        b.SetText = function(_, s) t:SetText(s) end
    end
    b:SetSize(220, 22)
    b:SetText(opt.label)
    b:SetScript("OnClick", function() pcall(opt.run); refresh() end)
    addTooltip(b, opt.label, opt.tip)
    return b, 30
end

local function buildPage(page)
    local f = CreateFrame("Frame")
    f.name = page.name
    f:Hide()
    local title = label(f, page.name, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    local y = -44
    if page.intro then
        local intro = label(f, page.intro, "GameFontHighlightSmall")
        intro:SetPoint("TOPLEFT", 16, y)
        intro:SetPoint("RIGHT", f, "RIGHT", -16, 0)
        intro:SetWordWrap(true)
        y = y - 32
    end
    local widgets = {}
    for _, opt in ipairs(page.options) do
        local w, h
        if opt.type == "header" then
            w = label(f, opt.label, "GameFontNormal")
            h = 22; y = y - 6
        elseif opt.type == "text" then
            w = label(f, opt.label, "GameFontHighlightSmall")
            w:SetPoint("RIGHT", f, "RIGHT", -16, 0)
            w:SetWordWrap(true)
            h = 36
        elseif opt.type == "check" then
            w, h = makeCheck(f, opt)
        elseif opt.type == "slider" then
            w, h = makeSlider(f, opt)
        elseif opt.type == "button" then
            w, h = makeButton(f, opt)
        end
        if w then
            w:SetPoint("TOPLEFT", f, "TOPLEFT", opt.type == "header" and 16 or 20, y)
            if w.sync then widgets[#widgets + 1] = w end
            y = y - h
        end
    end
    f:SetScript("OnShow", function() for _, w in ipairs(widgets) do pcall(w.sync) end end)
    -- legacy InterfaceOptions callbacks (harmless on the new Settings panel)
    f.OnCommit, f.OnDefault, f.OnRefresh = function() end, function() end, function()
        for _, w in ipairs(widgets) do pcall(w.sync) end
    end
    return f
end

-------------------------------------------------------------------------------
-- registration
-------------------------------------------------------------------------------
local mainCategory

local function register()
    if mainCategory then return end
    local frames = {}
    for i, page in ipairs(PAGES) do frames[i] = buildPage(page) end

    if Settings and Settings.RegisterCanvasLayoutCategory then
        for i, f in ipairs(frames) do
            local cat
            if i == 1 then
                cat = Settings.RegisterCanvasLayoutCategory(f, f.name)
                mainCategory = cat
            else
                cat = Settings.RegisterCanvasLayoutSubcategory(mainCategory, f, f.name)
            end
            Settings.RegisterAddOnCategory(cat)
        end
    elseif InterfaceOptions_AddCategory then
        for i, f in ipairs(frames) do
            if i > 1 then f.parent = frames[1].name end
            InterfaceOptions_AddCategory(f)
        end
        mainCategory = frames[1]
    end
end

function LS.OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        msg("options can't open during combat")
        return
    end
    if Settings and Settings.OpenToCategory and mainCategory then
        local id = (mainCategory.GetID and mainCategory:GetID()) or mainCategory.ID
        Settings.OpenToCategory(id)
    elseif InterfaceOptionsFrame_OpenToCategory and mainCategory then
        InterfaceOptionsFrame_OpenToCategory(mainCategory)
        InterfaceOptionsFrame_OpenToCategory(mainCategory)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    -- Tracker.lua's PLAYER_LOGIN handler (registered earlier) has initialised ui by now
    local ok, err = pcall(register)
    if not ok then msg("options panel failed to register: " .. tostring(err)) end
end)
