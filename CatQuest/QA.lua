-- Самопроверка и сбор расхождений в игре: /cq selftest, /cq mismatches, /cq report.
local ADDON, ns = ...

-- эталонные пары «очищенный текст → хэш» из генератора (tools/import_books.py); расхождение = сломан поиск книг/лора
local HASH_CASES = {
    { "Привет, мир!", "9ad1378c" },
    { "Ан'Кираж — город.", "15d6ee13" },
    { "Строка\r\nс переводом  и  пробелами", "420adb2e" },
}

local mismatches, last = {}, nil

local function VoiceRaceSex(v)
    local race, sex = v:match("^([a-z]+)%-(male)"), nil
    if race then return race, "male" end
    race = v:match("^([a-z]+)%-female")
    if race then return race, "female" end
    return nil, nil
end

-- Вызывается из PlayPack: голос файла (индекс) против расы/пола NPC, которого аддон видит перед игроком.
-- Чем на самом деле сыграли последний текст: pack / bridge / tts / «файл не найден …». Запись голоса в last делается
-- ДО PlaySoundFile, поэтому без этого поля отчёт не отличает «пак играл беззвучно» от «клиент файла не видит, ушли в TTS».
function ns.NoteResult(result, meta)
    if not last or (meta and last.quest ~= meta.quest) then
        last = { quest = meta and meta.quest, kind = meta and meta.kind }
    end
    last.result = result
end

function ns.CheckMismatch(entry, meta)
    last = { quest = meta.quest, kind = meta.kind, voice = entry.v, npc = meta.npc, npcID = meta.npcID, race = meta.race, sex = meta.sexName }
    if not (entry.v and meta.race and meta.sexName) then return end
    local vr, vs = VoiceRaceSex(entry.v)
    if not vs then return end  -- именной голос — не сравниваем
    if vs ~= meta.sexName or (vr ~= "human" and vr ~= meta.race) then
        local key = (meta.quest or 0) .. ":" .. (meta.kind or "")
        if not mismatches[key] then
            mismatches[key] = last
            mismatches[key].n = 1
        else
            mismatches[key].n = mismatches[key].n + 1
        end
    end
end

function ns.MismatchReport(print)
    local n = 0
    for _, m in pairs(mismatches) do
        n = n + 1
        print(("квест %s (%s): голос %s, NPC %s [%s] — %s %s"):format(
            tostring(m.quest), m.kind or "?", m.voice, m.npc or "?", tostring(m.npcID), m.race or "?", m.sex or "?"))
    end
    if n == 0 then print("расхождений голос/персонаж за сессию не замечено") end
end

function ns.QuickReport(print)
    if not last then print("ещё ничего не проигрывалось"); return end
    -- ch = канал озвучки, snd = звук/диалоги включены, dv = громкость диалогов — чтобы «голова идёт, звука нет» читалось из строки
    print(("CQ|q=%s|k=%s|v=%s|r=%s|npc=%s|id=%s|%s/%s|b=%s|ch=%s|snd=%s%s|dv=%d"):format(tostring(last.quest), last.kind or "", last.voice or "",
          last.result or "?", last.npc or "", tostring(last.npcID), last.race or "", last.sex or "", select(2, GetBuildInfo()),
          ns.SoundChannel(), GetCVar("Sound_EnableAllSound"), GetCVar("Sound_EnableDialog"),
          math.floor((tonumber(GetCVar("Sound_DialogVolume")) or 0) * 100 + 0.5)))
end

-- Ошибки обработчиков событий (перехвачены pcall в Core.lua): не роняют аддон, копятся до /cq errors.
local errors = {}
function ns.LogError(where, e)
    local msg = tostring(e)
    local key = where .. ":" .. msg
    if errors[key] then
        errors[key].n = errors[key].n + 1
    else
        errors[key] = { where = where, msg = msg, n = 1, at = date("%H:%M:%S") }
        if ns.ReportError then ns.ReportError(where, msg) end
        ns.Print("|cffff4444ошибка|r в " .. where .. " — подробности: /cq errors")
    end
end

-- «Модификация CatQuest заблокирована при попытке выполнения действия, доступного только интерфейсу Blizzard» (жалоба 30.09.2026,
-- окно /cq export): клиент сообщает имя защищённой функции событием — пишем его в ошибки и в отчёт, иначе чинить вслепую.
local blocked = CreateFrame("Frame")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_FORBIDDEN")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_BLOCKED")
blocked:SetScript("OnEvent", function(_, event, addon, func)
    if type(addon) ~= "string" or addon:sub(1, 8) ~= "CatQuest" then return end
    local stack = debugstack and debugstack(2, 6, 0) or ""
    ns.LogError(event == "ADDON_ACTION_FORBIDDEN" and "forbidden" or "blocked",
        tostring(func) .. (InCombatLockdown and InCombatLockdown() and " [в бою]" or "") .. " | " .. stack:gsub("\n", " < "):sub(1, 300))
end)

function ns.ErrorReport(print)
    local n = 0
    for _, e in pairs(errors) do
        n = n + 1
        print(("%s ×%d [%s] %s"):format(e.where, e.n, e.at, e.msg))
    end
    if n == 0 then print("ошибок за сессию не было") end
end

function ns.SelfTest(print)
    local ok = 0
    local function check(cond, label)
        if cond then ok = ok + 1 end
        print((cond and "|cff44ff44ок|r  " or "|cffff4444НЕТ|r ") .. label)
    end
    local pack = CatQuestVoicePack
    local nq, nb = 0, 0
    if pack and pack.quests then for _ in pairs(pack.quests) do nq = nq + 1 end end
    if pack and pack.books then for _ in pairs(pack.books) do nb = nb + 1 end end
    check(nq > 0, "пак квестов загружен: " .. nq)
    check(nb > 0, "пак книг/лора загружен: " .. nb)
    local hashOk = true
    for _, c in ipairs(HASH_CASES) do
        if ns.TextHash(ns.CleanText(c[1])) ~= c[2] then hashOk = false end
    end
    check(hashOk, "хэш текста совпадает с генератором")
    check(ns.NpcData and next(ns.NpcData) ~= nil, "база NPC")
    check(ns.GreetByDisplay and next(ns.GreetByDisplay) ~= nil, "длительности приветствий")
    local zone = GetRealZoneText and GetRealZoneText() or GetZoneText()
    check(ns.LoreZones and ns.LoreZones[zone] ~= nil, "лор текущей зоны: " .. tostring(zone))
    if ns.legacy then
        check(GetQuestLogQuestText and GetGossipText and GetTitleText and PlayMusic and StopMusic, "API 3.3.5a: квесты, диалоги, музыка")
        local indexed = ns.EnsureQuestTextIndex and ns.EnsureQuestTextIndex() or 0
        check(indexed > 0, "индекс текстов квестов для поиска ID: " .. indexed)
    else
        local api = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.GetSelectedQuest and C_Map and C_Map.GetPlayerMapPosition
        check(api ~= nil, "нужные API клиента")
    end
    -- звук: проверяем тем же каналом, которым играет озвучка (раньше пробный файл шёл в Master и проходил
    -- даже при выключенных «Диалогах» — тестер 26.09.2026: селфтест ок, голоса нет)
    local allOn = GetCVar("Sound_EnableAllSound") ~= "0"
    check(allOn, "звук в игре включён")
    if ns.legacy then
        local musicOn = GetCVar("Sound_EnableMusic") ~= "0"
        local musicVol = math.floor((tonumber(GetCVar("Sound_MusicVolume")) or 0) * 100 + 0.5)
        check(musicOn and musicVol >= 5, ("канал «Музыка» включён, громкость %d%% — на 3.3.5a озвучка идёт через него"):format(musicVol))
    else
        local dialogOn = GetCVar("Sound_EnableDialog") ~= "0"
        local dialogVol = math.floor((tonumber(GetCVar("Sound_DialogVolume")) or 0) * 100 + 0.5)
        check(dialogOn and dialogVol >= 5, ("канал «Диалоги» включён, громкость %d%%"):format(dialogVol)
            .. ((dialogOn and dialogVol >= 5) and "" or " — озвучка пойдёт в основной канал; лучше включить «Диалоги» в настройках звука"))
    end
    -- целостность пака: 20 случайных квестов и 10 книг — файл на месте? (тестер 26.09: первый файл есть, 752.ogg нет →
    -- аддон молча уходил в TTS; PlaySoundFile + StopSound(0) — беззвучная проверка «клиент видит файл»)
    -- На 3.3.5a PlaySoundFile ничего не возвращает, поэтому «файл не найден» отличить нельзя и проба запустила бы музыку.
    local function sample(tbl, n, path)
        if ns.legacy then return 0, {}, true end
        local keys = {}
        for k, e in pairs(tbl) do if e.d then keys[#keys + 1] = k end end  -- записи только со сдачей файла описания не имеют
        local missing, tested = {}, 0
        for _ = 1, math.min(n, #keys) do
            local k = table.remove(keys, math.random(#keys))
            local willPlay, handle = PlaySoundFile(path(k, tbl[k]), "Master")
            if willPlay and handle then StopSound(handle, 0) end
            tested = tested + 1
            if not willPlay then missing[#missing + 1] = tostring(k) end
        end
        return tested, missing, false
    end
    if pack and pack.quests then
        local tested, missing, skipped = sample(pack.quests, 20, function(k, e)
            return "Interface\\AddOns\\CatQuest_Voices\\Sounds\\q\\" .. k .. (e.g and "_m" or "") .. ".ogg" end)
        if skipped then
            check(true, "проверка файлов пака на 3.3.5a недоступна — слушайте пробный звук ниже")
        else
            check(#missing == 0, ("файлы пака квестов на месте: %d из %d случайных"):format(tested - #missing, tested)
                .. (#missing > 0 and (" — нет: " .. table.concat(missing, ", ") .. ". Пак неполный: распакуйте архив заново целиком") or ""))
        end
    end
    if pack and pack.books then
        local tested, missing, skipped = sample(pack.books, 10, function(k, e)
            return "Interface\\AddOns\\CatQuest_Books\\Sounds\\b\\" .. k .. (e.g and "_m" or "") .. ".ogg" end)
        if not skipped then
            check(#missing == 0, ("файлы пака книг на месте: %d из %d случайных"):format(tested - #missing, tested)
                .. (#missing > 0 and (" — нет: " .. table.concat(missing, ", ")) or ""))
        end
    end
    if pack and pack.quests then
        local qid = next(pack.quests)
        for k, e in pairs(pack.quests) do if e.d then qid = k; break end end
        local channel = ns.SoundChannel()
        local path = "Interface\\AddOns\\CatQuest_Voices\\Sounds\\q\\" .. qid .. (pack.quests[qid].g and "_m" or "") .. ".ogg"
        local willPlay, handle = ns.PlayVoiceFile(path, channel)
        check(willPlay, "пробный файл пака проигрывается (квест " .. qid .. ", канал " .. channel .. ") — должно быть слышно секунду")
        if willPlay and handle and ns.StopVoiceHandle then C_Timer.After(1, function() ns.StopVoiceHandle(handle) end) end
    end
    check(ns.CompanionInstalled() or not CatQuestDB.bridge, "мост к компаньону согласован с маячком")
    print(("самопроверка: %d проверок пройдено"):format(ok))
end
