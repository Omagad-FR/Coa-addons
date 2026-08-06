-- CoABuffManager Comm 0.7.0
-- Client WoW 3.3.5a / Interface 30300
--
-- Inter-addon communication over the standard AddOn message channel
-- (SendAddonMessage / CHAT_MSG_ADDON). Lets every CoABuffManager client in
-- the same party/raid announce its own class spec and the group-buff
-- spellIDs it actually knows, so remote members can be filtered/confirmed
-- the same way the local player already is in GetAutomaticCatalogEntry.
--
-- Design constraints:
--   * Only broadcasts small, already-locally-known facts (spec + a filtered
--     spellID list). Never asks a remote client to reveal anything it
--     could not already deduce about itself from its own spellbook.
--   * Throttled: re-announces on roster change or on a fixed interval, not
--     on every event, to avoid flooding the addon channel.
--   * Received data is purely additive and cosmetic to the UI: if it is
--     missing (addon not installed on a remote client, or message not yet
--     received), the addon falls back to the existing "potential" behavior
--     already implemented in GetAutomaticCatalogEntry.

local ADDON_NAME = "CoABuffManager"
local COMM_PREFIX = "CBM1"
-- Bumped to 2: the wire format now carries a 6th field with the sender's
-- current macroLocks (family -> GROUP or INDIVIDUAL+targets), so remote
-- clients can be warned about same-class lock conflicts (see
-- GetSameClassLockConflicts in CoABuffManager.lua). Same-class-only, and
-- read-only/cosmetic like every other field here: no remote client ever
-- has its own locks changed by another player's broadcast.
local COMM_VERSION = 2
local ANNOUNCE_INTERVAL = 45
local ANNOUNCE_MIN_GAP = 3

CoABuffComm = CoABuffComm or {}

-- Table of remote player data received this session, keyed by short unit
-- name (as returned by UnitName, matching the convention already used by
-- GetRoster in CoABuffManager.lua). Not persisted to SavedVariables: it is
-- session-only, rebuilt every time the addon reconnects/announces.
-- Shape: CoABuffComm.remote[name] = {
--     specID = number|nil,
--     specToken = string|nil,      -- normalized spec name, e.g. "RIFTBLADE"
--     knownSpellIDs = { [spellID] = true, ... },
--     locks = { [family] = { mode = "GROUP" } or { mode = "INDIVIDUAL", targets = { [name] = true, ... } }, ... },
--     receivedAt = number (GetTime()),
--     addonVersion = string|nil,
-- }
CoABuffComm.remote = CoABuffComm.remote or {}

local lastAnnounceTime = 0
local pendingAnnounce = false
local commFrame

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCoABuffManager|r - " .. tostring(message))
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------
-- Keep the wire format simple and dependency-free (no external libs in a
-- 3.3.5 environment): a versioned, pipe-delimited string.
--   "1|<specID>|<specToken>|<addonVersion>|<spellID1>,<spellID2>,..."
-- Fields are never free text from chat, so no escaping is needed beyond
-- avoiding "|" and "," in the fields we control ourselves.

-- Encodes the sender's current macroLocks as a compact 6th wire field:
--   "<family>:G;<family>:I:<name1>,<name2>;..."
-- "G" = GROUP lock (no target list needed, a Greater cast covers whoever
-- is in range). "I" = INDIVIDUAL lock, followed by its locked target
-- names. This mirrors BuildMacroThenAll's own reading of macroLocks, so
-- the wire format always reflects exactly what the local player would
-- see in the overview panel.
local function EncodeLockSummary(macroLocks)
    local familyNames = {}
    for family in pairs(macroLocks or {}) do
        table.insert(familyNames, family)
    end
    table.sort(familyNames)

    local entries = {}
    for _, family in ipairs(familyNames) do
        local lock = macroLocks[family]
        if lock and lock.mode == "GROUP" then
            table.insert(entries, family .. ":G")
        elseif lock and lock.mode == "INDIVIDUAL" and lock.targets then
            local targetNames = {}
            for targetName in pairs(lock.targets) do
                table.insert(targetNames, targetName)
            end
            table.sort(targetNames)
            if #targetNames > 0 then
                table.insert(entries, family .. ":I:" .. table.concat(targetNames, ","))
            end
        end
    end

    return table.concat(entries, ";")
end

-- Reverses EncodeLockSummary. Malformed or unrecognized entries are
-- silently skipped rather than erroring, since this only ever feeds a
-- cosmetic conflict warning -- never anything that changes local state.
local function DecodeLockSummary(text)
    local locks = {}
    if not text or text == "" then
        return locks
    end

    for entry in string.gmatch(text, "[^;]+") do
        local family, mode, rest = string.match(entry, "^([^:]+):([^:]*):?(.*)$")
        if family and mode == "G" then
            locks[family] = { mode = "GROUP" }
        elseif family and mode == "I" and rest and rest ~= "" then
            local targets = {}
            for targetName in string.gmatch(rest, "[^,]+") do
                targets[targetName] = true
            end
            if next(targets) then
                locks[family] = { mode = "INDIVIDUAL", targets = targets }
            end
        end
    end

    return locks
end

local function EncodeAnnounce(specID, specToken, knownSpellIDs, addonVersion, macroLocks)
    local ids = {}
    for spellID in pairs(knownSpellIDs or {}) do
        table.insert(ids, tostring(spellID))
    end
    table.sort(ids)

    return table.concat({
        tostring(COMM_VERSION),
        tostring(specID or ""),
        tostring(specToken or ""),
        tostring(addonVersion or ""),
        table.concat(ids, ","),
        EncodeLockSummary(macroLocks),
    }, "|")
end

local function DecodeAnnounce(message)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    -- Split on "|" without relying on Lua 5.1 patterns misbehaving on empty
    -- fields: gmatch with "([^|]*)" correctly yields empty strings between
    -- consecutive separators.
    local parts = {}
    for part in string.gmatch(message .. "|", "([^|]*)|") do
        table.insert(parts, part)
    end

    local version = tonumber(parts[1])
    if not version or version ~= COMM_VERSION then
        return nil
    end

    local specID = tonumber(parts[2])
    local specToken = parts[3]
    if specToken == "" then
        specToken = nil
    end
    local addonVersion = parts[4]
    if addonVersion == "" then
        addonVersion = nil
    end

    local knownSpellIDs = {}
    if parts[5] and parts[5] ~= "" then
        for idText in string.gmatch(parts[5], "[^,]+") do
            local id = tonumber(idText)
            if id then
                knownSpellIDs[id] = true
            end
        end
    end

    local locks = DecodeLockSummary(parts[6])

    return {
        specID = specID,
        specToken = specToken,
        addonVersion = addonVersion,
        knownSpellIDs = knownSpellIDs,
        locks = locks,
    }
end

-- ---------------------------------------------------------------------------
-- Public accessors (used by CoABuffManager.lua)
-- ---------------------------------------------------------------------------

-- Returns the cached remote data for a unit name, or nil if nothing has
-- been received yet (addon not installed remotely, or not announced yet).
function CoABuffComm.GetRemoteData(name)
    if not name then
        return nil
    end
    return CoABuffComm.remote[name]
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

local function GetChannelForBroadcast()
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then
        return "RAID"
    end

    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    if partyCount > 0 then
        return "PARTY"
    end

    return nil
end

local function SendAddonMessageCompat(prefix, message, channel)
    if C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" then
        return pcall(C_ChatInfo.SendAddonMessage, prefix, message, channel)
    elseif type(SendAddonMessage) == "function" then
        return pcall(SendAddonMessage, prefix, message, channel)
    end
    return false
end

-- Builds and sends this client's announce message. Relies on two callback
-- hooks assigned from CoABuffManager.lua (CoABuffComm.GetLocalSpecInfo and
-- CoABuffComm.GetLocalKnownGroupSpellIDs) to avoid duplicating spellbook
-- logic that already exists there.
function CoABuffComm.Announce(force)
    if InCombatLockdown and InCombatLockdown() then
        -- Sending addon messages is allowed in combat, but skip non-urgent
        -- announces to avoid any unnecessary work during a fight.
        if not force then
            return
        end
    end

    local channel = GetChannelForBroadcast()
    if not channel then
        return
    end

    local now = GetTime and GetTime() or 0
    if not force and (now - lastAnnounceTime) < ANNOUNCE_MIN_GAP then
        return
    end

    if type(CoABuffComm.GetLocalSpecInfo) ~= "function" then
        return
    end

    local specID, specToken = CoABuffComm.GetLocalSpecInfo()
    local knownSpellIDs = {}
    if type(CoABuffComm.GetLocalKnownGroupSpellIDs) == "function" then
        knownSpellIDs = CoABuffComm.GetLocalKnownGroupSpellIDs() or {}
    end

    local macroLocks = {}
    if type(CoABuffComm.GetLocalLockSummary) == "function" then
        macroLocks = CoABuffComm.GetLocalLockSummary() or {}
    end

    local addonVersion = CoABuffComm.addonVersion or ""
    local message = EncodeAnnounce(specID, specToken, knownSpellIDs, addonVersion, macroLocks)

    local ok = SendAddonMessageCompat(COMM_PREFIX, message, channel)
    if ok then
        lastAnnounceTime = now
        pendingAnnounce = false
    end
end

-- Call this whenever the roster changes or the local spec might have
-- changed. Actual sending is throttled internally.
function CoABuffComm.RequestAnnounce()
    pendingAnnounce = true
end

-- Distinct from RequestAnnounce above: that one only (re-)broadcasts OUR
-- OWN data on the usual throttle. This sends a small sentinel message
-- asking every OTHER CoABuffManager client in the group to announce
-- immediately, bypassing their own throttle -- e.g. after someone reloads
-- and their spec still shows as unknown to everyone else. Older clients
-- without this handler simply fail DecodeAnnounce on the sentinel and
-- ignore it silently, so this is safe to send into a mixed-version group.
local REQUEST_SENTINEL = "REQ"

function CoABuffComm.RequestFromOthers()
    local channel = GetChannelForBroadcast()
    if not channel then
        return false
    end
    -- Also push our own data back out at the same time, since the other
    -- side asking is a two-way signal that fresh info would help both of
    -- us, not just them.
    CoABuffComm.Announce(true)
    return SendAddonMessageCompat(COMM_PREFIX, REQUEST_SENTINEL, channel)
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local function HandleIncomingMessage(prefix, message, channel, sender)
    if prefix ~= COMM_PREFIX then
        return
    end

    -- Sender may come as "Name-Realm" on some clients/servers; normalize to
    -- the short name to match GetRoster()'s UnitName-based keys.
    local shortName = sender
    if shortName then
        shortName = string.match(shortName, "^([^-]+)") or shortName
    end

    if not shortName or shortName == (UnitName and UnitName("player")) then
        -- Ignore our own broadcast reflected back, if that ever happens.
        return
    end

    if message == REQUEST_SENTINEL then
        -- Someone asked everyone to announce right now -- reply
        -- immediately (bypassing our own throttle) instead of waiting
        -- for the next periodic tick.
        CoABuffComm.Announce(true)
        return
    end

    local decoded = DecodeAnnounce(message)
    if not decoded then
        return
    end

    CoABuffComm.remote[shortName] = {
        specID = decoded.specID,
        specToken = decoded.specToken,
        knownSpellIDs = decoded.knownSpellIDs,
        locks = decoded.locks,
        addonVersion = decoded.addonVersion,
        receivedAt = GetTime and GetTime() or 0,
    }

    if type(CoABuffComm.OnRemoteDataUpdated) == "function" then
        pcall(CoABuffComm.OnRemoteDataUpdated, shortName)
    end
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

local function EnsureCommFrame()
    if commFrame then
        return commFrame
    end

    commFrame = CreateFrame("Frame")
    commFrame:RegisterEvent("CHAT_MSG_ADDON")
    commFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    commFrame:RegisterEvent("RAID_ROSTER_UPDATE")
    commFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    if RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, COMM_PREFIX)
    elseif C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, COMM_PREFIX)
    end

    commFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "CHAT_MSG_ADDON" then
            local prefix, message, channel, sender = ...
            HandleIncomingMessage(prefix, message, channel, sender)
            return
        end

        if event == "PARTY_MEMBERS_CHANGED"
            or event == "RAID_ROSTER_UPDATE"
            or event == "PLAYER_ENTERING_WORLD" then
            CoABuffComm.RequestAnnounce()
        end
    end)

    commFrame:SetScript("OnUpdate", function(self, delta)
        if not pendingAnnounce then
            return
        end

        local now = GetTime and GetTime() or 0
        if (now - lastAnnounceTime) >= ANNOUNCE_MIN_GAP then
            CoABuffComm.Announce(false)
        end
    end)

    return commFrame
end

EnsureCommFrame()
