local render = require("atlassian.editor.render")
local extmarks_mod = require("atlassian.editor.extmarks")

local M = {}

---@param eb EditorBuffer
local function resolve_path(eb, path)
	local node = eb.adf
	local parent, idx
	for _, i in ipairs(path) do
		parent = node
		idx = i
		node = (node.content or {})[i]
		if not node then
			return nil
		end
	end
	return node, parent, idx
end

--- Extract text from a buffer line for a given span range.
---@param buf_line string The full buffer line text
---@param spans RenderSpan[] All spans on this line
---@return table<string, string> Map of serialized path → new text
local function extract_span_texts(buf_line, spans)
	local result = {}
	local line_len = #buf_line
	for _, span in ipairs(spans) do
		if span.editable and span.field == "text" then
			local s = math.min(span.col_start, line_len)
			local e = math.min(span.col_end, line_len)
			local key = table.concat(span.path, ".")
			result[key] = { path = span.path, text = buf_line:sub(s + 1, e) }
		end
	end
	return result
end

--- Apply a single-line text change to the ADF tree.
--- Returns true if handled, false if a full re-render is needed.
---@param eb EditorBuffer
---@param line number 0-indexed line that changed
---@return boolean handled
local function sync_line(eb, line)
	local spans = eb.line_to_spans[line]
	if not spans or #spans == 0 then
		return false
	end

	local buf_line = vim.api.nvim_buf_get_lines(eb.buf, line, line + 1, false)[1]
	if not buf_line then
		return false
	end

	-- Single editable text span on this line — fast path
	local editable_spans = {}
	for _, span in ipairs(spans) do
		if span.editable and span.field == "text" then
			editable_spans[#editable_spans + 1] = span
		end
	end

	if #editable_spans == 0 then
		return false
	end

	if #editable_spans == 1 then
		-- Single text node owns the editable content on this line
		local span = editable_spans[1]
		local node = resolve_path(eb, span.path)
		if not node or node.type ~= "text" then
			return false
		end

		-- The editable text is the whole line minus any virtual prefix (indent, bullet, etc.)
		-- For paragraphs at root level, col_start is 0. For list items, col_start accounts for indent.
		local new_text = buf_line:sub(span.col_start + 1)
		node.text = new_text
		eb.dirty = true

		-- Update span to reflect new text length
		span.col_end = span.col_start + #new_text

		return true
	end

	-- Multiple text spans on one line (e.g., paragraph with bold + regular text)
	-- We need to figure out which spans changed by looking at the total text length change.
	--
	-- Strategy: The line text is the concatenation of all span texts.
	-- If total length changed, distribute the change to the spans proportionally.
	-- This is an approximation — works well for edits within a single span.

	-- Compute old total span length
	local old_total = 0
	local first_col = editable_spans[1].col_start
	for _, span in ipairs(editable_spans) do
		old_total = old_total + (span.col_end - span.col_start)
	end

	local editable_region = buf_line:sub(first_col + 1)
	local new_total = #editable_region

	if new_total == old_total then
		-- Same length — re-extract each span's text at original boundaries
		for _, span in ipairs(editable_spans) do
			local node = resolve_path(eb, span.path)
			if node and node.type == "text" then
				local rel_start = span.col_start - first_col
				local rel_end = span.col_end - first_col
				node.text = editable_region:sub(rel_start + 1, rel_end)
			end
		end
		eb.dirty = true
		return true
	end

	-- Length changed — find which span the cursor is in and assign the delta to it
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_col = cursor[2] -- 0-indexed byte column

	local target_span = nil
	for _, span in ipairs(editable_spans) do
		if cursor_col >= span.col_start and cursor_col <= span.col_end + (new_total - old_total) then
			target_span = span
			break
		end
	end

	if not target_span then
		target_span = editable_spans[#editable_spans]
	end

	-- Assign the length delta to the target span
	local delta = new_total - old_total
	local offset = 0
	for _, span in ipairs(editable_spans) do
		local span_len = span.col_end - span.col_start
		if span == target_span then
			span_len = span_len + delta
		end
		local node = resolve_path(eb, span.path)
		if node and node.type == "text" then
			node.text = editable_region:sub(offset + 1, offset + span_len)
		end
		span.col_end = span.col_start + offset + span_len
		offset = offset + span_len
	end

	-- Update all span boundaries after the target
	local running_col = first_col
	for _, span in ipairs(editable_spans) do
		local node = resolve_path(eb, span.path)
		local len = node and node.text and #node.text or (span.col_end - span.col_start)
		span.col_start = running_col
		span.col_end = running_col + len
		running_col = running_col + len
	end

	eb.dirty = true
	return true
end

--- Re-render a single line's extmarks without full buffer rewrite.
---@param eb EditorBuffer
---@param line number 0-indexed
local function refresh_line_extmarks(eb, line)
	local ns = extmarks_mod.ns
	local buf = eb.buf

	-- Clear extmarks on this line only
	local existing = vim.api.nvim_buf_get_extmarks(buf, ns, { line, 0 }, { line, -1 }, {})
	for _, mark in ipairs(existing) do
		vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
	end

	-- Re-render just this line's marks from the result
	-- For now, do a lightweight re-render of inline marks based on current span state
	local spans = eb.line_to_spans[line]
	if not spans then return end

	local buf_line = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
	if not buf_line then return end
	local line_len = #buf_line

	for _, span in ipairs(spans) do
		if span.editable and span.field == "text" then
			local node = resolve_path(eb, span.path)
			if node and node.marks then
				for _, mark in ipairs(node.marks) do
					local hl = extmarks_mod.mark_hl[mark.type]
					if hl then
						local col_s = math.min(span.col_start, line_len)
						local col_e = math.min(span.col_end, line_len)
						pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, col_s, {
							end_col = col_e,
							hl_group = hl,
						})
					end
				end
			end
		end
	end
end

--- Full re-render from ADF tree (fallback for structural changes).
---@param eb EditorBuffer
local function full_rerender(eb)
	local buf = eb.buf
	local result = render.render(eb.adf)
	eb.render_result = result
	eb.line_to_spans = render.build_line_to_spans(result)
	eb.path_to_lines = render.build_path_to_lines(result)

	eb.suppress_sync = true
	vim.bo[buf].modifiable = true
	render.apply(buf, result)
	vim.bo[buf].modifiable = true -- keep editable
	eb.suppress_sync = false
end

--- Attach sync to an EditorBuffer. Call once after open.
---@param eb EditorBuffer
function M.attach(eb)
	local buf = eb.buf
	local pending = { first = nil, last_old = nil, last_new = nil }
	local sync_timer = vim.uv.new_timer()

	local function do_sync()
		if eb.suppress_sync then return end
		if not pending.first then return end

		local first = pending.first
		local last_old = pending.last_old
		local last_new = pending.last_new
		pending.first = nil
		pending.last_old = nil
		pending.last_new = nil

		if not vim.api.nvim_buf_is_valid(buf) then return end

		local ok, err = pcall(function()
			local lines_delta = last_new - last_old

			if lines_delta == 0 then
				for line = first, last_new - 1 do
					local handled = sync_line(eb, line)
					if handled then
						refresh_line_extmarks(eb, line)
					end
				end
			elseif lines_delta > 0 then
				-- Lines added (paste, Enter, etc.)
				-- Try to absorb new lines as new paragraph nodes
				local spans = eb.line_to_spans[first]
				if spans and #spans > 0 then
					local top_idx = spans[1].path[1]
					local node = (eb.adf.content or {})[top_idx]

					if node and node.type == "paragraph" then
						-- Update existing paragraph with first line text
						local new_lines = vim.api.nvim_buf_get_lines(buf, first, last_new, false)
						if new_lines and #new_lines > 0 then
							node.content = { { type = "text", text = new_lines[1] or "" } }
							-- Insert new paragraphs for each additional line
							for i = 2, #new_lines do
								local new_para = {
									type = "paragraph",
									content = { { type = "text", text = new_lines[i] or "" } },
								}
								table.insert(eb.adf.content, top_idx + i - 1, new_para)
							end
							eb.dirty = true
						end
					end
				end
				full_rerender(eb)
			else
				-- Lines removed (delete, join)
				full_rerender(eb)
			end
		end)
		if not ok then
			vim.notify("sync error: " .. tostring(err), vim.log.levels.DEBUG)
			pcall(full_rerender, eb)
		end
	end

	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, first, last_old, last_new)
			if eb.suppress_sync then return end

			-- Accumulate changes
			if not pending.first then
				pending.first = first
				pending.last_old = last_old
				pending.last_new = last_new
			else
				pending.first = math.min(pending.first, first)
				pending.last_old = math.max(pending.last_old, last_old)
				pending.last_new = math.max(pending.last_new, last_new)
			end

			-- Debounce: 30ms in insert mode, immediate in normal
			local delay = vim.fn.mode():find("i") and 30 or 1
			sync_timer:stop()
			sync_timer:start(delay, 0, vim.schedule_wrap(do_sync))
		end,

		on_detach = function()
			sync_timer:stop()
			sync_timer:close()
		end,
	})
end

return M
