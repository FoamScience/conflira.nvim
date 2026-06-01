-- Golden test for the Projection IR contract.
--
-- Locks `render.build_ir(adf)` output (clean lines + neutral decoration
-- descriptors via ir.classify) against a frozen snapshot. If a refactor changes
-- the IR — e.g. when extracting the build to a Go core — this catches the drift.
--
-- Run: nvim --headless -c "lua require('atlassian.editor.tests.render_golden').run()" -c "qa"
local M = {}

local FIXTURE = {
	type = "doc",
	content = {
		{ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Title" } } },
		{
			type = "paragraph",
			content = {
				{ type = "text", text = "hello " },
				{ type = "text", text = "bold", marks = { { type = "strong" } } },
				{ type = "text", text = " and " },
				{ type = "text", text = "code", marks = { { type = "code" } } },
			},
		},
		{
			type = "bulletList",
			content = {
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "one" } } } } },
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "two" } } } } },
			},
		},
	},
}

local EXPECTED_LINES = {
	"Title",
	"",
	"hello bold and code",
	"",
	"one",
	"two",
}

-- Neutral decoration descriptors, sorted as "line:col kind[detail]".
local EXPECTED_DECOS = {
	"0:0 highlight[heading.2]",
	"0:0 sign[heading.2]",
	"2:15 highlight[code]",
	"2:6 highlight[strong]",
	"4:0 inline_text",
	"5:0 inline_text",
}

--- Produce the normalized snapshot (lines, decos) for the fixture.
---@return string[] lines, string[] decos
local function snapshot()
	local render = require("atlassian.editor.render")
	local ir = require("atlassian.editor.ir")
	local result = render.build_ir(FIXTURE)

	local decos = {}
	for _, mark in ipairs(result.marks) do
		local d = ir.classify(mark)
		local detail = d.hl and ("[" .. d.hl .. "]") or (d.text and ("[" .. d.text .. "]") or "")
		decos[#decos + 1] = string.format("%d:%d %s%s", mark.line, mark.col, d.kind, detail)
	end
	table.sort(decos)
	return result.lines, decos
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
		print("  ✓ projection IR golden")
		print("========================================")
		print("  Results: 1 passed, 0 failed")
		print("========================================")
		return true
	end

	print("  ✗ projection IR golden")
	for _, err in ipairs(errors) do
		print("    " .. err)
	end
	print("========================================")
	print("  Results: 0 passed, 1 failed")
	print("========================================")
	return false
end

return M
