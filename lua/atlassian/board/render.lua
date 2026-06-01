local state_mod = require("atlassian.board.state")
local extmarks = require("atlassian.editor.extmarks")
local format = require("atlassian.format")

local M = {}

M.ns = vim.api.nvim_create_namespace("atlassian_board")

local urgency_signs = {
	overdue = { text = "●", hl = "DiagnosticError" },
	blocked = { text = "●", hl = "DiagnosticError" },
	due_soon = { text = "●", hl = "DiagnosticWarn" },
	done = { text = "●", hl = "DiagnosticOk" },
	stale = { text = "○", hl = "Comment" },
	normal = { text = " ", hl = "Normal" },
}

local default_type_icons = {
	Epic = "◆",
	Feature = "◆",
	Bug = "●",
	Issue = "◆",
	Task = "◇",
	["Sub-Task"] = "○",
}

local function get_type_icon(issue_type)
	local config = require("jira-interface.config")
	local configured = config.options.board and config.options.board.type_icons
	local icons = configured or default_type_icons
	return icons[issue_type] or icons.Task or "◆"
end

local type_hls = {
	Epic = "@markup.heading.1",
	Feature = "@markup.heading.2",
	Bug = "DiagnosticError",
	Issue = "@markup.heading.3",
	Task = "Function",
	["Sub-Task"] = "Identifier",
}

local setup_done = false

function M.setup()
	if setup_done then return end
	setup_done = true
	extmarks.setup()

	-- No custom highlights — use standard Neovim groups directly.
	-- Type icons, status badges, etc. all reference built-in groups.
end

local function status_badge_hl(status)
	if not status then return "CurSearch" end
	local s = status:lower()
	if s:find("done") or s:find("resolved") or s:find("closed") then
		return "DiffAdd"
	elseif s:find("progress") or s:find("review") or s:find("building") or s:find("testing") then
		return "DiffChange"
	elseif s:find("block") or s:find("error") or s:find("fail") then
		return "DiffDelete"
	end
	return "CurSearch"
end

---@class BoardRenderResult
---@field lines string[]
---@field marks table[]
---@field line_to_node table<number, BoardNode>

---@param board_state BoardState
---@return BoardRenderResult
function M.render(board_state)
	M.setup()

	-- Compute title column: all summaries start at same display column
	-- title_col = max_prefix_dw + icon(2) + max_key_dw + gap(2)
	-- max_prefix_dw accounts for deepest nesting: "  │   └── " etc.
	local max_key_dw = 0
	local max_depth = 0
	local function scan_depth(nodes, d)
		for _, node in ipairs(nodes) do
			local dw = vim.fn.strdisplaywidth(node.issue.key or "")
			if dw > max_key_dw then max_key_dw = dw end
			if d > max_depth then max_depth = d end
			if #node.children > 0 then
				scan_depth(node.children, d + 1)
			end
		end
	end
	scan_depth(board_state.tree, 0)
	max_key_dw = math.max(max_key_dw, 8)
	-- prefix at depth d: root="▼ "(2) or "  "+"│   "*d+"└── "(4) = 2+4*d+4
	-- icon = 2 display chars, gap = 2
	local deepest_prefix = 2 + 4 * max_depth + 4
	local title_col = deepest_prefix + 2 + max_key_dw + 2

	local lines = {}
	local marks = {}
	local line_to_node = {}
	local line = 0

	local function add_line(text)
		lines[#lines + 1] = text
		local l = line
		line = line + 1
		return l
	end

	local function add_mark(l, col, opts)
		marks[#marks + 1] = { line = l, col = col, opts = opts }
	end

	-- Summary bar — count "workable" items over the full fetched set, independent
	-- of the board.done_filter display mode (so hiding done items doesn't skew %).
	local total, status_counts, done_count = state_mod.workable_stats(board_state.issues or {})

	local pct = total > 0 and math.floor(done_count / total * 100) or 0
	local filled = total > 0 and math.floor((done_count / total) * 10) or 0

	local header_text = " " .. (board_state.project or "Board")
		.. " │ " .. total .. " issues │ "
	local l = add_line(header_text)
	add_mark(l, 0, { end_col = #header_text, hl_group = "Title" })

	-- Progress bar as inline virtual text with background colors
	local progress_vt = {}
	if filled > 0 then
		table.insert(progress_vt, { string.rep("█", filled), "DiffAdd" })
	end
	if 10 - filled > 0 then
		table.insert(progress_vt, { string.rep("░", 10 - filled), "DiffDelete" })
	end
	table.insert(progress_vt, { " " .. pct .. "%", "Title" })
	add_mark(l, #header_text, {
		virt_text = progress_vt,
		virt_text_pos = "inline",
	})

	-- Status breakdown from actual data, sorted by count descending
	local status_list = {}
	for s, count in pairs(status_counts) do
		status_list[#status_list + 1] = { name = s, count = count }
	end
	table.sort(status_list, function(a, b) return a.count > b.count end)

	local status_parts = {}
	for _, entry in ipairs(status_list) do
		local badge_hl = status_badge_hl(entry.name)
		status_parts[#status_parts + 1] = { " " .. entry.count .. " " .. entry.name .. " ", badge_hl }
	end
	if #status_parts > 0 then
		add_mark(l, 0, { virt_text = status_parts, virt_text_pos = "right_align" })
	end

	-- Separator
	local sep = string.rep("━", 80)
	l = add_line(sep)
	add_mark(l, 0, { end_col = #sep, hl_group = "NonText" })

	-- Render groups
	for gi, group in ipairs(board_state.groups) do
		if group.name ~= "" and group.name ~= "All" then
			add_line("")
			local gh = " ── " .. group.name .. " " .. string.rep("─", math.max(0, 74 - #group.name))
			l = add_line(gh)
			add_mark(l, 0, { end_col = #gh, hl_group = "@markup.heading.2" })
		end

		add_line("")

		for ni, node in ipairs(group.nodes) do
			if ni > 1 then
				add_line("")
			end
			local is_last_root = ni == #group.nodes
			render_node(lines, marks, line_to_node, node, 0, is_last_root, {}, add_line, add_mark, max_key_dw, title_col)
			line = #lines
		end
	end

	-- Help bar
	add_line("")
	l = add_line(" [e]dit [t]ransition [a]ssign [c]omment [/]search [g]roup [r]efresh [?]help")
	add_mark(l, 0, { end_col = #lines[#lines], hl_group = "StatusLine" })

	return {
		lines = lines,
		marks = marks,
		line_to_node = line_to_node,
	}
end

--- @param ancestors string[] continuation prefixes from ancestor levels ("│   " or "    ")
---@param lines string[]
---@param marks table[]
---@param line_to_node table
---@param node BoardNode
---@param depth number
---@param is_last boolean
---@param ancestors string[]
---@param add_line fun(text: string): number
---@param add_mark fun(l: number, col: number, opts: table)
function render_node(lines, marks, line_to_node, node, depth, is_last, ancestors, add_line, add_mark, max_key_dw, title_col)
	local issue = node.issue
	local ancestor_prefix = table.concat(ancestors)

	local tree_char = ""
	if depth > 0 then
		tree_char = is_last and "└── " or "├── "
	end

	-- Type icon (configurable)
	local type_icon_char = get_type_icon(issue.type)
	local type_icon = type_icon_char .. " "
	local type_hl = type_hls[issue.type] or "Identifier"

	-- Expand indicator for root/parent nodes
	local expand = ""
	if #node.children > 0 and depth == 0 then
		expand = node.expanded and "▼ " or "▶ "
	end

	-- Issue key
	local key_text = issue.key or ""

	-- Build left part: prefix + key, padded so title starts at title_col
	local prefix = ancestor_prefix .. tree_char .. expand
	local prefix_dw = vim.fn.strdisplaywidth(prefix)
	-- icon(2) + key + padding to reach title_col
	local left_dw = prefix_dw + 2 + vim.fn.strdisplaywidth(key_text)
	local pad_to_title = math.max(2, title_col - left_dw)
	local key_padded = key_text .. string.rep(" ", pad_to_title)

	-- Summary
	local summary = issue.summary or ""
	local max_summary = math.max(20, 70)
	if #summary > max_summary then
		summary = summary:sub(1, max_summary - 1) .. "…"
	end

	-- Build the line: prefix + key_padded + summary
	local main = key_padded .. summary
	local header_text = prefix .. main

	local l = add_line(header_text)
	line_to_node[l] = node

	-- Urgency sign
	local urg = urgency_signs[node.urgency] or urgency_signs.normal
	add_mark(l, 0, { sign_text = urg.text .. " ", sign_hl_group = urg.hl })

	-- Type icon as inline virtual text before the key
	add_mark(l, #prefix, {
		virt_text = { { type_icon, node.is_context and "Comment" or type_hl } },
		virt_text_pos = "inline",
	})

	-- Key highlight
	local key_start = #prefix
	local key_end = key_start + #key_text
	local key_hl = node.is_context and "Comment" or (type_hls[issue.type] or "Identifier")
	add_mark(l, key_start, { end_col = key_end, hl_group = key_hl })

	-- Summary highlight — starts after the padded key
	local sum_start = key_start + #key_padded
	local sum_end = sum_start + #summary
	local sum_hl = node.is_context and "Comment" or "Normal"
	add_mark(l, sum_start, { end_col = math.min(sum_end, #header_text), hl_group = sum_hl })

	-- Tree char highlight (ancestor lines + branch char)
	if #ancestor_prefix > 0 then
		add_mark(l, 0, { end_col = #ancestor_prefix, hl_group = "NonText" })
	end
	if #tree_char > 0 then
		local tc_start = #ancestor_prefix
		add_mark(l, tc_start, { end_col = tc_start + #tree_char, hl_group = "NonText" })
	end

	-- Right-aligned: [kind] + assignee + status badge
	local status = issue.status or ""
	local badge_hl = status_badge_hl(status)
	local assignee_text = issue.assignee or "unassigned"
	local right_vt = {}
	local kind = state_mod.epic_kind(issue)
	if kind then
		right_vt[#right_vt + 1] = { " " .. kind.icon .. " " .. kind.name .. " ", kind.hl }
	end
	right_vt[#right_vt + 1] = { " " .. assignee_text .. " ", "Constant" }
	right_vt[#right_vt + 1] = { " " .. status .. " ", badge_hl }
	add_mark(l, 0, {
		virt_text = right_vt,
		virt_text_pos = "right_align",
	})

	-- Detail line: tree continuation padded to title_col, then detail content
	if node.expanded or depth > 0 then
		local detail_tree
		if depth > 0 then
			detail_tree = ancestor_prefix .. (is_last and "    " or "│   ")
		else
			detail_tree = "  │"
		end
		local detail_tree_dw = vim.fn.strdisplaywidth(detail_tree)
		local detail_pad = math.max(0, title_col - detail_tree_dw)
		local detail_prefix = detail_tree .. string.rep(" ", detail_pad)

		-- Build detail as virtual text with per-segment highlighting
		local detail_vt = {}

		-- Definition-of-Ready glyph
		local readiness = state_mod.readiness(node)
		if readiness == "ready" then
			table.insert(detail_vt, { " ✓ ready", "DiagnosticOk" })
		elseif readiness == "shaping" then
			table.insert(detail_vt, { " ◐ shaping", "DiagnosticWarn" })
		end

		-- Cycle / release identifier
		local cycle = state_mod.cycle_id(issue)
		if cycle then
			if #detail_vt > 0 then table.insert(detail_vt, { " │ ", "NonText" }) end
			table.insert(detail_vt, { cycle, "Special" })
		end

		-- Blocked-by dependencies
		local blockers = {}
		for _, link in ipairs(issue.links or {}) do
			local is_blocked_by = (link.label or ""):lower():find("blocked by")
				or (link.link_type == "Blocks" and link.direction == "inward")
			if is_blocked_by and link.issue_key and link.issue_key ~= "" then
				blockers[#blockers + 1] = link.issue_key
			end
		end
		if #blockers > 0 then
			if #detail_vt > 0 then table.insert(detail_vt, { " │ ", "NonText" }) end
			table.insert(detail_vt, { "↑ blocked by " .. table.concat(blockers, ", "), "DiagnosticError" })
		end

		-- Reviewer (assignee is already shown right-aligned on header)
		local custom = issue.custom_fields_raw or {}
		for heading, val in pairs(custom) do
			if heading:lower():find("review") then
				local reviewer_name
				if type(val) == "table" and val.displayName then
					reviewer_name = val.displayName
				elseif type(val) == "string" and val ~= "" then
					reviewer_name = val
				end
				if reviewer_name then
					if #detail_vt > 0 then table.insert(detail_vt, { " │ ", "NonText" }) end
					table.insert(detail_vt, { reviewer_name, "Type" })
				end
			end
		end

		-- Subtask progress
		if #node.children > 0 then
			local done, total = state_mod.subtask_progress(node)
			local filled = math.floor((done / total) * 4)
			table.insert(detail_vt, { " │ ", "NonText" })
			table.insert(detail_vt, { done .. "/" .. total .. " ", "Number" })
			if filled > 0 then
				table.insert(detail_vt, { string.rep("█", filled), "DiffAdd" })
			end
			if 4 - filled > 0 then
				table.insert(detail_vt, { string.rep("░", 4 - filled), "DiffDelete" })
			end
		end

		-- Due date (skip for done issues)
		if issue.duedate and node.urgency ~= "done" then
			local due_text = format.format_duedate(issue.duedate)
			local due_rel = format.format_duedate_relative(issue.duedate)
			local due_display = due_text
			if due_rel and due_rel ~= "" then
				due_display = due_display .. " " .. due_rel
			end
			local due_hl = "Comment"
			if node.urgency == "overdue" then
				due_hl = "DiagnosticError"
			elseif node.urgency == "due_soon" then
				due_hl = "DiagnosticWarn"
			end
			table.insert(detail_vt, { " │ ", "NonText" })
			table.insert(detail_vt, { due_display, due_hl })
		end

		if #detail_vt > 0 then
		table.insert(detail_vt, 1, { "│ ", "NonText" })
		local dl = add_line(detail_prefix)
		line_to_node[dl] = node
		add_mark(dl, 0, { end_col = #detail_prefix, hl_group = "NonText" })
		add_mark(dl, #detail_prefix, {
			virt_text = detail_vt,
			virt_text_pos = "inline",
		})
		end
	end

	-- Render children if expanded
	if node.expanded then
		-- Build ancestors list for children
		local child_ancestors = {}
		for _, a in ipairs(ancestors) do
			child_ancestors[#child_ancestors + 1] = a
		end
		if depth > 0 then
			child_ancestors[#child_ancestors + 1] = is_last and "    " or "│   "
		else
			child_ancestors[#child_ancestors + 1] = "  "
		end

		for ci, child in ipairs(node.children) do
			local child_is_last = ci == #node.children
			render_node(lines, marks, line_to_node, child, depth + 1, child_is_last, child_ancestors, add_line, add_mark, max_key_dw, title_col)
		end
	end
end

---@param buf number
---@param result BoardRenderResult
function M.apply(buf, result)
	vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false

	local line_count = #result.lines
	for _, mark in ipairs(result.marks) do
		if mark.line < line_count then
			local line_len = #result.lines[mark.line + 1]
			local col = math.min(mark.col, line_len)
			local opts = mark.opts
			if opts.end_col then
				opts = vim.tbl_extend("force", opts, { end_col = math.min(opts.end_col, line_len) })
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, mark.line, col, opts)
		end
	end
end

return M
