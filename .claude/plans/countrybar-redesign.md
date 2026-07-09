# CountryBar Redesign — Plan

**Status:** IMPLEMENTED + lint-clean (0 errors project-wide) + adversarially verified (4-lens review, 0 real
findings). Remaining = in-Studio runtime check (can't run headless) + optional polish knobs. Files touched:
`UI/Components/HeroButton.luau` (new), `UI/Screens/RealmScreen.luau` (new), `UI/Screens/ScreenKit.luau`,
`UI/Screens/PoliticsScreen.luau`, `UI/Screens/DiplomacyScreen.luau`, `UI/Screens/CountryBar.luau`, `UI/Hud.luau`,
`UI/HudWiring.luau`.
**Owner decisions (2026-07-08):** crest → **one Realm window with FLAT peer tabs `Court · Estates · Reforms ·
Diplomacy`** (Politics' three panes + Diplomacy as a 4th tab — NOT a nested Domestic/Foreign split); buttons →
**sharp procedural body + gold corner-bracket adornments** (honors the no-rounded-corners rule); briefcase →
**dropped, Missions folded into Politics**; background → **composed reflow frame** (no new baked art).

Repo: `C:/Users/justi/Documents/art-of-war`. Live client stack = `ClientBoot → Hud + HudWiring → Screens/*`.
Verified by a 6-agent subsystem map (workflow `wgz5blllz`, 2026-07-08). Every fact below carries file:line evidence
from that map.

---

## Goal

Replace the CountryBar's 7-text-tab row + 5 stat pills + name/gov text with a small set of **large, value-or-icon
buttons**. Fewer, bigger, friendlier; bridge mobile↔PC.

### New bar contents (left → right)
`[ Crest ]  [ £ Economy ]  [ Manpower ]  [ Research ]`

- **Crest** (clickable) → opens the new **Realm window** with four peer tabs: `Court · Estates · Reforms ·
  Diplomacy` (Politics' three existing panes + Diplomacy as a 4th tab).
- **Economy** button — shows live treasury (`£350`) + small green income delta (`+43`) → opens **Economy** screen.
- **Manpower** button — shows live manpower (`643.4K`) → opens **Military** screen.
- **Research** button — icon only (test-tube) → opens **Research** screen.
- Briefcase/Missions button: **dropped**. Settings tab: **dropped** (standalone gear already exists).
- Removed from the bar: country **name**, **government/culture** text, and the **Political Power / Stability /
  Legitimacy** pills (all still visible on the Politics → Court tab).

### Screen coverage after redesign (all 7 originals still reachable)
| Original tab | New entry point |
|---|---|
| Politics | Crest → Realm (Court / Estates / Reforms tabs) |
| Diplomacy | Crest → Realm (Diplomacy tab); map/province crest deep-link still opens it focused |
| Economy | £ Economy button |
| Military | Manpower button |
| Research | Research button |
| Missions | folded into Politics (its only live content, Formables, is already Politics' "Releasables" tab) |
| Settings | existing top-left `SettingsGear` (Hud.luau:141-164), desktop + touch |

---

## Why this is mostly a re-layout (verified)

- CountryBar is a **dumb view**: it renders `config.resources` strings and never reads state. All values the new
  buttons need are already computed every tick in `HudWiring.normalizeCountry` (`treasury`=money(), `treasuryDelta`,
  `manpower`=abbreviate()) and delivered on the shared `countries` channel — **zero new replication/subscription**
  (HudWiring.luau:196-204, StateReplicator COUNTRY_DROP keeps these fields).
- Screen routing already exists 1:1: buttons just call `config.onMenu("Economy"|"Military"|"Research")` →
  `Hud.openScreen` → `SCREEN_MODULES` (Hud.luau:31-39, 314-344). No new plumbing for the value buttons.
- Research has **no scalar point balance** (`country.research = {active, progress}`, ResearchSystem.luau:11-13) →
  Research button is **icon-only** (matches mockup). `Research`/`Economy`/`Military` icons all exist (Icons.luau).

## The three real work items

1. **Realm window** (combined Domestic/Foreign) — net-new; requires making Politics + Diplomacy embeddable.
2. **Hero-button component** — sharp body + gold corner brackets; the corner assets exist but are orphaned.
3. **Bar rewrite** — swap the baked 900×96 art for a composed reflow frame; make the crest clickable.

---

## Contracts that must not break (from the map)

- `CountryBar.create` returns `{ root, setActive, buttons, update }`. `Hud.openScreen` calls
  `widgets.countryBar.setActive(name)` (Hud.luau:342) and `buildCountryBar` calls `setActive(...)` (Hud.luau:88).
  **Keep a callable `setActive`** — repoint it to highlight the matching hero button (or no-op).
- `update(cfg)` currently writes `nameLabel.Text` / `govLabel.Text` every tick (CountryBar.luau:357-360). When those
  labels are removed, **remove those writes too** or it nil-indexes.
- `HudWiring.RESOURCE_KEYS` equality guard (HudWiring.luau:433-453) gates live refresh: a displayed value NOT listed
  there renders once but never updates. **Trim to `{treasury, treasuryDelta, treasuryDeltaNum, manpower}`** to match
  the new bar (dropping pp/stability/legitimacy from the guard is safe since the bar no longer shows them).
- `Hud.openCountryProfile(tag)` currently deep-links `openScreen("Diplomacy", {focusTag})` (Hud.luau:426-434). After
  redesign it must open **Realm on the Diplomacy tab with focusTag**.
- Politics & Diplomacy must **still work standalone** (Diplomacy via focusTag deep-link; any retained hotkeys). The
  embed path is **additive**, never a replacement of their `create(ctx)`.
- Do **not** touch the dead flat-UI stack (UIController / DiplomacyWindow / CountryPanel / UIBuilder / UIAssets).
  Live diplomacy/politics = `Screens/DiplomacyScreen` + `Screens/PoliticsScreen` only.

---

## Phases

### Phase 0 — Hero-button component  `UI/Components/HeroButton.luau` (new)
A reusable big button matching the owner's style rule:
- **Body**: procedural `Frame` + `UIStroke` (no UICorner, correct on frame 0) — same approach as
  `Components/Button.luau:96-122`, so **no async-slice flash**.
- **Corner adornments**: four `Shells.create("corner_tl"|"tr"|"bl"|"br")` fit-mode ImageLabels (Shells.luau:74-77)
  inset ~a few px at each corner. These are single sprites with no SliceCenter → zero 9-slice race. Pattern reference
  (do not import): the dead `UIBuilder.secondaryButton` corner() helper (UIBuilder.luau:1297-1319).
- **Content slots**: optional leading `Icons.create(key)`, a big value label, an optional small caption/label line,
  and an optional colored delta sub-line (for the Economy income `+43`, colored via `Colors.delta`).
- **Interaction**: `TextButton` (or Frame + input), hover/press state via property tweens (no textures), min 44px tap
  target at the 900-canvas scale so it survives the TouchFit downscale. `AoWInputSink = true`.
- API: `HeroButton.create({ icon?, value?, caption?, delta?, onClick, active? })` → `{ root, setValue, setDelta,
  setActive, root }`. Lint clean.

### Phase 1 — Make Politics pane-addressable + Diplomacy embeddable (additive)
The flat 4-tab design means RealmScreen owns ONE tab bar (Court/Estates/Reforms/Diplomacy) and drives the panes —
so Politics must expose its panes WITHOUT drawing its own tab bar, and Diplomacy must mount as one chromeless pane.
- **`Screens/PoliticsScreen.luau`** — add `mount(container, ctx, opts) → controller { setPane(key), destroy }`,
  where `key ∈ {"Court","Estates","Reforms"}`. When `opts.externalTabs == true`, build the scroll body + all state
  (cache subscriptions, OwnPolitics overlay, per-open selections) into `container` but do **not** build Politics'
  own tab bar; `setPane(key)` sets the active pane and re-renders the body. The controller lives for the window's
  lifetime (mounted once → no re-subscribe churn on tab switches). `create(ctx)` (standalone) keeps its own tab bar
  and internally calls the same pane-render / `setPane`.
- **`Screens/DiplomacyScreen.luau`** — add `mount(container, ctx) → { destroy }` building the full list→profile→
  actions flow into `container` (no ScreenKit window); honors `ctx.data.focusTag`. `create(ctx)` (standalone) =
  `ScreenKit.open(...)` then `mount(window.body, ctx)`.
- First read each file to see how it builds its tab bar (ScreenKit `opts.tabs` vs a `TabBar` component) and where
  its subscriptions/`destroy` live. **Risk to watch:** all connections owned by the controller and torn down in
  `destroy` (no double-subscribe, no leak). Standalone `create()` behavior must be byte-for-byte unchanged.

### Phase 2 — Realm window  `UI/Screens/RealmScreen.luau` (new)  — FLAT 4 tabs
- `create(ctx)` opens one `ScreenKit` window titled "Realm" (or "Government") with a **`TabBar`: Court · Estates ·
  Reforms · Diplomacy**, and a content area holding two stacked body frames: `politicsBody` + `diplomacyBody`.
- Mount both controllers ONCE: `politicsCtrl = PoliticsScreen.mount(politicsBody, ctx, {externalTabs=true})` and
  `diploCtrl = DiplomacyScreen.mount(diplomacyBody, ctx)`. Both stay mounted (state preserved).
- Tab select toggles VISIBILITY (no remount): Court/Estates/Reforms → `politicsBody.Visible=true`,
  `diplomacyBody.Visible=false`, `politicsCtrl.setPane(key)`; Diplomacy → swap visibility to `diplomacyBody`.
- Accept `ctx.data.initialTab` (default "Court") and `ctx.data.focusTag` (→ select Diplomacy tab, pass to
  `diploCtrl`). Returns `{ root, destroy }`; `destroy` calls `politicsCtrl.destroy()` + `diploCtrl.destroy()` +
  window destroy.
- Flat peer tabs (owner's choice): shallower than nesting, at the cost of RealmScreen knowing Politics' three pane
  keys — acceptable coupling, isolated to `RealmScreen` + the `PoliticsScreen.mount` contract.

### Phase 3 — CountryBar rewrite  `UI/Screens/CountryBar.luau`
- **Background**: drop `hud_country_bar_bg` (baked crest recess + old wells). Use a composed dark frame — a plain
  procedural `Frame` (surface color + `UIStroke`) OR a neutral panel slice shell — sized to the bar, so content
  reflows.
- **Layout**: a `UIListLayout` (horizontal) inside Content holding: clickable crest cell + 3 `HeroButton`s. Remove
  the absolute PILLS_RESERVE/NAME_W offset math.
- **Crest**: keep `CountryBadge` but wrap it in a `TextButton` hit area (like the pill "Hit" pattern,
  CountryBar.luau:90-97); click → new `config.onCrest()` callback. Recess no longer art-locked (composed bg).
- **Values**: keep the `setResources`/`update` path (CountryBar.luau:267-277, 356-371) → Economy button `setValue`
  = `res.treasury`, `setDelta` = `res.treasuryDelta`/`treasuryDeltaNum`; Manpower button `setValue` = `res.manpower`.
- **Remove**: name/gov labels + their update writes; the 5 stat pills; the MENUS tab row + `MENUS` list.
- **Keep**: the `TouchFit` UIScale (CountryBar.luau:176-193) — still valid; only the 900 width constant may be
  retuned. Keep a callable `setActive(name)` that highlights the matching hero button (Economy/Military/Research);
  crest/Realm has no persistent highlight requirement.
- Hero buttons call `config.onMenu("Economy"|"Military"|"Research")` (unchanged Hud routing).

### Phase 4 — Hud + HudWiring rewire  `UI/Hud.luau`, `UI/HudWiring.luau`
- `SCREEN_MODULES`: add `Realm = "RealmScreen"`. Keep `PoliticsScreen`/`DiplomacyScreen`/`MilitaryScreen`/
  `EconomyScreen`/`ResearchScreen` (Realm requires Politics+Diplomacy; the value buttons use the others).
- `buildCountryBar`: pass `onCrest = function() Hud.openScreen("Realm") end` alongside the existing `onMenu`.
- `openCountryProfile(tag)` → `openScreen("Realm", { initialTab = "Diplomacy", focusTag = tag })`.
- Drop `Missions`/`Settings` from `SCREEN_MODULES`/`MENU_KEYS` (Missions stub folded into Politics; Settings via
  gear). Reconcile number-key hotkeys 1-7 (Hud.luau:22-30, 167-179) to the surviving set or retire them.
- `HudWiring`: trim `RESOURCE_KEYS` to the values the new bar shows (see Contracts).

### Phase 5 — Responsive / mobile + verification
- Tap targets ≥44px at canvas scale (they will be, being "big"); confirm TouchFit still fits the narrower content
  (fewer/bigger buttons improve the current slight-overflow on ~380px phones). Optionally reduce the canvas width
  constant below 900 for a truer mobile fit.
- Note the touch-predicate divergence (CountryBar uses `Responsive.isTouch()`, HudWiring uses `Platform.isTouch`) —
  keep CountryBar on `Responsive.isTouch()` for consistency with its existing TouchFit; only unify if it causes a
  hybrid-device issue.
- `selene` clean on all touched files. Studio verification checklist (can't be tested headless):
  crest opens Realm on Domestic; province/foreign crest opens Realm on Foreign focused; Economy/Manpower show live
  values + income delta updates; Military/Research open; Settings gear still works; nothing errors on the first
  `setActive`/`update` tick; mobile bar legible + buttons tappable.

---

## Risks / gotchas
- **Embedding two ~1,200-line screens is the main risk.** Mitigate with the additive `buildBody`/`mount` split
  (standalone `create` unchanged) and strict `destroy` ownership of all connections.
- Corner adornments are **orphaned assets** — first live use; get inset/aspect right (fit mode + UIAspectRatioConstraint).
- Baked bg removal means re-deriving the crest position (now trivial with a composed layout).
- Keep `setActive` callable and prune hotkeys, or the screen manager errors / hotkeys open removed tabs.
- Rollback = version control (no runtime flag planned; a half-flagged bar doubles maintenance). Can add an
  `EnableCountryBarRedesign` WorldConstants gate if the owner wants A/B — say so.
- CRLF repo + stylua save-hook → use CRLF-safe Python for edits (normalize→edit→restore), per prior mobile work.
