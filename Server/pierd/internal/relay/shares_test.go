package relay

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A box publishes its dev server; the relay serves it at the public host to
// anyone, a page at a time, with Host localhost; the link goes when the box
// takes it down, and relays without a share domain refuse.
func TestPublicLinkServesTheBoxPort(t *testing.T) {
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "host="+r.Host+" fwd="+r.Header.Get("X-Forwarded-Host")+" path="+r.URL.RequestURI())
	}))
	defer page.Close()
	port := page.Listener.Addr().(*net.TCPAddr).Port

	addr, _ := startRelay(t, "", func(s *Server) { s.ShareDomain = "example.test" })
	l := startBox(t, addr, "", newIdentity(t))
	waitConnected(t, l)
	name := l.SharePrefix() + "abcdefghij012345"
	url, err := l.Publish(context.Background(), name, port)
	if err != nil || url != "https://p-"+name+".example.test" {
		t.Fatalf("publish = %q %v", url, err)
	}

	get := func(host, path string) (int, string) {
		req, _ := http.NewRequest("GET", "http://"+addr+path, nil)
		req.Host = host
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	status, body := get("p-"+name+".example.test", "/app?x=1")
	if status != 200 || body != "host=localhost fwd=p-"+name+".example.test path=/app?x=1" {
		t.Fatalf("public page = %d %q", status, body)
	}
	// Twice: each request gets its own connection to the box.
	if status, _ := get("p-"+name+".example.test", "/"); status != 200 {
		t.Fatalf("second request = %d", status)
	}
	if status, _ := get("p-zzzzzzzzzzzzzzzzzzzz.example.test", "/"); status != http.StatusBadGateway {
		t.Fatalf("unknown link = %d", status)
	}

	l.Unpublish(name)
	deadline := time.Now().Add(3 * time.Second)
	for {
		status, _ := get("p-"+name+".example.test", "/")
		if status == http.StatusBadGateway {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("link still served after unpublish: %d", status)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestRelayWithoutShareDomainRefusesLinks(t *testing.T) {
	addr, _ := startRelay(t, "")
	l := startBox(t, addr, "", newIdentity(t))
	waitConnected(t, l)
	if _, err := l.Publish(context.Background(), l.SharePrefix()+"abcdefghij012345", 1); !errors.Is(err, ErrNoShares) {
		t.Fatalf("publish on a relay without links = %v", err)
	}
	for _, bad := range []string{"UPPER-case", "abcdefghij0123456789"} {
		if _, err := l.Publish(context.Background(), bad, 1); err == nil || !strings.Contains(err.Error(), "invalid") {
			t.Fatalf("bad name %q = %v", bad, err)
		}
	}
}

func TestShareOf(t *testing.T) {
	s := &Server{ShareDomain: "docktopier.com"}
	cases := map[string]string{
		"p-abcdefghij0123456789.docktopier.com":     "abcdefghij0123456789",
		"P-ABCDEFGHIJ0123456789.Docktopier.com:443": "abcdefghij0123456789",
		"t.docktopier.com":                          "",
		"p-short.docktopier.com":                    "",
		"abcdefghij0123456789.docktopier.com":       "",
		"p-abcdefghij0123456789.evil.com":           "",
		"x.p-abcdefghij0123456789.docktopier.com":   "",
	}
	for host, want := range cases {
		if got := s.shareOf(host); got != want {
			t.Errorf("shareOf(%q) = %q, want %q", host, got, want)
		}
	}
}

// Found in review: a WebSocket upgrade passes through a link (hot reload).
func TestPublicLinkPassesWebSockets(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				if _, err := http.ReadRequest(br); err != nil {
					return
				}
				io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
				io.Copy(c, br)
			}(c)
		}
	}()
	addr, _ := startRelay(t, "", func(s *Server) { s.ShareDomain = "example.test" })
	l := startBox(t, addr, "", newIdentity(t))
	waitConnected(t, l)
	name := l.SharePrefix() + "abcdefghij012345"
	if _, err := l.Publish(context.Background(), name, ln.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprintf(c, "GET /ws HTTP/1.1\r\nHost: p-%s.example.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: x\r\nSec-WebSocket-Version: 13\r\n\r\n", name)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != 101 {
		t.Fatalf("upgrade = %v %v", resp, err)
	}
	fmt.Fprint(c, "ping")
	got := make([]byte, 4)
	if _, err := io.ReadFull(br, got); err != nil || string(got) != "ping" {
		t.Fatalf("echo through the upgraded link = %q %v", got, err)
	}
}

// Found in review: a link's name belongs to its box's key; another box can
// never publish it, not even while the owner is away.
func TestPublicLinkNamesBelongToTheirBox(t *testing.T) {
	addr, s := startRelay(t, "", func(s *Server) { s.ShareDomain = "example.test" })
	ctx, cancel := context.WithCancel(context.Background())
	owner := NewListener(addr, "", newIdentity(t), nil)
	go owner.Run(ctx)
	waitConnected(t, owner)
	name := owner.SharePrefix() + "abcdefghij012345"
	if _, err := owner.Publish(context.Background(), name, 1); err != nil {
		t.Fatal(err)
	}
	cancel()
	deadline := time.Now().Add(3 * time.Second)
	for {
		s.mu.Lock()
		_, held := s.shares[name]
		s.mu.Unlock()
		if !held || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	attacker := startBox(t, addr, "", newIdentity(t))
	waitConnected(t, attacker)
	// Its own Publish refuses a name of another box; the relay refuses it too.
	if _, err := attacker.Publish(context.Background(), name, 2); err == nil {
		t.Fatal("another box published the owner's link name")
	}
	attacker.mu.Lock()
	ctrl := attacker.ctrl
	attacker.mu.Unlock()
	attacker.wmu.Lock()
	writeLine(ctrl, "PUBLISH %s", name)
	attacker.wmu.Unlock()
	time.Sleep(200 * time.Millisecond)
	s.mu.Lock()
	_, held := s.shares[name]
	s.mu.Unlock()
	if held {
		t.Fatal("the relay gave the owner's name to another box")
	}
}

// Found in review: the page's server sees the visitor's address, not the
// relay's, and visitors cannot use up the owner's own connections.
func TestPublicLinkVisitorsAreNotLocalAndNotTheOwner(t *testing.T) {
	block := make(chan struct{})
	seen := make(chan string, 8)
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.Header.Get("X-Forwarded-For") + "|" + r.Header.Get("X-Real-Ip")
		if r.URL.Path == "/slow" {
			<-block
		}
	}))
	defer page.Close()
	defer close(block)
	addr, _ := startRelay(t, "", func(s *Server) { s.ShareDomain = "example.test"; s.BehindProxy = true; s.MaxConnsPerBox = 4 })
	id := newIdentity(t)
	l := startBox(t, addr, "", id)
	waitConnected(t, l)
	name := l.SharePrefix() + "abcdefghij012345"
	if _, err := l.Publish(context.Background(), name, page.Listener.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("GET", "http://"+addr+"/", nil)
	req.Host = "p-" + name + ".example.test"
	req.Header.Set("Cf-Connecting-Ip", "203.0.113.9")
	req.Header.Set("X-Forwarded-For", "127.0.0.1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := <-seen; got != "203.0.113.9|203.0.113.9" {
		t.Fatalf("the page saw %q", got)
	}
	for i := 0; i < 6; i++ {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		fmt.Fprintf(c, "GET /slow HTTP/1.1\r\nHost: p-%s.example.test\r\n\r\n", name)
	}
	time.Sleep(500 * time.Millisecond)
	conn, err := Dial(context.Background(), addr, id.Fingerprint())
	if err != nil {
		t.Fatalf("the owner's app is locked out by visitors: %v", err)
	}
	conn.Close()
}
