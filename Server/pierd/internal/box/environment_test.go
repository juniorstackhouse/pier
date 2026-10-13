package box

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPlaceOf(t *testing.T) {
	cases := []struct {
		path, root, space string
		outside           bool
	}{
		{"/srv/code/shop", "/srv/code", "", false},
		{"/srv/code/acme/shop", "/srv/code", "acme", false},
		{"/srv/code-old/shop", "/srv/code", "", true},
		{"/home/x/shop", "", "", false},
	}
	for _, c := range cases {
		space, outside := placeOf(c.path, c.root)
		if space != c.space || outside != c.outside {
			t.Errorf("placeOf(%s, %s) = %q %v", c.path, c.root, space, outside)
		}
	}
}

func TestRuntimePresetsAndKinds(t *testing.T) {
	_, dockerfile, cmds, err := runtimePreset("php:8.4")
	if err != nil || !strings.Contains(dockerfile, "FROM php:8.4-cli") || !strings.Contains(dockerfile, "composer") || cmds[0] != "php" {
		t.Fatalf("php preset = %q %v %v", dockerfile, cmds, err)
	}
	if img, df, cmds, err := runtimePreset("node:22"); err != nil || img != "node:22" || df != "" || cmds[1] != "npm" {
		t.Fatalf("node preset = %q %v %v", img, cmds, err)
	}
	for _, bad := range []string{"php", "cobol:1", "php:8.4; rm -rf /", "node:latest"} {
		if _, _, _, err := runtimePreset(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	vars := kindOf("mysql:8.0").vars("127.0.0.1", 41020)
	if vars["DB_PORT"] != "41020" || vars["DATABASE_URL"] != "mysql://root:pier@127.0.0.1:41020/app" {
		t.Errorf("mysql vars = %v", vars)
	}
	if kindOf("library/postgres:16-alpine").port != 5432 || kindOf("redis:7").port != 6379 || kindOf("nginx").port != 0 {
		t.Error("kinds by image name")
	}
}

func TestEnvironmentValidate(t *testing.T) {
	ok := []Environment{
		{},
		{Runtime: &EnvRuntime{Preset: "php:8.5"}, Containers: []EnvContainer{{Name: "mysql", Image: "mysql:8.4"}, {Name: "cache", Image: "redis:7"}}},
		{Runtime: &EnvRuntime{Image: "ghcr.io/acme/tools:1.2", Commands: []string{"acme"}}},
		{Runtime: &EnvRuntime{ProjectDockerfile: true, Commands: []string{"php"}}, Compose: true},
		{Containers: []EnvContainer{{Name: "search", Image: "getmeili/meilisearch:v1.10", Port: 7700}}},
	}
	for i, e := range ok {
		if err := e.validate(); err != nil {
			t.Errorf("%d: %v", i, err)
		}
	}
	bad := []Environment{
		{Runtime: &EnvRuntime{}},
		{Runtime: &EnvRuntime{Preset: "php:8.4", Image: "php:8.4"}},
		{Runtime: &EnvRuntime{Image: "php:8.4"}},
		{Runtime: &EnvRuntime{Image: "php:8.4 --privileged", Commands: []string{"php"}}},
		{Runtime: &EnvRuntime{Image: "x", Commands: []string{"php;id"}}},
		{Containers: []EnvContainer{{Name: "db", Image: "mysql:8"}, {Name: "db", Image: "mysql:5.7"}}},
		{Containers: []EnvContainer{{Name: "Web", Image: "nginx", Port: 80}}},
		{Containers: []EnvContainer{{Name: "web", Image: "nginx"}}},
		{Containers: []EnvContainer{{Name: "db", Image: "mysql:8", Env: map[string]string{"A B": "x"}}}},
	}
	for i, e := range bad {
		if err := e.validate(); err == nil {
			t.Errorf("bad %d accepted", i)
		}
	}
}

// The launcher runs the program in the image on the worktree's folder, with
// the caller's variables, through whatever docker is first on PATH.
func TestLauncherRunsInTheImage(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	fake := filepath.Join(dir, "fakebin")
	os.MkdirAll(fake, 0o755)
	os.WriteFile(filepath.Join(fake, "docker"), []byte("#!/bin/sh\nfor a in \"$@\"; do echo \"[$a]\"; done\n"), 0o755)
	mount := filepath.Join(dir, "code")
	wt := filepath.Join(mount, "shop-fix")
	os.MkdirAll(wt, 0o755)
	script := filepath.Join(dir, "php")
	os.WriteFile(script, []byte(launcher("pier-env-shop:latest", mount, filepath.Join(dir, "home"), "php")), 0o755)
	cmd := exec.Command(script, "artisan", "serve", "--port=41010")
	cmd.Dir = wt
	cmd.Env = append(os.Environ(), "PATH="+fake+":"+os.Getenv("PATH"), "PIER_PORT=41010", "DB_HOST=127.0.0.1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	got := string(out)
	for _, want := range []string{"[run]", "[--network]", "[host]", "[-w]", "[" + wt + "]", "[" + mount + ":" + mount + "]",
		"[PIER_PORT]", "[DB_HOST]", "[pier-env-shop:latest]", "[php]", "[artisan]", "[--port=41010]"} {
		if !strings.Contains(got, want) {
			t.Errorf("launcher did not pass %s:\n%s", want, got)
		}
	}
	if strings.Contains(got, "[PATH]") || strings.Contains(got, "[HOME]") {
		t.Errorf("launcher passed the host's PATH or HOME:\n%s", got)
	}
}

// Setting the projects folder, a space, a clone into it, the environment of
// that project applied (with a stand-in docker) and its variables reaching
// the worktree, and the space removed with its project.
func TestProjectsRootSpacesAndEnvironment(t *testing.T) {
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { bx = b; b.StateDir = t.TempDir() })
	var mu sync.Mutex
	var ran [][]string
	oldDocker, oldState := docker, dockerState
	docker = func(ctx context.Context, log *os.File, stdin string, args ...string) error {
		mu.Lock()
		defer mu.Unlock()
		ran = append(ran, args)
		return nil
	}
	dockerState = func(context.Context) DockerState { return DockerState{Available: true, Version: "27.0"} }
	t.Cleanup(func() { docker, dockerState = oldDocker, oldState })

	root := filepath.Join(t.TempDir(), "projects")
	var settings SettingsView
	if status := call(t, c, "PUT", "/v1/settings", "", map[string]string{"projects_root": root}, &settings); status != 200 || settings.ProjectsRoot == "" || !settings.Docker.Available {
		t.Fatalf("settings = %d %+v", status, settings)
	}
	root = settings.ProjectsRoot
	if status := call(t, c, "POST", "/v1/spaces", "", map[string]string{"name": "acme"}, nil); status != 200 {
		t.Fatalf("add space = %d", status)
	}
	outside := gitRepo(t)
	if status := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": outside}, nil); status != 403 {
		t.Fatalf("a location outside the projects folder = %d", status)
	}

	src := gitRepo(t)
	dest := filepath.Join(root, "acme", "shop")
	cl := Clone{ID: "c1", Repo: src, Location: "shop", Path: dest, State: CloneCloning, Started: time.Now()}
	bx.clones.add(&cl)
	bx.runClone("pier", cl, repoSource{URL: src, Name: "shop"}, false, false)
	var loc Location
	if call(t, c, "GET", "/v1/locations", "", nil, nil); func() bool {
		locs, _ := bx.Locations.List(context.Background())
		for _, l := range locs {
			if l.Name == "shop" {
				loc = l
			}
		}
		return loc.Space != "acme" || loc.OutsideRoot
	}() {
		t.Fatalf("clone's place = %+v", loc)
	}
	call(t, c, "GET", "/v1/settings", "", nil, &settings)
	if len(settings.Spaces) != 1 || settings.Spaces[0].Projects != 1 {
		t.Fatalf("spaces = %+v", settings.Spaces)
	}

	env := Environment{Runtime: &EnvRuntime{Preset: "php:8.4"}, Containers: []EnvContainer{{Name: "mysql", Image: "mysql:8.0"}}}
	var view EnvView
	if status := call(t, c, "PUT", "/v1/locations/shop/environment", "", env, &view); status != 202 {
		t.Fatalf("put environment = %d %+v", status, view)
	}
	waitUntil(t, "the environment", 10*time.Second, func() bool {
		call(t, c, "GET", "/v1/locations/shop/environment", "", nil, &view)
		return view.Status.State == "ready" || view.Status.State == "failed"
	})
	if view.Status.State != "ready" || view.Status.Image != envImageTag("shop") || len(view.Status.Containers) != 1 || view.Status.Containers[0].HostPort == 0 {
		t.Fatalf("environment = %+v", view.Status)
	}
	mu.Lock()
	if len(ran) == 0 || ran[0][0] != "build" {
		t.Errorf("docker calls = %v", ran)
	}
	mu.Unlock()
	if _, err := os.Stat(filepath.Join(bx.envDir("shop"), "bin", "composer")); err != nil {
		t.Errorf("no composer launcher: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".pier")); err == nil {
		t.Error("the environment wrote into the project")
	}
	wtEnv, err := bx.WorktreeEnv(context.Background(), "shop", loc.Worktrees[0])
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(wtEnv, "\n")
	for _, want := range []string{"PATH=" + filepath.Join(bx.envDir("shop"), "bin") + ":", "DB_HOST=127.0.0.1", "DB_CONNECTION=mysql", "PIER_MYSQL_PORT="} {
		if !strings.Contains(joined, want) {
			t.Errorf("worktree env lacks %s", want)
		}
	}

	var e struct{ Code string }
	if status := call(t, c, "DELETE", "/v1/spaces/acme", "", nil, &e); status != 409 || e.Code != CodeSpaceNotEmpty {
		t.Fatalf("remove a space with a project = %d %+v", status, e)
	}
	if status := call(t, c, "DELETE", "/v1/spaces/acme?purge=1", "", nil, nil); status != 200 {
		t.Fatalf("remove space with its project = %d", status)
	}
	if _, err := os.Stat(filepath.Join(root, "acme")); !os.IsNotExist(err) {
		t.Error("the space's folder is still there")
	}
	if _, err := os.Stat(bx.envDir("shop")); !os.IsNotExist(err) {
		t.Error("the project's environment is still there")
	}
	if _, err := bx.Locations.Get(context.Background(), "shop"); err == nil {
		t.Error("the project is still a location")
	}
}
