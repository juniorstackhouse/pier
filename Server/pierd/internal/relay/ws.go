package relay

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// The relay's protocol also runs inside a WebSocket (RFC 6455, binary
// messages as one byte stream), so it can sit behind an HTTPS front such as a
// Cloudflare Tunnel, whose edge holds the certificate and passes WebSockets
// through. Nothing else changes: the same lines, then the same end-to-end TLS.
// A relay address that is a ws:// or wss:// URL is dialed this way; host:port
// is plain TCP. A relay serves both on one port (it tells them apart by the
// first bytes: "GET " is a WebSocket).

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// IsWebSocket says whether a relay address is a WebSocket URL.
func IsWebSocket(addr string) bool {
	return strings.HasPrefix(addr, "wss://") || strings.HasPrefix(addr, "ws://")
}

// dialRelay connects to a relay at addr, host:port or a ws(s):// URL.
func dialRelay(ctx context.Context, addr string) (net.Conn, error) {
	if IsWebSocket(addr) {
		return dialWebSocket(ctx, addr)
	}
	d := net.Dialer{Timeout: setupWithin, KeepAlive: 30 * time.Second}
	return d.DialContext(ctx, "tcp", addr)
}

// dialWebSocket opens a WebSocket to rawURL (TLS for wss, the system's roots).
func dialWebSocket(ctx context.Context, rawURL string) (net.Conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = "80"
		if u.Scheme == "wss" {
			port = "443"
		}
	}
	d := net.Dialer{Timeout: setupWithin, KeepAlive: 30 * time.Second}
	raw, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, err
	}
	c := raw
	if u.Scheme == "wss" {
		tc := tls.Client(raw, &tls.Config{ServerName: host, NextProtos: []string{"http/1.1"}})
		tc.SetDeadline(time.Now().Add(setupWithin))
		if err := tc.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		tc.SetDeadline(time.Time{})
		c = tc
	}
	keyBytes := make([]byte, 16)
	rand.Read(keyBytes)
	key := base64.StdEncoding.EncodeToString(keyBytes)
	path := u.RequestURI()
	req := "GET " + path + " HTTP/1.1\r\nHost: " + u.Host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\nUser-Agent: pierd\r\n\r\n"
	c.SetDeadline(time.Now().Add(setupWithin))
	if _, err := io.WriteString(c, req); err != nil {
		c.Close()
		return nil, err
	}
	br := bufio.NewReaderSize(c, 4096)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		c.Close()
		return nil, fmt.Errorf("relay %s: %w", rawURL, err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols ||
		!strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") ||
		resp.Header.Get("Sec-WebSocket-Accept") != acceptKey(key) {
		c.Close()
		return nil, fmt.Errorf("relay %s: no WebSocket (HTTP %d)", rawURL, resp.StatusCode)
	}
	c.SetDeadline(time.Time{})
	return newWSConn(c, br, true), nil
}

func acceptKey(key string) string {
	h := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h[:])
}

func (w *wsConn) RemoteAddr() net.Addr {
	if w.remote != nil {
		return w.remote
	}
	return w.Conn.RemoteAddr()
}

// upgradeWebSocket answers a WebSocket handshake read from r on c; the
// returned connection carries the relay's protocol. With trustProxy, the
// client's address is the one the proxy in front names.
func upgradeWebSocket(c net.Conn, r *bufio.Reader, trustProxy bool) (net.Conn, error) {
	req, err := http.ReadRequest(r)
	if err != nil {
		return nil, err
	}
	key := req.Header.Get("Sec-WebSocket-Key")
	if req.Method != http.MethodGet || !strings.EqualFold(req.Header.Get("Upgrade"), "websocket") || key == "" {
		io.WriteString(c, "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nPier tunnel: a WebSocket is expected here.\n")
		return nil, errors.New("not a WebSocket request")
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
		acceptKey(key) + "\r\n\r\n"
	if _, err := io.WriteString(c, resp); err != nil {
		return nil, err
	}
	ws := newWSConn(c, r, false)
	if trustProxy {
		from := req.Header.Get("Cf-Connecting-Ip")
		if from == "" {
			from, _, _ = strings.Cut(req.Header.Get("X-Forwarded-For"), ",")
		}
		if ip := net.ParseIP(strings.TrimSpace(from)); ip != nil {
			ws.remote = &net.TCPAddr{IP: ip}
		}
	}
	return ws, nil
}

// wsConn is a WebSocket as a net.Conn: binary messages, read and written as
// one stream of bytes. Pings are answered; a close ends the stream.
type wsConn struct {
	net.Conn
	r      *bufio.Reader
	client bool // a client masks what it sends

	// remote, when set, is the client's address as the proxy in front
	// reported it (Cloudflare's CF-Connecting-IP).
	remote net.Addr

	wmu     sync.Mutex
	left    int64
	masked  bool
	mask    [4]byte
	maskPos int
	closed  bool
}

func newWSConn(c net.Conn, r *bufio.Reader, client bool) *wsConn {
	return &wsConn{Conn: c, r: r, client: client}
}

const maxFrame = 1 << 20

func (w *wsConn) Read(p []byte) (int, error) {
	for w.left == 0 {
		if err := w.nextFrame(); err != nil {
			return 0, err
		}
	}
	if int64(len(p)) > w.left {
		p = p[:w.left]
	}
	n, err := w.r.Read(p)
	if w.masked {
		for i := 0; i < n; i++ {
			p[i] ^= w.mask[w.maskPos%4]
			w.maskPos++
		}
	}
	w.left -= int64(n)
	return n, err
}

// nextFrame reads frame headers until a data frame with a payload starts,
// answering control frames on the way.
func (w *wsConn) nextFrame() error {
	for {
		var h [2]byte
		if _, err := io.ReadFull(w.r, h[:]); err != nil {
			return err
		}
		op := h[0] & 0x0f
		w.masked = h[1]&0x80 != 0
		n := int64(h[1] & 0x7f)
		switch n {
		case 126:
			var b [2]byte
			if _, err := io.ReadFull(w.r, b[:]); err != nil {
				return err
			}
			n = int64(binary.BigEndian.Uint16(b[:]))
		case 127:
			var b [8]byte
			if _, err := io.ReadFull(w.r, b[:]); err != nil {
				return err
			}
			n = int64(binary.BigEndian.Uint64(b[:]))
		}
		if n < 0 || n > maxFrame {
			return errors.New("websocket: frame too large")
		}
		if w.masked {
			if _, err := io.ReadFull(w.r, w.mask[:]); err != nil {
				return err
			}
		}
		w.maskPos = 0
		switch op {
		case 0x0, 0x1, 0x2: // continuation, text, binary: the stream
			if n == 0 {
				continue
			}
			w.left = n
			return nil
		case 0x8: // close
			io.CopyN(io.Discard, w.r, n)
			w.writeFrame(0x8, nil)
			return io.EOF
		case 0x9: // ping: pong with the same payload
			payload := make([]byte, n)
			if _, err := io.ReadFull(w.r, payload); err != nil {
				return err
			}
			if w.masked {
				for i := range payload {
					payload[i] ^= w.mask[i%4]
				}
			}
			w.writeFrame(0xA, payload)
		default: // pong, or anything else: skip it
			if _, err := io.CopyN(io.Discard, w.r, n); err != nil {
				return err
			}
		}
	}
}

func (w *wsConn) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > 32<<10 {
			chunk = chunk[:32<<10]
		}
		if err := w.writeFrame(0x2, chunk); err != nil {
			return written, err
		}
		written += len(chunk)
		p = p[len(chunk):]
	}
	return written, nil
}

func (w *wsConn) writeFrame(op byte, payload []byte) error {
	w.wmu.Lock()
	defer w.wmu.Unlock()
	if w.closed {
		return net.ErrClosed
	}
	header := make([]byte, 0, 14)
	header = append(header, 0x80|op)
	mbit := byte(0)
	if w.client {
		mbit = 0x80
	}
	switch n := len(payload); {
	case n < 126:
		header = append(header, mbit|byte(n))
	case n <= 0xffff:
		header = append(header, mbit|126, byte(n>>8), byte(n))
	default:
		header = append(header, mbit|127)
		header = binary.BigEndian.AppendUint64(header, uint64(n))
	}
	frame := header
	if w.client {
		var mask [4]byte
		rand.Read(mask[:])
		frame = append(frame, mask[:]...)
		start := len(frame)
		frame = append(frame, payload...)
		for i := start; i < len(frame); i++ {
			frame[i] ^= mask[(i-start)%4]
		}
	} else {
		frame = append(frame, payload...)
	}
	_, err := w.Conn.Write(frame)
	if op == 0x8 {
		w.closed = true
	}
	return err
}

func (w *wsConn) Close() error {
	w.writeFrame(0x8, []byte{0x03, 0xe8}) // 1000: normal closure
	return w.Conn.Close()
}
