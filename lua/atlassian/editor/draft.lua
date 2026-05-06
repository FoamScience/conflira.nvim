local M = {}

local debounce_ms = 150

---@param eb EditorBuffer
local function update_winbar(eb)
	local buf = eb.buf
	if not vim.api.nvim_buf_is_valid(buf) then return end

	local wins = vim.fn.win_findbuf(buf)
	local label = eb.metadata and eb.metadata.key or "Atlassian"
	local status = eb.dirty and " DRAFT" or " SAVED"
	local bar = status .. "  " .. label .. "  %=  <leader>ss to submit "

	for _, w in ipairs(wins) do
		if vim.api.nvim_win_is_valid(w) then
			vim.wo[w].winbar = bar
		end
	end
end

--- Attach draft tracking to an EditorBuffer.
---@param eb EditorBuffer
function M.attach(eb)
	local buf = eb.buf
	local timer = vim.uv.new_timer()
	local group = vim.api.nvim_create_augroup("atlas_editor_draft_" .. buf, { clear = true })

	local function check_dirty()
		if not vim.api.nvim_buf_is_valid(buf) then return end
		update_winbar(eb)
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			timer:stop()
			timer:start(debounce_ms, 0, vim.schedule_wrap(check_dirty))
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
		group = group,
		buffer = buf,
		callback = function()
			update_winbar(eb)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			timer:stop()
			timer:close()
		end,
	})

	-- Initial winbar
	update_winbar(eb)
end

--- Mark the EditorBuffer as clean (after successful submit).
---@param eb EditorBuffer
function M.mark_clean(eb)
	eb.dirty = false
	eb.adf_snapshot = vim.deepcopy(eb.adf)
	update_winbar(eb)
end

return M
