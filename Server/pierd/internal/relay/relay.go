// Package relay lets apps reach a box they cannot dial (a Mac or a server at
// home, behind NAT, away from its network): the box keeps a connection out to
// a relay anyone can run (`pierd relay serve` on a VPS), and the relay joins
// each app's connection to a fresh one the box opens for it. Inside, the app
// and the box speak the same mutual TLS as on a direct connection, with the
// keys pinned at pairing: the relay passes bytes it can neither read nor
// change. What it does learn is which box an app asks for (its key's
// fingerprint), from where, when and how much.
//
// The protocol, PIER-RELAY/1: one line each way to set a connection up, then
// raw bytes. A line ends in \n and is at most 1 KB.
//
//	app → relay   PIER-RELAY/1 DIAL <box fingerprint>
//	relay → app   OK                                (then TLS, the app first)
//	              ERR <code> [text]                 (offline, timeout, busy, request)
//
//	box → relay   PIER-RELAY/1 LISTEN <box fingerprint> <SubjectPublicKeyInfo, base64> [token]
//	relay → box   CHALLENGE <32 random bytes, base64>
//	box → relay   PROOF <Ed25519 signature of ProofMessage, base64>
//	relay → box   OK                                (or ERR token, proof, request)
//	relay → box   CONNECT <id> <app address>        (one per app connection)
//	relay → box   PING                              (every 30 s; the box answers PONG)
//
//	box → relay   PIER-RELAY/1 ACCEPT <id>          (a new connection, joined to that app's)
//
// A box registers only with a key it holds (the challenge), so no one else can
// answer for it; a relay may also ask for a token, which keeps strangers' boxes
// off a personal relay. Apps need no token: the box still only answers devices
// it paired.
package relay

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

const (
	// Version opens every connection's first line.
	Version = "PIER-RELAY/1"
	// DefaultPort is where `pierd relay serve` listens unless told otherwise.
	DefaultPort = "7443"

	maxLine = 1024
	// pingEvery keeps a box's control connection (and the NATs on its way)
	// alive; deadAfter without a line means the connection is gone.
	pingEvery = 30 * time.Second
	deadAfter = 75 * time.Second
	// acceptWithin is how long an app waits for the box to open its side.
	acceptWithin = 10 * time.Second
	// setupWithin bounds every step before bytes flow.
	setupWithin = 15 * time.Second
)

// ProofMessage is what a box signs to show the relay it holds its key.
func ProofMessage(fingerprint string, challenge []byte) []byte {
	return append([]byte("pier relay v1\n"+fingerprint+"\n"), challenge...)
}

// Error is a relay's refusal (`ERR <code> [text]`).
type Error struct {
	Code string
	Text string
}

func (e *Error) Error() string {
	switch e.Code {
	case "offline":
		return "the box is not connected to the relay"
	case "timeout":
		return "the box did not answer through the relay"
	case "busy":
		return "the relay is busy"
	case "token":
		return "the relay refused the token"
	case "proof":
		return "the relay refused the box's key proof"
	}
	if e.Text != "" {
		return "relay: " + e.Code + ": " + e.Text
	}
	return "relay: " + e.Code
}

func parseErr(line string) error {
	f := strings.SplitN(strings.TrimPrefix(line, "ERR "), " ", 2)
	e := &Error{Code: f[0]}
	if len(f) > 1 {
		e.Text = f[1]
	}
	return e
}

var errLine = errors.New("relay: line too long or malformed")

// readLine reads one protocol line (without its \n).
func readLine(r *bufio.Reader) (string, error) {
	b, err := r.ReadSlice('\n')
	if errors.Is(err, bufio.ErrBufferFull) {
		return "", errLine
	}
	if err != nil {
		return "", err
	}
	line := strings.TrimRight(string(b), "\r\n")
	if line == "" || strings.ContainsAny(line, "\x00") {
		return "", errLine
	}
	return line, nil
}

func writeLine(c net.Conn, format string, args ...any) error {
	c.SetWriteDeadline(time.Now().Add(setupWithin))
	_, err := fmt.Fprintf(c, format+"\n", args...)
	c.SetWriteDeadline(time.Time{})
	return err
}

// bufferedConn reads through the reader that read the setup lines, so no byte
// it buffered is lost (none should be: the other side waits for an answer).
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }

func newReader(c net.Conn) *bufio.Reader { return bufio.NewReaderSize(c, maxLine) }
