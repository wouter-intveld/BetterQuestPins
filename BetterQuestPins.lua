-- BetterQuestPins
-- Puts a pin on the world map for every quest the character can pick up, using the quest
-- givers' positions from QuestieDB.

local ADDON, ns = ...
local BRAND = "|cffcda552Better|rQuestPins"
local DEFAULTS = {
    showPins = true, smallPins = false, maxAbove = 4, holidays = false,
    -- Townsfolk, each type off until ticked.
    tfFlight = false, tfInn = false, tfRepair = false, tfClass = false,
    tfProfession = false, tfBanker = false, tfStable = false,
}
local db

local ZoneDB = LibQuestieDB.Support.Get("ZoneDB")

-- QuestieDB keeps positions per area ID; the map wants UI map IDs.
local areaToMap = {}
do
    local private = ZoneDB and ZoneDB.private or {}
    for _, source in ipairs({ private.areaIdToUiMapId, private.areaIdToUiMapIdOverride }) do
        local chunk = type(source) == "string" and loadstring(source)
        local map = chunk and chunk() or type(source) == "table" and source
        if map then
            for areaID, mapID in pairs(map) do areaToMap[areaID] = mapID end
        end
    end
end

-- uiMapID -> { [quest giver location key] = { x, y, quests = { questID, ... } } }
-- Built once, the first time the world map shows: a pass over every quest in the database.
local byMap

local function AddStarter(questID, spawns)
    for areaID, coords in pairs(spawns) do
        local mapID = areaToMap[areaID]
        if mapID and mapID > 0 then
            local spots = byMap[mapID]
            if not spots then
                spots = {}
                byMap[mapID] = spots
            end
            for _, coord in ipairs(coords) do
                local x, y = coord[1], coord[2]
                if x and y and x >= 0 and y >= 0 then
                    local key = ("%.1f:%.1f"):format(x, y)
                    local spot = spots[key]
                    if not spot then
                        spot = { x = x / 100, y = y / 100, quests = {} }
                        spots[key] = spot
                    end
                    spot.quests[#spot.quests + 1] = questID
                end
            end
        end
    end
end

-- World events, generic seasonal and temporary quests: never pinned.
local EVENT_SORTS = { [-22] = true, [-368] = true, [-365] = true, [-1000] = true }

-- Holiday quest sorts, and words of the calendar title that names each holiday.
-- Matched on the English title for now, so other client languages see no holiday pins.
local HOLIDAY_SORTS = {
    [-404] = "winter veil", [-402] = "harvest festival", [-378] = "children's week",
    [-376] = "love is in the air", [-375] = "pilgrim", [-374] = "noblegarden",
    [-370] = "brewfest", [-369] = "midsummer", [-366] = "lunar festival",
    [-364] = "darkmoon", [-41] = "day of the dead", [-21] = "hallow's end",
}

local holidaySortOf = {} -- questID -> holiday sort, for holiday quests only
local activeHolidays = {} -- holiday sort -> true while that holiday runs today
local holidayDay -- the day activeHolidays was read for

-- A few calendar calls, once a day; map redraws only read the cached result.
local function ReadHolidays()
    wipe(activeHolidays)
    local now = C_DateAndTime.GetCurrentCalendarTime()
    holidayDay = now.monthDay
    if not (C_Calendar and C_Calendar.GetNumDayEvents) then return end
    for i = 1, C_Calendar.GetNumDayEvents(0, now.monthDay) do
        local event = C_Calendar.GetDayEvent(0, now.monthDay, i)
        local title = event and event.calendarType == "HOLIDAY" and event.title and event.title:lower()
        if title then
            for sort, words in pairs(HOLIDAY_SORTS) do
                if title:find(words, 1, true) then activeHolidays[sort] = true end
            end
        end
    end
end

local function BuildIndex()
    byMap = {}
    for _, questID in ipairs(QuestDB.GetAllIds()) do
        -- Unnamed entries are placeholders the database knows only by ID; blacklisted
        -- ones exist in the data but cannot be taken in game.
        local sort = QuestDB.zoneOrSort(questID) or 0
        if HOLIDAY_SORTS[sort] then holidaySortOf[questID] = sort end
        local starters = not ns.BLACKLIST[questID] and not EVENT_SORTS[sort] and QuestDB.name(questID)
            and QuestDB.startedBy(questID)
        if starters then
            for _, npcID in ipairs(starters[1] or {}) do
                local spawns = NpcDB.spawns(npcID)
                if spawns then AddStarter(questID, spawns) end
            end
            for _, objectID in ipairs(starters[2] or {}) do
                local spawns = ObjectDB.spawns(objectID)
                if spawns then AddStarter(questID, spawns) end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Can this character pick the quest up now?
---------------------------------------------------------------------------
local IsCompleted = C_QuestLog.IsQuestFlaggedCompleted

local function InLog(questID)
    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

local function Taken(questID)
    return questID and questID ~= 0 and (IsCompleted(questID) or InLog(questID))
end

-- Every prerequisite done. Finishing an alternative to one counts as doing it,
-- except for IDs the data marks negative, which must be done themselves.
local function GroupDone(list)
    for _, id in ipairs(list) do
        local done = IsCompleted(math.abs(id))
        if not done and id > 0 then
            for _, alt in ipairs(QuestDB.exclusiveTo(id) or {}) do
                if IsCompleted(alt) then done = true break end
            end
        end
        if not done then return false end
    end
    return true
end

-- Reputation as a {factionID, value} pair; value is standing in reputation points.
local function Reputation(factionID)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local data = C_Reputation.GetFactionDataByID(factionID)
        return data and data.currentStanding
    end
    local _, _, _, _, _, value = GetFactionInfoByID(factionID)
    return value
end

local function AnyCompleted(list)
    for _, id in ipairs(list) do
        if IsCompleted(id) then return true end
    end
    return false
end

local function AnyTaken(list)
    for _, id in ipairs(list) do
        if IsCompleted(id) or InLog(id) then return true end
    end
    return false
end

local player = {}

local function RefreshPlayer()
    player.level = UnitLevel("player")
    player.raceBit = bit.lshift(1, select(3, UnitRace("player")) - 1)
    player.classBit = bit.lshift(1, select(3, UnitClass("player")) - 1)
    player.grayBelow = player.level - (GetQuestGreenRange and GetQuestGreenRange() or 8)
end

local function IsAvailable(questID)
    if IsCompleted(questID) or InLog(questID) then return false end
    if (QuestDB.requiredLevel(questID) or 0) > player.level then return false end
    local maxLevel = QuestDB.requiredMaxLevel(questID)
    if maxLevel and maxLevel > 0 and player.level > maxLevel then return false end
    -- Gray quests give nothing worth the walk.
    local questLevel = QuestDB.questLevel(questID)
    if questLevel and questLevel > 0 and questLevel < player.grayBelow then return false end
    -- Red quests: allowed to pick up, but not something to walk to yet.
    if questLevel and questLevel > player.level + db.maxAbove then return false end
    local holiday = holidaySortOf[questID]
    if holiday and not (db.holidays and activeHolidays[holiday]) then return false end
    local races = QuestDB.requiredRaces(questID)
    if races and races > 0 and bit.band(races, player.raceBit) == 0 then return false end
    local classes = QuestDB.requiredClasses(questID)
    if classes and classes > 0 and bit.band(classes, player.classBit) == 0 then return false end
    -- Profession quests: skill levels aren't checked, so leave them out rather than guess.
    if QuestDB.requiredSkill(questID) then return false end
    local single = QuestDB.preQuestSingle(questID)
    if single and #single > 0 then
        if not AnyCompleted(single) then return false end
    else
        local group = QuestDB.preQuestGroup(questID)
        if group and #group > 0 and not GroupDone(group) then return false end
    end
    -- Done or in the log: a sibling that rules this one out, the next quest in the chain,
    -- or the quest a breadcrumb leads to. The game often skips flagging the earlier one.
    local exclusive = QuestDB.exclusiveTo(questID)
    if exclusive and AnyTaken(exclusive) then return false end
    if Taken(QuestDB.nextQuestInChain(questID)) then return false end
    if Taken(QuestDB.breadcrumbForQuestId(questID)) then return false end
    for _, id in ipairs(QuestDB.breadcrumbs(questID) or {}) do
        if InLog(id) then return false end
    end
    local parent = QuestDB.parentQuest(questID)
    if parent and parent ~= 0 and not InLog(parent) then return false end
    local disabledBy = QuestDB.disabledByQuest(questID)
    if disabledBy and disabledBy ~= 0 and InLog(disabledBy) then return false end
    local untilDone = QuestDB.availableUntilCompleted(questID)
    if untilDone and untilDone ~= 0 and IsCompleted(untilDone) then return false end
    local startingWith = QuestDB.availableStartingWith(questID)
    if startingWith and startingWith ~= 0 and not Taken(startingWith) then return false end
    local minRep = QuestDB.requiredMinRep(questID)
    if minRep and (Reputation(minRep[1]) or -math.huge) < minRep[2] then return false end
    local maxRep = QuestDB.requiredMaxRep(questID)
    if maxRep and (Reputation(maxRep[1]) or -math.huge) >= maxRep[2] then return false end
    -- Positive: a spell the player must know; negative: one they must not.
    local spell = QuestDB.requiredSpell(questID)
    if spell and spell ~= 0 and C_SpellBook and C_SpellBook.IsSpellKnown
        and (C_SpellBook.IsSpellKnown(math.abs(spell)) == (spell < 0)) then
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Map pins
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Townsfolk: friendly NPCs by the service they offer, from QuestieDB's NPC flags.
---------------------------------------------------------------------------
local FLAGS = LibQuestieDB.Enum.npcFlags
local TRACKING = "Interface\\Minimap\\Tracking\\"
local TOWNSFOLK = {
    { key = "tfFlight", flag = FLAGS.FLIGHT_MASTER, icon = "FlightMaster", name = "Flight masters" },
    { key = "tfInn", flag = FLAGS.INNKEEPER, icon = "Innkeeper", name = "Innkeepers" },
    { key = "tfRepair", flag = FLAGS.REPAIR, icon = "Repair", name = "Repair" },
    { key = "tfClass", flag = FLAGS.TRAINER, icon = "Class", name = "Class trainers", trainer = "class" },
    { key = "tfProfession", flag = FLAGS.TRAINER, icon = "Profession", name = "Profession trainers", trainer = "profession" },
    { key = "tfBanker", flag = FLAGS.BANKER, icon = "Banker", name = "Bankers" },
    { key = "tfStable", flag = FLAGS.STABLEMASTER, icon = "StableMaster", name = "Stable masters" },
}

-- Trainers share one flag; the subname ("Mage Trainer") tells class from
-- profession. The class names are the client's own, so this works in any language.
local function TrainerClass(sub)
    if not sub then return nil end
    for token, name in pairs(LOCALIZED_CLASS_NAMES_MALE) do
        local female = LOCALIZED_CLASS_NAMES_FEMALE[token]
        if sub:find(name, 1, true) or (female and sub:find(female, 1, true)) then return token end
    end
end

-- uiMapID -> list of { x, y, type, name, sub, class }, friendly NPCs only.
-- Built once, the first time a townsfolk type is ticked: a pass over every NPC.
local townsByMap

local function BuildTownsIndex()
    townsByMap = {}
    local faction = UnitFactionGroup("player") == "Alliance" and "A" or "H"
    for _, npcID in ipairs(NpcDB.GetAllIds()) do
        local flags = NpcDB.npcFlags(npcID) or 0
        local types
        for _, t in ipairs(TOWNSFOLK) do
            if t.flag and bit.band(flags, t.flag) ~= 0 then
                types = types or {}
                types[#types + 1] = t
            end
        end
        local friendly = types and (NpcDB.friendlyToFaction(npcID) or ""):find(faction, 1, true)
        local spawns = friendly and NpcDB.spawns(npcID)
        if spawns then
            local name, sub = NpcDB.name(npcID) or "?", NpcDB.subName(npcID)
            local class = TrainerClass(sub)
            for _, t in ipairs(types) do
                if not t.trainer or (t.trainer == "class") == (class ~= nil) then
                    for areaID, coords in pairs(spawns) do
                        local mapID = areaToMap[areaID]
                        if mapID and mapID > 0 then
                            local list = townsByMap[mapID] or {}
                            townsByMap[mapID] = list
                            for _, c in ipairs(coords) do
                                if c[1] and c[2] and c[1] >= 0 and c[2] >= 0 then
                                    list[#list + 1] = { x = c[1] / 100, y = c[2] / 100, type = t,
                                        name = name, sub = sub, class = class }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- /bqp why <npcID>: walks one NPC through the steps BuildTownsIndex takes.
local function ExplainNpc(npcID)
    local flags = NpcDB.npcFlags(npcID) or 0
    local sub = NpcDB.subName(npcID)
    print(("%s <%s> flags %d, friendly %s, trainer class %s"):format(NpcDB.name(npcID) or "?", sub or "",
        flags, tostring(NpcDB.friendlyToFaction(npcID)), tostring((TrainerClass(sub)))))
    for _, t in ipairs(TOWNSFOLK) do
        if t.flag and bit.band(flags, t.flag) ~= 0 then
            print(("  matches %s, ticked %s"):format(t.name, tostring(db[t.key])))
        end
    end
    for areaID in pairs(NpcDB.spawns(npcID) or {}) do
        local mapID = areaToMap[areaID]
        local found = 0
        for _, npc in ipairs(townsByMap and townsByMap[mapID or 0] or {}) do
            if npc.name == NpcDB.name(npcID) then
                found = found + 1
                print(("  entry: %s (%s, ticked %s), class %s, at %.3f %.3f"):format(npc.type.name, npc.type.key,
                    tostring(db[npc.type.key]), tostring(npc.class), npc.x, npc.y))
            end
        end
        if WorldMapFrame:IsShown() then
            local pins = 0
            for pin in WorldMapFrame:EnumeratePinsByTemplate("BetterQuestPinsPinTemplate") do
                if pin.info and pin.info.npc and pin.info.npc.name == NpcDB.name(npcID) then pins = pins + 1 end
            end
            print(("  open map %d, pins for this NPC: %d"):format(WorldMapFrame:GetMapID() or 0, pins))
        end
        print(("  area %d -> map %s, in index %d time(s)%s"):format(areaID, tostring(mapID), found,
            townsByMap and "" or " (index not built yet)"))
    end
end

SLASH_BETTERQUESTPINS1 = "/bqp"
SlashCmdList.BETTERQUESTPINS = function(msg)
    local id = tonumber((msg or ""):match("^why%s+(%d+)"))
    if id then return ExplainNpc(id) end
    print("/bqp why <npcID> - explain why an NPC has a townsfolk pin or not")
end

local function AnyTownsfolk()
    for _, t in ipairs(TOWNSFOLK) do
        if db[t.key] then return true end
    end
    return false
end

local PIN = "BetterQuestPinsPinTemplate"
local MAX_LINES = 10

BetterQuestPinsPinMixin = CreateFromMixins(MapCanvasPinMixin)

function BetterQuestPinsPinMixin:OnLoad()
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_PING")
end

-- info: { quests = { name, ... } } for a quest giver, or { npc = spot } for townsfolk.
function BetterQuestPinsPinMixin:OnAcquired(info)
    self.info = info
    if info.npc then
        self.Texture:SetTexture(TRACKING .. info.npc.type.icon)
    else
        self.Texture:SetAtlas("QuestNormal")
    end
end

-- Lists everything under the cursor, since pins at one spot overlap.
function BetterQuestPinsPinMixin:OnMouseEnter()
    local names, npcs = {}, {}
    for pin in self:GetMap():EnumeratePinsByTemplate(PIN) do
        if pin:IsMouseOver() then
            if pin.info.npc then
                npcs[#npcs + 1] = pin.info.npc
            else
                for _, name in ipairs(pin.info.quests) do names[#names + 1] = name end
            end
        end
    end
    local tooltip = GameTooltip
    tooltip:SetOwner(self, "ANCHOR_LEFT")
    if #names > 0 then
        tooltip:AddLine(#names == 1 and AVAILABLE_QUEST or AVAILABLE_QUESTS, 1, 1, 1, true)
        for i = 1, math.min(#names, MAX_LINES) do tooltip:AddLine(names[i]) end
        if #names > MAX_LINES then
            tooltip:AddLine(("+%d more"):format(#names - MAX_LINES), 0.6, 0.6, 0.6)
        end
    end
    for _, npc in ipairs(npcs) do
        tooltip:AddLine(npc.name, 1, 1, 1)
        tooltip:AddLine(npc.sub or npc.type.name, 0.6, 0.6, 0.6)
    end
    tooltip:Show()
end

function BetterQuestPinsPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

-- Click: the game's own map waypoint, which the arrow on screen then follows.
function BetterQuestPinsPinMixin:OnClick()
    local x, y = self:GetPosition()
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(self:GetMap():GetMapID(), x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

local DataProvider = CreateFromMixins(MapCanvasDataProviderMixin)

function DataProvider:OnAdded(mapCanvas)
    MapCanvasDataProviderMixin.OnAdded(self, mapCanvas)
    mapCanvas:SetPinTemplateType(PIN, "BUTTON")
end

function DataProvider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN)
end

local function QuestName(questID)
    local level = QuestDB.questLevel(questID)
    local name = QuestDB.name(questID) or ("Quest " .. questID)
    if not level or level <= 0 then return name end
    local color = GetQuestDifficultyColor(level)
    return ("|cff%02x%02x%02x[%d]|r %s"):format(color.r * 255, color.g * 255, color.b * 255, level, name)
end

-- Many townsfolk also give quests, and their quest pin would cover them. A
-- townsfolk pin on a quest pin moves a little down and right and shrinks, so
-- both show; the shared tooltip still lists both.
local NEAR, NUDGE = 0.005, 0.007

local function AddTownsfolkPins(map, mapID, size, questSpots)
    if not AnyTownsfolk() then return end
    if not townsByMap then BuildTownsIndex() end
    local _, playerClass = UnitClass("player")
    for _, npc in ipairs(townsByMap[mapID] or {}) do
        if db[npc.type.key] and (npc.type.trainer ~= "class" or npc.class == playerClass) then
            local x, y, pinSize = npc.x, npc.y, size
            for _, q in ipairs(questSpots) do
                if math.abs(q.x - x) < NEAR and math.abs(q.y - y) < NEAR then
                    x, y, pinSize = x + NUDGE, y + NUDGE, size * 0.75
                    break
                end
            end
            local pin = map:AcquirePin(PIN, { npc = npc })
            pin:SetPosition(x, y)
            pin:SetSize(pinSize, pinSize)
            pin:Show()
        end
    end
end

function DataProvider:RefreshAllData()
    self:RemoveAllData()
    if not db then return end
    local mapID = self:GetMap():GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info or info.mapType == Enum.UIMapType.Continent or info.mapType == Enum.UIMapType.World
        or info.mapType == Enum.UIMapType.Cosmic then
        return
    end
    local size = db.smallPins and 16 or 22
    local questSpots = self:AddQuestPins(mapID, size)
    AddTownsfolkPins(self:GetMap(), mapID, size, questSpots)
end

-- Returns the spots that got a quest pin, so townsfolk can step aside.
function DataProvider:AddQuestPins(mapID, size)
    local placed = {}
    if not db.showPins then return placed end
    if not byMap then BuildIndex() end
    local spots = byMap[mapID]
    if not spots then return placed end
    RefreshPlayer()
    if db.holidays and holidayDay ~= C_DateAndTime.GetCurrentCalendarTime().monthDay then ReadHolidays() end
    for _, spot in pairs(spots) do
        local names
        for _, questID in ipairs(spot.quests) do
            if IsAvailable(questID) then
                names = names or {}
                names[#names + 1] = QuestName(questID)
            end
        end
        if names then
            local pin = self:GetMap():AcquirePin(PIN, { quests = names })
            pin:SetPosition(spot.x, spot.y)
            pin:SetSize(size, size)
            pin:Show()
            placed[#placed + 1] = spot
        end
    end
    return placed
end

local function RefreshIfOpen()
    if WorldMapFrame:IsShown() then DataProvider:RefreshAllData() end
end

---------------------------------------------------------------------------
-- Settings panel (Options > AddOns)
---------------------------------------------------------------------------
local function RegisterSettings()
    local main = Settings.RegisterVerticalLayoutCategory(BRAND)
    local category = main -- the page the helper adds to; switched for the subpage
    local function Checkbox(key, name, tooltip)
        local setting = Settings.RegisterProxySetting(category, "BQP_" .. key, Settings.VarType.Boolean, name,
            DEFAULTS[key], function() return db[key] end, function(value)
                db[key] = value
                RefreshIfOpen()
            end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end
    Checkbox("showPins", "Show quest pins", "Pin quests you can pick up on the world map.")
    Checkbox("smallPins", "Small pins", "Draw the pins smaller.")
    local above = Settings.RegisterProxySetting(category, "BQP_maxAbove", Settings.VarType.Number,
        "Levels above you", DEFAULTS.maxAbove, function() return db.maxAbove end, function(value)
            db.maxAbove = value
            RefreshIfOpen()
        end)
    local options = Settings.CreateSliderOptions(0, 10, 1)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
        return ("+%d"):format(value)
    end)
    Settings.CreateSlider(category, above, options, "Hide quests more than this many levels above you.")
    Checkbox("holidays", "Holiday quests", "Also pin quests of a holiday that is running today, like the Darkmoon Faire or Hallow's End.")

    category = Settings.RegisterVerticalLayoutSubcategory(main, "Townsfolk")
    for _, t in ipairs(TOWNSFOLK) do
        Checkbox(t.key, t.name, ("Pin friendly %s on the world map."):format(t.name:lower()))
    end
    Settings.RegisterAddOnCategory(main)
end

WorldMapFrame:AddDataProvider(DataProvider)

-- Quest log changes alter what is available; redraw only while the map is open.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, name)
    if event == "CALENDAR_UPDATE_EVENT_LIST" then
        ReadHolidays()
        return RefreshIfOpen()
    end
    if event ~= "ADDON_LOADED" then return RefreshIfOpen() end
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    BetterQuestPinsDB = BetterQuestPinsDB or {}
    db = BetterQuestPinsDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    RegisterSettings()
    -- Calendar data loads after a request; CALENDAR_UPDATE_EVENT_LIST says it arrived.
    if C_Calendar and C_Calendar.OpenCalendar then
        self:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
        C_Calendar.OpenCalendar()
    end
    for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
        self:RegisterEvent(e)
    end
end)
