package relay

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/identity"
)

// Listener is a box's side of a relay: a net.Listener whose connections are
// the apps' that reached the box through it. Run keeps the control connection
// up (reconnecting with a backoff); pierd serves its usual TLS on Accept's
// connections.
type Listener struct {
	Relay    string // the relay, host:port
	Token    string
	Identity *identity.Identity
	Log      *log.Logger

	conns     chan net.Conn
	done      chan struct{}
	closeOnce sync.Once

	mu     sync.Mutex
	status Status

	// ctrl is the control connection while registered (wmu guards writes
	// on it); shares are the box's public links, name to port, and waiting
	// the PUBLISH answers someone waits for (shares.go).
	ctrl    net.Conn
	wmu     sync.Mutex
	shares  map[string]int
	waiting map[string]chan string
}

// Status is the control connection's state, for pierd doctor.
type Status struct {
	Connected bool
	Since     time.Time
	Err       string
}

func NewListener(addr, token string, id *identity.Identity, logger *log.Logger) *Listener {
	return &Listener{Relay: addr, Token: token, Identity: id, Log: logger, conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *Listener) logf(format string, args ...any) {
	if l.Log != nil {
		l.Log.Printf(format, args...)
	}
}

// Status says whether the box is registered with the relay now.
func (l *Listener) Status() Status {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.status
}

func (l *Listener) setStatus(st Status) {
	l.mu.Lock()
	l.status = st
	l.mu.Unlock()
}

// Run keeps the box registered with the relay until ctx ends, then closes l.
func (l *Listener) Run(ctx context.Context) {
	defer l.Close()
	backoff := time.Second
	lastErr := ""
	for ctx.Err() == nil {
		start := time.Now()
		err := l.session(ctx)
		if ctx.Err() != nil {
			return
		}
		msg := "the connection ended"
		if err != nil {
			msg = err.Error()
		}
		l.setStatus(Status{Since: time.Now(), Err: msg})
		if msg != lastErr {
			l.logf("relay %s: %s; trying again", l.Relay, msg)
			lastErr = msg
		}
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, time.Minute)
	}
}

// session registers once and serves CONNECTs until the connection drops.
func (l *Listener) session(ctx context.Context) error {
	c, err := dialRelay(ctx, l.Relay)
	if err != nil {
		return err
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	r := newReader(c)
	fp := l.Identity.Fingerprint().String()
	hello := fmt.Sprintf("%s LISTEN %s %s", Version, fp, base64.StdEncoding.EncodeToString(l.Identity.PublicKeyInfo()))
	if l.Token != "" {
		hello += " " + l.Token
	}
	c.SetReadDeadline(time.Now().Add(setupWithin))
	if err := writeLine(c, "%s", hello); err != nil {
		return err
	}
	line, err := readLine(r)
	if err != nil {
		return err
	}
	if strings.HasPrefix(line, "ERR ") {
		return parseErr(line)
	}
	challenge, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(line, "CHALLENGE "))
	if !strings.HasPrefix(line, "CHALLENGE ") || err != nil || len(challenge) < 16 {
		return errors.New("relay: unexpected answer to LISTEN")
	}
	sig := l.Identity.Sign(ProofMessage(fp, challenge))
	if err := writeLine(c, "PROOF %s", base64.StdEncoding.EncodeToString(sig)); err != nil {
		return err
	}
	if line, err = readLine(r); err != nil {
		return err
	}
	if line != "OK" {
		if strings.HasPrefix(line, "ERR ") {
			return parseErr(line)
		}
		return errors.New("relay: unexpected answer to PROOF")
	}
	l.setStatus(Status{Connected: true, Since: time.Now()})
	l.logf("relay %s: connected; apps can reach this box through it", l.Relay)
	l.mu.Lock()
	l.ctrl = c
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		if l.ctrl == c {
			l.ctrl = nil
		}
		l.mu.Unlock()
	}()
	go l.republish(c)
	for {
		c.SetReadDeadline(time.Now().Add(deadAfter))
		line, err := readLine(r)
		if err != nil {
			return err
		}
		f := strings.Fields(line)
		switch {
		case f[0] == "PING":
			l.wmu.Lock()
			err := writeLine(c, "PONG")
			l.wmu.Unlock()
			if err != nil {
				return err
			}
		case f[0] == "PUBLISHED" || f[0] == "ERR":
			l.answer(line)
		case f[0] == "SHARE" && len(f) >= 3:
			go l.serveShare(ctx, f[1], f[2])
		case f[0] == "CONNECT" && len(f) >= 2:
			from := ""
			if len(f) >= 3 {
				from = f[2]
			}
			go l.open(ctx, f[1], from)
		}
	}
}

// open makes the box's side of one app connection and hands it to Accept.
func (l *Listener) open(ctx context.Context, id, from string) {
	c, err := dialRelay(ctx, l.Relay)
	if err != nil {
		return
	}
	if err := writeLine(c, "%s ACCEPT %s", Version, id); err != nil {
		c.Close()
		return
	}
	conn := &relayedConn{Conn: c, from: from}
	select {
	case l.conns <- conn:
	case <-l.done:
		c.Close()
	case <-ctx.Done():
		c.Close()
	}
}

func (l *Listener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *Listener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return nil
}

func (l *Listener) Addr() net.Addr { return relayAddr(l.Relay) }

type relayAddr string

func (a relayAddr) Network() string { return "pier-relay" }
func (a relayAddr) String() string  { return string(a) }

// relayedConn is an app's connection as the box sees it: its remote address
// is the app's, as the relay reported it (pairing's rate limits are per
// address).
type relayedConn struct {
	net.Conn
	from string
}

func (c *relayedConn) RemoteAddr() net.Addr {
	if a, err := net.ResolveTCPAddr("tcp", c.from); err == nil && a.IP != nil {
		return a
	}
	return c.Conn.RemoteAddr()
}

// Dial opens a connection to the box with fingerprint fp through the relay at
// addr. When it returns, the box is on the other end: the caller starts TLS.
func Dial(ctx context.Context, addr string, fp identity.Fingerprint) (net.Conn, error) {
	c, err := dialRelay(ctx, addr)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	r := newReader(c)
	c.SetReadDeadline(time.Now().Add(setupWithin))
	if err := writeLine(c, "%s DIAL %s", Version, fp.String()); err != nil {
		c.Close()
		return nil, err
	}
	line, err := readLine(r)
	if err != nil {
		c.Close()
		return nil, fmt.Errorf("relay %s: %w", addr, err)
	}
	if line != "OK" {
		c.Close()
		if strings.HasPrefix(line, "ERR ") {
			return nil, parseErr(line)
		}
		return nil, errors.New("relay: unexpected answer to DIAL")
	}
	c.SetReadDeadline(time.Time{})
	return &bufferedConn{Conn: c, r: r}, nil
}

// NormalizeAddr gives a relay address its default port when it has none; a
// ws:// or wss:// URL stays as it is.
func NormalizeAddr(addr string) (string, error) {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return "", errors.New("empty relay address")
	}
	if IsWebSocket(addr) {
		if u, err := url.Parse(addr); err != nil || u.Host == "" {
			return "", fmt.Errorf("bad relay address %q", addr)
		}
		return addr, nil
	}
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(strings.Trim(addr, "[]"), DefaultPort)
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil || host == "" || port == "" {
		return "", fmt.Errorf("bad relay address %q (want HOST or HOST:PORT)", addr)
	}
	return addr, nil
}
