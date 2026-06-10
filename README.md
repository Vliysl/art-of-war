# Art of War

Source for the Art of War Roblox grand-strategy game. The Luau code lives here as files and syncs into Studio with [Rojo](https://rojo.space). The place file — map geometry, GUI instances, RemoteEvents, and the relay config — is **not** in this repository. It is shared separately and stays the source of truth for everything that isn't a script.

> **On Windows?** See [`WINDOWS-SETUP.md`](WINDOWS-SETUP.md) for a click-to-run setup and a step-by-step daily guide.

## Layout

- `src/` — every game script (141), mirroring the Studio tree
  - `ServerScriptService/ArtOfWar/` — `Bootstrap`, `Framework/` (7), `Systems/` (38)
  - `ServerScriptService/DataEditorService.server.luau`
  - `ReplicatedStorage/ArtOfWar/` — `Data/` (31), `Modules/` (21), `Shared/` (2), `UI/` (27 + `Tabs/` 6), `Events/`
  - `ReplicatedFirst/`, `StarterPlayer/StarterPlayerScripts/ArtOfWar/`, `StarterGui/DataEditorUI/`
  - `ServerStorage/Dev/` and `ServerStorage/Services/`
- `default.project.json` — the file-to-DataModel map
- `rokit.toml` — pinned toolchain (Rojo, Lune, StyLua, Selene)
- `tools/extract.luau` — one-shot exporter, place to `src/`
- `selene.toml`, `stylua.toml` — lint and format config

## What stays in the place, never here

- `workspace.ArtOfWarMap` geometry
- `ReplicatedStorage.ArtOfWar.Remotes` and the runtime `Data` folders
- `StarterGui.DataEditorUI` frames
- `ServerStorage.Dev.RelayConfig` — holds the cross-universe relay secret
- `ReplicatedStorage.Fonts` — a vendored font-asset library

Every container Rojo manages carries `ignoreUnknownInstances`, so a sync never deletes any of the above.

## Setup

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in the repo.
2. Install the Rojo plugin for Studio, plus the Rojo and Luau Language Server extensions for your editor.
3. Open the shared place in Studio.

## Daily workflow

1. `git pull`
2. `rojo sourcemap --watch --output sourcemap.json` for editor types
3. `rojo serve`, then connect from the Rojo plugin in Studio
4. Edit files. Every save syncs into Studio. Never edit a managed script inside Studio — Rojo overwrites it on the next sync.
5. Test with Play.
6. `stylua src` and `selene src`, then commit and open a pull request.

## Publishing

`rojo build` only contains scripts, not the out-of-git geometry, so publishing goes through `tools/publish.luau` (Lune). It loads a place snapshot, overlays the current `src/` scripts onto it (leaving geometry, GUI, Remotes, RelayConfig, and Fonts untouched), and uploads the result to both universes via Open Cloud:

    cp <your-place>.rbxl .export/base.rbxl
    ROBLOX_OPEN_CLOUD_KEY=<key> lune run tools/publish -- .export/base.rbxl

Add `--dry-run` to build `build/publish.rbxl` locally without uploading. Universe and place IDs live in `tools/publish.config.json`; the API key is read from the environment and never committed. The base place must sit inside the repo — Lune's filesystem is sandboxed to the project, which is why `.export/` (gitignored) exists. Re-snapshot the place whenever the geometry changes.

## Re-exporting from the place

If the place ever drifts from the files, save it as a `.rbxl` and run:

```
lune run tools/extract -- path/to/place.rbxl
```

That rewrites `src/` from the place using the Rojo naming conventions and preserves the `RelayConfig` and `Fonts` exclusions.
