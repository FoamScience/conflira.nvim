-- Phase 1 test: the Projection IR survives a JSON round-trip losslessly.
--
-- Proves the IR is a wire-serializable contract: a producer (this Lua build, or
-- a future Go core) can emit JSON that a consumer decodes back to the same
-- lines + neutral decorations. This is the prerequisite for an out-of-process core.
--
-- Run: nvim --headless -c "lua require('atlassian.editor.tests.ir_json').run()" -c "qa"
local M = {}

local FIXTURE = {
	type = "doc",
	content = {
		{ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Title" } } },
		{
			type = "paragraph",
			content = {
				{ type = "text", text = "a " },
				{ type = "text", text = "b", marks = { { type = "strong" } } },
			},
		},
		{
			type = "bulletList",
			content = {
				{ type = "listItem", content = { { type = "paragraph", content = { { type = "text", text = "one" } } } } },
			},
		},
		{
			type = "codeBlock",
			attrs = { language = "lua" },
			content = { { type = "text", text = "print(1)" } },
		},
	},
}

--- (lines, sorted decoration descriptors) for an IR.
---@param result table
---@return string[] lines, string[] decos
local function shape(result)
	local ir = require("atlassian.editor.ir")
	local lines = {}
	for i, l in ipairs(result.lines or {}) do lines[i] = l end
	local decos = {}
	for _, mark in ipairs(result.marks or {}) do
		local d = ir.classify(mark)
		local detail = d.hl and ("[" .. d.hl .. "]") or (d.text and ("[" .. d.text .. "]") or "")
		decos[#decos + 1] = string.format("%d:%d %s%s", mark.line, mark.col, d.kind, detail)
	end
	table.sort(decos)
	return lines, decos
end

local function diff(label, a, b)
	if #a ~= #b then return string.format("%s: %d vs %d", label, #a, #b) end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return string.format("%s[%d]: %q vs %q", label, i, tostring(a[i]), tostring(b[i]))
		end
	end
	return nil
end

---@return boolean ok
function M.run()
	pcall(function() require("jira-interface.config").setup({}) end)
	local render = require("atlassian.editor.render")
	local ir = require("atlassian.editor.ir")

	local direct = render.build_ir(FIXTURE)
	local roundtripped = ir.decode(ir.encode(direct))

	local dl, dd = shape(direct)
	local rl, rd = shape(roundtripped)

	local errors = {}
	local e1 = diff("lines", dl, rl)
	local e2 = diff("decos", dd, rd)
	if e1 then errors[#errors + 1] = e1 end
	if e2 then errors[#errors + 1] = e2 end
	-- sanity: the fixture actually exercises multiple decoration kinds
	if #dd < 4 then errors[#errors + 1] = "fixture produced too few decorations: " .. #dd end

	if #errors == 0 then
		print("  ✓ IR JSON round-trip (lossless)")
		print("========================================")
		print("  Results: 1 passed, 0 failed")
		print("========================================")
		return true
	end

	print("  ✗ IR JSON round-trip")
	for _, err in ipairs(errors) do print("    " .. err) end
	print("========================================")
	print("  Results: 0 passed, 1 failed")
	print("========================================")
	return false
end

return M
