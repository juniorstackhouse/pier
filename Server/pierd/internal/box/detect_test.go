package box

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDetectSetup(t *testing.T) {
	cases := []struct {
		name     string
		files    map[string]string
		setup    string
		services []WorktreeService
	}{
		{"empty", nil, "", nil},
		{"vite with pnpm", map[string]string{
			"package.json":   `{"scripts":{"dev":"vite","build":"vite build"}}`,
			"pnpm-lock.yaml": "",
			".env.example":   "A=1",
		}, "cp -n .env.example .env && pnpm install --frozen-lockfile",
			[]WorktreeService{{Name: "dev", Run: "HOST=0.0.0.0 pnpm run dev --host 0.0.0.0 --port $PIER_PORT", Autostart: true}}},
		{"next with npm", map[string]string{
			"package.json":      `{"scripts":{"dev":"next dev"}}`,
			"package-lock.json": "{}",
		}, "npm ci", []WorktreeService{{Name: "dev", Run: "HOST=0.0.0.0 npm run dev", Autostart: true}}},
		{"vite with npm passes flags after --", map[string]string{
			"package.json": `{"scripts":{"start":"vite"}}`,
		}, "npm install", []WorktreeService{{Name: "dev", Run: "HOST=0.0.0.0 npm run start -- --host 0.0.0.0 --port $PIER_PORT", Autostart: true}}},
		{"existing .env is kept", map[string]string{
			".env.example": "A=1", ".env": "A=2", "go.mod": "module x",
		}, "go mod download", nil},
		{"django", map[string]string{
			"requirements.txt": "django", "manage.py": "",
		}, "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt",
			[]WorktreeService{{Name: "web", Run: ".venv/bin/python manage.py runserver 0.0.0.0:$PIER_PORT", Autostart: true}}},
		{"rails", map[string]string{"Gemfile": "", "bin/rails": ""}, "bundle install",
			[]WorktreeService{{Name: "web", Run: "bin/rails server -b 0.0.0.0 -p $PIER_PORT", Autostart: true}}},
		{"node library without scripts", map[string]string{"package.json": `{"name":"x"}`, "yarn.lock": ""}, "yarn install", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, body := range c.files {
				os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755)
				os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644)
			}
			got := detectSetup(dir)
			if got.Setup != c.setup {
				t.Errorf("setup = %q, want %q", got.Setup, c.setup)
			}
			if len(got.Services) != len(c.services) {
				t.Fatalf("services = %+v, want %+v", got.Services, c.services)
			}
			for i := range c.services {
				if got.Services[i] != c.services[i] {
					t.Errorf("service %d = %+v, want %+v", i, got.Services[i], c.services[i])
				}
			}
			if err := got.validate(); err != nil {
				t.Errorf("detected config does not validate: %v", err)
			}
		})
	}
}
