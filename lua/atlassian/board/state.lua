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
---@field group_mode string "status"|"assignee"|"type"|"priority"|"due"|"kind"|"cycle"|"none"
---@field line_to_node table<number, BoardNode>
---@field line_count number
---@field filters table
---@field jql string
---@field project string
---@field my_account_id string|nil

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

	return roots
end

--- Filter a tree for display according to the configured done_filter mode.
--- Counting for the status bar is independent (see M.workable_stats), so hiding
--- done items here does not skew progress.
---   "none"   → show everything
---   "trees"  → hide only fully-done trees (root + all descendants done)
---   "leaves" → also hide done leaf nodes and fully-done subtrees at any level
---@param roots BoardNode[]
---@param mode string|nil
---@return BoardNode[]
function M.filter_for_display(roots, mode)
	mode = mode or "leaves"
	if mode == "none" then
		return roots
	end

	if mode == "trees" then
		local out = {}
		for _, node in ipairs(roots) do
			if not M.is_fully_done(node) then
				out[#out + 1] = node
			end
		end
		return out
	end

	-- "leaves": bottom-up — drop any node that is done and has no (remaining)
	-- children. This removes done leaves and collapses fully-done subtrees.
	local function prune(nodes)
		local out = {}
		for _, node in ipairs(nodes) do
			node.children = prune(node.children)
			local done_leaf = node.urgency == "done" and #node.children == 0
			if not done_leaf then
				out[#out + 1] = node
			end
		end
		return out
	end
	return prune(roots)
end

--- Status-bar stats over the flat fetched issue list (independent of display
--- filtering). "workable" = leaf issues (no children in the fetched set), or the
--- type set named in board.workable_jql when configured.
---@param issues JiraIssue[]
---@return number total, table<string, number> status_counts, number done_count
function M.workable_stats(issues)
	local config = require("jira-interface.config")
	local workable_jql = config.options.board and config.options.board.workable_jql

	local workable_set = nil
	if workable_jql then
		workable_set = {}
		for name in workable_jql:gmatch('"([^"]+)"') do
			workable_set[name:lower()] = true
		end
		if not next(workable_set) then workable_set = nil end
	end

	local by_key, has_child = {}, {}
	for _, issue in ipairs(issues) do by_key[issue.key] = true end
	for _, issue in ipairs(issues) do
		if issue.parent and by_key[issue.parent] then has_child[issue.parent] = true end
	end

	local total, done_count, status_counts = 0, 0, {}
	for _, issue in ipairs(issues) do
		local is_workable
		if workable_set then
			is_workable = workable_set[(issue.type or ""):lower()]
		else
			is_workable = not has_child[issue.key]
		end
		if is_workable then
			total = total + 1
			local s = issue.status or "Unknown"
			status_counts[s] = (status_counts[s] or 0) + 1
			local sl = s:lower()
			if sl:find("done") or sl:find("resolved") or sl:find("closed") then
				done_count = done_count + 1
			end
		end
	end

	return total, status_counts, done_count
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

	-- Link-derived blocked: an "is blocked by" link to a non-done issue.
	for _, link in ipairs(issue.links or {}) do
		local is_blocked_by = (link.label or ""):lower():find("blocked by")
			or (link.link_type == "Blocks" and link.direction == "inward")
		if is_blocked_by then
			local ls = (link.issue_status or ""):lower()
			if not (ls:find("done") or ls:find("resolved") or ls:find("closed")) then
				return "blocked"
			end
		end
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

--- Resolve the configured epic kind for an issue from its labels.
---@param issue JiraIssue
---@return table|nil { name, icon, hl }, string|nil label
function M.epic_kind(issue)
	local config = require("jira-interface.config")
	local kinds = config.options.board and config.options.board.epic_kinds
	if not kinds then return nil end
	for _, label in ipairs(issue.labels or {}) do
		local entry = kinds[label]
		if entry then return entry, label end
	end
	return nil
end

--- Extract a Shape Up cycle identifier from an issue (summary, then fix versions).
---@param issue JiraIssue
---@return string|nil
function M.cycle_id(issue)
	local config = require("jira-interface.config")
	local pattern = config.options.board and config.options.board.cycle_pattern
	if not pattern then return nil end
	local from_summary = issue.summary and issue.summary:match(pattern)
	if from_summary then return from_summary end
	for _, v in ipairs(issue.fix_versions or {}) do
		local m = v:match(pattern)
		if m then return m end
		-- Fix version name may itself be the cycle id (e.g. "SU1/26")
		if v ~= "" then return v end
	end
	return nil
end

--- Evaluate definition-of-readiness for a node.
--- Readiness is a set of issue rules (see atlassian.board.rules) that must all
--- pass for the item's hierarchy level.
---@param node BoardNode
---@return string|nil "ready"|"shaping" (nil when disabled / not applicable / done)
function M.readiness(node)
	local config = require("jira-interface.config")
	local cfg = config.options.board and config.options.board.readiness
	if not cfg or not cfg.enabled then return nil end
	if node.urgency == "done" then return nil end

	local rules = require("atlassian.board.rules")
	rules.load_user_rules()
	local ids = cfg.levels and cfg.levels[node.issue.level]
	local result = rules.all_pass(ids, node)
	if result == nil then return nil end
	return result and "ready" or "shaping"
end

---@param nodes BoardNode[]
---@param mode string
---@return BoardGroup[]
function M.group_nodes(nodes, mode)
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
		elseif mode == "kind" then
			local entry = M.epic_kind(node.issue)
			key = entry and entry.name or "Unclassified"
		elseif mode == "cycle" then
			key = M.cycle_id(node.issue) or "No cycle"
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
