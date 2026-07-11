-- Obfuscation pipeline for client-visible code.
--
-- Stages src/ into build/obf-src, then runs darklua over the CLIENT subtrees only:
--   pass 1: remove_comments            (comments never ship in bytecode; strip anyway)
--   pass 2: rename_variables           (locals + params -> short names; the ONLY transform
--                                       that survives Roblox's compile -> decompile round trip)
-- Server subtrees (ServerScriptService, ServerStorage) are copied verbatim: they never
-- replicate to clients, and raw names keep server stack traces readable.
--
-- HARD CONSTRAINT: this codebase resolves ModuleScripts and Remotes BY STRING NAME
-- (FindFirstChild/WaitForChild). String literals and Instance names must never be
-- rewritten - rename_variables does not touch them, and the canary check below fails
-- the build if that ever stops being true.
--
-- Usage:  lune run tools/obfuscate            (from the repo root)
-- Output: build/obf-src/            drop-in replacement for src/
--         build/release.project.json  rojo project serving the staged tree
-- Returns the staged src root ("build/obf-src/src") when require()d, so publish.luau
-- can run the pipeline via require("./obfuscate").

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local CLIENT_SUBTREES = { "ReplicatedStorage", "StarterPlayer", "ReplicatedFirst", "StarterGui" }
local STAGE_ROOT = "build/obf-src"
local STAGE_SRC = STAGE_ROOT .. "/src"

-- Load-bearing string literals that must survive the rename pass byte-for-byte.
-- Counted in their quoted form so stripped comments don't skew the baseline.
local CANARIES = {
	"RecruitUnit",
	"MoveArmyPath",
	"AttackProvince",
	"DeclareWar",
	"StateSync",
	"RequestFullState",
	"OwnPolitics",
	"NotificationChannel",
	"Hud",
	"HudWiring",
}

-- Lune renamed process.spawn -> process.exec across versions; support both.
local execFn
do
	local ok, fn = pcall(function()
		return process.exec
	end)
	if ok and fn then
		execFn = fn
	else
		execFn = process.spawn
	end
end

local function listFiles(dir, prefix, out)
	for _, entry in ipairs(fs.readDir(dir)) do
		local path = dir .. "/" .. entry
		local rel = if prefix == "" then entry else prefix .. "/" .. entry
		if fs.isDir(path) then
			listFiles(path, rel, out)
		else
			table.insert(out, rel)
		end
	end
end

local function isClientPath(rel)
	for _, subtree in ipairs(CLIENT_SUBTREES) do
		if rel:sub(1, #subtree + 1) == subtree .. "/" or rel == subtree then
			return true
		end
	end
	return false
end

local function countPlain(haystack, needle)
	local count = 0
	local init = 1
	while true do
		local found = haystack:find(needle, init, true)
		if not found then
			break
		end
		count += 1
		init = found + 1
	end
	return count
end

-- Counts quoted occurrences of every canary across all client .luau files under root.
local function canaryCounts(root)
	local files = {}
	listFiles(root, "", files)
	local counts = {}
	for _, name in ipairs(CANARIES) do
		counts[name] = 0
	end
	for _, rel in ipairs(files) do
		if rel:sub(-5) == ".luau" and isClientPath(rel) then
			local source = fs.readFile(root .. "/" .. rel)
			for _, name in ipairs(CANARIES) do
				counts[name] += countPlain(source, '"' .. name .. '"')
				counts[name] += countPlain(source, "'" .. name .. "'")
			end
		end
	end
	return counts
end

-- process.exec THROWS (rather than returning ok=false) when the program is not
-- found, so resolve darklua via pcall with a fallback to the rokit bin dir.
local darkluaBin = "darklua"

local function runDarklua(configPath, target)
	local args = { "process", "--config", configPath, target, target }
	local ok, result = pcall(execFn, darkluaBin, args)
	if not ok and darkluaBin == "darklua" then
		local home = process.env.USERPROFILE or process.env.HOME or ""
		darkluaBin = home .. "/.rokit/bin/darklua.exe"
		ok, result = pcall(execFn, darkluaBin, args)
	end
	if not ok then
		error(
			"could not run darklua - is it installed? Run first-time-setup.bat (or `rokit install`) from the repo root.\n"
				.. tostring(result)
		)
	end
	if not result.ok then
		error(
			string.format(
				"darklua (%s) failed on %s:\n%s\n%s",
				configPath,
				target,
				result.stdout,
				result.stderr
			)
		)
	end
end

local function main()
	-- 0. Remove the previous run's project file first: it must only ever exist as
	-- the final artifact of a fully verified run, never point at a half-built tree.
	if fs.isFile("build/release.project.json") then
		fs.removeFile("build/release.project.json")
	end

	-- 1. STAGE: fresh verbatim copy of the whole src tree
	if fs.isDir(STAGE_ROOT) then
		fs.removeDir(STAGE_ROOT)
	end
	if not fs.isDir("build") then
		fs.writeDir("build")
	end
	fs.writeDir(STAGE_ROOT)
	fs.copy("src", STAGE_SRC)

	-- 2. STRIP comments from client subtrees (pass 1)
	for _, subtree in ipairs(CLIENT_SUBTREES) do
		local target = STAGE_SRC .. "/" .. subtree
		if fs.isDir(target) then
			runDarklua("tools/darklua-strip.json", target)
		end
	end

	-- 3. BASELINE canary counts (after comment strip, before rename)
	local before = canaryCounts(STAGE_SRC)

	-- 4. RENAME locals/params in client subtrees (pass 2)
	for _, subtree in ipairs(CLIENT_SUBTREES) do
		local target = STAGE_SRC .. "/" .. subtree
		if fs.isDir(target) then
			runDarklua("tools/darklua-rename.json", target)
		end
	end

	-- 5a. VERIFY tree parity: no file gained or lost
	local srcFiles, stagedFiles = {}, {}
	listFiles("src", "", srcFiles)
	listFiles(STAGE_SRC, "", stagedFiles)
	table.sort(srcFiles)
	table.sort(stagedFiles)
	if #srcFiles ~= #stagedFiles then
		error(string.format("tree parity: src has %d files, staged has %d", #srcFiles, #stagedFiles))
	end
	for i, rel in ipairs(srcFiles) do
		if stagedFiles[i] ~= rel then
			error(string.format("tree parity: mismatch at %s vs %s", rel, tostring(stagedFiles[i])))
		end
	end

	-- 5b. VERIFY canaries: the rename pass must not have touched quoted lookups
	local after = canaryCounts(STAGE_SRC)
	for _, name in ipairs(CANARIES) do
		if before[name] == 0 then
			error(
				string.format(
					'canary "%s" has 0 quoted occurrences in the client tree - stale canary, update CANARIES in tools/obfuscate.luau',
					name
				)
			)
		end
		if before[name] ~= after[name] then
			error(
				string.format(
					'canary "%s": %d quoted occurrences before rename, %d after - rename pass touched string literals, ABORTING',
					name,
					before[name],
					after[name]
				)
			)
		end
	end

	-- 5c. VERIFY every staged client .luau still compiles
	local compiled = 0
	for _, rel in ipairs(stagedFiles) do
		if rel:sub(-5) == ".luau" and isClientPath(rel) then
			local source = fs.readFile(STAGE_SRC .. "/" .. rel)
			local ok, err = pcall(luau.compile, source)
			if not ok then
				error(string.format("compile check failed for %s:\n%s", rel, tostring(err)))
			end
			compiled += 1
		end
	end
	-- Guard against silent layout drift making the checks above vacuous: the
	-- client tree has ~160 .luau files today, so far fewer means something broke.
	if compiled < 100 then
		error(
			string.format(
				"compile check only saw %d client .luau files (expected ~160) - CLIENT_SUBTREES or the staged layout has drifted",
				compiled
			)
		)
	end

	-- 6. EMIT a rojo project pointing at the staged tree ($path values are relative
	--    to the project file's own directory, build/, hence "obf-src/...")
	local project = serde.decode("json", fs.readFile("default.project.json"))
	project.name = "ArtOfWar-Release"
	local function rewritePaths(node)
		if type(node) ~= "table" then
			return
		end
		for key, value in pairs(node) do
			if key == "$path" and type(value) == "string" and value:sub(1, 4) == "src/" then
				node[key] = "obf-src/" .. value
			else
				rewritePaths(value)
			end
		end
	end
	rewritePaths(project.tree)
	fs.writeFile("build/release.project.json", serde.encode("json", project, true))

	print(string.format("staged %d files into %s", #stagedFiles, STAGE_SRC))
	print(string.format("obfuscated + compile-checked %d client .luau files", compiled))
	print(string.format("canaries intact (%d checked)", #CANARIES))
	print("wrote build/release.project.json")
	return STAGE_SRC
end

return main()
