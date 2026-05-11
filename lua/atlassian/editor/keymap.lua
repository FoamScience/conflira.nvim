local M = {}

local function get_editor()
	return require("atlassian.editor")
end

--- Get the EditorBuffer for the current buffer, or nil.
---@return EditorBuffer|nil
local function get_eb()
	return get_editor().get(vim.api.nvim_get_current_buf())
end

--- Get the ADF node at the cursor line.
---@param eb EditorBuffer
---@return table|nil node, number[]|nil path
local function node_at_cursor(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
	local result = eb.render_result
	if not result then return nil, nil end

	local node = result.line_to_node[row]
	if not node then return nil, nil end

	-- Find the path for this node via spans
	local spans = eb.line_to_spans[row]
	if spans and #spans > 0 then
		-- Walk up to find the top-level content index
		local path = spans[1].path
		return node, path
	end

	return node, nil
end

--- Find the index of a node in its parent's content array.
---@param parent table
---@param node table
---@return number|nil
local function find_child_index(parent, node)
	for i, child in ipairs(parent.content or {}) do
		if child == node then return i end
	end
	return nil
end

--- Find the top-level ADF content index for the node at cursor.
---@param eb EditorBuffer
---@return number|nil index, table|nil node
local function top_level_index_at_cursor(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local spans = eb.line_to_spans[row]
	if spans and #spans > 0 then
		return spans[1].path[1], (eb.adf.content or {})[spans[1].path[1]]
	end
	-- Fallback: scan line_to_node
	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]
	if node then
		for i, n in ipairs(eb.adf.content or {}) do
			if n == node then return i, n end
		end
	end
	return nil, nil
end

--- Refresh buffer after ADF mutation. Tries to restore cursor near its original position.
---@param eb EditorBuffer
local function rerender(eb)
	local cursor = vim.api.nvim_win_get_cursor(0)
	eb.dirty = true
	get_editor().refresh(eb.buf)
	-- Restore cursor (clamp to new line count)
	local line_count = vim.api.nvim_buf_line_count(eb.buf)
	local row = math.min(cursor[1], line_count)
	local line = vim.api.nvim_buf_get_lines(eb.buf, row - 1, row, false)[1] or ""
	local col = math.min(cursor[2], #line)
	vim.api.nvim_win_set_cursor(0, { row, col })
end

-- ============================================================================
-- Insert mode: <CR>
-- ============================================================================

local function handle_cr_insert(eb)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1 -- 0-indexed
	local col = cursor[2]

	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]
	if not node then
		-- Fallback: let Vim handle it
		return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
	end

	-- Task item or list item context: find the parent list
	if node.type == "taskItem" or node.type == "listItem" then
		-- Find parent list in ADF
		local spans = eb.line_to_spans[row]
		if not spans or #spans == 0 then return end
		local path = spans[1].path

		-- path like {3, 2, 1} = doc.content[3].content[2].content[1]
		-- The list item is at path minus last element, the list is one more up
		if #path >= 2 then
			local list_idx = path[1]
			local item_idx = path[2]
			local list_node = (eb.adf.content or {})[list_idx]

			if list_node and (list_node.type == "bulletList" or list_node.type == "orderedList" or list_node.type == "taskList") then
				-- Check if current item is empty
				local item = (list_node.content or {})[item_idx]
				local item_text = ""
				if item and item.content then
					for _, child in ipairs(item.content) do
						if child.type == "paragraph" and child.content then
							for _, inline in ipairs(child.content) do
								if inline.type == "text" then
									item_text = item_text .. (inline.text or "")
								end
							end
						end
					end
				end

				if vim.trim(item_text) == "" then
					-- Empty item: remove it. If list becomes empty, remove list too.
					table.remove(list_node.content, item_idx)
					if #(list_node.content or {}) == 0 then
						local top_idx = path[1]
						table.remove(eb.adf.content, top_idx)
						-- Insert empty paragraph in its place
						table.insert(eb.adf.content, top_idx, {
							type = "paragraph",
							content = { { type = "text", text = "" } },
						})
					end
				else
					-- Non-empty: insert new item after current
					local new_item
					if list_node.type == "taskList" then
						new_item = {
							type = "taskItem",
							attrs = { state = "TODO" },
							content = { { type = "paragraph", content = { { type = "text", text = "" } } } },
						}
					else
						new_item = {
							type = "listItem",
							content = { { type = "paragraph", content = { { type = "text", text = "" } } } },
						}
					end
					table.insert(list_node.content, item_idx + 1, new_item)
				end

				rerender(eb)
				-- Move cursor to the new item line
				vim.api.nvim_win_set_cursor(0, { cursor[1] + 1, 0 })
				vim.cmd("startinsert")
				return
			end
		end
	end

	-- Paragraph context: split at cursor
	if node.type == "paragraph" then
		local line_text = vim.api.nvim_buf_get_lines(eb.buf, row, row + 1, false)[1] or ""
		local before = line_text:sub(1, col)
		local after = line_text:sub(col + 1)

		-- Find this paragraph in the ADF tree
		local spans = eb.line_to_spans[row]
		if not spans or #spans == 0 then return end
		local top_idx = spans[1].path[1]
		local para = (eb.adf.content or {})[top_idx]

		if para and para.type == "paragraph" then
			-- Replace paragraph text with "before", insert new paragraph with "after"
			para.content = { { type = "text", text = before } }
			local new_para = {
				type = "paragraph",
				content = { { type = "text", text = after } },
			}
			table.insert(eb.adf.content, top_idx + 1, new_para)

			rerender(eb)
			vim.api.nvim_win_set_cursor(0, { cursor[1] + 1, 0 })
			vim.cmd("startinsert")
			return
		end
	end

	-- Default: feed through
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
end

-- ============================================================================
-- Insert mode: <BS> at column 0
-- ============================================================================

local function handle_bs_insert(eb)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local col = cursor[2]

	if col > 0 then
		-- Not at start of line — let Vim handle
		return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
	end

	local row = cursor[1] - 1 -- 0-indexed
	if row == 0 then return end -- first line, nothing to merge with

	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]
	local prev_node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row - 1]

	if not node or not prev_node then return end

	-- Both paragraphs: merge
	if node.type == "paragraph" and prev_node.type == "paragraph" then
		local spans = eb.line_to_spans[row]
		local prev_spans = eb.line_to_spans[row - 1]
		if not spans or not prev_spans or #spans == 0 or #prev_spans == 0 then return end

		local cur_idx = spans[1].path[1]
		local prev_idx = prev_spans[1].path[1]

		if cur_idx ~= prev_idx then
			local prev_para = (eb.adf.content or {})[prev_idx]
			local cur_para = (eb.adf.content or {})[cur_idx]

			if prev_para and cur_para then
				-- Compute cursor position: end of previous paragraph text
				local prev_text_len = 0
				for _, child in ipairs(prev_para.content or {}) do
					if child.type == "text" then
						prev_text_len = prev_text_len + #(child.text or "")
					end
				end

				-- Append current paragraph's content to previous
				for _, child in ipairs(cur_para.content or {}) do
					table.insert(prev_para.content, child)
				end
				table.remove(eb.adf.content, cur_idx)

				rerender(eb)
				vim.api.nvim_win_set_cursor(0, { cursor[1] - 1, prev_text_len })
				return
			end
		end
	end

	-- Default: feed through
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
end

-- ============================================================================
-- Normal mode: J (join / merge with next)
-- ============================================================================

local function handle_join(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1

	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]
	if not node or node.type ~= "paragraph" then
		-- Not a paragraph — use default J
		return vim.cmd("normal! J")
	end

	local spans = eb.line_to_spans[row]
	if not spans or #spans == 0 then return end
	local cur_idx = spans[1].path[1]

	-- Find next top-level node
	local next_node = (eb.adf.content or {})[cur_idx + 1]
	if not next_node or next_node.type ~= "paragraph" then
		return -- can only join adjacent paragraphs
	end

	local cur_para = (eb.adf.content or {})[cur_idx]

	-- Compute join position
	local cur_text_len = 0
	for _, child in ipairs(cur_para.content or {}) do
		if child.type == "text" then
			cur_text_len = cur_text_len + #(child.text or "")
		end
	end

	-- Add a space between joined content
	table.insert(cur_para.content, { type = "text", text = " " })

	for _, child in ipairs(next_node.content or {}) do
		table.insert(cur_para.content, child)
	end
	table.remove(eb.adf.content, cur_idx + 1)

	rerender(eb)
	vim.api.nvim_win_set_cursor(0, { row + 1, cur_text_len })
end

-- ============================================================================
-- Normal mode: >> / << (indent / outdent list items)
-- ============================================================================

local function handle_indent(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]

	if not node then return end

	-- Only works on list items (paragraph inside a list)
	local spans = eb.line_to_spans[row]
	if not spans or #spans == 0 then return end
	local path = spans[1].path

	if #path < 2 then return end
	local list_idx = path[1]
	local item_idx = path[2]
	local list_node = (eb.adf.content or {})[list_idx]

	if not list_node or not (list_node.type == "bulletList" or list_node.type == "orderedList" or list_node.type == "taskList") then
		return
	end

	-- Can't indent first item (nothing to nest under)
	if item_idx <= 1 then return end

	local item = list_node.content[item_idx]
	local prev_item = list_node.content[item_idx - 1]

	-- Remove item from current position
	table.remove(list_node.content, item_idx)

	-- Create or find nested list inside previous item
	local nested_list = nil
	for _, child in ipairs(prev_item.content or {}) do
		if child.type == list_node.type then
			nested_list = child
			break
		end
	end

	if not nested_list then
		nested_list = { type = list_node.type, content = {} }
		table.insert(prev_item.content, nested_list)
	end

	table.insert(nested_list.content, item)

	rerender(eb)
end

local function handle_outdent(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local spans = eb.line_to_spans[row]
	if not spans or #spans == 0 then return end
	local path = spans[1].path

	-- Outdent requires path depth >= 4: doc.content[X].content[Y].content[Z].content[W]
	-- meaning we're inside a nested list
	if #path < 4 then return end

	-- For now, only handle one level of nesting
	-- This is a simplification — deep nesting needs recursive path walking
	-- TODO: handle arbitrary depth in Phase 6
end

-- ============================================================================
-- Normal mode: <CR> on task item — toggle checkbox
-- ============================================================================

local function handle_cr_normal(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]

	if node and node.type == "taskItem" then
		if node.attrs then
			node.attrs.state = node.attrs.state == "DONE" and "TODO" or "DONE"
		else
			node.attrs = { state = "DONE" }
		end
		eb.dirty = true
		rerender(eb)
		vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
		return
	end

	-- Default: feed through
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
end

-- ============================================================================
-- Normal mode: <Tab> / <S-Tab> in table — cell navigation
-- ============================================================================

local function is_in_table(eb)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row]
	return node and (node.type == "tableRow" or node.type == "tableCell" or node.type == "tableHeader")
end

local function handle_tab_table(eb, reverse)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local spans = eb.line_to_spans[row]
	if not spans then return end

	-- Find editable spans on this line (table cells)
	local editable = {}
	for _, span in ipairs(spans) do
		if span.editable then
			editable[#editable + 1] = span
		end
	end

	if #editable == 0 then return end

	-- Find current cell
	local current_idx = nil
	for i, span in ipairs(editable) do
		if col >= span.col_start and col < span.col_end then
			current_idx = i
			break
		end
	end

	if not current_idx then
		current_idx = reverse and #editable or 1
	end

	local next_idx
	if reverse then
		next_idx = current_idx - 1
		if next_idx < 1 then
			-- Move to previous row, last cell
			if row > 0 then
				local prev_spans = eb.line_to_spans[row - 1]
				local prev_node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row - 1]
				if prev_node and (prev_node.type == "tableRow") and prev_spans then
					local prev_editable = {}
					for _, span in ipairs(prev_spans) do
						if span.editable then prev_editable[#prev_editable + 1] = span end
					end
					if #prev_editable > 0 then
						local target = prev_editable[#prev_editable]
						vim.api.nvim_win_set_cursor(0, { row, target.col_start })
						return
					end
				end
			end
			return
		end
	else
		next_idx = current_idx + 1
		if next_idx > #editable then
			-- Move to next row, first cell
			local next_spans = eb.line_to_spans[row + 1]
			local next_node = (eb.render_result or {}).line_to_node and eb.render_result.line_to_node[row + 1]
			if next_node and (next_node.type == "tableRow") and next_spans then
				local next_editable = {}
				for _, span in ipairs(next_spans) do
					if span.editable then next_editable[#next_editable + 1] = span end
				end
				if #next_editable > 0 then
					local target = next_editable[1]
					vim.api.nvim_win_set_cursor(0, { row + 2, target.col_start })
					return
				end
			end
			return
		end
	end

	local target = editable[next_idx]
	vim.api.nvim_win_set_cursor(0, { row + 1, target.col_start })
end

-- ============================================================================
-- Visual mode: mark toggling
-- ============================================================================

local function toggle_mark(eb, mark_type, attrs)
	local start_pos = vim.fn.getpos("v")
	local end_pos = vim.fn.getpos(".")
	-- Normalize so start <= end
	if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
		start_pos, end_pos = end_pos, start_pos
	end

	local row = start_pos[2] - 1 -- 0-indexed
	local col_start = start_pos[3] - 1
	local col_end = end_pos[3] -- end is inclusive in Vim, exclusive in our spans

	local spans = eb.line_to_spans[row]
	if not spans then return end

	for _, span in ipairs(spans) do
		if span.editable and span.field == "text" then
			-- Check if span overlaps with selection
			if span.col_start < col_end and span.col_end > col_start then
				local node = get_editor().resolve_path(eb.adf, span.path)
				if node and node.type == "text" then
					node.marks = node.marks or {}
					-- Check if mark already exists
					local found = nil
					for i, m in ipairs(node.marks) do
						if m.type == mark_type then
							found = i
							break
						end
					end
					if found then
						table.remove(node.marks, found)
						if #node.marks == 0 then node.marks = nil end
					else
						local mark = { type = mark_type }
						if attrs then mark.attrs = attrs end
						table.insert(node.marks, mark)
					end
				end
			end
		end
	end

	eb.dirty = true
	-- Exit visual mode and re-render
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	vim.schedule(function()
		rerender(eb)
	end)
end

-- ============================================================================
-- Normal mode: insert block commands
-- ============================================================================

local function insert_block(eb, block)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local spans = eb.line_to_spans[row]
	local insert_idx

	if spans and #spans > 0 then
		insert_idx = spans[1].path[1] + 1
	else
		insert_idx = #(eb.adf.content or {}) + 1
	end

	table.insert(eb.adf.content, insert_idx, block)
	eb.dirty = true
	rerender(eb)
end

local function prompt_insert_heading(eb)
	vim.ui.input({ prompt = "Heading level (1-6): " }, function(input)
		local level = tonumber(input)
		if not level or level < 1 or level > 6 then return end
		insert_block(eb, {
			type = "heading",
			attrs = { level = level },
			content = { { type = "text", text = "" } },
		})
	end)
end

local function prompt_insert_code_block(eb)
	vim.ui.input({ prompt = "Language: " }, function(lang)
		insert_block(eb, {
			type = "codeBlock",
			attrs = { language = lang or "" },
			content = { { type = "text", text = "" } },
		})
	end)
end

local function prompt_insert_table(eb)
	vim.ui.input({ prompt = "Rows x Cols (e.g. 3x2): " }, function(input)
		if not input then return end
		local rows, cols = input:match("(%d+)%s*x%s*(%d+)")
		rows = tonumber(rows) or 2
		cols = tonumber(cols) or 2

		local table_rows = {}
		for r = 1, rows do
			local cells = {}
			for c = 1, cols do
				local cell_type = r == 1 and "tableHeader" or "tableCell"
				table.insert(cells, {
					type = cell_type,
					content = { { type = "paragraph", content = { { type = "text", text = "" } } } },
				})
			end
			table.insert(table_rows, { type = "tableRow", content = cells })
		end

		insert_block(eb, { type = "table", content = table_rows })
	end)
end

local function insert_panel(eb)
	vim.ui.select({ "info", "note", "warning", "tip" }, { prompt = "Panel type:" }, function(choice)
		if not choice then return end
		insert_block(eb, {
			type = "panel",
			attrs = { panelType = choice },
			content = { { type = "paragraph", content = { { type = "text", text = "" } } } },
		})
	end)
end

local function insert_bullet_list(eb)
	insert_block(eb, {
		type = "bulletList",
		content = { {
			type = "listItem",
			content = { { type = "paragraph", content = { { type = "text", text = "" } } } },
		} },
	})
end

-- ============================================================================
-- Attach all keymaps to a buffer
-- ============================================================================

---@param eb EditorBuffer
function M.attach(eb)
	local buf = eb.buf
	local opts = function(desc)
		return { buffer = buf, desc = desc, nowait = true }
	end

	-- Insert mode
	vim.keymap.set("i", "<CR>", function() handle_cr_insert(eb) end, opts("Split paragraph / new list item"))
	vim.keymap.set("i", "<BS>", function() handle_bs_insert(eb) end, opts("Merge with previous / delete"))

	-- Normal mode structural
	vim.keymap.set("n", "J", function() handle_join(eb) end, opts("Join paragraphs"))
	vim.keymap.set("n", "<CR>", function() handle_cr_normal(eb) end, opts("Toggle checkbox"))
	vim.keymap.set("n", ">>", function() handle_indent(eb) end, opts("Indent list item"))
	vim.keymap.set("n", "<<", function() handle_outdent(eb) end, opts("Outdent list item"))

	-- Table cell navigation — uses ]c / [c to avoid conflicting with <Tab> buffer nav
	vim.keymap.set("n", "]c", function() handle_tab_table(eb, false) end, opts("Next table cell"))
	vim.keymap.set("n", "[c", function() handle_tab_table(eb, true) end, opts("Prev table cell"))

	-- Visual mode mark toggling (buffer-local, no conflict with global <leader>j)
	vim.keymap.set("v", "<leader>b", function() toggle_mark(eb, "strong") end, opts("Toggle bold"))
	vim.keymap.set("v", "<leader>i", function() toggle_mark(eb, "em") end, opts("Toggle italic"))
	vim.keymap.set("v", "<leader>c", function() toggle_mark(eb, "code") end, opts("Toggle code"))
	vim.keymap.set("v", "<leader>s", function() toggle_mark(eb, "strike") end, opts("Toggle strikethrough"))
	vim.keymap.set("v", "<leader>k", function()
		vim.ui.input({ prompt = "URL: " }, function(url)
			if not url or url == "" then return end
			toggle_mark(eb, "link", { href = url })
		end)
	end, opts("Toggle link"))

	-- Insert blocks (buffer-local)
	vim.keymap.set("n", "<leader>ih", function() prompt_insert_heading(eb) end, opts("Insert heading"))
	vim.keymap.set("n", "<leader>ic", function() prompt_insert_code_block(eb) end, opts("Insert code block"))
	vim.keymap.set("n", "<leader>it", function() prompt_insert_table(eb) end, opts("Insert table"))
	vim.keymap.set("n", "<leader>ip", function() insert_panel(eb) end, opts("Insert panel"))
	vim.keymap.set("n", "<leader>il", function() insert_bullet_list(eb) end, opts("Insert bullet list"))
end

return M
