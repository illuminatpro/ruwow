-- Окно "CatQuest": вкладки "Мои квесты" (журнал), "Очередь" (что ждёт озвучки) и "История" (всё, что уже звучало).
local ADDON, ns = ...

local ROWS, ROW_H = 14, 24
local KIND_LABEL = {
    detail = "взятие", progress = "в процессе", complete = "сдача", greeting = "приветствие",
    gossip = "диалог", book = "книга", log = "журнал",
}

local win
local tab = "quests"
local offset = 0
local items = {}

local function QuestItems()
    local list = {}
    local header
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return list end
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and info.isHeader then
            header = info.title
        elseif info and not info.isHidden and info.questID then
            local saved = CatQuestDB.quests[info.questID]
            -- квест без записи в паке — серым: его прочитает только компаньон/встроенный TTS
            local pack = CatQuestVoicePack and CatQuestVoicePack.quests and CatQuestVoicePack.quests[info.questID]
            local voiced = pack and pack.d ~= nil
            list[#list + 1] = {
                label = info.title,
                sub = (header or "") .. (voiced and "  – озвучен" or (saved and saved.detail) and "  – голос NPC" or "  – без озвучки"),  -- «·» нет в шрифте
                gray = not voiced,
                play = function() ns.ReadQuest(info.questID) end,
            }
        end
    end
    return list
end

local function HistoryItems()
    local list = {}
    for _, h in ipairs(CatQuestDB.history) do
        local label = h.title or h.npc or strsub(h.text, 1, 60)
        list[#list + 1] = {
            label = label,
            sub = ("%s  %s  %s"):format(KIND_LABEL[h.kind] or h.kind or "", h.npc or "", h.time and date("%d.%m %H:%M", h.time) or ""),
            play = function() ns.Speak(h.text, ns.FillSpeaker and ns.FillSpeaker(ns.CopyMeta(h)) or ns.CopyMeta(h)) end,
        }
    end
    return list
end

local function QueueItems()
    local list = {}
    local st = ns.state
    if st.playing or st.pending then
        local m = (st.playing and st.meta) or st.pending.meta or {}
        list[#list + 1] = {
            label = m.title or m.npc or strsub(st.text or "", 1, 60),
            sub = (st.playing and "|cff80ff80сейчас|r  " or "|cffffd100ждём NPC|r  ") .. (KIND_LABEL[m.kind] or m.kind or "") .. "  " .. (m.npc or ""),
            play = function() if ns.Skip then ns.Skip() end end,
        }
    end
    for i, item in ipairs(ns.queue) do
        local m = item.meta or {}
        list[#list + 1] = {
            label = m.title or m.npc or strsub(item.text or "", 1, 60),
            sub = ("%d.  %s  %s"):format(i, KIND_LABEL[m.kind] or m.kind or "", m.npc or ""),
            play = function() ns.PlayQueued(i) end,
            remove = function() ns.RemoveQueued(i) end,
        }
    end
    return list
end

local function Refresh()
    if not win or not win:IsShown() then return end
    items = (tab == "quests") and QuestItems() or (tab == "queue") and QueueItems() or HistoryItems()
    offset = math.max(0, math.min(offset, #items - ROWS))
    for i, row in ipairs(win.rows) do
        local item = items[i + offset]
        row.item = item
        if item then row:Show() else row:Hide() end
        if item then
            row.label:SetText(item.label)
            row.sub:SetText(item.sub)
            if item.gray then row.label:SetTextColor(0.55, 0.55, 0.55) else row.label:SetTextColor(1, 0.82, 0) end
        end
    end
    win.empty:SetText(tab == "queue" and "Очередь пуста" or "Пока пусто")
    if #items == 0 then win.empty:Show() else win.empty:Hide() end
    win.tabQuests:SetEnabled(tab ~= "quests")
    win.tabQueue:SetEnabled(tab ~= "queue")
    win.tabHistory:SetEnabled(tab ~= "history")
    win.hint:SetText(tab == "queue" and "Клик — прочитать сейчас, правый клик — убрать из очереди" or "Клик — прочитать")
end
ns.OnHistoryChanged = Refresh
ns.OnQueueChanged = function() if tab == "queue" then Refresh() end end

local function CreateWindow()
    -- BasicFrameTemplateWithInset есть только на новых клиентах. Рамка собирается вручную.
    win = CreateFrame("Frame", "CatQuestWindow", UIParent, ns.Backdrop)
    win:SetSize(380, 124 + ROWS * ROW_H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.SetBackdrop then
        win:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        win:SetBackdropColor(0, 0, 0, 1)
    end
    tinsert(UISpecialFrames, "CatQuestWindow") -- закрывается по Esc

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local title = win.TitleText or win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetText("CatQuest")
    if not win.TitleText then title:SetPoint("TOP", 0, -14) end

    win.tabQuests = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.tabQuests:SetSize(96, 22)
    win.tabQuests:SetPoint("TOPLEFT", 16, -40)
    win.tabQuests:SetText("Мои квесты")
    win.tabQuests:SetScript("OnClick", function() tab, offset = "quests", 0; Refresh() end)

    win.tabQueue = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.tabQueue:SetSize(80, 22)
    win.tabQueue:SetPoint("LEFT", win.tabQuests, "RIGHT", 4, 0)
    win.tabQueue:SetText("Очередь")
    win.tabQueue:SetScript("OnClick", function() tab, offset = "queue", 0; Refresh() end)

    win.tabHistory = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.tabHistory:SetSize(80, 22)
    win.tabHistory:SetPoint("LEFT", win.tabQueue, "RIGHT", 4, 0)
    win.tabHistory:SetText("История")
    win.tabHistory:SetScript("OnClick", function() tab, offset = "history", 0; Refresh() end)

    local stop = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    stop:SetSize(80, 22)
    stop:SetPoint("TOPRIGHT", -12, -30)
    stop:SetText("Стоп")
    stop:SetScript("OnClick", function() SlashCmdList.CATQUEST("stop") end)

    win.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, win)
        row:SetSize(352, ROW_H)
        row:SetPoint("TOPLEFT", 16, -68 - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.label:SetPoint("TOPLEFT", 4, -1)
        row.label:SetPoint("RIGHT", -4, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("BOTTOMLEFT", 4, 1)
        row.sub:SetPoint("RIGHT", -4, 0)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, btn)
            if not self.item then return end
            if btn == "RightButton" then
                if self.item.remove then self.item.remove() end
            else
                self.item.play()
            end
        end)
        win.rows[i] = row
    end

    win.empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    win.empty:SetPoint("CENTER", 0, -10)
    win.empty:SetText("Пока пусто")
    win.hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.hint:SetPoint("BOTTOM", 0, 8)

    win:EnableMouseWheel(true)
    win:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * 3
        Refresh()
    end)
    win:SetScript("OnShow", Refresh)
    win:RegisterEvent("QUEST_LOG_UPDATE")
    win:SetScript("OnEvent", Refresh)
end

function ns.ToggleHistory(which)
    if not win then CreateWindow() end
    if win:IsShown() and (not which or which == tab) then
        win:Hide()
        return
    end
    tab = which or tab
    offset = 0
    win:Show()
    Refresh()
end

function CatQuest_ToggleWindow()
    ns.ToggleHistory()
end
