package wire

import (
	"context"
	"net"
	"testing"
	"time"

	"pier/pierd/internal/relay"
)

// A box away from its network: its own address answers nothing, its relay
// does. Pairing (bound to the TLS session) and requests still work, because
// the relay only carries the mutual TLS between the two ends.
func TestPairAndRequestThroughARelay(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relayDone := make(chan struct{})
	go func() { (&relay.Server{Token: "t0ken"}).Serve(ctx, ln); close(relayDone) }()
	defer func() { cancel(); <-relayDone }()

	b := startBox(t)
	rl := relay.NewListener(ln.Addr().String(), "t0ken", b.server.Identity, nil)
	go rl.Run(ctx)
	served := make(chan struct{})
	go func() { b.server.Serve(ctx, rl); close(served) }()
	defer func() { cancel(); <-served }()
	deadline := time.Now().Add(5 * time.Second)
	for !rl.Status().Connected {
		if time.Now().After(deadline) {
			t.Fatalf("the box never reached the relay: %+v", rl.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Port 1 refuses at once: the box's own address is out of reach.
	const unreachable = "127.0.0.1:1"
	tok := b.issue(t)
	tok.Address, tok.Relay = unreachable, ln.Addr().String()
	me := laptop(t)
	name, err := Pair(context.Background(), me, tok, "alex-phone")
	if err != nil {
		t.Fatalf("pairing through the relay: %v", err)
	}
	if name != "dev-test" {
		t.Fatalf("box name = %q", name)
	}
	peer := b.peer()
	peer.Address, peer.Relay = unreachable, ln.Addr().String()
	c := NewClient(me, peer)
	defer c.Close()
	if _, err := c.Ping(context.Background()); err != nil {
		t.Fatalf("a request through the relay: %v", err)
	}
	// The box's direct listener never saw any of it.
	if n := b.accepted.Load(); n != 0 {
		t.Fatalf("the box's own listener accepted %d connections", n)
	}
}
