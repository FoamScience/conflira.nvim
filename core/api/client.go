package api

import (
	"encoding/json"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Auth holds Atlassian Basic-auth credentials.
type Auth struct {
	Email string
	Token string
}

// Transport executes an HTTP request and returns the status code and body. It is
// the seam for actual networking — CurlTransport mirrors the Lua curl call; tests
// inject a fake.
type Transport interface {
	Do(method, url string, body []byte, auth Auth) (status int, respBody []byte, err error)
}

// CurlTransport shells out to curl, matching atlassian/request.lua.
type CurlTransport struct{}

func (CurlTransport) Do(method, url string, body []byte, auth Auth) (int, []byte, error) {
	args := []string{
		"-s", "-L", "-w", "\n%{http_code}", "-X", method,
		"-H", "Authorization: " + AuthHeader(auth.Email, auth.Token),
		"-H", "Content-Type: application/json",
		"-H", "Accept: application/json",
	}
	if body != nil {
		args = append(args, "-d", string(body))
	}
	args = append(args, url)

	out, err := exec.Command("curl", args...).Output()
	if err != nil {
		return 0, nil, fmt.Errorf("network error: %w", err)
	}
	text := string(out)
	idx := strings.LastIndexByte(text, '\n')
	if idx < 0 {
		return 0, nil, fmt.Errorf("malformed curl output")
	}
	code, _ := strconv.Atoi(strings.TrimSpace(text[idx+1:]))
	return code, []byte(text[:idx]), nil
}

// Client issues REST requests against a base URL with credentials.
type Client struct {
	BaseURL        string
	APIPath        string // REST base path; defaults to "/rest/api/3"
	Auth           Auth
	Transport      Transport
	CustomFieldIDs []string
}

func (c *Client) apiPath() string {
	if c.APIPath != "" {
		return c.APIPath
	}
	return "/rest/api/3"
}

// Request builds the full URL, sends the request, and returns the response body
// (or a parsed error for status >= 400).
func (c *Client) Request(method, endpoint string, body any) ([]byte, error) {
	url := NormalizeURL(c.BaseURL) + c.apiPath() + endpoint
	var raw []byte
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		raw = b
	}
	status, resp, err := c.Transport.Do(method, url, raw, c.Auth)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, ParseError(status, resp)
	}
	return resp, nil
}

// Search fetches issues for a JQL query (returns the raw response body).
func (c *Client) Search(jql, since string, maxResults int) ([]byte, error) {
	return c.Request("GET", SearchEndpoint(jql, since, maxResults, c.CustomFieldIDs), nil)
}

// GetIssue fetches a single issue.
func (c *Client) GetIssue(key string) ([]byte, error) {
	return c.Request("GET", IssueEndpoint(key, c.CustomFieldIDs), nil)
}

// GetFields fetches all field definitions (the /field response).
func (c *Client) GetFields() ([]byte, error) {
	return c.Request("GET", "/field", nil)
}

// GetMyself fetches the current user (/myself) — used to resolve the account ID
// for value-based involvement detection (Reviewer/Additional fields that aren't
// JQL-searchable).
func (c *Client) GetMyself() ([]byte, error) {
	return c.Request("GET", "/myself", nil)
}

// GetTransitions fetches the available workflow transitions for an issue.
func (c *Client) GetTransitions(key string) ([]byte, error) {
	return c.Request("GET", TransitionsEndpoint(key), nil)
}

// AssignableUsers fetches users assignable on a project.
func (c *Client) AssignableUsers(project string) ([]byte, error) {
	return c.Request("GET", "/user/assignable/search?project="+project+"&maxResults=50", nil)
}

// Assign sets the assignee (accountID) of an issue.
func (c *Client) Assign(key, accountID string) error {
	_, err := c.Request("PUT", "/issue/"+key+"/assignee", map[string]any{"accountId": accountID})
	return err
}

// AddComment posts a comment (ADF body) to an issue.
func (c *Client) AddComment(key string, adfBody any) error {
	_, err := c.Request("POST", "/issue/"+key+"/comment", map[string]any{"body": adfBody})
	return err
}

// DownloadFile fetches a (binary) URL with auth straight to dest — used for
// attachment/media previews. Uses curl -o so binary data isn't text-mangled.
func (c *Client) DownloadFile(url, dest string) error {
	out, err := exec.Command("curl", "-sL", "--fail",
		"-H", "Authorization: "+AuthHeader(c.Auth.Email, c.Auth.Token),
		"-o", dest, url).CombinedOutput()
	if err != nil {
		return fmt.Errorf("download failed: %v: %s", err, string(out))
	}
	return nil
}

// MaybeConvertPDF converts a PDF's first page to PNG via ImageMagick (magick or
// convert) so editors that can't render PDFs can still preview it. Returns the
// PNG path on success, otherwise the original path unchanged.
func MaybeConvertPDF(path string) string {
	if !strings.HasSuffix(strings.ToLower(path), ".pdf") {
		return path
	}
	tool := "magick"
	if _, err := exec.LookPath("magick"); err != nil {
		if _, err2 := exec.LookPath("convert"); err2 != nil {
			return path // no ImageMagick
		}
		tool = "convert"
	}
	png := path + ".png"
	if err := exec.Command(tool, "-density", "150", path+"[0]", png).Run(); err != nil {
		return path
	}
	if fi, err := os.Stat(png); err == nil && fi.Size() > 0 {
		return png
	}
	return path
}

// ImageDims returns the pixel dimensions of an image file (0,0 if not a
// decodable image), so a client can scale it to fit.
func ImageDims(path string) (int, int) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		return 0, 0
	}
	return cfg.Width, cfg.Height
}

// TextToADF wraps plain text in a minimal ADF document (for comments).
func TextToADF(text string) map[string]any {
	return map[string]any{
		"type": "doc", "version": 1,
		"content": []any{map[string]any{
			"type":    "paragraph",
			"content": []any{map[string]any{"type": "text", "text": text}},
		}},
	}
}

// EditIssue updates issue fields (PUT /issue/{key}). Used by the projection
// editor to write a field's ADF back.
func (c *Client) EditIssue(key string, fields map[string]any) error {
	_, err := c.Request("PUT", "/issue/"+key, map[string]any{"fields": fields})
	return err
}

// DoTransition performs a workflow transition.
func (c *Client) DoTransition(key, transitionID string) error {
	_, err := c.Request("POST", TransitionsEndpoint(key), NewTransitionBody(transitionID))
	return err
}

// ParseError builds an error message from a Jira/Confluence error response,
// covering the common shapes (errorMessages, errors map/array, title/detail,
// message). Functionally equivalent to atlassian/request.lua's error handling.
func ParseError(status int, body []byte) error {
	msg := "HTTP " + strconv.Itoa(status)
	var data map[string]json.RawMessage
	if err := json.Unmarshal(body, &data); err != nil {
		return fmt.Errorf("%s: %s", msg, truncate(string(body), 500))
	}

	var parts []string
	if raw, ok := data["errorMessages"]; ok {
		var arr []string
		if json.Unmarshal(raw, &arr) == nil {
			parts = append(parts, arr...)
		}
	}
	if raw, ok := data["errors"]; ok {
		// errors as { field: message }
		var m map[string]string
		if json.Unmarshal(raw, &m) == nil {
			for field, m2 := range m {
				parts = append(parts, field+": "+m2)
			}
		} else {
			// errors as [ { field, message } ]
			var arr []struct {
				Field   string `json:"field"`
				Message string `json:"message"`
			}
			if json.Unmarshal(raw, &arr) == nil {
				for _, e := range arr {
					if e.Message != "" {
						prefix := ""
						if e.Field != "" {
							prefix = e.Field + ": "
						}
						parts = append(parts, prefix+e.Message)
					}
				}
			}
		}
	}
	for _, key := range []string{"title", "detail", "message"} {
		if raw, ok := data[key]; ok {
			var s string
			if json.Unmarshal(raw, &s) == nil && s != "" {
				parts = append(parts, s)
			}
		}
	}

	if len(parts) > 0 {
		text := strings.Join(parts, "; ")
		msg += ": " + text
		if len(text) < 100 {
			msg += "\n" + truncate(string(body), 500)
		}
		return fmt.Errorf("%s", msg)
	}
	return fmt.Errorf("%s: %s", msg, truncate(string(body), 500))
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
