-- CoABuffManager 0.22.0 Audit
-- Client WoW 3.3.5a / Interface 30300
--
-- Fonctions :
--   1. conserve la matrice de lancement manuel des buffs personnels ;
--   2. detecte le nom, le token et l'ID des classes personnalisees CoA ;
--   3. permet de saisir manuellement les possibilites de buff par classe ;
--   4. compare les valeurs disponibles dans le groupe ;
--   5. affiche en vert la meilleure valeur disponible ;
--   6. audite le grimoire et enregistre les infobulles brutes.
--
-- Aucun sort n'est lance automatiquement.

local ADDON_NAME = "CoABuffManager"
local ADDON_VERSION = "0.22.3"
local PREFIX = "|cff66ccffCoABuffManager|r"

local DEFAULT_PERSONAL_SPELL_IDS = {
    712460, -- Greater Mark of Blaumeux
    680300, -- Greater Mark of Korth'azz
    803730, -- Greater Mark of Rivendare
    803731, -- Greater Mark of Zeliek
}

local MAX_MEMBERS = 40
-- Au-dela de ce nombre de membres dans le roster, l'overview n'affiche
-- plus qu'une colonne par membre de TA classe (voir RebuildOverviewPanel)
-- pour rester lisible en raid complet. Les conflits potentiels restent
-- verifies sur tout le raid quel que soit ce seuil.
local OVERVIEW_DISPLAY_ROSTER_THRESHOLD = 10
local MEMBER_WIDTH = 105
local LABEL_WIDTH = 190
local ROW_HEIGHT = 30
local OVERVIEW_ROW_HEIGHT = 50
local ACTION_WIDTH = 100
local OVERVIEW_ICON_SIZE = 32
local BUFF_WARNING_SECONDS = 300
-- New "will fade before we're likely done pulling" heads-up threshold,
-- requested explicitly as a wider/earlier tier than BUFF_WARNING_SECONDS:
-- red fires first at 10 minutes remaining (a heads-up to rebuff before a
-- long pull), then the existing orange tier still takes over at 5
-- minutes for the tighter, more urgent warning.
local BUFF_CRITICAL_SECONDS = 600
local BUFF_WARNING_SCAN_INTERVAL = 1

-- Main proposal view: keep useful stat/utility buffs, but hide resistances.
local OVERVIEW_CATEGORY_ORDER = {
    "STAMINA",
    "STRENGTH",
    "AGILITY",
    "INTELLECT",
    "SPIRIT",
    "TOTAL_STATS",
    "ATTACK_POWER",
    "ATTACK_POWER_PERCENT",
    "SPELL_POWER",
    "DAMAGE",
    "ARMOR",
    "CRITICAL_STRIKE",
    "SPELL_CRITICAL_STRIKE",
    "HASTE",
    "MELEE_RANGED_HASTE",
    "SPELL_HASTE",
    "HIT",
    "EXPERTISE",
    "ARMOR_PENETRATION",
    "MAGIC_DAMAGE",
    "MAGIC_DAMAGE_REDUCTION",
    "DAMAGE_REDUCTION",
    "CAST_PUSHBACK_REDUCTION",
    "RESOURCE_COST_REDUCTION",
    "MANA_REGEN",
    "HEALTH_REGEN",
    "HEALING_DONE",
}

local OVERVIEW_CATEGORY_PRIORITY = {}
for index, category in ipairs(OVERVIEW_CATEGORY_ORDER) do
    OVERVIEW_CATEGORY_PRIORITY[category] = index
end

local HIDDEN_OVERVIEW_CATEGORIES = {
    RETALIATION_DAMAGE = true,
}

-- Recommended specialization stats confirmed from the in-game Character
-- Advancement screen. Available for the local player directly, and for
-- remote group members once their specToken has been received via
-- CoABuffComm (see GetRoster/GetRecommendedStatsForMember).
local SPEC_RECOMMENDED_STATS = {
    FLESHWARDEN = {
        HELLFIRE = {
            STRENGTH = true,
            INTELLECT = true,
        },
        DEFIANCE = {
            STRENGTH = true,
            STAMINA = true,
        },
        WAR = {
            STRENGTH = true,
        },
    },
    CHRONOMANCER = {
        -- Confirmed in-game: Spirit is the best stat for all three specs,
        -- despite their different roles (Time = Healer, Infinite = Caster,
        -- Artificer = Ranged).
        TIME = {
            SPIRIT = true,
        },
        INFINITE = {
            SPIRIT = true,
        },
        ARTIFICER = {
            SPIRIT = true,
        },
    },
    PYROMANCER = {
        -- From the spec overview cards: Flameweaving is the Healer spec
        -- (Spirit), Incineration and Draconic are both Caster specs
        -- (Intellect).
        FLAMEWEAVING = {
            SPIRIT = true,
        },
        INCINERATION = {
            INTELLECT = true,
        },
        DRACONIC = {
            INTELLECT = true,
        },
    },
    -- Only Sanguine is confirmed so far (grants a Spirit group buff,
    -- consistent with a Healer-type spec) -- Accursed/Eternal/Fleshweaver
    -- not yet audited.
    SONOFARUGAL = {
        SANGUINE = {
            SPIRIT = true,
        },
    },
}

local RECOMMENDED_STAT_NAMES = {
    STAMINA = "Endurance",
    STRENGTH = "Force",
    AGILITY = "Agilite",
    INTELLECT = "Intelligence",
    SPIRIT = "Esprit",
}

-- French display names for the per-class buff tooltip (see
-- GetClassBuffSummaryLines). Deliberately separate from
-- RECOMMENDED_STAT_NAMES: that one only covers the 5 primary stats used by
-- the spec-recommendation feature, this one needs every effect key that
-- can appear in BuffDatabase.lua's `effects` tables.
local STAT_DISPLAY_NAMES = {
    STAMINA = "Endurance",
    STRENGTH = "Force",
    AGILITY = "Agilite",
    INTELLECT = "Intelligence",
    SPIRIT = "Esprit",
    ARMOR = "Armure",
    SPELL_POWER = "Puissance des sorts",
    ATTACK_POWER = "Puissance d'attaque",
    ATTACK_POWER_PERCENT = "Puissance d'attaque",
    CRITICAL_STRIKE = "Critique",
    MANA_REGEN = "Regen. de mana",
    HEALTH_REGEN = "Regen. de vie",
    RESOURCE_COST_REDUCTION = "Cout des ressources",
    CAST_PUSHBACK_REDUCTION = "Resist. au recul",
    MELEE_RANGED_HASTE = "Hate",
    TOTAL_STATS = "Stats totales",
    DAMAGE = "Degats",
    HEALING_DONE = "Soins prodigues",
}

-- Matches any "_RESISTANCE"/"_RESISTANCES" effect key (FROST_RESISTANCE,
-- ALL_RESISTANCES, ...).
local function IsResistanceCategory(category)
    return type(category) == "string"
        and string.match(category, "_RESISTANCES?$") ~= nil
end

-- French display names for resistance categories, used by
-- GetClassBuffSummaryLines to show which element is granted instead of a
-- generic "+ Resistance" tag.
local RESISTANCE_DISPLAY_NAMES = {
    FIRE_RESISTANCE = "Resist. Feu",
    FROST_RESISTANCE = "Resist. Givre",
    NATURE_RESISTANCE = "Resist. Nature",
    SHADOW_RESISTANCE = "Resist. Ombre",
    ARCANE_RESISTANCE = "Resist. Arcane",
    ALL_RESISTANCES = "Resist. (toutes)",
}

local function IsOverviewCategoryHidden(category)
    return type(category) == "string"
        and (
            HIDDEN_OVERVIEW_CATEGORIES[category]
            or string.match(category, "_RESISTANCE$") ~= nil
        )
end

-- The overview is a pre-buff planning screen. It shows both spells a
-- player can actively cast as a persistent buff (LONG_DURATION) and
-- always-on raid-wide auras (PASSIVE_AURA, e.g. Eternal Presence) so a
-- class's full known buff contribution is visible -- only temporary
-- combat cooldowns are excluded. See IsCastableForMacroSpell below for
-- the stricter check used when actually building /cast lines: a passive
-- aura has nothing to cast, so it must never end up in the BUFF THEM ALL
-- macro or get its own clickable cast button.
local function IsAutomaticOverviewSpellVisible(spell)
    return spell and (spell.kind == "LONG_DURATION" or spell.kind == "PASSIVE_AURA")
end

-- Stricter than IsAutomaticOverviewSpellVisible: only spells that are
-- actually worth issuing a /cast for (macro generation, per-category cast
-- buttons). Passive auras are informational-only -- see
-- IsAutomaticOverviewSpellVisible's comment.
local function IsCastableForMacroSpell(spell)
    return spell and spell.kind == "LONG_DURATION"
end

local mainFrame
local panels = {}
local activeTab = "overview"
local statusText
local pendingSecureRebuild = false
local RefreshOverviewCastStates
local RefreshTrackerHUD
local SetTrackerFrameLocked
local SetTrackerFrameOpacity
local SetMainFrameOpacity
local ApplyMainWindowBackground
local GetSameClassLockConflicts
local ShowBuffExpiryWarning
local GetFamilyAuraNames
local RefreshAllPanelsForRosterChange
-- Etat du cache de roster regroupe dans UNE table : ce fichier est a la limite
-- Lua 5.1 des 200 locales par scope, et cinq locals separes la faisaient
-- sauter. Declare ici car .Invalidate est appelee par du code defini AVANT
-- GetRoster (reception de donnees Comm, fin d'inspection).
local RosterCache = { list = nil, at = 0, ttl = 1.0 }
local RequestMacroRegeneration
local RebuildSettingsPanel

-- Namespace global volontaire : ce fichier est deja proche de la limite de
-- 200 variables locales de Lua 5.1. Le module regroupe l'affichage compact des
-- buffs natifs et le controle des buffs manquants sans ajouter de nouveaux
-- locals au scope principal.
CoABuffTray = CoABuffTray or {}

local castButtons = {}
local castLabels = {}
local castHeaders = {}

local overviewLabels = {}
local overviewMemberHoverFrames = {}
local overviewHeaders = {}
local overviewCastButtons = {}

local settingsLockLabels = {}
local settingsLocksScrollChild

-- The Greater and single-target variants can apply an aura from the same
-- family. Their button states must therefore not be inferred from the aura
-- name alone. This session state records which exact variant the local player
-- successfully cast.
local confirmedGroupCasts = {}
local groupSpellCategoriesByID = {}
local groupSpellCategoriesByName = {}
local individualSpellCategoriesByID = {}
local individualSpellCategoriesByName = {}
local warnedBuffExpirations = {}
local buffWarningElapsed = 0

local configMemberButtons = {}
local configEntryLines = {}
local configFields = {}
local auditTooltip

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " - " .. tostring(message))
end

local function Trim(value)
    value = tostring(value or "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function Upper(value)
    return string.upper(Trim(value))
end

local function EnsureDB()
    CoABuffManagerDB = CoABuffManagerDB or {}
    CoABuffManagerDB.spells = CoABuffManagerDB.spells or {}
    CoABuffManagerDB.catalog = CoABuffManagerDB.catalog or {}
    CoABuffManagerDB.position = CoABuffManagerDB.position or nil
    CoABuffManagerDB.audit = CoABuffManagerDB.audit or {}
    CoABuffManagerDB.audit.scans = CoABuffManagerDB.audit.scans or {}
    -- Separate from audit.scans (spellbook audits): a trainer scan reads
    -- the currently-open trainer window instead, which lists EVERY
    -- service including ones the character can't learn yet (greyed out,
    -- too low level). Its description tooltip usually states the exact
    -- level requirement and effect, which is exactly what's missing when
    -- a spellbook audit comes from a character below that level.
    CoABuffManagerDB.audit.trainerScans = CoABuffManagerDB.audit.trainerScans or {}

    -- A talent scan reads every INVESTED talent (currentRank > 0) across
    -- all talent tabs and captures its tooltip -- used to spot per-spec
    -- "boosts your class buffs by X%" talents (e.g. Felsworn's "Dark
    -- Teachings") that would otherwise make a spell's flat DB value wrong
    -- for characters who took it. Untaken talents aren't recorded: there's
    -- nothing to detect remotely for a talent nobody has invested in.
    CoABuffManagerDB.audit.talentScans = CoABuffManagerDB.audit.talentScans or {}

    -- macroLocks[family] = { mode = "GROUP" | "INDIVIDUAL", targets = { [name] = true, ... } }
    -- A family can only be locked in one mode at a time: locking a group
    -- buff for a family clears any individual targets for that same family,
    -- and vice versa, since applying both would be redundant (the group
    -- cast already covers everyone, including any individually-locked
    -- target of the same stat).
    CoABuffManagerDB.macroLocks = CoABuffManagerDB.macroLocks or {}

    -- minimap.angle is the button's position around the minimap ring (in
    -- degrees); minimap.hide lets the player turn the button off entirely
    -- (e.g. if they prefer the /cbm command or a macro) without losing the
    -- saved angle for whenever they turn it back on.
    CoABuffManagerDB.minimap = CoABuffManagerDB.minimap or {
        angle = 200,
        hide = false,
    }

    -- trackerHUD.mode is the player's visibility preference for the
    -- floating tracker: "auto" (hidden during combat, shown otherwise),
    -- "always" (stays up through combat as a read-only display), or
    -- "never" (fully off). trackerHUD.locked controls whether the
    -- background can be dragged to reposition it (see EnsureTrackerFrame
    -- and SetTrackerFrameLocked below). Both are set from the Reglages
    -- panel; "shown" below is a legacy field kept only for migration.
    CoABuffManagerDB.trackerHUD = CoABuffManagerDB.trackerHUD or {
        shown = true,
        point = nil,
    }
    -- mode replaces the old on/off "shown" flag with three states; migrate
    -- an existing shown=false (from before this option existed) into
    -- mode="never" so players who had hidden the HUD keep it hidden.
    if not CoABuffManagerDB.trackerHUD.mode then
        CoABuffManagerDB.trackerHUD.mode =
            (CoABuffManagerDB.trackerHUD.shown == false) and "never" or "auto"
    end
    if CoABuffManagerDB.trackerHUD.locked == nil then
        CoABuffManagerDB.trackerHUD.locked = true
    end
    CoABuffManagerDB.trackerHUD.opacity = CoABuffManagerDB.trackerHUD.opacity or 0.45

    -- Background opacity of the main /cbm window (Overview/Reglages),
    -- separate from the floating HUD's own opacity above. 1.0 = fully
    -- opaque dialog background (the original look), lower = more of the
    -- game world visible through it. Only the backdrop is affected --
    -- buttons and text stay fully readable.
    CoABuffManagerDB.mainWindowOpacity = CoABuffManagerDB.mainWindowOpacity or 1.0
    -- "parchment" (custom artwork background) or "black" (plain solid
    -- fill). Defaults to parchment now that the artwork exists; players
    -- who want the older plain-black look can switch back in Reglages.
    CoABuffManagerDB.mainWindowBackground = CoABuffManagerDB.mainWindowBackground or "parchment"

    -- Remplace visuellement la longue barre de buffs native par un seul bouton.
    -- Le cadre natif reste intact : il est simplement masque et redevient
    -- visible au survol, ce qui conserve les infobulles et le clic droit natifs.
    CoABuffManagerDB.buffTray = CoABuffManagerDB.buffTray or {}
    if CoABuffManagerDB.buffTray.enabled == nil then
        CoABuffManagerDB.buffTray.enabled = false
    end
    if CoABuffManagerDB.buffTray.showOnHover == nil then
        CoABuffManagerDB.buffTray.showOnHover = true
    end
    if CoABuffManagerDB.buffTray.groupBadge == nil then
        CoABuffManagerDB.buffTray.groupBadge = true
    end
    if CoABuffManagerDB.buffTray.buttonUnlocked == nil then
        CoABuffManagerDB.buffTray.buttonUnlocked = false
    end
    if CoABuffManagerDB.buffTray.hideMode == nil then
        -- "raid" masque les buffs de groupe/externes, "player" les effets
        -- personnels, et "both" conserve le comportement historique.
        CoABuffManagerDB.buffTray.hideMode = "both"
    end

    if CoABuffManagerDB.dataPolicyVersion ~= "0.5.1" then
        if next(CoABuffManagerDB.catalog) then
            CoABuffManagerDB.catalogBackup050 = CoABuffManagerDB.catalog
            CoABuffManagerDB.catalogResetNotice = true
        end
        CoABuffManagerDB.catalog = {}
        CoABuffManagerDB.dataPolicyVersion = "0.5.1"
    end
end

local function GetClassInfo(unit)
    local className, classToken, classID = UnitClass(unit)
    return {
        name = className or "Classe inconnue",
        token = classToken or "UNKNOWN",
        id = classID or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Macro lock system
-- ---------------------------------------------------------------------------
-- Right-clicking an overview cast button toggles a "lock" for that button's
-- family. A locked family is included when generating the BUFF THEM ALL
-- macro (see BuildMacroThenAll below). A family can only be locked in one
-- mode: GROUP (the party/raid-wide cast) or INDIVIDUAL (one or more named
-- targets), never both, since a group cast already covers any individually
-- locked target of the same family.

local function GetFamilyLock(family)
    if not family or not CoABuffManagerDB or not CoABuffManagerDB.macroLocks then
        return nil
    end
    return CoABuffManagerDB.macroLocks[family]
end

local function IsGroupLocked(family)
    local lock = GetFamilyLock(family)
    return lock ~= nil and lock.mode == "GROUP"
end

local function IsIndividualLocked(family, targetName)
    local lock = GetFamilyLock(family)
    if not lock or lock.mode ~= "INDIVIDUAL" or not targetName then
        return false
    end
    return lock.targets ~= nil and lock.targets[targetName] == true
end

-- Toggles the GROUP lock for a family. Locking the group mode clears any
-- individual targets previously locked for the same family (they would be
-- redundant once the group-wide cast is locked in).
-- Toggles the GROUP lock for a family. Only ONE family may be GROUP-locked
-- at a time across the whole database: the server only keeps a single
-- group-wide buff active per caster, regardless of family (casting a new
-- Greater spell replaces whichever Greater aura the caster had up before,
-- even if it was a different stat). Activating a GROUP lock therefore
-- clears any other family's GROUP lock first.
local function ToggleGroupLock(family)
    if not family then
        return
    end
    EnsureDB()

    local lock = CoABuffManagerDB.macroLocks[family]
    if lock and lock.mode == "GROUP" then
        CoABuffManagerDB.macroLocks[family] = nil
        Print("Verrou groupe retire pour " .. tostring(family) .. ".")
    else
        local replacedFamily = nil
        for otherFamily, otherLock in pairs(CoABuffManagerDB.macroLocks) do
            if otherFamily ~= family and otherLock.mode == "GROUP" then
                CoABuffManagerDB.macroLocks[otherFamily] = nil
                replacedFamily = otherFamily
            end
        end

        CoABuffManagerDB.macroLocks[family] = { mode = "GROUP", targets = {} }

        if replacedFamily then
            Print(
                "Verrou groupe active pour " .. tostring(family) ..
                " (remplace le verrou groupe de " .. tostring(replacedFamily) ..
                " : un seul buff de groupe peut rester actif a la fois)."
            )
        else
            Print("Verrou groupe active pour " .. tostring(family) .. ".")
        end
    end

    if RequestMacroRegeneration then
        RequestMacroRegeneration("verrou modifie")
        if RefreshTrackerHUD then RefreshTrackerHUD() end
    end

    if CoABuffComm and type(CoABuffComm.RequestAnnounce) == "function" then
        CoABuffComm.RequestAnnounce()
    end
end

-- Toggles the INDIVIDUAL lock for a family on a specific target name.
-- Switching a family from GROUP mode to an individual target on the same
-- family is allowed (it replaces the group lock), matching the rule that a
-- family can never have both modes active at once.
-- Enforces "one locked buff per player": removes targetName from every
-- OTHER family's individual lock before it gets added to a new one, so a
-- given recipient can never end up queued for two different categories
-- at once via individual locks. Returns the list of family names the
-- target was removed from, for the confirmation message.
local function ClearIndividualLockFromOtherFamilies(exceptFamily, targetName)
    local clearedFamilies = {}
    for otherFamily, otherLock in pairs(CoABuffManagerDB.macroLocks) do
        if otherFamily ~= exceptFamily
            and otherLock.mode == "INDIVIDUAL"
            and otherLock.targets
            and otherLock.targets[targetName] then

            otherLock.targets[targetName] = nil
            if not next(otherLock.targets) then
                CoABuffManagerDB.macroLocks[otherFamily] = nil
            end
            table.insert(clearedFamilies, otherFamily)
        end
    end
    return clearedFamilies
end

local function ToggleIndividualLock(family, targetName)
    if not family or not targetName then
        return
    end
    EnsureDB()

    local lock = CoABuffManagerDB.macroLocks[family]

    if lock and lock.mode == "GROUP" then
        -- Switching away from a group lock onto an individual target for
        -- the same family: start a fresh individual lock with just this
        -- target, rather than silently keeping the group lock active
        -- alongside it.
        local cleared = ClearIndividualLockFromOtherFamilies(family, targetName)
        CoABuffManagerDB.macroLocks[family] = {
            mode = "INDIVIDUAL",
            targets = { [targetName] = true },
        }
        local message = "Verrou groupe remplace par un verrou individuel (" ..
            tostring(targetName) .. ") pour " .. tostring(family) .. "."
        if #cleared > 0 then
            message = message .. " (retire aussi de " ..
                table.concat(cleared, ", ") ..
                " : un seul buff verrouille par joueur)."
        end
        Print(message)
    elseif lock and lock.mode == "INDIVIDUAL" and lock.targets[targetName] then
        lock.targets[targetName] = nil
        if not next(lock.targets) then
            CoABuffManagerDB.macroLocks[family] = nil
        end
        Print(
            "Verrou individuel retire pour " .. tostring(targetName) ..
            " (" .. tostring(family) .. ")."
        )
    else
        if not lock or lock.mode ~= "INDIVIDUAL" then
            lock = { mode = "INDIVIDUAL", targets = {} }
            CoABuffManagerDB.macroLocks[family] = lock
        end
        local cleared = ClearIndividualLockFromOtherFamilies(family, targetName)
        lock.targets[targetName] = true
        local message = "Verrou individuel active pour " .. tostring(targetName) ..
            " (" .. tostring(family) .. ")."
        if #cleared > 0 then
            message = message .. " Retire de " .. table.concat(cleared, ", ") ..
                " (un seul buff verrouille par joueur)."
        end
        Print(message)
    end

    if RequestMacroRegeneration then
        RequestMacroRegeneration("verrou modifie")
        if RefreshTrackerHUD then RefreshTrackerHUD() end
    end

    if CoABuffComm and type(CoABuffComm.RequestAnnounce) == "function" then
        CoABuffComm.RequestAnnounce()
    end
end

-- Same idea as ToggleIndividualLock, but acts on every roster member who
-- shares targetName's class at once, rather than just targetName alone.
-- Clicking one member of a class effectively says "let this class handle
-- it": every other player of that class currently in the group gets
-- locked onto the same family too (each still respecting the existing
-- "one buff per player" rule -- their own other individual locks get
-- cleared first, exactly as ToggleIndividualLock already does for a
-- single target). Clicking again (already locked) unlocks the whole
-- class from this family together. GROUP-mode locks are replaced with a
-- fresh INDIVIDUAL lock covering the class, same as ToggleIndividualLock.
local function ToggleClassIndividualLock(family, targetName, roster)
    if not family or not targetName then
        return
    end
    EnsureDB()

    local targetClassToken, targetClassName
    for _, m in ipairs(roster or {}) do
        if m.name == targetName then
            targetClassToken = m.classToken
            targetClassName = m.className
            break
        end
    end

    if not targetClassToken then
        -- Roster lookup failed for some reason -- fall back to the
        -- single-target behaviour rather than doing nothing.
        ToggleIndividualLock(family, targetName)
        return
    end

    local classmates = {}
    for _, m in ipairs(roster or {}) do
        if m.classToken == targetClassToken then
            table.insert(classmates, m.name)
        end
    end
    table.sort(classmates)

    local wasLocked = IsIndividualLocked(family, targetName)

    if wasLocked then
        local lock = CoABuffManagerDB.macroLocks[family]
        if lock and lock.mode == "INDIVIDUAL" and lock.targets then
            for _, name in ipairs(classmates) do
                lock.targets[name] = nil
            end
            if not next(lock.targets) then
                CoABuffManagerDB.macroLocks[family] = nil
            end
        end
        Print(
            "Verrou retire pour toute la classe " .. tostring(targetClassName) ..
            " (" .. tostring(family) .. ") : " .. table.concat(classmates, ", ") .. "."
        )
    else
        local wasGroupLocked = IsGroupLocked(family)
        local clearedFamilies = {}
        for _, name in ipairs(classmates) do
            for _, fam in ipairs(ClearIndividualLockFromOtherFamilies(family, name)) do
                clearedFamilies[fam] = true
            end
        end

        local lock = CoABuffManagerDB.macroLocks[family]
        if not lock or lock.mode ~= "INDIVIDUAL" then
            lock = { mode = "INDIVIDUAL", targets = {} }
            CoABuffManagerDB.macroLocks[family] = lock
        end
        for _, name in ipairs(classmates) do
            lock.targets[name] = true
        end

        local message = "Verrou individuel active pour toute la classe " ..
            tostring(targetClassName) .. " (" .. tostring(family) .. ") : " ..
            table.concat(classmates, ", ") .. "."
        if wasGroupLocked then
            message = message .. " (remplace le verrou groupe existant)."
        end
        local clearedList = {}
        for fam in pairs(clearedFamilies) do
            table.insert(clearedList, fam)
        end
        if #clearedList > 0 then
            table.sort(clearedList)
            message = message .. " Retire aussi de " .. table.concat(clearedList, ", ") ..
                " (un seul buff verrouille par joueur)."
        end
        Print(message)
    end

    if RequestMacroRegeneration then
        RequestMacroRegeneration("verrou de classe modifie")
        if RefreshTrackerHUD then RefreshTrackerHUD() end
    end

    if CoABuffComm and type(CoABuffComm.RequestAnnounce) == "function" then
        CoABuffComm.RequestAnnounce()
    end
end


-- current roster (left group, disconnected, etc.). Called on every
-- PARTY_MEMBERS_CHANGED/RAID_ROSTER_UPDATE so a verrou individuel never
-- lingers on someone who's gone -- if a family's targets all drop out
-- this way, the family lock itself is removed entirely (matches the
-- existing "empty targets => unlocked" rule used by ToggleIndividualLock).
-- GROUP-mode locks are untouched: they aren't tied to a specific person.
-- Returns true if anything changed, so callers know whether to refresh
-- the Reglages list / regenerate the macro.
local function PruneStaleLockTargets(roster)
    if not CoABuffManagerDB or not CoABuffManagerDB.macroLocks then
        return false
    end

    local present = {}
    for _, member in ipairs(roster or {}) do
        present[member.name] = true
    end

    local changed = false
    for family, lock in pairs(CoABuffManagerDB.macroLocks) do
        if lock.mode == "INDIVIDUAL" and lock.targets then
            for targetName in pairs(lock.targets) do
                if not present[targetName] then
                    lock.targets[targetName] = nil
                    changed = true
                end
            end
            if not next(lock.targets) then
                CoABuffManagerDB.macroLocks[family] = nil
            end
        end
    end

    return changed
end

local function GetActivePlayerSpecInfo()
    if not C_CharacterAdvancement
        or type(C_CharacterAdvancement.GetActiveChrSpec) ~= "function"
        or not C_ClassInfo
        or type(C_ClassInfo.GetSpecInfoByID) ~= "function" then
        return nil, nil
    end

    local okID, specID = pcall(C_CharacterAdvancement.GetActiveChrSpec)
    if not okID or not specID then
        return nil, nil
    end

    local okInfo, specInfo = pcall(C_ClassInfo.GetSpecInfoByID, specID)
    if not okInfo or not specInfo then
        return specID, nil
    end

    return specID, specInfo.Name or specInfo.name
end

-- CoABuffDatabase stores spec as an uppercase token with no punctuation
-- (e.g. "RIFTBLADE"), while the live API returns a display name (e.g.
-- "Riftblade"). This normalizes the latter into the former so a broadcast
-- specName (local or remote) can be compared against spell.spec.
local function NormalizeSpecToken(specName)
    if not specName or specName == "" then
        return nil
    end

    local token = string.upper(tostring(specName))
    token = string.gsub(token, "[^%w]", "")
    if token == "" then
        return nil
    end
    return token
end



-- ---------------------------------------------------------------------------
-- Audit du grimoire
-- ---------------------------------------------------------------------------

local function GetAuditTooltip()
    if auditTooltip then
        return auditTooltip
    end

    auditTooltip = CreateFrame(
        "GameTooltip",
        ADDON_NAME .. "AuditTooltip",
        UIParent,
        "GameTooltipTemplate"
    )
    auditTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    return auditTooltip
end

local function CaptureSpellTooltip(spellIndex, spellLink)
    local tooltip = GetAuditTooltip()
    tooltip:Hide()
    tooltip:ClearLines()
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")

    local ok = false
    if type(tooltip.SetSpellBookItem) == "function" then
        ok = pcall(
            tooltip.SetSpellBookItem,
            tooltip,
            spellIndex,
            BOOKTYPE_SPELL
        )
    end

    if (not ok or (tooltip:NumLines() or 0) == 0)
        and spellLink
        and type(tooltip.SetHyperlink) == "function" then

        tooltip:ClearLines()
        ok = pcall(tooltip.SetHyperlink, tooltip, spellLink)
    end

    if not ok then
        tooltip:Hide()
        return {}, "tooltip capture failed"
    end

    local lines = {}
    local tooltipName = tooltip:GetName()
    local lineCount = tooltip:NumLines() or 0

    for lineIndex = 1, lineCount do
        local leftRegion = _G[tooltipName .. "TextLeft" .. lineIndex]
        local rightRegion = _G[tooltipName .. "TextRight" .. lineIndex]
        local leftText = leftRegion and leftRegion:GetText() or nil
        local rightText = rightRegion and rightRegion:GetText() or nil

        if leftText or rightText then
            table.insert(lines, {
                left = leftText or "",
                right = rightText or "",
            })
        end
    end

    tooltip:Hide()
    return lines, nil
end

local function GetCurrentAuditKey()
    local playerName = UnitName("player") or "UnknownPlayer"
    local realmName = GetRealmName and GetRealmName() or "UnknownRealm"
    local classInfo = GetClassInfo("player")
    local specID, specName = GetActivePlayerSpecInfo()

    local key = table.concat({
        realmName,
        playerName,
        classInfo.token or "UNKNOWN",
        tostring(specID or "NOSPEC"),
    }, "|")

    return key, {
        playerName = playerName,
        realmName = realmName,
        className = classInfo.name,
        classToken = classInfo.token,
        classID = classInfo.id,
        level = UnitLevel("player") or 0,
        specID = specID,
        specName = specName,
    }
end

local function ScanSpellbook()
    EnsureDB()

    if InCombatLockdown and InCombatLockdown() then
        Print("Audit impossible pendant le combat.")
        return false
    end

    local scanKey, identity = GetCurrentAuditKey()
    local version, build, buildDate, interface = GetBuildInfo()
    local scan = {
        schemaVersion = 1,
        addonVersion = ADDON_VERSION,
        scannedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(time()),
        locale = GetLocale and GetLocale() or "unknown",
        client = {
            version = version,
            build = build,
            buildDate = buildDate,
            interface = interface,
        },
        character = identity,
        tabs = {},
        spells = {},
        errors = {},
    }

    local tabCount = GetNumSpellTabs and GetNumSpellTabs() or 0

    for tabIndex = 1, tabCount do
        local tabName, tabTexture, offset, spellCount = GetSpellTabInfo(tabIndex)
        offset = tonumber(offset) or 0
        spellCount = tonumber(spellCount) or 0

        table.insert(scan.tabs, {
            index = tabIndex,
            name = tabName or "",
            texture = tabTexture,
            offset = offset,
            spellCount = spellCount,
        })

        for spellIndex = offset + 1, offset + spellCount do
            local spellName, spellRank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
            local link = GetSpellLink and GetSpellLink(spellIndex, BOOKTYPE_SPELL)
            local spellID = link and tonumber(string.match(link, "spell:(%-?%d+)"))
            local passive = false

            if IsPassiveSpell then
                local okPassive, passiveResult = pcall(
                    IsPassiveSpell,
                    spellIndex,
                    BOOKTYPE_SPELL
                )
                passive = okPassive and passiveResult and true or false
            end

            local infoName, infoRank, icon, powerCost, isFunnel,
                powerType, castTime, minRange, maxRange

            local spellLookup = spellID or spellName
            if GetSpellInfo and spellLookup then
                infoName, infoRank, icon, powerCost, isFunnel,
                    powerType, castTime, minRange, maxRange =
                    GetSpellInfo(spellLookup)
            end

            local tooltipLines, tooltipError = CaptureSpellTooltip(spellIndex, link)

            if tooltipError then
                table.insert(scan.errors, {
                    spellIndex = spellIndex,
                    spellID = spellID,
                    error = tooltipError,
                })
            end

            table.insert(scan.spells, {
                spellbookIndex = spellIndex,
                tabIndex = tabIndex,
                tabName = tabName or "",
                spellID = spellID,
                name = spellName or infoName or "",
                rank = spellRank or infoRank or "",
                link = link,
                passive = passive,
                icon = icon,
                powerCost = powerCost,
                powerType = powerType,
                castTime = castTime,
                minRange = minRange,
                maxRange = maxRange,
                isFunnel = isFunnel and true or false,
                tooltip = tooltipLines,
            })
        end
    end

    scan.totalTabs = #scan.tabs
    scan.totalSpells = #scan.spells
    scan.totalErrors = #scan.errors
    CoABuffManagerDB.audit.scans[scanKey] = scan
    CoABuffManagerDB.audit.lastScanKey = scanKey

    Print(
        "Audit termine : " .. tostring(scan.totalSpells) ..
        " sorts, " .. tostring(scan.totalTabs) .. " onglets, " ..
        tostring(scan.totalErrors) .. " erreur(s)."
    )
    Print(
        "Spec : " .. tostring(identity.specName or "inconnue") ..
        " (ID " .. tostring(identity.specID or "?") .. ")."
    )
    Print("Execute /reload avant de copier CoABuffManager.lua depuis SavedVariables.")
    return true
end

-- Captures the description tooltip for one trainer service entry the
-- same way CaptureSpellTooltip does for a spellbook entry -- same
-- left/right line table shape, so both kinds of scan can be read with
-- the same downstream tooling.
local function CaptureTrainerServiceTooltip(serviceIndex)
    local tooltip = GetAuditTooltip()
    tooltip:Hide()
    tooltip:ClearLines()
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")

    local ok = false
    if type(tooltip.SetTrainerService) == "function" then
        ok = pcall(tooltip.SetTrainerService, tooltip, serviceIndex)
    end

    if not ok then
        tooltip:Hide()
        return {}, "tooltip capture failed"
    end

    local lines = {}
    local tooltipName = tooltip:GetName()
    local lineCount = tooltip:NumLines() or 0

    for lineIndex = 1, lineCount do
        local leftRegion = _G[tooltipName .. "TextLeft" .. lineIndex]
        local rightRegion = _G[tooltipName .. "TextRight" .. lineIndex]
        local leftText = leftRegion and leftRegion:GetText() or nil
        local rightText = rightRegion and rightRegion:GetText() or nil

        if leftText or rightText then
            table.insert(lines, {
                left = leftText or "",
                right = rightText or "",
            })
        end
    end

    tooltip:Hide()
    return lines, nil
end

-- Reads every entry (including greyed-out/unlearnable ones) from the
-- CURRENTLY OPEN trainer window -- GetNumTrainerServices/GetTrainerServiceInfo
-- only return meaningful data while a trainer interaction is active, so
-- this must be run with the trainer frame open (e.g. right after taking
-- the screenshot you'd normally read the level requirement from by eye).
-- Unlike a spellbook audit, this surfaces "Greater X" (or any high-rank)
-- service's exact level requirement and effect even on a character too
-- low level to have learned it yet.
local function ScanTrainer()
    EnsureDB()

    if InCombatLockdown and InCombatLockdown() then
        Print("Audit du formateur impossible pendant le combat.")
        return false
    end

    local serviceCount = GetNumTrainerServices and GetNumTrainerServices() or 0
    if serviceCount == 0 then
        Print("Aucun formateur ouvert (ou aucun service liste). Ouvre la fenetre du formateur d'abord.")
        return false
    end

    local scanKey, identity = GetCurrentAuditKey()
    local version, build, buildDate, interface = GetBuildInfo()
    local trainerName = TrainerFrameNpcNameText and TrainerFrameNpcNameText:GetText() or nil

    local scan = {
        schemaVersion = 1,
        addonVersion = ADDON_VERSION,
        scannedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(time()),
        locale = GetLocale and GetLocale() or "unknown",
        client = {
            version = version,
            build = build,
            buildDate = buildDate,
            interface = interface,
        },
        character = identity,
        trainerName = trainerName,
        services = {},
        errors = {},
    }

    for serviceIndex = 1, serviceCount do
        local name, subText, serviceType, isExpanded =
            GetTrainerServiceInfo(serviceIndex)
        local cost = GetTrainerServiceCost and GetTrainerServiceCost(serviceIndex)
        local icon = GetTrainerServiceIcon and GetTrainerServiceIcon(serviceIndex)

        -- Section header rows ("General", "Slayer", etc.) have no
        -- description tooltip of their own -- skip capturing one instead
        -- of recording a spurious "error" for every header in the list.
        local tooltipLines, tooltipError = {}, nil
        if serviceType ~= "header" then
            tooltipLines, tooltipError = CaptureTrainerServiceTooltip(serviceIndex)
        end
        if tooltipError then
            table.insert(scan.errors, {
                serviceIndex = serviceIndex,
                name = name,
                error = tooltipError,
            })
        end

        table.insert(scan.services, {
            serviceIndex = serviceIndex,
            name = name or "",
            subText = subText or "",
            serviceType = serviceType or "",
            isExpanded = isExpanded and true or false,
            cost = cost,
            icon = icon,
            tooltip = tooltipLines,
        })
    end

    scan.totalServices = #scan.services
    scan.totalErrors = #scan.errors
    CoABuffManagerDB.audit.trainerScans[scanKey] = scan
    CoABuffManagerDB.audit.lastTrainerScanKey = scanKey

    Print(
        "Audit du formateur termine : " .. tostring(scan.totalServices) ..
        " service(s)" ..
        (trainerName and (" chez " .. trainerName) or "") ..
        ", " .. tostring(scan.totalErrors) .. " erreur(s)."
    )
    Print("Execute /reload avant de copier CoABuffManager.lua depuis SavedVariables.")
    return true
end

-- Captures the description tooltip for one invested talent, same
-- left/right line table shape as CaptureSpellTooltip/CaptureTrainerServiceTooltip
-- so all three kinds of scan read the same way downstream.
local function CaptureTalentTooltip(tabIndex, talentIndex)
    local tooltip = GetAuditTooltip()
    tooltip:Hide()
    tooltip:ClearLines()
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")

    local ok = false
    if type(tooltip.SetTalent) == "function" then
        ok = pcall(tooltip.SetTalent, tooltip, tabIndex, talentIndex)
    end

    if not ok then
        tooltip:Hide()
        return {}, "tooltip capture failed"
    end

    local lines = {}
    local tooltipName = tooltip:GetName()
    local lineCount = tooltip:NumLines() or 0

    for lineIndex = 1, lineCount do
        local leftRegion = _G[tooltipName .. "TextLeft" .. lineIndex]
        local rightRegion = _G[tooltipName .. "TextRight" .. lineIndex]
        local leftText = leftRegion and leftRegion:GetText() or nil
        local rightText = rightRegion and rightRegion:GetText() or nil

        if leftText or rightText then
            table.insert(lines, {
                left = leftText or "",
                right = rightText or "",
            })
        end
    end

    tooltip:Hide()
    return lines, nil
end

-- talent_id -> {name, spellId} pour les 4 arbres de Knight of Xoroth
-- (156 entrees, sans collision de talent_id entre arbres), extrait de
-- kox_talents.json (issu d'un scan anterieur reussi de l'arbre de talents).
-- Necessaire car GetInspectedBuild ci-dessous ne renvoie que EntryId+Rank,
-- pas de nom ni de spell ID -- cette table fait le lien pour Knight of
-- Xoroth specifiquement. A etendre avec le meme format pour les autres
-- classes custom si besoin un jour (structure identique, juste une autre
-- table de lookup selectionnee sur classFile).
local KOX_TALENT_LOOKUP = {
    [30176] = { name = "Chainwhip", spellId = 800081 },
    [7099] = { name = "Suffuse", spellId = 801063 },
    [30668] = { name = "Chains of Malice", spellId = 803185 },
    [29437] = { name = "Xorothian Strength", spellId = 300382 },
    [7360] = { name = "Demonfire Plating", spellId = 704966 },
    [29610] = { name = "War Pig", spellId = 705020 },
    [34094] = { name = "Spiked Chains", spellId = 704987 },
    [34064] = { name = "Boiling Blood", spellId = 300395 },
    [34075] = { name = "Suffusion of Essence", spellId = 706566 },
    [7364] = { name = "Bloodied Blade", spellId = 800997 },
    [30701] = { name = "Black Shield", spellId = 805679 },
    [34114] = { name = "Omen of Rage", spellId = 706590 },
    [31701] = { name = "Demon Heart", spellId = 805669 },
    [30178] = { name = "Brimstone's Blood", spellId = 300387 },
    [34074] = { name = "Ragefist", spellId = 300384 },
    [7365] = { name = "Hell Blender", spellId = 704975 },
    [34117] = { name = "Darkrider", spellId = 704980 },
    [7359] = { name = "Demonic Rage", spellId = 524922 },
    [30016] = { name = "Juggernaut", spellId = 520294 },
    [6393] = { name = "Hellstriker", spellId = 704991 },
    [34112] = { name = "Burning Rage", spellId = 520295 },
    [34060] = { name = "Demonskin", spellId = 302581 },
    [5453] = { name = "Hellbound Charge", spellId = 807247 },
    [34071] = { name = "Dismemberment", spellId = 705018 },
    [7366] = { name = "Warpath", spellId = 805793 },
    [34096] = { name = "Hellbreaker", spellId = 680216 },
    [7885] = { name = "Xorothian Finesse", spellId = 300385 },
    [12620] = { name = "Mounted Reaver", spellId = 707835 },
    [29620] = { name = "Mounted Champion", spellId = 706295 },
    [7363] = { name = "Taskmaster", spellId = 500003 },
    [34069] = { name = "Rage of Xoroth", spellId = 300376 },
    [34090] = { name = "Heart of Xoroth", spellId = 704956 },
    [29623] = { name = "Brute Strength", spellId = 680723 },
    [34091] = { name = "Harbinger of Pestilence", spellId = 704182 },
    [30013] = { name = "Dread", spellId = 706502 },
    [30695] = { name = "Xorothian Sigil", spellId = 801061 },
    [6394] = { name = "Chain Warden", spellId = 704185 },
    [30229] = { name = "Shieldgore", spellId = 301302 },
    [4018] = { name = "Brimstone Buckler", spellId = 92104 },
    [30236] = { name = "Call: Hellfire Imp", spellId = 804883 },
    [30235] = { name = "A Gift from Hell", spellId = 300390 },
    [34085] = { name = "Impcaller", spellId = 706755 },
    [6679] = { name = "Imp Gang Boss", spellId = 706754 },
    [6620] = { name = "Hellsmelted Armor", spellId = 706569 },
    [9878] = { name = "Imp Guards", spellId = 804340 },
    [30237] = { name = "Bulwark of Xoroth", spellId = 300388 },
    [29329] = { name = "Warden of Hellfire", spellId = 704986 },
    [6928] = { name = "Hellfire Forgemaster", spellId = 560655 },
    [6392] = { name = "Sacrificial Circle", spellId = 805677 },
    [9485] = { name = "Demonfire Retaliation", spellId = 573034 },
    [6619] = { name = "Hellish Rebuke", spellId = 300391 },
    [34132] = { name = "Implosion", spellId = 524897 },
    [34077] = { name = "Hellfire Reprimand", spellId = 706565 },
    [5392] = { name = "Soul Furnace", spellId = 706758 },
    [9260] = { name = "Hellfire Resolve", spellId = 573035 },
    [6391] = { name = "Demon's Breath", spellId = 706563 },
    [6860] = { name = "Demonfire Command", spellId = 707028 },
    [6681] = { name = "Infernal Bulwark", spellId = 706564 },
    [34079] = { name = "Stoke the Flames", spellId = 704973 },
    [31086] = { name = "Speed Demon", spellId = 707232 },
    [34086] = { name = "Brimstone Knight", spellId = 704972 },
    [30699] = { name = "Chains of Xoroth", spellId = 706756 },
    [34087] = { name = "Pestilent Retaliation", spellId = 704971 },
    [29625] = { name = "Forgefiend's Bulwark", spellId = 801065 },
    [9258] = { name = "Imp Aura", spellId = 560546 },
    [34097] = { name = "Hellfire Sieger", spellId = 560828 },
    [29624] = { name = "Brimstone Striker", spellId = 807144 },
    [31079] = { name = "Demolisher", spellId = 807336 },
    [7887] = { name = "Hellfire Bellows", spellId = 807587 },
    [30124] = { name = "Black Skull Shield", spellId = 804354 },
    [30700] = { name = "Demonic Grit", spellId = 805678 },
    [34076] = { name = "Fiend of Forges", spellId = 300386 },
    [30125] = { name = "Hellwrath", spellId = 804014 },
    [30177] = { name = "Curse of Xoroth", spellId = 804169 },
    [29615] = { name = "Fiery Retribution", spellId = 804013 },
    [12765] = { name = "Demonic Bulwark", spellId = 573066 },
    [30498] = { name = "Call: Hellfire Abyssal", spellId = 805074 },
    [7367] = { name = "A Curse from Hell", spellId = 302548 },
    [30428] = { name = "Legion's Presence", spellId = 804879 },
    [31167] = { name = "Hellmaw", spellId = 806965 },
    [4017] = { name = "Greater Imp", spellId = 92101 },
    [6519] = { name = "Combusting Blade", spellId = 704999 },
    [30691] = { name = "Invasion", spellId = 300374 },
    [30697] = { name = "Pestilence of Apocalypse", spellId = 804786 },
    [30709] = { name = "Seeking Flame", spellId = 805671 },
    [11256] = { name = "Burning Power", spellId = 500004 },
    [34110] = { name = "To Ashes", spellId = 705000 },
    [34107] = { name = "Hellfire Embers", spellId = 807669 },
    [34068] = { name = "Flamewrath", spellId = 301358 },
    [34067] = { name = "Claws of Hell", spellId = 805706 },
    [34111] = { name = "Calamity", spellId = 300393 },
    [34066] = { name = "Hellfire Form", spellId = 805696 },
    [34108] = { name = "Doom", spellId = 802602 },
    [29619] = { name = "Seething Strikes", spellId = 300375 },
    [30706] = { name = "Cinderblade", spellId = 704959 },
    [7361] = { name = "Rain of Chaos", spellId = 704452 },
    [34063] = { name = "Grotesque", spellId = 707515 },
    [9257] = { name = "Hellfire Rituals", spellId = 500551 },
    [6929] = { name = "Infernal Steel", spellId = 805693 },
    [30393] = { name = "Indiscriminate", spellId = 704958 },
    [34105] = { name = "Inferno Blast", spellId = 805697 },
    [34109] = { name = "Infernal Pummeling", spellId = 680900 },
    [34098] = { name = "Hellbringer", spellId = 300963 },
    [30714] = { name = "Xorothian Empowerment", spellId = 704994 },
    [6859] = { name = "Infernal Pursuit", spellId = 704992 },
    [4706] = { name = "Impish Pestilence", spellId = 300398 },
    [30704] = { name = "Unbound Inferno", spellId = 704997 },
    [12607] = { name = "Partners in Flames", spellId = 500578 },
    [12179] = { name = "Brimstone Flames", spellId = 807671 },
    [30179] = { name = "Brimstone Splinters", spellId = 805703 },
    [34099] = { name = "Shadowflame Forge", spellId = 704989 },
    [30707] = { name = "Into the Maw", spellId = 802619 },
    [30713] = { name = "Punisher", spellId = 704988 },
    [11106] = { name = "Evil Duo", spellId = 704961 },
    [34100] = { name = "Hellstorm", spellId = 802342 },
    [30710] = { name = "Ascended Warlock", spellId = 802610 },
    [1710] = { name = "Fury of Xoroth", spellId = 802615 },
    [12166] = { name = "Warbringer", spellId = 570727 },
    [4016] = { name = "Crusher", spellId = 92100 },
    [31166] = { name = "Gore", spellId = 805555 },
    [34127] = { name = "Mutilation", spellId = 805695 },
    [6936] = { name = "Gored", spellId = 705015 },
    [7881] = { name = "Consuming Blade", spellId = 707388 },
    [11261] = { name = "Ripper", spellId = 706331 },
    [7408] = { name = "Fiend", spellId = 705005 },
    [30694] = { name = "Hellfire Striker", spellId = 573036 },
    [29621] = { name = "Pestilence of Death", spellId = 801054 },
    [7889] = { name = "Burning Blade", spellId = 524920 },
    [30463] = { name = "Burning Blade", spellId = 572370 },
    [7888] = { name = "Absolutism", spellId = 706501 },
    [6518] = { name = "Bringer of Destruction", spellId = 681449 },
    [34059] = { name = "Boundless Fury", spellId = 704954 },
    [30705] = { name = "Carver", spellId = 707390 },
    [31259] = { name = "Murderous Might", spellId = 520290 },
    [7810] = { name = "Decimation", spellId = 524913 },
    [7883] = { name = "Screamin' Demon", spellId = 804947 },
    [12817] = { name = "Burning Swings", spellId = 707632 },
    [34125] = { name = "Hellsmelted", spellId = 705016 },
    [34119] = { name = "Hand of Doom", spellId = 704186 },
    [7929] = { name = "Conqueror's Will", spellId = 520372 },
    [11890] = { name = "Hellborn", spellId = 707631 },
    [11212] = { name = "Chop Shop", spellId = 704953 },
    [9262] = { name = "Render", spellId = 704951 },
    [34056] = { name = "Domination", spellId = 704979 },
    [34104] = { name = "Hook, Line, and Sinker", spellId = 680991 },
    [29280] = { name = "Demonic Frenzy", spellId = 705008 },
    [6360] = { name = "Jagged Edge", spellId = 707614 },
    [6906] = { name = "Knight of Pestilence", spellId = 704981 },
    [7892] = { name = "The Butcher", spellId = 704952 },
    [7891] = { name = "Brimstone Bludgeon", spellId = 800710 },
    [34061] = { name = "Blood Frenzy", spellId = 520008 },
    [34058] = { name = "Pestilence Unbound", spellId = 560633 },
    [4217] = { name = "Knight of the Apocalypse", spellId = 520296 },
    [29519] = { name = "Demonic Blade", spellId = 704957 },
    [29376] = { name = "Gorged", spellId = 680199 },
    [34120] = { name = "Hellknight", spellId = 800702 },
}

-- CAO (Character Advancement Overhaul) : les classes custom d'Ascension
-- (Knight of Xoroth confirme, probablement les autres classes non-Blizzard
-- aussi) n'ont AUCUN onglet dans l'API de talents vanilla -- GetNumTalentTabs()
-- renvoie 0 pour ces personnages, d'ou l'echec "API absente ou personnage
-- non pret" de ScanTalents() ci-dessous, meme en plein ecran de talents
-- (confirme : l'utilisateur a l'ecran Character Advancement ouvert quand
-- l'erreur tombe).
--
-- Premiere version de ce chemin CAO utilisait CHARACTER_ADVANCEMENT_
-- CLASS_SPEC_ORDER + GetTalentsByClass (le pattern "classe par defaut" de
-- AscensionLogsCompanion/Capture/CAOScan.lua) -- ECHEC CONFIRME EN JEU :
-- diagnostic a montre que CASO ne connait que les 10 classes Blizzard
-- standard (DEATHKNIGHT, DRUID, HUNTER, MAGE, PALADIN, PRIEST, ROGUE,
-- SHAMAN, WARLOCK, WARRIOR), pas FLESHWARDEN (Knight of Xoroth). CAOScan.lua
-- gere pourtant deja ce cas : sa branche "isHero or not isDefault" utilise
-- GetInspectedBuild(unit, activeSpec) a la place, qui renvoie directement
-- les entrees investies (EntryId + Rank) sans passer par dbcClass/dbcSpec.
-- C'est cette branche qu'on porte ici -- toujours non testee en jeu, mais
-- la piste precedente est maintenant positivement exclue plutot que
-- supposee.
local function ScanTalentsCAO(scanKey, identity)
    local api = _G.C_CharacterAdvancement
    if not api or type(api.GetActiveSpecID) ~= "function" then
        Print("Impossible de lire les talents (API CAO absente non plus).")
        return false
    end

    local ok, activeSpec = pcall(api.GetActiveSpecID)
    if not ok or not activeSpec then
        Print("Impossible de lire les talents (spec CAO introuvable).")
        return false
    end

    if type(api.GetInspectedBuild) ~= "function" then
        Print("Impossible de lire les talents (GetInspectedBuild absente de l'API CAO).")
        return false
    end

    local bok, entries = pcall(api.GetInspectedBuild, "player", activeSpec)
    if not bok or type(entries) ~= "table" then
        Print("Impossible de lire les talents (GetInspectedBuild a echoue pour 'player').")
        return false
    end

    local _, classFile = UnitClass("player")
    local lookup = (classFile == "FLESHWARDEN") and KOX_TALENT_LOOKUP or nil

    local scan = {
        schemaVersion = 1,
        addonVersion = ADDON_VERSION,
        scannedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(time()),
        locale = GetLocale and GetLocale() or "unknown",
        character = identity,
        tabs = {},
        talents = {},
        errors = {},
        cao = true,
    }

    for _, entry in ipairs(entries) do
        if entry and entry.EntryId and type(entry.Rank) == "number" and entry.Rank > 0 then
            local info = lookup and lookup[entry.EntryId]
            local name = (info and info.name) or ("entry_" .. tostring(entry.EntryId))
            local spellId = info and info.spellId
            local tooltipLines, tooltipError = {}, "no spell id (unknown class or missing from lookup)"

            if spellId then
                local tooltip = GetAuditTooltip()
                tooltip:Hide()
                tooltip:ClearLines()
                tooltip:SetOwner(UIParent, "ANCHOR_NONE")
                local sok = type(tooltip.SetSpellByID) == "function"
                    and pcall(tooltip.SetSpellByID, tooltip, spellId)
                if sok then
                    tooltipError = nil
                    local tooltipName = tooltip:GetName()
                    for lineIndex = 1, (tooltip:NumLines() or 0) do
                        local leftRegion = _G[tooltipName .. "TextLeft" .. lineIndex]
                        local rightRegion = _G[tooltipName .. "TextRight" .. lineIndex]
                        local leftText = leftRegion and leftRegion:GetText() or nil
                        local rightText = rightRegion and rightRegion:GetText() or nil
                        if leftText or rightText then
                            table.insert(tooltipLines, { left = leftText or "", right = rightText or "" })
                        end
                    end
                else
                    tooltipError = "SetSpellByID failed"
                end
                tooltip:Hide()
            end

            if tooltipError then
                table.insert(scan.errors, { name = name, entryId = entry.EntryId, error = tooltipError })
            end

            table.insert(scan.talents, {
                entryId = entry.EntryId,
                name = name,
                currentRank = entry.Rank,
                spellId = spellId,
                tooltip = tooltipLines,
            })
        end
    end

    scan.totalTalents = #scan.talents
    scan.totalErrors = #scan.errors
    CoABuffManagerDB.audit.talentScans[scanKey] = scan
    CoABuffManagerDB.audit.lastTalentScanKey = scanKey

    Print(
        "Audit des talents (CAO) termine : " .. tostring(scan.totalTalents) ..
        " talent(s) investi(s), " .. tostring(scan.totalErrors) .. " erreur(s)."
    )
    Print("Execute /reload avant de copier CoABuffManager.lua depuis SavedVariables.")
    return true
end

-- Reads every INVESTED talent (currentRank > 0, any tab) and captures its
-- tooltip. Discovery tool: doesn't assume which talent (if any) boosts a
-- class's buffs by a percentage -- just dumps everything the character
-- has actually spent points in, so a "% "/buff-family keyword can be
-- spotted by eye in the printed list (see /cbm talentscans) without
-- needing to already know the talent's name ahead of time.
local function ScanTalents()
    EnsureDB()

    if InCombatLockdown and InCombatLockdown() then
        Print("Audit des talents impossible pendant le combat.")
        return false
    end

    local tabCount = GetNumTalentTabs and GetNumTalentTabs() or 0
    if tabCount == 0 then
        local scanKey, identity = GetCurrentAuditKey()
        return ScanTalentsCAO(scanKey, identity)
    end

    local scanKey, identity = GetCurrentAuditKey()
    local version, build, buildDate, interface = GetBuildInfo()

    local scan = {
        schemaVersion = 1,
        addonVersion = ADDON_VERSION,
        scannedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(time()),
        locale = GetLocale and GetLocale() or "unknown",
        client = {
            version = version,
            build = build,
            buildDate = buildDate,
            interface = interface,
        },
        character = identity,
        tabs = {},
        talents = {},
        errors = {},
    }

    for tabIndex = 1, tabCount do
        local tabName, tabIcon, pointsSpent = GetTalentTabInfo(tabIndex)

        table.insert(scan.tabs, {
            index = tabIndex,
            name = tabName or "",
            icon = tabIcon,
            pointsSpent = tonumber(pointsSpent) or 0,
        })

        local talentCount = GetNumTalents and GetNumTalents(tabIndex) or 0

        for talentIndex = 1, talentCount do
            local name, icon, tier, column, currentRank, maxRank =
                GetTalentInfo(tabIndex, talentIndex)

            if currentRank and currentRank > 0 then
                local tooltipLines, tooltipError =
                    CaptureTalentTooltip(tabIndex, talentIndex)

                if tooltipError then
                    table.insert(scan.errors, {
                        tabIndex = tabIndex,
                        talentIndex = talentIndex,
                        name = name,
                        error = tooltipError,
                    })
                end

                table.insert(scan.talents, {
                    tabIndex = tabIndex,
                    tabName = tabName or "",
                    talentIndex = talentIndex,
                    tier = tier,
                    column = column,
                    name = name or "",
                    icon = icon,
                    currentRank = currentRank,
                    maxRank = maxRank,
                    tooltip = tooltipLines,
                })
            end
        end
    end

    scan.totalTalents = #scan.talents
    scan.totalErrors = #scan.errors
    CoABuffManagerDB.audit.talentScans[scanKey] = scan
    CoABuffManagerDB.audit.lastTalentScanKey = scanKey

    Print(
        "Audit des talents termine : " .. tostring(scan.totalTalents) ..
        " talent(s) investi(s), " .. tostring(scan.totalErrors) .. " erreur(s)."
    )
    Print(
        "Spec : " .. tostring(identity.specName or "inconnue") ..
        " (ID " .. tostring(identity.specID or "?") .. ")."
    )
    Print("Execute /reload avant de copier CoABuffManager.lua depuis SavedVariables.")
    return true
end

local function ListTrainerScans()
    EnsureDB()

    local scans = CoABuffManagerDB.audit.trainerScans
    local keys = {}
    for key in pairs(scans) do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        Print("Aucun audit de formateur enregistre.")
        return
    end

    Print(tostring(#keys) .. " audit(s) de formateur enregistre(s) :")
    for _, key in ipairs(keys) do
        local scan = scans[key]
        local character = scan.character or {}
        Print(
            tostring(character.playerName or "?") ..
            " | " .. tostring(character.className or character.classToken or "?") ..
            " | " .. tostring(scan.trainerName or "formateur inconnu") ..
            " | services=" .. tostring(scan.totalServices or #(scan.services or {})) ..
            " | " .. tostring(scan.scannedAt or "date inconnue")
        )
    end
end

local function ClearCurrentTrainerScan()
    EnsureDB()
    local scanKey, identity = GetCurrentAuditKey()

    if CoABuffManagerDB.audit.trainerScans[scanKey] then
        CoABuffManagerDB.audit.trainerScans[scanKey] = nil
        if CoABuffManagerDB.audit.lastTrainerScanKey == scanKey then
            CoABuffManagerDB.audit.lastTrainerScanKey = nil
        end
        Print(
            "Audit de formateur supprime pour " .. tostring(identity.playerName) .. "."
        )
    else
        Print("Aucun audit de formateur pour ce personnage.")
    end
end

local function ListTalentScans()
    EnsureDB()

    local scans = CoABuffManagerDB.audit.talentScans
    local keys = {}
    for key in pairs(scans) do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        Print("Aucun audit de talents enregistre.")
        return
    end

    Print(tostring(#keys) .. " audit(s) de talents enregistre(s) :")
    for _, key in ipairs(keys) do
        local scan = scans[key]
        local character = scan.character or {}
        Print(
            tostring(character.playerName or "?") ..
            " | " .. tostring(character.className or character.classToken or "?") ..
            " | spec=" .. tostring(character.specName or "?") ..
            " | talents=" .. tostring(scan.totalTalents or #(scan.talents or {})) ..
            " | " .. tostring(scan.scannedAt or "date inconnue")
        )
    end
end

local function ClearCurrentTalentScan()
    EnsureDB()
    local scanKey, identity = GetCurrentAuditKey()

    if CoABuffManagerDB.audit.talentScans[scanKey] then
        CoABuffManagerDB.audit.talentScans[scanKey] = nil
        if CoABuffManagerDB.audit.lastTalentScanKey == scanKey then
            CoABuffManagerDB.audit.lastTalentScanKey = nil
        end
        Print(
            "Audit de talents supprime pour " .. tostring(identity.playerName) .. "."
        )
    else
        Print("Aucun audit de talents pour ce personnage.")
    end
end
local function ListSpellbookScans()
    EnsureDB()

    local scans = CoABuffManagerDB.audit.scans
    local keys = {}
    for key in pairs(scans) do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        Print("Aucun audit enregistre.")
        return
    end

    Print(tostring(#keys) .. " audit(s) enregistre(s) :")
    for _, key in ipairs(keys) do
        local scan = scans[key]
        local character = scan.character or {}
        Print(
            tostring(character.playerName or "?") ..
            " | " .. tostring(character.className or character.classToken or "?") ..
            " | " .. tostring(character.specName or "Spec inconnue") ..
            " | ID=" .. tostring(character.specID or "?") ..
            " | sorts=" .. tostring(scan.totalSpells or #(scan.spells or {})) ..
            " | " .. tostring(scan.scannedAt or "date inconnue")
        )
    end
end

local function ClearCurrentSpellbookScan()
    EnsureDB()
    local scanKey, identity = GetCurrentAuditKey()

    if CoABuffManagerDB.audit.scans[scanKey] then
        CoABuffManagerDB.audit.scans[scanKey] = nil
        if CoABuffManagerDB.audit.lastScanKey == scanKey then
            CoABuffManagerDB.audit.lastScanKey = nil
        end
        Print(
            "Audit supprime pour " .. tostring(identity.playerName) ..
            " / " .. tostring(identity.specName or identity.specID or "spec inconnue") .. "."
        )
    else
        Print("Aucun audit pour la specialisation actuelle.")
    end
end

local function IsSpellKnownByID(spellID)
    spellID = tonumber(spellID)
    if not spellID then
        return false
    end

    local tabCount = GetNumSpellTabs and GetNumSpellTabs() or 0
    for tabIndex = 1, tabCount do
        local _, _, offset, spellCount = GetSpellTabInfo(tabIndex)
        if offset and spellCount then
            for spellIndex = offset + 1, offset + spellCount do
                local link = GetSpellLink and GetSpellLink(spellIndex, BOOKTYPE_SPELL)
                local foundID = link and tonumber(string.match(link, "spell:(%-?%d+)"))
                if foundID == spellID then
                    return true
                end
            end
        end
    end

    return false
end

local function GetKnownSpellNameByID(spellID)
    spellID = tonumber(spellID)
    if not spellID then
        return nil
    end

    local tabCount = GetNumSpellTabs and GetNumSpellTabs() or 0
    for tabIndex = 1, tabCount do
        local _, _, offset, spellCount = GetSpellTabInfo(tabIndex)
        if offset and spellCount then
            for spellIndex = offset + 1, offset + spellCount do
                local spellName = GetSpellName(spellIndex, BOOKTYPE_SPELL)
                local link = GetSpellLink and GetSpellLink(spellIndex, BOOKTYPE_SPELL)
                local foundID = link and tonumber(string.match(link, "spell:(%-?%d+)"))
                if foundID == spellID then
                    return spellName
                end
            end
        end
    end

    return nil
end

local function ConfigureSecureSpellButton(button, spellID, fallbackName, unit)
    local exactName = GetKnownSpellNameByID(spellID)
        or (spellID and GetSpellInfo and GetSpellInfo(spellID))
        or fallbackName

    button:SetAttribute("type", "spell")
    button:SetAttribute("spell", exactName)
    button:SetAttribute("unit", unit)

    -- Explicit left-click attributes improve compatibility with the 3.3.5a
    -- secure-action implementation while retaining the generic fallback.
    button:SetAttribute("type1", "spell")
    button:SetAttribute("spell1", exactName)
    button:SetAttribute("unit1", unit)

    button.secureSpellName = exactName
    return exactName
end

-- Collects, from the local player's own spellbook, every spellID that
-- appears in CoABuffDatabase for the player's own class. Only these
-- already-locally-known facts are ever broadcast to the group; the addon
-- never asks a remote client to reveal spells outside this known set.
local function GetLocalKnownGroupSpellIDs()
    local knownSpellIDs = {}

    if not CoABuffDatabase or not CoABuffDatabase.classes then
        return knownSpellIDs
    end

    local classInfo = GetClassInfo("player")
    local classData = CoABuffDatabase.classes[classInfo.token]
    if not classData or not classData.spells then
        return knownSpellIDs
    end

    for _, spell in ipairs(classData.spells) do
        if spell.spellID and IsSpellKnownByID(spell.spellID) then
            knownSpellIDs[spell.spellID] = true
        end
    end

    return knownSpellIDs
end

-- Wire the comm module's send-side hooks to this file's existing logic,
-- without duplicating spellbook-reading code in Comm.lua.
if CoABuffComm then
    CoABuffComm.addonVersion = ADDON_VERSION

    CoABuffComm.GetLocalSpecInfo = function()
        local specID, specName = GetActivePlayerSpecInfo()
        return specID, NormalizeSpecToken(specName)
    end

    CoABuffComm.GetLocalKnownGroupSpellIDs = GetLocalKnownGroupSpellIDs

    -- Read-only: Comm.lua only ever reads this table to broadcast it, it
    -- never writes back to CoABuffManagerDB. Locks stay entirely local;
    -- see GetSameClassLockConflicts for the only thing remote lock data
    -- is used for.
    CoABuffComm.GetLocalLockSummary = function()
        EnsureDB()
        return CoABuffManagerDB.macroLocks
    end

    CoABuffComm.OnRemoteDataUpdated = function(remoteName)
        -- Le spec et les sorts connus d'un membre distant viennent d'arriver :
        -- le roster cache les porte, il doit etre refait.
        RosterCache.Invalidate()
        if type(RefreshAllPanelsForRosterChange) == "function" then
            RefreshAllPanelsForRosterChange()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Talent boost detection ("boosts your class buffs by X%" talents)
-- ---------------------------------------------------------------------------
-- TOUT ce que ce bloc expose passe par cette table UNIQUE, et pas par des
-- locals separes : le fichier est a la limite Lua 5.1 des 200 variables
-- locales par scope, atteinte trois fois pendant cette session. Une table =
-- une seule local, quel que soit le nombre de fonctions exposees.
--
-- .remoteBoosts est renseignee dans le do...end mais lue par GetRoster/AddUnit
-- definis apres : sans cette declaration prealable, plantage pour tout joueur
-- solo dont la classe n'a pas d'entree TALENT_VALUE_BOOSTS.
local Talents = { lastAutoScanCount = 0 }

do
    -- Only VERIFIED, magnitude-affecting talents from coa_buffs.db's
    -- talent_boosts table (boost_type = 'magnitude' or 'partial', verified = 1)
    -- are listed here. Duration boosts (e.g. Knight of Xoroth's Darkrider,
    -- +50% duration on Mark spells) and secondary-effect boosts (e.g.
    -- Pyromancer's Fiery Demeanor, pushback resist) are intentionally left out:
    -- they don't change the numeric group-buff VALUE shown in the overview.
    -- Keyed by classToken (the real UnitClass() token CoABuffDatabase.classes
    -- also uses, e.g. "DEMONHUNTER" for Felsworn -- see BuffDatabase.lua), not
    -- by the custom class's display name or classID.
    local TALENT_VALUE_BOOSTS = {
        WITCHDOCTOR = {
            { talentName = "Loa Empowerment", percent = 20, families = { "POWER_WUJU" } },
        },
        DEMONHUNTER = {
            -- Confirmed 2026-07-30: Bouyakha rescanned the trainer with
            -- Dark Teachings unlearned and every Illidari Intuition rank
            -- dropped by exactly 20% (e.g. Rank 1 Agility 24 -> 20),
            -- matching the same pattern already known for Man'ari
            -- Intuition -- so this talent boosts both families, not just
            -- the one originally assumed.
            { talentName = "Dark Teachings", percent = 20, families = { "MANARI_INTUITION", "ILLIDARI_INTUITION" } },
        },
        SONOFARUGAL = {
            { talentName = "Bloodbender", percent = 20, families = { "BLOODSOAKED_OFFERING" } },
        },
        CHRONOMANCER = {
            { talentName = "Mind Over Matter", percent = 20, families = { "CHROMIES_WISDOM", "NOZDORMUS_WISDOM" } },
        },
        PYROMANCER = {
            { talentName = "Flaming Finesse", percent = 20, families = { "SEAL_OF_ALAR", "SEAL_OF_ALYSRAZOR" } },
        },
        SPIRITMAGE = {
            { talentName = "Ancient Teachings", percent = 20, families = { "ETCHING_DEXTROUS" } },
        },

        -- Added 2026-07-30 for the 13 classes whose buffs landed in
        -- BuffDatabase.lua via /cbm scantrainer. Percent + target wording
        -- come from the real spell tooltip (coa.ascensionlogs.gg
        -- talent-grid API); the family keys below are then matched against
        -- the families actually present in BuffDatabase.lua, so each entry
        -- only lists families that genuinely exist for that class.
        --
        -- Safe to multiply: the trainer-preview values these boost were
        -- captured from greyed-out tooltips on characters that had not
        -- learned the spell (and had no talent points), so the DB holds
        -- BASE values -- same convention Bouyakha confirmed for Illidari
        -- Intuition (24 with Dark Teachings -> 20 without; DB stores 20).
        BARBARIAN = {
            { talentName = "Bellowing Voice", percent = 20, families = { "BRUTAL_SHOUT", "ENDURING_SHOUT" } },
        },
        GUARDIAN = {
            { talentName = "Standard Bearer", percent = 20, families = { "HONOR" } },
        },
        TEMPLAR = {
            -- Tooltip names Gift of Zeal specifically, so GIFT_OF_FERVOR
            -- (the class's other Gift family) is deliberately excluded.
            { talentName = "Martyr", percent = 20, families = { "GIFT_OF_ZEAL" } },
        },
        STARCALLER = {
            { talentName = "Star Citizen", percent = 20, families = { "CELESTIAL_MIND" } },
        },
        CULTIST = {
            { talentName = "Shadow Words", percent = 25, families = { "WHISPERS_OF_CTHUN", "WHISPERS_OF_NZOTH", "WHISPERS_OF_YSHAARJ" } },
        },
        TINKER = {
            -- "Function Over Form" (+50% Aether Augmentation) is NOT here:
            -- Aether Augmentation is a personal cooldown (other Tinker
            -- talents tie it to the Tinker's own Scrap Shot / ranged
            -- haste), and no such family exists in BuffDatabase.lua.
            { talentName = "Modulator", percent = 20, families = { "MANA_MODULE", "POWER_MODULE" } },
        },
        REAPER = {
            { talentName = "Burial Rites", percent = 20, families = { "RITE_OF_PERSEVERANCE", "RITE_OF_POWER", "RITE_OF_RESOLVE" } },
        },
        NECROMANCER = {
            { talentName = "Improved Mandates", percent = 20, families = { "FOUL_MANDATE", "GRIM_MANDATE" } },
        },
        WITCHHUNTER = {
            { talentName = "Follow The Edict", percent = 20, families = { "INQUISITORS_EDICT", "KNIGHTS_EDICT", "WITCHING_EDICT" } },
        },
        PROPHET = {
            -- Venomancer's Lua key is PROPHET (not VENOMANCER).
            { talentName = "Empowering Pheromones", percent = 20, families = { "BEETLE_PHEROMONES", "SPIDER_PHEROMONES", "TOXIC_PHEROMONES" } },
        },
        STORMBRINGER = {
            -- Tooltip: "Call of the Winds and Call of the Storm" -- so
            -- CALL_OF_LIGHTNING, the class's third Call family, is excluded.
            { talentName = "Storm Sorcery", percent = 20, families = { "CALL_OF_WIND", "CALL_OF_STORM" } },
        },
        SUNCLERIC = {
            { talentName = "Devotee", percent = 20, families = { "DEVOTION_OF_DAWN", "DEVOTION_OF_EMPERORS", "DEVOTION_OF_GRACE", "DEVOTION_OF_RADIANCE" } },
        },
        WILDWALKER = {
            -- Primalist's Lua key is WILDWALKER. Tooltip says "Boons and
            -- Instincts", but no Boon family exists in BuffDatabase.lua --
            -- only the two Instinct ones are applied, so this is a partial
            -- boost until a Boon family (if any) turns up.
            { talentName = "Bountiful Boons", percent = 10, families = { "GROVE_INSTINCT", "PRIMAL_INSTINCT" } },
        },

        -- RANGER deliberately absent: its boost candidate "Improved
        -- Waterskins" (+25% Waterskins) has no matching family -- the
        -- class's real families are WOODSMANS_ADAPTATION,
        -- FOOTPADS_ADAPTATION and WILD_BLESSING. Like Function Over Form,
        -- Waterskins look personal, not a group buff.
    }

    -- Shared by the local scan (no "inspect" flag, reads the player's own
    -- talents) and the remote scan (inspect flag set, reads whichever unit was
    -- last NotifyInspect'd -- see GetInspectedTalentBoosts below). Returns
    -- {[family] = percent, ...} or nil if classToken has no known boost talent
    -- or none of them are invested.
    local function CollectTalentBoosts(classToken, inspect)
        local defs = TALENT_VALUE_BOOSTS[classToken]
        if not defs then
            return nil
        end

        local boosts = {}
        local tabCount = GetNumTalentTabs and GetNumTalentTabs(inspect) or 0
        for tabIndex = 1, tabCount do
            local talentCount = GetNumTalents and GetNumTalents(tabIndex, inspect) or 0
            for talentIndex = 1, talentCount do
                local name, _, _, _, currentRank = GetTalentInfo(tabIndex, talentIndex, inspect)
                if name and currentRank and currentRank > 0 then
                    for _, def in ipairs(defs) do
                        if def.talentName == name then
                            for _, family in ipairs(def.families) do
                                if not boosts[family] or def.percent > boosts[family] then
                                    boosts[family] = def.percent
                                end
                            end
                        end
                    end
                end
            end
        end

        return next(boosts) and boosts or nil
    end

    -- CACHE OBLIGATOIRE, pas une optimisation de confort : GetRoster() appelle
    -- ceci pour le joueur, or GetRoster() est appele depuis RefreshTrackerHUD()
    -- qui tourne sur UNIT_AURA -- evenement qui se declenche a chaque
    -- application/disparition de buff sur n'importe quelle unite du raid, donc
    -- des dizaines de fois par seconde en raid 25. Sans cache, chaque
    -- occurrence relancait ~150-200 appels GetTalentInfo pour rien : les
    -- talents ne changent pas entre deux buffs.
    --
    -- nil = a recalculer ; false = calcule, aucun boost pour cette classe.
    local cachedLocalBoosts = nil

    Talents.GetLocalBoosts = function()
        if cachedLocalBoosts ~= nil then
            return cachedLocalBoosts or nil
        end
        local classInfo = GetClassInfo("player")
        cachedLocalBoosts = CollectTalentBoosts(classInfo.token, nil) or false
        return cachedLocalBoosts or nil
    end

    -- Appele par le dispatcher sur les seuls evenements qui peuvent vraiment
    -- changer les talents (respec, changement de spec, apprentissage).
    Talents.InvalidateLocal = function()
        cachedLocalBoosts = nil
    end

    local function GetInspectedTalentBoosts(classToken)
        return CollectTalentBoosts(classToken, true)
    end

    -- Raw dump of every invested talent (name + rank), no matching against
    -- TALENT_VALUE_BOOSTS -- same discovery-tool idea as ScanTalents (see
    -- its comment above), just aimed at a remote inspected unit instead of
    -- the local player. Only called for classes NOT YET in
    -- TALENT_VALUE_BOOSTS (see Talents.OnInspectReady below), so it's spotting
    -- new "boosts your buff by X%" CANDIDATES for classes with no verified
    -- boost talent yet, not renoising classes already confirmed.
    local function CollectInvestedTalentNames(inspect)
        local investedTalents = {}
        local tabCount = GetNumTalentTabs and GetNumTalentTabs(inspect) or 0
        for tabIndex = 1, tabCount do
            local talentCount = GetNumTalents and GetNumTalents(tabIndex, inspect) or 0
            for talentIndex = 1, talentCount do
                local name, _, _, _, currentRank = GetTalentInfo(tabIndex, talentIndex, inspect)
                if name and currentRank and currentRank > 0 then
                    table.insert(investedTalents, { name = name, rank = currentRank })
                end
            end
        end
        return investedTalents
    end

    -- The classID-keyed candidate table that used to live here is gone:
    -- all 13 classes it covered are now resolved into TALENT_VALUE_BOOSTS
    -- above (their buffs landed in BuffDatabase.lua via /cbm scantrainer,
    -- so their real families are known). The one entry that did NOT
    -- graduate is Ranger's "Improved Waterskins" -- deliberately dropped
    -- rather than kept as a candidate, because Ranger's real families
    -- (WOODSMANS_ADAPTATION / FOOTPADS_ADAPTATION / WILD_BLESSING) contain
    -- nothing Waterskin-like, so it looks personal like Tinker's
    -- "Function Over Form".
    --
    -- The raw invested-talent dump below is kept: it's the discovery tool
    -- for any class that still has no TALENT_VALUE_BOOSTS entry, so a new
    -- "boosts your X by Y%" talent can still be spotted by eye in chat.

    -- ---------------------------------------------------------------------------
    -- Remote talent-boost detection (inspect scan)
    -- ---------------------------------------------------------------------------
    -- Session-only, never written to SavedVariables: rebuilt every time the
    -- group changes. Keyed by short unit name, same convention as
    -- CoABuffComm.remote. Deliberately kept separate from CoABuffComm.remote
    -- (the addon-message channel): this data comes from Blizzard's own
    -- inspect API, not from a CBM1 broadcast, and doesn't need wiring in
    -- Comm.lua at all -- each client independently inspects everyone else in
    -- range, rather than trusting a remote client's self-report.
    Talents.remoteBoosts = {}
    local inspectQueue = {}
    local inspectInFlightUnit = nil
    local inspectTimeoutFrame

    local function After(seconds, callback)
        local frame = CreateFrame("Frame")
        local elapsed = 0
        frame:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if elapsed >= seconds then
                self:SetScript("OnUpdate", nil)
                callback()
            end
        end)
    end

    local function EnsureInspectTimeoutFrame()
        if not inspectTimeoutFrame then
            inspectTimeoutFrame = CreateFrame("Frame")
        end
        return inspectTimeoutFrame
    end

    local ProcessNextInspect

    local function ClearInspectTimeout()
        if inspectTimeoutFrame then
            inspectTimeoutFrame:SetScript("OnUpdate", nil)
        end
    end

    -- Timings below are NOT guesses: they're taken from AscensionLogsCompanion
    -- 0.65.0 (Core/Constants.lua), whose author validated them on live
    -- Ascension servers -- INSPECT_MIN_INTERVAL_S = 1.0 is annotated
    -- "24/24 fires got replies, 0% server-throttled".
    local INSPECT_TIMEOUT = 5.0   -- was a 2.0 guess; ALC uses 5.0
    local INSPECT_GAP     = 1.0   -- minimum delay between two NotifyInspect

    -- The inspect buffer is a SINGLE GLOBAL slot shared with the player's own
    -- character pane and with any open inspect window: NotifyInspect repoints
    -- it, so a background scan running while one of those frames is shown
    -- would make the player's own gear/talent tooltips read someone else's
    -- data. ALC, Details and Skada all take the same stance -- gate on the
    -- frames and never call ClearInspectPlayer.
    local function InspectBufferBusy()
        for _, frameName in ipairs({ "InspectFrame", "CharacterFrame", "PaperDollFrame" }) do
            local f = _G[frameName]
            if f and f.IsShown and f:IsShown() then
                return true
            end
        end
        return false
    end

    -- NotifyInspect only supports one in-flight target at a time and its reply
    -- (INSPECT_TALENT_READY) arrives asynchronously (and carries no unit
    -- argument on this client -- it always refers to whichever unit was last
    -- NotifyInspect'd), so the roster is walked one member at a time rather
    -- than all at once. The timeout skips a target that never answers (out of
    -- range/LoS, or declined by the server) instead of stalling the queue.
    ProcessNextInspect = function()
        if inspectInFlightUnit then
            return
        end

        -- Don't fight the player for the shared buffer: retry shortly instead
        -- of dropping the queue, since they'll close the frame eventually.
        if InspectBufferBusy() then
            After(2, ProcessNextInspect)
            return
        end

        local nextUnit = table.remove(inspectQueue, 1)
        if not nextUnit then
            return
        end

        -- CheckInteractDistance(unit, 4) is the ~28y "follow" range: CanInspect
        -- alone returns true for out-of-range units, whose inspect then just
        -- times out and wastes a full INSPECT_TIMEOUT slot.
        if not UnitExists(nextUnit)
            or (type(CanInspect) == "function" and not CanInspect(nextUnit))
            or (type(CheckInteractDistance) == "function" and not CheckInteractDistance(nextUnit, 4)) then
            ProcessNextInspect()
            return
        end

        inspectInFlightUnit = nextUnit
        NotifyInspect(nextUnit)

        local frame = EnsureInspectTimeoutFrame()
        local elapsed = 0
        frame:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if elapsed > INSPECT_TIMEOUT then
                self:SetScript("OnUpdate", nil)
                inspectInFlightUnit = nil
                ProcessNextInspect()
            end
        end)
    end

    -- Paces the queue at INSPECT_GAP instead of firing the next NotifyInspect
    -- immediately -- back-to-back requests get silently dropped by the server.
    local function ScheduleNextInspect()
        After(INSPECT_GAP, ProcessNextInspect)
    end

    -- Forward-declared: assigned below, but captured by the deferred read in
    -- Talents.OnInspectReady which is defined first.
    local ReadInspectedUnit

    Talents.OnInspectReady = function()
        if not inspectInFlightUnit then
            return
        end

        -- The event fires slightly before the talent data is actually
        -- readable; ALC waits INSPECT_FLIP_DELAY_S = 0.4 before reading for
        -- the same reason. Reading immediately yields the PREVIOUS target's
        -- talents (or nothing at all).
        local unit = inspectInFlightUnit
        ClearInspectTimeout()
        inspectInFlightUnit = nil

        After(0.4, function()
            ReadInspectedUnit(unit)
            if #inspectQueue > 0 then
                ScheduleNextInspect()
            elseif type(RefreshAllPanelsForRosterChange) == "function" then
                RefreshAllPanelsForRosterChange()
            end
        end)
    end

    -- Split out of Talents.OnInspectReady so the 0.4s deferred read above stays
    -- readable; does the actual talent extraction for one inspected unit.
    ReadInspectedUnit = function(unit)
        local name = UnitName(unit)
        if name then
            local classInfo = GetClassInfo(unit)
            Talents.remoteBoosts[name] = GetInspectedTalentBoosts(classInfo.token)
            -- Le roster cache porte talentBoosts : sans ca, le boost detecte
            -- n'apparaitrait qu'au prochain rafraichissement du cache.
            RosterCache.Invalidate()

            -- Classe pas encore dans TALENT_VALUE_BOOSTS : on ne sait pas
            -- encore si/lequel de ses talents boost ses buffs, donc on
            -- liste tout ce qui est investi pour reperage a l'oeil (nom
            -- "type Dark Teachings") plutot que de rester silencieux.
            if not TALENT_VALUE_BOOSTS[classInfo.token] then
                local invested = CollectInvestedTalentNames(true)
                if #invested > 0 then
                    local plainNames = {}
                    for _, talent in ipairs(invested) do
                        table.insert(plainNames, talent.name .. " (rang " .. talent.rank .. ")")
                    end

                    Print(
                        "Talents investis chez " .. name .. " (" ..
                        tostring(classInfo.name) ..
                        ", classe pas encore dans TALENT_VALUE_BOOSTS) : " ..
                        table.concat(plainNames, ", ")
                    )
                end
            end
        end
    end

    -- Scans every OTHER group member's talents via the standard inspect API to
    -- detect verified "boost %" talents (see TALENT_VALUE_BOOSTS), so the
    -- overview can show the REAL post-talent value instead of the flat DB
    -- value. Meant to run right as a group forms (everyone stacked at the same
    -- spot after a dungeon teleport, all in inspect range) -- see the
    -- automatic trigger on roster growth below -- but can also be run by hand
    -- with /cbm scannearby for stragglers or late joiners.
    Talents.ScanNearby = function(silent)
        if InCombatLockdown and InCombatLockdown() then
            if not silent then
                Print("Scan des talents impossible pendant le combat.")
            end
            return
        end

        inspectQueue = {}
        local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0

        if raidCount > 0 then
            for index = 1, raidCount do
                local unit = "raid" .. index
                if not UnitIsUnit(unit, "player") then
                    table.insert(inspectQueue, unit)
                end
            end
        elseif partyCount > 0 then
            for index = 1, partyCount do
                table.insert(inspectQueue, "party" .. index)
            end
        end

        if #inspectQueue == 0 then
            if not silent then
                Print("Pas de coequipier a portee : rien a scanner.")
            end
            return
        end

        if not silent then
            Print("Scan des talents du groupe en cours (" .. #inspectQueue .. " membre(s))...")
        end

        ProcessNextInspect()
    end
end

-- Identifiants d'unite precalcules : "raid" .. index cree une chaine a chaque
-- appel, soit 25 allocations inutiles par reconstruction de roster -- et le
-- roster se reconstruit sur UNIT_AURA, donc tres souvent.
RosterCache.raidIds, RosterCache.partyIds = {}, {}
for index = 1, MAX_MEMBERS do RosterCache.raidIds[index] = "raid" .. index end
for index = 1, MAX_MEMBERS - 1 do RosterCache.partyIds[index] = "party" .. index end

local function BuildRoster()
    local roster = {}
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local playerSpecID, playerSpecName = GetActivePlayerSpecInfo()
    local playerSpecToken = NormalizeSpecToken(playerSpecName)

    local function AddUnit(unit)
        if not UnitExists(unit) then
            return
        end

        local classInfo = GetClassInfo(unit)
        local isPlayer = UnitIsUnit(unit, "player") and true or false
        local name = UnitName(unit) or unit

        local specID, specToken, knownSpellIDs, remoteAddonVersion
        local talentBoosts

        if isPlayer then
            specID = playerSpecID
            specToken = playerSpecToken
            talentBoosts = Talents.GetLocalBoosts()
        else
            talentBoosts = Talents.remoteBoosts[name]
            if CoABuffComm and type(CoABuffComm.GetRemoteData) == "function" then
                local remote = CoABuffComm.GetRemoteData(name)
                if remote then
                    specID = remote.specID
                    specToken = remote.specToken
                    knownSpellIDs = remote.knownSpellIDs
                    remoteAddonVersion = remote.addonVersion
                end
            end
        end

        table.insert(roster, {
            unit = unit,
            name = name,
            className = classInfo.name,
            classToken = classInfo.token,
            classID = classInfo.id,
            level = UnitLevel(unit) or 0,
            isPlayer = isPlayer,
            specID = specID,
            specName = isPlayer and playerSpecName or nil,
            specToken = specToken,
            remoteKnownSpellIDs = knownSpellIDs,
            remoteAddonVersion = remoteAddonVersion,
            talentBoosts = talentBoosts,
        })
    end

    if raidCount > 0 then
        for index = 1, math.min(raidCount, MAX_MEMBERS) do
            AddUnit(RosterCache.raidIds[index])
        end
    else
        AddUnit("player")

        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
        for index = 1, math.min(partyCount, MAX_MEMBERS - 1) do
            AddUnit(RosterCache.partyIds[index])
        end
    end

    return roster
end

-- Le roster est reconstruit depuis RefreshTrackerHUD(), branche sur UNIT_AURA
-- -- evenement qui se declenche a chaque buff applique ou perdu par n'importe
-- quelle unite du raid. Sans cache, chaque occurrence refait ~6 appels API par
-- membre (UnitExists, UnitClass, UnitIsUnit, UnitName, UnitLevel...) plus une
-- table par membre, soit ~150 appels et 25 tables a jeter, des dizaines de
-- fois par seconde en raid 25.
--
-- Invalidation explicite sur les evenements qui changent reellement son
-- contenu, PLUS un TTL court en filet de securite : si une source de
-- changement a ete oubliee, l'incoherence se corrige toute seule en 1 s au
-- lieu de persister jusqu'au prochain changement de groupe.
RosterCache.Invalidate = function()
    RosterCache.list = nil
end

local function GetRoster()
    local now = GetTime and GetTime() or 0
    if RosterCache.list and (now - RosterCache.at) < RosterCache.ttl then
        return RosterCache.list
    end
    RosterCache.list = BuildRoster()
    RosterCache.at = now
    return RosterCache.list
end

local function IsSpellKnownByName(spellName)
    if not spellName or spellName == "" then
        return false
    end

    local tabCount = GetNumSpellTabs and GetNumSpellTabs() or 0
    for tabIndex = 1, tabCount do
        local _, _, offset, spellCount = GetSpellTabInfo(tabIndex)
        if offset and spellCount then
            for spellIndex = offset + 1, offset + spellCount do
                local name = GetSpellName(spellIndex, BOOKTYPE_SPELL)
                if name == spellName then
                    return true, spellIndex
                end
            end
        end
    end

    return false
end

local function PersonalSpellConfigured(spellName)
    for _, spell in ipairs(CoABuffManagerDB.spells) do
        if spell.name == spellName then
            return true
        end
    end
    return false
end

-- Looks up a spell's family (e.g. MARK_OF_KORTHAZZ) and canonical spellID in
-- CoABuffDatabase, first by spellID and then by normalized name. This lets a
-- personal spell added via /cbm add be linked back to its Greater/single-
-- target family so aura detection can use the same alias list everywhere
-- (overview tab and casts tab alike), instead of a bare name comparison.
local function FindDatabaseFamilyForSpell(spellID, spellName)
    if not CoABuffDatabase or not CoABuffDatabase.classes then
        return nil, nil
    end

    spellID = tonumber(spellID)
    local normalizedName
    if spellName and spellName ~= "" then
        normalizedName = string.lower(tostring(spellName))
        normalizedName = string.gsub(normalizedName, "^greater%s+", "")
        normalizedName = string.gsub(normalizedName, "[^%w]", "")
    end

    local nameMatchFamily, nameMatchSpellID

    for _, classData in pairs(CoABuffDatabase.classes) do
        if classData.spells then
            for _, spell in ipairs(classData.spells) do
                if spellID and tonumber(spell.spellID) == spellID then
                    return spell.family, spell.spellID
                end

                if normalizedName and not nameMatchFamily then
                    local candidateName = string.lower(tostring(spell.spellName or ""))
                    candidateName = string.gsub(candidateName, "^greater%s+", "")
                    candidateName = string.gsub(candidateName, "[^%w]", "")
                    if candidateName ~= "" and candidateName == normalizedName then
                        nameMatchFamily = spell.family
                        nameMatchSpellID = spell.spellID
                    end
                end
            end
        end
    end

    return nameMatchFamily, nameMatchSpellID
end

local function AddPersonalSpellByID(spellID, silent)
    EnsureDB()

    spellID = tonumber(spellID)
    local spellName = spellID and GetSpellInfo(spellID)

    if not spellName then
        if not silent then
            Print("ID de sort inconnu : " .. tostring(spellID))
        end
        return false
    end

    if not IsSpellKnownByName(spellName) then
        if not silent then
            Print("Le personnage ne connait pas : " .. spellName)
        end
        return false
    end

    if PersonalSpellConfigured(spellName) then
        return false
    end

    local family = FindDatabaseFamilyForSpell(spellID, spellName)

    table.insert(CoABuffManagerDB.spells, {
        id = spellID,
        name = spellName,
        aura = spellName,
        family = family,
    })

    if not silent then
        Print("Sort personnel ajoute : " .. spellName)
    end

    return true
end

local function FindKnownSpell(searchText)
    searchText = Trim(searchText)
    if searchText == "" then
        return nil
    end

    local wanted = string.lower(searchText)
    local exact
    local partial

    for tabIndex = 1, (GetNumSpellTabs() or 0) do
        local _, _, offset, spellCount = GetSpellTabInfo(tabIndex)
        for spellIndex = offset + 1, offset + spellCount do
            local spellName = GetSpellName(spellIndex, BOOKTYPE_SPELL)
            if spellName then
                local lowerName = string.lower(spellName)
                if lowerName == wanted then
                    exact = { name = spellName, index = spellIndex }
                elseif not partial and string.find(lowerName, wanted, 1, true) then
                    partial = { name = spellName, index = spellIndex }
                end
            end
        end
    end

    return exact or partial
end

local function AddPersonalSpellByName(searchText)
    EnsureDB()

    local found = FindKnownSpell(searchText)
    if not found then
        Print("Sort introuvable dans le grimoire : " .. tostring(searchText))
        return false
    end

    if PersonalSpellConfigured(found.name) then
        Print("Sort deja ajoute : " .. found.name)
        return false
    end

    local link = GetSpellLink(found.index, BOOKTYPE_SPELL)
    local spellID = link and tonumber(string.match(link, "spell:(%-?%d+)"))
    local family = FindDatabaseFamilyForSpell(spellID, found.name)

    table.insert(CoABuffManagerDB.spells, {
        id = spellID,
        name = found.name,
        aura = found.name,
        family = family,
    })

    Print("Sort personnel ajoute : " .. found.name)
    return true
end

local function SeedPersonalSpells()
    EnsureDB()

    if CoABuffManagerDB.personalDefaultsSeeded then
        return
    end

    for _, spellID in ipairs(DEFAULT_PERSONAL_SPELL_IDS) do
        AddPersonalSpellByID(spellID, true)
    end

    CoABuffManagerDB.personalDefaultsSeeded = true
end

-- Backfills the "family" field on personal spells saved by an addon version
-- prior to 0.6.6. Without a family, the casts tab can only match auras by
-- exact name and misses Greater/single-target aliases of the same buff,
-- causing it to disagree with the overview tab about whether a buff is up.
local function MigratePersonalSpellFamilies()
    EnsureDB()

    for _, spell in ipairs(CoABuffManagerDB.spells) do
        if not spell.family then
            spell.family = FindDatabaseFamilyForSpell(spell.id, spell.name)
        end
    end
end

local function NormalizeAuraName(name)
    name = string.lower(tostring(name or ""))
    name = string.gsub(name, "^greater%s+", "")
    name = string.gsub(name, "[^%w]", "")
    return name
end

local function NormalizeExactSpellName(name)
    name = string.lower(tostring(name or ""))
    name = string.gsub(name, "[^%w]", "")
    return name
end

local function RegisterTrackedSpell(byID, byName, spellID, spellName, category)
    spellID = tonumber(spellID)
    if spellID then
        byID[spellID] = category
    end

    local key = NormalizeExactSpellName(spellName)
    if key ~= "" then
        byName[key] = category
    end
end

local function GetTrackedSpellCategory(byID, byName, spellID, spellName)
    spellID = tonumber(spellID)
    if spellID and byID[spellID] then
        return byID[spellID]
    end

    local key = NormalizeExactSpellName(spellName)
    if key ~= "" then
        return byName[key]
    end

    return nil
end

local function UnitHasAura(unit, auraName, auraSpellID, auraAliases)
    if not unit then
        return false, nil
    end

    local normalizedCandidates = {}

    local function AddCandidate(name)
        local normalized = NormalizeAuraName(name)
        if normalized ~= "" then
            normalizedCandidates[normalized] = true
        end
    end

    AddCandidate(auraName)
    for _, alias in ipairs(auraAliases or {}) do
        AddCandidate(alias)
    end

    for index = 1, 40 do
        local name, _, _, _, _, duration, expirationTime, unitCaster,
            _, _, foundSpellID = UnitBuff(unit, index)
        if not name then
            break
        end

        if auraSpellID and foundSpellID
            and tonumber(auraSpellID) == tonumber(foundSpellID) then
            return true, expirationTime, duration, unitCaster, foundSpellID, name
        end

        if normalizedCandidates[NormalizeAuraName(name)] then
            return true, expirationTime, duration, unitCaster, foundSpellID, name
        end
    end

    return false, nil
end

local function SavePosition()
    if not mainFrame then
        return
    end

    local point, _, relativePoint, x, y = mainFrame:GetPoint(1)
    CoABuffManagerDB.position = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function RestorePosition()
    mainFrame:ClearAllPoints()

    local position = CoABuffManagerDB.position
    if position and position.point then
        mainFrame:SetPoint(
            position.point,
            UIParent,
            position.relativePoint or position.point,
            position.x or 0,
            position.y or 0
        )
    else
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function CreateText(parent, fontObject, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", fontObject)
    text:SetJustifyH(justify or "LEFT")
    return text
end

local function HideCollection(collection)
    for _, widget in ipairs(collection) do
        widget:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Onglet : buffs personnels
-- ---------------------------------------------------------------------------

local function GetCastHeader(index)
    if not castHeaders[index] then
        castHeaders[index] = CreateText(panels.casts, "GameFontNormalSmall", "CENTER")
    end
    return castHeaders[index]
end

local function GetCastLabel(index)
    if not castLabels[index] then
        castLabels[index] = CreateText(panels.casts, "GameFontHighlight", "LEFT")
    end
    return castLabels[index]
end

local function GetCastButton(index)
    if castButtons[index] then
        return castButtons[index]
    end

    local button = CreateFrame(
        "Button",
        ADDON_NAME .. "CastButton" .. index,
        panels.casts,
        "SecureActionButtonTemplate,UIPanelButtonTemplate"
    )

    button:RegisterForClicks("LeftButtonUp")
    button:SetWidth(MEMBER_WIDTH - 8)
    button:SetHeight(25)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.spellName or "Buff")
        GameTooltip:AddLine(
            "Cible : " .. tostring(UnitName(self.unit) or self.unit),
            1, 1, 1
        )
        GameTooltip:AddLine(
            "Aura attendue : " .. tostring(self.auraName),
            1, 1, 1
        )
        GameTooltip:AddLine("Clic gauche : lancer le sort.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    castButtons[index] = button
    return button
end

local function RefreshCastStates()
    if not mainFrame or not mainFrame:IsShown() or activeTab ~= "casts" then
        return
    end

    for _, button in ipairs(castButtons) do
        if button:IsShown() and button.unit then
            if not UnitExists(button.unit) then
                button:SetText("-")
                button:Disable()
            elseif not UnitIsConnected(button.unit) then
                button:SetText("Hors ligne")
                button:Disable()
            elseif UnitIsDeadOrGhost(button.unit) then
                button:SetText("Mort")
                button:Disable()
            else
                button:Enable()

                local auraAliases
                if button.family then
                    auraAliases = GetFamilyAuraNames(
                        button.member,
                        button.family,
                        button.auraName
                    )
                end

                local hasAura, expirationTime = UnitHasAura(
                    button.unit,
                    button.auraName,
                    button.spellID,
                    auraAliases
                )

                if hasAura then
                    if expirationTime and expirationTime > 0 then
                        local remaining =
                            math.max(0, expirationTime - GetTime())

                        if remaining < 60 then
                            button:SetText(string.format("%.0fs", remaining))
                        else
                            button:SetText(
                                string.format("%.0fm", remaining / 60)
                            )
                        end
                    else
                        button:SetText("OK")
                    end
                else
                    button:SetText("BUFF")
                end

                if IsSpellInRange
                    and IsSpellInRange(button.spellName, button.unit) == 0 then
                    button:SetText("Hors portee")
                end
            end
        end
    end
end

local function RebuildCastPanel()
    EnsureDB()

    if InCombatLockdown and InCombatLockdown() then
        pendingSecureRebuild = true
        statusText:SetText(
            "Combat : reconstruction des boutons differee."
        )
        return
    end

    pendingSecureRebuild = false
    HideCollection(castButtons)
    HideCollection(castLabels)
    HideCollection(castHeaders)

    local roster = GetRoster()

    local header = GetCastHeader(1)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", panels.casts, "TOPLEFT", 6, -8)
    header:SetWidth(LABEL_WIDTH - 12)
    header:SetText("Buff personnel")
    header:Show()

    for column, member in ipairs(roster) do
        header = GetCastHeader(column + 1)
        header:ClearAllPoints()
        header:SetPoint(
            "TOPLEFT",
            panels.casts,
            "TOPLEFT",
            LABEL_WIDTH + ((column - 1) * MEMBER_WIDTH),
            -8
        )
        header:SetWidth(MEMBER_WIDTH - 8)
        header:SetText(member.name)
        header:Show()
    end

    local buttonIndex = 0

    for row, spell in ipairs(CoABuffManagerDB.spells) do
        local label = GetCastLabel(row)
        label:ClearAllPoints()
        label:SetPoint(
            "TOPLEFT",
            panels.casts,
            "TOPLEFT",
            8,
            -(40 + ((row - 1) * ROW_HEIGHT))
        )
        label:SetWidth(LABEL_WIDTH - 16)
        label:SetText(tostring(row) .. ". " .. spell.name)
        label:Show()

        for column, member in ipairs(roster) do
            buttonIndex = buttonIndex + 1
            local button = GetCastButton(buttonIndex)

            button:ClearAllPoints()
            button:SetPoint(
                "TOPLEFT",
                panels.casts,
                "TOPLEFT",
                LABEL_WIDTH + ((column - 1) * MEMBER_WIDTH),
                -(36 + ((row - 1) * ROW_HEIGHT))
            )

            button:SetAttribute("type", "spell")
            button:SetAttribute("spell", spell.name)
            button:SetAttribute("unit", member.unit)

            button.unit = member.unit
            button.spellName = spell.name
            button.auraName = spell.aura or spell.name
            button.spellID = spell.id
            button.family = spell.family
            button.member = member
            button:Show()
        end
    end

    if #CoABuffManagerDB.spells == 0 then
        local label = GetCastLabel(1)
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", panels.casts, "TOPLEFT", 8, -44)
        label:SetWidth(500)
        label:SetText(
            "Aucun sort personnel. Utilise /cbm add <nom du sort>."
        )
        label:Show()
    end

    RefreshCastStates()
end

-- ---------------------------------------------------------------------------
-- Onglet : possibilites du groupe
-- ---------------------------------------------------------------------------

local function GetOverviewHeader(index)
    if not overviewHeaders[index] then
        overviewHeaders[index] =
            CreateText(panels.overview, "GameFontNormalSmall", "CENTER")
    end
    return overviewHeaders[index]
end

local function GetOverviewLabel(index)
    if not overviewLabels[index] then
        overviewLabels[index] =
            CreateText(panels.overview, "GameFontHighlight", "LEFT")
    end
    return overviewLabels[index]
end

-- Invisible hover target laid over a roster column's header (name +
-- class + level + spec) so hovering a member's class -- e.g. "Knight
-- of Xoroth" -- shows every buff that class can bring, not just the
-- one category the player happened to be looking at.
local function GetOverviewMemberHoverFrame(index)
    if overviewMemberHoverFrames[index] then
        return overviewMemberHoverFrames[index]
    end

    local frame = CreateFrame("Frame", nil, panels.overview)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        if not self.classBuffLines or #self.classBuffLines == 0 then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.className or "Classe", 1, 1, 1)
        GameTooltip:AddLine(
            "Buffs que cette classe peut fournir :",
            0.8, 0.8, 0.8, true
        )
        for _, line in ipairs(self.classBuffLines) do
            GameTooltip:AddLine(line, 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    overviewMemberHoverFrames[index] = frame
    return frame
end

local function GetOverviewCastButton(index)
    if overviewCastButtons[index] then
        return overviewCastButtons[index]
    end

    local button = CreateFrame(
        "Button",
        ADDON_NAME .. "OverviewCastButton" .. index,
        panels.overview,
        "SecureActionButtonTemplate,UIPanelButtonTemplate"
    )

    -- Left click remains owned entirely by the secure template's own
    -- attributes (never touched from a custom OnClick). Right click is a
    -- plain, non-secure toggle of this button's family lock, feeding the
    -- tracker HUD row for this family; it never reads or writes any secure
    -- attribute, so it stays safe to use even under combat lockdown.
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetWidth(OVERVIEW_ICON_SIZE)
    button:SetHeight(OVERVIEW_ICON_SIZE)
    button:SetText("")
    button:SetNormalTexture("")
    button:SetPushedTexture("")
    button:SetDisabledTexture("")
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    -- edgeSize bumped from 12 to 18: the state border (green/orange/red,
    -- see SetOverviewButtonVisual) was hard to read at a glance, especially
    -- ACTIVE's green. Shared by every state since they're all just a
    -- color change on this same backdrop -- there's no way to make just
    -- one state's border thicker without a second overlay frame.
    button:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 18,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    button:SetBackdropColor(0.02, 0.02, 0.02, 0.95)
    button:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -3, 3)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Bottom line of the button: shows the category's numeric value
    -- (colour-coded green/orange for best-in-group, see valueDisplay
    -- below) most of the time, but switches to a plain countdown when
    -- the buff is close to expiring -- see SetOverviewButtonVisual,
    -- which decides which of the two to show on every refresh.
    button.valueDisplay = ""
    button.timerText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.timerText:SetPoint("BOTTOM", button, "BOTTOM", 0, 3)
    button.timerText:SetText("")

    -- Separate lock indicator: a thin red highlight frame drawn on top of
    -- the icon, independent from the state border (active/inactive/out of
    -- range) managed by SetOverviewButtonVisual. Kept as its own layer so
    -- toggling the lock never interferes with the existing state logic.
    button.lockOverlay = CreateFrame("Frame", nil, button)
    button.lockOverlay:SetAllPoints(button)
    button.lockOverlay:SetFrameLevel(button:GetFrameLevel() + 1)
    button.lockOverlay:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    -- Gold rather than red: red is already used elsewhere on this button
    -- for error/expiration states (CRITICAL/OUT_OF_RANGE), so a red lock
    -- border read as "something's wrong" instead of "this is locked".
    button.lockOverlay:SetBackdropBorderColor(1, 0.82, 0, 1)
    button.lockOverlay:Hide()

    -- Re-assert the secure attributes right before every click, the same
    -- way the tracker HUD's rows do (see GetTrackerRow's PreClick) --
    -- ConfigureSecureSpellButton alone (setting them once, at rebuild
    -- time, outside any click) turned out not to be enough for left-click
    -- to actually fire the cast on this client, even outside combat.
    button:SetScript("PreClick", function(self)
        if self.secureSpellName then
            self:SetAttribute("type1", "spell")
            self:SetAttribute("spell1", self.secureSpellName)
            self:SetAttribute("unit1", self.unit)
        end
    end)

    -- PostClick, not OnClick: SecureActionButtonTemplate's own protected
    -- OnClick is what actually reads type1/spell1/unit1 and fires the
    -- cast on left-click. SetScript("OnClick", ...) would REPLACE that
    -- built-in handler entirely rather than run alongside it, silently
    -- breaking left-click casting on this button (unlike PreClick/
    -- PostClick, which are additive hooks).
    button:SetScript("PostClick", function(self, mouseButton)
        if mouseButton ~= "RightButton" then
            return
        end

        if not self.family then
            return
        end

        if self.groupWide then
            ToggleGroupLock(self.family)
        elseif self.targetName then
            -- Locks/unlocks this family for every roster member sharing
            -- this player's class in one go, not just this one player --
            -- see ToggleClassIndividualLock's comment for the reasoning.
            ToggleClassIndividualLock(self.family, self.targetName, GetRoster())
        end

        if RefreshOverviewCastStates then
            RefreshOverviewCastStates()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.spellName or "Buff")

        if self.groupWide then
            GameTooltip:AddLine(
                "Sort de groupe : un clic affecte tous les membres a portee.",
                1, 1, 1, true
            )
        else
            GameTooltip:AddLine(
                "Cible : " .. tostring(self.targetName or UnitName(self.unit) or self.unit),
                1, 1, 1
            )
        end

        if self.remainingSeconds and self.remainingSeconds > 0 then
            local minutes = math.floor((self.remainingSeconds + 59) / 60)
            GameTooltip:AddLine(
                "Temps restant : " .. tostring(minutes) .. " min",
                1, 0.82, 0
            )
        end

        GameTooltip:AddLine("Clic gauche : lancer le sort.", 0.8, 0.8, 0.8)

        local isLocked = self.groupWide
            and IsGroupLocked(self.family)
            or (self.targetName and IsIndividualLocked(self.family, self.targetName))
        if isLocked then
            GameTooltip:AddLine(
                "Clic droit : deverrouiller (retire du suivi).",
                1, 0.4, 0.4
            )
        else
            GameTooltip:AddLine(
                "Clic droit : verrouiller (toute la classe " ..
                tostring(self.className or "?") ..
                ") pour le suivi.",
                0.6, 1, 0.6, true
            )
        end

        if self.spellID then
            GameTooltip:AddLine("Spell ID : " .. tostring(self.spellID), 0.55, 0.55, 0.55)
        end
        if self.secureSpellName and self.secureSpellName ~= self.spellName then
            GameTooltip:AddLine(
                "Action exacte : " .. tostring(self.secureSpellName),
                0.55, 0.55, 0.55, true
            )
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    overviewCastButtons[index] = button
    return button
end

local function GetSpellIcon(spellID, spellName)
    if GetSpellInfo then
        local _, _, icon = GetSpellInfo(spellID or spellName)
        if icon then
            return icon
        end
    end

    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function FormatRemainingShort(remaining)
    remaining = math.max(0, tonumber(remaining) or 0)
    if remaining < 60 then
        return tostring(math.floor(remaining + 0.5)) .. "s"
    end

    return tostring(math.floor((remaining + 59) / 60)) .. "m"
end

local function SetOverviewButtonVisual(button, state, remaining)
    button.remainingSeconds = remaining
    button:SetText("")

    if button.timerText then
        if remaining and remaining > 0 and remaining <= BUFF_CRITICAL_SECONDS then
            button.timerText:SetText(FormatRemainingShort(remaining))
        else
            button.timerText:SetText(button.valueDisplay or "")
        end
    end

    if button.icon then
        if state == "DISABLED" then
            button.icon:SetVertexColor(0.35, 0.35, 0.35)
        else
            button.icon:SetVertexColor(1, 1, 1)
        end
    end

    if state == "ACTIVE" then
        button:SetBackdropBorderColor(0.15, 1, 0.25, 1)
    elseif state == "CRITICAL" then
        -- 10-minute heads-up tier: fires before the tighter 5-minute
        -- WARNING tier below, so this is a distinct, slightly darker red
        -- than OUT_OF_RANGE's brighter red to keep the two meanings
        -- visually distinguishable if they were ever both relevant.
        button:SetBackdropBorderColor(0.75, 0.05, 0.05, 1)
    elseif state == "WARNING" then
        button:SetBackdropBorderColor(1, 0.55, 0.05, 1)
    elseif state == "OUT_OF_RANGE" then
        button:SetBackdropBorderColor(1, 0.15, 0.15, 1)
    elseif state == "DISABLED" then
        button:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    else
        button:SetBackdropBorderColor(0.72, 0.72, 0.72, 1)
    end
end



local function GetRecommendedStatsForMember(member)
    if not member or not member.specToken or member.specToken == "" then
        return nil
    end

    local byClass = SPEC_RECOMMENDED_STATS[member.classToken]
    if not byClass then
        return nil
    end

    return byClass[member.specToken]
end

local function IsRecommendedStatForMember(member, category)
    local recommended = GetRecommendedStatsForMember(member)
    return recommended and recommended[category] and true or false
end

local function GetRecommendedStatsText(member)
    local recommended = GetRecommendedStatsForMember(member)
    if not recommended then
        return nil
    end

    local names = {}
    for _, category in ipairs(OVERVIEW_CATEGORY_ORDER) do
        if recommended[category] then
            table.insert(names, RECOMMENDED_STAT_NAMES[category] or category)
        end
    end

    if #names == 0 then
        return nil
    end

    return table.concat(names, " + ")
end

local function GetAutomaticCatalogEntry(member, category, preferredSpellID, requiredScope)
    if not member or not CoABuffDatabase or not CoABuffDatabase.classes then
        return nil
    end

    local classData = CoABuffDatabase.classes[member.classToken]
    if not classData or not classData.spells then
        return nil
    end

    local level = tonumber(member.level) or 0
    local best = nil
    local preferred = nil

    -- Confidence tiers for a spell being genuinely available to this member:
    --   1. Local player: confirmed directly from own spellbook (unchanged).
    --   2. Remote member who broadcast their known group-buff spellIDs via
    --      CoABuffComm: confirmed with the same precision as the local
    --      player, without guessing.
    --   3. Remote member who only broadcast their spec (no exact spellID
    --      list, e.g. addon version mismatch): filter to spells matching
    --      that spec, but still marked as "potential" since the exact rank
    --      learned is unknown.
    --   4. No comm data received at all: unchanged fallback behavior, every
    --      spell of the class is proposed as "potential".
    local hasRemoteSpellData = member.remoteKnownSpellIDs ~= nil
    local hasRemoteSpecData = member.specToken ~= nil and member.specToken ~= ""

    for _, spell in ipairs(classData.spells) do
        local requiredLevel = tonumber(spell.requiredLevel) or 0
        local effectValue = spell.effects and tonumber(spell.effects[category])
        local eligible = effectValue and requiredLevel <= level
            and IsAutomaticOverviewSpellVisible(spell)
            and (not requiredScope or spell.scope == requiredScope)
        local confirmed = false

        if eligible and member.isPlayer then
            confirmed = IsSpellKnownByID(spell.spellID)
            eligible = confirmed
        elseif eligible and hasRemoteSpellData then
            confirmed = spell.spellID
                and member.remoteKnownSpellIDs[tonumber(spell.spellID)] == true
            eligible = confirmed
        elseif eligible and hasRemoteSpecData and spell.spec then
            eligible = NormalizeSpecToken(spell.spec) == member.specToken
        end

        if eligible then
            -- Applies a VERIFIED "boosts this family by X%" talent detected
            -- for this specific member (see TALENT_VALUE_BOOSTS) -- local
            -- player via Talents.GetLocalBoosts, remote member via an inspect
            -- scan (Talents.ScanNearby). Falls back to the flat DB value
            -- when no boost was detected, exactly as before this existed.
            local boostPercent = member.talentBoosts
                and spell.family
                and member.talentBoosts[spell.family]
                or 0
            local boostedValue = effectValue
            if boostPercent > 0 then
                boostedValue = math.floor(effectValue * (1 + boostPercent / 100) + 0.5)
            end

            local candidate = {
                value = boostedValue,
                baseValue = effectValue,
                talentBoostPercent = boostPercent > 0 and boostPercent or nil,
                spell = spell.spellName,
                spellID = spell.spellID,
                rank = spell.rank,
                spec = spell.spec,
                scope = spell.scope,
                status = spell.status,
                note = spell.note,
                automatic = true,
                confirmed = confirmed,
                potential = not (member.isPlayer or confirmed),
                unit = spell.effectUnits and spell.effectUnits[category] or "FLAT",
                kind = spell.kind,
                family = spell.family,
            }

            if preferredSpellID
                and tonumber(spell.spellID) == tonumber(preferredSpellID) then
                preferred = candidate
            end

            if not best or boostedValue > best.value then
                best = candidate
            end
        end
    end

    return preferred or best
end

GetFamilyAuraNames = function(member, family, fallbackName)
    local names = {}
    local seen = {}

    local function AddName(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    AddName(fallbackName)

    if member and family and CoABuffDatabase and CoABuffDatabase.classes then
        local classData = CoABuffDatabase.classes[member.classToken]
        if classData and classData.spells then
            for _, spell in ipairs(classData.spells) do
                if spell.family == family then
                    AddName(spell.spellName)
                end
            end
        end
    end

    return names
end

-- Same idea as GetFamilyAuraNames, but aggregates spell names for the
-- family across EVERY class present in the roster, not just one member's
-- own class. This matters because a family locked as GROUP is checked
-- for "does everyone already have this buff" using only the caster's own
-- alias list -- so if two recipients instead received an individually-
-- cast "mono" version of the same family from a DIFFERENT class (a
-- different spell name entirely), the caster's own alias list would
-- never recognise it and would keep reporting them as still needing the
-- buff. Using the whole roster's classes closes that gap: any
-- teammate's version of the family (any class, rank, or scope) counts.
local function GetRosterFamilyAuraNames(family, roster, fallbackName)
    local names = {}
    local seen = {}

    local function AddName(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    AddName(fallbackName)

    if family and CoABuffDatabase and CoABuffDatabase.classes then
        local seenClasses = {}
        for _, member in ipairs(roster or {}) do
            local classToken = member.classToken
            if classToken and not seenClasses[classToken] then
                seenClasses[classToken] = true
                local classData = CoABuffDatabase.classes[classToken]
                if classData and classData.spells then
                    for _, spell in ipairs(classData.spells) do
                        if spell.family == family then
                            AddName(spell.spellName)
                        end
                    end
                end
            end
        end
    end

    return names
end

local function GetCatalogEntry(member, category)
    if not member then
        return nil
    end

    local byClass = CoABuffManagerDB.catalog[member.classToken]
    if byClass and byClass[category] then
        return byClass[category]
    end

    return GetAutomaticCatalogEntry(member, category)
end

-- Formats an entry's numeric value for display (e.g. "37", "48%",
-- "12/5s"), including the "~" suffix used for spells that are only a
-- deduced possibility rather than a confirmed known spell. Returns nil
-- if the entry has no usable numeric value (row/button should show no
-- text in that case).
local function FormatCategoryValue(entry)
    if not entry or not tonumber(entry.value) then
        return nil
    end

    local value = tonumber(entry.value)

    local displayValue = tostring(value)
    if entry.unit == "PERCENT" then
        displayValue = displayValue .. "%"
    elseif entry.unit == "PER_5_SEC" then
        displayValue = displayValue .. "/5s"
    end

    return displayValue
end

-- Builds one summary line per DISTINCT buff a class can bring ("Spell
-- Name : STAT value, STAT value, ..."), used to power the per-class "(i)"
-- hover on the roster column headers so a class with several distinct
-- buffs (e.g. Felsworn's Man'ari Intuition AND Illidari Intuition)
-- doesn't get flattened into a single ambiguous number.
--
-- The database stores every rank of a spell as its own entry, and a
-- "Greater" (group/raid-wide) version as a further separate entry sharing
-- the same `family` key -- e.g. Power Wuju has 6 rank entries plus a
-- "Greater Power Wuju" entry, all family = "POWER_WUJU". Grouped by family
-- (falling back to spellName if a spell has no family set): for each
-- non-resistance category the HIGHEST value seen across every rank/variant
-- in the family is shown (previously a single "representative" entry was
-- picked and always preferred single-target over Greater regardless of
-- actual value, which under-reported stats whenever Greater's number was
-- higher -- e.g. Greater Mark of Blaumeux's 62 spell power was hidden
-- behind the single-target rank's 49). Resistance categories are merged
-- the same way and shown with their specific element instead of a generic
-- "+ Resistance" tag.
local function GetClassBuffSummaryLines(classToken)
    local lines = {}
    if not classToken or not CoABuffDatabase or not CoABuffDatabase.classes then
        return lines
    end

    local classData = CoABuffDatabase.classes[classToken]
    if not classData or not classData.spells then
        return lines
    end

    local groups = {}
    local order = {}
    for _, spell in ipairs(classData.spells) do
        if IsAutomaticOverviewSpellVisible(spell) and spell.effects then
            local key = spell.family or spell.spellName or "?"
            if not groups[key] then
                groups[key] = {}
                table.insert(order, key)
            end
            table.insert(groups[key], spell)
        end
    end

    for _, key in ipairs(order) do
        local entries = groups[key]
        local best, bestScore
        local bestStat, bestResist = {}, {}

        for _, spell in ipairs(entries) do
            local score = 0
            for category, value in pairs(spell.effects) do
                local numeric = tonumber(value) or 0
                local unit = spell.effectUnits and spell.effectUnits[category] or "FLAT"
                local bucket = IsResistanceCategory(category) and bestResist or bestStat
                if not bucket[category] or numeric > bucket[category].value then
                    bucket[category] = { value = numeric, unit = unit }
                end
                if not IsResistanceCategory(category) then
                    score = score + numeric
                end
            end

            -- The displayed spell NAME still needs one representative entry;
            -- pick it by highest non-resistance score so it corresponds to
            -- whichever rank actually carries the best stats shown below.
            if not best or score > bestScore then
                best = spell
                bestScore = score
            end
        end

        if best then
            local statParts = {}
            for category, entry in pairs(bestStat) do
                local formatted = FormatCategoryValue(entry)
                if formatted then
                    local displayName = STAT_DISPLAY_NAMES[category] or category
                    table.insert(
                        statParts,
                        "|cff66cc66" .. displayName .. " " .. formatted .. "|r"
                    )
                end
            end
            for category, entry in pairs(bestResist) do
                local formatted = FormatCategoryValue(entry)
                if formatted then
                    local displayName = RESISTANCE_DISPLAY_NAMES[category] or category
                    table.insert(
                        statParts,
                        "|cff888888" .. displayName .. " " .. formatted .. "|r"
                    )
                end
            end
            table.sort(statParts)

            if #statParts > 0 then
                local line = (best.spellName or "?") .. " : " .. table.concat(statParts, ", ")
                table.insert(lines, line)
            end
        end
    end

    return lines
end

local function CollectCategoriesForRoster(roster)
    local seen = {}
    local categories = {}

    local function AddCategory(category)
        if IsOverviewCategoryHidden(category) then
            return
        end

        if not seen[category] then
            seen[category] = true
            table.insert(categories, category)
        end
    end

    for _, member in ipairs(roster) do
        local manual = CoABuffManagerDB.catalog[member.classToken]
        if manual then
            for category in pairs(manual) do
                AddCategory(category)
            end
        end

        if CoABuffDatabase and CoABuffDatabase.classes then
            local classData = CoABuffDatabase.classes[member.classToken]
            if classData and classData.spells then
                for _, spell in ipairs(classData.spells) do
                    local requiredLevel = tonumber(spell.requiredLevel) or 0
                    local eligible = requiredLevel <= (tonumber(member.level) or 0)
                        and IsAutomaticOverviewSpellVisible(spell)

                    if eligible and member.isPlayer then
                        eligible = IsSpellKnownByID(spell.spellID)
                    end

                    if eligible then
                        for category in pairs(spell.effects or {}) do
                            AddCategory(category)
                        end
                    end
                end
            end
        end
    end

    table.sort(categories, function(a, b)
        local priorityA = OVERVIEW_CATEGORY_PRIORITY[a] or 1000
        local priorityB = OVERVIEW_CATEGORY_PRIORITY[b] or 1000

        if priorityA == priorityB then
            return a < b
        end

        return priorityA < priorityB
    end)
    return categories
end

local function GetPlayerMemberFromRoster(roster)
    for _, member in ipairs(roster or {}) do
        if member.isPlayer then
            return member
        end
    end
    return nil
end

-- Resolves a locked target's display name back to its current unit ID
-- (e.g. "party2", or "player" for the caster themself) using the live
-- roster. Macro text conditions like [target=NAME] only reliably support
-- generic unit IDs (player/partyN/raidN), not literal player names, so the
-- macro generator must translate names to unit IDs at generation time
-- rather than writing the name directly into the macro body. Returns nil
-- if the named target is no longer in the group (disconnected, left,
-- etc.), so the caller can skip that line instead of writing an invalid
-- reference into the macro.
local function ResolveTargetNameToUnit(roster, targetName)
    for _, member in ipairs(roster or {}) do
        if member.name == targetName then
            return member.unit
        end
    end
    return nil
end

-- Finds the local player's best known (highest-value) spell of a given
-- family and scope, e.g. family="MARK_OF_KORTHAZZ", scope="PARTY_RAID".
-- Only spells actually confirmed via IsSpellKnownByID are considered: the
-- macro generator must never write a /cast line for a spell the player
-- does not truly have, since that would silently no-op in game.
local function GetBestKnownSpellForFamily(playerMember, family, scope)
    if not playerMember or not family or not CoABuffDatabase or not CoABuffDatabase.classes then
        return nil
    end

    local classData = CoABuffDatabase.classes[playerMember.classToken]
    if not classData or not classData.spells then
        return nil
    end

    local level = tonumber(playerMember.level) or 0
    local best = nil

    for _, spell in ipairs(classData.spells) do
        if spell.family == family and spell.scope == scope then
            local requiredLevel = tonumber(spell.requiredLevel) or 0
            if requiredLevel <= level
                and IsCastableForMacroSpell(spell)
                and IsSpellKnownByID(spell.spellID) then

                local effectValue = 0
                if spell.effects then
                    for _, value in pairs(spell.effects) do
                        local numeric = tonumber(value)
                        if numeric and numeric > effectValue then
                            effectValue = numeric
                        end
                    end
                end

                if not best or effectValue > best.value then
                    best = {
                        value = effectValue,
                        spell = spell.spellName,
                        spellID = spell.spellID,
                        scope = spell.scope,
                        family = spell.family,
                    }
                end
            end
        end
    end

    return best
end

-- Anti-repeat tracking: remembers the last time (GetTime()) each locked
-- target name was auto-buffed, so PickBestTargetForFamily never re-picks
-- the same recipient twice within AUTO_BUFF_REPEAT_GUARD_SECONDS. This is
-- our equivalent of PallyPower's AutoBuffedList: without it, a fast
-- double-click (or PreClick firing again before the aura has landed)
-- could waste a cast re-buffing whoever was just picked instead of
-- moving on to the next person who still needs it.
local autoBuffedAt = {}
local AUTO_BUFF_REPEAT_GUARD_SECONDS = 2

-- Picks the best recipient for a locked family's auto-cast button, meant
-- to be called from that button's PreClick handler (see
-- GetAutoFamilyButton), outside combat only. Mirrors PallyPower's
-- ClassifyUnitBuffStateForButton priority: anyone with no buff at all
-- always outranks someone whose buff is merely expiring soon.
--
-- GROUP mode has nothing to individually target -- a Greater/group cast
-- affects everyone in range of the caster automatically -- so it just
-- confirms at least one eligible member still needs it, to avoid
-- spamming an already-fully-buffed group.
--
-- INDIVIDUAL mode picks whichever locked target most needs the buff
-- right now (missing entirely first, then soonest-to-expire among those
-- who already have it), resolving names to live unit IDs the same way
-- BuildMacroThenAll does for the /castsequence fallback.
--
-- Returns unit, spellName, spellID, or nil if there is nothing to do
-- (e.g. no lock for this family, no known spell, or everyone eligible is
-- already buffed).
local function PickBestTargetForFamily(family, roster, playerMember)
    local lock = CoABuffManagerDB.macroLocks and CoABuffManagerDB.macroLocks[family]
    if not lock then
        return nil
    end

    local scope = (lock.mode == "GROUP") and "PARTY_RAID" or "ALLY"
    local best = GetBestKnownSpellForFamily(playerMember, family, scope)
    if not best or not best.spell then
        return nil
    end

    local auraNames = GetRosterFamilyAuraNames(family, roster, best.spell)

    if lock.mode == "GROUP" then
        for _, member in ipairs(roster or {}) do
            if UnitExists(member.unit)
                and UnitIsConnected(member.unit)
                and not UnitIsDeadOrGhost(member.unit) then
                local hasAura = UnitHasAura(member.unit, best.spell, best.spellID, auraNames)
                if not hasAura then
                    return "player", best.spell, best.spellID
                end
            end
        end
        return nil
    end

    if lock.mode == "INDIVIDUAL" and lock.targets then
        local now = GetTime()
        local chosenUnit, chosenName, chosenRemaining = nil, nil, math.huge

        for targetName in pairs(lock.targets) do
            local unit = ResolveTargetNameToUnit(roster, targetName)
            if unit and UnitExists(unit)
                and UnitIsConnected(unit)
                and not UnitIsDeadOrGhost(unit) then

                local recentlyBuffed = autoBuffedAt[targetName]
                    and (now - autoBuffedAt[targetName]) < AUTO_BUFF_REPEAT_GUARD_SECONDS

                if not recentlyBuffed then
                    local hasAura, expirationTime = UnitHasAura(
                        unit, best.spell, best.spellID, auraNames
                    )
                    local remaining
                    if not hasAura then
                        remaining = -1 -- missing entirely: always highest priority
                    elseif expirationTime and expirationTime > 0 then
                        remaining = expirationTime - now
                    else
                        remaining = math.huge -- permanent/no-expiry aura: never a priority
                    end

                    if remaining < chosenRemaining then
                        chosenRemaining = remaining
                        chosenUnit = unit
                        chosenName = targetName
                    end
                end
            end
        end

        if chosenUnit then
            autoBuffedAt[chosenName] = now
            return chosenUnit, best.spell, best.spellID
        end
    end

    return nil
end

-- Creates (once) a single secure auto-cast button for a locked family.
-- Unlike our per-member cast buttons (ConfigureSecureSpellButton), whose
-- attributes are refreshed on a periodic UI timer, this button recomputes
-- its target/spell in a PreClick handler -- i.e. at the instant just
-- before the click actually fires, outside combat. This closes the
-- "staleness window" a timer-based refresh always has: the recipient
-- choice can never be older than the time since the player's own last
-- click. This is the mechanism PallyPower calls its "smart button".
--
-- SetAttribute is blocked by InCombatLockdown(), so once combat starts
-- this button freezes on whatever it last had. BUFF THEM ALL's
-- /castsequence macro (regenerated on PLAYER_REGEN_DISABLED, see the
-- event handler below) is the intended fallback for continuing to buff
-- once combat has begun -- see BuildMacroThenAll's comment for why a
-- /castsequence, rather than several plain /cast lines, is needed there.
local autoFamilyButtons = {}

-- Counts, for a locked family, how many eligible recipients still need
-- the buff right now -- the number shown on the auto-cast button's badge
-- so the player knows how many times to click, mirroring PallyPower's
-- per-class "nneed" counter on its class buttons. Returns nil if the
-- family isn't locked or no known spell covers it (button should be
-- hidden in that case), 0 if everyone eligible already has it.
local function CountFamilyBuffsNeeded(family, roster, playerMember)
    local lock = CoABuffManagerDB.macroLocks and CoABuffManagerDB.macroLocks[family]
    if not lock then
        return nil
    end

    local scope = (lock.mode == "GROUP") and "PARTY_RAID" or "ALLY"
    local best = GetBestKnownSpellForFamily(playerMember, family, scope)
    if not best or not best.spell then
        return nil
    end

    local auraNames = GetRosterFamilyAuraNames(family, roster, best.spell)
    local needed = 0

    if lock.mode == "GROUP" then
        for _, member in ipairs(roster or {}) do
            if UnitExists(member.unit)
                and UnitIsConnected(member.unit)
                and not UnitIsDeadOrGhost(member.unit) then
                if not UnitHasAura(member.unit, best.spell, best.spellID, auraNames) then
                    needed = needed + 1
                end
            end
        end
    elseif lock.mode == "INDIVIDUAL" and lock.targets then
        for targetName in pairs(lock.targets) do
            local unit = ResolveTargetNameToUnit(roster, targetName)
            if unit and UnitExists(unit)
                and UnitIsConnected(unit)
                and not UnitIsDeadOrGhost(unit) then
                if not UnitHasAura(unit, best.spell, best.spellID, auraNames) then
                    needed = needed + 1
                end
            end
        end
    end

    return needed
end

-- Refreshes an auto-family button's badge text in place, without
-- rebuilding the whole overview panel. Safe to call frequently (periodic
-- refresh) since it does no frame creation, just SetText.
local function RefreshAutoFamilyButtonBadge(button, family, roster, playerMember)
    local needed = CountFamilyBuffsNeeded(family, roster, playerMember)
    if not needed then
        button:SetText(family)
    elseif needed == 0 then
        button:SetText(family .. " |cff33ff33(pret)|r")
    else
        button:SetText(family .. " |cffffcc00(" .. needed .. ")|r")
    end
end

local function GetAutoFamilyButton(family)
    if autoFamilyButtons[family] then
        return autoFamilyButtons[family]
    end

    local button = CreateFrame(
        "Button",
        ADDON_NAME .. "AutoFamily" .. family,
        panels.overview,
        "SecureActionButtonTemplate,UIPanelButtonTemplate"
    )
    button:RegisterForClicks("LeftButtonUp")
    button:SetWidth(ACTION_WIDTH - 8)
    button:SetHeight(OVERVIEW_ROW_HEIGHT - 6)
    button:SetText(family)
    button:Hide()

    button:SetScript("PreClick", function(self)
        if InCombatLockdown() then
            -- Attributes are frozen for the duration of combat; leave
            -- whatever was set last in effect rather than attempt (and
            -- fail) to change it.
            return
        end

        local roster = GetRoster()
        local playerMember = GetPlayerMemberFromRoster(roster)
        local unit, spellName = PickBestTargetForFamily(family, roster, playerMember)

        if unit and spellName then
            self:SetAttribute("type1", "spell")
            self:SetAttribute("spell1", spellName)
            self:SetAttribute("unit1", unit)
        else
            -- Nothing left to buff right now: clear the spell attribute
            -- so an idle click can never re-cast on a stale target.
            self:SetAttribute("type1", nil)
            self:SetAttribute("spell1", nil)
            self:SetAttribute("unit1", nil)
        end
    end)

    button:SetScript("PostClick", function(self)
        -- Badge feedback right after the click, without waiting for the
        -- next periodic refresh -- same spirit as PallyPower's
        -- UpdateButtonOnPostClick.
        local roster = GetRoster()
        local playerMember = GetPlayerMemberFromRoster(roster)
        RefreshAutoFamilyButtonBadge(self, family, roster, playerMember)
    end)

    autoFamilyButtons[family] = button
    return button
end

-- Hides every cached auto-family button. Called at the start of every
-- RebuildOverviewPanel, mirroring HideCollection for the other
-- index-keyed button pools -- this one is keyed by family name instead,
-- so it needs its own loop.
local function HideAllAutoFamilyButtons()
    for _, button in pairs(autoFamilyButtons) do
        button:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Floating tracker HUD
--
-- A small, movable, semi-transparent window listing every family the
-- player has locked (see the macro lock system above), one row per
-- family. Each row shows: the family's spell icon, a countdown in
-- minutes/seconds that changes colour as it approaches expiry (mirroring
-- SetOverviewButtonVisual's ACTIVE/CRITICAL/WARNING tiers), and is itself
-- clickable -- reusing the exact same PreClick "smart button" mechanism
-- as the Overview tab's auto-family button (PickBestTargetForFamily), so
-- clicking a row re-buffs whichever eligible recipient needs it most.
--
-- Combat behaviour: PreClick can no longer recompute a secure button's
-- target once combat starts (SetAttribute is blocked by
-- InCombatLockdown()), so a HUD row clicked mid-fight would silently
-- freeze on a stale target rather than adapt -- worse than no button at
-- all. The HUD is therefore hidden for the full duration of combat
-- (PLAYER_REGEN_DISABLED) and only reappears after combat ends
-- (PLAYER_REGEN_ENABLED), same as BUFF THEM ALL's macro-regeneration
-- fallback is the intended tool for buffing mid-fight.
local trackerFrame
local trackerRows = {}
local FALLBACK_ICON_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"
local TRACKER_ROW_HEIGHT = 34
local TRACKER_WIDTH = 44
-- Historically an extra strip reserved below the title bar for a "Buff
-- Them All" macro button (removed -- the macro system was unreliable
-- past a handful of locks, see BuildMacroThenAll's removal). Kept at 0
-- rather than deleted outright so every height/anchor computation below
-- that already adds it doesn't need touching.
local TRACKER_BUFFALL_ROW_HEIGHT = 0

-- Computes, for a locked family, both the number of eligible recipients
-- still missing the buff (see CountFamilyBuffsNeeded) and the minimum
-- remaining duration among recipients who already have it, in a single
-- pass. Returns needed, minimumRemaining, spellName, spellID -- or nil if
-- the family isn't locked or no known spell covers it (row should stay
-- hidden in that case).
local function GetFamilyTrackerStatus(family, roster, playerMember)
    local lock = CoABuffManagerDB.macroLocks and CoABuffManagerDB.macroLocks[family]
    if not lock then
        return nil
    end

    local scope = (lock.mode == "GROUP") and "PARTY_RAID" or "ALLY"
    local best = GetBestKnownSpellForFamily(playerMember, family, scope)
    if not best or not best.spell then
        return nil
    end

    local auraNames = GetRosterFamilyAuraNames(family, roster, best.spell)
    local needed = 0
    local minimumRemaining = nil
    -- Names locked into this family who are currently dead or offline --
    -- excluded from `needed` above (can't buff a corpse), but surfaced
    -- separately so the tooltip can remind the player to rebuff them once
    -- they're back up, instead of the group quietly forgetting they exist.
    local deadNames = {}

    local function CheckUnit(unit)
        local hasAura, expirationTime = UnitHasAura(
            unit, best.spell, best.spellID, auraNames
        )
        if not hasAura then
            needed = needed + 1
        elseif expirationTime and expirationTime > 0 then
            local remaining = math.max(0, expirationTime - GetTime())
            if not minimumRemaining or remaining < minimumRemaining then
                minimumRemaining = remaining
            end
        end
    end

    if lock.mode == "GROUP" then
        for _, member in ipairs(roster or {}) do
            if UnitExists(member.unit) and UnitIsConnected(member.unit) then
                if UnitIsDeadOrGhost(member.unit) then
                    table.insert(deadNames, member.name)
                else
                    CheckUnit(member.unit)
                end
            end
        end
    elseif lock.mode == "INDIVIDUAL" and lock.targets then
        for targetName in pairs(lock.targets) do
            local unit = ResolveTargetNameToUnit(roster, targetName)
            if unit and UnitExists(unit) and UnitIsConnected(unit) then
                if UnitIsDeadOrGhost(unit) then
                    table.insert(deadNames, targetName)
                else
                    CheckUnit(unit)
                end
            end
        end
    end

    table.sort(deadNames)
    return needed, minimumRemaining, best.spell, best.spellID, deadNames
end

-- Applies row colouring/text for a given status. Mirrors the four-tier
-- scheme used elsewhere (missing entirely / critical / warning / fully
-- buffed and safe), but always shows the timer in minutes -- unlike the
-- Overview buttons, which only surface a countdown once it is close to
-- expiring.
local function SetTrackerRowVisual(row, needed, minimumRemaining)
    if needed and needed > 0 then
        row.border:SetBackdropBorderColor(1, 0.15, 0.15, 1)
        row.timerText:SetText("|cffff3333-" .. needed .. "|r")
        return
    end

    if not minimumRemaining then
        row.border:SetBackdropBorderColor(0.15, 1, 0.25, 1)
        row.timerText:SetText("")
        return
    end

    local label = FormatRemainingShort(minimumRemaining)
    if minimumRemaining <= BUFF_WARNING_SECONDS then
        row.border:SetBackdropBorderColor(1, 0.55, 0.05, 1)
        row.timerText:SetText("|cffffcc00" .. label .. "|r")
    elseif minimumRemaining <= BUFF_CRITICAL_SECONDS then
        row.border:SetBackdropBorderColor(0.75, 0.05, 0.05, 1)
        row.timerText:SetText("|cffff8888" .. label .. "|r")
    else
        row.border:SetBackdropBorderColor(0.15, 1, 0.25, 1)
        row.timerText:SetText("|cff33ff33" .. label .. "|r")
    end
end

-- Creates (once) the movable tracker frame and returns it. Kept minimal:
-- a title bar (drag handle + close button) and a container the rows are
-- anchored into by RefreshTrackerHUD.
local function EnsureTrackerFrame()
    if trackerFrame then
        return trackerFrame
    end

    trackerFrame = CreateFrame("Frame", ADDON_NAME .. "TrackerHUD", UIParent)
    trackerFrame:SetWidth(TRACKER_WIDTH)
    trackerFrame:SetHeight(TRACKER_ROW_HEIGHT + 20 + TRACKER_BUFFALL_ROW_HEIGHT)
    trackerFrame:SetClampedToScreen(true)
    trackerFrame:SetMovable(true)
    trackerFrame:RegisterForDrag("LeftButton")
    trackerFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    trackerFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        CoABuffManagerDB.trackerHUD.point = {
            point = point,
            relativePoint = relativePoint,
            x = x,
            y = y,
        }
    end)

    -- Locked by default: dragging the background is disabled so the HUD
    -- can't be nudged by accident while clicking rows in a busy fight.
    -- The Reglages panel's "Deverrouiller" checkbox toggles this.
    trackerFrame:EnableMouse(not CoABuffManagerDB.trackerHUD.locked)

    trackerFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    -- Semi-transparent background as requested -- readable in combat
    -- lighting without covering the action underneath it.
    trackerFrame:SetBackdropColor(0, 0, 0, CoABuffManagerDB.trackerHUD.opacity or 0.45)
    trackerFrame:SetBackdropBorderColor(0, 0, 0, 0.6)

    local savedPoint = CoABuffManagerDB.trackerHUD.point
    if savedPoint then
        trackerFrame:SetPoint(
            savedPoint.point or "CENTER",
            UIParent,
            savedPoint.relativePoint or "CENTER",
            savedPoint.x or 0,
            savedPoint.y or 0
        )
    else
        trackerFrame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 120)
    end

    local closeButton = CreateFrame("Button", nil, trackerFrame, "UIPanelCloseButton")
    closeButton:SetWidth(16)
    closeButton:SetHeight(16)
    closeButton:SetPoint("TOPRIGHT", trackerFrame, "TOPRIGHT", 2, 2)
    closeButton:SetScript("OnClick", function()
        CoABuffManagerDB.trackerHUD.mode = "never"
        -- Rows are SecureActionButtonTemplate buttons, so Blizzard blocks
        -- Hide() on their parent frame during combat ("AddOn ... prevented
        -- the call of the secure function ... Hide()") even from a real
        -- button click. Skip it here; PLAYER_REGEN_ENABLED's
        -- RefreshTrackerHUD() call picks mode="never" up and hides it
        -- safely the moment combat lockdown lifts.
        if InCombatLockdown() then
            Print("Suivi masque une fois le combat termine. /cbm hud ou Reglages pour le reafficher.")
        else
            trackerFrame:Hide()
            Print("Suivi masque. /cbm hud ou Reglages pour le reafficher.")
        end
    end)

    -- Quick shortcut to the main /cbm window, so the HUD doesn't require
    -- remembering the slash command or having a macro on the action bar.
    local openButton = CreateFrame("Button", nil, trackerFrame, "UIPanelButtonTemplate")
    openButton:SetWidth(16)
    openButton:SetHeight(16)
    openButton:SetPoint("TOPLEFT", trackerFrame, "TOPLEFT", 2, 2)
    openButton:SetText("=")
    openButton:SetScript("OnClick", function()
        if mainFrame then
            if mainFrame:IsShown() then
                mainFrame:Hide()
            else
                mainFrame:Show()
            end
        end
    end)
    openButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Ouvrir/fermer CoA Buff Manager (/cbm)")
        GameTooltip:Show()
    end)
    openButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    trackerFrame:Hide()
    return trackerFrame
end

-- Toggles whether the HUD's background can be dragged. Called from the
-- Reglages panel's "Deverrouiller" checkbox; the frame must already
-- exist (EnsureTrackerFrame) for this to have anything to act on -- if
-- it doesn't yet, the locked flag saved in the DB is applied the moment
-- EnsureTrackerFrame first creates it.
SetTrackerFrameLocked = function(isLocked)
    if not trackerFrame then
        return
    end
    trackerFrame:EnableMouse(not isLocked)
end

-- Applies the saved opacity to the HUD's background. Called from the
-- Reglages panel's opacity slider; if the frame doesn't exist yet, the
-- value saved in the DB is simply picked up whenever EnsureTrackerFrame
-- first creates it.
SetTrackerFrameOpacity = function(value)
    if not trackerFrame then
        return
    end
    trackerFrame:SetBackdropColor(0, 0, 0, value)
end

-- Applies the saved background opacity to the main /cbm window (Overview/
-- Reglages). Only the background fades -- buttons, icons and text keep
-- full opacity so the window stays fully readable and clickable even
-- when mostly see-through. Which layer it applies to (plain black fill
-- vs the parchment texture) depends on CoABuffManagerDB.mainWindowBackground
-- -- see ApplyMainWindowBackground below. Called from the Reglages
-- panel's "Opacite de la fenetre principale" slider.
SetMainFrameOpacity = function(value)
    if not mainFrame then
        return
    end
    if CoABuffManagerDB.mainWindowBackground == "parchment" then
        if mainFrame.parchmentTexture then
            mainFrame.parchmentTexture:SetAlpha(value)
        end
    else
        mainFrame:SetBackdropColor(0, 0, 0, value)
    end
end

-- Switches the main window's background between the parchment artwork
-- and a plain black fill (see Reglages' "Fond" choice). Only one of the
-- two layers is ever visible at a time: the backdrop's own colour fill
-- is made fully transparent while the parchment texture is shown, and
-- vice versa, so they never show through one another.
ApplyMainWindowBackground = function()
    if not mainFrame then
        return
    end
    EnsureDB()

    local opacity = CoABuffManagerDB.mainWindowOpacity or 1.0
    if CoABuffManagerDB.mainWindowBackground == "parchment" then
        mainFrame:SetBackdropColor(0, 0, 0, 0)
        if mainFrame.parchmentTexture then
            mainFrame.parchmentTexture:SetAlpha(opacity)
            mainFrame.parchmentTexture:Show()
        end
    else
        if mainFrame.parchmentTexture then
            mainFrame.parchmentTexture:Hide()
        end
        mainFrame:SetBackdropColor(0, 0, 0, opacity)
    end
end

-- Creates (once) a single tracker row for a family: a secure clickable
-- button spanning the row, with an icon, a family label, and a timer
-- string. The click behaviour (PreClick/PostClick) is deliberately the
-- same pattern as GetAutoFamilyButton's -- see that function's comment
-- for why PreClick (rather than a periodically-refreshed attribute) is
-- required for the recipient choice to never be stale.
local function GetTrackerRow(family)
    if trackerRows[family] then
        return trackerRows[family]
    end

    local frame = EnsureTrackerFrame()

    local row = CreateFrame(
        "Button",
        ADDON_NAME .. "TrackerRow" .. family,
        frame,
        "SecureActionButtonTemplate"
    )
    row:RegisterForClicks("LeftButtonUp")
    row:SetWidth(TRACKER_WIDTH - 8)
    row:SetHeight(TRACKER_ROW_HEIGHT - 2)

    row.border = CreateFrame("Frame", nil, row)
    row.border:SetAllPoints(row)
    row.border:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row.border:SetBackdropColor(1, 1, 1, 0.08)
    row.border:SetFrameLevel(row:GetFrameLevel())

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(TRACKER_ROW_HEIGHT - 8)
    row.icon:SetHeight(TRACKER_ROW_HEIGHT - 8)
    row.icon:SetPoint("CENTER", row, "CENTER", 0, 2)

    -- Small red marker in the corner when another same-class player has
    -- also locked this family (see the "aussi verrouille par" tooltip in
    -- OnEnter below) -- kept minimal since the row no longer has room
    -- for a name label.
    row.conflictText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.conflictText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 1, 1)
    row.conflictText:SetText("")

    -- Small marker, opposite corner from conflictText, when someone
    -- locked into this family is dead/offline (see GetFamilyTrackerStatus'
    -- deadNames) -- full names are in the OnEnter tooltip below, this is
    -- just "someone needs a rebuff once they're back up".
    row.deadText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.deadText:SetPoint("TOPLEFT", row, "TOPLEFT", -1, 1)
    row.deadText:SetText("")

    row.timerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.timerText:SetPoint("BOTTOM", row, "BOTTOM", 0, 1)
    -- Bigger + outlined: the "-N missing" count (see SetTrackerRowVisual)
    -- was hard to read at the base GameFontNormalSmall size sitting right
    -- on top of a busy spell icon with no outline for contrast.
    do
        local timerFont = row.timerText:GetFont()
        row.timerText:SetFont(timerFont, 13, "OUTLINE")
    end

    row:SetScript("PreClick", function(self)
        if InCombatLockdown() then
            return
        end

        local roster = GetRoster()
        local playerMember = GetPlayerMemberFromRoster(roster)
        local unit, spellName = PickBestTargetForFamily(family, roster, playerMember)

        if unit and spellName then
            self:SetAttribute("type1", "spell")
            self:SetAttribute("spell1", spellName)
            self:SetAttribute("unit1", unit)
        else
            self:SetAttribute("type1", nil)
            self:SetAttribute("spell1", nil)
            self:SetAttribute("unit1", nil)
        end
    end)

    row:SetScript("PostClick", function()
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
    end)

    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(family)
        GameTooltip:AddLine("Clic gauche : buffer le prochain manquant.", 0.8, 0.8, 0.8)

        local roster = GetRoster()
        local playerMember = GetPlayerMemberFromRoster(roster)
        local conflicts = GetSameClassLockConflicts and
            GetSameClassLockConflicts(family, roster, playerMember) or {}
        if #conflicts > 0 then
            table.sort(conflicts)
            GameTooltip:AddLine(
                "Aussi verrouille par " .. table.concat(conflicts, ", "),
                1, 0.2, 0.2
            )
        end

        if self.deadNames and #self.deadNames > 0 then
            GameTooltip:AddLine(
                "Mort/deco, a rebuff : " .. table.concat(self.deadNames, ", "),
                1, 0.5, 0.1
            )
        end

        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    trackerRows[family] = row
    return row
end

-- Rebuilds the tracker's row list from the current macro locks and
-- refreshes their status. Cheap enough to call from the same 1-second
-- scan as RefreshOverviewCastStates (see the OnUpdate handler near the
-- bottom of this file) -- it does no frame creation beyond the first
-- time a given family is locked.
RefreshTrackerHUD = function()
    if not CoABuffManagerDB or not CoABuffManagerDB.trackerHUD then
        return
    end

    local mode = CoABuffManagerDB.trackerHUD.mode or "auto"
    local inCombat = InCombatLockdown()

    if mode == "never" then
        -- Rows are SecureActionButtonTemplate buttons, so Blizzard blocks
        -- Hide() on their parent frame during combat ("AddOn ... prevented
        -- the call of the secure function ... Hide()"). If this fires
        -- mid-combat, skip it -- PLAYER_REGEN_ENABLED calls
        -- RefreshTrackerHUD() again once lockdown lifts, which reaches
        -- here safely and hides it then.
        if trackerFrame and not inCombat then
            trackerFrame:Hide()
        end
        return
    end

    -- "always" is the one case that stays up through combat -- as a
    -- read-only display, since aura/timer data keeps updating even
    -- though PreClick can no longer retarget the rows (see the module
    -- comment at the top of this section).
    if mode == "auto" and inCombat then
        -- Can't Hide() here either (same secure-child restriction as
        -- above) -- if the frame was already hidden before combat this is
        -- a no-op anyway; if it was visible, it stays up until combat
        -- ends and this function runs again.
        return
    end

    local roster = GetRoster()
    local playerMember = GetPlayerMemberFromRoster(roster)

    if inCombat then
        -- Rows are SecureActionButtonTemplate buttons (needed for the
        -- click-to-cast PreClick). Blizzard blocks insecure (addon) code
        -- from calling Show/Hide/SetPoint on them during combat --
        -- attempting it throws "AddOn ... prevented the call of the
        -- secure function ... Hide()". So while in combat we only ever
        -- update colour/text on rows that are ALREADY shown from before
        -- combat started; visibility and layout are untouched until
        -- combat ends and the full rebuild below can run again safely.
        for family, row in pairs(trackerRows) do
            if row:IsShown() then
                local needed, minimumRemaining, _, _, deadNames =
                    GetFamilyTrackerStatus(family, roster, playerMember)
                if needed ~= nil then
                    SetTrackerRowVisual(row, needed, minimumRemaining)
                    row.deadNames = deadNames
                    row.deadText:SetText(#deadNames > 0 and "|cffff8800+|r" or "")
                end
            end
        end
        return
    end

    local families = {}
    for family in pairs(CoABuffManagerDB.macroLocks or {}) do
        table.insert(families, family)
    end
    table.sort(families, function(a, b)
        local priorityA = OVERVIEW_CATEGORY_PRIORITY[a] or 1000
        local priorityB = OVERVIEW_CATEGORY_PRIORITY[b] or 1000
        if priorityA == priorityB then
            return a < b
        end
        return priorityA < priorityB
    end)

    for _, row in pairs(trackerRows) do
        row:Hide()
    end

    local frame = EnsureTrackerFrame()
    local visibleCount = 0

    for _, family in ipairs(families) do
        local needed, minimumRemaining, spellName, spellID, deadNames =
            GetFamilyTrackerStatus(family, roster, playerMember)

        if needed ~= nil then
            visibleCount = visibleCount + 1
            local row = GetTrackerRow(family)
            row:ClearAllPoints()
            row:SetPoint(
                "TOPLEFT",
                frame,
                "TOPLEFT",
                4,
                -20 - TRACKER_BUFFALL_ROW_HEIGHT - ((visibleCount - 1) * TRACKER_ROW_HEIGHT)
            )
            local conflicts = GetSameClassLockConflicts and
                GetSameClassLockConflicts(family, roster, playerMember) or {}
            if #conflicts > 0 then
                row.conflictText:SetText("|cffff2222!|r")
            else
                row.conflictText:SetText("")
            end

            row.deadNames = deadNames
            row.deadText:SetText(#deadNames > 0 and "|cffff8800+|r" or "")

            local _, _, icon = GetSpellInfo(spellID or spellName)
            row.icon:SetTexture(icon or FALLBACK_ICON_TEXTURE)

            SetTrackerRowVisual(row, needed, minimumRemaining)
            row:Show()
        end
    end

    if visibleCount == 0 then
        frame:Hide()
        return
    end

    frame:SetHeight(20 + TRACKER_BUFFALL_ROW_HEIGHT + (visibleCount * TRACKER_ROW_HEIGHT) + 4)
    frame:Show()
end

local MACRO_ICON_TEXTURE = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local MACRO_ICON_FALLBACK_INDEX = 1 -- Blizzard's generic question-mark icon, always valid.

-- CreateMacro/EditMacro's second argument (iconIndex) is documented as a
-- numeric index into Blizzard's built-in macro icon list on some clients,
-- while others accept a texture path string. Rather than guess a specific
-- numeric index for a clock icon (risking another wrong-type error), this
-- tries the texture path first, then falls back to the universally valid
-- generic icon index, so macro creation never hard-fails over cosmetics.
local function CreateOrUpdateMacro(macroName, body, perCharacter)
    if not CreateMacro or not EditMacro or not GetMacroIndexByName then
        Print("API de macro indisponible sur ce client ; macro non generee.")
        return false
    end

    local existingIndex = GetMacroIndexByName(macroName)
    local isUpdate = existingIndex and existingIndex > 0

    local function TryIcon(icon)
        if isUpdate then
            return pcall(EditMacro, existingIndex, macroName, icon, body, perCharacter)
        else
            return pcall(CreateMacro, macroName, icon, body, perCharacter)
        end
    end

    local ok, err = TryIcon(MACRO_ICON_TEXTURE)

    if not ok then
        ok, err = TryIcon(MACRO_ICON_FALLBACK_INDEX)
    end

    if not ok then
        Print("Impossible de creer/mettre a jour la macro " .. macroName .. " : " .. tostring(err))
        return false
    end

    return true
end

-- The "BUFF THEM ALL" /castsequence macro generator used to live here.
-- Removed: past a handful of locked families the generated body routinely
-- exceeded WoW's 255-character macro limit and silently failed to update,
-- and multi-target /castsequence stepping was unreliable to begin with.
-- Buffing now goes exclusively through the per-family Overview buttons
-- and tracker HUD rows (each independently clickable, no ordering or
-- length limit to fight). RequestMacroRegeneration is kept as a no-op so
-- its existing call sites (lock toggles, roster changes, combat entry)
-- don't need to change.
RequestMacroRegeneration = function(reasonForLog)
end

local function CollectPlayerCastableCategories(roster)
    local playerMember = GetPlayerMemberFromRoster(roster)
    local categories = {}

    if not playerMember then
        return categories
    end

    for _, category in ipairs(CollectCategoriesForRoster(roster)) do
        local entry = GetAutomaticCatalogEntry(playerMember, category)

        if entry then
            table.insert(categories, category)
        end
    end

    return categories
end

-- Compares the local player's lock on a family against every other
-- roster member of the SAME class who has CoABuffManager and has
-- broadcast a lock on that same family (via CoABuffComm, see Comm.lua).
-- This is a read-only, informational check: it never changes anyone's
-- locks, it just surfaces "you and X both locked this" so players can
-- talk to each other, per the local-config-plus-human-communication
-- approach we're using instead of a centralized raid-assistant authority.
--
-- Deliberately permissive about what counts as a conflict: ANY lock (be
-- it GROUP or INDIVIDUAL, matching targets or not) from another same-class
-- player on the same family is reported, since in every case it means
-- both players are about to spend effort on a buff the other one might
-- already have covered.
--
-- Returns a (possibly empty) array of conflicting player names.
GetSameClassLockConflicts = function(family, roster, playerMember)
    local conflicts = {}
    if not family or not playerMember or not CoABuffManagerDB.macroLocks
        or not CoABuffManagerDB.macroLocks[family] then
        return conflicts
    end

    for _, member in ipairs(roster or {}) do
        if not member.isPlayer
            and member.classToken == playerMember.classToken then

            local remote = CoABuffComm and CoABuffComm.GetRemoteData
                and CoABuffComm.GetRemoteData(member.name)

            if remote and remote.locks and remote.locks[family] then
                table.insert(conflicts, member.name)
            end
        end
    end

    return conflicts
end

local function CountCategoryProviders(roster, category)
    local count = 0
    for _, member in ipairs(roster or {}) do
        if GetCatalogEntry(member, category) then
            count = count + 1
        end
    end
    return count
end

RefreshOverviewCastStates = function()
    if not mainFrame or not mainFrame:IsShown() or activeTab ~= "overview" then
        return
    end

    for _, button in ipairs(overviewCastButtons) do
        if button:IsShown() and button.spellName then
            if button.groupWide then
                local allBuffed = true
                local checked = 0
                local minimumRemaining = nil

                for _, unit in ipairs(button.rosterUnits or {}) do
                    if UnitExists(unit)
                        and UnitIsConnected(unit)
                        and not UnitIsDeadOrGhost(unit) then

                        checked = checked + 1
                        local hasAura, expirationTime = UnitHasAura(
                            unit,
                            button.auraName,
                            button.auraSpellID,
                            button.auraNames
                        )
                        if not hasAura then
                            allBuffed = false
                        elseif expirationTime and expirationTime > 0 then
                            local remaining = math.max(0, expirationTime - GetTime())
                            if not minimumRemaining or remaining < minimumRemaining then
                                minimumRemaining = remaining
                            end
                        end
                    end
                end

                button:Enable()
                if confirmedGroupCasts[button.category]
                    and checked > 0
                    and allBuffed then
                    if minimumRemaining and minimumRemaining <= BUFF_WARNING_SECONDS then
                        SetOverviewButtonVisual(button, "WARNING", minimumRemaining)
                    elseif minimumRemaining and minimumRemaining <= BUFF_CRITICAL_SECONDS then
                        SetOverviewButtonVisual(button, "CRITICAL", minimumRemaining)
                    else
                        SetOverviewButtonVisual(button, "ACTIVE", minimumRemaining)
                    end
                else
                    SetOverviewButtonVisual(button, "INACTIVE", nil)
                end
            elseif not button.unit or not UnitExists(button.unit) then
                button:Disable()
                SetOverviewButtonVisual(button, "DISABLED", nil)
            elseif not UnitIsConnected(button.unit) then
                button:Disable()
                SetOverviewButtonVisual(button, "DISABLED", nil)
            elseif UnitIsDeadOrGhost(button.unit) then
                button:Disable()
                SetOverviewButtonVisual(button, "DISABLED", nil)
            else
                button:Enable()
                local hasAura, expirationTime = UnitHasAura(
                    button.unit,
                    button.auraName,
                    button.auraSpellID,
                    button.auraNames
                )
                local remaining = nil
                if expirationTime and expirationTime > 0 then
                    remaining = math.max(0, expirationTime - GetTime())
                end

                if hasAura then
                    if remaining and remaining <= BUFF_WARNING_SECONDS then
                        SetOverviewButtonVisual(button, "WARNING", remaining)
                    elseif remaining and remaining <= BUFF_CRITICAL_SECONDS then
                        SetOverviewButtonVisual(button, "CRITICAL", remaining)
                    else
                        SetOverviewButtonVisual(button, "ACTIVE", remaining)
                    end
                else
                    SetOverviewButtonVisual(button, "INACTIVE", nil)
                end

                if not hasAura
                    and IsSpellInRange
                    and IsSpellInRange(button.spellName, button.unit) == 0 then
                    SetOverviewButtonVisual(button, "OUT_OF_RANGE", remaining)
                end
            end

            if button.lockOverlay then
                local isLocked = false
                if button.family then
                    if button.groupWide then
                        isLocked = IsGroupLocked(button.family)
                    elseif button.targetName then
                        isLocked = IsIndividualLocked(button.family, button.targetName)
                    end
                end

                if isLocked then
                    button.lockOverlay:Show()
                else
                    button.lockOverlay:Hide()
                end
            end
        end
    end

    -- Badge refresh for auto-family buttons: cheap (no frame creation),
    -- so safe to run on every periodic tick alongside the per-member
    -- buttons above. Positioning/visibility itself is only touched by
    -- RebuildOverviewPanel; this loop only ever updates already-shown
    -- buttons' text.
    local roster, playerMember
    for family, button in pairs(autoFamilyButtons) do
        if button:IsShown() then
            if not roster then
                roster = GetRoster()
                playerMember = GetPlayerMemberFromRoster(roster)
            end
            RefreshAutoFamilyButtonBadge(button, family, roster, playerMember)
        end
    end
end

local function RebuildOverviewPanel()
    EnsureDB()

    if InCombatLockdown and InCombatLockdown() then
        pendingSecureRebuild = true
        statusText:SetText(
            "Combat : mise a jour des boutons differee."
        )
        return
    end

    pendingSecureRebuild = false
    HideCollection(overviewLabels)
    HideCollection(overviewHeaders)
    HideCollection(overviewCastButtons)
    HideCollection(overviewMemberHoverFrames)
    HideAllAutoFamilyButtons()

    groupSpellCategoriesByID = {}
    groupSpellCategoriesByName = {}
    individualSpellCategoriesByID = {}
    individualSpellCategoriesByName = {}

    local roster = GetRoster()
    local categories = CollectPlayerCastableCategories(roster)
    local playerMember = GetPlayerMemberFromRoster(roster)

    -- Au-dela d'un certain effectif, afficher une colonne par membre du
    -- raid devient illisible (40 * MEMBER_WIDTH). Les conflits potentiels
    -- (CountCategoryProviders, GetSameClassLockConflicts plus bas) restent
    -- calcules sur le roster COMPLET, toutes classes confondues -- seul
    -- l'affichage des colonnes individuelles est reduit a ta propre classe,
    -- puisqu'un unique cast de groupe couvre de toute facon tout le raid.
    local displayRoster = roster
    if playerMember and #roster > OVERVIEW_DISPLAY_ROSTER_THRESHOLD then
        displayRoster = {}
        for _, member in ipairs(roster) do
            if member.classToken == playerMember.classToken then
                table.insert(displayRoster, member)
            end
        end
    end

    local actionX = LABEL_WIDTH + (#displayRoster * MEMBER_WIDTH)

    local header = GetOverviewHeader(1)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", panels.overview, "TOPLEFT", 6, -8)
    header:SetWidth(LABEL_WIDTH - 12)
    header:SetText("Mes buffs applicables")
    header:Show()

    for column, member in ipairs(displayRoster) do
        header = GetOverviewHeader(column + 1)
        header:ClearAllPoints()
        header:SetPoint(
            "TOPLEFT",
            panels.overview,
            "TOPLEFT",
            LABEL_WIDTH + ((column - 1) * MEMBER_WIDTH),
            -8
        )
        header:SetWidth(MEMBER_WIDTH - 8)
        header:SetHeight(40)
        local classLine = member.className .. " L" .. tostring(member.level or "?")

        local specDisplay = member.specName or member.specToken
        if specDisplay then
            classLine = classLine .. " - " .. specDisplay
        end

        local recommendedText = GetRecommendedStatsText(member)
        if recommendedText then
            classLine = classLine .. "\n|cffffd100" .. recommendedText .. "|r"
        end

        local classBuffLines = GetClassBuffSummaryLines(member.classToken)
        local memberHoverFrame = GetOverviewMemberHoverFrame(column)
        memberHoverFrame:ClearAllPoints()
        memberHoverFrame:SetPoint(
            "TOPLEFT",
            panels.overview,
            "TOPLEFT",
            LABEL_WIDTH + ((column - 1) * MEMBER_WIDTH),
            -8
        )
        memberHoverFrame:SetWidth(MEMBER_WIDTH - 8)
        memberHoverFrame:SetHeight(40)
        memberHoverFrame.className = member.className

        if #classBuffLines > 0 then
            classLine = classLine .. "  |cff888888(i)|r"
            memberHoverFrame.classBuffLines = classBuffLines
            memberHoverFrame:Show()
        else
            memberHoverFrame.classBuffLines = nil
            memberHoverFrame:Hide()
        end

        header:SetText(
            member.name ..
            "\n|cffaaaaaa" ..
            classLine ..
            "|r"
        )
        header:Show()
    end

    header = GetOverviewHeader(#displayRoster + 2)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", panels.overview, "TOPLEFT", actionX, -8)
    header:SetWidth(ACTION_WIDTH - 8)
    header:SetText("Buff\n|cff999999(Groupe)|r")
    header:Show()

    local labelIndex = 0
    local buttonIndex = 0

    for row, category in ipairs(categories) do
        -- Every element in this row -- the category label, the auto-family
        -- button, and both cast-button loops below -- anchors its TOPLEFT
        -- at -rowTop, so they all start flush with the same row top and
        -- stay visually aligned regardless of how many lines the label
        -- wraps to (conflict/lock-conflict text adds lines below it). A
        -- cast button previously used -(rowTop + 16), pushing its icon
        -- noticeably below the label for short, single-line categories.
        local rowTop = 48 + ((row - 1) * OVERVIEW_ROW_HEIGHT)
        local providerCount = CountCategoryProviders(roster, category)
        local hasPotentialConflict = providerCount >= 2

        labelIndex = labelIndex + 1
        local categoryLabel = GetOverviewLabel(labelIndex)
        categoryLabel:SetJustifyH("LEFT")
        categoryLabel:ClearAllPoints()
        categoryLabel:SetPoint(
            "TOPLEFT",
            panels.overview,
            "TOPLEFT",
            8,
            -rowTop
        )
        categoryLabel:SetWidth(LABEL_WIDTH - 16)

        -- A category can be provided by an always-on passive raid aura
        -- (e.g. Bloodmage Eternal's Eternal Presence) instead of a spell
        -- you actively cast. Detected from the LOCAL PLAYER's own entry:
        -- there's nothing to click or lock for the macro in that case, so
        -- it's shown as a plain "toujours actif" indicator further down
        -- instead of a cast button.
        local playerCategoryEntry = playerMember and GetAutomaticCatalogEntry(playerMember, category)
        local isPassiveCategory = playerCategoryEntry and playerCategoryEntry.kind == "PASSIVE_AURA"

        local categoryText = category
        if IsRecommendedStatForMember(playerMember, category) then
            categoryText = "|cffffd100" .. categoryText .. "|r"
        end
        if isPassiveCategory then
            categoryText = categoryText .. "\n|cff888888toujours actif|r"
        end
        if hasPotentialConflict then
            categoryText = categoryText .. "\n|cffff6666conflit possible|r"
        end

        local lockConflicts = GetSameClassLockConflicts(category, roster, playerMember)
        if #lockConflicts > 0 then
            table.sort(lockConflicts)
            categoryText = categoryText ..
                "\n|cffff2222aussi verrouille par " ..
                table.concat(lockConflicts, ", ") .. "|r"
        end

        categoryLabel:SetText(categoryText)
        categoryLabel:Show()

        if not isPassiveCategory
            and CoABuffManagerDB.macroLocks and CoABuffManagerDB.macroLocks[category] then
            local autoButton = GetAutoFamilyButton(category)
            autoButton:ClearAllPoints()
            autoButton:SetPoint(
                "TOPLEFT",
                panels.overview,
                "TOPLEFT",
                actionX,
                -rowTop
            )
            RefreshAutoFamilyButtonBadge(autoButton, category, roster, playerMember)
            autoButton:Show()
        end

        local maximum = nil
        for _, member in ipairs(roster) do
            local entry = GetCatalogEntry(member, category)
            if entry and tonumber(entry.value) then
                local value = tonumber(entry.value)
                if not maximum or value > maximum then
                    maximum = value
                end
            end
        end

        local groupEntry = not isPassiveCategory and playerMember and GetAutomaticCatalogEntry(
            playerMember,
            category,
            nil,
            "PARTY_RAID"
        )
        local allyEntry = not isPassiveCategory and playerMember and GetAutomaticCatalogEntry(
            playerMember,
            category,
            nil,
            "ALLY"
        )

        if isPassiveCategory then
            -- Nothing to cast: this is an always-on aura, not a spell the
            -- player triggers. Show the value directly instead of an icon.
            -- Uses the same sequential overviewLabels pool (not a separate
            -- index range) so HideCollection's ipairs still reclaims it.
            labelIndex = labelIndex + 1
            local passiveDisplay = GetOverviewLabel(labelIndex)
            passiveDisplay:SetJustifyH("CENTER")
            passiveDisplay:ClearAllPoints()
            passiveDisplay:SetPoint(
                "TOPLEFT",
                panels.overview,
                "TOPLEFT",
                actionX,
                -rowTop
            )
            passiveDisplay:SetWidth(ACTION_WIDTH - 8)
            local passiveValue = FormatCategoryValue(playerCategoryEntry)
            passiveDisplay:SetText(
                passiveValue and ("|cff33ff66" .. passiveValue .. "|r") or ""
            )
            passiveDisplay:Show()
        end

        if groupEntry and groupEntry.spell then
            buttonIndex = buttonIndex + 1
            local button = GetOverviewCastButton(buttonIndex)
            button:ClearAllPoints()
            button:SetPoint(
                "TOPLEFT",
                panels.overview,
                "TOPLEFT",
                actionX + math.floor((ACTION_WIDTH - OVERVIEW_ICON_SIZE) / 2),
                -rowTop
            )
            button:SetWidth(OVERVIEW_ICON_SIZE)
            button:SetHeight(OVERVIEW_ICON_SIZE)
            button:SetAttribute("type2", nil)
            button:SetAttribute("spell2", nil)
            button:SetAttribute("unit2", nil)
            button.spellName = groupEntry.spell
            local secureSpellName = ConfigureSecureSpellButton(
                button,
                groupEntry.spellID,
                groupEntry.spell,
                "player"
            )
            RegisterTrackedSpell(
                groupSpellCategoriesByID,
                groupSpellCategoriesByName,
                groupEntry.spellID,
                secureSpellName or groupEntry.spell,
                category
            )
            button.spellID = groupEntry.spellID
            if button.icon then
                button.icon:SetTexture(GetSpellIcon(groupEntry.spellID, secureSpellName or groupEntry.spell))
            end

            local groupDisplayValue = FormatCategoryValue(groupEntry)
            if groupDisplayValue then
                -- Group-wide always reflects the player's own best known
                -- spell for this category, so it's shown green like a
                -- best-in-group value rather than compared to `maximum`.
                button.valueDisplay = "|cff33ff66" .. groupDisplayValue .. "|r"
            else
                button.valueDisplay = ""
            end
            button.category = category
            button.family = groupEntry.family
            button.auraName = groupEntry.spell
            button.auraSpellID = groupEntry.spellID
            button.auraNames = GetRosterFamilyAuraNames(
                groupEntry.family,
                roster,
                groupEntry.spell
            )
            button.unit = "player"
            button.targetName = "__GROUP__"
            button.groupWide = true
            button.rosterUnits = {}
            for _, member in ipairs(roster) do
                table.insert(button.rosterUnits, member.unit)
            end

            button:Show()
        end

        if allyEntry and allyEntry.spell then
            for column, member in ipairs(displayRoster) do
                buttonIndex = buttonIndex + 1
                local button = GetOverviewCastButton(buttonIndex)
                button:ClearAllPoints()
                button:SetPoint(
                    "TOPLEFT",
                    panels.overview,
                    "TOPLEFT",
                    LABEL_WIDTH + ((column - 1) * MEMBER_WIDTH) +
                        math.floor((MEMBER_WIDTH - OVERVIEW_ICON_SIZE) / 2),
                    -rowTop
                )
                button:SetWidth(OVERVIEW_ICON_SIZE)
                button:SetHeight(OVERVIEW_ICON_SIZE)
                button:SetAttribute("type2", nil)
                button:SetAttribute("spell2", nil)
                button:SetAttribute("unit2", nil)
                button.spellName = allyEntry.spell
                local secureSpellName = ConfigureSecureSpellButton(
                    button,
                    allyEntry.spellID,
                    allyEntry.spell,
                    member.unit
                )
                RegisterTrackedSpell(
                    individualSpellCategoriesByID,
                    individualSpellCategoriesByName,
                    allyEntry.spellID,
                    secureSpellName or allyEntry.spell,
                    category
                )
                button.spellID = allyEntry.spellID
                if button.icon then
                    button.icon:SetTexture(GetSpellIcon(allyEntry.spellID, secureSpellName or allyEntry.spell))
                end

                local memberEntry = GetCatalogEntry(member, category)
                local memberDisplayValue = FormatCategoryValue(memberEntry)
                if memberDisplayValue then
                    local memberValue = tonumber(memberEntry.value)
                    if maximum and memberValue == maximum then
                        button.valueDisplay = "|cff33ff66" .. memberDisplayValue .. "|r"
                    else
                        button.valueDisplay = "|cffffaa33" .. memberDisplayValue .. "|r"
                    end
                else
                    button.valueDisplay = ""
                end

                button.category = category
                button.family = allyEntry.family
                button.auraName = allyEntry.spell
                button.auraSpellID = allyEntry.spellID
                button.auraNames = GetRosterFamilyAuraNames(
                    allyEntry.family,
                    roster,
                    allyEntry.spell
                )
                button.unit = member.unit
                button.targetName = member.name
                button.className = member.className
                button.groupWide = false
                button.rosterUnits = nil

                button:Show()
            end
        end
    end

    if #categories == 0 then
        local label = GetOverviewLabel(1)
        label:SetJustifyH("LEFT")
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", panels.overview, "TOPLEFT", 8, -52)
        label:SetWidth(760)
        label:SetText(
            "Aucun buff longue duree ou aura passive confirme dans votre grimoire."
        )
        label:Show()
    else
        labelIndex = labelIndex + 1
        local legend = GetOverviewLabel(labelIndex)
        -- GetOverviewLabel's pool creates every fontstring LEFT-justified
        -- by default (and reuses the same pooled widget across refreshes
        -- for whatever role ends up at this index), so the centering has
        -- to be (re)applied explicitly here every time, not just once at
        -- creation -- otherwise it silently reverts to LEFT, which is why
        -- it kept resetting after /reload.
        legend:SetJustifyH("CENTER")
        legend:ClearAllPoints()
        legend:SetPoint(
            "TOPLEFT",
            panels.overview,
            "TOPLEFT",
            8,
            -(60 + (#categories * OVERVIEW_ROW_HEIGHT))
        )
        legend:SetWidth(850)
        legend:SetText(
            "|cffffd100Icones :|r Clic gauche = lancer le buff. " ..
            "Cadre vert = actif. Cadre orange = expiration dans moins de 5 min. " ..
            "|cffffd100Cadre dore|r = verrouille (suivi dans le HUD flottant, clic droit pour (de)verrouiller). " ..
            "|cffff6666Conflit possible|r = un autre membre peut fournir la meme categorie. " ..
            "|cff888888Toujours actif|r = aura passive, rien a lancer.\n" ..
            "|cffffd100Suivi flottant (HUD) :|r une ligne par verrou, cadre rouge/orange/vert " ..
            "selon l'etat, marque orange si quelqu'un de verrouille est mort/deco."
        )
        legend:Show()
    end

    RefreshOverviewCastStates()
end

-- ---------------------------------------------------------------------------
-- Onglet : configuration du catalogue
-- ---------------------------------------------------------------------------

local function CreateLabeledEditBox(parent, labelText, x, y, width)
    local label = CreateText(parent, "GameFontNormalSmall", "LEFT")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width)
    label:SetText(labelText)

    local editBox = CreateFrame("EditBox", nil, parent)
    editBox:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 18)
    editBox:SetWidth(width)
    editBox:SetHeight(24)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetTextColor(1, 1, 1)
    editBox:SetTextInsets(7, 7, 3, 3)
    editBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    editBox:SetBackdropColor(0.03, 0.03, 0.03, 0.95)
    editBox:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    return editBox
end

local function FillConfigFromMember(member)
    configFields.className:SetText(member.className or "")
    configFields.classToken:SetText(member.classToken or "")
    configFields.classID:SetText(tostring(member.classID or 0))
end

local function RebuildConfigMemberButtons()
    HideCollection(configMemberButtons)

    local roster = GetRoster()

    for index, member in ipairs(roster) do
        local button = configMemberButtons[index]

        if not button then
            button = CreateFrame(
                "Button",
                nil,
                panels.config,
                "UIPanelButtonTemplate"
            )
            button:SetWidth(155)
            button:SetHeight(24)
            configMemberButtons[index] = button
        end

        button:ClearAllPoints()
        button:SetPoint(
            "TOPLEFT",
            panels.config,
            "TOPLEFT",
            8,
            -(32 + ((index - 1) * 27))
        )
        button:SetText(member.name .. " - " .. member.className)
        button.member = member
        button:SetScript("OnClick", function(self)
            FillConfigFromMember(self.member)
            if statusText then
                local specText = self.member.specName and (" - " .. self.member.specName) or ""
                statusText:SetText(
                    "Selection : " .. self.member.name .. " - " ..
                    self.member.className .. specText
                )
            end
        end)
        button:Show()

        if index == 1 and Trim(configFields.classToken:GetText()) == "" then
            FillConfigFromMember(member)
        end
    end
end

local function CollectAllCatalogEntries()
    local entries = {}

    for classToken, byClass in pairs(CoABuffManagerDB.catalog) do
        for category, entry in pairs(byClass) do
            table.insert(entries, {
                classToken = classToken,
                category = category,
                className = entry.className or classToken,
                classID = entry.classID or 0,
                value = tonumber(entry.value) or 0,
                spell = entry.spell or "",
                aura = entry.aura or "",
            })
        end
    end

    table.sort(entries, function(a, b)
        if a.className == b.className then
            return a.category < b.category
        end
        return a.className < b.className
    end)

    return entries
end

local function RebuildConfigEntryList()
    HideCollection(configEntryLines)

    local entries = CollectAllCatalogEntries()

    for index, entry in ipairs(entries) do
        local line = configEntryLines[index]

        if not line then
            line = CreateText(panels.config, "GameFontHighlightSmall", "LEFT")
            configEntryLines[index] = line
        end

        line:ClearAllPoints()
        line:SetPoint(
            "TOPLEFT",
            panels.config,
            "TOPLEFT",
            550,
            -(42 + ((index - 1) * 18))
        )
        line:SetWidth(300)
        line:SetText(
            entry.className ..
            " | " ..
            entry.category ..
            " = " ..
            tostring(entry.value)
        )
        line:Show()
    end

    if #entries == 0 then
        local line = configEntryLines[1]
        if not line then
            line = CreateText(panels.config, "GameFontHighlightSmall", "LEFT")
            configEntryLines[1] = line
        end

        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 550, -42)
        line:SetWidth(300)
        line:SetText("Aucune entree enregistree.")
        line:Show()
    end
end

local function SaveCatalogEntry()
    EnsureDB()

    local className = Trim(configFields.className:GetText())
    local classToken = Upper(configFields.classToken:GetText())
    local classID = tonumber(Trim(configFields.classID:GetText())) or 0
    local category = Upper(configFields.category:GetText())
    local value = tonumber(Trim(configFields.value:GetText()))
    local spell = Trim(configFields.spell:GetText())
    local aura = Trim(configFields.aura:GetText())

    if classToken == "" then
        Print("Token de classe manquant.")
        return
    end

    if category == "" then
        Print("Categorie de buff manquante.")
        return
    end

    if not value then
        Print("Valeur numerique invalide.")
        return
    end

    if className == "" then
        className = classToken
    end

    CoABuffManagerDB.catalog[classToken] =
        CoABuffManagerDB.catalog[classToken] or {}

    CoABuffManagerDB.catalog[classToken][category] = {
        className = className,
        classID = classID,
        category = category,
        value = value,
        spell = spell,
        aura = aura,
    }

    Print(
        "Enregistre : " ..
        className ..
        " / " ..
        category ..
        " = " ..
        tostring(value)
    )

    RebuildConfigEntryList()
    RebuildOverviewPanel()
end

local function DeleteCatalogEntry()
    EnsureDB()

    local classToken = Upper(configFields.classToken:GetText())
    local category = Upper(configFields.category:GetText())

    if classToken == "" or category == "" then
        Print("Token de classe et categorie requis.")
        return
    end

    if CoABuffManagerDB.catalog[classToken]
        and CoABuffManagerDB.catalog[classToken][category] then

        CoABuffManagerDB.catalog[classToken][category] = nil

        if not next(CoABuffManagerDB.catalog[classToken]) then
            CoABuffManagerDB.catalog[classToken] = nil
        end

        Print("Entree supprimee : " .. classToken .. " / " .. category)
        RebuildConfigEntryList()
        RebuildOverviewPanel()
    else
        Print("Entree introuvable.")
    end
end

local function BuildConfigPanel()
    local title = CreateText(panels.config, "GameFontNormal", "LEFT")
    title:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 8, -8)
    title:SetText("1. Membres du groupe")

    local formTitle = CreateText(panels.config, "GameFontNormal", "LEFT")
    formTitle:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 190, -8)
    formTitle:SetText("2. Buff de la classe")

    configFields.className =
        CreateLabeledEditBox(panels.config, "Nom de classe", 190, -38, 190)

    configFields.classToken =
        CreateLabeledEditBox(panels.config, "Token", 395, -38, 125)

    configFields.classID =
        CreateLabeledEditBox(panels.config, "ID", 190, -92, 75)

    configFields.category =
        CreateLabeledEditBox(
            panels.config,
            "Categorie, ex. ENDURANCE",
            280,
            -92,
            240
        )

    configFields.value =
        CreateLabeledEditBox(panels.config, "Valeur", 190, -146, 75)

    configFields.spell =
        CreateLabeledEditBox(
            panels.config,
            "Nom du sort, facultatif",
            280,
            -146,
            240
        )

    configFields.aura =
        CreateLabeledEditBox(
            panels.config,
            "Nom de l'aura, facultatif",
            190,
            -200,
            330
        )

    local saveButton = CreateFrame(
        "Button",
        nil,
        panels.config,
        "UIPanelButtonTemplate"
    )
    saveButton:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 190, -258)
    saveButton:SetWidth(145)
    saveButton:SetHeight(25)
    saveButton:SetText("Enregistrer")
    saveButton:SetScript("OnClick", SaveCatalogEntry)

    local deleteButton = CreateFrame(
        "Button",
        nil,
        panels.config,
        "UIPanelButtonTemplate"
    )
    deleteButton:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 355, -258)
    deleteButton:SetWidth(155)
    deleteButton:SetHeight(25)
    deleteButton:SetText("Supprimer l'entree")
    deleteButton:SetScript("OnClick", DeleteCatalogEntry)

    local listTitle = CreateText(panels.config, "GameFontNormal", "LEFT")
    listTitle:SetPoint("TOPLEFT", panels.config, "TOPLEFT", 550, -8)
    listTitle:SetText("Catalogue")
end

-- ---------------------------------------------------------------------------
-- Fenetre et navigation
-- ---------------------------------------------------------------------------

local OPEN_MACRO_NAME = "CBM"

-- Creates (or updates) a simple per-character macro that just opens the
-- addon window. Meant to be dragged onto the action bar so players do not
-- need to type /cbm manually every time they want to check buffs in a
-- dungeon.
local function CreateOpenAddonMacro()
    if CreateOrUpdateMacro(OPEN_MACRO_NAME, "/cbm", true) then
        Print(
            "Macro " .. OPEN_MACRO_NAME .. " prete. Glisse-la depuis la fenetre " ..
            "de macros generales (menu Echap > Macros) vers ta barre de sorts."
        )
    end
end

local function DescribeFamilyLock(family, lock)
    if lock.mode == "GROUP" then
        return family .. " : groupe/raid"
    end

    local targetNames = {}
    for targetName in pairs(lock.targets or {}) do
        table.insert(targetNames, targetName)
    end
    table.sort(targetNames)

    if #targetNames == 0 then
        return family .. " : individuel (aucune cible)"
    end

    return family .. " : " .. table.concat(targetNames, ", ")
end

-- ---------------------------------------------------------------------------
-- Bouton compact des buffs natifs + controle des buffs manquants du groupe
-- ---------------------------------------------------------------------------

function CoABuffTray.IsEligibleUnit(unit)
    if not unit or not UnitExists(unit) then
        return false
    end
    if UnitIsConnected and not UnitIsConnected(unit) then
        return false
    end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        return false
    end
    return true
end

function CoABuffTray.GetProviderOptions(member, roster)
    local options = {}
    local seen = {}

    -- GetAutomaticCatalogEntry applique deja toutes les regles du manager :
    -- classe, niveau, specialisation distante, sorts confirmes par Comm et
    -- repli "potentiel" lorsque l'autre joueur n'a pas l'addon.
    for _, category in ipairs(CollectCategoriesForRoster(roster)) do
        local entry = GetAutomaticCatalogEntry(member, category, nil, "PARTY_RAID")
        if entry and entry.spell then
            local key = entry.family
                or (entry.spellID and ("ID:" .. tostring(entry.spellID)))
                or ("NAME:" .. NormalizeExactSpellName(entry.spell))
            if key and not seen[key] then
                seen[key] = true
                table.insert(options, {
                    key = key,
                    family = entry.family,
                    spell = entry.spell,
                    spellID = entry.spellID,
                    potential = entry.potential,
                    auraNames = GetFamilyAuraNames(member, entry.family, entry.spell),
                })
            end
        end
    end

    table.sort(options, function(a, b)
        return tostring(a.spell) < tostring(b.spell)
    end)
    return options
end

function CoABuffTray.IsProviderOptionActive(option, roster)
    -- Une personne ne peut maintenir qu'un seul choix de cette famille a la
    -- fois. Une variante personnelle (Mark) compte donc autant que sa variante
    -- de groupe (Greater Mark) pour determiner si ce joueur a deja utilise son
    -- unique emplacement de buff.
    local auraNames = option.auraNames
        or GetFamilyAuraNames(nil, option.family, option.spell)
    for _, target in ipairs(roster) do
        if CoABuffTray.IsEligibleUnit(target.unit) then
            local hasAura = UnitHasAura(
                target.unit,
                option.spell,
                option.spellID,
                auraNames
            )
            if hasAura then return true end
        end
    end
    return false
end

function CoABuffTray.ShortSpellName(name)
    name = tostring(name or "Buff")
    name = string.gsub(name, "^Greater%s+", "")
    return name
end

function CoABuffTray.ScanMissing(force)
    local now = GetTime and GetTime() or 0
    if not force and CoABuffTray.missing
        and CoABuffTray.lastScanAt
        and (now - CoABuffTray.lastScanAt) < 0.5 then
        return CoABuffTray.missing, CoABuffTray.missingCount or 0
    end

    CoABuffTray.missing = {}
    CoABuffTray.missingCount = 0
    CoABuffTray.lastScanAt = now

    local roster = GetRoster()
    local providers = {}
    local activeByKey = {}

    for _, member in ipairs(roster) do
        if CoABuffTray.IsEligibleUnit(member.unit) then
            local options = CoABuffTray.GetProviderOptions(member, roster)
            if #options > 0 then
                table.insert(providers, { member = member, options = options })
                for _, option in ipairs(options) do
                    if activeByKey[option.key] == nil then
                        activeByKey[option.key] =
                            CoABuffTray.IsProviderOptionActive(option, roster)
                    end
                end
            end
        end
    end

    -- Un joueur ne peut maintenir qu'un seul buff de groupe de ce systeme.
    -- Chaque aura active ne remplit donc qu'un seul "slot fournisseur". Trier
    -- les joueurs les plus contraints d'abord evite qu'un joueur polyvalent
    -- consomme l'aura qui serait la seule option d'un autre membre.
    table.sort(providers, function(a, b)
        if #a.options ~= #b.options then
            return #a.options < #b.options
        end
        return tostring(a.member.name) < tostring(b.member.name)
    end)

    local usedActive = {}
    for _, provider in ipairs(providers) do
        local satisfied = false
        for _, option in ipairs(provider.options) do
            if activeByKey[option.key] and not usedActive[option.key] then
                usedActive[option.key] = true
                satisfied = true
                break
            end
        end

        if not satisfied then
            local optionNames = {}
            local allPotential = true
            for _, option in ipairs(provider.options) do
                table.insert(optionNames, CoABuffTray.ShortSpellName(option.spell))
                if not option.potential then allPotential = false end
            end
            table.insert(CoABuffTray.missing, {
                providerName = provider.member.name,
                className = provider.member.className,
                optionNames = optionNames,
                potential = allPotential,
            })
            CoABuffTray.missingCount = CoABuffTray.missingCount + 1
        end
    end

    table.sort(CoABuffTray.missing, function(a, b)
        return tostring(a.providerName) < tostring(b.providerName)
    end)
    return CoABuffTray.missing, CoABuffTray.missingCount
end

function CoABuffTray.BuildSummary(maxLines)
    local missing, count = CoABuffTray.ScanMissing(false)
    if count == 0 then
        return "|cff66ff66Aucun buff disponible ne manque au groupe.|r"
    end

    local lines = {
        "|cffff6666" .. count .. " joueur(s) pouvant encore poser un buff :|r",
    }
    local limit = math.min(#missing, maxLines or 10)
    for index = 1, limit do
        local item = missing[index]
        table.insert(
            lines,
            "|cffffffff" .. tostring(item.providerName) .. "|r (" ..
            tostring(item.className or "classe inconnue") .. ") : " ..
            ((#item.optionNames > 1) and "1 parmi " or "") ..
            table.concat(item.optionNames, " / ") ..
            (item.potential and " |cffaaaaaa(possible)|r" or "")
        )
    end
    if #missing > limit then
        table.insert(lines, "... et " .. (#missing - limit) .. " autre(s) buff(s).")
    end
    return table.concat(lines, "\n")
end

function CoABuffTray.GetNativeFrame()
    -- Conquest of Azeroth repose sur l'interface WoW 3.3.5a : sa barre
    -- s'appelle BuffFrame. PlayerBuffFrame n'est conserve qu'en repli pour
    -- les clients/skins qui exposeraient l'ancien nom.
    return BuffFrame or PlayerBuffFrame
end

local BUFF_TRAY_HIDE_MODE_LABELS = {
    raid = "Buffs de raid uniquement",
    player = "Buffs personnels uniquement",
    both = "Tous les buffs",
}

function CoABuffTray.BuildRaidAuraLookup()
    if CoABuffTray.raidAuraLookup then
        return CoABuffTray.raidAuraLookup
    end

    local lookup = { byID = {}, byName = {} }
    local raidFamilies = {}

    if CoABuffDatabase and CoABuffDatabase.classes then
        for _, classData in pairs(CoABuffDatabase.classes) do
            for _, spell in ipairs(classData.spells or {}) do
                if spell.scope == "PARTY_RAID" then
                    if spell.family then raidFamilies[spell.family] = true end
                    if spell.spellID then lookup.byID[tonumber(spell.spellID)] = true end
                    local nameKey = NormalizeAuraName(spell.spellName)
                    if nameKey ~= "" then lookup.byName[nameKey] = true end
                end
            end
        end

        -- Inclut aussi la variante individuelle d'une famille possedant un
        -- vrai buff de groupe (Mark et Greater Mark, par exemple).
        for _, classData in pairs(CoABuffDatabase.classes) do
            for _, spell in ipairs(classData.spells or {}) do
                if spell.family and raidFamilies[spell.family] then
                    if spell.spellID then lookup.byID[tonumber(spell.spellID)] = true end
                    local nameKey = NormalizeAuraName(spell.spellName)
                    if nameKey ~= "" then lookup.byName[nameKey] = true end
                end
            end
        end
    end

    CoABuffTray.raidAuraLookup = lookup
    return lookup
end

function CoABuffTray.IsRaidAura(auraName, spellID, unitCaster)
    local lookup = CoABuffTray.BuildRaidAuraLookup()
    spellID = tonumber(spellID)
    if spellID and lookup.byID[spellID] then return true end
    if lookup.byName[NormalizeAuraName(auraName)] then return true end

    -- Un buff lance par un autre joueur est considere comme un buff de raid,
    -- meme si sa classe n'est pas encore documentee dans la base CoA.
    if unitCaster then
        local isPlayer = unitCaster == "player"
            or (UnitIsUnit and UnitIsUnit(unitCaster, "player"))
        local isPet = unitCaster == "pet"
            or (UnitIsUnit and UnitExists("pet") and UnitIsUnit(unitCaster, "pet"))
        if not isPlayer and not isPet then return true end
    end
    return false
end

function CoABuffTray.SetNativeButtonsVisible(visible)
    for index = 1, 40 do
        local button = getglobal("BuffButton" .. tostring(index))
        if button then
            button:SetAlpha(visible and 1 or 0)
            if button.EnableMouse then button:EnableMouse(visible and true or false) end
        end
    end
end

function CoABuffTray.ApplySelectiveNativeVisibility()
    local mode = CoABuffManagerDB.buffTray.hideMode or "both"
    for index = 1, 40 do
        local button = getglobal("BuffButton" .. tostring(index))
        if button then
            local auraIndex = index
            if button.GetID then
                local buttonID = tonumber(button:GetID())
                if buttonID and buttonID > 0 then auraIndex = buttonID end
            end

            local auraName, _, _, _, _, _, _, unitCaster, _, _, spellID =
                UnitBuff("player", auraIndex)
            local hide = false
            if auraName then
                local isRaid = CoABuffTray.IsRaidAura(auraName, spellID, unitCaster)
                hide = (mode == "raid" and isRaid)
                    or (mode == "player" and not isRaid)
            end
            button:SetAlpha(hide and 0 or 1)
            if button.EnableMouse then button:EnableMouse(not hide) end
        end
    end
end

function CoABuffTray.SetNativeVisible(visible)
    local nativeFrame = CoABuffTray.GetNativeFrame()
    if not nativeFrame then
        return
    end
    if visible then
        nativeFrame:SetAlpha(1)
        nativeFrame:Show()
        CoABuffTray.SetNativeButtonsVisible(true)
    elseif (CoABuffManagerDB.buffTray.hideMode or "both") ~= "both" then
        -- En mode selectif le cadre reste affiche pour conserver les icones
        -- non masquees ; seules les icones choisies deviennent transparentes.
        nativeFrame:SetAlpha(1)
        nativeFrame:Show()
        CoABuffTray.ApplySelectiveNativeVisibility()
    else
        -- L'alpha evite tout flash visuel si BuffFrame_Update appelle :Show()
        -- entre deux controles du bouton compact.
        nativeFrame:SetAlpha(0)
        nativeFrame:Hide()
    end
end

function CoABuffTray.SaveButtonPosition()
    if not CoABuffTray.button then return end
    local point, _, relativePoint, x, y = CoABuffTray.button:GetPoint(1)
    CoABuffManagerDB.buffTray.buttonPoint = {
        point = point or "TOPRIGHT",
        relativePoint = relativePoint or point or "TOPRIGHT",
        x = x or -18,
        y = y or -18,
    }
end

function CoABuffTray.RestoreButtonPosition()
    if not CoABuffTray.button then return end
    local saved = CoABuffManagerDB.buffTray.buttonPoint
    CoABuffTray.button:ClearAllPoints()
    if saved and saved.point then
        CoABuffTray.button:SetPoint(
            saved.point,
            UIParent,
            saved.relativePoint or saved.point,
            saved.x or 0,
            saved.y or 0
        )
    else
        local nativeFrame = CoABuffTray.GetNativeFrame()
        if nativeFrame then
            CoABuffTray.button:SetPoint("TOPRIGHT", nativeFrame, "TOPRIGHT", 0, 0)
        else
            CoABuffTray.button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -18, -18)
        end
    end
end

function CoABuffTray.IsMouseOver(frame)
    if not frame or not frame.IsShown or not frame:IsShown() then
        return false
    end
    if MouseIsOver then
        return MouseIsOver(frame)
    end
    if GetMouseFocus then
        local focus = GetMouseFocus()
        while focus do
            if focus == frame then return true end
            focus = focus.GetParent and focus:GetParent() or nil
        end
    end
    return false
end

function CoABuffTray.ShowTooltip()
    if not CoABuffTray.button or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(CoABuffTray.button, "ANCHOR_BOTTOMLEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("CoA Buff Manager", 0.4, 0.8, 1)
    GameTooltip:AddLine(
        "Survol : afficher temporairement tous les buffs actifs.",
        1, 1, 1, true
    )
    GameTooltip:AddLine(
        "Masques : " .. (BUFF_TRAY_HIDE_MODE_LABELS[
            CoABuffManagerDB.buffTray.hideMode or "both"
        ] or "Tous les buffs"),
        0.75, 0.75, 0.75, true
    )
    if CoABuffManagerDB.buffTray.buttonUnlocked then
        GameTooltip:AddLine("Bouton deverrouille : glisse-le avec le clic gauche.", 1, 0.82, 0, true)
    end
    GameTooltip:AddLine(" ")

    local missing, count = CoABuffTray.ScanMissing(true)
    if count == 0 then
        GameTooltip:AddLine("Groupe complet : aucun buff disponible ne manque.", 0.4, 1, 0.4, true)
    else
        GameTooltip:AddLine(count .. " joueur(s) sans buff actif", 1, 0.35, 0.35)
        for index = 1, math.min(#missing, 8) do
            local item = missing[index]
            GameTooltip:AddDoubleLine(
                tostring(item.providerName),
                ((#item.optionNames > 1) and "1 parmi " or "") ..
                    table.concat(item.optionNames, " / "),
                1, 0.82, 0,
                1, 1, 1
            )
        end
        if #missing > 8 then
            GameTooltip:AddLine("Ouvre /cbm > Reglages pour la liste complete.", 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

function CoABuffTray.RefreshBadge(force)
    if not CoABuffTray.button then return end

    local count = 0
    if CoABuffManagerDB.buffTray.groupBadge then
        CoABuffTray.ScanMissing(force)
        count = CoABuffTray.missingCount or 0
    end

    if count > 0 then
        CoABuffTray.button.badge:SetText(count > 99 and "99+" or tostring(count))
        CoABuffTray.button.badge:SetTextColor(1, 0.2, 0.2)
    else
        CoABuffTray.button.badge:SetText("")
    end

    if CoABuffManagerDB.buffTray.buttonUnlocked then
        CoABuffTray.button.border:SetVertexColor(1, 0.82, 0, 1)
    elseif count > 0 then
        CoABuffTray.button.border:SetVertexColor(1, 0.15, 0.15, 1)
    else
        CoABuffTray.button.border:SetVertexColor(0.3, 1, 0.3, 0.9)
    end

    if CoABuffTray.settingsSummary then
        CoABuffTray.settingsSummary:SetText(CoABuffTray.BuildSummary(7))
    end
end

function CoABuffTray.Apply()
    EnsureDB()
    if not CoABuffTray.button then return end

    if CoABuffManagerDB.buffTray.enabled then
        CoABuffTray.button:Show()
        if not CoABuffTray.expanded then
            CoABuffTray.SetNativeVisible(false)
        end
        CoABuffTray.RefreshBadge()
    else
        CoABuffTray.expanded = false
        CoABuffTray.button:Hide()
        CoABuffTray.SetNativeVisible(true)
        if GameTooltip and GameTooltip:IsOwned(CoABuffTray.button) then
            GameTooltip:Hide()
        end
    end
end

function CoABuffTray.Create()
    if CoABuffTray.button then
        CoABuffTray.Apply()
        return
    end

    local button = CreateFrame("Button", ADDON_NAME .. "BuffTrayButton", UIParent)
    button:SetWidth(34)
    button:SetHeight(34)
    button:SetFrameStrata("HIGH")
    button:EnableMouse(true)
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    button:RegisterForDrag("LeftButton")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture("Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\MinimapIcon.tga")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)

    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    button.border:SetBlendMode("ADD")
    button.border:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.border:SetWidth(62)
    button.border:SetHeight(62)

    button.badge = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.badge:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -1)
    button.badge:SetJustifyH("RIGHT")

    button:SetScript("OnEnter", function()
        CoABuffTray.expanded = true
        CoABuffTray.leaveAt = nil
        if CoABuffManagerDB.buffTray.showOnHover then
            CoABuffTray.SetNativeVisible(true)
        end
        CoABuffTray.ShowTooltip()
    end)
    button:SetScript("OnLeave", function()
        CoABuffTray.leaveAt = (GetTime and GetTime() or 0) + 0.20
        if GameTooltip and GameTooltip:IsOwned(button) then
            GameTooltip:Hide()
        end
    end)
    button:SetScript("OnClick", function()
        CoABuffTray.expanded = not CoABuffTray.expanded
        CoABuffTray.SetNativeVisible(CoABuffTray.expanded)
    end)
    button:SetScript("OnDragStart", function(self)
        if CoABuffManagerDB.buffTray.buttonUnlocked
            and not (InCombatLockdown and InCombatLockdown()) then
            self:StartMoving()
        end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        CoABuffTray.SaveButtonPosition()
    end)

    button.elapsed = 0
    button:SetScript("OnUpdate", function(self, delta)
        if not CoABuffManagerDB or not CoABuffManagerDB.buffTray.enabled then return end
        self.elapsed = self.elapsed + (delta or 0)
        if self.elapsed < 0.15 then return end
        self.elapsed = 0

        local overButton = CoABuffTray.IsMouseOver(self)
        local overBuffs = CoABuffTray.IsMouseOver(CoABuffTray.GetNativeFrame())
        if overButton or overBuffs then
            CoABuffTray.leaveAt = nil
            if CoABuffManagerDB.buffTray.showOnHover then
                CoABuffTray.expanded = true
                CoABuffTray.SetNativeVisible(true)
            end
        elseif CoABuffTray.expanded and CoABuffManagerDB.buffTray.showOnHover then
            if not CoABuffTray.leaveAt then
                CoABuffTray.leaveAt = (GetTime and GetTime() or 0) + 0.20
            elseif (GetTime and GetTime() or 0) >= CoABuffTray.leaveAt then
                CoABuffTray.expanded = false
                CoABuffTray.leaveAt = nil
                CoABuffTray.SetNativeVisible(false)
            end
        elseif not CoABuffTray.expanded then
            -- Le code natif peut rappeler :Show() lors d'un changement d'aura.
            CoABuffTray.SetNativeVisible(false)
        end
    end)

    CoABuffTray.button = button
    CoABuffTray.RestoreButtonPosition()
    CoABuffTray.Apply()
end

function CoABuffTray.BuildSettings(parent)
    local title = CreateText(parent, "GameFontNormal", "LEFT")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -8)
    title:SetText("Affichage compact des buffs")

    local function AddOption(y, label, key)
        local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        check:SetWidth(20)
        check:SetHeight(20)
        check:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, y)
        check:SetChecked(CoABuffManagerDB.buffTray[key])
        check:SetScript("OnClick", function(self)
            CoABuffManagerDB.buffTray[key] = self:GetChecked() and true or false
            CoABuffTray.Apply()
            CoABuffTray.RefreshSettings()
        end)

        local text = CreateText(parent, "GameFontHighlightSmall", "LEFT")
        text:SetPoint("LEFT", check, "RIGHT", 2, 0)
        text:SetWidth(315)
        text:SetText(label)
        CoABuffTray.settingChecks[key] = check
    end

    CoABuffTray.settingChecks = {}
    AddOption(-34, "Remplacer la barre de buffs par un bouton", "enabled")
    AddOption(-56, "Reafficher les buffs au survol", "showOnHover")
    AddOption(-78, "Afficher le nombre de buffs manquants", "groupBadge")
    AddOption(-100, "Deverrouiller le bouton pour le deplacer", "buttonUnlocked")

    local hideModeTitle = CreateText(parent, "GameFontHighlightSmall", "LEFT")
    hideModeTitle:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -126)
    hideModeTitle:SetText("Buffs a masquer avec le bouton compact")

    local hideModeDropdown = CreateFrame(
        "Frame", "CoABuffManagerBuffTrayHideModeDropdown", parent,
        "UIDropDownMenuTemplate"
    )
    hideModeDropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", 504, -140)
    UIDropDownMenu_SetWidth(hideModeDropdown, 210)
    UIDropDownMenu_Initialize(hideModeDropdown, function()
        local definitions = {
            { value = "raid", label = BUFF_TRAY_HIDE_MODE_LABELS.raid },
            { value = "player", label = BUFF_TRAY_HIDE_MODE_LABELS.player },
            { value = "both", label = BUFF_TRAY_HIDE_MODE_LABELS.both },
        }
        for _, definition in ipairs(definitions) do
            local modeValue = definition.value
            local modeLabel = definition.label
            local info = UIDropDownMenu_CreateInfo()
            info.text = modeLabel
            info.value = modeValue
            info.checked = CoABuffManagerDB.buffTray.hideMode == modeValue
            info.func = function()
                CoABuffManagerDB.buffTray.hideMode = modeValue
                UIDropDownMenu_SetSelectedValue(hideModeDropdown, modeValue)
                UIDropDownMenu_SetText(hideModeDropdown, modeLabel)
                CoABuffTray.expanded = false
                CoABuffTray.Apply()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    CoABuffTray.hideModeDropdown = hideModeDropdown
    UIDropDownMenu_SetSelectedValue(hideModeDropdown, CoABuffManagerDB.buffTray.hideMode)
    UIDropDownMenu_SetText(
        hideModeDropdown,
        BUFF_TRAY_HIDE_MODE_LABELS[CoABuffManagerDB.buffTray.hideMode]
            or BUFF_TRAY_HIDE_MODE_LABELS.both
    )

    local summaryTitle = CreateText(parent, "GameFontNormal", "LEFT")
    summaryTitle:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -188)
    summaryTitle:SetText("Controle du groupe")

    CoABuffTray.settingsSummary = CreateText(parent, "GameFontHighlightSmall", "LEFT")
    CoABuffTray.settingsSummary:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -212)
    CoABuffTray.settingsSummary:SetWidth(340)
    CoABuffTray.settingsSummary:SetHeight(112)
    CoABuffTray.settingsSummary:SetJustifyV("TOP")

    local refresh = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    refresh:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -330)
    refresh:SetWidth(180)
    refresh:SetHeight(22)
    refresh:SetText("Actualiser le controle")
    refresh:SetScript("OnClick", function()
        CoABuffTray.RefreshBadge()
        CoABuffTray.RefreshSettings()
    end)
end

function CoABuffTray.RefreshSettings()
    if CoABuffTray.settingChecks then
        for key, check in pairs(CoABuffTray.settingChecks) do
            check:SetChecked(CoABuffManagerDB.buffTray[key] and true or false)
        end
    end
    if CoABuffTray.settingsSummary then
        CoABuffTray.settingsSummary:SetText(CoABuffTray.BuildSummary(7))
    end
    if CoABuffTray.hideModeDropdown then
        local mode = CoABuffManagerDB.buffTray.hideMode or "both"
        UIDropDownMenu_SetSelectedValue(CoABuffTray.hideModeDropdown, mode)
        UIDropDownMenu_SetText(
            CoABuffTray.hideModeDropdown,
            BUFF_TRAY_HIDE_MODE_LABELS[mode] or BUFF_TRAY_HIDE_MODE_LABELS.both
        )
    end
end

local settingsPanelBuilt = false

RebuildSettingsPanel = function()
    if not panels.settings then
        return
    end

    if not settingsPanelBuilt then
        settingsPanelBuilt = true

        CoABuffTray.BuildSettings(panels.settings)

        local title = CreateText(panels.settings, "GameFontNormal", "LEFT")
        title:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -8)
        title:SetText("Reglages")

        local openMacroLabel = CreateText(panels.settings, "GameFontHighlightSmall", "LEFT")
        openMacroLabel:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -40)
        openMacroLabel:SetWidth(500)
        openMacroLabel:SetText(
            "Cree une macro simple qui ouvre cette fenetre (/cbm), a placer sur ta barre de sorts."
        )

        local openMacroButton = CreateFrame(
            "Button", nil, panels.settings, "UIPanelButtonTemplate"
        )
        openMacroButton:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -62)
        openMacroButton:SetWidth(220)
        openMacroButton:SetHeight(25)
        openMacroButton:SetText("Creer la macro CBM")
        openMacroButton:SetScript("OnClick", CreateOpenAddonMacro)

        local macroThemAllLabel = CreateText(panels.settings, "GameFontHighlightSmall", "LEFT")
        macroThemAllLabel:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -104)
        macroThemAllLabel:SetWidth(500)
        macroThemAllLabel:SetText(
            "Clic droit sur une icone de sort dans la vue d'ensemble pour verrouiller " ..
            "cette categorie (contour rouge) -- alimente ses boutons Overview et sa " ..
            "ligne dans le suivi flottant (HUD). Pas de macro generee automatiquement."
        )

        -- Manual retry for the "spec inconnue chez un coequipier" case:
        -- normal announces only fire on login/roster-change/timer, each
        -- throttled a few seconds apart, so if a remote member's data
        -- still hasn't arrived (dropped message, addon just loaded,
        -- etc.) this asks every CoABuffManager client in the group to
        -- (re-)announce right now instead of waiting.
        local requestButton = CreateFrame(
            "Button", nil, panels.settings, "UIPanelButtonTemplate"
        )
        requestButton:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -140)
        requestButton:SetWidth(220)
        requestButton:SetHeight(25)
        requestButton:SetText("Redemander infos du groupe")
        requestButton:SetScript("OnClick", function()
            if CoABuffComm and type(CoABuffComm.RequestFromOthers) == "function" then
                local sent = CoABuffComm.RequestFromOthers()
                if sent then
                    Print(
                        "Demande envoyee au groupe. Si les autres ont bien " ..
                        "CoABuffManager, leurs specs/sorts connus devraient " ..
                        "apparaitre dans l'Overview d'ici quelques secondes."
                    )
                else
                    Print("Impossible d'envoyer : pas dans un groupe/raid actuellement.")
                end
            else
                Print("Module de communication indisponible.")
            end
        end)

        local mainWinTitle = CreateText(panels.settings, "GameFontNormal", "LEFT")
        mainWinTitle:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -180)
        mainWinTitle:SetText("Fenetre principale (Overview)")

        local mainWinOpacitySlider = CreateFrame(
            "Slider", "CoABuffManagerMainOpacitySlider", panels.settings, "OptionsSliderTemplate"
        )
        mainWinOpacitySlider:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 14, -204)
        mainWinOpacitySlider:SetWidth(160)
        mainWinOpacitySlider:SetHeight(16)
        mainWinOpacitySlider:SetOrientation("HORIZONTAL")
        mainWinOpacitySlider:SetMinMaxValues(0.2, 1.0)
        mainWinOpacitySlider:SetValueStep(0.05)
        mainWinOpacitySlider:SetValue(CoABuffManagerDB.mainWindowOpacity or 1.0)
        -- Behaviour attached before the decorative labels below, same
        -- reasoning as the HUD opacity slider: a missing Low/High/Text
        -- sub-region on this client must never be able to prevent the
        -- slider from actually doing something.
        mainWinOpacitySlider:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value * 20 + 0.5) / 20
            CoABuffManagerDB.mainWindowOpacity = value
            if SetMainFrameOpacity then
                SetMainFrameOpacity(value)
            end
        end)
        local mainWinLow = getglobal("CoABuffManagerMainOpacitySliderLow")
        if mainWinLow then mainWinLow:SetText("Transparent") end
        local mainWinHigh = getglobal("CoABuffManagerMainOpacitySliderHigh")
        if mainWinHigh then mainWinHigh:SetText("Opaque") end
        local mainWinText = getglobal("CoABuffManagerMainOpacitySliderText")
        if mainWinText then mainWinText:SetText("Opacite du fond de la fenetre") end

        local bgModeButtons = {}

        local function SetMainWindowBackground(mode)
            CoABuffManagerDB.mainWindowBackground = mode
            for buttonMode, button in pairs(bgModeButtons) do
                button:SetChecked(buttonMode == mode)
            end
            if ApplyMainWindowBackground then
                ApplyMainWindowBackground()
            end
        end

        local bgModeDefs = {
            { mode = "parchment", label = "Parchemin (illustration)", x = 8 },
            { mode = "black", label = "Noir uni", x = 180 },
        }

        for _, def in ipairs(bgModeDefs) do
            local button = CreateFrame(
                "CheckButton", nil, panels.settings, "UICheckButtonTemplate"
            )
            button:SetWidth(20)
            button:SetHeight(20)
            button:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", def.x, -228)
            button:SetScript("OnClick", function() SetMainWindowBackground(def.mode) end)

            local label = CreateText(panels.settings, "GameFontHighlightSmall", "LEFT")
            label:SetPoint("LEFT", button, "RIGHT", 2, 0)
            label:SetText(def.label)

            bgModeButtons[def.mode] = button
        end

        local currentBgMode = CoABuffManagerDB.mainWindowBackground or "parchment"
        for buttonMode, button in pairs(bgModeButtons) do
            button:SetChecked(buttonMode == currentBgMode)
        end

        local hudTitle = CreateText(panels.settings, "GameFontNormal", "LEFT")
        hudTitle:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -284)
        hudTitle:SetText("Suivi flottant (HUD)")

        local hudModeButtons = {}

        local function SetHudMode(mode)
            CoABuffManagerDB.trackerHUD.mode = mode
            for buttonMode, button in pairs(hudModeButtons) do
                button:SetChecked(buttonMode == mode)
            end
            if RefreshTrackerHUD then
                RefreshTrackerHUD()
            end
        end

        local hudModeDefs = {
            { mode = "auto", label = "Auto (cache pendant le combat, revient apres)", y = -308 },
            { mode = "always", label = "Toujours visible (meme en combat, lecture seule)", y = -328 },
            { mode = "never", label = "Toujours cache", y = -348 },
        }

        for _, def in ipairs(hudModeDefs) do
            local button = CreateFrame(
                "CheckButton", nil, panels.settings, "UICheckButtonTemplate"
            )
            button:SetWidth(20)
            button:SetHeight(20)
            button:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, def.y)
            button:SetScript("OnClick", function() SetHudMode(def.mode) end)

            local label = CreateText(panels.settings, "GameFontHighlightSmall", "LEFT")
            label:SetPoint("LEFT", button, "RIGHT", 2, 0)
            label:SetText(def.label)

            hudModeButtons[def.mode] = button
        end

        local currentMode = CoABuffManagerDB.trackerHUD.mode or "auto"
        for buttonMode, button in pairs(hudModeButtons) do
            button:SetChecked(buttonMode == currentMode)
        end

        local unlockButton = CreateFrame(
            "CheckButton", nil, panels.settings, "UICheckButtonTemplate"
        )
        unlockButton:SetWidth(20)
        unlockButton:SetHeight(20)
        unlockButton:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -372)
        unlockButton:SetChecked(not CoABuffManagerDB.trackerHUD.locked)
        unlockButton:SetScript("OnClick", function(self)
            CoABuffManagerDB.trackerHUD.locked = not self:GetChecked()
            if SetTrackerFrameLocked then
                SetTrackerFrameLocked(CoABuffManagerDB.trackerHUD.locked)
            end
        end)

        local unlockLabel = CreateText(panels.settings, "GameFontHighlightSmall", "LEFT")
        unlockLabel:SetPoint("LEFT", unlockButton, "RIGHT", 2, 0)
        unlockLabel:SetText("Deverrouiller le HUD pour le deplacer (glisser la fenetre)")

        local opacitySlider = CreateFrame(
            "Slider", "CoABuffManagerHUDOpacitySlider", panels.settings, "OptionsSliderTemplate"
        )
        opacitySlider:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 14, -404)
        opacitySlider:SetWidth(160)
        opacitySlider:SetHeight(16)
        opacitySlider:SetOrientation("HORIZONTAL")
        opacitySlider:SetMinMaxValues(0.1, 1.0)
        opacitySlider:SetValueStep(0.05)
        opacitySlider:SetValue(CoABuffManagerDB.trackerHUD.opacity or 0.45)
        -- Attach the behaviour FIRST: if the template's Low/High/Text
        -- sub-regions below don't exist under these exact global names on
        -- this client, getglobal returns nil and :SetText would throw --
        -- aborting the rest of this block before the slider actually did
        -- anything. Doing the labels last (and defensively) means a
        -- missing label can never break the slider's actual function.
        opacitySlider:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value * 20 + 0.5) / 20
            CoABuffManagerDB.trackerHUD.opacity = value
            if SetTrackerFrameOpacity then
                SetTrackerFrameOpacity(value)
            end
        end)
        local opacityLow = getglobal("CoABuffManagerHUDOpacitySliderLow")
        if opacityLow then opacityLow:SetText("Transparent") end
        local opacityHigh = getglobal("CoABuffManagerHUDOpacitySliderHigh")
        if opacityHigh then opacityHigh:SetText("Opaque") end
        local opacityText = getglobal("CoABuffManagerHUDOpacitySliderText")
        if opacityText then opacityText:SetText("Opacite du fond du HUD") end

        local locksTitle = CreateText(panels.settings, "GameFontNormal", "LEFT")
        locksTitle:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -440)
        locksTitle:SetText("Categories verrouillees")

        local pruneButton = CreateFrame(
            "Button", nil, panels.settings, "UIPanelButtonTemplate"
        )
        pruneButton:SetWidth(170)
        pruneButton:SetHeight(20)
        pruneButton:SetPoint("LEFT", locksTitle, "RIGHT", 12, 0)
        pruneButton:SetText("Nettoyer les verrous")
        pruneButton:SetScript("OnClick", function()
            local changed = PruneStaleLockTargets(GetRoster())
            if changed then
                Print("Verrou(s) obsolete(s) retire(s) (destinataire hors groupe).")
            else
                Print("Aucun verrou obsolete trouve.")
            end
            if RequestMacroRegeneration then
                RequestMacroRegeneration("nettoyage manuel des verrous")
            end
            if RefreshTrackerHUD then RefreshTrackerHUD() end
            if RebuildSettingsPanel then RebuildSettingsPanel() end
        end)

        -- Scrollable list: with many categories/targets locked at once
        -- (full raid, several individually-locked players per category)
        -- the list can easily exceed the panel's remaining height, so it
        -- lives in its own scroll frame rather than spilling past the
        -- bottom of Reglages with no way to see the rest.
        local locksScroll = CreateFrame(
            "ScrollFrame", "CoABuffManagerLocksScroll", panels.settings,
            "UIPanelScrollFrameTemplate"
        )
        locksScroll:SetPoint("TOPLEFT", panels.settings, "TOPLEFT", 8, -462)
        locksScroll:SetPoint("BOTTOMRIGHT", panels.settings, "BOTTOMRIGHT", -30, 4)

        settingsLocksScrollChild = CreateFrame("Frame", nil, locksScroll)
        settingsLocksScrollChild:SetWidth(1)
        settingsLocksScrollChild:SetHeight(1)
        locksScroll:SetScrollChild(settingsLocksScrollChild)
    end

    -- Stale individual-lock targets are NOT auto-pruned here on every
    -- open, by design: the player can force it with the "Nettoyer les
    -- verrous" button below, or it happens automatically on an actual
    -- group-composition change (PARTY_MEMBERS_CHANGED/RAID_ROSTER_UPDATE).
    HideCollection(settingsLockLabels)

    EnsureDB()
    CoABuffTray.RefreshSettings()
    local locks = CoABuffManagerDB.macroLocks or {}
    local families = {}
    for family in pairs(locks) do
        table.insert(families, family)
    end
    table.sort(families)

    local LOCKS_LIST_WIDTH = 440

    if #families == 0 then
        if not settingsLockLabels[1] then
            settingsLockLabels[1] = CreateText(settingsLocksScrollChild, "GameFontHighlightSmall", "LEFT")
        end
        local emptyLabel = settingsLockLabels[1]
        emptyLabel:ClearAllPoints()
        emptyLabel:SetPoint("TOPLEFT", settingsLocksScrollChild, "TOPLEFT", 0, 0)
        emptyLabel:SetWidth(LOCKS_LIST_WIDTH)
        emptyLabel:SetText("Aucune categorie verrouillee pour le moment.")
        emptyLabel:Show()
        settingsLocksScrollChild:SetWidth(LOCKS_LIST_WIDTH)
        settingsLocksScrollChild:SetHeight(16)
    else
        for index, family in ipairs(families) do
            if not settingsLockLabels[index] then
                settingsLockLabels[index] = CreateText(settingsLocksScrollChild, "GameFontHighlightSmall", "LEFT")
            end
            local lockLabel = settingsLockLabels[index]
            lockLabel:ClearAllPoints()
            lockLabel:SetPoint(
                "TOPLEFT", settingsLocksScrollChild, "TOPLEFT", 0, -((index - 1) * 16)
            )
            lockLabel:SetWidth(LOCKS_LIST_WIDTH)
            lockLabel:SetText(DescribeFamilyLock(family, locks[family]))
            lockLabel:Show()
        end
        settingsLocksScrollChild:SetWidth(LOCKS_LIST_WIDTH)
        settingsLocksScrollChild:SetHeight(math.max(1, #families * 16))
    end
end

local function ShowTab(tabName)
    tabName = tabName or "overview"

    if tabName ~= "settings" then
        tabName = "overview"
    end

    activeTab = tabName

    for name, panel in pairs(panels) do
        if name == tabName then
            panel:Show()
        else
            panel:Hide()
        end
    end

    if tabName == "settings" then
        if RebuildSettingsPanel then
            RebuildSettingsPanel()
        end
        statusText:SetText(
            "Reglages : creer la macro /cbm ou verrouiller des categories pour le suivi HUD."
        )
        return
    end

    RebuildOverviewPanel()

    local playerMember = GetPlayerMemberFromRoster(GetRoster())
    local recommendedText = GetRecommendedStatsText(playerMember)
    if recommendedText and playerMember and playerMember.specName then
        statusText:SetText(
            "Or = stats recommandees pour " ..
            tostring(playerMember.specName) ..
            " : " .. recommendedText ..
            ". Les lignes rouges signalent seulement un conflit potentiel."
        )
    else
        statusText:SetText(
            "Les lignes rouges signalent seulement un conflit potentiel."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Bouton minimap
-- ---------------------------------------------------------------------------

local minimapButton

local function GetMinimapButtonOffset(angle)
    local radius = 80
    local radians = math.rad(angle)
    return math.cos(radians) * radius, math.sin(radians) * radius
end

local function UpdateMinimapButtonPosition()
    if not minimapButton then
        return
    end

    local angle = (CoABuffManagerDB.minimap and CoABuffManagerDB.minimap.angle) or 200
    local x, y = GetMinimapButtonOffset(angle)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Manual minimap button (no LibDBIcon/Ace dependency, consistent with the
-- rest of the addon staying dependency-free). Left click toggles the main
-- window, same behaviour as /cbm with no argument. Dragging repositions it
-- anywhere around the minimap ring; the angle is saved so it stays put
-- across sessions.
local function CreateMinimapButton()
    EnsureDB()

    if minimapButton then
        UpdateMinimapButtonPosition()
        if CoABuffManagerDB.minimap.hide then
            minimapButton:Hide()
        else
            minimapButton:Show()
        end
        return
    end

    local button = CreateFrame("Button", ADDON_NAME .. "MinimapButton", Minimap)
    button:SetWidth(31)
    button:SetHeight(31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(31)
    icon:SetHeight(31)
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    icon:SetTexture(
        "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\MinimapIcon.tga"
    )
    button.icon = icon

    -- No separate Blizzard border texture here: this icon is a self-
    -- contained badge with its own gold ring baked in, so overlaying the
    -- standard MiniMap-TrackingBorder on top would just stack a second,
    -- redundant ring around it.

    button:SetScript("OnClick", function()
        if mainFrame then
            if mainFrame:IsShown() then
                mainFrame:Hide()
            else
                mainFrame:Show()
            end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("CoA Buff Manager")
        GameTooltip:AddLine("Clic gauche : ouvrir/fermer la fenetre.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Glisser : deplacer l'icone autour de la minimap.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local minimapX, minimapY = Minimap:GetCenter()
            local cursorX, cursorY = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cursorX = cursorX / scale
            cursorY = cursorY / scale

            local angle = math.deg(math.atan2(cursorY - minimapY, cursorX - minimapX))
            CoABuffManagerDB.minimap.angle = angle
            UpdateMinimapButtonPosition()
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton = button
    UpdateMinimapButtonPosition()

    if CoABuffManagerDB.minimap.hide then
        button:Hide()
    end
end

local function ToggleMinimapButton()
    EnsureDB()
    CoABuffManagerDB.minimap.hide = not CoABuffManagerDB.minimap.hide

    if not minimapButton then
        CreateMinimapButton()
    end

    if CoABuffManagerDB.minimap.hide then
        minimapButton:Hide()
        Print("Icone minimap masquee.")
    else
        minimapButton:Show()
        Print("Icone minimap affichee.")
    end
end

local function CreateMainFrame()
    mainFrame = CreateFrame("Frame", ADDON_NAME .. "Frame", UIParent)
    mainFrame:SetWidth(920)
    mainFrame:SetHeight(620)
    mainFrame:SetScale(0.82)
    mainFrame:SetFrameStrata("DIALOG")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:RegisterForDrag("LeftButton")

    -- Prevents the window from ever being positioned (or dragged) partly
    -- or fully off-screen -- e.g. a stale saved position from a previous
    -- session/resolution/UI scale could otherwise push it left until its
    -- border and the legend text at the bottom got clipped by the edge
    -- of the screen. The engine re-clamps automatically any time the
    -- frame's position changes, including on RestorePosition() below.
    mainFrame:SetClampedToScreen(true)

    mainFrame:SetScript("OnDragStart", function(self)
        if not (InCombatLockdown and InCombatLockdown()) then
            self:StartMoving()
        end
    end)

    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    mainFrame:SetScript("OnShow", function()
        ShowTab("overview")
    end)

    mainFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = false,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    mainFrame:SetBackdropBorderColor(1, 1, 1, 1)

    -- Custom artwork background, layered UNDER the backdrop's own fill --
    -- ApplyMainWindowBackground (below) decides which of the two is
    -- visible based on CoABuffManagerDB.mainWindowBackground: "parchment"
    -- shows this texture and makes the backdrop fill fully transparent;
    -- "black" hides this texture and uses the backdrop's plain black fill
    -- instead (see the opacity slider's comment for why that stays a
    -- plain colour rather than a recoloured texture).
    mainFrame.parchmentTexture = mainFrame:CreateTexture(nil, "BACKGROUND")
    mainFrame.parchmentTexture:SetTexture(
        "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\OverviewBackground.tga"
    )
    -- The actual artwork is a 1024x690 image, but WotLK 3.3.5 requires
    -- power-of-two texture dimensions to load reliably, so the file is a
    -- 1024x1024 canvas with the art in the top band and plain black
    -- padding below. This samples only that top band (0 to ~0.674 of the
    -- texture's height) so the padding never shows.
    mainFrame.parchmentTexture:SetTexCoord(0, 1, 0, 0.673828125)
    mainFrame.parchmentTexture:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 11, -12)
    mainFrame.parchmentTexture:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -12, 11)

    ApplyMainWindowBackground()

    local title = CreateText(mainFrame, "GameFontNormalLarge", "CENTER")
    title:SetPoint("TOP", mainFrame, "TOP", 0, -16)
    title:SetText("CoA Buff Manager")

    local versionText = CreateText(mainFrame, "GameFontHighlightSmall", "CENTER")
    versionText:SetPoint("TOP", title, "BOTTOM", 0, -2)
    versionText:SetText("v" .. ADDON_VERSION)

    local subtitle = CreateText(mainFrame, "GameFontNormalSmall", "CENTER")
    subtitle:SetPoint("TOP", versionText, "BOTTOM", 0, -5)
    subtitle:SetText("Buffs a lancer et conflits possibles")

    local closeButton =
        CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)

    local settingsButton = CreateFrame(
        "Button", nil, mainFrame, "UIPanelButtonTemplate"
    )
    settingsButton:SetWidth(90)
    settingsButton:SetHeight(22)
    settingsButton:SetPoint("TOPRIGHT", closeButton, "TOPLEFT", -4, -3)
    settingsButton:SetText("Reglages")
    settingsButton:SetScript("OnClick", function()
        if activeTab == "settings" then
            ShowTab("overview")
        else
            ShowTab("settings")
        end
    end)

    panels.overview = CreateFrame("Frame", nil, mainFrame)
    panels.overview:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 18, -62)
    panels.overview:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -18, 42)

    panels.settings = CreateFrame("Frame", nil, mainFrame)
    panels.settings:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 18, -62)
    panels.settings:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -18, 42)
    panels.settings:Hide()

    -- Conserved internally for legacy slash commands, but no longer exposed as a tab.
    panels.casts = CreateFrame("Frame", nil, mainFrame)
    panels.casts:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 18, -62)
    panels.casts:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -18, 42)

    statusText = CreateText(mainFrame, "GameFontHighlightSmall", "CENTER")
    statusText:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 17)
    statusText:SetWidth(870)

    RestorePosition()
    mainFrame:Hide()
end

local function ListDetectedClasses()
    local roster = GetRoster()

    for _, member in ipairs(roster) do
        Print(
            member.name ..
            " | " ..
            member.className ..
            " | TOKEN=" ..
            member.classToken ..
            " | ID=" ..
            tostring(member.classID)
        )
    end
end

local function ListCatalog()
    local entries = CollectAllCatalogEntries()

    if #entries == 0 then
        Print("Catalogue vide.")
        return
    end

    for _, entry in ipairs(entries) do
        Print(
            entry.className ..
            " | TOKEN=" ..
            entry.classToken ..
            " | " ..
            entry.category ..
            "=" ..
            tostring(entry.value)
        )
    end
end

SLASH_COABUFFMANAGER1 = "/cbm"
SLASH_COABUFFMANAGER2 = "/coabuffs"

SlashCmdList["COABUFFMANAGER"] = function(message)
    EnsureDB()

    local command, rest = string.match(
        Trim(message),
        "^(%S*)%s*(.-)$"
    )

    command = string.lower(command or "")
    rest = Trim(rest)

    if command == "" then
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            mainFrame:Show()
        end

    elseif command == "classes" then
        ListDetectedClasses()

    elseif command == "catalog" then
        ListCatalog()

    elseif command == "database" then
        local count = 0
        if CoABuffDatabase and CoABuffDatabase.classes then
            for _, classData in pairs(CoABuffDatabase.classes) do
                count = count + #(classData.spells or {})
            end
        end
        Print("Verified embedded database: " .. tostring(count) .. " spell record(s).")
        Print("Knight of Xoroth, Runemaster, Witch Doctor and Pyromancer records are verified from in-game spellbook audits.")

    elseif command == "scan" then
        ScanSpellbook()

    elseif command == "scans" then
        ListSpellbookScans()

    elseif command == "clearscan" then
        ClearCurrentSpellbookScan()

    elseif command == "scantrainer" then
        ScanTrainer()

    elseif command == "trainerscans" then
        ListTrainerScans()

    elseif command == "cleartrainerscan" then
        ClearCurrentTrainerScan()

    elseif command == "scantalent" then
        ScanTalents()

    elseif command == "talentscans" then
        ListTalentScans()

    elseif command == "scannearby" then
        Talents.ScanNearby()

    elseif command == "cleartalentscan" then
        ClearCurrentTalentScan()

    elseif command == "add" then
        if InCombatLockdown and InCombatLockdown() then
            Print("Ajout impossible pendant le combat.")
            return
        end

        if AddPersonalSpellByName(rest) then
            RebuildCastPanel()
            if activeTab == "overview" then
                RebuildOverviewPanel()
            end
        end

    elseif command == "addid" then
        if InCombatLockdown and InCombatLockdown() then
            Print("Ajout impossible pendant le combat.")
            return
        end

        if AddPersonalSpellByID(rest, false) then
            RebuildCastPanel()
            if activeTab == "overview" then
                RebuildOverviewPanel()
            end
        end

    elseif command == "remove" then
        if InCombatLockdown and InCombatLockdown() then
            Print("Suppression impossible pendant le combat.")
            return
        end

        local index = tonumber(rest)
        if index and CoABuffManagerDB.spells[index] then
            Print(
                "Sort personnel retire : " ..
                CoABuffManagerDB.spells[index].name
            )
            table.remove(CoABuffManagerDB.spells, index)
            RebuildCastPanel()
            if activeTab == "overview" then
                RebuildOverviewPanel()
            end
        else
            Print("Numero de ligne invalide.")
        end

    elseif command == "reset" then
        if InCombatLockdown and InCombatLockdown() then
            Print("Reset impossible pendant le combat.")
            return
        end

        CoABuffManagerDB.spells = {}
        CoABuffManagerDB.personalDefaultsSeeded = nil
        SeedPersonalSpells()
        RebuildCastPanel()
        if activeTab == "overview" then
            RebuildOverviewPanel()
        end
        Print("Sorts personnels reinitialises.")

    elseif command == "overview" then
        activeTab = "overview"
        mainFrame:Show()
        ShowTab("overview")

    elseif command == "casts" then
        activeTab = "overview"
        mainFrame:Show()
        ShowTab("overview")

    elseif command == "hud" then
        if CoABuffManagerDB.trackerHUD.mode == "never" then
            CoABuffManagerDB.trackerHUD.mode = "auto"
            Print("Suivi flottant active (mode auto). Details dans Reglages.")
        else
            CoABuffManagerDB.trackerHUD.mode = "never"
            Print("Suivi flottant desactive.")
        end
        if RebuildSettingsPanel and activeTab == "settings" then
            RebuildSettingsPanel()
        end
        if RefreshTrackerHUD then RefreshTrackerHUD() end

    elseif command == "minimap" then
        ToggleMinimapButton()

    elseif command == "testalert" then
        if ShowBuffExpiryWarning then
            ShowBuffExpiryWarning("Test CoA Buff Manager", UnitName("player") or "joueur")
        end

    else
        Print("/cbm : ouvrir ou fermer")
        Print("/cbm overview : buffs applicables et conflits potentiels")
        Print("/cbm casts : ouvrir la page de lancement")
        Print("/cbm classes : afficher les classes detectees")
        Print("/cbm catalog : afficher le catalogue manuel")
        Print("/cbm database : etat de la base embarquee")
        Print("/cbm scan : auditer le grimoire de la specialisation actuelle")
        Print("/cbm scans : lister les audits enregistres")
        Print("/cbm clearscan : supprimer l'audit de la specialisation actuelle")
        Print("/cbm testalert : tester l alerte d expiration")
        Print("/cbm hud : afficher/masquer le suivi flottant des verrous")
        Print("/cbm minimap : afficher/masquer l'icone minimap")
        Print("/cbm add <nom> : ajouter un buff personnel")
        Print("/cbm addid <ID> : ajouter un buff personnel par ID")
        Print("/cbm remove <numero> : retirer un buff personnel")
    end
end

ShowBuffExpiryWarning = function(spellName, targetName)
    local message = tostring(spellName or "Buff")
    if targetName and targetName ~= "" then
        message = message .. " sur " .. tostring(targetName)
    end
    message = message .. " expire dans moins de 5 min."

    Print(message)

    if RaidNotice_AddMessage and RaidWarningFrame
        and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
        pcall(
            RaidNotice_AddMessage,
            RaidWarningFrame,
            message,
            ChatTypeInfo["RAID_WARNING"]
        )
    end

    if PlaySound then
        pcall(PlaySound, "RaidWarning")
    end
end

local function MaybeWarnBuffExpiration(category, spellName, targetName, expirationTime)
    if not expirationTime or expirationTime <= 0 then
        return
    end

    local remaining = expirationTime - GetTime()
    if remaining <= 0 or remaining > BUFF_WARNING_SECONDS then
        return
    end

    local key = tostring(category) .. "|" .. tostring(targetName or "GROUP") ..
        "|" .. tostring(math.floor(expirationTime + 0.5))
    if warnedBuffExpirations[key] then
        return
    end

    warnedBuffExpirations[key] = expirationTime
    ShowBuffExpiryWarning(spellName, targetName)
end

local function ScanBuffExpiryWarnings()
    if not mainFrame or not CoABuffManagerDB then
        return
    end

    local roster = GetRoster()
    local playerMember = GetPlayerMemberFromRoster(roster)
    if not playerMember then
        return
    end

    local now = GetTime()
    for key, expirationTime in pairs(warnedBuffExpirations) do
        if not expirationTime or expirationTime < (now - 5) then
            warnedBuffExpirations[key] = nil
        end
    end

    for _, category in ipairs(CollectPlayerCastableCategories(roster)) do
        local groupEntry = GetAutomaticCatalogEntry(
            playerMember,
            category,
            nil,
            "PARTY_RAID"
        )
        local allyEntry = GetAutomaticCatalogEntry(
            playerMember,
            category,
            nil,
            "ALLY"
        )
        local referenceEntry = groupEntry or allyEntry

        if referenceEntry and referenceEntry.spell then
            local auraNames = GetFamilyAuraNames(
                playerMember,
                referenceEntry.family,
                referenceEntry.spell
            )

            if confirmedGroupCasts[category] and groupEntry then
                local allBuffed = true
                local checked = 0
                local earliestExpiration = nil

                for _, member in ipairs(roster) do
                    if UnitExists(member.unit)
                        and UnitIsConnected(member.unit)
                        and not UnitIsDeadOrGhost(member.unit) then

                        checked = checked + 1
                        local hasAura, expirationTime = UnitHasAura(
                            member.unit,
                            groupEntry.spell,
                            groupEntry.spellID,
                            auraNames
                        )
                        if not hasAura then
                            allBuffed = false
                        elseif expirationTime and expirationTime > 0
                            and (not earliestExpiration or expirationTime < earliestExpiration) then
                            earliestExpiration = expirationTime
                        end
                    end
                end

                if checked > 0 and allBuffed and earliestExpiration then
                    MaybeWarnBuffExpiration(
                        category,
                        groupEntry.spell,
                        "le groupe",
                        earliestExpiration
                    )
                end
            elseif allyEntry then
                local earliestExpiration = nil
                local earliestTarget = nil

                for _, member in ipairs(roster) do
                    if UnitExists(member.unit)
                        and UnitIsConnected(member.unit)
                        and not UnitIsDeadOrGhost(member.unit) then

                        local hasAura, expirationTime = UnitHasAura(
                            member.unit,
                            allyEntry.spell,
                            allyEntry.spellID,
                            auraNames
                        )
                        if hasAura and expirationTime and expirationTime > 0
                            and (not earliestExpiration or expirationTime < earliestExpiration) then
                            earliestExpiration = expirationTime
                            earliestTarget = member.name
                        end
                    end
                end

                if earliestExpiration then
                    MaybeWarnBuffExpiration(
                        category,
                        allyEntry.spell,
                        earliestTarget,
                        earliestExpiration
                    )
                end
            end
        end
    end
end

RefreshAllPanelsForRosterChange = function()
    if not mainFrame or not mainFrame:IsShown() then
        return
    end

    if activeTab == "overview" then
        RebuildOverviewPanel()
    elseif activeTab == "casts" then
        RebuildCastPanel()
    end
end

local eventFrame = CreateFrame("Frame")

local events = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PARTY_MEMBERS_CHANGED",
    "RAID_ROSTER_UPDATE",
    "UNIT_AURA",
    "UNIT_SPELLCAST_SUCCEEDED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    "SPELLS_CHANGED",
    "INSPECT_TALENT_READY",
    -- Les deux seuls evenements qui changent vraiment les talents du joueur :
    -- ils invalident le cache de Talents.GetLocalBoosts (voir son commentaire).
    "CHARACTER_POINTS_CHANGED",
    "ACTIVE_TALENT_GROUP_CHANGED",
}

for _, eventName in ipairs(events) do
    eventFrame:RegisterEvent(eventName)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2, arg3, arg4, arg5 = ...

    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()
        return
    end

    if event == "PLAYER_LOGIN" then
        EnsureDB()
        SeedPersonalSpells()
        MigratePersonalSpellFamilies()
        CreateMainFrame()
        CreateMinimapButton()
        CoABuffTray.Create()
        Print(ADDON_VERSION .. " Audit charge. Commande : /cbm")
        if CoABuffManagerDB.catalogResetNotice then
            Print("Ancien catalogue manuel retire des propositions et sauvegarde dans catalogBackup050.")
            CoABuffManagerDB.catalogResetNotice = nil
        end
        if CoABuffComm and type(CoABuffComm.RequestAnnounce) == "function" then
            CoABuffComm.RequestAnnounce()
        end
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
        CoABuffTray.lastScanAt = 0
        CoABuffTray.RefreshBadge(true)
        CoABuffTray.RefreshSettings()
        return
    end

    if event == "UNIT_AURA" then
        RefreshCastStates()
        RefreshOverviewCastStates()
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
        CoABuffTray.RefreshBadge()
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
        local groupCategory = GetTrackedSpellCategory(
            groupSpellCategoriesByID,
            groupSpellCategoriesByName,
            arg5,
            arg2
        )

        if groupCategory then
            confirmedGroupCasts[groupCategory] = true
            RefreshOverviewCastStates()
            return
        end

        local individualCategory = GetTrackedSpellCategory(
            individualSpellCategoriesByID,
            individualSpellCategoriesByName,
            arg5,
            arg2
        )

        if individualCategory then
            confirmedGroupCasts[individualCategory] = nil
            RefreshOverviewCastStates()
            return
        end
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- The auto-family buttons' PreClick can no longer recompute their
        -- target/spell once combat starts (SetAttribute is blocked by
        -- InCombatLockdown), so they would otherwise freeze on whatever
        -- they last had. RequestMacroRegeneration is now a no-op (the
        -- BUFF THEM ALL macro generator was removed) -- call kept only so
        -- this event handler doesn't need touching if it's ever reused.
        RequestMacroRegeneration("entree en combat")

        -- The tracker HUD's rows use the same frozen-PreClick mechanism,
        -- so ideally they'd hide for the whole fight rather than being left
        -- up in a state they can no longer keep accurate -- unless the
        -- player chose "always" in Reglages, in which case it stays up as
        -- a read-only display (see RefreshTrackerHUD). In practice a
        -- Hide() here is never reachable: InCombatLockdown() is already
        -- true by the time this handler runs, and Blizzard blocks
        -- Hide()/Show() on a frame with SecureActionButtonTemplate
        -- children during combat regardless of how it's triggered ("AddOn
        -- ... prevented the call of the secure function ... Hide()").
        -- Nothing to do here; RefreshTrackerHUD() already leaves an
        -- already-visible frame up untouched for the rest of the fight
        -- (colours/text still refresh) and hides it correctly the moment
        -- PLAYER_REGEN_ENABLED calls it again.

        if statusText then
            statusText:SetText(
                "Combat : les boutons existants restent utilisables."
            )
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if pendingSecureRebuild then
            if activeTab == "overview" then
                RebuildOverviewPanel()
            else
                RebuildCastPanel()
            end
        else
            RefreshCastStates()
            RefreshOverviewCastStates()
        end

        -- Reappears now that PreClick can recompute targets again --
        -- only if the player hasn't set mode to "never" in Reglages.
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
        CoABuffTray.RefreshBadge()
        CoABuffTray.RefreshSettings()
        return
    end

    if event == "PARTY_MEMBERS_CHANGED"
        or event == "RAID_ROSTER_UPDATE" then

        -- La composition a change : le roster cache est perime par definition.
        -- A faire AVANT le GetRoster() ci-dessous, sinon on travaillerait sur
        -- l'ancienne composition pendant tout le traitement de l'evenement.
        RosterCache.Invalidate()

        local roster = GetRoster()
        local locksChanged = PruneStaleLockTargets(roster)
        if locksChanged then
            Print("Verrou(s) individuel(s) retire(s) : le/la destinataire a quitte le groupe.")
        end

        if #roster > Talents.lastAutoScanCount then
            -- Group grew (new join, or a fresh group forming after a
            -- dungeon teleport) -- everyone is typically stacked at the
            -- same spot right then, all in inspect range, so this is the
            -- best moment to auto-scan talents instead of waiting for a
            -- manual /cbm scannearby. Small delay lets the roster/units
            -- actually finish loading in first.
            C_Timer.After(2, function() Talents.ScanNearby(true) end)
        end
        Talents.lastAutoScanCount = #roster

        RefreshAllPanelsForRosterChange()
        if locksChanged and mainFrame and mainFrame:IsShown()
            and activeTab == "settings" and RebuildSettingsPanel then
            RebuildSettingsPanel()
        end
        if RequestMacroRegeneration then
            RequestMacroRegeneration("composition du groupe modifiee")
        end
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
        CoABuffTray.lastScanAt = 0
        CoABuffTray.RefreshBadge(true)
        CoABuffTray.RefreshSettings()
        return
    end

    if event == "CHARACTER_POINTS_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if Talents.InvalidateLocal then
            Talents.InvalidateLocal()
        end
        RosterCache.Invalidate()
        RefreshAllPanelsForRosterChange()
        return
    end

    if event == "SPELLS_CHANGED" and mainFrame then
        -- Apprendre un sort peut accompagner un changement de talents.
        if Talents.InvalidateLocal then
            Talents.InvalidateLocal()
        end
        RosterCache.Invalidate()
        RebuildCastPanel()
        if mainFrame:IsShown() and activeTab == "overview" then
            RebuildOverviewPanel()
        end
        if CoABuffComm and type(CoABuffComm.RequestAnnounce) == "function" then
            CoABuffComm.RequestAnnounce()
        end
        return
    end

    if event == "INSPECT_TALENT_READY" then
        Talents.OnInspectReady()
        return
    end
end)

eventFrame:SetScript("OnUpdate", function(self, delta)
    buffWarningElapsed = buffWarningElapsed + (delta or 0)

    if buffWarningElapsed >= BUFF_WARNING_SCAN_INTERVAL then
        buffWarningElapsed = 0
        RefreshCastStates()
        RefreshOverviewCastStates()
        ScanBuffExpiryWarnings()
        if RefreshTrackerHUD then
            RefreshTrackerHUD()
        end
    end
end)
