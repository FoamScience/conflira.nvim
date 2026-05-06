local render = require("atlassian.editor.render")
local extmarks_mod = require("atlassian.editor.extmarks")
local sync = require("atlassian.editor.sync")
local draft = require("atlassian.editor.draft")
local keymap = require("atlassian.editor.keymap")
local md_input = require("atlassian.editor.markdown_input")

local M = {}

---@class EditorBuffer
---@field buf number
---@field win number
---@field ns number
---@field adf table
---@field adf_snapshot table
---@field render_result table
---@field line_to_spans table
---@field path_to_lines table
---@field metadata table
---@field dirty boolean
---@field suppress_sync boolean

---@type table<number, EditorBuffer>
M.buffers = {}

local setup_done = false

local function ensure_setup()
	if setup_done then
		return
	end
	extmarks_mod.setup()
	setup_done = true
end

---@param adf table ADF document
---@param metadata table { type = "jira"|"confluence", key = string, ... }
---@param opts? { buf?: number, win?: number, modifiable?: boolean }
---@return EditorBuffer
function M.open(adf, metadata, opts)
	ensure_setup()
	opts = opts or {}

	local buf = opts.buf
	local win = opts.win or vim.api.nvim_get_current_win()

	if not buf then
		buf = vim.api.nvim_create_buf(true, true)
	end

	local eb = {
		buf = buf,
		win = win,
		ns = extmarks_mod.ns,
		adf = adf,
		adf_snapshot = vim.deepcopy(adf),
		render_result = nil,
		line_to_spans = {},
		path_to_lines = {},
		metadata = metadata or {},
		dirty = false,
		suppress_sync = false,
	}

	-- Render ADF into buffer
	local result = render.render(adf)
	eb.render_result = result
	eb.line_to_spans = render.build_line_to_spans(result)
	eb.path_to_lines = render.build_path_to_lines(result)

	render.apply(buf, result)

	-- Buffer options
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "atlassian"

	-- Window options (only set what the editor engine needs; leave user prefs alone)
	if vim.api.nvim_win_is_valid(win) then
		vim.wo[win].wrap = false
		vim.wo[win].conceallevel = 0
		vim.wo[win].signcolumn = "yes:1"
	end

	if opts.modifiable then
		-- Editable mode: attach sync + draft tracking
		vim.bo[buf].modifiable = true
		vim.bo[buf].buftype = "acwrite"
		sync.attach(eb)
		draft.attach(eb)
	else
		vim.bo[buf].modifiable = false
	end

	M.buffers[buf] = eb

	-- Image hover support
	if result.image_refs and next(result.image_refs) then
		M.setup_image_hover(buf, eb)
	end

	-- Cleanup on buffer wipe
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			M.buffers[buf] = nil
		end,
	})

	return eb
end

---@param buf number
function M.close(buf)
	local eb = M.buffers[buf]
	if not eb then
		return
	end
	M.buffers[buf] = nil
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

---@param buf number
---@return EditorBuffer|nil
function M.get(buf)
	return M.buffers[buf]
end

---@param buf number
function M.refresh(buf)
	local eb = M.buffers[buf]
	if not eb then
		return
	end

	local result = render.render(eb.adf)
	eb.render_result = result
	eb.line_to_spans = render.build_line_to_spans(result)
	eb.path_to_lines = render.build_path_to_lines(result)

	eb.suppress_sync = true
	vim.bo[buf].modifiable = true
	render.apply(buf, result)
	eb.suppress_sync = false
end

---@param buf number
---@param eb EditorBuffer
function M.setup_image_hover(buf, eb)
	local image = require("atlassian.csf.image")
	local group = vim.api.nvim_create_augroup("atlas_editor_image_" .. buf, { clear = true })

	local function get_image_ref_at_cursor()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
		if not eb.render_result or not eb.render_result.image_refs then
			return nil, row
		end
		return eb.render_result.image_refs[row], row
	end

	local function fetch_and_show(ref, row)
		local meta = eb.metadata
		if ref.url then
			image.fetch_url(ref.url, function(err, path)
				if err or not path then return end
				if not vim.api.nvim_buf_is_valid(buf) then return end
				local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
				if cur_row == row then
					image.show_hover(path, buf)
				end
			end)
		elseif ref.filename or ref.id then
			local id_or_name = ref.filename or ref.id
			if meta.type == "jira" then
				image.fetch_jira_attachment(buf, id_or_name, function(err, path)
					if err or not path then return end
					if not vim.api.nvim_buf_is_valid(buf) then return end
					local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
					if cur_row == row then
						image.show_hover(path, buf)
					end
				end)
			elseif meta.type == "confluence" and meta.id then
				image.fetch_confluence_attachment(meta.id, id_or_name, function(err, path)
					if err or not path then return end
					if not vim.api.nvim_buf_is_valid(buf) then return end
					local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
					if cur_row == row then
						image.show_hover(path, buf)
					end
				end)
			end
		end
	end

	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		buffer = buf,
		callback = function()
			if vim.fn.mode() ~= "n" then return end
			local ref, row = get_image_ref_at_cursor()
			if not ref then
				image.hover_close()
				return
			end
			fetch_and_show(ref, row)
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			local ref = get_image_ref_at_cursor()
			if not ref then
				image.hover_close()
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		buffer = buf,
		callback = function()
			image.hover_close()
		end,
	})

	vim.keymap.set("n", "K", function()
		local ref, row = get_image_ref_at_cursor()
		if not ref then
			vim.notify("No image at cursor", vim.log.levels.INFO)
			return
		end
		vim.notify("Fetching image...", vim.log.levels.INFO)
		fetch_and_show(ref, row)
	end, { buffer = buf, desc = "Show image at cursor" })
end

---@param adf table ADF node path
---@param path number[]
---@return table|nil node
---@return table|nil parent
---@return number|nil index
function M.resolve_path(adf, path)
	local node = adf
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

return M
