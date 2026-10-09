-- Пиксельный мост к компаньону (tools/catquest_companion.py).
-- Аддон не может ни в сеть, ни в файлы, поэтому на несколько секунд рисует
-- в левом верхнем углу сетку цветных клеток, а компаньон считывает её с экрана.
--
-- Протокол (должен совпадать с companion): сетка COLS x ROWS клеток по CELL физ. пикселей.
-- Каждая клетка = 3 ниббла (R, G, B; цвет = ниббл * 17).
--   0..3   синхро: пурпурный, зелёный, пурпурный, зелёный
--   4..19  калибровка: серый 0..15
--   20 msgId, 21 индекс куска, 22 число кусков, 23 длина куска в байтах, 24 контрольная сумма
--   25..   данные: байт -> два ниббла (старший, младший), по 3 ниббла в клетку
local ADDON, ns = ...

local COLS, ROWS, CELL = 96, 8, 4
local HEADER = 25
local CHUNK_BYTES = math.floor((COLS * ROWS - HEADER) * 3 / 2)
local CHUNK_TIME = 0.05  -- сек на кусок (компаньон снимает 60 кадров/с)
local MIN_SHOW = 2.5     -- минимум сек показа сообщения
local MIN_CYCLES = 5     -- минимум полных прокруток всех кусков

local function Value12(v)
    return { math.floor(v / 256) % 16, math.floor(v / 16) % 16, v % 16 }
end

-- Чистая функция (тестируется вне игры): payload -> список кусков, кусок = список клеток {r,g,b}.
function ns.BridgeEncode(payload, msgId)
    local count = math.max(1, math.ceil(#payload / CHUNK_BYTES))
    local chunks = {}
    for c = 0, count - 1 do
        local data = payload:sub(c * CHUNK_BYTES + 1, (c + 1) * CHUNK_BYTES)
        local sum = 0
        for i = 1, #data do sum = (sum + data:byte(i)) % 4096 end

        local cells = {
            { 15, 0, 15 }, { 0, 15, 0 }, { 15, 0, 15 }, { 0, 15, 0 },
        }
        for v = 0, 15 do cells[#cells + 1] = { v, v, v } end
        cells[#cells + 1] = Value12(msgId)
        cells[#cells + 1] = Value12(c)
        cells[#cells + 1] = Value12(count)
        cells[#cells + 1] = Value12(#data)
        cells[#cells + 1] = Value12(sum)

        local nibbles = {}
        for i = 1, #data do
            local b = data:byte(i)
            nibbles[#nibbles + 1] = math.floor(b / 16)
            nibbles[#nibbles + 1] = b % 16
        end
        for i = 1, #nibbles, 3 do
            cells[#cells + 1] = { nibbles[i], nibbles[i + 1] or 0, nibbles[i + 2] or 0 }
        end
        chunks[#chunks + 1] = cells
    end
    return chunks
end

local bridge = { msgId = 0 }
ns.bridge = bridge

local function EnsureFrame()
    if bridge.frame then return bridge.frame end
    local f = CreateFrame("Frame", "CatQuestBridge", UIParent)
    f:SetIgnoreParentScale(true)
    f:SetScale(1)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(10000)
    f:Hide()
    f.tex = {}
    for i = 1, COLS * ROWS do
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(0, 0, 0, 1)
        f.tex[i] = t
    end
    bridge.frame = f
    return f
end

-- Размер клетки в UI-единицах так, чтобы она была ровно CELL физических пикселей.
local function Layout(f)
    local _, physH = GetPhysicalScreenSize()
    local unit = 768 / physH * CELL
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    f:SetSize(COLS * unit, ROWS * unit)
    for i, t in ipairs(f.tex) do
        local k = i - 1
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f, "TOPLEFT", (k % COLS) * unit, -math.floor(k / COLS) * unit)
        t:SetSize(unit, unit)
    end
end

local function Draw(f, cells)
    for i, t in ipairs(f.tex) do
        local c = cells[i]
        if c then
            t:SetColorTexture(c[1] * 17 / 255, c[2] * 17 / 255, c[3] * 17 / 255, 1)
        else
            t:SetColorTexture(0, 0, 0, 1)
        end
    end
end

local function OnUpdate(f, elapsed)
    bridge.elapsed = bridge.elapsed + elapsed
    bridge.total = bridge.total + elapsed
    if bridge.total >= bridge.duration then
        f:Hide()
        f:SetScript("OnUpdate", nil)
        return
    end
    if bridge.elapsed >= CHUNK_TIME then
        bridge.elapsed = 0
        bridge.index = bridge.index % #bridge.chunks + 1
        Draw(f, bridge.chunks[bridge.index])
    end
end

function ns.BridgeSend(payload)
    local f = EnsureFrame()
    bridge.msgId = (bridge.msgId + 1) % 4096
    bridge.chunks = ns.BridgeEncode(payload, bridge.msgId)
    bridge.index, bridge.elapsed, bridge.total = 1, 0, 0
    bridge.duration = math.max(MIN_SHOW, #bridge.chunks * CHUNK_TIME * MIN_CYCLES)
    Layout(f)
    Draw(f, bridge.chunks[1])
    f:SetScript("OnUpdate", OnUpdate)
    f:Show()
end

-- Сообщения:
--   "S\t<пол 2/3>\t<вид>\t<npc>\t<раса>\t<male/female>\t<тип существа>\t<npcID>\n<текст>" — прочитать
--   "X" — остановить
local function Field(v)
    return (tostring(v or ""):gsub("[\t\n]", " "))
end

function ns.BridgeSpeak(text, meta)
    local header = table.concat({
        "S", Field(meta.sex or 0), Field(meta.kind), Field(meta.npc),
        Field(meta.race), Field(meta.sexName), Field(meta.ctype), Field(meta.npcID),
    }, "\t")
    ns.BridgeSend(header .. "\n" .. text)
end

function ns.BridgeStop()
    ns.BridgeSend("X")
end
