package board

// Board configuration defaults, mirroring jira-interface/config.lua (board.*).
// Highlight values are pre-mapped to the semantic style tokens the IR uses.

// EpicKind is a label-driven epic classification.
type EpicKind struct {
	Name  string
	Icon  string
	Token string // style token (theme-resolved hl)
}

// EpicKinds maps a label → kind. Tokens: @markup.heading.1→heading.1,
// @markup.heading.2→heading.2, Comment→comment.
var EpicKinds = map[string]EpicKind{
	"pillar":        {Name: "Pillar", Icon: "▲", Token: "heading.1"},
	"shape-up-goal": {Name: "Shape Up Goal", Icon: "◈", Token: "heading.2"},
	"operational":   {Name: "Operational", Icon: "⚙", Token: "comment"},
}

// CyclePattern matches a Shape Up cycle id (Lua "SU%d+/%d+").
const CyclePattern = `SU\d+/\d+`

// TypeIcons maps issue type → outline glyph.
var TypeIcons = map[string]string{
	"Epic": "◆", "Feature": "◆", "Bug": "●",
	"Issue": "◆", "Task": "◇", "Sub-Task": "○",
}

// InvolvementKinds lists the relationship tags, in display order. Each issue on
// the board can carry any subset; they render as trailing icons next to the
// title. ("commented" is intentionally absent — not natively JQL-queryable.)
var InvolvementKinds = []string{"assigned", "reporter", "review", "additional", "watching"}

// InvolvementIconsNerd / Unicode are the two glyph sets. Unicode is the default
// (the board's type icons are plain Unicode too); a Nerd-Font client can opt in.
// Nerd Font glyphs (FontAwesome): user, pencil, check, user-plus, eye.
var InvolvementIconsNerd = map[string]string{
	"assigned": "\uf007", "reporter": "\uf040", "review": "\uf00c",
	"additional": "\uf234", "watching": "\uf06e",
}
var InvolvementIconsUnicode = map[string]string{
	"assigned": "★", "reporter": "✎", "review": "✓",
	"additional": "⊕", "watching": "◉",
}

// InvolvementColor is the single style token (color) used for every involvement
// icon, so the cluster reads as one group rather than a rainbow.
var InvolvementColor = "accent.fn"

// InvolvementIcons returns the glyph set for the named style ("nerd" → Nerd
// Font, anything else → Unicode).
func InvolvementIcons(style string) map[string]string {
	if style == "nerd" {
		return InvolvementIconsNerd
	}
	return InvolvementIconsUnicode
}

// ReadinessLevels lists the rule ids that must all pass per hierarchy level.
var ReadinessLevels = map[int][]string{
	2: {"description", "acceptance_criteria", "child_task", "fix_version", "epic_link"},
	3: {"description"},
}

// ReadinessEnabled toggles the definition-of-ready overlay.
const ReadinessEnabled = true

// DoneFilter selects which done issues to hide: "none" | "trees" | "leaves".
const DoneFilter = "leaves"
