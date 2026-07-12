package editor

import (
	"strings"

	"conflira/core/adf"
)

// --- small tree helpers ----------------------------------------------------

func isTextBlock(t string) bool {
	switch t {
	case "paragraph", "heading", "codeBlock":
		return true
	}
	return false
}

func mentionName(n *adf.Node) string {
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

// nodeLen is an inline node's buffer length (text bytes / hardBreak newline /
// mention display name).
func nodeLen(n *adf.Node) int {
	switch n.Type {
	case "text":
		return len(n.Text)
	case "hardBreak":
		return 1
	case "mention":
		return len(mentionName(n))
	}
	return 0
}

// inlineLen is the total buffer length of a block's inline content.
func inlineLen(content []*adf.Node) int {
	t := 0
	for _, n := range content {
		t += nodeLen(n)
	}
	return t
}

func insertAt(s []*adf.Node, pos int, n *adf.Node) []*adf.Node {
	if pos < 0 {
		pos = 0
	}
	if pos > len(s) {
		pos = len(s)
	}
	s = append(s, nil)
	copy(s[pos+1:], s[pos:])
	s[pos] = n
	return s
}

// removeAt removes the 1-based index from a slice.
func removeAt(s []*adf.Node, oneBased int) []*adf.Node {
	i := oneBased - 1
	if i < 0 || i >= len(s) {
		return s
	}
	out := make([]*adf.Node, 0, len(s)-1)
	out = append(out, s[:i]...)
	out = append(out, s[i+1:]...)
	return out
}

func textNode(s string, marks []adf.Mark) *adf.Node {
	return &adf.Node{Type: "text", Text: s, Marks: marks}
}

// caretAt maps a byte offset within a block's inline text to a (text-node path,
// offset) caret. Falls back to the block's last text node, then the block path.
func caretAt(blockPath Path, block *adf.Node, off int) (Path, int) {
	acc := 0
	for i, n := range block.Content {
		l := nodeLen(n)
		if n.Type == "text" && off <= acc+l {
			return appendIdx(blockPath, i+1), off - acc
		}
		acc += l
	}
	for i := len(block.Content) - 1; i >= 0; i-- {
		if block.Content[i].Type == "text" {
			return appendIdx(blockPath, i+1), len(block.Content[i].Text)
		}
	}
	return blockPath, 0
}

// caretStart returns the caret at the start of a (possibly empty) block.
func caretStart(block *adf.Node, blockPath Path) (Path, int) {
	if len(block.Content) > 0 && block.Content[0].Type == "text" {
		return appendIdx(blockPath, 1), 0
	}
	return blockPath, 0
}

// --- split / merge ---------------------------------------------------------

// splitInline divides a block's inline content at (1-based node ti, byte offset)
// into the content that stays (left) and what moves to the new block (right).
func splitInline(content []*adf.Node, ti, offset int) (left, right []*adf.Node) {
	for i, n := range content {
		idx := i + 1
		switch {
		case idx < ti:
			left = append(left, n)
		case idx > ti:
			right = append(right, n)
		default:
			if n.Type == "text" {
				o := offset
				if o < 0 {
					o = 0
				}
				if o > len(n.Text) {
					o = len(n.Text)
				}
				if o > 0 {
					left = append(left, textNode(n.Text[:o], n.Marks))
				}
				if o < len(n.Text) {
					right = append(right, textNode(n.Text[o:], n.Marks))
				}
			} else if offset > 0 {
				left = append(left, n)
			} else {
				right = append(right, n)
			}
		}
	}
	return left, right
}

// Split splits the block containing textPath at offset. A top-level block splits
// into two siblings; a list-item block creates a new sibling list item. Returns
// the caret in the new block.
func Split(root *adf.Node, textPath Path, offset int) (Path, int) {
	if len(textPath) < 1 {
		return textPath, offset
	}
	blockPath := textPath[:len(textPath)-1]
	ti := textPath[len(textPath)-1]
	block := NodeAt(root, blockPath)
	if block == nil || len(blockPath) < 1 {
		return textPath, offset
	}
	parentPath := blockPath[:len(blockPath)-1]
	parent := NodeAt(root, parentPath)
	if parent == nil {
		return textPath, offset
	}
	blockIdx := blockPath[len(blockPath)-1]

	left, right := splitInline(block.Content, ti, offset)
	block.Content = left
	newBlock := &adf.Node{Type: block.Type, Attrs: block.Attrs, Content: right}

	if parent.Type == "listItem" {
		listPath := parentPath[:len(parentPath)-1]
		list := NodeAt(root, listPath)
		itemIdx := parentPath[len(parentPath)-1]
		newItem := &adf.Node{Type: "listItem", Content: []*adf.Node{newBlock}}
		list.Content = insertAt(list.Content, itemIdx, newItem)
		caretBlock := appendIdx(appendIdx(listPath, itemIdx+1), 1)
		return caretStart(newBlock, caretBlock)
	}

	parent.Content = insertAt(parent.Content, blockIdx, newBlock)
	return caretStart(newBlock, appendIdx(parentPath, blockIdx+1))
}

// Merge joins the block containing textPath into the previous sibling (Backspace
// at start-of-block). Top-level text blocks merge; the caret lands at the join.
// List-item and non-text-block merges are no-ops for now (Phase 3b/4).
func Merge(root *adf.Node, textPath Path) (Path, int) {
	if len(textPath) < 2 {
		return textPath, 0
	}
	blockPath := textPath[:len(textPath)-1]
	parentPath := blockPath[:len(blockPath)-1]
	parent := NodeAt(root, parentPath)
	block := NodeAt(root, blockPath)
	if parent == nil || block == nil || parent.Type == "listItem" {
		return textPath, 0
	}
	blockIdx := blockPath[len(blockPath)-1]
	if blockIdx <= 1 {
		return textPath, 0
	}
	prev := parent.Content[blockIdx-2]
	if !isTextBlock(prev.Type) || !isTextBlock(block.Type) {
		return textPath, 0
	}
	prevPath := appendIdx(parentPath, blockIdx-1)
	joinOff := inlineLen(prev.Content)
	prev.Content = append(prev.Content, block.Content...)
	parent.Content = removeAt(parent.Content, blockIdx)
	return caretAt(prevPath, prev, joinOff)
}

// --- task + marks ----------------------------------------------------------

// ToggleTask flips the nearest taskItem ancestor's state (TODO ↔ DONE).
func ToggleTask(root *adf.Node, textPath Path) {
	for k := len(textPath); k >= 1; k-- {
		n := NodeAt(root, textPath[:k])
		if n != nil && n.Type == "taskItem" {
			if n.Attrs == nil {
				n.Attrs = map[string]any{}
			}
			if n.AttrStr("state", "TODO") == "DONE" {
				n.Attrs["state"] = "TODO"
			} else {
				n.Attrs["state"] = "DONE"
			}
			return
		}
	}
}

func hasMark(marks []adf.Mark, t string) bool {
	for _, m := range marks {
		if m.Type == t {
			return true
		}
	}
	return false
}

func toggledMarks(marks []adf.Mark, t string, add bool) []adf.Mark {
	out := make([]adf.Mark, 0, len(marks)+1)
	for _, m := range marks {
		if m.Type != t {
			out = append(out, m)
		}
	}
	if add {
		out = append(out, adf.Mark{Type: t})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// charPos converts a (1-based node index, in-node offset) to a flat byte offset
// within a block's inline content.
func charPos(block *adf.Node, ti, off int) int {
	acc := 0
	for i, n := range block.Content {
		if i+1 == ti {
			return acc + off
		}
		acc += nodeLen(n)
	}
	return acc
}

// ToggleMark adds or removes an inline mark over a selection within ONE block
// (the common case). If every text run in the range already has the mark it is
// removed, else it is added; text nodes are split at the boundaries.
func ToggleMark(root *adf.Node, startPath Path, startOff int, endPath Path, endOff int, mark string) {
	if len(startPath) < 2 || len(endPath) < 2 {
		return
	}
	sBlock := startPath[:len(startPath)-1]
	if !pathEqual(sBlock, endPath[:len(endPath)-1]) {
		return // multi-block selection: Phase 3b
	}
	block := NodeAt(root, sBlock)
	if block == nil {
		return
	}
	s := charPos(block, startPath[len(startPath)-1], startOff)
	e := charPos(block, endPath[len(endPath)-1], endOff)
	if s > e {
		s, e = e, s
	}
	if s >= e {
		return
	}

	// Determine direction: add unless every covered text run already has it.
	allHave, pos := true, 0
	for _, n := range block.Content {
		l := nodeLen(n)
		if n.Type == "text" {
			a, b := maxi(s, pos), mini(e, pos+l)
			if a < b && !hasMark(n.Marks, mark) {
				allHave = false
			}
		}
		pos += l
	}
	add := !allHave

	var out []*adf.Node
	pos = 0
	for _, n := range block.Content {
		l := nodeLen(n)
		if n.Type != "text" {
			out = append(out, n)
			pos += l
			continue
		}
		ns, ne := pos, pos+l
		a, b := maxi(s, ns), mini(e, ne)
		if a >= b {
			out = append(out, n) // fully outside the range
		} else {
			if a > ns {
				out = append(out, textNode(n.Text[:a-ns], n.Marks))
			}
			out = append(out, textNode(n.Text[a-ns:b-ns], toggledMarks(n.Marks, mark, add)))
			if b < ne {
				out = append(out, textNode(n.Text[b-ns:], n.Marks))
			}
		}
		pos += l
	}
	block.Content = out
}

func maxi(a, b int) int {
	if a > b {
		return a
	}
	return b
}
func mini(a, b int) int {
	if a < b {
		return a
	}
	return b
}
