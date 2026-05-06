local M = {}

M.ns = vim.api.nvim_create_namespace("atlassian_editor")

local icons = require("atlassian.icons")

M.heading_icons = {
	icons.ui.Heading1,
	icons.ui.Heading2,
	icons.ui.Heading3,
	icons.ui.Heading4,
	icons.ui.Heading5,
	icons.ui.Heading6,
}

M.bullet_icon = icons.ui.Circle
M.checkbox_done = icons.ui.BoxChecked
M.checkbox_todo = "󰄱"
M.blockquote_bar = icons.ui.BoldLineLeft
M.hr_char = icons.ui.HorizontalRule
M.code_icon = icons.ui.Code

M.panel_icons = {
	info = icons.diagnostics.Information,
	note = icons.ui.Pencil,
	warning = icons.diagnostics.Warning,
	tip = icons.diagnostics.Hint,
	error = icons.diagnostics.Warning,
}

M.heading_hls = {
	"AtlasHeading1", "AtlasHeading2", "AtlasHeading3",
	"AtlasHeading4", "AtlasHeading5", "AtlasHeading6",
}

function M.setup()
	local set = vim.api.nvim_set_hl

	-- Headings — link to built-in markup groups so themes work
	set(0, "AtlasHeading1", { link = "@markup.heading.1" })
	set(0, "AtlasHeading2", { link = "@markup.heading.2" })
	set(0, "AtlasHeading3", { link = "@markup.heading.3" })
	set(0, "AtlasHeading4", { link = "@markup.heading.4" })
	set(0, "AtlasHeading5", { link = "@markup.heading.5" })
	set(0, "AtlasHeading6", { link = "@markup.heading.6" })

	-- Inline marks
	set(0, "AtlasStrong", { link = "@markup.strong" })
	set(0, "AtlasEmphasis", { link = "@markup.italic" })
	set(0, "AtlasCode", { link = "@markup.raw" })
	set(0, "AtlasStrike", { link = "@markup.strikethrough" })
	set(0, "AtlasUnderline", { underline = true })
	set(0, "AtlasLink", { link = "@markup.link.url" })

	-- Code blocks
	set(0, "AtlasCodeBlock", { link = "@markup.raw.block" })
	set(0, "AtlasCodeBlockBorder", { link = "FloatBorder" })
	set(0, "AtlasCodeBlockLang", { link = "Comment" })

	-- Lists
	set(0, "AtlasBullet", { link = "@markup.list" })
	set(0, "AtlasOrderedNumber", { link = "@markup.list.checked" })
	set(0, "AtlasTaskDone", { link = "DiagnosticOk" })
	set(0, "AtlasTaskTodo", { link = "Comment" })

	-- Blockquote
	set(0, "AtlasBlockquote", { link = "@markup.quote" })
	set(0, "AtlasBlockquoteBar", { link = "FloatBorder" })

	-- Horizontal rule
	set(0, "AtlasRule", { link = "FloatBorder" })

	-- Panels
	set(0, "AtlasPanelInfo", { link = "DiagnosticInfo" })
	set(0, "AtlasPanelNote", { link = "DiagnosticHint" })
	set(0, "AtlasPanelWarning", { link = "DiagnosticWarn" })
	set(0, "AtlasPanelTip", { link = "DiagnosticOk" })
	set(0, "AtlasPanelError", { link = "DiagnosticError" })

	-- Table
	set(0, "AtlasTableBorder", { link = "FloatBorder" })
	set(0, "AtlasTableHeader", { link = "@markup.heading" })
	set(0, "AtlasTableDelimiter", { link = "Delimiter" })

	-- Media / mentions
	set(0, "AtlasMention", { link = "@markup.link" })
	set(0, "AtlasMediaPlaceholder", { link = "Comment" })

	-- Status colors (auto-generated from status names)
	set(0, "AtlasStatusDone", { link = "DiagnosticOk" })
	set(0, "AtlasStatusInProgress", { link = "DiagnosticWarn" })
	set(0, "AtlasStatusBlocked", { link = "DiagnosticError" })
	set(0, "AtlasStatusDefault", { link = "DiagnosticInfo" })
end

M.mark_hl = {
	strong = "AtlasStrong",
	em = "AtlasEmphasis",
	code = "AtlasCode",
	strike = "AtlasStrike",
	underline = "AtlasUnderline",
	link = "AtlasLink",
	subsup = "AtlasCode",
}

M.panel_hls = {
	info = "AtlasPanelInfo",
	note = "AtlasPanelNote",
	warning = "AtlasPanelWarning",
	tip = "AtlasPanelTip",
	error = "AtlasPanelError",
}

local status_patterns = {
	{ pattern = "done", hl = "AtlasStatusDone" },
	{ pattern = "resolved", hl = "AtlasStatusDone" },
	{ pattern = "closed", hl = "AtlasStatusDone" },
	{ pattern = "complete", hl = "AtlasStatusDone" },
	{ pattern = "in.progress", hl = "AtlasStatusInProgress" },
	{ pattern = "in.review", hl = "AtlasStatusInProgress" },
	{ pattern = "building", hl = "AtlasStatusInProgress" },
	{ pattern = "testing", hl = "AtlasStatusInProgress" },
	{ pattern = "block", hl = "AtlasStatusBlocked" },
	{ pattern = "error", hl = "AtlasStatusBlocked" },
	{ pattern = "fail", hl = "AtlasStatusBlocked" },
}

function M.status_hl(status_name)
	if not status_name then
		return "AtlasStatusDefault"
	end
	local lower = status_name:lower()
	for _, entry in ipairs(status_patterns) do
		if lower:find(entry.pattern) then
			return entry.hl
		end
	end
	return "AtlasStatusDefault"
end

return M
