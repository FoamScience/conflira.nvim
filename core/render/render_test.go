package render

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"conflira/core/adf"
	"conflira/core/ir"
)

// cases discovers every <name>.adf.json under testdata/cases.
func cases(t *testing.T) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join("..", "testdata", "cases", "*.adf.json"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, m := range matches {
		base := filepath.Base(m)
		names = append(names, strings.TrimSuffix(base, ".adf.json"))
	}
	sort.Strings(names)
	if len(names) == 0 {
		t.Fatal("no parity cases found (run: nvim --headless -c 'luafile core/testdata/gen.lua' -c qa)")
	}
	return names
}

func readJSON(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "cases", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// The Go renderer must reproduce, exactly, the IR the frozen Lua build emits for
// every case.
func TestParity(t *testing.T) {
	for _, name := range cases(t) {
		t.Run(name, func(t *testing.T) {
			doc, err := adf.Decode(readJSON(t, name+".adf.json"))
			if err != nil {
				t.Fatalf("decode adf: %v", err)
			}
			want, err := ir.Decode(readJSON(t, name+".ir.json"))
			if err != nil {
				t.Fatalf("decode expected ir: %v", err)
			}
			got := Build(doc)

			if !reflect.DeepEqual(got.Lines, want.Lines) {
				t.Errorf("lines mismatch:\n got: %#v\nwant: %#v", got.Lines, want.Lines)
			}
			compareMarks(t, got.Marks, want.Marks)
			compareSpans(t, got.Spans, want.Spans)
		})
	}
}

func compareMarks(t *testing.T, got, want []ir.Mark) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("mark count: got %d, want %d", len(got), len(want))
	}
	n := len(got)
	if len(want) < n {
		n = len(want)
	}
	for i := 0; i < n; i++ {
		if !reflect.DeepEqual(got[i], want[i]) {
			t.Errorf("mark[%d]:\n got: %+v\nwant: %+v", i, got[i], want[i])
		}
	}
}

func compareSpans(t *testing.T, got, want []ir.Span) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("span count: got %d, want %d", len(got), len(want))
	}
	n := len(got)
	if len(want) < n {
		n = len(want)
	}
	for i := 0; i < n; i++ {
		if !reflect.DeepEqual(got[i], want[i]) {
			t.Errorf("span[%d]:\n got: %+v\nwant: %+v", i, got[i], want[i])
		}
	}
}
