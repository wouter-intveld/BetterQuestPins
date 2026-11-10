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
    tfOnlyMine = false, -- profession trainers only for professions the character has
}
local db
local mainCategory, townsCategory -- the settings pages, for /bqp
local RequestRedraw -- defined with the data provider; the builder and the settings use it
-- /bqp perf: how long the map redraws and the index builds take (ms)
local perf = { last = 0, slowest = 0, count = 0, quests = 0, towns = 0 }

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

-- uiMapID -> list of spots, each { x, y, questID, questID, ... }: a quest giver's
-- position and the quests it starts. A plain array, since there are thousands: a
-- record with named fields and its own quest list costs three times the memory.
-- Built once, in the background (BuildIndex).
local byMap

-- lookup: mapID -> { ["x:y"] = spot }, so the quests of one giver share a spot; dropped after the build.
local function AddStarter(questID, spawns, lookup)
    for areaID, coords in pairs(spawns) do
        local mapID = areaToMap[areaID]
        if mapID and mapID > 0 then
            local spots, keys = byMap[mapID], lookup[mapID]
            if not spots then
                spots, keys = {}, {}
                byMap[mapID], lookup[mapID] = spots, keys
            end
            for _, coord in ipairs(coords) do
                local x, y = coord[1], coord[2]
                if x and y and x >= 0 and y >= 0 then
                    local key = ("%.1f:%.1f"):format(x, y)
                    local spot = keys[key]
                    if spot then
                        spot[#spot + 1] = questID
                    else
                        spot = { x / 100, y / 100, questID }
                        keys[key] = spot
                        spots[#spots + 1] = spot
                    end
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

-- The indexes are built in the background (StartBackground): a builder hands
-- control back every so often, so no frame waits long.
local YIELD_EVERY = 200
local questReady, townsReady
local function Pause(i)
    if i % YIELD_EVERY == 0 then coroutine.yield() end
end

local function BuildIndex()
    byMap = {}
    local lookup = {}
    for i, questID in ipairs(QuestDB.GetAllIds()) do
        Pause(i)
        -- Unnamed entries are placeholders the database knows only by ID; blacklisted
        -- ones exist in the data but cannot be taken in game.
        local sort = QuestDB.zoneOrSort(questID) or 0
        if HOLIDAY_SORTS[sort] then holidaySortOf[questID] = sort end
        local starters = not ns.BLACKLIST[questID] and not EVENT_SORTS[sort] and QuestDB.name(questID)
            and QuestDB.startedBy(questID)
        if starters then
            for _, npcID in ipairs(starters[1] or {}) do
                local spawns = NpcDB.spawns(npcID)
                if spawns then AddStarter(questID, spawns, lookup) end
            end
            for _, objectID in ipairs(starters[2] or {}) do
                local spawns = ObjectDB.spawns(objectID)
                if spawns then AddStarter(questID, spawns, lookup) end
            end
        end
    end
    questReady = true
    ns.BLACKLIST = nil -- only the build reads it: 2,491 entries, about 160 KB
end

---------------------------------------------------------------------------
-- Can this character pick the quest up now?
---------------------------------------------------------------------------
local IsCompleted = C_QuestLog.IsQuestFlaggedCompleted

local function InLog(questID)
    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

-- What the database says about a quest never changes in a session: the first
-- check keeps it in one record, later ones read that. Fields the quest lacks
-- (the database's 0, or an empty list) are left out.
local static = {}

local function Some(value) return value and value ~= 0 and value or nil end
local function List(list) return list and #list > 0 and list or nil end

local function Static(questID)
    local s = static[questID]
    if s then return s end
    s = { requiredLevel = QuestDB.requiredLevel(questID) or 0 }
    local function keep(key, value) if value then s[key] = value end end
    keep("maxLevel", Some(QuestDB.requiredMaxLevel(questID)))
    keep("level", Some(QuestDB.questLevel(questID)))
    keep("races", Some(QuestDB.requiredRaces(questID)))
    keep("classes", Some(QuestDB.requiredClasses(questID)))
    keep("skill", QuestDB.requiredSkill(questID) and true)
    keep("single", List(QuestDB.preQuestSingle(questID)))
    keep("group", List(QuestDB.preQuestGroup(questID)))
    keep("exclusive", List(QuestDB.exclusiveTo(questID)))
    keep("next", Some(QuestDB.nextQuestInChain(questID)))
    keep("breadcrumbFor", Some(QuestDB.breadcrumbForQuestId(questID)))
    keep("breadcrumbs", List(QuestDB.breadcrumbs(questID)))
    keep("parent", Some(QuestDB.parentQuest(questID)))
    keep("disabledBy", Some(QuestDB.disabledByQuest(questID)))
    keep("untilDone", Some(QuestDB.availableUntilCompleted(questID)))
    keep("startingWith", Some(QuestDB.availableStartingWith(questID)))
    keep("minRep", List(QuestDB.requiredMinRep(questID)))
    keep("maxRep", List(QuestDB.requiredMaxRep(questID)))
    keep("spell", Some(QuestDB.requiredSpell(questID)))
    static[questID] = s
    return s
end

local function Taken(questID)
    return questID ~= nil and (IsCompleted(questID) or InLog(questID))
end

-- Every prerequisite done. Finishing an alternative to one counts as doing it,
-- except for IDs the data marks negative, which must be done themselves.
local function GroupDone(list)
    for _, id in ipairs(list) do
        local done = IsCompleted(math.abs(id))
        local alts = not done and id > 0 and Static(id).exclusive
        if alts then
            for _, alt in ipairs(alts) do
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

local player = {}       -- level, and the bits that never change; read once per redraw
local availableNow = {} -- questID -> IsAvailable's answer this redraw (a quest giver can have several spawns)
local questNames, questNamesLevel = {}, nil -- questID -> QuestName's text, and the level it was coloured for

local function RefreshPlayer()
    player.level = UnitLevel("player")
    if not player.raceBit then
        player.raceBit = bit.lshift(1, select(3, UnitRace("player")) - 1)
        player.classBit = bit.lshift(1, select(3, UnitClass("player")) - 1)
        player.class = select(2, UnitClass("player"))
    end
    player.grayBelow = player.level - (GetQuestGreenRange and GetQuestGreenRange() or 8)
    if questNamesLevel ~= player.level then
        wipe(questNames)
        questNamesLevel = player.level
    end
end

local function CheckAvailable(questID)
    if IsCompleted(questID) or InLog(questID) then return false end
    local s = Static(questID)
    if s.requiredLevel > player.level then return false end
    if s.maxLevel and player.level > s.maxLevel then return false end
    -- Gray quests give nothing worth the walk; red ones are allowed, but not
    -- something to walk to yet.
    if s.level and (s.level < player.grayBelow or s.level > player.level + db.maxAbove) then return false end
    local holiday = holidaySortOf[questID]
    if holiday and not (db.holidays and activeHolidays[holiday]) then return false end
    if s.races and bit.band(s.races, player.raceBit) == 0 then return false end
    if s.classes and bit.band(s.classes, player.classBit) == 0 then return false end
    -- Profession quests: skill levels aren't checked, so leave them out rather than guess.
    if s.skill then return false end
    if s.single then
        if not AnyCompleted(s.single) then return false end
    elseif s.group and not GroupDone(s.group) then
        return false
    end
    -- Done or in the log: a sibling that rules this one out, the next quest in the chain,
    -- or the quest a breadcrumb leads to. The game often skips flagging the earlier one.
    if s.exclusive and AnyTaken(s.exclusive) then return false end
    if Taken(s.next) or Taken(s.breadcrumbFor) then return false end
    if s.breadcrumbs then
        for _, id in ipairs(s.breadcrumbs) do
            if InLog(id) then return false end
        end
    end
    if s.parent and not InLog(s.parent) then return false end
    if s.disabledBy and InLog(s.disabledBy) then return false end
    if s.untilDone and IsCompleted(s.untilDone) then return false end
    if s.startingWith and not Taken(s.startingWith) then return false end
    if s.minRep and (Reputation(s.minRep[1]) or -math.huge) < s.minRep[2] then return false end
    if s.maxRep and (Reputation(s.maxRep[1]) or -math.huge) >= s.maxRep[2] then return false end
    -- Positive: a spell the player must know; negative: one they must not.
    if s.spell and C_SpellBook and C_SpellBook.IsSpellKnown
        and (C_SpellBook.IsSpellKnown(math.abs(s.spell)) == (s.spell < 0)) then
        return false
    end
    return true
end

-- Once per quest per redraw: a quest giver with several spawns asks about the same quests at each.
local function IsAvailable(questID)
    local available = availableNow[questID]
    if available == nil then
        available = CheckAvailable(questID)
        availableNow[questID] = available
    end
    return available
end

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

-- A townsfolk entry is an array, { x, y, type, name, sub, class, profession }: a
-- record with named fields would cost more than twice the memory, and there are
-- thousands. These name its slots.
local X, Y, TYPE, NAME, SUB, CLASS, PROF = 1, 2, 3, 4, 5, 6, 7

-- Trainers share one flag; the subname ("Mage Trainer") tells class from
-- profession. The class names are the client's own, so this works in any language.
local function TrainerClass(npcID, sub)
    if ns.CLASS_TRAINER[npcID] then return ns.CLASS_TRAINER[npcID] end -- portal trainers
    if not sub then return nil end
    for token, name in pairs(LOCALIZED_CLASS_NAMES_MALE) do
        local female = LOCALIZED_CLASS_NAMES_FEMALE[token]
        if sub:find(name, 1, true) or (female and sub:find(female, 1, true)) then return token end
    end
end

-- uiMapID -> list of entries (X, Y, TYPE, ... above), friendly NPCs only.
-- Built once, in the background, when a townsfolk type is first ticked.
local townsByMap

local function BuildTownsIndex()
    townsByMap = {}
    local faction = UnitFactionGroup("player") == "Alliance" and "A" or "H"
    for i, npcID in ipairs(NpcDB.GetAllIds()) do
        Pause(i)
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
            local class = TrainerClass(npcID, sub)
            local profession = ns.TRAINER_PROFESSION[npcID]
            for _, t in ipairs(types) do
                if not t.trainer or (t.trainer == "class") == (class ~= nil) then
                    for areaID, coords in pairs(spawns) do
                        local mapID = areaToMap[areaID]
                        if mapID and mapID > 0 then
                            local list = townsByMap[mapID] or {}
                            townsByMap[mapID] = list
                            for _, c in ipairs(coords) do
                                if c[1] and c[2] and c[1] >= 0 and c[2] >= 0 then
                                    list[#list + 1] = { c[1] / 100, c[2] / 100, t, name, sub, class, profession }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    townsReady = true
end

-- /bqp why <npcID>: walks one NPC through the steps BuildTownsIndex takes.
local function ExplainNpc(npcID)
    local flags = NpcDB.npcFlags(npcID) or 0
    local sub = NpcDB.subName(npcID)
    print(("%s <%s> flags %d, friendly %s, trainer class %s"):format(NpcDB.name(npcID) or "?", sub or "",
        flags, tostring(NpcDB.friendlyToFaction(npcID)), tostring((TrainerClass(npcID, sub)))))
    for _, t in ipairs(TOWNSFOLK) do
        if t.flag and bit.band(flags, t.flag) ~= 0 then
            print(("  matches %s, ticked %s"):format(t.name, tostring(db[t.key])))
        end
    end
    for areaID in pairs(NpcDB.spawns(npcID) or {}) do
        local mapID = areaToMap[areaID]
        local found = 0
        for _, npc in ipairs(townsByMap and townsByMap[mapID or 0] or {}) do
            if npc[NAME] == NpcDB.name(npcID) then
                found = found + 1
                local t = npc[TYPE]
                print(("  entry: %s (%s, ticked %s), class %s, at %.3f %.3f"):format(t.name, t.key,
                    tostring(db[t.key]), tostring(npc[CLASS]), npc[X], npc[Y]))
            end
        end
        if WorldMapFrame:IsShown() then
            local pins = 0
            for pin in WorldMapFrame:EnumeratePinsByTemplate("BetterQuestPinsPinTemplate") do
                if pin.info and pin.info.npc and pin.info.npc[NAME] == NpcDB.name(npcID) then pins = pins + 1 end
            end
            print(("  open map %d, pins for this NPC: %d"):format(WorldMapFrame:GetMapID() or 0, pins))
        end
        print(("  area %d -> map %s, in index %d time(s)%s"):format(areaID, tostring(mapID), found,
            townsByMap and "" or " (index not built yet)"))
    end
end

local function AnyTownsfolk()
    for _, t in ipairs(TOWNSFOLK) do
        if db[t.key] then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Background build: each index takes tens of milliseconds, run at most BUDGET
-- ms a frame from 3 s after login, or when a townsfolk type is first ticked. A
-- map open while one builds gets its pins when it is done.
---------------------------------------------------------------------------
local BUDGET = 4
local jobs = {}   -- waiting or running, in order: { name = "quests" | "towns", run = coroutine }
local failed = {} -- name -> true after an error, so it isn't retried on every redraw
local builder = CreateFrame("Frame")
builder:Hide()

builder:SetScript("OnUpdate", function()
    local stop = debugprofilestop() + BUDGET
    while jobs[1] and debugprofilestop() < stop do
        local job = jobs[1]
        local start = debugprofilestop()
        local ok, err = coroutine.resume(job.run)
        perf[job.name] = perf[job.name] + debugprofilestop() - start
        if not ok or coroutine.status(job.run) == "dead" then
            table.remove(jobs, 1)
            if not ok then
                failed[job.name] = true
                error(err, 0)
            end
            RequestRedraw()
        end
    end
    if not jobs[1] then builder:Hide() end
end)

local function StartBackground()
    local function Queue(name, ready, build)
        if ready or failed[name] then return end
        for _, job in ipairs(jobs) do
            if job.name == name then return end
        end
        jobs[#jobs + 1] = { name = name, run = coroutine.create(build) }
    end
    Queue("quests", questReady, BuildIndex)
    if AnyTownsfolk() then Queue("towns", townsReady, BuildTownsIndex) end
    if jobs[1] then builder:Show() end
end

---------------------------------------------------------------------------
-- Map pins
---------------------------------------------------------------------------
local PIN = "BetterQuestPinsPinTemplate"
local MAX_LINES = 10

BetterQuestPinsPinMixin = CreateFromMixins(MapCanvasPinMixin)

-- Pin frames the map has made from the template: it keeps every one for reuse, and
-- each carries a copy of the pin mixin's methods, so they are most of the memory in use.
local pinFrames = 0

function BetterQuestPinsPinMixin:OnLoad()
    pinFrames = pinFrames + 1
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_PING")
end

-- info: { quests = { name, ... } } for a quest giver, or { npc = entry } for townsfolk.
function BetterQuestPinsPinMixin:OnAcquired(info)
    self.info = info
    if info.npc then
        self.Texture:SetTexture(TRACKING .. info.npc[TYPE].icon)
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
        tooltip:AddLine(npc[NAME], 1, 1, 1)
        tooltip:AddLine(npc[SUB] or npc[TYPE].name, 0.6, 0.6, 0.6)
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
    local text = questNames[questID]
    if text then return text end
    local name = QuestDB.name(questID) or ("Quest " .. questID)
    local level = Static(questID).level
    if level then
        local color = GetQuestDifficultyColor(level)
        text = ("|cff%02x%02x%02x[%d]|r %s"):format(color.r * 255, color.g * 255, color.b * 255, level, name)
    else
        text = name
    end
    questNames[questID] = text
    return text
end

-- Many townsfolk also give quests, and their quest pin would cover them. A
-- townsfolk pin on a quest pin moves a little down and right and shrinks, so
-- both show; the shared tooltip still lists both. The quest pins drawn go into
-- a grid of NEAR-sized cells (x, y pairs, flat), so a townsfolk pin looks at
-- nine cells rather than at every quest pin.
local NEAR, NUDGE = 0.005, 0.007
local CELLS = 4096 -- cells per row of the grid key; a map and its neighbours span far fewer

local function MarkQuestPin(grid, x, y)
    local key = math.floor(x / NEAR) * CELLS + math.floor(y / NEAR)
    local cell = grid[key]
    if not cell then
        cell = {}
        grid[key] = cell
    end
    cell[#cell + 1] = x
    cell[#cell + 1] = y
end

local function NearQuestPin(grid, x, y)
    local cx, cy = math.floor(x / NEAR), math.floor(y / NEAR)
    for i = cx - 1, cx + 1 do
        for j = cy - 1, cy + 1 do
            local cell = grid[i * CELLS + j]
            if cell then
                for k = 1, #cell, 2 do
                    if math.abs(cell[k] - x) < NEAR and math.abs(cell[k + 1] - y) < NEAR then return true end
                end
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- OpenMap: its stitched map shows the zones around the one underneath, but only
-- switches that one once the view has rested, so pins tied to it came late. While
-- OpenMap stitches, the zones near it are drawn on its canvas too, already there.
---------------------------------------------------------------------------
local REACH = 1                -- how far past the host map's edges, in host map widths
local worldRects = {}          -- mapID -> { u, v, width, height } on OpenMap's world, or false

local function WorldRect(mapID)
    local r = worldRects[mapID]
    if r == nil then
        local u0, v0 = OpenMapAPI.WorldFromMap(mapID, 0, 0)
        local u1, v1 = OpenMapAPI.WorldFromMap(mapID, 1, 1)
        r = (u0 and u1 and u1 ~= u0 and v1 ~= v0) and { u0, v0, u1 - u0, v1 - v0 } or false
        worldRects[mapID] = r
    end
    return r
end

-- fn(mapID, toHost) for each map of `maps` near the host, toHost(x, y) giving a point
-- of that map on the host's canvas. Nothing without OpenMap, or while it isn't stitching.
local function ForNeighbours(host, maps, fn)
    local om = OpenMapAPI -- nil without OpenMap
    if not (om and om.IsStitched and om.IsStitched()) then return end
    local h = WorldRect(host)
    if not h then return end
    for mapID in pairs(maps) do
        local r = mapID ~= host and WorldRect(mapID)
        if r then
            local ax, ay = (r[1] - h[1]) / h[3], (r[2] - h[2]) / h[4]
            local sx, sy = r[3] / h[3], r[4] / h[4]
            if ax + sx > -REACH and ax < 1 + REACH and ay + sy > -REACH and ay < 1 + REACH then
                fn(mapID, function(x, y) return ax + x * sx, ay + y * sy end)
            end
        end
    end
end

-- Skill line IDs of the professions and secondary skills the character has:
-- read when first needed and again after SKILL_LINES_CHANGED; false when this
-- client cannot say (then nothing is filtered).
local knownSkills

local function ReadKnownSkills()
    if not GetProfessions then return false end
    local known = {}
    for _, index in pairs({ GetProfessions() }) do
        local skillLine = select(7, GetProfessionInfo(index))
        if skillLine then known[skillLine] = true end
    end
    return known
end

local function AddTownsfolkPins(map, mapID, size, questPins)
    if not AnyTownsfolk() then return end
    if not townsReady then
        StartBackground() -- the pins follow when the index is done
        return
    end
    if db.tfOnlyMine and knownSkills == nil then knownSkills = ReadKnownSkills() end
    local known = db.tfOnlyMine and knownSkills or nil
    local function Draw(list, toHost)
        for _, npc in ipairs(list) do
            local t, profession = npc[TYPE], npc[PROF]
            -- A trainer Questie's lists don't know stays visible: better too many than missing.
            local wanted = t.trainer ~= "profession" or not known or not profession or known[profession]
            if db[t.key] and wanted and (t.trainer ~= "class" or npc[CLASS] == player.class) then
                local x, y, pinSize = npc[X], npc[Y], size
                if toHost then x, y = toHost(x, y) end
                if NearQuestPin(questPins, x, y) then
                    x, y, pinSize = x + NUDGE, y + NUDGE, size * 0.75
                end
                local pin = map:AcquirePin(PIN, { npc = npc })
                pin:SetPosition(x, y)
                pin:SetSize(pinSize, pinSize)
                pin:Show()
            end
        end
    end
    if townsByMap[mapID] then Draw(townsByMap[mapID]) end
    ForNeighbours(mapID, townsByMap, function(other, toHost) Draw(townsByMap[other], toHost) end)
end

function DataProvider:RefreshAllData()
    local start = debugprofilestop()
    self:DrawAll()
    perf.last = debugprofilestop() - start
    perf.slowest = math.max(perf.slowest, perf.last)
    perf.count = perf.count + 1
end

function DataProvider:DrawAll()
    self:RemoveAllData()
    if not db then return end
    local mapID = self:GetMap():GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info or info.mapType == Enum.UIMapType.Continent or info.mapType == Enum.UIMapType.World
        or info.mapType == Enum.UIMapType.Cosmic then
        return
    end
    RefreshPlayer()
    wipe(availableNow)
    local size = db.smallPins and 16 or 22
    local questPins = self:AddQuestPins(mapID, size)
    AddTownsfolkPins(self:GetMap(), mapID, size, questPins)
end

-- Returns the grid of quest pins drawn (MarkQuestPin), so townsfolk can step aside.
function DataProvider:AddQuestPins(mapID, size)
    local grid = {}
    if not db.showPins then return grid end
    if not questReady then
        StartBackground() -- the pins follow when the index is done
        return grid
    end
    if db.holidays and holidayDay ~= C_DateAndTime.GetCurrentCalendarTime().monthDay then ReadHolidays() end
    local map = self:GetMap()
    local function Draw(spots, toHost)
        for _, spot in ipairs(spots) do
            local names
            for i = 3, #spot do
                local questID = spot[i]
                if IsAvailable(questID) then
                    names = names or {}
                    names[#names + 1] = QuestName(questID)
                end
            end
            if names then
                local x, y = spot[1], spot[2]
                if toHost then x, y = toHost(x, y) end
                local pin = map:AcquirePin(PIN, { quests = names })
                pin:SetPosition(x, y)
                pin:SetSize(size, size)
                pin:Show()
                MarkQuestPin(grid, x, y)
            end
        end
    end
    if byMap[mapID] then Draw(byMap[mapID]) end
    ForNeighbours(mapID, byMap, function(other, toHost) Draw(byMap[other], toHost) end)
    return grid
end

-- One redraw a frame, however many events ask, and none while the map is closed:
-- opening it redraws anyway.
local redrawPending = false
local function Redraw()
    redrawPending = false
    if WorldMapFrame:IsShown() then DataProvider:RefreshAllData() end
end
function RequestRedraw()
    if redrawPending or not WorldMapFrame:IsShown() then return end
    redrawPending = true
    C_Timer.After(0, Redraw)
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
                StartBackground() -- a townsfolk type ticked with the map closed builds its index now
                RequestRedraw()
            end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end
    Checkbox("showPins", "Show quest pins", "Pin quests you can pick up on the world map.")
    Checkbox("smallPins", "Small pins", "Draw the pins smaller.")
    local above = Settings.RegisterProxySetting(category, "BQP_maxAbove", Settings.VarType.Number,
        "Levels above you", DEFAULTS.maxAbove, function() return db.maxAbove end, function(value)
            db.maxAbove = value
            RequestRedraw()
        end)
    local options = Settings.CreateSliderOptions(0, 10, 1)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
        return ("+%d"):format(value)
    end)
    Settings.CreateSlider(category, above, options, "Hide quests more than this many levels above you.")
    Checkbox("holidays", "Holiday quests", "Also pin quests of a holiday that is running today, like the Darkmoon Faire or Hallow's End.")

    category = Settings.RegisterVerticalLayoutSubcategory(main, "Townsfolk")
    mainCategory, townsCategory = main, category
    for _, t in ipairs(TOWNSFOLK) do
        Checkbox(t.key, t.name, ("Pin friendly %s on the world map."):format(t.name:lower()))
    end
    Checkbox("tfOnlyMine", "Only my professions", "Profession trainers only for professions and secondary skills you have.")
    Settings.RegisterAddOnCategory(main)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Print(text) print(BRAND .. ": " .. text) end

SLASH_BETTERQUESTPINS1 = "/bqp"
SlashCmdList.BETTERQUESTPINS = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" then
        Settings.OpenToCategory(mainCategory:GetID())
    elseif cmd == "town" or cmd == "townsfolk" then
        Settings.OpenToCategory(townsCategory:GetID())
    elseif cmd == "pins" then
        db.showPins = not db.showPins
        RequestRedraw()
        Print("quest pins " .. (db.showPins and "on" or "off"))
    elseif cmd == "why" and tonumber(arg) then
        ExplainNpc(tonumber(arg))
    elseif cmd == "perf" then
        local pins, spots, spawns = 0, 0, 0
        for _ in WorldMapFrame:EnumeratePinsByTemplate(PIN) do pins = pins + 1 end
        for _, list in pairs(byMap or {}) do spots = spots + #list end
        for _, list in pairs(townsByMap or {}) do spawns = spawns + #list end
        collectgarbage("collect") -- what is held, not what is waiting to be freed
        UpdateAddOnMemoryUsage()
        Print(("memory %.1f KB after a collection; %d quest spots and %d townsfolk spawns indexed"):format(
            GetAddOnMemoryUsage(ADDON), spots, spawns))
        Print(("pins: %d on the map now, %d more kept by the map for reuse"):format(pins, math.max(0, pinFrames - pins)))
        Print(("map redraw: last %.1f ms, slowest %.1f ms, %d redraws"):format(perf.last, perf.slowest, perf.count))
        Print(("index, built in the background: quests %.1f ms, townsfolk %.1f ms%s"):format(
            perf.quests, perf.towns, jobs[1] and " (still building)" or ""))
    else
        Print("commands:")
        print("  /bqp - open settings")
        print("  /bqp town - open the townsfolk settings")
        print("  /bqp pins - turn quest pins on or off")
        print("  /bqp why <npcID> - explain why an NPC has a townsfolk pin or not")
        print("  /bqp perf - memory, and how long the map redraws take")
    end
end

WorldMapFrame:AddDataProvider(DataProvider)

-- Quest log, level, skill, reputation and spell changes alter what is available
-- and which trainers are yours; they redraw the map while it is open.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        BetterQuestPinsDB = BetterQuestPinsDB or {}
        db = BetterQuestPinsDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        RegisterSettings()
        C_Timer.After(3, StartBackground)
        -- Calendar data loads after a request; CALENDAR_UPDATE_EVENT_LIST says it arrived.
        if C_Calendar and C_Calendar.OpenCalendar then
            self:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
            C_Calendar.OpenCalendar()
        end
        for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP",
            "SKILL_LINES_CHANGED", "UPDATE_FACTION", "SPELLS_CHANGED" }) do
            self:RegisterEvent(e)
        end
        return
    end
    if event == "CALENDAR_UPDATE_EVENT_LIST" then ReadHolidays() end
    if event == "SKILL_LINES_CHANGED" then knownSkills = nil end
    RequestRedraw()
end)
