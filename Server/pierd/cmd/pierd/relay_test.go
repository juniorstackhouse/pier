package main

import (
	"os"
	"path/filepath"
	"testing"

	"pier/pierd/internal/identity"
	"pier/pierd/internal/relay"
)

func TestTheBoxUsesThePierTunnelUnlessToldOtherwise(t *testing.T) {
	defer func(o string) { relay.Official = o }(relay.Official)
	b := boxHome{dir: t.TempDir()}
	id, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	fp := id.Fingerprint()

	// A build that names no tunnel: none.
	relay.Official = ""
	if cfg := relayConfig(b); cfg.Connect != "" || cfg.advertise(fp) != "" {
		t.Fatalf("no tunnel in the build: %+v", cfg)
	}
	// The Pier tunnel, by default: the box connects to it, apps dial its own name there.
	relay.Official = "t.example.com:443"
	cfg := relayConfig(b)
	if !cfg.Official || cfg.Connect != "t.example.com:443" || cfg.advertise(fp) != fp.Short()+".t.example.com:443" {
		t.Fatalf("default: %+v, advertises %q", cfg, cfg.advertise(fp))
	}
	if got := tunnelName(cfg.advertise(fp)); got != fp.Short()+".t.example.com" {
		t.Fatalf("tunnelName = %q", got)
	}
	// A relay of one's own, with its token.
	if err := saveRelay(b, "relay.example.org", "s3cret"); err != nil {
		t.Fatal(err)
	}
	cfg = relayConfig(b)
	if cfg.Official || cfg.Connect != "relay.example.org:7443" || cfg.Token != "s3cret" || cfg.advertise(fp) != "relay.example.org:7443" {
		t.Fatalf("own relay: %+v", cfg)
	}
	// Off.
	if err := os.WriteFile(filepath.Join(b.dir, "relay"), []byte("off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if cfg := relayConfig(b); cfg.Connect != "" {
		t.Fatalf("off: %+v", cfg)
	}
}

func TestTunnelNameReadsWithoutSchemeOrPort(t *testing.T) {
	for in, want := range map[string]string{
		"wss://t.example.com/ue4nkpjupj6v": "t.example.com/ue4nkpjupj6v",
		"ue4nkpjupj6v.t.example.com:443":   "ue4nkpjupj6v.t.example.com",
		"relay.example.org:7443":           "relay.example.org:7443",
	} {
		if got := tunnelName(in); got != want {
			t.Errorf("tunnelName(%q) = %q, want %q", in, got, want)
		}
	}
}
