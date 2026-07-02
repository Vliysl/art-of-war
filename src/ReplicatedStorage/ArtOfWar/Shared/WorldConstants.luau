local WorldConstants = {}

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
WorldConstants.EnableFullAnnex = true         -- Phase 1: full-annex peace term + defeated-country deletion + zombie cleanup
WorldConstants.EnableCores = false            -- Phase 2: cores suppress unrest / non-core unrest pressure
WorldConstants.EnablePeaceConference = false  -- Phase 3: war-score peace conference
WorldConstants.EnableFormables = true         -- Phase 4: formable nations (Iberia is the first; no releasable defs yet)
WorldConstants.EnableRebellions = false       -- Phase 4: rebellions flip provinces
WorldConstants.EnableNewEditor = false        -- Phase 5: reserved. Both editors currently run (legacy=backtick, new=backslash)

-- Feature kill-switches for the combat update (2026-07). Same pattern: each gates one phase's new
-- behavior; flip false to restore the old behavior without a code revert. A flag stays false until
-- its phase's code lands on this branch.
WorldConstants.EnableAnnexArmyDisband = true      -- C1: full annexation disbands the loser's armies + fleets
WorldConstants.EnableStrictRetreat = true         -- C1: retreat = adjacent allied/controlled LAND tile w/o battle or at-war army; none -> destroyed (encirclement)
WorldConstants.EnableInstantCapture = true        -- C2: entering an undefended enemy tile flips it instantly (siege progress off)
WorldConstants.EnableOccupationFreeze = true      -- C2: enemy occupation cancels recruitment (refunded) + pauses construction
WorldConstants.EnableAdjacentEngagement = true    -- C3: attackers fight from their own tile; march in only on victory
WorldConstants.EnableBattleDisc = true            -- C4: border battle disc (SurfaceGui 1-100) replaces the billboard battle bar
WorldConstants.EnableNewInputScheme = true        -- C5: LMB select/move, RMB pan/inspect (MMB pan kept)
WorldConstants.EnableMultiProvinceActions = true  -- C6: ctrl/shift multi-province selection + batched recruit/build remotes
WorldConstants.EnableNewUnitModels = true         -- C8: cavalry/dragoon horse model (+ C9 ship model at sea)
WorldConstants.EnableSeaTransport = false         -- C9: armies path over sea tiles (embark/sail/disembark, sea battles)

-- C2 instant-capture tunables: the walk-in cost. Forts no longer slow capture -- they bleed
-- the captor harder instead (per-tier casualty scaling).
WorldConstants.InstantCaptureCasualtyFrac = 0.02
WorldConstants.InstantCaptureCasualtyPerFortTier = 0.01
WorldConstants.InstantCaptureOrgLoss = 1.0
WorldConstants.OccupiedToastWindowSec = 10

-- C3: a beaten attacker stands down at home instead of retreating; AutoCapture waits this many
-- sim-seconds before re-attacking after such a loss.
WorldConstants.FailedAttackCooldownSec = 20

-- C4: world-space battle disc on the border between the attacker origin and the defended tile.
WorldConstants.BattleDiscDiameter = 4

-- C9 sea-transport tunables. Step costs ARE the embark mechanic: land->land keeps the 7-tick
-- week, open water sails fast, and the land<->sea transition is the slow, vulnerable window.
-- Transports fight poorly at sea; amphibious assaults attack ashore weakened.
WorldConstants.SeaMoveTicksPerStep = 4
WorldConstants.EmbarkMoveTicks = 10
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

WorldConstants.MultiplierCapEconomy = 10
WorldConstants.MultiplierCapCombatStat = 2
WorldConstants.MultiplierCapTechPerBranch = 3
WorldConstants.MultiplierCapArtillerySubStat = 2

WorldConstants.EntrenchedDefense = 1.5
WorldConstants.TrainingTierStep = 1.1
WorldConstants.TerrainSpecializationFlat = 1.2
WorldConstants.ArtillerySplashPerTick = 0.02

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

WorldConstants.PoliticalPowerCap = 200
WorldConstants.PoliticalPowerTickInterval = 6
WorldConstants.PoliticalPowerBasePerTick = 1.0

WorldConstants.TransitionStabilityPenalty = -0.10
WorldConstants.TransitionUnrestPenalty = 0.05
WorldConstants.TransitionPpGenerationPenalty = 0.5
WorldConstants.TransitionLegitimacyHit = 25
WorldConstants.TransitionLegitimacyRecoveryYears = 2
WorldConstants.TransitionCancelRefund = 0.5
WorldConstants.TransitionPolicyRepealStabilityHit = 0.05
WorldConstants.TransitionPolicyRepealStabilityCap = 0.20
WorldConstants.TransitionLawCancelRefund = 0.5

WorldConstants.RevolutionLegitimacyFloor = 30
WorldConstants.RevolutionTreasuryHit = 0.30
WorldConstants.RevolutionManpowerHit = 0.20

WorldConstants.LegitimacyMin = 0
WorldConstants.LegitimacyMax = 100
WorldConstants.StabilityMin = -3
WorldConstants.StabilityMax = 3

WorldConstants.YearsPerRealSecond = 0.05

WorldConstants.LawPhaseDurationDays = 100
WorldConstants.LawPhases = 3
WorldConstants.LawSetbackLimit = 3
WorldConstants.LawCooldownDays = 730
WorldConstants.LawCancelRefund = 0.40
WorldConstants.LawBaseSuccessChance = 0.50
WorldConstants.LawBaseStallChance = 0.30
WorldConstants.LawBaseSetbackChance = 0.20
WorldConstants.LawIdeologyPowerShiftMax = 0.20
WorldConstants.LawFactionInfluenceMax = 0.20

WorldConstants.LeaderAppointmentCost = 40
WorldConstants.LeaderDismissalCost = 30
WorldConstants.LeaderCandidatesPerSlot = 3
WorldConstants.LeaderTraitMinimum = 2
WorldConstants.LeaderTraitMaximum = 4
WorldConstants.LeaderPortraitPoolSize = 100

WorldConstants.FactionCloutMin = 0.01
WorldConstants.FactionCloutMax = 0.90
WorldConstants.FactionTierMarginalized = 0.04
WorldConstants.FactionTierInfluential = 0.20
WorldConstants.FactionDriftPerTick = 0.004
WorldConstants.FactionTickInterval = 6
WorldConstants.LegitimacyBase = 50
WorldConstants.LegitimacyAlignmentScale = 100

-- Politics overhaul ("Authority & the Estates")
WorldConstants.CrownAuthorityBase = 50          -- starting Authority for seeded countries
WorldConstants.CrownAuthorityCapBase = 100      -- max Authority before privileges lower it
WorldConstants.CrownAuthorityCapMin = 20        -- floor for the cap no matter how many privileges
WorldConstants.CrownAuthorityMin = 0
WorldConstants.CrownAuthorityRegenPerTick = 0.5 -- passive drift toward the cap
WorldConstants.EstateLoyaltyBase = 50
WorldConstants.EstateLoyaltyMin = 0
WorldConstants.EstateLoyaltyMax = 100
WorldConstants.EstateLoyaltyDriftPerTick = 0.4  -- drift toward target loyalty
WorldConstants.EstateSeizeAuthorityGain = 12    -- Authority gained by seizing power from an estate
WorldConstants.EstateSeizeLoyaltyHit = 15       -- loyalty lost by the seized-from estate
WorldConstants.EstateSeizeInfluenceShift = 0.03 -- clout removed from the seized-from estate
WorldConstants.EstateDemandLoyaltyThreshold = 40 -- below this an estate may issue a demand event
WorldConstants.UnrestMin = 0
WorldConstants.UnrestMax = 100
-- Unrest model (UnrestSystem): unrest drifts toward target = pressure - relief
WorldConstants.UnrestTickInterval = 6
WorldConstants.UnrestDriftPerTick = 0.15
WorldConstants.UnrestEstateLoyaltyPivot = 50    -- estate loyalty below this adds pressure
WorldConstants.UnrestEstateCloutWeight = 120    -- disloyalty(0..1) * clout(share) * weight
WorldConstants.UnrestLegitimacyPivot = 50
WorldConstants.UnrestLegitimacyWeight = 20      -- * max(0,(pivot-legit)/pivot)
WorldConstants.UnrestStabilityWeight = 6        -- * stability points below 0
WorldConstants.UnrestWarExhaustionWeight = 15   -- * war exhaustion (0..1)
WorldConstants.UnrestActiveTransitionFlat = 8   -- flat pressure while mid-transition (over-reform)
WorldConstants.UnrestBaseDecay = 10             -- baseline relief; a content realm trends to 0
WorldConstants.UnrestGoodGovReliefWeight = 15   -- * max(0,(legit-pivot)/pivot)
WorldConstants.UnrestStabilityReliefWeight = 5  -- * stability points above 0
WorldConstants.UnrestAuthorityReliefWeight = 12 -- * Crown Authority (0..1 of cap)
WorldConstants.UnrestRebellionThreshold = 70    -- crossing up publishes RebellionTriggered
WorldConstants.RebellionCooldownDays = 365      -- after a rebellion ends, no new trigger for a year
WorldConstants.EventTickInterval = 5            -- seconds between EventSystem ticks
WorldConstants.EventAmbientCheckDays = 120      -- min in-game days between ambient event checks per country
WorldConstants.EventAmbientChance = 0.35        -- chance an ambient check fires a random opportunity
-- Leadership & Succession (RulerSystem)
WorldConstants.SuccessionTickInterval = 6        -- scheduler cadence (s); aging is year-gated inside
WorldConstants.RulerStartAgeMin = 28
WorldConstants.RulerStartAgeMax = 55
WorldConstants.RulerDeathFloorAge = 45           -- below this, only the base death chance
WorldConstants.RulerDeathBaseChance = 0.01       -- per-year baseline
WorldConstants.RulerDeathChancePerYear = 0.012   -- +1.2%/yr over the floor age
WorldConstants.RulerDeathMaxChance = 0.55        -- cap at extreme age
WorldConstants.RulerOldAgeExtraChance = 0.10     -- surcharge if ruler has the "old_age" trait
WorldConstants.RulerRegencyAge = 16              -- heir below this rules under a regent
WorldConstants.RulerTermLengthDays = 360 * 6     -- republican_term length (~6 years)
WorldConstants.SuccessionCandidates = 3          -- elective/term/tribal candidate pool size
WorldConstants.HeirClaimLegitimacyDivisor = 5    -- legitimacy swing on accession = (claim-50)/this
WorldConstants.SuccessionDisputeLegitimacyFloor = 35
WorldConstants.SuccessionDisputeClaimFloor = 40
WorldConstants.SuccessionDisputeLegitimacyHit = 10
WorldConstants.SuccessionDisputeStabilityHit = 1

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
WorldConstants.FieldColliderTopY = 0.3       -- new map land top = 0.25; flat field-floor sits just above (was 6 @ 18665)
WorldConstants.FieldColliderThickness = 1
WorldConstants.FieldSpawnHeight = 5          -- spawn just above the field floor (was 45)
WorldConstants.FieldWalkSpeed = 16           -- characters no longer 6x-scaled; Roblox-default feel on the 2048 map (was 140)
WorldConstants.FieldSprintSpeed = 32         -- was 600
WorldConstants.FieldJumpHeight = 7.2         -- Roblox default (was 12)
WorldConstants.FieldBodyScale = 1            -- characters no longer resized (was 6)
WorldConstants.FieldHeadScale = 1            -- was 5
WorldConstants.CommandPerchHeight = 100000   -- off-screen avatar park in command mode; scale-independent

-- Economy (province-driven income engine)
WorldConstants.TaxIncomePerThousand = 0.05 -- gold per day per 1000 population per devTier
WorldConstants.ResourceInfraScalePerTier = 0.1 -- 10pct resource production per infrastructure tier
WorldConstants.DevTierMax = 10
WorldConstants.InfraTierMax = 10
WorldConstants.FortTierMax = 10
WorldConstants.DaysPerMonth = 30 -- monthly /mo projection scale
WorldConstants.UnrestTaxPenaltyPerPoint = 0.005 -- tax penalty per unrest point: -0.5% each (-50% at max unrest, caps at -100%)
WorldConstants.AutonomyAffectsTax = true -- multiplies (1 - autonomy)
WorldConstants.ManufactoryInfraScalePerTier = 0.05 -- +5pct manufactory throughput per infra tier above min
WorldConstants.ArmyUpkeepBaseMultiplier = 0.1 -- daily upkeep cost multiplier on unit upkeep stat
WorldConstants.ManufactoryDailyCycles = 0.1 -- a manufactory completes 0.1 cycles per day baseline

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
WorldConstants.FortBattleDefensePerTier = 0.15
WorldConstants.FortCannonDebuff = 0.75 -- hook: cannon-tech fort debuff (gated off)
-- Post-battle morale modifiers (spec G.1.7), applied by BattleManager.
WorldConstants.BattleVictorMoraleBonus = 0.10
WorldConstants.BattleLoserMoralePenalty = 0.20
WorldConstants.BattleMoraleModifierMonths = 6
-- Deterministic seed base for officer generation / trait picks.
WorldConstants.OfficerRngSeed = 13337
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
-- Each owned+controlled province contributes max(floor(population * ManpowerPopFraction),
-- ManpowerProvinceFloor) to country.manpowerCap; country.manpower regens continuously toward it.
WorldConstants.ManpowerPopFraction = 0.15 -- manpower cap contribution = 15% of province population
WorldConstants.ManpowerProvinceFloor = 5000 -- ...but at least 5K per owned+controlled province
WorldConstants.ManpowerRegenPerDay = 0.003 -- fraction of cap regenerated per in-game day (~11 months to full)
WorldConstants.AttritionTickInterval = 6

-- Diplomacy
WorldConstants.TrucePeriodDays = 1825
WorldConstants.PeaceProposalLifetimeSeconds = 600
WorldConstants.DiplomacyTickInterval = 6

-- Opinion / relations (Phase 1). Per-direction value on country.opinion[otherTag].
WorldConstants.OpinionMin = -200
WorldConstants.OpinionMax = 200
WorldConstants.OpinionImproveStep = 25 -- both-ways bump per Improve Relations
WorldConstants.OpinionImproveCost = 25 -- political power spent per Improve Relations
WorldConstants.OpinionImproveCooldownDays = 30 -- per-target cooldown
WorldConstants.OpinionWarPenalty = 50 -- both-ways drop on a war declaration
WorldConstants.OpinionFriendBase = 50 -- baseline toward a historical friend
WorldConstants.OpinionRivalBase = -50 -- baseline toward a historical rival
WorldConstants.OpinionDecayPerMonth = 3 -- drift toward baseline each month

-- Pacts (Phase 2): NAP offers (bilateral, offer->accept) + Guarantee independence (instant)
WorldConstants.PactOfferLifetimeSeconds = 600 -- pending NAP offer TTL before auto-expire
WorldConstants.NapDurationDays = 3650 -- active NAP length (~10 years)
WorldConstants.NapAcceptOpinionBonus = 15 -- both-ways on signing a NAP
WorldConstants.NapBreakOpinionPenalty = 40 -- both-ways for breaking a NAP early (betrayal)
WorldConstants.NapAcceptThreshold = 0 -- AI signs a NAP when opinion >= this
WorldConstants.GuaranteeOpinionBonus = 15 -- both-ways when a guarantee is issued
WorldConstants.GuaranteeRevokeOpinionPenalty = 15 -- protected->guarantor when a guarantee is revoked

-- Alliances + call-to-arms (Phase 3). Alliances reuse the pacts pipeline; call-to-arms drags a
-- defender's allies/guarantors into linked co-belligerent wars.
WorldConstants.AllianceOpinionBonus = 25 -- both-ways on forming an alliance
WorldConstants.AllianceBreakPenalty = 60 -- both-ways for breaking an alliance
WorldConstants.AllianceAcceptThreshold = 50 -- AI accepts an alliance only at opinion >= this
WorldConstants.CallToArmsDeclinePenalty = 75 -- both-ways for refusing a called ally's war (betrayal)

-- =====================================================================
-- SIEGES (spec G.2, Phase 5) - see Systems.SiegeSystem.
-- siegeProgress += SiegeBaseSpeed * armySizeFactor * (1 - fortDefenseMod) toward
-- OccupationProgressRequired; forts slow the siege AND bleed the besieger (attrition).
-- =====================================================================
WorldConstants.SiegeBaseSpeed = 1.0 -- progress per round at reference army size, no fort
WorldConstants.SiegeArmySizeRef = 8 -- regiments giving sizeFactor 1.0
WorldConstants.SiegeMinSizeFactor = 0.5 -- clamp: tiny besieging force
WorldConstants.SiegeMaxSizeFactor = 1.5 -- clamp: large force can't trivialise walls
WorldConstants.FortSiegeDefensePerTier = 0.15 -- each fort tier slows siege by this (pre-cap)
WorldConstants.SiegeFortMaxReduction = 0.85 -- max siege slowdown from forts
WorldConstants.SiegeAttritionPerRound = 0.01 -- besieger loses this regiment-fraction / round
WorldConstants.SiegeAttritionFortScale = 0.004 -- extra besieger attrition per fort tier
WorldConstants.OccupationOutputPenalty = 0.20 -- occupied province yields 20pct (hook for economy)

-- =====================================================================
-- WAR SCORE / EXHAUSTION / PEACE (spec B.9 / G.4-G.5, Phase 5).
-- war.score is ATTACKER POV (-100..+100): attacker gains push it +, defender gains -.
-- DiplomacySystem accrues from BattleResolved / ProvinceOccupied / NavalBattleResolved
-- and gates AI peace acceptance on score vs term cost (+ exhaustion willingness).
-- =====================================================================
WorldConstants.WarScoreMax = 100
WorldConstants.WarScoreBattleWin = 5 -- field-battle victory
WorldConstants.WarScoreNavalWin = 8 -- naval-battle victory (sink fleet)
WorldConstants.WarScoreOccupyProvince = 8 -- fully occupy an enemy province
WorldConstants.WarScoreForcedPeace = 100 -- at +/-100, war auto-ends in winner's favour
WorldConstants.WarExhaustionMonthlyBase = 0.05 -- both sides gain this per month at war
WorldConstants.WarExhaustionPerBattleLost = 0.5 -- loser of a battle gains this
WorldConstants.WarExhaustionPerProvinceLost = 1.0 -- losing a province to occupation
WorldConstants.WarExhaustionMax = 100
WorldConstants.WarStalemateYears = 5 -- mandatory white peace after this many years
-- Peace term war-score costs (paid by the side GAINING from the term):
WorldConstants.PeaceWhitePeaceCost = 0 -- revert occupations: free
WorldConstants.PeaceAnnexBaseCost = 20 -- annex occupied: base war-score cost
WorldConstants.PeaceAnnexPerProvinceCost = 10 -- + per annexed province
WorldConstants.PeaceAIExhaustionWeight = 0.5 -- each exhaustion point adds this to willingness
WorldConstants.PeaceAIAcceptMargin = 0 -- accept when willingness - cost >= this
WorldConstants.PeaceVassalizeCost = 90 -- vassalize peace term: very high war-score cost (AI only when crushed)
-- Phase 3 peace conference (gated by EnablePeaceConference): per-demand war-score costs.
WorldConstants.PeaceTakeProvinceCost = 12   -- base cost to demand one province
WorldConstants.PeaceCoreMultiplier = 1.5    -- x cost when the province is a CORE of the loser (homeland)
WorldConstants.PeaceClaimCostDiscount = 0.7 -- x cost when the demander holds a CLAIM on the province
WorldConstants.ReleaseSubjectOpinionBonus = 30 -- a freed subject's opinion of its former overlord

-- =====================================================================
-- ATTRITION (spec B.10 / 6.9, Phase 5) - see Systems.AttritionSystem.
-- Monthly: provinces with stacked armies over supply bleed manpower (crowding);
-- low-supply terrain adds a base rate. Wasteland slows movement (hook).
-- =====================================================================
WorldConstants.ProvinceSupplyLimitBase = 5000 -- strength a province supports for free
WorldConstants.ProvinceSupplyLimitPerDev = 500 -- + per devTier
WorldConstants.AttritionCrowdingRate = 0.05 -- monthly loss-frac per 1x supply overflow
WorldConstants.AttritionTerrainScale = 0.02 -- low-supply terrain attrition scale
WorldConstants.AttritionMaxPerMonth = 0.10 -- cap monthly attrition fraction
WorldConstants.AttritionTerrainFreeSupply = 8 -- terrain supplyLimit at/above which terrain attrition is 0
WorldConstants.AttritionFrostRate = 0.03 -- hook: extra attrition in winter provinces (no season system yet)
WorldConstants.WastelandMovementSlowdown = 0.5 -- hook: wasteland province speed x this

return WorldConstants
