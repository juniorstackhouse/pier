package box

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/groups"
)

// A project's environment, isolated from every other's: the language it
// runs (PHP 8.4 here, 8.5 there) and the databases it needs (MySQL 5.7 here,
// 8.4 there), each in Docker, and none of it in the project. The runtime is
// an image whose programs (php, composer…) get small launchers in pierd's
// own folder, first on the PATH of everything that runs in the project's
// worktrees — agents, terminals, services, setup — so they run in the
// container on the worktree's files, unaware of it. Databases are
// containers of their own, with their data in Docker volumes, reached on a
// port of the box's; their addresses reach the worktrees as DB_HOST,
// DATABASE_URL and the like. A project that ships its own Dockerfile or
// compose file can use that instead; otherwise Docker never touches it.

// Environment is a location's isolated environment, the box's own config
// for it (never written into the repository).
type Environment struct {
	Runtime    *EnvRuntime    `json:"runtime,omitempty"`
	Containers []EnvContainer `json:"containers,omitempty"`
	// Compose runs the project's own compose file in each worktree, as its
	// "compose" service.
	Compose bool `json:"compose,omitempty"`
}

// EnvRuntime is the image the project's programs run in: a preset
// ("php:8.4", "node:22", "python:3.12", "ruby:3.3", "go:1.23"), any image,
// or the project's own Dockerfile.
type EnvRuntime struct {
	Preset string `json:"preset,omitempty"`
	Image  string `json:"image,omitempty"`
	// ProjectDockerfile builds the image from the repository's Dockerfile.
	ProjectDockerfile bool `json:"project_dockerfile,omitempty"`
	// Commands get launchers; the preset's by default.
	Commands []string `json:"commands,omitempty"`
}

// EnvContainer is a service container of the project, such as its database.
type EnvContainer struct {
	Name  string `json:"name"`
	Image string `json:"image"`
	// Port is the container's own port; the kind's by default (3306…).
	Port int               `json:"port,omitempty"`
	Env  map[string]string `json:"env,omitempty"`
}

// EnvStatus is how a location's environment stands (GET …/environment).
type EnvStatus struct {
	// State: "none", "building", "ready" or "failed".
	State string `json:"state"`
	Error string `json:"error,omitempty"`
	// Image is what the runtime's launchers run.
	Image      string               `json:"image,omitempty"`
	Commands   []string             `json:"commands,omitempty"`
	Containers []EnvContainerStatus `json:"containers"`
	// Variables are the names the worktrees get from the environment.
	Variables []string `json:"variables"`
	Log       string   `json:"log,omitempty"`
}

type EnvContainerStatus struct {
	Name     string `json:"name"`
	Image    string `json:"image"`
	HostPort int    `json:"host_port,omitempty"`
	State    string `json:"state"`
	Unit     string `json:"unit"`
}

// EnvView answers GET /v1/locations/{name}/environment.
type EnvView struct {
	Environment Environment `json:"environment"`
	Status      EnvStatus   `json:"status"`
	// Project says what the repository ships: a Dockerfile, a compose file.
	Project struct {
		Dockerfile bool `json:"dockerfile"`
		Compose    bool `json:"compose"`
	} `json:"project"`
	Docker DockerState `json:"docker"`
}

// DockerState says whether the box can run the environments.
type DockerState struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	Error     string `json:"error,omitempty"`
}

var (
	imageRef      = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$`)
	launcherName  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,40}$`)
	errDocker     = errors.New("docker is not available on this box; install it (and add the box's user to the docker group) to isolate environments")
	presetVersion = regexp.MustCompile(`^[0-9][0-9.]{0,10}$`)
)

// runtimePreset is the image and launchers of a preset: the official image,
// and for PHP one built from it with Composer and the extensions most
// projects need.
func runtimePreset(preset string) (image, dockerfile string, commands []string, err error) {
	lang, version, ok := strings.Cut(preset, ":")
	if !ok || !presetVersion.MatchString(version) {
		return "", "", nil, badRequest("unknown runtime %q: use php:8.4, node:22, python:3.12, ruby:3.3 or go:1.23", preset)
	}
	switch lang {
	case "php":
		return "", "FROM php:" + version + "-cli\n" +
				"RUN apt-get update && apt-get install -y --no-install-recommends git unzip libzip-dev libicu-dev libpng-dev libpq-dev && rm -rf /var/lib/apt/lists/* \\\n" +
				" && docker-php-ext-install pdo_mysql mysqli pdo_pgsql zip intl gd bcmath pcntl\n" +
				"COPY --from=composer:2 /usr/bin/composer /usr/bin/composer\n",
			[]string{"php", "composer"}, nil
	case "node":
		return "node:" + version, "", []string{"node", "npm", "npx", "corepack", "yarn", "pnpm"}, nil
	case "python":
		return "python:" + version, "", []string{"python", "python3", "pip", "pip3"}, nil
	case "ruby":
		return "ruby:" + version, "", []string{"ruby", "gem", "bundle", "bundler", "irb"}, nil
	case "go":
		return "golang:" + version, "", []string{"go", "gofmt"}, nil
	}
	return "", "", nil, badRequest("unknown runtime %q: use php, node, python, ruby or go", lang)
}

// containerKind is what pierd knows of a service image: its port, where it
// keeps its data, the variables a project reads it from, and what it needs
// to start.
type containerKind struct {
	port int
	data string
	env  map[string]string
	vars func(host string, port int) map[string]string
}

const envPassword = "pier"

func kindOf(image string) containerKind {
	name := image
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	name, _, _ = strings.Cut(name, ":")
	switch name {
	case "mysql", "mariadb":
		return containerKind{port: 3306, data: "/var/lib/mysql",
			env: map[string]string{"MYSQL_ROOT_PASSWORD": envPassword, "MYSQL_DATABASE": "app", "MARIADB_ROOT_PASSWORD": envPassword, "MARIADB_DATABASE": "app"},
			vars: func(h string, p int) map[string]string {
				return map[string]string{"DB_CONNECTION": "mysql", "DB_HOST": h, "DB_PORT": strconv.Itoa(p), "DB_DATABASE": "app", "DB_USERNAME": "root",
					"DB_PASSWORD": envPassword, "DATABASE_URL": fmt.Sprintf("mysql://root:%s@%s:%d/app", envPassword, h, p)}
			}}
	case "postgres", "postgis":
		return containerKind{port: 5432, data: "/var/lib/postgresql/data",
			env: map[string]string{"POSTGRES_PASSWORD": envPassword, "POSTGRES_DB": "app"},
			vars: func(h string, p int) map[string]string {
				return map[string]string{"DB_CONNECTION": "pgsql", "DB_HOST": h, "DB_PORT": strconv.Itoa(p), "DB_DATABASE": "app", "DB_USERNAME": "postgres",
					"DB_PASSWORD": envPassword, "DATABASE_URL": fmt.Sprintf("postgres://postgres:%s@%s:%d/app", envPassword, h, p)}
			}}
	case "redis", "valkey":
		return containerKind{port: 6379, data: "/data", vars: func(h string, p int) map[string]string {
			return map[string]string{"REDIS_HOST": h, "REDIS_PORT": strconv.Itoa(p), "REDIS_URL": fmt.Sprintf("redis://%s:%d", h, p)}
		}}
	case "mongo":
		return containerKind{port: 27017, data: "/data/db", vars: func(h string, p int) map[string]string {
			return map[string]string{"MONGODB_URI": fmt.Sprintf("mongodb://%s:%d/app", h, p)}
		}}
	}
	return containerKind{}
}

func (e Environment) validate() error {
	if r := e.Runtime; r != nil {
		n := 0
		if r.Preset != "" {
			n++
			if _, _, _, err := runtimePreset(r.Preset); err != nil {
				return err
			}
		}
		if r.Image != "" {
			n++
			if !imageRef.MatchString(r.Image) {
				return badRequest("%q is not an image name", r.Image)
			}
		}
		if r.ProjectDockerfile {
			n++
		}
		if n != 1 {
			return badRequest("a runtime is one of a preset, an image or the project's Dockerfile")
		}
		for _, c := range r.Commands {
			if !launcherName.MatchString(c) {
				return badRequest("%q is not a program name", c)
			}
		}
		if r.Image != "" && len(r.Commands) == 0 {
			return badRequest("say which programs run in %s", r.Image)
		}
	}
	seen := map[string]bool{}
	for _, c := range e.Containers {
		if !serviceName.MatchString(c.Name) {
			return badRequest("container name %q must be lowercase letters, digits and dashes", c.Name)
		}
		if seen[c.Name] {
			return badRequest("two containers are called %s", c.Name)
		}
		seen[c.Name] = true
		if !imageRef.MatchString(c.Image) {
			return badRequest("%q is not an image name", c.Image)
		}
		if c.Port == 0 && kindOf(c.Image).port == 0 {
			return badRequest("say which port %s listens on", c.Image)
		}
		if c.Port < 0 || c.Port > 65535 {
			return badRequest("port %d is not a port", c.Port)
		}
		for k := range c.Env {
			if !envName.MatchString(k) {
				return badRequest("%q is not a variable name", k)
			}
		}
	}
	return nil
}

func (e Environment) empty() bool { return e.Runtime == nil && len(e.Containers) == 0 && !e.Compose }

// envDir is pierd's folder for a location's environment: launchers,
// the anchors of the containers' ports, logs.
func (b *Box) envDir(location string) string {
	base := b.StateDir
	if base == "" {
		base = filepath.Join(os.TempDir(), "pier-env")
	}
	return filepath.Join(base, "env", envKey(location))
}

// envKey names a location's environment in folders, images, units and
// volumes: its slug, and a hash of its exact name, so "my-app" and "my_app"
// (or "Shop" and "shop") never share a database.
func envKey(location string) string {
	sum := sha256.Sum256([]byte(location))
	return slug(location, 40) + "-" + hex.EncodeToString(sum[:3])
}

func envImageTag(location string) string { return "pier-env-" + envKey(location) + ":latest" }

func containerUnit(location, name string) string {
	n := "ctr-" + envKey(location) + "-" + name
	if len(n) > 128 {
		n = n[:128]
	}
	return strings.TrimRight(n, "-")
}

// containerPort is the box's port a container is reached on: a block of
// the box's own, anchored to a folder of pierd's.
func (b *Box) containerPort(location, name string) (int, error) {
	anchor := filepath.Join(b.envDir(location), "containers", name)
	if err := os.MkdirAll(anchor, 0o700); err != nil {
		return 0, err
	}
	return b.Locations.Ports.For(anchor)
}

// envStates are the environments' build states, in memory.
type envStates struct {
	mu  sync.Mutex
	all map[string]EnvStatus
}

func (s *envStates) get(loc string) (EnvStatus, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.all[loc]
	return st, ok
}

func (s *envStates) set(loc string, st EnvStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.all == nil {
		s.all = map[string]EnvStatus{}
	}
	s.all[loc] = st
}

// docker runs the docker CLI through the login shell (where it is on PATH).
var docker = func(ctx context.Context, log *os.File, stdin string, args ...string) error {
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	shArgs, shVar := shInLogin("exec docker " + strings.Join(quoted, " "))
	cmd := groups.CommandContext(ctx, loginShell(), shArgs...)
	cmd.Env = append(os.Environ(), shVar)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out strings.Builder
	if log != nil {
		cmd.Stdout, cmd.Stderr = log, log
	} else {
		cmd.Stdout, cmd.Stderr = &out, &out
	}
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Run(); err != nil {
		if s := strings.TrimSpace(out.String()); s != "" {
			return fmt.Errorf("docker %s: %s", args[0], s)
		}
		return fmt.Errorf("docker %s: %w", args[0], err)
	}
	return nil
}

// dockerState asks the box's docker for its server's version.
var dockerState = func(ctx context.Context) DockerState {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	shArgs, shVar := shInLogin("docker version --format '{{.Server.Version}}'")
	cmd := exec.CommandContext(ctx, loginShell(), shArgs...)
	cmd.Env = append(os.Environ(), shVar)
	out, err := cmd.CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err != nil {
		if s == "" {
			s = errDocker.Error()
		}
		return DockerState{Error: lastLine(s)}
	}
	return DockerState{Available: true, Version: lastLine(s)}
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// Environment reads a location's environment config.
func (l *Locations) Environment(name string) (Environment, error) {
	s, err := l.saved(name)
	if err != nil {
		return Environment{}, err
	}
	if s.Environment == nil {
		return Environment{}, nil
	}
	return *s.Environment, nil
}

// SetEnvironment replaces a location's environment config.
func (l *Locations) SetEnvironment(name string, e Environment) error {
	if err := e.validate(); err != nil {
		return err
	}
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name == name {
				if e.empty() {
					all[i].Environment = nil
				} else {
					ee := e
					all[i].Environment = &ee
				}
				return all, nil
			}
		}
		return nil, ErrUnknownLocation
	})
}

// envVariables are what a location's environment adds to its worktrees: the
// launchers first on PATH, and each container's address.
func (b *Box) envVariables(ctx context.Context, location string) map[string]string {
	env, err := b.Locations.Environment(location)
	if err != nil || env.empty() {
		return nil
	}
	out := map[string]string{}
	if env.Runtime != nil {
		// The launchers once written: until then the box's own programs run.
		bin := filepath.Join(b.envDir(location), "bin")
		if _, err := os.Stat(bin); err == nil {
			out["PIER_ENV_BIN"] = bin
			out["PATH"] = bin + string(os.PathListSeparator) + os.Getenv("PATH")
		}
	}
	for _, c := range env.Containers {
		port, err := b.containerPort(location, c.Name)
		if err != nil || port == 0 {
			continue
		}
		key := strings.ToUpper(strings.ReplaceAll(c.Name, "-", "_"))
		out["PIER_"+key+"_HOST"] = "127.0.0.1"
		out["PIER_"+key+"_PORT"] = strconv.Itoa(port)
		if k := kindOf(c.Image); k.vars != nil {
			for name, v := range k.vars("127.0.0.1", port) {
				if _, taken := out[name]; !taken {
					out[name] = v
				}
			}
		}
	}
	return out
}

// launcher is the script that runs one program of the project's runtime in
// its image, on the worktree's files at the same path, as the box's user,
// on the box's network (its ports are the worktree's), with the caller's
// environment. Only the worktree it runs in is mounted (and the repository's
// git folder, which a linked worktree's .git points into), never the folder
// around it; outside any worktree, the repository's main checkout.
func launcher(image, repo, cache, command string) string {
	run := `docker run --rm -i $tty --network host --user "$(id -u):$(id -g)" -e HOME=/tmp/pier-home -v ` + shellQuote(cache) + `:/tmp/pier-home`
	tail := `-w "$wd" $envs ` + shellQuote(image) + ` ` + shellQuote(command) + ` "$@"`
	return `#!/bin/sh
# pierd: ` + command + ` runs in ` + image + `, this project's environment.
envs=""
for n in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
  case "$n" in
    PATH|HOME|SHELL|PWD|OLDPWD|TMPDIR|SHLVL|_|USER|LOGNAME|MAIL|SSH_*|XDG_*|DBUS_*|LD_*|DYLD_*|TERM_*|LS_COLORS|PIER_ENV_BIN) ;;
    *) envs="$envs -e $n" ;;
  esac
done
tty=""; if [ -t 0 ] && [ -t 1 ]; then tty="-t"; fi
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
[ -n "$top" ] || top=` + shellQuote(repo) + `
common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
case "$PWD" in "$top"|"$top"/*) wd="$PWD" ;; *) wd="$top" ;; esac
mkdir -p ` + shellQuote(cache) + `
case "$common" in ""|"$top"/*)
  # shellcheck disable=SC2086
  exec ` + run + ` -v "$top:$top" ` + tail + ` ;;
esac
# shellcheck disable=SC2086
exec ` + run + ` -v "$top:$top" -v "$common:$common" ` + tail + `
`
}

// applyEnvironment makes a location's environment real: the runtime's
// image built or pulled and its launchers written, the containers running
// and the ones taken out stopped. It runs in the background.
func (b *Box) applyEnvironment(from, location string, removed []string) {
	// One apply of a location at a time: two would race on its launchers
	// and image.
	mu, _ := b.envLocks.LoadOrStore(location, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	defer mu.(*sync.Mutex).Unlock()
	ctx := context.Background()
	dir := b.envDir(location)
	os.MkdirAll(dir, 0o700)
	logPath := filepath.Join(dir, "apply.log")
	log, _ := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if log != nil {
		defer log.Close()
	}
	st := EnvStatus{State: "building", Log: logPath}
	b.envState.set(location, st)
	b.Events.Publish(events.Event{Type: "environment.started", Box: b.Name, Origin: from, Data: map[string]any{"location": location}})
	fail := func(err error) {
		st.State, st.Error = "failed", err.Error()
		if log != nil {
			if tail := logTail(logPath, 20, 2048); tail != "" {
				st.Error += "\n" + tail
			}
		}
		b.envState.set(location, st)
		b.Events.Publish(events.Event{Type: "environment.failed", Box: b.Name, Origin: from, Error: st.Error, Data: map[string]any{"location": location}})
	}
	for _, name := range removed {
		if b.Units != nil {
			b.Units.Remove(containerUnit(location, name))
		}
	}
	env, err := b.Locations.Environment(location)
	if err != nil {
		fail(err)
		return
	}
	loc, err := b.Locations.Get(ctx, location)
	if err != nil {
		fail(err)
		return
	}
	// The launchers in use stay until new ones are ready: during a build, or
	// after a failed one, the project keeps its last working environment.
	bin := filepath.Join(dir, "bin")
	binNew := bin + ".new"
	os.RemoveAll(binNew)
	if env.Runtime != nil {
		image, commands, err := b.buildRuntime(ctx, log, loc, *env.Runtime)
		if err != nil {
			fail(err)
			return
		}
		if err := os.MkdirAll(binNew, 0o700); err != nil {
			fail(err)
			return
		}
		for _, c := range commands {
			if err := os.WriteFile(filepath.Join(binNew, c), []byte(launcher(image, loc.Path, filepath.Join(dir, "home"), c)), 0o755); err != nil {
				fail(err)
				return
			}
		}
		st.Image, st.Commands = image, commands
		os.RemoveAll(bin)
		if err := os.Rename(binNew, bin); err != nil {
			fail(err)
			return
		}
	} else {
		os.RemoveAll(bin)
	}
	for _, c := range env.Containers {
		if err := b.startContainer(ctx, log, location, c); err != nil {
			fail(err)
			return
		}
	}
	st.State = "ready"
	b.envState.set(location, st)
	b.Events.Publish(events.Event{Type: "environment.ready", Box: b.Name, Origin: from, Data: map[string]any{"location": location, "image": st.Image}})
}

// buildRuntime makes the runtime's image: a preset's (built from its
// Dockerfile, or pulled), the image named, or the project's Dockerfile.
func (b *Box) buildRuntime(ctx context.Context, log *os.File, loc Location, r EnvRuntime) (string, []string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	switch {
	case r.Preset != "":
		image, dockerfile, commands, err := runtimePreset(r.Preset)
		if err != nil {
			return "", nil, err
		}
		if len(r.Commands) > 0 {
			commands = r.Commands
		}
		if dockerfile != "" {
			tag := envImageTag(loc.Name)
			return tag, commands, docker(ctx, log, dockerfile, "build", "-t", tag, "-")
		}
		return image, commands, docker(ctx, log, "", "pull", image)
	case r.ProjectDockerfile:
		if _, err := os.Stat(filepath.Join(loc.Path, "Dockerfile")); err != nil {
			return "", nil, badRequest("%s has no Dockerfile", loc.Name)
		}
		tag := envImageTag(loc.Name)
		commands := r.Commands
		if len(commands) == 0 {
			return "", nil, badRequest("say which programs run in the project's image")
		}
		return tag, commands, docker(ctx, log, "", "build", "-t", tag, "-f", filepath.Join(loc.Path, "Dockerfile"), loc.Path)
	default:
		return r.Image, r.Commands, docker(ctx, log, "", "pull", r.Image)
	}
}

// startContainer runs one of the project's containers as a managed unit,
// its data in a volume of its own and its port on 127.0.0.1.
func (b *Box) startContainer(ctx context.Context, log *os.File, location string, c EnvContainer) error {
	if b.Units == nil {
		return httpError{http.StatusNotImplemented, "this box cannot run managed units"}
	}
	port, err := b.containerPort(location, c.Name)
	if err != nil {
		return err
	}
	k := kindOf(c.Image)
	inner := c.Port
	if inner == 0 {
		inner = k.port
	}
	unit := containerUnit(location, c.Name)
	args := []string{"run", "--rm", "--name", unit, "-p", fmt.Sprintf("127.0.0.1:%d:%d", port, inner)}
	if k.data != "" {
		args = append(args, "-v", unit+":"+k.data)
	}
	vars := map[string]string{}
	for key, v := range k.env {
		vars[key] = v
	}
	for key, v := range c.Env {
		vars[key] = v
	}
	keys := make([]string, 0, len(vars))
	for key := range vars {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	// In a file only the box's user reads, not on the command line, where
	// every user of the machine sees it (ps).
	var envFile strings.Builder
	for _, key := range keys {
		if strings.ContainsAny(vars[key], "\n\r") {
			return badRequest("%s of %s spans lines", key, c.Name)
		}
		envFile.WriteString(key + "=" + vars[key] + "\n")
	}
	envPath := filepath.Join(b.envDir(location), "containers", c.Name+".env")
	if err := os.MkdirAll(filepath.Dir(envPath), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(envPath, []byte(envFile.String()), 0o600); err != nil {
		return err
	}
	args = append(args, "--env-file", envPath, c.Image)
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	// A container left by a crash would hold the name: it goes first.
	script := "docker rm -f " + shellQuote(unit) + " >/dev/null 2>&1; exec docker " + strings.Join(quoted, " ")
	if log != nil {
		fmt.Fprintf(log, "starting %s (%s) on 127.0.0.1:%d\n", c.Name, c.Image, port)
	}
	shArgs, shVar := shInLogin(script)
	_, err = b.Units.Install(ctx, UnitRequest{Name: unit, Program: loginShell(), Args: shArgs, Env: map[string]string{"PIER_SH": strings.TrimPrefix(shVar, "PIER_SH=")}})
	return err
}

// dropEnvironment stops a location's containers and removes its launchers,
// and with data its volumes and built image: a project leaving the disk.
func (b *Box) dropEnvironment(location string, data bool) {
	env, _ := b.Locations.Environment(location)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	for _, c := range env.Containers {
		unit := containerUnit(location, c.Name)
		if b.Units != nil {
			b.Units.Remove(unit)
		}
		b.Locations.Ports.Release(filepath.Join(b.envDir(location), "containers", c.Name))
		if data {
			docker(ctx, nil, "", "volume", "rm", "-f", unit)
		}
	}
	if data && env.Runtime != nil && (env.Runtime.ProjectDockerfile || env.Runtime.Preset != "" && strings.HasPrefix(env.Runtime.Preset, "php:")) {
		docker(ctx, nil, "", "image", "rm", envImageTag(location))
	}
	os.RemoveAll(b.envDir(location))
}

func (b *Box) environmentView(ctx context.Context, location string) (EnvView, error) {
	loc, err := b.Locations.Get(ctx, location)
	if err != nil {
		return EnvView{}, err
	}
	env, err := b.Locations.Environment(location)
	if err != nil {
		return EnvView{}, err
	}
	v := EnvView{Environment: env, Docker: dockerState(ctx)}
	for _, f := range []string{"Dockerfile"} {
		if _, err := os.Stat(filepath.Join(loc.Path, f)); err == nil {
			v.Project.Dockerfile = true
		}
	}
	for _, f := range composeFiles {
		if _, err := os.Stat(filepath.Join(loc.Path, f)); err == nil {
			v.Project.Compose = true
		}
	}
	st, ok := b.envState.get(location)
	if !ok {
		st = EnvStatus{State: "none"}
		if !env.empty() {
			// pierd restarted since it was applied: what is on disk tells.
			st.State = "ready"
			if env.Runtime != nil {
				if _, err := os.Stat(filepath.Join(b.envDir(location), "bin")); err != nil {
					st.State = "none"
				}
			}
		}
	}
	st.Containers = []EnvContainerStatus{}
	for _, c := range env.Containers {
		cs := EnvContainerStatus{Name: c.Name, Image: c.Image, Unit: containerUnit(location, c.Name), State: "stopped"}
		cs.HostPort, _ = b.containerPort(location, c.Name)
		if b.Units != nil {
			if u, err := b.Units.Get(cs.Unit); err == nil {
				cs.State = u.State
			}
		}
		st.Containers = append(st.Containers, cs)
	}
	st.Variables = []string{}
	for k := range b.envVariables(ctx, location) {
		if k != "PATH" {
			st.Variables = append(st.Variables, k)
		}
	}
	sort.Strings(st.Variables)
	v.Status = st
	return v, nil
}

// envBinFirst puts the environment's launchers back first on PATH in a login
// shell, whose profile may have put the box's own programs before them.
const envBinFirst = `[ -n "$PIER_ENV_BIN" ] && PATH="$PIER_ENV_BIN:$PATH"; `

var composeFiles = []string{"compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"}

// composeService is the service that runs the project's compose file in a
// worktree, named after it so worktrees never share containers.
var composeService = WorktreeService{Name: "compose", Run: `docker compose -p "$PIER_COMPOSE_PROJECT" up --remove-orphans`, Autostart: true}

// composeProject is a worktree's compose project name: its location's
// environment and a hash of its folder, unique on the box.
func composeProject(location string, wt Worktree) string {
	sum := sha256.Sum256([]byte(wt.Path))
	return "pier-" + envKey(location) + "-" + hex.EncodeToString(sum[:3])
}

func (b *Box) getEnvironment(w http.ResponseWriter, r *http.Request) error {
	v, err := b.environmentView(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	writeJSON(w, v)
	return nil
}

// putEnvironment saves a location's environment and applies it in the
// background (202): build, launchers, containers; environment.* events say
// how it went.
func (b *Box) putEnvironment(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	var env Environment
	if err := decode(r, &env); err != nil {
		return err
	}
	if err := env.validate(); err != nil {
		return err
	}
	if !env.empty() {
		if d := dockerState(r.Context()); !d.Available {
			return httpError{http.StatusNotImplemented, errDocker.Error() + " (" + d.Error + ")"}
		}
	}
	old, err := b.Locations.Environment(name)
	if err != nil {
		return err
	}
	if err := b.before(r, "environment.change", map[string]any{"location": name}); err != nil {
		return err
	}
	if err := b.Locations.SetEnvironment(name, env); err != nil {
		return err
	}
	var removed []string
	for _, o := range old.Containers {
		keep := false
		for _, c := range env.Containers {
			keep = keep || c.Name == o.Name && c.Image == o.Image
		}
		if !keep {
			removed = append(removed, o.Name)
		}
	}
	if env.empty() {
		b.dropEnvironment(name, false)
		b.envState.set(name, EnvStatus{State: "none"})
		for _, n := range removed {
			if b.Units != nil {
				b.Units.Remove(containerUnit(name, n))
			}
		}
	} else {
		b.envState.set(name, EnvStatus{State: "building"})
		go b.applyEnvironment(origin(r), name, removed)
	}
	b.publish(r, "environment.changed", map[string]any{"location": name})
	v, err := b.environmentView(r.Context(), name)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, v)
	return nil
}
