-- CSF (Confluence Storage Format) filetype detection and setup

-- Default @conceal highlight: link to Special instead of Comment (grey)
vim.api.nvim_set_hl(0, '@conceal.csf', { link = 'Special' })
vim.filetype.add({
    pattern = {
        ["csf://.*"] = "csf",
        ["confluence_storage:.*"] = "csf",
        ["confluence://.*"] = "csf",
        ["jira://.*"] = "csf",
    },
    extension = { csf = "csf" },
})

-- Defer all treesitter/parser work to first CSF buffer open
vim.api.nvim_create_autocmd('User', {
    pattern = 'TSUpdate',
    callback = function()
        local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
        if ok then
            parsers.csf = {
                install_info = {
                    url = 'https://github.com/FoamScience/tree-sitter-csf',
                    queries = 'queries/',
                },
            }
        end
    end,
})

-- Merge highlights + conceal into a single "highlights" query group.
-- Uses the plugin's own conceal.scm (with nerd font icons) instead of
-- the one from TSInstall.
do
    local done = false
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'csf',
        once = true,
        callback = function()
            if done then return end
            done = true

            -- Register parser with nvim-treesitter (deferred to first use)
            local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
            if ok then
                parsers.csf = {
                    install_info = {
                        url = 'https://github.com/FoamScience/tree-sitter-csf',
                        queries = 'queries/',
                    },
                }
            end

            -- Auto-install CSF parser if not already installed
            if not pcall(vim.treesitter.language.inspect, 'csf') then
                vim.cmd('TSInstall csf')
                return
            end

            pcall(function()
                local sources = {}
                local seen = {}
                -- Load highlights.scm from all runtimepaths
                for _, f in ipairs(vim.api.nvim_get_runtime_file('queries/csf/highlights.scm', true)) do
                    local content = table.concat(vim.fn.readfile(f), '\n')
                    content = content:gsub('^;; extends%s*\n?', '')
                    if content ~= '' and not seen[content] then
                        seen[content] = true
                        table.insert(sources, content)
                    end
                end
                -- Generate conceal queries dynamically from atlassian.icons
                -- (allows user customization via icons.setup())
                local dyn_ok, csf_queries = pcall(require, 'atlassian.csf.queries')
                if dyn_ok then
                    local dynamic = csf_queries.conceal()
                    if dynamic and dynamic ~= '' then
                        table.insert(sources, dynamic)
                    end
                end
                if #sources > 0 then
                    vim.treesitter.query.set('csf', 'highlights', table.concat(sources, '\n'))
                    vim.treesitter.query.set('csf', 'conceal', '')
                end
            end)
        end,
    })
end

vim.api.nvim_create_autocmd('FileType', {
    pattern = 'csf',
    callback = function(args)
        local buf = args.buf
        vim.treesitter.start(buf, 'csf')
        -- Buffer options
        vim.bo[buf].textwidth = 0
        -- Window options — defer to ensure window exists
        vim.schedule(function()
            local win = vim.fn.bufwinid(buf)
            if win == -1 then return end
            vim.wo[win].conceallevel = 2
            vim.wo[win].concealcursor = ""
            vim.wo[win].wrap = true
            vim.wo[win].linebreak = true
        end)
        -- Attach input translation for CSF buffers
        local ok, csf_input = pcall(require, 'atlassian.csf.input')
        if ok then
            csf_input.setup_buffer(buf)
        end
        -- Image hover (CursorHold) + K keymap
        local img_ok, csf_image = pcall(require, 'atlassian.csf.image')
        if img_ok then
            csf_image.setup_hover(buf)
            vim.keymap.set("n", "K", function()
                csf_image.show_at_cursor(buf)
            end, { buffer = buf, desc = "Show image at cursor" })
        end
        -- Math rendering (LaTeX → unicode via latex2text)
        local math_ok, csf_math = pcall(require, 'atlassian.csf.math')
        if math_ok then
            csf_math.setup(buf)
        end
        -- Slash command interactive keymap
        local int_ok, interactive = pcall(require, 'atlassian.slash_commands.interactive')
        if int_ok then
            interactive.setup_keymap(buf)
        end
    end,
})
