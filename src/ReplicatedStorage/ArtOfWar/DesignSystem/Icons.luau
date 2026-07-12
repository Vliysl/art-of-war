local Colors = require(script.Parent.Colors)

local Icons = {}

Icons.Ids = {
	Treasury = "rbxassetid://138670505450017",
	Manpower = "rbxassetid://83353272761419",
	PowerProj = "rbxassetid://106401857225782",
	Stability = "rbxassetid://103742736713016",
	Legitimacy = "rbxassetid://114394911801766",
	Prestige = "rbxassetid://115844361057468",
	Research = "rbxassetid://128184957166336",
	Trade = "rbxassetid://75129164497867",
	Army = "rbxassetid://122066084508043",
	Navy = "rbxassetid://97318453843806",
	Cannon = "rbxassetid://126758241027931",
	Battle = "rbxassetid://133214124156040",
	War = "rbxassetid://133214124156040",
	Shield = "rbxassetid://139797088396031",
	Fort = "rbxassetid://127716363574326",
	Ship = "rbxassetid://115441166924093",
	Anchor = "rbxassetid://85994869473180",
	Economy = "rbxassetid://132571419888486",
	Military = "rbxassetid://100272526175549",
	Building = "rbxassetid://88595927866410",
	Factory = "rbxassetid://80735335791465",
	Market = "rbxassetid://105789921160387",
	Production = "rbxassetid://119711663795601",
	Goods = "rbxassetid://84855255662677",
	GoodCoal = "rbxassetid://92510301762852",
	GoodGrain = "rbxassetid://79816930634432",
	Diplomacy = "rbxassetid://131085198439378",
	Core = "rbxassetid://128954535690883",
	Unrest = "rbxassetid://112336785814762",
	Pause = "rbxassetid://129372096809816",
	Play = "rbxassetid://87618704293505",
	FastForward = "rbxassetid://137765484012379",
	Menu = "rbxassetid://131303991041186",
	Settings = "rbxassetid://131303991041186",
	SettingsSmall = "rbxassetid://129669152376809",
	Search = "rbxassetid://121894533499865",
	Filter = "rbxassetid://121635958937083",
	Close = "rbxassetid://105537298709576",
	Pin = "rbxassetid://80747894682901",
	Bookmark = "rbxassetid://83574771573922",
	Check = "rbxassetid://140108649505426",
	More = "rbxassetid://75937453622253",
	Plus = "rbxassetid://88788490354548",
	Minus = "rbxassetid://123051159553212",
	Eye = "rbxassetid://104198472640508",
	Lock = "rbxassetid://127913315919723",
	Star = "rbxassetid://80116020289587",
	Info = "rbxassetid://139784398284576",
	Warning = "rbxassetid://128211582619882",
	Notification = "rbxassetid://124400270787114",
	MapPolitical = "rbxassetid://120515092688349",
	MapTerrain = "rbxassetid://103389150996327",
	MapTrade = "rbxassetid://140051821907975",
	MapCulture = "rbxassetid://126798173621023",
	MapReligion = "rbxassetid://73675166292615",
	TabOverview = "rbxassetid://139784398284576",
	TabFactions = "rbxassetid://81948245627447",
	TabLeaders = "rbxassetid://110215352415946",
	TabPolicies = "rbxassetid://131787029529275",
	TabLaws = "rbxassetid://120363756760345",
	TabDoctrines = "rbxassetid://72499876526924",
	-- CountryBar economy / manpower / research buttons (dedicated 1:1 square icons).
	BarEconomy = "rbxassetid://75735377512303",
	BarManpower = "rbxassetid://95003359351366",
	BarResearch = "rbxassetid://123336824010030",
}

local warnedIcons = {}

function Icons.create(key, size, tint)
	local px = size or 16
	local id = Icons.Ids[key]
	if not id and key ~= nil and not warnedIcons[key] then
		warnedIcons[key] = true
		warn("[AoW Icons] unknown icon key: " .. tostring(key))
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.Size = UDim2.fromOffset(px, px)
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = id or ""
	img.ImageColor3 = tint or Colors.TextSecondary
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = img
	return img
end

-- Warm every icon into the client texture cache up-front. Icons are otherwise fetched LAZILY the first
-- time each ImageLabel renders (Icons.create just sets .Image), so on a cold cache or a flaky CDN they
-- intermittently pop in late or render blank -- the "icons sometimes not loading" symptom. Preloading them
-- all on boot (see ClientBoot) makes later Icons.create renders instant, and a one-shot retry recovers the
-- odd transient fetch failure. Yields; call from a task.spawn. Uses throwaway ImageLabel holders because the
-- codebase's other PreloadAsync calls pass Instances (province meshes / shells).
function Icons.preload()
	local ContentProvider = game:GetService("ContentProvider")
	local function holdersFor(ids)
		local holders = {}
		for _, id in ipairs(ids) do
			local img = Instance.new("ImageLabel")
			img.Image = id
			holders[#holders + 1] = img
		end
		return holders
	end

	local ids = {}
	for _, id in pairs(Icons.Ids) do
		if type(id) == "string" and id ~= "" then
			ids[#ids + 1] = id
		end
	end
	if #ids == 0 then
		return
	end

	local failed = {}
	local holders = holdersFor(ids)
	pcall(function()
		ContentProvider:PreloadAsync(holders, function(contentId, status)
			if status ~= Enum.AssetFetchStatus.Success then
				failed[#failed + 1] = contentId
			end
		end)
	end)
	for _, img in ipairs(holders) do
		img:Destroy()
	end

	-- one retry pass for transient failures / timeouts
	if #failed > 0 then
		task.wait(1)
		local retry = holdersFor(failed)
		pcall(function()
			ContentProvider:PreloadAsync(retry)
		end)
		for _, img in ipairs(retry) do
			img:Destroy()
		end
	end
end

return Icons
