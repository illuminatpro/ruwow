-- Лор мест: аудиогид. Раз в секунду проверяем позицию игрока; рядом с точкой интереса показываем свиток (перетаскиваемый),
-- тап по свитку — рассказчик читает историю в говорящей голове с субтитрами, через общую очередь: квест, взятый во время
-- рассказа, встанет следом, и наоборот. Голос — рассказчик из пака (по хэшу текста, как книги) или компаньон.
-- (26.09.2026: отдельное окно-читалка и кнопки «Послушать/Текст» на голове убраны — три копии одного текста на экране.)
-- (27.09.2026: опция «читать при входе» — рассказ начинается сам, когда игрок впервые попадает в место с лором; что уже
-- услышано, помнится в сохранениях (CatQuestDB.loreHeard) на всех персонажах, повторно само не играет. /cq lore reset — забыть.)
local ADDON, ns = ...

local POLL = 1.0
local button
local nearby

-- Ключ точки для памяти «услышано»: у точек по имени — «Зона» или «Зона/Подзона», у точек по координатам — карта и заголовок.
local function KeyOf(p)
    if p.key then return p.key end
    p.key = ("%d:%s"):format(p.map or 0, p.title or "")
    return p.key
end

local function Heard(p)
    local h = CatQuestDB and CatQuestDB.loreHeard
    return h and p and h[KeyOf(p)] or false
end

local function PlayerPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return nil end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    return map, pos.x * 100, pos.y * 100
end

-- Точки по имени зоны/подзоны (LoreZones.lua): игра сама говорит, куда вошёл игрок, координаты не нужны.
-- Объекты записей создаются один раз на имя, чтобы «услышано» помнилось в рамках сессии.
local byName = {}
local function NamedPoint(zone, sub)
    local zt = ns.LoreZones and ns.LoreZones[zone]
    if not zt then return nil end
    local key, text, title
    if sub and sub ~= "" and zt[sub] then
        key, text, title = zone .. "/" .. sub, zt[sub], sub
    elseif zt._zone then
        key, text, title = zone, zt._zone, zone
    else
        return nil
    end
    if not byName[key] then byName[key] = { key = key, title = title, text = text, named = true } end
    return byName[key]
end

local function Nearest()
    local map, x, y = PlayerPos()
    if map then
        local best, bestD
        for _, p in ipairs(ns.LoreData) do
            if p.map == map then
                local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
                if d <= (p.r or 4) and (not bestD or d < bestD) then best, bestD = p, d end
            end
        end
        if best then return best, bestD end
    end
    -- приоритет: объект по координатам → подзона → зона
    return NamedPoint(GetRealZoneText and GetRealZoneText() or GetZoneText(), GetSubZoneText and GetSubZoneText() or "")
end

-- Рассказ в говорящей голове через очередь (как квесты и книги).
function ns.LoreSpeak(p)
    if not p then return end
    CatQuestDB.loreHeard = CatQuestDB.loreHeard or {}
    CatQuestDB.loreHeard[KeyOf(p)] = true
    if button then button.pulse:Stop(); button.glow:Hide() end
    local meta = { kind = "book", title = p.title, npc = "Рассказчик", lore = p }
    if ns.Enqueue then ns.Enqueue(p.text, meta) elseif ns.Speak then ns.Speak(p.text, meta) end
end

-- Клавиша «рассказчик для местности» (просьба игрока 30.09.2026): то же, что нажать на свиток, — ближайшее место.
function CatQuest_Lore()
    local p = Nearest()
    if p then ns.LoreSpeak(p) elseif ns.Print then ns.Print("здесь нет рассказа о месте") end
end

---------------------------------------------------------------------------
-- Свиток (кнопка)
---------------------------------------------------------------------------
local function CreateButton()
    local b = CreateFrame("Button", "CatQuestLoreButton", UIParent)
    b:SetSize(44, 44)
    local pos = CatQuestDB.lorePos or { point = "TOP", x = 0, y = -140 }
    b:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
    b:SetMovable(true)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", b.StartMoving)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        CatQuestDB.lorePos = { point = point, x = x, y = y }
    end)
    b:SetNormalTexture("Interface\\ICONS\\INV_Scroll_03")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.glow = b:CreateTexture(nil, "BACKGROUND")
    b.glow:SetPoint("CENTER")
    b.glow:SetSize(70, 70)
    b.glow:SetTexture("Interface\\Cooldown\\star4")
    b.glow:SetBlendMode("ADD")
    b.glow:SetAlpha(0.6)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("TOP", b, "BOTTOM", 0, -2)
    -- Появление новой точки: свиток «выплывает» (масштаб 0.6→1 с отскоком, прозрачность 0→1), свечение мягко пульсирует,
    -- пока не послушал. Заметно, но без крика.
    b.appear = b:CreateAnimationGroup()
    local a1 = b.appear:CreateAnimation("Alpha"); a1:SetFromAlpha(0); a1:SetToAlpha(1); a1:SetDuration(0.35); a1:SetOrder(1)
    local s1 = b.appear:CreateAnimation("Scale"); s1:SetScaleFrom(0.6, 0.6); s1:SetScaleTo(1.12, 1.12); s1:SetDuration(0.3); s1:SetOrder(1); s1:SetSmoothing("OUT")
    local s2 = b.appear:CreateAnimation("Scale"); s2:SetScaleFrom(1.12, 1.12); s2:SetScaleTo(1, 1); s2:SetDuration(0.2); s2:SetOrder(2); s2:SetSmoothing("IN_OUT")
    b.pulse = b.glow:CreateAnimationGroup()
    b.pulse:SetLooping("BOUNCE")
    local p1 = b.pulse:CreateAnimation("Alpha"); p1:SetFromAlpha(0.15); p1:SetToAlpha(0.6); p1:SetDuration(1.4); p1:SetSmoothing("IN_OUT")
    b:SetScript("OnClick", function() ns.LoreSpeak(nearby) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(nearby and nearby.title or "")
        GameTooltip:AddLine("История этого места. Нажмите — рассказчик прочитает; тяните, чтобы передвинуть.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:Hide()
    return b
end

local function Tick()
    if not CatQuestDB then return end  -- до ADDON_LOADED сохранений ещё нет
    if CatQuestDB.lore == false then if button then button:Hide() end; return end
    -- На такси (грифон/виверна) зоны сменяются каждые секунды: свиток не показываем и сами не читаем — иначе рассказчик
    -- подряд озвучивает лор мест, где игрок ещё не был (хотфикс 0.3.1). После приземления точка найдётся на следующем тике.
    local p = (UnitOnTaxi and UnitOnTaxi("player")) and nil or Nearest()
    if p ~= nearby then
        nearby = p
        if not button then button = CreateButton() end
        if p then
            button.label:SetText(p.title)
            button:Show()
            if Heard(p) then
                button.pulse:Stop()
                button.glow:Hide()
            else
                button.glow:Show()
                button.appear:Stop()
                button.appear:Play()
                button.pulse:Play()
            end
        else
            button.pulse:Stop()
            button:Hide()
        end
    end
    -- Автозапуск: впервые вошли в место с лором — рассказчик начинает сам (через общую очередь). В бою ждём его конца:
    -- точка остаётся «рядом» и не отмечена услышанной, так что рассказ начнётся на следующем тике после боя.
    if p and CatQuestDB.loreAuto and not Heard(p) and not (UnitAffectingCombat and UnitAffectingCombat("player")) then
        ns.LoreSpeak(p)
    end
end

C_Timer.NewTicker(POLL, function()
    local ok, e = pcall(Tick)  -- раз в секунду: ошибка не должна сыпаться в чат каждую секунду
    if not ok and ns.LogError then ns.LogError("Lore.Tick", e) end
end)

-- /cq lore — точки на этой карте; /cq lore here — координаты для новой точки
function ns.LoreCommand(arg, print)
    local map, x, y = PlayerPos()
    if arg == "reset" then
        local n = 0
        for _ in pairs(CatQuestDB.loreHeard or {}) do n = n + 1 end
        CatQuestDB.loreHeard = {}
        nearby = nil  -- следующий тик покажет свиток заново, с автозапуском, если он включён
        print(("память лора очищена: %d мест снова считаются непосещёнными"):format(n))
        return
    end
    if arg == "here" then
        if map then print(("{ map = %d, x = %.1f, y = %.1f, r = 4, title = \"…\", text = \"…\" },"):format(map, x, y))
        else print("позиция неизвестна") end
        return
    end
    local zone, sub = GetRealZoneText and GetRealZoneText() or GetZoneText(), GetSubZoneText and GetSubZoneText() or ""
    local zt = ns.LoreZones and ns.LoreZones[zone]
    print(("зона «%s», подзона «%s»: %s"):format(zone, sub, zt and ((sub ~= "" and zt[sub]) and "текст подзоны есть" or (zt._zone and "текст зоны есть" or "текстов нет")) or "зона не описана"))
    if not map then print("позиция неизвестна"); return end
    local n = 0
    for _, p in ipairs(ns.LoreData) do
        if p.map == map then
            n = n + 1
            local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
            print(("  %s%s|r — %.0f%% карты%s"):format(Heard(p) and "|cff8a8a8a" or "", p.title, d, d <= (p.r or 4) and " (рядом)" or ""))
        end
    end
    if n == 0 then print("на этой карте точек лора пока нет; /cq lore here — снять координаты") end
end
