package integrations

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallStatusLineKeepsThePersonsOwn(t *testing.T) {
	dir := t.TempDir()
	settings := filepath.Join(dir, "settings.json")
	os.WriteFile(settings, []byte(`{"statusLine":{"type":"command","command":"~/bin/my line | cut -c1-40","padding":0},"model":"opus"}`), 0o600)
	changed, err := InstallStatusLine(settings, "/opt/pier/pierd")
	if err != nil || !changed {
		t.Fatalf("install = %v %v", changed, err)
	}
	var got map[string]any
	data, _ := os.ReadFile(settings)
	json.Unmarshal(data, &got)
	sl := got["statusLine"].(map[string]any)
	if sl["command"] != `/opt/pier/pierd statusline --then '~/bin/my line | cut -c1-40'` || sl["padding"] != float64(0) || got["model"] != "opus" {
		t.Fatalf("settings = %s", data)
	}
	if again, _ := InstallStatusLine(settings, "/opt/pier/pierd"); again {
		t.Error("installing twice changed it again")
	}
	if !HasStatusLine(settings) {
		t.Error("HasStatusLine")
	}
	// Another tool's statusline is not pierd's; a line with shell operators
	// is kept whole.
	other := filepath.Join(dir, "other.json")
	os.WriteFile(other, []byte(`{"statusLine":{"type":"command","command":"npx -y ccusage statusline|head -c 80"}}`), 0o600)
	if HasStatusLine(other) {
		t.Error("ccusage's statusline read as pierd's")
	}
	if changed, err := InstallStatusLine(other, "/opt/pier/pierd"); err != nil || !changed {
		t.Fatalf("install over ccusage = %v %v", changed, err)
	}
	data, _ = os.ReadFile(other)
	var o map[string]any
	json.Unmarshal(data, &o)
	if cmd := o["statusLine"].(map[string]any)["command"]; cmd != `/opt/pier/pierd statusline --then 'npx -y ccusage statusline|head -c 80'` {
		t.Errorf("wrapped = %v", cmd)
	}
}

func TestStatusLineKeepsLimitsAndRunsTheOwnLine(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "acct")
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	in := `{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":4102444800},"seven_day":{"used_percentage":41,"resets_at":4102444800}}}`
	var out bytes.Buffer
	if err := StatusLine([]string{"--then", "cat | wc -c"}, strings.NewReader(in), &out, dir); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out.String()) != "176" && strings.TrimSpace(out.String()) == "" {
		t.Errorf("own line output = %q", out.String())
	}
	data, err := os.ReadFile(LimitsFile(dir, "claude", cfg))
	if err != nil {
		t.Fatal(err)
	}
	var l Limits
	json.Unmarshal(data, &l)
	if len(l.Windows) != 2 || l.Windows[0].Kind != "five_hour" || l.Windows[0].UsedPercent != 23.5 || l.Windows[1].Minutes != 10080 || l.Dir != cfg {
		t.Fatalf("limits = %+v", l)
	}
	out.Reset()
	StatusLine(nil, strings.NewReader(in), &out, dir)
	if strings.TrimSpace(out.String()) != "Opus · 5h 24% · 7d 41%" {
		t.Errorf("default line = %q", out.String())
	}
	// No limits (an API key, a first response not in yet): nothing kept, no crash.
	out.Reset()
	if err := StatusLine(nil, strings.NewReader(`{"model":{"display_name":"Sonnet"}}`), &out, t.TempDir()); err != nil || strings.TrimSpace(out.String()) != "Sonnet" {
		t.Errorf("no limits = %q %v", out.String(), err)
	}
}
