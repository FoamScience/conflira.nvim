package adf

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestToTextParity verifies adf.ToText reproduces the Lua adf_to_text output.
func TestToTextParity(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "testdata", "logic", "adf_text.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases map[string]struct {
		ADF  json.RawMessage `json:"adf"`
		Text string          `json:"text"`
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no adf_text cases")
	}
	for name, c := range cases {
		doc, err := Decode(c.ADF)
		if err != nil {
			t.Errorf("%s: decode: %v", name, err)
			continue
		}
		if got := ToText(doc); got != c.Text {
			t.Errorf("%s:\n got: %q\nwant: %q", name, got, c.Text)
		}
	}
}
