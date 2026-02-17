package httpmux

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtaci/smux"
)

// ═══════════════════════════════════════════════════════════════
// PicoTun Server — Multi-Client Session Pool
//
// Supports multiple kharej clients simultaneously.
// EOF-safe: normal stream/session lifecycle doesn't spam logs.
// ═══════════════════════════════════════════════════════════════

type Server struct {
	Config  *Config
	Mimic   *MimicConfig
	Obfs    *ObfsConfig
	PSK     string
	Verbose bool

	poolMu   sync.RWMutex
	sessions []*serverSession
	poolIdx  uint64
}

type serverSession struct {
	sess    *smux.Session
	remote  string
	created time.Time
}

func NewServer(cfg *Config) *Server {
	return &Server{
		Config:  cfg,
		Mimic:   &cfg.Mimic,
		Obfs:    &cfg.Obfs,
		PSK:     cfg.PSK,
		Verbose: cfg.Verbose,
	}
}

func (s *Server) Start() error {
	log.Printf("[SERVER] maps: %d, forward TCP=%d UDP=%d",
		len(s.Config.Maps), len(s.Config.Forward.TCP), len(s.Config.Forward.UDP))
	for i, m := range s.Config.Forward.TCP {
		log.Printf("[SERVER]   tcp[%d]: %s", i, m)
	}

	for _, m := range s.Config.Forward.TCP {
		if bind, target, ok := SplitMap(m); ok {
			go s.startReverseTCP(bind, target)
		} else {
			log.Printf("[WARN] invalid TCP map: %q", m)
		}
	}
	for _, m := range s.Config.Forward.UDP {
		if bind, target, ok := SplitMap(m); ok {
			go s.startReverseUDP(bind, target)
		}
	}

	go s.healthMonitor()

	tunnelPath := mimicPath(s.Mimic)
	prefix := strings.Split(tunnelPath, "{")[0]

	mux := http.NewServeMux()
	mux.HandleFunc(prefix, s.handleTunnel)
	if prefix != "/tunnel" {
		mux.HandleFunc("/tunnel", s.handleTunnel)
	}
	mux.HandleFunc("/", s.handleDecoy)

	sc := buildSmuxConfig(s.Config)
	log.Printf("[SERVER] listening on %s  tunnel=%s  profile=%s",
		s.Config.Listen, prefix, s.Config.Profile)
	log.Printf("[SERVER] smux: keepalive=%v timeout=%v frame=%d maxrecv=%d",
		sc.KeepAliveInterval, sc.KeepAliveTimeout,
		sc.MaxFrameSize, sc.MaxReceiveBuffer)

	return (&http.Server{
		Addr:        s.Config.Listen,
		Handler:     mux,
		IdleTimeout: 0,
	}).ListenAndServe()
}

// ──────────── Health Monitor ────────────

func (s *Server) healthMonitor() {
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for range tick.C {
		s.poolMu.Lock()
		alive := s.sessions[:0]
		removed := 0
		for _, ss := range s.sessions {
			if ss.sess != nil && !ss.sess.IsClosed() {
				alive = append(alive, ss)
			} else {
				removed++
			}
		}
		s.sessions = alive
		s.poolMu.Unlock()
		if removed > 0 {
			log.Printf("[HEALTH] removed %d dead sessions (alive: %d)", removed, len(alive))
		}
	}
}

// ──────────── HTTP Handlers ────────────

func (s *Server) handleTunnel(w http.ResponseWriter, r *http.Request) {
	if ok, reason := s.validate(r); !ok {
		if s.Verbose {
			log.Printf("[REJECT] %s from %s — %s", r.URL.Path, r.RemoteAddr, reason)
		}
		s.writeDecoy(w, r)
		return
	}
	log.Printf("[TUNNEL] accepted from %s", r.RemoteAddr)
	s.upgrade(w, r)
}

func (s *Server) handleDecoy(w http.ResponseWriter, r *http.Request) {
	s.writeDecoy(w, r)
}

// ──────────── Tunnel Upgrade ────────────

func (s *Server) upgrade(w http.ResponseWriter, r *http.Request) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack not supported", 500)
		return
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(s.Config.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(s.Config.Advanced.TCPNoDelay)
	}

	switchResp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
		"\r\n"
	if _, err := conn.Write([]byte(switchResp)); err != nil {
		conn.Close()
		return
	}

	ec, err := NewEncryptedConn(conn, s.PSK, s.Obfs)
	if err != nil {
		log.Printf("[ERR] encrypt: %v", err)
		conn.Close()
		return
	}

	sc := buildSmuxConfig(s.Config)
	sess, err := smux.Server(ec, sc)
	if err != nil {
		log.Printf("[ERR] smux: %v", err)
		ec.Close()
		return
	}

	ss := &serverSession{
		sess:    sess,
		remote:  conn.RemoteAddr().String(),
		created: time.Now(),
	}
	s.addSession(ss)
	log.Printf("[SESSION] new from %s (pool: %d)", ss.remote, s.poolSize())

	// Accept streams until session dies
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			age := time.Since(ss.created).Round(time.Second)
			s.removeSession(ss)
			// Only log if session was short-lived (unexpected death)
			if age < 30*time.Second {
				log.Printf("[SESSION] closed %s after %v: %v (pool: %d)",
					ss.remote, age, err, s.poolSize())
			} else {
				log.Printf("[SESSION] closed %s after %v (pool: %d)",
					ss.remote, age, s.poolSize())
			}
			return
		}
		go s.handleForwardStream(stream)
	}
}

// ──────────── Forward Stream ────────────

func (s *Server) handleForwardStream(stream *smux.Stream) {
	defer stream.Close()

	// Set read deadline for header — prevents stuck streams
	stream.SetReadDeadline(time.Now().Add(10 * time.Second))

	hdr := make([]byte, 2)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return // EOF or timeout — normal lifecycle
	}
	tLen := binary.BigEndian.Uint16(hdr)
	if tLen == 0 || tLen > 4096 {
		return
	}
	tBuf := make([]byte, tLen)
	if _, err := io.ReadFull(stream, tBuf); err != nil {
		return
	}

	// Clear deadline for data transfer
	stream.SetReadDeadline(time.Time{})

	network, addr := splitTarget(string(tBuf))
	if s.Verbose {
		log.Printf("[FWD] → %s://%s", network, addr)
	}

	remote, err := net.DialTimeout(network, addr, 10*time.Second)
	if err != nil {
		if s.Verbose {
			log.Printf("[FWD] dial fail %s: %v", addr, err)
		}
		return
	}
	defer remote.Close()
	relay(stream, remote)
}

// ──────────── Session Pool ────────────

func (s *Server) addSession(ss *serverSession) {
	s.poolMu.Lock()
	s.sessions = append(s.sessions, ss)
	s.poolMu.Unlock()
}

func (s *Server) removeSession(ss *serverSession) {
	s.poolMu.Lock()
	for i, e := range s.sessions {
		if e == ss {
			s.sessions = append(s.sessions[:i], s.sessions[i+1:]...)
			break
		}
	}
	s.poolMu.Unlock()
}

func (s *Server) poolSize() int {
	s.poolMu.RLock()
	defer s.poolMu.RUnlock()
	return len(s.sessions)
}

// openStream tries all pool sessions round-robin.
// Evicts zombies immediately on OpenStream failure.
// Skips sessions with too many active streams to balance load.
func (s *Server) openStream() (*smux.Stream, error) {
	s.poolMu.RLock()
	n := len(s.sessions)
	if n == 0 {
		s.poolMu.RUnlock()
		return nil, fmt.Errorf("no active sessions")
	}
	pool := make([]*serverSession, n)
	copy(pool, s.sessions)
	s.poolMu.RUnlock()

	start := int(atomic.AddUint64(&s.poolIdx, 1))
	var lastErr error
	for i := 0; i < n; i++ {
		ss := pool[(start+i)%n]
		if ss.sess == nil || ss.sess.IsClosed() {
			s.removeSession(ss)
			continue
		}
		// Load balancing: skip overloaded sessions
		if ss.sess.NumStreams() > 200 {
			continue
		}
		stream, err := ss.sess.OpenStream()
		if err == nil {
			return stream, nil
		}
		lastErr = err
		// OpenStream failed but IsClosed() was false → zombie
		ss.sess.Close()
		s.removeSession(ss)
	}
	if lastErr != nil {
		return nil, fmt.Errorf("all %d sessions failed: %v", n, lastErr)
	}
	return nil, fmt.Errorf("all %d sessions failed", n)
}

// ──────────── Reverse TCP ────────────

func (s *Server) startReverseTCP(bind, target string) {
	ln, err := net.Listen("tcp", bind)
	if err != nil {
		log.Printf("[RTCP] FAILED listen %s: %v", bind, err)
		return
	}
	log.Printf("[RTCP] %s → client → %s", bind, target)

	for {
		c, err := ln.Accept()
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go s.handleReverseTCP(c, target)
	}
}

func (s *Server) handleReverseTCP(local net.Conn, target string) {
	defer local.Close()

	stream, err := s.openStream()
	if err != nil {
		// Brief retry — pool may be reconnecting
		time.Sleep(2 * time.Second)
		stream, err = s.openStream()
		if err != nil {
			if s.Verbose {
				log.Printf("[RTCP] no session for %s → %s: %v",
					local.RemoteAddr(), target, err)
			}
			return
		}
	}
	defer stream.Close()

	sendTarget(stream, "tcp://"+target)

	if s.Verbose {
		log.Printf("[RTCP] %s → %s (via pool)", local.RemoteAddr(), target)
	}
	relay(local, stream)
}

// ──────────── Reverse UDP ────────────

type udpPeer struct {
	conn     *net.UDPConn
	addr     *net.UDPAddr
	lastSeen int64
	stream   *smux.Stream
}

func (s *Server) startReverseUDP(bind, target string) {
	laddr, _ := net.ResolveUDPAddr("udp", bind)
	ln, err := net.ListenUDP("udp", laddr)
	if err != nil {
		log.Printf("[RUDP] FAILED listen %s: %v", bind, err)
		return
	}
	log.Printf("[RUDP] %s → client → %s", bind, target)

	var mu sync.Mutex
	peers := map[string]*udpPeer{}

	go func() {
		for range time.NewTicker(30 * time.Second).C {
			now := time.Now().Unix()
			mu.Lock()
			for k, p := range peers {
				if now-atomic.LoadInt64(&p.lastSeen) > 120 {
					p.stream.Close()
					delete(peers, k)
				}
			}
			mu.Unlock()
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, raddr, err := ln.ReadFromUDP(buf)
		if err != nil || n == 0 {
			continue
		}
		key := raddr.String()
		mu.Lock()
		p, ok := peers[key]
		if !ok {
			stream, err := s.openStream()
			if err != nil {
				mu.Unlock()
				continue
			}
			sendTarget(stream, "udp://"+target)
			p = &udpPeer{conn: ln, addr: raddr, lastSeen: time.Now().Unix(), stream: stream}
			peers[key] = p
			go func(p *udpPeer) {
				rb := make([]byte, 65535)
				for {
					rn, err := p.stream.Read(rb)
					if err != nil {
						break
					}
					p.conn.WriteToUDP(rb[:rn], p.addr)
				}
			}(p)
		}
		atomic.StoreInt64(&p.lastSeen, time.Now().Unix())
		mu.Unlock()
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		p.stream.Write(pkt)
	}
}

// ──────────── Validation & Decoy ────────────

func (s *Server) validate(r *http.Request) (bool, string) {
	if r.Method != "GET" {
		return false, "method"
	}
	if s.Mimic != nil && s.Mimic.FakeDomain != "" {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if host != s.Mimic.FakeDomain && !strings.HasSuffix(host, "."+s.Mimic.FakeDomain) {
			// Allow IP-based connections (no domain match needed)
			if strings.Contains(host, ".") && !isIPAddress(host) {
				return false, "host"
			}
		}
	}
	if r.Header.Get("Upgrade") == "" ||
		!strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
		return false, "no upgrade"
	}
	expected := "/tunnel"
	if s.Mimic != nil && s.Mimic.FakePath != "" {
		expected = strings.Split(s.Mimic.FakePath, "{")[0]
	}
	if !strings.HasPrefix(r.URL.Path, expected) {
		return false, "path"
	}
	return true, ""
}

func isIPAddress(s string) bool {
	return net.ParseIP(s) != nil
}

func (s *Server) writeDecoy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Server", "nginx/1.18.0")
	w.Header().Set("Date", time.Now().UTC().Format(http.TimeFormat))
	w.Header().Set("Connection", "keep-alive")
	body := buildDecoyBody(r.URL.Path)
	status := http.StatusNotFound
	if r.URL.Path == "/" || r.URL.Path == "/index.html" {
		status = http.StatusOK
	}
	w.WriteHeader(status)
	w.Write(body)
}

func buildDecoyBody(path string) []byte {
	if strings.Contains(path, "api") || strings.Contains(path, "json") {
		return []byte(fmt.Sprintf(`{"status":"error","code":404,"ts":%d}`, time.Now().Unix()))
	}
	return []byte(`<!DOCTYPE html><html><head><title>Welcome to nginx!</title>` +
		`<style>body{width:35em;margin:0 auto;font-family:Tahoma,Verdana,Arial,sans-serif}</style>` +
		`</head><body><h1>Welcome to nginx!</h1>` +
		`<p>If you see this page, the nginx web server is successfully installed.</p>` +
		`</body></html>`)
}

// ──────────── Shared Helpers ────────────

func buildSmuxConfig(cfg *Config) *smux.Config {
	sc := smux.DefaultConfig()
	sc.Version = cfg.Smux.Version
	if sc.Version < 1 {
		sc.Version = 2
	}
	sc.KeepAliveInterval = time.Duration(cfg.Smux.KeepAlive) * time.Second
	if sc.KeepAliveInterval <= 0 {
		sc.KeepAliveInterval = 1 * time.Second
	}
	// Timeout = interval × 10 (fast detection)
	sc.KeepAliveTimeout = sc.KeepAliveInterval * 10
	if sc.KeepAliveTimeout < 10*time.Second {
		sc.KeepAliveTimeout = 10 * time.Second
	}
	if cfg.Smux.MaxRecv > 0 {
		sc.MaxReceiveBuffer = cfg.Smux.MaxRecv
	}
	if cfg.Smux.MaxStream > 0 {
		sc.MaxStreamBuffer = cfg.Smux.MaxStream
	}
	if cfg.Smux.FrameSize > 0 {
		sc.MaxFrameSize = cfg.Smux.FrameSize
	}
	return sc
}

func mimicPath(m *MimicConfig) string {
	p := "/tunnel"
	if m != nil && m.FakePath != "" {
		p = m.FakePath
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func splitTarget(s string) (network, addr string) {
	if strings.HasPrefix(s, "udp://") {
		return "udp", strings.TrimPrefix(s, "udp://")
	}
	return "tcp", strings.TrimPrefix(s, "tcp://")
}

func sendTarget(w io.Writer, target string) error {
	b := []byte(target)
	hdr := make([]byte, 2)
	binary.BigEndian.PutUint16(hdr, uint16(len(b)))
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

// relay copies data bidirectionally between two connections.
// Uses EOF-safe copy — normal stream close is NOT an error.
func relay(a, b io.ReadWriteCloser) {
	done := make(chan struct{}, 2)
	cp := func(dst io.Writer, src io.Reader) {
		buf := make([]byte, 32*1024)
		io.CopyBuffer(dst, src, buf)
		// Signal done — the other direction will terminate
		// when the peer closes or gets a broken pipe.
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	// Close both sides to unblock the other goroutine
	a.Close()
	b.Close()
	<-done
}
