-- CSF (Confluence Storage Format) filetype detection and setup
vim.filetype.add({
    pattern = {
        ["csf://.*"] = "csf",
        ["confluence_storage:.*"] = "csf",
        ["confluence://.*"] = "csf",
        ["jira://.*"] = "csf",
    },
    extension = { csf = "csf" },
})

-- Register CSF parser with nvim-treesitter immediately and on TSUpdate
local function register_csf_parser()
    local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
    if ok then
        parsers.csf = {
            install_info = {
                url = 'https://github.com/FoamScience/tree-sitter-csf',
                queries = 'queries/',
            },
        }
    end
end

register_csf_parser()

vim.api.nvim_create_autocmd('User', {
    pattern = 'TSUpdate',
    callback = register_csf_parser,
})

-- Auto-install CSF parser if not already installed
vim.defer_fn(function()
    if not pcall(vim.treesitter.language.inspect, 'csf') then
        register_csf_parser()
        vim.cmd('TSInstall csf')
    end
end, 100)

-- Set up conceal queries: merge static conceal.scm + dynamic icon-based queries
-- into the "conceal" query group. Highlights stay separate in "highlights" group.
do
    local done = false
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'csf',
        once = true,
        callback = function()
            if done then return end
            done = true
            pcall(function()
                -- Build conceal query from static files + dynamic icon queries
                local conceal_sources = {}
                local seen = {}
                for _, f in ipairs(vim.api.nvim_get_runtime_file('queries/csf/conceal.scm', true)) do
                    local content = table.concat(vim.fn.readfile(f), '\n')
                    content = content:gsub('^;; extends%s*\n?', '')
                    if content ~= '' and not seen[content] then
                        seen[content] = true
                        table.insert(conceal_sources, content)
                    end
                end
                -- Append dynamically generated conceal queries with nerd font icons
                local dyn_ok, csf_queries = pcall(require, 'atlassian.csf.queries')
                if dyn_ok then
                    local dynamic = csf_queries.conceal()
                    if dynamic and dynamic ~= '' then
                        table.insert(conceal_sources, dynamic)
                    end
                end
                if #conceal_sources > 0 then
                    vim.treesitter.query.set('csf', 'conceal', table.concat(conceal_sources, '\n'))
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
            vim.wo[win].concealcursor = "nc"
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
