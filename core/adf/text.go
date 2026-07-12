package adf

import (
	"strconv"
	"strings"
)

// ToText renders an ADF document to plain markdown-ish text, mirroring
// atlassian.adf.adf_to_text.
func ToText(doc *Node) string {
	var lines []string
	for _, node := range doc.Content {
		t := processNode(node)
		if t != "" {
			lines = append(lines, t)
		}
	}
	return strings.Join(lines, "\n\n")
}

func processNode(node *Node) string {
	if node == nil {
		return ""
	}
	switch node.Type {
	case "text":
		return node.Text
	case "paragraph":
		var texts []string
		for _, c := range node.Content {
			if t := processNode(c); t != "" {
				texts = append(texts, t)
			}
		}
		return strings.Join(texts, "")
	case "bulletList", "orderedList":
		var items []string
		for i, item := range node.Content {
			prefix := "- "
			if node.Type == "orderedList" {
				prefix = strconv.Itoa(i+1) + ". "
			}
			for _, c := range item.Content {
				if t := processNode(c); t != "" {
					items = append(items, prefix+t)
				}
			}
		}
		return strings.Join(items, "\n")
	case "heading":
		var texts []string
		for _, c := range node.Content {
			if t := processNode(c); t != "" {
				texts = append(texts, t)
			}
		}
		level := node.AttrInt("level", 1)
		return strings.Repeat("#", level) + " " + strings.Join(texts, "")
	case "codeBlock":
		var texts []string
		for _, c := range node.Content {
			if t := processNode(c); t != "" {
				texts = append(texts, t)
			}
		}
		lang := node.AttrStr("language", "")
		return "```" + lang + "\n" + strings.Join(texts, "") + "\n```"
	}
	if node.Content != nil {
		var texts []string
		for _, c := range node.Content {
			if t := processNode(c); t != "" {
				texts = append(texts, t)
			}
		}
		return strings.Join(texts, "\n")
	}
	return ""
}

// ExtractSection returns the text of the section under a heading matching
// section_name (case-insensitive substring), until the next heading.
func ExtractSection(doc *Node, sectionName string) string {
	if doc == nil || doc.Content == nil {
		return ""
	}
	inSection := false
	var content []string
	want := strings.ToLower(sectionName)
	for _, node := range doc.Content {
		if node.Type == "heading" {
			var h strings.Builder
			for _, c := range node.Content {
				if c.Type == "text" {
					h.WriteString(c.Text)
				}
			}
			if strings.Contains(strings.ToLower(h.String()), want) {
				inSection = true
				continue
			} else if inSection {
				break
			}
		} else if inSection {
			if t := processNode(node); t != "" {
				content = append(content, t)
			}
		}
	}
	return strings.Join(content, "\n\n")
}
