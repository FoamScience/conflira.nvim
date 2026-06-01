-- JiraHunks: live quickfix list of working changes for a Jira issue
-- Tracks unstaged + staged hunks across multiple repositories
local notify = require("jira-interface.notify")

local M = {}

local state = {
    issue_key = nil,
    repo_paths = {},
    augroup = nil,
    timer = nil,
}

---@param raw_diff string Output of git diff HEAD --unified=0
---@param repo_path string Repository root path
---@return {filename:string, lnum:number, col:number, text:string}[]
function M.parse_diff(raw_diff, repo_path)
    local items = {}
    local current_file = nil

    for _, line in ipairs(vim.split(raw_diff, "\n")) do
        -- File header: +++ b/path/to/file
        local file_path = line:match("^%+%+%+ b/(.*)")
        if file_path then
            current_file = repo_path .. "/" .. file_path
        end

        -- Hunk header: @@ -old_start[,count] +new_start[,count] @@ [context]
        if current_file then
            local new_start, new_count, ctx = line:match("^@@ .* %+(%d+),?(%d*) @@ ?(.*)")
            if new_start then
                local count = tonumber(new_count) or 1
                local text = count > 0 and ("+" .. count .. " lines") or "-lines"
                if ctx and ctx ~= "" then
                    text = text .. ": " .. ctx
                end
                table.insert(items, {
                    filename = current_file,
                    lnum = tonumber(new_start),
                    col = 0,
                    text = text,
                })
            end
        end
    end

    return items
end

---@param callback fun(items: {filename:string, lnum:number, col:number, text:string}[])
local function collect_hunks(callback)
    local all_items = {}
    local pending = #state.repo_paths
    if pending == 0 then
        callback({})
        return
    end

    for _, repo_path in ipairs(state.repo_paths) do
        vim.system(
            { "git", "-C", repo_path, "diff", "HEAD", "--unified=0", "--no-color" },
            { text = true },
            function(result)
                vim.schedule(function()
                    if result.code == 0 and result.stdout and result.stdout ~= "" then
                        local items = M.parse_diff(result.stdout, repo_path)
                        vim.list_extend(all_items, items)
                    end
                    pending = pending - 1
                    if pending == 0 then
                        callback(all_items)
                    end
                end)
            end
        )
    end
end

--- Refresh the quickfix list with current hunks (no jump, no copen on refresh)
---@param open_qf? boolean Whether to open the quickfix window (true on first call)
function M.refresh(open_qf)
    collect_hunks(function(items)
        local title = (state.issue_key or "hunks") .. " (" .. #items .. " hunks)"
        vim.fn.setqflist({}, "r", { title = title, items = items })
        if open_qf and #items > 0 then
            vim.cmd("copen")
        end
    end)
end

--- Start tracking working changes for a Jira issue
---@param issue_key string
---@param repo_paths string[]
function M.show_hunks(issue_key, repo_paths)
    -- Clear previous state
    M.stop()

    state.issue_key = issue_key
    state.repo_paths = repo_paths

    notify.progress_start("hunks", "Scanning hunks for " .. issue_key)

    collect_hunks(function(items)
        notify.progress_finish("hunks")

        local title = issue_key .. " (" .. #items .. " hunks)"
        vim.fn.setqflist({}, "r", { title = title, items = items })

        if #items == 0 then
            notify.info("No working changes found for " .. issue_key)
            return
        end

        notify.info(issue_key .. ": " .. #items .. " hunk(s) across "
            .. #state.repo_paths .. " repo(s)")
        vim.cmd("copen")

        -- Set up auto-refresh on file save
        state.augroup = vim.api.nvim_create_augroup("jira_hunks_refresh", { clear = true })
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = state.augroup,
            callback = function()
                if state.timer then
                    vim.fn.timer_stop(state.timer)
                end
                local config = require("jira-interface.config")
                local debounce = (config.options.hunks and config.options.hunks.refresh_debounce) or 500
                state.timer = vim.fn.timer_start(debounce, function()
                    state.timer = nil
                    M.refresh(false)
                end)
            end,
        })
    end)
end

--- Stop tracking and clear autocmds
function M.stop()
    if state.augroup then
        vim.api.nvim_del_augroup_by_id(state.augroup)
        state.augroup = nil
    end
    if state.timer then
        vim.fn.timer_stop(state.timer)
        state.timer = nil
    end
    state.issue_key = nil
    state.repo_paths = {}
end

return M
