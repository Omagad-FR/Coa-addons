-- EasyLoot 0.5.3 - coeur
-- made by Omagad
-- Client WoW 3.3.5a / Interface 30300
--
-- Fonctions :
--   1. scanne les sacs et retient les pieces d'equipement ;
--   2. maintient une liste de verrous persistants par objet ;
--   3. annonce une piece en avertissement raid, comme /rw ;
--   4. ouvre une fenetre de jets et designe le meilleur jet ;
--   5. annonce le gagnant dans le canal choisi, sur clic uniquement ;
--   6. suit qui a REELLEMENT recu chaque piece (pas juste qui a gagne le
--      jet) dans un historique persistant, en s'appuyant soit sur une
--      confirmation d'echange en jeu, soit sur une assignation manuelle ;
--   7. sur demande, place automatiquement la piece dans la fenetre
--      d'echange des qu'elle s'ouvre avec le destinataire attendu.
--
-- Aucun message n'est envoye sans action explicite de l'utilisateur.
-- L'addon ne detruit aucun objet. Le placement automatique dans l'echange
-- (point 7, /easyloot autotrade) est la seule action qui manipule un objet
-- des sacs ; il ne fait que le deposer dans la fenetre d'echange deja
-- ouverte par le joueur, jamais l'envoyer seul -- l'echange reste valide
-- manuellement des deux cotes, comme toujours en jeu.

EasyLootDB = EasyLootDB or {}

local ADDON_NAME = "EasyLoot"
local ADDON_VERSION = "0.5.3"
local PREFIX = "|cff66ccffEasyLoot|r"
local EPIC_QUALITY = 4

EasyLoot = EasyLoot or {}
local core = EasyLoot
core.version = ADDON_VERSION
core.prefix = PREFIX

-- /rw est l'avertissement raid : le message s'affiche au milieu de l'ecran
-- de tout le raid. L'addon passe par SendChatMessage sur le canal
-- RAID_WARNING, exactement le meme mecanisme, sans dependre de la barre de
-- chat ni du nom de l'alias. Le mode "slash" reste disponible au cas ou une
-- commande du serveur ajouterait un comportement propre.
--
-- Les modeles acceptent %s, remplace par le nom ou le lien de la piece.
local DEFAULTS = {
    -- Le butin de raid arrive lie mais echangeable : masquer les objets
    -- lies epargne quand meme ceux encore echangeables, seuls les objets
    -- lies et non echangeables (donc non distribuables) sont caches.
    -- Actif par defaut : /easyloot lies on pour tout revoir.
    hideSoulbound = true,
    -- Repli seulement si le client n'expose pas BIND_TRADE_TIME_REMAINING.
    tradePhrase = "trade this item",
    sendMode = "alerte",        -- "alerte" | "raid" | "slash"
    announceTemplate = "%s  -  /roll pour cette piece",
    slashCommand = "/rw %s",    -- utilise seulement si sendMode == "slash"
    announceUseLink = true,     -- true = lien cliquable, false = nom seul
    winnerChannel = "RAID_WARNING",
    rollSeconds = 30,
    rollsFromChat = true,       -- accepte aussi les nombres nus en raid
    firstRollOnly = true,       -- un seul jet retenu par joueur
    debug = false,
    locks = {},
    -- Place la piece attendue dans la fenetre d'echange des qu'elle s'ouvre
    -- avec le bon destinataire. Desactivable si le ML echange autre chose
    -- en meme temps que la distribution du loot.
    autoTrade = true,
    -- Historique persistant : qui a REELLEMENT recu chaque piece, le plus
    -- recent en tete. Rempli par AssignRecipient (echange confirme ou
    -- assignation manuelle), jamais par le seul gain d'un jet.
    history = {},
    -- Position de l'icone autour de la minimap (degres) et visibilite.
    minimapAngle = 215,
    minimapHide = false,
}

local BAG_LAST = NUM_BAG_SLOTS or 4

-- Etat de session, jamais sauvegarde.
core.items = {}
core.session = nil

--------------------------------------------------------------------------
-- Utilitaires
--------------------------------------------------------------------------

function core:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " " .. tostring(message))
end

function core:Debug(message)
    if EasyLootDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " |cff999999" .. tostring(message) .. "|r")
    end
end

-- Le serveur peut suffixer le royaume ("Nom-Royaume") ; les jets, les
-- assignations et le partenaire d'echange se comparent tous par nom court.
-- Fonction partagee (etait dupliquee localement dans EasyLoot_Rolls.lua).
function core:ShortName(name)
    if not name then return nil end
    return name:match("^([^%-]+)") or name
end

-- Petit bus d'evenements interne : le coeur ne connait pas l'interface.
core.listeners = {}

function core:On(event, callback)
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], callback)
end

function core:Fire(event, ...)
    local list = self.listeners[event]
    if not list then return end
    for _, callback in ipairs(list) do
        callback(...)
    end
end

-- Cle stable d'un objet : itemID + suffixe aleatoire. Le uniqueID varie
-- d'une instance a l'autre et ne peut donc pas servir de verrou durable.
function core:ItemKey(link)
    if not link then return nil end
    local itemId, _, _, _, _, _, suffixId = link:match(
        "|Hitem:(%d+):(%-?%d*):(%-?%d*):(%-?%d*):(%-?%d*):(%-?%d*):(%-?%d*)"
    )
    if not itemId then return nil end
    return itemId .. ":" .. (suffixId ~= "" and suffixId or "0")
end

--------------------------------------------------------------------------
-- Lecture du tooltip : lie a soi, et fenetre d'echange
--------------------------------------------------------------------------
--
-- Le butin de raid est lie des le ramassage tout en restant echangeable
-- quelques heures avec les joueurs eligibles. "Lie" ne veut donc pas dire
-- "non distribuable" : c'est le cas normal des pieces que cet addon sert a
-- repartir, et la vraie information utile est la fenetre d'echange.

local scanner = CreateFrame("GameTooltip", "EasyLootScanTooltip", nil, "GameTooltipTemplate")

-- Partie fixe du message d'echange, prise dans la globale du client quand
-- elle existe. Sinon on retombe sur une phrase configurable, car le texte
-- depend alors de la langue du serveur (voir /easyloot echange).
local TRADE_PREFIX
if BIND_TRADE_TIME_REMAINING then
    local prefix = BIND_TRADE_TIME_REMAINING:match("^(.-)%%s")
    if prefix and prefix ~= "" then
        TRADE_PREFIX = prefix
    end
end

local function InspectBagItem(bag, slot)
    local bound, tradeable = false, false
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner:ClearLines()
    scanner:SetBagItem(bag, slot)

    local phrase = EasyLootDB.tradePhrase
    phrase = (phrase and phrase ~= "") and phrase:lower() or nil

    for line = 2, scanner:NumLines() do
        local fontString = _G["EasyLootScanTooltipTextLeft" .. line]
        local text = fontString and fontString:GetText()
        if text then
            if text == ITEM_SOULBOUND then
                bound = true
            elseif TRADE_PREFIX and text:find(TRADE_PREFIX, 1, true) then
                tradeable = true
            elseif not TRADE_PREFIX and phrase and text:lower():find(phrase, 1, true) then
                tradeable = true
            end
        end
    end
    return bound, tradeable
end

--------------------------------------------------------------------------
-- Scan des sacs
--------------------------------------------------------------------------

-- Ne retient que ce qui est equipable : itemEquipLoc est un jeton non
-- localise ("INVTYPE_HEAD"...), contrairement au type d'objet renvoye par
-- GetItemInfo qui depend de la langue du client.
function core:Scan()
    local found = {}
    local unknown = 0
    local skippedQuality = 0
    local skippedBound = 0

    for bag = 0, BAG_LAST do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, quality, itemLevel, _, _, _, _, equipLoc, texture =
                    GetItemInfo(link)
                if not name then
                    -- L'objet n'est pas encore dans le cache client ; il
                    -- apparaitra au prochain scan.
                    unknown = unknown + 1
                elseif equipLoc and equipLoc ~= "" then
                    local quantity = select(2, GetContainerItemInfo(bag, slot)) or 1
                    local bound, tradeable = InspectBagItem(bag, slot)
                    -- EasyLoot est volontairement limite aux objets epiques.
                    -- Le filtre est fixe afin qu'une ancienne valeur enregistree
                    -- dans EasyLootDB ne puisse pas refaire apparaitre du gris.
                    if quality ~= EPIC_QUALITY then
                        skippedQuality = skippedQuality + 1
                    elseif EasyLootDB.hideSoulbound and bound and not tradeable then
                        skippedBound = skippedBound + 1
                    else
                        table.insert(found, {
                            key = self:ItemKey(link),
                            link = link,
                            name = name,
                            quality = quality,
                            itemLevel = itemLevel,
                            equipLoc = equipLoc,
                            texture = texture,
                            bag = bag,
                            slot = slot,
                            count = quantity,
                            soulbound = bound,
                            tradeable = tradeable,
                        })
                    end
                end
            end
        end
    end

    -- Ce qui est encore echangeable passe devant : c'est ce qui a une
    -- date limite, donc ce qu'il faut distribuer en premier.
    table.sort(found, function(a, b)
        if a.tradeable ~= b.tradeable then return a.tradeable end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.itemLevel ~= b.itemLevel then return (a.itemLevel or 0) > (b.itemLevel or 0) end
        return a.name < b.name
    end)

    self.items = found
    self.lastScan = {
        unknown = unknown,
        skippedQuality = skippedQuality,
        skippedBound = skippedBound,
    }
    self:Fire("ITEMS_CHANGED")
    return #found, unknown, skippedQuality, skippedBound
end

-- Scan + compte rendu de ce qui a ete ecarte : sans ca, une piece absente
-- de la liste ressemble a un bug alors que c'est un filtre qui l'exclut.
function core:ScanAndReport()
    local count, unknown, skippedQuality, skippedBound = self:Scan()
    local details = {}
    if skippedQuality > 0 then
        table.insert(details, skippedQuality .. " non epique(s)")
    end
    if skippedBound > 0 then
        table.insert(details, skippedBound .. " lie(s) et non echangeable(s)")
    end
    if unknown > 0 then
        table.insert(details, unknown .. " pas encore en cache, rescanne")
    end

    local message = count .. " piece(s) d'equipement retenue(s)"
    if #details > 0 then
        message = message .. " |cff999999(ecarte : " .. table.concat(details, ", ") .. ")|r"
    end
    self:Print(message)
    return count
end

function core:IsLocked(key)
    return key ~= nil and EasyLootDB.locks[key] == true
end

function core:ToggleLock(key)
    if not key then return end
    if EasyLootDB.locks[key] then
        EasyLootDB.locks[key] = nil
    else
        EasyLootDB.locks[key] = true
    end
    self:Fire("ITEMS_CHANGED")
end

function core:ClearLocks()
    EasyLootDB.locks = {}
    self:Fire("ITEMS_CHANGED")
end

--------------------------------------------------------------------------
-- Envoi de la commande d'annonce
--------------------------------------------------------------------------

-- Mode "slash" : on ecrit dans la barre de chat exactement comme si
-- l'utilisateur tapait la commande, puis on l'envoie. C'est le seul moyen
-- fiable de declencher une commande qui n'est pas une API du client.
local function RunSlash(text)
    local editBox = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
    if not editBox or not ChatEdit_SendText then
        core:Print("|cffff8c8cBarre de chat introuvable, commande non envoyee.|r")
        return false
    end
    editBox:SetText(text)
    ChatEdit_SendText(editBox, 0)
    editBox:SetText("")
    return true
end

-- L'avertissement raid est reserve au chef de raid et aux assistants.
function core:CanRaidWarn()
    return (GetNumRaidMembers() or 0) > 0
        and (IsRaidLeader() or IsRaidOfficer()) and true or false
end

-- Replie sur un canal reellement disponible plutot que de perdre le
-- message : le client refuse silencieusement RAID hors raid. Renvoie le
-- canal effectivement utilise pour que l'appelant puisse le signaler.
local function SendToChannel(text, channel)
    local inRaid = (GetNumRaidMembers() or 0) > 0
    local inParty = (GetNumPartyMembers() or 0) > 0

    if channel == "RAID_WARNING" and not core:CanRaidWarn() then
        channel = inRaid and "RAID" or (inParty and "PARTY" or "SAY")
    elseif channel == "RAID" and not inRaid then
        channel = inParty and "PARTY" or "SAY"
    elseif channel == "PARTY" and not inParty and not inRaid then
        channel = "SAY"
    end

    SendChatMessage(text, channel)
    return true, channel
end

local function FormatWith(template, subject)
    if template:find("%%s") then
        return template:format(subject)
    end
    return template .. " " .. subject
end

--------------------------------------------------------------------------
-- Session de jets
--------------------------------------------------------------------------

function core:GetSession()
    return self.session
end

-- index : position dans core.items. Renvoie false et un motif si l'annonce
-- n'a pas ete faite.
function core:Announce(index)
    local item = self.items[index]
    if not item then
        return false, "Aucune piece selectionnee."
    end
    if self:IsLocked(item.key) then
        return false, "Cette piece est verrouillee."
    end

    local subject = EasyLootDB.announceUseLink and item.link or item.name
    local mode = EasyLootDB.sendMode or DEFAULTS.sendMode
    local text
    if mode == "slash" then
        text = FormatWith(EasyLootDB.slashCommand or DEFAULTS.slashCommand, subject)
    else
        text = FormatWith(EasyLootDB.announceTemplate or DEFAULTS.announceTemplate, subject)
    end

    self.session = {
        item = item,
        index = index,
        text = text,
        startTime = GetTime(),
        endTime = GetTime() + (EasyLootDB.rollSeconds or 30),
        open = true,
        rolls = {},
        seen = {},
        raw = {},
    }

    -- La session doit exister avant l'envoi pour ne rater aucune reponse,
    -- mais elle est annulee si le message n'a pas pu partir.
    local sent, usedChannel
    if mode == "slash" then
        sent = RunSlash(text)
        usedChannel = "commande"
    elseif mode == "raid" then
        sent, usedChannel = SendToChannel(text, "RAID")
    else
        sent, usedChannel = SendToChannel(text, "RAID_WARNING")
        if usedChannel ~= "RAID_WARNING" then
            self:Print("|cffffd200Pas chef de raid ni assistant : envoye en "
                .. usedChannel .. " au lieu de l'alerte plein ecran.|r")
        end
    end

    if not sent then
        self.session = nil
        return false, "Envoi impossible."
    end

    self:Fire("SESSION_CHANGED")
    self:Print("Annonce : " .. text .. " |cff999999(jets ouverts "
        .. tostring(EasyLootDB.rollSeconds or 30) .. " s)|r")
    return true
end

function core:CloseRolls()
    if self.session and self.session.open then
        self.session.open = false
        self:Fire("SESSION_CHANGED")
        local winner, tied = self:GetWinner()
        if winner then
            self:Print("Meilleur jet : " .. winner.name .. " (" .. winner.value .. ")")
            if tied and #tied > 1 then
                self:Print("|cffffd200Egalite entre " .. #tied .. " joueurs, relance conseillee.|r")
            end
        else
            self:Print("Aucun jet enregistre.")
        end
    end
end

function core:CancelSession()
    self.session = nil
    self:Fire("SESSION_CHANGED")
end

-- Enregistre un jet. Appele par EasyLoot_Rolls.lua.
function core:AddRoll(name, value, minRoll, maxRoll, source)
    local session = self.session
    if not session or not session.open then return false end
    if EasyLootDB.firstRollOnly and session.seen[name] then
        self:Debug("Jet ignore (deja joue) : " .. name)
        return false
    end
    session.seen[name] = true
    table.insert(session.rolls, {
        name = name,
        value = value,
        min = minRoll or 1,
        max = maxRoll or 100,
        source = source or "?",
        time = GetTime() - session.startTime,
    })
    table.sort(session.rolls, function(a, b) return a.value > b.value end)
    self:Fire("ROLLS_CHANGED")
    return true
end

-- Renvoie le meilleur jet et, s'il y a egalite, la liste des ex aequo.
function core:GetWinner()
    local session = self.session
    if not session or #session.rolls == 0 then return nil end
    local best = session.rolls[1]
    local tied = {}
    for _, roll in ipairs(session.rolls) do
        if roll.value == best.value then
            table.insert(tied, roll)
        end
    end
    return best, tied
end

function core:AnnounceWinner()
    local session = self.session
    if not session then return false, "Aucune annonce en cours." end
    local winner, tied = self:GetWinner()
    if not winner then return false, "Aucun jet enregistre." end

    local subject = session.item.link or session.item.name
    local text
    if tied and #tied > 1 then
        local names = {}
        for _, roll in ipairs(tied) do table.insert(names, roll.name) end
        text = "Egalite a " .. winner.value .. " sur " .. subject
            .. " : " .. table.concat(names, ", ") .. " - relancez."
    else
        text = subject .. " remporte par " .. winner.name .. " avec " .. winner.value .. "."
    end
    SendToChannel(text, EasyLootDB.winnerChannel or "RAID")
    return true
end

--------------------------------------------------------------------------
-- Qui a REELLEMENT recu la piece : historique et suivi de l'echange
--------------------------------------------------------------------------
--
-- Le jet designe un gagnant, mais rien ne garantit qu'il vient recuperer sa
-- piece, ni que le ML ne change pas d'avis (verrou, absence, erreur de
-- jet...). AssignRecipient est le seul point qui ecrit dans l'historique :
-- c'est la confirmation qu'une piece a change de main, pas juste qu'un jet
-- a ete gagne.

-- La piece actuellement selectionnee, pour les actions qui n'ont pas de
-- session de jets en cours (assignation manuelle sans annonce, par ex.).
function core:CurrentItem()
    if self.session then return self.session.item end
    if self.pendingItem then return self.pendingItem end
    local ui = self.ui
    if ui and ui.selectedIndex then return self.items[ui.selectedIndex] end
    return nil
end

-- Retire une piece de la liste par sa cle stable : le tableau peut avoir
-- change (rescan) entre l'annonce et l'assignation, l'identite d'objet Lua
-- de session.item n'est donc plus fiable.
function core:RemoveItemByKey(key)
    if not key then return end
    for index, entry in ipairs(self.items) do
        if entry.key == key then
            table.remove(self.items, index)
            break
        end
    end
    self:Fire("ITEMS_CHANGED")
end

local HISTORY_MAX = 300

function core:RecordHistory(item, recipient, method)
    table.insert(EasyLootDB.history, 1, {
        name = item.name,
        link = item.link,
        quality = item.quality,
        recipient = recipient,
        method = method, -- "echange" (confirme en jeu) ou "manuel"
        time = date("%d/%m %H:%M"),
    })
    while #EasyLootDB.history > HISTORY_MAX do
        table.remove(EasyLootDB.history)
    end
    self:Fire("HISTORY_CHANGED")
end

-- Nombre de pieces deja recues par ce joueur, tout l'historique confondu.
-- L'historique survit au /reload (SavedVariables), donc ceci couvre
-- plusieurs boss dans la meme soiree sans rien reinitialiser tout seul --
-- voir ClearHistory pour le remettre a zero entre deux soirees de raid.
function core:GetLootCount(name)
    if not name then return 0 end
    local count = 0
    for _, entry in ipairs(EasyLootDB.history) do
        if entry.recipient == name then
            count = count + 1
        end
    end
    return count
end

-- Vide l'historique : a faire a la main en debut de nouvelle soiree de
-- raid, l'addon ne devine jamais tout seul qu'un nouveau raid commence.
function core:ClearHistory()
    EasyLootDB.history = {}
    self:Fire("HISTORY_CHANGED")
    self:Print("historique vide.")
end

-- Assigne immediatement la piece courante a un destinataire : c'est la
-- confirmation manuelle, utilisee quand l'echange a deja eu lieu ou quand
-- il n'y a pas de jet (attribution a la main par le ML).
function core:AssignRecipient(name, method)
    local item = self:CurrentItem()
    if not item then
        return false, "Aucune piece a assigner."
    end
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "Indique le nom du destinataire."
    end

    self:RecordHistory(item, self:ShortName(name), method or "manuel")
    self:RemoveItemByKey(item.key)

    if self.pendingItem and self.pendingItem.key == item.key then
        self.pendingItem = nil
        self.pendingRecipient = nil
    end
    self.session = nil
    self:Fire("SESSION_CHANGED")
    self:Print("Piece assignee a " .. self:ShortName(name)
        .. " |cff999999(" .. (method or "manuel") .. ")|r")
    return true
end

-- Arme le placement automatique : des que la fenetre d'echange s'ouvre avec
-- ce destinataire (nom court), la piece est deposee dans un emplacement
-- libre. Rien n'est envoye ni confirme automatiquement, seul l'echange
-- validee des deux cotes en jeu enregistre l'historique (voir OnTradeInfoMessage).
function core:PrepareTrade(name)
    local item = self:CurrentItem()
    if not item then
        return false, "Aucune piece a preparer."
    end
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "Indique le destinataire attendu."
    end

    self.pendingItem = item
    self.pendingRecipient = self:ShortName(name)
    self:Print("En attente de l'echange avec " .. self.pendingRecipient
        .. " pour placer automatiquement : " .. (item.link or item.name))
    self:Fire("SESSION_CHANGED")
    return true
end

-- Retrouve l'objet dans les sacs par sa cle stable : bag/slot peuvent avoir
-- bouge depuis le dernier scan (tri, retrait d'un autre objet...).
function core:FindBagSlot(key)
    if not key then return nil end
    for bag = 0, BAG_LAST do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link and self:ItemKey(link) == key then
                return bag, slot
            end
        end
    end
    return nil
end

-- Les 6 premiers emplacements d'echange sont utilisables par l'addon ; le
-- 7eme (non echangeable, cote "vous ne recevrez rien") est laisse de cote.
local TRADE_SLOT_COUNT = 6

function core:FindFreeTradeSlot()
    for slot = 1, TRADE_SLOT_COUNT do
        if not GetTradePlayerItemLink(slot) then
            return slot
        end
    end
    return nil
end

function core:PlaceItemInTrade()
    local item = self.pendingItem
    if not item then return end

    for slot = 1, TRADE_SLOT_COUNT do
        local link = GetTradePlayerItemLink(slot)
        if link and self:ItemKey(link) == item.key then
            self:Debug("Piece deja placee dans l'echange (emplacement " .. slot .. ").")
            return
        end
    end

    local bag, slot = self:FindBagSlot(item.key)
    if not bag then
        self:Print("|cffff8c8cPiece introuvable dans les sacs (deja donnee ou deplacee ?).|r")
        return
    end

    local freeSlot = self:FindFreeTradeSlot()
    if not freeSlot then
        self:Print("|cffff8c8cTous les emplacements d'echange sont occupes, place la piece a la main.|r")
        return
    end

    ClearCursor()
    PickupContainerItem(bag, slot)
    ClickTradeButton(freeSlot)
    self:Print("Piece placee automatiquement dans l'echange : " .. (item.link or item.name))
end

function core:OnTradeShow()
    if not EasyLootDB.autoTrade then return end
    if not self.pendingItem or not self.pendingRecipient then return end
    local partner = UnitName("NPC")
    if not partner or self:ShortName(partner) ~= self.pendingRecipient then
        self:Debug("Echange ouvert avec " .. tostring(partner)
            .. ", different du destinataire attendu (" .. tostring(self.pendingRecipient) .. ").")
        return
    end
    self:PlaceItemInTrade()
end

-- ERR_TRADE_COMPLETE est la chaine globale du client ("Trade complete."),
-- donc valable quelle que soit la langue du serveur.
function core:OnTradeInfoMessage(message)
    if not self.pendingRecipient or not self.pendingItem then return end
    if message ~= ERR_TRADE_COMPLETE then return end

    local item = self.pendingItem
    local recipient = self.pendingRecipient
    self.pendingItem = nil
    self.pendingRecipient = nil
    self:RecordHistory(item, recipient, "echange")
    self:RemoveItemByKey(item.key)
    if self.session and self.session.item and self.session.item.key == item.key then
        self.session = nil
    end
    self:Print("|cff62d394Echange termine avec " .. recipient
        .. ", piece enregistree dans l'historique.|r")
    self:Fire("SESSION_CHANGED")
end

function core:OnTradeClosed()
    if self.pendingRecipient then
        self:Debug("Fenetre d'echange fermee, en attente toujours active pour "
            .. self.pendingRecipient .. " (reouvre l'echange pour reessayer).")
    end
end

local tradeWatcher = CreateFrame("Frame")
tradeWatcher:RegisterEvent("TRADE_SHOW")
tradeWatcher:RegisterEvent("TRADE_CLOSED")
tradeWatcher:RegisterEvent("UI_INFO_MESSAGE")
tradeWatcher:SetScript("OnEvent", function(self, event, arg1)
    if event == "TRADE_SHOW" then
        core:OnTradeShow()
    elseif event == "UI_INFO_MESSAGE" then
        core:OnTradeInfoMessage(arg1)
    elseif event == "TRADE_CLOSED" then
        core:OnTradeClosed()
    end
end)

--------------------------------------------------------------------------
-- Fermeture automatique de la fenetre de jets
--------------------------------------------------------------------------

local ticker = CreateFrame("Frame")
local accumulated = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
    accumulated = accumulated + elapsed
    if accumulated < 0.25 then return end
    accumulated = 0
    local session = core.session
    if session and session.open and GetTime() >= session.endTime then
        core:CloseRolls()
    end
end)

--------------------------------------------------------------------------
-- Chargement et commandes
--------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name ~= ADDON_NAME then return end

    -- Migration depuis 0.1.0, qui traitait l'annonce comme une commande
    -- serveur inconnue plutot que comme l'avertissement raid du client.
    if EasyLootDB.announceCommand then
        EasyLootDB.slashCommand = EasyLootDB.announceCommand
        EasyLootDB.announceCommand = nil
    end
    if EasyLootDB.sendMode == "chat" then
        EasyLootDB.sendMode = "raid"
    end
    EasyLootDB.sendChannel = nil

    -- 0.3.0 : masquer les objets lies etait un mauvais defaut, il cachait
    -- justement le butin de raid, qui arrive lie mais echangeable. Les
    -- defauts ci-dessous ne s'appliquant qu'aux cles absentes, il faut
    -- forcer la valeur une fois pour les bases deja ecrites en 0.1/0.2.
    if (EasyLootDB.schema or 0) < 3 then
        EasyLootDB.hideSoulbound = false
        EasyLootDB.announceUseLink = true
        EasyLootDB.schema = 3
    end

    -- 0.3.1 : l'avertissement raid s'appelle /rw, pas /ar. Ne touche que
    -- l'ancienne valeur par defaut, pour ne pas ecraser une commande que
    -- l'utilisateur aurait lui-meme choisie.
    if (EasyLootDB.schema or 0) < 4 then
        if EasyLootDB.slashCommand == "/ar %s" then
            EasyLootDB.slashCommand = "/rw %s"
        end
        EasyLootDB.schema = 4
    end

    -- 0.3.2 : masquer les objets lies non echangeables devient le defaut.
    -- Ne force que si la valeur est encore celle ecrite par le schema 3
    -- (false) et jamais changee depuis via /easyloot lies.
    if (EasyLootDB.schema or 0) < 5 then
        if EasyLootDB.hideSoulbound == false then
            EasyLootDB.hideSoulbound = true
        end
        EasyLootDB.schema = 5
    end

    -- 0.4.0 : renomme depuis CoARaidLoot (generique, plus lie a Conquest of
    -- Azeroth). Nouvelle SavedVariables EasyLootDB : aucune donnee de
    -- l'ancien CoARaidLootDB n'est reprise, les migrations ci-dessus ne
    -- jouent donc que pour un utilisateur qui recopierait manuellement son
    -- ancienne base.
    EasyLootDB.schema = 6

    for key, value in pairs(DEFAULTS) do
        if EasyLootDB[key] == nil then
            if type(value) == "table" then
                EasyLootDB[key] = {}
            else
                EasyLootDB[key] = value
            end
        end
    end
    core:Fire("DB_READY")
    core:Print("version " .. ADDON_VERSION .. " chargee (made by Omagad). /easyloot pour ouvrir.")
end)

local function ShowHelp()
    core:Print("commandes disponibles :")
    core:Print("  /easyloot            ouvre ou ferme le panneau")
    core:Print("  /easyloot scan       relance le scan des sacs")
    core:Print("  /easyloot texte <txt>  modele du message, %s = la piece (actuel : "
        .. tostring(EasyLootDB.announceTemplate) .. ")")
    core:Print("  /easyloot mode alerte|raid|slash  alerte = /rw plein ecran (actuel : "
        .. tostring(EasyLootDB.sendMode) .. ")")
    core:Print("  /easyloot cmd <txt>  commande du mode slash (actuel : "
        .. tostring(EasyLootDB.slashCommand) .. ")")
    core:Print("  /easyloot lien on|off       annoncer le lien au lieu du nom (actuel : "
        .. tostring(EasyLootDB.announceUseLink) .. ")")
    core:Print("  /easyloot duree <s>  duree de la fenetre de jets (actuel : "
        .. tostring(EasyLootDB.rollSeconds) .. ")")
    core:Print("  filtre de qualite : objets epiques uniquement")
    core:Print("  /easyloot lies on|off    afficher les objets lies non echangeables (actuel : "
        .. tostring(not EasyLootDB.hideSoulbound) .. ")")
    core:Print("  /easyloot echange <txt>  phrase de repli de la fenetre d'echange")
    core:Print("  /easyloot verrous    vide tous les verrous")
    core:Print("  /easyloot autotrade on|off  placer la piece automatiquement des l'echange (actuel : "
        .. tostring(EasyLootDB.autoTrade) .. ")")
    core:Print("  /easyloot historique  affiche les 10 dernieres distributions")
    core:Print("  /easyloot historique reset  vide l'historique (entre deux soirees de raid)")
    core:Print("  /easyloot minimap on|off  afficher l'icone pres de la minimap (actuel : "
        .. tostring(not EasyLootDB.minimapHide) .. ")")
    core:Print("  /easyloot debug      affiche les messages bruts recus pendant les jets")
end

SLASH_EasyLoot1 = "/easyloot"
SLASH_EasyLoot2 = "/elraid"
SlashCmdList["EasyLoot"] = function(message)
    message = message or ""
    local command, rest = message:match("^(%S*)%s*(.-)%s*$")
    command = (command or ""):lower()

    if command == "" then
        core:Fire("TOGGLE_UI")
    elseif command == "scan" then
        core:ScanAndReport()
    elseif command == "texte" then
        if rest == "" then
            core:Print("modele actuel : " .. tostring(EasyLootDB.announceTemplate))
        else
            EasyLootDB.announceTemplate = rest
            core:Print("modele du message : " .. rest)
        end
    elseif command == "cmd" then
        if rest == "" then
            core:Print("commande actuelle : " .. tostring(EasyLootDB.slashCommand))
        else
            EasyLootDB.slashCommand = rest
            core:Print("commande du mode slash : " .. rest)
        end
    elseif command == "mode" then
        if rest == "alerte" or rest == "raid" or rest == "slash" then
            EasyLootDB.sendMode = rest
            core:Print("mode d'envoi : " .. rest)
            if rest == "alerte" and not core:CanRaidWarn() then
                core:Print("|cffffd200Tu n'es ni chef de raid ni assistant :"
                    .. " l'alerte retombera sur le canal du raid.|r")
            end
        else
            core:Print("valeurs possibles : alerte (comme /rw), raid, slash")
        end
    elseif command == "lien" then
        EasyLootDB.announceUseLink = (rest == "on")
        core:Print("annonce du lien complet : " .. tostring(EasyLootDB.announceUseLink))
    elseif command == "duree" then
        local seconds = tonumber(rest)
        if seconds and seconds >= 5 and seconds <= 300 then
            EasyLootDB.rollSeconds = seconds
            core:Print("fenetre de jets : " .. seconds .. " s")
        else
            core:Print("valeur attendue entre 5 et 300 secondes.")
        end
    elseif command == "qualite" then
        core:Print("le filtre est fixe : objets epiques uniquement (qualite 4).")
        core:Scan()
    elseif command == "lies" then
        EasyLootDB.hideSoulbound = (rest ~= "on")
        core:Print("objets lies non echangeables affiches : "
            .. tostring(not EasyLootDB.hideSoulbound))
        core:ScanAndReport()
    elseif command == "echange" then
        if rest == "" then
            core:Print("phrase de repli actuelle : "
                .. tostring(EasyLootDB.tradePhrase))
            core:Print(TRADE_PREFIX
                and "|cff62d394Le client expose BIND_TRADE_TIME_REMAINING, cette phrase n'est pas utilisee.|r"
                or "|cffffd200Le client n'expose pas BIND_TRADE_TIME_REMAINING : la phrase ci-dessus sert de repli.|r")
        else
            EasyLootDB.tradePhrase = rest
            core:Print("phrase de repli : " .. rest)
            core:ScanAndReport()
        end
    elseif command == "verrous" then
        core:ClearLocks()
        core:Print("tous les verrous ont ete retires.")
    elseif command == "autotrade" then
        EasyLootDB.autoTrade = (rest ~= "off")
        core:Print("placement automatique dans l'echange : " .. tostring(EasyLootDB.autoTrade))
    elseif command == "historique" then
        if rest == "reset" then
            core:ClearHistory()
        else
            local history = EasyLootDB.history or {}
            if #history == 0 then
                core:Print("Aucune distribution enregistree.")
            else
                core:Print("Dernieres distributions :")
                for i = 1, math.min(10, #history) do
                    local entry = history[i]
                    core:Print("  " .. entry.time .. "  " .. entry.name
                        .. "  ->  " .. entry.recipient .. "  (" .. entry.method .. ")")
                end
            end
        end
    elseif command == "minimap" then
        EasyLootDB.minimapHide = (rest == "off")
        core:Print("icone minimap affichee : " .. tostring(not EasyLootDB.minimapHide))
        core:Fire("MINIMAP_CHANGED")
    elseif command == "debug" then
        EasyLootDB.debug = not EasyLootDB.debug
        core:Print("mode diagnostic : " .. tostring(EasyLootDB.debug))
    else
        ShowHelp()
    end
end
