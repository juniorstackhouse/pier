package box

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// The terminal stream (POST /v1/sessions/{name}/tty): the app's terminal is
// a tmux client of the session, as a terminal on the box attached to it
// would be. What it shows is tmux's own drawing of the pane at the app's
// size, colors and cursor included, and what is typed in it (Ctrl-C, the
// arrows, Tab, a paste) reaches the program as it would from a keyboard on
// the box. The session's scrollback comes first, so the app can scroll
// back past what it saw.

const (
	// ttyTerm is the terminal the app's emulator answers as.
	ttyTerm = "xterm-256color"
	// ttyMax bounds the terminals open on the box at once.
	ttyMax = 16
	// ttyHistory is how much scrollback a terminal starts with, unless it
	// asks (?history=, at most ttyHistoryMax).
	ttyHistory    = 2000
	ttyHistoryMax = 10000
	// ttyFrameMax bounds one line of the request: a paste of 2 MB, in base64.
	ttyFrameMax = 3 << 20
)

var ttyOpen atomic.Int32

// ttyFrame is one line of the request's body: bytes typed, the terminal's
// new size, or both.
type ttyFrame struct {
	Data []byte `json:"data,omitempty"`
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
}

// sessionTTY answers POST /v1/sessions/{name}/tty?cols=C&rows=R[&history=N]:
// a terminal on the session, both ways over one request (HTTP/2, or
// HTTP/1.1 in full duplex). The body carries one JSON object per line,
// {"data":"<base64>"} for what is typed and {"cols":C,"rows":R} when the
// terminal changes size; the answer is the terminal's output as raw bytes,
// until the session ends or the client leaves.
func (b *Box) sessionTTY(w http.ResponseWriter, r *http.Request) error {
	// HTTP/1.1 clients (the local socket) read the answer while they still
	// send, an error too: without full duplex net/http would first wait
	// for the end of a body that only ends with the terminal. HTTP/2 does
	// both ways already, and says so with an error here.
	rc := http.NewResponseController(w)
	_ = rc.EnableFullDuplex()
	if !ptySupported {
		return httpError{http.StatusNotImplemented, "this box cannot open a terminal stream"}
	}
	q := r.URL.Query()
	cols, rows, err := ttySize(q.Get("cols"), q.Get("rows"))
	if err != nil {
		return err
	}
	history := ttyHistory
	if v := q.Get("history"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return badRequest("history must be a number of lines")
		}
		history = min(n, ttyHistoryMax)
	}
	name := r.PathValue("name")
	if _, err := b.Sessions.Get(r.Context(), name); err != nil {
		return err
	}
	// Typing into a terminal is sending to the session: a gate on sends
	// holds terminals too.
	if err := b.before(r, "session.send", map[string]any{"name": name, "terminal": true}); err != nil {
		return err
	}
	if ttyOpen.Add(1) > ttyMax {
		ttyOpen.Add(-1)
		return httpError{http.StatusTooManyRequests, fmt.Sprintf("%d terminals are open on this box already: close one first", ttyMax)}
	}
	defer ttyOpen.Add(-1)

	// The scrollback is read before the client attaches: attaching gives
	// the window the app's size, and the shell redraws its prompt for it.
	prelude := b.Sessions.ttyPrelude(r.Context(), name, history, rows)
	c, err := b.Sessions.Attach(r.Context(), name, cols, rows)
	if err != nil {
		return err
	}
	defer c.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	if len(prelude) > 0 {
		w.Write(prelude)
	}
	if rc.Flush() != nil {
		return nil
	}

	// What is typed goes to the client as it arrives; the body ending (or
	// failing) is the app closing the terminal.
	go func() {
		defer c.Close()
		readTTYFrames(r.Body, func(f ttyFrame) error {
			if f.Cols != 0 || f.Rows != 0 {
				if cols, rows, err := ttySize(strconv.Itoa(f.Cols), strconv.Itoa(f.Rows)); err == nil {
					c.Resize(cols, rows)
				}
			}
			if len(f.Data) > 0 {
				if _, err := c.Write(f.Data); err != nil {
					return err
				}
			}
			return nil
		})
	}()
	stop := context.AfterFunc(r.Context(), c.Close)
	defer stop()

	buf := make([]byte, 32<<10)
	for {
		n, err := c.Read(buf)
		if n > 0 {
			if _, err := w.Write(buf[:n]); err != nil {
				return nil
			}
			if rc.Flush() != nil {
				return nil
			}
		}
		if err != nil {
			return nil
		}
	}
}

// ttySize reads a terminal's size; nothing given is 80×24.
func ttySize(c, r string) (cols, rows int, err error) {
	cols, rows = 80, 24
	if c != "" {
		if cols, err = strconv.Atoi(c); err != nil || cols < 2 || cols > 1000 {
			return 0, 0, badRequest("cols must be 2 to 1000")
		}
	}
	if r != "" {
		if rows, err = strconv.Atoi(r); err != nil || rows < 2 || rows > 500 {
			return 0, 0, badRequest("rows must be 2 to 500")
		}
	}
	return cols, rows, nil
}

// readTTYFrames hands each line of body to handle, until the body ends
// (io.EOF), a line is not a frame, or handle fails.
func readTTYFrames(body io.Reader, handle func(ttyFrame) error) error {
	br := bufio.NewReaderSize(body, 64<<10)
	for {
		line, err := readLimitedLine(br, ttyFrameMax)
		if len(bytes.TrimSpace(line)) > 0 {
			var f ttyFrame
			if jerr := json.Unmarshal(line, &f); jerr != nil {
				return jerr
			}
			if herr := handle(f); herr != nil {
				return herr
			}
		}
		if err != nil {
			return err
		}
	}
}

// readLimitedLine reads up to and including the next '\n', refusing a line
// longer than limit.
func readLimitedLine(br *bufio.Reader, limit int) ([]byte, error) {
	var line []byte
	for {
		chunk, err := br.ReadSlice('\n')
		if len(line)+len(chunk) > limit {
			return nil, errors.New("terminal frame too long")
		}
		line = append(line, chunk...)
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return line, err
	}
}

// ttyPrelude is what a terminal starts with: up to lines of the session's
// scrollback (with its colors), pushed up into the terminal's own
// scrollback by a screenful of new lines, so tmux then draws the screen on
// an empty one and scrolling back shows what came before.
func (s *Sessions) ttyPrelude(ctx context.Context, name string, lines, rows int) []byte {
	if lines <= 0 {
		return nil
	}
	target := "=" + name + ":"
	out, err := s.tmux(ctx, "display-message", "-p", "-t", target, "#{history_size}")
	if err != nil {
		return nil
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	if n = min(n, lines); n <= 0 {
		return nil
	}
	out, err = s.tmux(ctx, "capture-pane", "-p", "-e", "-J", "-t", target, "-S", "-"+strconv.Itoa(n), "-E", "-1")
	if err != nil {
		return nil
	}
	text := strings.TrimRight(string(out), "\n")
	if text == "" {
		return nil
	}
	var b bytes.Buffer
	for _, line := range strings.Split(text, "\n") {
		b.WriteString(line)
		b.WriteString("\x1b[0m\r\n")
	}
	b.WriteString(strings.Repeat("\n", rows))
	b.WriteString("\x1b[H")
	return b.Bytes()
}

// ttyClient is a tmux client attached to a session on a pseudo-terminal of
// its own.
type ttyClient struct {
	ctl  *os.File
	cmd  *exec.Cmd
	done chan struct{}
	once sync.Once
}

// Attach attaches a tmux client to session name on a new pseudo-terminal of
// cols×rows. The session first gets what a terminal of the app needs: no
// prefix key (Ctrl-B is the shell's, not tmux's) and no mouse of tmux's own
// (the app selects and scrolls by itself; a program that asks for the mouse
// still gets it).
func (s *Sessions) Attach(ctx context.Context, name string, cols, rows int) (*ttyClient, error) {
	bin, err := tmuxPath()
	if err != nil {
		return nil, err
	}
	// The server's side of it, for this terminal: no alternate screen (tmux
	// draws on the main one, so what scrolls off the top lands in the app's
	// scrollback), 24-bit color, and Esc passed on at once. Options an older
	// tmux lacks are left out.
	s.tmux(ctx, "set-option", "-s", "escape-time", "10", ";",
		"set-option", "-s", "terminal-overrides[90]", ttyTerm+":smcup@:rmcup@")
	s.tmux(ctx, "set-option", "-s", "terminal-features[90]", ttyTerm+":RGB")
	target := "=" + name + ":"
	if out, err := s.tmux(ctx, "set-option", "-t", target, "prefix", "None", ";",
		"set-option", "-t", target, "prefix2", "None", ";",
		"set-option", "-t", target, "mouse", "off"); err != nil {
		return nil, tmuxError("set-option", out, err)
	}
	ctl, term, err := openPTY()
	if err != nil {
		return nil, fmt.Errorf("open a terminal: %w", err)
	}
	if err := setPTYSize(ctl, cols, rows); err != nil {
		ctl.Close()
		term.Close()
		return nil, fmt.Errorf("size a terminal: %w", err)
	}
	cmd := exec.Command(bin, "-u", "-L", tmuxSocket(), "-f", s.Config, "attach-session", "-t", "="+name)
	cmd.Env = ttyEnv(os.Environ())
	cmd.Stdin, cmd.Stdout, cmd.Stderr = term, term, term
	// The client's own session, on the terminal as its controlling one, so
	// a new size reaches it (SIGWINCH) and closing the terminal hangs it up.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true}
	if s.trace != nil {
		s.trace(cmd.Args[1:])
	}
	if err := cmd.Start(); err != nil {
		ctl.Close()
		term.Close()
		return nil, fmt.Errorf("tmux attach-session: %w", err)
	}
	term.Close()
	c := &ttyClient{ctl: ctl, cmd: cmd, done: make(chan struct{})}
	go func() {
		cmd.Wait()
		close(c.done)
	}()
	return c, nil
}

// ttyEnv is pierd's environment for a tmux client the app's terminal runs:
// the terminal it answers as, with 24-bit color, and not inside a tmux.
func ttyEnv(env []string) []string {
	out := make([]string, 0, len(env)+2)
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "TERM", "COLORTERM", "TMUX", "TMUX_PANE":
			continue
		}
		out = append(out, kv)
	}
	return append(out, "TERM="+ttyTerm, "COLORTERM=truecolor")
}

// Read reads the terminal's output; io.EOF once the client has left (tmux
// detached it, the session ended).
func (c *ttyClient) Read(p []byte) (int, error) {
	n, err := c.ctl.Read(p)
	if err != nil && (errors.Is(err, syscall.EIO) || errors.Is(err, os.ErrClosed)) {
		// Linux says EIO once no one holds the terminal any more.
		err = io.EOF
	}
	return n, err
}

// Write types p into the terminal.
func (c *ttyClient) Write(p []byte) (int, error) { return c.ctl.Write(p) }

// Resize gives the terminal a new size; tmux draws the session at it.
func (c *ttyClient) Resize(cols, rows int) error { return setPTYSize(c.ctl, cols, rows) }

// Close detaches the client, as a dropped ssh connection would (SIGHUP),
// and closes the terminal. Safe to call more than once and from any
// goroutine.
func (c *ttyClient) Close() {
	c.once.Do(func() {
		if c.cmd.Process != nil {
			c.cmd.Process.Signal(syscall.SIGHUP)
		}
		select {
		case <-c.done:
		case <-time.After(2 * time.Second):
			c.cmd.Process.Kill()
			<-c.done
		}
		c.ctl.Close()
	})
}
