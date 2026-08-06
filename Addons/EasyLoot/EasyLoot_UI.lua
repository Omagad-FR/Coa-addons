-- EasyLoot 0.5.3 - panneau
-- made by Omagad
-- Client WoW 3.3.5a / Interface 30300
--
-- Clic gauche  : selectionne la piece a annoncer
-- Clic droit   : verrouille / deverrouille (une piece verrouillee ne peut
--                pas etre annoncee)
-- Maj + clic   : insere le lien dans la barre de chat
--
-- Panneau du bas (session) : le champ "destinataire" se pre-remplit avec le
-- gagnant du jet mais reste modifiable -- le ML garde la main si le
-- gagnant ne vient pas recuperer sa piece ou si la decision change.
-- Cliquer directement sur une ligne de jet remplit aussi le champ (evite de
-- retaper un nom, sujet aux fautes de frappe et aux suffixes de royaume).
--   "Preparer l'echange"      : arme le placement automatique, voir
--                                EasyLoot.lua (core:PrepareTrade).
--   "Confirmer distribution"  : enregistre tout de suite dans l'historique
--                                (echange deja fait a la main, ou decision
--                                sans jet).

local core = EasyLoot

local FRAME_WIDTH = 430
local FRAME_HEIGHT = 620
local ROW_HEIGHT = 24
local VISIBLE_ROWS = 9
local MAX_ROLL_LINES = 5

local ui = {}
core.ui = ui

--------------------------------------------------------------------------
-- Cadre principal
--------------------------------------------------------------------------

local frame = CreateFrame("Frame", "EasyLootFrame", UIParent)
frame:SetWidth(FRAME_WIDTH)
frame:SetHeight(FRAME_HEIGHT)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    EasyLootDB.point = point
    EasyLootDB.relPoint = relPoint
    EasyLootDB.x = x
    EasyLootDB.y = y
end)
frame:SetClampedToScreen(true)
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -18)
title:SetText("EasyLoot - Loot de raid")

local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
subtitle:SetPoint("TOP", title, "BOTTOM", 0, -3)
subtitle:SetText("clic gauche : choisir - clic droit : verrouiller")

local credit = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
credit:SetPoint("BOTTOMRIGHT", -14, 8)
credit:SetText("made by Omagad")

-- L'avertissement raid demande le rang de chef ou d'assistant ; sans lui
-- l'annonce retombe sur le canal du raid, autant le dire avant le clic.
function ui.RefreshHeader()
    if (EasyLootDB.sendMode or "alerte") == "alerte" and not core:CanRaidWarn() then
        subtitle:SetText("|cffffd200Alerte plein ecran indisponible :"
            .. " ni chef de raid ni assistant|r")
    else
        subtitle:SetText("clic gauche : choisir - clic droit : verrouiller")
    end
end

local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 2, 2)

local historyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
historyButton:SetWidth(84)
historyButton:SetHeight(20)
historyButton:SetPoint("TOPRIGHT", -32, -6)
historyButton:SetText("Historique")

local scanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
scanButton:SetWidth(150)
scanButton:SetHeight(22)
scanButton:SetPoint("TOPLEFT", 20, -64)
scanButton:SetText("Scanner les sacs")

local countLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
countLabel:SetPoint("LEFT", scanButton, "RIGHT", 10, 0)
countLabel:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
countLabel:SetJustifyH("LEFT")
countLabel:SetText("Sacs non scannes.")

--------------------------------------------------------------------------
-- Liste des pieces
--------------------------------------------------------------------------

local listBackground = CreateFrame("Frame", nil, frame)
listBackground:SetPoint("TOPLEFT", 18, -92)
listBackground:SetWidth(FRAME_WIDTH - 36)
listBackground:SetHeight(VISIBLE_ROWS * ROW_HEIGHT + 8)
listBackground:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
listBackground:SetBackdropColor(0, 0, 0, 0.7)

local scroll = CreateFrame("ScrollFrame", "EasyLootScroll", listBackground, "FauxScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 4, -4)
scroll:SetPoint("BOTTOMRIGHT", -26, 4)

local rows = {}

local function SelectIndex(index)
    ui.selectedKey = core.items[index] and core.items[index].key or nil
    ui.selectedIndex = index
    ui.RefreshList()
end

local function RowOnClick(self, button)
    local item = self.item
    if not item then return end
    if button == "RightButton" then
        core:ToggleLock(item.key)
        return
    end
    if IsShiftKeyDown() then
        if ChatEdit_InsertLink then ChatEdit_InsertLink(item.link) end
        return
    end
    SelectIndex(self.index)
end

for line = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, listBackground)
    row:SetWidth(FRAME_WIDTH - 68)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 6, -4 - (line - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.highlight:SetBlendMode("ADD")
    row.highlight:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(18)
    row.icon:SetHeight(18)
    row.icon:SetPoint("LEFT", 2, 0)

    row.lock = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.lock:SetPoint("RIGHT", -4, 0)
    row.lock:SetWidth(80)
    row.lock:SetJustifyH("RIGHT")

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.label:SetPoint("RIGHT", row.lock, "LEFT", -4, 0)
    row.label:SetJustifyH("LEFT")

    row:SetScript("OnClick", RowOnClick)
    row:SetScript("OnEnter", function(self)
        if not self.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.item.link)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[line] = row
end

function ui.RefreshList()
    local items = core.items
    FauxScrollFrame_Update(scroll, #items, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    -- La selection suit la piece, pas sa position dans la liste.
    if ui.selectedKey then
        ui.selectedIndex = nil
        for index, item in ipairs(items) do
            if item.key == ui.selectedKey then
                ui.selectedIndex = index
                break
            end
        end
        if not ui.selectedIndex then ui.selectedKey = nil end
    end

    for line = 1, VISIBLE_ROWS do
        local row = rows[line]
        local index = offset + line
        local item = items[index]
        if item then
            local color = ITEM_QUALITY_COLORS[item.quality] or ITEM_QUALITY_COLORS[1]
            local locked = core:IsLocked(item.key)
            row.item = item
            row.index = index
            row.icon:SetTexture(item.texture)
            row.label:SetText(color.hex .. item.name .. "|r"
                .. (item.count and item.count > 1 and (" x" .. item.count) or ""))
            if locked then
                row.lock:SetText("|cffff8c8cverrouille|r")
                row.icon:SetVertexColor(0.4, 0.4, 0.4)
                row.label:SetAlpha(0.5)
            else
                -- "echangeable" est l'etat qui compte : lie sans fenetre
                -- d'echange veut dire qu'on ne peut plus le distribuer.
                if item.tradeable then
                    row.lock:SetText("|cff62d394echangeable|r")
                elseif item.soulbound then
                    row.lock:SetText("|cff999999lie|r")
                else
                    row.lock:SetText("")
                end
                row.icon:SetVertexColor(1, 1, 1)
                row.label:SetAlpha(1)
            end
            if index == ui.selectedIndex then
                row.highlight:Show()
            else
                row.highlight:Hide()
            end
            row:Show()
        else
            row.item = nil
            row.index = nil
            row:Hide()
        end
    end

    countLabel:SetText(#items .. " piece(s) equipables dans les sacs.")
end

scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, ui.RefreshList)
end)

-- Les lignes n'interceptent pas la molette : l'evenement retombe ici.
listBackground:EnableMouseWheel(true)
listBackground:SetScript("OnMouseWheel", function(self, delta)
    local maxOffset = math.max(0, #core.items - VISIBLE_ROWS)
    local offset = math.min(maxOffset, math.max(0, FauxScrollFrame_GetOffset(scroll) - delta))
    local bar = _G["EasyLootScrollScrollBar"]
    if bar then
        bar:SetValue(offset * ROW_HEIGHT)
    else
        FauxScrollFrame_SetOffset(scroll, offset)
        ui.RefreshList()
    end
end)

--------------------------------------------------------------------------
-- Historique des distributions (qui a REELLEMENT recu quoi)
--------------------------------------------------------------------------
-- Fenetre separee, ouverte/fermee independamment du panneau principal :
-- lecture seule, pas d'interaction ligne par ligne necessaire.

local historyFrame = CreateFrame("Frame", "EasyLootHistoryFrame", UIParent)
historyFrame:SetWidth(360)
historyFrame:SetHeight(400)
historyFrame:SetPoint("TOPLEFT", frame, "TOPRIGHT", 8, 0)
historyFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
historyFrame:SetMovable(true)
historyFrame:EnableMouse(true)
historyFrame:RegisterForDrag("LeftButton")
historyFrame:SetScript("OnDragStart", historyFrame.StartMoving)
historyFrame:SetScript("OnDragStop", historyFrame.StopMovingOrSizing)
historyFrame:SetClampedToScreen(true)
historyFrame:Hide()

local histTitle = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
histTitle:SetPoint("TOP", 0, -18)
histTitle:SetText("EasyLoot - Historique")

local histSubtitle = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
histSubtitle:SetPoint("TOP", histTitle, "BOTTOM", 0, -3)
histSubtitle:SetText("qui a reellement recu chaque piece, le plus recent en tete")

local histCloseButton = CreateFrame("Button", nil, historyFrame, "UIPanelCloseButton")
histCloseButton:SetPoint("TOPRIGHT", 2, 2)

-- Vider est manuel et confirme : rien ne detecte tout seul le debut d'une
-- nouvelle soiree de raid, c'est au ML de le decider.
StaticPopupDialogs["EASYLOOT_CLEAR_HISTORY"] = {
    text = "Vider tout l'historique EasyLoot ?\nLes badges +1/+2/+3 des jets seront remis a zero.",
    button1 = "Vider",
    button2 = "Annuler",
    OnAccept = function() core:ClearHistory() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local histClearButton = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
histClearButton:SetWidth(70)
histClearButton:SetHeight(20)
histClearButton:SetPoint("TOPRIGHT", -32, -6)
histClearButton:SetText("Vider")
histClearButton:SetScript("OnClick", function()
    StaticPopup_Show("EASYLOOT_CLEAR_HISTORY")
end)

local histScroll = CreateFrame("ScrollFrame", "EasyLootHistoryScroll", historyFrame, "UIPanelScrollFrameTemplate")
histScroll:SetPoint("TOPLEFT", 16, -56)
histScroll:SetPoint("BOTTOMRIGHT", -34, 16)

local histContent = CreateFrame("Frame", nil, histScroll)
histContent:SetWidth(300)
histContent:SetHeight(1)
histScroll:SetScrollChild(histContent)

local histText = histContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
histText:SetPoint("TOPLEFT", 0, 0)
histText:SetPoint("TOPRIGHT", 0, 0)
histText:SetJustifyH("LEFT")
histText:SetJustifyV("TOP")

function ui.RefreshHistory()
    local history = EasyLootDB.history or {}
    if #history == 0 then
        histText:SetText("|cff999999Aucune distribution enregistree.|r")
    else
        local lines = {}
        for _, entry in ipairs(history) do
            local color = ITEM_QUALITY_COLORS[entry.quality] or ITEM_QUALITY_COLORS[1]
            local methodLabel = (entry.method == "echange")
                and "|cff62d394echange|r" or "|cffffd200manuel|r"
            table.insert(lines, string.format("|cff999999%s|r  %s%s|r  ->  %s  (%s)",
                entry.time or "?", color.hex, entry.name or "?",
                entry.recipient or "?", methodLabel))
        end
        histText:SetText(table.concat(lines, "\n"))
    end
    histContent:SetHeight(math.max(histText:GetStringHeight(), 1))
end

historyButton:SetScript("OnClick", function()
    if historyFrame:IsShown() then
        historyFrame:Hide()
    else
        historyFrame:Show()
        ui.RefreshHistory()
    end
end)

--------------------------------------------------------------------------
-- Panneau de session
--------------------------------------------------------------------------

local sessionPanel = CreateFrame("Frame", nil, frame)
sessionPanel:SetPoint("TOPLEFT", listBackground, "BOTTOMLEFT", 0, -10)
sessionPanel:SetWidth(FRAME_WIDTH - 36)
sessionPanel:SetHeight(150)
sessionPanel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
sessionPanel:SetBackdropColor(0, 0, 0, 0.7)

local sessionItem = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sessionItem:SetPoint("TOPLEFT", 8, -8)
sessionItem:SetPoint("TOPRIGHT", -8, -8)
sessionItem:SetJustifyH("LEFT")

local sessionStatus = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sessionStatus:SetPoint("TOPLEFT", sessionItem, "BOTTOMLEFT", 0, -4)
sessionStatus:SetPoint("TOPRIGHT", sessionItem, "BOTTOMRIGHT", 0, -4)
sessionStatus:SetJustifyH("LEFT")

-- Declare tot pour que les closures des boutons de jet (ci-dessous) capturent
-- la bonne variable locale plutot que la globale nil du meme nom -- la
-- vraie EditBox est creee plus bas, pres du bouton "Confirmer distribution".
local recipientEditBox

-- Chaque ligne de jet est cliquable : evite de retaper le nom du gagnant
-- (fautes de frappe, royaume different...) dans le champ destinataire.
local rollLines = {}
local rollButtons = {}
for line = 1, MAX_ROLL_LINES do
    local button = CreateFrame("Button", nil, sessionPanel)
    button:SetHeight(14)
    button:SetWidth(FRAME_WIDTH - 56)
    if line == 1 then
        button:SetPoint("TOPLEFT", sessionStatus, "BOTTOMLEFT", 0, -6)
    else
        button:SetPoint("TOPLEFT", rollButtons[line - 1], "BOTTOMLEFT", 0, -2)
    end
    button:RegisterForClicks("LeftButtonUp")

    button.highlight = button:CreateTexture(nil, "BACKGROUND")
    button.highlight:SetAllPoints()
    button.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    button.highlight:SetBlendMode("ADD")
    button.highlight:Hide()

    local fontString = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fontString:SetAllPoints()
    fontString:SetJustifyH("LEFT")

    button:SetScript("OnClick", function(self)
        if not self.rollName then return end
        recipientEditBox:SetText(self.rollName)
        local item = core:CurrentItem()
        if item then ui.autoFillKey = item.key end
        ui.autoFillName = self.rollName
        ui.RefreshSession()
    end)
    button:SetScript("OnEnter", function(self)
        if self.rollName then self.highlight:Show() end
    end)
    button:SetScript("OnLeave", function(self)
        if self.rollName ~= recipientEditBox:GetText() then self.highlight:Hide() end
    end)

    rollLines[line] = fontString
    rollButtons[line] = button
end

local winnerLabel = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
winnerLabel:SetPoint("BOTTOMLEFT", 8, 8)
winnerLabel:SetPoint("BOTTOMRIGHT", -8, 8)
winnerLabel:SetJustifyH("LEFT")

-- Badge affiche a cote d'un jet : quel serait le Nieme loot du joueur (tout
-- l'historique confondu, donc plusieurs boss dans la meme soiree) s'il
-- gagne cette piece. /easyloot historique reset (ou bouton "Vider") remet
-- a zero entre deux soirees -- l'addon ne le fait jamais tout seul.
function ui.LootBadge(name)
    local ordinal = core:GetLootCount(name) + 1
    if ordinal <= 1 then
        return "|cff62d394+" .. ordinal .. "|r"
    elseif ordinal == 2 then
        return "|cffffd200+" .. ordinal .. "|r"
    else
        return "|cffff8c8c+" .. ordinal .. "|r"
    end
end

local lootLegend = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
lootLegend:SetPoint("BOTTOMLEFT", winnerLabel, "TOPLEFT", 0, 2)
lootLegend:SetPoint("BOTTOMRIGHT", winnerLabel, "TOPRIGHT", 0, 2)
lootLegend:SetJustifyH("LEFT")
lootLegend:SetText("|cff62d394+1|r jamais loot   |cffffd200+2|r deja 1 loot   |cffff8c8c+3|r 2 loots ou plus")

--------------------------------------------------------------------------
-- Boutons d'action
--------------------------------------------------------------------------

local announceButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
announceButton:SetWidth(185)
announceButton:SetHeight(24)
announceButton:SetPoint("BOTTOMLEFT", 20, 80)
announceButton:SetText("Annoncer en alerte raid")

local closeRollsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
closeRollsButton:SetWidth(185)
closeRollsButton:SetHeight(24)
closeRollsButton:SetPoint("BOTTOMRIGHT", -20, 80)
closeRollsButton:SetText("Cloturer les jets")

local winnerButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
winnerButton:SetWidth(185)
winnerButton:SetHeight(24)
winnerButton:SetPoint("BOTTOMLEFT", 20, 50)
winnerButton:SetText("Annoncer le gagnant")

local prepareTradeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
prepareTradeButton:SetWidth(185)
prepareTradeButton:SetHeight(24)
prepareTradeButton:SetPoint("BOTTOMRIGHT", -20, 50)
prepareTradeButton:SetText("Preparer l'echange")

-- Destinataire : pre-rempli avec le gagnant du jet, mais toujours
-- modifiable -- le ML garde la main si le gagnant ne vient pas ou si la
-- decision change.
local recipientLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
recipientLabel:SetPoint("BOTTOMLEFT", 22, 40)
recipientLabel:SetPoint("BOTTOMRIGHT", -20, 40)
recipientLabel:SetJustifyH("LEFT")
recipientLabel:SetText("Destinataire (nom exact) :")

local confirmButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
confirmButton:SetWidth(150)
confirmButton:SetHeight(24)
confirmButton:SetPoint("BOTTOMRIGHT", -20, 12)
confirmButton:SetText("Confirmer distribution")

recipientEditBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
recipientEditBox:SetAutoFocus(false)
recipientEditBox:SetHeight(20)
recipientEditBox:SetPoint("BOTTOMLEFT", 30, 15)
recipientEditBox:SetPoint("RIGHT", confirmButton, "LEFT", -10, 0)
recipientEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
recipientEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

scanButton:SetScript("OnClick", function()
    core:ScanAndReport()
end)

announceButton:SetScript("OnClick", function()
    local index = ui.selectedIndex
    if not index then
        core:Print("|cffff8c8cSelectionne d'abord une piece dans la liste.|r")
        return
    end
    local ok, reason = core:Announce(index)
    if not ok then
        core:Print("|cffff8c8c" .. tostring(reason) .. "|r")
    end
end)

closeRollsButton:SetScript("OnClick", function()
    core:CloseRolls()
end)

winnerButton:SetScript("OnClick", function()
    local ok, reason = core:AnnounceWinner()
    if not ok then
        core:Print("|cffff8c8c" .. tostring(reason) .. "|r")
    end
end)

prepareTradeButton:SetScript("OnClick", function()
    local ok, reason = core:PrepareTrade(recipientEditBox:GetText())
    if not ok then
        core:Print("|cffff8c8c" .. tostring(reason) .. "|r")
    end
end)

confirmButton:SetScript("OnClick", function()
    local ok, reason = core:AssignRecipient(recipientEditBox:GetText(), "manuel")
    if not ok then
        core:Print("|cffff8c8c" .. tostring(reason) .. "|r")
    end
end)

--------------------------------------------------------------------------
-- Rafraichissement du panneau de session
--------------------------------------------------------------------------

-- Pre-remplit le champ destinataire avec le gagnant du jet, sans ecraser
-- une modification que le ML aurait deja faite pour cette meme piece.
local function AutoFillRecipient(itemKey, name)
    if not name then return end
    if ui.autoFillKey == itemKey and recipientEditBox:GetText() ~= (ui.autoFillName or "") then
        -- le ML a change le texte lui-meme depuis le dernier auto-remplissage
        return
    end
    recipientEditBox:SetText(name)
    ui.autoFillKey = itemKey
    ui.autoFillName = name
end

function ui.RefreshSession()
    local session = core:GetSession()
    local item = session and session.item or core.pendingItem

    if not item then
        sessionItem:SetText("|cff999999Aucune annonce en cours.|r")
        sessionStatus:SetText("Choisis une piece, annonce-la, puis laisse le raid /roll.")
        for line, fontString in ipairs(rollLines) do
            fontString:SetText("")
            rollButtons[line].rollName = nil
            rollButtons[line].highlight:Hide()
        end
        winnerLabel:SetText("")
        recipientLabel:SetText("Destinataire (nom exact) :")
        closeRollsButton:Disable()
        winnerButton:Disable()
        prepareTradeButton:Disable()
        confirmButton:Disable()
        if not recipientEditBox:HasFocus() then
            recipientEditBox:SetText("")
        end
        ui.autoFillKey = nil
        return
    end

    local color = ITEM_QUALITY_COLORS[item.quality] or ITEM_QUALITY_COLORS[1]
    sessionItem:SetText(color.hex .. item.name .. "|r")

    if not session then
        -- Piece en attente d'echange, sans jet associe (assignation directe).
        sessionStatus:SetText("Aucun jet pour cette piece.")
        for line, fontString in ipairs(rollLines) do
            fontString:SetText("")
            rollButtons[line].rollName = nil
            rollButtons[line].highlight:Hide()
        end
        winnerLabel:SetText("")
        closeRollsButton:Disable()
        winnerButton:Disable()
    elseif session.open then
        local remaining = math.max(0, session.endTime - GetTime())
        sessionStatus:SetText(string.format(
            "Jets ouverts - %.0f s restantes - %d jet(s)",
            remaining, #session.rolls
        ))
        closeRollsButton:Enable()
    else
        sessionStatus:SetText("Jets clos - " .. #session.rolls .. " jet(s) enregistre(s)")
        closeRollsButton:Disable()
    end

    if session then
        local currentRecipient = recipientEditBox:GetText()
        for line = 1, MAX_ROLL_LINES do
            local roll = session.rolls[line]
            local button = rollButtons[line]
            if roll then
                rollLines[line]:SetText(string.format(
                    "%d. %s %s : |cffffd200%d|r |cff999999(%d-%d, %s)|r",
                    line, roll.name, ui.LootBadge(roll.name), roll.value, roll.min, roll.max, roll.source
                ))
                button.rollName = roll.name
                if roll.name == currentRecipient then
                    button.highlight:Show()
                else
                    button.highlight:Hide()
                end
            else
                rollLines[line]:SetText("")
                button.rollName = nil
                button.highlight:Hide()
            end
        end
        if #session.rolls > MAX_ROLL_LINES then
            rollLines[MAX_ROLL_LINES]:SetText(rollLines[MAX_ROLL_LINES]:GetText()
                .. "  |cff999999+" .. (#session.rolls - MAX_ROLL_LINES) .. " autre(s)|r")
        end
    end

    local winner, tied
    if session then winner, tied = core:GetWinner() end
    if not winner then
        if session then winnerLabel:SetText("|cff999999En attente de jets.|r") end
        winnerButton:Disable()
    elseif tied and #tied > 1 then
        local names = {}
        for _, roll in ipairs(tied) do table.insert(names, roll.name) end
        winnerLabel:SetText("|cffffd200Egalite a " .. winner.value .. " : "
            .. table.concat(names, ", ") .. "|r")
        winnerButton:Enable()
    else
        winnerLabel:SetText("|cff62d394Gagnant : " .. winner.name
            .. " (" .. winner.value .. ")|r  " .. ui.LootBadge(winner.name))
        winnerButton:Enable()
        AutoFillRecipient(item.key, winner.name)
    end

    if core.pendingItem and core.pendingItem.key == item.key and core.pendingRecipient then
        recipientLabel:SetText("|cffffd200En attente de l'echange avec "
            .. core.pendingRecipient .. "...|r")
    else
        recipientLabel:SetText("Destinataire (nom exact) :")
    end

    prepareTradeButton:Enable()
    confirmButton:Enable()
end

--------------------------------------------------------------------------
-- Branchements
--------------------------------------------------------------------------

core:On("ITEMS_CHANGED", function() ui.RefreshList() end)
core:On("SESSION_CHANGED", function() ui.RefreshSession() end)
core:On("ROLLS_CHANGED", function() ui.RefreshSession() end)
core:On("HISTORY_CHANGED", function()
    if historyFrame:IsShown() then ui.RefreshHistory() end
    ui.RefreshSession()
end)

core:On("DB_READY", function()
    if EasyLootDB.point then
        frame:ClearAllPoints()
        frame:SetPoint(
            EasyLootDB.point,
            UIParent,
            EasyLootDB.relPoint or EasyLootDB.point,
            EasyLootDB.x or 0,
            EasyLootDB.y or 0
        )
    end
end)

core:On("TOGGLE_UI", function()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end)

--------------------------------------------------------------------------
-- Icone minimap
--------------------------------------------------------------------------
-- Pas de librairie externe (LibDBIcon...) embarquee : implementation
-- minimale maison, angle stocke en degres dans EasyLootDB.minimapAngle.

local minimapButton = CreateFrame("Button", "EasyLootMinimapButton", Minimap)
minimapButton:SetWidth(31)
minimapButton:SetHeight(31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton:RegisterForClicks("LeftButtonUp")
minimapButton:RegisterForDrag("LeftButton")

local minimapIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
minimapIcon:SetWidth(20)
minimapIcon:SetHeight(20)
minimapIcon:SetPoint("TOPLEFT", 7, -5)
minimapIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")

local minimapBorder = minimapButton:CreateTexture(nil, "OVERLAY")
minimapBorder:SetWidth(53)
minimapBorder:SetHeight(53)
minimapBorder:SetPoint("TOPLEFT")
minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function UpdateMinimapPosition()
    local angle = math.rad(EasyLootDB.minimapAngle or 215)
    local radius = 80
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local function UpdateMinimapVisibility()
    if EasyLootDB.minimapHide then
        minimapButton:Hide()
    else
        minimapButton:Show()
    end
end

local function OnDragUpdate(self)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    EasyLootDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
    UpdateMinimapPosition()
end

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", OnDragUpdate)
end)
minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

minimapButton:SetScript("OnClick", function()
    core:Fire("TOGGLE_UI")
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("EasyLoot")
    GameTooltip:AddLine("Clic gauche : ouvre / ferme le panneau", 1, 1, 1)
    GameTooltip:AddLine("Glisser : deplace l'icone", 1, 1, 1)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

core:On("DB_READY", function()
    UpdateMinimapPosition()
    UpdateMinimapVisibility()
end)
core:On("MINIMAP_CHANGED", UpdateMinimapVisibility)

frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("PARTY_LEADER_CHANGED")
frame:SetScript("OnEvent", function()
    ui.RefreshHeader()
end)

frame:SetScript("OnShow", function()
    if #core.items == 0 then
        core:Scan()
    else
        ui.RefreshList()
    end
    ui.RefreshHeader()
    ui.RefreshSession()
end)

-- Le compte a rebours a besoin d'un rafraichissement continu ; le reste du
-- panneau ne bouge que sur evenement.
local elapsedSinceRefresh = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedSinceRefresh = elapsedSinceRefresh + elapsed
    if elapsedSinceRefresh < 0.25 then return end
    elapsedSinceRefresh = 0
    local session = core:GetSession()
    if session and session.open then
        ui.RefreshSession()
    end
end)
