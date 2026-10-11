package relay

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/identity"
)

// Server is a relay: `pierd relay serve`. It keeps every box's control
// connection, by the box's fingerprint, and joins apps to boxes.
type Server struct {
	// Token, when set, is what a box must present to register.
	Token string
	Log   *log.Logger
	// MaxBoxes and MaxPending bound what the relay holds (0: 1000 and 256).
	MaxBoxes, MaxPending int

	mu      sync.Mutex
	boxes   map[identity.Fingerprint]*control
	pending map[string]*pendingDial
	conns   map[net.Conn]struct{}
}

// control is a registered box's control connection.
type control struct {
	conn    net.Conn
	wmu     sync.Mutex
	pending int
}

func (c *control) send(line string) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return writeLine(c.conn, "%s", line)
}

// pendingDial is an app waiting for its box to open the other side.
type pendingDial struct {
	box    *control
	joined chan *bufferedConn
}

func (s *Server) logf(format string, args ...any) {
	if s.Log != nil {
		s.Log.Printf(format, args...)
	}
}

func (s *Server) init() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.boxes == nil {
		s.boxes = map[identity.Fingerprint]*control{}
		s.pending = map[string]*pendingDial{}
		s.conns = map[net.Conn]struct{}{}
	}
}

// Serve accepts connections on ln until ctx ends.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	s.init()
	stop := context.AfterFunc(ctx, func() {
		ln.Close()
		s.mu.Lock()
		for c := range s.conns {
			c.Close()
		}
		s.mu.Unlock()
	})
	defer stop()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return err
		}
		go s.handle(c)
	}
}

func (s *Server) track(c net.Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.boxes == nil {
		return false
	}
	s.conns[c] = struct{}{}
	return true
}

func (s *Server) untrack(c net.Conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
	c.Close()
}

func (s *Server) handle(c net.Conn) {
	if !s.track(c) {
		c.Close()
		return
	}
	keep := false
	defer func() {
		if !keep {
			s.untrack(c)
		}
	}()
	c.SetReadDeadline(time.Now().Add(setupWithin))
	r := newReader(c)
	line, err := readLine(r)
	if err != nil {
		return
	}
	f := strings.Fields(line)
	if len(f) < 2 || f[0] != Version {
		writeLine(c, "ERR request expected %s", Version)
		return
	}
	switch f[1] {
	case "DIAL":
		s.dial(c, r, f[2:])
	case "LISTEN":
		s.listen(c, r, f[2:])
	case "ACCEPT":
		// The connection now belongs to the app waiting for it, which closes it.
		keep = s.accept(c, r, f[2:])
	default:
		writeLine(c, "ERR request unknown verb")
	}
}

// dial joins an app to its box, or says why not.
func (s *Server) dial(c net.Conn, r *bufio.Reader, args []string) {
	if len(args) != 1 {
		writeLine(c, "ERR request")
		return
	}
	fp, err := identity.ParseFingerprint(args[0])
	if err != nil {
		writeLine(c, "ERR request bad fingerprint")
		return
	}
	id := newID()
	d := &pendingDial{joined: make(chan *bufferedConn, 1)}
	s.mu.Lock()
	box := s.boxes[fp]
	switch {
	case box == nil:
		s.mu.Unlock()
		writeLine(c, "ERR offline")
		return
	case box.pending >= 32 || len(s.pending) >= s.maxPending():
		s.mu.Unlock()
		writeLine(c, "ERR busy")
		return
	}
	d.box = box
	box.pending++
	s.pending[id] = d
	s.mu.Unlock()

	if err := box.send("CONNECT " + id + " " + c.RemoteAddr().String()); err != nil {
		s.take(id)
		writeLine(c, "ERR offline")
		return
	}
	timer := time.NewTimer(acceptWithin)
	defer timer.Stop()
	var other *bufferedConn
	select {
	case other = <-d.joined:
	case <-timer.C:
		if s.take(id) != nil {
			writeLine(c, "ERR timeout")
			return
		}
		// The box's side arrived just now.
		other = <-d.joined
	}
	defer s.untrack(other.Conn)
	c.SetReadDeadline(time.Time{})
	if writeLine(c, "OK") != nil {
		return
	}
	splice(&bufferedConn{Conn: c, r: r}, other)
}

// take removes a pending dial (nil when it was taken already).
func (s *Server) take(id string) *pendingDial {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.pending[id]
	if d != nil {
		delete(s.pending, id)
		d.box.pending--
	}
	return d
}

// accept hands a box's new connection to the app waiting for it.
func (s *Server) accept(c net.Conn, r *bufio.Reader, args []string) bool {
	if len(args) != 1 {
		return false
	}
	d := s.take(args[0])
	if d == nil {
		return false
	}
	c.SetReadDeadline(time.Time{})
	d.joined <- &bufferedConn{Conn: c, r: r}
	return true
}

// listen registers a box that proves it holds its key, then keeps its control
// connection until it drops.
func (s *Server) listen(c net.Conn, r *bufio.Reader, args []string) {
	if len(args) < 2 || len(args) > 3 {
		writeLine(c, "ERR request")
		return
	}
	if s.Token != "" && (len(args) < 3 || subtle.ConstantTimeCompare([]byte(args[2]), []byte(s.Token)) != 1) {
		writeLine(c, "ERR token")
		return
	}
	fp, err := identity.ParseFingerprint(args[0])
	if err != nil {
		writeLine(c, "ERR request bad fingerprint")
		return
	}
	spki, err := base64.StdEncoding.DecodeString(args[1])
	if err != nil || identity.Fingerprint(sha256.Sum256(spki)) != fp {
		writeLine(c, "ERR request the key does not match the fingerprint")
		return
	}
	parsed, err := x509.ParsePKIXPublicKey(spki)
	pub, ok := parsed.(ed25519.PublicKey)
	if err != nil || !ok {
		writeLine(c, "ERR request not an Ed25519 key")
		return
	}
	challenge := make([]byte, 32)
	rand.Read(challenge)
	if writeLine(c, "CHALLENGE "+base64.StdEncoding.EncodeToString(challenge)) != nil {
		return
	}
	line, err := readLine(r)
	if err != nil {
		return
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(line, "PROOF "))
	if !strings.HasPrefix(line, "PROOF ") || err != nil || !ed25519.Verify(pub, ProofMessage(fp.String(), challenge), sig) {
		writeLine(c, "ERR proof")
		return
	}
	box := &control{conn: c}
	s.mu.Lock()
	if old := s.boxes[fp]; old == nil && len(s.boxes) >= s.maxBoxes() {
		s.mu.Unlock()
		writeLine(c, "ERR busy")
		return
	}
	old := s.boxes[fp]
	s.boxes[fp] = box
	s.mu.Unlock()
	if old != nil {
		// The same box again (a restart, a new network): the new one wins.
		old.conn.Close()
	}
	defer func() {
		s.mu.Lock()
		if s.boxes[fp] == box {
			delete(s.boxes, fp)
		}
		s.mu.Unlock()
	}()
	if box.send("OK") != nil {
		return
	}
	s.logf("relay: box %s connected from %s", fp.Short(), c.RemoteAddr())
	defer s.logf("relay: box %s disconnected", fp.Short())

	done := make(chan struct{})
	defer close(done)
	go func() {
		t := time.NewTicker(pingEvery)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if box.send("PING") != nil {
					c.Close()
					return
				}
			}
		}
	}()
	for {
		c.SetReadDeadline(time.Now().Add(deadAfter))
		if _, err := readLine(r); err != nil {
			return
		}
	}
}

func (s *Server) maxBoxes() int {
	if s.MaxBoxes > 0 {
		return s.MaxBoxes
	}
	return 1000
}

func (s *Server) maxPending() int {
	if s.MaxPending > 0 {
		return s.MaxPending
	}
	return 256
}

var idEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return strings.ToLower(idEncoding.EncodeToString(b))
}

// splice copies both ways until either side ends, then closes both.
func splice(a, b *bufferedConn) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(b.Conn, a); done <- struct{}{} }()
	go func() { io.Copy(a.Conn, b); done <- struct{}{} }()
	<-done
	a.Conn.Close()
	b.Conn.Close()
	<-done
}
