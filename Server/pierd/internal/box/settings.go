package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"pier/pierd/internal/statefile"
	"pier/pierd/internal/trust"
)

// The box's projects folder: once set, every project lives under it, the
// way a root holds everything pierd does. Clones go there, a location
// outside it cannot be added, and nothing outside it is ever deleted.
// Folders right under it that are not repositories are spaces: groups of
// projects kept apart on the disk (root/<space>/<repo>), each with its
// worktrees beside its repository, inside the space.

// Settings are the box's own settings (GET/PUT /v1/settings).
type Settings struct {
	// ProjectsRoot is the folder every project lives under; empty: anywhere.
	ProjectsRoot string `json:"projects_root,omitempty"`
}

// SettingsView is what GET /v1/settings answers.
type SettingsView struct {
	Settings
	Home   string      `json:"home"`
	Spaces []Space     `json:"spaces"`
	Docker DockerState `json:"docker"`
}

// Space is a folder of projects under the projects folder.
type Space struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	Projects int    `json:"projects"`
}

var ErrSpaceNotEmpty = errors.New("the space still holds projects")

func (l *Locations) settingsPath() string {
	return filepath.Join(filepath.Dir(l.path), "settings.json")
}

// Settings reads the box's settings; none saved yet reads as the defaults.
func (l *Locations) Settings() Settings {
	var s Settings
	if b, err := os.ReadFile(l.settingsPath()); err == nil {
		json.Unmarshal(b, &s)
	}
	return s
}

// SetProjectsRoot sets (or with "" clears) the projects folder, creating it.
func (l *Locations) SetProjectsRoot(root string) (Settings, error) {
	s := l.Settings()
	if strings.TrimSpace(root) == "" {
		s.ProjectsRoot = ""
	} else {
		abs, err := filepath.Abs(expandHome(strings.TrimSpace(root)))
		if err != nil {
			return s, err
		}
		abs = filepath.Clean(abs)
		if abs == "/" {
			return s, badRequest("the projects folder cannot be /")
		}
		if fi, err := os.Stat(abs); err == nil && !fi.IsDir() {
			return s, badRequest("%s is a file, not a folder", abs)
		}
		if err := os.MkdirAll(abs, 0o755); err != nil {
			return s, err
		}
		if resolved, err := filepath.EvalSymlinks(abs); err == nil {
			abs = resolved
		}
		s.ProjectsRoot = abs
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	return s, statefile.Write(l.settingsPath(), append(b, '\n'))
}

// under reports whether path is root or inside it.
func under(path, root string) bool {
	path, root = filepath.Clean(path), filepath.Clean(root)
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

// placeOf says where a project at path sits against the projects folder:
// its space ("" right under the folder) and whether it is outside it.
func placeOf(path, root string) (space string, outside bool) {
	if root == "" {
		return "", false
	}
	if !under(path, root) {
		return "", true
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return "", true
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) >= 2 {
		return parts[0], false
	}
	return "", false
}

// withPlace sets loc's space against the projects folder.
func (l *Locations) withPlace(loc Location, root string) Location {
	loc.Space, loc.OutsideRoot = placeOf(loc.Path, root)
	return loc
}

// checkInRoot refuses a path outside the projects folder, when one is set.
func (l *Locations) checkInRoot(path string) error {
	root := l.Settings().ProjectsRoot
	if root == "" {
		return nil
	}
	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		return err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	if !under(abs, root) {
		return httpError{http.StatusForbidden, fmt.Sprintf("%s is outside the box's projects folder (%s)", abs, root)}
	}
	return nil
}

// Spaces lists the folders right under the projects folder that are not
// repositories (nor worktrees) themselves, with how many projects each holds.
func (l *Locations) Spaces(ctx context.Context) []Space {
	root := l.Settings().ProjectsRoot
	out := []Space{}
	if root == "" {
		return out
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return out
	}
	locs, _ := l.List(ctx)
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		p := filepath.Join(root, e.Name())
		if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
			continue
		}
		s := Space{Name: e.Name(), Path: p}
		for _, loc := range locs {
			if loc.Space == e.Name() {
				s.Projects++
			}
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// spaceDir is the folder of a space, made if it is not there yet.
func (l *Locations) spaceDir(name string, create bool) (string, error) {
	root := l.Settings().ProjectsRoot
	if root == "" {
		return "", badRequest("set the box's projects folder before using spaces")
	}
	if name == "" {
		return root, nil
	}
	if !trust.ValidName(name) {
		return "", badRequest("invalid space name %q", name)
	}
	p := filepath.Join(root, name)
	if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
		return "", badRequest("%s is a project, not a space", name)
	}
	if create {
		if err := os.MkdirAll(p, 0o755); err != nil {
			return "", err
		}
	} else if fi, err := os.Stat(p); err != nil || !fi.IsDir() {
		return "", httpError{http.StatusNotFound, "no space called " + name}
	}
	return p, nil
}

func (b *Box) settingsView(ctx context.Context) SettingsView {
	v := SettingsView{Settings: b.Locations.Settings(), Spaces: b.Locations.Spaces(ctx), Docker: dockerState(ctx)}
	v.Home, _ = os.UserHomeDir()
	return v
}

func (b *Box) getSettings(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.settingsView(r.Context()))
	return nil
}

func (b *Box) putSettings(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		ProjectsRoot *string `json:"projects_root"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.ProjectsRoot != nil {
		if err := b.before(r, "settings.change", map[string]any{"projects_root": *req.ProjectsRoot}); err != nil {
			return err
		}
		s, err := b.Locations.SetProjectsRoot(*req.ProjectsRoot)
		if err != nil {
			return err
		}
		b.publish(r, "settings.changed", map[string]any{"projects_root": s.ProjectsRoot})
	}
	writeJSON(w, b.settingsView(r.Context()))
	return nil
}

func (b *Box) addSpace(w http.ResponseWriter, r *http.Request) error {
	var req struct{ Name string }
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.Name == "" {
		return badRequest("a space needs a name")
	}
	p, err := b.Locations.spaceDir(req.Name, true)
	if err != nil {
		return err
	}
	b.publish(r, "space.added", map[string]any{"space": req.Name, "path": p})
	writeJSON(w, Space{Name: req.Name, Path: p})
	return nil
}

// removeSpace deletes a space: empty, or with ?purge=1 its projects are
// removed from the disk with it (each checked for unsaved work unless
// force=1). Its projects never move out of it.
func (b *Box) removeSpace(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	name := r.PathValue("name")
	if name == "" {
		return badRequest("which space?")
	}
	dir, err := b.Locations.spaceDir(name, false)
	if err != nil {
		return err
	}
	purge, force := r.URL.Query().Get("purge") == "1", r.URL.Query().Get("force") == "1"
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return err
	}
	var inside []Location
	for _, l := range locs {
		if under(l.Path, dir) {
			inside = append(inside, l)
		}
	}
	if len(inside) > 0 && !purge {
		names := make([]string, len(inside))
		for i, l := range inside {
			names[i] = l.Name
		}
		return fmt.Errorf("%w: %s (remove them with it with purge=1)", ErrSpaceNotEmpty, strings.Join(names, ", "))
	}
	// Every project is checked before any is touched: all go, or none.
	disks := make([]DiskUse, len(inside))
	for i, l := range inside {
		disks[i] = b.diskUse(ctx, l)
		if !disks[i].Removable {
			return httpError{http.StatusConflict, l.Name + ": " + disks[i].Reason}
		}
		if disks[i].Unsaved() && !force {
			return fmt.Errorf("%w: %s: %s", ErrUnsavedWork, l.Name, unsavedSummary(disks[i]))
		}
	}
	if err := b.before(r, "space.remove", map[string]any{"space": name, "path": dir, "projects": len(inside)}); err != nil {
		return err
	}
	var freed int64
	for i, l := range inside {
		if err := b.purge(r, l, disks[i]); err != nil {
			return err
		}
		freed += disks[i].Bytes
	}
	// What is left is not any project's: it goes only when asked to.
	if err := os.Remove(dir); err != nil {
		if !force {
			return httpError{http.StatusConflict, fmt.Sprintf("%s holds files that are not projects; remove it with force=1 to delete them too", dir)}
		}
		freed += dirSize(ctx, dir)
		if err := os.RemoveAll(dir); err != nil {
			return err
		}
	}
	b.publish(r, "space.removed", map[string]any{"space": name, "path": dir, "freed": freed})
	writeJSON(w, map[string]any{"removed": name, "freed": freed})
	return nil
}
