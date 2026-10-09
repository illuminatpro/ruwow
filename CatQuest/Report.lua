-- Отчёт для автора пака: /cq export. Лёгкий сбор того, что нужно для починки и пополнения пака:
--   N — квест без озвучки в паке: кто выдаёт/принимает (ID, облик, файл модели, раса, пол) и текст (для генерации);
--   V — квест в паке читает рассказчик, а NPC известен (можно дать ему свой голос);
--   M — голос из пака не совпал с расой/полом NPC перед игроком;
--   B — книга/табличка без озвучки (текст страницы);
--   E — ошибки аддона.
-- Ничего не отправляется само: игрок открывает окно и копирует строку. Имя персонажа в текстах заменяется на $N.
-- Хранится в SavedVariables CatQuestReport (в бете Forever между сессиями не загружается — тогда отчёт за сессию).
local ADDON, ns = ...

--   T — текст на экране не совпал с текстом, по которому собран файл пака (аддон сверяет число букв): настоящий текст.
local VERSION = 2
local NARRATOR = "human-male#114"
local LIMIT = { N = 200, V = 300, M = 200, B = 60, E = 50, T = 100 }
local TEXT_MAX = 2500      -- символов текста на запись
local EXPORT_BUDGET = 150000 -- байт текстов в одном экспорте; дальше — только метаданные

local function AddonVersion()
    return (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
end

local purged
local function R()
    if type(CatQuestReport) ~= "table" or CatQuestReport.v ~= VERSION then
        CatQuestReport = { v = VERSION, N = {}, V = {}, M = {}, B = {}, E = {}, T = {} }
    end
    if not purged then
        -- ошибки прошлых версий аддона не выгружаем: B-23 (SetTexCoord) починена в 0.2.0, а в отчётах 27.09 всё ещё
        -- приходила — таблица E в сохранениях не чистилась (B-25)
        purged = true
        local cur = AddonVersion()
        for k, x in pairs(CatQuestReport.E) do
            if x.ver ~= cur then CatQuestReport.E[k] = nil end
        end
    end
    return CatQuestReport
end

local function Enabled()
    return CatQuestDB and CatQuestDB.report ~= false
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function Put(kind, key, rec)
    local t = R()[kind]
    if t[key] then
        t[key].n = (t[key].n or 1) + 1
        for k, v in pairs(rec) do if t[key][k] == nil then t[key][k] = v end end
        return
    end
    if Count(t) >= LIMIT[kind] then return end
    rec.n = 1
    t[key] = rec
end

-- Имя персонажа, подставленное игрой в текст, — обратно в $N (в отчёт не попадает).
local function Anonymize(text)
    if not text or text == "" then return nil end
    local me = UnitName("player")
    if me and me ~= "" then
        -- игра подставляет имя и как есть, и капсом («благодарят тебя, ПАЖИЛОЙ» — утекло в отчёт 26.09.2026)
        for _, v in ipairs({ me, me:upper(), me:lower() }) do
            text = text:gsub((v:gsub("%p", "%%%0")), "$N")
        end
    end
    -- токен склонения |3-N(слово): окно экспорта (EditBox) съедает «|3», и в отчёт уходит «-6(ночной эльф)» — отдаём слово
    text = text:gsub("|3%-%d%((.-)%)", "%1")
    text = text:gsub("\r", ""):gsub("^%s+", "")
    if #text > TEXT_MAX * 2 then -- байты; кириллица — 2 байта на букву; не резать символ UTF-8 пополам
        local cut = TEXT_MAX * 2
        while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 128 and text:byte(cut + 1) < 192 do cut = cut - 1 end
        text = text:sub(1, cut)
    end
    return text
end

local function MapID()
    if C_Map and C_Map.GetBestMapForUnit then
        return C_Map.GetBestMapForUnit("player") or 0
    end
    if ns.LegacyMapPos then
        local map = ns.LegacyMapPos()
        return map or 0
    end
    return 0
end

local function VoiceRaceSex(v)
    local race, sex = v:match("^([a-z]+)%-(female)")
    if race then return race, sex end
    race = v:match("^([a-z]+)%-male")
    if race then return race, "male" end
end

-- Окно квеста открыто у NPC (взятие или сдача). info — из ns.IdentifyNpc; raw — текст NPC без названия/задачи.
function ns.ReportOffer(info, raw)
    if not Enabled() or not info.quest or info.quest == 0 then return end
    local kind = info.kind
    if kind ~= "detail" and kind ~= "complete" then return end
    local pack = CatQuestVoicePack and CatQuestVoicePack.quests
    local entry = pack and pack[info.quest]
    if entry and kind == "complete" then entry = entry.t end
    if entry and entry.d == nil and kind == "detail" then entry = nil end -- запись только со сдачей
    local key = info.quest .. ":" .. kind
    local who = {
        q = info.quest, k = kind, id = info.npcID or 0, npc = info.npc or "", disp = info.display or 0, mdl = info.model or 0,
        race = info.race or "", sex = info.sexName or "",
    }
    if not entry then
        if not pack then return end -- пак не установлен — отчёт о «пропусках» бессмыслен
        who.map, who.title, who.text = MapID(), info.title or "", Anonymize(raw)
        Put("N", key, who)
        return
    end
    if not entry.v or not info.npcID then return end
    if entry.v == NARRATOR then
        Put("V", key, who)
        return
    end
    local vr, vs = VoiceRaceSex(entry.v)
    if vs and info.sexName and info.race and (vs ~= info.sexName or (vr ~= "human" and vr ~= info.race)) then
        who.v = entry.v
        Put("M", key, who)
    end
end

-- Страница книги/таблички/записки.
function ns.ReportBook(text, hash)
    if not Enabled() or not text or text == "" then return end
    local books = CatQuestVoicePack and CatQuestVoicePack.books
    if not books or books[hash] then return end
    local item = ItemTextGetItem and ItemTextGetItem() or ""
    Put("B", hash, { h = hash, item = item, map = MapID(), text = Anonymize(text) })
end

-- Файл пака собран по тексту из базы, а на экране другой текст (другая редакция локализации, правка Forever):
-- np/ng — букв в паке / на экране. Настоящий текст уходит в отчёт, следующая сборка берёт его (B-16).
function ns.ReportTextMismatch(meta, text, np, ng)
    if not Enabled() or not meta or not meta.quest then return end
    local kind = meta.kind == "detail" and "detail" or "complete"
    Put("T", meta.quest .. ":" .. kind, { q = meta.quest, k = kind, id = meta.npcID or 0, np = np, ng = ng,
        title = meta.title or "", text = Anonymize(text) })
end

function ns.ReportError(where, msg)
    if not Enabled() then return end
    Put("E", where .. ":" .. tostring(msg):sub(1, 120), { w = where, msg = tostring(msg):sub(1, 300), ver = AddonVersion() })
end

---------------------------------------------------------------------------
-- Строка экспорта: построчно, поля через «¦», переводы строк в тексте — \n.
---------------------------------------------------------------------------
local function Esc(s)
    s = tostring(s == nil and "" or s)
    return (s:gsub("\\", "/"):gsub("¦", "!"):gsub("\t", " "):gsub("\r", ""):gsub("\n", "\\n"):gsub("|n", "\\n"))
end

local function Line(parts)
    for i = 1, #parts do parts[i] = Esc(parts[i]) end
    return table.concat(parts, "¦") -- «¦», а не табуляция: мессенджеры табуляцию съедают
end

local function Sorted(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function ns.BuildExport()
    local r = R()
    local _, build = GetBuildInfo()
    local pack = CatQuestVoicePack
    local nq, nb = 0, 0
    if pack and pack.quests then nq = Count(pack.quests) end
    if pack and pack.books then nb = Count(pack.books) end
    local ver = AddonVersion()
    local out = { "CATQUEST-REPORT v" .. VERSION,
        Line({ "H", ver, build, GetLocale(), nq, nb, ns.CompanionInstalled() and 1 or 0, date("!%Y-%m-%d %H:%M") }) }
    local budget = EXPORT_BUDGET
    for _, k in ipairs(Sorted(r.N)) do
        local x = r.N[k]
        local text = x.text or ""
        if #text > budget then text = "" end
        budget = budget - #text
        out[#out + 1] = Line({ "N", x.q, x.k, x.id, x.npc, x.disp, x.mdl, x.race, x.sex, x.map, x.n, x.title, text })
    end
    for _, k in ipairs(Sorted(r.V)) do
        local x = r.V[k]
        out[#out + 1] = Line({ "V", x.q, x.k, x.id, x.npc, x.disp, x.mdl, x.race, x.sex, x.n })
    end
    for _, k in ipairs(Sorted(r.M)) do
        local x = r.M[k]
        out[#out + 1] = Line({ "M", x.q, x.k, x.v, x.id, x.npc, x.disp, x.mdl, x.race, x.sex, x.n })
    end
    for _, k in ipairs(Sorted(r.B)) do
        local x = r.B[k]
        local text = x.text or ""
        if #text > budget then text = "" end
        budget = budget - #text
        out[#out + 1] = Line({ "B", x.h, x.item, x.map, x.n, text })
    end
    for _, k in ipairs(Sorted(r.T or {})) do
        local x = r.T[k]
        local text = x.text or ""
        if #text > budget then text = "" end
        budget = budget - #text
        out[#out + 1] = Line({ "T", x.q, x.k, x.id, x.np, x.ng, x.title, text })
    end
    for _, k in ipairs(Sorted(r.E)) do
        local x = r.E[k]
        out[#out + 1] = Line({ "E", x.w, x.n, x.msg, x.ver })
    end
    out[#out + 1] = "END"
    return table.concat(out, "\n"), Count(r.N), Count(r.V), Count(r.M), Count(r.B), Count(r.E)
end

---------------------------------------------------------------------------
-- Окно экспорта
---------------------------------------------------------------------------
local frame

local function CreateExportFrame()
    frame = CreateFrame("Frame", "CatQuestExportFrame", UIParent, ns.Backdrop)
    frame:SetSize(560, 400)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    tinsert(UISpecialFrames, "CatQuestExportFrame") -- закрывается по Esc

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("CatQuest — отчёт для автора")

    frame.info = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.info:SetPoint("TOPLEFT", 18, -40)
    frame.info:SetPoint("RIGHT", -18, 0)
    frame.info:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local scroll = CreateFrame("ScrollFrame", "CatQuestExportScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -92)
    scroll:SetPoint("BOTTOMRIGHT", -36, 48)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", scroll, -4, 4)
    bg:SetPoint("BOTTOMRIGHT", scroll, 22, -4)
    bg:SetColorTexture(0, 0, 0, 0.5)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontSmall or ChatFontNormal)
    edit:SetWidth(490)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    -- текст только для копирования: любые правки откатываем
    edit:SetScript("OnTextChanged", function(self, user)
        if user and frame.text then self:SetText(frame.text); self:HighlightText() end
    end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit

    local select = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    select:SetSize(150, 22)
    select:SetPoint("BOTTOMLEFT", 16, 16)
    select:SetText("Выделить всё")
    select:SetScript("OnClick", function() edit:SetFocus(); edit:HighlightText() end)

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(150, 22)
    clear:SetPoint("BOTTOMRIGHT", -16, 16)
    clear:SetText("Очистить отчёт")
    clear:SetScript("OnClick", function()
        CatQuestReport = nil
        ns.ShowExport()
        ns.Print("отчёт очищен")
    end)
    clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Очистить отчёт", 1, 1, 1)
        GameTooltip:AddLine("Нажмите после того, как отправили отчёт, чтобы в следующий попало только новое.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    clear:SetScript("OnLeave", GameTooltip_Hide)
end

function ns.ShowExport()
    if not frame then CreateExportFrame() end
    local text, n, v, m, b, e = ns.BuildExport()
    frame.text = text
    frame.info:SetText(("Без озвучки: |cffffd100%d|r квестов, |cffffd100%d|r книг. Рассказчик вместо NPC: |cffffd100%d|r. "
        .. "Голос не по персонажу: |cffffd100%d|r. Ошибки: |cffffd100%d|r.\n"
        .. "Нажмите |cffffd100Ctrl+C|r и вставьте в Discord или Telegram (длинный текст станет файлом). "
        .. "Имя персонажа в отчёт не попадает."):format(n, b, v, m, e))
    frame.edit:SetText(text)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
    frame.edit:SetCursorPosition(0)
    frame.edit:HighlightText()
end
