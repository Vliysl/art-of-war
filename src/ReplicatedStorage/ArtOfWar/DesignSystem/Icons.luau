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

return Icons
