local M = {}

local api = require("confluence-interface.api")
local types = require("confluence-interface.types")
local config = require("confluence-interface.config")
local cache = require("confluence-interface.cache")
local notify = require("confluence-interface.notify")
local atlassian_ui = require("atlassian.ui")
local atlassian_format = require("atlassian.format")
local bridge = require("atlassian.csf.bridge")
local editor = require("atlassian.editor")

--- Build a composite ADF document from a Confluence page.
---@param page ConfluencePage
---@return table ADF document
local function build_page_view_adf(page)
    local content = {}

    table.insert(content, {
        type = "heading", attrs = { level = 1 },
        content = { { type = "text", text = page.title or "" } },
    })

    local function add_field(label, value)
        if not value or value == "" then return end
        table.insert(content, {
            type = "paragraph",
            content = {
                { type = "text", text = label .. ": ", marks = { { type = "strong" } } },
                { type = "text", text = tostring(value) },
            },
        })
    end

    add_field("ID", page.id)
    add_field("Version", page.version)
    add_field("Status", page.status)
    if page.space_key then add_field("Space", page.space_key) end

    table.insert(content, { type = "rule" })

    -- Page body: convert CSF → ADF
    if page.body and page.body ~= "" then
        local body_adf = bridge.csf_to_adf(page.body)
        if body_adf and body_adf.content then
            for _, node in ipairs(body_adf.content) do
                table.insert(content, node)
            end
        end
    else
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = "No content", marks = { { type = "em" } } } },
        })
    end

    -- Footer
    table.insert(content, { type = "rule" })
    if page.web_url then
        local base_url = config.options.auth.url
        if not base_url:match("^https?://") then base_url = "https://" .. base_url end
        local url = base_url .. "/wiki" .. page.web_url
        table.insert(content, {
            type = "paragraph",
            content = {
                { type = "text", text = "URL: ", marks = { { type = "strong" } } },
                { type = "text", text = url, marks = { { type = "link", attrs = { href = url } } } },
            },
        })
    end
    table.insert(content, {
        type = "paragraph",
        content = { {
            type = "text",
            text = "Updated: " .. atlassian_format.format_timestamp(page.updated)
                .. " (" .. atlassian_format.format_relative_time(page.updated) .. ")",
            marks = { { type = "em" } },
        } },
    })

    return { type = "doc", version = 1, content = content }
end

--- Show a Confluence page using the ADF projection engine.
---@param page ConfluencePage
function M.show_page_projected(page)
    local display = vim.tbl_extend("force", config.options.display or {}, {})
    display.mode = "buffer"

    local buf, win = atlassian_ui.create_window({
        title = page.title,
        bufname = "confluence://" .. page.id,
        display = display,
        filetype = "atlassian",
    })

    local adf = build_page_view_adf(page)

    editor.open(adf, {
        type = "confluence",
        id = page.id,
        version = page.version,
        space_key = page.space_key,
    }, {
        buf = buf,
        win = win,
        modifiable = false,
    })

    -- Keymaps
    vim.keymap.set("n", "e", function()
        M.edit_page_projected(page.id)
    end, { buffer = buf, desc = "Edit page" })

    vim.keymap.set("n", "c", function()
        local picker = require("confluence-interface.picker")
        picker.show_children(page.id, page.title)
    end, { buffer = buf, desc = "Show children" })

    vim.keymap.set("n", "y", function()
        vim.fn.setreg("+", page.id)
        notify.info("Copied page ID: " .. page.id)
    end, { buffer = buf, desc = "Copy page ID" })

    vim.keymap.set("n", "Y", function()
        if page.web_url then
            local base_url = config.options.auth.url
            if not base_url:match("^https?://") then base_url = "https://" .. base_url end
            local url = base_url .. "/wiki" .. page.web_url
            vim.fn.setreg("+", url)
            notify.info("Copied: " .. url)
        end
    end, { buffer = buf, desc = "Copy page URL" })

    vim.keymap.set("n", "o", function()
        if page.web_url then
            local base_url = config.options.auth.url
            if not base_url:match("^https?://") then base_url = "https://" .. base_url end
            vim.ui.open(base_url .. "/wiki" .. page.web_url)
        end
    end, { buffer = buf, desc = "Open in browser" })

    vim.keymap.set("n", "?", function()
        vim.cmd("help atlassian-confluence-keymaps")
    end, { buffer = buf, desc = "Show help" })

    atlassian_ui.setup_view_keymaps(buf)
end

--- Edit a Confluence page using the ADF projection engine.
---@param page_id string
function M.edit_page_projected(page_id)
    notify.progress_start("edit", "Loading page for editing...")
    api.get_page(page_id, function(err, page)
        notify.progress_finish("edit")
        if err then
            notify.error("Failed to fetch page: " .. err)
            return
        end

        local display = vim.tbl_extend("force", config.options.display or {}, {})
        display.mode = "buffer"

        local buf, win = atlassian_ui.create_window({
            title = "Edit: " .. page.title,
            bufname = "confluence://" .. page.id .. "/edit",
            display = display,
            filetype = "atlassian",
        })

        -- Build editable ADF: title + body content
        local content = {}

        table.insert(content, {
            type = "heading", attrs = { level = 1 },
            content = { { type = "text", text = page.title or "" } },
        })

        local body_start = #content + 1

        if page.body and page.body ~= "" then
            local body_adf = bridge.csf_to_adf(page.body)
            if body_adf and body_adf.content then
                for _, node in ipairs(body_adf.content) do
                    table.insert(content, node)
                end
            end
        else
            table.insert(content, {
                type = "paragraph",
                content = { { type = "text", text = "" } },
            })
        end

        local edit_adf = { type = "doc", version = 1, content = content }

        local eb = editor.open(edit_adf, {
            type = "confluence",
            id = page.id,
            version = page.version,
            space_key = page.space_key,
        }, {
            buf = buf,
            win = win,
            modifiable = true,
        })

        local function do_submit()
            -- Extract title from first heading
            local title = page.title
            local adf_content = eb.adf.content or {}
            if adf_content[1] and adf_content[1].type == "heading" then
                local texts = {}
                for _, child in ipairs(adf_content[1].content or {}) do
                    if child.type == "text" then texts[#texts + 1] = child.text or "" end
                end
                title = table.concat(texts)
            end

            -- Collect body nodes (everything after the title heading)
            local body_content = {}
            for i = 2, #adf_content do
                table.insert(body_content, adf_content[i])
            end

            -- Convert ADF body → CSF for Confluence API
            local body_adf_doc = { type = "doc", version = 1, content = body_content }
            local csf_body = bridge.adf_to_csf(body_adf_doc)

            notify.progress_start("save", "Saving page...")
            api.update_page(page.id, title, csf_body, page.version,
                function(update_err, updated_page)
                    if update_err then
                        notify.progress_error("save", notify.format_api_error(update_err, "saving page"))
                    else
                        notify.progress_finish("save", "Saved: " .. updated_page.title)
                        local draft_mod = require("atlassian.editor.draft")
                        draft_mod.mark_clean(eb)

                        if vim.api.nvim_buf_is_valid(buf) then
                            vim.api.nvim_buf_delete(buf, { force = true })
                        end
                        cache.invalidate_space(page.space_key)
                        M.view_page_projected(updated_page.id)
                    end
                end)
        end

        require("atlassian.submit").register(buf, { submit = do_submit, label = "Confluence Page" })
    end)
end

---@param page_id string
function M.view_page_projected(page_id)
    notify.progress_start("view", "Loading page...")
    api.get_page(page_id, function(err, page)
        notify.progress_finish("view")
        if err then
            notify.error("Failed to fetch page: " .. err)
            return
        end
        M.show_page_projected(page)
    end)
end

M.show_page = M.show_page_projected
M.view_page = M.view_page_projected
M.edit_page = M.edit_page_projected

---@param space_id string
---@param space_key string
---@param parent_id? string
function M.create_page_buffer(space_id, space_key, parent_id)
    local display = vim.tbl_extend("force", config.options.display or {}, {})
    display.mode = "buffer"

    local buf, win = atlassian_ui.create_window({
        title = "New Page (" .. space_key .. ")",
        bufname = "confluence://new/" .. space_key,
        display = display,
        filetype = "atlassian",
    })

    local create_adf = {
        type = "doc", version = 1,
        content = {
            { type = "heading", attrs = { level = 1 }, content = { { type = "text", text = "" } } },
            { type = "paragraph", content = { { type = "text", text = "" } } },
        },
    }

    local eb = editor.open(create_adf, {
        type = "confluence",
        id = "NEW",
        version = 1,
        space_id = space_id,
        space_key = space_key,
        parent_id = parent_id,
    }, {
        buf = buf,
        win = win,
        modifiable = true,
    })

    local function do_submit()
        local adf_content = eb.adf.content or {}

        -- Extract title from first heading
        local title = "Untitled"
        if adf_content[1] and adf_content[1].type == "heading" then
            local texts = {}
            for _, child in ipairs(adf_content[1].content or {}) do
                if child.type == "text" then texts[#texts + 1] = child.text or "" end
            end
            title = table.concat(texts)
            if title == "" then title = "Untitled" end
        end

        -- Collect body nodes (everything after the title)
        local body_content = {}
        for i = 2, #adf_content do
            table.insert(body_content, adf_content[i])
        end

        local body_adf = { type = "doc", version = 1, content = body_content }
        local csf_body = bridge.adf_to_csf(body_adf)

        notify.progress_start("create", "Creating page...")
        api.create_page(space_id, title, csf_body, parent_id,
            function(err, page)
                if err then
                    notify.progress_error("create", notify.format_api_error(err, "creating page"))
                else
                    notify.progress_finish("create", "Created: " .. page.title)
                    cache.invalidate_space(space_key)
                    if vim.api.nvim_buf_is_valid(buf) then
                        vim.api.nvim_buf_delete(buf, { force = true })
                    end
                    M.show_page_projected(page)
                end
            end)
    end

    require("atlassian.submit").register(buf, { submit = do_submit, label = "Confluence Page" })
end

function M.show_status()
    local cache_mod = require("confluence-interface.cache")
    local cache_stats = cache_mod.stats()

    api.check_connectivity(function(online)
        local status = online and "Online" or "Offline"
        local icon = online and "" or ""

        local lines = {
            string.format("%s %s", icon, status),
            string.format("Cache: %d entries (%.1f KB)", cache_stats.entries, cache_stats.size_bytes / 1024),
            string.format("Default space: %s", config.options.default_space or "(none)"),
        }

        notify.info(table.concat(lines, "\n"))
    end)
end

return M
