package main

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/doctor"
	"pier/pierd/internal/relay"
	"pier/pierd/internal/service"
	"pier/pierd/internal/statefile"
)

const relayUsage = `usage:
  pierd relay                              This box's relay, and whether it is connected
  pierd relay use HOST[:PORT] [--token T]  Reach this box through the relay at HOST (port 7443 by default)
  pierd relay off                          Stop using a relay
  pierd relay install [--listen ADDR] [--open]
                                           On a server with a public address: run a relay as a user
                                           service (port 7443; --open lets any box use it)
  pierd relay serve [--listen ADDR] [--token T | --open]
                                           Run a relay in the foreground`

// relayCmd is `pierd relay`: a box's relay (use, off, status) and the relay
// itself (serve, install).
func relayCmd(b boxHome, args []string) error {
	if len(args) == 0 {
		return relayStatus(b)
	}
	switch args[0] {
	case "status":
		return relayStatus(b)
	case "use":
		return relayUse(b, args[1:])
	case "off":
		return relayOff(b)
	case "serve":
		return relayServe(b, args[1:])
	case "install":
		return relayInstall(b, args[1:])
	case "uninstall":
		path, err := service.Uninstall(relayService(b, nil))
		if err == nil && path != "" {
			fmt.Println("Removed " + path)
		}
		return err
	}
	return errors.New(relayUsage)
}

// relayDir holds a relay's own state (its token, its log).
func relayDir(b boxHome) string { return filepath.Join(b.home(), "relay") }

// relayToken is the token a relay asks boxes for: kept in its state, made the
// first time, so a relay is private unless --open says otherwise.
func relayToken(b boxHome) (string, error) {
	path := filepath.Join(relayDir(b), "token")
	if data, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(data)) != "" {
		return strings.TrimSpace(string(data)), nil
	}
	raw := make([]byte, 20)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw))
	if err := statefile.Write(path, []byte(token+"\n")); err != nil {
		return "", err
	}
	return token, nil
}

func relayServe(b boxHome, args []string) error {
	fs := flag.NewFlagSet("relay serve", flag.ContinueOnError)
	listen := fs.String("listen", ":"+relay.DefaultPort, "address to listen on")
	token := fs.String("token", "", "the token boxes must present (default: the one in $PIER_HOME/relay/token, made once)")
	open := fs.Bool("open", false, "let any box register, with no token")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *open {
		*token = ""
	} else if *token == "" {
		t, err := relayToken(b)
		if err != nil {
			return err
		}
		*token = t
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger := log.New(os.Stderr, "", log.LstdFlags)
	access := "boxes need its token"
	if *token == "" {
		access = "open to any box"
	}
	logger.Printf("pierd relay serving on %s (%s)", ln.Addr(), access)
	return (&relay.Server{Token: *token, Log: logger}).Serve(ctx, ln)
}

// relayService is the relay's user service; args are serve's (nil when only
// its name matters).
func relayService(b boxHome, args []string) service.Spec {
	name := "pierd-relay"
	if runtime.GOOS == "darwin" {
		name = "app.pier.pierd-relay"
	}
	exe, _ := os.Executable()
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return service.Spec{
		Name:        name,
		Description: "Pier relay",
		Program:     exe,
		Args:        append([]string{"relay", "serve"}, args...),
		Env:         map[string]string{"PIER_HOME": b.home()},
		LogPath:     filepath.Join(relayDir(b), "relay.log"),
	}
}

func relayInstall(b boxHome, args []string) error {
	fs := flag.NewFlagSet("relay install", flag.ContinueOnError)
	listen := fs.String("listen", ":"+relay.DefaultPort, "address to listen on")
	open := fs.Bool("open", false, "let any box register, with no token")
	if err := fs.Parse(args); err != nil {
		return err
	}
	_, port, err := net.SplitHostPort(*listen)
	if err != nil {
		return fmt.Errorf("--listen: %w", err)
	}
	serveArgs := []string{"--listen", *listen}
	token := ""
	if *open {
		serveArgs = append(serveArgs, "--open")
	} else if token, err = relayToken(b); err != nil {
		return err
	}
	if err := service.Preflight(); err != nil {
		return err
	}
	spec := relayService(b, serveArgs)
	if spec.Program, err = stableExecutable(spec.Program); err != nil {
		return err
	}
	path, err := service.Install(spec)
	if err != nil {
		return err
	}
	if err := waitListening(net.JoinHostPort("127.0.0.1", port), 10*time.Second); err != nil {
		return fmt.Errorf("installed %s, but the relay did not start: %w%s", path, err, logTail(spec.LogPath, 8))
	}
	public := net.JoinHostPort(pickAddress(interfaceIPs(), b.name(), ""), port)
	fmt.Printf("Installed %s; the relay listens on %s.\n\n", path, *listen)
	fmt.Println("Open TCP port " + port + " in this server's firewall, then on each box (a Mac, a server at home):")
	cmd := "pierd relay use " + public
	if token != "" {
		cmd += " --token " + token
	}
	fmt.Println("\n  " + cmd + "\n")
	if runtime.GOOS == "linux" && !lingering() {
		fmt.Println("Keep it running after you log out: sudo loginctl enable-linger " + currentUser())
	}
	return nil
}

func waitListening(addr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		c, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			c.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// relayUse points this box at a relay and restarts pierd so it connects.
func relayUse(b boxHome, args []string) error {
	fs := flag.NewFlagSet("relay use", flag.ContinueOnError)
	token := fs.String("token", "", "the relay's token (pierd relay install prints it)")
	var addr string
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		addr, args = args[0], args[1:]
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if addr == "" && fs.NArg() == 1 {
		addr = fs.Arg(0)
	}
	if addr == "" {
		return errors.New(relayUsage)
	}
	if err := saveRelay(b, addr, *token); err != nil {
		return err
	}
	return restartForRelay(b)
}

// saveRelay keeps the relay settings pierd serve reads at start.
func saveRelay(b boxHome, addr, token string) error {
	addr, err := relay.NormalizeAddr(addr)
	if err != nil {
		return err
	}
	if err := statefile.Write(filepath.Join(b.dir, "relay"), []byte(addr+"\n")); err != nil {
		return err
	}
	tokenPath := filepath.Join(b.dir, "relay-token")
	if token == "" {
		os.Remove(tokenPath)
		return nil
	}
	return statefile.Write(tokenPath, []byte(strings.TrimSpace(token)+"\n"))
}

func relayOff(b boxHome) error {
	if b.setting("relay") == "" {
		fmt.Println("This box uses no relay.")
		return nil
	}
	os.Remove(filepath.Join(b.dir, "relay"))
	os.Remove(filepath.Join(b.dir, "relay-token"))
	if err := restartForRelay(b); err != nil {
		return err
	}
	fmt.Println("Apps now reach this box at its own address only.")
	return nil
}

// restartForRelay restarts the box's service (when it is one) so it reads the
// relay settings, and reports the relay's state.
func restartForRelay(b boxHome) error {
	spec := daemonService(b, "")
	if !service.Installed(spec) {
		fmt.Println("Saved. pierd serve uses it from its next start.")
		return nil
	}
	started := time.Now()
	if err := service.Restart(spec); err != nil {
		return err
	}
	if err := waitServing(b, started, 20*time.Second); err != nil {
		return fmt.Errorf("pierd did not come back: %w", err)
	}
	if b.setting("relay") == "" {
		return nil
	}
	// The relay answers in a moment, or says why not.
	deadline := time.Now().Add(10 * time.Second)
	for {
		c, ok := relayDoctorCheck(b)
		if ok && (c.Status == doctor.OK || time.Now().After(deadline)) {
			printRelayCheck(b, c)
			return nil
		}
		if !ok && time.Now().After(deadline) {
			fmt.Println("Saved; pierd restarted. pierd doctor shows whether the relay is connected.")
			return nil
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// relayDoctorCheck is the running pierd's relay check, from its doctor report.
func relayDoctorCheck(b boxHome) (doctor.Check, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	checks, err := box.NewClient(box.NewLocal(b.socket())).Doctor(ctx)
	if err != nil {
		return doctor.Check{}, false
	}
	for _, c := range checks {
		if c.Name == "relay" {
			return c, true
		}
	}
	return doctor.Check{}, false
}

func printRelayCheck(b boxHome, c doctor.Check) {
	if c.Status == doctor.OK {
		fmt.Printf("Relay %s: %s. Apps reach this box from anywhere; paired apps learn it by themselves.\n", b.setting("relay"), c.Detail)
		return
	}
	fmt.Printf("Relay %s: %s\n", b.setting("relay"), c.Detail)
	if c.Fix != "" {
		fmt.Println("  → " + c.Fix)
	}
}

func relayStatus(b boxHome) error {
	addr := b.setting("relay")
	if addr == "" {
		fmt.Println("This box uses no relay: apps reach it at " + pairAddress(b) + " only.")
		fmt.Println("To reach it from anywhere (a Mac or a server at home, behind NAT), run a relay on a server with a")
		fmt.Println("public address (pierd relay install there), then here: pierd relay use HOST --token TOKEN")
		fmt.Println()
		fmt.Println(relayUsage)
		return nil
	}
	if c, ok := relayDoctorCheck(b); ok {
		printRelayCheck(b, c)
		return nil
	}
	fmt.Println("Relay: " + addr + " (pierd is not running, so not connected)")
	return nil
}

// relayChecks are the doctor's lines about the relay: none without one.
func relayChecks(rl *relay.Listener) []doctor.Check {
	if rl == nil {
		return nil
	}
	st := rl.Status()
	if st.Connected {
		return []doctor.Check{{Area: "pierd", Name: "relay", Status: doctor.OK,
			Detail: "connected to " + rl.Relay + " since " + st.Since.Format("15:04")}}
	}
	detail := "not connected to " + rl.Relay
	if st.Err != "" {
		detail += ": " + st.Err
	}
	return []doctor.Check{{Area: "pierd", Name: "relay", Status: doctor.Warn, Detail: detail,
		Fix: "check that the relay runs and its port is open; pierd relay use HOST --token TOKEN"}}
}
