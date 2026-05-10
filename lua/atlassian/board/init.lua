local state_mod = require("atlassian.board.state")
local render_mod = require("atlassian.board.render")

local M = {}

---@type BoardState|nil
local board = nil

--- Build the "my involvement" JQL query.
--- Resolves custom field IDs first, then builds JQL.
---@param callback fun(jql: string)
local function build_involvement_jql(callback)
	local api = require("jira-interface.api")

	-- Ensure custom fields are resolved before building JQL
	api.ensure_custom_fields_resolved(function()
		local config = require("jira-interface.config")
		local clauses = { "assignee = currentUser()" }

		local custom = config.options.custom_fields or {}
		local resolved = api._resolved_custom_fields or {}

		for heading, _ in pairs(custom) do
			local lower = heading:lower()
			if lower:find("review") or lower:find("additional") or lower:find("assignee") then
				local ids = resolved[heading]
				if ids then
					for _, id in ipairs(type(ids) == "table" and ids or { ids }) do
						table.insert(clauses, '"' .. id .. '" = currentUser()')
					end
				end
			end
		end

		local involvement = "(" .. table.concat(clauses, " OR ") .. ")"

		-- Exclude epics (lvl1 types) — trees start at level 2
		local lvl1 = config.options.types and config.options.types.lvl1 or { "Epic" }
		local exclude_parts = {}
		for _, t in ipairs(lvl1) do
			exclude_parts[#exclude_parts + 1] = '"' .. t .. '"'
		end
		local exclude = ""
		if #exclude_parts > 0 then
			exclude = " AND issuetype NOT IN (" .. table.concat(exclude_parts, ", ") .. ")"
		end

		local jql = involvement .. exclude .. " ORDER BY updated DESC"
		callback(jql)
	end)
end

--- Detect which custom_fields heading is the product area.
---@return string|nil
local function detect_product_area_field()
	local config = require("jira-interface.config")
	for heading, _ in pairs(config.options.custom_fields or {}) do
		local lower = heading:lower()
		if lower:find("product") or lower:find("area") or lower:find("component") or lower:find("team") then
			return heading
		end
	end
	return nil
end

--- Fetch parent issues not in the result set (context bubbling).
--- Stops at level 1 (epics) — does not fetch epic parents.
---@param issues JiraIssue[]
---@param callback fun(issues: JiraIssue[])
local function bubble_parents(issues, callback)
	local config = require("jira-interface.config")
	local lvl1 = {}
	for _, t in ipairs(config.options.types and config.options.types.lvl1 or { "Epic" }) do
		lvl1[t:lower()] = true
	end

	local by_key = {}
	for _, issue in ipairs(issues) do
		by_key[issue.key] = true
	end

	local missing_parents = {}
	local seen = {}
	for _, issue in ipairs(issues) do
		-- Only bubble up if this issue has a parent AND this issue is not level 2
		-- (level 2 parents are epics — don't fetch those)
		if issue.parent and not by_key[issue.parent] and not seen[issue.parent] then
			local issue_type_lower = (issue.type or ""):lower()
			-- If the issue's type is level 2, its parent is an epic — skip
			local is_lvl2 = false
			for _, t in ipairs(config.options.types and config.options.types.lvl2 or { "Feature", "Bug", "Issue" }) do
				if t:lower() == issue_type_lower then
					is_lvl2 = true
					break
				end
			end
			if not is_lvl2 then
				seen[issue.parent] = true
				table.insert(missing_parents, issue.parent)
			end
		end
	end

	if #missing_parents == 0 then
		callback(issues)
		return
	end

	-- Fetch missing parents
	local api = require("jira-interface.api")
	local remaining = #missing_parents
	local fetched = {}

	for _, key in ipairs(missing_parents) do
		api.get_issue(key, function(err, issue)
			if not err and issue then
				table.insert(fetched, issue)
			end
			remaining = remaining - 1
			if remaining == 0 then
				-- Combine and recurse (parent might also have a parent)
				local combined = vim.list_extend(vim.list_extend({}, issues), fetched)
				bubble_parents(combined, callback)
			end
		end)
	end
end

--- Open the board.
---@param opts? { project?: string, jql?: string }
function M.open(opts)
	opts = opts or {}
	local config = require("jira-interface.config")
	local api = require("jira-interface.api")
	local notify = require("jira-interface.notify")

	local project = opts.project or ""
	local force_group = opts.group

	local function do_open(jql)
		notify.progress_start("board", "Loading board...")

		api.search(jql, function(err, issues)
			if err then
				notify.progress_error("board", "Board failed: " .. tostring(err))
				return
			end

			issues = issues or {}
			notify.progress_update("board", "Building tree... (" .. #issues .. " issues)")

			bubble_parents(issues, function(all_issues)
				vim.schedule(function()
					notify.progress_finish("board")
					M.show(all_issues, project, jql, force_group)
				end)
			end)
		end)
	end

	if opts.jql then
		do_open(opts.jql)
	else
		build_involvement_jql(do_open)
	end
end

--- Show board with given issues.
---@param issues JiraIssue[]
---@param project string
---@param jql string
---@param force_group? string
function M.show(issues, project, jql, force_group)
	-- Create or reuse board buffer
	local buf, win
	if board and vim.api.nvim_buf_is_valid(board.buf) then
		buf = board.buf
		win = board.win
		if not vim.api.nvim_win_is_valid(win) then
			win = vim.api.nvim_get_current_win()
		end
		vim.api.nvim_win_set_buf(win, buf)
	else
		buf = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_buf_set_name(buf, "jira://board")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "atlassian-board"
	vim.bo[buf].modifiable = false

	vim.wo[win].wrap = false
	vim.wo[win].signcolumn = "yes:1"
	vim.wo[win].cursorline = true

	local product_area_field = detect_product_area_field()
	local tree = state_mod.build_tree(issues, nil)
	local group_mode = force_group or (product_area_field and "product_area" or "none")
	local groups = state_mod.group_nodes(tree, group_mode, product_area_field)

	board = {
		buf = buf,
		win = win,
		ns = render_mod.ns,
		issues = issues,
		tree = tree,
		groups = groups,
		group_mode = group_mode,
		line_to_node = {},
		line_count = 0,
		filters = {},
		jql = jql,
		project = project,
		my_account_id = nil,
		product_area_field = product_area_field,
	}

	M.refresh_render()
	M.setup_keymaps(buf)

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			if board and board.buf == buf then
				board = nil
			end
		end,
	})
end

--- Re-render the board from current state.
function M.refresh_render()
	if not board then return end
	local result = render_mod.render(board)
	board.line_to_node = result.line_to_node
	board.line_count = #result.lines
	render_mod.apply(board.buf, result)
end

--- Get the BoardNode at cursor.
---@return BoardNode|nil
local function node_at_cursor()
	if not board then return nil end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	return board.line_to_node[row]
end

--- Toggle expand/collapse of node at cursor.
local function toggle_expand()
	local node = node_at_cursor()
	if not node or #node.children == 0 then return end
	node.expanded = not node.expanded
	local cursor = vim.api.nvim_win_get_cursor(0)
	M.refresh_render()
	local line_count = vim.api.nvim_buf_line_count(board.buf)
	vim.api.nvim_win_set_cursor(0, { math.min(cursor[1], line_count), cursor[2] })
end

--- Expand all nodes recursively.
local function expand_all()
	if not board then return end
	local function expand(nodes)
		for _, node in ipairs(nodes) do
			if #node.children > 0 then
				node.expanded = true
				expand(node.children)
			end
		end
	end
	expand(board.tree)
	M.refresh_render()
end

--- Collapse all nodes.
local function collapse_all()
	if not board then return end
	local function collapse(nodes)
		for _, node in ipairs(nodes) do
			node.expanded = false
			collapse(node.children)
		end
	end
	collapse(board.tree)
	M.refresh_render()
end

--- Jump to next/prev issue header line (skip detail lines).
---@param direction number 1 = next, -1 = prev
local function jump_issue(direction)
	if not board then return end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local current_node = board.line_to_node[row]
	local target = row + direction

	while target >= 0 and target < board.line_count do
		local node = board.line_to_node[target]
		if node and node ~= current_node then
			vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
			return
		end
		target = target + direction
	end
end

--- Switch grouping mode.
---@param mode string
local function set_group_mode(mode)
	if not board then return end
	board.group_mode = mode
	board.groups = state_mod.group_nodes(board.tree, mode, board.product_area_field)
	M.refresh_render()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Refresh data from API.
local function refresh_data()
	if not board then return end
	M.open({ project = board.project, jql = board.jql })
end

--- Setup all keymaps on the board buffer.
---@param buf number
function M.setup_keymaps(buf)
	local opts = function(desc)
		return { buffer = buf, desc = desc, nowait = true, silent = true }
	end

	-- Expand/collapse
	-- za: toggle expand/collapse (like Vim fold toggle)
	-- zo: expand only (like Vim fold open)
	-- zc: collapse only (like Vim fold close)
	-- zO: expand entire tree recursively
	-- zM: collapse entire tree
	-- <CR>: toggle if has children, open issue if leaf
	vim.keymap.set("n", "<CR>", function()
		local node = node_at_cursor()
		if node and #node.children > 0 then
			toggle_expand()
		elseif node then
			local ui = require("jira-interface.ui")
			ui.show_issue_projected(node.issue)
		end
	end, opts("Expand/collapse or open issue"))

	vim.keymap.set("n", "za", toggle_expand, opts("Toggle expand/collapse"))
	vim.keymap.set("n", "zo", function()
		local node = node_at_cursor()
		if node and #node.children > 0 and not node.expanded then
			node.expanded = true
			local cursor = vim.api.nvim_win_get_cursor(0)
			M.refresh_render()
			local lc = vim.api.nvim_buf_line_count(board.buf)
			vim.api.nvim_win_set_cursor(0, { math.min(cursor[1], lc), cursor[2] })
		end
	end, opts("Expand"))
	vim.keymap.set("n", "zc", function()
		local node = node_at_cursor()
		if node and node.expanded then
			node.expanded = false
			local cursor = vim.api.nvim_win_get_cursor(0)
			M.refresh_render()
			local lc = vim.api.nvim_buf_line_count(board.buf)
			vim.api.nvim_win_set_cursor(0, { math.min(cursor[1], lc), cursor[2] })
		end
	end, opts("Collapse"))
	vim.keymap.set("n", "zO", expand_all, opts("Expand all"))
	vim.keymap.set("n", "zM", collapse_all, opts("Collapse all"))

	-- Issue jumping (]i / [i — skip detail lines)
	vim.keymap.set("n", "]i", function() jump_issue(1) end, opts("Next issue"))
	vim.keymap.set("n", "[i", function() jump_issue(-1) end, opts("Prev issue"))

	-- Actions
	vim.keymap.set("n", "e", function()
		local node = node_at_cursor()
		if node then
			local ui = require("jira-interface.ui")
			ui.edit_issue_projected(node.issue.key)
		end
	end, opts("Edit issue"))

	vim.keymap.set("n", "t", function()
		local node = node_at_cursor()
		if node then
			local ui = require("jira-interface.ui")
			ui.show_transition_picker(node.issue.key, node.issue.status)
		end
	end, opts("Transition status"))

	vim.keymap.set("n", "a", function()
		local node = node_at_cursor()
		if node then
			local ui = require("jira-interface.ui")
			ui.show_assign_picker(node.issue.key, node.issue.project)
		end
	end, opts("Assign"))

	vim.keymap.set("n", "c", function()
		local node = node_at_cursor()
		if node then
			local comments = require("jira-interface.comments")
			comments.add_comment(node.issue.key)
		end
	end, opts("Add comment"))

	vim.keymap.set("n", "y", function()
		local node = node_at_cursor()
		if node then
			vim.fn.setreg("+", node.issue.key)
			vim.notify("Copied: " .. node.issue.key, vim.log.levels.INFO)
		end
	end, opts("Yank issue key"))

	vim.keymap.set("n", "gx", function()
		local node = node_at_cursor()
		if node and node.issue.web_url then
			vim.ui.open(node.issue.web_url)
		end
	end, opts("Open in browser"))

	-- Grouping
	vim.keymap.set("n", "gs", function() set_group_mode("status") end, opts("Group by status"))
	vim.keymap.set("n", "ga", function() set_group_mode("assignee") end, opts("Group by assignee"))
	vim.keymap.set("n", "gp", function() set_group_mode("product_area") end, opts("Group by product area"))
	vim.keymap.set("n", "gt", function() set_group_mode("type") end, opts("Group by type"))
	vim.keymap.set("n", "gd", function() set_group_mode("due") end, opts("Group by due date"))
	vim.keymap.set("n", "gi", function() set_group_mode("priority") end, opts("Group by priority"))
	vim.keymap.set("n", "gn", function() set_group_mode("none") end, opts("No grouping"))

	-- Query picker — switch JQL via snacks picker
	vim.keymap.set("n", "gq", function()
		if not board then return end
		local filters = require("jira-interface.filters")
		local config = require("jira-interface.config")
		local project = board.project or config.options.default_project or ""

		local items = {}
		local function add(label, jql)
			items[#items + 1] = { text = label, jql = jql, label = label }
		end

		-- Builtins
		local function add_with_group(label, jql, group)
			items[#items + 1] = { text = label, jql = jql, label = label, group = group }
		end

		add_with_group("My work (involved)", "__involvement__", nil)
		add("Assigned to me", filters.builtin.assigned_to_me(project))
		add("Created by me", filters.builtin.created_by_me(project))
		add("Assigned but not created by me", filters.builtin.assigned_not_created(project))
		local team_jql = project ~= "" and ("project = " .. project .. " AND status != Done ORDER BY assignee ASC, updated DESC") or "status != Done ORDER BY assignee ASC, updated DESC"
		add_with_group("Team workload", team_jql, "assignee")
		add("Epics", filters.builtin.by_level(1, project))
		add("Features / Bugs", filters.builtin.by_level(2, project))
		add("Tasks", filters.builtin.by_level(3, project))
		add("Overdue", filters.builtin.overdue(project))
		add("Due this week", filters.builtin.due_this_week(project))
		add("Due soon (7 days)", filters.builtin.due_soon(project))
		add("All with due dates", filters.builtin.by_duedate(project))

		-- Saved filters
		local saved = filters.list_all()
		for _, f in ipairs(saved) do
			add("⭐ " .. f.name, f.jql)
		end

		-- Custom JQL option
		items[#items + 1] = { text = "Custom JQL...", jql = nil, label = "Custom JQL..." }

		local Snacks = require("snacks")
		Snacks.picker.pick({
			title = "Switch Board Query",
			items = items,
			format = function(item)
				return { { item.label, "Normal" } }
			end,
			confirm = function(picker, item)
				picker:close()
				if not item then return end
				if item.jql == "__involvement__" then
					M.open({ project = project, group = item.group })
				elseif item.jql then
					M.open({ project = project, jql = item.jql, group = item.group })
				else
					vim.ui.input({ prompt = "JQL: " }, function(jql)
						if jql and jql ~= "" then
							M.open({ project = project, jql = jql })
						end
					end)
				end
			end,
			layout = {
				layout = {
					box = "vertical",
					backdrop = false,
					row = -1,
					width = 0,
					height = 0.3,
					border = "top",
					title = " {title} {live} {flags}",
					title_pos = "left",
					{ win = "input", height = 1, border = "bottom" },
					{ win = "list", border = "none" },
				},
			},
			preview = false,
		})
	end, opts("Switch query"))

	-- Refresh
	vim.keymap.set("n", "r", refresh_data, opts("Refresh"))

	-- Close
	vim.keymap.set("n", "q", function()
		if board and vim.api.nvim_buf_is_valid(board.buf) then
			vim.api.nvim_buf_delete(board.buf, { force = true })
			board = nil
		end
	end, opts("Close board"))

	-- Help
	vim.keymap.set("n", "?", function()
		local help = {
			"Board Keymaps:",
			"  <CR>  Open issue / toggle expand",
			"  za    Toggle expand/collapse",
			"  zo    Expand (open fold)",
			"  zc    Collapse (close fold)",
			"  zO    Expand all recursively",
			"  zM    Collapse all",
			"  ]i/[i Next/prev issue",
			"  e     Edit issue",
			"  t     Transition status",
			"  a     Assign",
			"  c     Comment",
			"  y     Yank key",
			"  gx    Open in browser",
			"  gs    Group by status",
			"  ga    Group by assignee",
			"  gp    Group by product area",
			"  gi    Group by priority",
			"  gd    Group by due date",
			"  gt    Group by type",
			"  gn    No grouping",
			"  gq    Switch query (JQL picker)",
			"  r     Refresh",
			"  q     Close",
		}
		vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
	end, opts("Show help"))
end

return M
