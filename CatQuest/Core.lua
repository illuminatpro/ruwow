-- CatQuest: озвучка квестов/диалогов/книг для WoW Forever.
-- Два источника голоса:
--   1) нейро-озвучка: voice/<хэш>.mp3, сгенерированная tools/catquest_voice.py (есть в CatQuestVoiceIndex);
--   2) встроенный TTS клиента (C_VoiceChat.SpeakText) — запасной вариант, работает сразу.
local ADDON, ns = ...

local VOICE_DIR = "Interface\\AddOns\\" .. ADDON .. "\\voice\\"
local MAX_LINES = 5000
local MAX_HISTORY = 50

BINDING_HEADER_CATQUEST = "CatQuest"
BINDING_NAME_CATQUEST_TOGGLE = "Прочитать / остановить"
BINDING_NAME_CATQUEST_READLOG = "Прочитать выбранный квест в журнале"
BINDING_NAME_CATQUEST_WINDOW = "Окно: мои квесты / история"
BINDING_NAME_CATQUEST_SKIP = "Следующий в очереди"
BINDING_NAME_CATQUEST_LORE = "Рассказчик: лор этого места"

local DEFAULTS = {
    autoDetail = true,     -- читать при взятии квеста
    autoProgress = false,  -- "ты принёс?" — в паке нет, только компаньоном; по умолчанию молчим
    autoComplete = true,   -- текст сдачи квеста
    autoGreeting = false,  -- приветствие NPC — только компаньоном; иначе оно лезет перед озвучкой квеста
    autoGossip = false,    -- обычная болтовня NPC
    autoBooks = true,      -- книги, таблички, лор — в паке CatQuest_Books
    greetDelay = true,     -- начинать читать после приветственной реплики NPC (по длине его реплики)
    readAfterAccept = false, -- читать описание не в окне, а после нажатия «Принять»
    stopOnClose = false,   -- false = дослушиваем на ходу после закрытия окна
    readTitle = true,
    readObjectives = true,
    stripBrackets = true,  -- <Орк смотрит на вас.> -> Орк смотрит на вас.
    neural = true,         -- использовать mp3, если сгенерированы
    bridge = false,        -- живая нейро-озвучка через компаньон (tools/catquest_companion.py)
    collect = true,        -- копить тексты для генератора нейро-озвучки
    report = true,         -- копить отчёт для автора пака (/cq export): квесты без озвучки, расхождения, ошибки
    channel = "Dialog",    -- громкость регулируется ползунком «Диалоги» в настройках игры
    masterChannel = false, -- принудительно в основной канал: если у клиента «Диалоги» включены, а озвучку не слышно (B-12)
    keepInBackground = true, -- не обрывать озвучку при сворачивании игры: на время дорожки включаем звук в фоне (CVar)
    voiceMale = nil,       -- voiceID встроенного TTS (nil = первый доступный)
    voiceFemale = nil,
    rate = 0,              -- -10..10
    volume = 100,          -- 0..100
    bar = { point = "TOP", x = 0, y = -120 },
    queue = true,          -- взятые подряд квесты читаются по очереди, а не перебивают друг друга
    head = true,           -- «говорящая голова»: портрет, имя, квест, прогресс, очередь
    headScale = 1,
    headPos = { point = "BOTTOM", x = 0, y = 190 },
    headLocked = false,
    headCompact = false,   -- только портрет и субтитры; шапка с кнопками разворачивается по наведению
    subtitles = true,      -- субтитры под головой
    storyCard = true,      -- карточка «Сюжет» рядом с описанием квеста в журнале
    lore = true,           -- лор мест: свиток рядом с точкой интереса
    loreAuto = false,      -- рассказ начинается сам при первом входе в место с лором
    loreHeard = {},        -- [ключ места] = true — что уже услышано (все персонажи); /cq lore reset
    npcRaces = {},         -- [npcID] = { раса, пол } — выяснено по модели
    learnedModels = {},    -- [fileID модели] = { раса, пол } — выучено на игроках
    unknownModels = {},    -- [fileID] = имя NPC — модели, которых нет в таблице
    history = {},          -- последние озвученные тексты
    quests = {},           -- [questID] = { detail/progress/complete = {text, npc, sex, title} }
}

local db
local state = {
    text = nil,        -- последний озвученный/подготовленный текст
    meta = nil,
    playing = false,
    source = nil,      -- "tts" | "file"
    soundHandle = nil,
    timer = nil,
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffb347CatQuest:|r " .. tostring(msg))
end

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- Хэш должен совпадать с tools/catquest_voice.py: h = (h*31 + byte) mod 2^32 по UTF-8 байтам.
local function TextHash(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function CleanText(text)
    if not text or text == "" then return "" end
    local s = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|n", "\n")
    if db and db.stripBrackets then
        s = s:gsub("<(.-)>", "%1")
    else
        s = s:gsub("<", "("):gsub(">", ")")
    end
    s = s:gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    return strtrim(s)
end

-- В SavedVariables строки с переводами строк ломают загрузку файла (WoW пишет их как "\"+CRLF
-- и потом не может прочитать — все сохранения аддона сбрасываются). Храним перевод строки как |n,
-- CleanText превращает его обратно.
local function ForStorage(text)
    return (text:gsub("\r", ""):gsub("\n", "|n"))
end
---------------------------------------------------------------------------
-- Воспроизведение
---------------------------------------------------------------------------
local UpdateUI -- forward

-- Свёрнутая игра глушит звук (Sound_EnableSoundWhenGameIsInBG = 0), и дорожка обрывается: при возврате её уже нет.
-- На время нашей дорожки включаем звук в фоне, по окончании возвращаем как было (задевает и остальные звуки игры — но только пока
-- идёт озвучка). Просьба автора 26.09.2026.
local BG_CVAR = "Sound_EnableSoundWhenGameIsInBG"
local function KeepSoundInBackground(on)
    if not (SetCVar and GetCVar) then return end
    if on then
        if db.keepInBackground and GetCVar(BG_CVAR) == "0" then
            SetCVar(BG_CVAR, "1")
            db.bgCVarSet = true  -- в сохранениях: если /reload или вылет во время дорожки, вернём при следующей загрузке
        end
    elseif db.bgCVarSet then
        db.bgCVarSet = nil
        SetCVar(BG_CVAR, "0")
    end
end

local function SetPlaying(playing, source, duration)
    state.playing = playing
    state.source = playing and source or nil
    if playing then
        state.startedAt = GetTime()
        state.duration = duration
        KeepSoundInBackground(source == "pack" or source == "file")
    else
        KeepSoundInBackground(false)
        state.soundHandle = nil
        state.pending = nil  -- отложенный (ждём приветствие) текст — тоже снимается
        if state.timer then state.timer:Cancel(); state.timer = nil end
    end
    -- ошибка в отрисовке (голова/панель) не должна прерывать запуск дорожки: иначе playing=true навсегда и очередь висит
    local ok, e = pcall(UpdateUI)
    if not ok and ns.LogError then ns.LogError("UpdateUI", e) end
end

-- Естественный конец (таймер / событие TTS): очередь берёт следующий текст.
local function Finished()
    local handle = state.soundHandle
    SetPlaying(false)
    -- дорожка доиграла: на 3.3.5 вернуть музыку локации, если очередь пуста
    if handle == "music" and ns.StopVoiceHandle then ns.StopVoiceHandle(handle) end
    if ns.OnPlaybackEnded then ns.OnPlaybackEnded() end
end

ns.state = state

local function Stop()
    if (state.source == "file" or state.source == "pack") and state.soundHandle then
        if ns.StopVoiceHandle then ns.StopVoiceHandle(state.soundHandle)
        elseif StopSound then StopSound(state.soundHandle, 300) end
    end
    if state.source == "bridge" then
        ns.BridgeStop()
    end
    if C_VoiceChat and C_VoiceChat.StopSpeakingText then
        C_VoiceChat.StopSpeakingText()
    end
    SetPlaying(false)
end
ns.Stop = Stop

local function GetVoices()
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        return C_VoiceChat.GetTtsVoices() or {}
    end
    return {}
end

local function PickVoice(sex)
    local voices = GetVoices()
    local id = (sex == 3) and db.voiceFemale or db.voiceMale
    for _, v in ipairs(voices) do
        if v.voiceID == id then return id end
    end
    if sex == 3 and voices[2] then return voices[2].voiceID end
    if voices[1] then return voices[1].voiceID end
    if C_TTSSettings and C_TTSSettings.GetVoiceOptionID then
        return C_TTSSettings.GetVoiceOptionID(0) or 0
    end
    return 0
end

-- Канал звука: «Диалоги». Если игрок выключил диалоги или убрал ползунок в ноль, PlaySoundFile «играет» молча:
-- голова и субтитры идут, звука нет (тестер 26.09.2026 — селфтест проходил, т.к. играл в Master). Тогда — основной канал.
local channelWarned
function ns.SoundChannel()
    if ns.legacy then return "Music" end
    if db.masterChannel then return "Master" end
    if db.channel ~= "Dialog" then return db.channel end
    local enabled = GetCVar and GetCVar("Sound_EnableDialog")
    local volume = tonumber(GetCVar and GetCVar("Sound_DialogVolume")) or 1
    if enabled == "0" or volume < 0.05 then
        if not channelWarned then
            channelWarned = true
            Print("в настройках звука канал «Диалоги» выключен или на нуле — озвучка идёт в основной канал")
        end
        return "Master"
    end
    return "Dialog"
end

local function PlayFile(hash)
    local dur = CatQuestVoiceIndex and CatQuestVoiceIndex[hash]
    if not dur then return false end
    local willPlay, handle = ns.PlayVoiceFile(VOICE_DIR .. hash .. ".mp3")
    if not willPlay then return false end
    state.soundHandle = handle
    SetPlaying(true, "file", dur)
    state.timer = ns.NewTimer(dur + 0.3, function()
        state.timer = nil
        Finished()
    end)
    return true
end

-- Пак озвучки CatQuest_Voices: описание квеста голосом выдающего NPC, заранее сгенерировано.
local PACK_DIR = "Interface\\AddOns\\CatQuest_Voices\\Sounds\\q\\"
local BOOK_DIR = "Interface\\AddOns\\CatQuest_Books\\Sounds\\b\\"  -- отдельный пак: книги, таблички, лор мест

-- Есть ли для текста файл в паке (без запуска): очередь пропускает такие тексты вперёд компаньона/TTS.
function ns.PackHas(text, meta)
    if not (CatQuestVoicePack and meta) then return false end
    if meta.kind == "book" then
        local books = CatQuestVoicePack.books
        return books and books[TextHash(CleanText(text))] ~= nil
    end
    local entry = CatQuestVoicePack.quests and meta.quest and CatQuestVoicePack.quests[meta.quest]
    if not entry then return false end
    if meta.kind == "complete" then return entry.t ~= nil end
    return entry.d ~= nil and (meta.kind == "detail" or meta.kind == "log")  -- запись только со сдачей — описания нет
end

local function PlayPack(meta)
    local pack = CatQuestVoicePack and CatQuestVoicePack.quests
    local entry = pack and meta.quest and pack[meta.quest]
    local file = tostring(meta.quest)
    local dir = PACK_DIR
    if meta.kind == "book" then
        -- книги/таблички: ID нет, файл ищется по хэшу очищенного текста страницы (Sounds/b/<хэш>.ogg)
        local books = CatQuestVoicePack and CatQuestVoicePack.books
        entry = books and meta.hash and books[meta.hash]
        file, dir = tostring(meta.hash), BOOK_DIR
    elseif entry and meta.kind == "complete" then
        entry, file = entry.t, file .. "_t"  -- сдача: отдельная запись и файл <id>_t.ogg
    elseif not (entry and entry.d and (meta.kind == "detail" or meta.kind == "log")) then
        entry = nil
    end
    if not entry then return false end
    if ns.CheckMismatch then ns.CheckMismatch(entry, meta) end  -- QA: голос из пака против NPC перед игроком
    local suffix = entry.g and (UnitSex("player") == 3 and "_f" or "_m") or ""
    local willPlay, handle = ns.PlayVoiceFile(dir .. file .. suffix .. ".ogg")
    if not willPlay then
        -- запись в паке есть, а клиент файл не видит: чаще всего пак положили при запущенной игре (нужен полный перезапуск)
        if ns.NoteResult then ns.NoteResult("файл не найден " .. file .. suffix .. ".ogg", meta) end
        if not state.fileWarned then
            state.fileWarned = true
            Print("файл пака " .. file .. suffix .. ".ogg не проигрался — клиент его не видит. Если пак ставили или обновляли "
                .. "при запущенной игре, нужен полный перезапуск клиента (/reload не помогает). Пока читает компаньон/TTS.")
        end
        return false
    end
    if ns.NoteResult then ns.NoteResult("pack", meta) end
    -- Самопроверка источника (B-16): в индексе n = число букв текста, по которому собран файл; если текст на экране
    -- заметно другой (другая редакция локализации, правка Forever) — в отчёт уходит настоящий текст, следующая сборка его возьмёт.
    local n = entry.n and (entry.n[suffix == "_f" and "f" or (suffix == "_m" and "m" or "x")] or entry.n.x)
    local shown = meta.kind == "detail" and meta.desc or state.text
    if shown and not (meta.kind == "detail" and meta.desc) and meta.kind ~= "complete" and meta.kind ~= "book" then
        -- в паке только описание; полный текст (повтор, очередь) несёт ещё название и «Задача:» — без среза каждый такой
        -- повтор уходил в отчёт как «текст не совпал» (+130 букв, B-26)
        if meta.title then shown = shown:gsub("^" .. meta.title:gsub("%p", "%%%0") .. "%.?\n+", "") end
        shown = shown:gsub("\n+Задача: .*$", "")
    end
    if n and shown and ns.ReportTextMismatch then
        local me = UnitName("player")
        local s = me and shown:gsub((me:gsub("%p", "%%%0")), "") or shown
        local got = strlenutf8((s:gsub("[%s%p%d]", "")))
        if math.abs(got - n) > math.max(n * 0.08, 15) then
            ns.ReportTextMismatch(meta, shown, n, got)
        end
    end
    state.soundHandle = handle
    state.cues = entry.c and entry.c[suffix == "_f" and "f" or (suffix == "_m" and "m" or "x")] -- точные тайминги, если есть
    -- В паке озвучено только описание (без названия и «Задача:») — субтитры строим по нему
    if meta.desc then
        state.subtitleText = CleanText(meta.desc)
    elseif state.text then -- повтор из истории/журнала: срезаем название и абзац «Задача:»
        local t = state.text
        if meta.title then t = t:gsub("^" .. meta.title:gsub("%p", "%%%0") .. "%.?\n+", "") end
        state.subtitleText = (t:gsub("\n+Задача: .*$", ""))
    end
    state.voice = entry.v  -- для подсказки на голове
    SetPlaying(true, "pack", entry.d)
    state.timer = ns.NewTimer(entry.d + 0.3, function()
        state.timer = nil
        Finished()
    end)
    return true
end

-- Компаньон (CatQuestCompanion.exe) при установке кладёт в AddOns аддон-маячок CatQuest_Bridge:
-- настройки на Forever не сохраняются, а маячок виден при каждой загрузке — мост включается сам.
function ns.CompanionInstalled()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return loaded and loaded("CatQuest_Bridge") and true or false
end

ns.COMPANION_PATH = "Interface\\AddOns\\CatQuest\\Companion\\CatQuestCompanion.exe"
ns.COMPANION_HELP = "Живая озвучка того, чего нет в паке (новые и кастомные квесты, «ещё не готово»).\n"
    .. "Один раз запустите в папке игры: " .. ns.COMPANION_PATH .. "\n"
    .. "Дальше он стартует сам, сидит в трее и работает без интернета (голоса Silero)."

ns.Print = Print
ns.TextHash, ns.CleanText = TextHash, CleanText  -- для самопроверки (QA.lua)

local ttsWarned
local function PlayTTS(text, sex)
    -- На Forever встроенный TTS без голосов (SpeakText молча падает со статусом 6): не делаем вид, что играем,
    -- иначе «говорящая голова» вылезает на тишину.
    local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    if not (C_VoiceChat and C_VoiceChat.SpeakText) or not voices or #voices == 0 then
        if not ttsWarned then
            ttsWarned = true
            Print("встроенный TTS недоступен в этом клиенте — тексты без озвучки в паке пропускаются")
        end
        return false
    end
    C_VoiceChat.SpeakText(PickVoice(sex), text, db.rate, db.volume, false)
    SetPlaying(true, "tts", strlenutf8(text) / 14)
    -- страховка: если событие FINISHED/FAILED не придёт (Forever «молча» падает), не висеть с playing=true
    state.timer = ns.NewTimer(strlenutf8(text) / 14 + 5, function()
        state.timer = nil
        if state.source == "tts" then Finished() end
    end)
    return true
end

local function Remember(hash, text, meta)
    if not db.collect then return end
    CatQuestLines = CatQuestLines or {}
    if CatQuestLines[hash] then return end
    local n = 0
    for _ in pairs(CatQuestLines) do n = n + 1 end
    if n >= MAX_LINES then return end
    CatQuestLines[hash] = {
        text = ForStorage(text),
        kind = meta.kind,
        quest = meta.quest,
        npc = meta.npc,
        sex = meta.sex,
        time = time(),
    }
end

-- История озвученного: новые сверху, повтор того же текста поднимает его наверх.
-- Поля meta, которые описывают текст и говорящего (сохраняются в истории и квестах).
local META_KEYS = { "kind", "quest", "title", "npc", "npcID", "sex", "sexName", "race", "ctype", "display" }

local function CopyMeta(meta, into)
    into = into or {}
    for _, k in ipairs(META_KEYS) do into[k] = meta[k] end
    return into
end
ns.CopyMeta = CopyMeta

local function AddHistory(text, meta)
    if meta.kind == "test" then return end
    local history = db.history
    local stored = ForStorage(text)
    for i = #history, 1, -1 do
        if history[i].text == stored then table.remove(history, i) end
    end
    table.insert(history, 1, CopyMeta(meta, { text = stored, time = time() }))
    for i = #history, MAX_HISTORY + 1, -1 do history[i] = nil end
    if ns.OnHistoryChanged then ns.OnHistoryChanged() end
end

-- Оригинальные тексты NPC по квестам — чтобы из журнала читать именно их.
local function StoreQuestText(text, meta)
    if not meta.quest or meta.quest == 0 then return end
    local q = db.quests[meta.quest] or {}
    q[meta.kind] = CopyMeta(meta, { text = ForStorage(text) })
    db.quests[meta.quest] = q
end

local function Speak(text, meta)
    text = CleanText(text)
    if text == "" then return end
    meta = meta or {}
    Stop()
    state.text, state.meta, state.subtitleText, state.cues, state.voice = text, meta, nil, nil, nil  -- cues прошлого квеста — не для этого текста
    state.offerText, state.offerMeta = nil, nil
    local hash = TextHash(text)
    meta.hash = hash
    Remember(hash, text, meta)
    AddHistory(text, meta)
    if PlayPack(meta) then return true end
    if db.neural and PlayFile(hash) then return true end
    if db.bridge or ns.CompanionInstalled() then
        ns.BridgeSpeak(text, meta)
        if ns.NoteResult then ns.NoteResult("bridge", meta) end
        -- Когда компаньон закончит, мы не узнаем, поэтому прячем панель по оценке (~14 символов/сек).
        local est = 2 + strlenutf8(text) / 14
        SetPlaying(true, "bridge", est)
        state.timer = ns.NewTimer(est, function()
            state.timer = nil
            Finished()
        end)
        return true
    end
    if ns.NoteResult then ns.NoteResult("tts", meta) end
    return PlayTTS(text, meta.sex)  -- false = озвучить нечем: голову не показываем, очередь идёт дальше
end

-- «Секретные» значения клиента (защищённый контекст): любая строковая операция с ними — ошибка с taint на CatQuest
-- («attempt to perform string conversion on a secret string value», GOSSIP_SHOW, отчёт игрока 27.09.2026). Такие не трогаем.
local function IsSecret(v)
    return v ~= nil and type(issecretvalue) == "function" and issecretvalue(v)
end

-- Подготовить текст (для кнопки/хоткея) и, если нужно, сразу прочитать.
local function Offer(text, meta, auto)
    if IsSecret(text) then return end
    text = CleanText(text)
    if text == "" then return end
    StoreQuestText(text, meta)
    if auto then
        ns.Enqueue(text, meta)
    else
        -- не трогаем state.text/meta во время воспроизведения: иначе голова переключается на NPC открытого окна,
        -- а окно лора теряет свою дорожку. Текст «на кнопку» держим отдельно.
        state.offerText, state.offerMeta = text, meta
        if not state.playing and not state.pending then
            state.text, state.meta = text, meta
        end
        UpdateUI()
    end
end

ns.Speak = function(text, meta) return Speak(text, meta) end

function CatQuest_Toggle()
    if state.playing or state.pending then
        ns.ClearQueue()  -- «стоп» с кнопки/хоткея — вместе с очередью, иначе она висит с «ещё N»
    elseif state.offerText or state.text then
        Speak(state.offerText or state.text, state.offerMeta or state.meta)
    end
end

---------------------------------------------------------------------------
-- Сбор текста из игры
---------------------------------------------------------------------------
-- Текст берём сразу (пока окно открыто), говорящего определяем асинхронно — модель грузится.
-- Приветствие NPC («Приветствую!») игра играет в момент открытия диалога — ровно когда стартует наш файл.
-- Первый текст нового разговора откладываем на длину приветствия этого облика (GreetData), дальше — без задержки.
local lastInteract = 0
local function GreetDelay(info)
    local now = GetTime()
    local fresh = now - lastInteract > 4
    lastInteract = now
    if not fresh or not db.greetDelay then return 0 end
    local d = info.display and ns.GreetByDisplay and ns.GreetByDisplay[info.display]
    return math.min((d or 1.0) + 0.25, 3.5)
end

local function OfferFromNpc(text, kind, questID, auto, desc)
    if IsSecret(text) or IsSecret(desc) then return end
    local title = questID and GetTitleText and GetTitleText()
    if IsSecret(title) then title = nil end
    ns.IdentifyNpc("npc", function(info)
        info.kind, info.quest, info.desc = kind, questID, desc
        info.title = (title and title ~= "") and title or nil
        info.delay = GreetDelay(info)
        -- отчёт для автора (/cq export): до чтения, чтобы попали и квесты, которые игрок не слушал
        if ns.ReportOffer then pcall(ns.ReportOffer, info, kind == "detail" and desc or text) end
        Offer(text, info, auto)
    end)
end

local function Join(parts)
    return table.concat(parts, "\n\n")
end

local function QuestDetailText()
    local parts = {}
    local title = GetTitleText and GetTitleText()
    if db.readTitle and title and title ~= "" then parts[#parts + 1] = title .. "." end
    parts[#parts + 1] = GetQuestText and GetQuestText() or ""
    local obj = GetObjectiveText and GetObjectiveText()
    if db.readObjectives and obj and obj ~= "" then parts[#parts + 1] = "Задача: " .. obj end
    return Join(parts)
end

local function SelectedLogQuestID()
    if C_QuestLog and C_QuestLog.GetSelectedQuest then
        local id = C_QuestLog.GetSelectedQuest()
        if id and id ~= 0 then return id end
    end
    local details = QuestMapFrame and QuestMapFrame.DetailsFrame
    if details and details.questID then return details.questID end
    if GetQuestLogSelection and C_QuestLog and C_QuestLog.GetQuestIDForLogIndex then
        local idx = GetQuestLogSelection()
        if idx and idx > 0 then return C_QuestLog.GetQuestIDForLogIndex(idx) end
    end
end

-- Кнопка журнала — про ВЫБРАННЫЙ квест (B-32): раньше надпись была общая («Стоп», если что-то играет), а клик всегда
-- читал выбранный квест — «Стоп» на другом квесте обрывал текущую дорожку и запускал чтение (выглядело как повтор).
local function QuestQueued(questID)
    for _, item in ipairs(ns.queue or {}) do
        if item.meta and item.meta.quest == questID then return true end
    end
    return false
end

local function LogButtonState()
    local sel = SelectedLogQuestID()
    if not (state.playing or state.pending) then return "read", sel end
    local cur = (state.pending and state.pending.meta) or state.meta
    if sel and cur and cur.quest == sel then return "stop", sel end
    if sel and QuestQueued(sel) then return "queued", sel end
    return "enqueue", sel
end
ns.LogButtonState = LogButtonState

function CatQuest_ReadQuestLog()
    local what, questID = LogButtonState()
    if what == "stop" then
        ns.ClearQueue()  -- как «стоп» везде: вместе с очередью
        return
    end
    if not questID then
        Print("не выбран квест в журнале")
        return
    end
    if what == "queued" then return end
    ns.ReadQuest(questID, what == "enqueue")  -- что-то играет — выбранный квест встаёт следом
end

-- enqueue = true: через очередь (режим «читать после принятия» — взял несколько квестов подряд, читаются по одному);
-- иначе — сразу, перебивая текущее (кнопка «Читать», /cq log, хоткей). Раньше принятие шло напрямую через Speak,
-- Speak делает Stop() — текущая дорожка обрывалась, а очередь после этого не продолжалась (баг автора 26.09.2026).
-- Говорящий по базе аддона (NpcData.lua): для чтения из журнала/истории, когда NPC перед игроком нет.
-- Заполняет только пустые поля: то, что записано при живом разговоре, точнее.
function ns.FillSpeaker(meta)
    if not meta.quest then return meta end
    local id = meta.npcID
    if not id then
        id = (meta.kind == "complete" or meta.kind == "progress") and ns.QuestFinisher and ns.QuestFinisher[meta.quest]
             or ns.QuestGiver and ns.QuestGiver[meta.quest]
        if not id then return meta end
        meta.npcID = id
    end
    local nd = ns.NpcData and ns.NpcData[id]
    if nd then
        meta.npc = meta.npc or nd[4]
        meta.display = meta.display or nd[3]
        meta.race = meta.race or nd[1] or nil
        meta.sexName = meta.sexName or nd[2] or nil
        if meta.sex == nil and nd[2] then meta.sex = (nd[2] == "female") and 3 or 2 end
    end
    return meta
end

function ns.ReadQuest(questID, enqueue)
    local play = enqueue and ns.Enqueue or Speak
    local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
    -- Если квест брали при включённом аддоне — читаем слова NPC его же голосом.
    local saved = db.quests[questID] and db.quests[questID].detail
    if saved then
        local meta = ns.FillSpeaker(CopyMeta(saved))
        meta.title = title or saved.title
        play(saved.text, meta)
        return
    end
    if C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(questID) end
    local desc, obj = GetQuestLogQuestText()
    local parts = {}
    if db.readTitle and title and title ~= "" then parts[#parts + 1] = title .. "." end
    if desc and desc ~= "" then parts[#parts + 1] = desc end
    if db.readObjectives and obj and obj ~= "" then parts[#parts + 1] = "Задача: " .. obj end
    -- квест брали без аддона: голову и голос TTS берём по базе выдающих (26.09.2026: читалось «Рассказчиком» с книгой)
    play(Join(parts), ns.FillSpeaker({ kind = "log", quest = questID, title = title, desc = desc }))
end

local function CurrentQuestID()
    if GetQuestID then
        local id = GetQuestID()
        if id and id ~= 0 then return id end
    end
    -- 3.3.5a не отдаёт ID открытого квеста: ищем его по тексту пака
    if ns.QuestIDFromOpenWindow then return ns.QuestIDFromOpenWindow() end
end

local handlers = {}

function handlers.QUEST_DETAIL()
    OfferFromNpc(QuestDetailText(), "detail", CurrentQuestID(), db.autoDetail and not db.readAfterAccept, GetQuestText and GetQuestText())
end

-- Режим «читать после принятия»: текст NPC сохранён при показе окна, читаем его, когда квест взят.
function handlers.QUEST_ACCEPTED(a, b)
    -- ретейл: (questID); 4.x: (индекс, questID); 3.3.5: часто только индекс в журнале, иногда без аргументов
    local questID
    if type(b) == "number" and b > 0 then
        questID = b
    elseif type(a) == "number" and a > 0 then
        local n = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
        if a <= n and GetQuestLink then
            local link = GetQuestLink(a)
            questID = link and tonumber(link:match("quest:(%d+)"))
        end
        if not questID and a > n then questID = a end
    end
    if not questID and state.offerMeta and state.offerMeta.quest and state.offerMeta.quest > 0 then
        questID = state.offerMeta.quest
    end
    if db.readAfterAccept and db.autoDetail and questID and questID > 0 then
        -- через очередь: несколько принятых подряд читаются по одному, текущее не обрывается.
        -- Чуть позже, чем QUEST_FINISHED окна: иначе «останавливать при закрытии окна» обрывает только что начатое чтение
        ns.After(0.1, function() ns.ReadQuest(questID, true) end)
    end
end

function handlers.QUEST_PROGRESS()
    OfferFromNpc(GetProgressText(), "progress", CurrentQuestID(), db.autoProgress)
end

function handlers.QUEST_COMPLETE()
    OfferFromNpc(GetRewardText(), "complete", CurrentQuestID(), db.autoComplete)
end

function handlers.QUEST_GREETING()
    OfferFromNpc(GetGreetingText(), "greeting", nil, db.autoGreeting)
end

function handlers.GOSSIP_SHOW()
    local text = C_GossipInfo and C_GossipInfo.GetText and C_GossipInfo.GetText()
    OfferFromNpc(text, "gossip", nil, db.autoGossip)
end

function handlers.ITEM_TEXT_READY()
    local text = ItemTextGetText()
    if ns.ReportBook and text then pcall(ns.ReportBook, text, TextHash(CleanText(text))) end
    Offer(text, { kind = "book" }, db.autoBooks)
end

local function OnWindowClosed()
    -- «останавливать при закрытии окна» = вместе с очередью и ожиданием приветствия, иначе остатки очереди
    -- ждут следующего текста и голова висит с «ещё N»
    if db.stopOnClose and (state.playing or state.pending) then ns.ClearQueue() end
end
handlers.GOSSIP_CLOSED = OnWindowClosed
handlers.QUEST_FINISHED = OnWindowClosed
handlers.ITEM_TEXT_CLOSED = OnWindowClosed

-- /reload и выход (B-31): звук PlaySoundFile живёт в клиенте и переживает перезагрузку интерфейса, а наш handle — нет: после
-- /reload дорожку уже не остановить, головы нет, очередь пуста — следующая озвучка ложилась поверх. Глушим до выгрузки.
function handlers.PLAYER_LOGOUT()
    if state.soundHandle then
        if ns.StopVoiceHandle then ns.StopVoiceHandle(state.soundHandle)
        elseif StopSound then StopSound(state.soundHandle, 0) end
    end
    if state.source == "bridge" and ns.BridgeStop then ns.BridgeStop() end
    if C_VoiceChat and C_VoiceChat.StopSpeakingText then C_VoiceChat.StopSpeakingText() end
    KeepSoundInBackground(false)
end

-- Экран загрузки (подземелье, телепорт) интерфейс не перезагружает: дорожка и очередь живы, голову просто перерисовываем.
function handlers.PLAYER_ENTERING_WORLD(isLogin, isReload)
    if not isLogin and not isReload and state.playing then
        local ok, e = pcall(UpdateUI)
        if not ok and ns.LogError then ns.LogError("UpdateUI", e) end
    end
end

function handlers.VOICE_CHAT_TTS_PLAYBACK_STARTED()
    state.lastTtsEvent = "STARTED"
    if state.source == "tts" then UpdateUI() end
end

function handlers.VOICE_CHAT_TTS_PLAYBACK_FINISHED()
    state.lastTtsEvent = "FINISHED"
    if state.source == "tts" then Finished() end
end

function handlers.VOICE_CHAT_TTS_PLAYBACK_FAILED(status)
    state.lastTtsEvent = "FAILED " .. tostring(status)
    Print("встроенный TTS не смог прочитать текст (" .. tostring(status) .. ")")
    if state.source == "tts" then Finished() end
end

function handlers.VOICE_CHAT_TTS_VOICES_UPDATE()
    state.lastTtsEvent = "VOICES_UPDATE (" .. #GetVoices() .. ")"
end

---------------------------------------------------------------------------
-- UI: кнопки на окнах + плавающая панель "играет"
---------------------------------------------------------------------------
local frameButtons = {}
local bar

local function CreateFrameButton(parent, onClick)
    if not parent then return end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(74, 20)
    b:SetFrameStrata("DIALOG")
    -- левее крестика окна: на 3.3.5 он сидит в самом углу
    b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -44, -8)
    b:SetScript("OnClick", onClick or CatQuest_Toggle)
    frameButtons[#frameButtons + 1] = b
    return b
end

local function CreateBar()
    bar = CreateFrame("Frame", "CatQuestBar", UIParent, ns.Backdrop)
    bar:SetSize(170, 28)
    bar:SetPoint(db.bar.point, UIParent, db.bar.point, db.bar.x, db.bar.y)
    bar:SetFrameStrata("HIGH")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    if bar.SetBackdrop then
        bar:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        bar:SetBackdropColor(0, 0, 0, 0.75)
    end
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.bar.point, db.bar.x, db.bar.y = point, x, y
    end)

    bar.label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.label:SetPoint("LEFT", 8, 0)

    bar.stop = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    bar.stop:SetSize(56, 20)
    bar.stop:SetPoint("RIGHT", -4, 0)
    bar.stop:SetText("Стоп")
    bar.stop:SetScript("OnClick", Stop)
    bar:Hide()
end

local LOG_LABELS = { read = "Читать", stop = "Стоп", enqueue = "В очередь", queued = "В очереди" }

local function UpdateLogButton(b)
    local what = ns.LogButtonState and ns.LogButtonState() or "read"
    b:SetText(LOG_LABELS[what])
    b:SetEnabled(what ~= "queued")
end

UpdateUI = function()
    for _, b in ipairs(frameButtons) do
        if b.isLog then
            UpdateLogButton(b)
        else
            b:SetText(state.playing and "Стоп" or "Читать")
        end
    end
    if ns.UpdateHead then ns.UpdateHead() end
    if bar then
        local labels = { file = "Нейро-голос", pack = "Озвучка", bridge = "Компаньон", tts = "TTS" }
        bar.label:SetText(labels[state.source] or "Озвучка")
        bar:SetShown(state.playing)
    end
end

-- Кнопка журнала: надпись зависит от выбранного квеста, а выбор меняется без наших событий — сверяем 4 раза в секунду,
-- пока журнал открыт (дёшево: одна проверка очереди).
local function LogButton(parent)
    local b = CreateFrameButton(parent, CatQuest_ReadQuestLog)
    b.isLog, b.tick = true, 0
    b:SetScript("OnUpdate", function(self, elapsed)
        self.tick = self.tick + elapsed
        if self.tick < 0.25 then return end
        self.tick = 0
        UpdateLogButton(self)
    end)
    UpdateLogButton(b)
    return b
end

local function HookQuestLog()
    local details = QuestMapFrame and QuestMapFrame.DetailsFrame
    if details and not details.catQuestButton then
        details.catQuestButton = LogButton(details)
    end
    local classicLog = QuestLogDetailFrame or QuestLogFrame
    if classicLog and not classicLog.catQuestButton then
        local b = LogButton(classicLog)
        classicLog.catQuestButton = b
        if classicLog == QuestLogFrame then
            b:ClearAllPoints()
            b:SetPoint("BOTTOMRIGHT", classicLog, "BOTTOMRIGHT", -40, 80)
        end
    end
end

---------------------------------------------------------------------------
-- Настройки (Settings API, если есть) + слэш-команды
---------------------------------------------------------------------------
local function RegisterSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
        if ns.RegisterLegacyOptions then ns.RegisterLegacyOptions() end
        return
    end
    local category = Settings.RegisterVerticalLayoutCategory("CatQuest")

    local layout = SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(category)
    local function Header(text)
        if layout and CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end
    local function Check(key, name, tip, onChange)
        local s = Settings.RegisterAddOnSetting(category, "CATQUEST_" .. key, key, db, "boolean", name, DEFAULTS[key])
        Settings.CreateCheckbox(category, s, tip)
        if onChange then s:SetValueChangedCallback(onChange) end
    end
    local function Slider(key, name, min, max)
        local s = Settings.RegisterAddOnSetting(category, "CATQUEST_" .. key, key, db, "number", name, DEFAULTS[key])
        local opts = Settings.CreateSliderOptions(min, max, 1)
        opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return tostring(math.floor(v + 0.5)) end)
        Settings.CreateSlider(category, s, opts, "")
    end

    -- Настройки сгруппированы (27.09.2026): раньше 25 галочек шли одним столбом, нужное искали глазами.
    Header("Что читать")
    Check("autoDetail", "При взятии квеста", "Автоматически озвучивать описание квеста.")
    Check("autoComplete", "При сдаче квеста", "Текст награды.")
    Check("autoProgress", "«Ещё не готово»", "Текст NPC, когда задание не выполнено.")
    Check("autoGreeting", "Приветствие NPC", "Приветствие NPC с несколькими квестами.")
    Check("autoGossip", "Болтовню NPC", "Обычные диалоги (gossip).")
    Check("autoBooks", "Книги и таблички", "Тексты предметов.")
    Check("readTitle", "Название квеста", "Перед описанием читается название (встроенный TTS и компаньон; в паке — только описание).")
    Check("readObjectives", "Задачу квеста", "После описания читается абзац «Задача» (встроенный TTS и компаньон).")

    Header("Как читать")
    Check("queue", "Очередь", "Взятые подряд квесты читаются по очереди; выключено — новый текст перебивает.")
    Check("readAfterAccept", "После принятия квеста", "Описание читается не в окне, а после нажатия «Принять» — в пути.")
    Check("greetDelay", "Ждать приветствие NPC", "Начинать читать после того, как NPC поздоровался (по длине его реплики), чтобы голоса не накладывались.")
    Check("stopOnClose", "Останавливать при закрытии окна", "Выключено = дослушивать на ходу.")
    Check("keepInBackground", "Не обрывать при сворачивании игры", "Пока идёт озвучка, звук игры не глушится в фоне (на это время "
        .. "включается «звук в фоне» в настройках звука и выключается обратно по окончании дорожки).")
    Check("masterChannel", "Играть в основной канал", "Обычно озвучка идёт в канал «Диалоги». Включите, если голова и субтитры идут, "
        .. "а звука нет, хотя «Диалоги» включены — тогда файлы играют в основной канал (громкость — общий ползунок).")
    Check("neural", "Нейро-голос, если сгенерирован", "Проигрывать mp3 из voice/ вместо встроенного TTS.")

    Header("Голова и субтитры")
    Check("head", "Говорящая голова", "Портрет, имя, квест, прогресс и очередь во время озвучки; здесь же — лор мест.")
    Check("subtitles", "Субтитры", "Текущее предложение под говорящей головой.")
    Check("headCompact", "Компактная голова", "Только портрет и субтитры; имя, прогресс и кнопки показываются при наведении.",
          function() if ns.HeadRelayout then ns.HeadRelayout() end end)
    Check("headLocked", "Закрепить голову", "Запретить перетаскивание.")
    do
        local s = Settings.RegisterAddOnSetting(category, "CATQUEST_headScale", "headScale", db, "number", "Масштаб головы", 1)
        local opts = Settings.CreateSliderOptions(0.6, 1.6, 0.1)
        opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return ("%.1f"):format(v) end)
        Settings.CreateSlider(category, s, opts, "")
        s:SetValueChangedCallback(function() if CatQuestHead then CatQuestHead:SetScale(db.headScale) end end)
    end

    Header("Лор мест")
    Check("lore", "Лор мест", "Свиток рядом с историческим местом: нажмите — рассказчик прочитает историю в говорящей голове "
        .. "(через общую очередь с квестами). Свиток можно перетащить.")
    Check("loreAuto", "Читать при входе в локацию", "Впервые попав в зону, подзону или к месту с лором, рассказчик начинает сам, "
        .. "без нажатия на свиток. Что уже услышано (сами или по свитку), помнится на всех персонажах и повторно не играет; "
        .. "в бою рассказ ждёт конца боя, в полёте на такси молчит. Забыть всё: /cq lore reset.")
    if ns.StoryZones then  -- сюжеты зон временно отключены (не загружаются в TOC)
        Check("storyCard", "Карточка «Сюжет» в журнале", "Рядом с описанием квеста: в каком сюжете вы, какая глава, что дальше.")
    end

    Header("Для автора")
    Check("report", "Копить отчёт для автора", "Квесты и книги без озвучки (NPC, его облик и текст), голоса не по персонажу, "
        .. "ошибки аддона. Ничего не отправляется само: /cq export открывает окно, откуда отчёт копируют. Имя персонажа не сохраняется.")
    Check("collect", "Копить тексты для нейро-озвучки", "Сохраняет тексты в SavedVariables для генератора.")

    -- Компаньон: заголовок со статусом + галочка ручного включения (подсказка = инструкция)
    Header("Компаньон (живая озвучка): " .. (ns.CompanionInstalled() and "установлен, мост включён" or "не установлен"))
    Check("bridge", "Мост к компаньону (вручную)",
          ns.COMPANION_HELP .. "\n\nГалочка нужна только если компаньон запущен, но маячок CatQuest_Bridge не установлен. "
          .. "Во время передачи текста в левом верхнем углу мигает полоска пикселей — это канал связи.")

    Header("Встроенный TTS (когда нет озвучки)")
    local function VoiceOptions()
        local c = Settings.CreateControlTextContainer()
        for _, v in ipairs(GetVoices()) do c:Add(v.voiceID, v.name) end
        return c:GetData()
    end
    -- Список голосов может прийти позже (VOICE_CHAT_TTS_VOICES_UPDATE); 0 = "по умолчанию".
    local defaultVoice = 0
    if db.voiceMale == nil then db.voiceMale = defaultVoice end
    if db.voiceFemale == nil then db.voiceFemale = defaultVoice end
    local male = Settings.RegisterAddOnSetting(category, "CATQUEST_voiceMale", "voiceMale", db, "number", "Голос (мужские NPC)", defaultVoice)
    Settings.CreateDropdown(category, male, VoiceOptions, "Встроенный голос для мужских персонажей.")
    local female = Settings.RegisterAddOnSetting(category, "CATQUEST_voiceFemale", "voiceFemale", db, "number", "Голос (женские NPC)", defaultVoice)
    Settings.CreateDropdown(category, female, VoiceOptions, "Встроенный голос для женских персонажей.")
    Slider("rate", "Скорость (встроенный TTS)", -10, 10)
    Slider("volume", "Громкость (встроенный TTS)", 0, 100)

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end

local function Diagnostics()
    Print("interface " .. select(4, GetBuildInfo()) .. ", build " .. select(2, GetBuildInfo()))
    local checks = {
        "C_VoiceChat.SpeakText", "C_VoiceChat.GetTtsVoices", "C_GossipInfo.GetText",
        "C_QuestLog.GetSelectedQuest", "GetQuestLogQuestText", "GetQuestLogSelection",
        "C_QuestLog.GetAllCompletedQuestIDs", "C_QuestLog.IsQuestFlaggedCompleted", "C_QuestLog.GetNumQuestLogEntries",
        "QuestMapFrame.DetailsFrame", "QuestLogFrame", "QuestLogDetailFrame", "Settings.RegisterAddOnSetting",
    }
    for _, path in ipairs(checks) do
        local v = _G
        for part in path:gmatch("[^.]+") do v = type(v) == "table" and v[part] or nil end
        Print(path .. ": " .. (v and "|cff00ff00есть|r" or "|cffff4040нет|r"))
    end
    local voices = GetVoices()
    Print("голосов TTS: " .. #voices)
    for _, v in ipairs(voices) do Print("голос " .. v.voiceID .. ": " .. v.name) end
    if C_VoiceChat and C_VoiceChat.GetRemoteTtsVoices then
        Print("удалённых голосов: " .. #(C_VoiceChat.GetRemoteTtsVoices() or {}))
    end
    if C_TTSSettings and C_TTSSettings.GetVoiceOptionID then
        Print("голос TTS из настроек игры: " .. tostring(C_TTSSettings.GetVoiceOptionID(0)))
    end
    Print("последнее событие TTS: " .. tostring(state.lastTtsEvent))
    local lines, files = 0, 0
    for _ in pairs(CatQuestLines or {}) do lines = lines + 1 end
    for _ in pairs(CatQuestVoiceIndex or {}) do files = files + 1 end
    Print(("собрано текстов: %d, нейро-файлов: %d"):format(lines, files))
end

SLASH_CATQUEST1 = "/cq"
SLASH_CATQUEST2 = "/catquest"
SlashCmdList.CATQUEST = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "stop" then
        ns.ClearQueue()  -- как в README: остановить и очистить очередь
    elseif cmd:match("^mine") then
        ns.Mine(strtrim(cmd:sub(5)))
    elseif cmd:match("^pack") then
        local id = tonumber(cmd:match("%d+"))
        local pack = CatQuestVoicePack and CatQuestVoicePack.quests
        if not pack then
            Print("пак CatQuest_Voices не загружен")
        elseif not id then
            local n = 0
            for _ in pairs(pack) do n = n + 1 end
            Print(("в паке %d квестов; /cq pack <id> — проиграть"):format(n))
        elseif not pack[id] then
            Print("квеста " .. id .. " нет в паке")
        else
            Stop()
            local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
            Print(("пак: %s [%s] %.0f с"):format(title or id, tostring(pack[id].v), pack[id].d or 0))
            if not pack[id].d then
                Print("в паке только сдача этого квеста (описания нет)")
            elseif not PlayPack({ quest = id, kind = "detail" }) then
                Print("файл не проигрался (нужен перезапуск клиента после генерации)")
            end
        end
    elseif cmd == "npc" then
        ns.DescribeNpc()
    elseif cmd == "log" then
        CatQuest_ReadQuestLog()
    elseif cmd == "history" or cmd == "h" or cmd == "quests" or cmd == "q" then
        ns.ToggleHistory(cmd:sub(1, 1) == "h" and "history" or "quests")
    elseif cmd == "diag" then
        Diagnostics()
    elseif cmd == "test" then
        Speak("Привет! Это CatQuest. Так будут звучать задания.", { kind = "test", sex = 2 })
    elseif cmd == "story" then
        if ns.StoryReport then ns.StoryReport(Print) else Print("сюжеты зон временно отключены — дорабатываются") end
    elseif cmd == "selftest" then
        ns.SelfTest(Print)
    elseif cmd == "mismatches" then
        ns.MismatchReport(Print)
    elseif cmd == "report" then
        ns.QuickReport(Print)
    elseif cmd == "errors" then
        ns.ErrorReport(Print)
    elseif cmd == "export" then
        ns.ShowExport()
    elseif cmd:match("^lore") then
        ns.LoreCommand(strtrim(cmd:sub(5)), Print)
    elseif cmd == "companion" then
        Print(ns.CompanionInstalled() and "компаньон: маячок CatQuest_Bridge найден, мост включён"
              or "компаньон: не установлен" .. (db.bridge and " (мост включён вручную)" or ""))
        for line in ns.COMPANION_HELP:gmatch("[^\n]+") do Print(line) end
    elseif cmd == "bridge" then
        Stop()
        ns.BridgeSpeak("Связь с компаньоном установлена. Теперь квесты будут звучать живым голосом.", { kind = "test", sex = 3 })
    elseif cmd == "tts" then
        Stop()
        state.text, state.meta = "Проверка встроенного голоса.", { kind = "test" }
        PlayTTS(state.text, 2)
    elseif cmd == "options" or cmd == "config" then
        if ns.settingsCategory and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(ns.settingsCategory:GetID())
        elseif ns.OpenLegacyOptions then
            ns.OpenLegacyOptions()
        end
    elseif cmd == "" then
        CatQuest_Toggle()
    else
        Print("/cq — повтор/стоп, /cq q — мои квесты, /cq h — история, /cq log — выбранный в журнале, /cq test, /cq diag, /cq options")
        Print("|cffffd100/cq export|r — отчёт для автора (квесты без озвучки, неподходящие голоса, ошибки): скопировать и прислать")
        Print("проверки: /cq selftest — самопроверка, /cq mismatches — голос не по персонажу, /cq errors — ошибки, /cq report — строка для баг-репорта")
    end
end

---------------------------------------------------------------------------
-- Инициализация
---------------------------------------------------------------------------
-- Приветствие: первый запуск — что умеет аддон и где настройки; обновление — одна строка; иначе короткая диагностика.
local function Welcome()
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
    local packs = (CatQuestVoicePack and CatQuestVoicePack.quests) and "пак озвучки найден" or "|cffff6060пак озвучки не найден|r (CatQuest_Voices)"
    if db.firstRun then
        db.firstRun = nil
        db.seenVersion = version
        Print(("|cffffd100добро пожаловать!|r CatQuest %s — русская озвучка квестов, книг и истории мест. %s."):format(version, packs))
        Print("Возьмите квест — его прочитает голос персонажа; над головой появится портрет с субтитрами (её можно тянуть).")
        if ns.legacy then
            Print("Настройки: /cq options. Громкость — ползунок «Музыка»: на 3.3.5a озвучку можно остановить, поэтому она идёт музыкальным каналом.")
        else
            Print("Настройки: Esc > Параметры > Дополнения > CatQuest. Команды: /cq — окно квестов и истории, /cq stop, /cq test, /cq help.")
        end
        return
    end
    if ns.legacy and not db.legacyNoted then
        db.legacyNoted = true
        Print("WoW 3.3.5a: громкость озвучки — ползунок «Музыка». Пока говорит персонаж, музыка локации замолкает.")
    end
    if db.seenVersion ~= version then
        db.seenVersion = version
        Print(("обновлён до %s. Что нового — в README; проблемы — /cq export и автору."):format(version))
    end
    local lines = 0
    for _ in pairs(CatQuestLines) do lines = lines + 1 end
    Print(("сохранения: запуск №%d, история %d, текстов %d; %s"):format(db.loads, #db.history, lines, packs))
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON then
            local firstRun = CatQuestDB == nil
            CatQuestDB = CatQuestDB or {}
            if firstRun then CatQuestDB.firstRun = true end
            CatQuestLines = CatQuestLines or {}
            db = CatQuestDB
            CopyDefaults(db, DEFAULTS)
            if db.channel == "Master" then db.channel = "Dialog" end -- миграция ранних сохранений
            if db.bgCVarSet and SetCVar then SetCVar("Sound_EnableSoundWhenGameIsInBG", "0"); db.bgCVarSet = nil end
            -- Диагностика: переживают ли сохранения перезапуск игры.
            db.loads = (db.loads or 0) + 1
            ns.After(3, Welcome)
        elseif db then
            HookQuestLog() -- журнал квестов может грузиться отдельным аддоном
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        if not db.head then CreateBar() end
        CreateFrameButton(QuestFrame)
        CreateFrameButton(GossipFrame)
        CreateFrameButton(ItemTextFrame)
        HookQuestLog()
        local ok, err = pcall(RegisterSettings)
        if not ok then Print("панель настроек недоступна: " .. tostring(err)) end
        for e in pairs(handlers) do
            pcall(self.RegisterEvent, self, e)
        end
        UpdateUI()
        return
    end
    local handler = handlers[event]
    if handler then
        -- ошибка в одном обработчике не должна ронять остальные; копим для /cq errors
        local ok, e = pcall(handler, ...)
        if not ok then
            if ns.LogError then ns.LogError(event, e) else Print("ошибка в " .. event .. ": " .. tostring(e)) end
        end
    end
end)
