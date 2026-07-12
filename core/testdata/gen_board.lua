-- Board parity fixture generator. Runs the FROZEN Lua board pipeline
-- (build_tree → filter_for_display → group_nodes → build_ir) on issue sets and
-- writes { <name>.board.json, <name>.ir.json } under cases_board/. Fixtures are
-- kept deterministic (no duedate / no stale updated) so urgency is stable.
--
-- Run: nvim --headless -c "luafile core/testdata/gen_board.lua" -c "qa"
require("jira-interface.config").setup({})
local state = require("atlassian.board.state")
local render = require("atlassian.board.render")
local ir = require("atlassian.editor.ir")

local dir = "core/testdata/cases_board/"
vim.fn.mkdir(dir, "p")

local function issue(t)
	t.labels = t.labels or {}
	t.fix_versions = t.fix_versions or {}
	t.links = t.links or {}
	t.children = {}
	t.custom_fields_raw = t.custom_fields_raw or {}
	return t
end

local cases = {
	simple = {
		project = "P", group = "none",
		issues = {
			issue({ key = "F-1", summary = "Feature one", status = "In Progress", type = "Feature", level = 2 }),
			issue({ key = "T-1", summary = "Task one", status = "To Do", type = "Task", level = 3, parent = "F-1" }),
		},
	},
	-- Note: leaf status counts are kept DISTINCT so the count-descending status
	-- breakdown is deterministic (the Lua sort is unstable for equal counts).
	two_trees = {
		project = "P", group = "none",
		issues = {
			issue({ key = "F-1", summary = "Alpha", status = "In Progress", type = "Feature", level = 2 }),
			issue({ key = "T-1", summary = "a1", status = "To Do", type = "Task", level = 3, parent = "F-1" }),
			issue({ key = "B-1", summary = "Beta bug", status = "In Progress", type = "Bug", level = 2 }),
			issue({ key = "T-2", summary = "b1", status = "To Do", type = "Task", level = 3, parent = "B-1" }),
		},
	},
	grouped_status = {
		project = "P", group = "status",
		issues = {
			issue({ key = "T-1", summary = "todo task", status = "To Do", type = "Task", level = 3 }),
			issue({ key = "T-3", summary = "todo two", status = "To Do", type = "Task", level = 3 }),
			issue({ key = "T-2", summary = "prog task", status = "In Progress", type = "Task", level = 3 }),
		},
	},
	kind_cycle = {
		project = "P", group = "none",
		issues = {
			issue({ key = "F-1", summary = "Meshing SU1/26", status = "In Progress", type = "Feature", level = 2,
				labels = { "shape-up-goal" }, fix_versions = { "SU1/26" } }),
			issue({ key = "T-1", summary = "impl", status = "To Do", type = "Task", level = 3, parent = "F-1" }),
		},
	},
	blocked = {
		project = "P", group = "none",
		issues = {
			issue({ key = "F-1", summary = "blocked feat", status = "To Do", type = "Feature", level = 2,
				links = { { link_type = "Blocks", direction = "inward", label = "is blocked by", issue_key = "X-9", issue_status = "To Do" } } }),
			issue({ key = "T-1", summary = "t", status = "To Do", type = "Task", level = 3, parent = "F-1" }),
		},
	},
	readiness = {
		project = "P", group = "none",
		issues = {
			issue({ key = "F-1", summary = "ready feat", status = "To Do", type = "Feature", level = 2,
				description = "d", acceptance_criteria = "ac", fix_versions = { "SU1/26" }, parent = "E-1" }),
			issue({ key = "T-1", summary = "child", status = "To Do", type = "Task", level = 3, parent = "F-1", description = "d" }),
		},
	},
}

local names = {}
for n in pairs(cases) do names[#names + 1] = n end
table.sort(names)

for _, name in ipairs(names) do
	local c = cases[name]
	local tree = state.filter_for_display(state.build_tree(c.issues, nil), "leaves")
	local groups = state.group_nodes(tree, c.group)
	local board = { tree = tree, issues = c.issues, groups = groups, project = c.project }

	local bf = io.open(dir .. name .. ".board.json", "w")
	bf:write(vim.json.encode({ issues = c.issues, project = c.project, group = c.group }))
	bf:close()
	local rf = io.open(dir .. name .. ".ir.json", "w")
	rf:write(ir.encode(render.build_ir(board)))
	rf:close()
	print("wrote " .. name)
end
