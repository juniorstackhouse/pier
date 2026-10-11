package main

import (
	"net"
	"testing"
)

func ips(s ...string) []net.IP {
	out := make([]net.IP, len(s))
	for i, v := range s {
		out[i] = net.ParseIP(v)
	}
	return out
}

func TestPickAddress(t *testing.T) {
	for _, tc := range []struct {
		name, local string
		ips         []net.IP
		want        string
	}{
		{name: "public beats private and tailnet", ips: ips("127.0.0.1", "10.0.0.5", "100.101.102.103", "203.0.113.5"), want: "203.0.113.5"},
		{name: "tailnet when nothing is public", ips: ips("127.0.0.1", "10.0.0.5", "100.101.102.103"), want: "100.101.102.103"},
		{name: "tailnet beats private in any order", ips: ips("192.168.1.20", "100.101.102.103"), want: "100.101.102.103"},
		{name: "private when there is nothing else", ips: ips("127.0.0.1", "192.168.1.20"), want: "192.168.1.20"},
		{name: "tailnet alone", ips: ips("100.101.102.103"), want: "100.101.102.103"},
		{name: "a Mac's Bonjour name beats private and tailnet", local: "ana-mac.local", ips: ips("100.101.102.103", "192.168.1.20"), want: "ana-mac.local"},
		{name: "public beats the Bonjour name", local: "ana-mac.local", ips: ips("192.168.1.20", "203.0.113.5"), want: "203.0.113.5"},
		{name: "link-local and loopback are skipped", ips: ips("127.0.0.1", "169.254.1.1", "fe80::1"), want: "box.example"},
		{name: "IPv6 is skipped for now", ips: ips("2001:db8::1"), want: "box.example"},
		{name: "IPv4-mapped IPv6 is treated as IPv4", ips: ips("::ffff:203.0.113.9"), want: "203.0.113.9"},
		{name: "no addresses falls back to hostname", want: "box.example"},
	} {
		if got := pickAddress(tc.ips, "box.example", tc.local); got != tc.want {
			t.Errorf("%s: pickAddress = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestDefaultListenIsEveryInterface(t *testing.T) {
	// No Tailscale needed: a VPS, a server at home or a Mac all listen on every interface.
	for _, all := range [][]net.IP{ips("127.0.0.1", "203.0.113.5", "10.0.0.5", "100.101.102.103"), ips("192.168.1.20"), nil} {
		if got, err := defaultListen(all); err != nil || got != "0.0.0.0:7444" {
			t.Fatalf("defaultListen(%v) = %q, %v; want every interface", all, got, err)
		}
	}
}

func TestAdvertiseUsesTheAddressActuallyListenedOn(t *testing.T) {
	defer func(f func() string) { localName = f }(localName)
	localName = func() string { return "" }
	all := ips("203.0.113.5", "100.101.102.103")
	for listening, want := range map[string]string{
		"100.101.102.103:7444": "100.101.102.103:7444",
		"0.0.0.0:7444":         "203.0.113.5:7444",
		"[::]:9000":            "203.0.113.5:9000",
		":7444":                "203.0.113.5:7444",
		"":                     "203.0.113.5:7444",
		"box.example:7444":     "box.example:7444",
	} {
		if got := advertise(listening, all, "box.example"); got != want {
			t.Errorf("advertise(%q) = %q, want %q", listening, got, want)
		}
	}
}
