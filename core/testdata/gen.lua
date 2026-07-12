-- Parity fixture generator. Reads the FROZEN Lua renderer and writes, for each
-- ADF case, a pair { <name>.adf.json, <name>.ir.json } under cases/. The Go
-- renderer port is verified to reproduce <name>.ir.json from <name>.adf.json.
--
-- Run: nvim --headless -c "luafile core/testdata/gen.lua" -c "qa"
require("jira-interface.config").setup({})
local render = require("atlassian.editor.render")
local ir = require("atlassian.editor.ir")

local dir = "core/testdata/cases/"
vim.fn.mkdir(dir, "p")

local function txt(s, marks)
	return { type = "text", text = s, marks = marks }
end
local function para(...)
	return { type = "paragraph", content = { ... } }
end
local function doc(...)
	return { type = "doc", content = { ... } }
end

local cases = {
	heading1 = doc({ type = "heading", attrs = { level = 1 }, content = { txt("Hello") } }),
	heading2 = doc({ type = "heading", attrs = { level = 2 }, content = { txt("Title") } }),
	para = doc(para(txt("simple text"))),
	marks = doc(para(
		txt("a "),
		txt("bold", { { type = "strong" } }),
		txt(" "),
		txt("it", { { type = "em" } }),
		txt(" "),
		txt("co", { { type = "code" } }),
		txt(" "),
		txt("st", { { type = "strike" } }),
		txt(" "),
		txt("lnk", { { type = "link", attrs = { href = "https://x.y" } } })
	)),
	para_wrap = doc(para(txt(string.rep("word ", 30)))),
	hardbreak = doc(para(txt("line one"), { type = "hardBreak" }, txt("line two"))),
	bullet = doc({
		type = "bulletList",
		content = {
			{ type = "listItem", content = { para(txt("one")) } },
			{ type = "listItem", content = { para(txt("two")) } },
		},
	}),
	bullet_nested = doc({
		type = "bulletList",
		content = {
			{ type = "listItem", content = {
				para(txt("outer")),
				{ type = "bulletList", content = {
					{ type = "listItem", content = { para(txt("inner")) } },
				} },
			} },
		},
	}),
	ordered = doc({
		type = "orderedList",
		content = {
			{ type = "listItem", content = { para(txt("first")) } },
			{ type = "listItem", content = { para(txt("second")) } },
			{ type = "listItem", content = { para(txt("third")) } },
		},
	}),
	task = doc({
		type = "taskList",
		content = {
			{ type = "taskItem", attrs = { state = "DONE" }, content = { para(txt("done one")) } },
			{ type = "taskItem", attrs = { state = "TODO" }, content = { para(txt("todo two")) } },
		},
	}),
	code = doc({
		type = "codeBlock",
		attrs = { language = "lua" },
		content = { txt("local x = 1\nprint(x)") },
	}),
	quote = doc({ type = "blockquote", content = { para(txt("quoted text here")) } }),
	rule = doc(para(txt("above")), { type = "rule" }, para(txt("below"))),
	panel_info = doc({ type = "panel", attrs = { panelType = "info" }, content = { para(txt("an info panel")) } }),
	panel_warning = doc({ type = "panel", attrs = { panelType = "warning" }, content = { para(txt("careful")) } }),
	table = doc({
		type = "table",
		content = {
			{ type = "tableRow", content = {
				{ type = "tableHeader", content = { para(txt("H1")) } },
				{ type = "tableHeader", content = { para(txt("H2")) } },
			} },
			{ type = "tableRow", content = {
				{ type = "tableCell", content = { para(txt("a")) } },
				{ type = "tableCell", content = { para(txt("bb")) } },
			} },
		},
	}),
	mention = doc(para(txt("hi "), { type = "mention", attrs = { text = "alice" } })),
	media = doc({
		type = "mediaSingle",
		content = { { type = "media", attrs = { type = "external", url = "https://img/x.png", alt = "pic" } } },
	}),
	mixed = doc(
		{ type = "heading", attrs = { level = 1 }, content = { txt("Top") } },
		para(txt("intro paragraph")),
		{ type = "rule" },
		{ type = "heading", attrs = { level = 2 }, content = { txt("Section") } },
		para(txt("body"))
	),
}

local names = {}
for name in pairs(cases) do names[#names + 1] = name end
table.sort(names)

for _, name in ipairs(names) do
	local adf = cases[name]
	local af = io.open(dir .. name .. ".adf.json", "w")
	af:write(vim.json.encode(adf))
	af:close()
	local rf = io.open(dir .. name .. ".ir.json", "w")
	rf:write(ir.encode(render.build_ir(adf)))
	rf:close()
	print("wrote " .. name)
end
