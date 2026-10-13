package relay

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/identity"
)

// Public links: a box can publish one of its dev servers at
// https://p-<name>.<ShareDomain>, served by the relay to anyone with the
// link. The box chooses what to publish and for how long; the relay only
// learns a name, and asks the box for a connection per request, which the
// box joins to the port it keeps for that name (the relay never names a
// port). Nothing is published unless the box asks, and the relay forgets a
// box's links when its control connection drops; the box publishes them
// again when it is back.
//
// On the control connection, after OK (PROTOCOL.md §10):
//
//	box → relay   PUBLISH <name>       relay → box   PUBLISHED <name> <url>, or ERR <name> <why>
//	box → relay   UNPUBLISH <name>
//	relay → box   SHARE <id> <name>    the box dials ACCEPT <id> and joins it to the name's port
//
// A relay without a share domain answers ERR; an older relay ignores the
// lines, and an older box ignores SHARE.

// SharePrefix starts every public link's host, so a share domain can be the
// relay's own domain without its names taking any other host's.
const SharePrefix = "p-"

var shareName = regexp.MustCompile(`^[a-z0-9]{16,40}$`)

// maxSharesPerBox bounds the links one box holds on a relay.
const maxSharesPerBox = 32

// ShareHost is the host a name is published at.
func ShareHost(name, domain string) string { return SharePrefix + name + "." + domain }

// shareOf reads a share name from a request's host, or "".
func (s *Server) shareOf(host string) string {
	if s.ShareDomain == "" {
		return ""
	}
	h := strings.ToLower(host)
	if i := strings.LastIndex(h, ":"); i > strings.LastIndex(h, "]") {
		h = h[:i]
	}
	label, ok := strings.CutSuffix(h, "."+strings.ToLower(s.ShareDomain))
	if !ok {
		return ""
	}
	name, ok := strings.CutPrefix(label, SharePrefix)
	if !ok || !shareName.MatchString(name) {
		return ""
	}
	return name
}

// controlLine handles a line a registered box sends on its control
// connection: PUBLISH and UNPUBLISH (anything else is ignored).
func (s *Server) controlLine(fp identity.Fingerprint, box *control, line string) {
	f := strings.Fields(line)
	if len(f) != 2 {
		return
	}
	name := f[1]
	switch f[0] {
	case "PUBLISH":
		if s.ShareDomain == "" {
			box.send("ERR " + name + " shares this relay serves no public links")
			return
		}
		if !shareName.MatchString(name) {
			box.send("ERR " + name + " request")
			return
		}
		s.mu.Lock()
		if s.shares == nil {
			s.shares = map[string]identity.Fingerprint{}
		}
		owner, taken := s.shares[name]
		n := 0
		for _, o := range s.shares {
			if o == fp {
				n++
			}
		}
		switch {
		case taken && owner != fp:
			s.mu.Unlock()
			box.send("ERR " + name + " taken")
			return
		case !taken && n >= maxSharesPerBox:
			s.mu.Unlock()
			box.send("ERR " + name + " busy too many links")
			return
		}
		s.shares[name] = fp
		s.mu.Unlock()
		box.send("PUBLISHED " + name + " https://" + ShareHost(name, s.ShareDomain))
	case "UNPUBLISH":
		s.mu.Lock()
		if s.shares[name] == fp {
			delete(s.shares, name)
		}
		s.mu.Unlock()
	}
}

// forgetShares drops a box's links when it disconnects.
func (s *Server) forgetShares(fp identity.Fingerprint) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for name, o := range s.shares {
		if o == fp {
			delete(s.shares, name)
		}
	}
}

// dialShare asks the box holding name for a connection to it.
func (s *Server) dialShare(ctx context.Context, name string) (net.Conn, error) {
	s.mu.Lock()
	fp, ok := s.shares[name]
	box := s.boxes[fp]
	if !ok || box == nil {
		s.mu.Unlock()
		return nil, errShareOffline
	}
	if box.pending >= 32 || len(s.pending) >= s.maxPending() || s.MaxConnsPerBox > 0 && box.active+box.pending >= s.MaxConnsPerBox || s.overQuota(fp) {
		s.mu.Unlock()
		return nil, errors.New("busy")
	}
	id := newID()
	d := &pendingDial{box: box, joined: make(chan *bufferedConn, 1)}
	box.pending++
	s.pending[id] = d
	s.mu.Unlock()
	if err := box.send("SHARE " + id + " " + name); err != nil {
		s.take(id)
		return nil, errShareOffline
	}
	timer := time.NewTimer(acceptWithin)
	defer timer.Stop()
	select {
	case other := <-d.joined:
		s.mu.Lock()
		box.active++
		s.mu.Unlock()
		return &sharedConn{bufferedConn: other, done: func() {
			s.mu.Lock()
			box.active--
			s.mu.Unlock()
			s.untrack(other.Conn)
		}, count: func(n int) bool { return s.count(fp, n) }}, nil
	case <-timer.C:
		if s.take(id) != nil {
			return nil, errors.New("the box did not answer")
		}
		other := <-d.joined
		s.untrack(other.Conn)
		other.Close()
		return nil, errors.New("the box did not answer in time")
	case <-ctx.Done():
		s.take(id)
		return nil, ctx.Err()
	}
}

var errShareOffline = errors.New("offline")

// sharedConn is a box's side of a public request, metered like an app's.
type sharedConn struct {
	*bufferedConn
	once  sync.Once
	done  func()
	count func(int) bool
}

func (c *sharedConn) Read(p []byte) (int, error) {
	n, err := c.bufferedConn.Read(p)
	if n > 0 && !c.count(n) {
		return n, errors.New("today's traffic for this box is used up")
	}
	return n, err
}

func (c *sharedConn) Write(p []byte) (int, error) {
	if !c.count(len(p)) {
		return 0, errors.New("today's traffic for this box is used up")
	}
	return c.bufferedConn.Write(p)
}

func (c *sharedConn) Close() error {
	c.once.Do(c.done)
	return c.bufferedConn.Close()
}

// shareProxy forwards public requests to their boxes: one connection to the
// box per request (the page's server sees Host localhost, so dev servers that
// check the host answer), the public host in X-Forwarded-Host.
func (s *Server) shareProxy() *httputil.ReverseProxy {
	s.shareOnce.Do(func() {
		t := &http.Transport{
			DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
				name, _, _ := strings.Cut(addr, ".")
				return s.dialShare(ctx, name)
			},
			DisableKeepAlives:     true,
			ResponseHeaderTimeout: 2 * time.Minute,
		}
		s.proxy = &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				name := s.shareOf(pr.In.Host)
				pr.Out.URL = &url.URL{Scheme: "http", Host: name + ".share", Path: pr.In.URL.Path, RawPath: pr.In.URL.RawPath, RawQuery: pr.In.URL.RawQuery}
				pr.Out.Host = "localhost"
				pr.SetXForwarded()
				pr.Out.Header.Set("X-Forwarded-Host", pr.In.Host)
				pr.Out.Header.Set("X-Forwarded-Proto", "https")
			},
			Transport: t,
			ModifyResponse: func(r *http.Response) error {
				// One request per connection from the proxy in front: a
				// connection never carries another host's request after it.
				r.Header.Set("Connection", "close")
				return nil
			},
			ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
				msg := "This link's box is offline, or the link was taken down."
				if !errors.Is(err, errShareOffline) {
					msg = "The box did not serve this page: " + err.Error()
				}
				w.Header().Set("Content-Type", "text/plain; charset=utf-8")
				w.Header().Set("Connection", "close")
				w.WriteHeader(http.StatusBadGateway)
				io.WriteString(w, "Pier: "+msg+"\n")
			},
		}
	})
	return s.proxy
}

// serveShareConn serves one connection that brought a public request.
func (s *Server) serveShareConn(c net.Conn, r *bufio.Reader) {
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if s.shareOf(req.Host) == "" {
				w.Header().Set("Connection", "close")
				http.Error(w, "Pier: misdirected request", http.StatusMisdirectedRequest)
				return
			}
			s.shareProxy().ServeHTTP(w, req)
		}),
		ReadHeaderTimeout: setupWithin,
		ErrorLog:          s.Log,
	}
	ln := &oneConn{c: &bufferedConn{Conn: c, r: r}, done: make(chan struct{})}
	srv.Serve(ln)
	<-ln.done
}

// oneConn is a listener that hands out one connection and then waits for
// it to close.
type oneConn struct {
	c    net.Conn
	once sync.Once
	done chan struct{}
	used bool
}

func (l *oneConn) Accept() (net.Conn, error) {
	if l.used {
		<-l.done
		return nil, net.ErrClosed
	}
	l.used = true
	return &closeNotify{Conn: l.c, onClose: func() { l.once.Do(func() { close(l.done) }) }}, nil
}
func (l *oneConn) Close() error   { return nil }
func (l *oneConn) Addr() net.Addr { return l.c.LocalAddr() }

type closeNotify struct {
	net.Conn
	onClose func()
}

func (c *closeNotify) Close() error { c.onClose(); return c.Conn.Close() }

// requestHost reads the Host header of the HTTP request at the head of r
// without consuming it ("" when it is not one, or too long to tell).
func requestHost(r *bufio.Reader) string {
	head, err := r.Peek(1)
	for {
		// What has come so far, then wait for one more byte only if the
		// head is not complete yet.
		head, _ = r.Peek(r.Buffered())
		if i := bytes.Index(head, []byte("\r\n\r\n")); i >= 0 {
			for _, line := range bytes.Split(head[:i], []byte("\r\n"))[1:] {
				k, v, ok := bytes.Cut(line, []byte(":"))
				if ok && strings.EqualFold(string(bytes.TrimSpace(k)), "host") {
					return string(bytes.TrimSpace(v))
				}
			}
			return ""
		}
		if err != nil || r.Buffered() >= r.Size() {
			return ""
		}
		_, err = r.Peek(r.Buffered() + 1)
	}
}

// httpMethod says whether b starts like an HTTP request.
func httpMethod(b []byte) bool {
	for _, m := range []string{"GET ", "POST", "PUT ", "HEAD", "DELE", "PATC", "OPTI"} {
		if bytes.HasPrefix(b, []byte(m)) {
			return true
		}
	}
	return false
}

// --- the box's side ---

// ShareTarget is what a box's link serves: a port on the box.
type ShareTarget struct {
	Port int
}

// Publish publishes name on the relay, served from port on this box, and
// returns its public URL. It waits for the relay's answer.
func (l *Listener) Publish(ctx context.Context, name string, port int) (string, error) {
	if !shareName.MatchString(name) {
		return "", fmt.Errorf("invalid link name %q", name)
	}
	l.mu.Lock()
	if l.shares == nil {
		l.shares = map[string]int{}
	}
	l.shares[name] = port
	ctrl := l.ctrl
	l.mu.Unlock()
	if ctrl == nil {
		return "", errors.New("the box is not connected to its relay right now")
	}
	return l.ask(ctx, ctrl, name)
}

// ask sends PUBLISH for name and waits for the answer.
func (l *Listener) ask(ctx context.Context, ctrl net.Conn, name string) (string, error) {
	ch := make(chan string, 1)
	l.mu.Lock()
	if l.waiting == nil {
		l.waiting = map[string]chan string{}
	}
	l.waiting[name] = ch
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		delete(l.waiting, name)
		l.mu.Unlock()
	}()
	l.wmu.Lock()
	err := writeLine(ctrl, "PUBLISH %s", name)
	l.wmu.Unlock()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	select {
	case answer := <-ch:
		f := strings.Fields(answer)
		if f[0] == "PUBLISHED" && len(f) >= 3 {
			return f[2], nil
		}
		if len(f) >= 3 && f[2] == "shares" {
			return "", ErrNoShares
		}
		return "", fmt.Errorf("the relay refused the link: %s", strings.Join(f[2:], " "))
	case <-ctx.Done():
		// An older relay never answers.
		return "", ErrNoShares
	}
}

// ErrNoShares says the box's relay does not serve public links.
var ErrNoShares = errors.New("the box's relay does not serve public links")

// Unpublish takes name down.
func (l *Listener) Unpublish(name string) {
	l.mu.Lock()
	delete(l.shares, name)
	ctrl := l.ctrl
	l.mu.Unlock()
	if ctrl != nil {
		l.wmu.Lock()
		writeLine(ctrl, "UNPUBLISH %s", name)
		l.wmu.Unlock()
	}
}

// republish publishes the box's links again on a new control connection.
func (l *Listener) republish(ctrl net.Conn) {
	l.mu.Lock()
	names := make([]string, 0, len(l.shares))
	for n := range l.shares {
		names = append(names, n)
	}
	l.mu.Unlock()
	for _, n := range names {
		l.wmu.Lock()
		writeLine(ctrl, "PUBLISH %s", n)
		l.wmu.Unlock()
	}
}

// answer hands a PUBLISHED / ERR line to whoever waits for it.
func (l *Listener) answer(line string) {
	f := strings.Fields(line)
	if len(f) < 2 {
		return
	}
	l.mu.Lock()
	ch := l.waiting[f[1]]
	l.mu.Unlock()
	if ch != nil {
		select {
		case ch <- line:
		default:
		}
	}
}

// serveShare joins a public request's connection to the name's port.
func (l *Listener) serveShare(ctx context.Context, id, name string) {
	l.mu.Lock()
	port, ok := l.shares[name]
	l.mu.Unlock()
	if !ok {
		return
	}
	local, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return
	}
	c, err := dialRelay(ctx, l.Relay)
	if err != nil {
		local.Close()
		return
	}
	if err := writeLine(c, "%s ACCEPT %s", Version, id); err != nil {
		c.Close()
		local.Close()
		return
	}
	go func() {
		io.Copy(local, c)
		if tc, ok := local.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
	}()
	io.Copy(c, local)
	c.Close()
	local.Close()
}
