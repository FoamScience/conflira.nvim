package board

import (
	"sort"
	"strconv"
	"strings"

	"conflira/core/ir"
)

// Style tokens (post-neutralization equivalents of the board's highlight groups).
var typeTok = map[string]string{
	"Epic": "heading.1", "Feature": "heading.2", "Bug": "error",
	"Issue": "heading.3", "Task": "accent.fn", "Sub-Task": "accent.id",
}

func typeTokOf(t string) string {
	if tok, ok := typeTok[t]; ok {
		return tok
	}
	return "accent.id"
}

type sign struct {
	text  string
	token string
}

var urgencySigns = map[string]sign{
	"overdue":  {"●", "error"},
	"blocked":  {"●", "error"},
	"due_soon": {"●", "warn"},
	"done":     {"●", "ok"},
	"stale":    {"○", "comment"},
	"normal":   {" ", "text"},
}

func statusBadgeTok(status string) string {
	s := strings.ToLower(status)
	switch {
	case strings.Contains(s, "done"), strings.Contains(s, "resolved"), strings.Contains(s, "closed"):
		return "diff.add"
	case strings.Contains(s, "progress"), strings.Contains(s, "review"), strings.Contains(s, "building"), strings.Contains(s, "testing"):
		return "diff.change"
	case strings.Contains(s, "block"), strings.Contains(s, "error"), strings.Contains(s, "fail"):
		return "diff.delete"
	}
	return "search"
}

func typeIcon(t string) string {
	if ic, ok := TypeIcons[t]; ok {
		return ic
	}
	if ic, ok := TypeIcons["Task"]; ok {
		return ic
	}
	return "◆"
}

type bctx struct {
	lines    []string
	marks    []ir.Mark
	lineKeys map[int]string    // buffer line -> issue key (for "open issue at cursor")
	icons    map[string]string // involvement kind -> glyph (set from State.Icons)
}

func (c *bctx) addLine(text string) int {
	idx := len(c.lines)
	c.lines = append(c.lines, text)
	return idx
}

func (c *bctx) cur() int { return len(c.lines) }

func (c *bctx) highlight(line, col, endCol int, token string) {
	ec := endCol
	c.marks = append(c.marks, ir.Mark{Line: line, Col: col, Kind: "highlight", Hl: token, EndCol: &ec})
}

func (c *bctx) sign(line int, token, text string) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: 0, Kind: "sign", Text: text, Hl: token})
}

func (c *bctx) inline(line, col int, chunks []ir.Chunk) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: col, Kind: "inline_text", Chunks: chunks, Pos: "inline"})
}

func (c *bctx) eol(line int, chunks []ir.Chunk) {
	c.marks = append(c.marks, ir.Mark{Line: line, Col: 0, Kind: "eol_text", Chunks: chunks, Align: "right_align"})
}

// hasInvolvement reports whether the issue carries the given relationship tag.
func hasInvolvement(is *Issue, kind string) bool {
	for _, k := range is.Involvement {
		if k == kind {
			return true
		}
	}
	return false
}

// involvementDw is the display width of an issue's trailing involvement icons
// (each " " + glyph), for keeping summaries aligned.
func involvementDw(is *Issue, icons map[string]string) int {
	w := 0
	for _, kind := range InvolvementKinds {
		if hasInvolvement(is, kind) {
			if g := icons[kind]; g != "" {
				w += dw(" " + g)
			}
		}
	}
	return w
}

// Build renders a board State to the Projection IR (matches board.build_ir).
func Build(st *State) *ir.ProjectionIR {
	doc, _ := BuildWithKeys(st)
	return doc
}

// BuildWithKeys renders the board and also returns a line→issue-key map, so a
// client can resolve the issue under the cursor.
func BuildWithKeys(st *State) (*ir.ProjectionIR, map[int]string) {
	c := &bctx{marks: []ir.Mark{}, lineKeys: map[int]string{}, icons: InvolvementIcons(st.Icons)}

	// title_col: summaries align at a fixed display column.
	maxKeyDw, maxDepth, maxInvDw := 0, 0, 0
	var scan func(nodes []*Node, d int)
	scan = func(nodes []*Node, d int) {
		for _, n := range nodes {
			if x := dw(n.Issue.Key); x > maxKeyDw {
				maxKeyDw = x
			}
			if x := involvementDw(n.Issue, c.icons); x > maxInvDw {
				maxInvDw = x
			}
			if d > maxDepth {
				maxDepth = d
			}
			if len(n.Children) > 0 {
				scan(n.Children, d+1)
			}
		}
	}
	scan(st.Tree, 0)
	if maxKeyDw < 8 {
		maxKeyDw = 8
	}
	deepestPrefix := 2 + 4*maxDepth + 4
	titleCol := deepestPrefix + 2 + maxKeyDw + 2 + maxInvDw

	// Summary bar.
	total, statusCounts, doneCount := WorkableStats(st.Issues)
	pct := 0
	filled := 0
	if total > 0 {
		pct = doneCount * 100 / total
		filled = doneCount * 10 / total
	}
	project := st.Project
	if project == "" {
		project = "Board"
	}
	header := " " + project + " │ " + strconv.Itoa(total) + " issues │ "
	l := c.addLine(header)
	c.highlight(l, 0, len(header), "title")

	progress := []ir.Chunk{}
	if filled > 0 {
		progress = append(progress, ir.Chunk{strings.Repeat("█", filled), "diff.add"})
	}
	if 10-filled > 0 {
		progress = append(progress, ir.Chunk{strings.Repeat("░", 10-filled), "diff.delete"})
	}
	progress = append(progress, ir.Chunk{" " + strconv.Itoa(pct) + "%", "title"})
	c.inline(l, len(header), progress)

	// Status breakdown, sorted by count desc (ties broken by name for determinism
	// — Lua relies on count only; names are unique per status here).
	type sc struct {
		name  string
		count int
	}
	var list []sc
	for name, count := range statusCounts {
		list = append(list, sc{name, count})
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].count != list[j].count {
			return list[i].count > list[j].count
		}
		return list[i].name < list[j].name
	})
	var statusParts []ir.Chunk
	for _, e := range list {
		statusParts = append(statusParts, ir.Chunk{" " + strconv.Itoa(e.count) + " " + e.name + " ", statusBadgeTok(e.name)})
	}
	if len(statusParts) > 0 {
		c.eol(l, statusParts)
	}

	// Separator.
	sep := strings.Repeat("━", 80)
	l = c.addLine(sep)
	c.highlight(l, 0, len(sep), "muted")

	// Groups.
	for _, group := range st.Groups {
		if group.Name != "" && group.Name != "All" {
			c.addLine("")
			gh := " ── " + group.Name + " " + strings.Repeat("─", maxInt(0, 74-len(group.Name)))
			l = c.addLine(gh)
			c.highlight(l, 0, len(gh), "heading.2")
		}
		c.addLine("")
		for ni, node := range group.Nodes {
			if ni > 0 {
				c.addLine("")
			}
			isLastRoot := ni == len(group.Nodes)-1
			c.renderNode(node, 0, isLastRoot, nil, titleCol)
		}
	}

	// Help bar.
	c.addLine("")
	help := " [e]dit [t]ransition [a]ssign [c]omment [/]search [g]roup [r]efresh [?]help"
	l = c.addLine(help)
	c.highlight(l, 0, len(help), "statusline")

	return &ir.ProjectionIR{Lines: c.lines, Marks: c.marks, Spans: []ir.Span{}}, c.lineKeys
}

func (c *bctx) renderNode(node *Node, depth int, isLast bool, ancestors []string, titleCol int) {
	issue := node.Issue
	ancestorPrefix := strings.Join(ancestors, "")

	treeChar := ""
	if depth > 0 {
		if isLast {
			treeChar = "└── "
		} else {
			treeChar = "├── "
		}
	}

	typeIconChar := typeIcon(issue.Type)
	typeIconStr := typeIconChar + " "
	typeHl := typeTokOf(issue.Type)

	expand := ""
	if len(node.Children) > 0 && depth == 0 {
		if node.Expanded {
			expand = "▼ "
		} else {
			expand = "▶ "
		}
	}

	keyText := issue.Key

	prefix := ancestorPrefix + treeChar + expand
	prefixDw := dw(prefix)
	// Involvement icons sit right after the key; reserve their display width so
	// the summaries still line up at titleCol.
	invIconDw := involvementDw(issue, c.icons)
	leftDw := prefixDw + 2 + dw(keyText) + invIconDw
	padToTitle := maxInt(2, titleCol-leftDw)
	keyPadded := keyText + strings.Repeat(" ", padToTitle)

	summary := issue.Summary
	const maxSummary = 70
	if len(summary) > maxSummary {
		summary = summary[:maxSummary-1] + "…"
	}

	main := keyPadded + summary
	header := prefix + main
	l := c.addLine(header)
	if c.lineKeys != nil {
		c.lineKeys[l] = issue.Key
	}

	urg, ok := urgencySigns[node.Urgency]
	if !ok {
		urg = urgencySigns["normal"]
	}
	c.sign(l, urg.token, urg.text+" ")

	ctxToken := func(tok string) string {
		if node.IsContext {
			return "comment"
		}
		return tok
	}

	c.inline(l, len(prefix), []ir.Chunk{{typeIconStr, ctxToken(typeHl)}})

	keyStart := len(prefix)
	keyEnd := keyStart + len(keyText)
	c.highlight(l, keyStart, keyEnd, ctxToken(typeTokOf(issue.Type)))

	// Involvement icons, immediately right of the key.
	if len(issue.Involvement) > 0 {
		var inv []ir.Chunk
		for _, kind := range InvolvementKinds {
			if hasInvolvement(issue, kind) {
				if g := c.icons[kind]; g != "" {
					inv = append(inv, ir.Chunk{" " + g, ctxToken(InvolvementColor)})
				}
			}
		}
		if len(inv) > 0 {
			c.inline(l, keyEnd, inv)
		}
	}

	sumStart := keyStart + len(keyPadded)
	sumEnd := sumStart + len(summary)
	if sumEnd > len(header) {
		sumEnd = len(header)
	}
	c.highlight(l, sumStart, sumEnd, ctxToken("text"))

	if len(ancestorPrefix) > 0 {
		c.highlight(l, 0, len(ancestorPrefix), "muted")
	}
	if len(treeChar) > 0 {
		tc := len(ancestorPrefix)
		c.highlight(l, tc, tc+len(treeChar), "muted")
	}

	// Right-aligned: [kind] + assignee + status.
	status := issue.Status
	assignee := issue.Assignee
	if assignee == "" {
		assignee = "unassigned"
	}
	var right []ir.Chunk
	if kind := EpicKindOf(issue); kind != nil {
		right = append(right, ir.Chunk{" " + kind.Icon + " " + kind.Name + " ", kind.Token})
	}
	right = append(right, ir.Chunk{" " + assignee + " ", "accent.constant"})
	right = append(right, ir.Chunk{" " + status + " ", statusBadgeTok(status)})
	c.eol(l, right)

	// Detail line.
	if node.Expanded || depth > 0 {
		var detailTree string
		if depth > 0 {
			if isLast {
				detailTree = ancestorPrefix + "    "
			} else {
				detailTree = ancestorPrefix + "│   "
			}
		} else {
			detailTree = "  │"
		}
		detailPad := maxInt(0, titleCol-dw(detailTree))
		detailPrefix := detailTree + strings.Repeat(" ", detailPad)

		var detail []ir.Chunk
		sep := func() {
			if len(detail) > 0 {
				detail = append(detail, ir.Chunk{" │ ", "muted"})
			}
		}

		switch Readiness(node) {
		case "ready":
			detail = append(detail, ir.Chunk{" ✓ ready", "ok"})
		case "shaping":
			detail = append(detail, ir.Chunk{" ◐ shaping", "warn"})
		}

		if cycle := CycleID(issue); cycle != "" {
			sep()
			detail = append(detail, ir.Chunk{cycle, "accent.special"})
		}

		var blockers []string
		for _, link := range issue.Links {
			blockedBy := strings.Contains(strings.ToLower(link.Label), "blocked by") ||
				(link.LinkType == "Blocks" && link.Direction == "inward")
			if blockedBy && link.IssueKey != "" {
				blockers = append(blockers, link.IssueKey)
			}
		}
		if len(blockers) > 0 {
			sep()
			detail = append(detail, ir.Chunk{"↑ blocked by " + strings.Join(blockers, ", "), "error"})
		}

		// Reviewer (from custom_fields_raw headings containing "review").
		custom := issue.CustomFields()
		for _, heading := range sortedKeys(custom) {
			if !strings.Contains(strings.ToLower(heading), "review") {
				continue
			}
			var name string
			switch v := custom[heading].(type) {
			case map[string]any:
				if dn, ok := v["displayName"].(string); ok {
					name = dn
				}
			case string:
				name = v
			}
			if name != "" {
				sep()
				detail = append(detail, ir.Chunk{name, "accent.type"})
			}
		}

		if len(node.Children) > 0 {
			done, total := SubtaskProgress(node)
			fill := 0
			if total > 0 {
				fill = done * 4 / total
			}
			detail = append(detail, ir.Chunk{" │ ", "muted"})
			detail = append(detail, ir.Chunk{strconv.Itoa(done) + "/" + strconv.Itoa(total) + " ", "accent.number"})
			if fill > 0 {
				detail = append(detail, ir.Chunk{strings.Repeat("█", fill), "diff.add"})
			}
			if 4-fill > 0 {
				detail = append(detail, ir.Chunk{strings.Repeat("░", 4-fill), "diff.delete"})
			}
		}

		if len(detail) > 0 {
			detail = append([]ir.Chunk{{"│ ", "muted"}}, detail...)
			dl := c.addLine(detailPrefix)
			if c.lineKeys != nil {
				c.lineKeys[dl] = issue.Key
			}
			c.highlight(dl, 0, len(detailPrefix), "muted")
			c.inline(dl, len(detailPrefix), detail)
		}
	}

	// Children.
	if node.Expanded {
		childAncestors := append([]string{}, ancestors...)
		if depth > 0 {
			if isLast {
				childAncestors = append(childAncestors, "    ")
			} else {
				childAncestors = append(childAncestors, "│   ")
			}
		} else {
			childAncestors = append(childAncestors, "  ")
		}
		for ci, child := range node.Children {
			c.renderNode(child, depth+1, ci == len(node.Children)-1, childAncestors, titleCol)
		}
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
