local addonName, addonTable = ...;
local zc = addonTable.zc;

local ATR_BOARD_HISTORY_DAYS = 180;
local ATR_BOARD_TOP_RESULTS = 8;
local gAtr_AscensionBoardFrame = nil;
local gAtr_AscensionBoardHeading = nil;

local function Atr_BoardTodayKey ()
	return date ("%Y-%m-%d");
end

local function Atr_BoardEnsureDatabase ()
	if (AUCTIONATOR_PROFESSION_BOARD_HISTORY == nil) then
		AUCTIONATOR_PROFESSION_BOARD_HISTORY = {
			version = 1;
			days = {};
			details = {};
		};
	end

	AUCTIONATOR_PROFESSION_BOARD_HISTORY.days = AUCTIONATOR_PROFESSION_BOARD_HISTORY.days or {};
	AUCTIONATOR_PROFESSION_BOARD_HISTORY.details = AUCTIONATOR_PROFESSION_BOARD_HISTORY.details or {};
end

local function Atr_BoardRequestedItem (title)
	if (not title) then
		return nil;
	end

	local itemName = string.match (title, ".*:%s*(.+)$");
	if (itemName) then
		itemName = string.gsub (itemName, "^%s+", "");
		itemName = string.gsub (itemName, "%s+$", "");
	end
	return itemName;
end

local function Atr_BoardAddQuest (quests, title, source, itemName)
	if (title and title ~= "") then
		quests[title] = {
			source = source;
			item = itemName or Atr_BoardRequestedItem(title);
		};
	end
end

local function Atr_BoardNormalizeText (text)
	if (not text) then
		return nil;
	end
	text = string.gsub (text, "[%c]+", " ");
	text = string.gsub (text, "%s+", " ");
	text = string.gsub (text, "^%s+", "");
	text = string.gsub (text, "%s+$", "");
	return text;
end

local function Atr_BoardVisitFontStrings (callback, requiredRoot)
	if (not EnumerateFrames) then
		return;
	end

	local frame = EnumerateFrames();
	while (frame) do
		local belongs = requiredRoot == nil;
		if (requiredRoot) then
			local parent = frame;
			while (parent) do
				if (parent == requiredRoot) then
					belongs = true;
					break
				end
				parent = parent:GetParent();
			end
		end

		if (belongs and frame:IsVisible()) then
			local regions = { frame:GetRegions() };
			for _,region in ipairs (regions) do
				if (region:GetObjectType() == "FontString" and region:IsVisible()) then
					callback (region, frame, Atr_BoardNormalizeText(region:GetText()));
				end
			end
		end
		frame = EnumerateFrames (frame);
	end
end

local function Atr_BoardFindAscensionFrame ()
	local anchorFrame = nil;
	local heading = nil;
	Atr_BoardVisitFontStrings (function (region, frame, text)
		local lower = text and string.lower(text) or "";
		if (lower == "daily crafting and gathering") then
			anchorFrame = frame;
			heading = region;
		elseif (not anchorFrame and string.find(lower, "command board", 1, true)) then
			anchorFrame = frame;
		end
	end);

	if (not anchorFrame) then
		return nil, nil;
	end

	local root = anchorFrame;
	while (root:GetParent() and root:GetParent() ~= UIParent and root:GetParent() ~= WorldFrame) do
		root = root:GetParent();
	end
	return root, heading;
end

local function Atr_BoardCollectAscension (quests)
	local root,heading = Atr_BoardFindAscensionFrame();
	if (not root) then
		return false;
	end

	gAtr_AscensionBoardFrame = root;
	gAtr_AscensionBoardHeading = heading;
	local headingLeft = heading and heading:GetLeft() or nil;
	local headingTop = heading and heading:GetTop() or nil;

	Atr_BoardVisitFontStrings (function (region, frame, text)
		if (not text or not string.find(text, ":", 1, true) or not string.find(text, "%a")) then
			return;
		end

		local left = region:GetLeft();
		local top = region:GetTop();
		if (headingLeft and left and left < headingLeft - 40) then
			return;
		end
		if (headingTop and top and top >= headingTop - 8) then
			return;
		end

		local itemName = Atr_BoardRequestedItem (text);
		if (itemName and itemName ~= "") then
			Atr_BoardAddQuest (quests, text, "ascension", itemName);
		end
	end, root);

	return true;
end

local function Atr_BoardCollectQuestGreeting (quests)
	if (GetNumAvailableQuests and GetAvailableTitle) then
		for index = 1,GetNumAvailableQuests() do
			Atr_BoardAddQuest (quests, GetAvailableTitle(index), "available");
		end
	end

	if (GetNumActiveQuests and GetActiveTitle) then
		for index = 1,GetNumActiveQuests() do
			Atr_BoardAddQuest (quests, GetActiveTitle(index), "active");
		end
	end
end

local function Atr_BoardCollectGossip (quests)
	if (not GetNumGossipAvailableQuests or not GetGossipAvailableQuests) then
		return;
	end

	local count = GetNumGossipAvailableQuests();
	if (count <= 0) then
		return;
	end

	local values = { GetGossipAvailableQuests() };
	local stride = math.max (5, math.floor(#values / count));

	for index = 1,count do
		Atr_BoardAddQuest (quests, values[(index - 1) * stride + 1], "gossip");
	end
end

local function Atr_BoardPruneHistory ()
	local keys = {};
	for day,_ in pairs (AUCTIONATOR_PROFESSION_BOARD_HISTORY.days) do
		table.insert (keys, day);
	end
	table.sort (keys);

	while (#keys > ATR_BOARD_HISTORY_DAYS) do
		AUCTIONATOR_PROFESSION_BOARD_HISTORY.days[keys[1]] = nil;
		table.remove (keys, 1);
	end
end

local function Atr_BoardBuildStatistics ()
	local stats = {};
	local observedDays = 0;

	for _,dayData in pairs (AUCTIONATOR_PROFESSION_BOARD_HISTORY.days) do
		observedDays = observedDays + 1;
		for title,_ in pairs (dayData.quests or {}) do
			stats[title] = (stats[title] or 0) + 1;
		end
	end

	local sorted = {};
	for title,seen in pairs (stats) do
		table.insert (sorted, { title = title; seen = seen; });
	end
	table.sort (sorted, function (a, b)
		if (a.seen == b.seen) then
			return a.title < b.title;
		end
		return a.seen > b.seen;
	end);

	return sorted, observedDays;
end

local function Atr_BoardBuildItemStatistics ()
	local stats = {};
	local observedDays = 0;
	for _,dayData in pairs (AUCTIONATOR_PROFESSION_BOARD_HISTORY.days) do
		observedDays = observedDays + 1;
		local seenToday = {};
		for _,questData in pairs (dayData.quests or {}) do
			local itemName = questData.item;
			if (itemName and not seenToday[itemName]) then
				stats[itemName] = (stats[itemName] or 0) + 1;
				seenToday[itemName] = true;
			end
		end
	end

	local sorted = {};
	for itemName,seen in pairs (stats) do
		table.insert (sorted, { item = itemName; seen = seen; });
	end
	table.sort (sorted, function (a, b)
		if (a.seen == b.seen) then
			return a.item < b.item;
		end
		return a.seen > b.seen;
	end);
	return sorted, observedDays;
end

local function Atr_BoardPrintSummary (quests)
	local count = 0;
	for _,_ in pairs (quests) do
		count = count + 1;
	end

	zc.msg_yellow ("Auctionator: tableau professions enregistre - "..count.." quete(s).");
	for title,questData in pairs (quests) do
		local suffix = questData.item and (" |cffffff00=> "..questData.item.."|r") or "";
		zc.msg_atr ("|cff00ff00[Aujourd'hui]|r "..title..suffix);
	end

	local stats,observedDays = Atr_BoardBuildStatistics();
	if (observedDays > 1 and #stats > 0) then
		zc.msg_atr ("Quetes les plus frequentes sur "..observedDays.." jour(s):");
		for index = 1,math.min(ATR_BOARD_TOP_RESULTS, #stats) do
			local entry = stats[index];
			local percent = math.floor (entry.seen * 100 / observedDays + 0.5);
			zc.msg_atr (entry.title.." - "..entry.seen.." jour(s), "..percent.."%");
		end
	end
end

function Atr_ScanProfessionBoard ()
	Atr_BoardEnsureDatabase();

	local quests = {};
	Atr_BoardCollectAscension (quests);
	Atr_BoardCollectQuestGreeting (quests);
	Atr_BoardCollectGossip (quests);

	local count = 0;
	for _,_ in pairs (quests) do
		count = count + 1;
	end

	if (count == 0) then
		zc.msg_red ("Auctionator: aucune quete visible. Ouvre le tableau avant de lancer le scan.");
		return;
	end

	AUCTIONATOR_PROFESSION_BOARD_HISTORY.days[Atr_BoardTodayKey()] = {
		time = time();
		quests = quests;
	};

	Atr_BoardPruneHistory();
	Atr_BoardPrintSummary (quests);
end

local function Atr_BoardCaptureQuestDetail ()
	Atr_BoardEnsureDatabase();

	if (not GetTitleText) then
		return;
	end

	local title = GetTitleText();
	local today = AUCTIONATOR_PROFESSION_BOARD_HISTORY.days[Atr_BoardTodayKey()];
	if (not title or not today or not today.quests or not today.quests[title]) then
		return;
	end

	local detail = {
		lastSeen = time();
		items = {};
	};

	local itemCount = GetNumQuestItems and GetNumQuestItems() or 0;
	for index = 1,itemCount do
		local name,texture,quantity,quality = GetQuestItemInfo ("required", index);
		if (name) then
			table.insert (detail.items, {
				name = name;
				quantity = quantity or 1;
				quality = quality;
				link = GetQuestItemLink and GetQuestItemLink("required", index) or nil;
			});
		end
	end

	AUCTIONATOR_PROFESSION_BOARD_HISTORY.details[title] = detail;
	if (#detail.items > 0) then
		zc.msg_atr ("Objets requis memorises pour "..title..":");
		for _,item in ipairs (detail.items) do
			zc.msg_atr ((item.link or item.name).." x"..item.quantity);
		end
	end
end

local function Atr_BoardCreateButton (parent, name)
	if (not parent or _G[name]) then
		return;
	end

	local button = CreateFrame ("Button", name, parent, "UIPanelButtonTemplate");
	button:SetWidth (165);
	button:SetHeight (22);
	button:SetPoint ("TOPLEFT", parent, "TOPRIGHT", -12, -82);
	button:SetText ("Scan tableau professions");
	button:SetScript ("OnClick", Atr_ScanProfessionBoard);
end

local function Atr_BoardEnsureButtons ()
	Atr_BoardCreateButton (QuestFrame, "Atr_ProfessionBoardQuestButton");
	Atr_BoardCreateButton (GossipFrame, "Atr_ProfessionBoardGossipButton");

	local root,heading = Atr_BoardFindAscensionFrame();
	if (root and not Atr_ProfessionBoardAscensionButton) then
		local button = CreateFrame ("Button", "Atr_ProfessionBoardAscensionButton", root, "UIPanelButtonTemplate");
		button:SetWidth (185);
		button:SetHeight (22);
		button:SetPoint ("BOTTOM", root, "BOTTOM", -280, 27);
		button:SetText ("Scan tableau professions");
		button:SetScript ("OnClick", Atr_ScanProfessionBoard);
		gAtr_AscensionBoardFrame = root;
		gAtr_AscensionBoardHeading = heading;
	end
end

local Atr_BoardMonitor = CreateFrame ("Frame");
local Atr_BoardMonitorElapsed = 0;
Atr_BoardMonitor:SetScript ("OnUpdate", function (self, elapsed)
	Atr_BoardMonitorElapsed = Atr_BoardMonitorElapsed + elapsed;
	if (Atr_BoardMonitorElapsed >= 3) then
		Atr_BoardMonitorElapsed = 0;
		if (not Atr_ProfessionBoardAscensionButton) then
			Atr_BoardEnsureButtons();
		end
	end
end);

function Atr_ProfessionBoardOnEvent (eventName)
	Atr_BoardEnsureButtons();
	if (eventName == "QUEST_DETAIL") then
		Atr_BoardCaptureQuestDetail();
	end
end

function Atr_ProfessionBoardCommand (param1)
	Atr_BoardEnsureDatabase();
	if (param1 == "history") then
		local stats,observedDays = Atr_BoardBuildStatistics();
		zc.msg_atr ("Historique du tableau: "..observedDays.." jour(s) observes.");
		for index = 1,math.min(ATR_BOARD_TOP_RESULTS, #stats) do
			local entry = stats[index];
			zc.msg_atr (entry.title.." - "..entry.seen.." jour(s)");
		end

		local itemStats = Atr_BoardBuildItemStatistics();
		if (#itemStats > 0) then
			zc.msg_atr ("Objets demandes les plus frequents:");
			for index = 1,math.min(ATR_BOARD_TOP_RESULTS, #itemStats) do
				local entry = itemStats[index];
				zc.msg_atr (entry.item.." - "..entry.seen.." jour(s)");
			end
		end
	else
		Atr_ScanProfessionBoard();
	end
end
