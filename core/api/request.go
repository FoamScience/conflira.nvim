// Package api ports the request-construction layer (atlassian/request.lua and
// the endpoint builders in jira-interface/api.lua): auth, URL normalization, the
// vim-compatible URI encoder, the fields parameter, and REST endpoints. The pure
// builders are verified against fixtures captured from the frozen Lua; actual
// HTTP is behind the Transport interface (see client.go).
package api

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// BaseFields is the field set requested for issues (jira-interface/api.lua
// build_fields_param).
var BaseFields = []string{
	"summary", "description", "status", "issuetype", "project",
	"assignee", "parent", "attachment", "comment", "issuelinks",
	"priority", "duedate", "created", "updated", "labels", "fixVersions",
}

// AuthHeader builds the Basic auth header value.
func AuthHeader(email, token string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(email+":"+token))
}

var schemeRe = regexp.MustCompile(`^https?://`)

// NormalizeURL ensures an https scheme and trims a trailing slash.
func NormalizeURL(url string) string {
	if !schemeRe.MatchString(url) {
		url = "https://" + url
	}
	return strings.TrimRight(url, "/")
}

// uriPreserved is the byte set vim.uri_encode leaves unescaped.
var uriPreserved [256]bool

func init() {
	const keep = "!$&'()*+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~"
	for i := 0; i < len(keep); i++ {
		uriPreserved[keep[i]] = true
	}
}

// URIEncode percent-encodes a string exactly like Neovim's vim.uri_encode
// (lowercase hex; preserves "!$&'()*+,-./:;=@" and unreserved).
func URIEncode(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if uriPreserved[c] {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02x", c)
		}
	}
	return b.String()
}

// BuildFieldsParam returns "fields=a,b,c" for the base fields plus custom IDs.
func BuildFieldsParam(customFieldIDs []string) string {
	fields := append(append([]string{}, BaseFields...), customFieldIDs...)
	return "fields=" + strings.Join(fields, ",")
}

var orderByRe = regexp.MustCompile(`ORDER\s+BY\s+.+$`)
var orderByStripRe = regexp.MustCompile(`\s+ORDER\s+BY\s+.+$`)

// InjectSince adds a "created >= <since>" clause to a JQL query, preserving any
// ORDER BY (jira-interface/api.lua search). since == "" returns jql unchanged.
func InjectSince(jql, since string) string {
	if since == "" {
		return jql
	}
	orderBy := orderByRe.FindString(jql)
	if orderBy != "" {
		base := strings.TrimSpace(orderByStripRe.ReplaceAllString(jql, ""))
		if base != "" {
			return base + " AND created >= " + since + " " + orderBy
		}
		return "created >= " + since + " " + orderBy
	}
	return jql + " AND created >= " + since
}

// SearchEndpoint builds the /search/jql endpoint with encoded JQL, fields, and
// maxResults.
func SearchEndpoint(jql, since string, maxResults int, customFieldIDs []string) string {
	jql = InjectSince(jql, since)
	return "/search/jql?jql=" + URIEncode(jql) +
		"&" + BuildFieldsParam(customFieldIDs) +
		"&maxResults=" + strconv.Itoa(maxResults)
}

// IssueEndpoint builds the /issue/<key> endpoint with fields.
func IssueEndpoint(key string, customFieldIDs []string) string {
	return "/issue/" + key + "?" + BuildFieldsParam(customFieldIDs)
}

// TransitionsEndpoint builds the transitions list endpoint.
func TransitionsEndpoint(key string) string {
	return "/issue/" + key + "/transitions"
}

// TransitionBody is the POST body for performing a transition.
type TransitionBody struct {
	Transition struct {
		ID string `json:"id"`
	} `json:"transition"`
}

// NewTransitionBody builds the do-transition request body.
func NewTransitionBody(transitionID string) TransitionBody {
	var b TransitionBody
	b.Transition.ID = transitionID
	return b
}
