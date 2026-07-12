// Package jql ports the JQL builders from jira-interface/filters.lua. Pure string
// construction; verified against fixtures captured from the frozen Lua.
package jql

import (
	"regexp"
	"strconv"
	"strings"
)

// TypesByLevel mirrors config.lua types.lvl1..lvl4.
var TypesByLevel = map[int][]string{
	1: {"Epic"},
	2: {"Feature", "Bug", "Issue"},
	3: {"Task"},
	4: {"Sub-Task"},
}

func andProject(jql, project string) string {
	if project != "" {
		jql += " AND project = " + project
	}
	return jql
}

func AssignedToMe() string {
	return "assignee = currentUser() AND status != Done ORDER BY statusCategory DESC, duedate ASC, updated DESC"
}

func CreatedByMe() string {
	return "reporter = currentUser() ORDER BY created DESC"
}

func AssignedNotCreated() string {
	return "assignee = currentUser() AND reporter != currentUser() AND status != Done ORDER BY statusCategory DESC, duedate ASC, updated DESC"
}

func ByProject(project string) string {
	return "project = " + project + " ORDER BY updated DESC"
}

func ByStatus(status string) string {
	return `status = "` + status + `" ORDER BY updated DESC`
}

func ByType(typeName string) string {
	return `issuetype = "` + typeName + `" ORDER BY updated DESC`
}

func ByLevel(level int, project string) string {
	types := TypesByLevel[level]
	jql := `issuetype in ("` + strings.Join(types, `","`) + `")`
	return andProject(jql, project) + " ORDER BY updated DESC"
}

func ByLabel(label, project string) string {
	jql := `labels = "` + label + `"`
	return andProject(jql, project) + " ORDER BY updated DESC"
}

func ChildrenOf(parentKey string) string {
	return "parent = " + parentKey + " ORDER BY created ASC"
}

func Overdue(project string) string {
	return andProject("duedate < now() AND status != Done", project) + " ORDER BY duedate ASC"
}

func DueToday(project string) string {
	return andProject("duedate = startOfDay() AND status != Done", project) + " ORDER BY duedate ASC"
}

func DueThisWeek(project string) string {
	return andProject("duedate >= startOfDay() AND duedate <= endOfWeek() AND status != Done", project) + " ORDER BY duedate ASC"
}

func DueSoon(project string) string {
	return andProject("duedate >= startOfDay() AND duedate <= 7d AND status != Done", project) + " ORDER BY duedate ASC"
}

func ByDuedate(project string) string {
	return andProject("duedate is not EMPTY", project) + " ORDER BY duedate ASC"
}

func excludeEpics() string {
	var lvl1 []string
	for _, t := range TypesByLevel[1] {
		lvl1 = append(lvl1, `"`+t+`"`)
	}
	if len(lvl1) == 0 {
		return ""
	}
	return " AND issuetype NOT IN (" + strings.Join(lvl1, ", ") + ")"
}

// Main builds the board's primary query: issues assigned to me, excluding epics.
// Mirrors board/init.lua build_queries (main).
func Main() string {
	return "assignee = currentUser()" + excludeEpics() + " ORDER BY updated DESC"
}

// Reporter / Watching are native involvement queries for the merged board.
// Like Main, they exclude epics (epics appear only as bubbled context parents).
func Reporter() string {
	return "reporter = currentUser()" + excludeEpics() + " ORDER BY updated DESC"
}

func Watching() string {
	return "watcher = currentUser()" + excludeEpics() + " ORDER BY updated DESC"
}

// RecentlyUpdated is the bounded discovery query for involvement fields that
// aren't JQL-searchable (Reviewer / Additional Assignees): fetch issues updated
// in the last `days`, then detect membership client-side from field values.
func RecentlyUpdated(days int) string {
	return "updated >= -" + strconv.Itoa(days) + "d" + excludeEpics() + " ORDER BY updated DESC"
}

// InvolvementField builds a merged-board involvement query: any of the given
// custom user-picker fields is me. Unlike InvolvementSection it does NOT exclude
// the assignee — the merged board WANTS overlaps (an issue assigned AND reviewed
// shows both icons); dedup/union of relationships is done client-side by key.
// Returns "" when there are no fields.
func InvolvementField(fieldIDs []string) string {
	if len(fieldIDs) == 0 {
		return ""
	}
	var or []string
	for _, id := range fieldIDs {
		or = append(or, `"`+id+`" = currentUser()`)
	}
	return "(" + strings.Join(or, " OR ") + ")" + excludeEpics() + " ORDER BY updated DESC"
}

// InvolvementSection builds a board section query: any of the given fields is
// me, and I am NOT the assignee (dedup against Main and across sections is done
// client-side — a server-side NOT clause would wrongly drop EMPTY-field issues).
// Returns "" when there are no fields. Mirrors board/init.lua build_queries.
func InvolvementSection(fieldIDs []string) string {
	if len(fieldIDs) == 0 {
		return ""
	}
	var or []string
	for _, id := range fieldIDs {
		or = append(or, `"`+id+`" = currentUser()`)
	}
	return "(" + strings.Join(or, " OR ") + ")" +
		" AND assignee != currentUser()" + excludeEpics() + " ORDER BY updated DESC"
}

var orderByRe = regexp.MustCompile(`ORDER\s+BY\s+.+$`)
var orderByStripRe = regexp.MustCompile(`\s+ORDER\s+BY\s+.+$`)

// Combine merges a base JQL with an additional clause, preserving the base's
// ORDER BY (or defaulting it). Mirrors filters.combine_jql.
func Combine(jql, clause string) string {
	base := orderByStripRe.ReplaceAllString(jql, "")
	orderBy := orderByRe.FindString(jql)
	if orderBy == "" {
		orderBy = "ORDER BY updated DESC"
	}
	return "(" + base + ") AND (" + clause + ") " + orderBy
}
