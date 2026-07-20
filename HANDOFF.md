# Art of War — Developer Handoff

A practical map of the codebase for a developer (or AI pair) picking this project up. It focuses on the
things that aren't obvious from the tree: how the game is wired, where data *actually* lives, and the traps
that will bite you. It complements the existing docs — read those first for setup:

- **[README.md](README.md)** — layout, setup, daily workflow, publishing.
- **[AI-AGENT-GUIDE.md](AI-AGENT-GUIDE.md)** — the golden rules for an AI agent (edit files, not Studio).
- **[TEAM_PROMPT.md](TEAM_PROMPT.md)** — the short version + the two universes.
- **[WINDOWS-SETUP.md](WINDOWS-SETUP.md)** — click-to-run Windows setup.

> **What the game is.** *Art of War* is a mobile-first 1750s grand-strategy RTS on Roblox (own a nation,
> wage war, run an economy, form new nations). Landscape-only HUD. Two published universes share one codebase.
> The current feature branch is **`combat-update-v1`**; `main` is the trunk.

---

## 0. The one-paragraph mental model

The code is a folder of **`.luau` files under `src/`**, version-controlled in git. **Rojo** syncs those files
one-way into a Roblox Studio place. The **place** (`.rbxl`) owns everything that *isn't* a script — the ~17k-part
map, GUI frames, `RemoteEvents`, `RelayConfig`, `Fonts` — and is **not in git** (shared separately). At runtime a
single server `Bootstrap` script builds a shared **`ctx`** table, loads game data, registers ~60 **Systems** onto
`ctx`, and drives them from one **TickScheduler**. The authoritative **world state is DataStore-backed**, not the
data files. The client mirrors replicated state and renders a HUD. That's the whole shape.

---

## 1. The rules that stop you breaking things

Read this section twice. Most of these have already burned someone.

| # | Rule | Why |
|---|------|-----|
| 1 | **Edit the FILES in `C:/Users/justi/Documents/art-of-war`, never scripts inside Studio.** | Rojo is one-way; a Studio edit is overwritten on the next sync and the real source (the file) never changed. |
| 2 | **Work only in `…/art-of-war`. There is a STALE separate copy at `…\ROBLOX\Art of War Debug`.** | The Debug copy is an old tree (it still has `.lua` files); the real repo is uniformly `.luau`. Tools that fall back to the stale cwd will read the wrong files. If a path 404s, re-check you used the `art-of-war` absolute path. |
| 3 | **Editing `Data/Provinces.luau` or `Data/Countries.luau` has NO runtime effect.** | Province/country runtime state is **DataStore-authoritative** (collapsed v3/v4 schema). `DataOverlay.applyTo` literally discards those two source tables and rebuilds them from the DataStore. Change world data through the **Data Editor** (→ Push to Live) or `DataOverlay.setProvince/setCountry` + flush. *All other* data kinds (unit types, terrains, buildings, tech, formables, …) DO come from the files. |
| 4 | **The Studio MCP is READ-ONLY for source.** | Use it for `get_script_analysis` (compile check), read-only `execute_luau`, and playtest logs. Never `set_script_source` / `find_and_replace_in_scripts` / `edit_script_lines` — they desync the files. |
| 5 | **Nothing here is runtime-verified by the agent — the owner playtests in Studio.** | `selene`/`stylua` clean ≠ works. Ship behind a flag, hand off, let the owner Play-test. |
| 6 | **Lint & format before every commit: `stylua src` then `selene src`** (whole tree, from the repo root). | That's the team convention. Formatting a *single* older file can produce a huge whitespace diff if it predates a stylua pass — if you see that, either run the whole-tree pass or keep your edit minimal and match the surrounding style. There are no `-- stylua: ignore` markers, so `stylua` reformats whatever you point it at. |
| 7 | **Never commit a `.rbxl`/`.rbxlx`; never move `RelayConfig` or `Fonts` into git.** | The place is the binary source of truth for non-script content and holds the cross-universe relay secret. |
| 8 | **Never remove an `ignoreUnknownInstances` flag** (in `default.project.json` or any `init.meta.json`). | It's the only thing stopping a sync from deleting the map, Remotes, and GUI. |
| 9 | **Feature flags live in two files. Know which.** Client-safe flags in `Shared/WorldConstants.luau`; server-only thresholds in `ServerScriptService/ArtOfWar/WorldConstantsServer.luau` (merged into the same table at boot). | Re-adding a server-only field to the shared file **replicates it to clients** as exploitable data. |
| 10 | **Never add a public "set your flag/decal from an asset id" field.** | Content-policy landmine (a competitor was permanently banned over user-uploaded flag decals). Crest authoring stays admin-only, in the Data Editor. |
| 11 | **Buttons get no `UICorner`** — the owner treats rounded button corners as "AI slop". | The shared `Button.luau` draws its surface procedurally. Pills/badges may stay rounded. |
| 12 | **Combat is deterministic (seeded RNG, no luck term).** | Don't introduce unseeded `math.random` or time-based jitter into combat resolution. |

Commit messages on this project end with a co-author trailer; two developers share the repo, so
`git pull --rebase` before you start and before you push. Commit identity is set per-clone — leave it alone.

---

## 2. How to make a change (the loop)

1. `git pull --rebase`.
2. `rojo serve` (Studio plugin → Connect) so file saves land in Studio live. `rojo sourcemap --watch` for editor types.
3. **Edit the `.luau` file(s)** with your normal tools.
4. `stylua src && selene src` → fix until clean.
5. Owner **Play-tests in Studio** (this is the real verification; you can compile-check via the MCP `get_script_analysis`).
6. Commit in reasonable chunks; open a PR to `main` (or push the feature branch).
7. **Publishing is a human step** from Studio / `tools/publish.luau` — agents don't publish. `rojo build` contains only scripts, not the out-of-git geometry.

New gameplay behavior should ship **behind a `WorldConstants` flag, default off**, so it can be merged dark and
turned on after a playtest.

---

## 3. Architecture

```
 src/**.luau ──(rojo serve, one-way)──► Studio place ──(publish)──► 2 universes ──► players
 (source of truth, in git)              (map, GUI, Remotes,
                                         RelayConfig, Fonts — NOT git)

 SERVER (one Bootstrap.server.luau)                     CLIENT (one ClientBoot.client.luau)
 ├─ merge WorldConstantsServer → WorldConstants         ├─ require Modules stack (map/camera/interaction)
 ├─ DataLoader.loadBundle → ctx.Bundle                  ├─ ClientStateCache  ◄── StateReplicator (stateSync)
 ├─ register ProvinceRegistry, CountryRegistry, then    ├─ Registries (static Data, raw require)
 │  auto-register ~60 Systems onto ctx                  ├─ HudWiring.start → Hud (5 ScreenGui layers)
 ├─ declare+bind ~90 Remotes (InputValidator + bind)    │    └─ Screens/* via ctx.fire('Remote', …)
 ├─ WorldState (authoritative in-memory, 15 collections)└─ world-space views: ArmyView/CombatView/PathPreview…
 └─ TickScheduler (one Heartbeat drives every System)
```

### 3.1 Server boot & the `ctx` object

`src/ServerScriptService/ArtOfWar/Bootstrap.server.luau` (~80 KB) is the whole server entry point. It:

1. Merges `WorldConstantsServer.luau` into the require-cached `WorldConstants` table **before** anything reads it.
2. Builds **`ctx`** (a.k.a. `context`) — a plain table seeded with the framework singletons: `EventBus`,
   `TickScheduler`, `WorldState`, `DataLoader`, `UIBridge`, `InputValidator`, `Channels`, `WorldConstants`, then `Bundle`.
3. `DataLoader.loadBundle()` → `ctx.Bundle`.
4. Registers `ProvinceRegistry` and `CountryRegistry` **first** (explicit order), hydrates them from the bundle,
   then **auto-discovers every other System** by iterating `Systems:GetChildren()` and calling `.register(ctx)` on any
   module that has one.
5. Declares ~90 remotes (`InputValidator.register(name, {schema, rate})`) and binds them (`bindEvent`/`bindFunction`).
6. Starts `TickScheduler`.

**The System pattern** (this is the backbone — learn it once):

```lua
-- src/ServerScriptService/ArtOfWar/Systems/SomeSystem.luau
local SomeSystem = {}
local ctx
function SomeSystem.register(context)
    ctx = context
    ctx.SomeSystem = { doThing = doThing }              -- publish this system's API onto ctx
    ctx.TickScheduler.register({ id = "SomeSystem", priority = 50,
        updateIntervalSeconds = 3, update = tick })     -- optional per-tick job
    ctx.EventBus.subscribe(ctx.Channels.SomethingHappened, onSomething)
end
return SomeSystem
```

- Systems reference each other **only through `ctx`** (`ctx.BattleManager.startBattle(...)`), never by `require`.
- **Register order is arbitrary** except the two registries. So **don't read `ctx.OtherSystem` at register time** —
  only at tick/remote/event time (by then everything is registered). Publish your own api *inside* your `register`.
- A System is picked up only if its module returns a table with `.register`. A module that errors on require or
  lacks `.register` is **silently skipped with a warn** — no hard failure. Adding a system = drop a file in `Systems/`.

### 3.2 The framework layer (`Framework/`)

- **`TickScheduler.luau`** — the single sim clock. One `RunService.Heartbeat` drives every registered System.
  Each descriptor has an **accumulator** that is *decremented and clamped*, **not reset to 0** — this preserves
  per-system phase so same-interval systems don't all fire on the same frame (the "herd", staggered by
  `PHASE_STEP=0.37s`; disable via `WorldConstants.TickPhaseStagger=false`). Also owns the game calendar
  (`getGameDate`, `DateAdvanced`, `MonthBoundaryReached` — monthly economy hangs off the month roll) and
  speed/pause. **One slow `update()` blocks every other system that frame** (shared thread) — this is the known
  50-player scaling bottleneck.
- **`WorldState.luau`** — the authoritative **in-memory** store across 15 collections (provinces, countries,
  markets, units, fleets, armies, battles, wars, peaceProposals, tradeOrders, pacts, armyGroups, …). `get/set/all`
  per collection; writes mark a dirty set + bump a `revision`; `drainDirty()` feeds the replicator.
  **`setProvinceOwnership(id, {owner, controller, reason})` is the single chokepoint** for ownership/occupation —
  it writes *and* publishes `ProvinceOwnershipChanged` / `ProvinceOccupied` so every downstream view stays in sync.
  Province keys are **canonically numeric** (reads coerce with `tonumber`). Armies/fleets/battles/armyGroups
  **tombstone** on `setX(id, nil)` so removals replicate; other collections have dedicated delete fns.
- **`EventBus.luau` + `Events/Channels.luau`** — in-process pub/sub over ~130 named channels. `publish` is
  **queued and drained synchronously** (FIFO, with a loop-guard). Handlers run in `pcall`. To trace a cross-system
  effect, follow `ctx.Channels.<Name>` publishers/subscribers — e.g. `BattleResolved` fans out to DiplomacySystem
  (war-score), CombatSystem (index cleanup), and NotificationBroadcaster (toast) all at once.
- **`InputValidator.luau`** — every remote handler calls `InputValidator.accept(player, name, ...)` first. It
  enforces a **typed positional schema** + **per-player sliding-window rate limit**. Types include `countryTag`
  (exactly 3 uppercase A–Z), `peaceTerms`, `tradeOffer`, etc. **A remote with no `register()` schema is
  ungated** (`accept` returns true for unknown names) — always register a schema when you add a remote.
- **`DataLoader.luau`** — builds `ctx.Bundle` (see §3.3).

> **Everything runs in `pcall`** — tick updates, event handlers, remote handlers. A broken system fails *silently
> with a warn*, not a crash. When something "just stops working," grep the output for
> `[TickScheduler] system X errored` / `[EventBus] handler … failed` / `remote X handler errored`.

### 3.3 Data: where the world actually lives

`DataLoader.loadBundle()` reads ~34 data modules via a `pull(name)` helper that looks in
`ServerScriptService/ArtOfWar/ServerData` **first** (server-only seed data, kept out of client dumps), else
`ReplicatedStorage/ArtOfWar/Data`. Then it heals, applies an overlay, and validates (validation is **non-fatal** —
boot continues on errors).

**The critical fact:** for **provinces and countries**, the overlay (`ServerStorage/Services/DataOverlay.luau`)
is **DataStore-authoritative**. Under the live collapsed schema (v3/v4) it **discards `bundle.provinces` and
`bundle.countries`** and rebuilds them from JSON aggregate blobs in the DataStore. So:

- Editing `Data/Provinces.luau` / `Data/Countries.luau` → **no runtime effect**.
- `cultures/religions/ideologies/governmentTypes` → **merged** (source is base, DataStore wins per field).
- **Everything else** (terrains, unit types, building types, technologies, factions, policies, formables, …) →
  straight from the **files** (editing them works).

Other data facts:

- **Data Editor** (`ServerStorage/Dev/DataEditor.luau` + `DataEditorService.server.luau`) is **place-gated**
  (Map Editor place `104399454095233`, or any Studio session) and **write-isolated**: in an editor env every
  aggregate read/write is redirected to parallel `:edit` DataStore keys, seeded from live. The live game is
  untouched until **`pushEditToLive()`** ("Push to Live"). **Studio counts as an editor env** — a change you make
  in a Studio playtest writes `:edit`, not live.
- Saves use **`MERGE_SAVES` (UpdateAsync per-record journal merge)** so two concurrent editors don't clobber each
  other. There's a **mass-deletion breaker** — an overlay that would tombstone >~⅓ of a kind is refused (watch for
  the "mass-deletion breaker TRIPPED" warn if a legit bulk delete silently no-ops).
- **Province id == map part id** under the collapsed schema. `ProvinceStamper` stamps `province_id` onto each map
  `BasePart`. You cannot remap a province to a different part.
- **Adjacency is baked**, not computed: `ServerData/ProvinceAdjacency.luau`. If it matches too few stamped
  provinces, `AdjacencyGraph` silently falls back to a legacy 300-stud proximity graph — **regenerate the baked
  adjacency after any map/collapse edit.**
- **`WorldConstants` split**: client-safe tunables + all gameplay feature flags in
  `Shared/WorldConstants.luau`; server-only thresholds (AI cutoffs, `OfficerRngSeed`, law/faction/war-score IP) in
  `WorldConstantsServer.luau`, merged in at boot. Server sees the union; clients only get the shared subset.
- **Baked-world mode**: if `WorldConstants.UseBakedWorldData` (default **off**) is on, `Framework/BakedWorld.luau`
  boots from committed `ServerData/World/*` modules and **skips the DataStore overlay** entirely.

### 3.4 Replication & the two client data paths

- **Dynamic state** (province ownership, armies, wars, markets, …): server `StateReplicator.luau` broadcasts
  `WorldState` deltas/snapshots over a `stateSync` remote every ~0.4 s wall-clock (independent of sim speed); the
  client applies them into **`Modules/ClientStateCache.luau`** (per-collection tables + `revision` + `onChange`
  pub/sub). Large collections are **chunked** (provinces ≤800/packet, armies ≤250) because the full province set
  truncates if sent whole — never `FireAllClients` a big collection in one shot.
- **Static reference data** (unit types, terrains, trade goods, …): the client reads it directly through
  **`UI/Registries.luau`**, a lazy `require`-cache over the raw `Data/*.luau` modules. **Registries is NOT
  overlay-aware and NOT replicated** — it's the shipped files. (This is why the `absorbedByDistrict` flag added to
  `Data/BuildingTypes.luau` reaches the client: `Registries` requires that module raw.)

> Reading the wrong path is a classic bug: **`ClientStateCache` for live per-record state, `Registries` for static
> defs.**

### 3.5 Client UI

- **`ClientBoot.client.luau`** is the single live client entry. It locks the HUD to landscape, requires the
  `Modules` stack (map/camera/interaction/state), wires the `stateSync`/`OwnPolitics` remotes into
  `ClientStateCache`, connects `NotificationChannel`, then calls **`HudWiring.start(...)`**.
- **`UI/HudWiring.luau`** is the real bootstrapper: it builds the **`fire(name, ...)`** closure (looks up
  `ReplicatedStorage.ArtOfWar.Remotes.<name>` → `FireServer`), binds Hud handlers, and injects the screen context.
- **`UI/Hud.luau`** manages 5 stacked ScreenGui layers (`AoW_Hud` 10, `AoW_Screens` 20, `AoW_Modals` 50,
  `AoW_Notifications` 60, `AoW_Tooltips` 80) and the persistent **CountryBar** (bottom) + **TopBar** (top).
  Menu screens open via `Hud.openScreen(name)` (`SCREEN_MODULES`) with hotkeys `2`=Economy `3`=Military
  `4`=Diplomacy `5`=Research `6`=Formables `7`=Settings.
- **A screen reaches the server only through `ctx.fire('RemoteName', ...)`.** Screens are plain modules returning
  `{ create(ctx) -> handle }`; `ctx` (from `Hud.setContext` + `Hud.mergedCtx`) carries `cache`, `fire`,
  `registries`, layer refs, and openers. A typo'd remote name just warns.
- **`DesignSystem/`** (`Colors`, `Typography`, `Shells`, `Icons`, `Responsive`, `Spacing`, `Animations`) — a
  **dark-gilt palette**: near-black surfaces, gold accents/borders, warm ivory text, `Shells.create(name, props)`
  for the 9-slice gilt art. This is the visual identity; new UI should use it.
- **World-space views are NOT part of Hud** — `ArmyView`, `CombatView`, `MoveArrowView`, `CapitalMarkerView`,
  `PathPreview` are independent modules inited by ClientBoot/HudWiring and render tokens/banners/arrows on the map.
- **Notifications**: server `NotificationBroadcaster` → `NotificationChannel` remote → client routes `payload.kind
  == "superevent"` to **`Hud.showSuperEvent`** (the "World News" broadsheet), else `Hud.notify` (corner toast).

> **`UIController` is DEAD** (only in `_preserved/`). Anything under `_preserved/` is archived — don't resurrect it
> or assume it runs. Some `PoliticsScreen`/`TradeOffer` code exists but was **cut from the menus pre-playtest**
> (hotkey 1 is intentionally unbound) — *a screen file existing does not mean it's reachable.*

### 3.6 Gameplay systems (the important ones)

All in `src/ServerScriptService/ArtOfWar/Systems/` (~60 modules). Each attaches its api to `ctx`; feature flags
read from `ctx.WorldConstants`.

- **Combat** — `CombatSystem` (entry `attackProvince`; with `EnableAdjacentEngagement` on, the attacker fights the
  battle **at the target tile while staying on its own tile**, and only **marches in** on victory — no
  chain-capture teleport), `BattleManager` (round-based, **deterministic**, resolved by **rout** not pure
  attrition; awards officer/general XP; publishes `BattleResolved`), `CombatEngine` (pure round math),
  `MovementSystem` (`beginMove`; land step = 7 ticks ≈ one week; sea transport prices embark/disembark as the
  transition cost). `EnableInstantCapture` flips undefended enemy tiles instantly at a small casualty/org cost
  (bypassing gradual siege).
- **Economy / districts** — the **district rework is fully ON** (`MonthlyEconomy`, `DistrictTax`,
  `DistrictsPlayable`, `GateExtractionOnDistricts`, `GateRecruitOnMilitary` all true). `DistrictSystem` places 6
  district types into province building **slots** (= infra tier), separate from `BuildingSystem`. Buildings that
  districts replaced carry **`absorbedByDistrict = true`** in `Data/BuildingTypes.luau` (single source of truth):
  when districts are on, `BuildingSystem.enqueue` rejects them and the UI hides them. `BuildingSystem` still builds
  "special" buildings (walls/fortress/shipyard/university) + tier upgrades. **Don't describe the game as
  tax-per-population — that path is replaced.**
- **Diplomacy** — `DiplomacySystem` (~2200 lines) owns wars, peace, opinion, NAP, alliance, vassal/subject, and
  **release**. War-score accrues from `BattleResolved`/`ProvinceOccupied` + monthly exhaustion. Peace terms:
  white peace, annex-occupied, full annex (deletes the defeated country). Peace-conference and core-unrest are
  coded but **off** (`EnablePeaceConference`, `EnableCores` = false).
- **Formables & releasables** — `FormableSystem` (`EnableFormables` on). **Forming does not create a new tag** —
  the existing country *adopts* the formable's identity (name/color/flag), cores the provinces, gains a small
  bonus, one-time per tag (`country.formedTags`). **Release is cores-driven** and lives in `DiplomacySystem`
  (`releaseNation`): each province has a `releasableCores` list; releasing transfers those provinces and revives
  the dormant nation via `NationFactory`. Annexation stamps the loser's tag into conquered provinces'
  `releasableCores` so it can later break away.
- **Notifications & super-events** — `NotificationBroadcaster` coalesces combat toasts and fires the full-screen
  **super-event broadsheet** for nation **formed**/**released** (`fireSuperEvent`).

---

## 4. Feature flags — what's on and off

Flags live in `Shared/WorldConstants.luau` (+ server-only in `WorldConstantsServer.luau`). **Verify a flag before
assuming a behavior is live.** As of this handoff:

**On:** `EnableFormables`, `EnableAdjacentEngagement`, `EnableInstantCapture`, `EnableStrictRetreat`,
`EnableSeaTransport`, `EnableFullAnnex`, `MonthlyEconomy`, `DistrictTax`, `DistrictsPlayable`,
`GateExtractionOnDistricts`, `GateRecruitOnMilitary`, `UseArmyMembershipIndex`, `TickPhaseStagger`,
`RecordDrivenMapColoring`.

**Off (coded but dormant):** `EnableCores`, `EnablePeaceConference`, `EnableRebellions`, `EnableNewEditor`,
`EnableTerrainMaterials`, `EnableMarketSim`, `EnableRadialOrders`, `EnableDragToMove`, `UseBakedWorldData`.
`UnrestTaxPenaltyPerPoint = 0` (unrest simulates but has no tax effect — neutralized for the public playtest).

---

## 5. Current state, roadmap, and recent work

**Update 1 "Raise the Banner"** (crests + a ~30-formable game-loop + releasable nations + formation/release
super-events) is **code-complete on `combat-update-v1`** but **not fully playtested**. The wider roadmap: UPD2
Establish & Expand (politics/economy), UPD3 Flames of War (unit skin packs = the main monetization, tech tree,
vassals, colonization), UPD4 religion, UPD5 factions/events/AI. Don't build later-update depth early.

**Recent changes on the branch (newest first):**

- SuperEvent modal reworked as a period **newspaper broadsheet** ("World News"): centered, draggable, no
  auto-dismiss, always-fits-the-viewport (`UIScale`), flush-left headline + kicker + deck, drop-cap body, colophon,
  ornate end-mark, bordered dismiss button.
- **Legacy buildings phased out** of every build surface: absorption is data-driven via
  `Data/BuildingTypes.luau#absorbedByDistrict`; the multi-select "Build in all" panel, single-province panel, and
  Economy catalog all filter it, and the server `BuildingSystem.enqueue` rejects it (defense-in-depth). Audited +
  verified.
- UPD1 addenda: formation/release events + audio + mute, formed-marker, all-formables catalog, global
  fastest-time leaderboard; playtest fixes (merge = per-army toggle default on; right-click no longer deselects;
  post-victory timed march instead of chain-capture).

**Still needs a Studio playtest:** the broadsheet's fit-scaling on a mobile viewport; the multi-select build panel
now showing only special buildings; the UPD1 formables/releasables loop end-to-end.

---

## 6. File cheat-sheet

| Path | What it is |
|------|-----------|
| `src/ServerScriptService/ArtOfWar/Bootstrap.server.luau` | Server entry: builds `ctx`, loads data, registers systems, binds remotes, starts the clock. |
| `…/Framework/TickScheduler.luau` | The single sim clock + calendar + speed/pause. |
| `…/Framework/WorldState.luau` | Authoritative in-memory state; `setProvinceOwnership` chokepoint. |
| `…/Framework/EventBus.luau` + `Events/Channels.luau` | In-process pub/sub + the ~130 channel names. |
| `…/Framework/InputValidator.luau` | Remote schema + rate limiting. |
| `…/Framework/DataLoader.luau` | Builds `ctx.Bundle` from Data modules + overlay. |
| `src/ServerStorage/Services/DataOverlay.luau` | DataStore-authoritative world overlay; `:edit` isolation; Push to Live. |
| `src/ServerStorage/Dev/DataEditor.luau` + `…/DataEditorService.server.luau` | The place-gated Data Editor. |
| `…/Systems/*` | ~60 gameplay systems (combat, districts, diplomacy, formables, …). |
| `…/WorldConstantsServer.luau` + `Shared/WorldConstants.luau` | Server-only + client-safe tunables/flags. |
| `src/StarterPlayer/StarterPlayerScripts/ArtOfWar/ClientBoot.client.luau` | The single live client entry. |
| `src/ReplicatedStorage/ArtOfWar/UI/HudWiring.luau` + `Hud.luau` | HUD bootstrap + screen/layer manager. |
| `…/UI/Screens/*` | Per-screen modules (`create(ctx)`). |
| `…/UI/Registries.luau` | Static Data reads for the client (not overlay-aware). |
| `…/Modules/ClientStateCache.luau` | Client mirror of replicated dynamic state. |
| `…/DesignSystem/*` | Dark-gilt palette, typography, 9-slice shells. |
| `default.project.json`, `rokit.toml`, `selene.toml`, `stylua.toml` | Rojo map + pinned toolchain + lint/format config. |
| `tools/publish.luau`, `extract.luau`, `export-world.luau`, `obfuscate.luau` | Lune scripts (publish/re-export/bake/obfuscate). |
| `_preserved/` | **Dead/archived** — do not use. |

## 7. Glossary

- **tag** — a 3-letter uppercase country id (e.g. `FRA`). The primary key for a nation; reused across form/release.
- **province** — a map tile; its record id *is* the map part id. `owner` (peace/annex) vs `controller` (combat
  occupation) can differ.
- **cores / defaultCores / claims / releasableCores** — per-province membership lists. `releasableCores` drives
  which nation can break away from a tile.
- **district** — the current economy building (6 types, occupy infra slots). Replaced most old "buildings".
- **formable** — an identity a country can adopt on meeting a territory requirement (min-count / %). Doesn't change
  the tag.
- **bundle** — the loaded game data (`ctx.Bundle`), built by `DataLoader` from the Data modules + overlay.
- **overlay** — `DataOverlay`, the DataStore-authoritative layer that owns province/country runtime data.
- **the place** — the `.rbxl` in Studio: map, GUI, Remotes, `RelayConfig`, `Fonts`. Not in git.

---

*Generated 2026-07-12. When something here disagrees with the code, the code wins — grep and verify, then fix this
doc.*
