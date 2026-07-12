local state_mod = require("atlassian.board.state")
local render_mod = require("atlassian.board.render")

local M = {}

---@type BoardState|nil
local board = nil

--- The relationship tag a sensed involvement section maps to: a "review"-ish
--- section → "review", otherwise "additional".
local function section_kind(def)
	for _, m in ipairs(def.match or {}) do
		if m:lower():find("review", 1, true) then
			return "review"
		end
	end
	return "additional"
end

--- Build the board's relationship-tagged queries plus the value-based detection
--- context. Native relationships (assigned/reporter/watching) are JQL queries.
--- Reviewer / Additional Assignees fields usually have NO JQL searcher, so they
--- can't be queried — instead we request those field VALUES on every search and
--- detect membership client-side, plus run one bounded "discovery" scan to
--- surface issues where you're ONLY a reviewer/additional. Resolves custom field
--- IDs and the current account id first.
---@param callback fun(queries: { kind: string, jql: string }[], ctx: { review_ids: string[], additional_ids: string[], account_id: string|nil })
local function build_queries(callback)
	local api = require("jira-interface.api")

	api.ensure_custom_fields_resolved(function()
		api.ensure_account_id(function(account_id)
			local config = require("jira-interface.config")

			-- Exclude epics (lvl1) — trees start at level 2.
			local lvl1 = config.options.types and config.options.types.lvl1 or { "Epic" }
			local exclude_parts = {}
			for _, t in ipairs(lvl1) do
				exclude_parts[#exclude_parts + 1] = '"' .. t .. '"'
			end
			local exclude = ""
			if #exclude_parts > 0 then
				exclude = " AND issuetype NOT IN (" .. table.concat(exclude_parts, ", ") .. ")"
			end

			-- Split sensed people fields into review vs additional (by section kind),
			-- plus any configured custom_fields headings matching (backward compat).
			local section_defs = config.options.board and config.options.board.involvement_sections or {}
			local section_ids = api.involvement_section_ids or {}
			local custom = config.options.custom_fields or {}
			local review_ids, additional_ids = {}, {}
			local seen = {}
			local function add_id(target, id)
				if id and not seen[id] then seen[id] = true; target[#target + 1] = id end
			end
			for i, def in ipairs(section_defs) do
				local target = section_kind(def) == "review" and review_ids or additional_ids
				for _, id in ipairs(section_ids[i] or {}) do add_id(target, id) end
				for heading, hids in pairs(custom) do
					local hl = heading:lower()
					for _, m in ipairs(def.match or {}) do
						if hl:find(m:lower(), 1, true) then
							for _, id in ipairs(type(hids) == "table" and hids or { hids }) do add_id(target, id) end
							break
						end
					end
				end
			end

			-- Native (JQL-searchable) relationships.
			local queries = {
				{ kind = "assigned", jql = "assignee = currentUser()" .. exclude .. " ORDER BY updated DESC" },
				{ kind = "reporter", jql = "reporter = currentUser()" .. exclude .. " ORDER BY updated DESC" },
				{ kind = "watching", jql = "watcher = currentUser()" .. exclude .. " ORDER BY updated DESC" },
			}

			-- Discovery scan for the non-searchable review/additional fields.
			local scan_days = (config.options.board and config.options.board.involvement_scan_days) or 120
			if (#review_ids > 0 or #additional_ids > 0) and account_id and scan_days > 0 then
				queries[#queries + 1] = {
					kind = "discovery",
					jql = "updated >= -" .. scan_days .. "d" .. exclude .. " ORDER BY updated DESC",
				}
			end

			callback(queries, { review_ids = review_ids, additional_ids = additional_ids, account_id = account_id })
		end)
	end)
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

	-- Run each relationship-tagged query, union the results by key (stamping
	-- issue.involvement with every kind that matched), bubble parents once, and
	-- show ONE merged board. Native kinds come from the query; review/additional
	-- are detected from people-field VALUES (those fields aren't JQL-searchable),
	-- and a "discovery" query only contributes value-matched issues.
	local function do_open(queries, ctx)
		ctx = ctx or {}
		notify.progress_start("board", "Loading board...")

		local by_key = {} -- key -> issue (first wins; involvement unioned)
		local order = {}
		local main_jql = queries[1] and queries[1].jql or ""

		local function add_involvement(issue, kind)
			if not kind then return end
			issue.involvement = issue.involvement or {}
			if not vim.tbl_contains(issue.involvement, kind) then
				issue.involvement[#issue.involvement + 1] = kind
			end
		end

		-- Detect review/additional from the issue's people-field values.
		local function value_match(issue, ids)
			local pf = issue.people_fields or {}
			for _, id in ipairs(ids or {}) do
				for _, acc in ipairs(pf[id] or {}) do
					if acc == ctx.account_id then return true end
				end
			end
			return false
		end

		local function run(i)
			if i > #queries then
				notify.progress_update("board", "Building tree... (" .. #order .. " issues)")
				bubble_parents(order, function(all_issues)
					vim.schedule(function()
						notify.progress_finish("board")
						M.show(all_issues, project, main_jql, force_group, opts.jql)
					end)
				end)
				return
			end
			local q = queries[i]
			api.search(q.jql, function(err, issues)
				if err and q.kind == "assigned" then
					notify.progress_error("board", "Board failed: " .. tostring(err))
					return
				end
				for _, is in ipairs(issues or {}) do
					local review = ctx.account_id and value_match(is, ctx.review_ids) or false
					local additional = ctx.account_id and value_match(is, ctx.additional_ids) or false
					-- Discovery only surfaces reviewer/additional-only issues.
					if not (q.kind == "discovery" and not review and not additional) then
						local ex = by_key[is.key]
						if not ex then
							by_key[is.key] = is
							order[#order + 1] = is
							ex = is
						end
						if q.kind ~= "discovery" then add_involvement(ex, q.kind) end
						if review then add_involvement(ex, "review") end
						if additional then add_involvement(ex, "additional") end
					end
				end
				run(i + 1)
			end)
		end
		run(1)
	end

	if opts.jql then
		do_open({ { kind = "assigned", jql = opts.jql } })
	else
		build_queries(do_open)
	end
end

--- Recompute board.groups from the merged tree using the current group mode.
local function compute_groups()
	if not board then return end
	board.groups = state_mod.group_nodes(board.tree, board.group_mode)
end

--- Show board with given issues (a single merged tree; involvement is carried
--- per-issue as icons).
---@param issues JiraIssue[]
---@param project string
---@param jql string  main (assigned) jql, kept for display
---@param force_group? string
---@param custom_jql? string  explicit user jql, if opened with one (for refresh)
function M.show(issues, project, jql, force_group, custom_jql)
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

	local config = require("jira-interface.config")
	local done_filter = config.options.board and config.options.board.done_filter or "leaves"
	local tree = state_mod.filter_for_display(state_mod.build_tree(issues, nil), done_filter)

	local group_mode = force_group or "none"

	board = {
		buf = buf,
		win = win,
		ns = render_mod.ns,
		issues = issues,
		tree = tree,
		groups = {},
		group_mode = group_mode,
		line_to_node = {},
		line_count = 0,
		filters = {},
		jql = jql,
		custom_jql = custom_jql,
		project = project,
		my_account_id = nil,
	}
	compute_groups()

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
	compute_groups()
	M.refresh_render()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Refresh data from API. A merged board (no explicit jql) re-runs the full
--- involvement query set; a custom-jql board re-runs that single query.
local function refresh_data()
	if not board then return end
	M.open({ project = board.project, jql = board.custom_jql })
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
	-- <CR>: always open the issue view (folding is on za/zo/zc).
	vim.keymap.set("n", "<CR>", function()
		local node = node_at_cursor()
		if node then
			local ui = require("jira-interface.ui")
			ui.show_issue_projected(node.issue)
		end
	end, opts("Open issue"))

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
			ui.show_transition_picker(node.issue.key, node.issue.status, function(new_status)
				vim.schedule(function()
					if not board then return end
					node.issue.status = new_status
					node.urgency = state_mod.compute_urgency(node.issue)
					compute_groups()
					M.refresh_render()
				end)
			end)
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
	vim.keymap.set("n", "gk", function() set_group_mode("kind") end, opts("Group by epic kind"))
	vim.keymap.set("n", "gc", function() set_group_mode("cycle") end, opts("Group by cycle"))
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

		-- Epic-kind label presets (Shape Up structure)
		local epic_kinds = config.options.board and config.options.board.epic_kinds or {}
		for label, entry in pairs(epic_kinds) do
			add(entry.icon .. " " .. entry.name, filters.builtin.by_label(label, project))
		end

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
			"  <CR>  Open issue",
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
			"  gk    Group by epic kind",
			"  gc    Group by cycle",
			"  gi    Group by priority",
			"  gd    Group by due date",
			"  gt    Group by type",
			"  gn    No grouping",
			"  gq    Switch query (JQL picker)",
			"  r     Refresh",
			"  q     Close",
		}
		-- Involvement icon legend (matches the active icon set).
		local legend = render_mod.involvement_legend()
		if #legend > 0 then
			help[#help + 1] = ""
			help[#help + 1] = "Involvement icons (next to key):"
			for _, e in ipairs(legend) do
				help[#help + 1] = "  " .. e.glyph .. "  " .. e.label
			end
		end
		vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
	end, opts("Show help"))
end

return M
