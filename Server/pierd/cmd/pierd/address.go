package main

import (
	"net"
	"net/netip"
	"os/exec"
	"runtime"
	"strings"
)

// carrierGradeNAT is 100.64.0.0/10, which Tailscale uses and Go's IsPrivate
// does not cover.
var carrierGradeNAT = netip.MustParsePrefix("100.64.0.0/10")

// pickAddress guesses the address an app should dial: a public IPv4 address
// first (a VPS), then this Mac's Bonjour name (local, when given: it follows
// the Mac from one Wi-Fi address to the next, and phones on that network
// resolve it with nothing installed), then a tailnet address (a server whose
// owner set up Tailscale reaches their phone from anywhere), then a private
// address (a server at home or at the office), and the hostname as the last
// resort. `pair --address` overrides the guess.
func pickAddress(ips []net.IP, hostname, local string) string {
	var private, tailnet string
	for _, ip := range ips {
		addr, ok := netip.AddrFromSlice(ip)
		if !ok {
			continue
		}
		addr = addr.Unmap()
		if !addr.Is4() || addr.IsLoopback() || addr.IsLinkLocalUnicast() || addr.IsUnspecified() {
			continue
		}
		switch {
		case carrierGradeNAT.Contains(addr):
			if tailnet == "" {
				tailnet = addr.String()
			}
		case addr.IsPrivate():
			if private == "" {
				private = addr.String()
			}
		default:
			return addr.String()
		}
	}
	for _, a := range []string{local, tailnet, private} {
		if a != "" {
			return a
		}
	}
	return hostname
}

func interfaceIPs() []net.IP {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	ips := make([]net.IP, 0, len(addrs))
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			ips = append(ips, n.IP)
		}
	}
	return ips
}

// localName is this Mac's Bonjour name ("Ana-MacBook.local"), which phones on
// the same network resolve by themselves; "" anywhere else.
var localName = func() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	out, err := exec.Command("scutil", "--get", "LocalHostName").Output()
	name := strings.TrimSpace(string(out))
	if err != nil || name == "" {
		return ""
	}
	return name + ".local"
}

// defaultListen is where pierd listens when --listen is not given: every
// interface. pierd answers only devices it paired (mutual TLS with pinned
// keys) and single-use, short-lived pairing codes, so it runs as it is on a
// VPS, on a server at home or on a Mac, with no Tailscale needed; --listen
// narrows it (a tailnet address, 127.0.0.1).
func defaultListen([]net.IP) (string, error) {
	return net.JoinHostPort("0.0.0.0", defaultPort), nil
}

// advertise is the address a pairing link tells apps to dial. When pierd
// listens on one specific address, that is the only one that works, so it
// wins over any guess.
func advertise(listening string, ips []net.IP, hostname string) string {
	host, port, err := net.SplitHostPort(listening)
	if err != nil {
		host, port = "", defaultPort
	}
	if ip := net.ParseIP(host); host != "" && (ip == nil || !ip.IsUnspecified()) {
		return listening
	}
	return net.JoinHostPort(pickAddress(ips, hostname, localName()), port)
}

func netipAddr(ip net.IP) netip.Addr {
	a, _ := netip.AddrFromSlice(ip)
	return a.Unmap()
}
