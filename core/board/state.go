package board

import (
	"regexp"
	"sort"
	"strings"
	"time"
)

var priorityOrder = map[string]int{"Highest": 1, "High": 2, "Medium": 3, "Low": 4, "Lowest": 5}
var urgencyOrder = map[string]int{"overdue": 1, "blocked": 2, "due_soon": 3, "normal": 4, "stale": 5, "done": 6}

func priorityRank(p string) int {
	if p == "" {
		return 99
	}
	if r, ok := priorityOrder[p]; ok {
		return r
	}
	return 99
}

func urgencyRank(u string) int {
	if r, ok := urgencyOrder[u]; ok {
		return r
	}
	return 4
}

func statusDone(s string) bool {
	s = strings.ToLower(s)
	return strings.Contains(s, "done") || strings.Contains(s, "resolved") || strings.Contains(s, "closed")
}

// computeUrgency mirrors state.lua compute_urgency.
func computeUrgency(issue *Issue) string {
	status := strings.ToLower(issue.Status)
	if strings.Contains(status, "block") || strings.Contains(status, "error") || strings.Contains(status, "fail") {
		return "blocked"
	}
	if statusDone(issue.Status) {
		return "done"
	}
	for _, link := range issue.Links {
		blockedBy := strings.Contains(strings.ToLower(link.Label), "blocked by") ||
			(link.LinkType == "Blocks" && link.Direction == "inward")
		if blockedBy && !statusDone(link.IssueStatus) {
			return "blocked"
		}
	}
	if days, ok := daysFromNow(issue.Duedate); ok {
		if days < 0 {
			return "overdue"
		} else if days <= 7 {
			return "due_soon"
		}
	}
	if d, ok := daysSince(issue.Updated); ok && d > 14 {
		return "stale"
	}
	return "normal"
}

var dateRe = regexp.MustCompile(`(\d+)-(\d+)-(\d+)`)

func parseDate(s string) (time.Time, bool) {
	m := dateRe.FindStringSubmatch(s)
	if m == nil {
		return time.Time{}, false
	}
	t, err := time.Parse("2006-1-2", m[1]+"-"+m[2]+"-"+m[3])
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

func daysFromNow(s string) (float64, bool) {
	t, ok := parseDate(s)
	if !ok {
		return 0, false
	}
	return time.Until(t).Hours() / 24, true
}

func daysSince(s string) (float64, bool) {
	t, ok := parseDate(s)
	if !ok {
		return 0, false
	}
	return time.Since(t).Hours() / 24, true
}

func effectivePriority(n *Node) string {
	rank := n.MaxPriorityRank
	for name, r := range priorityOrder {
		if r == rank {
			return name
		}
	}
	return "None"
}

// BuildTree mirrors state.lua build_tree (returns the full sorted tree; display
// filtering is separate).
func BuildTree(issues []*Issue) []*Node {
	byKey := map[string]*Issue{}
	involved := map[string]bool{}
	for _, is := range issues {
		byKey[is.Key] = is
		involved[is.Key] = true
	}

	childrenOf := map[string][]string{}
	hasParent := map[string]bool{}
	for _, is := range issues {
		if is.Parent != "" && byKey[is.Parent] != nil {
			childrenOf[is.Parent] = append(childrenOf[is.Parent], is.Key)
			hasParent[is.Key] = true
		}
	}

	var build func(key string, depth int) *Node
	build = func(key string, depth int) *Node {
		issue := byKey[key]
		if issue == nil {
			return nil
		}
		n := &Node{
			Issue:           issue,
			Expanded:        depth == 0,
			Depth:           depth,
			IsContext:       !involved[key],
			Urgency:         computeUrgency(issue),
			MaxPriorityRank: priorityRank(issue.Priority),
		}
		for _, ck := range childrenOf[key] {
			child := build(ck, depth+1)
			if child != nil {
				n.Children = append(n.Children, child)
				if child.MaxPriorityRank < n.MaxPriorityRank {
					n.MaxPriorityRank = child.MaxPriorityRank
				}
			}
		}
		sortNodes(n.Children)
		return n
	}

	var roots []*Node
	for _, is := range issues {
		if !hasParent[is.Key] {
			if n := build(is.Key, 0); n != nil {
				roots = append(roots, n)
			}
		}
	}
	sortNodes(roots)
	return roots
}

func sortNodes(nodes []*Node) {
	sort.Slice(nodes, func(i, j int) bool {
		a, b := nodes[i], nodes[j]
		ua, ub := urgencyRank(a.Urgency), urgencyRank(b.Urgency)
		if ua != ub {
			return ua < ub
		}
		if a.MaxPriorityRank != b.MaxPriorityRank {
			return a.MaxPriorityRank < b.MaxPriorityRank
		}
		return a.Issue.Key < b.Issue.Key
	})
}

func isFullyDone(n *Node) bool {
	if n.Urgency != "done" {
		return false
	}
	for _, c := range n.Children {
		if !isFullyDone(c) {
			return false
		}
	}
	return true
}

// FilterForDisplay mirrors state.lua filter_for_display.
func FilterForDisplay(roots []*Node, mode string) []*Node {
	if mode == "" {
		mode = "leaves"
	}
	switch mode {
	case "none":
		return roots
	case "trees":
		var out []*Node
		for _, n := range roots {
			if !isFullyDone(n) {
				out = append(out, n)
			}
		}
		return out
	default: // leaves
		var prune func(nodes []*Node) []*Node
		prune = func(nodes []*Node) []*Node {
			var out []*Node
			for _, n := range nodes {
				n.Children = prune(n.Children)
				if !(n.Urgency == "done" && len(n.Children) == 0) {
					out = append(out, n)
				}
			}
			return out
		}
		return prune(roots)
	}
}

var cycleRe = regexp.MustCompile(CyclePattern)

// EpicKindOf returns the configured kind for an issue's labels, or nil.
func EpicKindOf(issue *Issue) *EpicKind {
	for _, label := range issue.Labels {
		if k, ok := EpicKinds[label]; ok {
			return &k
		}
	}
	return nil
}

// CycleID extracts a cycle id from summary then fix versions.
func CycleID(issue *Issue) string {
	if m := cycleRe.FindString(issue.Summary); m != "" {
		return m
	}
	for _, v := range issue.FixVersions {
		if m := cycleRe.FindString(v); m != "" {
			return m
		}
		if v != "" {
			return v
		}
	}
	return ""
}

// Readiness returns "ready"|"shaping"|"" (empty = no glyph).
func Readiness(n *Node) string {
	if !ReadinessEnabled || n.Urgency == "done" {
		return ""
	}
	ids := ReadinessLevels[n.Issue.Level]
	if len(ids) == 0 {
		return ""
	}
	for _, id := range ids {
		if !readinessRule(id, n) {
			return "shaping"
		}
	}
	return "ready"
}

func readinessRule(id string, n *Node) bool {
	switch id {
	case "description":
		return n.Issue.Description != ""
	case "acceptance_criteria":
		return n.Issue.AcceptanceCriteria != ""
	case "child_task":
		return len(n.Children) > 0
	case "fix_version":
		return len(n.Issue.FixVersions) > 0
	case "epic_link":
		return n.Issue.Parent != ""
	case "assignee":
		return n.Issue.Assignee != ""
	}
	return true // unknown rule id: skip (never fails)
}

// SubtaskProgress returns done/total over direct children.
func SubtaskProgress(n *Node) (done, total int) {
	for _, c := range n.Children {
		total++
		if statusDone(c.Issue.Status) {
			done++
		}
	}
	return
}

// WorkableStats mirrors state.lua workable_stats (workable = leaf issues).
func WorkableStats(issues []*Issue) (total int, statusCounts map[string]int, doneCount int) {
	statusCounts = map[string]int{}
	byKey := map[string]bool{}
	hasChild := map[string]bool{}
	for _, is := range issues {
		byKey[is.Key] = true
	}
	for _, is := range issues {
		if is.Parent != "" && byKey[is.Parent] {
			hasChild[is.Parent] = true
		}
	}
	for _, is := range issues {
		if hasChild[is.Key] {
			continue
		}
		total++
		s := is.Status
		if s == "" {
			s = "Unknown"
		}
		statusCounts[s]++
		if statusDone(is.Status) {
			doneCount++
		}
	}
	return
}

// GroupNodes mirrors state.lua group_nodes.
func GroupNodes(nodes []*Node, mode string) []Group {
	if mode == "none" {
		return []Group{{Name: "", Nodes: nodes}}
	}
	order := []string{}
	m := map[string][]*Node{}
	keyOf := func(n *Node) string {
		switch mode {
		case "status":
			if n.Issue.Status != "" {
				return n.Issue.Status
			}
			return "Unknown"
		case "assignee":
			if n.Issue.Assignee != "" {
				return n.Issue.Assignee
			}
			return "Unassigned"
		case "type":
			if n.Issue.Type != "" {
				return n.Issue.Type
			}
			return "Unknown"
		case "priority":
			return effectivePriority(n)
		case "kind":
			if k := EpicKindOf(n.Issue); k != nil {
				return k.Name
			}
			return "Unclassified"
		case "cycle":
			if c := CycleID(n.Issue); c != "" {
				return c
			}
			return "No cycle"
		}
		return "All"
	}
	for _, n := range nodes {
		k := keyOf(n)
		if _, ok := m[k]; !ok {
			order = append(order, k)
		}
		m[k] = append(m[k], n)
	}
	if mode == "priority" {
		rank := map[string]int{"Highest": 1, "High": 2, "Medium": 3, "Low": 4, "Lowest": 5, "None": 6}
		sort.SliceStable(order, func(i, j int) bool { return at(rank, order[i]) < at(rank, order[j]) })
	}
	out := make([]Group, 0, len(order))
	for _, name := range order {
		out = append(out, Group{Name: name, Nodes: m[name]})
	}
	return out
}

func at(m map[string]int, k string) int {
	if v, ok := m[k]; ok {
		return v
	}
	return 99
}

// BuildState runs the full pipeline: tree → display filter → grouping.
func BuildState(in *BoardInput) *State {
	tree := FilterForDisplay(BuildTree(in.Issues), "leaves")
	return &State{
		Issues:  in.Issues,
		Tree:    tree,
		Groups:  GroupNodes(tree, in.Group),
		Project: in.Project,
	}
}
