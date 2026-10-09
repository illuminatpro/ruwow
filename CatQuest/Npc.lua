-- Кто говорит: раса/пол NPC по его 3D-модели, тип существа, ID NPC.
-- UnitRace() для NPC обычно пустой, поэтому "примеряем" модель в невидимом PlayerModel
-- и смотрим ID файла модели (ns.RaceModels). Неизвестные модели дообучаются на игроках.
local ADDON, ns = ...

local MODEL_WAIT = 0.5 -- сек ждём загрузки модели

local probe

local function Probe()
    if probe then return probe end
    probe = CreateFrame("PlayerModel", nil, UIParent)
    probe:SetSize(1, 1)
    probe:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
    probe:SetAlpha(0)
    probe:Show()
    return probe
end

local function NpcID(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    if ns.NpcIDFromGUID then return ns.NpcIDFromGUID(guid) end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function ModelFileID(model)
    if model and model.GetModelFileID then return model:GetModelFileID() end
end

local function SexName(sex)
    return (sex == 3 and "female") or (sex == 2 and "male") or nil
end

local function LookupModel(fileID)
    if not fileID then return end
    local known = ns.RaceModels[fileID] or CatQuestDB.learnedModels[fileID]
    if known then return known[1], known[2] end
end

-- Раса по API (у игроков и некоторых NPC): "Scourge" -> "scourge"
local function ApiRace(unit)
    local _, raceFile = UnitRace(unit)
    return raceFile and raceFile:lower() or nil
end

local function Finish(info, fileID, callback)
    info.model = fileID
    local race, sex = LookupModel(fileID)
    if race then
        info.race, info.raceSource = race, "model"
        info.sexName = sex or info.sexName
    elseif fileID then
        CatQuestDB.unknownModels[fileID] = info.npc or true
    end
    if info.npcID and info.race then
        CatQuestDB.npcRaces[info.npcID] = { info.race, info.sexName }
    end
    callback(info)
end

-- callback(info) вызывается сразу или после загрузки модели (до MODEL_WAIT сек).
-- info = { npcID, npc, sex, sexName, race, raceSource, ctype, model }
function ns.IdentifyNpc(unit, callback)
    if not UnitExists(unit) then
        callback({})
        return
    end
    local info = {
        npcID = NpcID(unit),
        npc = UnitName(unit),
        sex = UnitSex(unit),
        ctype = UnitCreatureType(unit),
    }
    info.sexName = SexName(info.sex)

    local known = info.npcID and ns.NpcData and ns.NpcData[info.npcID]
    if known then
        info.display = known[3]
        if known[1] then
            info.race, info.sexName, info.raceSource = known[1], known[2] or info.sexName, "data"
            callback(info)
            return
        end
    end
    local cached = info.npcID and CatQuestDB.npcRaces[info.npcID]
    if cached then
        info.race, info.sexName, info.raceSource = cached[1], cached[2] or info.sexName, "cache"
        callback(info)
        return
    end
    local apiRace = ApiRace(unit)
    if apiRace then
        info.race, info.raceSource = apiRace, "api"
        callback(info)
        return
    end

    local m = Probe()
    m:ClearModel()
    m:SetUnit(unit)
    local fileID = ModelFileID(m)
    if fileID then
        Finish(info, fileID, callback)
        return
    end
    -- один probe на всех: если предыдущий запрос ещё ждёт модель, завершаем его без модели — иначе его callback
    -- (Offer/ReportOffer) потеряется навсегда
    if m.pendingFinish then
        local pf = m.pendingFinish
        m.pendingFinish = nil
        pf()
    end
    m.pendingFinish = function() Finish(info, nil, callback) end
    local waited = 0
    m:SetScript("OnUpdate", function(self, elapsed)
        waited = waited + elapsed
        local id = ModelFileID(self)
        if id or waited >= MODEL_WAIT then
            self:SetScript("OnUpdate", nil)
            m.pendingFinish = nil
            Finish(info, id, callback)
        end
    end)
end

-- Дообучение: игрок в цели — знаем и расу, и модель.
local learner = CreateFrame("Frame")
learner:RegisterEvent("PLAYER_TARGET_CHANGED")
learner:SetScript("OnEvent", function()
    if not CatQuestDB or not UnitIsPlayer("target") then return end
    local race = ApiRace("target")
    local sex = SexName(UnitSex("target"))
    if not race or not sex then return end
    local m = Probe()
    if m:GetScript("OnUpdate") then return end  -- probe занят определением NPC — не подменять ему модель
    m:ClearModel()
    m:SetUnit("target")
    local fileID = ModelFileID(m)
    if fileID and not ns.RaceModels[fileID] and not CatQuestDB.learnedModels[fileID] then
        CatQuestDB.learnedModels[fileID] = { race, sex }
        CatQuestDB.unknownModels[fileID] = nil
        DEFAULT_CHAT_FRAME:AddMessage(("|cffffb347CatQuest:|r выучил модель %d = %s/%s"):format(fileID, race, sex))
    end
end)

-- /cq npc — что аддон думает о цели (или собеседнике)
function ns.DescribeNpc()
    local unit = UnitExists("npc") and "npc" or "target"
    ns.IdentifyNpc(unit, function(info)
        local p = function(k, v) DEFAULT_CHAT_FRAME:AddMessage("|cffffb347CatQuest:|r " .. k .. ": " .. tostring(v)) end
        p("юнит", unit)
        p("имя / ID", tostring(info.npc) .. " / " .. tostring(info.npcID))
        p("пол", tostring(info.sex) .. " (" .. tostring(info.sexName) .. ")")
        p("тип существа", info.ctype)
        p("модель", info.model)
        p("раса", tostring(info.race) .. " [" .. tostring(info.raceSource) .. "]")
        p("голос-профиль", ns.VoiceKey(info))
    end)
end

-- Ключ профиля голоса, как его увидит компаньон
function ns.VoiceKey(info)
    if info.race then return info.race .. ":" .. (info.sexName or "male") end
    if info.ctype then return "type:" .. info.ctype end
    return info.sexName or "narrator"
end
