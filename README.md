# conflira.nvim

> Disclaimer; This plugin is an unofficial effort to remove some of the pain of working with a web app
> on Jira issues. This is not affiliated to Atlassian in any way.

A Neovim plugin for Jira and Confluence with an ADF projection editor, outline board, and offline support.

## Requirements

### Required

- Neovim >= 0.11.4
- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker UI and notifications  (auto-installed with the plugin)
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

### Full Configuration

Everything below is optional — the defaults shown are what ships. Pass only the keys you want to override to `require("jira-interface").setup{}`.

<details>
<summary>Complete <code>jira-interface</code> options (with defaults)</summary>

```lua
require("jira-interface").setup({
    auth = {
        url   = vim.env.JIRA_URL,
        email = vim.env.JIRA_EMAIL,
        token = vim.env.JIRA_API_TOKEN,
    },
    default_project = vim.env.JIRA_PROJECT, -- "" searches all projects

    cache_ttl   = 300,    -- cache time-to-live (seconds)
    max_results = 500,    -- max issues fetched per query
    since       = "-365d", -- only issues created since (e.g. "-30d"); nil disables

    -- Issue-type hierarchy (drives tree nesting and level-based filters).
    types = {
        lvl1 = { "Epic" },
        lvl2 = { "Feature", "Bug", "Issue" },
        lvl3 = { "Task" },
        lvl4 = { "Sub-Task" },
    },

    -- Statuses offered in transition/status flows.
    statuses = { "To Do", "In Progress", "In Review", "Blocked", "Done" },

    board = {
        -- What counts as a "workable" item for the status bar. nil = leaf nodes.
        -- Set a JQL string; type names quoted in it define the workable set.
        workable_jql = nil,

        -- Which done issues to hide from the outline. The status-bar progress %
        -- always counts the full fetched set, so this never skews it.
        --   "none"   show everything
        --   "trees"  hide only fully-done trees (item + all children done)
        --   "leaves" also hide done leaf items and fully-done subtrees anywhere
        done_filter = "leaves",

        -- Type glyphs in the outline.
        type_icons = {
            Epic = "◆", Feature = "◆", Bug = "●",
            Issue = "◆", Task = "◇", ["Sub-Task"] = "○",
        },

        -- Epic kinds, distinguished by label (Shape Up structure).
        -- label → { name, icon, hl }. Set to {} to disable kind badges/grouping (gk).
        epic_kinds = {
            pillar             = { name = "Pillar",        icon = "▲", hl = "@markup.heading.1" },
            ["shape-up-goal"]  = { name = "Shape Up Goal", icon = "◈", hl = "@markup.heading.2" },
            operational        = { name = "Operational",   icon = "⚙", hl = "Comment" },
        },

        -- Lua pattern matching a Shape Up cycle id (e.g. "SU1/26"). Matched against
        -- the summary first, then fix version names. nil disables cycle badges/grouping (gc).
        cycle_pattern = "SU%d+/%d+",

        -- Issue rules: named boolean predicates usable by any board concept
        -- (see "Issue Rules" below). id = function(node) -> boolean.
        -- Custom ids override built-ins. Built-in ids:
        --   "description" | "acceptance_criteria" | "child_task"
        --   "fix_version" | "epic_link" | "assignee"
        rules = {},

        -- Definition-of-Ready overlay (✓ ready / ◐ shaping) — one consumer of
        -- the rules above. levels[N] lists rule ids that must ALL pass at level N.
        readiness = {
            enabled = true,
            levels = {
                [2] = { "description", "acceptance_criteria", "child_task", "fix_version", "epic_link" },
                [3] = { "description" },
            },
        },
    },

    -- Display-name fragments used to auto-discover the Acceptance Criteria field
    -- from Jira field metadata. A field matches if its name contains all words of
    -- any entry (case-insensitive). No custom_fields entry is required for it.
    acceptance_criteria_names = { "acceptance criteria" },

    -- Optional: map a section heading → Jira field ID(s) for extra custom fields.
    -- Rich-text (doc/textarea) fields are auto-discovered by name and need no entry;
    -- add entries here only for non-rich-text fields (selects, user pickers, numbers).
    custom_fields = {},

    data_dir  = vim.fn.stdpath("data") .. "/jira-interface",

    display = {
        mode         = "float",   -- "float" | "vsplit" | "split" | "tab"
        width        = "80%",     -- number (cols) or "NN%"
        height       = "80%",     -- number (lines) or "NN%"
        border       = "rounded", -- "none" | "single" | "double" | "rounded" | "solid" | "shadow"
        wrap         = true,
        linebreak    = true,
        conceallevel = 2,
        cursorline   = true,
    },

    image = {
        enabled       = true,
        max_file_size = 12 * 1024 * 1024, -- 12 MB
        auto_preview  = false,            -- true = preview on CursorHold
        cache_dir     = vim.fn.stdpath("cache") .. "/atlassian/images",
        cell_aspect   = 2.0,              -- terminal cell height/width ratio
    },

    math = {
        enabled      = true,
        block_macro  = "mathblock",  -- ac:name for new block equations
        inline_macro = "mathinline", -- ac:name for new inline equations
        inline_param = "body",       -- parameter name for inline LaTeX source
    },
})
```

</details>

<details>
<summary>Complete <code>confluence-interface</code> options (with defaults)</summary>

```lua
require("confluence-interface").setup({
    auth = {
        url   = vim.env.CONFLUENCE_URL or vim.env.JIRA_URL,
        email = vim.env.CONFLUENCE_EMAIL or vim.env.JIRA_EMAIL,
        token = vim.env.CONFLUENCE_API_TOKEN or vim.env.JIRA_API_TOKEN,
    },
    default_space = vim.env.CONFLUENCE_SPACE,

    cache_ttl   = 300,
    max_results = 100,
    data_dir    = vim.fn.stdpath("data") .. "/confluence-interface",

    -- display, image, and math share the same shape and defaults as jira-interface.
    display = { mode = "float", width = "80%", height = "80%", border = "rounded",
                wrap = true, linebreak = true, conceallevel = 2, cursorline = true },
    image   = { enabled = true, max_file_size = 12 * 1024 * 1024, auto_preview = false,
                cache_dir = vim.fn.stdpath("cache") .. "/atlassian/images", cell_aspect = 2.0 },
    math    = { enabled = true, block_macro = "mathblock", inline_macro = "mathinline", inline_param = "body" },
})
```

</details>

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

Issues and pages are edited using an ADF (Atlassian Document Format) projection engine.
The ADF tree lives in memory; the buffer shows clean text with extmark-based styling:

- **Headings** — plain text with highlight + sign icon
- **Bold, italic, code, links** — extmark highlights, no XML visible
- **Tables** — row-per-line with `│` delimiters and box-drawing borders
- **Lists** — bullet/number/checkbox prefixes via inline virtual text
- **Code blocks** — bordered box with language label
- **Panels** — icon + colored bar (info/note/warning/tip)
- **Images** — `K` to preview in floating window (supports PDF first page)

Markdown-style shortcuts work in insert mode (`## ` for heading, `- ` for list, `- [ ] ` for task, `> ` for quote, `---` for rule, \`\`\` for code blocks).

Draft-first editing: `:w` saves locally, `<leader>ss` submits to API.

### Outline Board

`:JiraBoard` opens an outline view of your work:

- **Tree hierarchy** — Feature → Task with expand/collapse (`za`, `zo`, `zc`, `zO`, `zM`)
- **Urgency heatmap** — colored dots in sign column (overdue, blocked incl. `is blocked by` links, due soon, stale)
- **Shape Up structure** — epic kind badges (Pillar / Shape Up Goal / Operational, by label), cycle tags (e.g. `SU1/26`), and a definition-of-ready glyph (✓ ready / ◐ shaping)
- **Detail lines** — readiness, cycle, blocked-by deps, reviewer, subtask progress bar, due dates
- **Grouping** — `gs` status, `ga` assignee, `gk` epic kind, `gc` cycle, `gi` priority, `gd` due date, `gt` type
- **Query switching** — `gq` opens a picker with presets (my work, assigned, created, epics, epic-kind labels, team workload, overdue, saved filters, custom JQL)
- **Actions** — `e` edit, `t` transition, `a` assign, `c` comment, `gx` open in browser
- **Navigation** — `]i`/`[i` jump between issues, `/` search works natively

Context parents (shown because their child involves you) render dimmed. Done items are hidden per `board.done_filter` (default `"leaves"` — hides done leaf tasks and fully-done subtrees; set `"trees"` or `"none"` to loosen). The status bar counts the full fetched workable set regardless — leaf nodes by default, or the type set named in `board.workable_jql` — so the progress % stays accurate even when done items are hidden.

### Issue Rules

An **issue rule** is a named boolean predicate over an issue — a small, general, configurable concept that any board feature can consume, not just readiness. Rules are evaluated entirely on the conflira side (no Jira automation required), and you can add your own.

A rule is `id = function(node) -> boolean`, where `node.issue` is the [`JiraIssue`](lua/jira-interface/types.lua) and `node.children` are its child nodes in the tree. Custom rules live under `board.rules` and are shared across every consumer.

Built-in rules:

| Rule id | Passes when |
|---|---|
| `description` | description is non-empty |
| `acceptance_criteria` | the Acceptance Criteria field is non-empty (auto-discovered by name) |
| `child_task` | the issue has ≥1 child in the tree |
| `fix_version` | the issue has ≥1 Fix Version/s (release / cycle) |
| `epic_link` | the issue has a parent (linked to an Epic) |
| `assignee` | the issue has an assignee |

**Readiness** is the first consumer of rules: `board.readiness.levels[N]` lists the rule ids that must *all* pass for an item at hierarchy level N to be `✓ ready` (otherwise `◐ shaping`). Done items and levels with no rules show no glyph.

Define custom rules once under `board.rules`, then reference their ids from any consumer (e.g. `readiness.levels`):

```lua
board = {
    rules = {
        -- Acceptance criteria must list at least two items
        ac_two_plus = function(node)
            local ac = node.issue.acceptance_criteria or ""
            return select(2, ac:gsub("\n", "")) >= 1  -- ≥2 lines
        end,
        -- Not stale: updated within 14 days (reuse any issue field)
        fresh = function(node)
            return node.urgency ~= "stale"
        end,
    },
    readiness = {
        enabled = true,
        levels = {
            [2] = { "description", "ac_two_plus", "child_task", "fix_version", "epic_link" },
            [3] = { "description", "fresh" },
        },
    },
}
```

Custom rule ids override built-ins of the same name. Unknown ids referenced by a consumer are skipped (never fail), so a typo degrades gracefully rather than erroring.

Under the hood, [`lua/atlassian/board/rules.lua`](lua/atlassian/board/rules.lua) is a standalone registry — `register(id, fn)`, `check(id, node)`, `all_pass(ids, node)`, `ids()`. A future feature (custom urgency, grouping, filtering, badges) can reuse the exact same rules by id without touching readiness.

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

### Confluence

- Search and navigate spaces
- View, edit, create pages with the projection editor
- CQL search and saved filters
- Page mentions search

### Health Check

Run `:checkhealth jira-interface` to verify configuration, dependencies, API connectivity, and cache status.

## License

MIT
