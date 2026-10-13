package relay

import (
	"context"
	"errors"
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
	name := "abcdefghij0123456789"
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
	if _, err := l.Publish(context.Background(), "abcdefghij0123456789", 1); !errors.Is(err, ErrNoShares) {
		t.Fatalf("publish on a relay without links = %v", err)
	}
	if _, err := l.Publish(context.Background(), "UPPER-case", 1); err == nil || !strings.Contains(err.Error(), "invalid") {
		t.Fatalf("bad name = %v", err)
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
