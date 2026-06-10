# Art of War — Rojo + GitHub workflow

You're working on Art of War, a Roblox grand-strategy game. The code is a folder of `.luau` files that sync into Studio with Rojo and live on GitHub. The Studio place — map geometry, GUI frames, RemoteEvents, the relay config — is shared separately and is **not** in git. It owns everything that isn't a script.

## Golden rules

1. Edit scripts only as files in this repo. Never edit a managed script directly in Studio — Rojo overwrites it on the next sync. Geometry and GUI-instance changes happen in Studio and are saved back to the shared place.
2. Code is text in git; the place is binary, out of git. Never commit a `.rbxl` or `.rbxlx`.
3. File names follow Rojo: a ModuleScript is `Name.luau`, a server Script is `Name.server.luau`, a LocalScript is `Name.client.luau`.
4. Leave the `ignoreUnknownInstances` flags alone — in `default.project.json` and the `init.meta.json` files. They're what stop a sync from deleting the map, the RemoteEvents, and the GUI frames, and they're set deliberately on every container Rojo touches.

## The two universes

Two published games run the same code:

- Private dev — universe `10041569799`, place `126275639019912`
- Public mappers' game — universe `10042966553`

Each has its own DataStore, and an external Cloudflare relay mirrors saved edits between them. That entire data layer — the DataStores, the relay, and the relay secret in `RelayConfig` — is runtime state, separate from the code. Rojo never touches it, so editing or moving scripts can't affect the sync. `RelayConfig` and the `Fonts` asset library both stay in the place, never in git.

## First-time setup

1. Install Rokit, then run `rokit install` here. That provisions Rojo, Lune, StyLua, and Selene at the pinned versions.
2. Install the Rojo Studio plugin, plus the Rojo and Luau Language Server extensions for your editor.
3. Get the shared place and open your own copy in Studio. Each person serves into their own copy — don't point `rojo serve` at a place someone else is live-editing, and merge through pull requests instead.

## Day to day

1. `git pull`
2. `rojo sourcemap --watch --output sourcemap.json` in the background, for editor types.
3. `rojo serve`, then hit Connect in the Rojo plugin. Scripts sync from the files.
4. Edit files. Each save lands in Studio automatically.
5. Press Play to test.
6. `stylua src && selene src`, then commit and open a pull request to `main`.

## Publishing

`rojo build` only contains the scripts, not the out-of-git geometry, so there's no build artifact to publish. You publish from a place that already holds the geometry: sync the current scripts in, then publish to the live universe. The map and GUI ride along from the place.

## If you're an AI agent with the Roblox Studio MCP

Use it for runtime work only — read-only checks of live state, Play-mode smoke tests. Don't read or write script source through it anymore; the files plus Rojo replace that, and the old base64 transport was slow and lossy on big scripts, which is the whole reason this repo exists. See [`AI-AGENT-GUIDE.md`](AI-AGENT-GUIDE.md) for the full agent workflow and golden rules.
