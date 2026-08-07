
local addonName, addonTable = ...;
local zc = addonTable.zc;

KM_NULL_STATE	= 0;
KM_PREQUERY		= 1;
KM_INQUERY		= 2;
KM_POSTQUERY	= 3;
KM_ANALYZING	= 4;
KM_SETTINGSORT	= 5;

local AUCTION_CLASS_WEAPON = 1;
local AUCTION_CLASS_ARMOR  = 2;

local gAllScans = {};

local BIGNUM = 999999999999;

local ATR_SORTBY_NAME_ASC = 0;
local ATR_SORTBY_NAME_DES = 1;
local ATR_SORTBY_PRICE_ASC = 2;
local ATR_SORTBY_PRICE_DES = 3;

-----------------------------------------

AtrScan = {};
AtrScan.__index = AtrScan;

-----------------------------------------

AtrSearch = {};
AtrSearch.__index = AtrSearch;

-----------------------------------------

function Atr_NewSearch (itemName, exact, rescanThreshold, callback)

	local srch = {};
	setmetatable (srch, AtrSearch);
	srch:Init (itemName, exact, rescanThreshold, callback);

	return srch;
end

-----------------------------------------

function AtrSearch:Init (searchText, exact, rescanThreshold, callback)

	if (searchText == nil) then
		searchText = "";
	end

	self.origSearchText = searchText;

	if (not exact) then
		if (zc.StringStartsWith (searchText, "\"") and zc.StringEndsWith (searchText, "\"")) then
			searchText = string.sub (searchText, 2, searchText:len()-1);
			exact = true;
		end
	end

	self.searchText			= searchText;
	self.exact				= exact;
	self.processing_state	= KM_NULL_STATE
	self.current_page		= -1
	self.items				= {};
	self.query				= Atr_NewQuery();
	self.sortedScans		= nil;
	self.sortHow			= ATR_SORTBY_PRICE_ASC;
	self.callback			= callback;

	if (exact) then

		if (rescanThreshold and rescanThreshold > 0) then
			local scan = Atr_FindScan (searchText);
			if (scan and (time() - scan.whenScanned) <= rescanThreshold) then
				self.items[searchText] = scan;
			end
		end

		if (not self.items[searchText]) then
			self.items[searchText] = Atr_FindScanAndInit (searchText);
		end

	end

end

-----------------------------------------

function Atr_FindScanAndInit (itemName)

	return Atr_FindScan (itemName, true);
end

-----------------------------------------

function Atr_FindScan (itemName, init)

	if (itemName == nil or itemName == "") then
		itemName = "nil";
	end

	local itemNameLC = string.lower (itemName);

	if (gAllScans[itemNameLC] == nil) then

		local scn = {};
		setmetatable (scn, AtrScan);
		scn:Init (itemName);

		gAllScans[itemNameLC] = scn;
	elseif (init) then
		gAllScans[itemNameLC]:Init (itemName);
	end

	return gAllScans[itemNameLC];
end

-----------------------------------------

function Atr_ClearScanCache ()

--	zc.msg_red ("Clearing Scan Cache");

	for a,v in pairs (gAllScans) do
		if (a ~= "nil") then
			gAllScans[a] = nil;
		end
	end

end

-----------------------------------------

function AtrScan:Init (itemName)
	self.itemName			= itemName;
	self.itemLink			= nil;
	self.scanData			= {};
	self.sortedData			= {};
	self.whenScanned		= 0;
	self.lowprices			= {BIGNUM, BIGNUM, BIGNUM};
	self.absoluteBest		= nil;
	self.itemClass			= 0;
	self.itemSubclass		= 0;
	self.yourBestPrice		= nil;
	self.yourWorstPrice		= nil;
	self.numYourSingletons	= 0;
	self.itemTextColor 		= { 1.0, 1.0, 1.0 };
	self.searchWasExact		= false;

	self:UpdateItemLink (Atr_GetItemLink (itemName));
end

-----------------------------------------

function AtrScan:UpdateItemLink (itemLink)

	self.itemLink = itemLink;

	if (itemLink) then

		Atr_AddToItemLinkCache (self.itemName, itemLink);

		local _, _, quality, _, _, sType, sSubType = GetItemInfo(itemLink);
		self.itemQuality	= quality;
		self.itemClass		= Atr_ItemType2AuctionClass (sType);
		self.itemSubclass	= Atr_SubType2AuctionSubclass (self.itemClass, sSubType);
		self.itemTextColor = ITEM_QUALITY_COLORS[quality]
	end

end


-----------------------------------------

function AtrSearch:NumScans()

	if (self.sortedScans) then
		return #self.sortedScans;
	end

	local count = 0;
	for name,scn in pairs (self.items) do
		count = count + 1;
	end

	return count;
end

-----------------------------------------

function AtrSearch:NumSortedScans()

	if (self.sortedScans) then
		return #self.sortedScans;
	end

	return 0;
end

-----------------------------------------

function AtrSearch:GetFirstScan()

	if (self.sortedScans) then
		return self.sortedScans[1];
	end

	for name,scn in pairs (self.items) do
		return scn;
	end

	return nil;

end


-----------------------------------------

function AtrSearch:Start ()

	if (self.searchText == "") then
		return;
	end

	if (Atr_IsCompoundSearch (self.searchText)) then

		local _, itemClass = Atr_ParseCompoundSearch (self.searchText);

		if (itemClass == 0) then
			Atr_Error_Display (ZT("The first part of this compound\n\nsearch is not a valid category."));
			return;
		end

		self.sortHow = ATR_SORTBY_PRICE_DES;

	end

	self.processing_state = KM_SETTINGSORT;

	SortAuctionClearSort ("list");

	BrowseName:SetText (self.searchText);		-- not necessary but nice when user switches to Browse tab

	self.current_page		= 0;
	self.processing_state	= KM_PREQUERY;

	self:Continue();

end

-----------------------------------------

function AtrSearch:Abort ()

	if (self.processing_state == KM_NULL_STATE) then
		return;
	end

	self.processing_state = KM_NULL_STATE;
	self:Init();
end

-----------------------------------------

function AtrSearch:CheckForDuplicatePage ()

	local isDup = self.query:CheckForDuplicatePage(self.current_page);

	if (isDup) then
--		zc.msg_red ("DUPLICATE PAGE FOUND: ", "  current_page: ", self.current_page, "  numDupPages: ", self.query.numDupPages);

		self.current_page	= self.current_page - 1;   -- requery the page

		self.processing_state = KM_PREQUERY;
	end

	return isDup;
end




-----------------------------------------

function AtrSearch:AnalyzeResultsPage()

	self.processing_state = KM_ANALYZING;

	if (self.query.numDupPages > 10) then 	 -- hopefully this will never happen but need check to avoid looping
		return true;						 -- done
	end


	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list");

	if (self.current_page == 1 and totalAuctions > 5000) then -- give Blizz servers a break
		Atr_Error_Display (ZT("Too many results\n\nPlease narrow your search"));
		return true;  -- done
	end

	if (totalAuctions >= 50) then
		Atr_SetMessage (string.format (ZT("Scanning auctions: page %d"), self.current_page));
	end

	-- analyze

	local numNilOwners = 0;

	if (numBatchAuctions > 0) then

		local x;

		for x = 1, numBatchAuctions do

			local name, _, count, _, _, _, _, _, buyoutPrice, _, _, owner = GetAuctionItemInfo("list", x);

			if (owner == nil) then
				numNilOwners = numNilOwners + 1;
			end
			local exactMatch = zc.StringSame (name, self.searchText);

			if (exactMatch or not self.exact) then

				if (self.items[name] == nil) then
					self.items[name] = Atr_FindScanAndInit (name);
				end

				local curpage = (tonumber(self.current_page)-1);

				local scn = self.items[name];

				scn:AddScanItem (name, count, buyoutPrice, owner, 1, curpage);

				if (scn.itemLink == nil or self.itemClass == nil) then
					scn:UpdateItemLink (GetAuctionItemLink("list", x));
				end

				if (self.callback) then
					self.callback (x, numBatchAuctions, count, buyoutPrice, owner);
				end

			end
		end
	end

	local done = (numBatchAuctions < 50);

	if (not done) then
		self.processing_state = KM_PREQUERY;
	end

	return done;
end

-----------------------------------------

function AtrScan:AddScanItem (name, stackSize, buyoutPrice, owner, numAuctions, curpage)

	local sd = {};

	if (numAuctions == nil) then
		numAuctions = 1;
	end

	for i = 1, numAuctions do
		sd["stackSize"]		= stackSize;
		sd["buyoutPrice"]	= buyoutPrice;
		sd["owner"]			= owner;
		sd["pagenum"]		= curpage;
		sd["enchantID"]		= enchantID

		tinsert (self.scanData, sd);

		local itemPrice = math.floor (buyoutPrice / stackSize);

		Atr_AddToLowPrices (self.lowprices, itemPrice);
	end

end


-----------------------------------------

function AtrScan:AddSDXToScan (price, owner, volume)	-- helper function for AddExternalDataToScan

	local sd = {};

	if (price and price > 0) then
		sd["stackSize"]		= 1;
		sd["buyoutPrice"]	= price;
		sd["owner"]			= owner;

		if (volume) then
			sd["volume"] = volume;
		end

		tinsert (self.scanData, sd);
	end

end

-----------------------------------------

function AtrScan:AddExternalDataToScan ()

	if (self.itemLink == nil) then
		return;
	end

	-- Wowecon

	if (Wowecon and Wowecon.API) then

		local priceG, volG = Wowecon.API.GetAuctionPrice_ByLink (self.itemLink, Wowecon.API.GLOBAL_PRICE)
		local priceS, volS = Wowecon.API.GetAuctionPrice_ByLink (self.itemLink, Wowecon.API.SERVER_PRICE)

		self:AddSDXToScan (priceG, "__wowEconG", volG);
		self:AddSDXToScan (priceS, "__wowEconS", volS);

	end

	-- GoingPrice Wowhead

	local id = zc.ItemIDfromLink (self.itemLink);

	id = tonumber(id);

	if (GoingPrice_Wowhead_Data and GoingPrice_Wowhead_Data[id] and GoingPrice_Wowhead_SV._index) then
		local index = GoingPrice_Wowhead_SV._index["Buyout price"];

		if (index ~= nil) then
			local price = GoingPrice_Wowhead_Data[id][index];

			self:AddSDXToScan (price, "__wowHead");
		end
	end

	-- GoingPrice Allakhazam

	if (GoingPrice_Allakhazam_Data and GoingPrice_Allakhazam_Data[id] and GoingPrice_Allakhazam_SV._index) then
		local index = GoingPrice_Allakhazam_SV._index["Median"];

		if (index ~= nil) then
			local price = GoingPrice_Allakhazam_Data[id][index];

			self:AddSDXToScan (price, "__allakhazam");
		end
	end

	-- most recent historical price

	local price = Atr_Process_Historydata();
	if (price ~= nil) then
		self:AddSDXToScan (price, "__atrLast");
	end

end

-----------------------------------------

function AtrScan:SubtractScanItem (name, stackSize, buyoutPrice)

	local sd;
	local i;

	for i,sd in ipairs (self.scanData) do

		if (sd.stackSize == stackSize and sd.buyoutPrice == buyoutPrice) then

			tremove (self.scanData, i);
			return;
		end
	end

end

-----------------------------------------

function Atr_IsCompoundSearch (searchString)

	return zc.StringContains (searchString, ">") or zc.StringContains (searchString, "/");
end

-----------------------------------------

function Atr_ParseCompoundSearch (searchString)

	local delim = "/";

	if (zc.StringContains (searchString, ">")) then
		delim = ">";
	end

	local tbl	= { strsplit (delim, searchString) };

	local queryString	= "";
	local itemClass		= 0;
	local itemSubclass	= 0;
	local minLevel		= nil;
	local maxLevel		= nil;
	local prevWasItemClass;
	local n;

	for n = 1,#tbl do
		local s = tbl[n];

		local handled = false;

		if (not handled and tonumber(s)) then
			if (minLevel == nil) then
				minLevel = tonumber(s);
			elseif (maxLevel == nil) then
				maxLevel = tonumber(s);
			end

			handled = true;
			prevWasItemClass = false;
		end

		if (not handled and prevWasItemClass and itemSubclass == 0) then
			itemSubclass = Atr_SubType2AuctionSubclass (itemClass, s);
			if (itemSubclass > 0) then
				handled = true;
				prevWasItemClass = false;
			end
		end

		if (not handled and itemClass == 0) then
			itemClass = Atr_ItemType2AuctionClass (s);
			if (itemClass > 0) then
				prevWasItemClass = true;
				handled = true;
			end
		end

		if (not handled) then
			queryString = s;
			handled = true;
		end
	end

	return queryString, itemClass, itemSubclass, minLevel, maxLevel;
end

-----------------------------------------

function AtrSearch:Continue()

	if (CanSendAuctionQuery()) then

		self.processing_state = KM_IN_QUERY;

		local queryString = self.searchText;

--	zc.md (queryString.."  page:"..self.current_page);

		local itemClass		= 0;
		local itemSubclass	= 0;
		local minLevel		= nil;
		local maxLevel		= nil;

		if (self.exact) then
			local scn = self:GetFirstScan();
			itemClass		= scn.itemClass;
			itemSubclass	= scn.itemSubclass;
		end

		if (Atr_IsCompoundSearch(queryString)) then

			queryString, itemClass, itemSubclass, minLevel, maxLevel = Atr_ParseCompoundSearch (queryString);

		end

		queryString = zc.UTF8_Truncate (queryString,63);	-- attempting to reduce number of disconnects

		QueryAuctionItems (queryString, minLevel, maxLevel, nil, itemClass, itemSubclass, self.current_page, nil, nil);

		self.query_sent_when	= Atr_ptime;
		self.processing_state	= KM_POSTQUERY;
		self.current_page		= self.current_page + 1;
	end

end

-----------------------------------------

local gSortScansBy;

-----------------------------------------

local function Atr_SortScans (x, y)

	if (gSortScansBy == ATR_SORTBY_NAME_ASC) then		return string.lower (x.itemName) < string.lower (y.itemName);	end
	if (gSortScansBy == ATR_SORTBY_NAME_DES) then		return string.lower (x.itemName) > string.lower (y.itemName);	end

	local xprice = 0;
	local yprice = 0;

	if (x.absoluteBest) then	xprice = zc.round(x.absoluteBest.buyoutPrice/x.absoluteBest.stackSize);		end;
	if (y.absoluteBest) then	yprice = zc.round(y.absoluteBest.buyoutPrice/y.absoluteBest.stackSize);		end;

	if (gSortScansBy == ATR_SORTBY_PRICE_ASC) then		return xprice < yprice;		end
	if (gSortScansBy == ATR_SORTBY_PRICE_DES) then		return xprice > yprice;		end

end

-----------------------------------------

function AtrSearch:Finish()

	local finishTime = time();

	self.processing_state	= KM_NULL_STATE;
	self.current_page		= -1;
	self.query_sent_when	= nil;

	self.sortedScans = nil;

	local wasExactSearch = (self:NumScans() == 1);		-- search returned only 1 item

	local x = 1;
	self.sortedScans = {};

	for name,scn in pairs (self.items) do
		self.sortedScans[x] = scn;
		x = x + 1;

		scn.whenScanned		= finishTime;
		scn.searchWasExact	= wasExactSearch;

		scn:CondenseAndSort();

		-- update the fullscan DB

		local newprice = Atr_CalcNewDBprice (scn.itemName, scn.lowprices);
		if (newprice > 0) then
			if (scn.itemQuality + 1 >= AUCTIONATOR_SCAN_MINLEVEL) then
				Atr_ScanDB[scn.itemName] = newprice;
			end
		end
	end

	Atr_ClearBrowseListings();

	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);
end

-----------------------------------------

function AtrSearch:ClickPriceCol()

	if (self.sortHow == ATR_SORTBY_PRICE_ASC) then
		self.sortHow = ATR_SORTBY_PRICE_DES;
	else
		self.sortHow = ATR_SORTBY_PRICE_ASC;
	end

	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);

end

-----------------------------------------

function AtrSearch:ClickNameCol()

	if (self.sortHow == ATR_SORTBY_NAME_ASC) then
		self.sortHow = ATR_SORTBY_NAME_DES;
	else
		self.sortHow = ATR_SORTBY_NAME_ASC;
	end

	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);
end

-----------------------------------------

function AtrSearch:UpdateArrows()

	Atr_Col1_Heading_ButtonArrow:Hide();
	Atr_Col3_Heading_ButtonArrow:Hide();

	if (self.sortHow == ATR_SORTBY_PRICE_ASC) then
		Atr_Col1_Heading_ButtonArrow:Show();
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0);
	elseif (self.sortHow == ATR_SORTBY_PRICE_DES) then
		Atr_Col1_Heading_ButtonArrow:Show();
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0);
	elseif (self.sortHow == ATR_SORTBY_NAME_ASC) then
		Atr_Col3_Heading_ButtonArrow:Show();
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0);
	elseif (self.sortHow == ATR_SORTBY_NAME_DES) then
		Atr_Col3_Heading_ButtonArrow:Show();
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0);
	end
end

-----------------------------------------

function Atr_ClearBrowseListings()

	local start = time();

	while (time() - start < 5) do

		if (CanSendAuctionQuery()) then
			QueryAuctionItems("xyzzy", 43, 43, 0, 7, 0);
			break
		end
	end

end

-----------------------------------------

function Atr_SortAuctionData (x, y)

	return x.itemPrice < y.itemPrice;

end

-----------------------------------------

function AtrScan:CondenseAndSort ()

	----- Condense the scan data into a table that has only a single entry per stacksize/price combo

	self.sortedData	= {};

	local conddata = {};

	for i,sd in ipairs (self.scanData) do

		local ownerCode = "x";
		local dataType  = "n";		-- normal

		if (sd.owner == UnitName("player")) then
			ownerCode = "y";
--		elseif (Atr_IsMyToon (sd.owner)) then
--			ownerCode = sd.owner;
		elseif (sd.owner == "__wowEconG") then
			dataType = "eg";
		elseif (sd.owner == "__wowEconS") then
			dataType = "es";
		elseif (sd.owner == "__wowHead") then
			dataType = "h";
		elseif (sd.owner == "__allakhazam") then
			dataType = "k";
		elseif (sd.owner == "__atrLast") then
			dataType = "a";
		end

		local key = "_"..sd.stackSize.."_"..sd.buyoutPrice.."_"..ownerCode..dataType;

		if (conddata[key]) then
			conddata[key].count		= conddata[key].count + 1;
			conddata[key].minpage 	= zc.Min (conddata[key].minpage, sd.pagenum);
			conddata[key].maxpage 	= zc.Max (conddata[key].maxpage, sd.pagenum);
		else
			local data = {};

			data.stackSize 		= sd.stackSize;
			data.buyoutPrice	= sd.buyoutPrice;
			data.itemPrice		= sd.buyoutPrice / sd.stackSize;
			data.minpage		= sd.pagenum;
			data.maxpage		= sd.pagenum;
			data.count			= 1;
			data.type			= dataType;
			data.yours			= (ownerCode == "y");

			if (ownerCode ~= "x" and ownerCode ~= "y") then
				data.altname = ownerCode;
			end

			if (sd.volume) then
				data.volume = sd.volume;
			end

			conddata[key] = data;
		end

	end

	----- create a table of these entries

	local n = 1;

	for _,v in pairs (conddata) do
		self.sortedData[n] = v;
		n = n + 1;
	end

	-- sort the table by itemPrice

	table.sort (self.sortedData, Atr_SortAuctionData);

	-- analyze and store some info about the data

	self:AnalyzeSortData ();

end

-----------------------------------------

function AtrScan:AnalyzeSortData ()

	self.absoluteBest			= nil;
	self.bestPrices				= {};		-- a table with one entry per stacksize that is the cheapest auction for that particular stacksize
	self.numMatches				= 0;
	self.numMatchesWithBuyout	= 0;
	self.hasStack				= false;
	self.yourBestPrice			= nil;
	self.yourWorstPrice			= nil;
	self.numYourSingletons		= 0;

	local j, sd;

	----- find the best price per stacksize and overall -----

	for j,sd in ipairs(self.sortedData) do

		if (sd.type == "n") then

			self.numMatches = self.numMatches + 1;

			if (sd.itemPrice > 0) then

				self.numMatchesWithBuyout = self.numMatchesWithBuyout + 1;

				if (self.bestPrices[sd.stackSize] == nil or self.bestPrices[sd.stackSize].itemPrice >= sd.itemPrice) then
					self.bestPrices[sd.stackSize] = sd;
				end

				if (self.absoluteBest == nil or self.absoluteBest.itemPrice > sd.itemPrice) then
					self.absoluteBest = sd;
				end

				if (sd.yours) then
					if (self.yourBestPrice == nil or self.yourBestPrice > sd.itemPrice) then
						self.yourBestPrice = sd.itemPrice;
					end

					if (self.yourWorstPrice == nil or self.yourWorstPrice < sd.itemPrice) then
						self.yourWorstPrice = sd.itemPrice;
					end

					if (sd.stackSize == 1) then
						self.numYourSingletons = self.numYourSingletons + sd.count;
					end
				end
			end

			if (sd.stackSize > 1) then
				self.hasStack = true;
			end
		end
	end
end

-----------------------------------------

function AtrScan:FindInSortedData (stackSize, buyoutPrice)
	local j = 1;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.stackSize == stackSize and sd.buyoutPrice == buyoutPrice and sd.yours) then
			return j;
		end
	end

	return 0;
end


-----------------------------------------

function AtrScan:FindMatchByStackSize (stackSize)

	local index = nil;

	local basedata = self.absoluteBest;

	if (self.bestPrices[stackSize]) then
		basedata = self.bestPrices[stackSize];
	end

	local numrows = #self.sortedData;

	local n;

	for n = 1,numrows do

		local data = self.sortedData[n];

		if (basedata and data.itemPrice == basedata.itemPrice and data.stackSize == basedata.stackSize and data.yours == basedata.yours) then
			index = n;
			break
		end
	end

	return index;

end

-----------------------------------------

function AtrScan:FindMatchByYours ()

	local index = nil;

	local j;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.yours) then
			index = j;
			break
		end
	end

	return index;

end

-----------------------------------------

function AtrScan:FindCheapest ()

	local index = nil;

	local j;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.itemPrice > 0) then
			index = j;
			break
		end
	end

	return index;

end


-----------------------------------------

function AtrScan:GetNumAvailable ()

	local num = 0;

	local j, data;
	for j = 1,#self.sortedData do

		data = self.sortedData[j];
		num = num + (data.count * data.stackSize);
	end

	return num;
end

-----------------------------------------

function AtrScan:IsNil ()

	if (self.itemName == nil or self.itemName == "" or self.itemName == "nil") then
		return true;
	end

	return false;
end

-----------------------------------------

ATR_FS_NULL			= 0;
ATR_FS_STARTED		= 1;
ATR_FS_ANALYZING	= 2;
ATR_FS_CLEANING_UP	= 3;

gAtr_FullScanState = ATR_FS_NULL;

-- A full scan walks the auction house one page at a time.  The server may or may
-- not honour the "getAll" flag; when it does not it simply answers page 0, so we
-- keep asking for the following pages until we have seen every auction.

local gFullScanLowPrices	= {};	-- accumulated over every page of the current scan
local gFullScanQualities	= {};
local gFullScanNumScanned	= 0;	-- auctions processed so far
local gFullScanTotal		= 0;	-- auctions the server says exist
local gFullScanPage			= 0;	-- page we last asked for
local gFullScanStartedAt	= nil;
local gFullScanPendingPage	= nil;	-- page waiting to be sent (held back by CanSendAuctionQuery)
local gFullScanWaitingSince	= nil;	-- Atr_ptime when the outstanding page was requested
local gFullScanStatusText	= "";	-- status line without the animated trailing dots
local gFullScanUseGetAll		= false;	-- only use getAll when the server explicitly allows it
local gFullScanBargainCandidates = {};
local gLastBargains = {};
local gFullScanCompleted = false;
local gFullScanMode = "full";
local gFullScanEpicsAutoAdded = 0;	-- count of epics auto-added to watch during this Full Scan

local gQuickScanItems = {};
local gQuickScanItemIndex = 0;
local gQuickScanPage = 0;
local ATR_QUICK_SCAN_MAX_PAGES_PER_ITEM = 3;
local ATR_WATCH_HISTORY_SAMPLES = 20;

local ATR_DEFAULT_WATCHLIST = {
	"Copper Bar", "Iron Bar", "Steel Bar", "Mithril Bar", "Thorium Bar",
	"Silk Cloth", "Mageweave Cloth", "Runecloth",
	"Light Leather", "Heavy Leather", "Rugged Leather", "Light Hide", "Heavy Hide",
	"Silverleaf", "Briarthorn", "Swiftthistle", "Wild Steelbloom", "Kingsblood",
	"Goldthorn", "Khadgar's Whisker", "Dreamfoil", "Mountain Silversage", "Plaguebloom",
	"Small Venom Sac", "Boar Ribs", "Silk Bandage", "Handful of Copper Bolts",
	"Elixir of Greater Defense", "Cured Light Hide", "Enchanted Thorium Bar",
	"Dry Pork Ribs", "Distilled Flask of Butchery"
};

local ATR_FS_PAGE_TIMEOUT	= 30;	-- seconds without an answer before we give up on a page
local ATR_FS_MAX_PAGES		= 5000;	-- 250,000 auctions at 50 per page

-----------------------------------------

local function Atr_FullScanSetStatus (text)

	gFullScanStatusText = text;
	Atr_FullScanStatus:SetText (text);
end

-----------------------------------------

local function Atr_FormatScanDuration (seconds)

	seconds = math.max (0, math.floor(seconds + 0.5));
	local hours = math.floor (seconds / 3600);
	local minutes = math.floor ((seconds % 3600) / 60);
	local remainingSeconds = seconds % 60;

	if (hours > 0) then
		return hours.."h "..minutes.."m";
	elseif (minutes > 0) then
		return minutes.."m "..remainingSeconds.."s";
	else
		return remainingSeconds.."s";
	end
end

-----------------------------------------

local function Atr_FullScanProgressText ()

	local text = ZT("Scanning").." "..gFullScanNumScanned.."/"..gFullScanTotal;
	local elapsed = gFullScanStartedAt and Atr_ptime and (Atr_ptime - gFullScanStartedAt) or 0;

	-- Ignore the first few pages, whose network timing is too noisy.
	if (gFullScanNumScanned >= 250 and gFullScanTotal > gFullScanNumScanned and elapsed > 0) then
		local auctionsPerSecond = gFullScanNumScanned / elapsed;
		local secondsRemaining = (gFullScanTotal - gFullScanNumScanned) / auctionsPerSecond;
		text = text.." - ~"..Atr_FormatScanDuration(secondsRemaining).." restantes";
	end

	return text;
end

-----------------------------------------

function Atr_GetDBsize()

	local n = 0;
	local a,v;

	for a,v in pairs (Atr_ScanDB) do
		n = n + 1;
	end

	return n;
end

-----------------------------------------

local gNumAdded, gNumUpdated;

-----------------------------------------

function Atr_FullScanSendPage (page)

	gFullScanPage			= page;
	gFullScanPendingPage	= nil;
	gFullScanWaitingSince	= Atr_ptime or 0;

	if (page == 0 and gFullScanUseGetAll) then
		QueryAuctionItems ("", nil, nil, 0, 0, 0, 0, 0, 0, true);		-- ask for everything when the server supports it
	else
		-- Match AtrSearch:Continue's known-good regular query signature.  In
		-- particular, inventory type, usable and quality must be nil: some
		-- private servers reject zero-valued filters without sending an update.
		QueryAuctionItems ("", nil, nil, nil, 0, 0, page, nil, nil);
	end
end

-----------------------------------------

function Atr_FullScanStart()

	local canQuery,canQueryAll = CanSendAuctionQuery();

	-- Private/custom 3.3.5 servers commonly never advertise getAll support.
	-- A regular query is enough: Atr_FullScanAnalyze will request every page.
	if (canQuery) then

		Atr_FullScanStartButton:Disable();
		Atr_QuickScanButton:Disable();
		Atr_FullScanDone:Disable();

		gAtr_FullScanState = ATR_FS_STARTED;

		SortAuctionClearSort ("list");

		gNumAdded = 0;
		gNumUpdated = 0;

		gFullScanLowPrices		= {};
		gFullScanQualities		= {};
		gFullScanNumScanned		= 0;
		gFullScanTotal			= 0;
		gFullScanStartedAt		= Atr_ptime or 0;
		gFullScanUseGetAll		= canQueryAll and true or false;
		gFullScanBargainCandidates = {};
		gFullScanEpicsAutoAdded	= 0;
		gFullScanCompleted		= false;
		gFullScanMode			= "full";

		Atr_FullScanSetStatus (ZT("Scanning"));

		Atr_FullScanSendPage (0);
	end

end

-----------------------------------------

function Atr_CalcNewDBprice (name, prices)

	if (prices[1] ~= BIGNUM) then
		return prices[1];
	end

	return 0;

end

-----------------------------------------

function Atr_AddToLowPrices (lowprices, itemPrice)

	if (itemPrice > 0) then
		if (itemPrice < lowprices[1]) then
			if (lowprices[1] < lowprices[2]) then
				lowprices[2] = lowprices[1];
			end
			lowprices[1] = itemPrice;
			return true;
		elseif (itemPrice < lowprices[2]) then
			lowprices[2] = itemPrice;
			return true;
		end
	end

	return false;
end




-----------------------------------------

local gScanDetails = {}

local function Atr_WatchEnsureData ()

	if (type(AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST) ~= "table") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST = {};
		for _,name in ipairs (ATR_DEFAULT_WATCHLIST) do
			table.insert (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST, name);
		end
	end
	if (type(AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY) ~= "table") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY = {};
	end
end

local function Atr_WatchFindIndex (wantedName)

	Atr_WatchEnsureData();
	for index,name in ipairs (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST) do
		if (zc.StringSame(name, wantedName)) then
			return index;
		end
	end
	return nil;
end

local function Atr_WatchAutoAddEpic (name, itemLink)

	if (AUCTIONATOR_SAVEDVARS.BARGAIN_AUTO_WATCH_EPICS == 0) then
		return;
	end

	if (not name or not itemLink or Atr_WatchFindIndex(name)) then
		return;
	end

	-- GetItemInfo can return nil until the client has cached the item; in that
	-- case we simply miss this occurrence and pick it up on a later scan.
	local _,_,itemRarity,_,_,_,_,_,itemEquipLoc = GetItemInfo (itemLink);
	if (itemRarity == 4 and itemEquipLoc ~= nil and itemEquipLoc ~= "") then
		Atr_WatchEnsureData();
		table.insert (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST, name);
		gFullScanEpicsAutoAdded = gFullScanEpicsAutoAdded + 1;
	end

end

local function Atr_WatchMedianReference (name)

	Atr_WatchEnsureData();
	local history = AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY[name];
	if (type(history) ~= "table" or #history < 3) then
		return nil, history and #history or 0;
	end

	local prices = {};
	for _,sample in ipairs (history) do
		local price = type(sample) == "table" and sample.price or sample;
		if (type(price) == "number" and price > 0) then
			table.insert (prices, price);
		end
	end
	if (#prices < 3) then
		return nil, #prices;
	end
	table.sort (prices);
	local middle = math.floor ((#prices + 1) / 2);
	if (#prices % 2 == 0) then
		return math.floor ((prices[middle] + prices[middle + 1]) / 2), #prices;
	end
	return prices[middle], #prices;
end

local function Atr_WatchRememberCurrentPrices ()

	Atr_WatchEnsureData();
	for name,market in pairs (gFullScanBargainCandidates) do
		if (market.lowestUnitPrice and Atr_WatchFindIndex(name)) then
			local history = AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY[name];
			if (type(history) ~= "table") then
				history = {};
				AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY[name] = history;
			end
			table.insert (history, { time = time(); price = market.lowestUnitPrice; });
			while (#history > ATR_WATCH_HISTORY_SAMPLES) do
				table.remove (history, 1);
			end
		end
	end
end

local function Atr_WatchPrintList ()

	Atr_WatchEnsureData();
	local list = AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST;
	zc.msg_yellow ("Auctionator: surveillance - "..#list.." objet(s).");
	for startIndex = 1,#list,5 do
		local line = {};
		for index = startIndex,math.min(startIndex + 4, #list) do
			table.insert (line, list[index]);
		end
		zc.msg_atr (table.concat(line, " | "));
	end
end

function Atr_GetWatchlistCount ()
	Atr_WatchEnsureData();
	return #AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST;
end

function Atr_HandleWatchCommand (action, itemName)

	Atr_WatchEnsureData();
	action = action and string.lower(action) or "";
	itemName = itemName and string.gsub(itemName, "^%s+", "") or "";
	itemName = string.gsub(itemName, "%s+$", "");

	if (action == "add" and itemName ~= "") then
		if (Atr_WatchFindIndex(itemName)) then
			zc.msg_atr (itemName.." est deja surveille.");
		else
			table.insert (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST, itemName);
			zc.msg_atr ("Ajoute a la surveillance: "..itemName);
		end
	elseif ((action == "remove" or action == "del") and itemName ~= "") then
		local index = Atr_WatchFindIndex(itemName);
		if (index) then
			local removed = table.remove (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST, index);
			AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY[removed] = nil;
			zc.msg_atr ("Retire de la surveillance: "..removed);
		else
			zc.msg_red ("Auctionator: objet absent de la surveillance: "..itemName);
		end
	elseif (action == "reset") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST = nil;
		AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY = {};
		Atr_WatchEnsureData();
		zc.msg_atr ("Liste de surveillance restauree.");
	elseif (action == "scan") then
		Atr_QuickScanStart();
		return;
	elseif (action == "clearhistory") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_WATCH_HISTORY = {};
		zc.msg_atr ("Historique de surveillance efface.");
	else
		Atr_WatchPrintList();
		zc.msg_atr ("Commandes: /atr watch add NOM, remove NOM, scan, reset, clearhistory");
	end

	if (Atr_UpdateCommandsHelp) then
		Atr_UpdateCommandsHelp();
	end
end

local function Atr_RecordBargainCandidate (name, itemLink, count, buyoutPrice, owner)

	if (name == nil or count == nil or count <= 0 or buyoutPrice == nil or buyoutPrice <= 0) then
		return;
	end

	if (owner ~= nil and owner == UnitName("player")) then
		return;
	end

	local unitPrice = math.floor (buyoutPrice / count);
	local market = gFullScanBargainCandidates[name];

	if (market == nil) then
		market = {};
		gFullScanBargainCandidates[name] = market;
	end

	if (market.lowestUnitPrice == nil or unitPrice < market.lowestUnitPrice) then
		market.nextUnitPrice = market.lowestUnitPrice;
		market.lowestUnitPrice = unitPrice;
		market.quantity = count;
		market.totalBuyout = buyoutPrice;
		market.itemLink = itemLink;
	elseif (unitPrice == market.lowestUnitPrice) then
		market.quantity = market.quantity + count;
		market.totalBuyout = market.totalBuyout + buyoutPrice;
		market.itemLink = market.itemLink or itemLink;
	elseif (market.nextUnitPrice == nil or unitPrice < market.nextUnitPrice) then
		market.nextUnitPrice = unitPrice;
	end
end

-----------------------------------------

local function Atr_FindReliableBargains ()

	local bargains = {};

	if (AUCTIONATOR_SAVEDVARS.BARGAIN_ALERTS ~= 1) then
		return bargains;
	end

	local minDiscount = AUCTIONATOR_SAVEDVARS.BARGAIN_DISCOUNT or 50;
	local minProfit = AUCTIONATOR_SAVEDVARS.BARGAIN_MIN_PROFIT or 50000;
	local auctionHouseCut = (AUCTIONATOR_SAVEDVARS.BARGAIN_AH_CUT or 5) / 100;

	for name,market in pairs (gFullScanBargainCandidates) do
		local previousPrice = Atr_ScanDB[name];
		local currentReference = market.nextUnitPrice;
		local historicalReference,historySamples = Atr_WatchMedianReference(name);

		-- Prefer several independent anchors and keep the lowest one, so a single
		-- inflated listing cannot create a false alert. Three watch scans are
		-- required before the persistent history is trusted by itself.
		local references = {};
		if (currentReference and currentReference > market.lowestUnitPrice) then
			table.insert (references, currentReference);
		end
		if (previousPrice and previousPrice > market.lowestUnitPrice) then
			table.insert (references, previousPrice);
		end
		if (historicalReference and historySamples >= 3 and historicalReference > market.lowestUnitPrice) then
			table.insert (references, historicalReference);
		end

		if (#references > 0) then
			local referencePrice = references[1];
			for index = 2,#references do
				referencePrice = math.min (referencePrice, references[index]);
			end
			local discount = math.floor ((1 - market.lowestUnitPrice / referencePrice) * 100 + 0.5);
			local expectedRevenue = math.floor (referencePrice * market.quantity * (1 - auctionHouseCut));
			local profit = expectedRevenue - market.totalBuyout;

			if (discount >= minDiscount and profit >= minProfit) then
				local isEpic = false;
				if (market.itemLink) then
					local _,_,itemRarity,_,_,_,_,_,itemEquipLoc = GetItemInfo (market.itemLink);
					isEpic = (itemRarity == 4 and itemEquipLoc ~= nil and itemEquipLoc ~= "");
				end

				table.insert (bargains, {
					name = name;
					itemLink = market.itemLink;
					quantity = market.quantity;
					buyout = market.totalBuyout;
					unitPrice = market.lowestUnitPrice;
					referencePrice = referencePrice;
					historySamples = historySamples;
					discount = discount;
					profit = profit;
					isEpic = isEpic;
				});
			end
		end
	end

	table.sort (bargains, function (a, b) return a.profit > b.profit; end);
	return bargains;
end

-----------------------------------------

local function Atr_PrintBargainAlerts (bargains)

	gLastBargains = bargains or {};

	if (AUCTIONATOR_SAVEDVARS.BARGAIN_ALERTS ~= 1) then
		return;
	end

	if (#gLastBargains == 0) then
		zc.msg_atr ("Bonnes affaires: aucune anomalie fiable detectee.");
		return;
	end

	local maxResults = AUCTIONATOR_SAVEDVARS.BARGAIN_MAX_RESULTS or 20;
	local shown = math.min (#gLastBargains, maxResults);

	local epicCount = 0;
	for _,deal in ipairs (gLastBargains) do
		if (deal.isEpic) then
			epicCount = epicCount + 1;
		end
	end

	local title = shown.." bonne(s) affaire(s) detectee(s) - /atr deals list";
	if (epicCount > 0) then
		title = title.." dont "..epicCount.." epique(s) sous-evalue(s)";
	end

	PlaySound ("AuctionWindowOpen");
	if (RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]) then
		RaidNotice_AddMessage (RaidWarningFrame, title, ChatTypeInfo["RAID_WARNING"]);
	end

	zc.msg_yellow ("Auctionator: "..title);
	for index = 1,shown do
		local deal = gLastBargains[index];
		local label = deal.itemLink or deal.name;
		local tag = deal.isEpic and "|cffa335ee[EPIQUE sous-evalue]|r " or "|cff00ff00[Bon plan]|r ";
		zc.msg_atr (tag..label.." x"..deal.quantity
			.." - achat "..zc.priceToMoneyString(deal.buyout)
			..", reference "..zc.priceToMoneyString(deal.referencePrice).."/u"
			..", -"..deal.discount.."%, profit net estime "..zc.priceToMoneyString(deal.profit));
	end
end

-----------------------------------------

function Atr_HandleBargainCommand (param1, param2)

	if (param1 == "on") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_ALERTS = 1;
	elseif (param1 == "off") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_ALERTS = 0;
	elseif (param1 == "discount" and tonumber(param2)) then
		AUCTIONATOR_SAVEDVARS.BARGAIN_DISCOUNT = math.max (10, math.min (90, tonumber(param2)));
	elseif (param1 == "profit" and tonumber(param2)) then
		AUCTIONATOR_SAVEDVARS.BARGAIN_MIN_PROFIT = math.max (0, math.floor (tonumber(param2) * 10000));
	elseif (param1 == "max" and tonumber(param2)) then
		AUCTIONATOR_SAVEDVARS.BARGAIN_MAX_RESULTS = math.max (1, math.min (50, math.floor(tonumber(param2))));
	elseif (param1 == "cut" and tonumber(param2)) then
		AUCTIONATOR_SAVEDVARS.BARGAIN_AH_CUT = math.max (0, math.min (25, tonumber(param2)));
	elseif (param1 == "autowatch" and param2 == "on") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_AUTO_WATCH_EPICS = 1;
	elseif (param1 == "autowatch" and param2 == "off") then
		AUCTIONATOR_SAVEDVARS.BARGAIN_AUTO_WATCH_EPICS = 0;
	elseif (param1 == "list") then
		Atr_PrintBargainAlerts (gLastBargains);
		return;
	end

	local enabled = AUCTIONATOR_SAVEDVARS.BARGAIN_ALERTS == 1 and "ON" or "OFF";
	local autowatch = AUCTIONATOR_SAVEDVARS.BARGAIN_AUTO_WATCH_EPICS == 0 and "OFF" or "ON";
	zc.msg_atr ("Alertes bonnes affaires: "..enabled
		.." | reduction >= "..(AUCTIONATOR_SAVEDVARS.BARGAIN_DISCOUNT or 50).."%"
		.." | profit net >= "..zc.priceToMoneyString(AUCTIONATOR_SAVEDVARS.BARGAIN_MIN_PROFIT or 50000)
		.." | commission "..(AUCTIONATOR_SAVEDVARS.BARGAIN_AH_CUT or 5).."%"
		.." | auto-surveillance epiques: "..autowatch);
	zc.msg_atr ("Commandes: /atr deals on|off, discount 50, profit 5, cut 5, autowatch on|off, max 20, list");
end

-----------------------------------------

local function Atr_QuickScanSendPage ()

	local item = gQuickScanItems[gQuickScanItemIndex];
	if (item == nil) then
		return;
	end

	gFullScanPendingPage = nil;
	gFullScanWaitingSince = Atr_ptime or 0;

	QueryAuctionItems (zc.UTF8_Truncate(item.name, 63), nil, nil, nil, 0, 0, gQuickScanPage, nil, nil);
end

-----------------------------------------

local function Atr_QuickScanNextItem ()

	gQuickScanItemIndex = gQuickScanItemIndex + 1;
	gQuickScanPage = 0;

	if (gQuickScanItemIndex > #gQuickScanItems) then
		local bargains = Atr_FindReliableBargains();
		Atr_WatchRememberCurrentPrices();
		gFullScanCompleted = true;
		gAtr_FullScanState = ATR_FS_CLEANING_UP;

		Atr_PrintBargainAlerts (bargains);
		Atr_FullScanSetStatus ("Scan surveillance termine");
		Atr_FullScanStartButton:Enable();
		Atr_QuickScanButton:Enable();
		Atr_FullScanDone:Enable();
		Atr_ClearBrowseListings();
		gFullScanBargainCandidates = {};
		return;
	end

	Atr_FullScanSetStatus ("Surveillance "..gQuickScanItemIndex.."/"..#gQuickScanItems);

	if (CanSendAuctionQuery()) then
		Atr_QuickScanSendPage();
	else
		gFullScanPendingPage = 0;
	end
end

-----------------------------------------

function Atr_QuickScanStart ()

	if (gAtr_FullScanState ~= ATR_FS_NULL or not CanSendAuctionQuery()) then
		return;
	end

	Atr_WatchEnsureData();
	gQuickScanItems = {};
	for _,name in ipairs (AUCTIONATOR_SAVEDVARS.BARGAIN_WATCHLIST) do
		if (type(name) == "string" and name ~= "") then
			table.insert (gQuickScanItems, { name = name; price = Atr_ScanDB[name] or 0; });
		end
	end

	if (#gQuickScanItems == 0) then
		zc.msg_red ("Auctionator: la liste de surveillance est vide. Utilise /atr watch reset.");
		return;
	end

	SortAuctionClearSort ("list");
	if (SortAuctionSetSort) then
		SortAuctionSetSort ("list", "buyout", false);
	end

	gFullScanMode = "quick";
	gFullScanCompleted = false;
	gFullScanBargainCandidates = {};
	gQuickScanItemIndex = 0;
	gQuickScanPage = 0;
	gAtr_FullScanState = ATR_FS_STARTED;

	Atr_FullScanStartButton:Disable();
	Atr_QuickScanButton:Disable();
	Atr_FullScanDone:Disable();

	zc.msg_atr ("Scan surveillance: "..#gQuickScanItems.." objet(s) cible(s).");
	Atr_QuickScanNextItem();
end

-----------------------------------------

function Atr_QuickScanAnalyze ()

	if (gFullScanWaitingSince == nil) then
		return;
	end
	gFullScanWaitingSince = nil;

	local item = gQuickScanItems[gQuickScanItemIndex];
	if (item == nil) then
		Atr_QuickScanNextItem();
		return;
	end

	local numBatchAuctions,totalAuctions = GetNumAuctionItems("list");
	for index = 1,numBatchAuctions do
		local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", index);
		if (name and zc.StringSame(name, item.name) and count and count > 0 and buyoutPrice and buyoutPrice > 0) then
			Atr_RecordBargainCandidate (name, GetAuctionItemLink("list", index), count, buyoutPrice, owner);
		end
	end

	local hasMorePages = ((gQuickScanPage + 1) * 50) < (totalAuctions or numBatchAuctions);
	if (hasMorePages and gQuickScanPage + 1 < ATR_QUICK_SCAN_MAX_PAGES_PER_ITEM) then
		gQuickScanPage = gQuickScanPage + 1;
		if (CanSendAuctionQuery()) then
			Atr_QuickScanSendPage();
		else
			gFullScanPendingPage = gQuickScanPage;
		end
	else
		Atr_QuickScanNextItem();
	end
end

-----------------------------------------

function Atr_FullScanMoreDetails ()

	zc.msg (" ");
	zc.msg_atr (ZT("Auctions scanned")..": |cffffffff", gScanDetails.numBatchAuctions, " |r("..gScanDetails.totalItems, "items)");

	-- qualities above Epic exist on custom servers; only show them when present

	if (gScanDetails.numEachQual[8] > 0) then	zc.msg_atr ("|cff00ccff   "..ZT("Heirloom items")..": |r",	gScanDetails.numEachQual[8]);	end
	if (gScanDetails.numEachQual[7] > 0) then	zc.msg_atr ("|cffe6cc80   "..ZT("Artifact items")..": |r",	gScanDetails.numEachQual[7]);	end
	if (gScanDetails.numEachQual[6] > 0) then	zc.msg_atr ("|cffff8000   "..ZT("Legendary items")..": |r",	gScanDetails.numEachQual[6]);	end

	zc.msg_atr ("|cffa335ee   "..ZT("Epic items")..": |r",		gScanDetails.numEachQual[5]);
	zc.msg_atr ("|cff0070dd   "..ZT("Rare items")..": |r",		gScanDetails.numEachQual[4]);
	zc.msg_atr ("|cff1eff00   "..ZT("Uncommon items")..": |r",	gScanDetails.numEachQual[3]);
	zc.msg_atr ("|cffffffff   "..ZT("Common items")..": |r",		gScanDetails.numEachQual[2]);
	zc.msg_atr ("|cff9d9d9d   "..ZT("Poor items")..": |r",		gScanDetails.numEachQual[1]);


	if (gScanDetails.numRemoved[4] > 0) then		zc.msg_atr (ZT("Rare items").." "..ZT("removed from database")..": |cffffffff",		gScanDetails.numRemoved[4]);		end
	if (gScanDetails.numRemoved[3] > 0) then		zc.msg_atr (ZT("Uncommon items").." "..ZT("removed from database")..": |cffffffff",	gScanDetails.numRemoved[3]);		end
	if (gScanDetails.numRemoved[2] > 0) then		zc.msg_atr (ZT("Common items").." "..ZT("removed from database")..": |cffffffff",	gScanDetails.numRemoved[2]);		end
	if (gScanDetails.numRemoved[1] > 0) then		zc.msg_atr (ZT("Poor items").." "..ZT("removed from database")..": |cffffffff",		gScanDetails.numRemoved[1]);		end

	zc.msg_atr (ZT("Items added to database")..": |cffffffff", gScanDetails.gNumAdded);
	zc.msg_atr (ZT("Items updated in database")..": |cffffffff", gScanDetails.gNumUpdated);
	zc.msg_atr (ZT("Items ignored")..": |cffffffff", gScanDetails.totalItems - (gScanDetails.gNumAdded + gScanDetails.gNumUpdated));
	zc.msg (" ");
end

-----------------------------------------

function Atr_FullScanAnalyze()

	if (gFullScanMode == "quick") then
		Atr_QuickScanAnalyze();
		return;
	end

	if (gFullScanWaitingSince == nil) then		-- not the answer to a page we asked for
		return;
	end

	gFullScanWaitingSince = nil;

	Atr_FullScanSetStatus (ZT("Processing"));

	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list");

	gFullScanTotal = totalAuctions or numBatchAuctions;

	zc.md ("FULL SCAN: page "..gFullScanPage.."  "..numBatchAuctions.." out of  "..gFullScanTotal)

	local lowprices = gFullScanLowPrices;
	local qualities = gFullScanQualities;
	local x;

	if (numBatchAuctions > 0) then

		for x = 1, numBatchAuctions do

			local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", x);

			if (name ~= nil and buyoutPrice ~= nil and count ~= nil and count > 0) then

				qualities[name] = quality;

				local itemPrice = math.floor (buyoutPrice / count);

				if (itemPrice > 0) then
					Atr_RecordBargainCandidate (name, GetAuctionItemLink("list", x), count, buyoutPrice, owner);

					if (quality == 4) then
						Atr_WatchAutoAddEpic (name, GetAuctionItemLink("list", x));
					end

					if (not lowprices[name]) then
						lowprices[name] = {BIGNUM,BIGNUM,BIGNUM};		-- one extra for later
					end

					Atr_AddToLowPrices (lowprices[name], itemPrice);
				end
			end

			if (x % 100 == 0) then
				Atr_FullScanSetStatus (ZT("Processing").." ("..(gFullScanNumScanned + x)..")");
			end
		end
	end

	gFullScanNumScanned = gFullScanNumScanned + numBatchAuctions;

	if (Atr_PrintBargains and Atr_CheckForBargain and numBatchAuctions > 0) then

		for x = 1, numBatchAuctions do
			Atr_CheckForBargain (x);
		end
	end

	-- the server answered with one page out of several: ask for the next one and
	-- stay in ATR_FS_STARTED so that its answer comes back through here too

	if (numBatchAuctions > 0 and gFullScanNumScanned < gFullScanTotal) then
		if (gFullScanPage + 1 < ATR_FS_MAX_PAGES) then
			Atr_FullScanSetStatus (Atr_FullScanProgressText());

			local nextPage = gFullScanPage + 1;
			if (CanSendAuctionQuery()) then
				-- The response to the previous page has arrived, so request the
				-- next one immediately. This avoids the old 0.2 second idle delay
				-- on every page (over seven minutes for 114,440 auctions).
				Atr_FullScanSendPage (nextPage);
			else
				gFullScanPendingPage = nextPage;
			end

			return;
		else
			zc.msg_red ("Auctionator: limite de securite atteinte avant la fin du scan ("
				..gFullScanNumScanned.."/"..gFullScanTotal..").");
			Atr_FullScanAbort();
			return;
		end
	end

	Atr_FullScanFinish();
end

-----------------------------------------

function Atr_FullScanFinish(completed)

	gAtr_FullScanState = ATR_FS_ANALYZING;
	gFullScanCompleted = completed ~= false;
	local scanDuration = gFullScanStartedAt and Atr_ptime and (Atr_ptime - gFullScanStartedAt) or nil;
	local bargains = Atr_FindReliableBargains();

	gFullScanPendingPage	= nil;
	gFullScanWaitingSince	= nil;

	local lowprices = gFullScanLowPrices;
	local qualities = gFullScanQualities;

	local numEachQual = {0, 0, 0, 0, 0, 0, 0, 0, 0};
	local totalItems = 0;
	local numRemoved = { 0, 0, 0, 0, 0, 0, 0, 0 };

	for name,prices in pairs (lowprices) do

		local newprice = Atr_CalcNewDBprice (name, prices);

		if (newprice > 0) then

			local qx = qualities[name] + 1;

			numEachQual[qx]	= numEachQual[qx] + 1;
			totalItems		= totalItems + 1;

			if (qx < AUCTIONATOR_SCAN_MINLEVEL and Atr_ScanDB[name]) then
				numRemoved[qx] = numRemoved[qx] + 1;
				Atr_ScanDB[name] = nil;
				zc.md ("removed: |cffbbbbbb", name, "   ("..qx..")");
			end

			if (qx >= AUCTIONATOR_SCAN_MINLEVEL) then

				if (Atr_ScanDB[name] == nil) then
					gNumAdded = gNumAdded + 1;
				else
					gNumUpdated = gNumUpdated + 1;
				end

				Atr_ScanDB[name] = newprice;
			end
		end
	end

	gScanDetails.numBatchAuctions		= gFullScanNumScanned;
	gScanDetails.totalItems				= totalItems;
	gScanDetails.numEachQual			= numEachQual;
	gScanDetails.numRemoved				= numRemoved;
	gScanDetails.gNumAdded				= gNumAdded;
	gScanDetails.gNumUpdated			= gNumUpdated;


	if (Atr_PrintBargains and Atr_CheckForBargain and gFullScanNumScanned > 0) then
		Atr_PrintBargains();
	end

	gAtr_FullScanState = ATR_FS_CLEANING_UP;

	Atr_FullScanMoreDetails();
	if (gFullScanCompleted and scanDuration) then
		zc.msg_atr ("Duree du scan complet: "..Atr_FormatScanDuration(scanDuration)..".");
	end
	Atr_PrintBargainAlerts (bargains);

	if (gFullScanEpicsAutoAdded > 0) then
		zc.msg_atr (gFullScanEpicsAutoAdded.." epique(s) equipable(s) ajoute(s) a la surveillance ("
			..Atr_GetWatchlistCount().." au total) - /atr watch scan les couvrira desormais en quelques secondes.");
	end

	Atr_FullScanSetStatus (ZT("Cleaning up"));

	Atr_FullScanStartButton:Enable();
	Atr_QuickScanButton:Enable();
	Atr_FullScanDone:Enable();
	Atr_FullScanSetStatus ("");

	Atr_FSR_scanned_count:SetText	(gFullScanNumScanned);
	Atr_FSR_added_count:SetText		(gNumAdded);
	Atr_FSR_updated_count:SetText	(gNumUpdated);
	Atr_FSR_ignored_count:SetText	(totalItems - (gNumAdded + gNumUpdated));

	Atr_FullScanHTML:Hide();
	Atr_FullScanResults:Show();

	Atr_FullScanResults:SetBackdropColor (0.3, 0.3, 0.4);

	if (gFullScanCompleted) then
		AUCTIONATOR_LAST_SCAN_TIME = time();
		if (Atr_InventoryValuePricesUpdated) then
			Atr_InventoryValuePricesUpdated();
		end
	end

	Atr_UpdateFullScanFrame ();

	Atr_ClearBrowseListings();

	gFullScanLowPrices	= {};
	gFullScanQualities	= {};
	gFullScanBargainCandidates = {};
	collectgarbage ("collect");
end

-----------------------------------------

function Atr_FullScanAbort()

	gFullScanPendingPage	= nil;
	gFullScanWaitingSince	= nil;

	if (gFullScanMode == "quick") then
		gFullScanCompleted = false;
		gAtr_FullScanState = ATR_FS_CLEANING_UP;
		zc.msg_red ("Auctionator: scan surveillance interrompu ("
			..gQuickScanItemIndex.."/"..#gQuickScanItems..").");
		Atr_FullScanStartButton:Enable();
		Atr_QuickScanButton:Enable();
		Atr_FullScanDone:Enable();
		Atr_ClearBrowseListings();
		gFullScanBargainCandidates = {};
		return;
	end

	zc.msg_red ("Auctionator: "..ZT("Scan interrupted").." ("..gFullScanNumScanned.."/"..gFullScanTotal..")");

	if (gFullScanNumScanned > 0) then		-- keep what we did manage to read
		Atr_FullScanFinish(false);
	else
		Atr_FullScanSetStatus ("");
		Atr_FullScanStartButton:Enable();
		Atr_QuickScanButton:Enable();
		Atr_FullScanDone:Enable();
		gAtr_FullScanState = ATR_FS_NULL;
	end
end

-----------------------------------------

function auctionator_AuctionFrameBrowse_Update ()

	return auctionator_orig_AuctionFrameBrowse_Update ();

end

-----------------------------------------

function Atr_ShowFullScanFrame()

	Atr_FullScanHTML:Show();
	Atr_FullScanResults:Hide();

	Atr_FullScanFrame:Show();
	Atr_FullScanFrame:SetBackdropColor(0,0,0,100);

	Atr_UpdateFullScanFrame();
	Atr_FullScanStatus:SetText ("");

	local expText = "<html><body>"
					.."<p>"
					..ZT("Scanning is entirely optional.")
					.."<br/><br/>"
					..ZT("SCAN_EXPLANATION")
					.."</p>"
					.."</body></html>"
					;



	Atr_FullScanHTML:SetText (expText);
	Atr_FullScanHTML:SetSpacing (3);
end

-----------------------------------------

function Atr_UpdateFullScanFrame()

	Atr_FullScanDBsize:SetText (Atr_GetDBsize());

	if (AUCTIONATOR_LAST_SCAN_TIME) then
		Atr_FullScanDBwhen:SetText (date ("%A, %B %d at %I:%M %p", AUCTIONATOR_LAST_SCAN_TIME));
	else
		Atr_FullScanDBwhen:SetText (ZT("Never"));
	end

	local canQuery,canQueryAll = CanSendAuctionQuery();

	-- Full scans can also run through normal paginated auction queries.
	if (canQuery) then
		Atr_FullScanStatus:SetText ("");
		Atr_FullScanStartButton:Enable();
		Atr_QuickScanButton:Enable();
		Atr_FullScanNext:SetText(ZT("Now"));
	else
		Atr_FullScanStartButton:Disable();
		Atr_QuickScanButton:Disable();

		if (AUCTIONATOR_LAST_SCAN_TIME) then
			local when = 15*60 - (time() - AUCTIONATOR_LAST_SCAN_TIME);

			when = math.floor (when/60);

			if (when == 0) then
				Atr_FullScanNext:SetText (ZT("in less than a minute"));
			elseif (when == 1) then
				Atr_FullScanNext:SetText (ZT("in about one minute"));
			elseif (when > 0) then
				Atr_FullScanNext:SetText (string.format (ZT("in about %d minutes"), when));
			else
				Atr_FullScanNext:SetText (ZT("unknown"));
			end
		else
			Atr_FullScanNext:SetText (ZT("unknown"));
		end
	end
end

-----------------------------------------

function Atr_FullScanFrameIdle()

	if (gAtr_FullScanState == ATR_FS_CLEANING_UP) then

		Atr_FullScanStatus:SetText ("Cleaning up");

		if (GetNumAuctionItems("list") < 100) then

			gAtr_FullScanState = ATR_FS_NULL;
			Atr_UpdateFullScanFrame();

			if (gFullScanCompleted) then
				if (gFullScanMode == "quick") then
					Atr_FullScanStatus:SetText ("Scan surveillance termine");
				else
					Atr_FullScanStatus:SetText (ZT("Scan complete"));
				end
				PlaySound("AuctionWindowClose");
			else
				if (gFullScanMode == "quick") then
					Atr_FullScanStatus:SetText ("Scan surveillance interrompu");
				else
					Atr_FullScanStatus:SetText (ZT("Scan interrupted"));
				end
			end
		end

	end

	if (gAtr_FullScanState == ATR_FS_STARTED) then

		if (gFullScanPendingPage and CanSendAuctionQuery()) then
			if (gFullScanMode == "quick") then
				Atr_QuickScanSendPage();
			else
				Atr_FullScanSendPage (gFullScanPendingPage);
			end
		end

		if (gFullScanWaitingSince and Atr_ptime and Atr_ptime - gFullScanWaitingSince > ATR_FS_PAGE_TIMEOUT) then
			Atr_FullScanAbort();
			return;
		end

		-- animate the trailing dots so a stalled scan is still visibly alive

		local btext = Atr_FullScanStatus:GetText ();

		if (btext) then
			if (string.len (btext) >= string.len (gFullScanStatusText) + 3) then
				Atr_FullScanStatus:SetText (gFullScanStatusText);
			else
				Atr_FullScanStatus:SetText (btext..".");
			end
		end
	end

end







