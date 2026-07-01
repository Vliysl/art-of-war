-- VirtualList: a windowed (virtualized) scrolling list. Only ~viewport-many row instances exist and are
-- recycled as you scroll, so a list of thousands of rows (e.g. ~2800 provinces in the Data Editor) renders
-- and filters in O(visible), not O(total). This replaces the editor's full clear-and-rebuild-on-keystroke.
--
-- Usage:
--   local list = VirtualList.create({
--     parent    = someFrame,             -- the list fills this
--     rowHeight = 32,                    -- fixed px per row
--     getCount  = function() return #items end,
--     createRow = function() return <a reusable empty row GuiObject> end,  -- called once per pooled row
--     bindRow   = function(row, dataIndex) ... set row content for items[dataIndex] ... end,
--     buffer    = 3,                     -- optional extra rows above/below the viewport
--   })
--   list.refresh()   -- call after the underlying data changes (count and/or contents)
--   list.destroy()
--
-- The data source is whatever getCount()/bindRow close over -- VirtualList holds no data itself, so a
-- search/filter is just "rebuild your filtered index array, then list.refresh()".

local VirtualList = {}

function VirtualList.create(opts)
	local rowHeight = opts.rowHeight
	assert(type(rowHeight) == "number" and rowHeight > 0, "VirtualList: rowHeight must be > 0")
	local buffer = opts.buffer or 3

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "VirtualList"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.ClipsDescendants = true
	scroll.Parent = opts.parent

	local pool = {} -- reusable row frames, repositioned + rebound each render

	local function viewportHeight()
		local h = scroll.AbsoluteWindowSize.Y
		if h <= 0 then h = scroll.AbsoluteSize.Y end
		return h
	end

	-- How many rows we need instances for: the viewport's worth plus buffer on each side.
	local function poolTarget()
		return math.ceil(viewportHeight() / rowHeight) + buffer * 2 + 1
	end

	local function ensurePool(n)
		while #pool < n do
			local row = opts.createRow()
			row.Visible = false
			row.Size = UDim2.new(1, 0, 0, rowHeight)
			row.Parent = scroll
			pool[#pool + 1] = row
		end
	end

	local function render()
		local count = opts.getCount() or 0
		scroll.CanvasSize = UDim2.fromOffset(0, count * rowHeight)

		local target = math.min(count, poolTarget())
		ensurePool(target)

		-- First data row to draw, biased up by the buffer so scrolling reveals pre-bound rows.
		local first = math.max(1, math.floor(scroll.CanvasPosition.Y / rowHeight) - buffer + 1)
		for i = 1, #pool do
			local row = pool[i]
			local dataIndex = first + (i - 1)
			if i <= target and dataIndex >= 1 and dataIndex <= count then
				row.Position = UDim2.fromOffset(0, (dataIndex - 1) * rowHeight)
				row.Visible = true
				opts.bindRow(row, dataIndex)
			else
				row.Visible = false
			end
		end
	end

	local conns = {}
	conns[#conns + 1] = scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(render)
	conns[#conns + 1] = scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(render)
	task.defer(render) -- initial paint once AbsoluteSize is known

	return {
		instance = scroll,
		refresh = render,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			scroll:Destroy()
		end,
	}
end

return VirtualList
