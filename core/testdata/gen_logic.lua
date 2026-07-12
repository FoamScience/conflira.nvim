-- Parity fixtures for the non-rendering subsystems: JQL builders, ADF→text, and
-- request building (auth, URL, fields param, endpoints, encoding). Captured from
-- the FROZEN Lua so the Go ports can be verified against them.
--
-- Run: nvim --headless -c "luafile core/testdata/gen_logic.lua" -c "qa"
local config = require("jira-interface.config")
config.setup({})
local filters = require("jira-interface.filters")
local adf = require("atlassian.adf")
local request = require("atlassian.request")

local dir = "core/testdata/logic/"
vim.fn.mkdir(dir, "p")
local function write(name, data)
	local f = io.open(dir .. name, "w")
	f:write(vim.json.encode(data))
	f:close()
end

-- 1. JQL builders ---------------------------------------------------------
local b = filters.builtin
local jql = {
	assigned_to_me = b.assigned_to_me(),
	created_by_me = b.created_by_me(),
	assigned_not_created = b.assigned_not_created(),
	by_project = b.by_project("PROJ"),
	by_status = b.by_status("In Progress"),
	by_type = b.by_type("Bug"),
	by_level_1 = b.by_level(1, "PROJ"),
	by_level_2 = b.by_level(2, "PROJ"),
	by_level_3_noproj = b.by_level(3, ""),
	by_label = b.by_label("ready", "PROJ"),
	by_label_noproj = b.by_label("operational", ""),
	children_of = b.children_of("PROJ-7"),
	overdue = b.overdue("PROJ"),
	due_today = b.due_today("PROJ"),
	due_this_week = b.due_this_week("PROJ"),
	due_soon = b.due_soon("PROJ"),
	by_duedate = b.by_duedate("PROJ"),
	combine = filters.combine_jql("project = PROJ ORDER BY updated DESC", "assignee = currentUser()"),
	combine_noorder = filters.combine_jql("project = PROJ", "status = Done"),
}
write("jql.json", jql)

-- 2. ADF → text ----------------------------------------------------------
local function doc(...) return { type = "doc", content = { ... } } end
local function p(t) return { type = "paragraph", content = { { type = "text", text = t } } } end
local adf_cases = {
	heading = doc({ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Title" } } }),
	para = doc(p("hello world")),
	list = doc({ type = "bulletList", content = {
		{ type = "listItem", content = { p("one") } },
		{ type = "listItem", content = { p("two") } },
	} }),
	ordered = doc({ type = "orderedList", content = {
		{ type = "listItem", content = { p("first") } },
		{ type = "listItem", content = { p("second") } },
	} }),
	code = doc({ type = "codeBlock", attrs = { language = "lua" }, content = { { type = "text", text = "x=1" } } }),
	mixed = doc(
		{ type = "heading", attrs = { level = 1 }, content = { { type = "text", text = "H" } } },
		p("intro"),
		{ type = "bulletList", content = { { type = "listItem", content = { p("item") } } } }
	),
}
local adf_out = {}
for name, d in pairs(adf_cases) do
	adf_out[name] = { adf = d, text = adf.adf_to_text(d) }
end
write("adf_text.json", adf_out)

-- 3. Request building ----------------------------------------------------
local req = {
	auth_header = request.get_auth_header({ email = "user@example.com", token = "s3cr3t" }),
	url_plain = request.normalize_url("mysite.atlassian.net"),
	url_https = request.normalize_url("https://mysite.atlassian.net/"),
	url_http = request.normalize_url("http://localhost:8080/"),
	uri_encode_jql = vim.uri_encode('project = PROJ AND status = "In Progress" ORDER BY updated DESC'),
}
-- Lock the URI encoder over all printable ASCII.
local ascii = {}
for i = 32, 126 do ascii[#ascii + 1] = string.char(i) end
req.uri_encode_ascii = vim.uri_encode(table.concat(ascii))
write("request.json", req)

-- 4. Issue parsing -------------------------------------------------------
local types = require("jira-interface.types")
local raw_issue = {
	key = "PROJ-5",
	id = "10005",
	fields = {
		summary = "Build the thing",
		issuetype = { name = "Task" },
		status = { name = "In Progress" },
		priority = { name = "High" },
		project = { key = "PROJ" },
		assignee = { displayName = "Alice" },
		parent = { key = "PROJ-1" },
		labels = { "backend", "ready" },
		fixVersions = { { name = "SU1/26" }, { name = "SU2/26" } },
		duedate = "2026-07-01",
		created = "2026-05-01T10:00:00.000+0000",
		updated = "2026-05-20T12:00:00.000+0000",
		description = {
			type = "doc", version = 1,
			content = {
				{ type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "Goal" } } },
				{ type = "paragraph", content = { { type = "text", text = "do it well" } } },
			},
		},
		issuelinks = {
			{
				id = "200",
				type = { name = "Blocks", inward = "is blocked by", outward = "blocks" },
				inwardIssue = { key = "PROJ-9", fields = { summary = "blocker", status = { name = "To Do" } } },
			},
		},
	},
}
local parsed = types.parse_issue(raw_issue)
write("parse.json", { raw = raw_issue, parsed = {
	key = parsed.key, summary = parsed.summary, status = parsed.status, type = parsed.type,
	level = parsed.level, project = parsed.project, parent = parsed.parent, assignee = parsed.assignee,
	priority = parsed.priority, labels = parsed.labels, fix_versions = parsed.fix_versions,
	duedate = parsed.duedate, created = parsed.created, updated = parsed.updated,
	description = parsed.description, links = parsed.links,
} })

-- 5. Custom-field resolution (ensure_custom_fields_resolved) -------------
-- Stub get_all_fields with a fixed /field response and capture the resolved
-- config.options.custom_fields (empty-config auto-discovery + AC fuzzy match).
local api = require("jira-interface.api")
local FIELDS = {
	{ id = "customfield_10001", name = "Reviewer Notes", custom = true, schema = { type = "doc" } },
	{ id = "customfield_10002", name = "Extra", custom = true, schema = { custom = "com.x:textarea" } },
	{ id = "customfield_10003", name = "Acceptance Criteria", custom = true, schema = { type = "doc" } },
	{ id = "customfield_10004", name = "Story Points", custom = true, schema = { type = "number" } },
	{ id = "customfield_10005", name = "Acceptance Criteria (DoD)", custom = true, schema = { type = "doc" } },
	{ id = "customfield_10006", name = "Reviewer", custom = true, schema = { type = "user", custom = "com.atlassian.jira.plugin.system.customfieldtypes:userpicker" } },
	{ id = "customfield_10007", name = "Additional Assignees", custom = true, schema = { custom = "com.atlassian.jira.plugin.system.customfieldtypes:multiuserpicker" } },
	{ id = "customfield_10008", name = "Reviewer", custom = true, schema = { type = "array", custom = "com.atlassian.jira.plugin.system.customfieldtypes:people" } },
	{ id = "summary", name = "Summary", custom = false, schema = { type = "string", system = "summary" } },
}
api.get_all_fields = function(cb) cb(nil, FIELDS) end
api.ensure_custom_fields_resolved(function()
	local resolved = config.options.custom_fields
	resolved._resolved_ids = nil -- not produced by this path
	local secs = {}
	for i, def in ipairs(config.options.board.involvement_sections) do
		secs[i] = { name = def.name, match = def.match, ids = api.involvement_section_ids[i] or {} }
	end
	write("fields.json", { fields = FIELDS, resolved = resolved, sections = secs })
end)

-- 6. Offline queue on-disk format --------------------------------------
config.options.data_dir = vim.fn.fnamemodify("core/testdata/logic", ":p"):gsub("/$", "")
os.remove(config.get_queue_path())
local queue = require("jira-interface.queue")
queue.queue_transition("PROJ-1", "31", "Done")
queue.queue_update("PROJ-2", { summary = "new title" }, "Update PROJ-2")
queue.queue_comment("PROJ-3", "<p>hi</p>")
-- queue.json now written by the plugin at logic/queue.json (the format fixture).

-- 7. Cache on-disk format ------------------------------------------------
local acache = require("atlassian.cache")
local cpath = dir .. "cache.json"
os.remove(cpath)
local c = acache.create_cache({ cache_path = cpath, cache_ttl = 300 })
c.set("issue_types_PROJ", { "Task", "Bug", "Feature" }, "PROJ")
c.set("greeting", "hello", nil)
-- cache.json now written by atlassian.cache at logic/cache.json (the format fixture).

print("wrote logic fixtures")
