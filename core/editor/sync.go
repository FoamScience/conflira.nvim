package editor

import (
	"fmt"
	"strconv"
	"strings"
)

// ApplyText reconciles a full edited buffer back into the ADF (the typing path).
// The editor renders without hard-wrap, so each editable block occupies a stable
// line range. Two reconciliation kinds:
//   - text blocks (paragraph/heading/codeBlock, at any nesting incl. table cells'
//     paragraphs): rebuild from the block's buffer line range.
//   - table rows (cells share a line via " │ " delimiters): re-split the row line
//     and update each cell.
//
// Structural changes (line count differs) are rejected — those come via ops.
func (s *Session) ApplyText(newLines []string, at Cursor) (*EditorIR, Cursor, error) {
	old := s.ir
	if len(newLines) != len(old.Lines) {
		return s.ir, at, fmt.Errorf("line count changed (%d→%d): structural edits require an op",
			len(old.Lines), len(newLines))
	}
	root := s.doc.Root
	changed := false

	blockRange := map[string]*lineRange{}
	blockPaths := map[string]Path{}
	rowLine := map[int]Path{} // table-row line → row path

	for i := range old.Spans {
		sp := &old.Spans[i]
		if !sp.Editable || sp.Field != "text" {
			continue
		}
		node := NodeAt(root, sp.Path)
		if node == nil {
			continue
		}
		switch node.Type {
		case "tableCell", "tableHeader":
			rp := make(Path, len(sp.Path)-1)
			copy(rp, sp.Path[:len(sp.Path)-1])
			rowLine[sp.Line] = rp
		case "text":
			addBlockSpan(blockRange, blockPaths, sp.Path[:len(sp.Path)-1], sp.Line)
		default:
			if isTextBlock(node.Type) { // empty-block caret anchor
				addBlockSpan(blockRange, blockPaths, sp.Path, sp.Line)
			}
		}
	}

	// Text blocks.
	for key, r := range blockRange {
		bp := blockPaths[key]
		block := NodeAt(root, bp)
		if block == nil || !editableBlock(block.Type) {
			continue
		}
		oldText := joinLines(old.Lines, r.lo, r.hi)
		newText := joinLines(newLines, r.lo, r.hi)
		if oldText != newText {
			setBlockText(block, newText)
			changed = true
		}
	}

	// Table rows.
	for line, rp := range rowLine {
		row := NodeAt(root, rp)
		if row == nil {
			continue
		}
		cells := splitTableRow(newLines[line])
		if len(cells) != len(row.Content) {
			continue // unexpected shape; leave it to a re-render
		}
		for ci, cell := range row.Content {
			if cellText(cell) != cells[ci] {
				setCellText(cell, cells[ci])
				changed = true
			}
		}
	}

	if changed {
		s.rerender()
	}
	return s.ir, at, nil
}

type lineRange struct{ lo, hi int }

func addBlockSpan(rngs map[string]*lineRange, paths map[string]Path, bp Path, line int) {
	key := pathKey(bp)
	if r := rngs[key]; r != nil {
		if line < r.lo {
			r.lo = line
		}
		if line > r.hi {
			r.hi = line
		}
		return
	}
	rngs[key] = &lineRange{line, line}
	paths[key] = bp
}

func pathKey(p Path) string {
	parts := make([]string, len(p))
	for i, x := range p {
		parts[i] = strconv.Itoa(x)
	}
	return strings.Join(parts, ".")
}

func joinLines(lines []string, lo, hi int) string {
	if lo < 0 || hi >= len(lines) || lo > hi {
		return ""
	}
	out := lines[lo]
	for i := lo + 1; i <= hi; i++ {
		out += "\n" + lines[i]
	}
	return out
}
