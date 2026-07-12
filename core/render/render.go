// Package render ports the Lua projection renderer (atlassian/editor/render.lua)
// to Go: it walks an ADF tree and produces an editor-agnostic ir.ProjectionIR
// with semantic style tokens. It is verified to reproduce, byte-for-byte, the IR
// the frozen Lua build emits (see render_test.go and core/testdata/cases).
package render

import (
	"strconv"
	"strings"

	"conflira/core/adf"
	"conflira/core/ir"
)

const wrapWidth = 100

// Icon glyphs (must match atlassian/editor/extmarks.lua exactly).
var (
	headingIcons  = []string{"\U000F0CA1", "\U000F0CA3", "\U000F0CA5", "\U000F0CA7", "\U000F0CA9", "\U000F0CAB"}
	bulletIcon    = ""
	checkboxDone  = ""
	checkboxTodo  = "\U000F0131"
	blockquoteBar = "▎" // ▎
	hrChar        = "━" // ━
	panelIcons    = map[string]string{
		"info": "", "note": "\U000F03EB", "warning": "",
		"tip": "\U000F0336", "error": "",
	}
)

// Inline mark type → semantic style token (mirrors extmarks.mark_hl after token
// neutralization).
var markTok = map[string]string{
	"strong": "strong", "em": "emphasis", "code": "code",
	"strike": "strike", "underline": "underline", "link": "link", "subsup": "code",
}

type ctx struct {
	lines      []string
	marks      []ir.Mark
	spans      []ir.Span
	links      map[int][][]int // line → list of {col_start, col_end} (href tracked separately upstream)
	indent     int
	wrapW      int  // hard-wrap width; the editor uses a huge value (no wrap, client soft-wraps)
	editorMode bool // emit zero-width caret anchors for empty editable blocks
}

// emptyAnchor emits a zero-width editable text span so the cursor can land in an
// empty paragraph/heading (editor mode only — keeps Build parity untouched).
func (c *ctx) emptyAnchor(line int, path []int) {
	if c.editorMode {
		c.span(line, 0, 0, path, "text", true)
	}
}

func (c *ctx) appendLine(text string) int {
	text = strings.ReplaceAll(text, "\n", " ")
	idx := len(c.lines)
	c.lines = append(c.lines, text)
	return idx
}

func (c *ctx) cur() int { return len(c.lines) }

func (c *ctx) span(line, colStart, colEnd int, path []int, field string, editable bool) {
	c.spans = append(c.spans, ir.Span{
		Line: line, ColStart: colStart, ColEnd: colEnd, Path: path, Field: field, Editable: editable,
	})
}

func (c *ctx) highlight(line, col, endCol int, token string) {
	ec := endCol
	c.marks = append(c.marks, ir.Mark{Line: line, Col: col, Kind: "highlight", Hl: token, EndCol: &ec})
}

func (c *ctx) sign(line int, token, text string) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: 0, Kind: "sign", Text: text, Hl: token})
}

func (c *ctx) inline(line, col int, chunks []ir.Chunk, pos string) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: col, Kind: "inline_text", Chunks: chunks, Pos: pos})
}

func (c *ctx) virtLines(line int, lines []ir.Line, above bool) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: 0, Kind: "virt_lines", Lines: lines, Above: &above})
}

func pathAppend(path []int, idx int) []int {
	p := make([]int, len(path)+1)
	copy(p, path)
	p[len(path)] = idx
	return p
}

func mentionText(n *adf.Node) string {
	name := "user"
	if n.Attrs != nil {
		if v, ok := n.Attrs["text"].(string); ok {
			name = v
		}
	}
	if !strings.HasPrefix(name, "@") {
		name = "@" + name
	}
	return name
}

func collectInlineText(n *adf.Node) string {
	switch n.Type {
	case "text":
		return strings.ReplaceAll(n.Text, "\n", " ")
	case "hardBreak":
		return "\n"
	case "mention":
		return mentionText(n)
	}
	var b strings.Builder
	for _, c := range n.Content {
		b.WriteString(collectInlineText(c))
	}
	return b.String()
}

// renderInline places spans + marks for inline nodes on a single line.
func (c *ctx) renderInline(nodes []*adf.Node, baseLine, baseCol int, path []int) {
	col := baseCol
	for i, node := range nodes {
		childPath := pathAppend(path, i+1)
		switch node.Type {
		case "text":
			textLen := len(node.Text)
			c.span(baseLine, col, col+textLen, childPath, "text", true)
			for _, mark := range node.Marks {
				if tok, ok := markTok[mark.Type]; ok {
					c.highlight(baseLine, col, col+textLen, tok)
				}
			}
			col += textLen
		case "mention":
			name := mentionText(node)
			textLen := len(name)
			c.span(baseLine, col, col+textLen, childPath, "text", false)
			c.highlight(baseLine, col, col+textLen, "mention")
			col += textLen
		case "hardBreak":
			// newline handled at paragraph level
		}
	}
}

func wordWrap(text string, width int) ([]string, []int) {
	n := len(text)
	if n <= width {
		return []string{text}, []int{0}
	}
	var lines []string
	offsets := []int{0}
	pos := 1
	for pos <= n {
		if pos+width-1 >= n {
			lines = append(lines, text[pos-1:])
			break
		}
		chunkEnd := pos + width - 1
		breakAt := -1
		for i := chunkEnd; i >= pos; i-- {
			if text[i-1] == ' ' {
				breakAt = i
				break
			}
		}
		if breakAt >= 0 {
			lines = append(lines, text[pos-1:breakAt-1])
			pos = breakAt + 1
		} else {
			lines = append(lines, text[pos-1:chunkEnd])
			pos = chunkEnd + 1
		}
		offsets = append(offsets, pos-1)
	}
	return lines, offsets
}

type segment struct {
	offset    int
	length    int
	idx       int
	node      *adf.Node
	isMention bool
}

// renderInlineWrapped places spans + marks across wrapped lines.
func (c *ctx) renderInlineWrapped(nodes []*adf.Node, firstLine int, breakOffsets []int, wrapped []string, path []int) {
	var segments []segment
	offset := 0
	for i, node := range nodes {
		switch node.Type {
		case "text":
			t := strings.ReplaceAll(node.Text, "\n", " ")
			segments = append(segments, segment{offset: offset, length: len(t), idx: i + 1, node: node})
			offset += len(t)
		case "mention":
			name := mentionText(node)
			segments = append(segments, segment{offset: offset, length: len(name), idx: i + 1, node: node, isMention: true})
			offset += len(name)
		}
	}

	for _, seg := range segments {
		segStart := seg.offset
		segEnd := seg.offset + seg.length
		for li := 1; li <= len(wrapped); li++ {
			lineStart := breakOffsets[li-1]
			lineEnd := lineStart + len(wrapped[li-1])
			bufLine := firstLine + li - 1

			visStart := max(segStart, lineStart)
			visEnd := min(segEnd, lineEnd)
			if visStart < visEnd {
				colStart := visStart - lineStart
				colEnd := visEnd - lineStart
				childPath := pathAppend(path, seg.idx)
				c.span(bufLine, colStart, colEnd, childPath, "text", !seg.isMention)
				if seg.isMention {
					c.highlight(bufLine, colStart, colEnd, "mention")
				} else {
					for _, mark := range seg.node.Marks {
						if tok, ok := markTok[mark.Type]; ok {
							c.highlight(bufLine, colStart, colEnd, tok)
						}
					}
				}
			}
		}
	}
}

func (c *ctx) renderParagraph(node *adf.Node, path []int) {
	var b strings.Builder
	for _, child := range node.Content {
		b.WriteString(collectInlineText(child))
	}
	subLines := strings.Split(b.String(), "\n")
	for _, sub := range subLines {
		wrapped, offsets := wordWrap(sub, c.wrapW)
		firstLine := c.cur()
		for _, wl := range wrapped {
			c.appendLine(wl)
		}
		c.renderInlineWrapped(node.Content, firstLine, offsets, wrapped, path)
	}
	if len(node.Content) == 0 {
		c.emptyAnchor(c.cur()-1, path)
	}
}

func (c *ctx) renderHeading(node *adf.Node, path []int) {
	level := min(node.AttrInt("level", 1), 6)
	var b strings.Builder
	for _, child := range node.Content {
		b.WriteString(collectInlineText(child))
	}
	full := b.String()
	line := c.cur()
	c.appendLine(full)
	tok := "heading." + strconv.Itoa(level)
	c.highlight(line, 0, len(full), tok)
	c.sign(line, tok, headingIcons[level-1]+" ")
	c.renderInline(node.Content, line, 0, path)
	if len(node.Content) == 0 {
		c.emptyAnchor(line, path)
	}
}

func (c *ctx) renderList(node *adf.Node, path []int) {
	ordered := node.Type == "orderedList"
	for i, item := range node.Content {
		if item.Type != "listItem" {
			continue
		}
		itemPath := pathAppend(path, i+1)
		indentStr := strings.Repeat("  ", c.indent)
		for ci, child := range item.Content {
			childPath := pathAppend(itemPath, ci+1)
			switch child.Type {
			case "paragraph":
				var b strings.Builder
				for _, inl := range child.Content {
					b.WriteString(collectInlineText(inl))
				}
				full := indentStr + b.String()
				line := c.cur()
				c.appendLine(full)
				var prefix, prefixTok string
				if ordered {
					prefix = strconv.Itoa(i+1) + ". "
					prefixTok = "list.ordered"
				} else {
					prefix = bulletIcon + " "
					prefixTok = "list.bullet"
				}
				c.inline(line, 0, []ir.Chunk{{prefix, prefixTok}}, "inline")
				c.renderInline(child.Content, line, len(indentStr), childPath)
			case "bulletList", "orderedList":
				c.indent++
				c.renderList(child, childPath)
				c.indent--
			default:
				c.renderNode(child, childPath)
			}
		}
	}
}

func (c *ctx) renderTaskList(node *adf.Node, path []int) {
	for i, item := range node.Content {
		if item.Type != "taskItem" {
			continue
		}
		itemPath := pathAppend(path, i+1)
		isDone := item.AttrStr("state", "") == "DONE"
		for ci, child := range item.Content {
			childPath := pathAppend(itemPath, ci+1)
			if child.Type == "paragraph" {
				var b strings.Builder
				for _, inl := range child.Content {
					b.WriteString(collectInlineText(inl))
				}
				full := b.String()
				line := c.cur()
				c.appendLine(full)
				checkbox, checkboxTok := checkboxTodo, "task.todo"
				if isDone {
					checkbox, checkboxTok = checkboxDone, "task.done"
				}
				c.inline(line, 0, []ir.Chunk{{checkbox + " ", checkboxTok}}, "inline")
				if isDone {
					c.highlight(line, 0, len(full), "task.done")
				}
				c.renderInline(child.Content, line, 0, childPath)
			} else {
				c.renderNode(child, childPath)
			}
		}
	}
}

func (c *ctx) renderCodeBlock(node *adf.Node, path []int) {
	lang := node.AttrStr("language", "")
	var b strings.Builder
	for _, child := range node.Content {
		if child.Type == "text" {
			b.WriteString(child.Text)
		}
	}
	codeLines := strings.Split(b.String(), "\n")

	const bw = 40
	topBorder := "╭" + strings.Repeat("─", bw) + "╮" // ╭─╮
	botBorder := "╰" + strings.Repeat("─", bw) + "╯" // ╰─╯

	firstLine := c.cur()
	topChunks := []ir.Chunk{{topBorder, "code.border"}}
	if lang != "" {
		topChunks = append(topChunks, ir.Chunk{" " + lang, "code.lang"})
	}
	c.virtLines(firstLine, []ir.Line{topChunks}, true)

	for li, cl := range codeLines {
		line := c.cur()
		c.appendLine(cl)
		c.span(line, 0, len(cl), pathAppend(path, 1), "text", true)
		c.highlight(line, 0, len(cl), "code.block")
		c.inline(line, 0, []ir.Chunk{{"│ ", "code.border"}}, "inline") // │
		if li == len(codeLines)-1 {
			c.virtLines(line, []ir.Line{{{botBorder, "code.border"}}}, false)
		}
	}
	c.appendLine("")
}

func (c *ctx) renderBlockquote(node *adf.Node, path []int) {
	for i, child := range node.Content {
		childPath := pathAppend(path, i+1)
		if child.Type == "paragraph" {
			var b strings.Builder
			for _, inl := range child.Content {
				b.WriteString(collectInlineText(inl))
			}
			wrapped, offsets := wordWrap(b.String(), c.wrapW)
			firstLine := c.cur()
			for _, wl := range wrapped {
				line := c.cur()
				c.appendLine(wl)
				c.inline(line, 0, []ir.Chunk{{blockquoteBar + " ", "quote.bar"}}, "inline")
				c.highlight(line, 0, len(wl), "quote")
			}
			c.renderInlineWrapped(child.Content, firstLine, offsets, wrapped, path)
		} else {
			c.renderNode(child, childPath)
		}
	}
}

func (c *ctx) renderRule(node *adf.Node, path []int) {
	line := c.cur()
	c.appendLine("")
	ruleText := strings.Repeat(hrChar, 40)
	c.inline(line, 0, []ir.Chunk{{ruleText, "rule"}}, "overlay")
}

func (c *ctx) renderPanel(node *adf.Node, path []int) {
	panelType := node.AttrStr("panelType", "info")
	icon, ok := panelIcons[panelType]
	if !ok {
		icon = panelIcons["info"]
	}
	tok := "panel." + panelType
	if _, valid := panelIcons[panelType]; !valid {
		tok = "panel.info"
	}
	for i, child := range node.Content {
		childPath := pathAppend(path, i+1)
		if child.Type == "paragraph" {
			var b strings.Builder
			for _, inl := range child.Content {
				b.WriteString(collectInlineText(inl))
			}
			wrapped, offsets := wordWrap(b.String(), c.wrapW)
			firstLine := c.cur()
			for wi, wl := range wrapped {
				line := c.cur()
				c.appendLine(wl)
				if i == 0 && wi == 0 {
					c.sign(line, tok, icon+" ")
				}
				c.inline(line, 0, []ir.Chunk{{blockquoteBar + " ", tok}}, "inline")
			}
			c.renderInlineWrapped(child.Content, firstLine, offsets, wrapped, path)
		} else {
			c.renderNode(child, childPath)
		}
	}
}

func (c *ctx) renderMedia(node *adf.Node, path []int) {
	var media *adf.Node
	for _, child := range node.Content {
		if child.Type == "media" {
			media = child
			break
		}
	}
	label := "media"
	if media != nil && media.Attrs != nil {
		typ := media.AttrStr("type", "")
		alt := media.AttrStr("alt", "")
		url := media.AttrStr("url", "")
		id := media.AttrStr("id", "")
		switch {
		case typ == "external" && url != "":
			if alt != "" {
				label = alt
			} else {
				label = url
			}
		case id != "":
			if alt != "" {
				label = alt
			} else {
				label = id
			}
		default:
			if alt != "" {
				label = alt
			} else if url != "" {
				label = url
			} else if id != "" {
				label = id
			} else {
				label = "image"
			}
		}
	}
	line := c.cur()
	text := "[image: " + label + "]"
	c.appendLine(text)
	c.highlight(line, 0, len(text), "media")
}

func (c *ctx) renderTable(node *adf.Node, path []int) {
	rows := node.Content
	if len(rows) == 0 {
		return
	}
	type cell struct {
		text     string
		isHeader bool
		path     []int
		dw       int
	}
	grid := make([][]cell, len(rows))
	colWidths := []int{}
	for ri, row := range rows {
		cells := row.Content
		grid[ri] = make([]cell, len(cells))
		for ci, cl := range cells {
			var b strings.Builder
			for _, block := range cl.Content {
				for _, inl := range block.Content {
					b.WriteString(collectInlineText(inl))
				}
			}
			text := b.String()
			dw := displayWidth(text)
			grid[ri][ci] = cell{text: text, isHeader: cl.Type == "tableHeader", path: pathAppend(pathAppend(path, ri+1), ci+1), dw: dw}
			for len(colWidths) < ci+1 {
				colWidths = append(colWidths, 0)
			}
			colWidths[ci] = max(colWidths[ci], dw)
		}
	}
	numCols := len(colWidths)
	for i := range colWidths {
		colWidths[i] = max(colWidths[i], 3)
	}

	makeBorder := func(mid string) string {
		segs := make([]string, numCols)
		for ci := 0; ci < numCols; ci++ {
			segs[ci] = strings.Repeat("─", colWidths[ci]+2)
		}
		return strings.Join(segs, "─"+mid+"─")
	}
	topBorder := makeBorder("┬") // ┬
	midBorder := makeBorder("┼") // ┼
	botBorder := makeBorder("┴") // ┴

	delStr := " │ " // │
	delByteLen := len(delStr)

	for ri, rowData := range grid {
		var border string
		if ri == 0 {
			border = topBorder
		} else {
			prevHeader := len(grid[ri-1]) > 0 && grid[ri-1][0].isHeader
			curHeader := len(rowData) > 0 && rowData[0].isHeader
			if prevHeader && !curHeader {
				border = midBorder
			}
		}
		if border != "" {
			bl := c.cur()
			c.appendLine(border)
			c.highlight(bl, 0, len(border), "table.border")
		}

		line := c.cur()
		parts := make([]string, len(rowData))
		bytePos := 0
		for ci, cd := range rowData {
			padCount := colWidths[ci] - cd.dw
			padded := cd.text + strings.Repeat(" ", padCount)
			part := " " + padded + " "
			parts[ci] = part
			textStart := bytePos + 1
			textEnd := textStart + len(cd.text)
			c.span(line, textStart, textEnd, cd.path, "text", true)
			if cd.isHeader {
				c.highlight(line, textStart, textEnd, "table.header")
			}
			bytePos += len(part)
			if ci < numCols-1 {
				bytePos += delByteLen
			}
		}
		rowText := strings.Join(parts, delStr)
		c.appendLine(rowText)

		delPos := 0
		for ci := 0; ci < numCols-1; ci++ {
			delPos += len(parts[ci])
			c.highlight(line, delPos, delPos+delByteLen, "table.delimiter")
			delPos += delByteLen
		}

		if ri == len(grid)-1 {
			bl := c.cur()
			c.appendLine(botBorder)
			c.highlight(bl, 0, len(botBorder), "table.border")
		}
	}
	c.appendLine("")
}

func (c *ctx) renderNode(node *adf.Node, path []int) {
	if node == nil || node.Type == "" {
		return
	}
	switch node.Type {
	case "paragraph":
		c.renderParagraph(node, path)
	case "heading":
		c.renderHeading(node, path)
	case "bulletList", "orderedList":
		c.renderList(node, path)
	case "taskList":
		c.renderTaskList(node, path)
	case "codeBlock":
		c.renderCodeBlock(node, path)
	case "blockquote":
		c.renderBlockquote(node, path)
	case "rule":
		c.renderRule(node, path)
	case "panel":
		c.renderPanel(node, path)
	case "table":
		c.renderTable(node, path)
	case "mediaSingle":
		c.renderMedia(node, path)
	case "bodiedExtension", "extension":
		for i, child := range node.Content {
			c.renderNode(child, pathAppend(path, i+1))
		}
	}
}

var structural = map[string]bool{
	"heading": true, "codeBlock": true, "table": true,
	"bulletList": true, "orderedList": true, "taskList": true,
	"panel": true, "blockquote": true, "mediaSingle": true,
}

// Build walks an ADF doc and returns the Projection IR (lines, neutral marks,
// spans), matching atlassian.editor.render.build_ir.
func Build(doc *adf.Node) *ir.ProjectionIR { return build(doc, wrapWidth) }

// BuildEditable renders for the projection editor: no hard word-wrap (the client
// soft-wraps for display), so each block maps to a stable set of logical lines —
// which keeps the buffer↔ADF render-map reconcilable on edit.
func BuildEditable(doc *adf.Node) *ir.ProjectionIR {
	c := newCtx(1<<30, true)
	return c.run(doc)
}

func build(doc *adf.Node, wrapW int) *ir.ProjectionIR {
	return newCtx(wrapW, false).run(doc)
}

func newCtx(wrapW int, editor bool) *ctx {
	return &ctx{marks: []ir.Mark{}, spans: []ir.Span{}, links: map[int][][]int{}, wrapW: wrapW, editorMode: editor}
}

func (c *ctx) run(doc *adf.Node) *ir.ProjectionIR {
	if doc == nil || doc.Content == nil {
		return &ir.ProjectionIR{Lines: []string{""}, Marks: []ir.Mark{}, Spans: []ir.Span{}}
	}

	content := doc.Content
	for i, node := range content {
		c.renderNode(node, []int{i + 1})
		if i < len(content)-1 {
			next := content[i+1]
			switch {
			case node.Type == "rule" && next.Type == "heading":
				// tight: no spacing
			case node.Type == "heading":
				c.appendLine("")
			case structural[node.Type] || structural[next.Type]:
				c.appendLine("")
			}
		}
	}

	// Keep trailing empties in editor mode — a just-inserted empty block must
	// stay visible and caret-addressable.
	if !c.editorMode {
		for len(c.lines) > 1 && c.lines[len(c.lines)-1] == "" {
			c.lines = c.lines[:len(c.lines)-1]
		}
	}

	return &ir.ProjectionIR{Lines: c.lines, Marks: c.marks, Spans: c.spans}
}
