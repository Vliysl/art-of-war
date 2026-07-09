# Mobile Experience Rework — Plan

**Status:** CODE-COMPLETE + final review fixes applied, lint-clean (0 errors project-wide). Scope: comprehensive
(Phases A–D). Remaining = ON-DEVICE verification/tuning (touch gestures can't be tested here) + enable Phase-C flags.

### Progress (2026-07-07)
- **Phase A DONE** — A1 marquee touch coords now from `GetMouseLocation` (ProvinceInteraction, verify on-device);
  A2 screen-space army-priority hit-test (`ArmyView.selectNearestOwnedArmy` + `ProvinceInteraction.addScreenSelector`,
  wired into both tap paths, 44px touch / 10px desktop); A3 `ProvinceInteraction.selectProvincesInScreenRect` +
  drag routing (PC Alt→provinces, touch target sub-toggle) → existing aggregate panel.
- **Phase B core DONE** — B1 group-card multi-select already worked (surfaced via the new control column); B2
  `ArmyView.selectOwnedArmiesOnScreen` + touch "Select Army" button + desktop **G** key. Touch controls reworked
  into a left-edge column (Deselect / Select Army / Box Select toggle / Units-Provinces target).
- **Phase B DONE (full)** — +B3 marquee live "N selected" count above the finger (`ArmyView.countArmiesInRect` +
  `ProvinceInteraction.setDragCountProvider`/count label) and B4 tap-to-add (touch box-select mode taps ADD).
- **Phase D DONE (minus optional D6)** — D1 touch scale bump (`Responsive.computeScale` ×1.25 + 0.9 floor on touch,
  tune on-device); D2 tap targets; D3 CountryBar stat-pill tap-to-show tooltip; D4 live ProvinceTooltip pins top-right
  on touch; D5 zoom +/- buttons. D6 (edge-pan) intentionally SKIPPED (one-finger pan covers it; would collide with the
  left-edge control column).
- **Phase C DONE (flag-gated OFF — needs on-device tuning):** C1 long-press radial order menu — NEW `UI/RadialMenu.luau`
  (ring of buttons at the touch point + full-screen catcher) + long-press detection in `ProvinceInteraction`
  (`onLongPress`, 0.35s hold, cancels on move) + HudWiring wiring with REAL orders (Halt=`CancelMove`,
  Reinforce=`SetReinforce`, Auto-Cap=`SetAutoCapture`, Deselect). C2 drag-from-army-to-move — `ArmyView.selectedArmyNearScreen`
  probe + `ProvinceInteraction` drag detection → `onRightClicked` move; the camera-pan race is SOLVED by making the
  InputGuard freeze predicate (`cameraShouldFreeze`) do a FRESH hit-test each check (no stored flag) so it can't race
  the camera controller's InputBegan. Flags: `WorldConstants.EnableRadialOrders` / `EnableDragToMove` (both default false).
  **Both need on-device gesture tuning (I can't test touch here) — enable the flags on a device to feel/adjust.**
- All A/B/C/D lint-clean: **0 errors across 11 files** (ProvinceInteraction, ArmyView, HudWiring, RadialMenu[new],
  ArmyPanel, Slider, ProvinceOverview, Responsive, ProvinceTooltip, CountryBar, WorldConstants).
GOTCHA: repo files are CRLF + a save hook runs stylua — the Edit tool flaked on tab depth; used CRLF-safe Python
(normalize→edit→restore) for reliable edits.

### Final adversarial review + fixes (2026-07-07)
Ran a multi-agent find→verify pass over the whole rework (15 raised → 11 confirmed). Applied **8 fixes** (all lint-clean):
- **#1/#9 touch control column** — was top-anchored (`AnchorPoint(0,0)`, grew DOWN from y=56) and overflowed the
  CountryBar / overlapped the settings gear. Now **bottom-anchored** (`AnchorPoint(0,1)`, grows UP from
  `COL_BOTTOM=124` above the country bar, `ROW_GAP=56`). Bottom-left column, clear of top-left gear + right-side chrome.
- **#4 zoom +/- buttons** — were top-right (`1,-16,0,y`), colliding with notification toasts. Now **bottom-right**
  (`AnchorPoint(1,1)`, `1,-16,1,-y`; "+" at y=180, "−" at y=124 just above the country bar).
- **#3 `ArmyView.countArmiesInRect`** — the live marquee "N armies" count counted distinct *provinces*, not the
  armies `selectArmiesInScreenRect` actually selects (whole owned stack per hit province). Now counts every owned
  army on the hit provinces → count matches the real selection exactly.
- **#5 group-card content clip** — icon40+name30+count28+gaps overflowed the shrunk touch `STRIP_H=88`. Raised
  touch `STRIP_H`→108 AND shrank touch content (icon 40→28, vlist gap 4→2) so content(90) ≤ card interior(92): no clip,
  still smaller than desktop (128).
- **#6 radial Reinforce / Auto-Cap** — were one-way (always set true). Now **toggles**: reads the selection's
  aggregate state via `ClientStateCache.getArmy` (`reinforceEnabled`/`autoCapture`, mirrors ArmyPanel) and fires the
  opposite, with label flipping "Reinforce On/Off" · "Auto-Cap On/Off".
- **#7 drag-to-move camera-freeze leak** — `dragMoveFrom` wasn't cleared on the box-select early-return branch, so a
  box-select after arming a drag-move could leak a frozen camera. Now captured+cleared (`local fromArmy = dragMoveFrom;
  dragMoveFrom = nil`) at the TOP of every touch-end path.
- **#10 strip scrollbar** — `ScrollBarThickness=4` too thin to grab on touch → `TOUCH_STRIP and 10 or 4`.

**Deferred / flagged (not blindly changed):**
- **#2 marquee touch coordinate** (`input.Position + GuiInset`) — left as-is; needs **on-device** verification. Belief:
  likely correct (isMouseOverUI proves `GetMouseLocation` = true-top-left = `WorldToViewportPoint` box space, and
  `input.Position` is inset-relative so `+GuiInset` lands in the same space). If a device shows a consistent offset,
  flip the inset sign — do NOT change blind.
- **#8 drag-to-move has no path preview** — polish; the feature is flag-gated OFF anyway. Add a preview when enabling
  `EnableDragToMove` on-device.
- **#11 button discoverability** — the touch column labels are terse ("B", target toggle). Polish once the layout is
  felt on a device.
**Goal:** make Art of War genuinely playable on touch and bridge the mobile↔PC gap — fix the three named
issues, adopt proven mobile-RTS control patterns, and clean up the HUD/responsive layer.

Repo: `C:/Users/justi/Documents/art-of-war`. LIVE client stack = `ClientBoot → Hud → CountryBar / HudWiring /
Screens/*`, with map interaction in `Modules/ProvinceInteraction` + `Modules/ArmyView` + `Modules/CameraController`.

---

## Guiding principles (from the mobile-RTS research)

1. **Army beats province on a tap.** Units are the small, intentional target; provinces are big and hittable
   elsewhere. Priority hit-testing is the single highest-leverage fix.
2. **Keep the camera-freeze marquee toggle** — you already ship the industry-correct answer (an explicit mode,
   not a raw one-finger drag that fights panning, which is Company of Heroes' documented mistake).
3. **Lean on what already works:** tapping an `ArmyGroupStrip` card already selects the whole group
   (`quickSelect`); that IS touch multi-select. Surface it, don't rebuild it.
4. **Parity by intent, not by port:** every PC hotkey gets a touch equivalent mapped by *intent* (control-groups
   → group cards, right-click order → long-press radial / drag-to-move, `G` select-nearby → a button).
5. **Forgiving over pixel-perfect:** enlarged hit radii, live selection counts, generous inclusion.

## Infra reference (verified — build on these)

- **`Modules/Platform.luau`**: `Platform.isTouch` (`:47`, static bool), `.scale` (1.15 phone/1.05 tablet), `.tapTargetMin`
  (44/40/22), `Platform.viewport()`, `Platform.onChanged(fn)`.
- **`DesignSystem/Responsive.luau`**: `isTouch()` (`:12`, = TouchEnabled and not MouseEnabled), `computeScale()`
  (`:21`, ×1.15 on touch), `attach(root)` (`:33`, parents a `ResponsiveScale` UIScale — how `Hud.makeLayer` scales
  every layer), `tapHeight(base)` (`:63`, = max(base,44) on touch), `guiInset()` (`:58`).
- **`Modules/InputGuard.luau`**: `register(name, predicate)` (`:5`), `isCameraBlocked()` (`:15`, true if ANY
  predicate true). `ProvinceInteraction` registers `"dragSelect"` = `getMultiSelectMode` (freezes camera for marquee).
- **`Modules/CameraController.luau`**: `TouchPan` (`:251`, one-finger, gated by `inputBlocked()` at `:254`),
  `TouchPinch` (`:272`, two-finger zoom → `targetZoom`), `inputBlocked()` (`:35`, = InputGuard OR over an
  `AoWInputSink`), public `setZoom(z)`/`getZoom()` (`:339`/`:335`), `MIN_ZOOM=20/MAX/DEFAULT` (`:47`). Edge-pan
  `handleEdgePan` (`:162`) is `if Platform.isTouch then return` (`:164`).
- **`UI/ArmyGroupStrip.luau`**: card `MouseButton1Click` → `quickSelect(groupId)` (`:547`→`:306`) = deselect + `armyView.focusArmy(id, true)` per member. Group cards ARE touch multi-select.
- **`Modules/ArmyView.luau`**: `armyParts[armyId]=model`, `selectArmiesInScreenRect(rectMin,rectMax,additive)` (`:1650`,
  uses `WorldToViewportPoint`), `focusArmy`, `selectStackOnProvince` (`:1543`), `deselect`. Selection is raycast-classified via `classifyArmyClick` (`:1565`).
- **`Modules/ProvinceInteraction.luau`**: touch tap/drag branch (`:559`–`:674`), mouse branch (`:700`–`:798`),
  drag box (`ensureDragGui` `:417` IgnoreGuiInset=true, `updateDragRect` `:449`), multi-province state
  (`multiSelection`, `toggleInMultiSelection` `:341`, `addMultiSelectListener` `:852`), `MULTI_SELECT_MAX=25`.
- **Multi-province consumer** already wired: `HudWiring.luau:891` `addMultiSelectListener` → `Hud.openProvince({multi=true,...})` aggregate panel. Gated on `WorldConstants.EnableMultiProvinceActions` — **confirm this flag's state; the province multi-select paths are dormant if it's off.**
- **Gotcha:** `ClientBoot.client.luau:14` locks `ScreenOrientation = LandscapeSensor` (HUD assumes landscape).
- **Dead files — do NOT touch:** `UI/BottomBar.luau`, `UI/UIController.luau`, `UI/ProvinceTooltip.luau` (non-Components), `UI/NotificationFeed.luau`, `_preserved/*`. LIVE equivalents: `Screens/CountryBar.luau` (menu row), `Components/ProvinceTooltip.luau`, `Components/NotificationCard.luau`.

---

## Phase A — The three named issues

### A1. Marquee-select offset on touch
**Root cause:** the drag box lives in an `IgnoreGuiInset=true` ScreenGui (`ProvinceInteraction:429`). The **desktop**
path feeds `updateDragRect`/the final rect from `GetMouseLocation()` (true-top-left, consistent with the
`WorldToViewportPoint` hit-test) — aligned. The **touch** path uses `input.Position` (`:607/615`, `:636-637`),
which is inset-relative, so the box lands ≈ the GUI-inset height off the finger and the selection rect is off from
the hit-test too.
**Fix:** unify the touch drag onto the desktop coordinate source. Either (a) read `GetMouseLocation()` in the touch
`InputChanged`/`InputEnded` (it already tracks the active touch — see the tap raycast at `:654`), or (b) convert
`input.Position` by `GuiService:GetGuiInset()`. Prefer (a): identical pipeline to desktop, which is known-aligned.
Touch points: `ProvinceInteraction` `:561` (touchDownPos), `:606-617` (drag update), `:632-640` (final rect).
**Risk:** Roblox inset semantics vary by device/topbar state — **verify on a real device** (or Studio device emulation).
**Verify:** on touch, the box corner sits exactly under the finger and the units selected match the drawn box.

### A2. Hard to select a unit sitting on a province  ← highest-impact fix
**Root cause:** unit selection is a precise raycast (`tryClassifierRaycasts` → `classifyArmyClick`, `ArmyView:1565`)
that must hit a small token part; finger taps miss and fall through to the province (`ProvinceInteraction:648-654`
touch, `:730` mouse).
**Fix — screen-space priority hit-test (army > province):**
- New `ArmyView.nearestOwnedArmyToScreenPoint(screenPos: Vector2, maxPx: number)` → iterate `armyParts`, project each
  owned stack's `model:GetPivot().Position` via `WorldToViewportPoint`, return the nearest `{armyId, provinceId}` whose
  projected point is within `maxPx` (≈ `Responsive.tapTargetMin` = 44 on touch, ~12 on desktop) and on-screen.
- In `ProvinceInteraction` tap resolution: BEFORE the province raycast, try the nearest-army test; if hit, select that
  stack (`selectStackOnProvince`) and consume. Keep the existing raycast classifier as a fallback.
- Optional: give each token an invisible enlarged `CanQuery` hit-part so the raycast fallback is also forgiving.
- Keep the desktop Alt-override (`:726`) that forces province-under-unit selection.
**Risk:** must not steal taps meant for the province when zoomed in (units far apart) — tune `maxPx`, and only prefer
army when the province tap ALSO has an army near (don't hijack an empty-province tap). Respect `EnableNewInputScheme`
move semantics (with units already selected a province tap is a MOVE, not a select — army-priority applies to the
SELECT case).
**Verify:** tapping on/near a stack selects the stack; tapping bare province still selects the province.

### A3. Multi-select provinces + Alt-marquee (PC), and unify the marquee
**Current:** marquee (mb1 drag) selects only UNITS (`selectArmiesInScreenRect`). Provinces multi-select via
shift/ctrl-click only, desktop-only, behind `EnableMultiProvinceActions`. Alt currently = inspect province-under-unit.
**Fix:**
- New `ArmyView`-analog province rect select: `selectProvincesInScreenRect(rectMin, rectMax)` that projects province
  parts (workspace `ArtOfWarMap.Provinces`) into the rect and adds them to `multiSelection` via a new batch
  `ProvinceInteraction.addManyToMultiSelection(parts)` (respects `MULTI_SELECT_MAX`, fires `notifyMultiSelectionChanged`
  once). Perf: iterate the rendered/on-screen province set, not all 5713, or cap by the camera frustum.
- Route the mb1 drag-end in `ProvinceInteraction:708-718`: **Alt held → province rect select; otherwise → unit rect
  select** (today's behavior). Extend `onDragSelected(min,max,additive,mode)` with a `mode` ("units"|"provinces") or add
  a second callback. Feeds the existing `HudWiring:891` aggregate `ProvinceOverview` consumer.
- Touch (no Alt): add a target sub-toggle to the Drag-Select control ("Select: Units / Provinces") in
  `HudWiring:1222`, so touch can marquee provinces too.
- Confirm/enable `WorldConstants.EnableMultiProvinceActions`.
**Risk:** province projection cost on huge maps (mitigate with on-screen culling); the aggregate panel already exists so
UI risk is low.
**Verify:** Alt-drag on PC boxes provinces (not units) → aggregate panel; plain drag still boxes units.

---

## Phase B — Touch multi-select ergonomics (make it discoverable + fast)

### B1. Surface group-card selection (already functional)
Tapping an `ArmyGroupStrip` card already selects the whole group (`:547`→`quickSelect`). Gap = discoverability. Ensure
the strip is visible/reachable on touch, sized ≥44px, and add a first-use hint. Little/no new logic.

### B2. "Select nearby armies" button (Conquerors `G` / StarCraft double-click)
New `ArmyView.selectOwnedArmiesNear(screenPoint or cameraCenter, radiusPx)` → select all owned stacks within a screen
radius; wire an on-screen button next to Deselect (`HudWiring:1198+`) and the `G` key on desktop. One tap, no drag —
the cheapest, most reliable multi-select.

### B3. Marquee accuracy upgrades
On the drag box (`updateDragRect`): (a) **offset crosshair** rendering the active corner ~40–60px above the fingertip
(dodges finger occlusion); (b) **live "N selected" counter** label following the box (needs `ArmyView.countInRect`
preview); (c) **forgiving inclusion** — count a unit if the box touches its enlarged radius, not just its centroid.

### B4. Tap-to-add units
In touch multi-select mode, a plain tap on a unit ADDS it to the selection (toggle) instead of replacing — mirrors
shift-click. Touch point: `ProvinceInteraction:648-653`.

---

## Phase C — Order UX (reduce mis-taps, stop buttons occluding the phone screen)

### C1. Long-press radial order menu
New module `UI/RadialMenu.luau` (or fold into HudWiring): on a selected army, a long-press (UserInputService,
~0.3s, movement < threshold) spawns a ring of buttons centered on the touch point — Move / Attack / Stop / Split /
Reinforce / Add-to-group — sliding onto one + releasing fires it; slide to center cancels. Wire to the existing order
remotes already used in `HudWiring` (`MoveArmyPath[Multi]`, group remotes, etc.). Flag-gate (`EnableRadialOrders`).
**Risk:** must not fight the pan/pinch gestures — spawn only when an army is selected and the press starts on it;
cancel on second finger.

### C2. Drag-from-army-to-province move gesture (Iron Marines model)
Press on a selected/own army → drag → release on a province = MOVE there (finger starts on a known object, watches the
endpoint — dodges occlusion). Distinct from a plain tap (select). Touch point: `ProvinceInteraction` touch branch;
reuse the `onRightClicked(province)` move path (`HudWiring:1023`). Flag-gate; keep tap-to-move as the fallback.

---

## Phase D — HUD / responsive polish (verified items only)

> Corrections from verification — NO WORK NEEDED: menu access already exists (LIVE `CountryBar` menu row exposes all 7
> screens on touch); the minimap already has full touch (pan/pinch/tap-to-teleport); `CountryHeader` hover is already
> `Platform.isTouch`-guarded; `NotificationFeed`/`BottomBar` are dead.

- **D1. Global touch text bump.** `caption=11`/`bodySm=12` (`DesignSystem/Typography.luau:18-19`) are too small on phones.
  Add a touch multiplier at the Typography source (or via `Responsive`) so gameplay labels scale up ~15–20% on touch.
  (`CountryBar` already bumps its menu labels +3 — generalize it.) Verify readability at 375-wide.
- **D2. Tap targets.**
  - **ArmyPanel action buttons stuck at 32px (real bug):** `actionGrid` forces `CellSize=…32` + `AutomaticSize=None`
    (`Screens/ArmyPanel.luau:451,466`), overriding `Button`'s `tapHeight`. Make the cell height/`AutomaticSize`
    touch-aware (≥44).
  - **ProvinceOverview inline `+` build stepper is 28px** (`Screens/ProvinceOverview.luau:671-674`) — enlarge on touch.
    (The diamond action buttons there are already 44px on touch — fine.)
  - **Slider handle 18px** (`Components/Slider.luau:15`) — enlarge to ~28–32 on touch (used by Settings sliders).
  - **NotificationCard close button** (`Components/NotificationCard.luau`) — verify ≥44px hit area on touch.
- **D3. Touch feedback for hover-only affordances.** Only real gap: **CountryBar stat-pill tooltips**
  (`Screens/CountryBar.luau:128/136` MouseEnter/Leave, no touch) — add tap/long-press to show the tooltip on touch.
- **D4. ProvinceTooltip touch positioning.** LIVE `Components/ProvinceTooltip.luau` `follow()` (`:87-111`) always tracks
  `GetMouseLocation()` (last-tap on touch) with no pin — on touch, pin to a fixed corner + clamp to viewport.
- **D5. On-screen zoom ±.** Pinch is the only zoom (`CameraController:272`). Add +/- buttons (top-right, ≥44px) →
  `setZoom(getZoom() * factor)`. One-handed play.
- **D6. Edge-pan on touch (optional/low).** Disabled on touch (`CameraController:164`). One-finger `TouchPan` already
  covers panning, so this is a nicety, not a gap — consider virtual edge zones or skip. Low priority.

---

## Cross-cutting

- **Flags:** gate the behavior-changing pieces — `EnableMultiProvinceActions` (A3), `EnableRadialOrders` (C1),
  `EnableDragToMove` (C2). A1/A2/D are straight fixes/polish (no flag needed, but A2's priority hit-test could be
  flag-gated during rollout).
- **Live-game safety:** all of this is client-side UI/input (no server/DataStore); low blast radius.
- **Verification:** primary is on-device (Studio device emulation for layout/tap-targets; a real phone for the
  coordinate-space + gesture work in A1/A2/C, which Studio emulation can misrepresent).
- **`selene` clean** after each phase.

## Suggested sequencing
1. **Phase A** (the named issues) — A2 first (biggest win), then A1, then A3.
2. **Phase D2/D1** (tap targets + text) — cheap, broad comfort wins; can land alongside A.
3. **Phase B** (multi-select ergonomics) — B1/B2 first (low effort), then B3.
4. **Phase C** (radial + drag-to-move) — highest effort/novelty; flag-gated; do last.
5. Remaining D polish (D3/D4/D5).
