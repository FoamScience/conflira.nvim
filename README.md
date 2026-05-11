# conflira.nvim

> Disclaimer; This plugin is an unofficial effort to remove some of the pain of working with a web app
> on Jira issues. This is not affiliated to Atlassian in any way.

A Neovim plugin for Jira and Confluence with an ADF projection editor, outline board, and offline support.

## Requirements

### Required

- Neovim >= 0.11.4
- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker UI and notifications
- `curl` — HTTP requests to Jira/Confluence REST APIs
- A nerd font with ligatures support. You can get some with [getnf](https://github.com/getnf/getnf)
- An Atlassian API token

### Optional
- [3rd/image.nvim](https://github.com/3rd/image.nvim) or [snacks.image](https://github.com/folke/snacks.nvim) — image and PDF preview in floating windows
- [blink.cmp](https://github.com/saghen/blink.cmp) — completion providers for Jira issue keys and Confluence page links
- [todo-comments.nvim](https://github.com/folke/todo-comments.nvim) — required by `:JiraTodoToIssue`
- ImageMagick (`magick` or `convert`) — PDF first-page preview
- Image-capable terminal — [Kitty](https://sw.kovidgoyal.net/kitty/), [WezTerm](https://wezfurlong.org/wezterm/), [iTerm2](https://iterm2.com/), [Ghostty](https://ghostty.org/)

## Setup

```lua
-- lazy.nvim
{
    "FoamScience/conflira.nvim",
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

```lua
sources = {
    per_filetype = {
        gitcommit = { 'jira', 'confluence' },
        atlassian = { 'jira', 'confluence' },
    },
    providers = {
        jira = { module = "atlassian-cmp.jira", min_keyword_length = 2 },
        confluence = { module = "atlassian-cmp.confluence", min_keyword_length = 2 },
    },
}
```

### Recommended Keybindings

<details>
<summary>which-key.nvim keybindings for Jira and Confluence</summary>

```lua
-- Jira keybindings (<leader>j)
{ "<leader>j",  group = "Jira" },
{ "<leader>jj", "<cmd>JiraSearch<cr>",       desc = "Search issues" },
{ "<leader>jb", "<cmd>JiraBoard<cr>",        desc = "Board (my work)" },
{ "<leader>jn", "<cmd>JiraCreate<cr>",       desc = "New issue" },
{ "<leader>jr", "<cmd>JiraRefresh<cr>",      desc = "Refresh cache" },
{ "<leader>js", "<cmd>JiraStatus<cr>",       desc = "Status" },
{ "<leader>jT", "<cmd>JiraTodoToIssue<cr>",  desc = "TODO to issue" },
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
```

</details>

## Features

### ADF Projection Editor

Issues and pages are edited using an ADF (Atlassian Document Format) projection engine. The ADF tree lives in memory; the buffer shows clean text with extmark-based styling:

- **Headings** — plain text with highlight + sign icon
- **Bold, italic, code, links** — extmark highlights, no XML visible
- **Tables** — row-per-line with `│` delimiters and box-drawing borders
- **Lists** — bullet/number/checkbox prefixes via inline virtual text
- **Code blocks** — bordered box with language label
- **Panels** — icon + colored bar (info/note/warning/tip)
- **Images** — `K` to preview in floating window (supports PDF first page)

Markdown-style shortcuts work in insert mode (`## ` for heading, `- ` for list, `- [ ] ` for task, `> ` for quote, `---` for rule, ` ``` ` for code block).

Draft-first editing: `:w` saves locally, `<leader>ss` submits to API.

### Outline Board

`:JiraBoard` opens an outline view of your work:

- **Tree hierarchy** — Feature → Task with expand/collapse (`za`, `zo`, `zc`, `zO`, `zM`)
- **Urgency heatmap** — colored dots in sign column (overdue, blocked, due soon, stale)
- **Right-aligned** assignee + status badge per issue
- **Detail lines** — reviewer, subtask progress bar, due dates
- **Grouping** — `gs` status, `ga` assignee, `gp` product area, `gi` priority, `gd` due date, `gt` type
- **Query switching** — `gq` opens a picker with presets (my work, assigned, created, epics, team workload, overdue, saved filters, custom JQL)
- **Actions** — `e` edit, `t` transition, `a` assign, `c` comment, `gx` open in browser
- **Navigation** — `]i`/`[i` jump between issues, `/` search works natively

Context parents (shown because their child involves you) render dimmed. Fully-done trees are hidden. Status bar counts only workable items (leaf nodes).

### Protocol Handlers

```vim
:edit jira://PROJ-123
:edit jira://PROJ-123/edit
:edit confluence://12345
:edit confluence://12345/edit
```

### Jira

- Search issues (`:JiraSearch`)
- View, edit, create issues with the projection editor
- Transition issues (`:JiraTransition`, `:JiraStart`, `:JiraDone`, `:JiraReview`)
- Comments — add, edit, delete
- Issue links — add, delete
- Custom JQL filters (`:JiraFilter save/load/list/delete`)
- Offline queue and sync (`:JiraQueue`, `:JiraSync`)
- Git hunk tracking (`:JiraHunks`)

### Confluence

- Search and navigate spaces
- View, edit, create pages with the projection editor
- CQL search and saved filters
- Page mentions search

### Git Hunk Tracking

Track unstaged and staged changes tied to a Jira issue:

```
:JiraHunks PROJ-123                    " track changes in cwd
:JiraHunks PROJ-123 ~/repo1 ~/repo2   " track across repos
:JiraHunksStop                         " stop auto-refresh
```

### Health Check

Run `:checkhealth jira-interface` to verify configuration, dependencies, API connectivity, and cache status.

## License

MIT
