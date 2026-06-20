# Art of War — UI Redesign Summary

A complete, ground-up rebuild of the player UI, replacing the legacy skeuomorphic
modules with a flat design-system architecture driven by the uploaded v2 shell
assets (the ~180 ChatGPT-made PNGs) and the overhaul specification.

---

## 1. New architecture

Everything lives under `ReplicatedStorage/ArtOfWar`:

```
DesignSystem/            -- tokens + asset wiring (shared foundation)
  Colors.luau            -- 23 spec color tokens + resolve() + delta()
  Typography.luau        -- serif/sans/mono families + role scale + apply()
  Spacing.luau           -- 8-step spacing scale
  Animations.luau        -- tween presets (Default/Fast/Slow/ModalIn) + tween()
  Icons.luau             -- 61 semantic icon ids + create()
  Responsive.luau        -- isTouch/computeScale/attach (global UIScale)/tapHeight/guiInset
  Shells.luau            -- 135 v2 shell assets (slice/fit/stretch) + create()
  init.luau              -- aggregates the above

UI/
  Components/            -- reusable primitives (shell-based)
    Button.luau          -- 5 variants, hover/disabled, tap targets
    Panel.luau           -- shell panel + title/subtitle/close + content
    StatRow.luau         -- label/value/delta/inline-progress/icon (36px)
    ProgressBar.luau     -- shell track+fill (green/amber/red/grey) + flat fallback
    CountryBadge.luau    -- flag placeholder (country color + code)
    SectionDivider.luau  -- tracked caps + rules
    TabBar.luau          -- segmented OR underline tabs
    Modal.luau           -- scrim + modal shell + header + close + footer
    Tooltip.luau         -- shell tooltip + rows + cursor-follow attach()
    NotificationCard.luau-- severity accent + icon + title/body + TTL + dismiss

  Screens/               -- composed screens
    CountryBar.luau      -- bottom HUD: flag + identity + 5 stat pills + menu tabs
    TopBar.luau          -- date/speed capsule: pause + date + speed pips + -/+
    MapModeGrid.luau     -- map-mode buttons (icon + active state + tooltips)
    ScreenKit.luau       -- shared scaffold: shell panel + header + tabs + scroll body
    PoliticsScreen.luau  -- Overview / Government / Laws tabs
    EconomyScreen.luau   -- Budget / Trade / Buildings tabs
    MilitaryScreen.luau  -- Army / Navy / Doctrines tabs
    ResearchScreen.luau  -- tech categories with progress
    MissionsScreen.luau  -- mission groups + objectives
    ProvinceOverview.luau-- clicked-province panel (Land / Society / Output)
    NationSelection.luau -- claim screen: nation list + detail + Play
    PeaceTreaty.luau     -- peace modal: demands / cost + accept/refuse

  Hud.luau               -- controller: layers, persistent mount, router,
                            notification stack, hotkeys, data API
  HudWiring.luau         -- integration: binds Hud to the live game modules
```

### Design language (from the spec + the two concept images)
- Flat dark "parchment" surfaces (`SurfaceBase` 15,14,11 → `SurfaceOverlay` 28,25,20),
  framed by the gold-bordered v2 shells.
- Gold accent (`#F5D27A`), serif display type (Merriweather, intent Lora) for
  headings, sans (Gotham/Inter) for body, mono (RobotoMono) for figures.
- Semantic green/red/amber for positive/negative/warning values and deltas.
- No gradients on content; the only ornamentation is the shell art itself.

### Mobile / scaling
- `Responsive.attach()` puts a global `UIScale` on every layer, recomputed from
  viewport height (clamped 0.7–1.5, ×1.15 on touch).
- `Responsive.tapHeight()` enforces a 44px minimum hit target on touch for
  buttons, tabs, and map-mode cells.
- Screens use `ScrollingFrame` bodies with `AutomaticCanvasSize` so dense content
  never overflows on small viewports.
- Layers respect `GuiService:GetGuiInset()` via per-layer `IgnoreGuiInset`.

---

## 2. The cutover (`StarterPlayerScripts/ArtOfWar/ClientBoot.client.luau`)

Three surgical, defensive edits (all pcall-guarded — a failure warns, never
crashes the boot or the map):

1. `NotificationChannel` now routes to `Hud.notify(...)` instead of
   `UIController.notify(...)`.
2. The `UIController.start()` block is replaced by `HudWiring.start({...})`,
   passing the live modules (ClientStateCache, MapModeController,
   ProvinceInteraction, ProvinceCodes).
3. The legacy `UIBuilder.preloadHoverAssets()` spawn was removed.

Everything else in ClientBoot (CharacterHandler, CameraController, MapRenderer,
ProvinceInteraction.init, SimClock, MapModeController, state sync, the deferred
political paint) is untouched.

---

## 3. What is wired to live data (working now)

Persistent HUD: Country Strip (flag/name/gov·culture/treasury+income delta/manpower/PP/stability/legitimacy),
date·speed capsule, 5-mode map grid, notification stack, settings gear. Access: 6 menu tabs
(Politics 1 / Economy 2 / Military 3 / Diplomacy 4 / Research 5 / Missions 6), Esc closes, Space pauses.
Every screen reads **live** from `ClientStateCache` (debounced subscriptions) + the `Data/*` registries
via `UI/Registries.luau`, and fires the named remotes via `ctx.fire`.

| Screen | Live data | Actions (remotes) |
|---|---|---|
| **Country Strip** | `getCountry(tag)` | resources + 6 menu tabs |
| **Province Overview** (click) | `getProvince(id)` | Develop / Build |
| **Politics** (7 tabs) | legitimacy/stability/PP, governmentForm, ideology, factions, leaders/leaderCandidates, activePolicies, lawPass, lawCooldowns, doctrines | Enact/Repeal `EnactPolicy`/`RepealPolicy`, `CancelLaw`, `AppointLeader`/`DismissLeader`, `SetDoctrine` |
| **Economy** (Budget/Production/Trade/Buildings) | treasury, income/expenseBreakdown, stockpiles, dailyProduction/Consumption, economyPolicy, buildQueue, provinces | `SetEconomyPolicy`, `AcceptTrade`/`CancelTrade`, `BuildBuilding`/`CancelBuilding` |
| **Military** (Army/Navy) | `allArmies`/`allFleets` (own), manpower/levy | row click → Army/Fleet panel |
| **Army panel** (army select / Military list) | `getArmy` + UnitTypes/OfficerTraits | `RecruitUnit`, `DisbandArmy`, `MergeArmies` |
| **Fleet panel** (Military Navy list) | `getFleet` + ShipTypes/NavalMissions | `RecruitShip`, `SetFleetMission`/`ClearFleetMission`, `DisbandFleet` |
| **Diplomacy** (Nations/Wars/Proposals) | `allCountries`/`allWars`/`allPeaceProposals`, truces | `DeclareWar`, `ProposePeace`, `AcceptPeace`/`RejectPeace`/`CancelPeaceProposal` |
| **Research** | `technologyGroup`, `techs` + researchGate scan of LeaderSlots/TradeGoods/GovernmentTypes | read-only (no server research system) |
| **Settings** (General/Controls) | `SoundMuted`/`ReduceMotion` attributes | `SetMapMode` (Command/Field) |
| **Nation Selection** | unclaimed `allCountries` + province/dev totals | `ClaimCountry` |
| **Peace modal** | fed by Diplomacy | `AcceptPeace`/`RejectPeace` |
| Date/speed | `TimeSync` `{year,month,day,speed,paused}` | `TimeRequest` |
| Map modes | `MapModeController.requestMode`+`onChange` | — |
| Army selection | `ArmyView.onArmySelected` → Army panel (province-click guarded) | — |
| Notifications | `NotificationChannel` | kind→severity |

All 25 action remotes were checked against the server `bindEvent` signatures — the client fires the trailing
args only (player is implicit via `OnServerEvent`).

---

## 4. Old UI modules being retired

All replaced and no longer referenced by any kept code (only stale comments
mention them). Slated for deletion once the live playtest is signed off:

| Old module | Replaced by |
|---|---|
| `UIController.luau` (1497 lines) | `Hud.luau` + `HudWiring.luau` |
| `UIStyle / UIAssets / UIRoot / UISound / UIBuilder` | `DesignSystem/*` |
| `TopBar.luau` | `Screens/TopBar.luau` |
| `BottomBar / CountryHeader / CountryPanel` | `Screens/CountryBar.luau` |
| `ProvinceTooltip / ProvinceDetailPanel` | `Screens/ProvinceOverview.luau` (+ `Components/Tooltip`) |
| `EconomyWindow` | `Screens/EconomyScreen.luau` |
| `ResearchWindow` | `Screens/ResearchScreen.luau` |
| `DiplomacyWindow` + `Tabs/*` | `Screens/PoliticsScreen.luau` (partial) |
| `ClaimScreen` | `Screens/NationSelection.luau` |
| `NotificationFeed` | `Components/NotificationCard.luau` + Hud stack |
| `MapModesBar` | `Screens/MapModeGrid.luau` |

---

## 5. Phase 2 (2026-06-16) — full feature build

Every old-UI feature is now ported into the new design system (the 8 screens in the
Section-3 table). Built via multi-agent orchestration: parallel contract-mapping →
parallel screen build (each against the exact contracts) → 5-reviewer adversarial pass.
Review fixed: CountryBadge now accepts a Color3 OR `{r,g,b}` array; army strength is
summed from `composition` (no phantom `strength` field); dead `normalizeCountry`
sub-tables + phantom delta fields removed; province/dev counts computed from
`allProvinces`; Economy build-modal tracked + closed on destroy; MilitaryScreen
phantom `sailors`/`discipline` removed.

### Honest remaining work
**A. Server data fields that don't exist yet** (screens degrade gracefully — show value
without a delta/bar, never crash). Add these server-side to enrich the UI:
- `manpowerDelta`, `politicalPowerGain` → restore the manpower/PP deltas on the strip.
- `maxManpower` → real manpower progress bar (currently value-only).
- `prestige`, `absolutism`, ruler + adm/dip/mil → Politics Overview rows.
- Per-army `morale/org` are present; a friendly **income/expense provider-label map**
  would beat the prettified raw ids in the Economy budget.
- **No research system** exists (no tech tree/levels/progress, no research remotes).
  ResearchScreen is honest read-only gate status. A real system needs a Technologies
  registry + server ResearchSystem + an `InvestResearch`/`SelectResearch` remote.
- **No mission data model** → MissionsScreen shows an empty state.

**B. Map-driven orders not in panels (by design):** army move/attack (right-click +
`PathPreview` → `MoveArmy`/`MoveArmyPath`/`AttackProvince`) and fleet sail/engage
(`MoveFleet`/`AttackFleet`) are issued from the map; the panels note this. Wiring the
right-click → move/attack flow into the new HUD is the main remaining interaction.
Target-fleet selection for intercept/escort/transport missions is likewise map-driven.

**C. Preserved, not rebuilt:** the **Minimap** (DECAL `97466333148060` + UV constants)
is kept intact in `src/.../UI/Minimap.luau` AND backed up in
`_preserved/legacy_ui_2026-06-16/` — to be ported to the new style later. Multi-select
provinces (supported by `ProvinceInteraction`) is not yet surfaced.

---

## 6. Verification done
- selene **0 errors** + StyLua clean across every authored module (legacy files untouched).
- All 16 screens + components + Hud + HudWiring + Registries **require cleanly** in the synced place.
- All 8 new screens + both context panels **rendered & screenshotted** in Studio via the real
  `HudWiring.start` → `Hud.openScreen` path with a contract-accurate mock `ClientStateCache`.
- 5-agent adversarial review; every real finding fixed; false positives (Luau generalized
  iteration) confirmed safe.
- Cutover is defensive (pcall); no kept module requires any old UI module.
- **Not live-playtested** by the tooling (MCP `execute_luau` only sees the edit DataModel) —
  an F5 playtest is the human sign-off step.

## 7. Recommended next steps
1. Playtest (F5): claim a nation; open each menu (1–6); click an army; check the panels populate.
2. Add the Section-5A server fields to light up the remaining rows.
3. Wire right-click army/fleet move+attack into the new HUD (Section 5B).
4. Sign off → delete the 34 legacy UI files (preserved in `_preserved/` + git) and port the Minimap.
