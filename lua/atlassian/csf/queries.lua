-- Generate treesitter conceal queries from atlassian.icons
-- Rules for merged highlights group:
--   - NO child captures inside @conceal parents (causes fragmentation)
--   - Use #match? with plain substrings (no anchors, no escaped quotes)
--   - Split-tag on "<" for headings/bullets (icon on leaf token)
local M = {}

---@return string Treesitter query string for CSF concealing
function M.conceal()
    local icons = require("atlassian.icons")
    local function ic(s) return vim.trim(s) end

    local q = {}
    local function add(s) table.insert(q, s) end

    -- ── Headings: split-tag (icon on "<", hide name, space on ">") ──
    local headings = {
        { "h1", ic(icons.ui.Heading1) }, { "h2", ic(icons.ui.Heading2) },
        { "h3", ic(icons.ui.Heading3) }, { "h4", ic(icons.ui.Heading4) },
        { "h5", ic(icons.ui.Heading5) }, { "h6", ic(icons.ui.Heading6) },
    }
    for _, h in ipairs(headings) do
        local tag, icon = h[1], h[2]
        add(('(element (STag "<" @conceal (Name) @_n) (#eq? @_n "%s") (#set! conceal "%s"))'):format(tag, icon))
        add(('(element (STag (Name) @conceal) (#eq? @conceal "%s") (#set! conceal ""))'):format(tag))
        add(('(element (STag (Name) @_n ">" @conceal) (#eq? @_n "%s") (#set! conceal " "))'):format(tag))
        add(('(element (ETag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end

    -- ── Inline formatting: hidden (no child captures) ──
    for _, tag in ipairs({ "strong", "em", "code", "s" }) do
        add(('(element (STag) @conceal (#match? @conceal "<%s>") (#set! conceal ""))'):format(tag))
        add(('(element (ETag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end

    -- ── Invisible tags: hidden ──
    for _, tag in ipairs({ "p", "u", "ul", "ol", "table", "tr", "tbody", "thead", "pre", "sup", "sub" }) do
        add(('(element (STag) @conceal (#match? @conceal "<%s>") (#set! conceal ""))'):format(tag))
        add(('(element (ETag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end
    -- Tags that may have attributes
    for _, tag in ipairs({ "span", "div" }) do
        add(('(element (STag) @conceal (#match? @conceal "<%s") (#set! conceal ""))'):format(tag))
        add(('(element (ETag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end

    -- ── List items: split-tag (bullet + space) ──
    local bullet = ic(icons.ui.Circle)
    add(('(element (STag "<" @conceal (Name) @_n) (#eq? @_n "li") (#set! conceal "%s"))'):format(bullet))
    add( '(element (STag (Name) @conceal) (#eq? @conceal "li") (#set! conceal ""))')
    add( '(element (STag (Name) @_n ">" @conceal) (#eq? @_n "li") (#set! conceal " "))')
    add( '(element (ETag) @conceal (#match? @conceal "li") (#set! conceal ""))')

    -- ── Block elements ──
    local quote_ic = ic(icons.ui.BoldLineLeft)
    add(('(element (STag "<" @markup.quote (Name) @_n) (#eq? @_n "blockquote") (#set! conceal "%s"))'):format(quote_ic))
    add( '(element (STag (Name) @conceal) (#eq? @conceal "blockquote") (#set! conceal ""))')
    add( '(element (STag (Name) @_n ">" @conceal) (#eq? @_n "blockquote") (#set! conceal " "))')
    add( '(element (ETag) @conceal (#match? @conceal "blockquote") (#set! conceal ""))')
    add(('(element (EmptyElemTag) @conceal (#match? @conceal "<hr") (#set! conceal "%s"))'):format(ic(icons.ui.HorizontalRule)))
    add( '(element (EmptyElemTag) @conceal (#match? @conceal "<br") (#set! conceal ""))')

    -- ── Links & images ──
    local link_ic = ic(icons.kind.Reference)
    local file_ic = ic(icons.kind.File)
    add(('(element (STag) @conceal (#match? @conceal "<a") (#set! conceal "%s"))'):format(link_ic))
    add( '(element (ETag) @conceal (#match? @conceal "a") (#set! conceal ""))')
    add(('(element (EmptyElemTag) @conceal (#match? @conceal "<img") (#set! conceal "%s"))'):format(file_ic))

    -- ── Table cells ──
    add(('(element (STag) @conceal (#match? @conceal "<td") (#set! conceal "%s"))'):format(ic(icons.ui.LineMiddle)))
    add( '(element (ETag) @conceal (#match? @conceal "td") (#set! conceal ""))')
    add(('(element (STag) @conceal (#match? @conceal "<th") (#set! conceal "%s"))'):format(ic(icons.ui.LineBold)))
    add( '(element (ETag) @conceal (#match? @conceal "th") (#set! conceal ""))')

    -- ── Metadata comment ──
    add(('(Comment) @conceal (#set! conceal "%s")'):format(ic(icons.ui.Ellipsis)))

    -- ── Structured macros (no child captures) ──
    local macros = {
        { "info",    ic(icons.diagnostics.Information) },
        { "warning", ic(icons.diagnostics.Warning) },
        { "note",    ic(icons.ui.Pencil) },
        { "tip",     ic(icons.diagnostics.Hint) },
        { "code",    ic(icons.ui.Code) },
        { "status",  ic(icons.ui.Target) },
        { "expand",  ic(icons.ui.Triangle) },
        { "panel",   ic(icons.ui.Table) },
        { "anchor",  ic(icons.ui.BookMark) },
        { "toc",     ic(icons.ui.List) },
        { "mathblock", ic(icons.ui.MathBlock) },
        { "mathinline", ic(icons.ui.MathInline) },
    }
    for _, m in ipairs(macros) do
        add(('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "%s") (#set! conceal "%s"))'):format(m[1], m[2]))
    end
    add('(ac_element (ac_end_tag) @conceal (#match? @conceal "ac:structured-macro") (#set! conceal ""))')

    -- ── Task elements ──
    for _, tag in ipairs({ "ac:task-list", "ac:task-id", "ac:task-status", "ac:task-body" }) do
        add(('(ac_element (ac_start_tag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
        add(('(ac_element (ac_end_tag)   @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end
    -- ac:task (exact, not matching ac:task-*)
    add('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task>") (#set! conceal ""))')
    add('(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task>") (#set! conceal ""))')
    -- Task ID content hidden
    add('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-id") (content (CharData) @conceal) (#set! conceal ""))')
    -- Task checkboxes on CharData leaf (no parent capture)
    add(('(ac_element (content (CharData) @markup.list.unchecked) (#eq? @markup.list.unchecked "incomplete") (#set! conceal "%s"))'):format(ic(icons.ui.Circle)))
    add(('(ac_element (content (CharData) @markup.list.checked) (#eq? @markup.list.checked "complete") (#set! conceal "%s"))'):format(ic(icons.ui.BoxChecked)))
    -- Task body → space
    add('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-body") (#set! conceal " "))')

    -- ── Body/parameter tags hidden ──
    for _, tag in ipairs({ "ac:rich-text-body", "ac:plain-text-body", "ac:parameter" }) do
        add(('(ac_element (ac_start_tag) @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
        add(('(ac_element (ac_end_tag)   @conceal (#match? @conceal "%s") (#set! conceal ""))'):format(tag))
    end

    -- ── AC links/images ──
    add(('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:link") (#set! conceal "%s"))'):format(link_ic))
    add( '(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:link") (#set! conceal ""))')
    add(('(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:image") (#set! conceal "%s"))'):format(file_ic))
    add( '(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:image") (#set! conceal ""))')

    -- ── Emoticon ──
    add(('(ac_element (ac_empty_tag) @conceal (#match? @conceal "ac:emoticon") (#set! conceal "%s"))'):format(ic(icons.misc.Smiley)))

    -- ── CDATA hidden ──
    add('(CDSect (CDStart) @conceal (#set! conceal ""))')
    add('(CDSect (CDEnd) @conceal (#set! conceal ""))')

    -- ── ri: namespace hidden ──
    add('(ri_empty_tag) @conceal (#set! conceal "")')
    add('(ri_start_tag) @conceal (#set! conceal "")')
    add('(ri_end_tag) @conceal (#set! conceal "")')

    return table.concat(q, "\n")
end

return M
