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
		-- Editable mode: attach sync + draft + keymaps
		vim.bo[buf].modifiable = true
		vim.bo[buf].buftype = "acwrite"
		sync.attach(eb)
		draft.attach(eb)
		keymap.attach(eb)
		md_input.attach(eb)
	else
		vim.bo[buf].modifiable = false
	end

	M.buffers[buf] = eb

	local function open_link_at_cursor()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local refs = eb.render_result and eb.render_result.link_refs and eb.render_result.link_refs[row]
		if refs then
			local best, best_dist
			for _, ref in ipairs(refs) do
				local dist = 0
				if col < ref.col_start then
					dist = ref.col_start - col
				elseif col >= ref.col_end then
					dist = col - ref.col_end + 1
				end
				if not best_dist or dist < best_dist then
					best = ref
					best_dist = dist
				end
			end
			if best then
				vim.ui.open(best.href)
				return
			end
		end
		local img_ref = eb.render_result and eb.render_result.image_refs and eb.render_result.image_refs[row]
		if img_ref and img_ref.url then
			vim.ui.open(img_ref.url)
			return
		end
		vim.notify("No link at cursor", vim.log.levels.INFO)
	end

	-- Prevent K from triggering :Man
	vim.bo[buf].keywordprg = ""

	-- gx / gf: open link at cursor
	vim.keymap.set("n", "gx", open_link_at_cursor, { buffer = buf, desc = "Open link at cursor" })
	vim.keymap.set("n", "gf", open_link_at_cursor, { buffer = buf, desc = "Open link at cursor" })

	-- Image hover + PDF preview support
	M.setup_image_hover(buf, eb)
	M.setup_preview_keymap(buf, eb)

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

--- Resolve the auth config for a buffer's backend (jira/confluence).
---@param meta table
---@return table|nil
local function get_auth_for(meta)
	if meta.type == "jira" then
		local ok, jc = pcall(require, "jira-interface.config")
		if ok then return jc.options.auth end
	elseif meta.type == "confluence" then
		local ok, cc = pcall(require, "confluence-interface.config")
		if ok then return cc.options.auth end
	end
	return nil
end

---@param buf number
---@param eb EditorBuffer
function M.setup_image_hover(buf, eb)
	local image = require("atlassian.image")
	local group = vim.api.nvim_create_augroup("atlas_editor_image_" .. buf, { clear = true })

	-- Image attachments rendered as links (e.g. the Attachments section) are not
	-- `media` nodes, so they have no image_ref. Detect image-filename links so they
	-- can be previewed like embedded images.
	local function get_image_link_at_cursor()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		local refs = eb.render_result and eb.render_result.link_refs and eb.render_result.link_refs[row]
		if not refs then
			return nil, row
		end
		local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		for _, ref in ipairs(refs) do
			local link_text = line_text:sub(ref.col_start + 1, ref.col_end)
			if ref.href and image.is_image_filename(link_text) then
				return { href = ref.href, ext = link_text:lower():match("%.(%w+)$") }, row
			end
		end
		return nil, row
	end

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
			if ref then
				fetch_and_show(ref, row)
				return
			end
			local img_link, link_row = get_image_link_at_cursor()
			if img_link then
				local auth = get_auth_for(eb.metadata)
				image.download_file(img_link.href, auth, function(err, path)
					if err or not path then return end
					if not vim.api.nvim_buf_is_valid(buf) then return end
					if vim.api.nvim_win_get_cursor(0)[1] - 1 == link_row then
						image.show_hover(path, buf)
					end
				end, { ext = img_link.ext })
				return
			end
			-- Keep hover open on link ref lines (PDF previews)
			local link_refs = eb.render_result and eb.render_result.link_refs and eb.render_result.link_refs[row]
			if link_refs then return end
			image.hover_close()
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			local ref = get_image_ref_at_cursor()
			if ref then return end
			local row = vim.api.nvim_win_get_cursor(0)[1] - 1
			local link_refs = eb.render_result and eb.render_result.link_refs and eb.render_result.link_refs[row]
			if link_refs then return end
			image.hover_close()
		end,
	})

	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		buffer = buf,
		callback = function()
			image.hover_close()
		end,
	})

end

--- K keymap: preview images and PDF attachments
---@param buf number
---@param eb EditorBuffer
function M.setup_preview_keymap(buf, eb)
	local image = require("atlassian.image")

	vim.keymap.set("n", "K", function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		local col = vim.api.nvim_win_get_cursor(0)[2]

		-- Check image refs first
		local img_ref = eb.render_result and eb.render_result.image_refs and eb.render_result.image_refs[row]
		if img_ref then
			vim.notify("Fetching image...", vim.log.levels.INFO)
			local meta = eb.metadata
			if img_ref.url then
				image.fetch_url(img_ref.url, function(err, path)
					if err or not path then return end
					if not vim.api.nvim_buf_is_valid(buf) then return end
					image.show_hover(path, buf)
				end)
			elseif img_ref.filename or img_ref.id then
				local id_or_name = img_ref.filename or img_ref.id
				if meta.type == "jira" then
					image.fetch_jira_attachment(buf, id_or_name, function(err, path)
						if err or not path then return end
						if not vim.api.nvim_buf_is_valid(buf) then return end
						image.show_hover(path, buf)
					end)
				elseif meta.type == "confluence" and meta.id then
					image.fetch_confluence_attachment(meta.id, id_or_name, function(err, path)
						if err or not path then return end
						if not vim.api.nvim_buf_is_valid(buf) then return end
						image.show_hover(path, buf)
					end)
				end
			end
			return
		end

		-- Check link refs for PDF attachments
		local link_refs = eb.render_result and eb.render_result.link_refs and eb.render_result.link_refs[row]
		if link_refs then
			local best, best_dist
			for _, ref in ipairs(link_refs) do
				local dist = 0
				if col < ref.col_start then
					dist = ref.col_start - col
				elseif col >= ref.col_end then
					dist = col - ref.col_end + 1
				end
				if not best_dist or dist < best_dist then
					best = ref
					best_dist = dist
				end
			end

			if best and best.href then
				-- Extract filename from the line text to check extension
				local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
				local link_text = line_text:sub(best.col_start + 1, best.col_end)
				local auth = get_auth_for(eb.metadata)

				if image.is_pdf_filename(link_text) or best.href:lower():match("%.pdf") then
					vim.notify("Fetching PDF preview...", vim.log.levels.INFO)
					image.download_file(best.href, auth, function(err, pdf_path)
						if err or not pdf_path then
							vim.notify("PDF download failed: " .. (err or ""), vim.log.levels.ERROR)
							return
						end
						if not vim.api.nvim_buf_is_valid(buf) then return end
						image.show_pdf(pdf_path, buf)
					end, { ext = "pdf" })
					return
				elseif image.is_image_filename(link_text) then
					vim.notify("Fetching image...", vim.log.levels.INFO)
					image.download_file(best.href, auth, function(err, path)
						if err or not path then
							vim.notify("Image download failed: " .. (err or ""), vim.log.levels.ERROR)
							return
						end
						if not vim.api.nvim_buf_is_valid(buf) then return end
						image.show_hover(path, buf)
					end, { ext = link_text:lower():match("%.(%w+)$") })
					return
				end
			end
		end

		vim.notify("No previewable content at cursor", vim.log.levels.INFO)
	end, { buffer = buf, desc = "Preview image/PDF at cursor" })
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
