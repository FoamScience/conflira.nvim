-- Golden test for the board BoardIR contract.
--
-- Locks `render.build_ir(board_state)` output (whitespace-normalized lines +
-- neutral decoration descriptors via ir.classify) against a frozen snapshot.
-- Lines are normalized (internal whitespace collapsed, trimmed) so cosmetic
-- padding tweaks don't break the test, while the decoration descriptors — the
-- portable cross-editor contract — are asserted exactly.
--
-- Run: nvim --headless -c "lua require('atlassian.board.tests.render_golden').run()" -c "qa"
local M = {}

local ISSUES = {
	{ key = "F-1", summary = "Feature one", status = "In Progress", type = "Feature", level = 2, parent = nil, labels = {}, fix_versions = {}, links = {}, children = {}, custom_fields_raw = {} },
	{ key = "T-1", summary = "Task one", status = "To Do", type = "Task", level = 3, parent = "F-1", labels = {}, fix_versions = {}, links = {}, children = {}, custom_fields_raw = {} },
}

local EXPECTED_LINES = {
	"P │ 1 issues │",
	string.rep("━", 80),
	"",
	"▼ F-1 Feature one",
	"│",
	"└── T-1 Task one",
	"",
	"",
	"[e]dit [t]ransition [a]ssign [c]omment [/]search [g]roup [r]efresh [?]help",
}

local EXPECTED_DECOS = {
	"0:0 eol_text",
	"0:0 highlight[title]",
	"0:20 inline_text",
	"1:0 highlight[muted]",
	"3:0 eol_text",
	"3:0 sign[text]",
	"3:22 highlight[text]",
	"3:4 highlight[heading.2]",
	"3:4 inline_text",
	"4:0 highlight[muted]",
	"4:24 inline_text",
	"5:0 eol_text",
	"5:0 highlight[muted]",
	"5:0 sign[text]",
	"5:12 highlight[accent.fn]",
	"5:12 inline_text",
	"5:2 highlight[muted]",
	"5:26 highlight[text]",
	"6:0 highlight[muted]",
	"6:22 inline_text",
	"8:0 highlight[statusline]",
}

---@return string[] lines, string[] decos
local function snapshot()
	local render = require("atlassian.board.render")
	local state = require("atlassian.board.state")
	local ir = require("atlassian.editor.ir")

	local tree = state.filter_for_display(state.build_tree(ISSUES, nil), "leaves")
	local board = { tree = tree, issues = ISSUES, groups = state.group_nodes(tree, "none"), project = "P" }
	local result = render.build_ir(board)

	local lines = {}
	for _, l in ipairs(result.lines) do
		lines[#lines + 1] = l:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	end

	local decos = {}
	for _, mark in ipairs(result.marks) do
		local d = ir.classify(mark)
		local detail = d.hl and ("[" .. d.hl .. "]") or (d.text and ("[" .. d.text .. "]") or "")
		decos[#decos + 1] = string.format("%d:%d %s%s", mark.line, mark.col, d.kind, detail)
	end
	table.sort(decos)
	return lines, decos
end

local function diff(label, got, expected)
	if #got ~= #expected then
		return string.format("%s: length %d, expected %d", label, #got, #expected)
	end
	for i = 1, #expected do
		if got[i] ~= expected[i] then
			return string.format("%s[%d]: got %q, expected %q", label, i, tostring(got[i]), expected[i])
		end
	end
	return nil
end

---@return boolean ok
function M.run()
	pcall(function() require("jira-interface.config").setup({}) end)

	local lines, decos = snapshot()
	local errors = {}
	local e1 = diff("lines", lines, EXPECTED_LINES)
	local e2 = diff("decos", decos, EXPECTED_DECOS)
	if e1 then errors[#errors + 1] = e1 end
	if e2 then errors[#errors + 1] = e2 end

	if #errors == 0 then
		print("  ✓ board IR golden")
		print("========================================")
		print("  Results: 1 passed, 0 failed")
		print("========================================")
		return true
	end

	print("  ✗ board IR golden")
	for _, err in ipairs(errors) do
		print("    " .. err)
	end
	print("========================================")
	print("  Results: 0 passed, 1 failed")
	print("========================================")
	return false
end

return M
