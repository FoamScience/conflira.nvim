# conflira.nvim

> Disclaimer; This plugin is an unofficial effort to remove some of the pain of working with a web app
> on Jira issues. This is not affiliated to Atlassian in any way.

A Neovim plugin for Jira and Confluence integration with rich CSF (Confluence Storage Format) editing, offline support, and agile board views.

## Requirements

### Required

- Neovim >= 0.11.4
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) — **required** for syntax highlighting, concealing, and CSF editing. The [tree-sitter-csf](https://github.com/FoamScience/tree-sitter-csf) grammar is auto-installed on first use via `:TSInstall csf`
- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker UI, notifications, and image display
- [nui-components.nvim](https://github.com/grapp-dev/nui-components.nvim) — UI components for interactive views
- `curl` — HTTP requests to Jira/Confluence REST APIs
- A nerd font that has some ligatures support. You can get some with [getnf](https://github.com/getnf/getnf)
- An Atlassian API token

### Optional
- [blink.cmp](https://github.com/saghen/blink.cmp) - Completion providers for Jira issue keys, Confluence page links, and CSF slash commands
- [todo-comments.nvim](https://github.com/folke/todo-comments.nvim) - Required by `:JiraTodoToIssue` to scan buffers/projects for TODO comments and convert them to Jira issues
- `latex2text` ([pylatexenc](https://pypi.org/project/pylatexenc/)) - LaTeX-to-unicode rendering for math blocks and inline equations in CSF buffers. Install with `uv tool install pylatexenc`
- Image-capable terminal - Required for inline image display in CSF buffers. Supported terminals: [Kitty](https://sw.kovidgoyal.net/kitty/), [WezTerm](https://wezfurlong.org/wezterm/), [iTerm2](https://iterm2.com/), [Ghostty](https://ghostty.org/)

## Setup

```lua
-- lazy.nvim
-- entry points are split into jira-interface and confluence-interface
{
    "FoamScience/conflira.nvim",
    dependencies = { "folke/snacks.nvim", "grapp-dev/nui-components.nvim" },
    config = function()
        require("jira-interface").setup({
            auth = {
                url = vim.env.JIRA_URL,
                email = vim.env.JIRA_EMAIL,
                token = vim.env.JIRA_API_TOKEN,
            },
            default_project = vim.env.JIRA_PROJECT,
        })

        require("confluence-interface").setup({
            auth = {
                url = vim.env.CONFLUENCE_URL or vim.env.JIRA_URL,
                email = vim.env.CONFLUENCE_EMAIL or vim.env.JIRA_EMAIL,
                token = vim.env.CONFLUENCE_API_TOKEN or vim.env.JIRA_API_TOKEN,
            },
            default_space = vim.env.CONFLUENCE_SPACE,
        })
    end,
}
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `JIRA_URL` | Yes | Jira instance URL |
| `JIRA_EMAIL` | Yes | User email |
| `JIRA_API_TOKEN` | Yes | API token |
| `JIRA_PROJECT` | No | Default project key |
| `CONFLUENCE_URL` | No | Confluence URL (falls back to `JIRA_URL`) |
| `CONFLUENCE_EMAIL` | No | Falls back to `JIRA_EMAIL` |
| `CONFLUENCE_API_TOKEN` | No | Falls back to `JIRA_API_TOKEN` |
| `CONFLUENCE_SPACE` | No | Default space key |

### Completion Providers (blink.cmp)

Register the built-in completion providers for issue keys, page links, and slash commands:

```lua
sources = {
    per_filetype = {
        gitcommit = { 'jira', 'confluence' },
        csf = { 'slash_commands', 'jira', 'confluence' },
        atlassian_jira = { 'slash_commands', 'jira', 'confluence' },
        atlassian_confluence = { 'slash_commands', 'jira', 'confluence' },
    },
    providers = {
        jira = { module = "atlassian-cmp.jira", min_keyword_length = 2 },
        confluence = { module = "atlassian-cmp.confluence", min_keyword_length = 2 },
        slash_commands = { module = "atlassian-cmp.slash_commands", min_keyword_length = 1 },
    },
}
```

### Icon Overrides

Override default icons to match your theme, or proxy to some other icons package:

```lua
require("atlassian.icons").setup({
    ui = { Heading1 = "# ", Heading2 = "## " },
    kind = { Reference = " " },
})
```

### Sample Configuration

<details>
<summary>Full configuration with all options and defaults</summary>

```lua
-- lazy.nvim
{
    "FoamScience/conflira.nvim",
    dependencies = {
        "folke/snacks.nvim",
        "grapp-dev/nui-components.nvim",
        "nvim-treesitter/nvim-treesitter",
    },
    config = function()
        -- Jira setup (all options shown with defaults)
        require("jira-interface").setup({
            auth = {
                url = vim.env.JIRA_URL or "",
                email = vim.env.JIRA_EMAIL or "",
                token = vim.env.JIRA_API_TOKEN or "",
            },
            default_project = vim.env.JIRA_PROJECT or "",
            cache_ttl = 300,          -- Cache time-to-live in seconds
            max_results = 500,        -- Max issues per query
            since = "-365d",          -- Filter by creation date ("-365d", "-30d", nil to disable)
            types = {
                lvl1 = { "Epic" },
                lvl2 = { "Feature", "Bug", "Issue" },
                lvl3 = { "Task" },
                lvl4 = { "Sub-Task" },
            },
            statuses = {
                "To Do",
                "In Progress",
                "In Review",
                "Blocked",
                "Done",
            },
            custom_fields = {},       -- Map of section heading -> Jira field ID @deprecated
            data_dir = vim.fn.stdpath("data") .. "/jira-interface",
            display = {
                mode = "float",       -- "float", "vsplit", "split", "tab"
                width = "80%",        -- number (columns) or string ("80%")
                height = "80%",       -- number (lines) or string ("80%")
                border = "rounded",   -- "none", "single", "double", "rounded", "solid", "shadow"
                wrap = true,
                linebreak = true,
                conceallevel = 2,
                cursorline = true,
            },
            image = {
                enabled = true,
                max_file_size = 2 * 1024 * 1024,  -- 2MB
                auto_preview = false,              -- true = CursorHold preview
                cache_dir = vim.fn.stdpath("cache") .. "/atlassian/images",
            },
            math = {
                enabled = true,
                block_macro = "mathblock",
                inline_macro = "mathinline",
                inline_param = "body",
            },
            templates = {}, -- @deprecated
            hunks = {
                enabled = true,           -- set to false to disable :JiraHunks
                refresh_debounce = 500,   -- ms to wait after save before refreshing
            },
        })

        -- Confluence setup (all options shown with defaults)
        require("confluence-interface").setup({
            auth = {
                url = vim.env.CONFLUENCE_URL or vim.env.JIRA_URL or "",
                email = vim.env.CONFLUENCE_EMAIL or vim.env.JIRA_EMAIL or "",
                token = vim.env.CONFLUENCE_API_TOKEN or vim.env.JIRA_API_TOKEN or "",
            },
            default_space = vim.env.CONFLUENCE_SPACE or "",
            cache_ttl = 300,
            max_results = 100,
            data_dir = vim.fn.stdpath("data") .. "/confluence-interface",
            display = {
                mode = "float",
                width = "80%",
                height = "80%",
                border = "rounded",
                wrap = true,
                linebreak = true,
                conceallevel = 2,
                cursorline = true,
            },
            image = {
                enabled = true,
                max_file_size = 2 * 1024 * 1024,
                auto_preview = false,
                cache_dir = vim.fn.stdpath("cache") .. "/atlassian/images",
            },
            math = {
                enabled = true,
                block_macro = "mathblock",
                inline_macro = "mathinline",
                inline_param = "body",
            },
        })
    end,
}
```

</details>

### Recommended Keybindings

<details>
<summary>which-key.nvim keybindings for Jira and Confluence</summary>

```lua
-- Jira keybindings (<leader>j)
{ "<leader>j",  group = "Jira" },
{ "<leader>jj", "<cmd>JiraSearch<cr>",       desc = "Search issues" },
{ "<leader>jm", "<cmd>JiraMe<cr>",           desc = "Assigned to me" },
{ "<leader>jc", "<cmd>JiraCreatedByMe<cr>",  desc = "Created by me" },
{ "<leader>jp", "<cmd>JiraProject<cr>",      desc = "By project" },
{ "<leader>jd", "<cmd>JiraDue<cr>",          desc = "By due date" },
{ "<leader>je", "<cmd>JiraEpics<cr>",        desc = "Epics" },
{ "<leader>jf", "<cmd>JiraFeatures<cr>",     desc = "Features/Bugs" },
{ "<leader>jt", "<cmd>JiraTasks<cr>",        desc = "Tasks" },
{ "<leader>jn", "<cmd>JiraCreate<cr>",       desc = "New issue" },
{ "<leader>jr", "<cmd>JiraRefresh<cr>",      desc = "Refresh cache" },
{ "<leader>js", "<cmd>JiraStatus<cr>",       desc = "Status" },
{ "<leader>jw", "<cmd>JiraTeam<cr>",         desc = "Team workload" },
{ "<leader>jb", "<cmd>JiraBoard<cr>",        desc = "Board view" },
{ "<leader>jS", "<cmd>JiraSprint<cr>",       desc = "Sprint view" },
{ "<leader>jT", "<cmd>JiraTodoToIssue<cr>",  desc = "TODO to Sub-Task" },
{ "<leader>jJ", "<cmd>JiraSearchEdit<cr>",   desc = "Search & edit" },

-- Confluence keybindings (<leader>c)
{ "<leader>c",  group = "Confluence" },
{ "<leader>cc", "<cmd>ConfluenceSearch<cr>",     desc = "Search pages" },
{ "<leader>cs", "<cmd>ConfluenceSpaces<cr>",     desc = "List spaces" },
{ "<leader>cp", "<cmd>ConfluencePages<cr>",      desc = "Pages in space" },
{ "<leader>cr", "<cmd>ConfluenceRecent<cr>",     desc = "Recent pages" },
{ "<leader>cn", "<cmd>ConfluenceCreate<cr>",     desc = "New page" },
{ "<leader>cq", "<cmd>ConfluenceSearchCQL<cr>",  desc = "CQL search" },
{ "<leader>cf", "<cmd>ConfluenceCQLFilter<cr>",  desc = "CQL filters" },
{ "<leader>cR", "<cmd>ConfluenceRefresh<cr>",    desc = "Refresh cache" },
{ "<leader>cS", "<cmd>ConfluenceStatus<cr>",     desc = "Status" },
{ "<leader>cC", "<cmd>ConfluenceSearchEdit<cr>", desc = "Search & edit" },
```

To avoid circular dependency when checking plugin availability, use runtimepath checks instead of `pcall(require, ...)`:

```lua
local jira_ok = vim.env.JIRA_API_TOKEN
    and #vim.api.nvim_get_runtime_file("lua/jira-interface/init.lua", false) > 0
if jira_ok then
    -- register Jira keybindings
end
```

</details>

## Features

### Jira

- [x] Extensive help documents (`:help atlassian-jira`)
- [x] Search and Navigate your spaces; command shortcuts for assigned-to-me (`:JiraMe`), created-by-me (`:JiraCreatedByMe`),
  assigned-but-not-created-by-me (`:JiraAssignedNotCreated`)
- [x] Commands targeting specific issue levels (epics, features, tasks)
- [x] Edit, view and create new Jira issues; auto-populating buffers from Jira templates
- [x] Transition Jira issues
- [x] Manage issue links, and edit/add comments on issues
- [x] Custom JQL filters management through `:JiraFilter` (if the above isn't enough)
- [x] Agile Boards support (eg. `:JiraBoard` and `:JitaTeams`)
- [x] Offline Queue and sync later
- [x] Git Hunk Tracking (`:JiraHunks`)

### Git Hunk Tracking

Track your unstaged and staged changes in a quickfix list, tied to a Jira issue. Works across multiple repositories.

```
:JiraHunks PROJ-123                    " track changes in cwd
:JiraHunks PROJ-123 ~/repo1 ~/repo2   " track changes across repos
:JiraHunks                             " pick issue from branch or picker
:JiraHunksStop                         " stop auto-refresh
```

The quickfix list auto-refreshes on file save (debounced). Committed changes automatically disappear from the list.

To disable this feature:

```lua
require("jira-interface").setup({
    hunks = { enabled = false },
})
```

The debounce interval (default 500ms) is configurable:

```lua
require("jira-interface").setup({
    hunks = { refresh_debounce = 1000 },
})
```

### Confluence

- Search and navigate spaces, including getting pages which mention a user
- Custom JQL filters support
- Edit, view and create new confluence pages

### CSF Rich Editing

> [!IMPORTANT]
> I'm still figuring this section out, so expect frequent changes here.
> Mainly, conceals get in the way of efficient vim-style editing, but it is
> not interesting to look at XML content - so a good comprise must be found
>
> Current behavior: conceals are turned off for the line where the cursor is.

Both Jira and Confluence content is edited in CSF (XML-like) buffers with:

- **Treesitter highlighting** via [tree-sitter-csf](https://github.com/FoamScience/tree-sitter-csf) (auto-installed)
- **Smart concealing** of XML tags with nerd font icons
- **Image hover** on `K` keypress or `CursorHold` event
- **LaTeX math rendering** (block and inline equations converted to unicode)
- **Slash commands** for inserting formatted content (type `/` at line start)

#### Slash Commands
> Some of these are tested more often than others, open issues if you encounter
> any strange behavior

| Command | Category | Description |
|---|---|---|
| `/Heading 1-6` | Formatting | Insert headings |
| `/Divider` | Formatting | Horizontal rule |
| `/Quote` | Formatting | Block quote |
| `/Code block` | Code | Fenced code block with language |
| `/Info panel` | Panels | Blue information panel |
| `/Note panel` | Panels | Yellow note panel |
| `/Warning panel` | Panels | Red warning panel |
| `/Tip panel` | Panels | Green tip/success panel |
| `/Table` | Structure | Insert table |
| `/Expand` | Structure | Expandable/collapsible section |
| `/Task list` | Structure | Checkbox list |
| `/Bullet list` | Structure | Bulleted list |
| `/Numbered list` | Structure | Numbered list |
| `/Mention` | Media | Mention a user (interactive) |
| `/Page link` | Media | Link to Confluence page (interactive) |
| `/Jira issue` | Media | Link to Jira issue (interactive) |
| `/External link` | Media | External hyperlink |
| `/Upload` | Media | Upload file attachment (interactive) |
| `/Date` | Inline | Insert date |
| `/Status` | Inline | Colored status lozenge (interactive) |
| `/Math block` | Math | Block LaTeX equation |
| `/Math inline` | Math | Inline LaTeX equation |

### Health Check

Run `:checkhealth jira-interface` to verify:
- Configuration (URL, email, token)
- Dependencies (curl, snacks.nvim)
- API connectivity (authentication, projects, search)
- Cache and offline queue status

## License

MIT
