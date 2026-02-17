package httpmux

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	utls "github.com/refraction-networking/utls"
	"github.com/xtaci/smux"
)

// ═══════════════════════════════════════════════════════════════
// PicoTun Client — Session Pool with Multi-IP Failover
//
//   - N parallel connections per path
//   - If IP is blocked, auto-switch to next path after 3 fails
//   - Each pool goroutine cycles through paths independently
//   - EOF-safe: normal lifecycle events don't spam logs
// ═══════════════════════════════════════════════════════════════

const maxFailsBeforeSwitch = 3

type Client struct {
	cfg     *Config
	mimic   *MimicConfig
	obfs    *ObfsConfig
	psk     string
	paths   []PathConfig
	verbose bool

	sessMu   sync.RWMutex
	sessions []*smux.Session
	rrIndex  uint64
}

func NewClient(cfg *Config) *Client {
	paths := cfg.Paths
	if len(paths) == 0 && cfg.ServerURL != "" {
		paths = []PathConfig{{
			Transport:      cfg.Transport,
			Addr:           cfg.ServerURL,
			ConnectionPool: cfg.NumConnections,
			RetryInterval:  3,
			DialTimeout:    10,
		}}
	}
	return &Client{
		cfg:     cfg,
		mimic:   &cfg.Mimic,
		obfs:    &cfg.Obfs,
		psk:     cfg.PSK,
		paths:   paths,
		verbose: cfg.Verbose,
	}
}

func (c *Client) Start() error {
	if len(c.paths) == 0 {
		return fmt.Errorf("no paths configured")
	}

	poolSize := c.paths[0].ConnectionPool
	if poolSize <= 0 {
		poolSize = c.cfg.NumConnections
	}
	if poolSize <= 0 {
		poolSize = 4
	}

	sc := buildSmuxConfig(c.cfg)
	log.Printf("[CLIENT] pool=%d paths=%d profile=%s",
		poolSize, len(c.paths), c.cfg.Profile)
	for i, p := range c.paths {
		log.Printf("[CLIENT]   path[%d]: %s (%s)", i, p.Addr, p.Transport)
	}
	log.Printf("[CLIENT] smux: keepalive=%v timeout=%v frame=%d",
		sc.KeepAliveInterval, sc.KeepAliveTimeout, sc.MaxFrameSize)

	go c.sessionHealthCheck()

	var wg sync.WaitGroup
	for i := 0; i < poolSize; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			c.poolWorker(id)
		}(i)
		// Stagger connections to avoid DPI pattern
		if i < poolSize-1 {
			time.Sleep(500 * time.Millisecond)
		}
	}

	wg.Wait()
	return nil
}

// poolWorker — one goroutine that cycles through paths on failure.
func (c *Client) poolWorker(id int) {
	pathIdx := 0
	failCount := 0

	for {
		path := c.paths[pathIdx]
		retryInterval := time.Duration(path.RetryInterval) * time.Second
		if retryInterval <= 0 {
			retryInterval = 3 * time.Second
		}

		connStart := time.Now()
		err := c.connectAndServe(id, path)
		connDuration := time.Since(connStart)

		if err != nil {
			alive := c.sessionCount()

			// Only count short-lived failures as "blocked"
			// Long-lived sessions that die are normal — retry same path
			if connDuration < 30*time.Second {
				failCount++
			} else {
				failCount = 0
			}

			// Switch to next path after N consecutive short failures
			if failCount >= maxFailsBeforeSwitch && len(c.paths) > 1 {
				oldIdx := pathIdx
				pathIdx = (pathIdx + 1) % len(c.paths)
				failCount = 0
				log.Printf("[POOL#%d] path[%d] seems blocked → switching to path[%d] %s",
					id, oldIdx, pathIdx, c.paths[pathIdx].Addr)

				// If we cycled through all paths, longer backoff
				if pathIdx == 0 {
					log.Printf("[POOL#%d] all paths tried, backing off 10s", id)
					time.Sleep(10 * time.Second)
					continue
				}
			} else {
				log.Printf("[POOL#%d] disconnected from %s (alive: %d) — retry %v",
					id, path.Addr, alive, retryInterval)
			}

			time.Sleep(retryInterval)
		} else {
			failCount = 0
			time.Sleep(retryInterval)
		}
	}
}

func (c *Client) connectAndServe(id int, path PathConfig) error {
	transport := strings.ToLower(strings.TrimSpace(path.Transport))
	if transport == "" {
		transport = c.cfg.Transport
	}
	addr := strings.TrimSpace(path.Addr)
	if addr == "" {
		return fmt.Errorf("empty address")
	}

	dialTimeout := time.Duration(path.DialTimeout) * time.Second
	if dialTimeout <= 0 {
		dialTimeout = 10 * time.Second
	}

	host, port := parseAddr(addr, transport)
	dialAddr := net.JoinHostPort(host, port)

	if c.verbose {
		log.Printf("[POOL#%d] connecting to %s (%s)", id, dialAddr, transport)
	}

	// ① Dial TCP/TLS connection
	var conn net.Conn
	var err error

	switch transport {
	case "httpsmux", "wssmux":
		conn, err = c.dialFragmentedTLS(dialAddr, dialTimeout)
	case "httpmux", "wsmux":
		conn, err = DialFragmented(dialAddr, c.fragmentCfg(), dialTimeout)
	default:
		conn, err = net.DialTimeout("tcp", dialAddr, dialTimeout)
	}
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}

	c.setTCPOptions(conn)

	// ② Mimicry handshake — returns bufferedConn
	conn, err = ClientHandshake(conn, c.mimic)
	if err != nil {
		conn.Close()
		return fmt.Errorf("handshake: %w", err)
	}

	// ③ Encrypted connection (AES-256-GCM)
	ec, err := NewEncryptedConn(conn, c.psk, c.obfs)
	if err != nil {
		conn.Close()
		return fmt.Errorf("encrypt: %w", err)
	}

	// ④ smux session
	sc := buildSmuxConfig(c.cfg)
	sess, err := smux.Client(ec, sc)
	if err != nil {
		ec.Close()
		return fmt.Errorf("smux: %w", err)
	}

	c.addSession(sess)
	count := c.sessionCount()
	log.Printf("[POOL#%d] connected to %s (pool: %d)", id, dialAddr, count)

	// ⑤ Accept reverse streams — blocks until session dies
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			c.removeSession(sess)
			sess.Close()
			return fmt.Errorf("session closed: %w", err)
		}
		go c.handleReverseStream(stream)
	}
}

func (c *Client) setTCPOptions(conn net.Conn) {
	type hasTCP interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
		SetNoDelay(bool) error
	}
	if tc, ok := conn.(hasTCP); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
	}
}

// ──────────── Reverse stream handler ────────────

func (c *Client) handleReverseStream(stream *smux.Stream) {
	defer stream.Close()

	// Read deadline for header — prevents stuck streams
	stream.SetReadDeadline(time.Now().Add(10 * time.Second))

	hdr := make([]byte, 2)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return
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
	if c.verbose {
		log.Printf("[REVERSE] dial %s://%s", network, addr)
	}

	remote, err := net.DialTimeout(network, addr, 10*time.Second)
	if err != nil {
		if c.verbose {
			log.Printf("[REVERSE] dial failed %s: %v", addr, err)
		}
		return
	}
	defer remote.Close()
	relay(stream, remote)
}

// ──────────── Session Pool ────────────

func (c *Client) addSession(sess *smux.Session) {
	c.sessMu.Lock()
	c.sessions = append(c.sessions, sess)
	c.sessMu.Unlock()
}

func (c *Client) removeSession(sess *smux.Session) {
	c.sessMu.Lock()
	for i, s := range c.sessions {
		if s == sess {
			c.sessions = append(c.sessions[:i], c.sessions[i+1:]...)
			break
		}
	}
	c.sessMu.Unlock()
}

func (c *Client) sessionCount() int {
	c.sessMu.RLock()
	defer c.sessMu.RUnlock()
	return len(c.sessions)
}

func (c *Client) OpenStream(target string) (*smux.Stream, error) {
	c.sessMu.RLock()
	n := len(c.sessions)
	if n == 0 {
		c.sessMu.RUnlock()
		return nil, fmt.Errorf("no active session")
	}
	sessions := make([]*smux.Session, n)
	copy(sessions, c.sessions)
	c.sessMu.RUnlock()

	idx := atomic.AddUint64(&c.rrIndex, 1)
	for i := 0; i < n; i++ {
		pick := sessions[(int(idx)+i)%n]
		if pick.IsClosed() {
			continue
		}
		stream, err := pick.OpenStream()
		if err == nil {
			sendTarget(stream, target)
			return stream, nil
		}
		// Zombie — evict immediately
		c.removeSession(pick)
	}
	return nil, fmt.Errorf("all %d sessions dead", n)
}

func (c *Client) sessionHealthCheck() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		c.sessMu.Lock()
		alive := c.sessions[:0]
		removed := 0
		for _, sess := range c.sessions {
			if sess.IsClosed() {
				sess.Close()
				removed++
			} else {
				alive = append(alive, sess)
			}
		}
		c.sessions = alive
		c.sessMu.Unlock()
		if removed > 0 {
			log.Printf("[POOL] cleaned %d dead (alive: %d)", removed, len(alive))
		}
	}
}

// ──────────── TLS ────────────

func (c *Client) dialFragmentedTLS(addr string, timeout time.Duration) (net.Conn, error) {
	fragCfg := c.fragmentCfg()
	rawConn, err := DialFragmented(addr, fragCfg, timeout)
	if err != nil {
		return nil, err
	}
	sni := c.mimic.FakeDomain
	if sni == "" {
		sni, _, _ = net.SplitHostPort(addr)
	}
	uConn := utls.UClient(rawConn, &utls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
	}, utls.HelloChrome_120)
	if err := uConn.Handshake(); err != nil {
		uConn.Close()
		return nil, fmt.Errorf("tls: %w", err)
	}
	return uConn, nil
}

func (c *Client) fragmentCfg() *FragmentConfig {
	if c.cfg.Fragment.Enabled {
		return &c.cfg.Fragment
	}
	transport := strings.ToLower(c.cfg.Transport)
	if transport == "httpsmux" || transport == "wssmux" {
		cfg := DefaultFragmentConfig()
		return &cfg
	}
	return nil
}

// ──────────── Helpers ────────────

func parseAddr(addr, transport string) (host, port string) {
	addr = strings.TrimPrefix(addr, "http://")
	addr = strings.TrimPrefix(addr, "https://")
	addr = strings.TrimPrefix(addr, "ws://")
	addr = strings.TrimPrefix(addr, "wss://")
	if idx := strings.Index(addr, "/"); idx != -1 {
		addr = addr[:idx]
	}
	h, p, err := net.SplitHostPort(addr)
	if err != nil {
		h = addr
		switch transport {
		case "httpsmux", "wssmux":
			p = "443"
		default:
			p = "80"
		}
	}
	return h, p
}
