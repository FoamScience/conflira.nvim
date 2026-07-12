package editor

import "conflira/core/adf"

// BlockSpec describes a block to insert.
type BlockSpec struct {
	Type  string         `json:"type"`
	Attrs map[string]any `json:"attrs,omitempty"`
}

func toInt(v any, def int) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	}
	return def
}

func clampi(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func emptyPara() *adf.Node { return &adf.Node{Type: "paragraph", Content: []*adf.Node{}} }

// newBlock builds a fresh empty block of the requested kind.
func newBlock(spec BlockSpec) *adf.Node {
	switch spec.Type {
	case "heading":
		lvl := clampi(toInt(spec.Attrs["level"], 1), 1, 6)
		return &adf.Node{Type: "heading", Attrs: map[string]any{"level": float64(lvl)}, Content: []*adf.Node{}}
	case "codeBlock":
		attrs := map[string]any{}
		if l, ok := spec.Attrs["language"]; ok {
			attrs["language"] = l
		}
		return &adf.Node{Type: "codeBlock", Attrs: attrs, Content: []*adf.Node{}}
	case "blockquote":
		return &adf.Node{Type: "blockquote", Content: []*adf.Node{emptyPara()}}
	case "panel":
		pt := "info"
		if v, ok := spec.Attrs["panelType"].(string); ok && v != "" {
			pt = v
		}
		return &adf.Node{Type: "panel", Attrs: map[string]any{"panelType": pt}, Content: []*adf.Node{emptyPara()}}
	case "rule":
		return &adf.Node{Type: "rule"}
	case "bulletList", "orderedList":
		return &adf.Node{Type: spec.Type, Content: []*adf.Node{{Type: "listItem", Content: []*adf.Node{emptyPara()}}}}
	case "taskList":
		return &adf.Node{Type: "taskList", Content: []*adf.Node{
			{Type: "taskItem", Attrs: map[string]any{"state": "TODO"}, Content: []*adf.Node{emptyPara()}}}}
	case "table":
		return newTable(clampi(toInt(spec.Attrs["rows"], 2), 1, 50), clampi(toInt(spec.Attrs["cols"], 2), 1, 20))
	default:
		return emptyPara()
	}
}

func newTable(rows, cols int) *adf.Node {
	var trows []*adf.Node
	for r := 0; r < rows; r++ {
		cellType := "tableCell"
		if r == 0 {
			cellType = "tableHeader"
		}
		var cells []*adf.Node
		for c := 0; c < cols; c++ {
			cells = append(cells, &adf.Node{Type: cellType, Content: []*adf.Node{emptyPara()}})
		}
		trows = append(trows, &adf.Node{Type: "tableRow", Content: cells})
	}
	return &adf.Node{Type: "table", Content: trows}
}

// caretInto descends a block to its first editable text position.
func caretInto(block *adf.Node, blockPath Path) (Path, int) {
	switch block.Type {
	case "paragraph", "heading", "codeBlock":
		return caretStart(block, blockPath)
	}
	for i, c := range block.Content {
		p := appendIdx(blockPath, i+1)
		switch c.Type {
		case "paragraph", "heading", "codeBlock", "listItem", "taskItem", "panel", "blockquote",
			"bulletList", "orderedList", "taskList", "tableRow", "tableCell", "tableHeader":
			return caretInto(c, p)
		}
	}
	return blockPath, 0
}

// ancestorOfType returns the path of the nearest ancestor (incl. the node at
// textPath) whose type matches, or nil.
func ancestorOfType(root *adf.Node, textPath Path, typ string) Path {
	for k := len(textPath); k >= 1; k-- {
		if n := NodeAt(root, textPath[:k]); n != nil && n.Type == typ {
			out := make(Path, k)
			copy(out, textPath[:k])
			return out
		}
	}
	return nil
}

// attrOwner maps an attribute to the block type that carries it.
var attrOwner = map[string]string{"level": "heading", "panelType": "panel", "language": "codeBlock"}

// SetAttr changes a block attribute (heading level, panel type, code language).
// Targets the nearest ancestor that owns the attribute, else the cursor's block.
func SetAttr(root *adf.Node, textPath Path, attr string, value any) {
	var target *adf.Node
	if owner := attrOwner[attr]; owner != "" {
		if p := ancestorOfType(root, textPath, owner); p != nil {
			target = NodeAt(root, p)
		}
	} else if len(textPath) >= 1 {
		target = NodeAt(root, textPath[:len(textPath)-1])
	}
	if target == nil {
		return
	}
	if target.Attrs == nil {
		target.Attrs = map[string]any{}
	}
	if attr == "level" {
		target.Attrs[attr] = float64(clampi(toInt(value, 1), 1, 6))
	} else {
		target.Attrs[attr] = value
	}
}

// InsertBlock inserts a new empty block after the current top-level block and
// returns the caret inside it.
func InsertBlock(root *adf.Node, textPath Path, spec BlockSpec) (Path, int) {
	nb := newBlock(spec)
	if len(textPath) < 1 {
		root.Content = append(root.Content, nb)
		return caretInto(nb, Path{len(root.Content)})
	}
	topIdx := textPath[0]
	root.Content = insertAt(root.Content, topIdx, nb)
	return caretInto(nb, Path{topIdx + 1})
}

// DeleteBlock removes the current top-level block; an emptied doc keeps one
// empty paragraph. Caret lands in the block that takes its place.
func DeleteBlock(root *adf.Node, textPath Path) (Path, int) {
	if len(textPath) < 1 || len(root.Content) == 0 {
		return textPath, 0
	}
	topIdx := textPath[0]
	root.Content = removeAt(root.Content, topIdx)
	if len(root.Content) == 0 {
		root.Content = []*adf.Node{emptyPara()}
		return Path{1}, 0
	}
	idx := topIdx
	if idx > len(root.Content) {
		idx = len(root.Content)
	}
	return caretInto(root.Content[idx-1], Path{idx})
}
