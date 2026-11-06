-- BetterQuestPins
-- Puts a pin on the world map for every quest the character can pick up, using the quest
-- givers' positions from QuestieDB.

local ADDON = ...
local BRAND = "|cff33ff99Better|rQuestPins"
local DEFAULTS = { showPins = true, smallPins = false }
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

-- Holiday and world event quests: their givers stand there all year, the quests don't.
local EVENT_SORTS = {
    [-404] = true, [-402] = true, [-378] = true, [-376] = true, [-375] = true, [-374] = true,
    [-370] = true, [-369] = true, [-366] = true, [-364] = true, [-41] = true, [-22] = true,
    [-21] = true, [-368] = true, [-365] = true, [-1000] = true,
}

local function BuildIndex()
    byMap = {}
    for _, questID in ipairs(QuestDB.GetAllIds()) do
        -- Unnamed entries are placeholders the database knows only by ID.
        local starters = not EVENT_SORTS[QuestDB.zoneOrSort(questID) or 0] and QuestDB.name(questID)
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

local function AllCompleted(list)
    for _, id in ipairs(list) do
        if not IsCompleted(id) then return false end
    end
    return true
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
    if questLevel and questLevel >= player.level + 5 then return false end
    local races = QuestDB.requiredRaces(questID)
    if races and races > 0 and bit.band(races, player.raceBit) == 0 then return false end
    local classes = QuestDB.requiredClasses(questID)
    if classes and classes > 0 and bit.band(classes, player.classBit) == 0 then return false end
    -- Profession quests: skill levels aren't checked, so leave them out rather than guess.
    if QuestDB.requiredSkill(questID) then return false end
    local group = QuestDB.preQuestGroup(questID)
    if group and #group > 0 and not AllCompleted(group) then return false end
    local single = QuestDB.preQuestSingle(questID)
    if single and #single > 0 and not AnyCompleted(single) then return false end
    local exclusive = QuestDB.exclusiveTo(questID)
    if exclusive and AnyTaken(exclusive) then return false end
    return true
end

---------------------------------------------------------------------------
-- Map pins
---------------------------------------------------------------------------
local PIN = "BetterQuestPinsPinTemplate"
local MAX_LINES = 10

BetterQuestPinsPinMixin = CreateFromMixins(MapCanvasPinMixin)

function BetterQuestPinsPinMixin:OnLoad()
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_PING")
end

function BetterQuestPinsPinMixin:OnAcquired(names)
    self.names = names
end

-- Lists every quest under the cursor, since pins at one spot overlap.
function BetterQuestPinsPinMixin:OnMouseEnter()
    local names = {}
    for pin in self:GetMap():EnumeratePinsByTemplate(PIN) do
        if pin:IsMouseOver() then
            for _, name in ipairs(pin.names) do names[#names + 1] = name end
        end
    end
    local tooltip = GameTooltip
    tooltip:SetOwner(self, "ANCHOR_LEFT")
    tooltip:AddLine(#names == 1 and AVAILABLE_QUEST or AVAILABLE_QUESTS, 1, 1, 1, true)
    for i = 1, math.min(#names, MAX_LINES) do tooltip:AddLine(names[i]) end
    if #names > MAX_LINES then
        tooltip:AddLine(("+%d more"):format(#names - MAX_LINES), 0.6, 0.6, 0.6)
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

function DataProvider:RefreshAllData()
    self:RemoveAllData()
    if not (db and db.showPins) then return end
    local mapID = self:GetMap():GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info or info.mapType == Enum.UIMapType.Continent or info.mapType == Enum.UIMapType.World
        or info.mapType == Enum.UIMapType.Cosmic then
        return
    end
    if not byMap then BuildIndex() end
    local spots = byMap[mapID]
    if not spots then return end
    RefreshPlayer()
    local size = db.smallPins and 16 or 22
    for _, spot in pairs(spots) do
        local names
        for _, questID in ipairs(spot.quests) do
            if IsAvailable(questID) then
                names = names or {}
                names[#names + 1] = QuestName(questID)
            end
        end
        if names then
            local pin = self:GetMap():AcquirePin(PIN, names)
            pin:SetPosition(spot.x, spot.y)
            pin:SetSize(size, size)
            pin:Show()
        end
    end
end

local function RefreshIfOpen()
    if WorldMapFrame:IsShown() then DataProvider:RefreshAllData() end
end

---------------------------------------------------------------------------
-- Settings panel (Options > AddOns)
---------------------------------------------------------------------------
local function RegisterSettings()
    local category = Settings.RegisterVerticalLayoutCategory(BRAND)
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
    Settings.RegisterAddOnCategory(category)
end

WorldMapFrame:AddDataProvider(DataProvider)

-- Quest log changes alter what is available; redraw only while the map is open.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, name)
    if event ~= "ADDON_LOADED" then return RefreshIfOpen() end
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    BetterQuestPinsDB = BetterQuestPinsDB or {}
    db = BetterQuestPinsDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    RegisterSettings()
    for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
        self:RegisterEvent(e)
    end
end)
