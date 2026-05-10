--- Markdown-style input detection for the ADF projection editor.
--- Detects patterns like `## `, `- `, `- [ ] `, `> `, `---` at line start
--- and converts the current paragraph to the appropriate ADF node.
local M = {}

local function get_editor()
	return require("atlassian.editor")
end

local patterns = {
	{ match = "^(######)%s", type = "heading", level = 6 },
	{ match = "^(#####)%s", type = "heading", level = 5 },
	{ match = "^(####)%s", type = "heading", level = 4 },
	{ match = "^(###)%s", type = "heading", level = 3 },
	{ match = "^(##)%s", type = "heading", level = 2 },
	{ match = "^(#)%s", type = "heading", level = 1 },
	{ match = "^(-%s%[x%])%s", type = "taskItem", state = "DONE" },
	{ match = "^(-%s%[ %])%s", type = "taskItem", state = "TODO" },
	{ match = "^(%d+%.)%s", type = "orderedList" },
	{ match = "^(-)%s", type = "bulletList" },
	{ match = "^(%*)%s", type = "bulletList" },
	{ match = "^(>)%s", type = "blockquote" },
	{ match = "^(---)$", type = "rule" },
	{ match = "^(```)$", type = "codeBlock" },
}

---@param eb EditorBuffer
---@param row number 0-indexed
---@param line_text string
---@return boolean handled
local function try_convert(eb, row, line_text)
	for _, pat in ipairs(patterns) do
		local prefix = line_text:match(pat.match)
		if prefix then
			local remaining = line_text:sub(#prefix + 1):gsub("^%s", "")

			-- Find which top-level ADF node this line belongs to
			local spans = eb.line_to_spans[row]
			if not spans or #spans == 0 then return false end
			local top_idx = spans[1].path[1]
			local node = (eb.adf.content or {})[top_idx]
			if not node then return false end

			-- Only convert paragraphs (don't re-convert existing structural nodes)
			if node.type ~= "paragraph" then return false end

			if pat.type == "heading" then
				eb.adf.content[top_idx] = {
					type = "heading",
					attrs = { level = pat.level },
					content = { { type = "text", text = remaining } },
				}
			elseif pat.type == "bulletList" then
				eb.adf.content[top_idx] = {
					type = "bulletList",
					content = { {
						type = "listItem",
						content = { { type = "paragraph", content = { { type = "text", text = remaining } } } },
					} },
				}
			elseif pat.type == "orderedList" then
				eb.adf.content[top_idx] = {
					type = "orderedList",
					content = { {
						type = "listItem",
						content = { { type = "paragraph", content = { { type = "text", text = remaining } } } },
					} },
				}
			elseif pat.type == "taskItem" then
				eb.adf.content[top_idx] = {
					type = "taskList",
					content = { {
						type = "taskItem",
						attrs = { state = pat.state },
						content = { { type = "paragraph", content = { { type = "text", text = remaining } } } },
					} },
				}
			elseif pat.type == "blockquote" then
				eb.adf.content[top_idx] = {
					type = "blockquote",
					content = { {
						type = "paragraph",
						content = { { type = "text", text = remaining } },
					} },
				}
			elseif pat.type == "rule" then
				eb.adf.content[top_idx] = { type = "rule" }
			elseif pat.type == "codeBlock" then
				eb.adf.content[top_idx] = {
					type = "codeBlock",
					attrs = { language = "" },
					content = { { type = "text", text = "" } },
				}
			end

			eb.dirty = true
			get_editor().refresh(eb.buf)

			-- Position cursor at end of remaining text on the converted line
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(eb.buf) then return end
				local line_count = vim.api.nvim_buf_line_count(eb.buf)
				local target_row = math.min(row + 1, line_count)
				local target_line = vim.api.nvim_buf_get_lines(eb.buf, target_row - 1, target_row, false)[1] or ""
				vim.api.nvim_win_set_cursor(0, { target_row, #target_line })
			end)

			return true
		end
	end
	return false
end

---@param eb EditorBuffer
function M.attach(eb)
	local buf = eb.buf
	local group = vim.api.nvim_create_augroup("atlas_editor_mdinput_" .. buf, { clear = true })

	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = buf,
		callback = function()
			if eb.suppress_sync then return end

			local cursor = vim.api.nvim_win_get_cursor(0)
			local row = cursor[1] - 1 -- 0-indexed
			local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""

			try_convert(eb, row, line_text)
		end,
	})
end

return M
