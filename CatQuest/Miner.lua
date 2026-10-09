-- /cq mine: просим сервер прислать данные квестов из CatQuestMineList.
-- Ответ сервера клиент складывает в Cache/WDB/<locale>/questcache.wdb (пишется на диск при выходе),
-- оттуда tools/questcache.py достаёт тексты для пака озвучки.
local ADDON, ns = ...

local DEFAULT_RATE = 10 -- запросов в секунду; /cq mine 3 — медленнее

local miner = CreateFrame("Frame")
local run

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffb347CatQuest:|r " .. msg)
end

local function Report(final)
    Print(("%s: отправлено %d/%d, ответов %d, из них с данными %d"):format(
        final and "готово" or "идёт", run.sent, #run.ids, run.answered, run.loaded))
    -- Итог — в SavedVariables, чтобы tools/ могли прочитать его без копирования из чата.
    CatQuestDB.lastMine = {
        time = time(), rate = run.rate, sent = run.sent, total = #run.ids,
        answered = run.answered, loaded = run.loaded, results = run.results,
    }
    if final then
        Print("Теперь выйдите из игры (не /reload) — кеш запишется на диск.")
    end
end

miner:SetScript("OnEvent", function(_, _, questID, success)
    if not run or not run.pending[questID] then return end
    run.pending[questID] = nil
    run.answered = run.answered + 1
    run.results[questID] = success and true or false
    if success then run.loaded = run.loaded + 1 end
end)

local function Tick()
    if not run then return end
    local id = run.ids[run.sent + 1]
    if not id then
        run.ticker:Cancel()
        C_Timer.After(5, function() Report(true); miner:UnregisterEvent("QUEST_DATA_LOAD_RESULT"); run = nil end)
        return
    end
    run.sent = run.sent + 1
    run.pending[id] = true
    C_QuestLog.RequestLoadQuestByID(id)
    if run.sent % 100 == 0 then Report(false) end
end

function ns.Mine(cmd)
    if cmd == "stop" then
        if run then run.ticker:Cancel(); Report(true); run = nil end
        return
    end
    if run then Print("уже идёт; /cq mine stop — остановить") return end
    local ids = CatQuestMineList
    if not ids or #ids == 0 then
        Print("список пуст — запустите tools/build_minelist.py и перезапустите игру")
        return
    end
    local rate = tonumber(cmd) or DEFAULT_RATE
    run = { ids = ids, sent = 0, answered = 0, loaded = 0, pending = {}, results = {}, rate = rate }
    miner:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    run.ticker = C_Timer.NewTicker(1 / rate, Tick)
    Print(("запрашиваю %d квестов по %d/сек, ~%d сек"):format(#ids, rate, math.ceil(#ids / rate)))
end
