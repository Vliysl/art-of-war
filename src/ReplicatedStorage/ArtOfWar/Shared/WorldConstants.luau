local WorldConstants = {}

WorldConstants.MapWidth = 18665
WorldConstants.MapDepth = 7518
WorldConstants.MapHalfWidth = WorldConstants.MapWidth * 0.5
WorldConstants.MapHalfDepth = WorldConstants.MapDepth * 0.5
WorldConstants.MapCenterX = -27.0
WorldConstants.MapCenterZ = 67.8

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

WorldConstants.AdjacencyThreshold = 300
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
WorldConstants.NavalBuildTickInterval = 3
WorldConstants.BuildingTickInterval = 3
WorldConstants.NavalMovementSpeed = 120
WorldConstants.NavalTravelMinSeconds = 10
WorldConstants.NavalTravelMaxSeconds = 90
WorldConstants.ShipyardInfraRequirement = 2
WorldConstants.FleetRecruitMaxPerCall = 5

WorldConstants.MapModeField = "field"
WorldConstants.MapModeCommand = "command"
WorldConstants.MapModeDefault = "command"
WorldConstants.FieldColliderTopY = 6
WorldConstants.FieldColliderThickness = 4
WorldConstants.FieldSpawnHeight = 45
WorldConstants.FieldWalkSpeed = 140
WorldConstants.FieldSprintSpeed = 600
WorldConstants.FieldJumpHeight = 12
WorldConstants.FieldBodyScale = 6
WorldConstants.FieldHeadScale = 5
WorldConstants.CommandPerchHeight = 100000

-- Economy (province-driven income engine)
WorldConstants.TaxIncomePerThousand = 0.05      -- gold per day per 1000 population per devTier
WorldConstants.ResourceInfraScalePerTier = 0.1  -- 10pct resource production per infrastructure tier
WorldConstants.DevTierMax = 10
WorldConstants.InfraTierMax = 10
WorldConstants.DaysPerMonth = 30                -- monthly /mo projection scale
WorldConstants.UnrestTaxPenaltyPerPoint = 0.05      -- -5pct tax per unrest point (caps at 0)
WorldConstants.AutonomyAffectsTax = true             -- multiplies (1 - autonomy)
WorldConstants.ManufactoryInfraScalePerTier = 0.05   -- +5pct manufactory throughput per infra tier above min
WorldConstants.ArmyUpkeepBaseMultiplier = 0.1        -- daily upkeep cost multiplier on unit upkeep stat
WorldConstants.ManufactoryDailyCycles = 0.1          -- a manufactory completes 0.1 cycles per day baseline

-- HOI4-style combat additions
WorldConstants.CombatFlankingWidthPerExtraProvince = 30
WorldConstants.CombatFlankingMaxExtraOrigins = 3
WorldConstants.CombatTerrainDefaultWidth = 60
WorldConstants.CombatTerrainMinWidth = 30
WorldConstants.CombatEntrenchmentMax = 5
WorldConstants.CombatEntrenchmentDailyGain = 0.25
WorldConstants.CombatEntrenchmentDefensePerLevel = 0.02
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
WorldConstants.CombatDamageScale = 10            -- net damage -> strength casualties
WorldConstants.CombatDefenderCounterHi = 0.6
WorldConstants.CombatDefenderCounterLo = 0.3
WorldConstants.CombatRoundCasualtyCap = 0.20     -- max fraction of a side lost per round
-- Resolution by ROUT (morale/org), not strength attrition:
WorldConstants.CombatMoraleRoutFloor = 30        -- a formation routs at/below this morale
WorldConstants.CombatRoutFraction = 0.5          -- side breaks when >= this strength-frac routed
WorldConstants.CombatOrgBreakRatio = 0.15        -- or aggregate org ratio below this
WorldConstants.CombatMoraleRoundBase = 1         -- morale lost per round under fire
WorldConstants.CombatMoraleCasualtyScale = 140   -- extra morale lost scaled by casualty ratio
WorldConstants.CombatOrgRoundBase = 0            -- org lost per round (0 = casualty-driven only)
WorldConstants.CombatOrgCasualtyScale = 12       -- org lost scaled by casualty ratio
-- Discipline per unit class (folds into offense/defense); data wired Phase 2/4.
WorldConstants.DisciplineLevy = 0.6
WorldConstants.DisciplineStandard = 1.0
WorldConstants.DisciplineElite = 1.4
-- Forts in field battle: defender defense x (1 + fortTier*FortBattleDefensePerTier).
WorldConstants.FortBattleDefensePerTier = 0.15
WorldConstants.FortCannonDebuff = 0.75           -- hook: cannon-tech fort debuff (gated off)
-- Post-battle morale modifiers (spec G.1.7), applied by BattleManager.
WorldConstants.BattleVictorMoraleBonus = 0.10
WorldConstants.BattleLoserMoralePenalty = 0.20
WorldConstants.BattleMoraleModifierMonths = 6
-- Deterministic seed base for officer generation / trait picks.
WorldConstants.OfficerRngSeed = 13337
-- Naval role-matched rounds (Phase 3).
WorldConstants.NavalCombatWidth = 40
WorldConstants.NavalDamageScale = 2          -- per-round naval casualty scale (lower than land; hull pools are large)
WorldConstants.NavalOrgRegenPerTick = 0.5    -- fleet organization regen while docked (mirrors ArmyOrganizationRegenPerTick)
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
WorldConstants.LevyManpowerPerBaseMP = 250    -- province levy cap = baseManpower * this * mods
WorldConstants.LevyDevFactorPerTier = 0.10    -- devFactor = 1 + (devTier-1)*this
WorldConstants.LevyForeignCultureMod = 0.5    -- province culture not primary/accepted -> levy x this
WorldConstants.LevyAutonomyMaxReduction = 1.0 -- levy x (1 - autonomy*this) (autonomy 0..1)
WorldConstants.LevyConscriptionDefault = 1.0  -- HOOK: conscription-law multiplier (Politics out of scope)
WorldConstants.LevyRegenPerMonthPct = 0.05    -- levy pool regens 5%/mo of cap (peacetime)
WorldConstants.ProfessionalRegenPerMonthPct = 0 -- HOOK: pro regen (laws/barracks out of scope; 0 = legacy static)
WorldConstants.ManpowerRegenTickInterval = 6  -- scheduler cadence (effective s); actual regen is month-gated

-- Diplomacy
WorldConstants.TrucePeriodDays = 1825
WorldConstants.PeaceProposalLifetimeSeconds = 600
WorldConstants.DiplomacyTickInterval = 6


-- =====================================================================
-- SIEGES (spec G.2, Phase 5) - see Systems.SiegeSystem.
-- siegeProgress += SiegeBaseSpeed * armySizeFactor * (1 - fortDefenseMod) toward
-- OccupationProgressRequired; forts slow the siege AND bleed the besieger (attrition).
-- =====================================================================
WorldConstants.SiegeBaseSpeed = 1.0              -- progress per round at reference army size, no fort
WorldConstants.SiegeArmySizeRef = 8              -- regiments giving sizeFactor 1.0
WorldConstants.SiegeMinSizeFactor = 0.5          -- clamp: tiny besieging force
WorldConstants.SiegeMaxSizeFactor = 1.5          -- clamp: large force can't trivialise walls
WorldConstants.FortSiegeDefensePerTier = 0.15    -- each fort tier slows siege by this (pre-cap)
WorldConstants.SiegeFortMaxReduction = 0.85      -- max siege slowdown from forts
WorldConstants.SiegeAttritionPerRound = 0.01     -- besieger loses this regiment-fraction / round
WorldConstants.SiegeAttritionFortScale = 0.004   -- extra besieger attrition per fort tier
WorldConstants.OccupationOutputPenalty = 0.20    -- occupied province yields 20pct (hook for economy)

-- =====================================================================
-- WAR SCORE / EXHAUSTION / PEACE (spec B.9 / G.4-G.5, Phase 5).
-- war.score is ATTACKER POV (-100..+100): attacker gains push it +, defender gains -.
-- DiplomacySystem accrues from BattleResolved / ProvinceOccupied / NavalBattleResolved
-- and gates AI peace acceptance on score vs term cost (+ exhaustion willingness).
-- =====================================================================
WorldConstants.WarScoreMax = 100
WorldConstants.WarScoreBattleWin = 5             -- field-battle victory
WorldConstants.WarScoreNavalWin = 8             -- naval-battle victory (sink fleet)
WorldConstants.WarScoreOccupyProvince = 8        -- fully occupy an enemy province
WorldConstants.WarScoreForcedPeace = 100         -- at +/-100, war auto-ends in winner's favour
WorldConstants.WarExhaustionMonthlyBase = 0.05   -- both sides gain this per month at war
WorldConstants.WarExhaustionPerBattleLost = 0.5  -- loser of a battle gains this
WorldConstants.WarExhaustionPerProvinceLost = 1.0-- losing a province to occupation
WorldConstants.WarExhaustionMax = 100
WorldConstants.WarStalemateYears = 5             -- mandatory white peace after this many years
-- Peace term war-score costs (paid by the side GAINING from the term):
WorldConstants.PeaceWhitePeaceCost = 0           -- revert occupations: free
WorldConstants.PeaceAnnexBaseCost = 20           -- annex occupied: base war-score cost
WorldConstants.PeaceAnnexPerProvinceCost = 10    -- + per annexed province
WorldConstants.PeaceAIExhaustionWeight = 0.5     -- each exhaustion point adds this to willingness
WorldConstants.PeaceAIAcceptMargin = 0           -- accept when willingness - cost >= this

-- =====================================================================
-- ATTRITION (spec B.10 / 6.9, Phase 5) - see Systems.AttritionSystem.
-- Monthly: provinces with stacked armies over supply bleed manpower (crowding);
-- low-supply terrain adds a base rate. Wasteland slows movement (hook).
-- =====================================================================
WorldConstants.ProvinceSupplyLimitBase = 5000    -- strength a province supports for free
WorldConstants.ProvinceSupplyLimitPerDev = 500   -- + per devTier
WorldConstants.AttritionCrowdingRate = 0.05      -- monthly loss-frac per 1x supply overflow
WorldConstants.AttritionTerrainScale = 0.02      -- low-supply terrain attrition scale
WorldConstants.AttritionMaxPerMonth = 0.10       -- cap monthly attrition fraction
WorldConstants.AttritionTerrainFreeSupply = 8    -- terrain supplyLimit at/above which terrain attrition is 0
WorldConstants.AttritionFrostRate = 0.03         -- hook: extra attrition in winter provinces (no season system yet)
WorldConstants.WastelandMovementSlowdown = 0.5   -- hook: wasteland province speed x this

return WorldConstants
