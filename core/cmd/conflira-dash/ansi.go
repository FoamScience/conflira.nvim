package main

import (
	"strings"

	"conflira/core/board"
	"conflira/core/ir"
)

// sgr maps IR style tokens to ANSI SGR params. Basic 16 colors, so the
// terminal theme decides the actual palette (the theme.lua counterpart).
var sgr = map[string]string{
	"heading.1": "1;35", "heading.2": "1;34", "heading.3": "1;36",
	"title": "1", "strong": "1", "emphasis": "3", "underline": "4", "strike": "9",
	"comment": "2", "muted": "2", "link": "4;34", "code": "36",
	"search": "7", "statusline": "7",
	"accent.fn": "34", "accent.id": "36", "accent.type": "32",
	"accent.number": "33", "accent.special": "35", "accent.constant": "35",
	"diff.add": "32", "diff.change": "33", "diff.delete": "31",
	"error": "31", "warn": "33", "ok": "32", "info": "36", "hint": "36", "unnecessary": "2",
}

func style(tok string) string {
	if c, ok := sgr[tok]; ok {
		return "\x1b[" + c + "m"
	}
	return ""
}

func chunkTok(c ir.Chunk) string {
	if len(c) > 1 {
		return c[1]
	}
	return ""
}

func pad(s string, n int) string {
	if gap := n - board.DisplayWidth(s); gap > 0 {
		return s + strings.Repeat(" ", gap)
	}
	return s
}

// marksByLine indexes marks per line and returns the sign gutter width.
func marksByLine(doc *ir.ProjectionIR) (map[int][]ir.Mark, int) {
	byLine := map[int][]ir.Mark{}
	gutter := 0
	for _, m := range doc.Marks {
		byLine[m.Line] = append(byLine[m.Line], m)
		if m.Kind == "sign" {
			gutter = max(gutter, board.DisplayWidth(m.Text))
		}
	}
	return byLine, gutter
}

// renderLine draws one IR line as ANSI text padded to width: sign gutter,
// highlights, inline and right-aligned virtual text. base is re-applied after
// every reset (cursor-line reverse video).
func renderLine(line string, marks []ir.Mark, gutter, width int, base string) string {
	styles := make([]string, len(line))
	inserts := map[int][]ir.Chunk{}
	var sign ir.Mark
	var right []ir.Chunk
	for _, m := range marks {
		switch m.Kind {
		case "highlight":
			end := len(line)
			if m.EndCol != nil && *m.EndCol < end {
				end = *m.EndCol
			}
			for c := m.Col; c < end; c++ {
				styles[c] = m.Hl
			}
		case "sign":
			sign = m
		case "inline_text":
			col := min(m.Col, len(line))
			inserts[col] = append(inserts[col], m.Chunks...)
		case "eol_text":
			right = append(right, m.Chunks...)
		}
	}

	reset := "\x1b[0m" + base
	var b strings.Builder
	b.WriteString(reset)
	w := 0
	put := func(text, tok string) {
		b.WriteString(style(tok) + text + reset)
		w += board.DisplayWidth(text)
	}

	put(pad(sign.Text, gutter), sign.Hl)
	for i := 0; i <= len(line); {
		for _, c := range inserts[i] {
			put(c[0], chunkTok(c))
		}
		if i == len(line) {
			break
		}
		j := i + 1
		for j < len(line) && styles[j] == styles[i] && len(inserts[j]) == 0 {
			j++
		}
		put(line[i:j], styles[i])
		i = j
	}

	if len(right) > 0 {
		rw := 0
		for _, c := range right {
			rw += board.DisplayWidth(c[0])
		}
		put(strings.Repeat(" ", max(1, width-w-rw)), "")
		for _, c := range right {
			put(c[0], chunkTok(c))
		}
	}
	if w < width {
		b.WriteString(strings.Repeat(" ", width-w))
	}
	b.WriteString("\x1b[0m")
	return b.String()
}
