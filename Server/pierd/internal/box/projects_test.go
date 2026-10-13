package box

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseRepoSource(t *testing.T) {
	ok := []struct{ in, url, slug, name string }{
		{"octocat/shop", "https://github.com/octocat/shop.git", "octocat/shop", "shop"},
		{" octocat/shop.git ", "https://github.com/octocat/shop.git", "octocat/shop", "shop"},
		{"https://github.com/octocat/shop", "https://github.com/octocat/shop.git", "octocat/shop", "shop"},
		{"https://github.com/octocat/shop/tree/main/src", "https://github.com/octocat/shop.git", "octocat/shop", "shop"},
		{"https://github.com/octocat/shop.git", "https://github.com/octocat/shop.git", "octocat/shop", "shop"},
		{"git@github.com:octocat/shop.git", "git@github.com:octocat/shop.git", "octocat/shop", "shop"},
		{"ssh://git@github.com/octocat/shop.git", "ssh://git@github.com/octocat/shop.git", "octocat/shop", "shop"},
		{"https://gitlab.com/group/sub/app.git?x=1", "https://gitlab.com/group/sub/app.git", "", "app"},
		{"git@gitlab.com:group/app.git", "git@gitlab.com:group/app.git", "", "app"},
	}
	for _, c := range ok {
		got, err := parseRepoSource(c.in)
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if got.URL != c.url || got.Slug != c.slug || got.Name != c.name {
			t.Errorf("%q = %+v, want url %q slug %q name %q", c.in, got, c.url, c.slug, c.name)
		}
	}
	for _, in := range []string{"", "shop", "-upload-pack=x/y", "ext::sh -c touch% /tmp/x", "file:///etc", "/home/me/repo",
		"https://user:token@github.com/a/b", "https://github.com/a", "ftp://host/a.git", "https://host/$(id).git", "o/..", "javascript:alert(1)"} {
		if got, err := parseRepoSource(in); err == nil {
			t.Errorf("%q accepted as %+v", in, got)
		}
	}
}

func TestLocationName(t *testing.T) {
	taken := map[string]bool{"shop": true, "shop-2": true}
	if got := locationName("Shop", taken); got != "Shop-3" {
		t.Errorf("taken name = %q", got)
	}
	if got := locationName("my app!", nil); got != "my-app" {
		t.Errorf("sanitised = %q", got)
	}
	if got := locationName("...", nil); got != "project" {
		t.Errorf("empty = %q", got)
	}
}

func TestProjectsParent(t *testing.T) {
	locs := []Location{
		{Name: "a", Path: "/srv/code/a", Repo: true},
		{Name: "b", Path: "/srv/code/b", Repo: true},
		{Name: "c", Path: "/home/x/c", Repo: true},
		{Name: "notes", Path: "/home/x/notes"},
	}
	if got := projectsParent(locs); got != "/srv/code" {
		t.Errorf("parent = %q", got)
	}
}

func TestParseGHRepos(t *testing.T) {
	out := []byte(`[{"nameWithOwner":"octocat/old","name":"old","url":"https://github.com/octocat/old","isPrivate":false,"updatedAt":"2026-01-01T00:00:00Z","primaryLanguage":null},
{"nameWithOwner":"octocat/shop","name":"shop","description":"The shop","url":"https://github.com/octocat/shop","isPrivate":true,"isFork":true,"updatedAt":"2026-09-01T00:00:00Z","primaryLanguage":{"name":"Go"}}]`)
	got, err := parseGHRepos(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Slug != "octocat/shop" || !got[0].Private || !got[0].Fork || got[0].Language != "Go" || got[1].Language != "" {
		t.Fatalf("repos = %+v", got)
	}
}

// A clone of a repository with its own config is trusted and set up, and
// removing it from the disk refuses while a commit exists only there.
func TestCloneSetUpAndPurge(t *testing.T) {
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { bx = b })
	src := gitRepo(t)
	os.MkdirAll(filepath.Join(src, ".pier"), 0o755)
	os.WriteFile(filepath.Join(src, ".pier", "config.json"), []byte(`{"setup":"touch .ready"}`), 0o644)
	gitIn(t, src, "add", ".")
	gitIn(t, src, "commit", "-q", "-m", "config")

	dest := filepath.Join(t.TempDir(), "shop")
	cl := Clone{ID: "c1", Repo: src, Location: "shop", Path: dest, State: CloneCloning, Started: time.Now()}
	bx.clones.add(&cl)
	bx.runClone("pier", cl, repoSource{URL: src, Name: "shop"}, true, false)

	var list []Clone
	call(t, c, "GET", "/v1/clones", "", nil, &list)
	if len(list) != 1 || list[0].State != CloneReady || list[0].Setup != "repo" {
		t.Fatalf("clones = %+v", list)
	}
	if _, err := os.Stat(filepath.Join(dest, ".ready")); err != nil {
		t.Fatalf("setup did not run: %v", err)
	}
	if call(t, c, "POST", "/v1/locations/shop/worktrees", "", WorktreeRequest{Name: "fix"}, nil) != 200 {
		t.Fatal("worktree of the clone")
	}

	// A commit no remote has.
	os.WriteFile(filepath.Join(dest, "new.txt"), []byte("x"), 0o644)
	gitIn(t, dest, "add", "new.txt")
	gitIn(t, dest, "commit", "-q", "-m", "local only")

	var disk DiskUse
	if status := call(t, c, "GET", "/v1/locations/shop/disk", "", nil, &disk); status != 200 || !disk.Removable || disk.Bytes == 0 || len(disk.Paths) != 2 {
		t.Fatalf("disk = %d %+v", status, disk)
	}
	if len(disk.Unpushed) != 1 || disk.Unpushed[0].Commits != 1 {
		t.Fatalf("unpushed = %+v", disk.Unpushed)
	}
	var e struct{ Code string }
	if status := call(t, c, "DELETE", "/v1/locations/shop?purge=1", "", nil, &e); status != 409 || e.Code != CodeUnsavedWork {
		t.Fatalf("purge with unsaved work = %d %+v", status, e)
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatal("refused purge deleted the folder")
	}
	var done struct {
		Removed string
		Freed   int64
	}
	if status := call(t, c, "DELETE", "/v1/locations/shop?purge=1&force=1", "", nil, &done); status != 200 || done.Removed != "shop" || done.Freed == 0 {
		t.Fatalf("forced purge = %d %+v", status, done)
	}
	for _, p := range disk.Paths {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s still exists", p)
		}
	}
	if status := call(t, c, "GET", "/v1/locations/shop/disk", "", nil, nil); status != 404 {
		t.Errorf("location still there: %d", status)
	}
}

func TestPurgeRefusesAFolderHoldingAnotherLocation(t *testing.T) {
	c, _ := servedBox(t)
	repo := gitRepo(t)
	inner := filepath.Join(repo, "docs")
	os.MkdirAll(inner, 0o755)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "docs", "path": inner}, nil)
	var disk DiskUse
	call(t, c, "GET", "/v1/locations/cal/disk", "", nil, &disk)
	if disk.Removable {
		t.Fatalf("disk = %+v", disk)
	}
	if status := call(t, c, "DELETE", "/v1/locations/cal?purge=1&force=1", "", nil, nil); status != 409 {
		t.Fatalf("purge = %d", status)
	}
	if _, err := os.Stat(repo); err != nil {
		t.Fatal(err)
	}
}
