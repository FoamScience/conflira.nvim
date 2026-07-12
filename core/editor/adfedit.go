package editor

import (
	"strings"

	"conflira/core/adf"
)

// NodeAt resolves a 1-based ADF path ({1} = doc.Content[0]) to its node, or nil.
func NodeAt(root *adf.Node, p Path) *adf.Node {
	n := root
	for _, idx := range p {
		if n == nil || idx < 1 || idx > len(n.Content) {
			return nil
		}
		n = n.Content[idx-1]
	}
	return n
}

// editableBlock reports whether a block's text can be reconciled from the buffer
// in Phase 2 (single text run; no inline-prefix in the buffer text).
func editableBlock(t string) bool {
	switch t {
	case "paragraph", "heading", "codeBlock":
		return true
	}
	return false
}

// setBlockText rebuilds a block's content from plain buffer text, preserving the
// block type and attrs. Newlines map to hardBreaks (paragraph) or are kept
// verbatim (codeBlock); headings collapse to a single line.
//
// NOTE: inline marks in the edited block are flattened to plain text — Phase 3's
// toggleMark restores rich inline editing. Unedited blocks are untouched.
func setBlockText(block *adf.Node, text string) {
	switch block.Type {
	case "heading":
		block.Content = []*adf.Node{{Type: "text", Text: strings.ReplaceAll(text, "\n", " ")}}
	case "codeBlock":
		block.Content = []*adf.Node{{Type: "text", Text: text}}
	case "paragraph":
		var content []*adf.Node
		for i, part := range strings.Split(text, "\n") {
			if i > 0 {
				content = append(content, &adf.Node{Type: "hardBreak"})
			}
			if part != "" {
				content = append(content, &adf.Node{Type: "text", Text: part})
			}
		}
		if content == nil {
			content = []*adf.Node{}
		}
		block.Content = content
	}
}
