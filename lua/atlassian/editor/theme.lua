-- Style-token vocabulary.
--
-- The IR's decorations reference styles by *semantic token* (e.g. "heading.2",
-- "strong", "diff.add") rather than a Neovim highlight-group name. Tokens are
-- the editor-agnostic vocabulary: the Neovim applier resolves them to highlight
-- groups here; a VSCode/Sublime applier maps the same tokens to its own theme.
--
-- `to_token` runs at the build boundary (Neovim group → token); `to_nvim` runs
-- in apply (token → canonical Neovim group). Unknown values pass through
-- unchanged so nothing breaks if a new group/token appears unmapped.
local M = {}

-- Neovim highlight group → semantic token. May be many-to-one (e.g. both
-- "AtlasHeading2" and "@markup.heading.2" → "heading.2").
M.to_token_map = {
	-- headings (editor Atlas groups + board treesitter groups alias to same tokens)
	AtlasHeading1 = "heading.1", ["@markup.heading.1"] = "heading.1",
	AtlasHeading2 = "heading.2", ["@markup.heading.2"] = "heading.2",
	AtlasHeading3 = "heading.3", ["@markup.heading.3"] = "heading.3",
	AtlasHeading4 = "heading.4",
	AtlasHeading5 = "heading.5",
	AtlasHeading6 = "heading.6",
	-- inline marks
	AtlasStrong = "strong",
	AtlasEmphasis = "emphasis",
	AtlasCode = "code",
	AtlasStrike = "strike",
	AtlasUnderline = "underline",
	AtlasLink = "link",
	-- code blocks
	AtlasCodeBlock = "code.block",
	AtlasCodeBlockBorder = "code.border",
	AtlasCodeBlockLang = "code.lang",
	-- lists
	AtlasBullet = "list.bullet",
	AtlasOrderedNumber = "list.ordered",
	AtlasTaskDone = "task.done",
	AtlasTaskTodo = "task.todo",
	-- blockquote / rule
	AtlasBlockquote = "quote",
	AtlasBlockquoteBar = "quote.bar",
	AtlasRule = "rule",
	-- panels
	AtlasPanelInfo = "panel.info",
	AtlasPanelNote = "panel.note",
	AtlasPanelWarning = "panel.warning",
	AtlasPanelTip = "panel.tip",
	AtlasPanelError = "panel.error",
	-- table
	AtlasTableBorder = "table.border",
	AtlasTableHeader = "table.header",
	AtlasTableDelimiter = "table.delimiter",
	-- media / mention
	AtlasMention = "mention",
	AtlasMediaPlaceholder = "media",
	-- status (editor)
	AtlasStatusDone = "status.done",
	AtlasStatusInProgress = "status.progress",
	AtlasStatusBlocked = "status.blocked",
	AtlasStatusDefault = "status.default",
	-- generic / board styling (standard + diagnostic groups)
	Normal = "text",
	NonText = "muted",
	Comment = "comment",
	Title = "title",
	StatusLine = "statusline",
	CurSearch = "search",
	Function = "accent.fn",
	Identifier = "accent.id",
	Type = "accent.type",
	Number = "accent.number",
	Special = "accent.special",
	Constant = "accent.constant",
	DiffAdd = "diff.add",
	DiffDelete = "diff.delete",
	DiffChange = "diff.change",
	DiagnosticError = "error",
	DiagnosticWarn = "warn",
	DiagnosticOk = "ok",
	DiagnosticInfo = "info",
	DiagnosticHint = "hint",
}

-- Semantic token → canonical Neovim highlight group (the inverse used by apply).
-- For tokens with several source groups, one canonical group is chosen; it
-- renders identically (the Atlas groups link to the treesitter ones).
M.to_nvim_map = {
	["heading.1"] = "@markup.heading.1",
	["heading.2"] = "@markup.heading.2",
	["heading.3"] = "@markup.heading.3",
	["heading.4"] = "AtlasHeading4",
	["heading.5"] = "AtlasHeading5",
	["heading.6"] = "AtlasHeading6",
	strong = "AtlasStrong",
	emphasis = "AtlasEmphasis",
	code = "AtlasCode",
	strike = "AtlasStrike",
	underline = "AtlasUnderline",
	link = "AtlasLink",
	["code.block"] = "AtlasCodeBlock",
	["code.border"] = "AtlasCodeBlockBorder",
	["code.lang"] = "AtlasCodeBlockLang",
	["list.bullet"] = "AtlasBullet",
	["list.ordered"] = "AtlasOrderedNumber",
	["task.done"] = "AtlasTaskDone",
	["task.todo"] = "AtlasTaskTodo",
	quote = "AtlasBlockquote",
	["quote.bar"] = "AtlasBlockquoteBar",
	rule = "AtlasRule",
	["panel.info"] = "AtlasPanelInfo",
	["panel.note"] = "AtlasPanelNote",
	["panel.warning"] = "AtlasPanelWarning",
	["panel.tip"] = "AtlasPanelTip",
	["panel.error"] = "AtlasPanelError",
	["table.border"] = "AtlasTableBorder",
	["table.header"] = "AtlasTableHeader",
	["table.delimiter"] = "AtlasTableDelimiter",
	mention = "AtlasMention",
	media = "AtlasMediaPlaceholder",
	["status.done"] = "AtlasStatusDone",
	["status.progress"] = "AtlasStatusInProgress",
	["status.blocked"] = "AtlasStatusBlocked",
	["status.default"] = "AtlasStatusDefault",
	text = "Normal",
	muted = "NonText",
	comment = "Comment",
	title = "Title",
	statusline = "StatusLine",
	search = "CurSearch",
	["accent.fn"] = "Function",
	["accent.id"] = "Identifier",
	["accent.type"] = "Type",
	["accent.number"] = "Number",
	["accent.special"] = "Special",
	["accent.constant"] = "Constant",
	["diff.add"] = "DiffAdd",
	["diff.delete"] = "DiffDelete",
	["diff.change"] = "DiffChange",
	error = "DiagnosticError",
	warn = "DiagnosticWarn",
	ok = "DiagnosticOk",
	info = "DiagnosticInfo",
	hint = "DiagnosticHint",
}

--- Neovim highlight group → semantic token (pass through if unmapped).
---@param hl string|nil
---@return string|nil
function M.to_token(hl)
	if hl == nil then return nil end
	return M.to_token_map[hl] or hl
end

--- Semantic token → Neovim highlight group (pass through if unmapped).
---@param token string|nil
---@return string|nil
function M.to_nvim(token)
	if token == nil then return nil end
	return M.to_nvim_map[token] or token
end

return M
