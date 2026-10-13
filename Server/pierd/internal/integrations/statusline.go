package integrations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Claude Code hands its status line command a JSON with the subscription's
// usage (`rate_limits.five_hour` / `seven_day`, with `used_percentage` and
// `resets_at`; code.claude.com/docs/en/statusline). pierd's status line
// keeps the latest of each account in a file so the app can show the
// limits, then prints what the person's own status line prints: an existing
// one is kept, run by pierd's with the same input.

// StatusLineMark is in the command of pierd's status line (after pierd's
// path), and in no other tool's: ccusage's own `statusline` says ccusage.
const StatusLineMark = " statusline"

// isPierdStatusLine reports whether command is pierd's status line.
func isPierdStatusLine(command, bin string) bool {
	first, _, _ := strings.Cut(strings.TrimSpace(command), " statusline")
	if first == strings.TrimSpace(command) {
		return false
	}
	first = strings.Trim(first, "'\"")
	return first == bin || filepath.Base(first) == "pierd"
}

// quoteAlways single-quotes s for sh, whatever it holds.
func quoteAlways(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// InstallStatusLine puts pierd's status line in a Claude Code settings file.
// A status line already there is kept and run behind it (--then). Running
// it again changes nothing.
func InstallStatusLine(settingsPath, bin string) (bool, error) {
	f, rel := fileAt(settingsPath)
	return editJSON(f, rel, func(root map[string]any) bool {
		sl, _ := root["statusLine"].(map[string]any)
		old, _ := sl["command"].(string)
		if isPierdStatusLine(old, bin) {
			return false
		}
		command := shellQuote(bin) + StatusLineMark
		if strings.TrimSpace(old) != "" {
			command += " --then " + quoteAlways(old)
		}
		next := map[string]any{"type": "command", "command": command}
		for k, v := range sl {
			if k != "type" && k != "command" {
				next[k] = v
			}
		}
		root["statusLine"] = next
		return true
	})
}

// HasStatusLine reports whether pierd's status line is in a settings file.
func HasStatusLine(settingsPath string) bool {
	b, err := os.ReadFile(settingsPath)
	if err != nil {
		return false
	}
	var s struct {
		StatusLine struct {
			Command string `json:"command"`
		} `json:"statusLine"`
	}
	if json.Unmarshal(b, &s) != nil {
		return false
	}
	return isPierdStatusLine(s.StatusLine.Command, "")
}

// LimitWindow is one usage window of an account's subscription.
type LimitWindow struct {
	// Kind: "five_hour", "seven_day", or Codex's "primary" / "secondary".
	Kind        string    `json:"kind"`
	Minutes     int       `json:"minutes,omitempty"`
	UsedPercent float64   `json:"used_percent"`
	ResetsAt    time.Time `json:"resets_at,omitempty"`
}

// Limits is what was last seen of an account's usage.
type Limits struct {
	Agent   string        `json:"agent"`
	Dir     string        `json:"dir"`
	Windows []LimitWindow `json:"windows"`
	Updated time.Time     `json:"updated"`
	// Source: "statusline" (Claude Code) or "session_log" (Codex).
	Source string `json:"source"`
}

// LimitsFile is where an account's limits are kept, in dir.
func LimitsFile(dir, agent, configDir string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(configDir)))
	return filepath.Join(dir, agent+"-"+hex.EncodeToString(sum[:6])+".json")
}

// ParseStatusLine reads Claude Code's status line input.
func ParseStatusLine(input []byte) (windows []LimitWindow, model string) {
	var in struct {
		Model struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
		RateLimits map[string]struct {
			Used     *float64 `json:"used_percentage"`
			ResetsAt int64    `json:"resets_at"`
		} `json:"rate_limits"`
	}
	if json.Unmarshal(input, &in) != nil {
		return nil, ""
	}
	for _, kind := range []string{"five_hour", "seven_day"} {
		w, ok := in.RateLimits[kind]
		if !ok || w.Used == nil {
			continue
		}
		lw := LimitWindow{Kind: kind, UsedPercent: *w.Used, Minutes: map[string]int{"five_hour": 300, "seven_day": 10080}[kind]}
		if w.ResetsAt > 0 {
			lw.ResetsAt = time.Unix(w.ResetsAt, 0).UTC()
		}
		windows = append(windows, lw)
	}
	return windows, in.Model.DisplayName
}

// StatusLine is `pierd statusline [--then COMMAND]`: it keeps the limits
// in its input in dir, then prints COMMAND's output for the same input, or
// a short line of its own.
func StatusLine(args []string, stdin io.Reader, stdout io.Writer, dir string) error {
	input, _ := io.ReadAll(io.LimitReader(stdin, 1<<20))
	windows, model := ParseStatusLine(input)
	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		home, _ := os.UserHomeDir()
		configDir = filepath.Join(home, ".claude")
	}
	if len(windows) > 0 {
		l := Limits{Agent: "claude", Dir: configDir, Windows: windows, Updated: time.Now().UTC(), Source: "statusline"}
		if data, err := json.Marshal(l); err == nil && os.MkdirAll(dir, 0o700) == nil {
			path := LimitsFile(dir, "claude", configDir)
			tmp := path + ".tmp"
			if os.WriteFile(tmp, data, 0o600) == nil {
				os.Rename(tmp, path)
			}
		}
	}
	if len(args) >= 2 && args[0] == "--then" {
		cmd := exec.Command("/bin/sh", "-c", args[1])
		cmd.Stdin = bytes.NewReader(input)
		cmd.Stdout, cmd.Stderr = stdout, os.Stderr
		return cmd.Run()
	}
	var parts []string
	if model != "" {
		parts = append(parts, model)
	}
	for _, w := range windows {
		label := map[string]string{"five_hour": "5h", "seven_day": "7d"}[w.Kind]
		parts = append(parts, fmt.Sprintf("%s %.0f%%", label, w.UsedPercent))
	}
	fmt.Fprintln(stdout, strings.Join(parts, " · "))
	return nil
}
