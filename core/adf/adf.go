// Package adf is the Atlassian Document Format model: the source tree the
// renderer walks to produce a Projection IR.
package adf

import "encoding/json"

// Mark is an inline styling mark on a text node (strong, em, code, link, ...).
type Mark struct {
	Type  string         `json:"type"`
	Attrs map[string]any `json:"attrs,omitempty"`
}

// Node is an ADF node. Block nodes have Content; text nodes have Text/Marks.
type Node struct {
	Type    string         `json:"type"`
	Attrs   map[string]any `json:"attrs,omitempty"`
	Content []*Node        `json:"content,omitempty"`
	Text    string         `json:"text,omitempty"`
	Marks   []Mark         `json:"marks,omitempty"`
}

// Decode parses an ADF document from JSON.
func Decode(data []byte) (*Node, error) {
	var n Node
	if err := json.Unmarshal(data, &n); err != nil {
		return nil, err
	}
	return &n, nil
}

// AttrInt returns an integer attribute (JSON numbers decode as float64).
func (n *Node) AttrInt(key string, def int) int {
	if n.Attrs == nil {
		return def
	}
	if v, ok := n.Attrs[key].(float64); ok {
		return int(v)
	}
	return def
}

// AttrStr returns a string attribute, or def if absent.
func (n *Node) AttrStr(key, def string) string {
	if n.Attrs == nil {
		return def
	}
	if v, ok := n.Attrs[key].(string); ok {
		return v
	}
	return def
}

// MarkAttrStr returns a string attribute of a mark, or def if absent.
func (m Mark) AttrStr(key, def string) string {
	if m.Attrs == nil {
		return def
	}
	if v, ok := m.Attrs[key].(string); ok {
		return v
	}
	return def
}
