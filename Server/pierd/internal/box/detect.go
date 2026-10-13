package box

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// A repository cloned from the app should be ready to work in: its
// dependencies installed and its dev server running on the worktree's own
// port. When the repository describes that itself (.pier/config.json) its
// config is used; otherwise detectSetup works it out from the files a
// project of each kind has, and the result becomes the box's own config for
// the location, which the person can change like any other.

// detectSetup is the setup script and services a checkout at dir looks like
// it needs, empty when nothing is recognised.
func detectSetup(dir string) RepoConfig {
	has := func(name string) bool {
		_, err := os.Stat(filepath.Join(dir, name))
		return err == nil
	}
	var steps []string
	var services []WorktreeService
	addService := func(name, run string) {
		if len(services) == 0 {
			services = append(services, WorktreeService{Name: name, Run: run, Autostart: true})
		}
	}

	// The environment file most projects ship an example of.
	for _, example := range []string{".env.example", ".env.sample", ".env.dist"} {
		if has(example) && !has(".env") {
			steps = append(steps, "cp -n "+example+" .env")
			break
		}
	}

	if has("package.json") {
		pm, install := "npm", "npm install"
		switch {
		case has("pnpm-lock.yaml"):
			pm, install = "pnpm", "pnpm install --frozen-lockfile"
		case has("yarn.lock"):
			pm, install = "yarn", "yarn install"
		case has("bun.lockb") || has("bun.lock"):
			pm, install = "bun", "bun install"
		case has("package-lock.json"):
			install = "npm ci"
		}
		steps = append(steps, install)
		if run := nodeDevCommand(filepath.Join(dir, "package.json"), pm); run != "" {
			addService("dev", run)
		}
	}

	python := ""
	switch {
	case has("uv.lock"):
		steps = append(steps, "uv sync")
		python = "uv run python"
	case has("poetry.lock"):
		steps = append(steps, "poetry install")
		python = "poetry run python"
	case has("requirements.txt"):
		steps = append(steps, "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt")
		python = ".venv/bin/python"
	}
	if python != "" && has("manage.py") {
		addService("web", python+" manage.py runserver 0.0.0.0:$PIER_PORT")
	}

	if has("Gemfile") {
		steps = append(steps, "bundle install")
		if has("bin/rails") {
			addService("web", "bin/rails server -b 0.0.0.0 -p $PIER_PORT")
		}
	}
	if has("composer.json") {
		steps = append(steps, "composer install")
		if has("artisan") {
			addService("web", "php artisan serve --host=0.0.0.0 --port=$PIER_PORT")
		}
	}
	if has("go.mod") {
		steps = append(steps, "go mod download")
	}
	if has("Cargo.toml") {
		steps = append(steps, "cargo fetch")
	}
	return RepoConfig{Setup: strings.Join(steps, " && "), Services: services}
}

// nodeDevCommand runs the package's dev script (or its start script) so it
// answers on the worktree's port from other devices: PORT is already the
// worktree's, HOST opens it beyond localhost, and Vite and Astro, which read
// neither, get flags.
func nodeDevCommand(packageJSON, pm string) string {
	b, err := os.ReadFile(packageJSON)
	if err != nil {
		return ""
	}
	var pkg struct {
		Scripts map[string]string `json:"scripts"`
	}
	if json.Unmarshal(b, &pkg) != nil {
		return ""
	}
	script := ""
	for _, s := range []string{"dev", "start"} {
		if pkg.Scripts[s] != "" {
			script = s
			break
		}
	}
	if script == "" {
		return ""
	}
	run := pm + " run " + script
	if body := pkg.Scripts[script]; strings.Contains(body, "vite") || strings.Contains(body, "astro dev") {
		flags := " --host 0.0.0.0 --port $PIER_PORT"
		if pm == "npm" {
			flags = " --" + flags
		}
		run += flags
	}
	return "HOST=0.0.0.0 " + run
}
