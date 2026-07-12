local M = {}

---@class JiraAuthConfig
---@field url string Jira instance URL
---@field email string User email
---@field token string API token

---@class JiraTypesConfig
---@field lvl1 string[] Level 1 issue types (Epics)
---@field lvl2 string[] Level 2 issue types (Features, Bugs, Issues)
---@field lvl3 string[] Level 3 issue types (Tasks)
---@field lvl4 string[] Level 4 issue types (Sub-Tasks)

---@class JiraDisplayConfig
---@field mode string Display mode: "float", "vsplit", "split", "tab"
---@field width number|string Width for float/vsplit (number = columns, string like "80%" = percentage)
---@field height number|string Height for float/split (number = lines, string like "80%" = percentage)
---@field border string Border style for floats: "none", "single", "double", "rounded", "solid", "shadow"
---@field wrap boolean Enable line wrapping
---@field linebreak boolean Break at word boundaries when wrapping
---@field conceallevel number Conceal level for markdown (0-3)
---@field cursorline boolean Highlight current line

---@class JiraBoardConfig
---@field workable_jql string|nil JQL whose quoted type names define the "workable" set (nil = leaf nodes)
---@field done_filter string Hide done issues: "none" | "trees" | "leaves"
---@field type_icons table<string, string> Per issue-type glyphs in the outline
---@field epic_kinds table<string, {name: string, icon: string, hl: string}> Epic kinds by label
---@field cycle_pattern string|nil Lua pattern for the Shape Up cycle id (nil disables)
---@field rules table<string, fun(node: table): boolean> Custom issue rules
---@field readiness {enabled: boolean, levels: table<number, string[]>} Definition-of-Ready overlay

---@class JiraConfig
---@field auth JiraAuthConfig
---@field default_project string
---@field cache_ttl number Cache time-to-live in seconds
---@field max_results number Maximum issues to fetch per query
---@field since string|nil Filter issues created since (e.g., "-365d", "-30d", "-7d")
---@field types JiraTypesConfig
---@field statuses string[]
---@field board JiraBoardConfig Outline board settings
---@field acceptance_criteria_names string[] Name fragments for auto-discovering the Acceptance Criteria field
---@field custom_fields table<string, string|string[]> Map of section heading → Jira field ID(s) for edit/create buffers
---@field data_dir string Directory for storing cache and queue
---@field display JiraDisplayConfig Display settings for issue windows
---@field image table Image/PDF preview settings
---@field math table LaTeX macro settings

---@type JiraConfig
M.defaults = {
    auth = {
        url = vim.env.JIRA_URL or "",
        email = vim.env.JIRA_EMAIL or "",
        token = vim.env.JIRA_API_TOKEN or "",
    },
    default_project = vim.env.JIRA_PROJECT or "",
    cache_ttl = 300,
    max_results = 500, -- Max issues to fetch per query
    since = "-365d",   -- Filter by creation date (use days: -365d, -30d, -7d; set to nil to disable)
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
    board = {
        workable_jql = nil,
        -- Which done issues to hide from the outline (the status-bar progress %
        -- always counts the full fetched set, so this never skews it):
        --   "none"   show everything
        --   "trees"  hide only fully-done trees (item + all children done)
        --   "leaves" also hide done leaf items and fully-done subtrees anywhere
        done_filter = "leaves",
        -- Bottom "involvement" sections: issues where a user-valued custom field
        -- (Reviewer, Additional Assignees, …) is you, but you're not the assignee.
        -- Each section has a `name` and `match` substrings tested (lowercased,
        -- case-insensitive) against custom-field names. Fields are auto-sensed;
        -- a field joins the FIRST section it matches (so sections are mutually
        -- exclusive — order matters). Set to {} to disable these sections.
        involvement_sections = {
            { name = "Reviewing", match = { "review" } },
            { name = "Additional Assignees", match = { "additional", "assignee" } },
        },
        -- Reviewer / Additional Assignees fields usually have no JQL searcher, so
        -- they can't be queried. The board detects them from field VALUES on
        -- fetched issues, and scans issues updated in the last N days to surface
        -- ones where you're ONLY a reviewer/additional. 0 disables the scan.
        involvement_scan_days = 120,
        -- Involvement icons drawn next to each issue key, per matched relationship
        -- (assigned/reporter/review/additional/watching). One of:
        --   "nerd"     force Nerd Font glyphs (requires a Nerd Font)
        --   "unicode"  force plain Unicode glyphs
        --   { kind = glyph } table to pin your own
        --   nil (default) auto-detect: uses Nerd Font if vim.g.have_nerd_font is
        --                 set, OR if an icon plugin (nvim-web-devicons / mini.icons)
        --                 is installed; otherwise plain Unicode
        involvement_icons = nil,
        type_icons = {
            Epic = "◆",
            Feature = "◆",
            Bug = "●",
            Issue = "◆",
            Task = "◇",
            ["Sub-Task"] = "○",
        },
        -- Epic kinds, distinguished by label (Shape Up structure).
        -- label → { name, icon, hl }. Set to {} to disable kind badges/grouping.
        epic_kinds = {
            pillar = { name = "Pillar", icon = "▲", hl = "@markup.heading.1" },
            ["shape-up-goal"] = { name = "Shape Up Goal", icon = "◈", hl = "@markup.heading.2" },
            operational = { name = "Operational", icon = "⚙", hl = "Comment" },
        },
        -- Lua pattern matching a Shape Up cycle identifier (e.g. "SU1/26").
        -- Matched against the summary first, then fix version names. nil disables.
        cycle_pattern = "SU%d+/%d+",

        -- Issue rules: named boolean predicates over an issue, usable by ANY
        -- board concept (readiness today; more later). See
        -- lua/atlassian/board/rules.lua. Each is `id = function(node) -> boolean`
        -- where node.issue is the JiraIssue and node.children are child nodes.
        -- Custom ids override built-ins of the same name.
        --
        -- Built-in rule ids:
        --   "description"         non-empty description
        --   "acceptance_criteria" non-empty Acceptance Criteria field
        --                         (auto-discovered by name; no custom_fields entry needed)
        --   "child_task"          has ≥1 child in the tree
        --   "fix_version"         has ≥1 Fix Version/s (release / cycle)
        --   "epic_link"           has a parent (linked to an Epic)
        --   "assignee"            has an assignee
        rules = {},

        -- Definition-of-Ready overlay (Shape Up "ready for development" bar) —
        -- one consumer of the rules above. enabled → show ✓ready / ◐shaping on
        -- workable items. levels[N] lists the rule ids that must ALL pass for an
        -- item at hierarchy level N.
        readiness = {
            enabled = true,
            levels = {
                [2] = { "description", "acceptance_criteria", "child_task", "fix_version", "epic_link" },
                [3] = { "description" },
            },
        },
    },
    -- Display-name fragments used to auto-discover the Acceptance Criteria field
    -- from Jira field metadata. A custom field matches if its name contains all
    -- words of any entry here (case-insensitive). Add aliases like
    -- "definition of done" to match differently-named fields.
    acceptance_criteria_names = { "acceptance criteria" },
    custom_fields = {},
    data_dir = vim.fn.stdpath("data") .. "/jira-interface",
    display = {
        mode = "float",     -- "float", "vsplit", "split", "tab"
        width = "80%",      -- number (columns) or string ("80%")
        height = "80%",     -- number (lines) or string ("80%")
        border = "rounded", -- "none", "single", "double", "rounded", "solid", "shadow"
        wrap = true,
        linebreak = true,
        conceallevel = 2,
        cursorline = true,
    },
    image = {
        enabled = true,
        max_file_size = 12 * 1024 * 1024,  -- 12MB
        auto_preview = false,              -- true = CursorHold preview
        cache_dir = vim.fn.stdpath("cache") .. "/atlassian/images",
        cell_aspect = 2.0,                 -- terminal cell height/width ratio (tune to fit previews)
    },
    math = {
        enabled = true,
        block_macro = "mathblock",     -- ac:name for new block equations
        inline_macro = "mathinline",   -- ac:name for new inline equations
        inline_param = "body",         -- parameter name for inline LaTeX source
    },
}

---@type JiraConfig
M.options = {}

---@param opts? JiraConfig
---@return JiraConfig
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

    -- Ensure data directory exists
    vim.fn.mkdir(M.options.data_dir, "p")

    return M.options
end

---@return boolean, string?
function M.validate()
    local auth = M.options.auth
    if not auth.url or auth.url == "" then
        return false, "JIRA_URL is not set"
    end
    if not auth.email or auth.email == "" then
        return false, "JIRA_EMAIL is not set"
    end
    if not auth.token or auth.token == "" then
        return false, "JIRA_API_TOKEN is not set"
    end
    -- default_project is optional - can search across all projects
    return true, nil
end

---@return string
function M.get_cache_path()
    return M.options.data_dir .. "/cache.json"
end

---@return string
function M.get_queue_path()
    return M.options.data_dir .. "/queue.json"
end

---@return string
function M.get_filters_path()
    return M.options.data_dir .. "/filters.json"
end

return M
