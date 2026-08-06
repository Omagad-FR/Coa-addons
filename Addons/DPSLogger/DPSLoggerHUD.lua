-- DPSLoggerHUD 1.2
-- Panneau in-game pour piloter DPSLogger sans taper de commandes.
-- N'agit jamais directement sur la capture : pilote uniquement
-- SlashCmdList["DPSLOG"], le meme point d'entree que /dpslog en tapant.
-- La checklist detaillee et l'archivage restent dans Tests-Ingame.html ;
-- ce panneau donne juste de quoi demarrer/arreter/marquer sans alt-tab.

DPSLoggerHUDSettings = DPSLoggerHUDSettings or {}

-- Tests utilisables par n'importe quelle classe : ne dependent d'aucune
-- mecanique specifique, seulement d'une capture propre.
local GENERIC_TESTS = {
    {
        title = "Installation et demarrage",
        goal = "Confirmer que DPSLogger est charge sans erreur.",
        action = "Fais /reload puis Commencer ce test.",
        expected = "Le statut ci-dessus passe a ACTIF, aucune erreur Lua a l'ecran.",
    },
    {
        title = "Capture elementaire",
        goal = "Verifier qu'un petit combat produit une session exploitable.",
        action = "Frappe un mannequin 15 secondes, puis Arreter et /reload.",
        expected = "/dpslog last affiche des evenements, des degats et des critiques.",
    },
}

-- Tests specifiques a une classe/spe. Vide pour l'instant sauf Knight of
-- Xoroth (Warrior) : a completer au fur et a mesure que d'autres classes
-- sont calibrees (voir ETAT-DU-PROJET.md et Tests-Ingame.html).
local CLASS_TESTS = {
    WARRIOR = {
        {
            title = "Burning Blade : activation a 0 Demonfire",
            goal = "Etablir le nombre de charges de base.",
            action = "Vide Demonfire, Commencer ce test, active Burning Blade, puis Arreter tout de suite.",
            expected = "L'aura doit commencer a 6 charges sur ton build actuel.",
        },
        {
            title = "Burning Blade : activation a 6 Demonfire",
            goal = "Confirmer une charge supplementaire par Demonfire consomme.",
            action = "Monte a 6 Demonfire, Commencer ce test, active Burning Blade, puis Arreter.",
            expected = "L'aura doit commencer a 12 charges et Demonfire passer de 6 a 0.",
        },
        {
            title = "Burning Blade : attaques automatiques seules",
            goal = "Voir si une charge disparait sur coup blanc critique ou sur chaque coup blanc.",
            action = "Active Burning Blade, ne lance aucune competence, laisse les attaques automatiques 30 secondes.",
            expected = "Compare chaque baisse de charge aux coups blancs critiques et non critiques.",
        },
        {
            title = "Burning Blade : competence de melee mono",
            goal = "Verifier si Sever ou Gore consomme une charge et sous quelle condition.",
            action = "Active Burning Blade, utilise un seul type de competence et marque chaque essai.",
            expected = "Chaque baisse de charge doit etre reliee au cast critique ou non critique.",
        },
        {
            title = "Burning Blade : competence de zone",
            goal = "Verifier si une AoE consomme une charge par cast ou par cible.",
            action = "Sur 5 cibles, lance une seule AoE identifiable pendant Burning Blade.",
            expected = "Comparer le nombre de cibles touchees au nombre de charges perdues.",
        },
        {
            title = "Burning Blade : critique non-melee",
            goal = "Verifier qu'un critique magique independant ne consomme pas de charge.",
            action = "Provoque un critique magique sans attaque de melee simultanee.",
            expected = "Aucune baisse de charge reliee a ce critique.",
        },
        {
            title = "Domination : critique d'attaque automatique",
            goal = "Prouver si un coup blanc critique retire 1 seconde de cooldown.",
            action = "Active Burning Blade, ne fais que des coups blancs, Marque juste avant/apres chaque critique visible.",
            expected = "Une reduction de cooldown proche du coup critique, d'environ 1 seconde.",
        },
        {
            title = "Domination : critique de competence de melee",
            goal = "Mesurer la reduction produite par une competence physique critique.",
            action = "Utilise une seule competence a la fois et marque les critiques.",
            expected = "Un COOLDOWN_REDUCED d'environ 1 seconde relie a la competence.",
        },
        {
            title = "Domination : critique AoE multi-cibles",
            goal = "Savoir si la reduction se fait par cast ou par cible critique.",
            action = "Lance une seule AoE sur 5 cibles et compte les impacts critiques.",
            expected = "Comparer critiques produits et secondes retirees.",
        },
        {
            title = "Domination : apres disparition de l'aura",
            goal = "Verifier si les critiques reduisent encore le cooldown sans charge active.",
            action = "Epuise Burning Blade puis continue jusqu'a plusieurs critiques.",
            expected = "Des COOLDOWN_REDUCED peuvent encore apparaitre sans aura active.",
        },
        {
            title = "Demon's Blood : generation de base",
            goal = "Compter les stacks produits par coup blanc et competence physique.",
            action = "Sans Brimstone si possible, separe coups blancs et competences avec un marqueur.",
            expected = "Chaque hausse doit etre reliee a son evenement candidat.",
        },
        {
            title = "Brimstone's Blood : effet reel",
            goal = "Determiner si le talent ajoute une stack ou augmente une chance.",
            action = "Repete une longue serie avec le talent dans les memes conditions.",
            expected = "Comparer tentatives physiques et stacks gagnees.",
        },
        {
            title = "Hellborn au plafond de 10 Demon's Blood",
            goal = "Prouver que Hellborn peut proc meme quand Demon's Blood reste a 10.",
            action = "Atteins 10 stacks puis continue a attaquer plusieurs minutes sans les consommer.",
            expected = "Des Pestilences Hellborn doivent apparaitre alors que Demon's Blood reste a 10.",
        },
        {
            title = "Hellborn : taux de proc",
            goal = "Verifier le taux annonce par tentative de generation.",
            action = "Produis au moins 1000 tentatives de generation possibles.",
            expected = "Rapport procs/tentatives avec intervalle de confiance exploitable.",
        },
        {
            title = "Pestilence of War : complete et 50 pourcent",
            goal = "Separer Unleash manuel et declenchements a demi-efficacite.",
            action = "Avec les memes stats, provoque plusieurs declenchements complets et a 50 pourcent.",
            expected = "Deux groupes de degats coherents hors critiques.",
        },
        {
            title = "Pestilence of War : variation d'AP",
            goal = "Calculer le coefficient AP sans le confondre avec la Force.",
            action = "Fais deux series sur le meme mannequin, meme Force, AP differente.",
            expected = "Noter AP exacte et degats non critiques de chaque serie.",
        },
        {
            title = "Pestilence of War : variation de Force",
            goal = "Detecter un coefficient direct de Force en plus de l'AP.",
            action = "Change la Force en notant aussi l'AP, sans autre changement.",
            expected = "Au moins deux couples Force/AP/degats exploitables.",
        },
        {
            title = "Pestilence of Death : complete, demi et critiques",
            goal = "Mesurer separement ses degats selon l'origine du declenchement.",
            action = "Repete Unleash manuel, Hellborn et Pestilence Unbound.",
            expected = "Degats non critiques, critiques et cibles pour chaque origine.",
        },
        {
            title = "Pestilences : portee et nombre de cibles",
            goal = "Determiner la limite de cibles et l'egalite des impacts.",
            action = "Teste successivement sur 1, 5 puis 10 cibles groupees.",
            expected = "Compter les impacts d'un seul declenchement.",
        },
        {
            title = "Rage des attaques automatiques",
            goal = "Mesurer la Rage d'un coup blanc normal et critique.",
            action = "Pars a faible Rage et ne fais que des attaques automatiques.",
            expected = "Relier POWER_CHANGED aux degats et au statut critique.",
        },
        {
            title = "Rage provenant des degats recus",
            goal = "Mesurer la formule de Rage quand le personnage subit des degats.",
            action = "Fais-toi frapper sans attaquer, avec armure et buffs stables.",
            expected = "Relier chaque degat entrant a la hausse de Rage.",
        },
        {
            title = "Combat reel de reference",
            goal = "Fournir une rotation complete pour comparer au simulateur.",
            action = "Joue 3 a 5 minutes sur mannequin, sans buffs de groupe.",
            expected = "DPS, casts, ressources et cooldowns complets, aucun evenement perdu.",
        },
        {
            title = "Combat AoE de reference",
            goal = "Capturer une rotation realiste sur plusieurs cibles.",
            action = "Fais une session sur 5 cibles puis une autre sur 10 cibles.",
            expected = "Cibles stables et aucun changement d'equipement entre essais.",
        },
    },
}

local function BuildTestList()
    local _, classToken = UnitClass("player")
    local list = {}
    for _, test in ipairs(GENERIC_TESTS) do
        list[#list + 1] = test
    end
    for _, test in ipairs(CLASS_TESTS[classToken] or {}) do
        list[#list + 1] = test
    end
    return list, classToken
end

local tests, classToken = BuildTestList()
local currentIndex = 1

local function RunSlash(message)
    SlashCmdList["DPSLOG"](message)
end

StaticPopupDialogs["DPSLOGGERHUD_START"] = {
    text = "Note de session (contexte du test) :",
    button1 = "Commencer",
    button2 = "Annuler",
    hasEditBox = true,
    maxLetters = 120,
    OnShow = function(self)
        local default = self.data and self.data.default or ""
        self.editBox:SetText(default)
        self.editBox:HighlightText()
    end,
    OnAccept = function(self)
        local text = self.editBox:GetText() or ""
        RunSlash("start " .. text)
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        parent.button1:Click()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["DPSLOGGERHUD_MARK"] = {
    text = "Texte du marqueur :",
    button1 = "Marquer",
    button2 = "Annuler",
    hasEditBox = true,
    maxLetters = 120,
    OnAccept = function(self)
        local text = self.editBox:GetText()
        if text and text ~= "" then
            RunSlash("mark " .. text)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        parent.button1:Click()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local hud = CreateFrame("Frame", "DPSLoggerHUDFrame", UIParent)
hud:SetSize(360, 460)
hud:SetPoint(
    DPSLoggerHUDSettings.point or "CENTER",
    UIParent,
    DPSLoggerHUDSettings.relPoint or "CENTER",
    DPSLoggerHUDSettings.x or 0,
    DPSLoggerHUDSettings.y or 0
)
hud:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
hud:SetMovable(true)
hud:EnableMouse(true)
hud:RegisterForDrag("LeftButton")
hud:SetScript("OnDragStart", hud.StartMoving)
hud:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    DPSLoggerHUDSettings.point = point
    DPSLoggerHUDSettings.relPoint = relPoint
    DPSLoggerHUDSettings.x = x
    DPSLoggerHUDSettings.y = y
end)
hud:SetClampedToScreen(true)
hud:Hide()

local title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -18)
title:SetText("CoA - Journal de combat")

local classLabel = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
classLabel:SetPoint("TOP", title, "BOTTOM", 0, -4)
classLabel:SetText(classToken or "?")

local status = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
status:SetPoint("TOP", classLabel, "BOTTOM", 0, -8)

local counter = hud:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
counter:SetPoint("TOP", status, "BOTTOM", 0, -10)

local testTitle = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
testTitle:SetPoint("TOPLEFT", 20, -100)
testTitle:SetPoint("TOPRIGHT", -20, -100)
testTitle:SetJustifyH("LEFT")

local function AddField(anchorTo, label)
    local caption = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -8)
    caption:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, -8)
    caption:SetJustifyH("LEFT")
    caption:SetText(label)
    caption:SetTextColor(0.93, 0.73, 0.33)

    local body = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", 0, -2)
    body:SetPoint("TOPRIGHT", caption, "BOTTOMRIGHT", 0, -2)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    return caption, body
end

local goalCaption, goalBody = AddField(testTitle, "Objectif")
local actionCaption, actionBody = AddField(goalBody, "A faire")
local expectedCaption, expectedBody = AddField(actionBody, "Ce que l'on cherche")

local function RefreshStatus()
    if DPSLogger_IsActive and DPSLogger_IsActive() then
        status:SetText("|cff62d394EN MARCHE|r")
    else
        status:SetText("|cffff8c8cARRETE|r")
    end
end

local function RefreshTest()
    local test = tests[currentIndex]
    counter:SetText(currentIndex .. " / " .. #tests)
    if not test then
        testTitle:SetText("Aucun test disponible pour cette classe.")
        goalCaption:Hide(); goalBody:Hide()
        actionCaption:Hide(); actionBody:Hide()
        expectedCaption:Hide(); expectedBody:Hide()
        return
    end
    goalCaption:Show(); goalBody:Show()
    actionCaption:Show(); actionBody:Show()
    expectedCaption:Show(); expectedBody:Show()
    testTitle:SetText(test.title)
    goalBody:SetText(test.goal)
    actionBody:SetText(test.action)
    expectedBody:SetText(test.expected)
end

local prevButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
prevButton:SetSize(28, 22)
prevButton:SetPoint("TOPLEFT", testTitle, "TOPLEFT", -4, 14)
prevButton:SetText("<")
prevButton:SetScript("OnClick", function()
    if #tests == 0 then return end
    currentIndex = currentIndex - 1
    if currentIndex < 1 then currentIndex = #tests end
    RefreshTest()
end)

local nextButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
nextButton:SetSize(28, 22)
nextButton:SetPoint("TOPRIGHT", testTitle, "TOPRIGHT", 4, 14)
nextButton:SetText(">")
nextButton:SetScript("OnClick", function()
    if #tests == 0 then return end
    currentIndex = currentIndex + 1
    if currentIndex > #tests then currentIndex = 1 end
    RefreshTest()
end)

local startButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
startButton:SetSize(150, 24)
startButton:SetPoint("BOTTOMLEFT", 20, 44)
startButton:SetText("Commencer ce test")
startButton:SetScript("OnClick", function()
    local test = tests[currentIndex]
    StaticPopup_Show("DPSLOGGERHUD_START", nil, nil, { default = test and test.title or "" })
    reloadButton:Hide()
end)

local reloadButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
reloadButton:SetSize(150, 24)
reloadButton:SetPoint("BOTTOM", 0, 78)
reloadButton:SetText("Recharger (/reload)")
reloadButton:SetScript("OnClick", function()
    ReloadUI()
end)
reloadButton:Hide()

local stopButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
stopButton:SetSize(150, 24)
stopButton:SetPoint("BOTTOMRIGHT", -20, 74)
stopButton:SetText("Arreter")
stopButton:SetScript("OnClick", function()
    RunSlash("stop")
    RefreshStatus()
    reloadButton:Show()
end)

local cancelButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
cancelButton:SetSize(150, 24)
cancelButton:SetPoint("BOTTOMRIGHT", -20, 44)
cancelButton:SetText("Annuler la capture")
cancelButton:SetScript("OnClick", function()
    RunSlash("cancel")
    RefreshStatus()
end)

local markButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
markButton:SetSize(150, 24)
markButton:SetPoint("BOTTOMLEFT", 20, 14)
markButton:SetText("Marquer")
markButton:SetScript("OnClick", function()
    StaticPopup_Show("DPSLOGGERHUD_MARK")
end)

local priorityButton = CreateFrame("Button", nil, hud, "UIPanelButtonTemplate")
priorityButton:SetSize(150, 24)
priorityButton:SetPoint("BOTTOMRIGHT", -20, 14)
priorityButton:SetText("Priorites de rotation")
priorityButton:SetScript("OnClick", function()
    SlashCmdList["COAPRIO"]()
end)

local closeButton = CreateFrame("Button", nil, hud, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 2, 2)

hud:SetScript("OnShow", function()
    RefreshStatus()
    RefreshTest()
end)

local ticker = 0
hud:SetScript("OnUpdate", function(self, elapsed)
    ticker = ticker + elapsed
    if ticker >= 1 then
        ticker = 0
        RefreshStatus()
    end
end)

SLASH_COAHUD1 = "/coahud"
SlashCmdList["COAHUD"] = function()
    if hud:IsShown() then
        hud:Hide()
    else
        hud:Show()
    end
end
