# Art of War — Windows Guide (for Avierns)

Hey Avierns — this is everything you need to work on Art of War from your Windows PC: how to set it up once, and what to do every day. Take it slow the first time; after that it's a four-step routine.

## How this works (the 30-second version)

The game's code lives as a folder of files in this repo. Four pieces move it around:

- **The files** — the real source of truth. Your Claude edits these.
- **Rojo** — a little live bridge. While it's running, every file change appears in Studio instantly. It only ever pushes *files → Studio*, so it can't mess up your files.
- **Git / GitHub** — version history. Your saves go up as **avierns-dev**, Vernal's as **Vliysl** — automatically, once you've done the one-time setup.
- **Publish** — pushing the game to players, from Studio.

One golden rule up front: **edit the files, never the scripts inside Studio.** Rojo overwrites Studio's scripts from the files on every sync, so a change you make directly in Studio just disappears. (Geometry, the map, and GUI are the opposite — those live in the place and you change them in Studio. Only *scripts* come from the files.)

You'll do two things in two different places:
- **Work in the private place** — *"Art of War Debug"* — that's where Rojo syncs and where you test.
- **Publish to the group game** — *"Art of War Playtesting"* — that's where players get it.

---

## Part 1 — One-time setup

You only do this once. ~15 minutes.

**1. Install Git for Windows** — https://git-scm.com/download/win (just click through the installer with the defaults).

**2. Install Rokit** (it manages Rojo and the other tools) — https://github.com/rojo-rbx/rokit/releases — grab the Windows download, run it.

**3. Get the repo.** Open a terminal (press Start, type `cmd`, Enter) and run:
```
cd %USERPROFILE%\Documents
git clone https://github.com/Vliysl/art-of-war.git
cd art-of-war
```
Now you have the folder at `Documents\art-of-war`.

**4. Run the setup file.** In that folder, **double-click `first-time-setup.bat`** and press `y`. It does two things: tags your commits as **avierns-dev**, and installs Rojo + the other tools. (The first time you push, GitHub will ask you to sign in — sign in as **avierns-dev**.)

**5. Install the Rojo plugin in Studio.** Easiest way — back in the terminal:
```
rojo plugin install
```
That drops the plugin straight into Studio. (If that ever doesn't work, you can also get "Rojo" from the Studio Toolbox / Creator Store.)

That's it. You're set up.

---

## Part 2 — Your daily routine

Every time you sit down to work:

**1. Open the place in Studio.**
File → Open from Roblox → **Art of War Debug** (the private one). This is where you'll see your edits and test them.

**2. Start Rojo.**
In the `art-of-war` folder, **double-click `serve-aow.bat`.** A black window opens and says the server's running — **leave it open** the whole time you work. Closing it stops the sync.

**3. Connect Studio to it.**
In Studio: **Plugins** tab → **Rojo** → **Connect**. It'll say connected. Now Studio is live-linked to your files.

**4. Work with your Claude.**
Tell it what you want, like you always do. It edits the files, and you'll watch them update in Studio in real time. Press **Play** to test whenever you want.

**5. Save your work to GitHub.**
When you've got something worth keeping, either ask your Claude to *"commit and push"*, or just **double-click `commit-push.bat`**, type a short description, and it handles the rest. Your saves show up as **avierns-dev**.

**6. Publish to players** (when it's ready for the group game).
**Ctrl+S** to save the place, then **File → Publish to Roblox As… → Art of War Playtesting**. That's what puts it in front of players.

---

## Part 3 — Saving vs. publishing (they're different)

These are two separate things, and it helps to keep them straight:

- **Saving to GitHub** (`commit-push.bat`, or your Claude) = backing up the *code* and sharing it with Vernal. Do this often. It does **not** change the live game.
- **Publishing** (Ctrl+S → Publish As → group) = pushing the game to *players*. Do this when something's ready to go live.

A good habit: **save to GitHub first, then publish.** That way the code that's live always matches what's on GitHub.

*(Down the road there's also a one-command publish — `lune run tools/publish` — that pushes to both games at once. We've left it off for now; plain Ctrl+S → Publish As is simpler and works great.)*

---

## Part 4 — Sharing the repo with Vernal

You two are both full admins on the same repo, so a little rhythm keeps it smooth:

- **Pull before you start.** At the beginning of a session, grab Vernal's latest so you're building on the newest code. Ask your Claude to *"pull the latest"*, or run `git pull`. (`commit-push.bat` also pulls automatically before it pushes.)
- **Save in reasonable chunks** rather than one giant save at the end — smaller saves are easier to merge.
- **If two of you change the same line**, git will flag a conflict. Don't worry about it — just tell your Claude *"pull, resolve the conflicts, and push"* and it'll sort it out.
- **Coordinate publishes.** Whoever publishes last is what players see, so a quick "publishing now" between you two avoids surprises. Always pull first so you publish the newest code.

The golden rules again, since they matter most:
1. Edit **files**, never scripts inside Studio.
2. Keep the **`serve-aow.bat` window open** while working.
3. **Pull before you start**, save often.
4. The place file (map, GUI, the relay secret) is **not** in git and never should be — only scripts are.

---

## Part 5 — If something's off

**The serve window flashes and closes instantly.**
Rojo probably isn't installed. Run `first-time-setup.bat` again. If the window stays open with a red error, read it — it usually says what's missing.

**Rojo plugin won't connect / says the place is wrong.**
Two things to check: is the `serve-aow.bat` window still open and running? And did you open **Art of War Debug** (the private place)? The sync is locked to that place on purpose — if you open the group place instead, it'll refuse to connect.

**My edits aren't showing up in Studio.**
Make sure the serve window is open *and* the Rojo plugin says "Connected." If both are true, the file just needs to be saved — your Claude saves as it edits, so this is rare.

**A change I made in Studio disappeared.**
That's the golden rule biting — you edited a *script* inside Studio, and Rojo overwrote it from the files. Make the change in the files instead (ask your Claude). Geometry/GUI changes are fine to make in Studio.

**My push was rejected / "behind".**
Vernal pushed something while you were working. `commit-push.bat` handles this automatically (it pulls first). If you hit it another way, ask your Claude to *"pull and push."*

**Still stuck?** Ask your Claude — it can see the repo and the error and will walk you out of almost anything.

---

## Daily cheat-sheet

Pin this somewhere:

```
1.  Open  "Art of War Debug"  in Studio
2.  Double-click  serve-aow.bat   (leave the window open)
3.  Studio -> Plugins -> Rojo -> Connect
4.  Work with your Claude  (Play to test)
5.  Save:     double-click  commit-push.bat
6.  Publish:  Ctrl+S  ->  File -> Publish to Roblox As -> "Art of War Playtesting"
```

Welcome aboard — go build something great. 🫡
