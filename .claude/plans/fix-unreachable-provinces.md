# Plan — Fix unreachable / mis-adjacent provinces (adjacency bake blind spots)

Status: **IMPLEMENTED + VERIFIED** (2026-07-09, uncommitted). Branch `combat-update-v1`. Follow-up to
[[handoff-2026-07-09-movement-sea]] and memory `aow-adjacency-coastal-regen` (the 12-province gap).

## Outcome (what was actually done)
Owner chose the **direct-geometry rewrite**. Implemented in `Dev/AdjacencyGenerator.luau`, scoped to the two
detections that had the blind spot (the seam-aware sea↔sea grid and the WaterBodies zone naming were left
intact — both correct, and re-deriving the X-seam wrap would add risk with no bug fixed):
- **Sea-tile SHORE**: replaced the 8-stud grid's cell-adjacency shore with **direct per-sea-tile mesh overlap**
  (`GetPartsInPart`, tile proxy vs real province meshes, `SHORE_MARGIN=2`) + a **coastal-coverage backstop**
  (any coastal-but-shoreless province escalates a proxy until it hits a tile). Catches contained/overlapping/
  thin provinces by construction.
- **LAND adjacency**: added a **gap-tolerant pass** (`Phase 4.4`) — re-queries each land-LESS province with a
  small inflation (`landGapMargin=2`, rotation-aware via `part.CFrame`) and adds same-Y neighbors, GUARDED so
  the midpoint must sit over land (never bridges water). Phase 2's margin-0 overlap missed sub-stud gaps.

Regenerated `ProvinceAdjacency` + `SeaTileAdjacency` (`SeaZones` unchanged). **Verified:** 0 unreachable
provinces of any kind (whole land+sea graph is one component from the mainland), all 12 sea-reachable,
orphans=0, `land={}` 204→151 (53 provinces gained real land edges), the 6 land-adjacency misses now walkable
(655↔4356, 4350↔656, 1991↔1993, …), the 6 genuine islands correctly stay `land={}` (water guard), lint clean.
The direct shore is tighter (shore edges 4415→3471) but every coastal province keeps ≥1 edge — the dropped
edges were redundant over-connections.

---
_Original plan below (options A/B/rewrite) — kept for reference._


## TL;DR
The 12 "unreachable" provinces are actually **two overlapping bugs**, both caused by the same thing:
geometry that is thin, contained-inside-a-sea-tile, or separated by a sub-stud gap slips through the
bakes' **sampled** detection (cell-center raycast grids + margin-0 overlap). No exotic algorithm is
required — the existing `GetPartsInPart` rescue machinery already detects every case; it's just gated
too tightly. Fix = widen two rescue passes (one per bake) with a water-crossing guard, then regenerate.

## Evidence (Studio, edit mode, current baked data)

**Bug A — sea unreachable (12 provinces).** `coastal=true` in the zone bake but absent from every sea
tile's `shore` in `SeaTileAdjacency`. An inflated-in-Y proxy of each one **already overlaps a sea tile at
margin 0** (`sea@0` non-empty for all 12) — i.e. they sit inside/overlapping a sea tile's footprint (your
"contained inside another sea tile" observation), yet the 8-stud cell grid never recorded the shore edge.

| id | min dim | sea@0 (overlapping tiles) | land@margin1 |
|----|--------:|---------------------------|-------------|
| 574 | 11.6 | {1349} | — island |
| 1991 | 23.6 | {1734} | — island |
| 2002 | 16.4 | {1702} | — island |
| 2022 | 12.4 | {1559} | — island |
| 2025 | 33.5 | {1607} | — island |
| 4020 | 18.9 | {1449} | — island |
| 5077 | 25.1 | {1444,1445} | — island |
| 5920 | 8.4 | {1681} | — island |
| 655 | 10.5 | {1368,4357} | **borders 4356** |
| 2716 | 9.8 | {1357} | **borders 4796** |
| 4350 | 10.2 | {1395,1397} | **borders 656** |
| 4356 | 11.6 | {1368,1395,4357} | **borders 655** |

Why the grid misses them: shore edges only form when a cell landing *on the province* is orthogonally
adjacent to a cell landing *on a sea tile*, and "land wins" over any sea mesh beneath it. For a province
that overlaps/contains a sea tile (or is only ~1 cell wide), the province's cells and the tile's exposed
water cells never end up adjacent at 8-stud resolution. The `generateSea` **Phase 4.6** rescue is exactly
the right tool (inflate a province proxy, `GetPartsInPart` vs sea proxies) but it only runs for
`math.min(size) < cell(8)` — all 12 are larger, so they're skipped.

**Bug B — land-adjacency misses (16 provinces, map-wide).** Of the **47** provinces with `land={}` in
`ProvinceAdjacency`, **16** actually border ≥1 land province at margin ~1.5 (same Y plane) — they should be
**walkable**, not sea-only/unreachable. Examples: `14(4 nbrs), 35(2), 369, 631, 655, 1032, 1236, 1983(2),
2613, 2693, 2716, 4350`. The remaining **31 are genuine islands** (correctly `land={}`). Root cause: the
land bake (Phase 2, line ~206) uses **margin-0 `GetPartsInPart`** ("no inflation"), so two provinces
separated by a sub-stud mesh-tessellation gap never register a border. The Phase 4.5 gap-rescue only
force-bridges provinces that are *stranded* (0 land AND 0 shore); a coastal province with `land={}` is not
stranded, so it keeps the empty land set.

Overlap: `655, 2716, 4350, 4356` are in **both** sets. `655`+`4356` border only each other (an isolated
2-province landmass → they need land edge to each other **and** sea shore to be reachable from elsewhere).
`2716→4796` and `4350→656` become land-reachable once their true land edge exists (if 4796/656 are on the
mainland).

## Fixes

### Fix A — sea-shore rescue (makes all 12 reachable). LOW risk.
In `AdjacencyGenerator.generateSea`, Phase 4.6: **remove the `math.min(size) < cell` gate** and run the
proxy `GetPartsInPart`-vs-sea rescue for *every* shore-less province, with escalating margins `{0, 4, 10,
20}` (start at 0 because these overlap tiles already). Optionally gate on coastal (require
`ProvinceAdjacency` and skip provinces with `coastal ~= true`) to bound cost; interior provinces overlap no
sea and would no-op anyway. Only ADDS shore edges → cannot break existing routes. Proven sufficient: `sea@0`
hits for all 12.

### Fix B — land-border gap rescue (makes the 16 walkable). MEDIUM risk.
In `AdjacencyGenerator.generate`, add a pass AFTER the raw Phase 2 overlap and BEFORE the Phase 4.5
gap-rescue: for each province, `GetPartsInPart` a proxy inflated by a **small** margin (~1.5–2 studs, tall
in Y) against Provinces; for each hit with **|Δy| < 3** (same landmass plane) that isn't already a neighbor,
add the land edge. Guards to avoid false bridges across narrow straits:
- keep the margin small (≤2) — real straits are ≥1 sea cell (8 studs) wide;
- **water-crossing check**: reject a candidate edge if the midpoint between the two province centers sits
  over a sea tile (raycast/`nearestNode`), so we never connect across water;
- only *add* edges (never remove), and log every added edge for review.

### Alternative (if you want to kill the class, not patch it): direct-geometry rewrite.
Replace the cell grids with per-tile / per-province `GetPartsInPart` overlap for BOTH shore and land
adjacency, at a consistent small inflation + water guard. More robust by construction, but larger, loses the
grid's "land-wins" conservatism, and risks over-connection. **Not recommended now** — the targeted rescues
above fix every observed case at a fraction of the risk. Revisit only if new blind spots keep appearing.

## Recommended sequence
1. **Fix B first** (land), regenerate `ProvinceAdjacency` (+ re-key adjacency), verify no edge crosses
   water and the 16 now have land neighbors.
2. **Fix A second** (sea), regenerate `SeaTileAdjacency`, verify all remaining shore-less **coastal**
   provinces get a shore edge and the 12 are reachable.
   (Order matters only for clarity — both are additive and independent. Doing B first means the 4 overlap
   provinces get their correct land edges, and A then covers the true islands + the 655/4356 cluster.)
3. Re-run the pathfinding reachability check (self-contained edit-mode test from the last session): expect
   **0 unreachable coastal provinces** and **0 land={} provinces that border land**.

## Verification
- **Fix B:** count `land={}` provinces that still border land (target 0, down from 16); assert every newly
  added land edge's midpoint is NOT over a sea tile (no water bridges); spot-check 655↔4356, 2716↔4796,
  4350↔656 exist.
- **Fix A:** re-run the island-reachability probe — every genuine island appears in ≥1 sea tile's shore;
  the 12 ids all reachable via `findPath` from a mainland (returns a path containing a sea node).
- **End-to-end:** `run_script_in_play_mode` (run_server), `findPath` from a mainland province to each of the
  12 → non-nil.
- Lint (stylua + selene) all touched files.

## Regen mechanics (reuse last session's method)
`generate()` ~24s / `generateSea()` ~27s in EDIT mode. Source too big for run_code to return — store in
≤170k `ModuleScript.Source` splits, print each (only the FIRST printed line gets `[OUTPUT] `; strip it, join
`\n`, byte-concat), write CRLF, stylua, selene. Write to `Data/ProvinceAdjacency.luau` /
`Data/SeaTileAdjacency.luau`. See `aow-adjacency-coastal-regen`.

## Risks & rollback
- Fix B false bridges across water — mitigated by small margin + midpoint water check + edge logging;
  reviewable in the diff. Rollback = revert the data file (git) / re-run without the pass.
- Both fixes only ADD edges, so pathfinding/combat can't lose existing routes.
- Data files are Rojo-synced code → committing + place publish deploys them (no DataStore migration).

## Effort
Small–medium. Fix A ~20 lines + regen. Fix B ~30 lines + water-guard + regen. Most of the time is the
regenerate-extract-verify loop, which is now scripted/known.
