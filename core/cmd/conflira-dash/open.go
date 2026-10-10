package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// herdr-nvim keeps one headless nvim per herdr tab, listening on
// <runtime dir>/<tab id with ':'→'_'>.sock; its sidebar pane is recorded in
// <state dir>/<same key>.json. Paths mirror herdr-nvim's daemon/registry.rs
// and state.rs.
const herdrNvimPlugin = "chmarax.herdr-nvim"

var issueKey = regexp.MustCompile(`^[A-Z][A-Z0-9_]*-\d+$`)

func herdrNvimDir(override, xdg, fallback string) string {
	if d := os.Getenv(override); d != "" {
		return d
	}
	if d := os.Getenv(xdg); d != "" {
		return filepath.Join(d, "herdr-nvim")
	}
	return fallback
}

func herdr(args ...string) error {
	bin := os.Getenv("HERDR_BIN_PATH")
	if bin == "" {
		bin = "herdr"
	}
	return exec.Command(bin, args...).Run()
}

func nvimExpr(sock, expr string) (string, error) {
	out, err := exec.Command("nvim", "--server", sock, "--remote-expr", expr).Output()
	return strings.TrimSpace(string(out)), err
}

func sidebarOpen(tabKey string) bool {
	home, _ := os.UserHomeDir()
	dir := herdrNvimDir("HERDR_NVIM_STATE_DIR", "XDG_STATE_HOME", filepath.Join(home, ".local/state/herdr-nvim"))
	b, err := os.ReadFile(filepath.Join(dir, tabKey+".json"))
	if err != nil {
		return false
	}
	var st struct {
		Phase   string `json:"phase"`
		Sidebar string `json:"sidebar_pane"`
	}
	return json.Unmarshal(b, &st) == nil && st.Phase == "Open" && st.Sidebar != "" && herdr("pane", "get", st.Sidebar) == nil
}

func openInNvim(key string) error {
	if !issueKey.MatchString(key) {
		return errors.New("unexpected issue key " + key)
	}
	tab := os.Getenv("HERDR_TAB_ID")
	if tab == "" {
		return errors.New("not in a herdr tab")
	}
	tabKey := strings.ReplaceAll(tab, ":", "_")
	sock := filepath.Join(herdrNvimDir("HERDR_NVIM_RUNTIME_DIR", "XDG_RUNTIME_DIR", filepath.Join(os.TempDir(), "herdr-nvim")), tabKey+".sock")

	if !sidebarOpen(tabKey) {
		if err := herdr("plugin", "action", "invoke", "toggle", "--plugin", herdrNvimPlugin); err != nil {
			return errors.New("herdr-nvim sidebar unavailable")
		}
	}
	var err error
	for range 50 {
		if _, err = nvimExpr(sock, "1"); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return errors.New("sidebar nvim not reachable")
	}
	if v, _ := nvimExpr(sock, `exists(':JiraView')`); v != "2" {
		return errors.New("conflira not loaded in sidebar nvim")
	}
	_, err = nvimExpr(sock, "execute('JiraView "+key+"')")
	return err
}

// openBrowser launches the system URL opener and returns a status message.
func openBrowser(url string) string {
	opener := "xdg-open"
	if runtime.GOOS == "darwin" {
		opener = "open"
	}
	c := exec.Command(opener, url)
	if err := c.Start(); err != nil {
		return "error: " + err.Error()
	}
	go c.Wait()
	return "opened " + url
}
