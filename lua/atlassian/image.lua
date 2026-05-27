-- CSF image display via snacks.image
-- Fetches and caches Confluence/Jira attachments, shows float on hover
local M = {}

local request = require("atlassian.request")

--- Current hover state per buffer
---@type { buf: number, win: number, placement: table, src: string }|nil
local hover = nil

---@param key string Cache key
---@return string|nil path Cached image path
function M.get_cached(key)
    local cache_dir = M.get_cache_dir()
    local path = cache_dir .. "/" .. key
    if vim.fn.filereadable(path) == 1 then
        return path
    end
    return nil
end

---@return string
function M.get_cache_dir()
    local ok, cc = pcall(require, "confluence-interface.config")
    if ok and cc.options and cc.options.image and cc.options.image.cache_dir then
        return cc.options.image.cache_dir
    end
    local ok2, jc = pcall(require, "jira-interface.config")
    if ok2 and jc.options and jc.options.image and jc.options.image.cache_dir then
        return jc.options.image.cache_dir
    end
    return vim.fn.stdpath("cache") .. "/atlassian/images"
end

---@return number Max file size in bytes
function M.get_max_file_size()
    local ok, cc = pcall(require, "confluence-interface.config")
    if ok and cc.options and cc.options.image and cc.options.image.max_file_size then
        return cc.options.image.max_file_size
    end
    return 2 * 1024 * 1024 -- 2MB default
end

---@return number Terminal cell height/width ratio used to fit preview floats
function M.get_cell_aspect()
    local ok, cc = pcall(require, "confluence-interface.config")
    if ok and cc.options and cc.options.image and cc.options.image.cell_aspect then
        return cc.options.image.cell_aspect
    end
    local ok2, jc = pcall(require, "jira-interface.config")
    if ok2 and jc.options and jc.options.image and jc.options.image.cell_aspect then
        return jc.options.image.cell_aspect
    end
    return 2.0
end

---@param url string
---@param auth table|nil Auth config
---@param cb fun(err: string|nil, path: string|nil)
---@param opts? { ext?: string }
function M.download_file(url, auth, cb, opts)
    local ext = (opts and opts.ext) or url:match("%.(%w+)[%?#]?") or ""
    local hash = vim.fn.sha256(url):sub(1, 16)
    local cache_key = ext ~= "" and (hash .. "." .. ext) or hash

    local cached = M.get_cached(cache_key)
    if cached then
        cb(nil, cached)
        return
    end

    local cache_dir = M.get_cache_dir()
    vim.fn.mkdir(cache_dir, "p")
    local output_path = cache_dir .. "/" .. cache_key

    local args = { "curl", "-s", "-L", "-o", output_path }
    if auth then
        table.insert(args, "-H")
        table.insert(args, "Authorization: " .. request.get_auth_header(auth))
    end
    table.insert(args, url)

    vim.system(args, { text = false }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                cb("Download failed: " .. (result.stderr or ""), nil)
                return
            end
            if vim.fn.filereadable(output_path) == 1 then
                cb(nil, output_path)
            else
                cb("File not saved", nil)
            end
        end)
    end)
end

---@param page_id string
---@param filename string
---@param cb fun(err: string|nil, path: string|nil)
function M.fetch_confluence_attachment(page_id, filename, cb)
    local ok, cc = pcall(require, "confluence-interface.config")
    if not ok then
        cb("Confluence not configured", nil)
        return
    end

    local base_url = request.normalize_url(cc.options.auth.url)
    request.request({
        auth = cc.options.auth,
        base_url = base_url,
        endpoint = "/wiki/rest/api/content/" .. page_id .. "/child/attachment"
            .. "?filename=" .. vim.uri_encode(filename),
        method = "GET",
        callback = function(err, data)
            if err then
                cb(tostring(err), nil)
                return
            end
            if data and data.results and data.results[1] then
                local att = data.results[1]
                local download_url = base_url .. "/wiki" .. att._links.download
                if att.extensions and att.extensions.fileSize then
                    local size = tonumber(att.extensions.fileSize) or 0
                    if size > M.get_max_file_size() then
                        cb(nil, nil)
                        return
                    end
                end
                local ext = filename:match("%.(%w+)$") or ""
                M.download_file(download_url, cc.options.auth, cb, { ext = ext })
            else
                cb("Attachment not found: " .. filename, nil)
            end
        end,
    })
end

--- Download a resolved Jira attachment object, gating on the size limit.
---@param att table Attachment { url, filename, size }
---@param auth table
---@param cb fun(err: string|nil, path: string|nil)
local function download_jira_att(att, auth, cb)
    if att.size and att.size > M.get_max_file_size() then
        cb(nil, nil)
        return
    end
    local ext = (att.filename or ""):match("%.(%w+)$") or ""
    M.download_file(att.url, auth, cb, { ext = ext })
end

--- Build (and cache on the buffer) a map of media-services UUID -> attachment.
--- Jira embeds images in ADF as `media` nodes keyed by a media-services UUID,
--- which is not the attachment id. The attachment content endpoint 303-redirects
--- to `.../file/<uuid>/binary`, so we probe each attachment to recover its UUID.
---@param buf number
---@param auth table
---@param attachments table[] Parsed attachments with numeric `id`
---@param cb fun(map: table<string, table>)
function M.ensure_jira_media_map(buf, auth, attachments, cb)
    if vim.b[buf] and vim.b[buf].atlassian_media_map then
        cb(vim.b[buf].atlassian_media_map)
        return
    end

    local map = {}
    local pending = #attachments
    if pending == 0 then
        cb(map)
        return
    end

    local base_url = request.normalize_url(auth.url)
    local auth_header = request.get_auth_header(auth)

    for _, att in ipairs(attachments) do
        local url = base_url .. "/rest/api/3/attachment/content/" .. att.id .. "?redirect=true"
        local args = {
            "curl", "-s", "-o", "/dev/null", "-w", "%{redirect_url}",
            "-H", "Authorization: " .. auth_header, url,
        }
        vim.system(args, { text = true }, function(result)
            vim.schedule(function()
                local uuid = (result.stdout or ""):match("/file/([^/]+)/binary")
                if uuid then
                    map[uuid] = att
                end
                pending = pending - 1
                if pending == 0 then
                    if vim.api.nvim_buf_is_valid(buf) then
                        vim.b[buf].atlassian_media_map = map
                    end
                    cb(map)
                end
            end)
        end)
    end
end

--- Fetch Jira attachment using stored attachment data from buffer variable
---@param buf number
---@param id_or_name string Attachment ID, filename, or ADF media-services UUID
---@param cb fun(err: string|nil, path: string|nil)
function M.fetch_jira_attachment(buf, id_or_name, cb)
    local ok, jc = pcall(require, "jira-interface.config")
    if not ok then
        cb("Jira not configured", nil)
        return
    end
    local auth = jc.options.auth
    local attachments = (vim.b[buf] and vim.b[buf].atlassian_attachments) or {}

    -- Direct match by attachment id or filename (covers ADF `alt` set to filename)
    for _, att in ipairs(attachments) do
        if att.id == id_or_name or att.filename == id_or_name then
            download_jira_att(att, auth, cb)
            return
        end
    end

    -- Resolve an ADF `media` node's media-services UUID to its attachment.
    M.ensure_jira_media_map(buf, auth, attachments, function(map)
        local att = map[id_or_name]
        if att then
            download_jira_att(att, auth, cb)
        else
            cb("Attachment not found: " .. id_or_name, nil)
        end
    end)
end

---@param url string Direct URL for ri:url images
---@param cb fun(err: string|nil, path: string|nil)
function M.fetch_url(url, cb)
    M.download_file(url, nil, cb)
end

--- Get buffer metadata and auth config
---@param buf number
---@return table|nil meta, table|nil auth
local function get_buf_context(buf)
    local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    local csf_mod = require("atlassian.csf")
    local meta = csf_mod.parse_metadata(first_line)
    if not meta then return nil, nil end

    if meta.type == "confluence" then
        local ok, cc = pcall(require, "confluence-interface.config")
        if ok then return meta, cc.options.auth end
    elseif meta.type == "jira" then
        local ok, jc = pcall(require, "jira-interface.config")
        if ok then return meta, jc.options.auth end
    end
    return meta, nil
end

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, bmp = true, webp = true, svg = true, tiff = true }
local PDF_EXTS = { pdf = true }

--- Convert a single PDF page to PNG via the ImageMagick CLI. Cached per page.
---@param pdf_path string Local path to the PDF file
---@param page number 0-indexed page number
---@param cb fun(err: string|nil, png_path: string|nil)
function M.convert_pdf_to_png(pdf_path, page, cb)
    page = page or 0
    local cache_dir = M.get_cache_dir()
    local hash = vim.fn.sha256(pdf_path):sub(1, 16)
    local png_path = cache_dir .. "/" .. hash .. "_v3_p" .. (page + 1) .. ".png"

    if vim.fn.filereadable(png_path) == 1 then
        cb(nil, png_path)
        return
    end

    vim.fn.mkdir(cache_dir, "p")
    -- ImageMagick 7 uses "magick", ImageMagick 6 uses "convert".
    -- `-density` must precede the input to set the PDF rasterization resolution.
    local cmd = vim.fn.executable("magick") == 1 and "magick" or "convert"
    vim.system(
        { cmd, "-density", "150", pdf_path .. "[" .. page .. "]", "-background", "white", "-alpha", "remove", png_path },
        { text = false },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    cb("magick convert failed: " .. (result.stderr or ""), nil)
                    return
                end
                if vim.fn.filereadable(png_path) == 1 then
                    cb(nil, png_path)
                else
                    cb("PNG not created", nil)
                end
            end)
        end
    )
end

--- Count the pages in a PDF. Prefers pdfinfo, falls back to ImageMagick.
---@param pdf_path string
---@param cb fun(count: number)
function M.pdf_page_count(pdf_path, cb)
    if vim.fn.executable("pdfinfo") == 1 then
        vim.system({ "pdfinfo", pdf_path }, { text = true }, function(r)
            vim.schedule(function()
                cb(tonumber((r.stdout or ""):match("Pages:%s*(%d+)")) or 1)
            end)
        end)
        return
    end
    local cmd = vim.fn.executable("magick") == 1 and "magick" or "convert"
    vim.system({ cmd, "identify", "-format", "%n\n", pdf_path }, { text = true }, function(r)
        vim.schedule(function()
            cb(tonumber((r.stdout or ""):match("(%d+)")) or 1)
        end)
    end)
end

--- Check if a filename is a previewable document (PDF)
---@param name string
---@return boolean
function M.is_pdf_filename(name)
    local ext = name:lower():match("%.(%w+)$")
    return ext and PDF_EXTS[ext] or false
end

--- Check if a filename has an image extension
---@param name string
---@return boolean
function M.is_image_filename(name)
    local ext = name:lower():match("%.(%w+)$")
    return ext and IMAGE_EXTS[ext] or false
end
local is_image_filename = M.is_image_filename

--- Fetch an image reference, dispatching to the right backend
---@param buf number
---@param ref { filename?: string, url?: string, auth_url?: string }
---@param meta table Buffer metadata
---@param cb fun(err: string|nil, path: string|nil)
local function fetch_image_ref(buf, ref, meta, cb)
    if ref.auth_url then
        local _, auth = get_buf_context(buf)
        local ext = ref.filename and ref.filename:match("%.(%w+)$") or ""
        M.download_file(ref.auth_url, auth, cb, { ext = ext })
    elseif ref.url then
        M.fetch_url(ref.url, cb)
    elseif ref.filename and meta.type == "confluence" and meta.id then
        M.fetch_confluence_attachment(meta.id, ref.filename, cb)
    elseif ref.filename and meta.type == "jira" then
        M.fetch_jira_attachment(buf, ref.filename, cb)
    else
        cb("Cannot resolve image reference", nil)
    end
end

--- Parse image reference from a buffer line
---@param line string
---@return table|nil ref
local function parse_image_ref(line)
    -- <ac:image> with ri:attachment
    local filename = line:match('ri:filename="([^"]+)"')
    if filename then
        return { filename = filename }
    end
    -- <ac:image> with ri:url
    local url = line:match('ri:value="([^"]+)"')
    if url and line:match("ac:image") then
        return { url = url }
    end
    -- <a href="...">image_filename.png</a> (attachment links)
    local href, link_text = line:match('<a href="([^"]+)">([^<]+)</a>')
    if href and link_text and is_image_filename(link_text) then
        return { auth_url = href, filename = link_text }
    end
    return nil
end

--- Detect which image backend is available
---@return "snacks"|"image_nvim"|nil
local function detect_backend()
    local ok_snacks, Snacks = pcall(require, "snacks")
    if ok_snacks and Snacks.image then
        local snacks_config = Snacks.config or {}
        local image_config = snacks_config.image or (snacks_config.get and snacks_config.get("image"))
        if not image_config or image_config.enabled ~= false then
            return "snacks"
        end
    end

    local ok_img = pcall(require, "image")
    if ok_img then
        return "image_nvim"
    end

    return nil
end

--- Close current hover float
function M.hover_close()
    if hover then
        if hover.pdf and hover.pdf.keys and hover.buf and vim.api.nvim_buf_is_valid(hover.buf) then
            pcall(vim.keymap.del, "n", "]", { buffer = hover.buf })
            pcall(vim.keymap.del, "n", "[", { buffer = hover.buf })
        end
        if hover.placement then
            pcall(function() hover.placement:close() end)
        end
        if hover.image_obj then
            pcall(function() hover.image_obj:clear() end)
        end
        if hover.win and vim.api.nvim_win_is_valid(hover.win) then
            pcall(vim.api.nvim_win_close, hover.win, true)
        end
        hover = nil
    end
end

--- Read pixel dimensions from a PNG header (no external dependency).
---@param path string
---@return number|nil w, number|nil h
local function read_png_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(24)
    f:close()
    if not data or #data < 24 or data:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil
    end
    local function be32(o)
        local a, b, c, d = data:byte(o, o + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    -- 8-byte signature, 4-byte length, "IHDR", then width(4) and height(4).
    return be32(17), be32(21)
end

--- Read pixel dimensions from a JPEG by scanning to the Start-of-Frame marker.
---@param path string
---@return number|nil w, number|nil h
local function read_jpeg_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    if f:read(2) ~= "\255\216" then -- SOI (FF D8)
        f:close()
        return nil
    end
    while true do
        local b = f:read(1)
        if not b then break end
        if b == "\255" then
            local m = f:read(1)
            while m == "\255" do m = f:read(1) end -- skip fill bytes
            if not m then break end
            local marker = m:byte()
            -- Standalone markers (no length): SOI/EOI, RST0-7, TEM.
            if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01 then
            -- luacheck: ignore (intentionally fall through to next marker)
            else
                local lenb = f:read(2)
                if not lenb or #lenb < 2 then break end
                local len = lenb:byte(1) * 256 + lenb:byte(2)
                -- SOF markers carry dimensions: C0-CF except C4(DHT), C8(JPG), CC(DAC).
                if marker >= 0xC0 and marker <= 0xCF
                    and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    local sof = f:read(5) -- precision(1), height(2), width(2)
                    f:close()
                    if not sof or #sof < 5 then return nil end
                    return sof:byte(4) * 256 + sof:byte(5), sof:byte(2) * 256 + sof:byte(3)
                end
                f:seek("cur", len - 2) -- skip this segment's payload
            end
        end
    end
    f:close()
    return nil
end

--- Read pixel dimensions of a PNG or JPEG image (by content, not extension).
---@param path string
---@return number|nil w, number|nil h
local function read_image_size(path)
    local w, h = read_png_size(path)
    if w then return w, h end
    return read_jpeg_size(path)
end

--- Float window size (in cells) fitted to an image's aspect ratio, within bounds.
---@param path string Local image path
---@return number cols, number rows
local function fit_dims(path)
    local max_w = math.min(80, math.floor(vim.o.columns * 0.45))
    local max_h = math.floor(vim.o.lines * 0.9)
    local w, h = read_image_size(path)
    if not (w and h and w > 0 and h > 0) then
        return max_w, max_h
    end
    local cell_aspect = M.get_cell_aspect()
    local cols = max_w
    local rows = math.floor(cols * (h / w) / cell_aspect + 0.5)
    if rows > max_h then
        rows = max_h
        cols = math.floor(rows * (w / h) * cell_aspect + 0.5)
    end
    return math.max(cols, 10), math.max(rows, 3)
end

--- Show an image hover float in the top-right corner, fitted to the image.
---@param path string Local cached image path
---@param source_buf number The document buffer
---@param opts? { title?: string }
function M.show_hover(path, source_buf, opts)
    if hover and hover.src == path then return end

    M.hover_close()

    local backend = detect_backend()
    if not backend then return end

    local width, height = fit_dims(path)
    local title = opts and opts.title

    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].bufhidden = "wipe"

    local lines = {}
    for _ = 1, height do
        table.insert(lines, "")
    end
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

    local win = vim.api.nvim_open_win(float_buf, false, {
        relative = "editor",
        width = width,
        height = height,
        row = 1,
        col = vim.o.columns - width - 1,
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 50,
        title = title,
        title_pos = title and "center" or nil,
    })

    hover = {
        buf = source_buf,
        win = win,
        src = path,
    }

    if backend == "snacks" then
        local Snacks = require("snacks")
        hover.placement = Snacks.image.placement.new(float_buf, path, {
            pos = { 1, 0 },
            inline = true,
            max_width = width,
            max_height = height,
        })
    elseif backend == "image_nvim" then
        local image = require("image")
        local img = image.from_file(path, {
            window = win,
            buffer = float_buf,
            with_virtual_padding = true,
            x = 0,
            y = 0,
            width = width,
            height = height,
        })
        if img then
            img:render()
            hover.image_obj = img
        end
    end
end

--- Render a PDF page into the hover float and wire up page navigation.
---@param pdf_path string
---@param source_buf number
---@param png_path string Rendered page image
---@param page number 0-indexed
---@param total number
local function show_pdf_page(pdf_path, source_buf, png_path, page, total)
    local title = total > 1 and string.format(" PDF %d/%d   [ prev · ] next ", page + 1, total) or nil
    M.show_hover(png_path, source_buf, { title = title })
    if not hover then return end
    hover.pdf = { path = pdf_path, page = page, total = total }
    if total > 1 then
        vim.keymap.set("n", "]", function() M.pdf_page(1) end,
            { buffer = source_buf, desc = "PDF preview: next page" })
        vim.keymap.set("n", "[", function() M.pdf_page(-1) end,
            { buffer = source_buf, desc = "PDF preview: previous page" })
        hover.pdf.keys = true
    end
end

--- Turn the currently previewed PDF by `delta` pages (rendered on demand).
---@param delta number
function M.pdf_page(delta)
    if not (hover and hover.pdf) then return end
    local p = hover.pdf
    local new_page = p.page + delta
    if new_page < 0 or new_page >= p.total then return end
    local pdf_path, source_buf, total = p.path, hover.buf, p.total
    M.convert_pdf_to_png(pdf_path, new_page, function(err, png_path)
        if err or not png_path then
            vim.notify("PDF page render failed: " .. (err or ""), vim.log.levels.ERROR)
            return
        end
        if not vim.api.nvim_buf_is_valid(source_buf) then return end
        show_pdf_page(pdf_path, source_buf, png_path, new_page, total)
    end)
end

--- Preview a downloaded PDF with fitted dimensions and page navigation.
---@param pdf_path string Local path to the PDF
---@param source_buf number The document buffer
function M.show_pdf(pdf_path, source_buf)
    M.pdf_page_count(pdf_path, function(total)
        M.convert_pdf_to_png(pdf_path, 0, function(err, png_path)
            if err or not png_path then
                vim.notify("PDF convert failed: " .. (err or ""), vim.log.levels.ERROR)
                return
            end
            if not vim.api.nvim_buf_is_valid(source_buf) then return end
            show_pdf_page(pdf_path, source_buf, png_path, 0, total)
        end)
    end)
end

--- Attach hover autocmds to a CSF buffer
---@param buf number
function M.setup_hover(buf)
    local group = vim.api.nvim_create_augroup("csf_image_hover_" .. buf, { clear = true })

    vim.api.nvim_create_autocmd("CursorHold", {
        group = group,
        buffer = buf,
        callback = function()
            if vim.fn.mode() ~= "n" then return end
            local row = vim.api.nvim_win_get_cursor(0)[1]
            local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            local ref = parse_image_ref(line)
            if not ref then
                M.hover_close()
                return
            end

            local meta = get_buf_context(buf)
            if not meta then return end

            fetch_image_ref(buf, ref, meta, function(err, path)
                if err or not path then return end
                if not vim.api.nvim_buf_is_valid(buf) then return end
                -- Only show if cursor is still on same line
                local cur_row = vim.api.nvim_win_get_cursor(0)[1]
                if cur_row == row then
                    M.show_hover(path, buf)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = buf,
        callback = function()
            if not hover or hover.buf ~= buf then return end
            local row = vim.api.nvim_win_get_cursor(0)[1]
            local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            local ref = parse_image_ref(line)
            if not ref then
                M.hover_close()
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        group = group,
        buffer = buf,
        callback = function()
            M.hover_close()
        end,
    })
end

--- Show image at cursor (explicit K keymap trigger)
---@param buf number
function M.show_at_cursor(buf)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    local ref = parse_image_ref(line)

    if not ref then
        vim.notify("No image found at cursor", vim.log.levels.INFO)
        return
    end

    local meta = get_buf_context(buf)
    if not meta then
        vim.notify("Cannot determine buffer context for image", vim.log.levels.WARN)
        return
    end

    vim.notify("Fetching image...", vim.log.levels.INFO)
    fetch_image_ref(buf, ref, meta, function(err, path)
        if err then
            vim.notify("Image error: " .. err, vim.log.levels.ERROR)
        elseif not path then
            vim.notify("[Image too large, exceeds size limit]", vim.log.levels.WARN)
        else
            M.show_hover(path, buf)
        end
    end)
end

return M
