-- «Говорящая голова»: портрет говорящего, имя, название квеста, прогресс с временем, очередь (кликабельно), субтитры на подложке.
-- Лор мест читается здесь же рассказчиком (портрет — свиток), запускается свитком из Lore.lua через общую очередь.
local ADDON, ns = ...

local KIND_LABEL = {
    detail = "Задание", progress = "Задание", complete = "Задание выполнено", greeting = "Приветствие",
    gossip = "Разговор", book = "Текст", log = "Задание", test = "Проверка",
}
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local SCROLL_ICON = "Interface\\ICONS\\INV_Scroll_03"
local FULL_W, FULL_H, COMPACT_W = 360, 78, 78

local head
local sentences, cueTimes = {}, {}

-- Разбивка текста на предложения для субтитров (как в генераторе: по .!?; «…» — это три байта,
-- в наборе символов Lua его использовать нельзя, поэтому многоточие заранее заменяем на точки)
local function SplitSentences(text)
    local out = {}
    text = text:gsub("…", "...")
    for para in text:gmatch("[^\n]+") do
        local start = 1
        for s, e in para:gmatch("()[^%.!%?]*[%.!%?]+%s*()") do
            local piece = strtrim(para:sub(s, e - 1))
            if piece ~= "" then out[#out + 1] = piece end
            start = e
        end
        local rest = strtrim(para:sub(start))
        if rest ~= "" then out[#out + 1] = rest end
    end
    return out
end

-- Тайминги: точные из пака (cues), иначе пропорционально длине предложений.
local function BuildCues(text, meta, duration, cues)
    -- Точные тайминги из пака: { {t, "текст"}, ... } — куски с текстом, как их резал генератор
    if cues and #cues > 0 and type(cues[1]) == "table" then
        sentences, cueTimes = {}, {}
        for i, c in ipairs(cues) do
            cueTimes[i], sentences[i] = c[1], c[2]
        end
        return
    end
    sentences = SplitSentences(text)
    cueTimes = {}
    local total = 0
    for _, s in ipairs(sentences) do total = total + strlenutf8(s) end
    local pos = 0
    for i, s in ipairs(sentences) do
        cueTimes[i] = duration * pos / math.max(total, 1)
        pos = pos + strlenutf8(s) + 3 -- +3 ≈ пауза между предложениями
    end
end

local function CurrentSentence(elapsed)
    local idx = 1
    for i, t in ipairs(cueTimes) do
        if elapsed >= t then idx = i end
    end
    return sentences[idx] or ""
end

local function SetPortrait(tex, meta)
    -- у текстуры круглая маска (SetMask), а с маской SetTexCoord запрещён («Cannot set tex coords when texture has mask»,
    -- 26.09.2026 — голова не показывалась вовсе); края иконок и так срезает маска
    if meta.lore then
        tex:SetTexture(SCROLL_ICON)
        return
    end
    local display = meta.display or (meta.npcID and ns.NpcData and ns.NpcData[meta.npcID] and ns.NpcData[meta.npcID][3])
    -- ID облика в базе с нового клиента; на 3.3.5a портрет берём у NPC, с которым говорим
    if display and not ns.legacy and SetPortraitTextureFromCreatureDisplayID then
        SetPortraitTextureFromCreatureDisplayID(tex, display)
        return
    end
    if meta.npc and UnitExists("npc") and UnitName("npc") == meta.npc then
        SetPortraitTexture(tex, "npc")
        return
    end
    tex:SetTexture(FALLBACK_ICON)
end

local function FormatTime(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local SOURCE_LABEL = { pack = "озвучка из пака", file = "нейро-голос", bridge = "компаньон", tts = "встроенный TTS" }

---------------------------------------------------------------------------
-- Появление/исчезание
---------------------------------------------------------------------------
local function ShowHead()
    if head:IsShown() and not head.hiding then return end
    head.hiding = nil
    head.fadeOut:Stop()
    if not head._absAlpha then head:SetAlpha(0) end
    head:Show()
    head.fadeIn:Play()
end

local function HideHead()
    if not head or not head:IsShown() or head.hiding then return end
    head.hiding = true
    head.fadeIn:Stop()
    head.fadeOut:Play()
end

---------------------------------------------------------------------------
-- Раскладка: полная (портрет + текст + кнопки) или компактная (только портрет, разворот по наведению)
---------------------------------------------------------------------------
local function Layout(expanded)
    if head.expanded == expanded then return end
    head.expanded = expanded
    for _, r in ipairs({ head.name, head.title, head.bar, head.time, head.queue, head.skip, head.close }) do
        r:SetShown(expanded)
    end
    head:SetWidth(expanded and FULL_W or COMPACT_W)
    if expanded then head:UpdateButtons() end
end

local function WantExpanded()
    return not CatQuestDB.headCompact or head.hovered
end

---------------------------------------------------------------------------
-- Создание
---------------------------------------------------------------------------
local function Create()
    local db = CatQuestDB
    head = CreateFrame("Frame", "CatQuestHead", UIParent, ns.Backdrop)
    head:SetSize(FULL_W, FULL_H)
    head:SetPoint(db.headPos.point, UIParent, db.headPos.point, db.headPos.x, db.headPos.y)
    head:SetScale(db.headScale or 1)
    head:SetFrameStrata("HIGH")
    head:SetClampedToScreen(true)
    head:SetMovable(true)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    head:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    head:SetScript("OnDragStart", function(self)
        if not db.headLocked then self:StartMoving() end
    end)
    head:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.headPos.point, db.headPos.x, db.headPos.y = point, x, y
    end)

    -- плавно: появление 0.25 с, исчезание 0.35 с (резкое мигание головы между квестами раздражало)
    head.fadeIn = head:CreateAnimationGroup()
    local a = head.fadeIn:CreateAnimation("Alpha"); a:SetDuration(0.25)
    head._absAlpha = ns.ApplyAlphaAnim(a, 0, 1)
    head.fadeOut = head:CreateAnimationGroup()
    local b = head.fadeOut:CreateAnimation("Alpha"); b:SetDuration(0.35)
    ns.ApplyAlphaAnim(b, 1, 0)
    head.fadeOut:SetScript("OnFinished", function() head.hiding = nil; head:Hide() end)

    -- портрет круглый (SetMask), рамка — тоже из масок: золотой круг 60 → тёмный круг 56 → портрет 54.
    -- Текстуры-кольца из UI (MiniMap-TrackingBorder и т. п.) занимают лишь часть своего квадрата и не совпадают по размеру
    -- с портретом (26.09.2026: кольцо вышло меньше портрета и съехало) — поэтому только маски.
    -- Круглая маска есть только на новых клиентах. На 3.3.5 портрет квадратный.
    local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
    head.ring = head:CreateTexture(nil, "BACKGROUND")
    head.ring:SetSize(60, 60)
    head.ring:SetPoint("LEFT", 9, 0)
    head.ring:SetColorTexture(0.85, 0.65, 0.13, 1)
    if head.ring.SetMask then head.ring:SetMask(MASK) end
    head.portraitBg = head:CreateTexture(nil, "BORDER")
    head.portraitBg:SetSize(56, 56)
    head.portraitBg:SetPoint("CENTER", head.ring, "CENTER", 0, 0)
    head.portraitBg:SetColorTexture(0.05, 0.05, 0.05, 1)
    if head.portraitBg.SetMask then head.portraitBg:SetMask(MASK) end
    head.portrait = head:CreateTexture(nil, "ARTWORK")
    head.portrait:SetSize(54, 54)
    head.portrait:SetPoint("CENTER", head.ring, "CENTER", 0, 0)
    if head.portrait.SetMask then head.portrait:SetMask(MASK) end

    head.name = head:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    head.name:SetPoint("TOPLEFT", 74, -10)
    head.name:SetPoint("RIGHT", -92, 0)
    head.name:SetJustifyH("LEFT")
    head.name:SetWordWrap(false)

    head.title = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    head.title:SetPoint("TOPLEFT", head.name, "BOTTOMLEFT", 0, -2)
    head.title:SetPoint("RIGHT", -92, 0)
    head.title:SetJustifyH("LEFT")
    head.title:SetWordWrap(false)

    head.bar = CreateFrame("StatusBar", nil, head)
    head.bar:SetSize(150, 6)
    head.bar:SetPoint("BOTTOMLEFT", 74, 11)
    head.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    head.bar:SetStatusBarColor(1, 0.7, 0.28)
    head.bar:SetMinMaxValues(0, 1)
    local bg = head.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.12)

    head.time = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    head.time:SetPoint("LEFT", head.bar, "RIGHT", 6, 0)

    -- «ещё N» — кнопка: наведение показывает, что в очереди; клик открывает вкладку «Очередь»
    head.queue = CreateFrame("Button", nil, head)
    head.queue:SetSize(60, 14)
    head.queue:SetPoint("LEFT", head.time, "RIGHT", 6, 0)
    head.queue.text = head.queue:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    head.queue.text:SetPoint("LEFT")
    head.queue:SetScript("OnClick", function() if ns.ToggleHistory then ns.ToggleHistory("queue") end end)
    head.queue:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("В очереди")
        for i, item in ipairs(ns.queue) do
            if i > 8 then GameTooltip:AddLine("…", 0.6, 0.6, 0.6); break end
            local m = item.meta or {}
            GameTooltip:AddLine(("%d. %s"):format(i, m.title or m.npc or KIND_LABEL[m.kind] or "текст"), 0.9, 0.9, 0.9, true)
        end
        GameTooltip:AddLine("Нажмите, чтобы открыть список.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    head.queue:SetScript("OnLeave", GameTooltip_Hide)

    -- кнопки-иконки в правом верхнем углу: ▶| дальше, × стоп и очистить; для лора — ▶ послушать и «Текст»
    head.close = CreateFrame("Button", nil, head, "UIPanelCloseButton")
    head.close:SetSize(24, 24)
    head.close:SetPoint("TOPRIGHT", -2, -2)
    head.close:SetScript("OnClick", ns.ClearQueue)
    head.close:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Стоп и очистить очередь")
        GameTooltip:Show()
    end)
    head.close:SetScript("OnLeave", GameTooltip_Hide)

    head.skip = CreateFrame("Button", nil, head, "UIPanelButtonTemplate")
    head.skip:SetSize(60, 18)
    head.skip:SetPoint("RIGHT", head.close, "LEFT", 0, 0)
    head.skip:SetText("Дальше")
    head.skip:SetScript("OnClick", ns.Skip)

    -- субтитры: подложка фиксированной высоты (две строки), чтобы текст не прыгал по экрану от фразы к фразе
    head.subBox = CreateFrame("Frame", nil, head, ns.Backdrop)
    head.subBox:SetSize(520, 44)
    head.subBox:SetPoint("TOP", head, "BOTTOM", 0, -4)
    head.subBox:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
    head.subBox:SetBackdropColor(0, 0, 0, 0.55)
    head.subtitle = head.subBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    head.subtitle:SetPoint("TOPLEFT", 10, -6)
    head.subtitle:SetPoint("BOTTOMRIGHT", -10, 6)
    head.subtitle:SetJustifyH("CENTER")
    head.subtitle:SetJustifyV("MIDDLE")
    head.subtitle:SetWordWrap(true)
    head.subtitle:SetShadowOffset(1, -1)

    -- подсказка по голове: полное имя и название (в шапке они обрезаются), источник, голос
    head:SetScript("OnEnter", function(self)
        self.hovered = true
        Layout(WantExpanded())
        local st = ns.state
        local meta = (st.playing and st.meta) or (st.pending and st.pending.meta) or nil
        if not meta then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(meta.npc or (meta.lore and "Рассказчик") or (meta.kind == "book" and "Текст" or "Рассказчик"))
        if meta.title then GameTooltip:AddLine(meta.title, 1, 0.82, 0, true) end
        local kind = meta.lore and "Лор места" or KIND_LABEL[meta.kind]
        if kind then GameTooltip:AddLine(kind, 0.7, 0.7, 0.7) end
        if st.playing and st.source then
            local v = st.voice and (", голос " .. st.voice) or ""  -- «·» нет в игровом шрифте — был квадратик (отчёт 30.09.2026)
            GameTooltip:AddLine((SOURCE_LABEL[st.source] or st.source) .. v, 0.6, 0.6, 0.6)
        end
        if #ns.queue > 0 then GameTooltip:AddLine(("в очереди: %d"):format(#ns.queue), 0.6, 0.6, 0.6) end
        GameTooltip:AddLine(db.headLocked and "Голова закреплена (настройки)." or "Тяните, чтобы передвинуть.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    head:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        self.hovered = false
        ns.After(0.8, function() if not head.hovered then Layout(WantExpanded()) end end)
    end)

    function head:UpdateButtons()
        self.queue:SetShown(#ns.queue > 0)
    end

    head.elapsedSince = 0
    head:SetScript("OnUpdate", function(self, elapsed)
        self.elapsedSince = self.elapsedSince + elapsed
        if self.elapsedSince < 0.1 then return end
        self.elapsedSince = 0
        local st = ns.state
        if st.playing and st.startedAt and st.duration then
            local t = GetTime() - st.startedAt
            self.bar:SetValue(math.min(1, t / math.max(st.duration, 0.1)))
            self.time:SetText(FormatTime(math.min(t, st.duration)) .. " / " .. FormatTime(st.duration))
            if db.subtitles then self.subtitle:SetText(CurrentSentence(t)) end
        end
    end)
    head.expanded = true
    head:Hide()
end

-- Тайминги предложений для внешних окон (читалка лора): { предложения }, { время начала }.
function ns.SentenceTiming(text, duration, cues)
    if cues and #cues > 0 and type(cues[1]) == "table" then
        local s, t = {}, {}
        for i, c in ipairs(cues) do t[i], s[i] = c[1], c[2] end
        return s, t
    end
    local s = SplitSentences(text)
    local t, total, pos = {}, 0, 0
    for _, x in ipairs(s) do total = total + strlenutf8(x) end
    for i, x in ipairs(s) do
        t[i] = (duration or 10) * pos / math.max(total, 1)
        pos = pos + strlenutf8(x) + 3
    end
    return s, t
end

function ns.UpdateHead()
    local db = CatQuestDB
    if not db.head then
        if head then HideHead() end
        return
    end
    if not head then Create() end
    local st = ns.state
    local n = #ns.queue
    if not st.playing and not st.pending and n == 0 then
        ns.After(1.5, function()
            local s = ns.state
            if not s.playing and not s.pending and #ns.queue == 0 then HideHead() end
        end)
        return
    end
    if st.playing or st.pending then
        -- pending — ждём приветствие NPC: портрет и название уже на месте, речь начнётся через секунду-две
        local meta = (st.playing and st.meta) or (st.pending and st.pending.meta) or {}
        head.name:SetText(meta.npc or (meta.kind == "book" and "Текст" or "Рассказчик"))
        local story = ns.StoryLine and meta.quest and ns.StoryLine(meta.quest)
        local title = meta.title or KIND_LABEL[meta.kind] or ""
        -- источник не из пака помечаем: иначе голова с молчащим компаньоном выглядит как «озвучка не запустилась» (26.09.2026)
        local src = ns.state and ns.state.source
        local srcLabel = src == "bridge" and "компаньон" or src == "tts" and "TTS" or nil
        local tail = story or srcLabel
        head.title:SetText(tail and (title ~= "" and (title .. "  |cff9d9d9d" .. tail .. "|r") or tail) or title)
        SetPortrait(head.portrait, meta)
        local subText = st.subtitleText or st.text or ""  -- /cq pack <id> без текста: не падать на SplitSentences(nil)
        if subText ~= head.lastText then
            head.lastText = subText
            BuildCues(subText, meta, st.duration or 10, st.cues)
        end
    end
    head.queue.text:SetText(n > 0 and ("ещё " .. n) or "")
    head.subBox:SetShown(db.subtitles and st.playing)
    if not st.playing then
        head.bar:SetValue(0)
        head.time:SetText(st.pending and "ждём NPC…" or "")
    end
    head:UpdateButtons()
    Layout(WantExpanded())
    ShowHead()
end

-- Настройка «компактная голова» переключилась — перестроить.
function ns.HeadRelayout()
    if head then head.expanded = nil; Layout(WantExpanded()) end
end
