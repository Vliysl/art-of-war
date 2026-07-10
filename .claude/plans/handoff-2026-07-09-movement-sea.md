# Handoff — Movement / Sea work (2026-07-09)

Branch `combat-update-v1`. Two commits this session, plus one place-side revert. Everything below is
pushed **except** the place publish (see "Action required").

## What shipped

### 1. Land-preferring troop pathfinding  — commit `6469155`
**Problem:** armies crossed sea to shortcut between two provinces on the same contiguous landmass.
**Root cause:** `AdjacencyGraph.findPath` was an unweighted **BFS (min hop-count)**; the graph mixes land
edges and sea edges (province ↔ negative-id sea tile) all at weight 1, so `A→sea→B` (2 hops) beat a 3+-hop
coastal march.
**Fix:** `findPath` is now a **weighted Dijkstra** (binary min-heap). A land↔sea transition costs
`WorldConstants.SeaPathEmbarkPenalty` (**10**); every other step costs 1. So a land route up to ~2×penalty
(~20) tiles longer than a sea shortcut still wins; sea is used only when land is far longer or impossible
(islands). Single chokepoint → both the real move (`MovementSystem.beginMovePath`) and the client preview
arrow (`computePreviewPath` → `RequestPreviewPath`) follow automatically. Travel time (`moveTicksFor`) is
unchanged — this only affects **route choice**.
- Files: `ServerScriptService/ArtOfWar/Systems/AdjacencyGraph.luau` (findPath + `DEFAULT_EMBARK_PENALTY`
  fallback), `ReplicatedStorage/ArtOfWar/Shared/WorldConstants.luau` (`SeaPathEmbarkPenalty`).
- **Tuning lever:** raise `SeaPathEmbarkPenalty` for stronger land preference, lower to embark more readily.
  Data at penalty sweep: 6→29.8%, **10→14.0%**, 16→5.9%, 40→0% of same-landmass close-coastal pairs still
  cross sea. 10 chosen because land-detour lengths for these pairs are median 12 / p90 32 / max 75 hops, so a
  higher penalty would force absurd 30–75-tile marches for the ~16.5% of pairs that are genuinely
  water-separated. 10 kills the short/moderate detours (the complaint) and lets only genuinely-long detours sail.
- **Verified:** unnecessary same-landmass sea crossings **83% → 14%**; islands still sea-reachable; live
  server end-to-end PASS (`769→749` now land-only; Puerto Rico 492 still via sea; returned paths are valid
  node-by-node adjacency chains); 3-lens adversarial review (algorithm / return-contract / regression) = **0
  findings**.

### 2. Coastal adjacency + sea regen  — commit `6469155` (same commit)
- `Dev/AdjacencyGenerator.luau`: added thin-province rescue passes (zone **Phase 4.6** + tile **Sea 4.6**) so
  provinces thinner than a grid cell register as coastal / get sea shore edges.
- Regenerated `Data/ProvinceAdjacency` (coastal **1534 → 3838**), `Data/SeaZones`, `Data/SeaTileAdjacency`.
  Puerto Rico (492) and other thin islands now sea-reachable.
- Regen how-to (if needed again): run `AdjacencyGenerator.generate()` (~24s) and `.generateSea()` (~27s) in
  **edit** mode; source is too big for run_code to return (prov ~506KB) — store in ≤170k `ModuleScript.Source`
  splits, print each (only the **first** printed line gets an `[OUTPUT] ` prefix; strip it, join with `\n`,
  byte-concat), write CRLF. See memory `aow-adjacency-coastal-regen`.

### 3. UI  — commit `6469155` (same commit)
- CountryBar economy/manpower/research icons → new assets (`Icons.BarEconomy/BarManpower/BarResearch` =
  102838857191936 / 95003359351366 / 123336824010030). CountryBar references by key; Icons.luau is the only
  source.
- `NationSelection`: paginated list (top 10/25/50) + sort alphabetical / by country rank.

### 4. DoubleSided revert (place-side, NOT git)
Set `MeshPart.DoubleSided = false` on all ~2,571 coastal meshes (edit-mode). Needs a place SAVE to persist.

## Action required (owner)
1. **Publish the place.** Rojo has synced all repo files to Studio (confirmed), but the live game needs a
   publish. This also persists the DoubleSided revert (place-side).

## Pending / recommended follow-up (NOT done)
- **12 provinces unreachable by sea** — ids `574, 655, 1991, 2002, 2022, 2025, 2716, 4020, 4350, 4356, 5077,
  5920`. They're `coastal=true` in the zone bake but absent from every sea tile's shore in `SeaTileAdjacency`,
  so no army can reach them. **Two sub-classes:**
  - *Large* ones (2025 = 69×33, 5077 = 25×44, 1991 = 24×35, 4020 = 19×21) have `land={}` — almost certainly
    **land-adjacency misses** (should have LAND neighbors), not islands. Investigate why the zone bake gave them
    no land set.
  - *Small* ones with a sea tile within ~6–14 studs were missed by the tile bake's shore detection; the Sea
    phase 4.6 rescue only fires for `min(size) < cell(8)` and these are slightly larger — loosening that
    threshold + regenerating `SeaTileAdjacency` would likely rescue them.
  This is the same class as the original "Puerto Rico inaccessible" complaint but a **data** gap, independent
  of the pathfinding change. Recommend a dedicated pass.

## Verification assets (this session)
- Self-contained edit-mode graph test (old BFS vs new Dijkstra, penalty sweep, island reachability) — rerun via
  run_code requiring `Data/ProvinceAdjacency` + `Data/SeaTileAdjacency`.
- Live end-to-end: `run_script_in_play_mode` mode=run_server, require `AdjacencyGraph`, poll `getSource()`,
  call `findPath`.
