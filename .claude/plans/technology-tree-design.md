# Technology Tree — Design & Implementation Plan

Status: **DESIGN / APPROVED-DIRECTION**. Author: tech-tree rework. Supersedes the cut flat-list research system and the `Data/Technologies.luau` single-level DAG.

This document is the authoritative spec for the new Hearts-of-Iron-4-style, left-to-right, interactive, **leveled** technology tree. It leaves nothing to interpretation: every schema field, cap, wiring point, and phase is specified. Where a number is a balance placeholder it is marked `(tunable)`.

---

## 0. Locked design decisions

From the two clarification rounds with the design owner:

1. **Scope** — Full Tech.txt scope, including the modern pillars (Airforce, Tanks, Anti-Air, Missiles, Nuclear/ICBM). These modern pillars are **entirely net-new subsystems** (no backing code exists today) and are delivered in **later phases**.
2. **Research interaction** — **Multiple parallel research slots** (full HOI4). Each slot researches one node-level over time.
3. **Existing 146 historical techs** — **Converted into the new leveled format** (one unified tree), preserving their names/flavour.
4. **Era model** — Historical content carries real **era labels 1600–1900** (drives left→right layout + starting distribution). Modern branches are **prerequisite-gated, not year-dated** — they live in their own advanced tabs and open only when their prerequisite trees are complete (e.g. the Nuclear tree opens after ballistic missiles are fully researched).
5. **Authoring** — Techs are authored in the **data file** (`Data/Technologies.luau`) via a clean declarative schema. The tree UI **auto-builds and auto-connects** prerequisite lines from that data. No in-game Data-Editor integration in this scope (may be a later phase).
6. **Research Power** — **Flat base per slot**, modified by research-efficiency / research-power-gain tech multipliers and policy. Not economy-derived in this scope.
7. **Sequencing** — **Phased.** Framework + all branches that buff **existing** systems first; net-new subsystems staged after.
8. **Effect caps** — Multiplicative, on top of existing multipliers, per Tech.txt. The reserved-but-unused constants `MultiplierCapTechPerBranch = 3` and `MultiplierCapArtillerySubStat = 2` (`WorldConstantsServer.luau:26-28`) were pre-provisioned for exactly this and are now consumed.

---

## 1. Current-state ground truth (why this is mostly greenfield)

Established by a full-codebase recon. Key facts the design depends on:

- **`ResearchSystem.luau` (204 lines)** — one active tech at a time; each in-game day adds a flat rate into `country.research.progress[active]` until `>= def.cost`, then marks `country.techs[id]=true`. Techs are **boolean, single-level**. `year` is display-only (no era gating). Points source `ResearchPointsPerDay` is **undefined** → silent fallback of 1/day.
- **All tech effects are INERT.** `aggregateModifier` sums `effects.modifiers[key]` additively and uncapped, but the only consumer is `research_speed` (feeding its own accrual). `ResearchSystem.modifierTotal(tag,key)` / `hasTech(tag,id)` have **zero external callers** — no combat/economy/political system reads tech modifiers, and `effects.unlocks` (unit/building ids) is read by nothing.
- **UI is a 33-line "Coming Soon" stub** (`ResearchScreen.luau`). No tree/canvas/pan/zoom exists. `WorldConstants.EnableResearch = false` gates the whole path off. `Channels.TechCompleted` is published but **not defined** (dead no-op).
- **State already replicates.** `country.techs` / `country.research` live on the country record and broadcast to all clients (not in `StateReplicator` `COUNTRY_DROP`). Runtime state is **not persisted** to a DataStore — the world re-seeds each boot.
- **`technologyGroup`** (western/eastern/nomad/…) exists per country but is **vestigial** for research — the perfect lever for era-based starting distribution.
- **Reserved caps already in code:** `MultiplierCapCombatStat=2`, `MultiplierCapTechPerBranch=3`, `MultiplierCapArtillerySubStat=2` (`WorldConstantsServer.luau`), `GeneralCombatBonusCap=1.30` (`WorldConstants.luau:104`, already equals the requested +30% military-leader cap).
- **`ModifierStack`** is the single 6-source fold point (ideology / government / policy / privilege / leader / doctrine) for combat + political domains. **Tech is not a source.** Adding a 7th (tech) source wires up most branches cheaply.
- **`armyTrainingTier` (0–5)** and **`terrainSpecializations`** are read by `BattleManager` but **written by nothing** — a Military-Training branch can drive them with zero new plumbing.
- **Name-mismatch trap (real, live):** `EconomySystem` reads `country_tax_income` / `country_production`, but data authors `tax_income` — so the authored value is inert. **Every new tech modifier key must exactly match the string its consumer reads.** A domain registry (§4.3) prevents this.
- **Net-new (no code):** aircraft, carriers/air-capacity, anti-air, missiles, silos, nuclear ICBMs, per-structure building HP, projectile-in-transit entities, a "military power" resource, "operations", city-integration timers, militia/garrison resistance. Also **movement speed is dead code** (`MovementSystem.beginMove` uses a fixed 7-tick cadence; `effectiveSpeed` is computed but unused) — **speed buffs do nothing until movement is rewired.**

---

## 2. Scope, pillars & phasing

### 2.1 The tree pillars (top-level tabs / left rail)

Reconciling Tech.txt, the reference image, and the era decision. Left-rail order top→bottom:

| # | Tab (left rail) | Era model | Backing today | Tech.txt source |
|---|---|---|---|---|
| 1 | **Infantry** | 1600–1900 dated | exists (buffs inert) | Military › Infantry |
| 2 | **Cavalry & Armor** | cavalry dated 1600–1900; **tanks prereq-gated modern** | cavalry exists; tanks net-new | Military › Cavalry/Tanks |
| 3 | **Artillery** | 1600–1900 dated | exists (buffs inert) | Military › Artillery |
| 4 | **Naval** | 1600–1900 dated; **carrier air-capacity prereq-gated** | fleets exist (no country mult); carriers net-new | Military › Navy |
| 5 | **Air & Missiles** | **prereq-gated modern** | 100% net-new | Military › Airforce / AA / Missiles |
| 6 | **Economy** | 1600–1900 dated | exists (buffs inert) | Economic Advancements |
| 7 | **Political** | 1600–1900 dated | partly exists (many domains inert) | Political Advancements |
| 8 | **Command** (Military Training) | 1600–1900 dated + modern ops | leaders/doctrines exist; military-power/operations net-new | Military › Military Training |
| 9 | **Research** | 1600–1900 dated; **Nuclear Research sub-branch prereq-gated** | exists (only research_speed live) | Research Tree + Nuclear catalysts |

> The Nuclear **weapon** branch is a sub-tree of **Air & Missiles**, gated behind (a) ballistic missiles fully researched **and** (b) the four Nuclear Research catalysts in the **Research** tab (Isotope Research, Fission, Uranium Enrichment, Silos), exactly per Tech.txt.

Tab taxonomy is adjustable — it is data (`tab` field), so re-grouping is a data edit, not a code change.

### 2.2 Phase roadmap

**Phase 1 — Framework + existing-system branches (this deliverable's core).**
- New leveled tech data schema (§3) + convert the 146 historical techs + author the full buff-branch content for tabs 1,3,4(historical),6,7,8(historical),9(minus nuclear weapons).
- Multi-slot research backend rework (§5).
- Capped multiplicative **effect-application layer** (§4) + wiring into combat (land per-class), artillery, naval, economy, political, military-training. This is where the tree finally *does something*.
- HOI4 tree UI (§6): pan/zoom canvas, left rail, leveled node cards, auto-connected orthogonal prerequisite lines, slot management, tooltips, touch.
- Re-enable research (`EnableTechTree` flag), private `OwnResearch` replication channel, era/tech-group starting distribution.

**Phase 2 — Movement + fortification + militia + integration (existing-adjacent net-new mechanics).**
- Rewire movement so **speed buffs matter** (`compositionSpeed` + `beginMove` duration).
- Fortification as a country modifier (`fort_defense` into `CapitalSystem`/`BattleManager.fortTierFor`).
- Militia / undefended-tile garrison resistance (`CombatSystem.captureIfUndefended`).
- City-integration timer mechanic (cores currently flip instantly) + `integration_speed` consumer.
- Wire the Political tab branches that need these mechanics.

**Phase 3 — Foundations for modern warfare.**
- **Per-structure building HP** (buildings have none today) — foundational for AA/silos/missile targets.
- **Projectile-in-transit entity framework** — foundational for missiles/nuclear.
- **Military Power** resource + generation tick + **Operations** system (Command tab's power-gain + operations spend).

**Phase 4 — Airforce.** Air units, air bases, carrier `aircraftCapacity`, air missions (CAS / interception / strategic bombing), sortie resolution. Wire the Air branch.

**Phase 5 — Anti-Air & Missiles.** AA buildings/units (damage-to-air, range, building HP, anti-ballistic interception); missile-system building; missiles as projectiles (damage-to-buildings, range, in-flight health, speed). Wire the AA + Missile branches.

**Phase 6 — Nuclear.** Uranium Enrichers + Silos (destroyable buildings), nuclear ICBMs (AOE splash to nearby cities, population damage, up-to-10× range, up-to-120% speed), MAD/diplomacy hooks. Wire the Nuclear sub-tree.

Each phase ships independently; the tree simply **locks** the branches whose systems aren't built yet (nodes render greyed with a "system coming soon" tooltip).

---

## 3. Data schema — the leveled tech node

Authored in `Data/Technologies.luau`. **Backward-compatible superset** of the current schema (existing fields keep their meaning; new fields are additive so partially-migrated data still loads).

```lua
["infantry_small_arms"] = {
    id = "infantry_small_arms",
    name = "Infantry Small Arms",
    tab = "infantry",              -- left-rail pillar (§2.1)
    branch = "firepower",          -- sub-group / row band within the tab (was `category`)
    era = 1700,                    -- era of LEVEL 1 (left→right x-axis). nil/omitted for prereq-gated modern nodes
    prerequisites = { "gunpowder_doctrine" },   -- tech ids (DAG edges; auto-drawn connector lines)
    icon = "InfantryRifle",        -- Icons.Ids key (optional; falls back to tab icon)
    banner = "rbxassetid://0",     -- NEW. optional image id shown as the chip's banner art. Accepts a bare
                                   -- numeric id or a full rbxassetid://; normalized via the existing normalizeFlag
                                   -- convention (DataEditor.luau:247). Empty/absent → generative branch-tinted banner.
    bannerByLevel = nil,           -- NEW optional { [n] = imageId } to swap the banner art as the tech levels up

    maxLevel = 5,                  -- NEW. 1 = one-shot unlock node. >1 = leveled upgrade
    -- Per-level cost. Either a list (explicit) or a base+growth formula.
    cost = { 120, 180, 260, 360, 500 },        -- length == maxLevel
    -- OR: cost = { base = 120, growth = 1.5 },  -- cost_n = base * growth^(n-1)

    -- Per-level ERA gate: level n unlocks only at/after eraByLevel[n] (defaults to `era` for all levels).
    eraByLevel = { 1700, 1750, 1841, 1866, 1888 },   -- optional; matches historical progression

    starting = false,              -- if true, LEVEL 1 is granted free at seed (see startingLevel)
    startingLevel = 0,             -- levels granted at seed (era/tech-group can raise this; §5.4)

    description = "…",             -- shown in node detail panel
    -- Per-level flavour + effect. effects[n] applies when the tech reaches level n.
    effects = {
        [1] = { summary = "Flintlock line infantry.", modifiers = { infantry_attack = 0.10 }, unlocks = { "line_infantry" } },
        [2] = { summary = "Percussion cap.",          modifiers = { infantry_attack = 0.12, infantry_defense = 0.08 } },
        [3] = { summary = "Rifled musket / Minié.",   modifiers = { infantry_attack = 0.15, infantry_range = 0.10 } },
        [4] = { summary = "Metallic cartridge breechloader.", modifiers = { infantry_attack = 0.18, infantry_reload = 0.15 } },
        [5] = { summary = "Bolt-action magazine rifle.", modifiers = { infantry_attack = 0.22, infantry_defense = 0.15 }, unlocks = { "modern_infantry" } },
    },

    gates = { "infantry_small_arms" },   -- boolean flag ids also set on completion (leader/doctrine researchGate compat)

    -- OPTIONAL layout overrides (auto-layout handles the common case; §6.4)
    x = nil, y = nil, order = nil,
    -- OPTIONAL unlock gating: this node is hidden/locked until the referenced trees are maxed
    unlockRequires = nil,          -- e.g. { branchMaxed = "missiles" } for the nuclear sub-tree
}
```

### 3.1 Effect accumulation semantics (multiplicative, capped)

- A stat's **tech factor** for a country = the product over that country's owned levels of `(1 + perLevelBonus)`, clamped to the branch cap:

  `techFactor(tag, stat) = clamp( Π over owned levels ( 1 + effects[n].modifiers[stat] ), 1, branchCap(stat) )`

- Applied **multiplicatively on top of existing multipliers**: `final = base × existingMultipliers × techFactor`. This is exactly Tech.txt's "multiplicative, not additive… capped at an additional Nx."
- **Authoring convention:** choose per-level bonuses so the product reaches the branch cap at `maxLevel`; the clamp is a hard safety net. (e.g. artillery cap = 2.0 → five levels of ≈ +0.149 give `1.149^5 ≈ 2.0`.)
- `unlocks` and `gates` fire at the level they are attached to. A `maxLevel = 1` node with a single `unlocks` entry behaves like the old discrete unlock tech.

### 3.2 Converting the 146 historical techs

Methodology (produces the Phase-1 content):

1. **Collapse historical chains into leveled branch nodes.** Each themed chain becomes one node whose levels are the chain's steps, era-gated to the original `year`s.
   - *Infantry firepower:* flintlock → percussion cap → rifled musket/Minié → metallic cartridge/breechloader → bolt-action ⇒ `infantry_small_arms` L1–5.
   - *Artillery:* smoothbore → standardized calibres → rifled → breech-loading → steel/quick-firing ⇒ `artillery_guns` L1–5.
   - *Naval hull:* frigate/SotL → copper sheathing → live oak → ironclad → steel hull/pre-dreadnought ⇒ `naval_hulls` L1–5, etc.
2. **Keep marquee unit unlocks as `maxLevel=1` unlock nodes** where a discrete ship/unit is the point (Ship of the Line, Ironclad, Frigate, Destroyer). Their `unlocks` gate recruitment once §4.4 lands.
3. **Preserve names & flavour** — the historical `name`/`description` text moves into the per-level `summary`.
4. **Re-key modifiers to the domain registry (§4.3)** so they are consumed, not inert.

Target Phase-1 node count: ~55–70 leveled nodes across the historical tabs (down from 146 discrete), plus the authored buff branches from Tech.txt.

---

## 4. Effect-application layer (the heart of Phase 1)

The single biggest gap: **researching anything currently changes zero gameplay numbers.** This layer fixes that with three coordinated pieces.

### 4.1 `TechEffects` resolver (new)

A thin server module (or an expansion of `ResearchSystem`) exposing:

- `TechEffects.factor(tag, stat)` → multiplicative tech factor for a stat, clamped to `branchCap(stat)` (§4.3). Pure function of `country.techs` + `country.techLevel`. **Deterministic** (no RNG, no time) — safe for combat.
- `TechEffects.additive(tag, domain)` → summed additive bonus for domains that feed `ModifierStack` (economy/political).
- `TechEffects.has(tag, id, level?)` → ownership / level check (unlock gating).

Backed by the existing `country.techs` set plus a new `country.techLevel[id]` map (§5). Caches per-country totals, invalidated on `TechCompleted`.

### 4.2 Wiring points (exact, per recon)

| Buff family | Where it hooks | Mechanism |
|---|---|---|
| **Infantry / Cavalry+Tank attack·defense** (per unit class, cap 3×) | `BattleManager.buildSideInput` unit loop (`:594-606`) | `role = CombatEngine.classifyRole(u,'ground')`; multiply copied `attack`/`defense` by `TechEffects.factor(ownerTag, role.."_attack")`. Keeps `CombatEngine` pure. |
| **Infantry / Cavalry+Tank speed** (cap 3×) | Phase 2: `ArmySystem.compositionSpeed` (`:86`) + consume `effectiveSpeed` in `MovementSystem.beginMove` (`:102`) | speed is dead code today; buff is authored now but marked "active in Phase 2". |
| **Artillery damage·range·speed** (cap 2×) | `BattleManager.buildSideInput` for the artillery role + `SiegeSystem` speed (`:100-104`) | `MultiplierCapArtillerySubStat = 2`. "range" reinterpreted as attack/siege bonus (no ranged mechanic exists — see §7). |
| **Naval** (nerfed RON-style, capped) | **new** fleet stat-multiplier in `NavalSystem.fleetSide` (`:107-122`) / `shipsToUnits` (`:79-104`) — currently applies **no** country multiplier | mirror `BattleManager.statMultiplier`; clamp under `MultiplierCapTechPerBranch`. |
| **Military-leader flat buffs** (cap +30%) | already exists: `commanderCombatMultiplier` capped at `GeneralCombatBonusCap = 1.30` | tech tunes trait rolls / training tier. |
| **Military training tiers** | `country.armyTrainingTier` / `terrainSpecializations` (read by `BattleManager`, written by nothing) | Command branch **sets these directly** → immediate combat effect, zero new plumbing. |
| **Economy** (tax split, build cost/speed, factory +100%, gov spend −30%, fuel +50%, mining +80%) | `EconomyPreview.taxOf`/`productionOf`, `DistrictSystem.districtCost`/`districtBuildDays`, `ManufactorySystem` output, `EconomySystem` expense sum | pass resolved per-country modifiers into the per-province loops; clamp with the specific caps. |
| **Political** (stability, PP gain +100%, policy eff +50%, unrest −80%, build-penalty −20%, integration +150%, fort +50%, militia 2×) | add tech as 7th `ModifierStack` source **and** add the missing consumers (`PoliticalPower.generateFor`, `UnrestSystem.targetUnrest`, `PolicySystem`, `CapitalSystem`, `CombatSystem.captureIfUndefended`) | many domains authored-but-inert today; Phase 1 wires the ones with existing mechanics, Phase 2 the rest. |
| **Doctrine / operation cost** (−30%) | `DoctrineSystem.switchCostFor` (`:39-45`) | operations are net-new (Phase 3). |
| **Research efficiency / power** | `ResearchSystem.researchRate` (§5) | efficiency −cost, power-gain ×rate. |

**Preferred aggregation:** add a **7th "tech" source to `ModifierStack.resolveAdditive`** (`ModifierStack.luau:122-134`) for the domains `ModifierStack` already serves (`army_attack`, `army_defense`, `army_movement_speed`, `army_occupation_speed`, `army_entrenchment_max`, `ideology_power`, and the economy/political domains). This makes those branches light up **with no new consumer code**. The **per-unit-class** combat buffs (infantry/cavalry — which `ModifierStack` cannot express) and the **naval** buffs use `TechEffects.factor` directly at their injection points.

### 4.3 Domain registry + caps (prevents the name-mismatch trap)

A single source-of-truth table (`Shared/TechDomains.luau`) listing every modifier key, the exact consumer, and its cap. Authoring must use these keys verbatim. Illustrative subset:

| Domain key | Consumer (verified) | Cap constant | Cap value |
|---|---|---|---|
| `infantry_attack` / `infantry_defense` | `BattleManager.buildSideInput` (per-class) | `MultiplierCapTechPerBranch` | 3.0× |
| `cavalry_attack` / `cavalry_defense` | `BattleManager.buildSideInput` (per-class) | `MultiplierCapTechPerBranch` | 3.0× |
| `artillery_attack` / `artillery_range` | `BattleManager` (artillery role) / `SiegeSystem` | `MultiplierCapArtillerySubStat` | 2.0× |
| `ship_attack` / `ship_defense` / `ship_speed` | `NavalSystem.fleetSide` (new) | `MultiplierCapTechPerBranch` (tuned low) | ≤3.0× |
| `country_tax_income` / `country_production` | `EconomySystem` (already read) | per-effect | branch-specific |
| `factory_output` | `ManufactorySystem` output | new `TechCapFactoryOutput` | +100% |
| `government_spending_reduction` | `EconomySystem` expense sum | new `TechCapGovSpend` | 30% |
| `fuel_efficiency` | `ManufactorySystem` fuel input | new `TechCapFuel` | 50% |
| `mining_output` | `EconomyPreview.productionOf` (Mining) | new `TechCapMining` | 80% |
| `political_power_gain` | `PoliticalPower.generateFor` | new `TechCapPPGain` | +100% |
| `policy_efficiency` | `PolicySystem` upkeep/cost | new `TechCapPolicyEff` | 50% |
| `unrest_reduction` | `UnrestSystem.targetUnrest` relief | new `TechCapUnrest` | 80% |
| `integration_speed` | integration timer (Phase 2) | new `TechCapIntegration` | +150% |
| `fort_defense` | `CapitalSystem`/`BattleManager.fortTierFor` (Phase 2) | new `TechCapFort` | 50% |
| `base_stability` | new stability drift tick | new `TechCapStability` | +100% (10% + 90% surveillance) |

New cap constants land in `WorldConstantsServer.luau` next to the three reserved ones.

### 4.4 Unit/building unlock gating (optional, Phase 1.5)

Today `effects.unlocks` is read by nothing, so a tech that "unlocks Ironclad" doesn't actually gate anything. To honour it: `RecruitSystem`/`NavalSystem.queueRecruit`/`BuildingSystem.enqueue` check `TechEffects.has(tag, unlockId)`. Gated behind a flag so it can't retroactively lock nations out of units they already build. (The naval catalogue also needs expanding — `ShipTypes` references ironclad/battleship/destroyer/carrier hulls that have **no definition** yet.)

---

## 5. Research backend rework (`ResearchSystem.luau`)

### 5.1 State shape (extends `country.research`)

```lua
country.techLevel = { [techId] = number }        -- NEW: current level per node (0 = unowned)
country.research = {
    slots = {                                     -- NEW: N parallel slots
        { active = techId | nil, targetLevel = number },
        …
    },
    slotCount = number,                           -- unlockable (start 2, up to ~5)
    progress = { [techId] = number },             -- points accumulated toward the active level (reused)
}
country.techs = { [techId|gateId] = true }        -- kept: "has at least level 1 / gate set" for researchGate compat
```

### 5.2 Accrual (multi-slot, flat base per slot)

- `researchRate(country) = ResearchPointsPerDay × (1 + TechEffects.additive(tag,"research_power_gain")) × (1 + research_speed legacy)` — **per slot**, flat base (`ResearchPointsPerDay` finally defined, `(tunable)` e.g. 8/day).
- `applyDays` iterates each slot; a slot with an `active` node accrues into `progress[active]`; on `>= levelCost` it calls `completeLevel`, which increments `country.techLevel[id]`, applies `effects[newLevel]`, fires `TechCompleted`, and clears the slot (auto-advance to next level optional/tunable).
- **Research efficiency** (`research_efficiency`, cap 30%) reduces `levelCost`.
- Era gate: a level is researchable only if `currentYear >= eraByLevel[targetLevel]` **and** prerequisites met **and** (for modern nodes) `unlockRequires` satisfied.

### 5.3 Slot management

- `slotCount` starts at 2 `(tunable)`. Additional slots unlock via specific Research-tab nodes and/or economic milestones. Client can assign/clear any slot via the `SetResearch` remote (extended to carry a slot index + target level).

### 5.4 Starting distribution by era + tech-group (uses the vestigial `technologyGroup`)

`seedAll` grants starting levels per node based on `country.technologyGroup` and a per-group **start era**:

- Each group maps to a start year (e.g. `nomad → 1600`, `sub_saharan → 1650`, `eastern → 1700`, `western → 1750`) `(tunable)`.
- For each node, grant the highest level whose `eraByLevel[n] <= group.startYear` (respecting `starting`/`startingLevel`).
- This directly implements "some tribes might not have technologies from the 1600" — less-advanced groups seed fewer levels.

### 5.5 Persistence & replication

- **Persistence:** match existing behaviour — **runtime tech progress is not persisted**; it re-seeds each boot from era/tech-group (§5.4). (The whole runtime world already behaves this way; a `SettingsStore`-style tech store is a future option if cross-session persistence is ever wanted.)
- **Replication:** move tech fields to a **private `OwnResearch` per-owner channel**, mirroring `OwnPolitics`. Rationale: leveled tables × multi-slot per country risk bloating the shared broadcast (country records are unchunked and already near the ~1 MB transit limit). Add `techLevel`/`research` to `StateReplicator` `COUNTRY_DROP` (`:80-92`); build `buildOwnResearch`/`pushOwnResearchTo`; create the `OwnResearch` RemoteEvent (mirror `:2545-2552`); push per-owner in `broadcast()` and `RequestFullState`; add `ClientStateCache.setOwnResearch` + a `ClientBoot` subscription. (`country.techs` boolean set can remain broadcast for cheap "does nation X have unlock Y" intel checks if ever needed.)
- Define `Channels.TechCompleted`; gate the whole feature behind a new `WorldConstants.EnableTechTree` flag (leave legacy `EnableResearch` alone).

---

## 6. UI — the HOI4-style tree (`ResearchScreen.luau`)

Rewrites the "Coming Soon" stub in place. `ResearchScreen` is already registered (`Hud.SCREEN_MODULES` → hotkey **5**), so no registry change. Returns `{ root, destroy }`.

### 6.0 Frame — a movable, resizable in-game window (not a docked screen)

The tech tree deliberately **breaks from the docked full-screen `Screen` convention**: it is a **floating window the player can drag, resize, and maximize**, so it can sit alongside the map and other panels rather than taking over the viewport.

- Build the window as a free-floating parchment panel (`ScreenKit.open(..., noBody=true)` for the chrome, but positioned/anchored as a movable window rather than the standard centered screen — or `Modal.create({ floating = true })`, which already gives a draggable, no-scrim popover).
- **Drag** by the title bar using the `EventCard.luau:53-78` idiom (InputBegan MB1/Touch on the header → InputChanged delta → update the window's `Position`), clamped to the viewport so it can't be dragged fully off-screen.
- **Resize** via a bottom-right corner handle (InputBegan → InputChanged delta → grow/shrink `Size`), clamped to a min (`~760×460`) and the viewport max. The internal rail + slot bar + canvas reflow to the window size.
- **Maximize / restore** toggle in the title bar (fills the safe area minus the HUD bars; second click restores the last floated size/position).
- Remembers last size/position for the session (client-only). Opening/closing still goes through `Hud.openScreen("ResearchScreen")` + hotkey **5**; the window just isn't modal and doesn't dim the map.

### 6.1 Layout

`ScreenKit.open(ctx, { name="ResearchScreen", title="Research", subtitle="Technology", shell="panel_large_shell", size=UDim2.new(0,1000,1,-132), noBody=true })`, then under `headerHeight`:

- **Left rail (~180px):** vertical list of pillar tabs (§2.1) with icon + label; active/hover states via `Shells` `sidebar_item_*` (mirrors `RealmScreen.selectTab`). Locked pillars (net-new, pre-phase) render dimmed with a lock badge.
- **Research-slot bar (top of right pane):** N slot chips, each showing its active node + a `ProgressBar`. Click a slot → "assigning" mode. Shows research power/day and the "5000"-style research counter from the reference.
- **Canvas (rest of right pane):** the pannable/zoomable node graph for the active pillar.

### 6.2 Canvas (pan + zoom)

- Inner content `Frame` hosting nodes + edges, inside a `CanvasGroup` (needed so rotated children — if any — clip correctly).
- **Pan:** drag idiom from `EventCard.luau:53-78` (InputBegan MB1/Touch → InputChanged delta → move content), clamped to graph bounds via `SuperEvent.clampAxis`.
- **Zoom:** `UIScale` on the content driven by `MouseWheel` (`Responsive.attach` pattern), zoom-to-cursor, clamped `[0.5, 1.8]` `(tunable)`. On touch: pinch + on-screen `+/-` buttons (mirror `HudWiring` touch zoom buttons). **Do not** reuse `CameraController` (that's the 3D map).

### 6.3 Node cards

- Card `Frame` with an **image banner header** + a footer. The banner is an `ImageLabel` sourced from the node's `banner` id (or `bannerByLevel[currentLevel]`), with a bottom gradient **scrim** (`UIGradient` fading to the card surface) so the name stays legible over any image, and the node name overlaid poster-style at the banner's lower edge. Nodes without a `banner` fall back to a **generative branch-tinted banner** (branch-colour glow + the node icon as a watermark) so the tree looks finished even before art is authored.
- Footer: an era label + **level pips `n/max`** (the reference's `0/5`), and a `ProgressBar` for the in-progress level. A thin branch-colour divider separates banner from footer.
- Banner images are validated as asset ids at load (reuse `normalizeFlag`); a bad/empty id degrades gracefully to the generative banner rather than showing a broken image.
- **States** (color tokens, animated via `Animations.tween` so ReduceMotion is honoured):
  - *Locked* (prereqs/era unmet) — `TextDisabled`, lock icon.
  - *Available* — `secondary` styling.
  - *Researching* (active in a slot) — accent border + live progress bar.
  - *Partially leveled* — pips filled to current level.
  - *Maxed* — `Positive`/success styling.
- **Hover** → `Tooltip.attach` detail (desktop). **Tap** (touch) → node detail panel (`Modal`, `floating=true`) with description, current vs next-level effects, level cost, prerequisites, and **[Research in slot ▸]** buttons.

### 6.4 Auto-layout & connector lines

- **X** from `era` (historical) or dependency tier (modern), snapped to era columns (1600, 1650, …, 1900). **Y** from `branch` band within the tab; tie-break same-column nodes by `order`. Optional explicit `x`/`y` overrides for hand-tuning.
- **Connector lines auto-drawn from `prerequisites`** as **orthogonal elbow** Frames (axis-aligned; no CanvasGroup-clip caveat). Color: met = `BorderActive`, unmet = `BorderSubtle`. This is the "auto connect it to previous technologies via a UI line" requirement — it is derived entirely from the data.

### 6.5 Live data & actions

- Subscribe `ctx.cache.onChangePrefix("countries", refresh)` reading `OwnResearch`; wrap in `ScreenKit.throttle(fn, 0.2)` (PoliticsScreen pattern).
- Actions fire `ctx.fire("SetResearch", { slot=i, techId=id, targetLevel=n })` (remote + `InputValidator` extended, §5.3).

---

## 7. Known scope reinterpretations & net-new mechanics

Called out so nothing is silently assumed:

- **"Artillery range" / "missile in-flight health" / "AA anti-ballistic"** require a ranged/back-row-fire combat mechanic and a projectile-in-transit entity — **neither exists**. Phase 1 reinterprets artillery "range" as attack/siege bonuses; the true projectile mechanics arrive with Phase 3's projectile framework.
- **"Building health"** (AA sites, silos, enrichers) — buildings have **no HP** today (only provinces have `fortTier`). Per-structure HP is net-new (Phase 3 foundation).
- **"Military power"** is **not a resource** — doctrines/generals cost `politicalPower`. Phase 3 adds a `militaryPower` pool + generation tick (Command tab's power-gain branch feeds it) and an **Operations** spend system.
- **"City integration speed"** — cores are an **instant boolean list**; there is no coring timer. Phase 2 adds a timed integration mechanic before `integration_speed` can bite.
- **"Militia / undefended-tile resistance"** — undefended tiles flip **instantly**. Phase 2 adds a garrison strength the captor must overcome.
- **Movement speed** — dead code (fixed cadence). Phase 2 rewires it; speed techs are authored now but inert until then (UI shows "active next update").
- **Naval fleet combat applies no country multipliers today** — the naval buff hook is net-new (but small).

---

## 8. File-by-file change list (Phase 1)

**New files**
- `src/ReplicatedStorage/ArtOfWar/Shared/TechDomains.luau` — domain registry + cap map (§4.3).
- `src/ServerScriptService/ArtOfWar/Systems/TechEffects.luau` — resolver (§4.1) *(or fold into ResearchSystem)*.

**Data**
- `src/ReplicatedStorage/ArtOfWar/Data/Technologies.luau` — new leveled schema; convert 146 historical → leveled; author buff branches.

**Server**
- `Systems/ResearchSystem.luau` — multi-slot, leveling, era gate, tech-group seeding, `researchRate`, `completeLevel`, `TechCompleted`.
- `Framework/ModifierStack.luau` — add tech as 7th `resolveAdditive` source.
- `Systems/BattleManager.luau` — per-unit-class tech factor in `buildSideInput`; artillery role.
- `Systems/NavalSystem.luau` — new fleet stat-multiplier in `fleetSide`.
- `Systems/EconomySystem.luau`, `Modules/EconomyPreview.luau`, `Systems/ManufactorySystem.luau`, `Systems/DistrictSystem.luau` — economy buff hooks.
- `Systems/StateReplicator.luau` — `COUNTRY_DROP` + `OwnResearch` channel.
- `Bootstrap.server.luau` — `SetResearch` payload (slot/level), `OwnResearch` remote + `RequestFullState`, `EnableTechTree` gate.
- `Events/Channels.luau` — `TechCompleted`.
- `WorldConstantsServer.luau` — new cap constants; `ResearchPointsPerDay`.
- `Shared/WorldConstants.luau` — `EnableTechTree` flag.

**Client**
- `UI/Screens/ResearchScreen.luau` — the full tree UI (replaces stub).
- `Modules/ClientStateCache.luau` — `setOwnResearch`/`getOwnResearch`.
- `StarterPlayerScripts/ArtOfWar/ClientBoot.client.luau` — `OwnResearch` subscription.

**Verification (per repo convention):** `selene src` clean + Studio `get_script_analysis` zero errors on every touched container; unit-test `TechEffects.factor` (cap clamping) and `CombatEngine.resolveRound` (determinism unchanged) via `execute_luau`; playtest the tree UI. No comments in code (repo convention).

---

## 9. Open items for the design owner (non-blocking; sensible defaults chosen)

1. **Slot count curve** — default start 2, max 5 via Research nodes. Adjust?
2. **`ResearchPointsPerDay` base** and per-level cost curve — placeholders; needs a balance pass with real game pacing.
3. **Tab grouping** — proposed 9 pillars (§2.1); trivially re-groupable in data.
4. **Auto-advance levels** — default: a slot stops after each level (player re-confirms). Alternative: auto-continue to `maxLevel`.
5. **Unlock gating (§4.4)** — turn on recruitment gating from `effects.unlocks`, or keep unlocks cosmetic for now?
