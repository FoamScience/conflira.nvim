package ir

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// fixtures are wire JSON captured from the Lua producer (atlassian.editor.ir).
// They are the parity oracle: the Go types must faithfully represent whatever
// the Lua build emits.
var fixtures = []string{"editor_ir.json", "board_ir.json"}

func load(t *testing.T, name string) ([]byte, *ProjectionIR) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	p, err := Decode(data)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	return data, p
}

// Every Lua-emitted fixture must decode and validate cleanly.
func TestFixturesValidate(t *testing.T) {
	for _, name := range fixtures {
		_, p := load(t, name)
		if errs := p.Validate(); len(errs) > 0 {
			for _, e := range errs {
				t.Errorf("%s: %v", name, e)
			}
		}
	}
}

// decode → encode → decode must be a structural fixed point, proving the Go IR
// types capture the full wire contract with no lossy fields.
func TestRoundTrip(t *testing.T) {
	for _, name := range fixtures {
		_, p1 := load(t, name)
		data2, err := Encode(p1)
		if err != nil {
			t.Fatalf("%s: encode: %v", name, err)
		}
		p2, err := Decode(data2)
		if err != nil {
			t.Fatalf("%s: re-decode: %v", name, err)
		}
		if !reflect.DeepEqual(p1, p2) {
			t.Errorf("%s: round-trip not stable", name)
		}
	}
}

// Assert the concrete decoration shape of the known editor fixture, including
// semantic style tokens (not Neovim highlight groups).
func TestEditorFixtureShape(t *testing.T) {
	_, p := load(t, "editor_ir.json")

	wantLines := []string{"Title", "", "hello bold and code", "", "one", "two"}
	if !reflect.DeepEqual(p.Lines, wantLines) {
		t.Errorf("lines = %v, want %v", p.Lines, wantLines)
	}

	byKind := p.MarksByKind()
	if byKind["highlight"] != 3 { // heading + strong + code
		t.Errorf("highlight marks = %d, want 3", byKind["highlight"])
	}
	if byKind["sign"] != 1 { // heading sign
		t.Errorf("sign marks = %d, want 1", byKind["sign"])
	}
	if byKind["inline_text"] != 2 { // two bullets
		t.Errorf("inline_text marks = %d, want 2", byKind["inline_text"])
	}

	tokens := p.StyleTokens()
	for _, want := range []string{"heading.2", "strong", "code"} {
		if !tokens[want] {
			t.Errorf("missing semantic style token %q (have %v)", want, tokens)
		}
	}
	// No raw Neovim highlight groups should leak into the wire contract.
	for _, leak := range []string{"AtlasStrong", "AtlasHeading2", "@markup.heading.2"} {
		if tokens[leak] {
			t.Errorf("Neovim highlight group %q leaked into IR (should be a token)", leak)
		}
	}
}
