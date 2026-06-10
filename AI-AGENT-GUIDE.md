# AI Agent Guide — Art of War

This is for any AI coding agent (Claude or otherwise) working on this repo, on **any** developer's machine. Read it at the start of a session, follow it, and — if you keep a memory — record the rules below so you don't relapse to the old way.

## The one shift that matters most

This project used to live **only inside Roblox Studio**, and agents read/wrote script source through the Studio MCP (base64 console dumps and HTTP-fetch writes). **That era is over.** The code is now a folder of `.luau` files synced into Studio by **Rojo**, version-controlled on **GitHub**.

So, the rule that changes everything:

> **Edit the FILES, never the scripts inside Studio. Use the Roblox Studio MCP for read-only and runtime work only — never to write script source.**

Editing a script in Studio now accomplishes nothing lasting: Rojo overwrites it from the files on the next sync. All code changes happen in the `src/` files with your normal Read / Edit / Write tools.

## Mental model

```
   src/**.luau  ──(rojo serve, one-way, live)──►  Roblox Studio  ──(publish)──►  players
   (the source of truth, in git)                  (the place: map, GUI,
                                                    Remotes, RelayConfig —
                                                    NOT in git)
```

- **Files = source of truth.** Every game script is a `.luau` file under `src/`, mirroring the Studio tree.
- **Rojo** is a one-way live bridge. While `rojo serve` runs (a dev starts it; on Windows that's `serve-aow.bat`), every file save lands in Studio instantly. It only pushes files → Studio, so it can never corrupt the files or the repo.
- **The place** (`.rbxl`) owns everything that isn't a script: the ~17k-part map geometry, GUI frames, RemoteEvents, and `RelayConfig`. It is **not in git** — it's shared separately and is the source of truth for non-script content.
- **`default.project.json`** maps files into the DataModel. Every container it manages is marked `ignoreUnknownInstances`, which is what stops a sync from ever deleting the map, the Remotes, or the GUI. The same flag is set in the `init.meta.json` files. **Never remove it.**

## Golden rules

1. **Edit scripts only as files.** Never edit a managed script in Studio. (Geometry / GUI / map changes are the exception — those happen in Studio and save to the place. Only *scripts* come from files.)
2. **The place is binary and out of git.** Never commit a `*.rbxl` / `*.rbxlx`. Never move `RelayConfig` into git — it holds the cross-universe relay secret and stays place-resident.
3. **Rojo file naming:** ModuleScript = `Name.luau`, server Script = `Name.server.luau`, LocalScript = `Name.client.luau`, a ModuleScript that has child instances = a folder `Name/init.luau`.
4. **Leave the `ignoreUnknownInstances` flags alone** — in `default.project.json` and in `init.meta.json`. They are deliberate and they're the whole reason a sync is non-destructive.
5. **`git pull` before you start** (two developers share this repo), and commit in reasonable chunks.

## The Roblox Studio MCP is READ-ONLY now

**Use it for:**
- `get_script_analysis` — compile-check scripts (Roblox `loadstring`) after edits. This is the authoritative compile check; run it on the containers you touched and aim for zero errors.
- `execute_luau` — read-only checks of live state, and deterministic unit-tests: `require` the synced module and call its functions (e.g. test `CombatEngine.resolveRound` with a hand-built input), or `loadstring` a fresh copy with a fake `ctx`. The synced module *is* the current code, so this verifies real behavior without editing anything.
- `get_output_log`, `start_playtest` / `get_playtest_output` — runtime verification.
- Reading instance properties / map state.

**Never use** (these write script source, which desyncs the files from Studio — Rojo then overwrites your edit, and the file, which is the real source, never changed): `set_script_source`, `find_and_replace_in_scripts`, `edit_script_lines`, `insert_script_lines`, `delete_script_lines`. To read code, read the **files**, not the Studio script source. (`find_and_replace_in_scripts` also misreports its counts — another reason to ignore it.)

**Performance caveat:** the live map has ~17,000 parts. Never iterate all workspace children in `execute_luau` — it can OOM Studio (which runs under Wine/Vinegar on at least one machine). Query narrowly and exit early.

## The development loop

1. A developer opens the **private** place ("Art of War Debug") in Studio, starts `rojo serve`, and connects the Rojo plugin.
2. **You edit the `src/**` files** to make the change — it syncs into Studio live.
3. **You verify:** `selene src` (parse + lint; config is in the repo) **and** `get_script_analysis` on the touched containers (Roblox compile). Zero errors before committing.
4. **You commit + push:** `git add -A && git commit -m "..." && git push`. The clone is already configured to credit the right developer (see *Commit identity*). `git pull --rebase` first if the push is rejected.
5. The developer publishes to players from Studio (Ctrl+S → File → Publish to Roblox As → "Art of War Playtesting"). Agents don't publish.

## The two universes and the relay (don't fear breaking data)

Two published games run the same code:

- **Private dev** — universe `10041569799`, place `126275639019912` ("Art of War Debug"). This is where devs serve and test.
- **Group game** — universe `10042966553`, place `101881400801704` ("Art of War Playtesting"). Where players get it.

Each has its own DataStore, and an external Cloudflare relay mirrors saved data between them. **This data layer is entirely separate from the code** — Rojo never touches DataStores or the relay, so editing scripts cannot break the sync. The relay secret lives in `RelayConfig` in the place, never in git.

## Repo layout (where things are)

- `src/ServerScriptService/ArtOfWar/` — `Bootstrap.server.luau`, `Framework/` (7), `Systems/` (38)
- `src/ServerScriptService/DataEditorService.server.luau`
- `src/ReplicatedStorage/ArtOfWar/` — `Data/` (31), `Events/Channels.luau`, `Modules/` (21), `Shared/` (Types, WorldConstants), `UI/` (panels + `UI/Tabs/`)
- `src/ReplicatedFirst/`, `src/StarterPlayer/StarterPlayerScripts/ArtOfWar/`, `src/StarterGui/DataEditorUI/`
- `src/ServerStorage/Dev/` and `Services/` — the in-game data-editor backend
- `default.project.json`, `rokit.toml`, `selene.toml`, `stylua.toml`, `tools/`
- Docs: `README.md`, `TEAM_PROMPT.md`, `WINDOWS-SETUP.md` (the Windows click-to-run guide), this file.

## Project specifics & sensitive areas

- **The in-game data editor** (`ServerStorage/Dev/DataEditor.luau`, `DataEditorService.server.luau`, `StarterGui/DataEditorUI/EditorClient.client.luau`, `ServerStorage/Services/*`) is the can't-break zone — mappers use it live to paint the world, and its data lives in the shared DataStore. Change it carefully and verify thoroughly.
- **Combat is deterministic by design** — `WorldConstants.OfficerRngSeed = 13337`, seeded RNG, **no luck term**, so battles are replayable. Don't introduce nondeterminism (`math.random` without a seed, time-based jitter) into combat resolution.
- **Most Remotes are created at runtime** by `Bootstrap` (`bindEvent` / `ensureEvent`); only a couple are static. Don't try to model the runtime ones as files, and don't double-bind them.
- **The map geometry is not in git** — province parts live in the place; the political colors and ownership are painted at runtime from the DataStore overlay.

## Commit identity

Each developer's clone is configured (locally, via `git config`) to commit as that developer — **Vernal / Vliysl** on Vernal's machine, **Avierns / avierns-dev** on Avierns's. This is set once during setup. Don't change it; just commit normally and the right person gets credited.

## Code conventions

- **No comments.** The codebase has none — match it. Clean, modular Luau, no dead or unused code, no spaghetti.
- Server-authoritative; RemoteEvents are validated server-side; ModuleScripts return a table.
- Match the surrounding style exactly.
- Editing the **files** (Edit / Write) is the reliable path. Always verify a change compiles (`selene` + `get_script_analysis`) before you commit.

---

If you keep a persistent memory: save the shift (edit files, not Studio), the MCP read-only rule, the golden rules, the two places, and the commit-identity setup — so future sessions start correct. For the human-facing setup walkthrough, see `WINDOWS-SETUP.md`; for the shorter workflow note, `TEAM_PROMPT.md`.
