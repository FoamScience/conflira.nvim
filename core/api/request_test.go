package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func loadRequestFixture(t *testing.T) map[string]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "logic", "request.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// Auth, URL normalization, and the URI encoder must match the frozen Lua.
func TestRequestParity(t *testing.T) {
	f := loadRequestFixture(t)

	checks := map[string]string{
		"auth_header":      AuthHeader("user@example.com", "s3cr3t"),
		"url_plain":        NormalizeURL("mysite.atlassian.net"),
		"url_https":        NormalizeURL("https://mysite.atlassian.net/"),
		"url_http":         NormalizeURL("http://localhost:8080/"),
		"uri_encode_jql":   URIEncode(`project = PROJ AND status = "In Progress" ORDER BY updated DESC`),
		"uri_encode_ascii": URIEncode(asciiPrintable()),
	}
	for name, got := range checks {
		if got != f[name] {
			t.Errorf("%s:\n got: %q\nwant: %q", name, got, f[name])
		}
	}
}

func asciiPrintable() string {
	var b strings.Builder
	for i := 32; i <= 126; i++ {
		b.WriteByte(byte(i))
	}
	return b.String()
}

// InjectSince and SearchEndpoint compose the verified pieces (unit checks).
func TestSinceAndEndpoints(t *testing.T) {
	if got := InjectSince("project = PROJ ORDER BY updated DESC", "-30d"); got != "project = PROJ AND created >= -30d ORDER BY updated DESC" {
		t.Errorf("InjectSince with order: %q", got)
	}
	if got := InjectSince("project = PROJ", "-30d"); got != "project = PROJ AND created >= -30d" {
		t.Errorf("InjectSince no order: %q", got)
	}
	if got := InjectSince("project = PROJ", ""); got != "project = PROJ" {
		t.Errorf("InjectSince empty: %q", got)
	}
	if got := BuildFieldsParam(nil); !strings.HasPrefix(got, "fields=summary,description,") || !strings.HasSuffix(got, ",labels,fixVersions") {
		t.Errorf("BuildFieldsParam: %q", got)
	}
	if got := BuildFieldsParam([]string{"customfield_1"}); !strings.HasSuffix(got, ",fixVersions,customfield_1") {
		t.Errorf("BuildFieldsParam custom: %q", got)
	}
	ep := IssueEndpoint("PROJ-1", nil)
	if !strings.HasPrefix(ep, "/issue/PROJ-1?fields=") {
		t.Errorf("IssueEndpoint: %q", ep)
	}
	if TransitionsEndpoint("PROJ-1") != "/issue/PROJ-1/transitions" {
		t.Errorf("TransitionsEndpoint wrong")
	}
}

// NewTransitionBody marshals to the Jira shape.
func TestTransitionBody(t *testing.T) {
	b, _ := json.Marshal(NewTransitionBody("31"))
	if string(b) != `{"transition":{"id":"31"}}` {
		t.Errorf("transition body: %s", b)
	}
}
