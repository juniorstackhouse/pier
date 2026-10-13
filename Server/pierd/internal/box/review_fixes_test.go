package box

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Regressions for what the review of the projects, environments and links work found.

func TestARepositoryConfigThatIsNotAFileIsRefused(t *testing.T) {
	c, _ := servedBox(t)
	repo := gitRepo(t)
	fifo := filepath.Join(t.TempDir(), "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Skip("no FIFOs here")
	}
	os.MkdirAll(filepath.Join(repo, ".pier"), 0o755)
	os.Symlink(fifo, filepath.Join(repo, ".pier", "config.json"))
	done := make(chan int, 1)
	go func() {
		done <- call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "evil", "path": repo}, nil)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("adding a repository whose config is a pipe hangs")
	}
	big := gitRepo(t)
	os.MkdirAll(filepath.Join(big, ".pier"), 0o755)
	os.WriteFile(filepath.Join(big, ".pier", "config.json"), make([]byte, maxRepoFile+1), 0o644)
	if _, _, ok, err := readRepoFile(big); ok || err == nil {
		t.Error("a config larger than the limit was read")
	}
}

func TestEnvironmentKeysDoNotCollide(t *testing.T) {
	for _, pair := range [][2]string{{"my_app", "my-app"}, {"Shop", "shop"}, {"api", "api-cache"}} {
		if envKey(pair[0]) == envKey(pair[1]) || containerUnit(pair[0], "db") == containerUnit(pair[1], "db") {
			t.Errorf("%s and %s share an environment", pair[0], pair[1])
		}
	}
	if containerUnit("api", "cache-redis") == containerUnit("api-cache", "redis") {
		t.Error("units collide across location and container names")
	}
}

func TestOnlyPierVariablesAreExpanded(t *testing.T) {
	vars := map[string]string{"PIER_PORT": "41010", "PORT": "41010"}
	cases := map[string]string{
		"p@ss$w0rd":                     "p@ss$w0rd",
		"$2y$10$abcdefghijklmnopqrstuv": "$2y$10$abcdefghijklmnopqrstuv",
		"http://localhost:$PIER_PORT":   "http://localhost:41010",
		"${PORT}/x and $HOME":           "41010/x and $HOME",
	}
	for in, want := range cases {
		if got := expandPier(in, vars); got != want {
			t.Errorf("expandPier(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPurgeOnlyTakesARepositorysTopFolder(t *testing.T) {
	c, _ := servedBox(t)
	repo := gitRepo(t)
	sub := filepath.Join(repo, "apps", "web")
	os.MkdirAll(sub, 0o755)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "web", "path": sub}, nil)
	var disk DiskUse
	call(t, c, "GET", "/v1/locations/web/disk", "", nil, &disk)
	if disk.Removable {
		t.Fatalf("a folder inside a repository can be purged: %+v", disk)
	}
	if status := call(t, c, "DELETE", "/v1/locations/web?purge=1&force=1", "", nil, nil); status != 409 {
		t.Fatalf("purge = %d", status)
	}
	if _, err := os.Stat(sub); err != nil {
		t.Fatal("the folder was deleted")
	}
}

func TestSpacesAreOnlyFoldersMadeAsSpaces(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	c, _ := servedBox(t)
	root := filepath.Join(home, "code")
	var s SettingsView
	call(t, c, "PUT", "/v1/settings", "", map[string]string{"projects_root": root}, &s)
	root = s.ProjectsRoot
	// A folder that is just there is no space.
	plain := filepath.Join(root, "clients", "app")
	os.MkdirAll(plain, 0o755)
	os.WriteFile(filepath.Join(plain, "work.txt"), []byte("uncommitted"), 0o644)
	if status := call(t, c, "DELETE", "/v1/spaces/clients?purge=1&force=1", "", nil, nil); status != 404 {
		t.Fatalf("a plain folder removed as a space: %d", status)
	}
	// A space with a folder that is no project needs delete_files.
	call(t, c, "POST", "/v1/spaces", "", map[string]string{"name": "acme"}, nil)
	os.MkdirAll(filepath.Join(root, "acme", "notes"), 0o755)
	var e struct{ Code, Error string }
	if status := call(t, c, "DELETE", "/v1/spaces/acme?purge=1&force=1", "", nil, &e); status != 409 || e.Code != CodeSpaceHasFiles || !strings.Contains(e.Error, "notes") {
		t.Fatalf("remove a space with other files = %d %+v", status, e)
	}
	if status := call(t, c, "DELETE", "/v1/spaces/acme?delete_files=1", "", nil, nil); status != 200 {
		t.Fatalf("remove with delete_files = %d", status)
	}
	// The home folder or above it is no projects folder.
	for _, bad := range []string{home, filepath.Dir(home)} {
		if status := call(t, c, "PUT", "/v1/settings", "", map[string]string{"projects_root": bad}, nil); status != 400 {
			t.Errorf("projects folder %s = %d", bad, status)
		}
	}
}

func TestTwoClonesOfOneRepositoryAtOnce(t *testing.T) {
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { bx = b })
	parent := t.TempDir()
	first := &Clone{ID: "a", Location: "shop", Path: filepath.Join(parent, "shop"), State: CloneCloning, Started: time.Now()}
	if !bx.clones.reserve(first) {
		t.Fatal("first reservation refused")
	}
	if bx.clones.reserve(&Clone{ID: "b", Location: "shop-2", Path: first.Path, State: CloneCloning}) {
		t.Fatal("a second clone into the same folder was let through")
	}
	if bx.clones.reserve(&Clone{ID: "c", Location: "Shop", Path: filepath.Join(parent, "x"), State: CloneCloning}) {
		t.Fatal("a second clone with the same name was let through")
	}
	_ = c
}
