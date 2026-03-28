# atlassian.nvim

A Neovim plugin for Jira and Confluence integration with rich CSF (Confluence Storage Format) editing, offline support, and agile board views.

## Requirements

### Required

- Neovim >= 0.11.4
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) — **required** for syntax highlighting, concealing, and CSF editing. The [tree-sitter-csf](https://github.com/FoamScience/tree-sitter-csf) grammar is auto-installed on first use via `:TSInstall csf`
- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker UI, notifications, and image display
- `curl` — HTTP requests to Jira/Confluence REST APIs

### Optional

| Dependency | Purpose |
|---|---|
| [blink.cmp](https://github.com/saghen/blink.cmp) | Completion providers for Jira issue keys, Confluence page links, and CSF slash commands |
| [todo-comments.nvim](https://github.com/folke/todo-comments.nvim) | Required by `:JiraTodoToIssue` to scan buffers/projects for TODO comments and convert them to Jira issues |
| `latex2text` ([pylatexenc](https://pypi.org/project/pylatexenc/)) | LaTeX-to-unicode rendering for math blocks and inline equations in CSF buffers. Install with `pip install pylatexenc` |
| Image-capable terminal | Required for inline image display in CSF buffers (`K` keymap). Supported terminals: [Kitty](https://sw.kovidgoyal.net/kitty/), [WezTerm](https://wezfurlong.org/wezterm/), [iTerm2](https://iterm2.com/), [Ghostty](https://ghostty.org/) |

## Setup

```lua
-- lazy.nvim
{
    "FoamScience/atlassian.nvim",
    dependencies = { "folke/snacks.nvim" },
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

Override default icons to match your theme:

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
    "FoamScience/atlassian.nvim",
    dependencies = {
        "folke/snacks.nvim",
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
            custom_fields = {},       -- Map of section heading -> Jira field ID
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
            -- Templates: expanded as LuaSnip snippets in issue create buffers
            templates = {
                default = {
                    description_sections = {},
                    acceptance_criteria = { "Criteria" },
                },
                epic = {
                    description_sections = {
                        { heading = "Overview", placeholder = "High-level overview" },
                        { heading = "Goals", placeholder = "Goals" },
                        { heading = "Scope", placeholder = "Scope" },
                    },
                    acceptance_criteria = { "All child features completed", "Documentation updated" },
                },
                feature = {
                    description_sections = {
                        { heading = "Problem", placeholder = "Describe the problem" },
                        { heading = "Solution", placeholder = "Proposed solution" },
                        { heading = "Technical Notes", placeholder = "Technical details" },
                    },
                    acceptance_criteria = { "Implementation complete", "Tests passing", "Code reviewed" },
                },
                bug = {
                    description_sections = {
                        { heading = "Steps to Reproduce", placeholder = "1. First step" },
                        { heading = "Expected Behavior", placeholder = "Expected behavior" },
                        { heading = "Actual Behavior", placeholder = "Actual behavior" },
                        { heading = "Environment", placeholder = "Environment details" },
                    },
                    acceptance_criteria = { "Bug fixed", "Tests added", "No regression" },
                },
                task = {
                    description_sections = {},
                    acceptance_criteria = { "Task completed", "Verified working" },
                },
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

## Features

### Jira

#### Search and Navigation

| Command | Description |
|---|---|
| `:JiraSearch` | Search all issues |
| `:JiraMe` | Issues assigned to me |
| `:JiraCreatedByMe` | Issues I created |
| `:JiraAssignedNotCreated` | Assigned to me but created by others |
| `:JiraProject [name]` | Filter by project |
| `:JiraEpics` | Browse Epics |
| `:JiraFeatures` | Browse Features / Bugs / Issues |
| `:JiraTasks` | Browse Tasks |
| `:JiraDue [overdue\|today\|week\|soon]` | Filter by due date |

#### Issue Management

| Command | Description |
|---|---|
| `:JiraView [key]` | View issue details |
| `:JiraEdit [key]` | Edit issue in CSF buffer |
| `:JiraSearchEdit` | Search and edit |
| `:JiraCreate [type]` | Create new issue |
| `:JiraQuick <summary>` | Quick-create Sub-Task under branch issue |

#### Status Transitions

| Command | Description |
|---|---|
| `:JiraTransition [key]` | Pick a transition |
| `:JiraStart [key]` | Move to In Progress |
| `:JiraReview [key]` | Move to In Review |
| `:JiraDone [key]` | Move to Done |

#### Comments and Links

| Command | Description |
|---|---|
| `:JiraComment add\|edit\|delete [key]` | Manage comments |
| `:JiraLink add\|delete [key]` | Manage issue links |

#### JQL Filters

| Command | Description |
|---|---|
| `:JiraFilter save [name]` | Save current JQL filter |
| `:JiraFilter load` | Load a saved filter |
| `:JiraFilter list` | List saved filters |
| `:JiraFilter delete` | Delete a saved filter |

#### Agile Boards

| Command | Description |
|---|---|
| `:JiraBoard [board_id]` | Kanban board view |
| `:JiraSprint [board_id]` | Sprint board view |
| `:JiraTeam [project]` | Team workload dashboard |

#### Offline Queue

| Command | Description |
|---|---|
| `:JiraQueue` | View pending offline edits |
| `:JiraSync` | Sync queued edits to Jira |

Edits are automatically queued when Jira is unreachable and synced on reconnect. Supports queued updates, transitions, comments, and issue creation.

#### Utilities

| Command | Description |
|---|---|
| `:JiraTodoToIssue [buffer\|project]` | Convert TODO comments to Sub-Tasks |
| `:JiraRefresh` | Clear cache |
| `:JiraStatus` | Show connection status |
| `:JiraFields [key]` | Inspect issue fields |
| `:JiraTypes [project]` | List issue types |

### Confluence

#### Navigation

| Command | Description |
|---|---|
| `:ConfluenceSpaces` | List spaces |
| `:ConfluencePages [space_key]` | List pages in space |
| `:ConfluenceRecent` | Recently updated pages |

#### Search

| Command | Description |
|---|---|
| `:ConfluenceSearch [query]` | Search pages |
| `:ConfluenceSearchEdit [query]` | Search and edit |
| `:ConfluenceSearchCQL [query]` | Raw CQL search |
| `:ConfluenceMentions [user]` | Pages mentioning a user |

#### Page Management

| Command | Description |
|---|---|
| `:ConfluenceView <page_id>` | View page |
| `:ConfluenceEdit <page_id>` | Edit page in CSF buffer |
| `:ConfluenceCreate [space_key]` | Create new page |
| `:ConfluenceDelete <page_id>` | Delete page (with confirmation) |

#### CQL Filters

| Command | Description |
|---|---|
| `:ConfluenceCQLFilter save\|load\|list\|delete [name]` | Manage saved CQL filters |

#### Utilities

| Command | Description |
|---|---|
| `:ConfluenceRefresh` | Clear cache |
| `:ConfluenceStatus` | Show connection status |

### CSF Rich Editing

Both Jira and Confluence content is edited in CSF buffers with:

- **Treesitter highlighting** via [tree-sitter-csf](https://github.com/FoamScience/tree-sitter-csf) (auto-installed)
- **Smart concealing** of XML tags with nerd font icons
- **Image hover** on `K` keypress or CursorHold
- **LaTeX math rendering** (block and inline equations converted to unicode)
- **Slash commands** for inserting formatted content (type `/` at line start)

#### Slash Commands

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
