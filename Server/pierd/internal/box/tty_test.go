package box

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/wire"
)

// ttyOutput collects what a terminal client prints, for a test to wait on.
type ttyOutput struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (o *ttyOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.String()
}

func readAll(c *ttyClient, out *ttyOutput) {
	buf := make([]byte, 4096)
	for {
		n, err := c.Read(buf)
		out.mu.Lock()
		out.buf.Write(buf[:n])
		out.mu.Unlock()
		if err != nil {
			return
		}
	}
}

// A terminal attached to a session shows its program, takes what is typed
// (Ctrl-C included) and a new size, and ends when the session does.
func TestTerminalTypesAndInterrupts(t *testing.T) {
	s := testSessions(t)
	ctx := context.Background()
	if _, err := s.Create(ctx, "shell-1", "", t.TempDir(), "", nil); err != nil {
		t.Fatal(err)
	}
	c, err := s.Attach(ctx, "shell-1", 100, 30)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	out := &ttyOutput{}
	go readAll(c, out)

	// The client is up when tmux lists it, at the terminal's size.
	waitUntil(t, "the client to attach", 5*time.Second, func() bool {
		o, _ := s.tmux(ctx, "list-clients", "-t", "=shell-1", "-F", "#{client_width}x#{client_height}")
		return strings.TrimSpace(string(o)) == "100x30"
	})
	// tmux draws on the main screen (the app keeps a scrollback) in 24-bit color.
	o, _ := s.tmux(ctx, "list-clients", "-t", "=shell-1", "-F", "#{client_termfeatures}")
	if !strings.Contains(string(o), "RGB") {
		t.Errorf("client features = %q, want RGB", o)
	}
	c.Write([]byte("echo typed-$((40+2))\r"))
	waitUntil(t, "the line's output", 5*time.Second, func() bool { return strings.Contains(out.String(), "typed-42") })
	if strings.Contains(out.String(), "\x1b[?1049h") {
		t.Error("tmux switched the app's terminal to its alternate screen")
	}

	// Ctrl-C stops what runs: the shell answers the next line.
	c.Write([]byte("sleep 30\r"))
	time.Sleep(300 * time.Millisecond)
	c.Write([]byte{0x03})
	c.Write([]byte("echo after-$((1+1))\r"))
	waitUntil(t, "the shell after Ctrl-C", 5*time.Second, func() bool { return strings.Contains(out.String(), "after-2") })

	// Ctrl-B is the shell's: no prefix key catches it (bash and sh show nothing for it; the line still runs).
	c.Write([]byte{0x02})
	c.Write([]byte("echo prefix-free\r"))
	waitUntil(t, "a line after Ctrl-B", 5*time.Second, func() bool { return strings.Contains(out.String(), "prefix-free") })

	if err := c.Resize(60, 20); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the new size", 5*time.Second, func() bool {
		o, _ := s.tmux(ctx, "display-message", "-p", "-t", "=shell-1:", "#{window_width}x#{window_height}")
		return strings.TrimSpace(string(o)) == "60x20"
	})

	// The session ending ends the stream.
	if err := s.Kill(ctx, "shell-1"); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 1024)
		for {
			if _, err := c.Read(buf); err != nil {
				close(done)
				return
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the stream did not end with the session")
	}
}

// The scrollback comes first, pushed up out of the screen tmux draws next.
func TestTerminalStartsWithTheScrollback(t *testing.T) {
	s := testSessions(t)
	ctx := context.Background()
	if _, err := s.Create(ctx, "logs", "", t.TempDir(), "i=1; while [ $i -le 120 ]; do echo line-$i; i=$((i+1)); done; sleep 30", nil); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the output", 5*time.Second, func() bool {
		text, _ := s.Screen(ctx, "logs", 0)
		return strings.Contains(text, "line-120")
	})
	p := string(s.ttyPrelude(ctx, "logs", 2000, 24))
	if !strings.Contains(p, "line-1\x1b[0m\r\n") || strings.Contains(p, "line-120") {
		t.Fatalf("prelude = %q", p)
	}
	if !strings.HasSuffix(p, strings.Repeat("\n", 24)+"\x1b[H") {
		t.Fatalf("prelude does not push the scrollback up: %q", p[max(0, len(p)-60):])
	}
	if got := s.ttyPrelude(ctx, "logs", 0, 24); got != nil {
		t.Fatalf("history=0 prelude = %q", got)
	}
}

func TestTTYFrames(t *testing.T) {
	body := strings.NewReader("{\"data\":\"ZWNobyBoaQ0=\"}\n\n{\"cols\":120,\"rows\":40}\n{\"data\":\"Aw==\",\"cols\":90,\"rows\":30}")
	var got []ttyFrame
	err := readTTYFrames(body, func(f ttyFrame) error { got = append(got, f); return nil })
	if err != io.EOF {
		t.Fatalf("err = %v", err)
	}
	if len(got) != 3 || string(got[0].Data) != "echo hi\r" || got[1].Cols != 120 || got[1].Rows != 40 || got[2].Data[0] != 3 || got[2].Cols != 90 {
		t.Fatalf("frames = %+v", got)
	}
	if err := readTTYFrames(strings.NewReader("not json\n"), func(ttyFrame) error { return nil }); err == nil {
		t.Fatal("a line that is not a frame was taken")
	}
	long := strings.NewReader("{\"data\":\"" + strings.Repeat("A", ttyFrameMax) + "\"}\n")
	if err := readTTYFrames(long, func(ttyFrame) error { return nil }); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("an over-long frame: %v", err)
	}
}

func TestTTYSize(t *testing.T) {
	if c, r, err := ttySize("", ""); err != nil || c != 80 || r != 24 {
		t.Fatalf("default = %d×%d, %v", c, r, err)
	}
	if c, r, err := ttySize("132", "43"); err != nil || c != 132 || r != 43 {
		t.Fatalf("132×43 = %d×%d, %v", c, r, err)
	}
	for _, bad := range [][2]string{{"1", "24"}, {"80", "0"}, {"x", "24"}, {"80", "501"}, {"1001", "24"}} {
		if _, _, err := ttySize(bad[0], bad[1]); err == nil {
			t.Errorf("size %v taken", bad)
		}
	}
}

func TestTTYEnv(t *testing.T) {
	env := ttyEnv([]string{"PATH=/bin", "TERM=dumb", "TMUX=/tmp/x,1,0", "COLORTERM=", "HOME=/h"})
	got := strings.Join(env, " ")
	if got != "PATH=/bin HOME=/h TERM=xterm-256color COLORTERM=truecolor" {
		t.Fatalf("env = %s", got)
	}
}

// Over the local socket (HTTP/1.1) a refusal answers at once, while the
// client's body is still open: that body only ends with the terminal, so
// the answer must not wait for it.
func TestTTYRefusalAnswersWhileTheBodyIsOpen(t *testing.T) {
	if !ptySupported {
		t.Skip("no pseudo-terminals here")
	}
	srv := &wire.Server{}
	bx := &Box{Name: "devbox", Locations: NewLocations(filepath.Join(t.TempDir(), "locations.json")), Sessions: testSessions(t), Events: &events.Bus{}}
	bx.Mount(srv)
	ts := httptest.NewServer(srv.LocalHandler())
	defer ts.Close()

	body, typing := io.Pipe()
	defer typing.Close()
	req, err := http.NewRequest("POST", ts.URL+"/v1/sessions/nope/tty?cols=80&rows=24", body)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/x-ndjson")
	status := make(chan int, 1)
	go func() {
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			status <- -1
			return
		}
		resp.Body.Close()
		status <- resp.StatusCode
	}()
	typing.Write([]byte(`{"cols":100,"rows":30}` + "\n"))
	select {
	case got := <-status:
		if got != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the refusal waited for the body to end")
	}
}
