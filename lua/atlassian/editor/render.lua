local extmarks = require("atlassian.editor.extmarks")

local M = {}

---@class RenderSpan
---@field line number 0-indexed buffer line
---@field col_start number 0-indexed byte column start
---@field col_end number 0-indexed byte column end (-1 = EOL)
---@field path number[] ADF node path
---@field field string "text" | "attrs.level" | etc.
---@field editable boolean

---@class RenderResult
---@field lines string[]
---@field marks table[] {line, col, opts} for nvim_buf_set_extmark
---@field spans RenderSpan[]
---@field line_to_node table<number, table>

---@class RenderContext
---@field lines string[]
---@field marks table[]
---@field spans RenderSpan[]
---@field line_to_node table<number, table>
---@field line number current 0-indexed line
---@field indent number nesting depth for lists

local function ctx_new()
	return {
		lines = {},
		marks = {},
		spans = {},
		line_to_node = {},
		image_refs = {},
		link_refs = {},
		line = 0,
		indent = 0,
	}
end

local function ctx_line(ctx)
	return ctx.line
end

local function ctx_append_line(ctx, text)
	text = text:gsub("\n", " ")
	table.insert(ctx.lines, text)
	ctx.line = ctx.line + 1
end

local function ctx_add_mark(ctx, line, col, opts)
	table.insert(ctx.marks, { line = line, col = col, opts = opts })
end

local function ctx_add_span(ctx, span)
	table.insert(ctx.spans, span)
end

local function ctx_map_line(ctx, line, node)
	ctx.line_to_node[line] = node
end

local function path_append(path, idx)
	local p = {}
	for _, v in ipairs(path) do
		p[#p + 1] = v
	end
	p[#p + 1] = idx
	return p
end

local function collect_inline_text(node)
	if node.type == "text" then
		local t = node.text or ""
		return t:gsub("\n", " ")
	end
	if node.type == "hardBreak" then
		return "\n"
	end
	if node.type == "mention" then
		local name = node.attrs and node.attrs.text or "user"
		if name:sub(1, 1) ~= "@" then
			name = "@" .. name
		end
		return name
	end
	local parts = {}
	for _, child in ipairs(node.content or {}) do
		parts[#parts + 1] = collect_inline_text(child)
	end
	return table.concat(parts)
end

---@param ctx RenderContext
---@param nodes table[] inline ADF nodes (text, mention, hardBreak)
---@param base_line number 0-indexed line to render on
---@param base_col number byte offset within that line
---@param path number[] parent path
local function render_inline(ctx, nodes, base_line, base_col, path)
	local col = base_col
	for i, node in ipairs(nodes) do
		local child_path = path_append(path, i)
		if node.type == "text" then
			local text = node.text or ""
			local text_len = #text
			ctx_add_span(ctx, {
				line = base_line,
				col_start = col,
				col_end = col + text_len,
				path = child_path,
				field = "text",
				editable = true,
			})
			if node.marks then
				for _, mark in ipairs(node.marks) do
					local hl = extmarks.mark_hl[mark.type]
					if hl then
						ctx_add_mark(ctx, base_line, col, {
							end_col = col + text_len,
							hl_group = hl,
						})
					end
					if mark.type == "link" and mark.attrs and mark.attrs.href then
						if not ctx.link_refs[base_line] then
							ctx.link_refs[base_line] = {}
						end
						table.insert(ctx.link_refs[base_line], {
							col_start = col,
							col_end = col + text_len,
							href = mark.attrs.href,
						})
					end
				end
			end
			col = col + text_len
		elseif node.type == "mention" then
			local name = node.attrs and node.attrs.text or "user"
			if name:sub(1, 1) ~= "@" then
				name = "@" .. name
			end
			local text_len = #name
			ctx_add_span(ctx, {
				line = base_line,
				col_start = col,
				col_end = col + text_len,
				path = child_path,
				field = "text",
				editable = false,
			})
			ctx_add_mark(ctx, base_line, col, {
				end_col = col + text_len,
				hl_group = "AtlasMention",
			})
			col = col + text_len
		elseif node.type == "hardBreak" then
			-- hardBreak inserts a newline — handled at paragraph level
		end
	end
end

local render_node -- forward declaration

local WRAP_WIDTH = 100

--- Word-wrap a string at word boundaries.
---@param text string
---@param width number
---@return string[] wrapped lines
---@return number[] break_offsets byte offset in original text where each line starts
local function word_wrap(text, width)
	if #text <= width then
		return { text }, { 0 }
	end

	local lines = {}
	local offsets = { 0 }
	local pos = 1
	local len = #text

	while pos <= len do
		if pos + width - 1 >= len then
			lines[#lines + 1] = text:sub(pos)
			break
		end

		-- Find last space within the width
		local chunk_end = pos + width - 1
		local break_at = nil
		for i = chunk_end, pos, -1 do
			if text:byte(i) == 32 then -- space
				break_at = i
				break
			end
		end

		if break_at then
			lines[#lines + 1] = text:sub(pos, break_at - 1)
			pos = break_at + 1 -- skip the space
		else
			-- No space found — break at width (hard break)
			lines[#lines + 1] = text:sub(pos, chunk_end)
			pos = chunk_end + 1
		end
		offsets[#offsets + 1] = pos - 1
	end

	return lines, offsets
end

--- Place inline spans and marks across wrapped lines.
--- `flat_offset` is each node's start offset in the unwrapped text.
---@param ctx RenderContext
---@param nodes table[] inline ADF nodes
---@param first_line number 0-indexed first buffer line
---@param break_offsets number[] byte offsets where each wrapped line starts
---@param wrapped_lines string[] the wrapped line texts
---@param path number[] parent path
local function render_inline_wrapped(ctx, nodes, first_line, break_offsets, wrapped_lines, path)
	-- Build a flat list of {offset, len, node_index, node} for text/mention nodes
	local segments = {}
	local offset = 0
	for i, node in ipairs(nodes) do
		if node.type == "text" then
			local t = (node.text or ""):gsub("\n", " ")
			segments[#segments + 1] = { offset = offset, len = #t, idx = i, node = node }
			offset = offset + #t
		elseif node.type == "mention" then
			local name = node.attrs and node.attrs.text or "user"
			if name:sub(1, 1) ~= "@" then name = "@" .. name end
			segments[#segments + 1] = { offset = offset, len = #name, idx = i, node = node, is_mention = true }
			offset = offset + #name
		end
	end

	-- For each segment, find which wrapped line(s) it falls on
	for _, seg in ipairs(segments) do
		local seg_start = seg.offset
		local seg_end = seg.offset + seg.len

		for li = 1, #wrapped_lines do
			local line_start = break_offsets[li]
			local line_end = line_start + #wrapped_lines[li]
			local buf_line = first_line + li - 1

			-- Intersect segment with this line
			local vis_start = math.max(seg_start, line_start)
			local vis_end = math.min(seg_end, line_end)

			if vis_start < vis_end then
				local col_start = vis_start - line_start
				local col_end = vis_end - line_start
				local child_path = path_append(path, seg.idx)

				ctx_add_span(ctx, {
					line = buf_line,
					col_start = col_start,
					col_end = col_end,
					path = child_path,
					field = "text",
					editable = not seg.is_mention,
				})

				if seg.is_mention then
					ctx_add_mark(ctx, buf_line, col_start, {
						end_col = col_end,
						hl_group = "AtlasMention",
					})
				elseif seg.node.marks then
					for _, mark in ipairs(seg.node.marks) do
						local hl = extmarks.mark_hl[mark.type]
						if hl then
							ctx_add_mark(ctx, buf_line, col_start, {
								end_col = col_end,
								hl_group = hl,
							})
						end
						if mark.type == "link" and mark.attrs and mark.attrs.href then
							if not ctx.link_refs[buf_line] then
								ctx.link_refs[buf_line] = {}
							end
							table.insert(ctx.link_refs[buf_line], {
								col_start = col_start,
								col_end = col_end,
								href = mark.attrs.href,
							})
						end
					end
				end
			end
		end
	end
end

---@param ctx RenderContext
---@param node table ADF paragraph node
---@param path number[]
local function render_paragraph(ctx, node, path)
	local text_parts = {}
	for _, child in ipairs(node.content or {}) do
		text_parts[#text_parts + 1] = collect_inline_text(child)
	end
	local full_text = table.concat(text_parts)

	-- Split on hardBreak newlines first
	local sub_lines = vim.split(full_text, "\n", { plain = true })

	for _, sub_line in ipairs(sub_lines) do
		-- Word-wrap each sub_line
		local wrapped, break_offsets = word_wrap(sub_line, WRAP_WIDTH)
		local first_line = ctx_line(ctx)

		for _, wl in ipairs(wrapped) do
			local line = ctx_line(ctx)
			ctx_map_line(ctx, line, node)
			ctx_append_line(ctx, wl)
		end

		-- Place spans and marks across wrapped lines
		render_inline_wrapped(ctx, node.content or {}, first_line, break_offsets, wrapped, path)
	end
end

---@param ctx RenderContext
---@param node table ADF heading node
---@param path number[]
local function render_heading(ctx, node, path)
	local level = (node.attrs and node.attrs.level) or 1
	level = math.min(level, 6)

	local text_parts = {}
	for _, child in ipairs(node.content or {}) do
		text_parts[#text_parts + 1] = collect_inline_text(child)
	end
	local full_text = table.concat(text_parts)

	local line = ctx_line(ctx)
	ctx_map_line(ctx, line, node)
	ctx_append_line(ctx, full_text)

	-- Heading highlight across entire line
	local hl = extmarks.heading_hls[level] or extmarks.heading_hls[1]
	ctx_add_mark(ctx, line, 0, {
		end_col = #full_text,
		hl_group = hl,
	})

	-- Sign with heading icon
	local icon = extmarks.heading_icons[level] or extmarks.heading_icons[1]
	ctx_add_mark(ctx, line, 0, {
		sign_text = icon .. " ",
		sign_hl_group = hl,
	})

	-- Inline marks
	render_inline(ctx, node.content or {}, line, 0, path)
end

---@param ctx RenderContext
---@param node table ADF bulletList or orderedList node
---@param path number[]
local function render_list(ctx, node, path)
	local is_ordered = node.type == "orderedList"
	local items = node.content or {}

	for i, item in ipairs(items) do
		if item.type == "listItem" then
			local item_path = path_append(path, i)
			local indent_str = string.rep("  ", ctx.indent)

			-- Render each child of the list item
			for ci, child in ipairs(item.content or {}) do
				local child_path = path_append(item_path, ci)

				if child.type == "paragraph" then
					local text_parts = {}
					for _, inline in ipairs(child.content or {}) do
						text_parts[#text_parts + 1] = collect_inline_text(inline)
					end
					local full_text = indent_str .. table.concat(text_parts)

					local line = ctx_line(ctx)
					ctx_map_line(ctx, line, child)
					ctx_append_line(ctx, full_text)

					-- Bullet/number as inline virtual text
					local prefix
					local prefix_hl
					if is_ordered then
						prefix = i .. ". "
						prefix_hl = "AtlasOrderedNumber"
					else
						prefix = extmarks.bullet_icon .. " "
						prefix_hl = "AtlasBullet"
					end
					ctx_add_mark(ctx, line, 0, {
						virt_text = { { prefix, prefix_hl } },
						virt_text_pos = "inline",
					})

					-- Inline marks (offset by indent)
					render_inline(ctx, child.content or {}, line, #indent_str, child_path)
				elseif child.type == "bulletList" or child.type == "orderedList" then
					ctx.indent = ctx.indent + 1
					render_list(ctx, child, child_path)
					ctx.indent = ctx.indent - 1
				else
					render_node(ctx, child, child_path)
				end
			end
		end
	end
end

---@param ctx RenderContext
---@param node table ADF taskList node
---@param path number[]
local function render_task_list(ctx, node, path)
	local items = node.content or {}

	for i, item in ipairs(items) do
		if item.type == "taskItem" then
			local item_path = path_append(path, i)
			local is_done = item.attrs and item.attrs.state == "DONE"

			for ci, child in ipairs(item.content or {}) do
				local child_path = path_append(item_path, ci)

				if child.type == "paragraph" then
					local text_parts = {}
					for _, inline in ipairs(child.content or {}) do
						text_parts[#text_parts + 1] = collect_inline_text(inline)
					end
					local full_text = table.concat(text_parts)

					local line = ctx_line(ctx)
					ctx_map_line(ctx, line, item)
					ctx_append_line(ctx, full_text)

					local checkbox = is_done and extmarks.checkbox_done or extmarks.checkbox_todo
					local checkbox_hl = is_done and "AtlasTaskDone" or "AtlasTaskTodo"
					ctx_add_mark(ctx, line, 0, {
						virt_text = { { checkbox .. " ", checkbox_hl } },
						virt_text_pos = "inline",
					})

					if is_done then
						ctx_add_mark(ctx, line, 0, {
							end_col = #full_text,
							hl_group = "AtlasTaskDone",
						})
					end

					render_inline(ctx, child.content or {}, line, 0, child_path)
				else
					render_node(ctx, child, child_path)
				end
			end
		end
	end
end

---@param ctx RenderContext
---@param node table ADF codeBlock node
---@param path number[]
local function render_code_block(ctx, node, path)
	local lang = (node.attrs and node.attrs.language) or ""

	local text_parts = {}
	for _, child in ipairs(node.content or {}) do
		if child.type == "text" then
			text_parts[#text_parts + 1] = child.text or ""
		end
	end
	local code = table.concat(text_parts)
	local code_lines = vim.split(code, "\n", { plain = true })

	-- Top border with language label
	local border_width = 40
	local top_border = "╭" .. string.rep("─", border_width) .. "╮"
	local bot_border = "╰" .. string.rep("─", border_width) .. "╯"

	local first_line = ctx_line(ctx)

	-- Top border as virtual line above first code line
	ctx_add_mark(ctx, first_line, 0, {
		virt_lines_above = true,
		virt_lines = { {
			{ top_border, "AtlasCodeBlockBorder" },
			lang ~= "" and { " " .. lang, "AtlasCodeBlockLang" } or nil,
		} },
	})

	for li, cl in ipairs(code_lines) do
		local line = ctx_line(ctx)
		ctx_map_line(ctx, line, node)
		ctx_append_line(ctx, cl)

		ctx_add_span(ctx, {
			line = line,
			col_start = 0,
			col_end = #cl,
			path = path_append(path, 1),
			field = "text",
			editable = true,
		})

		ctx_add_mark(ctx, line, 0, {
			end_col = #cl,
			hl_group = "AtlasCodeBlock",
		})

		-- Left bar
		ctx_add_mark(ctx, line, 0, {
			virt_text = { { "│ ", "AtlasCodeBlockBorder" } },
			virt_text_pos = "inline",
		})

		-- Bottom border after last line
		if li == #code_lines then
			ctx_add_mark(ctx, line, 0, {
				virt_lines = { { { bot_border, "AtlasCodeBlockBorder" } } },
			})
		end
	end

	-- Blank line after code block
	ctx_append_line(ctx, "")
end

---@param ctx RenderContext
---@param node table ADF blockquote node
---@param path number[]
local function render_blockquote(ctx, node, path)
	local children = node.content or {}
	for i, child in ipairs(children) do
		local child_path = path_append(path, i)
		if child.type == "paragraph" then
			local text_parts = {}
			for _, inline in ipairs(child.content or {}) do
				text_parts[#text_parts + 1] = collect_inline_text(inline)
			end
			local full_text = table.concat(text_parts)

			local wrapped, break_offsets = word_wrap(full_text, WRAP_WIDTH)
			local first_line = ctx_line(ctx)

			for _, wl in ipairs(wrapped) do
				local line = ctx_line(ctx)
				ctx_map_line(ctx, line, child)
				ctx_append_line(ctx, wl)

				ctx_add_mark(ctx, line, 0, {
					virt_text = { { extmarks.blockquote_bar .. " ", "AtlasBlockquoteBar" } },
					virt_text_pos = "inline",
				})
				ctx_add_mark(ctx, line, 0, {
					end_col = #wl,
					hl_group = "AtlasBlockquote",
				})
			end

			render_inline_wrapped(ctx, child.content or {}, first_line, break_offsets, wrapped, path)
		else
			render_node(ctx, child, child_path)
		end
	end
end

---@param ctx RenderContext
---@param node table ADF rule node
---@param path number[]
local function render_rule(ctx, node, path)
	local line = ctx_line(ctx)
	ctx_map_line(ctx, line, node)
	ctx_append_line(ctx, "")

	local rule_text = string.rep(extmarks.hr_char, 40)
	ctx_add_mark(ctx, line, 0, {
		virt_text = { { rule_text, "AtlasRule" } },
		virt_text_pos = "overlay",
	})
end

---@param ctx RenderContext
---@param node table ADF panel node
---@param path number[]
local function render_panel(ctx, node, path)
	local panel_type = (node.attrs and node.attrs.panelType) or "info"
	local icon = extmarks.panel_icons[panel_type] or extmarks.panel_icons.info
	local hl = extmarks.panel_hls[panel_type] or extmarks.panel_hls.info

	local children = node.content or {}
	for i, child in ipairs(children) do
		local child_path = path_append(path, i)

		if child.type == "paragraph" then
			local text_parts = {}
			for _, inline in ipairs(child.content or {}) do
				text_parts[#text_parts + 1] = collect_inline_text(inline)
			end
			local full_text = table.concat(text_parts)

			local wrapped, break_offsets = word_wrap(full_text, WRAP_WIDTH)
			local first_line = ctx_line(ctx)

			for wi, wl in ipairs(wrapped) do
				local line = ctx_line(ctx)
				ctx_map_line(ctx, line, child)
				ctx_append_line(ctx, wl)

				-- Panel icon on first line of first paragraph
				if i == 1 and wi == 1 then
					ctx_add_mark(ctx, line, 0, {
						sign_text = icon .. " ",
						sign_hl_group = hl,
					})
				end

				ctx_add_mark(ctx, line, 0, {
					virt_text = { { extmarks.blockquote_bar .. " ", hl } },
					virt_text_pos = "inline",
				})
			end

			render_inline_wrapped(ctx, child.content or {}, first_line, break_offsets, wrapped, path)
		else
			render_node(ctx, child, child_path)
		end
	end
end

---@param ctx RenderContext
---@param node table ADF table node
---@param path number[]
local function render_table(ctx, node, path)
	local rows = node.content or {}
	if #rows == 0 then
		return
	end

	-- First pass: compute column widths and collect cell texts
	local grid = {} -- grid[row][col] = { text, is_header, path, dw }
	local col_widths = {} -- display widths

	for ri, row in ipairs(rows) do
		grid[ri] = {}
		local cells = row.content or {}
		for ci, cell in ipairs(cells) do
			local text_parts = {}
			for _, block in ipairs(cell.content or {}) do
				for _, inline in ipairs(block.content or {}) do
					text_parts[#text_parts + 1] = collect_inline_text(inline)
				end
			end
			local cell_text = table.concat(text_parts)
			local is_header = cell.type == "tableHeader"
			local dw = vim.fn.strdisplaywidth(cell_text)

			grid[ri][ci] = {
				text = cell_text,
				is_header = is_header,
				cell_node = cell,
				cell_path = path_append(path_append(path, ri), ci),
				dw = dw,
			}
			col_widths[ci] = math.max(col_widths[ci] or 0, dw)
		end
	end

	local num_cols = #col_widths
	for i = 1, num_cols do
		col_widths[i] = math.max(col_widths[i], 3) -- minimum 3 display chars
	end

	-- Build border to mirror data row exactly:
	-- Data: " cell1 " .. " │ " .. " cell2 "
	-- Border: "─cell1─" .. "─┼─" .. "─cell2─"  (same display widths)
	local function make_border(mid)
		local segments = {}
		for ci = 1, num_cols do
			segments[#segments + 1] = string.rep("─", col_widths[ci] + 2)
		end
		return table.concat(segments, "─" .. mid .. "─")
	end

	local top_border = make_border("┬")
	local mid_border = make_border("┼")
	local bot_border = make_border("┴")

	-- Render rows
	for ri, row_data in ipairs(grid) do
		-- Top border or mid border as real buffer line
		local border
		if ri == 1 then
			border = top_border
		else
			local prev_has_header = grid[ri - 1][1] and grid[ri - 1][1].is_header
			local cur_has_header = row_data[1] and row_data[1].is_header
			if prev_has_header and not cur_has_header then
				border = mid_border
			end
		end

		if border then
			local bline = ctx_line(ctx)
			ctx_append_line(ctx, border)
			ctx_add_mark(ctx, bline, 0, {
				end_col = #border,
				hl_group = "AtlasTableBorder",
			})
		end

		local line = ctx_line(ctx)

		-- Build row text: " cell1 │ cell2 │ cell3 "
		-- Pad uses display width; byte offsets tracked separately for extmarks
		local parts = {}
		local byte_offsets = {} -- byte_offsets[ci] = { part_start, text_start, text_end }
		local byte_pos = 0
		local del_str = " │ "
		local del_byte_len = #del_str

		for ci, cell_data in ipairs(row_data) do
			local pad_count = col_widths[ci] - cell_data.dw
			local padded = cell_data.text .. string.rep(" ", pad_count)
			local part = " " .. padded .. " "
			parts[#parts + 1] = part

			local text_start = byte_pos + 1 -- after leading space
			local text_end = text_start + #cell_data.text

			byte_offsets[ci] = { part_start = byte_pos, text_start = text_start, text_end = text_end }

			ctx_add_span(ctx, {
				line = line,
				col_start = text_start,
				col_end = text_end,
				path = cell_data.cell_path,
				field = "text",
				editable = true,
			})

			if cell_data.is_header then
				ctx_add_mark(ctx, line, text_start, {
					end_col = text_end,
					hl_group = "AtlasTableHeader",
				})
			end

			byte_pos = byte_pos + #part
			if ci < num_cols then
				byte_pos = byte_pos + del_byte_len
			end
		end

		local row_text = table.concat(parts, del_str)
		ctx_map_line(ctx, line, rows[ri])
		ctx_append_line(ctx, row_text)

		-- Highlight delimiters
		local del_pos = 0
		for ci = 1, num_cols - 1 do
			del_pos = del_pos + #parts[ci]
			ctx_add_mark(ctx, line, del_pos, {
				end_col = del_pos + del_byte_len,
				hl_group = "AtlasTableDelimiter",
			})
			del_pos = del_pos + del_byte_len
		end

		-- Bottom border after last row
		if ri == #grid then
			local bline = ctx_line(ctx)
			ctx_append_line(ctx, bot_border)
			ctx_add_mark(ctx, bline, 0, {
				end_col = #bot_border,
				hl_group = "AtlasTableBorder",
			})
		end
	end

	-- Blank line after table
	ctx_append_line(ctx, "")
end

---@param ctx RenderContext
---@param node table ADF mediaSingle node
---@param path number[]
local function render_media(ctx, node, path)
	local media = nil
	for _, child in ipairs(node.content or {}) do
		if child.type == "media" then
			media = child
			break
		end
	end

	local label
	local ref = {}
	if media and media.attrs then
		local attrs = media.attrs
		if attrs.type == "external" and attrs.url then
			label = attrs.alt or attrs.url
			ref.url = attrs.url
		elseif attrs.id then
			label = attrs.alt or attrs.id
			ref.id = attrs.id
			ref.filename = attrs.alt
		else
			label = attrs.alt or attrs.url or attrs.id or "image"
			ref.url = attrs.url
			ref.filename = attrs.alt
			ref.id = attrs.id
		end
	else
		label = "media"
	end

	local line = ctx_line(ctx)
	local text = "[image: " .. label .. "]"
	ctx_map_line(ctx, line, node)
	ctx_append_line(ctx, text)
	ctx_add_mark(ctx, line, 0, {
		end_col = #text,
		hl_group = "AtlasMediaPlaceholder",
	})

	ctx.image_refs[line] = ref
end

---@param ctx RenderContext
---@param node table Any ADF node
---@param path number[]
render_node = function(ctx, node, path)
	if not node or not node.type then
		return
	end

	if node.type == "paragraph" then
		render_paragraph(ctx, node, path)
	elseif node.type == "heading" then
		render_heading(ctx, node, path)
	elseif node.type == "bulletList" or node.type == "orderedList" then
		render_list(ctx, node, path)
	elseif node.type == "taskList" then
		render_task_list(ctx, node, path)
	elseif node.type == "codeBlock" then
		render_code_block(ctx, node, path)
	elseif node.type == "blockquote" then
		render_blockquote(ctx, node, path)
	elseif node.type == "rule" then
		render_rule(ctx, node, path)
	elseif node.type == "panel" then
		render_panel(ctx, node, path)
	elseif node.type == "table" then
		render_table(ctx, node, path)
	elseif node.type == "mediaSingle" then
		render_media(ctx, node, path)
	elseif node.type == "bodiedExtension" or node.type == "extension" then
		-- Fallback: render children if any
		for i, child in ipairs(node.content or {}) do
			render_node(ctx, child, path_append(path, i))
		end
	end
end

---@param adf table ADF document ({ type = "doc", content = {...} })
---@return RenderResult
function M.render(adf)
	local ctx = ctx_new()

	if not adf or not adf.content then
		return {
			lines = { "" },
			marks = {},
			spans = {},
			line_to_node = {},
		}
	end

	local structural = {
		heading = true, codeBlock = true, table = true,
		bulletList = true, orderedList = true, taskList = true,
		panel = true, blockquote = true, mediaSingle = true,
	}

	for i, node in ipairs(adf.content) do
		render_node(ctx, node, { i })

		if i < #adf.content then
			local next_node = adf.content[i + 1]
			-- rule → heading: no blank line (separator + section title stay tight)
			if node.type == "rule" and next_node.type == "heading" then
				-- no spacing
			-- after heading: always blank line (breathing room before content)
			elseif node.type == "heading" then
				ctx_append_line(ctx, "")
			-- before/after structural blocks: blank line
			elseif structural[node.type] or structural[next_node.type] then
				ctx_append_line(ctx, "")
			-- consecutive paragraphs: no blank line
			end
		end
	end

	-- Remove trailing empty lines
	while #ctx.lines > 1 and ctx.lines[#ctx.lines] == "" do
		ctx.lines[#ctx.lines] = nil
	end

	return {
		lines = ctx.lines,
		marks = ctx.marks,
		spans = ctx.spans,
		line_to_node = ctx.line_to_node,
		image_refs = ctx.image_refs,
		link_refs = ctx.link_refs,
	}
end

---@param buf number
---@param result RenderResult
function M.apply(buf, result)
	local ns = extmarks.ns

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false

	local line_count = #result.lines
	for _, mark in ipairs(result.marks) do
		local line = mark.line
		if line < line_count then
			local line_len = #result.lines[line + 1]
			local col = math.min(mark.col, line_len)
			local opts = mark.opts
			if opts.end_col then
				opts = vim.tbl_extend("force", opts, { end_col = math.min(opts.end_col, line_len) })
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, col, opts)
		end
	end
end

---@param result RenderResult
---@return table<number, RenderSpan[]>
function M.build_line_to_spans(result)
	local map = {}
	for _, span in ipairs(result.spans) do
		if not map[span.line] then
			map[span.line] = {}
		end
		table.insert(map[span.line], span)
	end
	return map
end

---@param result RenderResult
---@return table<string, number[]>
function M.build_path_to_lines(result)
	local map = {}
	for _, span in ipairs(result.spans) do
		local key = table.concat(span.path, ".")
		if not map[key] then
			map[key] = {}
		end
		table.insert(map[key], span.line)
	end
	return map
end

return M
