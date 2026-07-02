export type CountryTag = string
export type ProvinceId = number
export type AreaId = string
export type RegionId = string
export type SuperRegionId = string
export type CultureId = string
export type ReligionId = string
export type TradeGoodId = string
export type TerrainId = string
export type ClimateId = string
export type ManufactoryId = string
export type EconomyPolicyId = string
export type ResearchGateId = string
export type IdeologyId = string
export type GovernmentTypeId = string
export type PolicyId = string
export type FactionId = string
export type ModifierDomain = string
export type LeaderSlotId = string
export type LeaderTraitId = string
export type LeaderId = string
export type PrivilegeId = string
export type EventId = string
export type RebellionId = string

export type Date = {
	year: number,
	month: number,
	day: number,
}

export type ProvinceRecord = {
	id: ProvinceId,
	name: string,
	displayCityName: string?,
	areaId: AreaId,
	regionId: RegionId,
	superRegionId: SuperRegionId,
	terrain: TerrainId,
	climate: ClimateId,
	baseTax: number,
	baseProduction: number,
	baseManpower: number,
	culture: CultureId,
	religion: ReligionId,
	tradeGood: TradeGoodId,
	goods: { [TradeGoodId]: number }?,
	isCity: boolean,
	centerOfTrade: number,
	ownerTag: CountryTag,
	controllerTag: CountryTag,
	cores: { CountryTag }, -- all current cores (default + acquired); grows via forming/conquest
	defaultCores: { CountryTag }, -- static homeland cores (seeded, never mutated at runtime); shown gold-outlined
	claims: { CountryTag },
	devTier: number,
	infraTier: number,
	fortTier: number,
	population: number,
	unrest: number,
	autonomy: number,
}

export type TransitionRecord = {
	from: GovernmentTypeId,
	to: GovernmentTypeId,
	startedAtDay: number,
	completesAtDay: number,
	ppSpent: number,
	trigger: "voluntary" | "revolution" | "event" | "conquest",
	targetIdeology: IdeologyId?,
}

export type CountryRecord = {
	tag: CountryTag,
	displayName: string,
	capitalProvinceId: ProvinceId,
	primaryCulture: CultureId,
	stateReligion: ReligionId,
	governmentForm: GovernmentTypeId,
	ideology: IdeologyId,
	stability: number,
	legitimacy: number,
	treasury: number,
	manpower: number,
	politicalPower: number,
	politicalPowerCap: number?,
	technologyGroup: string,
	historicalRivals: { CountryTag },
	historicalFriends: { CountryTag },
	color: { number },
	flagAssetId: string?,
	economyPolicy: EconomyPolicyId?,
	consumerGoodsPriority: { [TradeGoodId]: number }?,
	lastIncome: number?,
	activePolicies: { [PolicyId]: { enactedAt: number } }?,
	factions: { [FactionId]: FactionRecord }?,
	leaders: { [string]: any }?,
	transition: TransitionRecord?,
	transitionCooldowns: { [GovernmentTypeId]: number }?,
	lawPass: LawPassRecord?,
	lawCooldowns: { [PolicyId]: number }?,
	leaderCandidates: { [LeaderSlotId]: { LeaderCandidateRecord } }?,
	stockpiles: { [TradeGoodId]: number }?,
	totalIncome: number?,
	totalExpenses: number?,
	dailyProduction: { [TradeGoodId]: number }?,
	incomeBreakdown: { [string]: number }?,
	expenseBreakdown: { [string]: number }?,
	dailyConsumption: { [TradeGoodId]: number }?,
	truces: { [CountryTag]: number }?,
	formedTags: { [string]: boolean }?, -- formables already formed (one-time bonus guard)
	-- Politics overhaul ("Authority & the Estates") — all optional, system-seeded, save-compatible
	crownAuthority: number?,                                                    -- 0..cap, current Authority (Crown/Republican/Chiefly)
	crownAuthorityCap: number?,                                                 -- 100 + Σ privilege.authorityCap (<=0 each)
	unrest: number?,                                                            -- 0..100 country-level danger meter
	estatePrivileges: { [PrivilegeId]: { grantedAt: number, estateId: FactionId } }?,
	ruler: RulerRecord?,
	heir: RulerRecord?,
	succession: SuccessionRecord?,
	activeEvent: CountryEventRecord?,
	eventCooldowns: { [EventId]: number }?,
	eventClock: { nextCheckDay: number?, lastFiredDay: number? }?,
	rebellions: { [RebellionId]: RebellionRecord }?,
}

export type LawCheckpoint = {
	day: number,
	phase: number,
	outcome: "success" | "stall" | "setback",
}

export type LawPassRecord = {
	policyId: PolicyId,
	phase: number,
	setbacksTotal: number,
	startedAtDay: number,
	nextCheckpointDay: number,
	ppSpent: number,
	state: "in_progress" | "passed" | "failed" | "cancelled",
	checkpoints: { LawCheckpoint },
}

-- ── Politics overhaul types ────────────────────────────────────────────────

export type GovernmentArchetype = "monarchy" | "republic" | "tribal"
export type SuccessionKind = "hereditary" | "elective" | "republican_term" | "tribal_strongest"

export type RulerRecord = {
	id: LeaderId,
	firstName: string,
	lastName: string,
	title: string,
	age: number,
	bornDay: number,
	adm: number,                 -- 0..6 ruler stats
	dip: number,
	mil: number,
	traits: { LeaderTraitId },
	legitimacyClaim: number,     -- 0..100, personal claim strength
	isRegent: boolean?,
	portraitId: number,
}

export type SuccessionRecord = {
	kind: SuccessionKind,
	candidates: { RulerRecord }?,
	deadlineDay: number?,
	reason: string?,             -- "death" | "term_end" | "disputed" | ...
}

export type EventEffects = {
	authority: number?,
	legitimacy: number?,
	stability: number?,
	unrest: number?,
	politicalPower: number?,
	treasury: number?,
	estateLoyalty: { [FactionId]: number }?,
	estateInfluence: { [FactionId]: number }?,
	grantPrivilege: PrivilegeId?,
	revokePrivilege: PrivilegeId?,
	enactPolicy: PolicyId?,
	setIdeology: IdeologyId?,
	beginTransition: GovernmentTypeId?,
	spawnRebellion: string?,     -- rebellion kind
	chainEvent: EventId?,
}

export type CountryEventOption = {
	id: string,
	label: string,
	tooltip: string?,
	effects: EventEffects?,
	aiWeight: number?,
	isDefault: boolean?,         -- chosen on deadline auto-resolve / safest fallback
}

export type CountryEventRecord = {
	eventId: EventId,
	firedDay: number,
	deadlineDay: number?,
	context: { [string]: any }?,
	options: { CountryEventOption },
}

export type RebellionRecord = {
	id: RebellionId,
	kind: string,                -- "peasant" | "noble" | "pretender" | "mob" | "clan" | ...
	estateId: FactionId?,
	armyIds: { ArmyId },
	startedDay: number,
	demands: EventEffects?,
	targetIdeology: IdeologyId?,
	targetGovernment: GovernmentTypeId?,
}

export type PrivilegeDef = {
	id: PrivilegeId,
	displayName: string,
	estateId: FactionId,
	grantBonus: { [ModifierDomain]: number },
	influenceGain: number,
	authorityCap: number,        -- negative: how much it lowers max Authority
	loyaltyGain: number,
	ideologyGate: IdeologyId?,
	govGate: GovernmentTypeId?,
	archetypeGate: GovernmentArchetype?,
	description: string?,
}

export type GovernmentArchetypeDef = {
	archetype: GovernmentArchetype,
	successionKind: SuccessionKind,
}

export type PoliticalEventDef = {
	id: EventId,
	title: string,
	body: string,
	category: string?,
	trigger: { [string]: any }?,
	govArchetype: GovernmentArchetype?,
	cooldownDays: number?,
	weight: number?,
	deadlineDays: number?,
	options: { CountryEventOption },
}

export type LeaderSlotDef = {
	id: LeaderSlotId,
	displayName: string,
	primaryDomain: string,
	unlockedByDefault: boolean?,
	researchGate: ResearchGateId?,
	order: number,
}

export type LeaderTraitDef = {
	id: LeaderTraitId,
	displayName: string,
	modifiers: { [ModifierDomain]: number },
	preferredSlots: { LeaderSlotId },
	weight: number,
}

export type LeaderRecord = {
	id: LeaderId,
	firstName: string,
	lastName: string,
	title: string,
	slot: LeaderSlotId,
	traits: { LeaderTraitId },
	portraitId: number,
	appointedAt: number,
	age: number?,
}

export type LeaderCandidateRecord = LeaderRecord

export type FactionDef = {
	id: FactionId,
	displayName: string,
	baseClout: number,
	ideologyAffinity: { [IdeologyId]: number },
	policyReactions: { [PolicyId]: number }?,
	governmentAffinity: { [GovernmentTypeId]: number }?,
}

export type FactionRecord = {
	id: FactionId,
	clout: number,            -- "Influence": share of national power (existing field name kept)
	loyalty: number?,         -- 0..100, how content the estate is with the crown/council/chief
	tier: "marginalized" | "influential" | "powerful",
	lastDelta: number?,
}

export type IdeologyDef = {
	id: IdeologyId,
	displayName: string,
	modifiers: { [ModifierDomain]: number },
	description: string?,
}

export type GovernmentTypeDef = {
	id: GovernmentTypeId,
	displayName: string,
	allowedIdeologies: { IdeologyId },
	modifiers: { [ModifierDomain]: number },
	ppStartBonus: number,
	ppPerTick: number,
	transitions: { [GovernmentTypeId]: TransitionRule }?,
}

export type TransitionRule = {
	ppCost: number,
	minYears: number,
	requires: { [string]: any }?,
}

export type PolicyDef = {
	id: PolicyId,
	displayName: string,
	ideologyGate: IdeologyId?,
	ppCost: number,
	ppUpkeep: number,
	modifiers: { [ModifierDomain]: number },
}

export type MarketRecord = {
	goodId: TradeGoodId,
	category: string,
	basePrice: number,
	price: number,
	supply: number,
	demand: number,
	lastChange: number,
}

export type TradeOffer = {
	goodId: TradeGoodId,
	amount: number,
}

export type TradeRecord = {
	id: number,
	fromTag: CountryTag,
	toTag: CountryTag,
	offer: TradeOffer,
	request: TradeOffer,
	state: "Proposed" | "Accepted" | "Completed" | "Cancelled" | "Expired",
	createdAt: number,
	completedAt: number?,
	cancelledAt: number?,
	expiresAt: number?,
}

export type ManufactoryDef = {
	id: ManufactoryId,
	displayName: string,
	output: TradeGoodId,
	outputAmount: number,
	inputs: { [TradeGoodId]: number },
	minInfraTier: number?,
	unlockedByDefault: boolean?,
	researchGate: ResearchGateId?,
}

export type TradeGoodDef = {
	id: TradeGoodId,
	displayName: string,
	basePrice: number,
	category: string,
	unlockedByDefault: boolean?,
	researchGate: ResearchGateId?,
}

export type EconomyPolicyDef = {
	id: EconomyPolicyId,
	displayName: string,
	taxMult: number,
	productionMult: number,
	tradeMult: number,
	unrestMult: number,
}

export type EventPayload = { [string]: any }
export type EventHandler = (EventPayload) -> ()

export type TickContext = {
	simTime: number,
	deltaSeconds: number,
	gameDate: Date,
	scenarioProgress: number,
}

export type SystemDescriptor = {
	id: string,
	updateIntervalSeconds: number,
	priority: number,
	update: (TickContext) -> (),
	start: (() -> ())?,
}

export type PlayerClaim = {
	userId: number,
	tag: CountryTag,
	since: number,
}

export type StateDeltaPacket = {
	revision: number,
	provinces: { [ProvinceId]: ProvinceRecord? }?,
	countries: { [CountryTag]: CountryRecord? }?,
	markets: { [TradeGoodId]: MarketRecord? }?,
	tradeRoutes: { [number]: TradeRecord? }?,
	wars: { [string]: WarRecord? }?,
	peaceProposals: { [string]: PeaceProposal? }?,
	fullSnapshot: boolean?,
}

export type RemoteSchemaField = {
	name: string,
	type: string,
}

export type RemoteConfig = {
	schema: { RemoteSchemaField }?,
	rate: { count: number, window: number }?,
}

export type UnitTypeId = string
export type DoctrineId = string
export type ArmyId = string
export type ArmyState = "idle" | "moving" | "attacking" | "defending" | "retreating"
export type WarId = string
export type PeaceProposalId = string
export type PeaceTermsType = "white_peace" | "annex_occupied"

export type UnitTypeDef = {
	id: UnitTypeId,
	displayName: string,
	attack: number,
	defense: number,
	speed: number,
	upkeep: number,
	recruitCost: number,
	recruitManpower: number,
	recruitTicks: number,
	combatWidth: number?,
	terrainMods: { [TerrainId]: number }?,
	tags: { string }?,
	unlockedByDefault: boolean?,
	researchGate: ResearchGateId?,
}

export type RegimentComposition = { [UnitTypeId]: number }

export type MovementOrder = {
	toProvinceId: ProvinceId,
	fromProvinceId: ProvinceId,
	startedAt: number,
	completesAt: number,
	pathDistance: number,
}

export type SlotEntry = {
	armyId: ArmyId,
	unitTypeId: UnitTypeId,
	count: number,
}

export type BattleRecord = {
	id: string,
	provinceId: ProvinceId,
	attackerArmyIds: { ArmyId },
	defenderArmyIds: { ArmyId },
	attackerOriginByArmyId: { [ArmyId]: ProvinceId },
	startedAt: number,
	lastTickAt: number,
	width: number,
	attackerStrengthStart: number,
	defenderStrengthStart: number,
	attackerOrgStart: number,
	defenderOrgStart: number,
	warId: WarId?,
	frontline: { attacker: { SlotEntry }, defender: { SlotEntry } }?,
	reserves: { attacker: { SlotEntry }, defender: { SlotEntry } }?,
	attackerTacticAtk: number?,
	attackerTacticDef: number?,
	defenderTacticAtk: number?,
	defenderTacticDef: number?,
	lastDamageRoll: { attacker: number, defender: number }?,
	round: number?,
	tide: number?,           -- -1..1 attacker advantage; replicated read-only for the battle UI
	phaseCycle: string?,     -- "ground" | "naval"
	phaseIndex: number?,
	phaseElapsed: number?,
	ending: boolean?,        -- endBattle reentrancy guard; record is already removed when set
}

export type ArmyRecord = {
	id: ArmyId,
	ownerTag: CountryTag,
	provinceId: ProvinceId,
	composition: RegimentComposition,
	morale: number,
	createdAt: number,
	movement: MovementOrder?,
	battleId: string?,
	retreating: boolean?,
	baseOrganization: number?,
	organization: number?,
	entrenchment: number?,
	state: ArmyState?,
	originProvinceId: ProvinceId?,
	supplyStatus: string?,   -- "adequate" | "crowded" | "starving" (display only; set by AttritionSystem)
	movementPath: { steps: { ProvinceId }, finalProvinceId: ProvinceId }?,  -- remaining legs of a multi-tile order
	groupId: GroupId?,       -- persistent army-group membership back-ref (Combat depth B)
	autoCapture: boolean?,   -- AutoCaptureSystem toggle (nil when off, never false)
	lastFailedAttackAt: number?,  -- sim-time of the last lost attack (AutoCapture re-attack cooldown)
	battleMoraleMod: { pct: number, expireMonthIndex: number? }?,
	casualtyDebt: number?,
	reinforceEnabled: boolean?,
	reinforceTarget: RegimentComposition?,
	domain: string?,         -- "ground" | "naval"
}

export type GroupId = string
export type GeneralId = string

-- Persistent named army group (Combat depth B). Its own replicated collection (armyGroups).
export type ArmyGroupRecord = {
	id: GroupId,
	ownerTag: CountryTag,
	name: string,
	memberArmyIds: { ArmyId },
	commanderId: GeneralId?,            -- assigned roster general (Combat depth C); nil = no boost
	borderCoverTargetTag: CountryTag?,  -- "Cover Border" order (Combat depth D); nil = passive
	borderCoverLastRunAt: number?,      -- Combat depth D thrash guard
	createdAt: number,
}

-- A hired named general (Combat depth C). Lives on country.generalRoster (not its own collection).
export type GeneralRecord = {
	id: GeneralId,
	firstName: string,
	lastName: string,
	title: string?,
	traits: { string },
	portraitId: number?,
	hiredAt: number,
	experience: number,
	level: number,
	skill: number,                      -- 0..5, drives the (clamp-2)*0.1 combat bonus
	assignedGroupId: GroupId?,
}

export type RecruitTicket = {
	id: string,
	tag: CountryTag,
	provinceId: ProvinceId,
	unitTypeId: UnitTypeId,
	count: number,
	completesAt: number,
	queuedAt: number,
}

export type DoctrineDef = {
	id: DoctrineId,
	displayName: string,
	modifiers: { [ModifierDomain]: number },
	description: string?,
}

export type WarRecord = {
	id: WarId,
	attackerTag: CountryTag,
	defenderTag: CountryTag,
	declaredAt: number,
	status: "active" | "ended",
	endedAt: number?,
	peaceTermsApplied: PeaceTerms?,
}

export type PeaceTerms = {
	type: PeaceTermsType,
}

export type PeaceProposal = {
	id: PeaceProposalId,
	warId: WarId,
	fromTag: CountryTag,
	toTag: CountryTag,
	terms: PeaceTerms,
	proposedAt: number,
	expiresAt: number,
	status: "pending" | "accepted" | "rejected" | "cancelled" | "expired",
}

return {}
