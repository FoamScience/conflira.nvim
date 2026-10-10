// Command conflira-dash is a terminal Jira board (a herdr plugin pane). It
// drives the core in-process through the same JSON-RPC methods the editor
// clients use, and renders the board IR as ANSI text.
//
// Auth comes from JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN (JIRA_PROJECT
// optional), the same variables the Neovim plugin reads.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"conflira/core/api"
	"conflira/core/ir"
	"conflira/core/rpc"
)

const help = "↵ open  o browser  t transition  a assign  c comment  r refresh  q quit"

type choice struct{ label, id string }

type picker struct {
	title  string
	items  []choice
	filter string
	sel    int
	pick   func(choice)
}

func (p *picker) visible() []choice {
	var out []choice
	f := strings.ToLower(p.filter)
	for _, c := range p.items {
		if strings.Contains(strings.ToLower(c.label), f) {
			out = append(out, c)
		}
	}
	return out
}

type input struct {
	prompt string
	buf    string
	submit func(string)
}

type app struct {
	srv     *rpc.Server
	auth    rpc.AuthParams
	project string
	ev      chan func(*app)

	doc      *ir.ProjectionIR
	marks    map[int][]ir.Mark
	gutter   int
	lineKeys map[int]string

	rows, cols int
	cur, top   int
	msg        string
	pick       *picker
	in         *input
	quit       bool
}

func main() {
	a := &app{
		srv: rpc.NewServer(),
		auth: rpc.AuthParams{
			URL:   os.Getenv("JIRA_URL"),
			Email: os.Getenv("JIRA_EMAIL"),
			Token: os.Getenv("JIRA_API_TOKEN"),
		},
		project:  os.Getenv("JIRA_PROJECT"),
		ev:       make(chan func(*app), 16),
		doc:      &ir.ProjectionIR{},
		lineKeys: map[int]string{},
	}
	rpc.Register(a.srv, rpc.CurlFetcher, rpc.CurlClient)

	saved := stty("-g")
	stty("raw", "-echo")
	fmt.Print("\x1b[?1049h\x1b[?25l\x1b[?7l")
	defer func() {
		fmt.Print("\x1b[?7h\x1b[?25h\x1b[?1049l")
		stty(saved)
	}()
	a.resize()

	go func() {
		buf := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				a.ev <- func(a *app) { a.quit = true }
				return
			}
			k := string(buf[:n])
			a.ev <- func(a *app) { a.key(k) }
		}
	}()
	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	tick := time.NewTicker(5 * time.Minute)
	go func() {
		for {
			select {
			case <-winch:
				a.ev <- (*app).resize
			case <-tick.C:
				a.ev <- (*app).reload
			}
		}
	}()

	a.reload()
	for !a.quit {
		a.draw()
		(<-a.ev)(a)
	}
}

func stty(args ...string) string {
	c := exec.Command("stty", args...)
	c.Stdin = os.Stdin
	out, _ := c.Output()
	return strings.TrimSpace(string(out))
}

func (a *app) resize() {
	f := strings.Fields(stty("size"))
	a.rows, a.cols = 24, 80
	if len(f) == 2 {
		a.rows, _ = strconv.Atoi(f[0])
		a.cols, _ = strconv.Atoi(f[1])
	}
}

// call runs a core RPC method in-process, decoding its result into out.
func (a *app) call(method string, params map[string]any, out any) error {
	params["auth"] = a.auth
	p, err := json.Marshal(params)
	if err != nil {
		return err
	}
	resp := a.srv.Dispatch(&rpc.Request{Method: method, Params: p})
	if resp.Error != nil {
		return errors.New(resp.Error.Message)
	}
	if out == nil {
		return nil
	}
	b, err := json.Marshal(resp.Result)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, out)
}

// async runs work off the UI loop; work returns the state update to apply.
func (a *app) async(status string, work func() func(*app)) {
	a.msg = status
	go func() { a.ev <- work() }()
}

func (a *app) mutate(method string, params map[string]any, done string) {
	a.async(done+"…", func() func(*app) {
		err := a.call(method, params, nil)
		return func(a *app) {
			if err != nil {
				a.msg = "error: " + err.Error()
				return
			}
			a.reload()
			a.msg = done
		}
	})
}

func (a *app) reload() {
	if a.auth.URL == "" || a.auth.Email == "" || a.auth.Token == "" {
		a.msg = "set JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN (herdr pane: $HERDR_PLUGIN_CONFIG_DIR/env)"
		return
	}
	a.async("loading…", func() func(*app) {
		var res struct {
			IR       ir.ProjectionIR `json:"ir"`
			LineKeys map[int]string  `json:"line_keys"`
		}
		err := a.call("board.open", map[string]any{"project": a.project}, &res)
		return func(a *app) {
			if err != nil {
				a.msg = "error: " + err.Error()
				return
			}
			prev := a.lineKeys[a.cur]
			a.doc, a.lineKeys = &res.IR, res.LineKeys
			a.marks, a.gutter = marksByLine(a.doc)
			a.cur = 0
			for l, k := range a.lineKeys {
				if k == prev {
					a.cur = l
				}
			}
			if a.lineKeys[a.cur] == "" {
				a.move(1)
			}
			if a.msg == "loading…" {
				a.msg = ""
			}
		}
	})
}

// move steps the cursor n issue lines, skipping lines without an issue key.
func (a *app) move(n int) {
	step := 1
	if n < 0 {
		step, n = -1, -n
	}
	for ; n > 0; n-- {
		for l := a.cur + step; l >= 0 && l < len(a.doc.Lines); l += step {
			if a.lineKeys[l] != "" {
				a.cur = l
				break
			}
		}
	}
}

func (a *app) draw() {
	var b strings.Builder
	b.WriteString("\x1b[H")
	h := a.rows - 1
	var overlay []string
	if p := a.pick; p != nil {
		overlay = append(overlay, "\x1b[0;1m "+p.title+": "+p.filter+"\x1b[0m")
		vis := p.visible()
		for i, c := range vis {
			if i == 10 {
				overlay = append(overlay, "\x1b[2m  … "+strconv.Itoa(len(vis)-10)+" more, type to filter\x1b[0m")
				break
			}
			sel := "  "
			if i == p.sel {
				sel = "\x1b[7m▶ "
			}
			overlay = append(overlay, sel+c.label+"\x1b[0m")
		}
	}
	h -= len(overlay)

	if a.cur < a.top {
		a.top = a.cur
	}
	if a.cur >= a.top+h {
		a.top = a.cur - h + 1
	}
	for i := a.top; i < a.top+h; i++ {
		if i < len(a.doc.Lines) {
			base := ""
			if i == a.cur {
				base = "\x1b[7m"
			}
			b.WriteString(renderLine(a.doc.Lines[i], a.marks[i], a.gutter, a.cols, base))
		}
		b.WriteString("\x1b[K\r\n")
	}
	for _, l := range overlay {
		b.WriteString(l + "\x1b[K\r\n")
	}

	status := a.msg
	if a.in != nil {
		status = a.in.prompt + a.in.buf + "█"
	} else if status == "" {
		status = help
	}
	b.WriteString("\x1b[2m" + status + "\x1b[0m\x1b[K")
	fmt.Print(b.String())
}

func (a *app) key(k string) {
	switch {
	case a.in != nil:
		a.inputKey(k)
	case a.pick != nil:
		a.pickKey(k)
	default:
		a.boardKey(k)
	}
}

func (a *app) boardKey(k string) {
	key := a.lineKeys[a.cur]
	half := max(1, (a.rows-1)/2)
	switch k {
	case "q", "\x03":
		a.quit = true
	case "j", "\x1b[B":
		a.move(1)
	case "k", "\x1b[A":
		a.move(-1)
	case "\x04", "\x1b[6~":
		a.move(half)
	case "\x15", "\x1b[5~":
		a.move(-half)
	case "g":
		a.cur = 0
		a.move(1)
	case "G":
		a.cur = len(a.doc.Lines)
		a.move(-1)
	case "r":
		a.reload()
	}
	if key == "" {
		return
	}
	switch k {
	case "\r":
		a.openIssue(key)
	case "o":
		a.msg = openBrowser(a.browseURL(key))
	case "t":
		a.transition(key)
	case "a":
		a.assign(key)
	case "c":
		a.in = &input{prompt: "comment " + key + ": ", submit: func(text string) {
			a.mutate("issue.comment", map[string]any{"key": key, "text": text}, "commented on "+key)
		}}
	}
}

func (a *app) pickKey(k string) {
	p := a.pick
	vis := p.visible()
	switch k {
	case "\x1b", "\x03":
		a.pick = nil
	case "\r":
		a.pick = nil
		if p.sel < len(vis) {
			p.pick(vis[p.sel])
		}
	case "\x1b[B", "\x0e":
		p.sel = min(p.sel+1, max(0, min(len(vis), 10)-1))
	case "\x1b[A", "\x10":
		p.sel = max(p.sel-1, 0)
	case "\x7f":
		p.filter = trimLastRune(p.filter)
		p.sel = 0
	default:
		if printable(k) {
			p.filter += k
			p.sel = 0
		}
	}
}

func (a *app) inputKey(k string) {
	in := a.in
	switch k {
	case "\x1b", "\x03":
		a.in = nil
	case "\r":
		a.in = nil
		if strings.TrimSpace(in.buf) != "" {
			in.submit(in.buf)
		}
	case "\x7f":
		in.buf = trimLastRune(in.buf)
	default:
		if printable(k) {
			in.buf += k
		}
	}
}

func printable(k string) bool { return k != "" && k[0] >= 0x20 && k[0] != 0x7f }

func trimLastRune(s string) string {
	r := []rune(s)
	if len(r) == 0 {
		return s
	}
	return string(r[:len(r)-1])
}

func (a *app) transition(key string) {
	a.async("transitions…", func() func(*app) {
		var ts []struct{ ID, Name, To string }
		err := a.call("issue.transitions", map[string]any{"key": key}, &ts)
		return func(a *app) {
			if err != nil {
				a.msg = "error: " + err.Error()
				return
			}
			items := make([]choice, len(ts))
			for i, t := range ts {
				items[i] = choice{t.Name + " → " + t.To, t.ID}
			}
			a.msg = ""
			a.pick = &picker{title: "transition " + key, items: items, pick: func(c choice) {
				a.mutate("issue.transition", map[string]any{"key": key, "transition_id": c.id}, key+": "+c.label)
			}}
		}
	})
}

func (a *app) assign(key string) {
	project, _, _ := strings.Cut(key, "-")
	a.async("assignable users…", func() func(*app) {
		var us []struct {
			AccountID   string `json:"account_id"`
			DisplayName string `json:"display_name"`
		}
		err := a.call("issue.assignable", map[string]any{"project": project}, &us)
		return func(a *app) {
			if err != nil {
				a.msg = "error: " + err.Error()
				return
			}
			items := make([]choice, len(us))
			for i, u := range us {
				items[i] = choice{u.DisplayName, u.AccountID}
			}
			a.msg = ""
			a.pick = &picker{title: "assign " + key, items: items, pick: func(c choice) {
				a.mutate("issue.assign", map[string]any{"key": key, "account_id": c.id}, key+" → "+c.label)
			}}
		}
	})
}

func (a *app) browseURL(key string) string {
	return api.NormalizeURL(a.auth.URL) + "/browse/" + key
}

// openIssue shows the issue in the herdr-nvim sidebar when that nvim has the
// conflira plugin, else falls back to the browser.
func (a *app) openIssue(key string) {
	a.async("opening "+key+"…", func() func(*app) {
		err := openInNvim(key)
		return func(a *app) {
			if err == nil {
				a.msg = key + " opened in nvim sidebar"
				return
			}
			a.msg = openBrowser(a.browseURL(key)) + " (nvim: " + err.Error() + ")"
		}
	})
}
