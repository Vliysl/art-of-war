# Map Editor: Snapshot Saves on a Single Shared Editor Server + Live Sync

**Status:** WRAPPED UP behind `SINGLE_SERVER_EDITOR` (default OFF). Phases 0-5 implemented + adversarially
reviewed (2 passes) + double-checked (4 invariants); 4 review bugs + 6 coherence gaps all fixed; lint-clean.
**Owner chose to DEFER Phase 7 deletion until after a 2-player Team Test** (keep legacy as a flag-flip fallback).
Remaining (owner-driven, after the test): Phase 7 (retire diffBundles/promote/MERGE_SAVES/drafts), per-user undo
(undo/redo currently DISABLED in single-server mode). **To enable/test:** flip the flag → Studio Team Test.

### Final double-check (2026-07-07) — 4 invariant checks. flag-OFF path UNCHANGED, the 4 review fixes CORRECT,
### and live-game ISOLATION all verified to hold. flag-ON coherence found 6 gaps — ALL FIXED:
- **[HIGH]** `writeFullSnapshot` had no read-failed guard → a boot DataStore read failure on a source-less kind
  (tiles/eu4map) would blank that `:edit` aggregate on Save. Fix: all-or-nothing `cache.loadStatus=="read_failed"`
  refusal (DataOverlay), mirroring flush/saveNamedConfig.
- **[MED]** non-blessed server showed the wrong "off the editor place" message → now says "not the editing server,
  reopen from the blessed link" (service write-gate).
- **[MED]** `canWriteHere` was returned but unread → client now surfaces a read-only banner on load (`snapshotState`
  carries `canWriteHere`; client `ensureLoaded` reads it).
- **[MED]** legacy staging commands (promote/saveDraft/…) still ran under the flag (guarded on `STAGING_ENABLED`,
  not mode) → new `STAGING_ONLY_COMMANDS` set rejected in single-server mode.
- **[LOW]** non-blessed read-only server was stuck stale (reloadState skipped `Editor.load()`) → now only the
  blessed WRITER skips the re-read; read-only servers reload.
- **[LOW]** a live VIP server would claim the blessed crown when the flag is on → `ensureWriteAuthority` + boot
  resolve now gated on `EditorAdmins.isMapEditorPlace()`.
All lint-clean. NOTE: the new model is REVIEW-verified but NOT yet playtested (can't run a 2-player Team Test here).

### Adversarial review (2026-07-07) — 5 dimensions, each finding independently verified. Snapshot-save and
### blessed-server dimensions came back CLEAN. 4 confirmed bugs found + FIXED:
- **[HIGH, fixed]** `worldDirty` was only set for `LOG_ACTIONS` commands, so `setTileOwner`/`undo`/`redo`
  mutated without marking dirty → crash-safety could silently drop them. Fix: set `worldDirty` for ANY
  successful non-read-only, non-`save` command (DataEditorService `~1976`).
- **[HIGH, fixed]** Shared global undo/redo stack in single-server mode → one editor's Undo reverts another's
  edits (full-snapshot undo wipes co-editors' work). Fix: **undo/redo DISABLED in single-server mode** (service
  handlers return a clear error). Per-user undo is the planned follow-up (see §Phase 1 undo note).
- **[LOW, fixed]** A province delta during initial paging could be clobbered by a stale page. Fix:
  `livePatchedProvinces` guard set — the fill loop skips ids a delta already patched (client).
- **[LOW, fixed]** Country dirty-gate compared widget values against the record, so a nil `displayName`/`color`
  read as "changed" and shipped `""`/default. Fix: `fieldSame` treats empty-string==nil and the {150,150,150}
  colour default==nil as unchanged (client `~1600`).
**Chosen model:** Single shared editor server + real-time live sync. Save = full snapshot of the shared world, **no merge**.
**Branch base:** `combat-update-v1`

### Progress log
- **Phase 0 done** — country detail Save dirty-gated (`EditorClientV2.client.luau` edit branch, ~:1595): sends
  only changed fields, matching the province Save. Standalone win, active regardless of the flag.
- **Phase 1 done** — `SINGLE_SERVER_EDITOR` flag + `DataEditor.isSingleServerMode()` (`DataEditor.luau:46`).
  Under the flag: `setActiveUser` is presence-only (no per-user world swap, just `ensureLoaded`);
  `clearActiveUser`/`dropUserState` never drop the shared world (no `loaded=false`). One shared world for all
  editors on the server.
- **Phase 4 done** — `DataOverlay.writeFullSnapshot(worldByKind)` (`DataOverlay.luau:927`) full-overwrites each
  `:edit` key (guards: empty provinces/countries refused, size cap, adopts into cache + clears journal).
  `DataEditor.snapshotSave()` (`DataEditor.luau:1967`) promotes painted tiles then snapshots the shared world.
  Service `save` handler routes to it under the flag; `reloadState` no longer re-reads DataStore under the flag
  (would clobber unsaved shared edits) — it just re-sends the shared snapshot.
- Verified: `selene` 0 errors / 0 parse errors on all 4 files.
- **To test:** flip `SINGLE_SERVER_EDITOR = true`, run a 2-player Studio Team Test (a Team Test is one shared
  server + `IsStudio()` → writes `:edit`, live game untouched). Edit different + same records on both clients,
  Save, confirm nothing is lost. Not yet: crash-safety (Phase 5), live per-edit view (Phase 3).

---

## 1. Goal

Map editors currently lose each other's work when editing concurrently. Replace the multi-layer
merge with a model where:

- **All map editors sit on ONE server instance** and edit **one shared in-memory world**.
- **Every edit broadcasts live** to all other editors (shared view, like Figma/Google Docs).
- **Save takes a full snapshot** of that shared world and overwrites the `:edit` DataStore keys —
  no 3-way diff, no per-record UpdateAsync merge.

Because everyone always sees the same live world, a whole-world snapshot can't drop anyone's work.
The only residual conflict is two editors changing the *same field* in the same instant
(last keystroke wins) — unavoidable and acceptable.

---

## 1b. Double-check verdict (added after a deeper code pass)

The single-server + snapshot plan is **structurally sound** — it does eliminate lost work — but the
double-check turned up three things that change the cost/benefit and must fold into the plan:

1. **Live sync is UX, not correctness.** On one shared server, every edit already lands *immediately* on
   the shared world via field-patch writes (`updateCountry:622`, `updateProvince:777` both do
   `for k,v in pairs(opts) do rec[k]=v end`; `paintProvinceTag:798` is per-tag idempotent). So the
   server world is always the union of everyone's edits regardless of what any client screen shows. A
   snapshot of it is always complete. **Correctness = single world + snapshot + autosave. Live sync is
   the "see each other live" polish** (Phase 3 can follow the core, not gate it).

2. **The country detail Save is a latent clobber even on one server, and must be fixed.** The province
   Save is already dirty-gated — it sends a field only if the user changed it (`EditorClientV2:2077`).
   The **country** Save is not: it blindly sends 7 fields from local widgets (`EditorClientV2:1566`).
   Because `updateCountry` patches those exact keys, editor B saving FRA reverts the other 6 fields to
   B's stale values — single server or not, live sync or not (an *open* form holds a stale snapshot).
   **Fix: dirty-gate the country Save exactly like provinces.** This is a standalone quick win that helps
   under *any* model.

3. **Single-instance can be far simpler than reserved-server + teleport.** See the revised Phase 2 — a
   designated private (VIP) server + a "only the blessed server may Save" guard removes the MemoryStore
   heartbeat and teleport machinery entirely.

### The cheaper alternative you should weigh (Option B — keep multi-server, fix granularity)

The *actual* data loss today is **whole-record last-writer-wins on the same record across servers** — the
persist layer merges at the record-key level (`writeAggregateMerged:309` journals whole records), so two
editors painting the same province or editing the same country on different servers clobber each other.
There is a much smaller fix that closes almost all of it **without** single-server, teleport, or ripping
out the merge:

- **B1.** Dirty-gate the country Save (item 2 above). ~1 client function.
- **B2.** Make the persist merge **field-level** instead of record-level: journal changed *fields* and
  deep-merge them in the `writeAggregateMerged` UpdateAsync transform. Then two editors changing different
  fields/tags of the same record both survive cross-server. Only the *same field* edited at the same
  instant is LWW — rare and unavoidable in any model.

**Cost/benefit:** Option B is ~a few functions, no matchmaking/teleport risk, no volatile in-memory world,
no autosave/crash-safety burden — and it likely eliminates the loss you're actually seeing. What it does
**not** give you is real-time collaborative UX (editors still work somewhat blind and reload on save
boundaries). Option A (single-server + live sync) is the better *experience* but a materially bigger,
riskier project (single-instance guarantee + volatile memory).

**Recommendation:** do **B1 immediately** (pure win, trivial, helps regardless). Then choose:
- If the goal is "stop losing work, minimal risk" → **B2** and stop. Keep the current architecture.
- If the goal is "real-time collaborative editing + clean snapshot model" → proceed to Option A below,
  but treat B1 as a prerequisite and use the simplified Phase 2.

---

## 1c. Scope & isolation (this is map-editor-place-only)

The entire rework is scoped to the **Map Editor place** (`PlaceId 104399454095233`, or Studio). The live
game is untouched:
- **Separate keys.** `IS_EDITOR_ENV` (`DataOverlay:22`) redirects every editor read/write to `:edit`-suffixed
  keys (`keyFor:166`). Editor saves write `aggregate:*:edit`; the live game reads the un-suffixed keys.
- **Live game is read-only w.r.t. the overlay.** Its only touch is `DataOverlay.applyTo(bundle)` at boot
  (`DataLoader:142`). No live write path exists; all `set*`/`flush`/`writeFullSnapshot` calls are editor-only.
- **Only bridge = "Push to Live"** (`pushEditToLive`), unchanged by this plan.
- **Single-server = the EDITOR place**, not the live game. The live game keeps normal many-server matchmaking.

**Hard invariant for implementation:** the live boot read path (`DataOverlay.applyTo` and what `DataLoader`
feeds it) must behave **identically before and after** every phase. Phase 4 only *adds* `writeFullSnapshot`;
Phase 7 only removes editor-only write paths (`MERGE_SAVES`/`diffBundles`/drafts). Never alter `applyTo`.
Verify: a live-game boot loads the same world after each phase.

## 2. How saving works today (what we're replacing)

Three layers of persisted data:

| Layer | Keys | Reader |
|---|---|---|
| Source ModuleScripts (`Countries`, `Provinces`, …) | — | boot baseline |
| **DataOverlay** aggregate | `aggregate:<kind>` (live) / `aggregate:<kind>:edit` (editor env) | live game / editor |
| **DraftOverlay** | `draft:<userId>:<kind>` | per-editor private backup |

`STAGING_ENABLED = true` (`DataEditorService.server.luau:12`). A **Save** (`save` command handler,
`DataEditorService.server.luau:1387`) does:

1. `Editor.saveDraft()` → dumps the editor's whole world to their private `draft:<id>:*` keys.
2. `Editor.promote(nil)` (`DataEditor.luau:2697`) — the real publish, with **three stacked merges**:
   - **Merge #1 – 3-way diff** (`DraftOverlay.diffBundles`, `DraftOverlay.luau:235`): promote only records
     the user actually changed vs their session `baseline`.
   - **Merge #2 – UpdateAsync overlay** (`DataOverlay.writeAggregateMerged`, `DataOverlay.luau:309`, flag
     `MERGE_SAVES`, `DataOverlay.luau:106`): write only journaled records into the live aggregate.
   - **Merge #3 – LiveSync reload** (`EditorClientV2.client.luau:3364`): other editors auto-reload on a
     Save boundary **only if they have no unsaved edits**.
3. Broadcast `{ sharedMoved = true }` to other editors.

Per-user server worlds are swapped in/out by `DataEditor.setActiveUser` (`DataEditor.luau:2439`) using
`userStates[userId]`, serialized by `withCommandLock` (`DataEditorService.server.luau:366`).

### Why work still gets lost
- Editors are on **different Roblox servers** (separate caches, no shared memory — the reason merges exist).
- The "shared" side of the 3-way diff is read from the **local cache** (`overlay.snapshot(false)` →
  `cache.data`, `DataOverlay.luau:1668`), stale vs another server's just-saved data.
- Result: records you didn't touch are preserved, but **same-record edits are last-writer-wins**.

### Key discovery that makes the new model cheap
`broadcastDelta` / `broadcastBatch` already fire on nearly every edit command, but **short-circuit when
`STAGING_ENABLED` is true** (`DataEditorService.server.luau:551-553`, `568-571`). A full per-edit
live-sync path already exists — it's just gated off. We revive it and remove the merge code.

---

## 3. Target architecture

```
                ┌─────────────────────────────────────────────┐
   editor A ───►│  ONE canonical editor server                 │
   editor B ───►│  • single shared in-memory world             │
   editor C ───►│  • every edit → mutate world → broadcast Δ   │◄── all editors join here
                │  • Save → full snapshot → aggregate:*:edit    │    (teleport handshake)
                │  • autosave + BindToClose crash safety       │
                └─────────────────────────────────────────────┘
                                  │  Push to Live (unchanged, separate)
                                  ▼
                        aggregate:* (live game)
```

- **No** `diffBundles`, **no** `MERGE_SAVES` journaling for the editor path, **no** per-user world swap.
- Save is a plain full-overwrite of each `:edit` aggregate (same byte size as today's full flush — no new
  size risk; today already writes each kind as one `:edit` key).
- Correctness invariant: **only the canonical server may Save** (belt-and-suspenders against a stray 2nd server).

---

## 4. Implementation plan (phased, flag-gated)

Add a flag `SINGLE_SERVER_EDITOR` (WorldConstants or DataEditorService-local). Keep the old staging path
runnable as fallback until the new model is verified, then delete the dead code (Phase 7).

### Phase 0 — Quick win, do first regardless of A vs B
*File: `EditorClientV2.client.luau`*
- **Dirty-gate the country detail Save** (`:1566`): send a field only if it changed vs the loaded record,
  exactly as the province Save already does (`:2077`). Kills the biggest same-record clobber under every
  model. Pure win, no server change. If you stop after this + Option B2, you may not need Phases 1-7.

### Phase 1 — Collapse to one shared server world
*Files: `DataEditor.luau`, `DataEditorService.server.luau`*
- Stop swapping per-user worlds: `setActiveUser` becomes presence-only; all editors mutate the single
  module-global `countries`/`provinces`/… tables. Retire `userStates` world-swap + the per-user branch of
  `withCommandLock` (keep a lock only to serialize DataStore *writes*).
- Load the shared world from `:edit` on boot (already happens via `DataOverlay.load` + `DataEditor.load`).
- **Undo/redo needs a decision** — a naïve single shared stack means your Undo pops *someone else's* last
  action (surprising). Prefer **per-user undo**: each editor's Undo re-applies the inverse of *their own*
  last op onto the current shared world (a new forward edit, not a stack rewind). More robust than a global
  stack; matches how collaborative editors behave. Flag this as a sub-decision — a global stack is simpler
  to build but worse UX. *(Behavior change either way — call out to the team.)*
- Remove `saveDraft`/`loadDraft`/`discardDraft` per-user calls from the save flow (drafts are obsolete
  once the world is shared; `DraftOverlay` is repurposed for autosave in Phase 5 or deleted).

### Phase 2 — Single-instance enforcement (simpler than first drafted)
The correctness invariant we actually need is: **only ONE blessed server may write the `:edit` world.**
Everything else is UX for getting editors onto it. Two tiers, pick per appetite:

- **Tier 1 (recommended, minimal): designated private (VIP) server + save-gate.**
  - Enable free private servers on the Map Editor place. The team always joins **one** private-server
    link. Roblox keeps them on the same instance; when it empties and later respawns, it's the *same*
    `PrivateServerId`, so the world reloads from `:edit` on boot.
  - Store the blessed `game.PrivateServerId` in a DataStore key (`meta:editorServerId`). **`save`,
    autosave, and `pushToLive` refuse to run unless `game.PrivateServerId == blessed`.** A public server
    or a second private server is automatically **read-only** — it can never overwrite. First-run: if the
    key is empty, the first private server to save claims it.
  - No MemoryStore, no heartbeat, no teleport code. ~30 lines + a guard on the write commands.
- **Tier 2 (optional polish, later): reserved-server + teleport funnel.** Auto-teleport public-place
  joiners onto the canonical server (registry in `MemoryStoreService`, TTL heartbeat, `ReserveServer` +
  `TeleportToPrivateServer`). Nicer "just join the place" UX, but real matchmaking edge cases. Only worth
  it if the private-server-link workflow proves too manual. The Tier-1 save-gate stays as the safety net
  regardless.

> Either tier makes single-instance a *correctness* property (blessed-server-only-save), not a best-effort
> hope — so a stray second server is harmless.

### Phase 3 — Revive + complete live edit broadcast
*Files: `DataEditorService.server.luau`, `EditorClientV2.client.luau`*
> **This is UX + open-form safety, not core correctness** (see §1b.1). The shared world is already correct
> without it; live sync makes editors *see* each other's work and keeps open detail forms fresh so a save
> from a stale form can't revert a field. Ship it after the core (Phases 1/4/5) is proven.
- Broadcast when the new model is on: replace the blanket `STAGING_ENABLED` early-return in
  `broadcastDelta`/`broadcastBatch` (`:551`, `:568`) with a `SINGLE_SERVER_EDITOR` gate.
- **Audit every mutating command** broadcasts a delta: add/update/remove for countries, provinces,
  cultures, religions, ideologies, governments; `paintProvinceTag`; `assignProvince`/`assignProvinceField`;
  `setTileOwner`; `promoteTile`; bulk apply. Most already call `broadcastDelta`/`broadcastBatch` — fill gaps.
- **Client: add a per-delta apply handler.** Today `DataEditorLive` only handles `sharedMoved`
  (`EditorClientV2.client.luau:3364`). Add handling for `{ kind, key, value }` and `{ batch, items }`:
  patch the in-memory snapshot, refresh the affected list row / detail pane / **map coloring** in place
  (no full reload, preserve selection). Handle deletes (`value == nil`/tombstone).
- Presence UI (`broadcastPresence`, `DataEditorService.server.luau:391`) already exists — surface "who's
  editing" so concurrent edits are visible.

### Phase 4 — Snapshot save (remove the merge)
*Files: `DataOverlay.luau`, `DataEditor.luau`, `DataEditorService.server.luau`*
- New `DataOverlay.writeFullSnapshot()` (or reuse the `saveNamedConfig` writer shape): for each kind,
  `SetAsync(keyFor(kind), fullMap)` — full overwrite of the `:edit` key. Keep the existing guards:
  - `MAX_AGGREGATE_BYTES` size ceiling (`DataOverlay.luau:27`) — refuse oversized.
  - **Never blank the map:** refuse if provinces/countries snapshot is empty (mirrors `pushEditToLive`
    guard, `DataOverlay.luau:897`).
  - Keep the mass-deletion breaker *concept* as a sanity check (`deletesAreSafe`, `DataOverlay.luau:1339`).
- New `DataEditor.snapshotSave()` replacing the `promote()` path: snapshot the shared world → `writeFullSnapshot`.
  No `diffBundles`, no journaling.
- **Optional hardening — version CAS:** store `meta:editWorldVersion`; bump via `UpdateAsync`, refuse the
  write if the stored version is newer than the one this server loaded. Cheap insurance against a stale
  server (redundant with the canonical-only guard, but defense in depth).
- Rewrite the `save` command handler (`DataEditorService.server.luau:1387`) to call `snapshotSave`, then
  broadcast a lightweight `{ sharedMoved = true }` "saved" toast (world already live-synced, so no reload
  needed — this is just a "persisted ✓" signal + `ProvinceStamper`/`AdjacencyGraph` refresh as today).

### Phase 5 — Crash safety / autosave
*Files: coordinator + `DataEditor.luau`*
- The shared world is volatile (in memory on one server). Add:
  - **Periodic autosave** — snapshot to `:edit` every N minutes (only on the canonical server, only when
    dirty).
  - **`game:BindToClose`** — final snapshot on shutdown.
  - **Last-editor-leaves** — snapshot when the editor count hits zero.
- This replaces the per-user `draft:*` backups with one shared-world backup.

### Phase 6 — Push to Live (verify unchanged)
- `pushToLive` (`DataOverlay.pushEditToLive`, `DataOverlay.luau:865`) still publishes `:edit` → live keys.
  It re-reads `:edit` fresh, so it composes fine with snapshot saves. Add the canonical-server guard. No
  other change.

### Phase 7 — Delete dead code
- Remove `diffBundles`, `promote`, `sharedSnapshotBundle` (diff usage), `MERGE_SAVES` journaling for the
  editor path, `saveDraft`/`loadDraft`/`discardDraft`, per-user `userStates`/`setActiveUser` swapping, and
  the old `DataEditor.save()` per-record-diff path — once the new model is verified. Drop `STAGING_ENABLED`.

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Teleport/reserved-server handshake edge cases (canonical dies mid-edit, reserve race) | Canonical-only-Save invariant + version CAS → a misroute is read-only, never corrupting. Frequent autosave bounds loss. |
| In-memory shared world lost on crash | Autosave interval + BindToClose + last-leaver save (Phase 5). |
| Same-field simultaneous edit | Last keystroke wins — unavoidable, rare, accepted per the chosen model. |
| Undo/redo now global | Single shared stack with author tags; document the behavior change. |
| Live-delta UI churn (flicker, stale selection) | Patch-in-place apply, preserve selection, refresh only affected rows/map cells. |
| Provinces `:edit` aggregate size | Same size as today's full flush (already one key) — no new risk; size guard stays. |

---

## 6. Testing / verification
- **Two clients** (Studio Team Test or two devices): (a) edit different regions → both persist after each
  Save; (b) both edit the same country → last keystroke wins live, no whole-map loss; (c) editor B sees
  A's paint/ownership changes appear live without reloading.
- **Single-instance:** second joiner is teleported onto the first's server; a manually-spun second server
  refuses to Save.
- **Crash safety:** kill the server between autosaves → reboot loads the last autosave; BindToClose on
  graceful shutdown persists the latest.
- **Push to Live** still publishes `:edit` → live and the main game boots the new world.

---

## 7. Suggested sequencing
0. **Phase 0 (country Save dirty-gate)** — ship now, standalone. Removes the biggest same-record clobber.
1. **Decision gate:** is the pain "stop losing work" (→ do **Option B2** field-level merge, keep the current
   architecture, stop) or "real-time collaborative editing" (→ continue to Option A below)?
2. Phase 1 (shared world) + Phase 4 (snapshot save) + Phase 5 (autosave) — the correctness core, fully
   exercisable in **one Studio Team Test** (a Team Test *is* a single shared server) before any teleport.
3. Phase 3 (live broadcast) — the collaborative UX layer, on top of the proven core.
4. Phase 2 Tier 1 (private-server save-gate) — production single-instance safety.
5. Phase 6 verify, Phase 7 cleanup. (Phase 2 Tier 2 teleport funnel only if the link workflow is too manual.)
