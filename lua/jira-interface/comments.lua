local M = {}

local api = require("jira-interface.api")
local cache = require("jira-interface.cache")
local config = require("jira-interface.config")
local notify = require("jira-interface.notify")
local atlassian_ui = require("atlassian.ui")
local atlassian_format = require("atlassian.format")
local bridge = require("atlassian.csf.bridge")

---@type table<number, { issue_key: string, comments: JiraComment[] }>
M._buf_comments = {}

--- Refresh the issue view buffer after a comment action
---@param issue_key string
local function refresh_issue_view(issue_key)
    api.get_issue(issue_key, function(err, fresh_issue)
        if err then
            notify.info("Comment saved for " .. issue_key)
        else
            local ui = require("jira-interface.ui")
            ui.show_issue_projected(fresh_issue)
        end
    end)
end

---@param issue_key string
function M.add_comment(issue_key)
    local editor = require("atlassian.editor")
    local display = vim.tbl_extend("force", config.options.display or {}, {})
    display.mode = "buffer"

    local buf, win = atlassian_ui.create_window({
        title = "Add Comment - " .. issue_key,
        bufname = "jira://" .. issue_key .. "/comment/new",
        display = display,
        filetype = "atlassian",
    })

    local comment_adf = {
        type = "doc", version = 1,
        content = {
            { type = "paragraph", content = { { type = "text", text = "" } } },
        },
    }

    local eb = editor.open(comment_adf, {
        type = "jira",
        key = issue_key,
    }, {
        buf = buf,
        win = win,
        modifiable = true,
    })

    local function do_submit()
        local body_adf = bridge.sanitize_for_jira(vim.deepcopy(eb.adf))

        -- Check if empty
        local has_content = false
        for _, node in ipairs(body_adf.content or {}) do
            if node.content then
                for _, child in ipairs(node.content) do
                    if child.type == "text" and child.text and vim.trim(child.text) ~= "" then
                        has_content = true
                        break
                    end
                end
            end
            if has_content then break end
        end

        if not has_content then
            notify.info("Empty comment, not saving")
            return
        end

        if api.is_online then
            api.add_comment(issue_key, body_adf, function(add_err)
                if add_err then
                    notify.error(notify.format_api_error(add_err, "adding comment"))
                else
                    if vim.api.nvim_buf_is_valid(buf) then
                        vim.api.nvim_buf_delete(buf, { force = true })
                    end
                    cache.invalidate_project(config.options.default_project)
                    notify.info("Comment added to " .. issue_key)
                    refresh_issue_view(issue_key)
                end
            end)
        else
            local queue = require("jira-interface.queue")
            local csf_body = bridge.adf_to_csf(body_adf)
            queue.queue_comment(issue_key, csf_body)
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end

    require("atlassian.submit").register(buf, { submit = do_submit, label = "Jira Comment" })
end

---@param issue_key string
---@param comment JiraComment
function M.edit_comment(issue_key, comment)
    local editor = require("atlassian.editor")
    local display = vim.tbl_extend("force", config.options.display or {}, {})
    display.mode = "buffer"

    local buf, win = atlassian_ui.create_window({
        title = "Edit Comment - " .. issue_key,
        bufname = "jira://" .. issue_key .. "/comment/" .. comment.id,
        display = display,
        filetype = "atlassian",
    })

    -- Use existing comment body ADF, or empty
    local comment_adf
    if comment.body and type(comment.body) == "table" and comment.body.content then
        comment_adf = vim.deepcopy(comment.body)
    else
        comment_adf = {
            type = "doc", version = 1,
            content = {
                { type = "paragraph", content = { { type = "text", text = "" } } },
            },
        }
    end

    local eb = editor.open(comment_adf, {
        type = "jira",
        key = issue_key,
    }, {
        buf = buf,
        win = win,
        modifiable = true,
    })

    M._buf_comments[buf] = { issue_key = issue_key, comment = comment }
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            M._buf_comments[buf] = nil
        end,
    })

    local function do_submit()
        local body_adf = bridge.sanitize_for_jira(vim.deepcopy(eb.adf))

        api.update_comment(issue_key, comment.id, body_adf, function(update_err)
            if update_err then
                notify.error(notify.format_api_error(update_err, "updating comment"))
            else
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
                notify.info("Comment updated on " .. issue_key)
                refresh_issue_view(issue_key)
            end
        end)
    end

    require("atlassian.submit").register(buf, { submit = do_submit, label = "Jira Comment" })
end

---@param issue_key string
---@param comment JiraComment
function M.delete_comment(issue_key, comment)
    local preview = comment.author_name .. ": "
    if comment.body and type(comment.body) == "table" and comment.body.content then
        local text = require("atlassian.adf").adf_to_text(comment.body)
        preview = preview .. (text:sub(1, 60) .. (text:len() > 60 and "..." or ""))
    end

    vim.ui.input({ prompt = "Delete comment? (" .. preview .. ") [yes/no]: " }, function(input)
        if not input or input:lower() ~= "yes" then
            return
        end

        api.delete_comment(issue_key, comment.id, function(err)
            if err then
                notify.error("Failed to delete comment: " .. err)
            else
                notify.info("Comment deleted from " .. issue_key)
                refresh_issue_view(issue_key)
            end
        end)
    end)
end

---@param issue_key string
---@param comments JiraComment[]
---@param action_name string
---@param cb fun(comment: JiraComment)
function M.select_comment(issue_key, comments, action_name, cb)
    if #comments == 0 then
        notify.info("No comments on " .. issue_key)
        return
    end

    local Snacks = require("snacks")

    local items = {}
    for idx, comment in ipairs(comments) do
        local time_str = atlassian_format.format_relative_time(comment.created)
        local preview = ""
        if comment.body and type(comment.body) == "table" and comment.body.content then
            local text = require("atlassian.adf").adf_to_text(comment.body)
            preview = text:sub(1, 50):gsub("\n", " ")
        end
        table.insert(items, {
            idx = idx,
            text = string.format("%s %s %s", comment.author_name, time_str, preview),
            comment = comment,
            author = comment.author_name,
            time = time_str,
            preview = preview,
        })
    end

    local ms = atlassian_ui.multiselect(items)
    local ms_actions = atlassian_ui.multiselect_actions(ms)

    Snacks.picker.pick({
        title = action_name:sub(1, 1):upper() .. action_name:sub(2) .. " Comment (" .. issue_key .. ")",
        items = items,
        format = function(item, _picker)
            local ret = {
                { item.author .. " ", "Function" },
                { "(" .. item.time .. "): ", "Comment" },
                { item.preview, "Normal" },
            }
            return atlassian_ui.multiselect_indicator(ret, ms, item)
        end,
        confirm = function(picker, item)
            picker:close()
            local selected = ms.get_selected(item, "comment")
            for _, c in ipairs(selected) do
                cb(c)
            end
        end,
        actions = ms_actions,
        layout = {
            layout = {
                box = "vertical",
                backdrop = false,
                row = -1,
                width = 0,
                height = 0.4,
                border = "top",
                title = " {title} {live} {flags}",
                title_pos = "left",
                { win = "input", height = 1, border = "bottom" },
                { win = "list", border = "none" },
            },
        },
        preview = false,
        win = {
            input = {
                keys = atlassian_ui.multiselect_keys,
            },
        },
    })
end

---@param issue_key string
---@param action_name string
---@param cb fun(comment: JiraComment)
function M.fetch_and_select_comment(issue_key, action_name, cb)
    api.get_comments(issue_key, nil, function(err, data)
        if err then
            notify.error("Failed to fetch comments: " .. err)
            return
        end
        M.select_comment(issue_key, data.comments, action_name, cb)
    end)
end

return M
