package board

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"conflira/core/ir"
)

func boardCases(t *testing.T) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join("..", "testdata", "cases_board", "*.board.json"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, m := range matches {
		names = append(names, strings.TrimSuffix(filepath.Base(m), ".board.json"))
	}
	sort.Strings(names)
	if len(names) == 0 {
		t.Fatal("no board parity cases (run: nvim --headless -c 'luafile core/testdata/gen_board.lua' -c qa)")
	}
	return names
}

func readCase(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "cases_board", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// The Go board pipeline must reproduce the frozen Lua board IR for each case.
func TestBoardParity(t *testing.T) {
	for _, name := range boardCases(t) {
		t.Run(name, func(t *testing.T) {
			in, err := DecodeInput(readCase(t, name+".board.json"))
			if err != nil {
				t.Fatalf("decode board input: %v", err)
			}
			want, err := ir.Decode(readCase(t, name+".ir.json"))
			if err != nil {
				t.Fatalf("decode expected ir: %v", err)
			}
			got := Build(BuildState(in))

			if !reflect.DeepEqual(got.Lines, want.Lines) {
				t.Errorf("lines mismatch:\n got: %#v\nwant: %#v", got.Lines, want.Lines)
			}
			if len(got.Marks) != len(want.Marks) {
				t.Errorf("mark count: got %d, want %d", len(got.Marks), len(want.Marks))
			}
			n := len(got.Marks)
			if len(want.Marks) < n {
				n = len(want.Marks)
			}
			for i := 0; i < n; i++ {
				if !reflect.DeepEqual(got.Marks[i], want.Marks[i]) {
					t.Errorf("mark[%d]:\n got: %+v\nwant: %+v", i, got.Marks[i], want.Marks[i])
				}
			}
		})
	}
}
