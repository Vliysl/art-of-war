# Art of War — V2 UI System Guide (for Claude)

This document is the single source of truth for building or editing **any** UI in Art of War. Read it fully before writing UI code.

The game already has a complete, consistent "V2" UI system: a design-token layer, a slice-9 image-asset library ("Shells"), an icon set, and a component library. **Your job is to compose UI from these existing pieces — never to invent new visual styles, art, or ad-hoc frames-as-art.** If you follow this guide the result will match the rest of the game automatically.

> **Where the V2 assets live (open these to see every available asset):**
> - Image/panel/button/etc. assets → `src/ReplicatedStorage/ArtOfWar/DesignSystem/Shells.luau` — use via `Shells.create("<key>")`. Full key list in Section 3.
> - Icon assets → `src/ReplicatedStorage/ArtOfWar/DesignSystem/Icons.luau` — use via `Icons.create("<key>", size, tint)`. Full key list in Section 4.
> - Design tokens (colors/fonts/spacing/animations/responsive) → the other files in `src/ReplicatedStorage/ArtOfWar/DesignSystem/`.
>
> These "assets" are Roblox asset IDs (`rbxassetid://…`) registered inside those two files — not loose image files. **Always reference an existing key; never upload, invent, or hardcode a new asset ID.** Paths above are relative to the `art-of-war` repo root.

---

## 0. Golden rules (do not break these)

1. **Only use the existing V2 assets.** All visible panels, buttons, rows, cards, pills, tooltips, dividers, inputs, badges and slots come from `DesignSystem.Shells` (image assets) and `DesignSystem.Icons` (icon images). Do **not** invent new colors, gradients, strokes-as-decoration, or upload/reference new asset IDs.
2. **Do not build raw `Frame`s as final art.** Plain `Frame`s are fine for *structure, layout, hitboxes, and live text*. Anything the player perceives as a panel/button/row/card must be a Shell.
3. **Reuse the components** in `UI/Components` and the screen scaffold `UI/Screens/ScreenKit`. Don't reimplement a button, stat row, tab bar, modal, tooltip, or section header — they exist.
4. **Use the design tokens** (`Colors`, `Typography`, `Spacing`) for every color, font, and gap. Never hardcode `Color3.fromRGB(...)` for text/surfaces, never set `TextSize`/`Font` directly (use `Typography.apply`), never use magic pixel gaps (use `Spacing.spaceN`).
5. **No emojis. No unicode symbols as icons.** Use `Icons.create(...)` or a text label. If an icon doesn't exist, use a text label — never an emoji or a glyph like `★`/`✓`.
6. **No `TextScaled`.** Use a fixed role via `Typography.apply` plus `TextTruncate = Enum.TextTruncate.AtEnd` and/or compact number formatting.
7. **Format every number for display.** Never put `tostring(someNumber)` straight into a label — floats render as `139.199999999`. Use the formatting helpers (Section 9).
8. **Data-driven, never hardcoded.** Read live data from `ClientStateCache`; never hardcode country tags, province ids, or lists.
9. **Match the house style of the file you're editing:** tabs for indentation, no comments unless the surrounding code has them, no dead code, `local` everything, return a table from modules.
10. **Verify before declaring done:** `selene src` (0 errors), `stylua --check <file>`, and the Studio Luau analyzer must all be clean. See Section 13.

---

## 1. Where everything lives

```
src/ReplicatedStorage/ArtOfWar/
  DesignSystem/            -- tokens + asset registries (require the folder; it has init.luau)
    init.luau              -- aggregates: Colors, Typography, Spacing, Animations, Icons, Responsive, Shells
    Colors.luau            -- color tokens + Colors.resolve / Colors.delta
    Typography.luau        -- fonts + roles + Typography.apply
    Spacing.luau           -- spacing scale (space1..space10)
    Animations.luau        -- TweenInfo presets + Animations.tween
    Icons.luau             -- icon image ids + Icons.create
    Responsive.luau        -- UIScale + touch helpers
    Shells.luau            -- THE V2 image-asset registry + Shells.create
  UI/
    Components/            -- reusable widgets (Button, CountryBadge, StatRow, ProgressBar,
                              SectionDivider, TabBar, Modal, Tooltip, NotificationCard, Panel, ProvinceTooltip)
    Screens/               -- full screens + ScreenKit scaffold + CountryBar/TopBar/MapModeGrid/NationSelection/...
    Hud.luau               -- the HUD manager (layers, open/close screens, notifications)
    HudWiring.luau         -- binds Hud to live data (ClientStateCache, remotes, map interaction)
    Registries.luau        -- client-side data registry helpers
  Modules/
    ClientStateCache.luau  -- replicated game state (countries, provinces, armies, ...)
    ProvinceInteraction.luau -- map hover/click raycasting + listeners
```

To require the design system from a Component (`UI/Components/X.luau`):
```lua
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
```
From a Screen (`UI/Screens/X.luau`):
```lua
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Components = script.Parent.Parent.Components
```

---

## 2. Design tokens

### 2.1 Colors (`DesignSystem.Colors`)
Warm dark palette. Use these — never raw RGB for UI.

| Token | RGB | Use |
|---|---|---|
| `SurfaceBase` | 15,14,11 | deepest background / primary button text |
| `SurfaceElevated` | 22,20,16 | raised surfaces |
| `SurfaceOverlay` | 28,25,20 | overlays |
| `SurfaceSunken` | 10,9,7 | insets, scrims, progress track |
| `BorderSubtle` | 58,47,31 | hairlines, faint borders |
| `BorderStrong` | 82,67,44 | scrollbars, stronger borders |
| `BorderActive` | 245,210,122 | gold focus border (search focus, selected) |
| `TextPrimary` | 245,241,232 | **cream** — primary/neutral values |
| `TextSecondary` | 138,126,106 | **warm grey** — labels, secondary text |
| `TextTertiary` | 107,104,98 | hints, captions |
| `TextDisabled` | 74,71,66 | disabled |
| `TextInverse` | 15,14,11 | text on light |
| `Positive` | 91,143,106 | **green** — good / income / easy |
| `Negative` | 196,74,69 | **red** — bad / cost / hard |
| `Warning` | 212,166,71 | **amber** — medium / warning |
| `Accent` / `AccentHover` | 245,210,122 / 255,220,130 | **gold** — SELECTED / FOCUSED / ACTIVE only |
| `FactionMonarchist/Aristocrat/Clergy/Merchant/Intellectual/Populist/Military` | … | estate/faction colors |

**Color semantics (follow exactly):** cream = neutral primary values · warm grey = labels/secondary · green = positive/good · red = negative/bad · amber = medium/warning · **gold = selected/focused/active ONLY (never general decoration; never "glow").**

Helpers:
- `Colors.resolve(key)` → Color3 for `"positive"|"negative"|"warning"|"accent"|"primary"|"secondary"|"tertiary"`.
- `Colors.delta(value)` → Positive if `>0`, Negative if `<0`, else TextSecondary (handles non-number → TextSecondary).

### 2.2 Typography (`DesignSystem.Typography`)
Fonts: **Serif = Merriweather** (display/headers), **Sans = GothamSSm** (everything else), **Mono = RobotoMono** (numbers when monospacing helps).

Apply a role — never set `.Font`/`.TextSize` manually:
```lua
Typography.apply(label, "bodyMd")
```

| Role | Font | Size | Use |
|---|---|---|---|
| `displayXl` | SerifBold | 32 | hero titles |
| `displayLg` | SerifBold | 24 | screen titles |
| `displayMd` | Serif | 18 | card/section titles, country names |
| `title` | SerifBold | 20 | tooltip titles |
| `bodyLg` | SansMedium | 16 | prominent body |
| `bodyMd` | Sans | 14 | body |
| `label` | SansMedium | 13 | field labels, buttons |
| `value` | SansBold | 14 | stat values |
| `bodySm` | Sans | 12 | secondary/subtitles |
| `caption` | SansBold | 11 | tab labels, pills, eyebrow text |
| `mono` | RobotoMono Bold | 14 | numeric/code |

### 2.3 Spacing (`DesignSystem.Spacing`)
4px scale. Use these for **all** padding and gaps.
`space1=4 · space2=8 · space3=12 · space4=16 · space5=24 · space6=32 · space8=48 · space10=64`

### 2.4 Animations (`DesignSystem.Animations`)
Presets: `Default` (0.15s), `Fast` (0.10s), `Slow` (0.30s), `ModalIn` (0.20s) — all Quad/Out.
```lua
Animations.tween(instance, Animations.Fast, { ImageTransparency = 0 })
```
Cross-fade hover/active states by tweening `ImageTransparency` between stacked Shell images. Don't write your own TweenService calls.

### 2.5 Responsive (`DesignSystem.Responsive`)
- `Responsive.attach(screenGui)` adds a `UIScale` named **`ResponsiveScale`** with `Scale = clamp(viewportY/1080, 0.7, 1.5)` (×1.15 on touch). **Every HUD layer already has this.** It means the whole layer scales uniformly with resolution — so **you author at 1080p design pixels and the scale handles other resolutions.** Do not pre-divide layout sizes by scale.
- `Responsive.tapHeight(base)` → on touch, `max(base, 44)`; on desktop, `base`. Use for button/tab heights so they're tappable on mobile.
- `Responsive.isTouch()`, `Responsive.guiInset()`.
- **CRITICAL GOTCHA — cursor-following elements:** because the layer has a `UIScale`, a tooltip positioned with raw `UserInputService:GetMouseLocation()` pixels via `UDim2.fromOffset(x, y)` will render at `mouse × scale` (drifts toward the top-left). You must divide by the layer's scale. See Section 10.4.

---

## 3. Shells — the V2 image-asset library (`DesignSystem.Shells`)

This is the heart of the V2 look. Every visible container is a Shell. Create one with:
```lua
local panel = Shells.create("panel_large_shell", {
    Name = "MyPanel",
    Size = UDim2.fromOffset(360, 200),
    Position = UDim2.fromOffset(16, 16),
    ZIndex = 2,
})
panel.Parent = someParent
```
- Returns an `ImageLabel` (or `Frame` fallback for an unknown key) with slice/stretch/fit already configured.
- The 2nd arg is a flat props table applied to the instance (`Name`, `Size`, `Position`, `ZIndex`, `ImageTransparency`, `AnchorPoint`, `Visible`, …).
- An **unknown key never errors** — it returns a plain dark `Frame` — so a typo silently loses the art. Copy key names exactly from the list below.
- For hover/active states, create the idle Shell + the hover/active Shell stacked, start the non-idle ones at `ImageTransparency = 1`, and cross-fade with `Animations.tween`.

### 3.1 Full key reference (use the right one for the job)

**Panels / windows**
`panel_large_shell` (big screens) · `panel_medium_shell` · `panel_small_shell` · `panel_sub_shell` (nested sub-panel) · `panel_wide_shell` · `panel_card_tall_shell` (tall detail card) · `panel_modal_shell` (centered modal) · `panel_modal_header_shell` · `modal_footer_shell` · `panel_title_plaque_shell` · `panel_tooltip_shell` · `window_frame_close_slot`

**Rows**
`panel_row_shell` (generic row) · `panel_row_selected_shell` · `nation_list_row_shell` / `nation_list_row_selected` (country list rows) · `treaty_row_shell`

**Cards / tiles**
`building_card_shell` · `doctrine_card_shell` · `law_card_shell` · `policy_card_shell` · `mission_tile_shell` · `resource_tile_shell` · `unit_card_shell`

**Buttons** (each has `_default` + state variants)
`button_primary_default/hover/active/disabled` (gold CTA) · `button_secondary_default/hover/active/disabled` · `button_ghost_default/hover/disabled` (subtle) · `button_success_default/hover/disabled` · `button_danger_default/hover/disabled` · `button_small_action_default/hover/active/disabled` · `button_icon_square_default/hover/active/disabled`

**Tabs / sidebar / chips**
`tab_horizontal_idle/hover/active/disabled` · `tab_vertical_idle/hover/active/disabled` · `sidebar_item_idle/hover/active/disabled` · `underline_idle/focus/warning/disabled` (tab underline) · `keycap_badge_shell`

**Inputs**
`search_box_shell` · `input_field_shell` · `dropdown_shell`

**Pills / badges / status**
`pill_green/amber/red/grey` (status tags) · `stat_pill_shell` (HUD stat capsule) · `status_badge_rect/circle/diamond/hex/shield` · `notification_badge_circle/shield`

**Progress / sliders / balance**
`progress_track_long/medium/short` · `progress_fill_green/amber/red/grey_long` (and `_short`) · `balance_track_shell` · `balance_fill_green_right` · `balance_fill_red_left` · `slider_knob_diamond` · `slider_knob_vertical`

**Dividers / trim / ornament**
`divider_line_thin` · `divider_line_double` · `divider_section_gap` · `divider_ornate_diamond` · `trim_gold_hairline_long` · `trim_gold_focus_long` · `frame_thin_small/medium/large` · `frame_card_trim` · `frame_inset_wide` · `frame_focus_plaque` · `frame_selected_row` · `frame_selected_large` · `corner_tl/tr/bl/br` · `ornament_diamond_center` · `ornament_small_star_line`

**Slots** (image placeholders)
`slot_flag_rect/square/banner` (flag slots) · `slot_emblem_rect` · `slot_portrait_ring` · `slot_badge_square/shield`

**HUD-specific**
`hud_country_bar_bg` · `hud_medallion_ring` · `date_speed_shell` · `map_mode_button_shell` / `map_mode_button_active` · `speed_button_default/hover/disabled` · `notification_shell` · `notification_large_shell`

> If you need a kind of surface that isn't listed, pick the closest existing Shell — **do not invent one.** Flag the gap to the user.

---

## 4. Icons (`DesignSystem.Icons`)

```lua
local icon = Icons.create("Treasury", 16, Colors.TextSecondary)  -- key, size px, tint
icon.Parent = pill
```
Returns a square `ImageLabel` (aspect-locked). Unknown key → empty image (no error), so spell keys exactly.

**Available keys:** `Treasury, Manpower, PowerProj, Stability, Legitimacy, Prestige, Research, Trade, Army, Navy, Cannon, Battle, War, Shield, Fort, Ship, Anchor, Economy, Military, Building, Factory, Market, Production, Goods, GoodCoal, GoodGrain, Diplomacy, Core, Unrest, Pause, Play, FastForward, Menu, Settings, SettingsSmall, Search, Filter, Close, Pin, Bookmark, Check, More, Plus, Minus, Eye, Lock, Star, Info, Warning, Notification, MapPolitical, MapTerrain, MapTrade, MapCulture, MapReligion, TabOverview, TabFactions, TabLeaders, TabPolicies, TabLaws, TabDoctrines`.

If the icon you want isn't here, use a text label — **never an emoji.**

---

## 5. Component library (`UI/Components`)

All return either an instance or a `{ ... }` handle. All take a single `config` table. `parent` in config auto-parents. Exact signatures:

### Button — `Button.create(config) -> TextButton`
```lua
local btn = Button.create({
    variant = "primary",   -- "primary"|"secondary"|"ghost"|"success"|"danger" (default "secondary")
    size = "lg",           -- "sm"|"md"|"lg" → heights 30/38/46 (default "md")
    text = "Play",
    width = 200,           -- omit to auto-size to text (AutomaticSize.X)
    disabled = false,
    onClick = function() end,
    layoutOrder = 1,
    parent = row,
})
```
- Variant maps to `button_<variant>_default/hover/disabled` Shells with cross-fade hover.
- **To enable/disable later:** set `btn.Active = false` / `true` (it auto-swaps the disabled Shell + dims the label). There is no `SetDisabled` method.
- The label TextLabel is named `"Label"` (`btn:FindFirstChild("Label").Text = ...` to relabel, e.g. "Play as France").

### CountryBadge — `CountryBadge.create(config) -> Frame`
Flat 3-letter country code on a dark tint of the country color.
```lua
CountryBadge.create({
    code = "FRA",
    countryColor = country.color,  -- accepts a Color3 OR a {r,g,b} array (0-255)
    size = "sm",                   -- "sm"|"md"|"lg" → 36x28 / 48x40 / 64x52
    parent = row,
})
```

### StatRow — `StatRow.create(config) -> (Frame, valueLabel)`
A label + right-aligned value, optional icon/delta/progress. The workhorse for stat lists.
```lua
StatRow.create({
    icon = "Treasury",        -- optional Icons key (indents label 26px); omit for text-only rows
    iconColor = "secondary",  -- Color3 or semantic string
    label = "Treasury",
    value = "£21.6K",         -- pre-formatted string (see Section 9)
    valueColor = "positive",  -- Color3 or semantic string; default cream
    mono = true,              -- value uses mono font
    delta = "+10.5K", deltaColor = "positive", deltaNum = 10500,  -- optional secondary line
    progress = { value = 3, min = 0, max = 10, color = "amber" }, -- optional inline bar (color = key)
    height = 36, layoutOrder = 4, parent = body,
})
```
Returns `(frame, valueLabel)` — capture `valueLabel` to mutate `.Text`/`.TextColor3` later without rebuilding.

### SectionDivider — `SectionDivider.create(config) -> Frame`
Centered letter-spaced uppercase header flanked by adaptive gold-ish hairlines. Pass normal-case text; it uppercases + letter-spaces. The rules flex to fit, so it never overflows.
```lua
SectionDivider.create({ parent = body, label = "Government", layoutOrder = 3 })
```

### TabBar — `TabBar.create(config) -> { root, setActive, entries }`
```lua
TabBar.create({
    tabs = { { key = "overview", label = "Overview" }, { key = "laws", label = "Laws" } },
    style = "underline",  -- "underline" (default) or "segment" (uses tab_horizontal_* shells)
    align = "left",       -- "left" or "center" (default)
    active = "overview",
    onChange = function(key) end,
    parent = header,
})
```

### ProgressBar — `ProgressBar.create(config) -> (root, setValue)`
```lua
local bar, setValue = ProgressBar.create({
    value = 70, min = 0, max = 100,
    color = "green",       -- KEY: "green"|"amber"|"red"|"grey" (shell mode)
    length = "long",       -- "long"|"medium"|"short" (picks track shell)
    height = 10, parent = body,
    -- flat = true,        -- alt: plain rounded Frame; then `color` must be a Color3
})
setValue(85, "amber")      -- animated; in shell mode newColor is a KEY
```

### Modal — `Modal.create(config) -> { root, panel, header, content, footer, open, close }`
Centered modal with scrim, title/subtitle, gold close X, optional footer button row.
```lua
local modal = Modal.create({
    title = "Declare War", subtitle = "Choose a target",
    width = 540, height = 440,
    footer = true,               -- adds a right-aligned footer button row
    dismissable = true,          -- clicking scrim closes (default true)
    onClose = function() end,
    parent = ctx.modalLayer,     -- mount in the Modals layer
})
-- put content into modal.content (it has padding); buttons into modal.footer
```

### Tooltip — `Tooltip.create(config) -> ImageLabel` and `Tooltip.attach(target, builder)`
`tooltip_shell`-based. `create` builds content (`title`, `body`, `rows = {{label,value,color}}`, `width`). `attach(target, function() return Tooltip.create{...} end)` shows it on hover.
**Caveat:** `Tooltip.attach`'s built-in follow uses raw mouse pixels and does **not** divide by the layer `UIScale` — fine for tooltips inside an unscaled context, but for a cursor-following tooltip on a scaled HUD layer position it manually (Section 10.4) and set `root:SetAttribute("AoWInputSink", false)`.

### NotificationCard — `NotificationCard.create(config) -> { root, dismiss }`
```lua
NotificationCard.create({
    severity = "success",  -- "info"|"success"|"warning"|"danger"
    title = "Province captured", body = "Optional detail",
    ttl = 8,               -- auto-dismiss seconds
    onDismiss = function() end, parent = holder,
})
```
Prefer `Hud.notify(...)` (Section 8) instead of building these directly.

### Panel / ProvinceTooltip
`Panel` is a generic titled container; `ProvinceTooltip` is the in-game map hover tooltip (already wired). You rarely instantiate these directly.

---

## 6. Building a full screen — use `ScreenKit`

**Always** scaffold panel screens with `UI/Screens/ScreenKit` so the header, close button, tab strip, scrolling body, padding, and the `AoWInputSink` attribute are all correct and consistent.

```lua
local ScreenKit = require(script.Parent.ScreenKit)

function MyScreen.create(ctx)
    local handle = ScreenKit.open(ctx, {
        name = "MyScreen",
        shell = "panel_large_shell",       -- default; or panel_medium_shell etc.
        title = "Economy",
        subtitle = "Treasury & trade",     -- optional
        width = 440,                        -- or size = UDim2.new(...)
        tabs = { { key = "tax", label = "Tax" }, { key = "trade", label = "Trade" } },  -- optional
        activeTab = "tax",
        onTab = function(key) ... end,
    })
    local body = handle.body  -- a ScrollingFrame with vertical UIListLayout + padding

    ScreenKit.section(body, "Income", 1)
    ScreenKit.stat(body, { icon = "Treasury", label = "Balance", value = "£21.6K", valueColor = "positive", layoutOrder = 2 })
    ScreenKit.note(body, "Wrapped secondary text.", 3)
    ScreenKit.spacer(body, 8, 4)
    local row = ScreenKit.buttonRow(body, 5)
    Button.create({ variant = "primary", text = "Collect", parent = row })

    return handle  -- { root, header, body, tabs, clearBody, destroy }
end

return MyScreen
```
- `ctx` is supplied by the Hud (Section 8): `ctx.parent` (the Screens layer), `ctx.onClose`, `ctx.modalLayer`, `ctx.tooltipLayer`, `ctx.hudLayer`, plus app context you set via `Hud.setContext` (`cache`, `fire`, `registries`, `tag`, `openArmyPanel`, …).
- `ScreenKit.open` sets `AoWInputSink = true` on the root for you (Section 10.1).
- Add rows in LayoutOrder; `body` auto-scrolls and auto-sizes its canvas.
- The screen module **must** return a table with `.create(ctx)` returning `{ root, destroy }` (ScreenKit's handle satisfies this).

---

## 7. Wiring a new screen into the Hud menu

Screens are opened by name. To register one:
1. Put the module at `UI/Screens/<Name>Screen.luau` returning `{ create(ctx) -> handle }`.
2. Add it to `Hud.SCREEN_MODULES` (`Name = "NameScreen"`) and, if it's a top-menu, to `MENU_KEYS` / the CountryBar `MENUS` list.
3. It opens via `Hud.openScreen("Name")`, which requires the module, calls `create(mergedCtx)`, and tracks it as the active screen (opening another closes it).

---

## 8. The Hud manager (`UI/Hud`)

The Hud owns a set of stacked `ScreenGui` **layers** (each with the Responsive UIScale + `ZIndexBehavior.Sibling`):

| Layer | DisplayOrder | IgnoreGuiInset | For |
|---|---|---|---|
| `Hud` | 10 | false | persistent chrome (CountryBar, TopBar, MapModeGrid, gear) |
| `Screens` | 20 | false | menu screens, province/army/fleet panels |
| `Modals` | 50 | true | modals, nation selection |
| `Notifications` | 60 | false | toast column |
| `Tooltips` | 80 | true | cursor tooltips |

Get a layer with `Hud.getLayer("Modals")`. Mount screens into the layer ScreenKit/`ctx.parent` gives you — don't create your own top-level ScreenGui.

**Public API (use these; don't reach around them):**
- `Hud.openScreen(name, props)` / `Hud.closeScreen()` — menu screens (one active at a time).
- `Hud.openProvince(data)` / `Hud.openArmyPanel(data)` / `Hud.openFleetPanel(data)` — context panels.
- `Hud.openSettings()`, `Hud.openNationSelection(opts)` / `Hud.closeNationSelection()`, `Hud.openPeaceTreaty(treaty)`.
- `Hud.setCountry(data)` — refresh the CountryBar.
- `Hud.setClock(dateString)`, `Hud.setMapMode(key)`.
- `Hud.notify({ kind = "success", title = ..., body = ..., ttl = 8 })` — toast (don't build NotificationCards yourself).
- `Hud.setContext(t)` — merge values into the ctx every screen receives.
- `Hud.getLayer(name)`, `Hud.bind(handlerMap)`, `Hud.isStarted()`.

Hotkeys: `1` Politics · `2` Economy · `3` Military · `4` Diplomacy · `5` Research · `6` Missions · `Esc` closes the active screen + context.

---

## 9. Numbers, data, and formatting

### 9.1 Read live data from `ClientStateCache` (`Modules/ClientStateCache`)
Never hardcode lists. Getters: `getCountry(tag)`, `getProvince(id)`, `getArmy(id)`, `getFleet(id)`, `getWar(id)`, … and `allCountries()`, `allProvinces()`, `allArmies()`, … (each returns the live keyed table — treat read-only).
Subscriptions:
- `onChangePrefix("countries", fn)` → fires on **incremental** per-record deltas. Returns an unsubscribe fn.
- `onChange("snapshot", fn)` → fires when the **full snapshot** lands. **You must subscribe to this too** if your UI must react to the initial replicated state — the full snapshot does NOT fire the per-collection prefixes. (This exact omission once caused the nation-selection screen to never open.)
- `isReady()` → has the first snapshot arrived. `revision()` → monotonically increasing.
- **Debounce** subscription callbacks (set a dirty flag + `task.defer`) — they can fire many times per packet.

### 9.2 Number formatting — never `tostring(number)`
Raw floats render as `139.199999999`. Use a formatter. The HUD path already has these in `HudWiring.luau` (reuse the same shapes in new code):
- `abbreviate(n)` → `139` (<1000, rounded) · `70.0K` · `1.50M` · `2.30B` (signed).
- `money(n)` → `£` + abbreviate (em-dash on non-number).
- `delta(n)` → `+10.5K` / `-2.4K` (nil for 0).
- `signed(n)` → rounded signed integer: `+3` / `-2` / `0` (use for stability-like stats; **round** — these stats can become fractional).
- For "whole stays whole, fraction → one decimal" use: `n % 1 == 0 and tostring(n) or string.format("%.1f", n)`.

**Apply compact formatting to treasury, income, manpower, political power, stability, legitimacy, province counts — every numeric the player sees.** Keep the underlying data untouched; format only at display.

---

## 10. Critical conventions & gotchas (these caused real bugs)

### 10.1 `AoWInputSink` — UI vs map clicks
The map uses raycasting and checks `isMouseOverUI` by walking up from the GUI under the cursor looking for an `AoWInputSink` attribute:
- Set `root:SetAttribute("AoWInputSink", true)` on a panel/card to make it **swallow** map clicks (the default for screens via ScreenKit). Children inherit via the upward walk — only the panel root needs it.
- Set `AoWInputSink = false` on something that must **not** block the map underneath it (e.g. a cursor tooltip).
- Leave it unset on transparent structural frames so clicks pass through to the map.
- **Never** set `AoWInputSink=true` on a full-screen transparent root or use `Modal=true` over the map unless you intend to block the entire map.

### 10.2 ZIndex
Layers use `ZIndexBehavior.Sibling`. Within a panel, raise `ZIndex` for content above the Shell background (Shell at `z`, content at `z+1`, text at `z+2`, etc.). Keep it consistent with the file you're editing.

### 10.3 Truncation, not overflow
Long text must `TextTruncate = Enum.TextTruncate.AtEnd` within a fixed-width label, or use compact numbers. Give name/subtitle blocks a safe max width. Don't let labels auto-grow into neighbors. For headers that sit between rules, the rules should flex (see `SectionDivider`) — never fixed-width side rules that can overflow.

### 10.4 Cursor-following tooltips under a UIScale (resolution-safe)
Because HUD layers have a `ResponsiveScale` UIScale, position a cursor tooltip like this:
```lua
local function follow()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local sg = tooltip.Parent
    local us = sg and sg:FindFirstChildWhichIsA("UIScale")
    local scale = (us and us.Scale) or 1
    local size, mp = tooltip.AbsoluteSize, UserInputService:GetMouseLocation()
    local x, y = mp.X + 16, mp.Y + 18
    if x + size.X > vp.X - 8 then x = mp.X - 16 - size.X end   -- flip near right edge
    if y + size.Y > vp.Y - 8 then y = mp.Y - 18 - size.Y end   -- flip near bottom edge
    x = math.clamp(x, 8, math.max(8, vp.X - size.X - 8))
    y = math.clamp(y, 8, math.max(8, vp.Y - size.Y - 8))
    tooltip.Position = UDim2.fromOffset(x / scale, y / scale)   -- divide by scale!
end
```
`GetMouseLocation` is already in true top-left space (matches an `IgnoreGuiInset=true` layer), so no inset term — just divide by `scale`. Omitting `/scale` makes the tooltip drift toward the top-left.

### 10.5 Fixed-size HUD elements vs the viewport
Persistent HUD pieces (CountryBar, MapModeGrid) are fixed-size and anchored to corners. When changing a width, check it doesn't collide with the opposite-corner element or the notification column at common resolutions (1280×720 and 1920×1080). The notification column's left edge ≈ `viewportWidth − 356`.

---

## 11. Copy-paste recipes

**A stat pill (HUD capsule):** `Shells.create("stat_pill_shell", {Size = UDim2.fromOffset(104,36)})` + an `Icons.create(...)` at left + a `value`-role label with `TextTruncate.AtEnd` and internal padding.

**A selectable list row:** stack `nation_list_row_shell` (idle) + `nation_list_row_selected` (start `ImageTransparency=1`) in a `TextButton`, cross-fade on select; add a `CountryBadge`, a `displayMd` name, a `bodySm` warm-grey subline, and an optional `pill_grey` "Taken" tag.

**A filter chip:** `tab_horizontal_idle/hover/active` stacked in a `TextButton` with a `caption` label; active = gold text + `_active` shell visible (rectangular — never a big rounded pill).

**A detail card:** `panel_card_tall_shell` with `AutomaticSize.Y`, padding `space4`, vertical `UIListLayout` `space2`; flag via `slot_flag_rect`; `SectionDivider` headers; `StatRow`s for stats.

---

## 12. Anti-patterns — do NOT

- Invent new frames/panels/buttons/art, or upload/reference new asset IDs.
- Replace a V2 surface with a plain colored `Frame`, gradient, or custom `UIStroke` decoration.
- Use emojis or unicode glyphs as icons/bullets.
- Use `TextScaled`, or `tostring(number)` for displayed numbers.
- Hardcode country tags, province ids, or lists; bake names/flags into images.
- Use parchment, wood, faux-metal, fantasy ornamentation, bright saturated modern colors, glows, or heavy 3D bevels.
- Overuse gold (gold = active/selected/focused only).
- Build a full-screen modal that covers the map when a side panel would do; block map clicks you didn't mean to.
- Reimplement Button/StatRow/TabBar/Modal/Tooltip/SectionDivider/ScreenKit instead of reusing them.

---

## 13. Verifying your work

This is a **Rojo** project (file → Studio one-way sync at `localhost:34872`). Edit the `.luau` files on disk; Rojo syncs them.

Before saying you're done:
```bash
selene src                 # must be 0 errors (existing warnings are pre-existing house noise)
stylua --check <yourfile>  # must be clean; run `stylua <yourfile>` to auto-format (tabs)
```
In Studio (read-only for source — do not edit scripts via MCP), the Luau analyzer should report 0 diagnostics for your file. Note two Studio gotchas when testing via the live tools: edit-mode `require` caches modules, and the script compiler can lag a fast Rojo write — clone the tree / re-check after it settles, and trust on-disk source + the formatters/analyzer over a flaky live render. Full UI that needs a `LocalPlayer` (the HUD) only mounts in an actual playtest, not edit mode.

---

## 14. TL;DR checklist for any UI change

- [ ] Visible surfaces are `Shells.create(...)` keys; icons are `Icons.create(...)`; no new art.
- [ ] Colors/fonts/gaps come from `Colors` / `Typography.apply` / `Spacing`.
- [ ] Reused `ScreenKit` + existing Components instead of hand-rolling.
- [ ] Every number runs through a formatter; no raw floats.
- [ ] Data read live from `ClientStateCache`; nothing hardcoded.
- [ ] `AoWInputSink` set correctly; cursor tooltips divide by the layer `UIScale`.
- [ ] Long text truncates; nothing overflows or overlaps at 720p and 1080p.
- [ ] No emojis/unicode icons; gold only for active/selected.
- [ ] `selene` 0 errors, `stylua --check` clean, analyzer clean.
