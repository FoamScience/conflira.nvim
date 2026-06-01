-- Issue rules: named boolean predicates evaluated against a board node.
--
-- A "rule" is just `id -> function(node) -> boolean`. Built-in rules ship below;
-- users add their own via `board.rules` in config. Any concept can consume them
-- (currently the Definition-of-Ready overlay): reference rules by id and ask
-- whether a single rule, or a set of them, pass for a given node.
--
-- The argument is a BoardNode: `node.issue` is the JiraIssue, `node.children` are
-- its child nodes in the rendered tree.
local M = {}

---@class IssueRule
---@field id string
---@field fn fun(node: BoardNode): boolean

---@type table<string, IssueRule>
local registry = {}

--- Register (or override) a rule.
---@param id string
---@param fn fun(node: BoardNode): boolean
function M.register(id, fn)
	registry[id] = { id = id, fn = fn }
end

--- Get a rule by id.
---@param id string
---@return IssueRule|nil
function M.get(id)
	return registry[id]
end

--- Ids of all registered rules (built-in + user).
---@return string[]
function M.ids()
	local ids = {}
	for id in pairs(registry) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

--- Evaluate a single rule. Unknown id → nil (skipped, never fails).
---@param id string
---@param node BoardNode
---@return boolean|nil
function M.check(id, node)
	local rule = registry[id]
	if not rule then return nil end
	return rule.fn(node) and true or false
end

--- Whether every rule in `ids` passes for `node`. Unknown ids are skipped.
--- Returns nil when the list is empty/nil (caller decides "not applicable").
---@param ids string[]|nil
---@param node BoardNode
---@return boolean|nil
function M.all_pass(ids, node)
	if not ids or #ids == 0 then return nil end
	for _, id in ipairs(ids) do
		local rule = registry[id]
		if rule and not rule.fn(node) then
			return false
		end
	end
	return true
end

-- Built-in rules ------------------------------------------------------------

M.register("description", function(node)
	return node.issue.description ~= nil and node.issue.description ~= ""
end)

M.register("acceptance_criteria", function(node)
	return node.issue.acceptance_criteria ~= nil and node.issue.acceptance_criteria ~= ""
end)

M.register("child_task", function(node)
	return #node.children > 0
end)

M.register("fix_version", function(node)
	return #(node.issue.fix_versions or {}) > 0
end)

M.register("epic_link", function(node)
	return node.issue.parent ~= nil
end)

M.register("assignee", function(node)
	return node.issue.assignee ~= nil
end)

-- User rules ----------------------------------------------------------------

local user_loaded = false

--- Merge user-defined rules from `board.rules` into the registry.
--- These are general predicates usable by any consumer (readiness, and future
--- concepts). Idempotent; runs once per session.
function M.load_user_rules()
	if user_loaded then return end
	user_loaded = true
	local config = require("jira-interface.config")
	local rules = config.options.board and config.options.board.rules
	if type(rules) == "table" then
		for id, fn in pairs(rules) do
			if type(fn) == "function" then
				M.register(id, fn)
			end
		end
	end
end

return M
