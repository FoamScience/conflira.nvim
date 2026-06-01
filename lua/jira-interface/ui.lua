local M = {}

local api = require("jira-interface.api")
local types = require("jira-interface.types")
local cache = require("jira-interface.cache")
local config = require("jira-interface.config")
local notify = require("jira-interface.notify")
local atlassian_ui = require("atlassian.ui")
local atlassian_format = require("atlassian.format")
local bridge = require("atlassian.csf.bridge")
local editor = require("atlassian.editor")

--- Build a composite ADF document from a JiraIssue for the projection engine.
---@param issue JiraIssue
---@return table ADF document
local function build_issue_adf(issue)
    local content = {}

    -- Title
    table.insert(content, {
        type = "heading",
        attrs = { level = 1 },
        content = { { type = "text", text = issue.summary or "" } },
    })

    -- Metadata fields as bold key-value paragraphs
    local function add_field(label, value)
        if not value or value == "" then
            return
        end
        table.insert(content, {
            type = "paragraph",
            content = {
                { type = "text", text = label .. ": ", marks = { { type = "strong" } } },
                { type = "text", text = tostring(value) },
            },
        })
    end

    add_field("Key", issue.key)
    add_field("Type", issue.type .. " (Level " .. issue.level .. ")")

    local status_info = types.get_status_display(issue.status)
    add_field("Status", status_info.icon .. " " .. issue.status)
    add_field("Project", issue.project)
    add_field("Assignee", issue.assignee or "Unassigned")

    if issue.parent then
        add_field("Parent", issue.parent)
    end

    if issue.duedate then
        local due_display = atlassian_format.format_duedate(issue.duedate)
            .. " (" .. atlassian_format.format_duedate_relative(issue.duedate) .. ")"
        add_field("Due", due_display)
    end

    -- Separator
    table.insert(content, { type = "rule" })

    -- Description heading
    table.insert(content, {
        type = "heading",
        attrs = { level = 2 },
        content = { { type = "text", text = "Description" } },
    })

    -- Description content
    if issue.description_raw and type(issue.description_raw) == "table" and issue.description_raw.content then
        for _, node in ipairs(issue.description_raw.content) do
            table.insert(content, node)
        end
    elseif issue.description and issue.description ~= "" then
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = issue.description } },
        })
    else
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = "No description", marks = { { type = "em" } } } },
        })
    end

    -- Custom field sections
    for heading, _ in pairs(config.options.custom_fields or {}) do
        table.insert(content, { type = "rule" })
        table.insert(content, {
            type = "heading",
            attrs = { level = 2 },
            content = { { type = "text", text = heading } },
        })

        local raw = (issue.custom_fields_raw or {})[heading]
        if raw and type(raw) == "table" and raw.content then
            local adf = vim.deepcopy(raw)
            for _, node in ipairs(adf.content) do
                if node.type == "bulletList" then
                    node.type = "taskList"
                    for _, item in ipairs(node.content or {}) do
                        if item.type == "listItem" then
                            item.type = "taskItem"
                            item.attrs = item.attrs or {}
                            item.attrs.state = item.attrs.state or "TODO"
                        end
                    end
                end
                table.insert(content, node)
            end
        elseif raw and type(raw) == "string" and raw ~= "" then
            table.insert(content, {
                type = "paragraph",
                content = { { type = "text", text = raw } },
            })
        else
            table.insert(content, {
                type = "paragraph",
                content = { { type = "text", text = "No " .. heading:lower(), marks = { { type = "em" } } } },
            })
        end
    end

    -- Comments
    if issue.comments and #issue.comments > 0 then
        table.insert(content, { type = "rule" })
        table.insert(content, {
            type = "heading",
            attrs = { level = 2 },
            content = { { type = "text", text = "Comments (" .. #issue.comments .. ")" } },
        })

        for _, comment in ipairs(issue.comments) do
            local author_text = comment.author_name or "Unknown"
            local time_text = " · " .. atlassian_format.format_relative_time(comment.created)

            table.insert(content, {
                type = "paragraph",
                content = {
                    { type = "text", text = author_text, marks = { { type = "strong" } } },
                    { type = "text", text = time_text, marks = { { type = "em" } } },
                },
            })

            if comment.body and comment.body.content then
                for _, node in ipairs(comment.body.content) do
                    table.insert(content, node)
                end
            end
        end
    end

    -- Attachments
    if issue.attachments and #issue.attachments > 0 then
        table.insert(content, { type = "rule" })
        table.insert(content, {
            type = "heading",
            attrs = { level = 2 },
            content = { { type = "text", text = "Attachments (" .. #issue.attachments .. ")" } },
        })

        local items = {}
        for _, att in ipairs(issue.attachments) do
            local size = atlassian_format.format_file_size(att.size or 0)
            table.insert(items, {
                type = "listItem",
                content = { {
                    type = "paragraph",
                    content = {
                        { type = "text", text = att.filename, marks = { { type = "link", attrs = { href = att.url } } } },
                        { type = "text", text = " (" .. size .. ")" },
                    },
                } },
            })
        end
        table.insert(content, { type = "bulletList", content = items })
    end

    -- Footer
    table.insert(content, { type = "rule" })
    table.insert(content, {
        type = "paragraph",
        content = {
            { type = "text", text = "URL: ", marks = { { type = "strong" } } },
            { type = "text", text = issue.web_url, marks = { { type = "link", attrs = { href = issue.web_url } } } },
        },
    })
    table.insert(content, {
        type = "paragraph",
        content = { {
            type = "text",
            text = "Created: " .. atlassian_format.format_timestamp(issue.created)
                .. " (" .. atlassian_format.format_relative_time(issue.created) .. ")"
                .. "  ·  Updated: " .. atlassian_format.format_timestamp(issue.updated)
                .. " (" .. atlassian_format.format_relative_time(issue.updated) .. ")",
            marks = { { type = "em" } },
        } },
    })

    return { type = "doc", version = 1, content = content }
end

--- Show an issue using the ADF projection engine.
---@param issue JiraIssue
function M.show_issue_projected(issue)
    local display = vim.tbl_extend("force", config.options.display or {}, {})
    display.mode = "buffer"

    local buf, win = atlassian_ui.create_window({
        title = issue.key .. " - " .. issue.summary,
        bufname = "jira://" .. issue.key,
        display = display,
        filetype = "atlassian",
    })

    local adf = build_issue_adf(issue)

    local eb = editor.open(adf, {
        type = "jira",
        key = issue.key,
        project = issue.project,
    }, {
        buf = buf,
        win = win,
        modifiable = false,
    })

    -- Store attachment data for image resolution
    if issue.attachments and #issue.attachments > 0 then
        vim.b[buf].atlassian_attachments = issue.attachments
    end

    -- Keymaps for actions
    vim.keymap.set("n", "t", function()
        M.show_transition_picker(issue.key, issue.status)
    end, { buffer = buf, desc = "Transition status" })

    vim.keymap.set("n", "e", function()
        M.edit_issue_projected(issue.key)
    end, { buffer = buf, desc = "Edit issue" })

    vim.keymap.set("n", "s", function()
        M.show_children(issue.key)
    end, { buffer = buf, desc = "Show children / sub-tasks" })

    vim.keymap.set("n", "y", function()
        vim.fn.setreg("+", issue.key)
        notify.info("Copied: " .. issue.key)
    end, { buffer = buf, desc = "Copy issue key" })

    vim.keymap.set("n", "Y", function()
        local url = config.options.auth.url .. "/browse/" .. issue.key
        vim.fn.setreg("+", url)
        notify.info("Copied: " .. url)
    end, { buffer = buf, desc = "Copy issue URL" })

    vim.keymap.set("n", "?", function()
        vim.cmd("help atlassian-jira-keymaps")
    end, { buffer = buf, desc = "Show help" })

    local comments_mod = require("jira-interface.comments")
    vim.keymap.set("n", "c", function()
        comments_mod.add_comment(issue.key)
    end, { buffer = buf, desc = "Add comment" })

    vim.keymap.set("n", "C", function()
        comments_mod.fetch_and_select_comment(issue.key, "edit", function(comment)
            comments_mod.edit_comment(issue.key, comment)
        end)
    end, { buffer = buf, desc = "Edit comment" })

    vim.keymap.set("n", "D", function()
        comments_mod.fetch_and_select_comment(issue.key, "delete", function(comment)
            comments_mod.delete_comment(issue.key, comment)
        end)
    end, { buffer = buf, desc = "Delete comment" })

    local links_mod = require("jira-interface.links")
    vim.keymap.set("n", "L", function()
        links_mod.add_link(issue.key)
    end, { buffer = buf, desc = "Add issue link" })

    vim.keymap.set("n", "X", function()
        links_mod.fetch_and_delete_link(issue.key)
    end, { buffer = buf, desc = "Delete issue link" })

    vim.keymap.set("n", "a", function()
        M.show_assign_picker(issue.key, issue.project)
    end, { buffer = buf, desc = "Assign issue" })

    vim.keymap.set("n", "n", function()
        local picker = require("jira-interface.picker")
        picker.create_issue(nil, issue.project, issue.key)
    end, { buffer = buf, desc = "Create child issue" })

    atlassian_ui.setup_view_keymaps(buf)
end

M.show_issue = M.show_issue_projected

---@param key string
function M.view(key)
    api.get_issue(key, function(err, issue)
        if err then
            notify.error("Failed to fetch issue: " .. err)
            return
        end
        M.show_issue_projected(issue)
    end)
end

---@param key string
function M.show_transition_picker(key, current_status, on_success)
    api.get_transitions(key, function(err, transitions)
        if err then
            notify.error("Failed to get transitions: " .. err)
            return
        end

        if #transitions == 0 then
            notify.warn("No transitions available")
            return
        end

        local Snacks = require("snacks")
        local atlassian_ui = require("atlassian.ui")

        local picker_items = {}
        for i, t in ipairs(transitions) do
            local label
            if current_status then
                label = current_status .. " -> " .. t.to
            else
                label = t.name .. " -> " .. t.to
            end
            table.insert(picker_items, {
                idx = i,
                text = label,
                transition = t,
                label = label,
            })
        end

        local ms = atlassian_ui.multiselect(picker_items)
        local ms_actions = atlassian_ui.multiselect_actions(ms)

        Snacks.picker.pick({
            title = "Transition " .. key,
            items = picker_items,
            format = function(item, _picker)
                local ret = { { item.label, "Normal" } }
                return atlassian_ui.multiselect_indicator(ret, ms, item)
            end,
            confirm = function(picker, item)
                picker:close()
                local selected = ms.get_selected(item, "transition")
                if #selected > 0 then
                    local t = selected[#selected] -- use last selected transition
                    if api.is_online then
                        api.do_transition(key, t.id, function(trans_err)
                            if trans_err then
                                notify.error("Transition failed: " .. trans_err)
                            else
                                notify.info(string.format("%s -> %s", key, t.to))
                                if on_success then on_success(t.to) end
                            end
                        end)
                    else
                        local queue = require("jira-interface.queue")
                        queue.queue_transition(key, t.id, t.to)
                        if on_success then on_success(t.to) end
                    end
                end
            end,
            actions = ms_actions,
            layout = {
                layout = {
                    box = "vertical",
                    backdrop = false,
                    row = -1,
                    width = 0,
                    height = 0.3,
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
    end)
end

---@param key string
---@param project string
function M.show_assign_picker(key, project)
    api.get_project_members(project, function(err, members)
        if err then
            notify.error("Failed to get users: " .. err)
            return
        end

        local Snacks = require("snacks")
        local atlassian_ui = require("atlassian.ui")

        -- Build display items: Unassign first, then all assignable members
        local items = {}
        table.insert(items, {
            idx = 1,
            text = "Unassigned",
            display_name = "Unassigned",
            account_id = nil,
            member = { displayName = "Unassigned" },
        })
        for i, m in ipairs(members or {}) do
            table.insert(items, {
                idx = i + 1,
                text = m.displayName,
                display_name = m.displayName,
                account_id = m.accountId,
                member = m,
            })
        end

        local ms = atlassian_ui.multiselect(items)
        local ms_actions = atlassian_ui.multiselect_actions(ms)

        Snacks.picker.pick({
            title = "Assign " .. key,
            items = items,
            format = function(item, _picker)
                local ret = { { item.display_name, item.idx == 1 and "Comment" or "Normal" } }
                return atlassian_ui.multiselect_indicator(ret, ms, item)
            end,
            confirm = function(picker, item)
                picker:close()
                if not item then return end
                -- For assign, use the cursor item (multi-select doesn't make sense for assignment)
                local account_id = item.account_id
                local choice = item.display_name

                if api.is_online then
                    local effective_id = account_id or vim.NIL
                    api.assign_issue(key, effective_id, function(assign_err)
                        if assign_err then
                            notify.error("Assign failed: " .. assign_err)
                        else
                            local msg = account_id == nil and (key .. " unassigned") or (key .. " assigned to " .. choice)
                            notify.info(msg)
                            api.get_issue(key, function(fetch_err, fresh_issue)
                                if not fetch_err and fresh_issue then
                                    M.show_issue_projected(fresh_issue)
                                end
                            end)
                        end
                    end)
                else
                    local queue = require("jira-interface.queue")
                    local desc = account_id == nil and ("Unassign " .. key) or ("Assign " .. key .. " to " .. choice)
                    queue.queue_update(key, { assignee = { accountId = account_id } }, desc)
                end
            end,
            actions = ms_actions,
            layout = {
                layout = {
                    box = "vertical",
                    backdrop = false,
                    row = -1,
                    width = 0,
                    height = 0.3,
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
    end)
end

--- Build an editable ADF document from a JiraIssue (summary + description + custom fields only).
---@param issue JiraIssue
---@return table ADF document
---@return table section_map Maps ADF content indices to field names
local function build_edit_adf(issue)
    local content = {}
    local section_map = {} -- { [start_idx] = { field = "summary"|"description"|field_id, end_idx = N } }

    -- Summary as h1 (editable)
    table.insert(content, {
        type = "heading",
        attrs = { level = 1 },
        content = { { type = "text", text = issue.summary or "" } },
    })
    section_map[#content] = { field = "summary" }

    -- Description section
    table.insert(content, {
        type = "heading",
        attrs = { level = 2 },
        content = { { type = "text", text = "Description" } },
    })
    local desc_start = #content + 1

    if issue.description_raw and type(issue.description_raw) == "table" and issue.description_raw.content then
        for _, node in ipairs(issue.description_raw.content) do
            table.insert(content, node)
        end
    elseif issue.description and issue.description ~= "" then
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = issue.description } },
        })
    else
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = "" } },
        })
    end
    section_map[desc_start] = { field = "description", end_idx = #content }

    -- Custom field sections
    for heading, _ in pairs(config.options.custom_fields or {}) do
        table.insert(content, { type = "rule" })
        table.insert(content, {
            type = "heading",
            attrs = { level = 2 },
            content = { { type = "text", text = heading } },
        })
        local field_start = #content + 1

        local raw = (issue.custom_fields_raw or {})[heading]
        if raw and type(raw) == "table" and raw.content then
            local adf_copy = vim.deepcopy(raw)
            for _, node in ipairs(adf_copy.content) do
                if node.type == "bulletList" then
                    node.type = "taskList"
                    for _, item in ipairs(node.content or {}) do
                        if item.type == "listItem" then
                            item.type = "taskItem"
                            item.attrs = item.attrs or {}
                            item.attrs.state = item.attrs.state or "TODO"
                        end
                    end
                end
                table.insert(content, node)
            end
        elseif raw and type(raw) == "string" and raw ~= "" then
            table.insert(content, {
                type = "paragraph",
                content = { { type = "text", text = raw } },
            })
        else
            table.insert(content, {
                type = "paragraph",
                content = { { type = "text", text = "" } },
            })
        end

        local resolved_ids = (issue.custom_fields_raw or {})._resolved_ids or {}
        local field_id = resolved_ids[heading]
        if not field_id then
            local ref = (config.options.custom_fields or {})[heading]
            field_id = type(ref) == "table" and ref[1] or ref
        end
        if field_id then
            section_map[field_start] = { field = field_id, end_idx = #content }
        end
    end

    return { type = "doc", version = 1, content = content }, section_map
end

--- Extract only CHANGED fields from the edited ADF tree using the section map.
---@param adf table Current ADF document
---@param adf_snapshot table Original ADF snapshot
---@param section_map table
---@param original_issue JiraIssue
---@return table fields Map of field name/id → ADF value (only changed fields)
local function extract_edit_fields(adf, adf_snapshot, section_map, original_issue)
    local fields = {}
    local content = adf.content or {}
    local orig_content = adf_snapshot.content or {}

    for start_idx, section in pairs(section_map) do
        if section.field == "summary" then
            local node = content[start_idx]
            if node and node.content then
                local texts = {}
                for _, child in ipairs(node.content) do
                    if child.type == "text" then
                        texts[#texts + 1] = child.text or ""
                    end
                end
                local new_summary = table.concat(texts)
                if new_summary ~= original_issue.summary then
                    fields.summary = new_summary
                end
            end
        else
            local end_idx = section.end_idx or start_idx
            local section_content = {}
            local orig_section_content = {}
            for i = start_idx, end_idx do
                if content[i] then
                    table.insert(section_content, content[i])
                end
                if orig_content[i] then
                    table.insert(orig_section_content, orig_content[i])
                end
            end

            -- Only send if content actually changed
            local new_json = vim.json.encode(section_content)
            local orig_json = vim.json.encode(orig_section_content)
            if new_json ~= orig_json then
                local section_adf = { type = "doc", version = 1, content = section_content }
                fields[section.field] = bridge.sanitize_for_jira(section_adf)
            end
        end
    end

    return fields
end

---@param key string
function M.edit_issue_projected(key)
    api.get_issue(key, function(err, issue)
        if err then
            notify.error("Failed to fetch issue: " .. err)
            return
        end

        local display = vim.tbl_extend("force", config.options.display or {}, {})
        display.mode = "buffer"

        local buf, win = atlassian_ui.create_window({
            title = "Edit " .. key,
            bufname = "jira://" .. key .. "/edit",
            display = display,
            filetype = "atlassian",
        })

        local edit_adf, section_map = build_edit_adf(issue)

        local eb = editor.open(edit_adf, {
            type = "jira",
            key = key,
            project = issue.project,
            issue_type = issue.type,
        }, {
            buf = buf,
            win = win,
            modifiable = true,
        })

        if issue.attachments and #issue.attachments > 0 then
            vim.b[buf].atlassian_attachments = issue.attachments
        end

        local function do_submit()
            local fields = extract_edit_fields(eb.adf, eb.adf_snapshot, section_map, issue)

            if vim.tbl_isempty(fields) then
                notify.info("No changes to save")
                return
            end

            if api.is_online then
                api.update_issue(key, fields, function(update_err)
                    if update_err then
                        notify.error(notify.format_api_error(update_err, "updating " .. key))
                    else
                        local draft_mod = require("atlassian.editor.draft")
                        draft_mod.mark_clean(eb)

                        if vim.api.nvim_buf_is_valid(buf) then
                            vim.api.nvim_buf_delete(buf, { force = true })
                        end
                        cache.invalidate_project(issue.project)
                        api.get_issue(key, function(fetch_err, fresh_issue)
                            if fetch_err then
                                notify.info("Issue updated: " .. key)
                            else
                                notify.info("Issue updated: " .. key)
                                M.show_issue_projected(fresh_issue)
                            end
                        end)
                    end
                end)
            else
                local queue = require("jira-interface.queue")
                queue.queue_update(key, fields, "Update " .. key)
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end
        end

        require("atlassian.submit").register(buf, { submit = do_submit, label = "Jira Issue" })
    end)
end

M.edit_issue = M.edit_issue_projected

---@param parent_key string
function M.show_children(parent_key)
    api.get_children(parent_key, function(err, children)
        if err then
            notify.error("Failed to fetch children: " .. err)
            return
        end

        if #children == 0 then
            notify.info("No children found for " .. parent_key)
            return
        end

        local picker = require("jira-interface.picker")
        picker.show_issues(children, { title = "Children of " .. parent_key })
    end)
end

function M.show_queue()
    local queue = require("jira-interface.queue")
    local edits = queue.get_all()

    if #edits == 0 then
        notify.info("No pending edits in queue")
        return
    end

    local buf, win = create_window({ title = "Offline Queue", bufname = "jira://queue" })

    local lines = {
        "<h1>Offline Edit Queue</h1>",
        string.format("<p><strong>%d pending edit(s)</strong></p>", #edits),
    }

    for idx, edit in ipairs(edits) do
        table.insert(lines, string.format("<h2>%d. %s</h2>", idx, edit.description))
        table.insert(lines, string.format("<p>Type: %s</p>", edit.type))
        if edit.issue_key then
            table.insert(lines, string.format("<p>Issue: %s</p>", edit.issue_key))
        end
        table.insert(lines, string.format("<p>Queued: %s</p>", os.date("%Y-%m-%d %H:%M", edit.timestamp)))
    end

    table.insert(lines, "<hr />")
    table.insert(lines, "<p><strong>Actions:</strong> [s]ync all | [d]elete item | [c]lear all</p>")

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.keymap.set("n", "s", function()
        queue.sync_all(function(results)
            local success = 0
            local failed = 0
            for _, r in ipairs(results) do
                if r.success then
                    success = success + 1
                else
                    failed = failed + 1
                end
            end
            notify.info(string.format("Sync: %d succeeded, %d failed", success, failed))
        end)
    end, { buffer = buf, desc = "Sync all" })

    vim.keymap.set("n", "c", function()
        vim.ui.input({ prompt = "Clear all pending edits? (yes/no): " }, function(input)
            if input == "yes" then
                queue.clear()
                vim.api.nvim_win_close(win, true)
                notify.info("Queue cleared")
            end
        end)
    end, { buffer = buf, desc = "Clear all" })

    vim.keymap.set("n", "?", function()
        vim.cmd("help atlassian-jira-keymaps")
    end, { buffer = buf, desc = "Show help" })
end

function M.show_status()
    local queue = require("jira-interface.queue")
    local cache = require("jira-interface.cache")

    local cache_stats = cache.stats()
    local queue_count = queue.count()

    api.check_connectivity(function(online)
        local status = online and "Online" or "Offline"
        local icon = online and "" or ""

        local lines = {
            string.format("%s %s", icon, status),
            string.format("Cache: %d entries (%.1f KB)", cache_stats.entries, cache_stats.size_bytes / 1024),
            string.format("Queue: %d pending edit(s)", queue_count),
            string.format("Project: %s", config.options.default_project),
        }

        notify.info(table.concat(lines, "\n"))
    end)
end

return M
