package editor

import (
	"strings"

	"conflira/core/adf"
)

// tableDelim is the cell separator the renderer joins with (" " + │ + " ").
const tableDelim = " │ "

// cellCoords decomposes a cell path [..table, rowIdx, cellIdx] into the table
// path and the 1-based row/cell indices.
func cellCoords(cellPath Path) (tablePath Path, rowIdx, cellIdx int, ok bool) {
	if len(cellPath) < 3 {
		return nil, 0, 0, false
	}
	tp := make(Path, len(cellPath)-2)
	copy(tp, cellPath[:len(cellPath)-2])
	return tp, cellPath[len(cellPath)-2], cellPath[len(cellPath)-1], true
}

func cellTypeOfRow(row *adf.Node) string {
	if len(row.Content) > 0 && row.Content[0].Type == "tableHeader" {
		return "tableHeader"
	}
	return "tableCell"
}

func tableCellOf(cellType string) *adf.Node {
	return &adf.Node{Type: cellType, Content: []*adf.Node{emptyPara()}}
}

func tableRowOf(cols int, cellType string) *adf.Node {
	var cells []*adf.Node
	for i := 0; i < cols; i++ {
		cells = append(cells, tableCellOf(cellType))
	}
	return &adf.Node{Type: "tableRow", Content: cells}
}

// cellText is a cell's concatenated inline text.
func cellText(cell *adf.Node) string {
	var b strings.Builder
	for _, blk := range cell.Content {
		for _, inl := range blk.Content {
			switch inl.Type {
			case "text":
				b.WriteString(inl.Text)
			case "hardBreak":
				b.WriteString("\n")
			case "mention":
				b.WriteString(mentionName(inl))
			}
		}
	}
	return b.String()
}

// setCellText replaces a cell's content with a single paragraph of plain text.
func setCellText(cell *adf.Node, text string) {
	if len(cell.Content) == 0 || cell.Content[0].Type != "paragraph" {
		cell.Content = []*adf.Node{emptyPara()}
	}
	p := cell.Content[0]
	if text == "" {
		p.Content = []*adf.Node{}
	} else {
		p.Content = []*adf.Node{{Type: "text", Text: text}}
	}
}

// splitTableRow reverses the renderer's row layout: split on the delimiter and
// trim each cell's padding.
func splitTableRow(line string) []string {
	parts := strings.Split(line, tableDelim)
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

// --- row / column operations ----------------------------------------------

// TableInsertRow inserts an empty row above/below the cursor's row.
func TableInsertRow(root *adf.Node, cellPath Path, below bool) (Path, int) {
	tablePath, rowIdx, _, ok := cellCoords(cellPath)
	if !ok {
		return cellPath, 0
	}
	table := NodeAt(root, tablePath)
	if table == nil || len(table.Content) == 0 {
		return cellPath, 0
	}
	cols := len(table.Content[0].Content)
	pos := rowIdx - 1
	if below {
		pos = rowIdx
	}
	table.Content = insertAt(table.Content, pos, tableRowOf(cols, "tableCell"))
	cp := appendIdx(appendIdx(tablePath, pos+1), 1)
	return caretInto(NodeAt(root, cp), cp)
}

// TableDeleteRow removes the cursor's row (no-op if it's the only row).
func TableDeleteRow(root *adf.Node, cellPath Path) (Path, int) {
	tablePath, rowIdx, _, ok := cellCoords(cellPath)
	if !ok {
		return cellPath, 0
	}
	table := NodeAt(root, tablePath)
	if table == nil || len(table.Content) <= 1 {
		return cellPath, 0
	}
	table.Content = removeAt(table.Content, rowIdx)
	idx := rowIdx
	if idx > len(table.Content) {
		idx = len(table.Content)
	}
	cp := appendIdx(appendIdx(tablePath, idx), 1)
	return caretInto(NodeAt(root, cp), cp)
}

// TableInsertCol inserts an empty column left/right of the cursor's column,
// matching each row's cell type (header row gets a header cell).
func TableInsertCol(root *adf.Node, cellPath Path, right bool) (Path, int) {
	tablePath, rowIdx, cellIdx, ok := cellCoords(cellPath)
	if !ok {
		return cellPath, 0
	}
	table := NodeAt(root, tablePath)
	if table == nil {
		return cellPath, 0
	}
	pos := cellIdx - 1
	if right {
		pos = cellIdx
	}
	for _, row := range table.Content {
		row.Content = insertAt(row.Content, pos, tableCellOf(cellTypeOfRow(row)))
	}
	cp := appendIdx(appendIdx(tablePath, rowIdx), pos+1)
	return caretInto(NodeAt(root, cp), cp)
}

// TableDeleteCol removes the cursor's column from every row (no-op if it's the
// only column).
func TableDeleteCol(root *adf.Node, cellPath Path) (Path, int) {
	tablePath, rowIdx, cellIdx, ok := cellCoords(cellPath)
	if !ok {
		return cellPath, 0
	}
	table := NodeAt(root, tablePath)
	if table == nil || len(table.Content) == 0 || len(table.Content[0].Content) <= 1 {
		return cellPath, 0
	}
	for _, row := range table.Content {
		row.Content = removeAt(row.Content, cellIdx)
	}
	idx := cellIdx
	if idx > len(table.Content[0].Content) {
		idx = len(table.Content[0].Content)
	}
	cp := appendIdx(appendIdx(tablePath, rowIdx), idx)
	return caretInto(NodeAt(root, cp), cp)
}
