package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestFindReposLooksInsideTheUsualFolders(t *testing.T) {
	home := t.TempDir()
	mk := func(p string) {
		if err := os.MkdirAll(filepath.Join(home, p), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	mk("code/web/.git")
	mk("code/api/.git")
	mk("code/notes")        // not a repository
	mk("code/.hidden/.git") // hidden folders are skipped
	mk("Projects/Billing/.git")
	mk("src/.git")                 // the folder is a repository itself
	mk("code/web/vendor/lib/.git") // two levels down: not looked at
	got := findRepos(append(defaultProjectFolders(home), filepath.Join(home, "code")), 10)
	var names []string
	for _, r := range got {
		names = append(names, r.name)
	}
	if want := []string{"api", "Billing", "src", "web"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("findRepos = %v, want %v (each once, by name)", names, want)
	}
	if got[0].path != filepath.Join(home, "code", "api") {
		t.Fatalf("path = %q", got[0].path)
	}
	if n := len(findRepos(defaultProjectFolders(home), 2)); n != 2 {
		t.Fatalf("max 2 gave %d", n)
	}
	if got := findRepos([]string{filepath.Join(home, "missing")}, 10); len(got) != 0 {
		t.Fatalf("a missing folder gave %v", got)
	}
}

func TestUniqueName(t *testing.T) {
	taken := map[string]bool{"web": true, "web-2": true}
	if got := uniqueName("web", taken); got != "web-3" {
		t.Fatalf("uniqueName = %q", got)
	}
	if got := uniqueName("api", taken); got != "api" {
		t.Fatalf("uniqueName = %q", got)
	}
}

func TestPublicAddress(t *testing.T) {
	for addr, want := range map[string]bool{
		"203.0.113.7:7444":     true,
		"box.example.com:7444": true,
		"192.168.1.20:7444":    false,
		"10.0.0.5:7444":        false,
		"100.101.102.103:7444": false,
		"ana-mac.local:7444":   false,
		"127.0.0.1:7444":       false,
	} {
		if got := publicAddress(addr); got != want {
			t.Errorf("publicAddress(%q) = %v, want %v", addr, got, want)
		}
	}
}
