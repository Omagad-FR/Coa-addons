-- EasyLoot 0.5.3 - capture des jets
-- made by Omagad
-- Client WoW 3.3.5a / Interface 30300
--
-- L'avertissement raid (/rw) affiche un texte, il ne lance aucun jet. Les
-- joueurs repondent donc avec un /roll ordinaire, et c'est CHAT_MSG_SYSTEM
-- qui porte le resultat -- source principale ici.
--
-- Deux sources, volontairement separees :
--   1. CHAT_MSG_SYSTEM : les /roll standards. Le format est lu dans la
--      globale RANDOM_ROLL_RESULT, donc valable quelle que soit la langue
--      du client.
--   2. les canaux de groupe, en appoint : un joueur qui ecrit son chiffre
--      au lieu de lancer /roll. Seules les formes non ambigues sont
--      acceptees ("85", "roll 85") pour eviter de compter une conversation
--      comme un jet ; desactivable par rollsFromChat.
--
-- /easyloot debug affiche tous les messages recus pendant une fenetre de
-- jets, au cas ou le serveur emploierait une forme inattendue.

local core = EasyLoot

--------------------------------------------------------------------------
-- Motif systeme construit depuis la globale du client
--------------------------------------------------------------------------

local function BuildSystemPattern(template)
    if not template then return nil end
    local escaped = template:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    escaped = escaped:gsub("%%%%s", "(.+)")
    escaped = escaped:gsub("%%%%d", "(%%d+)")
    return "^" .. escaped .. "$"
end

local SYSTEM_PATTERN = BuildSystemPattern(RANDOM_ROLL_RESULT)

-- Repli si la globale manque ou si sa forme resiste a la conversion :
-- "<nom> ... <valeur> (<min>-<max>)" couvre les locales connues.
local FALLBACK_PATTERN = "^(%S+).-(%d+)%s*%((%d+)%s*%-%s*(%d+)%)"

local function ParseSystemRoll(message)
    if SYSTEM_PATTERN then
        local name, value, minRoll, maxRoll = message:match(SYSTEM_PATTERN)
        if name then
            return name, tonumber(value), tonumber(minRoll), tonumber(maxRoll)
        end
    end
    local name, value, minRoll, maxRoll = message:match(FALLBACK_PATTERN)
    if name then
        return name, tonumber(value), tonumber(minRoll), tonumber(maxRoll)
    end
    return nil
end

--------------------------------------------------------------------------
-- Motifs de canal
--------------------------------------------------------------------------

local CHAT_PATTERNS = {
    "^%s*(%d+)%s*$",
    "^%s*[Rr][Oo][Ll][Ll]%s*:?%s*(%d+)%s*$",
    "^%s*(%d+)%s*[Rr][Oo][Ll][Ll]%s*$",
}

local function ParseChatRoll(message)
    for _, pattern in ipairs(CHAT_PATTERNS) do
        local value = message:match(pattern)
        if value then
            return tonumber(value)
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Ecoute
--------------------------------------------------------------------------

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_SYSTEM")
listener:RegisterEvent("CHAT_MSG_RAID")
listener:RegisterEvent("CHAT_MSG_RAID_LEADER")
listener:RegisterEvent("CHAT_MSG_RAID_WARNING")
listener:RegisterEvent("CHAT_MSG_PARTY")
listener:RegisterEvent("CHAT_MSG_PARTY_LEADER")

listener:SetScript("OnEvent", function(self, event, message, author)
    local session = core:GetSession()
    if not session or not session.open then return end
    if not message then return end

    -- Journal brut : sert uniquement au diagnostic, jamais au calcul.
    table.insert(session.raw, event .. " | " .. tostring(author) .. " | " .. message)
    core:Debug(event .. " | " .. tostring(author) .. " | " .. message)

    if event == "CHAT_MSG_SYSTEM" then
        local name, value, minRoll, maxRoll = ParseSystemRoll(message)
        if name and value then
            core:AddRoll(core:ShortName(name), value, minRoll, maxRoll, "systeme")
        end
        return
    end

    if not EasyLootDB.rollsFromChat then return end

    -- Un jet annonce par le serveur arrive sans auteur exploitable : dans ce
    -- cas seul le motif systeme peut l'identifier, on ne devine pas.
    if not author or author == "" then
        local name, value, minRoll, maxRoll = ParseSystemRoll(message)
        if name and value then
            core:AddRoll(core:ShortName(name), value, minRoll, maxRoll, "canal")
        end
        return
    end

    local value = ParseChatRoll(message)
    if value and value >= 1 and value <= 100 then
        core:AddRoll(core:ShortName(author), value, 1, 100, "canal")
    end
end)
