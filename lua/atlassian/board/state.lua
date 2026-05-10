local M = {}

---@class BoardNode
---@field issue JiraIssue
---@field children BoardNode[]
---@field expanded boolean
---@field depth number
---@field is_context boolean True if shown only as parent context (dimmed)
---@field urgency string "overdue"|"blocked"|"due_soon"|"stale"|"done"|"normal"

---@class BoardGroup
---@field name string Group header label
---@field nodes BoardNode[]

---@class BoardState
---@field buf number
---@field win number
---@field ns number
---@field issues JiraIssue[]
---@field tree BoardNode[]
---@field groups BoardGroup[]
---@field group_mode string "product_area"|"status"|"assignee"|"type"|"none"
---@field line_to_node table<number, BoardNode>
---@field line_count number
---@field filters table
---@field jql string
---@field project string
---@field my_account_id string|nil
---@field product_area_field string|nil

---@param issues JiraIssue[]
---@param my_account_id string|nil
---@return BoardNode[]
function M.build_tree(issues, my_account_id)
	local by_key = {}
	for _, issue in ipairs(issues) do
		by_key[issue.key] = issue
	end

	-- Determine which issues directly involve the current user
	local involved = {}
	for _, issue in ipairs(issues) do
		involved[issue.key] = true
	end

	-- Build parent→children mapping
	local children_of = {}
	local has_parent = {}
	for _, issue in ipairs(issues) do
		if issue.parent and by_key[issue.parent] then
			if not children_of[issue.parent] then
				children_of[issue.parent] = {}
			end
			table.insert(children_of[issue.parent], issue.key)
			has_parent[issue.key] = true
		end
	end

	-- Build nodes recursively
	local function build_node(key, depth)
		local issue = by_key[key]
		if not issue then return nil end

		local node = {
			issue = issue,
			children = {},
			expanded = depth == 0,
			depth = depth,
			is_context = not involved[key],
			urgency = M.compute_urgency(issue),
			max_priority_rank = M.priority_rank(issue.priority),
		}

		for _, child_key in ipairs(children_of[key] or {}) do
			local child = build_node(child_key, depth + 1)
			if child then
				table.insert(node.children, child)
				-- Bubble up: parent inherits highest priority (lowest rank number) from children
				if child.max_priority_rank < node.max_priority_rank then
					node.max_priority_rank = child.max_priority_rank
				end
			end
		end

		-- Sort children: blocked/overdue first, then by priority, then by key
		table.sort(node.children, function(a, b)
			local ua = M.urgency_rank(a.urgency)
			local ub = M.urgency_rank(b.urgency)
			if ua ~= ub then return ua < ub end
			if a.max_priority_rank ~= b.max_priority_rank then
				return a.max_priority_rank < b.max_priority_rank
			end
			return a.issue.key < b.issue.key
		end)

		return node
	end

	-- Root nodes: issues with no parent (or parent not in result set)
	local roots = {}
	for _, issue in ipairs(issues) do
		if not has_parent[issue.key] then
			local node = build_node(issue.key, 0)
			if node then
				table.insert(roots, node)
			end
		end
	end

	-- Sort roots: blocked/overdue first, then by priority, then by key
	table.sort(roots, function(a, b)
		local ua = M.urgency_rank(a.urgency)
		local ub = M.urgency_rank(b.urgency)
		if ua ~= ub then return ua < ub end
		if a.max_priority_rank ~= b.max_priority_rank then
			return a.max_priority_rank < b.max_priority_rank
		end
		return a.issue.key < b.issue.key
	end)

	-- Filter out fully-done trees (feature + all children done)
	local filtered = {}
	for _, node in ipairs(roots) do
		if not M.is_fully_done(node) then
			filtered[#filtered + 1] = node
		end
	end

	return filtered
end

---@param node BoardNode
---@return boolean
function M.is_fully_done(node)
	if node.urgency ~= "done" then
		return false
	end
	for _, child in ipairs(node.children) do
		if not M.is_fully_done(child) then
			return false
		end
	end
	return true
end

---@param issue JiraIssue
---@return string
function M.compute_urgency(issue)
	local status = (issue.status or ""):lower()
	if status:find("block") or status:find("error") or status:find("fail") then
		return "blocked"
	end
	if status:find("done") or status:find("resolved") or status:find("closed") then
		return "done"
	end

	if issue.duedate then
		local y, m, d = issue.duedate:match("(%d+)-(%d+)-(%d+)")
		if y then
			local due_ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			local now = os.time()
			local days_until = (due_ts - now) / 86400
			if days_until < 0 then
				return "overdue"
			elseif days_until <= 7 then
				return "due_soon"
			end
		end
	end

	if issue.updated then
		local y, m, d = issue.updated:match("(%d+)-(%d+)-(%d+)")
		if y then
			local upd_ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			local now = os.time()
			local days_since = (now - upd_ts) / 86400
			if days_since > 14 then
				return "stale"
			end
		end
	end

	return "normal"
end

local urgency_order = {
	overdue = 1,
	blocked = 2,
	due_soon = 3,
	normal = 4,
	stale = 5,
	done = 6,
}

local priority_order = {
	Highest = 1,
	High = 2,
	Medium = 3,
	Low = 4,
	Lowest = 5,
}

---@param priority string|nil
---@return number
function M.priority_rank(priority)
	if not priority then return 99 end
	return priority_order[priority] or 99
end

---@param node BoardNode
---@return string The effective priority name (highest among self + children)
function M.effective_priority(node)
	local rank = node.max_priority_rank or 99
	for name, r in pairs(priority_order) do
		if r == rank then return name end
	end
	return "None"
end

---@param urgency string
---@return number
function M.urgency_rank(urgency)
	return urgency_order[urgency] or 4
end

---@param nodes BoardNode[]
---@param mode string
---@param product_area_field string|nil
---@return BoardGroup[]
function M.group_nodes(nodes, mode, product_area_field)
	if mode == "none" then
		return { { name = "", nodes = nodes } }
	end

	local groups_map = {}
	local group_order = {}

	for _, node in ipairs(nodes) do
		local key
		if mode == "status" then
			key = node.issue.status or "Unknown"
		elseif mode == "assignee" then
			key = node.issue.assignee or "Unassigned"
		elseif mode == "type" then
			key = node.issue.type or "Unknown"
		elseif mode == "priority" then
			key = M.effective_priority(node)
		elseif mode == "due" then
			local dd = node.issue.duedate
			if not dd then
				key = "No due date"
			else
				local y, m, d = dd:match("(%d+)-(%d+)-(%d+)")
				if y then
					local due_ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
					local now = os.time()
					local days = (due_ts - now) / 86400
					if days < 0 then
						key = "Overdue"
					elseif days <= 1 then
						key = "Today"
					elseif days <= 7 then
						key = "This week"
					elseif days <= 30 then
						key = "This month"
					else
						key = "Later"
					end
				else
					key = "No due date"
				end
			end
		elseif mode == "product_area" and product_area_field then
			local raw = (node.issue.custom_fields_raw or {})[product_area_field]
			if type(raw) == "string" then
				key = raw
			elseif type(raw) == "table" and raw.value then
				key = raw.value
			elseif type(raw) == "table" and raw.name then
				key = raw.name
			else
				key = "Uncategorized"
			end
		else
			key = "All"
		end

		if not groups_map[key] then
			groups_map[key] = {}
			table.insert(group_order, key)
		end
		table.insert(groups_map[key], node)
	end

	-- Sort groups for modes with natural ordering
	if mode == "priority" then
		local priority_order = { "Highest", "High", "Medium", "Low", "Lowest", "None" }
		local rank = {}
		for i, p in ipairs(priority_order) do rank[p] = i end
		table.sort(group_order, function(a, b)
			return (rank[a] or 99) < (rank[b] or 99)
		end)
	elseif mode == "due" then
		local due_order = { "Overdue", "Today", "This week", "This month", "Later", "No due date" }
		local rank = {}
		for i, d in ipairs(due_order) do rank[d] = i end
		table.sort(group_order, function(a, b)
			return (rank[a] or 99) < (rank[b] or 99)
		end)
	end

	local groups = {}
	for _, name in ipairs(group_order) do
		table.insert(groups, { name = name, nodes = groups_map[name] })
	end
	return groups
end

---@param node BoardNode
---@return number done
---@return number total
function M.subtask_progress(node)
	local done, total = 0, 0
	for _, child in ipairs(node.children) do
		total = total + 1
		local s = (child.issue.status or ""):lower()
		if s:find("done") or s:find("resolved") or s:find("closed") then
			done = done + 1
		end
	end
	return done, total
end

---@param done number
---@param total number
---@param width number
---@return string
function M.progress_bar(done, total, width)
	if total == 0 then return "" end
	local filled = math.floor((done / total) * width)
	return string.rep("█", filled) .. string.rep("░", width - filled)
end

return M
