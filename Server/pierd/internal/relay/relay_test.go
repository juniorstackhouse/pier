package relay

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/identity"
)

func newIdentity(t *testing.T) *identity.Identity {
	t.Helper()
	id, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// startRelay runs a relay on a free local port.
func startRelay(t *testing.T, token string) (addr string, s *Server) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s = &Server{Token: token}
	done := make(chan struct{})
	go func() { s.Serve(ctx, ln); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	return ln.Addr().String(), s
}

// startBox registers a box with the relay and echoes, upper-cased, whatever its apps send.
func startBox(t *testing.T, relay, token string, id *identity.Identity) *Listener {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	l := NewListener(relay, token, id, nil)
	go l.Run(ctx)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				fmt.Fprintf(c, "from %s\n", c.RemoteAddr())
				sc := bufio.NewScanner(c)
				for sc.Scan() {
					fmt.Fprintln(c, strings.ToUpper(sc.Text()))
				}
			}()
		}
	}()
	t.Cleanup(cancel)
	return l
}

func waitConnected(t *testing.T, l *Listener) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if l.Status().Connected {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("the box never registered: %+v", l.Status())
}

func TestAppReachesTheBoxThroughTheRelay(t *testing.T) {
	relay, _ := startRelay(t, "s3cret")
	id := newIdentity(t)
	waitConnected(t, startBox(t, relay, "s3cret", id))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, relay, id.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	first, _ := r.ReadString('\n')
	// The box sees the app's address, not the relay's own connection.
	if !strings.HasPrefix(first, "from 127.0.0.1:") || strings.Contains(first, relay) {
		t.Fatalf("box saw the app as %q", first)
	}
	fmt.Fprintln(c, "hello box")
	if got, _ := r.ReadString('\n'); got != "HELLO BOX\n" {
		t.Fatalf("echo = %q", got)
	}
	// Several apps at once, each joined to its own box connection.
	for i := 0; i < 3; i++ {
		c2, err := Dial(ctx, relay, id.Fingerprint())
		if err != nil {
			t.Fatal(err)
		}
		r2 := bufio.NewReader(c2)
		r2.ReadString('\n')
		fmt.Fprintf(c2, "app %d\n", i)
		if got, _ := r2.ReadString('\n'); got != fmt.Sprintf("APP %d\n", i) {
			t.Fatalf("app %d echo = %q", i, got)
		}
		c2.Close()
	}
}

func TestDialingABoxThatIsNotThere(t *testing.T) {
	relay, _ := startRelay(t, "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := Dial(ctx, relay, newIdentity(t).Fingerprint())
	var re *Error
	if !errors.As(err, &re) || re.Code != "offline" {
		t.Fatalf("err = %v, want offline", err)
	}
}

func TestAWrongTokenKeepsTheBoxOut(t *testing.T) {
	relay, _ := startRelay(t, "right")
	l := startBox(t, relay, "wrong", newIdentity(t))
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && !strings.Contains(l.Status().Err, "token") {
		time.Sleep(10 * time.Millisecond)
	}
	if st := l.Status(); st.Connected || !strings.Contains(st.Err, "token") {
		t.Fatalf("status = %+v, want refused for its token", st)
	}
}

// listenAs speaks the box's side of LISTEN by hand: claim fp with spki, then sign with sign.
func listenAs(t *testing.T, relay string, fp string, spki []byte, sign func([]byte) []byte) string {
	t.Helper()
	c, err := net.Dial("tcp", relay)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	r := bufio.NewReader(c)
	fmt.Fprintf(c, "%s LISTEN %s %s\n", Version, fp, base64.StdEncoding.EncodeToString(spki))
	line, _ := r.ReadString('\n')
	if !strings.HasPrefix(line, "CHALLENGE ") {
		return strings.TrimSpace(line)
	}
	challenge, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(line, "CHALLENGE ")))
	fmt.Fprintf(c, "PROOF %s\n", base64.StdEncoding.EncodeToString(sign(ProofMessage(fp, challenge))))
	line, _ = r.ReadString('\n')
	return strings.TrimSpace(line)
}

func TestOnlyTheKeysOwnerCanRegisterIt(t *testing.T) {
	relay, _ := startRelay(t, "")
	box, other := newIdentity(t), newIdentity(t)
	fp := box.Fingerprint().String()
	// Someone else's key under the box's fingerprint.
	if got := listenAs(t, relay, fp, other.PublicKeyInfo(), other.Sign); !strings.HasPrefix(got, "ERR request") {
		t.Fatalf("a key that is not the fingerprint's: %q", got)
	}
	// The box's public key, without its private key.
	if got := listenAs(t, relay, fp, box.PublicKeyInfo(), other.Sign); got != "ERR proof" {
		t.Fatalf("a proof by another key: %q", got)
	}
	if got := listenAs(t, relay, fp, box.PublicKeyInfo(), box.Sign); got != "OK" {
		t.Fatalf("the box itself: %q", got)
	}
}

func TestTheSameBoxAgainReplacesItsOldRegistration(t *testing.T) {
	relay, _ := startRelay(t, "")
	id := newIdentity(t)
	first := startBox(t, relay, "", id)
	waitConnected(t, first)
	second := startBox(t, relay, "", id)
	waitConnected(t, second)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, relay, id.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	r.ReadString('\n')
	fmt.Fprintln(c, "still here")
	if got, _ := r.ReadString('\n'); got != "STILL HERE\n" {
		t.Fatalf("echo = %q", got)
	}
}

func TestABoxThatNeverAcceptsTimesOut(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the accept deadline")
	}
	relay, _ := startRelay(t, "")
	id := newIdentity(t)
	// Registered by hand, and then deaf to CONNECT.
	c, err := net.Dial("tcp", relay)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	fp := id.Fingerprint().String()
	fmt.Fprintf(c, "%s LISTEN %s %s\n", Version, fp, base64.StdEncoding.EncodeToString(id.PublicKeyInfo()))
	line, _ := r.ReadString('\n')
	challenge, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(line, "CHALLENGE ")))
	fmt.Fprintf(c, "PROOF %s\n", base64.StdEncoding.EncodeToString(id.Sign(ProofMessage(fp, challenge))))
	if line, _ = r.ReadString('\n'); strings.TrimSpace(line) != "OK" {
		t.Fatalf("register: %q", line)
	}
	go io.Copy(io.Discard, r)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_, err = Dial(ctx, relay, id.Fingerprint())
	var re *Error
	if !errors.As(err, &re) || re.Code != "timeout" {
		t.Fatalf("err = %v, want timeout", err)
	}
}

func TestNormalizeAddr(t *testing.T) {
	for in, want := range map[string]string{
		"relay.example.com":      "relay.example.com:7443",
		"relay.example.com:443":  "relay.example.com:443",
		"203.0.113.7":            "203.0.113.7:7443",
		"[2001:db8::1]:9000":     "[2001:db8::1]:9000",
		" relay.example.com:80 ": "relay.example.com:80",
	} {
		if got, err := NormalizeAddr(in); err != nil || got != want {
			t.Errorf("NormalizeAddr(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := NormalizeAddr(""); err == nil {
		t.Error("an empty address must not pass")
	}
}
