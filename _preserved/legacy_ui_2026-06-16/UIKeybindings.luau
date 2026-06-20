local UserInputService = game:GetService("UserInputService")

local UIKeybindings = {}

-- Internal state
local _actions = {}        -- id -> { id, label, defaultKey, currentKey, contextId, fn }
local _keyToActions = {}   -- keyCode -> array of action ids in registration order (top wins)
local _changedSubscribers = {}
local activeConn = nil

local function indexAction(action)
	local key = action.currentKey
	local bucket = _keyToActions[key]
	if not bucket then
		bucket = {}
		_keyToActions[key] = bucket
	end
	table.insert(bucket, action.id)
end

local function unindexAction(action, key)
	local bucket = _keyToActions[key]
	if not bucket then return end
	for i = #bucket, 1, -1 do
		if bucket[i] == action.id then
			table.remove(bucket, i)
			break
		end
	end
	if #bucket == 0 then _keyToActions[key] = nil end
end

local function emitChange(id, newKey)
	for _, sub in _changedSubscribers do
		pcall(sub, id, newKey)
	end
end

local function dispatch(keyCode)
	local bucket = _keyToActions[keyCode]
	if not bucket then return false end
	-- Top-of-stack action fires
	local id = bucket[#bucket]
	local action = _actions[id]
	if not action or not action.fn then return false end
	local ok, result = pcall(action.fn)
	return ok and result ~= false
end

function UIKeybindings.start()
	if activeConn then return end
	activeConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if UserInputService:GetFocusedTextBox() then return end
		dispatch(input.KeyCode)
	end)
end

function UIKeybindings.stop()
	if activeConn then activeConn:Disconnect() activeConn = nil end
	_actions = {}
	_keyToActions = {}
	_changedSubscribers = {}
end

-- New action-based API.
-- opts = { id, label, defaultKey, contextId?, fn }
function UIKeybindings.registerAction(opts)
	assert(opts and opts.id, "registerAction requires opts.id")
	assert(opts.fn, "registerAction requires opts.fn")
	local key = opts.currentKey or opts.defaultKey or Enum.KeyCode.Unknown
	-- If id already registered, unindex first (idempotent)
	if _actions[opts.id] then
		unindexAction(_actions[opts.id], _actions[opts.id].currentKey)
	end
	local action = {
		id = opts.id,
		label = opts.label or opts.id,
		defaultKey = opts.defaultKey or key,
		currentKey = key,
		contextId = opts.contextId or "default",
		fn = opts.fn,
	}
	_actions[opts.id] = action
	indexAction(action)
	-- Returns an unregister function
	return function()
		unindexAction(action, action.currentKey)
		_actions[opts.id] = nil
	end
end

function UIKeybindings.getBindings()
	local list = {}
	for _, a in _actions do
		table.insert(list, {
			id = a.id,
			label = a.label,
			currentKey = a.currentKey,
			defaultKey = a.defaultKey,
			contextId = a.contextId,
		})
	end
	table.sort(list, function(a, b) return a.label < b.label end)
	return list
end

function UIKeybindings.findConflicts(id, keyCode)
	local conflicts = {}
	for otherId, a in _actions do
		if otherId ~= id and a.currentKey == keyCode then
			table.insert(conflicts, otherId)
		end
	end
	return conflicts
end

function UIKeybindings.setBinding(id, keyCode)
	local action = _actions[id]
	if not action then return false end
	if action.currentKey == keyCode then return true end
	unindexAction(action, action.currentKey)
	action.currentKey = keyCode
	indexAction(action)
	emitChange(id, keyCode)
	return true
end

function UIKeybindings.resetBinding(id)
	local action = _actions[id]
	if not action then return false end
	return UIKeybindings.setBinding(id, action.defaultKey)
end

function UIKeybindings.resetAll()
	for id, _ in _actions do
		UIKeybindings.resetBinding(id)
	end
end

function UIKeybindings.subscribeChanged(fn)
	table.insert(_changedSubscribers, fn)
	return function()
		for i = #_changedSubscribers, 1, -1 do
			if _changedSubscribers[i] == fn then
				table.remove(_changedSubscribers, i)
				break
			end
		end
	end
end

-- ===== LEGACY SHIM =====
-- Old API: UIKeybindings.register(keyCode, fn, contextId)
-- Wrapped into a synthetic action with id = "legacy_<key>_<n>"
local _legacyCounter = 0
function UIKeybindings.register(keyCode, fn, contextId)
	_legacyCounter = _legacyCounter + 1
	local id = string.format("legacy_%s_%d", tostring(keyCode), _legacyCounter)
	return UIKeybindings.registerAction({
		id = id,
		label = "(unnamed)",
		defaultKey = keyCode,
		contextId = contextId or "default",
		fn = fn,
	})
end

function UIKeybindings.bindAll(bindings, contextId)
	local unregs = {}
	for key, fn in bindings do
		table.insert(unregs, UIKeybindings.register(key, fn, contextId))
	end
	return function()
		for _, u in unregs do u() end
	end
end

return UIKeybindings
