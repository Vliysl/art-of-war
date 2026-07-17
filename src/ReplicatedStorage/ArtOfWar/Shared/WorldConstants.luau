local WorldConstants = {}

-- NOTE: server-only fields (AI decision thresholds, law/ruler/faction/estate/unrest
-- tuning, war-score/siege/attrition costs, OfficerRngSeed) live in
-- ServerScriptService/ArtOfWar/WorldConstantsServer and are merged into this table by
-- Bootstrap at startup, so they never replicate to clients. Do NOT re-add them here.

-- Map scale: migrated 2026-06 from the 18665-wide map to the 2048-wide raw-coastline map (measured extents, centered on origin).
WorldConstants.MapWidth = 2048
WorldConstants.MapDepth = 837.82
WorldConstants.MapHalfWidth = WorldConstants.MapWidth * 0.5
WorldConstants.MapHalfDepth = WorldConstants.MapDepth * 0.5
WorldConstants.MapCenterX = 0
WorldConstants.MapCenterZ = 0
-- Extra invisible FieldFloor (FieldCollider) overhang past each X seam, so the field-mode character
-- wrap (CharacterHandler) always has ground under the player at the instant it teleports across.
WorldConstants.FieldSeamMargin = 120

-- Render distance (client-side tile culling; see Modules/RenderDistanceController). Horizontal (XZ)
-- studs from the camera's ground focus; map tiles farther than this are hidden. Max = no culling
-- (large enough to cover the whole map from any camera position). Per-device defaults applied on join.
WorldConstants.RenderDistanceMin = 400
WorldConstants.RenderDistanceMax = 2300
WorldConstants.RenderDistanceDefaultDesktop = WorldConstants.RenderDistanceMax -- PC: render everything
WorldConstants.RenderDistanceDefaultTablet = 1400
WorldConstants.RenderDistanceDefaultMobile = 900

-- Dedicated "Map Editor" place (same universe). The Data Editor's config-driven access (managers +
-- historians set in the "data_editor_access" config) unlocks ONLY on this place; every other place
-- restricts the editor to the built-in dev managers. The Settings "Teleport to Map Editor" button and the
-- Map Editor place's join gate both key off this id. Single source of truth (EditorAdmins reads it too).
WorldConstants.MapEditorPlaceId = 104399454095233

-- Feature kill-switches for the country/province restructure (v4). Each gates a phase's new behavior so it
-- can be disabled at runtime without a code revert -- flip false to fall back to the old behavior.
WorldConstants.EnableFullAnnex = true -- Phase 1: full-annex peace term + defeated-country deletion + zombie cleanup
WorldConstants.EnableCores = false -- Phase 2: cores suppress unrest / non-core unrest pressure
WorldConstants.EnablePeaceConference = false -- Phase 3: war-score peace conference
WorldConstants.EnableFormables = true -- Phase 4: formable nations (Iberia is the first; no releasable defs yet)
WorldConstants.EnableRebellions = false -- Phase 4: rebellions flip provinces
WorldConstants.EnableNewEditor = false -- Phase 5: reserved. Both editors currently run (legacy=backtick, new=backslash)
WorldConstants.EnablePolitics = false -- PoliticsScreen (authority/estates/policies/leaders) cut for playtest; server remotes gated, returns UPD2
WorldConstants.EnableResearch = false -- tech tree cut; ResearchScreen is a "Coming Soon" stub; SetResearch gated until the rework ships
WorldConstants.EnableTrade = false -- trade UI cut for playtest; legacy TradeSystem + TradeOrderSystem remotes gated, returns UPD2
WorldConstants.EnableFogOfWar = false -- B2: fog enemy army detail (composition/movement/officer); own armies delivered full via the OwnArmies channel. Default off (full-info) until the client overlay + a perf pass ship

-- Map aesthetics: paint each land tile's Material from its province terrain (farmland→Carpet, grass
-- family→Grass, desert→Sand, …; mapping = TERRAIN_MATERIALS in Systems/ProvinceStamper). Coast tiles
-- keep the legacy default ("ignore"); ocean/sea tiles live outside the Provinces folders and are never
-- touched. Materials are applied at RUNTIME only — the place file is never modified — so flipping this
-- false fully restores the old uniform Concrete/Snow tile look without a code revert.
WorldConstants.EnableTerrainMaterials = false

-- Feature kill-switches for the combat update (2026-07). Same pattern: each gates one phase's new
-- behavior; flip false to restore the old behavior without a code revert. A flag stays false until
-- its phase's code lands on this branch.
WorldConstants.EnableAnnexArmyDisband = true -- C1: full annexation disbands the loser's armies + fleets
WorldConstants.EnableStrictRetreat = true -- C1: retreat = adjacent allied/controlled LAND tile w/o battle or at-war army; none -> destroyed (encirclement)
WorldConstants.EnableInstantCapture = true -- C2: entering an undefended enemy tile flips it instantly (siege progress off)
WorldConstants.EnableOccupationFreeze = true -- C2: enemy occupation cancels recruitment (refunded) + pauses construction
WorldConstants.EnableAdjacentEngagement = true -- C3: attackers fight from their own tile; march in only on victory
WorldConstants.EnableBattleDisc = true -- C4: border battle disc (SurfaceGui 1-100) replaces the billboard battle bar
WorldConstants.EnableNewInputScheme = true -- C5: LMB select/move, RMB pan/inspect (MMB pan kept)
WorldConstants.EnableMultiProvinceActions = true -- C6: ctrl/shift multi-province selection + batched recruit/build remotes
WorldConstants.EnableNewUnitModels = true -- C8: cavalry/dragoon horse model (+ C9 ship model at sea)
WorldConstants.EnableSeaTransport = true -- C9: armies path over sea tiles (embark/sail/disembark, sea battles)
WorldConstants.EnableDefenseBreakdown = true -- Combat depth A: show terrain/fort/entrench defender bonus in province + army UI
WorldConstants.EnableArmyGroups = true -- Combat depth B: persistent named army groups
WorldConstants.EnableGenerals = true -- Combat depth C: hire/assign named generals that boost a group
WorldConstants.EnableBorderCover = true -- Combat depth D: "Cover Border vs Nation" auto-front order
WorldConstants.EnableGroupCards = true -- HUD army-group card strip (moves group functions off the unit panel); off -> old ArmyPanel group bar
WorldConstants.EnableRadialOrders = false -- Phase C: long-press radial order menu (touch); flag-gated, needs on-device tuning
WorldConstants.EnableDragToMove = false -- Phase C: drag from a selected army to a province = move (touch); flag-gated, needs on-device tuning

-- Audio
WorldConstants.EnableMusic = false -- adaptive music (menu/peace/war/battle crossfades + regional themes); off until tracks are plugged in + playtested
WorldConstants.MusicDefaultVolume = 0.6 -- default MusicVolume attribute on first join (session-only, no persistence)
WorldConstants.MusicDebug = false -- log-only: print each music phase/region/track transition for tuning

-- Client settings persistence (per-user DataStore; see Systems/SettingsStore + Modules/SettingsSync). Off =
-- every SettingsScreen toggle/slider is session-only and resets each join. On = the allowlisted attributes
-- (volume/mute/render-distance/tooltips/reduce-motion/...) load on join and save on change. A NEW player still
-- starts at the defaults (nothing is written until they change a setting), so e.g. Reduce Motion stays OFF
-- until opted in, then that choice sticks across sessions. Note RenderDistance persists globally, not
-- per-device. Kill-switch: flip false to revert to session-only.
WorldConstants.PersistClientSettings = true

-- Ownership unification (single source of truth = the WorldState record). See the ownership-restructure plan.
WorldConstants.RecordDrivenMapColoring = true -- P2: client colours the political map + nation-select highlight from the replicated record, not part attributes
WorldConstants.RecordOwnershipChokepoint = true -- P3: server ownership mutations route through WorldState.setProvinceOwnership
-- (P3b "retire owner/controller attribute stamping" intentionally NOT done: those attrs are a DERIVED backup
--  still load-bearing for ProvinceReconciler boot-seeding of painted tiles + the recordFromPart fallback +
--  the Map Editor. See the note above ProvinceStamper.writeAttrs.)
-- Phase 1 (record-replication reliability). OwnershipReconcile is safe-on: a low-frequency client heal that
-- re-syncs any province whose cached record drifted from the server (kills the "annexed tile still shows the
-- old owner" class). OwnershipReplicationDebug is log-only diagnostics (server delta + client apply).
WorldConstants.OwnershipReconcile = true
WorldConstants.OwnershipReplicationDebug = false

-- Combat depth C: general hire cost + combat-fold caps (per-formation, so N grouped armies can't
-- compound the general N times).
WorldConstants.GeneralBuyPpCost = 60
WorldConstants.GeneralBuyGoldCost = 150
WorldConstants.GeneralCombatBonusCap = 1.30
WorldConstants.GeneralMoraleResistCap = 0.25

-- Combat depth D: border-cover distribution + auto-split bounds (thrash guard).
WorldConstants.BorderCoverMinRegiments = 1
WorldConstants.BorderCoverMaxSplitsPerRun = 4
WorldConstants.BorderCoverCooldownSec = 6

-- C2 instant-capture tunables: the walk-in cost. Forts no longer slow capture -- they bleed
-- the captor harder instead (per-tier casualty scaling).
WorldConstants.InstantCaptureCasualtyFrac = 0.02
WorldConstants.InstantCaptureCasualtyPerFortTier = 0.01
WorldConstants.InstantCaptureOrgLoss = 6.0 -- massive org hit: org max is 10, so a walk-in leaves the army spent + vulnerable to a counter-attack
WorldConstants.OccupiedToastWindowSec = 10
-- Coalescing window for high-volume combat toasts (Under Attack / Victory / Defeat): first fires immediately,
-- the rest within the window collapse into one "N more ..." summary so a war doesn't flood the feed.
WorldConstants.CombatToastWindowSec = 12

-- C3: a beaten attacker stands down at home instead of retreating; AutoCapture waits this many
-- sim-seconds before re-attacking after such a loss.
WorldConstants.FailedAttackCooldownSec = 20

-- C4: world-space battle disc on the border between the attacker origin and the defended tile.
WorldConstants.BattleDiscDiameter = 2

-- C9 sea-transport tunables. Step costs ARE the embark mechanic: land->land keeps the 7-tick
-- week, open water sails fast, and the land<->sea transition is the slow, vulnerable window.
-- Transports fight poorly at sea; amphibious assaults attack ashore weakened.
WorldConstants.SeaMoveTicksPerStep = 4
WorldConstants.EmbarkMoveTicks = 10
-- Pathfinding-only land-preference lever (troop auto-path). A land<->sea transition (embark or
-- disembark) costs this many "steps" in AdjacencyGraph.findPath while every land/sea step costs 1,
-- so a sea crossing carries a ~2x surcharge and a land route up to ~2*this-many tiles longer than
-- a sea shortcut is still preferred: armies march around bays/peninsulas instead of embarking to
-- cut a corner. Sea is used only when it is the sole route (islands) or the land alternative is far
-- longer. Does NOT change actual travel time (that stays SeaMoveTicksPerStep / EmbarkMoveTicks);
-- tune UP for stronger land preference, DOWN to let armies embark more readily.
WorldConstants.SeaPathEmbarkPenalty = 10
WorldConstants.SeaTransportCombatPenalty = 0.35
WorldConstants.SeaInvasionAttackPenalty = 0.5

-- Phase 2: unrest added per owned province the nation holds NO core on (cores suppress unrest). Default 0
-- (opt-in) -- raise once balanced. Gated by EnableCores; computed O(owned) in UnrestSystem.targetUnrest.
WorldConstants.UnrestNonCorePressure = 0

WorldConstants.ScenarioStartYear = 1750
WorldConstants.ScenarioStartMonth = 1
WorldConstants.ScenarioStartDay = 1
WorldConstants.ScenarioEndYear = 1849
WorldConstants.ScenarioEndMonth = 12
WorldConstants.ScenarioEndDay = 31

WorldConstants.EarlyEraCutoffYear = 1799
WorldConstants.DaysPerEarlyTick = 1
WorldConstants.DaysPerLateTick = 1

WorldConstants.SecondsPerSimTick = 1.5

WorldConstants.SecondsPerPopulationUpdate = 6
WorldConstants.SecondsPerEconomyUpdate = 3
WorldConstants.SecondsPerMilitaryUpdate = 1.5
WorldConstants.SecondsPerDiplomacyUpdate = 6

WorldConstants.PriceBandLow = 0.25
WorldConstants.PriceBandHigh = 1.75
WorldConstants.PlayerResourceTradeCap = 5
WorldConstants.TradeOrderRecurringIntervalDays = 5
WorldConstants.TradeOrderMaxLines = 8
WorldConstants.TradeOrderMaxActive = 20
WorldConstants.TradeOrderMultiplierMin = 0.25
WorldConstants.TradeOrderMultiplierMax = 4

WorldConstants.CapitalTaxMultiplier = 1.25
WorldConstants.CapitalManpowerMultiplier = 1.15
WorldConstants.CapitalUnrestReduction = 0.10
WorldConstants.CapitalFortBonus = 1

WorldConstants.YearsPerRealSecond = 0.05

WorldConstants.LeaderAppointmentCost = 40
WorldConstants.LeaderDismissalCost = 30
WorldConstants.LeaderCandidatesPerSlot = 3
WorldConstants.LeaderTraitMinimum = 2
WorldConstants.LeaderTraitMaximum = 4
WorldConstants.LeaderPortraitPoolSize = 100

WorldConstants.AdjacencyThreshold = 33 -- scaled for 2048 map (was 300 @ 18665); baked adjacency is primary, this only gates the legacy/synth fallback
WorldConstants.ArmyRecruitInfraRequirement = 2 -- DEPRECATED: no longer enforced (recruitment unlocked for all owned provinces)
WorldConstants.ArmyRegimentManpowerCost = 1000
WorldConstants.ArmyRegimentStrength = 1000
WorldConstants.ArmyMovementSpeed = 80
WorldConstants.ArmyRetreatRange = 2
WorldConstants.ArmyMoraleMax = 100
WorldConstants.ArmyMoraleMin = 0
WorldConstants.ArmyMoraleRegenPerTick = 3
WorldConstants.ArmyMoraleBattleLoss = 6
WorldConstants.ArmyOrganizationMax = 10
WorldConstants.ArmyOrganizationMin = 0
WorldConstants.ArmyOrganizationRegenPerTick = 0.5
WorldConstants.ReinforceRegimentsPerTick = 0.5 -- regiments a settled army rebuilds toward its pre-loss size per regen tick (manpower-gated)
-- perf: when true, MovementSystem/EntrenchmentSystem iterate ArmySystem's movingArmies()/idleArmies()
-- membership indices instead of scanning allArmies() every tick (sparse-subset narrowing; behavior identical).
WorldConstants.UseArmyMembershipIndex = true
-- perf: when true, ArmyView coalesces snapshot-driven reconcileAll() passes to at most once per frame
-- (task.defer) and skips its provinceSub allArmies() scan when the province's occupation signature is
-- unchanged. Visually identical; OFF restores the immediate-per-snapshot / ungated-provinceSub behavior.
WorldConstants.UseArmyViewCoalesce = true
WorldConstants.ArmyOrganizationBattleLoss = 1.5
WorldConstants.ArmyOrganizationCombatFloor = 0.3
WorldConstants.ArmyDisbandManpowerRefund = 0.5
WorldConstants.CombatTickInterval = 3
WorldConstants.OccupationProgressRequired = 12
WorldConstants.CombatArtillerySplashPerTick = 0.02
WorldConstants.MovementTickInterval = 1.5
WorldConstants.RecruitTickInterval = 3

WorldConstants.DoctrineCostMultiplierPerHigherTier = 1.6
WorldConstants.DoctrineSwitchCostFloor = 10
WorldConstants.DoctrineTierCount = 3
WorldConstants.ArmyTrainingTierMax = 5
WorldConstants.TerrainSpecializationMax = 3

WorldConstants.NavalMoraleMax = 100
WorldConstants.NavalMoraleMin = 0
WorldConstants.NavalMoraleRegenPerTick = 2
WorldConstants.NavalMoraleBattleLoss = 8
WorldConstants.NavalMovementTickInterval = 1.5
WorldConstants.NavalCombatTickInterval = 3
WorldConstants.NavalMissionTickInterval = 3
WorldConstants.NavalBuildTickInterval = 3
WorldConstants.BuildingTickInterval = 3
WorldConstants.NavalMovementSpeed = 13 -- scaled for 2048 map (was 120 @ 18665) to preserve naval travel times (stud-distance based)
WorldConstants.NavalTravelMinSeconds = 10
WorldConstants.NavalTravelMaxSeconds = 90
WorldConstants.ShipyardInfraRequirement = 2
WorldConstants.FleetRecruitMaxPerCall = 5

WorldConstants.MapModeField = "field"
WorldConstants.MapModeCommand = "command"
WorldConstants.MapModeDefault = "command"
WorldConstants.FieldColliderTopY = 0.3 -- new map land top = 0.25; flat field-floor sits just above (was 6 @ 18665)
WorldConstants.FieldColliderThickness = 1
WorldConstants.FieldSpawnHeight = 5 -- spawn just above the field floor (was 45)
WorldConstants.FieldWalkSpeed = 16 -- characters no longer 6x-scaled; Roblox-default feel on the 2048 map (was 140)
WorldConstants.FieldSprintSpeed = 32 -- was 600
WorldConstants.FieldJumpHeight = 7.2 -- Roblox default (was 12)
WorldConstants.FieldBodyScale = 1 -- characters no longer resized (was 6)
WorldConstants.FieldHeadScale = 1 -- was 5
WorldConstants.CommandPerchHeight = 100000 -- off-screen avatar park in command mode; scale-independent

-- Economy (province-driven income engine)
WorldConstants.TaxIncomePerThousand = 0.05 -- gold per day per 1000 population per devTier
WorldConstants.ResourceInfraScalePerTier = 0.1 -- 10pct resource production per infrastructure tier
WorldConstants.DevTierMax = 10
WorldConstants.InfraTierMax = 10
WorldConstants.FortTierMax = 10
WorldConstants.DaysPerMonth = 30 -- monthly /mo projection scale
-- Playtest neutralization: unrest has NO player-facing meter and the Estates/Reforms UI to manage loyalty was
-- cut, so an unrest->tax bite would be an invisible penalty a tester cannot respond to. Set to 0 (unrest still
-- simulates, but is purely internal/cosmetic). Restore to 0.005 when the politics UI returns.
WorldConstants.UnrestTaxPenaltyPerPoint = 0 -- was 0.005 (-0.5% tax per unrest point); neutralized for the public playtest
-- Playtest perf: the market price simulation is unused by any live screen (Trade UI was cut). Off = MarketSystem
-- skips its per-tick province scan / price rebalance and the `markets` table stops replicating. See MarketSystem.
WorldConstants.EnableMarketSim = false
WorldConstants.AutonomyAffectsTax = true -- multiplies (1 - autonomy)
WorldConstants.ManufactoryInfraScalePerTier = 0.05 -- +5pct manufactory throughput per infra tier above min
WorldConstants.ArmyUpkeepBaseMultiplier = 0.1 -- daily upkeep cost multiplier on unit upkeep stat
WorldConstants.ManufactoryDailyCycles = 0.1 -- a manufactory completes 0.1 cycles per day baseline

-- =====================================================================
-- DISTRICT ECONOMY REWORK (see plan i-want-to-plan-swift-peacock.md)
-- Phased kill-switches -- each OFF until its phase ships + is verified.
-- Enable order: MonthlyEconomy -> (seed districts) -> DistrictTax -> DistrictsPlayable -> gates.
-- =====================================================================
WorldConstants.MonthlyEconomy = true -- P1: commit treasury + resources once per in-game month
WorldConstants.DistrictTax = true -- P2: district-based tax (removes tax-per-population)
WorldConstants.DistrictsPlayable = true -- P3: districts occupy infra slots; build/upgrade; seed migration
WorldConstants.GateExtractionOnDistricts = true -- P4: a good is produced only if its matching extraction district exists
WorldConstants.GateRecruitOnMilitary = true -- P4: professional units require a Military district

-- District monthly tax = DistrictBaseTax[type] * D(level), D(L)=(1-g^L)/(1-g) (diminishing; asymptote 1/(1-g)).
WorldConstants.DistrictBaseTax = {
	Harbor = 0.5,
	Manufacturing = 0.7,
	Industrial = 0.5,
	Mining = 0.3,
	Agricultural = 0.2,
	Military = 0,
}
WorldConstants.DistrictLevelDiminish = 0.6 -- g in D(L); 0.6 => L1=1.0 L2=1.6 L3=1.96 ... asymptote 2.5x
WorldConstants.CapitalInnateTax = 1.0 -- flat +/mo innate tax on the capital province
WorldConstants.ExportSellRate = 0.01 -- monthly surplus goods auto-sell at basePrice * this
WorldConstants.DistrictExtractionLevelBonus = 0.25 -- extraction amount *= (1 + this*(level-1))

-- District build / upgrade cost + time (per TARGET level).
WorldConstants.DistrictBaseCost = 15 -- cost(L) = round(DistrictBaseCost * DistrictCostGrowth^(L-1))
WorldConstants.DistrictCostGrowth = 1.7
WorldConstants.DistrictBuildDaysBase = 60 -- buildDays(L) = base + perLevel*(L-1)
WorldConstants.DistrictBuildDaysPerLevel = 30
WorldConstants.DistrictManufactoryCostMult = 1.3 -- Industrial/Manufacturing pricier than extraction
WorldConstants.DistrictBuildConcurrency = 2 -- how many districts may build simultaneously per province

-- HOI4-style combat additions
WorldConstants.CombatFlankingWidthPerExtraProvince = 30
WorldConstants.CombatFlankingMaxExtraOrigins = 3
WorldConstants.CombatTerrainDefaultWidth = 60
WorldConstants.CombatTerrainMinWidth = 30
WorldConstants.CombatEntrenchmentMax = 5
WorldConstants.CombatEntrenchmentDailyGain = 0.25
WorldConstants.CombatEntrenchmentDefensePerLevel = 0.03 -- +3%/level (max 5 => +15% def); rewards digging in
WorldConstants.CombatEntrenchmentResetStrengthLossPct = 0.10

-- =====================================================================
-- COMBAT (round-based, deterministic, role-matched) - see Systems.CombatEngine.
-- A combat "round" resolves on the CombatSystem scheduler tick; CombatRoundTicks
-- lets a round span multiple scheduler ticks (1 = current 1-day-tick cadence).
-- =====================================================================
WorldConstants.CombatRoundTicks = 1
-- Deterministic damage (spec G.1.2, no luck term): per role,
--   netToDefender += max(0, attackerOffense - defenderDefense)
--   netToAttacker += max(0, defenderDefense*CounterHi - attackerOffense*CounterLo)
-- offense/defense fold count, stat, discipline, morale-factor, terrain, fort, mods.
WorldConstants.CombatDamageScale = 10 -- net damage -> strength casualties
WorldConstants.CombatDefenderCounterHi = 0.6
WorldConstants.CombatDefenderCounterLo = 0.3
WorldConstants.CombatRoundCasualtyCap = 0.15 -- max fraction of a side lost per round (lowered: more attritional, time to react)
-- Resolution by ROUT (morale/org), not strength attrition:
WorldConstants.CombatMoraleRoutFloor = 30 -- a formation routs at/below this morale
WorldConstants.CombatRoutFraction = 0.5 -- side breaks when >= this strength-frac routed
WorldConstants.CombatOrgBreakRatio = 0.15 -- or aggregate org ratio below this
WorldConstants.CombatMoraleRoundBase = 1 -- morale lost per round under fire
WorldConstants.CombatMoraleCasualtyScale = 120 -- extra morale lost scaled by casualty ratio (softened so org/strength decide more)
WorldConstants.CombatOrgRoundBase = 0 -- org lost per round (0 = casualty-driven only)
WorldConstants.CombatOrgCasualtyScale = 12 -- org lost scaled by casualty ratio
-- Discipline per unit class (folds into offense/defense); data wired Phase 2/4.
WorldConstants.DisciplineLevy = 0.6
WorldConstants.DisciplineStandard = 1.0
WorldConstants.DisciplineElite = 1.4
-- Forts in field battle: defender defense x (1 + fortTier*FortBattleDefensePerTier).
-- Combat depth A: 0.15 -> 0.20 so a Tier-2 fortress gives +40% defender in a field battle,
-- making fortified lines a real obstacle. Only the DEFENDER multiplier -- capturing an
-- UNDEFENDED fort is unchanged (see InstantCaptureCasualtyPerFortTier / siege constants, untouched).
WorldConstants.FortBattleDefensePerTier = 0.20
WorldConstants.FortCannonDebuff = 0.75 -- hook: cannon-tech fort debuff (gated off)
-- Post-battle morale modifiers (spec G.1.7), applied by BattleManager.
WorldConstants.BattleVictorMoraleBonus = 0.10
WorldConstants.BattleLoserMoralePenalty = 0.20
WorldConstants.BattleMoraleModifierMonths = 6
-- Naval role-matched rounds (Phase 3).
WorldConstants.NavalCombatWidth = 40
WorldConstants.NavalDamageScale = 2 -- per-round naval casualty scale (lower than land; hull pools are large)
WorldConstants.NavalOrgRegenPerTick = 0.5 -- fleet organization regen while docked (mirrors ArmyOrganizationRegenPerTick)
-- Doctrine tactic bonuses fold into the single statMultiplier (kept).
WorldConstants.CombatTacticOffensiveBonus = 0.05
WorldConstants.CombatTacticDefensiveBonus = 0.05
-- Monthly cadence for war-exhaustion / attrition passes (Phase 5).
WorldConstants.TicksPerMonth = 30

-- =====================================================================
-- MANPOWER POOLS: Levies vs Professionals (spec 6.5.2 / B.5, Phase 4).
-- country.manpower stays the PROFESSIONAL pool (existing ~40 consumers).
-- country.levyManpower is the new LEVY pool, regenerated up to country.levyCap
-- (sum of per-province contributions). UnitTypes[t].class ("levy"|"professional")
-- selects the pool. Levies are cheap+plentiful but low discipline (DisciplineLevy);
-- professionals are scarce+elite. RecruitSystem owns the pools + monthly regen.
-- =====================================================================
WorldConstants.LevyManpowerPerBaseMP = 250 -- province levy cap = baseManpower * this * mods
WorldConstants.LevyDevFactorPerTier = 0.10 -- devFactor = 1 + (devTier-1)*this
WorldConstants.LevyForeignCultureMod = 0.5 -- province culture not primary/accepted -> levy x this
WorldConstants.LevyAutonomyMaxReduction = 1.0 -- levy x (1 - autonomy*this) (autonomy 0..1)
WorldConstants.LevyConscriptionDefault = 1.0 -- HOOK: conscription-law multiplier (Politics out of scope)
WorldConstants.LevyRegenPerMonthPct = 0.05 -- levy pool regens 5%/mo of cap (peacetime)
WorldConstants.ProfessionalRegenPerMonthPct = 0 -- HOOK: pro regen (laws/barracks out of scope; 0 = legacy static)
WorldConstants.ManpowerRegenTickInterval = 6 -- scheduler cadence (effective s); regen is continuous per in-game day

-- Unified population-based manpower (replaces the levy/professional split above, now dormant).
-- Each owned+controlled province contributes floor(population * ManpowerPopFraction) to country.manpowerCap;
-- a nation that holds any territory is then floored at ManpowerNationFloor. country.manpower regens toward it.
WorldConstants.ManpowerPopFraction = 0.02 -- manpower cap contribution = 2% of province population (was 0.15)
WorldConstants.ManpowerNationFloor = 5000 -- a nation with any owned+controlled land has a total cap of at least 5K
WorldConstants.ManpowerRegenPerDay = 0.003 -- fraction of cap regenerated per in-game day (~11 months to full)
WorldConstants.AttritionTickInterval = 6

-- Phase 3 peace conference (gated by EnablePeaceConference): per-demand war-score costs.
WorldConstants.PeaceTakeProvinceCost = 12 -- base cost to demand one province
WorldConstants.PeaceCoreMultiplier = 1.5 -- x cost when the province is a CORE of the loser (homeland)
WorldConstants.PeaceClaimCostDiscount = 0.7 -- x cost when the demander holds a CLAIM on the province

return WorldConstants
