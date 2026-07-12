// Package cache ports the file-backed TTL cache (atlassian/cache.lua): a JSON
// file of { key: {data, timestamp, scope} } with a memory layer in front. The
// on-disk format is identical to the Lua plugin's, so the Go core and Neovim can
// share the same cache.json.
package cache

import (
	"encoding/json"
	"os"
	"time"
)

// Entry is one cached value with its insertion time and optional scope.
type Entry struct {
	Data      json.RawMessage `json:"data"`
	Timestamp int64           `json:"timestamp"`
	Scope     string          `json:"scope,omitempty"`
}

// Cache is a file-backed TTL cache.
type Cache struct {
	Path string
	TTL  int64 // seconds
	// Now is injectable for deterministic tests; defaults to wall clock.
	Now func() int64

	memory map[string]Entry
}

// New creates a cache backed by path with the given TTL (seconds).
func New(path string, ttlSeconds int64) *Cache {
	return &Cache{Path: path, TTL: ttlSeconds, memory: map[string]Entry{}}
}

func (c *Cache) now() int64 {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now().Unix()
}

func (c *Cache) loadDisk() map[string]Entry {
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return map[string]Entry{}
	}
	var m map[string]Entry
	if json.Unmarshal(data, &m) != nil {
		return map[string]Entry{}
	}
	return m
}

func (c *Cache) saveDisk(m map[string]Entry) {
	if b, err := json.Marshal(m); err == nil {
		_ = os.WriteFile(c.Path, b, 0o644)
	}
}

// Get returns the cached value for key if present and not expired (TTL). A
// memory miss falls back to disk; an expired entry is invalidated.
func (c *Cache) Get(key string) (json.RawMessage, bool) {
	entry, ok := c.memory[key]
	if !ok {
		disk := c.loadDisk()
		entry, ok = disk[key]
		if ok {
			c.memory[key] = entry
		}
	}
	if !ok {
		return nil, false
	}
	if c.now()-entry.Timestamp > c.TTL {
		c.Invalidate(key)
		return nil, false
	}
	return entry.Data, true
}

// Set stores data under key with the current timestamp and optional scope.
func (c *Cache) Set(key string, data json.RawMessage, scope string) {
	entry := Entry{Data: data, Timestamp: c.now(), Scope: scope}
	c.memory[key] = entry
	disk := c.loadDisk()
	disk[key] = entry
	c.saveDisk(disk)
}

// Invalidate removes a single key.
func (c *Cache) Invalidate(key string) {
	delete(c.memory, key)
	disk := c.loadDisk()
	delete(disk, key)
	c.saveDisk(disk)
}

// InvalidateScope removes all entries with the given scope (or all entries when
// scope is "").
func (c *Cache) InvalidateScope(scope string) {
	for k, e := range c.memory {
		if scope == "" || e.Scope == scope {
			delete(c.memory, k)
		}
	}
	disk := c.loadDisk()
	for k, e := range disk {
		if scope == "" || e.Scope == scope {
			delete(disk, k)
		}
	}
	c.saveDisk(disk)
}

// Clear empties the cache.
func (c *Cache) Clear() {
	c.memory = map[string]Entry{}
	c.saveDisk(map[string]Entry{})
}

// GetOrFetch returns the cached value, or calls fetch, caches, and returns it.
func (c *Cache) GetOrFetch(key, scope string, fetch func() (json.RawMessage, error)) (json.RawMessage, error) {
	if data, ok := c.Get(key); ok {
		return data, nil
	}
	data, err := fetch()
	if err != nil {
		return nil, err
	}
	c.Set(key, data, scope)
	return data, nil
}

// Stats reports the entry count and file size.
type Stats struct {
	Entries   int   `json:"entries"`
	SizeBytes int64 `json:"size_bytes"`
}

// Stats returns the on-disk entry count and file size.
func (c *Cache) Stats() Stats {
	disk := c.loadDisk()
	var size int64
	if fi, err := os.Stat(c.Path); err == nil {
		size = fi.Size()
	}
	return Stats{Entries: len(disk), SizeBytes: size}
}
