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

vim.api.nvim_create_autocmd('User', {
    pattern = 'TSUpdate',
    callback = function()
        require('nvim-treesitter.parsers').csf = {
            install_info = {
                url = 'https://github.com/FoamScience/tree-sitter-csf',
                queries = 'queries/',
            },
        }
    end
})

-- Merge highlights + conceal queries into a single "highlights" query group
-- so vim.treesitter.start() picks everything up together
do
    local done = false
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'csf',
        once = true,
        callback = function()
            if done then return end
            done = true
            pcall(function()
                local sources = {}
                local seen = {}
                for _, group in ipairs({ 'highlights', 'conceal' }) do
                    for _, f in ipairs(vim.api.nvim_get_runtime_file('queries/csf/' .. group .. '.scm', true)) do
                        local content = table.concat(vim.fn.readfile(f), '\n')
                        content = content:gsub('^;; extends%s*\n?', '')
                        -- Deduplicate: skip if identical content already loaded
                        if content ~= '' and not seen[content] then
                            seen[content] = true
                            table.insert(sources, content)
                        end
                    end
                end
                if #sources > 0 then
                    vim.treesitter.query.set('csf', 'highlights', table.concat(sources, '\n'))
                    -- Clear standalone conceal query to prevent double application
                    -- by nvim-treesitter or Neovim's built-in treesitter modules
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
        if not require('nvim-treesitter.parsers').csf then
            vim.treesitter.start(buf, 'csf')
        end
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
