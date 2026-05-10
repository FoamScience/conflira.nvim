-- conflira.nvim — protocol handlers and filetype detection

-- Protocol handlers: :edit jira://PROJ-123 or :edit confluence://12345
vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "jira://*",
    callback = function(args)
        local uri = args.file or ""
        local key = uri:match("^jira://([^/]+)")
        if not key then return end

        local is_edit = uri:match("/edit$") ~= nil
        local ok, jira_ui = pcall(require, "jira-interface.ui")
        if not ok then return end

        vim.bo[args.buf].buftype = "nofile"

        if is_edit then
            jira_ui.edit_issue_projected(key)
        else
            jira_ui.view(key)
        end
    end,
})

vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "confluence://*",
    callback = function(args)
        local uri = args.file or ""
        local page_id = uri:match("^confluence://([^/]+)")
        if not page_id then return end

        local is_edit = uri:match("/edit$") ~= nil
        local ok, conf_ui = pcall(require, "confluence-interface.ui")
        if not ok then return end

        vim.bo[args.buf].buftype = "nofile"

        if is_edit then
            conf_ui.edit_page_projected(page_id)
        else
            conf_ui.view_page(page_id)
        end
    end,
})
