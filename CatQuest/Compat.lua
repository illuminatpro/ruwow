-- Совместимость с клиентом WoW 3.3.5a.
-- На новых клиентах недостающие куски не подменяются: если API уже есть, остаётся родной.
local ADDON, ns = ...

local TOC = select(4, GetBuildInfo()) or 0
-- 3.3.5a = 30300. Катаклизм и новее начинаются с 40000.
ns.legacy = TOC < 40000
-- С 9.0 SetBackdrop есть только у фреймов с BackdropTemplate. На 3.3.5 такого шаблона нет.
ns.Backdrop = (TOC >= 90000) and "BackdropTemplate" or nil

---------------------------------------------------------------------------
-- Методы виджетов, которых нет в 3.3.5
---------------------------------------------------------------------------
local function SetSize(self, w, h)
    self:SetWidth(w)
    self:SetHeight(h or w)
end

local function SetShown(self, shown)
    if shown then self:Show() else self:Hide() end
end

local function SetEnabled(self, on)
    if on then self:Enable() else self:Disable() end
end

local function Noop() end

local function PatchIndex(obj, methods)
    local mt = getmetatable(obj)
    if not mt then return end
    local idx = mt.__index
    if type(idx) == "table" then
        for name, fn in pairs(methods) do
            if idx[name] == nil then idx[name] = fn end
        end
        return
    end
    -- На части сборок __index — функция. Подменяем её один раз и складываем методы рядом.
    if type(idx) ~= "function" then return end
    local extra = mt.__cqExtra
    if not extra then
        extra = {}
        mt.__cqExtra = extra
        local orig = idx
        mt.__index = function(self, key)
            local v = extra[key]
            if v ~= nil then return v end
            return orig(self, key)
        end
    end
    for name, fn in pairs(methods) do
        if extra[name] == nil then extra[name] = fn end
    end
end

local function Patch(widget, methods)
    local ok, obj = pcall(CreateFrame, widget, nil, UIParent)
    if not ok or not obj then return end
    PatchIndex(obj, methods)
    obj:Hide()
    obj:SetParent(nil)
end

for _, widget in ipairs({
    "Frame", "Button", "StatusBar", "CheckButton", "ScrollFrame", "EditBox", "Slider", "PlayerModel",
}) do
    local methods = { SetSize = SetSize, SetShown = SetShown, SetIgnoreParentScale = Noop }
    if widget == "Button" or widget == "CheckButton" or widget == "Slider" then
        methods.SetEnabled = SetEnabled
    end
    Patch(widget, methods)
end

do
    -- Текстуры и надписи — не фреймы. Без SetSize/SetShown голова обрывается на портрете
    -- и окно «Мои квесты» падает на пустой строке.
    local region = { SetSize = SetSize, SetShown = SetShown }
    local tex = UIParent:CreateTexture(nil, "OVERLAY")
    region.SetColorTexture = function(self, r, g, b, a)
        self:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        self:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    end
    PatchIndex(tex, region)
    tex:Hide()

    local fs = UIParent:CreateFontString(nil, "OVERLAY")
    PatchIndex(fs, { SetSize = SetSize, SetShown = SetShown, SetWordWrap = Noop })
    fs:Hide()
end

if not GetPhysicalScreenSize then
    function GetPhysicalScreenSize()
        local windowed = GetCVar("gxWindow")
        local res = (windowed == "0") and GetCVar("gxResolution") or GetCVar("gxWindowedResolution")
        local w, h = tostring(res or ""):match("(%d+)x(%d+)")
        return tonumber(w) or 1024, tonumber(h) or 768
    end
end

if not strtrim then
    function strtrim(s)
        return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
    end
end

if not wipe then
    function wipe(t)
        for k in pairs(t) do t[k] = nil end
        return t
    end
end

if not strlenutf8 then
    function strlenutf8(s)
        local _, n = tostring(s):gsub("[^\128-\191]", "")
        return n
    end
end

---------------------------------------------------------------------------
-- Таймеры. В чистом 3.3.5a C_Timer нет. На клиентах с SharedXML/C_TimerAugment.lua
-- глобальный C_Timer есть, но его NewTicker/After сравнивают число с функцией и
-- роняют интерфейс (C_TimerAugment.lua:36). Свой планировщик не вызывает его и не
-- подменяет глобал, поэтому чужие аддоны остаются на клиентской реализации.
---------------------------------------------------------------------------
do
    local runner = CreateFrame("Frame")
    local timers = {}
    runner:Hide()
    runner:SetScript("OnUpdate", function(_, elapsed)
        if #timers == 0 then
            runner:Hide()
            return
        end
        for i = #timers, 1, -1 do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            else
                t.left = t.left - elapsed
                if t.left <= 0 then
                    if t.repeating then
                        t.left = t.left + t.interval
                        if t.left <= 0 then t.left = t.interval end
                    else
                        table.remove(timers, i)
                    end
                    local ok, err = pcall(t.fn)
                    if not ok and geterrorhandler then geterrorhandler()(err) end
                end
            end
        end
        if #timers == 0 then runner:Hide() end
    end)

    local function Schedule(delay, fn, repeating)
        delay = tonumber(delay) or 0
        if delay < 0 then delay = 0 end
        local t = { left = delay, interval = delay, fn = fn, repeating = repeating, cancelled = false }
        timers[#timers + 1] = t
        runner:Show()
        return {
            Cancel = function() t.cancelled = true end,
            IsCancelled = function() return t.cancelled end,
        }
    end

    function ns.After(delay, fn) Schedule(delay, fn, false) end
    function ns.NewTimer(delay, fn) return Schedule(delay, fn, false) end
    function ns.NewTicker(interval, fn) return Schedule(interval, fn, true) end
end

---------------------------------------------------------------------------
-- Анимации: в 3.3.5 альфа задаётся приращением, а не From/To
---------------------------------------------------------------------------
function ns.ApplyAlphaAnim(anim, from, to)
    -- На 3.3.5 движок анимации смотрит только на SetChange. Если у клиента есть
    -- пустой SetFromAlpha (бэкпорт), смена остаётся 0 и анимация кончается в тот же кадр.
    if not ns.legacy and anim.SetFromAlpha then
        anim:SetFromAlpha(from)
        anim:SetToAlpha(to)
        return true
    end
    anim:SetChange(to - from)
    return false
end

function ns.ApplyScaleAnim(anim, fx, fy, tx, ty)
    if anim.SetScaleFrom then
        anim:SetScaleFrom(fx, fy)
        anim:SetScaleTo(tx, ty)
        return
    end
    if anim.SetScale then
        anim:SetScale(tx / math.max(fx, 0.01), ty / math.max(fy, 0.01))
    end
end

---------------------------------------------------------------------------
-- Звук. На 3.3.5 PlaySoundFile ничего не возвращает и дорожку нельзя остановить,
-- а PlayMusic файл зацикливает. Так же, как WowVoice: ogg играем через PlayMusic
-- (путь не переписываем в mp3 — клиент Sirus/3.3.5 этот ogg воспроизводит).
-- Громкость — ползунок «Музыка». StopMusic на Sirus файл не обрывает, поэтому
-- после реплики на мгновение выключаем музыкальный канал.
---------------------------------------------------------------------------
function ns.DialogShown()
    return (QuestFrame and QuestFrame:IsShown())
        or (GossipFrame and GossipFrame:IsShown())
        or (ItemTextFrame and ItemTextFrame:IsShown())
end

local function LegacyForceMusic()
    if not (GetCVar and SetCVar) then return end
    if ns._musicSavedVol == nil then
        ns._musicSavedVol = GetCVar("Sound_MusicVolume")
        ns._musicSavedEnable = GetCVar("Sound_EnableMusic")
    end
    SetCVar("Sound_EnableMusic", "1")
    local vol = tonumber(ns._musicSavedVol) or 0
    if ns._musicSavedEnable ~= "1" or vol < 0.15 then
        SetCVar("Sound_MusicVolume", "1")
    end
end

local function LegacyRestoreMusic()
    if not SetCVar or ns._musicSavedVol == nil then return end
    SetCVar("Sound_MusicVolume", ns._musicSavedVol)
    SetCVar("Sound_EnableMusic", ns._musicSavedEnable or "1")
    ns._musicSavedVol, ns._musicSavedEnable = nil, nil
end

function ns.PlayVoiceFile(path, channel)
    if not ns.legacy then
        channel = channel or (ns.SoundChannel and ns.SoundChannel()) or "Master"
        local willPlay, handle = PlaySoundFile(path, channel)
        if willPlay then return true, handle end
        return false, nil
    end
    -- 3.3.5: у PlaySoundFile один аргумент и дорожку нельзя остановить, поэтому
    -- реплика идёт через PlayMusic — тем же вызовом, что ogg в WowVoice.
    -- Файл не переписываем в mp3: пак автора лежит в ogg и клиент его играет.
    LegacyForceMusic()
    PlayMusic(path)
    ns._usingMusic = true
    return true, "music"
end

function ns.StopVoiceHandle(handle)
    if handle == "sound" then return end
    if handle == "music" or (ns.legacy and ns._usingMusic and (handle == nil or handle == "music")) then
        ns._usingMusic = false
        if StopMusic then StopMusic() end
        if not ns.legacy then return end
        local token = (ns._musicToken or 0) + 1
        ns._musicToken = token
        -- Короткий зазор: если очередь сразу ставит следующий файл, глушить нельзя.
        -- Иначе PlayMusic уже зациклил конец реплики — обрываем канал, как /wv stopmode cvar.
        ns.After(0.05, function()
            if ns._musicToken ~= token or ns._usingMusic then return end
            if ns.state and (ns.state.playing or ns.state.pending) then return end
            if ns.queue and #ns.queue > 0 then return end
            if not SetCVar then return end
            SetCVar("Sound_EnableMusic", "0")
            ns.After(0.25, function()
                if ns._musicToken ~= token or ns._usingMusic then return end
                if ns.state and (ns.state.playing or ns.state.pending) then return end
                LegacyRestoreMusic()
            end)
        end)
        return
    end
    if handle and StopSound then
        pcall(StopSound, handle, 300)
    end
end

---------------------------------------------------------------------------
-- Аддоны, сплетни, карта
---------------------------------------------------------------------------
if not C_AddOns then
    C_AddOns = {}
end
if not C_AddOns.GetAddOnMetadata then C_AddOns.GetAddOnMetadata = GetAddOnMetadata end
if not C_AddOns.IsAddOnLoaded then C_AddOns.IsAddOnLoaded = IsAddOnLoaded end

if not C_GossipInfo then C_GossipInfo = {} end
if not C_GossipInfo.GetText and GetGossipText then
    function C_GossipInfo.GetText()
        return GetGossipText()
    end
end

-- Координаты для /cq lore here. UiMapID новых клиентов здесь нет: это areaID 3.3.5.
function ns.LegacyMapPos()
    if not (SetMapToCurrentZone and GetCurrentMapAreaID and GetPlayerMapPosition) then return nil end
    local continent = GetCurrentMapContinent and GetCurrentMapContinent() or nil
    local zone = GetCurrentMapZone and GetCurrentMapZone() or nil
    SetMapToCurrentZone()
    local map = GetCurrentMapAreaID()
    local x, y = GetPlayerMapPosition("player")
    if continent and continent > 0 and SetMapZoom then
        if zone and zone > 0 then SetMapZoom(continent, zone) else SetMapZoom(continent) end
    end
    if not map or not x or not y then return nil end
    return map, x, y
end

---------------------------------------------------------------------------
-- ID NPC из GUID. В 3.3.5 это hex 0xF130<entry 6 hex><счётчик>, не Creature-...-id.
---------------------------------------------------------------------------
function ns.NpcIDFromGUID(guid)
    if not guid or guid == "" then return nil end
    local dash = guid:find("-", 1, true)
    if dash then
        local kind, _, _, _, _, id = strsplit("-", guid)
        if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
        return nil
    end
    local hex = guid:match("0x(%x+)") or guid:match("(%x+)")
    if not hex or #hex < 10 then return nil end
    if #hex < 16 then hex = string.rep("0", 16 - #hex) .. hex end
    local high = tonumber(hex:sub(1, 4), 16)
    -- F130 существо, F140 питомец, F150 транспорт
    if high == 0xF130 or high == 0xF140 or high == 0xF150 then
        return tonumber(hex:sub(5, 10), 16)
    end
    return nil
end

---------------------------------------------------------------------------
-- Журнал квестов. В 3.3.5 GetQuestLogTitle не возвращает ID: он в ссылке Hquest:.
---------------------------------------------------------------------------
local function QuestIDFromLogIndex(index)
    if not index or index <= 0 or not GetQuestLogTitle then return nil end
    local _, _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
    if isHeader then return nil end
    if type(questID) == "number" and questID > 0 then return questID end
    local link = GetQuestLink and GetQuestLink(index)
    return link and tonumber(link:match("quest:(%d+)")) or nil
end

if not C_QuestLog then C_QuestLog = {} end

if not C_QuestLog.GetNumQuestLogEntries and GetNumQuestLogEntries then
    function C_QuestLog.GetNumQuestLogEntries()
        return GetNumQuestLogEntries()
    end
end

if not C_QuestLog.GetInfo and GetQuestLogTitle then
    function C_QuestLog.GetInfo(index)
        local title, level, _, _, isHeader, isCollapsed, isComplete, isDaily = GetQuestLogTitle(index)
        if not title then return nil end
        return {
            title = title,
            level = level,
            isHeader = isHeader,
            isCollapsed = isCollapsed,
            isComplete = isComplete,
            frequency = isDaily and 1 or nil,
            questID = QuestIDFromLogIndex(index),
        }
    end
end

if not C_QuestLog.GetQuestIDForLogIndex then
    function C_QuestLog.GetQuestIDForLogIndex(index)
        return QuestIDFromLogIndex(index)
    end
end

if not C_QuestLog.GetSelectedQuest and GetQuestLogSelection then
    function C_QuestLog.GetSelectedQuest()
        local idx = GetQuestLogSelection()
        if not idx or idx <= 0 then return 0 end
        return QuestIDFromLogIndex(idx) or 0
    end
end

if not C_QuestLog.SetSelectedQuest and SelectQuestLogEntry then
    function C_QuestLog.SetSelectedQuest(questID)
        local n = select(1, GetNumQuestLogEntries())
        for i = 1, n do
            if QuestIDFromLogIndex(i) == questID then
                SelectQuestLogEntry(i)
                return
            end
        end
    end
end

if not C_QuestLog.GetTitleForQuestID and GetQuestLogTitle then
    function C_QuestLog.GetTitleForQuestID(questID)
        local n = select(1, GetNumQuestLogEntries())
        for i = 1, n do
            if QuestIDFromLogIndex(i) == questID then
                return GetQuestLogTitle(i)
            end
        end
    end
end

if not C_QuestLog.IsQuestFlaggedCompleted then
    function C_QuestLog.IsQuestFlaggedCompleted(questID)
        if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(questID) end
        local done = GetQuestsCompleted and GetQuestsCompleted()
        return done and done[questID] and true or false
    end
end

if not C_QuestLog.GetAllCompletedQuestIDs then
    function C_QuestLog.GetAllCompletedQuestIDs()
        local done = GetQuestsCompleted and GetQuestsCompleted() or {}
        local ids = {}
        for id in pairs(done) do ids[#ids + 1] = id end
        return ids
    end
end

---------------------------------------------------------------------------
-- ID квеста в открытом окне. GetQuestID() есть только с 4.0, поэтому
-- текст на экране сверяется с фразами пака CatQuest_Voices.
---------------------------------------------------------------------------
local detailFull, detailPre, completeFull, completePre
local indexBuilt = false

local function Norm(s)
    if not s or s == "" then return "" end
    s = s:lower():gsub("ё", "е")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", "")
    s = s:gsub("|h.-|h", ""):gsub("|H.-|h", "")
    local name = UnitName and UnitName("player")
    if name and name ~= "" then
        -- %w в Lua 5.1 не считает кириллицу буквами, поэтому экранируем только спецсимволы шаблона
        local magic = name:lower():gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        s = s:gsub(magic, "")
    end
    s = s:gsub("%p", ""):gsub("%s", ""):gsub("\194\160", "")
    return s
end

local function Push(map, key, qid)
    if not key or key == "" then return end
    local cur = map[key]
    if cur == nil then
        map[key] = qid
    elseif type(cur) == "number" and cur ~= qid then
        map[key] = { cur, qid }
    elseif type(cur) == "table" then
        for _, id in ipairs(cur) do
            if id == qid then return end
        end
        cur[#cur + 1] = qid
    end
end

local function CuesToText(cues)
    if not cues then return nil end
    local parts = {}
    for i, cue in ipairs(cues) do parts[i] = cue[2] end
    return table.concat(parts, " ")
end

local function AddTexts(full, pre, cues, qid)
    local text = CuesToText(cues)
    if not text then return end
    local n = Norm(text)
    if #n < 16 then return end
    Push(full, n, qid)
    if #n > 48 then Push(pre, n:sub(1, 48), qid) end
end

function ns.EnsureQuestTextIndex()
    if indexBuilt then
        local n = 0
        if detailFull then for _ in pairs(detailFull) do n = n + 1 end end
        return n
    end
    indexBuilt = true
    detailFull, detailPre, completeFull, completePre = {}, {}, {}, {}
    local pack = CatQuestVoicePack and CatQuestVoicePack.quests
    if not pack then return 0 end
    for qid, entry in pairs(pack) do
        local c = entry.c
        if c then
            AddTexts(detailFull, detailPre, c.x, qid)
            AddTexts(detailFull, detailPre, c.m, qid)
            AddTexts(detailFull, detailPre, c.f, qid)
        end
        local tc = entry.t and entry.t.c
        if tc then
            AddTexts(completeFull, completePre, tc.x, qid)
            AddTexts(completeFull, completePre, tc.m, qid)
            AddTexts(completeFull, completePre, tc.f, qid)
        end
    end
    local n = 0
    for _ in pairs(detailFull) do n = n + 1 end
    return n
end

local function Pick(hit, kind, npcID)
    if type(hit) == "number" then return hit end
    if type(hit) ~= "table" then return nil end
    if npcID then
        local order = (kind == "complete") and { ns.QuestFinisher, ns.QuestGiver } or { ns.QuestGiver, ns.QuestFinisher }
        for _, map in ipairs(order) do
            if map then
                for _, qid in ipairs(hit) do
                    if map[qid] == npcID then return qid end
                end
            end
        end
    end
    return hit[1]
end

local function Lookup(kind, text, npcID)
    if not text or text == "" or not indexBuilt then return nil end
    local full = (kind == "complete") and completeFull or detailFull
    local pre = (kind == "complete") and completePre or detailPre
    if not full then return nil end
    local n = Norm(text)
    if n == "" then return nil end
    local hit = full[n]
    if not hit and #n > 48 then hit = pre[n:sub(1, 48)] end
    return Pick(hit, kind, npcID)
end

function ns.QuestIDFromText(text, kind, npcID)
    ns.EnsureQuestTextIndex()
    local id = Lookup(kind or "detail", text, npcID)
    if id then return id end
    if kind == "complete" then return Lookup("detail", text, npcID) end
    if kind == "detail" or kind == "log" or not kind then return Lookup("complete", text, npcID) end
end

function ns.QuestIDFromOpenWindow()
    ns.EnsureQuestTextIndex()
    local kind, text = "detail", nil
    if QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown() then
        kind, text = "complete", GetRewardText and GetRewardText()
    elseif QuestFrameProgressPanel and QuestFrameProgressPanel:IsShown() then
        kind, text = "progress", GetProgressText and GetProgressText()
    else
        text = GetQuestText and GetQuestText()
    end
    local npcID = UnitExists and UnitExists("npc") and ns.NpcIDFromGUID(UnitGUID("npc")) or nil
    local id = Lookup(kind, text, npcID)
    if id then return id end
    -- сдача иногда приходит тем же текстом, что описание, или наоборот
    if kind == "complete" then return Lookup("detail", text, npcID) end
    if kind == "detail" then return Lookup("complete", GetRewardText and GetRewardText(), npcID) end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    -- не на логине: сбор индекса по паку занимает заметную долю секунды
    ns.After(1, function() ns.EnsureQuestTextIndex() end)
end)

---------------------------------------------------------------------------
-- Настройки. Панели Settings (Dragonflight) в 3.3.5 нет.
---------------------------------------------------------------------------
local OPTIONS = {
    { "autoDetail", "При взятии квеста", "Читать описание, когда квест открыт." },
    { "autoComplete", "При сдаче квеста", "Читать текст награды." },
    { "autoProgress", "«Ещё не готово»", "Текст NPC, если задание ещё не выполнено." },
    { "autoGreeting", "Приветствие NPC", "Короткое приветствие перед списком квестов." },
    { "autoGossip", "Болтовню NPC", "Обычный диалог, не квест." },
    { "autoBooks", "Книги и таблички", "Нужен пак CatQuest_Books." },
    { "readTitle", "Название квеста", "Перед описанием. В паке озвучено только описание." },
    { "readObjectives", "Задачу квеста", "Абзац «Задача» после описания." },
    { "queue", "Очередь", "Несколько квестов подряд читаются по одному." },
    { "readAfterAccept", "После кнопки «Принять»", "Читать уже в пути, а не в окне квеста." },
    { "greetDelay", "Ждать приветствие NPC", "Не накладывать голос на реплику NPC." },
    { "stopOnClose", "Стоп при закрытии окна", "Иначе дослушивает на ходу." },
    { "keepInBackground", "Не обрывать в фоне", "Пока идёт озвучка, звук не глушится при сворачивании." },
    { "neural", "Файлы нейро-голоса", "Короткие mp3 из папки voice, если они есть." },
    { "head", "Говорящая голова", "Портрет, имя, полоса времени и субтитры." },
    { "subtitles", "Субтитры", "Текущая фраза под головой." },
    { "headCompact", "Компактная голова", "Только портрет, остальное по наведению." },
    { "headLocked", "Закрепить голову", "Нельзя перетаскивать." },
    { "lore", "Лор мест", "Свиток при входе в описанную зону или подзону." },
    { "loreAuto", "Читать лор при входе", "Первый визит озвучивается сам. Сброс: /cq lore reset." },
    { "report", "Копить отчёт", "/cq export — текст для автора пака." },
    { "collect", "Копить тексты", "Сохранять услышанные тексты в SavedVariables." },
    { "bridge", "Мост к компаньону", "Живая озвучка программой рядом с игрой." },
}

function ns.RegisterLegacyOptions()
    if ns._options then return end
    local panel = CreateFrame("Frame", "CatQuestOptions", UIParent, ns.Backdrop)
    panel:SetSize(440, 520)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        panel:SetBackdropColor(0, 0, 0, 1)
    end
    tinsert(UISpecialFrames, "CatQuestOptions")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("CatQuest")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", 20, -40)
    note:SetPoint("RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetText(ns.legacy
        and "WoW 3.3.5a: громкость озвучки — ползунок «Музыка». Пока говорит персонаж, музыка локации замолкает."
        or "Озвучка квестов, книг и лора мест.")

    local scroll = CreateFrame("ScrollFrame", "CatQuestOptScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -72)
    scroll:SetPoint("BOTTOMRIGHT", -36, 16)
    local content = CreateFrame("Frame", "CatQuestOptContent", scroll)
    content:SetSize(360, #OPTIONS * 26 + 70)
    scroll:SetScrollChild(content)

    for i, opt in ipairs(OPTIONS) do
        local key, label, tip = opt[1], opt[2], opt[3]
        local cb = CreateFrame("CheckButton", "CatQuestOpt" .. i, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 4, -((i - 1) * 26))
        local text = _G["CatQuestOpt" .. i .. "Text"]
        if text then
            text:SetText(label)
            text:SetWidth(300)
            text:SetJustifyH("LEFT")
        end
        cb:SetScript("OnShow", function(self)
            self:SetChecked(CatQuestDB and CatQuestDB[key])
        end)
        cb:SetScript("OnClick", function(self)
            if not CatQuestDB then return end
            CatQuestDB[key] = self:GetChecked() and true or false
            if key == "headCompact" and ns.HeadRelayout then ns.HeadRelayout() end
            if key == "headScale" then return end
        end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end

    local slider = CreateFrame("Slider", "CatQuestHeadScale", content, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 8, -(#OPTIONS * 26 + 16))
    slider:SetWidth(220)
    slider:SetMinMaxValues(0.6, 1.6)
    slider:SetValueStep(0.1)
    if _G.CatQuestHeadScaleText then _G.CatQuestHeadScaleText:SetText("Масштаб головы") end
    if _G.CatQuestHeadScaleLow then _G.CatQuestHeadScaleLow:SetText("0.6") end
    if _G.CatQuestHeadScaleHigh then _G.CatQuestHeadScaleHigh:SetText("1.6") end
    slider:SetScript("OnShow", function(self)
        self._lock = true
        self:SetValue(CatQuestDB and CatQuestDB.headScale or 1)
        self._lock = nil
    end)
    slider:SetScript("OnValueChanged", function(self, value)
        if self._lock or not CatQuestDB then return end
        value = math.floor(value * 10 + 0.5) / 10
        CatQuestDB.headScale = value
        if CatQuestHead then CatQuestHead:SetScale(value) end
    end)

    if ns.legacy and InterfaceOptions_AddCategory then
        panel.name = "CatQuest"
        panel.parent = nil
        -- Отдельная копия не нужна: то же окно открывается и из меню интерфейса, и по /cq options.
        -- InterfaceOptions ждёт панель, которая прячется сама. Клон без кнопок только путает, поэтому
        -- в список модификаций кладём тонкую панель-заглушку со ссылкой.
        local stub = CreateFrame("Frame", "CatQuestOptionsStub")
        stub.name = "CatQuest"
        stub:Hide()
        local hint = stub:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        hint:SetPoint("TOPLEFT", 16, -16)
        hint:SetText("Настройки CatQuest открываются командой /cq options")
        pcall(InterfaceOptions_AddCategory, stub)
        ns._optionsStub = stub
    end

    ns._options = panel
end

function ns.OpenLegacyOptions()
    ns.RegisterLegacyOptions()
    if ns._options:IsShown() then ns._options:Hide() else ns._options:Show() end
end
