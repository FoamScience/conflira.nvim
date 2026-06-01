-- Aggregate test runner: unit suite + projection/board IR golden tests.
--
-- Run: nvim --headless -c "lua require('atlassian.tests').run_all()" -c "qa"
local M = {}

---@return boolean ok
function M.run_all()
	pcall(function() require("jira-interface.config").setup({}) end)

	local results = {}

	print("[jira-interface unit suite]")
	results[#results + 1] = require("jira-interface.tests.init").run()

	print("\n[projection IR golden]")
	results[#results + 1] = require("atlassian.editor.tests.render_golden").run()

	print("\n[board IR golden]")
	results[#results + 1] = require("atlassian.board.tests.render_golden").run()

	print("\n[IR JSON round-trip]")
	results[#results + 1] = require("atlassian.editor.tests.ir_json").run()

	local all_ok = true
	for _, ok in ipairs(results) do
		all_ok = all_ok and ok
	end

	print("\n========================================")
	print(all_ok and "  ALL SUITES PASSED" or "  SOME SUITES FAILED")
	print("========================================")
	return all_ok
end

return M
