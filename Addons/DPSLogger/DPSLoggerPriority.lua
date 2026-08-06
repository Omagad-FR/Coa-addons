-- DPSLoggerPriority 1.0
-- Permet au joueur de classer ses sorts connus par ordre de priorite,
-- separement en mono-cible et en zone (AoE). Le classement est enregistre
-- dans DPSLoggerPriorityDB pour import ulterieur par CoA Data Manager ;
-- ce module ne touche jamais aux sessions de combat de DPSLogger.lua.
--
-- Reordonnancement par boutons Monter/Descendre plutot que glisser-deposer
-- pixel a pixel : plus simple et fiable avec l'API WoW 3.3.5, meme resultat
-- pour classer du plus important au moins important.

DPSLoggerPriorityDB = DPSLoggerPriorityDB or {}

local ROWS_VISIBLE = 10
local ROW_HEIGHT = 18

local function CharacterKey()
    local name = UnitName("player") or "Inconnu"
    local realm = GetRealmName() or "Royaume"
    return name .. "-" .. realm
end

local function ScanSpellbook()
    local spells = {}
    local seen = {}
    local numTabs = GetNumSpellTabs()
    for tab = 1, numTabs do
        local _, _, offset, numSpells = GetSpellTabInfo(tab)
        offset = offset or 0
        numSpells = numSpells or 0
        for i = offset + 1, offset + numSpells do
            local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
            local spellType = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
            if name and spellType ~= "PASSIVE" and spellType ~= "FUTURESPELL" and not seen[name] then
                seen[name] = true
                spells[#spells + 1] = name
            end
        end
    end
    table.sort(spells)
    return spells
end

local function NormalizeList(list)
    -- Compatibilite avec un ancien format (simple liste de noms) : chaque
    -- entree devient {name, note} pour porter le commentaire de priorite.
    for i, entry in ipairs(list) do
        if type(entry) == "string" then
            list[i] = { name = entry, note = "" }
        end
    end
end

local characterKey = CharacterKey()
DPSLoggerPriorityDB[characterKey] = DPSLoggerPriorityDB[characterKey] or {}
local saved = DPSLoggerPriorityDB[characterKey]
saved.class = select(2, UnitClass("player"))
saved.mono = saved.mono or {}
saved.aoe = saved.aoe or {}
NormalizeList(saved.mono)
NormalizeList(saved.aoe)

local allSpells = {}
local mode = "mono"

local function RankedList()
    return saved[mode]
end

local function AvailableList()
    local rankedSet = {}
    for _, entry in ipairs(RankedList()) do rankedSet[entry.name] = true end
    local available = {}
    for _, name in ipairs(allSpells) do
        if not rankedSet[name] then available[#available + 1] = name end
    end
    return available
end

local frame = CreateFrame("Frame", "DPSLoggerPriorityFrame", UIParent)
frame:SetSize(700, 380)
frame:SetPoint("CENTER", 0, 40)
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
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetClampedToScreen(true)
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -18)
title:SetText("CoA - Priorites de rotation")

local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
subtitle:SetText("Classe les sorts du plus important au moins important, separement en mono et en zone.")

local modeMonoButton = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
modeMonoButton:SetPoint("TOPLEFT", 30, -70)
local modeMonoLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
modeMonoLabel:SetPoint("LEFT", modeMonoButton, "RIGHT", 4, 0)
modeMonoLabel:SetText("Mono-cible")

local modeAoeButton = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
modeAoeButton:SetPoint("LEFT", modeMonoLabel, "RIGHT", 24, 0)
local modeAoeLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
modeAoeLabel:SetPoint("LEFT", modeAoeButton, "RIGHT", 4, 0)
modeAoeLabel:SetText("Zone (AoE)")

local availableCaption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
availableCaption:SetPoint("TOPLEFT", 30, -100)
availableCaption:SetText("Sorts disponibles (clic pour ajouter)")

local rankedCaption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rankedCaption:SetPoint("TOPLEFT", 300, -100)
rankedCaption:SetText("Ordre de priorite (haut = plus important)")

local noteCaption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
noteCaption:SetPoint("LEFT", rankedCaption, "RIGHT", 116, 0)
noteCaption:SetText("Pourquoi (1 ligne)")

local NAME_COLUMN_WIDTH = 110

local function CreateScrollList(x, y, width, withNote)
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", x, y)
    scrollFrame:SetSize(width, ROWS_VISIBLE * ROW_HEIGHT)
    scrollFrame.rows = {}
    for i = 1, ROWS_VISIBLE do
        local row = CreateFrame("Button", nil, scrollFrame)
        row:SetSize(width, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 2, 0)
        row.text:SetJustifyH("LEFT")
        if withNote then
            row.text:SetWidth(NAME_COLUMN_WIDTH - 4)

            local noteBox = CreateFrame("EditBox", nil, row)
            noteBox:SetAutoFocus(false)
            noteBox:SetFontObject("GameFontHighlightSmall")
            noteBox:SetHeight(ROW_HEIGHT - 2)
            noteBox:SetPoint("LEFT", row.text, "RIGHT", 4, 0)
            noteBox:SetPoint("RIGHT", -2, 0)
            noteBox:SetMaxLetters(80)
            noteBox:SetTextInsets(4, 4, 0, 0)
            local bg = noteBox:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture(0, 0, 0, 0.35)
            noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            noteBox:SetScript("OnEditFocusLost", function(self)
                local entry = RankedList()[self.rankedIndex]
                if entry then entry.note = self:GetText() end
            end)
            row.noteBox = noteBox
        else
            row.text:SetPoint("RIGHT", -2, 0)
        end
        scrollFrame.rows[i] = row
    end
    return scrollFrame
end

local availableScroll = CreateScrollList(30, -118, 250, false)
local rankedScroll = CreateScrollList(300, -118, 360, true)

local upButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
upButton:SetSize(24, 24)
upButton:SetPoint("LEFT", rankedScroll, "RIGHT", 6, ROW_HEIGHT)
upButton:SetText("^")

local downButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
downButton:SetSize(24, 24)
downButton:SetPoint("TOP", upButton, "BOTTOM", 0, -4)
downButton:SetText("v")

local removeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
removeButton:SetSize(24, 24)
removeButton:SetPoint("TOP", downButton, "BOTTOM", 0, -4)
removeButton:SetText("x")

local selectedRankedIndex = nil

local function RefreshLists()
    local available = AvailableList()
    FauxScrollFrame_Update(availableScroll, #available, ROWS_VISIBLE, ROW_HEIGHT)
    local availableOffset = FauxScrollFrame_GetOffset(availableScroll)
    for i = 1, ROWS_VISIBLE do
        local row = availableScroll.rows[i]
        local index = i + availableOffset
        local name = available[index]
        if name then
            row.text:SetText(name)
            row.spellName = name
            row:Show()
        else
            row:Hide()
        end
    end

    local ranked = RankedList()
    FauxScrollFrame_Update(rankedScroll, #ranked, ROWS_VISIBLE, ROW_HEIGHT)
    local rankedOffset = FauxScrollFrame_GetOffset(rankedScroll)
    for i = 1, ROWS_VISIBLE do
        local row = rankedScroll.rows[i]
        local index = i + rankedOffset
        local entry = ranked[index]
        if entry then
            row.text:SetText(index .. ". " .. entry.name)
            row.rankedIndex = index
            row.noteBox.rankedIndex = index
            if not row.noteBox:HasFocus() then
                row.noteBox:SetText(entry.note or "")
            end
            if index == selectedRankedIndex then
                row.text:SetTextColor(0.93, 0.73, 0.33)
            else
                row.text:SetTextColor(1, 1, 1)
            end
            row:Show()
        else
            row:Hide()
        end
    end
end

for i = 1, ROWS_VISIBLE do
    availableScroll.rows[i]:SetScript("OnClick", function(self)
        if not self.spellName then return end
        table.insert(RankedList(), { name = self.spellName, note = "" })
        RefreshLists()
    end)
    rankedScroll.rows[i]:SetScript("OnClick", function(self, button)
        -- Le clic sur la case de commentaire ne doit pas voler le focus au champ.
        if self.noteBox and self.noteBox:HasFocus() then return end
        selectedRankedIndex = self.rankedIndex
        RefreshLists()
    end)
end

availableScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshLists)
end)
rankedScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshLists)
end)

upButton:SetScript("OnClick", function()
    local list = RankedList()
    if not selectedRankedIndex or selectedRankedIndex <= 1 then return end
    list[selectedRankedIndex], list[selectedRankedIndex - 1] =
        list[selectedRankedIndex - 1], list[selectedRankedIndex]
    selectedRankedIndex = selectedRankedIndex - 1
    RefreshLists()
end)

downButton:SetScript("OnClick", function()
    local list = RankedList()
    if not selectedRankedIndex or selectedRankedIndex >= #list then return end
    list[selectedRankedIndex], list[selectedRankedIndex + 1] =
        list[selectedRankedIndex + 1], list[selectedRankedIndex]
    selectedRankedIndex = selectedRankedIndex + 1
    RefreshLists()
end)

removeButton:SetScript("OnClick", function()
    local list = RankedList()
    if not selectedRankedIndex then return end
    table.remove(list, selectedRankedIndex)
    selectedRankedIndex = nil
    RefreshLists()
end)

local function SetMode(newMode)
    mode = newMode
    selectedRankedIndex = nil
    modeMonoButton:SetChecked(mode == "mono")
    modeAoeButton:SetChecked(mode == "aoe")
    rankedCaption:SetText(mode == "mono"
        and "Ordre de priorite mono (haut = plus important)"
        or "Ordre de priorite AoE (haut = plus important)")
    RefreshLists()
end

modeMonoButton:SetScript("OnClick", function() SetMode("mono") end)
modeAoeButton:SetScript("OnClick", function() SetMode("aoe") end)

local saveButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
saveButton:SetSize(160, 24)
saveButton:SetPoint("BOTTOM", 0, 20)
saveButton:SetText("Enregistrer le classement")
saveButton:SetScript("OnClick", function()
    saved.updatedAt = date("%Y-%m-%d %H:%M:%S")
    print("|cff00ff88[DPSLogger]|r Priorites enregistrees pour " .. characterKey ..
          " (mono : " .. #saved.mono .. " sorts, aoe : " .. #saved.aoe .. " sorts).")
    print("|cff00ff88[DPSLogger]|r Fais /reload ou deconnecte-toi pour ecrire le fichier.")
end)

local rescanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
rescanButton:SetSize(160, 24)
rescanButton:SetPoint("BOTTOM", saveButton, "TOP", 0, 8)
rescanButton:SetText("Rescanner le grimoire")
rescanButton:SetScript("OnClick", function()
    allSpells = ScanSpellbook()
    RefreshLists()
end)

local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 2, 2)

frame:SetScript("OnShow", function()
    allSpells = ScanSpellbook()
    SetMode(mode)
end)

SLASH_COAPRIO1 = "/coaprio"
SlashCmdList["COAPRIO"] = function()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
