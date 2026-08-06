local addonName, addonTable = ...;
local zc = addonTable.zc;

local ATR_VALUE_ROWS = 18;
local ATR_VALUE_GUILD_TIMEOUT = 3;
local ATR_VALUE_STALE_PRICE_AGE = 24 * 60 * 60;
local ATR_VALUE_SELL_MIN_WEIGHT = 3;		-- minimum weighted history samples before trusting the average
local ATR_VALUE_SELL_RATIO = 1.3;			-- current price 30% above the historical average = good time to sell

local gValueFrame = nil;
local gValueRows = {};
local gValueResults = {};
local gValueOffset = 0;
local gValueBankOpen = false;
local gValueGuildOpen = false;
local gValueBagRefreshAt = nil;
local gValueGuildQueue = {};
local gValueGuildPending = nil;
local gValueGuildRequestedAt = nil;
local gValueGuildReadyAt = nil;
local gValueGuildContext = "guild";

local function Atr_ValueEnsureData ()
	if (type(AUCTIONATOR_INVENTORY_VALUE_DATA) ~= "table") then
		AUCTIONATOR_INVENTORY_VALUE_DATA = {};
	end

	AUCTIONATOR_INVENTORY_VALUE_DATA.version = 1;
	AUCTIONATOR_INVENTORY_VALUE_DATA.characters = AUCTIONATOR_INVENTORY_VALUE_DATA.characters or {};
	AUCTIONATOR_INVENTORY_VALUE_DATA.guilds = AUCTIONATOR_INVENTORY_VALUE_DATA.guilds or {};
	AUCTIONATOR_INVENTORY_VALUE_DATA.personalBanks = AUCTIONATOR_INVENTORY_VALUE_DATA.personalBanks or {};
	AUCTIONATOR_INVENTORY_VALUE_DATA.realmBanks = AUCTIONATOR_INVENTORY_VALUE_DATA.realmBanks or {};
end

local function Atr_ValueCharacterKey ()
	return (GetRealmName() or "?").."|"..(UnitName("player") or "?");
end

local function Atr_ValueGuildKey ()
	local guildName = GetGuildInfo and GetGuildInfo("player");
	if (not guildName) then
		return nil;
	end
	return (GetRealmName() or "?").."|"..guildName;
end

local function Atr_ValueCharacterData ()
	Atr_ValueEnsureData();
	local key = Atr_ValueCharacterKey();
	local data = AUCTIONATOR_INVENTORY_VALUE_DATA.characters[key];
	if (type(data) ~= "table") then
		data = { name = UnitName("player"); realm = GetRealmName(); };
		AUCTIONATOR_INVENTORY_VALUE_DATA.characters[key] = data;
	end
	return data;
end

local function Atr_ValueNameFromLink (itemLink)
	if (not itemLink) then
		return nil;
	end

	local itemName = GetItemInfo(itemLink);
	if (not itemName) then
		itemName = string.match(itemLink, "%[(.-)%]");
	end
	return itemName;
end

local function Atr_ValueAddItem (items, itemLink, itemCount)
	local itemName = Atr_ValueNameFromLink(itemLink);
	if (not itemName) then
		return;
	end

	local entry = items[itemName];
	if (not entry) then
		entry = { name = itemName; link = itemLink; count = 0; };
		items[itemName] = entry;
	end

	entry.link = entry.link or itemLink;
	entry.count = entry.count + (itemCount or 1);
end

local function Atr_ValueScanContainer (items, bagID)
	local slots = GetContainerNumSlots(bagID) or 0;
	for slot = 1,slots do
		local itemLink = GetContainerItemLink(bagID, slot);
		if (itemLink) then
			local _,itemCount = GetContainerItemInfo(bagID, slot);
			Atr_ValueAddItem(items, itemLink, itemCount);
		end
	end
end

local function Atr_ValueScanBags ()
	local snapshot = { time = time(); items = {}; };
	for bagID = 0,(NUM_BAG_SLOTS or 4) do
		Atr_ValueScanContainer(snapshot.items, bagID);
	end
	Atr_ValueCharacterData().bags = snapshot;
	return snapshot;
end

local function Atr_ValueScanPersonalBank ()
	if (not gValueBankOpen) then
		return false;
	end

	local snapshot = { time = time(); items = {}; };
	Atr_ValueScanContainer(snapshot.items, BANK_CONTAINER or -1);

	local firstBankBag = (NUM_BAG_SLOTS or 4) + 1;
	local lastBankBag = firstBankBag + (NUM_BANKBAGSLOTS or 7) - 1;
	for bagID = firstBankBag,lastBankBag do
		Atr_ValueScanContainer(snapshot.items, bagID);
	end

	Atr_ValueCharacterData().bank = snapshot;
	return true;
end

local function Atr_ValueFrameContainsText (frame, wanted, depth)
	if (not frame or depth > 8) then
		return false;
	end

	local regions = { frame:GetRegions() };
	for _,region in ipairs(regions) do
		if (region.GetText) then
			local text = region:GetText();
			if (text and string.find(string.lower(text), wanted, 1, true)) then
				return true;
			end
		end
	end

	local children = { frame:GetChildren() };
	for _,child in ipairs(children) do
		if (Atr_ValueFrameContainsText(child, wanted, depth + 1)) then
			return true;
		end
	end
	return false;
end

local function Atr_ValueDetectGuildContext ()
	if (GuildBankFrame) then
		if (Atr_ValueFrameContainsText(GuildBankFrame, "realm belongings", 0)
			or Atr_ValueFrameContainsText(GuildBankFrame, "realm bank", 0)) then
			return "realm";
		end
		if (Atr_ValueFrameContainsText(GuildBankFrame, "personal belongings", 0)
			or Atr_ValueFrameContainsText(GuildBankFrame, "personal bank", 0)) then
			return "personal";
		end
	end
	return "guild";
end

local function Atr_ValueContextLabel (context)
	if (context == "personal") then return "Personal Belongings"; end
	if (context == "realm") then return "Realm Belongings"; end
	return "banque de guilde";
end

local function Atr_ValueBankData (context)
	Atr_ValueEnsureData();
	local collection,key,label;

	if (context == "personal") then
		collection = AUCTIONATOR_INVENTORY_VALUE_DATA.personalBanks;
		key = Atr_ValueCharacterKey();
		label = "Personal Belongings";
	elseif (context == "realm") then
		collection = AUCTIONATOR_INVENTORY_VALUE_DATA.realmBanks;
		key = GetRealmName() or "?";
		label = "Realm Belongings";
	else
		collection = AUCTIONATOR_INVENTORY_VALUE_DATA.guilds;
		key = Atr_ValueGuildKey();
		label = GetGuildInfo and GetGuildInfo("player") or nil;
		if (not key) then
			return nil;
		end
	end

	local data = collection[key];
	if (type(data) ~= "table") then
		data = { name = label; realm = GetRealmName(); tabs = {}; };
		collection[key] = data;
	end
	data.tabs = data.tabs or {};
	return data;
end

local function Atr_ValueScanGuildTab (tab)
	local bankData = Atr_ValueBankData(gValueGuildContext);
	if (not bankData or not tab) then
		return false;
	end

	local tabName = GetGuildBankTabInfo and GetGuildBankTabInfo(tab) or ("Onglet "..tab);
	local snapshot = { time = time(); name = tabName or ("Onglet "..tab); items = {}; };
	local slots = MAX_GUILDBANK_SLOTS_PER_TAB or 98;

	for slot = 1,slots do
		local itemLink = GetGuildBankItemLink and GetGuildBankItemLink(tab, slot);
		if (itemLink) then
			local _,itemCount = GetGuildBankItemInfo(tab, slot);
			Atr_ValueAddItem(snapshot.items, itemLink, itemCount);
		end
	end

	bankData.tabs[tab] = snapshot;
	return true;
end

local function Atr_ValueStartGuildScan ()
	gValueGuildQueue = {};
	gValueGuildPending = nil;
	gValueGuildRequestedAt = nil;
	gValueGuildReadyAt = GetTime() + 0.3;
	gValueGuildContext = Atr_ValueDetectGuildContext();

	if (not gValueGuildOpen or not GetNumGuildBankTabs) then
		return false;
	end

	for tab = 1,(GetNumGuildBankTabs() or 0) do
		local _,_,isViewable = GetGuildBankTabInfo(tab);
		if (isViewable) then
			table.insert(gValueGuildQueue, tab);
		end
	end

	return #gValueGuildQueue > 0;
end

local function Atr_ValueRequestNextGuildTab ()
	if (gValueGuildPending or #gValueGuildQueue == 0 or not gValueGuildOpen) then
		return;
	end

	gValueGuildPending = table.remove(gValueGuildQueue, 1);
	gValueGuildRequestedAt = GetTime();
	if (QueryGuildBankTab) then
		QueryGuildBankTab(gValueGuildPending);
	else
		Atr_ValueScanGuildTab(gValueGuildPending);
		gValueGuildPending = nil;
	end
end

local function Atr_ValueAgeText (stamp)
	if (not stamp) then
		return "jamais";
	end

	local age = math.max(0, time() - stamp);
	if (age < 60) then
		return "a l'instant";
	elseif (age < 3600) then
		return "il y a "..math.floor(age / 60).." min";
	elseif (age < 86400) then
		return "il y a "..math.floor(age / 3600).." h";
	else
		return "il y a "..math.floor(age / 86400).." j";
	end
end

local function Atr_ValueLocationLabel (locations)
	local labels = {};
	if (locations.bags) then table.insert(labels, "Sacs"); end
	if (locations.bank) then table.insert(labels, "Banque"); end
	if (locations.personal) then table.insert(labels, "Perso"); end
	if (locations.realm) then table.insert(labels, "Royaume"); end
	if (locations.guild) then table.insert(labels, "Guilde"); end
	return table.concat(labels, "+");
end

local function Atr_ValueMergeSnapshot (combined, snapshot, location)
	if (not snapshot or type(snapshot.items) ~= "table") then
		return;
	end

	for itemName,item in pairs(snapshot.items) do
		local entry = combined[itemName];
		if (not entry) then
			entry = { name = itemName; link = item.link; count = 0; locations = {}; };
			combined[itemName] = entry;
		end
		entry.link = entry.link or item.link;
		entry.count = entry.count + (item.count or 0);
		entry.locations[location] = true;
	end
end

local function Atr_ValueHistoricalAverage (itemName)
	if (type(AUCTIONATOR_PRICING_HISTORY) ~= "table") then
		return nil, 0;
	end

	local hist = AUCTIONATOR_PRICING_HISTORY[itemName];
	if (type(hist) ~= "table") then
		return nil, 0;
	end

	local weightedSum = 0;
	local totalWeight = 0;

	for tag,entry in pairs (hist) do
		if (tag ~= "is" and type(entry) == "string") then
			local _,_,price,stacksize,numauctions = ParseHist (tag, entry);
			local weight = (numauctions and numauctions > 0) and numauctions or (stacksize or 0);
			if (type(price) == "number" and price > 0 and weight > 0) then
				weightedSum = weightedSum + price * weight;
				totalWeight = totalWeight + weight;
			end
		end
	end

	if (totalWeight < ATR_VALUE_SELL_MIN_WEIGHT) then
		return nil, totalWeight;
	end

	return weightedSum / totalWeight, totalWeight;
end

local function Atr_ValueBuildResults ()
	Atr_ValueEnsureData();
	local combined = {};
	local character = Atr_ValueCharacterData();
	Atr_ValueMergeSnapshot(combined, character.bags, "bags");
	Atr_ValueMergeSnapshot(combined, character.bank, "bank");

	local personalData = Atr_ValueBankData("personal");
	if (personalData and personalData.tabs) then
		for _,snapshot in pairs(personalData.tabs) do
			Atr_ValueMergeSnapshot(combined, snapshot, "personal");
		end
	end

	local realmData = Atr_ValueBankData("realm");
	if (realmData and realmData.tabs) then
		for _,snapshot in pairs(realmData.tabs) do
			Atr_ValueMergeSnapshot(combined, snapshot, "realm");
		end
	end

	local guildData = Atr_ValueBankData("guild");
	if (guildData and guildData.tabs) then
		for _,snapshot in pairs(guildData.tabs) do
			Atr_ValueMergeSnapshot(combined, snapshot, "guild");
		end
	end

	local results = {};
	local unpriced = 0;
	local totalValue = 0;
	local minimumValue = (AUCTIONATOR_SAVEDVARS and AUCTIONATOR_SAVEDVARS.INVENTORY_MIN_VALUE) or 10000;

	for itemName,item in pairs(combined) do
		local unitPrice = Atr_ScanDB and Atr_ScanDB[itemName];
		if (type(unitPrice) == "number" and unitPrice > 0) then
			local value = unitPrice * item.count;
			totalValue = totalValue + value;
			if (value >= minimumValue) then
				item.unitPrice = unitPrice;
				item.value = value;
				item.location = Atr_ValueLocationLabel(item.locations);

				-- sell-now signal: only meaningful for items actually sitting in a bank
				item.sellNow = false;
				if (item.locations.bank or item.locations.personal) then
					local avgPrice,samples = Atr_ValueHistoricalAverage(itemName);
					if (avgPrice and unitPrice >= avgPrice * ATR_VALUE_SELL_RATIO) then
						item.sellNow = true;
						item.avgPrice = avgPrice;
					end
				end

				table.insert(results, item);
			end
		else
			unpriced = unpriced + 1;
		end
	end

	table.sort(results, function(a, b)
		if (a.value == b.value) then
			return a.name < b.name;
		end
		return a.value > b.value;
	end);

	return results, totalValue, unpriced;
end

local function Atr_ValueShowTooltip (self)
	if (not self.itemLink) then return; end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	GameTooltip:SetHyperlink(self.itemLink);
	GameTooltip:Show();
end

local function Atr_ValueHideTooltip ()
	GameTooltip:Hide();
end

local function Atr_ValueRowClick (self)
	if (self.itemLink and IsModifiedClick("CHATLINK")) then
		ChatEdit_InsertLink(self.itemLink);
	end
end

local function Atr_ValueCreateFrame ()
	if (gValueFrame) then return; end

	local frame = CreateFrame("Frame", "Atr_InventoryValueFrame", UIParent);
	frame:SetWidth(650);
	frame:SetHeight(490);
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20);
	frame:SetFrameStrata("DIALOG");
	frame:SetToplevel(true);
	frame:SetMovable(true);
	frame:EnableMouse(true);
	frame:RegisterForDrag("LeftButton");
	frame:SetScript("OnDragStart", function(self) self:StartMoving(); end);
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); end);
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background";
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border";
		tile = true; tileSize = 32; edgeSize = 32;
		insets = { left = 11; right = 12; top = 12; bottom = 11; };
	});
	frame:Hide();
	gValueFrame = frame;

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge");
	title:SetPoint("TOP", 0, -18);
	title:SetText("Objets de valeur");

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
	close:SetPoint("TOPRIGHT", -5, -5);

	local scan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
	scan:SetWidth(135); scan:SetHeight(22);
	scan:SetPoint("TOPLEFT", 20, -46);
	scan:SetText("Scanner maintenant");
	scan:SetScript("OnClick", function() Atr_InventoryValueScan(); end);

	local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
	refresh:SetWidth(90); refresh:SetHeight(22);
	refresh:SetPoint("LEFT", scan, "RIGHT", 5, 0);
	refresh:SetText("Actualiser");
	refresh:SetScript("OnClick", function() Atr_InventoryValueRefresh(); end);

	frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	frame.status:SetPoint("TOPLEFT", 20, -76);
	frame.status:SetWidth(610);
	frame.status:SetJustifyH("LEFT");
	frame.sources = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	frame.sources:SetPoint("TOPLEFT", 20, -94);
	frame.sources:SetWidth(610);
	frame.sources:SetJustifyH("LEFT");
	frame.sources:SetTextColor(0.7, 0.7, 0.7);

	local headings = { {"Objet", 20, 260}, {"Qte", 285, 42}, {"Prix/u", 335, 95}, {"Valeur", 435, 105}, {"Lieu", 545, 80} };
	for _,heading in ipairs(headings) do
		local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
		text:SetPoint("TOPLEFT", heading[2], -118);
		text:SetWidth(heading[3]);
		text:SetJustifyH(heading[1] == "Objet" and "LEFT" or "RIGHT");
		text:SetText(heading[1]);
	end

	for index = 1,ATR_VALUE_ROWS do
		local row = CreateFrame("Button", nil, frame);
		row:SetWidth(610); row:SetHeight(17);
		row:SetPoint("TOPLEFT", 20, -134 - (index - 1) * 17);
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD");
		row:SetScript("OnEnter", Atr_ValueShowTooltip);
		row:SetScript("OnLeave", Atr_ValueHideTooltip);
		row:SetScript("OnClick", Atr_ValueRowClick);

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
		row.name:SetPoint("LEFT", 0, 0); row.name:SetWidth(260); row.name:SetJustifyH("LEFT");
		row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
		row.count:SetPoint("LEFT", 265, 0); row.count:SetWidth(42); row.count:SetJustifyH("RIGHT");
		row.unit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
		row.unit:SetPoint("LEFT", 315, 0); row.unit:SetWidth(95); row.unit:SetJustifyH("RIGHT");
		row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
		row.value:SetPoint("LEFT", 415, 0); row.value:SetWidth(105); row.value:SetJustifyH("RIGHT");
		row.location = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
		row.location:SetPoint("LEFT", 525, 0); row.location:SetWidth(80); row.location:SetJustifyH("RIGHT");

		gValueRows[index] = row;
	end

	local previous = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
	previous:SetWidth(85); previous:SetHeight(22);
	previous:SetPoint("BOTTOMLEFT", 20, 22);
	previous:SetText("Precedent");
	previous:SetScript("OnClick", function()
		gValueOffset = math.max(0, gValueOffset - ATR_VALUE_ROWS);
		Atr_InventoryValueRefresh(true);
	end);
	frame.previous = previous;

	frame.page = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	frame.page:SetPoint("BOTTOM", 0, 29);

	local nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
	nextButton:SetWidth(85); nextButton:SetHeight(22);
	nextButton:SetPoint("BOTTOMRIGHT", -20, 22);
	nextButton:SetText("Suivant");
	nextButton:SetScript("OnClick", function()
		if (gValueOffset + ATR_VALUE_ROWS < #gValueResults) then
			gValueOffset = gValueOffset + ATR_VALUE_ROWS;
			Atr_InventoryValueRefresh(true);
		end
	end);
	frame.nextButton = nextButton;
end

function Atr_InventoryValueRefresh (keepOffset)
	Atr_ValueCreateFrame();
	if (not keepOffset) then gValueOffset = 0; end

	local totalValue,unpriced;
	gValueResults,totalValue,unpriced = Atr_ValueBuildResults();

	for index,row in ipairs(gValueRows) do
		local item = gValueResults[gValueOffset + index];
		if (item) then
			row.itemLink = item.link;
			row.name:SetText(item.link or item.name);
			row.count:SetText(item.count);
			row.unit:SetText(zc.priceToMoneyString(item.unitPrice));
			row.value:SetText(zc.priceToMoneyString(item.value));
			if (item.sellNow) then
				row.value:SetTextColor(0.2, 1, 0.2);
				row.location:SetText(item.location.." |cff20ff20VENDS!|r");
			else
				row.value:SetTextColor(1, 1, 1);
				row.location:SetText(item.location);
			end
			row:Show();
		else
			row.itemLink = nil;
			row:Hide();
		end
	end

	local priceAge = Atr_ValueAgeText(AUCTIONATOR_LAST_SCAN_TIME);
	local warning = "";
	if (not AUCTIONATOR_LAST_SCAN_TIME) then
		warning = " |cffff4040Aucun Full Scan: prix indisponibles.|r";
	elseif (time() - AUCTIONATOR_LAST_SCAN_TIME > ATR_VALUE_STALE_PRICE_AGE) then
		warning = " |cffffa000Prix anciens: relance un Full Scan.|r";
	end

	local minimumValue = (AUCTIONATOR_SAVEDVARS and AUCTIONATOR_SAVEDVARS.INVENTORY_MIN_VALUE) or 10000;
	gValueFrame.status:SetText(#gValueResults.." objet(s) au-dessus de "..zc.priceToMoneyString(minimumValue)
		.." | Total valorise: "..zc.priceToMoneyString(totalValue)
		.." | Prix "..priceAge.." | "..unpriced.." sans prix."..warning);

	local character = Atr_ValueCharacterData();
	local function OldestTabStamp (data)
		local stamp = nil;
		if (data and data.tabs) then
			for _,snapshot in pairs(data.tabs) do
				if (snapshot.time and (not stamp or snapshot.time < stamp)) then stamp = snapshot.time; end
			end
		end
		return stamp;
	end
	local personalStamp = OldestTabStamp(Atr_ValueBankData("personal"));
	local realmStamp = OldestTabStamp(Atr_ValueBankData("realm"));
	local guildStamp = OldestTabStamp(Atr_ValueBankData("guild"));
	gValueFrame.sources:SetText("Contenu memorise - sacs "..Atr_ValueAgeText(character.bags and character.bags.time)
		.." | banque "..Atr_ValueAgeText(character.bank and character.bank.time)
		.." | perso "..Atr_ValueAgeText(personalStamp)
		.." | royaume "..Atr_ValueAgeText(realmStamp)
		.." | guilde "..Atr_ValueAgeText(guildStamp));

	local pages = math.max(1, math.ceil(#gValueResults / ATR_VALUE_ROWS));
	local page = math.floor(gValueOffset / ATR_VALUE_ROWS) + 1;
	gValueFrame.page:SetText("Page "..page.." / "..pages);
	if (gValueOffset > 0) then gValueFrame.previous:Enable(); else gValueFrame.previous:Disable(); end
	if (gValueOffset + ATR_VALUE_ROWS < #gValueResults) then gValueFrame.nextButton:Enable(); else gValueFrame.nextButton:Disable(); end

	if (Atr_UpdateCommandsHelp) then Atr_UpdateCommandsHelp(); end
end

function Atr_InventoryValueScan ()
	Atr_ValueScanBags();
	local bankScanned = Atr_ValueScanPersonalBank();
	local guildStarted = Atr_ValueStartGuildScan();
	Atr_InventoryValueRefresh();

	local message = "Sacs scannes";
	if (bankScanned) then message = message..", banque personnelle scannee";
	else message = message.." (ouvre ta banque pour l'ajouter)"; end
	if (guildStarted) then message = message..", banque de guilde en cours";
	else message = message.." (ouvre la banque de guilde pour l'ajouter)"; end
	if (guildStarted) then
		message = string.gsub(message, "banque de guilde en cours", Atr_ValueContextLabel(gValueGuildContext).." en cours");
	end
	zc.msg_atr("Auctionator: "..message..".");

	local sellNowCount = 0;
	for _,item in ipairs(gValueResults) do
		if (item.sellNow) then
			sellNowCount = sellNowCount + 1;
			if (sellNowCount <= ATR_VALUE_ROWS) then
				zc.msg_yellow("|cff20ff20[Vends maintenant]|r "..(item.link or item.name)
					.." x"..item.count.." - prix actuel "..zc.priceToMoneyString(item.unitPrice)
					.." vs moyenne "..zc.priceToMoneyString(item.avgPrice));
			end
		end
	end
	if (sellNowCount > 0) then
		zc.msg_yellow("Auctionator: "..sellNowCount.." objet(s) de la banque au-dessus de leur prix moyen ("..math.floor((ATR_VALUE_SELL_RATIO - 1) * 100).."%+) - bon moment pour vendre.");
	end
end

function Atr_ShowInventoryValueFrame ()
	Atr_ValueCreateFrame();
	Atr_ValueScanBags();
	Atr_InventoryValueRefresh();
	gValueFrame:Show();
end

function Atr_InventoryValueCommand (action, value)
	action = action and string.lower(action) or "";
	if (action == "scan") then
		Atr_ShowInventoryValueFrame();
		Atr_InventoryValueScan();
	elseif (action == "min" and tonumber(value)) then
		AUCTIONATOR_SAVEDVARS.INVENTORY_MIN_VALUE = math.max(0, math.floor(tonumber(value) * 10000));
		zc.msg_atr("Valeur minimale: "..zc.priceToMoneyString(AUCTIONATOR_SAVEDVARS.INVENTORY_MIN_VALUE).." par pile possedee.");
		Atr_ShowInventoryValueFrame();
	else
		Atr_ShowInventoryValueFrame();
	end
end

function Atr_InventoryValuePricesUpdated ()
	if (gValueFrame and gValueFrame:IsShown()) then
		Atr_InventoryValueRefresh(true);
	end
end

local function Atr_ValueCreateAuctionButton ()
	if (Atr_InventoryValueButton or not Atr_FullScanButton) then return; end
	local button = CreateFrame("Button", "Atr_InventoryValueButton", Atr_FullScanButton:GetParent(), "UIPanelButtonTemplate");
	button:SetWidth(84); button:SetHeight(18);
	button:SetPoint("RIGHT", Atr_FullScanButton, "LEFT", -2, 0);
	button:SetText("Mes objets");
	button:SetScript("OnClick", Atr_ShowInventoryValueFrame);
	button:SetNormalFontObject(GameFontNormalSmall);
end

local Atr_ValueEvents = CreateFrame("Frame");
Atr_ValueEvents:RegisterEvent("PLAYER_ENTERING_WORLD");
Atr_ValueEvents:RegisterEvent("BAG_UPDATE");
Atr_ValueEvents:RegisterEvent("BANKFRAME_OPENED");
Atr_ValueEvents:RegisterEvent("BANKFRAME_CLOSED");
Atr_ValueEvents:RegisterEvent("PLAYERBANKSLOTS_CHANGED");
Atr_ValueEvents:RegisterEvent("GUILDBANKFRAME_OPENED");
Atr_ValueEvents:RegisterEvent("GUILDBANKFRAME_CLOSED");
Atr_ValueEvents:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED");
Atr_ValueEvents:SetScript("OnEvent", function(self, eventName, arg1)
	if (eventName == "PLAYER_ENTERING_WORLD") then
		Atr_ValueEnsureData();
		Atr_ValueScanBags();
		Atr_ValueCreateAuctionButton();
	elseif (eventName == "BAG_UPDATE") then
		gValueBagRefreshAt = GetTime() + 0.5;
	elseif (eventName == "BANKFRAME_OPENED") then
		gValueBankOpen = true;
		Atr_ValueScanPersonalBank();
	elseif (eventName == "BANKFRAME_CLOSED") then
		Atr_ValueScanPersonalBank();
		gValueBankOpen = false;
	elseif (eventName == "PLAYERBANKSLOTS_CHANGED" and gValueBankOpen) then
		Atr_ValueScanPersonalBank();
	elseif (eventName == "GUILDBANKFRAME_OPENED") then
		gValueGuildOpen = true;
		gValueGuildContext = Atr_ValueDetectGuildContext();
		Atr_ValueStartGuildScan();
		zc.msg_atr("Auctionator: stockage detecte - "..Atr_ValueContextLabel(gValueGuildContext)..".");
	elseif (eventName == "GUILDBANKFRAME_CLOSED") then
		gValueGuildOpen = false;
		gValueGuildQueue = {};
		gValueGuildPending = nil;
		gValueGuildReadyAt = nil;
	elseif (eventName == "GUILDBANKBAGSLOTS_CHANGED" and gValueGuildPending) then
		if (not arg1 or tonumber(arg1) == gValueGuildPending) then
			Atr_ValueScanGuildTab(gValueGuildPending);
			gValueGuildPending = nil;
			gValueGuildRequestedAt = nil;
			if (gValueFrame and gValueFrame:IsShown()) then Atr_InventoryValueRefresh(true); end
		end
	end
end);

Atr_ValueEvents:SetScript("OnUpdate", function(self, elapsed)
	local now = GetTime();
	if (gValueBagRefreshAt and now >= gValueBagRefreshAt) then
		gValueBagRefreshAt = nil;
		Atr_ValueScanBags();
		if (gValueFrame and gValueFrame:IsShown()) then Atr_InventoryValueRefresh(true); end
	end

	if (gValueGuildOpen) then
		if (gValueGuildPending and gValueGuildRequestedAt and now - gValueGuildRequestedAt > ATR_VALUE_GUILD_TIMEOUT) then
			Atr_ValueScanGuildTab(gValueGuildPending);
			gValueGuildPending = nil;
			gValueGuildRequestedAt = nil;
		end
		if (not gValueGuildPending and gValueGuildReadyAt and now >= gValueGuildReadyAt) then
			gValueGuildContext = Atr_ValueDetectGuildContext();
			gValueGuildReadyAt = nil;
		end
		if (not gValueGuildReadyAt) then
			Atr_ValueRequestNextGuildTab();
		end
	end
end);
