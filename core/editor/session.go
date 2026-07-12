package editor

import (
	"container/list"
	"strconv"
	"sync"

	"conflira/core/adf"
)

// Session is one open editor: the live ADF doc, its rendered IR, and the
// baseline snapshot for dirty tracking. Mutating methods (Apply/ApplyText) land
// in later phases; Phase 1 is read-only.
type Session struct {
	ID   string
	doc  *Doc
	ir   *EditorIR
	base *adf.Node // snapshot at open, for Dirty/diff
}

// IR returns the current rendered editor IR.
func (s *Session) IR() *EditorIR { return s.ir }

// ADF returns the live source-of-truth tree.
func (s *Session) ADF() *adf.Node { return s.doc.Root }

// Meta returns the submit metadata.
func (s *Session) Meta() Meta { return s.doc.Meta }

// Dirty reports whether the tree has diverged from the opened baseline.
func (s *Session) Dirty() bool { return !adfEqual(s.base, s.doc.Root) }

// rerender refreshes the cached IR from the live tree (called after mutations).
func (s *Session) rerender() *EditorIR {
	s.ir = Render(s.doc)
	return s.ir
}

// Store is an LRU registry of open editor sessions, so a crashed client can't
// leak unbounded memory. Safe for concurrent RPC handlers.
type Store struct {
	mu   sync.Mutex
	cap  int
	seq  int
	m    map[string]*Session
	lru  *list.List               // front = most-recently-used; values are ids
	elem map[string]*list.Element // id → its lru element
}

// NewStore creates a session store holding at most `capacity` sessions.
func NewStore(capacity int) *Store {
	if capacity < 1 {
		capacity = 32
	}
	return &Store{
		cap:  capacity,
		m:    map[string]*Session{},
		lru:  list.New(),
		elem: map[string]*list.Element{},
	}
}

// Open renders the doc, registers a new session, and evicts the LRU if over cap.
func (st *Store) Open(d *Doc) *Session {
	st.mu.Lock()
	defer st.mu.Unlock()

	st.seq++
	id := "ed-" + strconv.Itoa(st.seq)
	s := &Session{ID: id, doc: d, base: cloneADF(d.Root)}
	s.rerender()

	st.m[id] = s
	st.elem[id] = st.lru.PushFront(id)
	for st.lru.Len() > st.cap {
		oldest := st.lru.Back()
		if oldest == nil {
			break
		}
		oid := oldest.Value.(string)
		st.lru.Remove(oldest)
		delete(st.m, oid)
		delete(st.elem, oid)
	}
	return s
}

// Get returns a session and marks it most-recently-used.
func (st *Store) Get(id string) (*Session, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	s, ok := st.m[id]
	if ok {
		if e := st.elem[id]; e != nil {
			st.lru.MoveToFront(e)
		}
	}
	return s, ok
}

// Close frees a session.
func (st *Store) Close(id string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if e := st.elem[id]; e != nil {
		st.lru.Remove(e)
	}
	delete(st.m, id)
	delete(st.elem, id)
}
