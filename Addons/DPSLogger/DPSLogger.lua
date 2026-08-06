-- DPSLogger 2.0
-- Journal de telemetrie factuel pour CoASim / WoW 3.3.5 custom.
-- Le logger capture les faits bruts et laisse le parseur deduire les regles.

DPSLoggerDB = DPSLoggerDB or {}
DPSLoggerSettings = DPSLoggerSettings or {}

local ADDON_VERSION = "2.6.0"
local SCHEMA_VERSION = 3
local DEFAULT_MAX_EVENTS = 60000
local POLL_INTERVAL = 0.05
local POST_CAST_DELAY = 0.10
local CAUSE_WINDOW = 0.35
local COOLDOWN_EPSILON = 0.25

local logging = false
local currentSession = nil
local sessionStartTime = nil
local pendingAfter = {}
local preCast = {}
local trackedCooldowns = {}
local recentCauses = {}
local lastState = nil
local lastStatsSignature = nil
local stateDirty = false
local statsDirty = false
local nextPollAt = 0
local eventLimitWarned = false
local currentAttackPower = 0
local currentRangedAttackPower = 0

local frame = CreateFrame("Frame")

local POWER_NAMES = {
    [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY",
    [4] = "HAPPINESS", [5] = "RUNES", [6] = "RUNIC_POWER",
}

local function Trim(value)
    value = value or ""
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

local function Now()
    return GetTime()
end

local function RelativeTime(now)
    if not sessionStartTime then return 0 end
    return now - sessionStartTime
end

local function ShallowCopy(source)
    local result = {}
    if not source then return result end
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function SafeCall(func, ...)
    if not func then return nil end
    local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
    if not ok then return nil end
    return a, b, c, d, e, f, g, h
end

local function GetSpecializationSnapshot()
    local selectedTab = nil
    if GetPrimaryTalentTree then
        local ok, value = pcall(GetPrimaryTalentTree)
        if ok then selectedTab = value end
    end

    local bestTab, bestName, bestPoints = nil, nil, -1
    local tabCount = GetNumTalentTabs and GetNumTalentTabs() or 0
    for tab = 1, tabCount do
        local name, _, points = GetTalentTabInfo(tab)
        points = tonumber(points) or 0
        if tab == selectedTab or points > bestPoints then
            bestTab, bestName, bestPoints = tab, name, points
            if tab == selectedTab then break end
        end
    end
    return bestTab, bestName, math.max(0, bestPoints)
end

local function GetCharacterSnapshot()
    local name, realm = UnitName("player")
    local localizedClass, classToken = UnitClass("player")
    local race, raceToken = UnitRace("player")
    local specId, specName, specPoints = GetSpecializationSnapshot()
    return {
        name = name,
        realm = realm or GetRealmName(),
        guid = UnitGUID("player"),
        level = UnitLevel("player"),
        class = localizedClass,
        className = localizedClass,
        classToken = classToken,
        specId = specId,
        specName = specName,
        specPoints = specPoints,
        race = race,
        raceToken = raceToken,
        faction = UnitFactionGroup("player"),
    }
end

local function GetEnvironmentSnapshot()
    local zone = GetRealZoneText and GetRealZoneText() or nil
    local subZone = GetSubZoneText and GetSubZoneText() or nil
    local instanceName, instanceType, difficultyIndex,
          difficultyName, maxPlayers = nil, nil, nil, nil, nil
    if GetInstanceInfo then
        instanceName, instanceType, difficultyIndex,
        difficultyName, maxPlayers = GetInstanceInfo()
    end
    local _, _, homeLatency, worldLatency = GetNetStats()
    local version, build, buildDate, interface = GetBuildInfo()
    return {
        zone = zone,
        subZone = subZone,
        instanceName = instanceName,
        instanceType = instanceType,
        difficultyIndex = difficultyIndex,
        difficultyName = difficultyName,
        maxPlayers = maxPlayers,
        latencyHome = homeLatency,
        latencyWorld = worldLatency,
        clientVersion = version,
        clientBuild = build,
        clientBuildDate = buildDate,
        interface = interface,
    }
end

local function GetTargetSnapshot()
    if not UnitExists("target") then return nil end
    local classification = UnitClassification and UnitClassification("target")
    local creatureType = UnitCreatureType and UnitCreatureType("target")
    local creatureFamily = UnitCreatureFamily and UnitCreatureFamily("target")
    return {
        name = UnitName("target"),
        guid = UnitGUID("target"),
        level = UnitLevel("target"),
        classification = classification,
        creatureType = creatureType,
        creatureFamily = creatureFamily,
        hostile = UnitCanAttack("player", "target") and true or false,
        player = UnitIsPlayer("target") and true or false,
    }
end

-- Classes custom d'Ascension (Knight of Xoroth confirme) : AUCUN onglet
-- dans l'API de talents vanilla, GetNumTalentTabs() renvoie 0. C'est pour
-- ca que ce snapshot etait toujours vide sur ce personnage -- confirme le
-- 05/08/2026 en comparant aux sessions DPSLogger deja en base (talents
-- systematiquement []). Meme constat et meme repli que CoABuffManager
-- (ScanTalents/ScanTalentsCAO) : l'API "Character Advancement Overhaul"
-- (C_CharacterAdvancement.GetInspectedBuild) donne les entrees investies
-- (EntryId + Rank) directement, sans passer par les onglets classiques.
--
-- Contrairement au scan manuel de CoABuffManager, PAS de lecture de
-- tooltip ici (evite de dupliquer sa grosse table de correspondance
-- entryId -> nom/spellId, et le risque des appels tooltip pendant le
-- combat) : seuls entryId et rank sont captures. La resolution du nom se
-- fait en aval, cote CoASim/CoADataManager, par jointure sur entryId
-- contre kox_talents.json -- meme cle deja utilisee partout ailleurs dans
-- le projet (omaghad.js stocke deja `entryId` a cote de `name`).
--
-- Pas de garde "hors combat" contrairement a ScanTalents() : StartLogging()
-- doit pouvoir capturer au clic sur "commencer", y compris juste avant ou
-- pendant l'engagement. GetInspectedBuild() est un lecteur de donnees, pas
-- une manipulation de frame securisee ; en cas d'echec malgre tout, pcall
-- l'absorbe et renvoie simplement aucun talent CAO (pas pire qu'avant).
-- A VALIDER EN JEU : jamais testee en combat, seulement lue dans le code
-- de CoABuffManager qui, lui, s'interdit le combat par prudence generale.
local function GetTalentsSnapshotCAO()
    local api = _G.C_CharacterAdvancement
    if not api or type(api.GetActiveSpecID) ~= "function"
        or type(api.GetInspectedBuild) ~= "function" then
        return {}
    end

    local specOk, activeSpec = pcall(api.GetActiveSpecID)
    if not specOk or not activeSpec then return {} end

    local buildOk, entries = pcall(api.GetInspectedBuild, "player", activeSpec)
    if not buildOk or type(entries) ~= "table" then return {} end

    local result = {}
    for _, entry in ipairs(entries) do
        if entry and entry.EntryId and type(entry.Rank) == "number"
            and entry.Rank > 0 then
            result[#result + 1] = {
                source = "cao",
                entryId = entry.EntryId,
                rank = entry.Rank,
            }
        end
    end
    return result
end

local function GetTalentsSnapshot()
    local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 0
    if numTabs == 0 then
        return GetTalentsSnapshotCAO()
    end

    local result = {}
    for tab = 1, numTabs do
        local tabName = select(1, GetTalentTabInfo(tab))
        local numTalents = GetNumTalents(tab)
        for index = 1, numTalents do
            local name, icon, tier, column, rank, maxRank =
                GetTalentInfo(tab, index)
            if rank and rank > 0 then
                result[#result + 1] = {
                    tab = tabName,
                    index = index,
                    name = name,
                    icon = icon,
                    tier = tier,
                    column = column,
                    rank = rank,
                    maxRank = maxRank,
                }
            end
        end
    end
    return result
end

local function SafeCombatRating(id)
    return SafeCall(GetCombatRating, id)
end

local function RefreshAttackPower()
    local base, positive, negative = UnitAttackPower("player")
    currentAttackPower = (base or 0) + (positive or 0) + (negative or 0)
    local rangedBase, rangedPositive, rangedNegative = UnitRangedAttackPower("player")
    currentRangedAttackPower =
        (rangedBase or 0) + (rangedPositive or 0) + (rangedNegative or 0)
end

local function GetStatsSnapshot()
    local stats = { level = UnitLevel("player") }
    stats.strength = select(1, UnitStat("player", 1))
    stats.agility = select(1, UnitStat("player", 2))
    stats.stamina = select(1, UnitStat("player", 3))
    stats.intellect = select(1, UnitStat("player", 4))
    stats.spirit = select(1, UnitStat("player", 5))

    local base, positive, negative = UnitAttackPower("player")
    stats.attackPowerBase = base or 0
    stats.attackPowerPositive = positive or 0
    stats.attackPowerNegative = negative or 0
    stats.attackPower =
        stats.attackPowerBase +
        stats.attackPowerPositive +
        stats.attackPowerNegative

    local rangedBase, rangedPositive, rangedNegative =
        UnitRangedAttackPower("player")
    stats.rangedAttackPower =
        (rangedBase or 0) + (rangedPositive or 0) + (rangedNegative or 0)

    stats.spellPower = {}
    for school = 2, 7 do
        stats.spellPower[school] = SafeCall(GetSpellBonusDamage, school)
    end

    local ratingIds = {
        critMelee = CR_CRIT_MELEE or 14,
        critRanged = CR_CRIT_RANGED or 15,
        critSpell = CR_CRIT_SPELL or 16,
        hitMelee = CR_HIT_MELEE or 8,
        hitRanged = CR_HIT_RANGED or 9,
        hitSpell = CR_HIT_SPELL or 10,
        hasteMelee = CR_HASTE_MELEE or 18,
        hasteRanged = CR_HASTE_RANGED or 19,
        hasteSpell = CR_HASTE_SPELL or 20,
        expertise = CR_EXPERTISE or 21,
        armorPen = CR_ARMOR_PENETRATION or 24,
    }
    stats.ratings = {}
    stats.ratingBonuses = {}
    for key, id in pairs(ratingIds) do
        stats.ratings[key] = SafeCombatRating(id)
        stats.ratingBonuses[key] = SafeCall(GetCombatRatingBonus, id)
    end

    stats.meleeCritPct = SafeCall(GetCritChance)
    stats.rangedCritPct = SafeCall(GetRangedCritChance)
    stats.spellCritPct = SafeCall(GetSpellCritChance, 2)
    stats.hitModifier = SafeCall(GetHitModifier)

    local minMain, maxMain, minOff, maxOff,
          damagePositive, damageNegative, damagePercent =
        SafeCall(UnitDamage, "player")
    stats.weaponDamage = {
        minMain = minMain,
        maxMain = maxMain,
        minOff = minOff,
        maxOff = maxOff,
        positive = damagePositive,
        negative = damageNegative,
        percent = damagePercent,
    }

    local mainSpeed, offSpeed = SafeCall(UnitAttackSpeed, "player")
    stats.attackSpeed = { main = mainSpeed, off = offSpeed }
    local mainExpertise, offExpertise = SafeCall(GetExpertise)
    stats.expertise = { main = mainExpertise, off = offExpertise }
    local mainExpertisePct, offExpertisePct = SafeCall(GetExpertisePercent)
    stats.expertisePercent = {
        main = mainExpertisePct,
        off = offExpertisePct,
    }
    return stats
end

local function StatsSignature(stats)
    return table.concat({
        stats.strength or 0,
        stats.agility or 0,
        stats.attackPower or 0,
        stats.meleeCritPct or 0,
        stats.ratings.hasteMelee or 0,
        stats.ratings.hitMelee or 0,
        stats.ratings.expertise or 0,
        stats.ratings.armorPen or 0,
        stats.attackSpeed.main or 0,
    }, "|")
end

local function CompactStats(stats)
    return {
        strength = stats.strength,
        agility = stats.agility,
        attackPower = stats.attackPower,
        meleeCritPct = stats.meleeCritPct,
        meleeHasteRating = stats.ratings.hasteMelee,
        attackSpeed = stats.attackSpeed.main,
    }
end

local function GetEquippedItems()
    local items = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            items[#items + 1] = {
                slot = slot,
                link = link,
                itemId = tonumber(link:match("item:(%d+)")),
            }
        end
    end
    return items
end

local function GetStateSnapshot()
    local result = { powers = {}, powerMaximums = {}, auras = {} }
    for powerType = 0, 20 do
        local value = SafeCall(UnitPower, "player", powerType)
        local maximum = SafeCall(UnitPowerMax, "player", powerType)
        if (value and value > 0) or (maximum and maximum > 0) then
            local key = POWER_NAMES[powerType] or ("POWER_" .. powerType)
            result.powers[key] = value or 0
            result.powerMaximums[key] = maximum or 0
        end
    end

    local activeType, activeToken = SafeCall(UnitPowerType, "player")
    local activeValue = SafeCall(UnitPower, "player")
    if activeValue ~= nil then
        local key = "ACTIVE_" .. tostring(activeToken or activeType or "UNKNOWN")
        result.powers[key] = activeValue
    end
    local legacyValue = SafeCall(UnitMana, "player")
    if legacyValue ~= nil then result.powers.LEGACY_ACTIVE = legacyValue end

    for index = 1, 80 do
        local name, rank, icon, count, debuffType, duration,
              expirationTime, caster, isStealable, shouldConsolidate,
              spellId = UnitAura("player", index)
        if not name then break end
        result.auras[name] = {
            count = (count and count > 0) and count or 1,
            rank = rank,
            icon = icon,
            debuffType = debuffType,
            duration = duration,
            expirationTime = expirationTime,
            caster = caster,
            spellId = spellId,
            isStealable = isStealable and true or nil,
            shouldConsolidate = shouldConsolidate and true or nil,
        }
    end
    return result
end

local function CompactState(state)
    local compact = { powers = {}, auras = {}, auraIds = {} }
    for key, value in pairs(state.powers or {}) do
        compact.powers[key] = value
    end
    for name, aura in pairs(state.auras or {}) do
        compact.auras[name] = aura.count
        if aura.spellId then compact.auraIds[name] = aura.spellId end
    end
    return compact
end

local function AddEvent(entry)
    if not logging or not currentSession then return nil end
    local maximum = DPSLoggerSettings.maxEvents or DEFAULT_MAX_EVENTS
    if #currentSession.events >= maximum then
        currentSession.droppedEvents =
            (currentSession.droppedEvents or 0) + 1
        if not eventLimitWarned then
            eventLimitWarned = true
            print("|cffffaa00[DPSLogger]|r Limite d'evenements atteinte; " ..
                  "la session continue mais les nouveaux evenements sont comptes comme perdus.")
        end
        return nil
    end

    local now = entry.t or Now()
    entry.t = now
    entry.dt = RelativeTime(now)
    entry.seq = #currentSession.events + 1
    currentSession.events[#currentSession.events + 1] = entry
    return entry
end

local function RecentCauseCandidates(now)
    local candidates = {}
    for index = #recentCauses, 1, -1 do
        local cause = recentCauses[index]
        if now - cause.t > CAUSE_WINDOW then break end
        candidates[#candidates + 1] = {
            eventSeq = cause.eventSeq,
            dt = cause.dt,
            sub = cause.sub,
            kind = cause.kind,
            spell = cause.spell,
            spellId = cause.spellId,
            school = cause.school,
            target = cause.target,
            perspective = cause.perspective,
            amount = cause.amount,
            critical = cause.critical,
            likelyMelee = cause.likelyMelee,
        }
    end
    return candidates
end

local function RememberCause(entry)
    recentCauses[#recentCauses + 1] = {
        t = entry.t,
        dt = entry.dt,
        eventSeq = entry.seq,
        sub = entry.sub,
        spell = entry.spell,
        spellId = entry.spellId,
        school = entry.school,
        target = entry.target,
        kind = entry.kind,
        perspective = entry.perspective,
        amount = entry.amount,
        critical = entry.critical and true or nil,
        likelyMelee =
            entry.sub == "SWING_DAMAGE" or
            (
                entry.school == 1 and
                entry.sub ~= "SPELL_PERIODIC_DAMAGE"
            ),
    }
    while #recentCauses > 60 do table.remove(recentCauses, 1) end
end

local function RecordStateChanges(now, force)
    local state = GetStateSnapshot()
    if not lastState then
        lastState = state
        return
    end

    local function CompareMap(kind, oldMap, newMap, extractor)
        local seen = {}
        for key, oldValue in pairs(oldMap or {}) do
            seen[key] = true
            local before = extractor(oldValue)
            local after = extractor(newMap and newMap[key])
            if force or before ~= after then
                AddEvent({
                    t = now,
                    sub = kind .. "_CHANGED",
                    name = key,
                    before = before,
                    after = after,
                    delta =
                        type(before) == "number" and
                        type(after) == "number" and
                        (after - before) or nil,
                    causeCandidates = RecentCauseCandidates(now),
                })
            end
        end
        for key, newValue in pairs(newMap or {}) do
            if not seen[key] then
                local after = extractor(newValue)
                AddEvent({
                    t = now,
                    sub = kind .. "_CHANGED",
                    name = key,
                    before = 0,
                    after = after,
                    delta = type(after) == "number" and after or nil,
                    causeCandidates = RecentCauseCandidates(now),
                })
            end
        end
    end

    CompareMap("POWER", lastState.powers, state.powers, function(value)
        return value or 0
    end)
    CompareMap("AURA", lastState.auras, state.auras, function(value)
        return value and value.count or 0
    end)
    lastState = state
end

local function GetCooldownSnapshot(tracked, now)
    local key = tracked.id or tracked.name
    local start, duration, enabled = SafeCall(GetSpellCooldown, key)
    if start == nil and tracked.name then
        start, duration, enabled = SafeCall(GetSpellCooldown, tracked.name)
    end
    start = start or 0
    duration = duration or 0
    local remaining = 0
    if start > 0 and duration > 0 then
        remaining = math.max(0, start + duration - now)
    end
    return {
        start = start,
        duration = duration,
        enabled = enabled,
        remaining = remaining,
    }
end

local function TrackCooldown(name, spellId)
    if not name and not spellId then return end
    for _, existing in pairs(trackedCooldowns) do
        if (spellId and existing.id == spellId) or
           (name and existing.name == name) then
            existing.name = existing.name or name
            existing.id = existing.id or spellId
            return
        end
    end
    local key = tostring(spellId or name)
    local tracked = trackedCooldowns[key]
    if not tracked then
        tracked = { name = name, id = spellId, state = nil, lastPollAt = Now() }
        trackedCooldowns[key] = tracked
    else
        tracked.name = tracked.name or name
        tracked.id = tracked.id or spellId
    end
end

local function PollCooldowns(now)
    for _, tracked in pairs(trackedCooldowns) do
        local current = GetCooldownSnapshot(tracked, now)
        local previous = tracked.state
        if previous then
            local elapsed = now - (tracked.lastPollAt or now)
            local expected = math.max(0, previous.remaining - elapsed)
            local reduction = expected - current.remaining

            if current.remaining > expected + COOLDOWN_EPSILON then
                AddEvent({
                    t = now,
                    sub = "COOLDOWN_STARTED",
                    spell = tracked.name,
                    spellId = tracked.id,
                    duration = current.duration,
                    remaining = current.remaining,
                })
            elseif reduction > COOLDOWN_EPSILON then
                AddEvent({
                    t = now,
                    sub = "COOLDOWN_REDUCED",
                    spell = tracked.name,
                    spellId = tracked.id,
                    amount = reduction,
                    expectedRemaining = expected,
                    remaining = current.remaining,
                    causeCandidates = RecentCauseCandidates(now),
                })
            elseif previous.remaining > 0 and current.remaining == 0 and
                   expected <= COOLDOWN_EPSILON then
                AddEvent({
                    t = now,
                    sub = "COOLDOWN_READY",
                    spell = tracked.name,
                    spellId = tracked.id,
                })
            end
        end
        tracked.state = current
        tracked.lastPollAt = now
    end
end

local function RecordStatsIfChanged(now)
    local stats = GetStatsSnapshot()
    local signature = StatsSignature(stats)
    if signature ~= lastStatsSignature then
        AddEvent({
            t = now,
            sub = "STATS_CHANGED",
            stats = stats,
        })
        lastStatsSignature = signature
    end
end

local function FlushPending(now)
    for index = #pendingAfter, 1, -1 do
        local pending = pendingAfter[index]
        if now >= pending.captureAt then
            pending.entry.after = CompactState(GetStateSnapshot())
            table.remove(pendingAfter, index)
        end
    end
end

local function BuildSummary(session)
    local summary = {
        damageDone = 0,
        damageTaken = 0,
        healingDone = 0,
        criticals = 0,
        misses = 0,
        damageBySpell = {},
        castsBySpell = {},
    }
    for _, entry in ipairs(session.events) do
        if entry.amount and entry.kind == "damage" then
            if entry.perspective == "outgoing" then
                summary.damageDone = summary.damageDone + entry.amount
                local key = entry.spell or entry.environmentalType or "Unknown"
                summary.damageBySpell[key] =
                    (summary.damageBySpell[key] or 0) + entry.amount
            elseif entry.perspective == "incoming" then
                summary.damageTaken = summary.damageTaken + entry.amount
            end
        elseif entry.amount and entry.kind == "heal" and
               entry.perspective == "outgoing" then
            summary.healingDone = summary.healingDone + entry.amount
        end
        if entry.critical then summary.criticals = summary.criticals + 1 end
        if entry.missType then summary.misses = summary.misses + 1 end
        if entry.sub == "CAST" then
            summary.castsBySpell[entry.spell] =
                (summary.castsBySpell[entry.spell] or 0) + 1
        end
    end
    return summary
end

local function IsOwnedGuid(guid)
    if not guid then return false end
    return guid == UnitGUID("player") or guid == UnitGUID("pet")
end

local function ParseCombatLog(...)
    local timestamp, subevent,
          sourceGUID, sourceName, sourceFlags,
          destGUID, destName, destFlags,
          a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 = ...

    local sourceOwned = IsOwnedGuid(sourceGUID)
    local destOwned = IsOwnedGuid(destGUID)
    if not sourceOwned and not destOwned then return end

    local now = Now()
    local entry = {
        t = now,
        combatLogTimestamp = timestamp,
        sub = subevent,
        source = sourceName,
        sourceGuid = sourceGUID,
        sourceFlags = sourceFlags,
        target = destName,
        targetGuid = destGUID,
        targetFlags = destFlags,
        perspective =
            sourceOwned and (destOwned and "self" or "outgoing") or "incoming",
    }

    if subevent == "SWING_DAMAGE" then
        entry.kind = "damage"
        entry.spell = "Melee"
        entry.amount = a1
        entry.overkill = a2
        entry.school = a3
        entry.resisted = a4
        entry.blocked = a5
        entry.absorbed = a6
        entry.critical = a7 and true or nil
        entry.glancing = a8 and true or nil
        entry.crushing = a9 and true or nil
    elseif subevent == "ENVIRONMENTAL_DAMAGE" then
        entry.kind = "damage"
        entry.environmentalType = a1
        entry.amount = a2
        entry.overkill = a3
        entry.school = a4
        entry.resisted = a5
        entry.blocked = a6
        entry.absorbed = a7
        entry.critical = a8 and true or nil
    elseif subevent:find("_DAMAGE") then
        entry.kind = "damage"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.amount = a4
        entry.overkill = a5
        entry.school = a6
        entry.resisted = a7
        entry.blocked = a8
        entry.absorbed = a9
        entry.critical = a10 and true or nil
        entry.glancing = a11 and true or nil
        entry.crushing = a12 and true or nil
    elseif subevent == "SWING_MISSED" then
        entry.kind = "miss"
        entry.spell = "Melee"
        entry.missType = a1
        entry.amountMissed = a2
    elseif subevent:find("_MISSED") then
        entry.kind = "miss"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.missType = a4
        entry.amountMissed = a5
    elseif subevent:find("_HEAL") then
        entry.kind = "heal"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.amount = a4
        entry.overhealing = a5
        entry.absorbed = a6
        entry.critical = a7 and true or nil
    elseif subevent == "SPELL_CAST_START" or
           subevent == "SPELL_CAST_SUCCESS" or
           subevent == "SPELL_CAST_FAILED" then
        entry.kind = "cast"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.failedReason = subevent == "SPELL_CAST_FAILED" and a4 or nil
    elseif subevent:find("AURA_") then
        entry.kind = "aura"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.auraType = a4
        entry.auraAmount = a5
        if destOwned then stateDirty = true end
    elseif subevent:find("_ENERGIZE") then
        entry.kind = "resource"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.amount = a4
        entry.powerType = a5
        if destOwned then stateDirty = true end
    elseif subevent:find("_DRAIN") or subevent:find("_LEECH") then
        entry.kind = "resource"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.amount = a4
        entry.powerType = a5
        entry.extraAmount = a6
        if destOwned then stateDirty = true end
    elseif subevent == "SPELL_INTERRUPT" or subevent == "SPELL_DISPEL" or
           subevent == "SPELL_STOLEN" then
        entry.kind = "utility"
        entry.spellId = a1
        entry.spell = a2
        entry.spellSchool = a3
        entry.extraSpellId = a4
        entry.extraSpell = a5
        entry.extraSchool = a6
        entry.auraType = a7
    elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
        entry.kind = "death"
    else
        return
    end

    if entry.kind == "damage" and sourceOwned then
        entry.attackPowerAtHit = currentAttackPower
        entry.rangedAttackPowerAtHit = currentRangedAttackPower
    end

    local saved = AddEvent(entry)
    if not saved then return end

    if entry.kind == "damage" or entry.kind == "resource" or
       entry.kind == "cast" then
        RememberCause(entry)
    end
    if sourceOwned and entry.kind == "cast" and entry.spell then
        TrackCooldown(entry.spell, entry.spellId)
    end
end

local function StartLogging(label)
    if logging then
        print("|cff00ff88[DPSLogger]|r Une session est deja active.")
        return
    end

    DPSLoggerSettings.maxEvents =
        tonumber(DPSLoggerSettings.maxEvents) or DEFAULT_MAX_EVENTS
    logging = true
    sessionStartTime = Now()
    pendingAfter = {}
    preCast = {}
    trackedCooldowns = {}
    recentCauses = {}
    eventLimitWarned = false
    stateDirty = false
    statsDirty = false
    nextPollAt = sessionStartTime
    lastState = GetStateSnapshot()
    local initialStats = GetStatsSnapshot()
    lastStatsSignature = StatsSignature(initialStats)
    RefreshAttackPower()

    currentSession = {
        schemaVersion = SCHEMA_VERSION,
        addonVersion = ADDON_VERSION,
        label = Trim(label) ~= "" and Trim(label) or nil,
        startedAt = date("%Y-%m-%d %H:%M:%S"),
        startedAtEpoch = time(),
        character = GetCharacterSnapshot(),
        environment = GetEnvironmentSnapshot(),
        targetAtStart = GetTargetSnapshot(),
        stats = initialStats,
        talents = GetTalentsSnapshot(),
        items = GetEquippedItems(),
        initialState = CompactState(lastState),
        events = {},
        droppedEvents = 0,
    }

    TrackCooldown("Burning Blade", 524920)
    AddEvent({
        sub = "SESSION_START",
        target = currentSession.targetAtStart,
    })
    print("|cff00ff88[DPSLogger]|r Session demarree. Combat puis /dpslog stop.")
end

local function StopLogging()
    if not logging or not currentSession then
        print("|cff00ff88[DPSLogger]|r Aucune session active.")
        return
    end

    local now = Now()
    FlushPending(now + POST_CAST_DELAY)
    RecordStateChanges(now, false)
    PollCooldowns(now)
    currentSession.finalState = CompactState(GetStateSnapshot())
    currentSession.finalStats = GetStatsSnapshot()
    currentSession.targetAtStop = GetTargetSnapshot()
    currentSession.stoppedAt = date("%Y-%m-%d %H:%M:%S")
    currentSession.stoppedAtEpoch = time()
    currentSession.duration = RelativeTime(now)
    currentSession.summary = BuildSummary(currentSession)

    logging = false
    DPSLoggerDB[#DPSLoggerDB + 1] = currentSession
    print("|cff00ff88[DPSLogger]|r Session #" .. #DPSLoggerDB ..
          " sauvegardee : " .. #currentSession.events .. " evenements, " ..
          (currentSession.droppedEvents or 0) .. " perdus.")
    print("|cff00ff88[DPSLogger]|r Fais /reload ou deconnecte-toi pour ecrire le fichier.")
    currentSession = nil
    sessionStartTime = nil
end

local function CancelLogging()
    if not logging or not currentSession then
        print("|cff00ff88[DPSLogger]|r Aucune session active.")
        return
    end

    local eventCount = #currentSession.events
    logging = false
    currentSession = nil
    sessionStartTime = nil
    pendingAfter = {}
    preCast = {}
    print("|cff00ff88[DPSLogger]|r Session annulee (" .. eventCount ..
          " evenements jetes), rien de sauvegarde.")
end

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("UNIT_SPELLCAST_SENT")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("UNIT_MANA")
frame:RegisterEvent("UNIT_RAGE")
frame:RegisterEvent("UNIT_ENERGY")
frame:RegisterEvent("UNIT_DISPLAYPOWER")
frame:RegisterEvent("UNIT_STATS")
frame:RegisterEvent("UNIT_ATTACK_POWER")
frame:RegisterEvent("COMBAT_RATING_UPDATE")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnUpdate", function()
    if not logging or not currentSession then return end
    local now = Now()
    if now < nextPollAt then return end
    nextPollAt = now + POLL_INTERVAL

    FlushPending(now)
    PollCooldowns(now)
    if stateDirty then
        RecordStateChanges(now, false)
        stateDirty = false
    end
    if statsDirty then
        RecordStatsIfChanged(now)
        statsDirty = false
    end
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if not logging or not currentSession then return end

    if event == "UNIT_SPELLCAST_SENT" then
        local unit, spellName = ...
        if unit == "player" and spellName then
            preCast[spellName] = {
                state = CompactState(GetStateSnapshot()),
                stats = CompactStats(GetStatsSnapshot()),
                target = GetTargetSnapshot(),
                t = Now(),
            }
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, spellName = ...
        if unit == "player" and spellName then
            local pre = preCast[spellName]
            preCast[spellName] = nil
            local entry = AddEvent({
                sub = "CAST",
                kind = "cast",
                perspective = "outgoing",
                spell = spellName,
                before = pre and pre.state or CompactState(GetStateSnapshot()),
                statsBefore = pre and pre.stats or nil,
                targetBefore = pre and pre.target or nil,
                sentAt = pre and pre.t or nil,
            })
            if entry then
                RememberCause(entry)
                pendingAfter[#pendingAfter + 1] = {
                    entry = entry,
                    captureAt = Now() + POST_CAST_DELAY,
                }
            end
            TrackCooldown(spellName, nil)
        end
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ParseCombatLog(...)
        return
    end

    local unit = ...
    if event == "UNIT_AURA" and unit == "player" then
        stateDirty = true
    elseif (event == "UNIT_MANA" or event == "UNIT_RAGE" or
            event == "UNIT_ENERGY" or event == "UNIT_DISPLAYPOWER") and
           unit == "player" then
        stateDirty = true
    elseif event == "UNIT_STATS" or event == "UNIT_ATTACK_POWER" or
           event == "COMBAT_RATING_UPDATE" then
        if unit == nil or unit == "player" then
            statsDirty = true
            if event == "UNIT_ATTACK_POWER" then RefreshAttackPower() end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        AddEvent({ sub = "TARGET_CHANGED", target = GetTargetSnapshot() })
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        AddEvent({ sub = "ENVIRONMENT_CHANGED", environment = GetEnvironmentSnapshot() })
    elseif event == "PLAYER_REGEN_DISABLED" then
        AddEvent({ sub = "COMBAT_STARTED", target = GetTargetSnapshot() })
    elseif event == "PLAYER_REGEN_ENABLED" then
        AddEvent({ sub = "COMBAT_ENDED", target = GetTargetSnapshot() })
    end
end)

local function PrintLastSummary()
    local session = currentSession or DPSLoggerDB[#DPSLoggerDB]
    if not session then
        print("|cff00ff88[DPSLogger]|r Aucune session.")
        return
    end
    local summary = session.summary or BuildSummary(session)
    print(string.format(
        "|cff00ff88[DPSLogger]|r %.1fs, %d evenements, %d degats, %d recus, %d critiques, %d rates.",
        session.duration or RelativeTime(Now()),
        #session.events,
        summary.damageDone,
        summary.damageTaken,
        summary.criticals,
        summary.misses
    ))
end

local function PrintCooldown()
    local tracked = trackedCooldowns[tostring(524920)] or {
        name = "Burning Blade", id = 524920,
    }
    local state = GetCooldownSnapshot(tracked, Now())
    print(string.format(
        "|cff00ff88[DPSLogger]|r Burning Blade : %.2fs restantes (duree %.2fs).",
        state.remaining, state.duration
    ))
end

local function ClassifyCause(candidates)
    if not candidates then return "unknown" end
    for _, cause in ipairs(candidates) do
        if cause.critical and cause.likelyMelee then
            if cause.sub == "SWING_DAMAGE" then return "auto" end
            return "ability"
        end
    end
    return "unknown"
end

local function PrintMechanicsCheck()
    local session = currentSession or DPSLoggerDB[#DPSLoggerDB]
    if not session then
        print("|cff00ff88[DPSLogger]|r Aucune session a analyser.")
        return
    end

    local chargeDrops = { total = 0, auto = 0, ability = 0, unknown = 0 }
    local reductions = {
        events = 0, seconds = 0, auto = 0, ability = 0, unknown = 0,
    }
    for _, entry in ipairs(session.events) do
        if entry.sub == "AURA_CHANGED" and
           entry.name == "Burning Blade" and
           entry.delta and entry.delta < 0 then
            local kind = ClassifyCause(entry.causeCandidates)
            chargeDrops.total = chargeDrops.total - entry.delta
            chargeDrops[kind] = chargeDrops[kind] + 1
        elseif entry.sub == "COOLDOWN_REDUCED" and
               (entry.spell == "Burning Blade" or entry.spellId == 524920) then
            local kind = ClassifyCause(entry.causeCandidates)
            reductions.events = reductions.events + 1
            reductions.seconds = reductions.seconds + (entry.amount or 0)
            reductions[kind] = reductions[kind] + 1
        end
    end

    print(string.format(
        "|cff00ff88[DPSLogger]|r Burning Blade - charges perdues: %d " ..
        "(auto:%d, competences:%d, indetermine:%d).",
        chargeDrops.total, chargeDrops.auto,
        chargeDrops.ability, chargeDrops.unknown
    ))
    print(string.format(
        "|cff00ff88[DPSLogger]|r Burning Blade - reductions cooldown: %d " ..
        "evenement(s), %.2fs (auto:%d, competences:%d, indetermine:%d).",
        reductions.events, reductions.seconds, reductions.auto,
        reductions.ability, reductions.unknown
    ))
    if (session.schemaVersion or 1) < 2 then
        print("|cffffaa00[DPSLogger]|r Cette ancienne session ne contient pas " ..
              "la telemetrie cooldown/aura de la version 2.")
    end
end

-- Accesseur en lecture seule pour le HUD (DPSLoggerHUD.lua) : ne modifie rien
-- au moteur de capture, permet juste d'afficher un statut a jour.
function DPSLogger_IsActive()
    return logging
end

SLASH_DPSLOG1 = "/dpslog"
SlashCmdList["DPSLOG"] = function(message)
    local raw = Trim(message)
    local command, argument = raw:match("^(%S+)%s*(.-)$")
    command = command and command:lower() or ""

    if command == "start" then
        StartLogging(argument)
    elseif command == "stop" then
        StopLogging()
    elseif command == "cancel" then
        CancelLogging()
    elseif command == "status" then
        if logging and currentSession then
            print(string.format(
                "|cff00ff88[DPSLogger]|r ACTIF : %.1fs, %d evenements, %d perdus.",
                RelativeTime(Now()),
                #currentSession.events,
                currentSession.droppedEvents or 0
            ))
        else
            print("|cff00ff88[DPSLogger]|r Inactif.")
        end
    elseif command == "mark" then
        if logging and currentSession then
            AddEvent({ sub = "MARKER", label = argument })
            print("|cff00ff88[DPSLogger]|r Marqueur ajoute : " .. argument)
        else
            print("|cff00ff88[DPSLogger]|r Demarre une session avant d'ajouter un marqueur.")
        end
    elseif command == "cooldown" then
        PrintCooldown()
    elseif command == "check" then
        PrintMechanicsCheck()
    elseif command == "watch" then
        if logging and argument ~= "" then
            TrackCooldown(argument, nil)
            print("|cff00ff88[DPSLogger]|r Cooldown surveille : " .. argument)
        else
            print("|cff00ff88[DPSLogger]|r Pendant une session : /dpslog watch Nom du sort")
        end
    elseif command == "last" then
        PrintLastSummary()
    elseif command == "count" then
        print("|cff00ff88[DPSLogger]|r " .. #DPSLoggerDB .. " session(s) sauvegardee(s).")
    elseif command == "maxevents" then
        local value = tonumber(argument)
        if value and value >= 1000 and value <= 500000 then
            DPSLoggerSettings.maxEvents = math.floor(value)
            print("|cff00ff88[DPSLogger]|r Limite fixee a " ..
                  DPSLoggerSettings.maxEvents .. " evenements.")
        else
            print("|cff00ff88[DPSLogger]|r Utilise /dpslog maxevents 60000.")
        end
    elseif command == "clear" and argument:lower() == "confirm" then
        DPSLoggerDB = {}
        print("|cff00ff88[DPSLogger]|r Toutes les sessions ont ete effacees.")
    elseif command == "clear" then
        print("|cffffaa00[DPSLogger]|r Confirmation requise : /dpslog clear confirm")
    else
        print("|cff00ff88[DPSLogger]|r Commandes :")
        print("  /dpslog start [nom]  - demarrer une session")
        print("  /dpslog stop         - terminer et sauvegarder")
        print("  /dpslog cancel       - annuler sans sauvegarder")
        print("  /dpslog status       - etat de la capture")
        print("  /dpslog mark texte   - ajouter un repere temporel")
        print("  /dpslog cooldown     - cooldown actuel de Burning Blade")
        print("  /dpslog check        - bilan charges/cooldown de Burning Blade")
        print("  /dpslog watch sort   - surveiller un autre cooldown")
        print("  /dpslog last         - resume de la derniere session")
        print("  /dpslog count        - nombre de sessions")
        print("  /dpslog maxevents N  - limite de securite")
        print("  /dpslog clear confirm - effacer les sessions")
    end
end
