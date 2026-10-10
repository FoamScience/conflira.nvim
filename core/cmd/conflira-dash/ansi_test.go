package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"conflira/core/ir"
)

var sgrRe = regexp.MustCompile("\x1b\\[[0-9;]*m")

func plain(s string) string { return sgrRe.ReplaceAllString(s, "") }

func TestRenderLine(t *testing.T) {
	end := 5
	marks := []ir.Mark{
		{Kind: "sign", Text: "●", Hl: "error"},
		{Kind: "highlight", Col: 0, EndCol: &end, Hl: "accent.id"},
		{Kind: "inline_text", Col: 6, Chunks: []ir.Chunk{{"◆ ", "heading.2"}}},
		{Kind: "eol_text", Chunks: []ir.Chunk{{"Done", "diff.add"}}},
	}
	got := renderLine("PRJ-1 title", marks, 2, 30, "")
	want := "● PRJ-1 ◆ title" + strings.Repeat(" ", 30-15-4) + "Done"
	if p := plain(got); p != want {
		t.Fatalf("plain text\n got %q\nwant %q", p, want)
	}
	if !strings.Contains(got, "\x1b[36mPRJ-1") || !strings.Contains(got, "\x1b[32mDone") {
		t.Fatalf("missing styles: %q", got)
	}
}

func TestRenderLineInlinePastEOL(t *testing.T) {
	marks := []ir.Mark{{Kind: "inline_text", Col: 99, Chunks: []ir.Chunk{{"tail"}}}}
	if p := plain(renderLine("ab", marks, 0, 0, "")); p != "abtail" {
		t.Fatalf("got %q", p)
	}
}

func TestRenderBoardFixtures(t *testing.T) {
	files, _ := filepath.Glob("../../testdata/cases_board/*.ir.json")
	if len(files) == 0 {
		t.Fatal("no board fixtures")
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		doc, err := ir.Decode(data)
		if err != nil {
			t.Fatal(err)
		}
		marks, gutter := marksByLine(doc)
		for i, l := range doc.Lines {
			p := plain(renderLine(l, marks[i], gutter, 120, ""))
			for _, word := range strings.Fields(l) {
				if !strings.Contains(p, word) {
					t.Errorf("%s line %d: %q lost %q", filepath.Base(f), i, p, word)
				}
			}
		}
	}
}
