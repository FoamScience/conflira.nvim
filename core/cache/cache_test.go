package cache

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

// The Go cache must read the exact on-disk format the Lua plugin writes.
func TestCacheFormatCompat(t *testing.T) {
	c := New(filepath.Join("..", "testdata", "logic", "cache.json"), 1<<62) // huge TTL
	c.Now = func() int64 { return 1780387369 }                              // match fixture timestamp

	data, ok := c.Get("issue_types_PROJ")
	if !ok {
		t.Fatal("issue_types_PROJ missing")
	}
	var types []string
	json.Unmarshal(data, &types)
	if len(types) != 3 || types[0] != "Task" {
		t.Errorf("data: %v", types)
	}

	data, ok = c.Get("greeting")
	if !ok || string(data) != `"hello"` {
		t.Errorf("greeting: %q ok=%v", data, ok)
	}
}

func TestTTLExpiry(t *testing.T) {
	now := int64(1000)
	c := New(filepath.Join(t.TempDir(), "cache.json"), 300)
	c.Now = func() int64 { return now }

	c.Set("k", json.RawMessage(`{"v":1}`), "")
	if _, ok := c.Get("k"); !ok {
		t.Fatal("fresh entry should hit")
	}
	now += 301 // past TTL
	if _, ok := c.Get("k"); ok {
		t.Fatal("expired entry should miss")
	}
	// and a fresh Cache (memory cleared) also misses on disk → invalidated.
	c2 := New(c.Path, 300)
	c2.Now = func() int64 { return now }
	if _, ok := c2.Get("k"); ok {
		t.Fatal("expired entry should miss after reload")
	}
}

func TestGetOrFetch(t *testing.T) {
	now := int64(1000)
	c := New(filepath.Join(t.TempDir(), "cache.json"), 300)
	c.Now = func() int64 { return now }

	calls := 0
	fetch := func() (json.RawMessage, error) { calls++; return json.RawMessage(`42`), nil }

	for i := 0; i < 3; i++ {
		v, err := c.GetOrFetch("n", "", fetch)
		if err != nil || string(v) != "42" {
			t.Fatalf("got %q err %v", v, err)
		}
	}
	if calls != 1 {
		t.Errorf("fetcher called %d times, want 1 (cached)", calls)
	}
}

func TestInvalidateScopeAndClear(t *testing.T) {
	c := New(filepath.Join(t.TempDir(), "cache.json"), 1<<62)
	c.Set("a", json.RawMessage(`1`), "PROJ")
	c.Set("b", json.RawMessage(`2`), "OTHER")
	c.Set("c", json.RawMessage(`3`), "PROJ")

	c.InvalidateScope("PROJ")
	if _, ok := c.Get("a"); ok {
		t.Error("a (PROJ) should be gone")
	}
	if _, ok := c.Get("b"); !ok {
		t.Error("b (OTHER) should remain")
	}
	if c.Stats().Entries != 1 {
		t.Errorf("entries: %d, want 1", c.Stats().Entries)
	}

	c.Clear()
	if c.Stats().Entries != 0 {
		t.Errorf("after clear: %d entries", c.Stats().Entries)
	}
}
