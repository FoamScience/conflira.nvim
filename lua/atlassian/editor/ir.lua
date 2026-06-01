-- Projection IR — the editor-agnostic contract between the (pure) renderer and
-- the editor-specific applier.
--
-- `render.build_ir(adf)` produces a ProjectionIR: plain data, no editor calls.
-- `render.apply_ir(buf, ir)` renders it to Neovim extmarks via to_extmark(). A
-- future VSCode or Sublime client translates the same IR to its own decoration
-- API instead.
--
-- ProjectionIR = {
--   lines        : string[]                  -- the clean buffer text
--   marks        : IRMark[]                  -- neutral decoration descriptors
--   spans        : RenderSpan[]              -- ADF path ↔ text-range map
--   line_to_node : table<number, table>      -- line → ADF node (editor-side)
--   image_refs?, link_refs? : table          -- interaction metadata (editor-side)
-- }
--
-- IRMark is a NEUTRAL descriptor — it no longer carries raw extmark opts:
--   { line, col, kind = IRDecorationKind, ...fields }
--     highlight    : { end_col, hl }
--     inline_text  : { chunks = {{text, hl?}, ...}, pos }
--     eol_text     : { chunks, align = "right_align"|"eol" }
--     sign         : { text, hl }
--     virt_lines   : { lines = {{{text, hl?}, ...}, ...}, above }
-- `hl` is a semantic style *token* (e.g. "heading.2", "strong", "diff.add"),
-- not a Neovim highlight group — see atlassian.editor.theme. Each applier maps
-- tokens to its own theme; the Neovim applier resolves them back to highlight
-- groups. `chunks`/`lines` use {text, styleToken} tuples.
--
-- The build is now editor-agnostic data end to end; the only Neovim runtime
-- dependency is display width (see atlassian.width), routed through a swappable
-- module so a non-Neovim host can provide its own.
local theme = require("atlassian.editor.theme")

local M = {}

-- Map the style token in every {text, style} chunk via `fn`, returning new chunks.
---@param chunks table[]|nil
---@param fn fun(style: string|nil): string|nil
---@return table[]|nil
local function map_chunk_styles(chunks, fn)
	if not chunks then return nil end
	local out = {}
	for i, c in ipairs(chunks) do
		out[i] = { c[1], fn(c[2]) }
	end
	return out
end

-- Map the style token in every chunk of every virtual line via `fn`.
---@param vlines table[]|nil
---@param fn fun(style: string|nil): string|nil
---@return table[]|nil
local function map_vline_styles(vlines, fn)
	if not vlines then return nil end
	local out = {}
	for i, line in ipairs(vlines) do
		out[i] = map_chunk_styles(line, fn)
	end
	return out
end

---@alias IRDecorationKind
---| "highlight"    # colored text range over [col, end_col)
---| "inline_text"  # virtual text inserted inline, shifting real text
---| "eol_text"     # virtual text at end of line / right-aligned
---| "virt_lines"   # whole virtual lines above/below (borders, tables)
---| "sign"         # sign-column glyph
---| "unknown"

--- Convert a Neovim-dialect mark ({line, col, opts}) to a neutral descriptor.
--- Called once at the build boundary so the IR a consumer sees is editor-neutral.
---@param mark table { line, col, opts }
---@return table neutral descriptor { line, col, kind, ... }
function M.to_neutral(mark)
	local o = mark.opts or {}
	local d = { line = mark.line, col = mark.col }
	if o.virt_lines then
		d.kind = "virt_lines"
		d.lines = map_vline_styles(o.virt_lines, theme.to_token)
		d.above = o.virt_lines_above or false
	elseif o.sign_text then
		d.kind = "sign"
		d.text = o.sign_text
		d.hl = theme.to_token(o.sign_hl_group)
	elseif o.virt_text then
		local pos = o.virt_text_pos
		if pos == "right_align" or pos == "eol" then
			d.kind = "eol_text"
			d.chunks = map_chunk_styles(o.virt_text, theme.to_token)
			d.align = pos
		else
			d.kind = "inline_text"
			d.chunks = map_chunk_styles(o.virt_text, theme.to_token)
			d.pos = pos or "inline"
		end
	elseif o.hl_group then
		d.kind = "highlight"
		d.hl = theme.to_token(o.hl_group)
		d.end_col = o.end_col
	else
		d.kind = "unknown"
		d.opts = o
	end
	return d
end

--- Convert a neutral descriptor back to the Neovim extmark form ({line,col,opts}).
--- This is the Neovim applier's translation step; other editors write their own.
---@param d table neutral descriptor
---@return table { line, col, opts }
function M.to_extmark(d)
	local opts
	local k = d.kind
	if k == "virt_lines" then
		opts = { virt_lines = map_vline_styles(d.lines, theme.to_nvim), virt_lines_above = d.above or nil }
	elseif k == "sign" then
		opts = { sign_text = d.text, sign_hl_group = theme.to_nvim(d.hl) }
	elseif k == "inline_text" then
		opts = { virt_text = map_chunk_styles(d.chunks, theme.to_nvim), virt_text_pos = d.pos or "inline" }
	elseif k == "eol_text" then
		opts = { virt_text = map_chunk_styles(d.chunks, theme.to_nvim), virt_text_pos = d.align }
	elseif k == "highlight" then
		opts = { hl_group = theme.to_nvim(d.hl), end_col = d.end_col }
	else
		opts = d.opts or {}
	end
	return { line = d.line, col = d.col, opts = opts }
end

--- Neutralize every mark in an IR result in place, returning the result.
---@param result table ProjectionIR with dialect marks
---@return table result with neutral marks
function M.neutralize(result)
	local marks = result.marks or {}
	for i = 1, #marks do
		marks[i] = M.to_neutral(marks[i])
	end
	return result
end

--- The portable, wire-serializable subset of an IR. Drops editor-side
--- interaction metadata (line_to_node, image_refs, link_refs) that references
--- live ADF nodes; keeps lines + neutral marks + spans (path ↔ range mapping).
---@param result table ProjectionIR (neutral marks)
---@return table { lines, marks, spans }
function M.to_wire(result)
	return {
		lines = result.lines or {},
		marks = result.marks or {},
		spans = result.spans or {},
	}
end

--- Encode an IR to a JSON string (the cross-process contract). The producer may
--- be this Lua build or a future Go core; either side decodes the same shape.
---@param result table ProjectionIR
---@return string
function M.encode(result)
	return vim.json.encode(M.to_wire(result))
end

--- Decode a wire IR from JSON.
---@param str string
---@return table { lines, marks, spans }
function M.decode(str)
	return vim.json.decode(str)
end

--- Describe a mark for tests/inspection. Accepts a neutral descriptor (returns
--- it as-is shape) or a legacy dialect mark (classifies it).
---@param mark table
---@return { kind: IRDecorationKind, [string]: any }
function M.classify(mark)
	if mark.kind then
		return {
			kind = mark.kind,
			hl = mark.hl,
			text = mark.text,
			end_col = mark.end_col,
			align = mark.align,
			pos = mark.pos,
			count = mark.lines and #mark.lines or nil,
		}
	end
	return M.to_neutral(mark)
end

return M
