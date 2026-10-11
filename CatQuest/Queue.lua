-- Очередь озвучки: взял 4 квеста подряд — они прочитаются по очереди, а не перебьют друг друга.
local ADDON, ns = ...

local queue = {}
ns.queue = queue

-- Окно «Очередь» (History.lua) и голова обновляются при каждом изменении.
local function Changed()
    if ns.UpdateHead then ns.UpdateHead() end
    if ns.OnQueueChanged then ns.OnQueueChanged() end
end

local function Contains(text)
    for _, item in ipairs(queue) do
        if item.text == text then return true end
    end
    return false
end

-- Поставить в очередь (или прочитать сразу, если ничего не играет / очередь выключена).
function ns.Enqueue(text, meta)
    local st = ns.state
    if not CatQuestDB.queue then
        ns.Speak(text, meta)
        return
    end
    if (st.playing and st.text == text) or (st.pending and st.pending.text == text) or Contains(text) then
        Changed()
        return
    end
    -- Озвучка из пака важнее живого TTS: если сейчас говорит компаньон/встроенный TTS (приветствие, госсип),
    -- а пришёл квест с файлом — обрываем и играем файл сразу, иначе он ждёт, пока договорит машинный голос.
    local packed = ns.PackHas and ns.PackHas(text, meta)
    if st.playing and packed and st.source ~= "pack" and st.source ~= "file" then
        ns.Stop()
        table.insert(queue, 1, { text = text, meta = meta })
        ns.PlayNext()
        return
    end
    table.insert(queue, { text = text, meta = meta })
    if st.playing or st.pending then
        Changed()
    else
        ns.PlayNext()
    end
end

function ns.PlayNext()
    local st = ns.state
    local item = table.remove(queue, 1)
    if ns.OnQueueChanged then ns.OnQueueChanged() end
    if not item then
        if ns.UpdateHead then ns.UpdateHead() end
        return
    end
    -- Ждём приветствие NPC: голова показывается сразу, речь — через meta.delay секунд.
    if item.meta and item.meta.delay and item.meta.delay > 0 and not item.meta.delayed then
        item.meta.delayed = true
        st.pending = item
        if ns.UpdateHead then ns.UpdateHead() end
        ns.After(item.meta.delay, function()
            if st.pending ~= item then return end  -- сняли стопом/скипом
            st.pending = nil
            if not ns.Speak(item.text, item.meta) then ns.PlayNext() end
        end)
        return
    end
    if not ns.Speak(item.text, item.meta) then ns.PlayNext() end  -- озвучить нечем — берём следующий
end

-- Естественный конец воспроизведения (таймер/событие TTS) — через паузу берём следующий.
function ns.OnPlaybackEnded()
    ns.After(0.6, function()
        if not ns.state.playing then ns.PlayNext() end
    end)
end

function ns.Skip()
    ns.state.pending = nil
    ns.Stop()
    ns.PlayNext()
end

function ns.ClearQueue()
    wipe(queue)
    ns.state.pending = nil
    ns.Stop()
    Changed()
end

-- Из окна «Очередь»: прочитать i-й элемент сейчас (текущий обрывается, остальные ждут).
function ns.PlayQueued(i)
    local item = table.remove(queue, i)
    if not item then return end
    ns.state.pending = nil
    ns.Stop()
    table.insert(queue, 1, item)
    ns.PlayNext()
end

function ns.RemoveQueued(i)
    table.remove(queue, i)
    Changed()
end

function CatQuest_Skip()
    ns.Skip()
end
