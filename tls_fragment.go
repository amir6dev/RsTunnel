package httpmux

import (
	"crypto/rand"
	"fmt"
	"net"
	"sync"
	"time"
)

// ═══════════════════════════════════════════════════════════════
// TLS ClientHello Fragmentation (anti-DPI)
//
// How DPI detects tunnels:
//   DPI inspects the TLS ClientHello to extract SNI (Server Name).
//   If SNI is blocked or the fingerprint looks suspicious → RST.
//
// How fragmentation defeats this:
//   1. TCP_NODELAY ensures each Write() = separate TCP segment
//   2. First write (ClientHello) is split at random offset (64-191 bytes)
//   3. 1-2ms random delay between fragments → separate TCP packets
//   4. DPI gets partial ClientHello → can't parse SNI → passes through
//
// Identical to PicoTun's FragmentedConn + dialWithFragmentation.
// ═══════════════════════════════════════════════════════════════

// FragmentConfig controls TLS fragmentation behavior.
type FragmentConfig struct {
	Enabled  bool `yaml:"enabled"`
	MinSize  int  `yaml:"min_size"`  // Min fragment size (default 64)
	MaxSize  int  `yaml:"max_size"`  // Max fragment size (default 191)
	MinDelay int  `yaml:"min_delay"` // Min delay between fragments in ms (default 1)
	MaxDelay int  `yaml:"max_delay"` // Max delay between fragments in ms (default 2)
}

// DefaultFragmentConfig returns PicoTun defaults.
func DefaultFragmentConfig() FragmentConfig {
	return FragmentConfig{
		Enabled:  true,
		MinSize:  64,
		MaxSize:  191,
		MinDelay: 1,
		MaxDelay: 2,
	}
}

// ──────────────────────────────────────────────────
// FragmentedConn — wraps net.Conn, splits first large Write
// ──────────────────────────────────────────────────

// FragmentedConn wraps a net.Conn and fragments the first large write
// (TLS ClientHello) into two pieces with a random delay between them.
// All subsequent writes pass through unchanged.
type FragmentedConn struct {
	net.Conn
	fragmentSize int
	delay        time.Duration
	firstWrite   bool
	mu           sync.Mutex
}

// Write splits the first large write (ClientHello) into fragments.
// Matches PicoTun's FragmentedConn.Write logic exactly.
func (c *FragmentedConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// After first write, or data fits in one fragment: passthrough
	if c.firstWrite || len(b) <= c.fragmentSize {
		c.firstWrite = true
		return c.Conn.Write(b)
	}

	// ━━━ First write with large data = TLS ClientHello ━━━
	c.firstWrite = true

	// Fragment 1: first N bytes (cuts through SNI field)
	frag1 := b[:c.fragmentSize]
	// Fragment 2: remainder
	frag2 := b[c.fragmentSize:]

	// Write fragment 1
	n1, err := c.Conn.Write(frag1)
	if err != nil {
		return n1, err
	}

	// Random delay between fragments — forces separate TCP segments
	// PicoTun: (random_bit & 1) + 1 = 1 or 2 ms
	time.Sleep(c.delay)

	// Write fragment 2
	n2, err := c.Conn.Write(frag2)
	if err != nil {
		return n1 + n2, err
	}

	return n1 + n2, nil
}

// ──────────────────────────────────────────────────
// Dialer functions
// ──────────────────────────────────────────────────

// DialFragmented creates a TCP connection with ClientHello fragmentation.
// Steps:
//   1. TCP connect with timeout
//   2. Set TCP_NODELAY (critical — prevents OS from combining fragments)
//   3. Wrap in FragmentedConn
func DialFragmented(addr string, cfg *FragmentConfig, timeout time.Duration) (net.Conn, error) {
	if cfg == nil || !cfg.Enabled {
		// No fragmentation — normal dial
		return net.DialTimeout("tcp", addr, timeout)
	}

	// Apply defaults
	minSize := cfg.MinSize
	maxSize := cfg.MaxSize
	minDelay := cfg.MinDelay
	maxDelay := cfg.MaxDelay
	if minSize <= 0 {
		minSize = 64
	}
	if maxSize <= 0 {
		maxSize = 191
	}
	if minDelay <= 0 {
		minDelay = 1
	}
	if maxDelay <= 0 {
		maxDelay = 2
	}

	// Random fragment size: minSize..maxSize (PicoTun: 64..191)
	fragSize := minSize
	diff := maxSize - minSize
	if diff > 0 {
		fragSize += secureRandInt(diff + 1)
	}

	// Random delay
	delayMs := minDelay
	delayDiff := maxDelay - minDelay
	if delayDiff > 0 {
		delayMs += secureRandInt(delayDiff + 1)
	}
	delay := time.Duration(delayMs) * time.Millisecond

	// Try raw socket first (best: TCP_NODELAY before connect)
	conn, err := dialRawTCP(addr, timeout)
	if err != nil {
		// Fallback: standard dial + set TCP_NODELAY after
		conn, err = net.DialTimeout("tcp", addr, timeout)
		if err != nil {
			return nil, fmt.Errorf("dial: %w", err)
		}
		setTCPNoDelay(conn)
	}

	return &FragmentedConn{
		Conn:         conn,
		fragmentSize: fragSize,
		delay:        delay,
		firstWrite:   false,
	}, nil
}

// setTCPNoDelay enables TCP_NODELAY on a connection.
// TCP_NODELAY disables Nagle's algorithm — each Write() goes as
// its own TCP segment immediately. Without this, OS might combine
// our two fragments into one segment, defeating the purpose.
func setTCPNoDelay(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
}

// ──────────────────────────────────────────────────
// Random cipher suites (PicoTun)
// ──────────────────────────────────────────────────

// picotunCipherSuites are the 6 cipher suites PicoTun uses.
// They are shuffled randomly and a subset (3-6) is returned.
var picotunCipherSuites = []uint16{
	0xc02f, // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
	0xc030, // TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
	0xcca8, // TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
	0xcca9, // TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
	0xc02b, // TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
	0xc02c, // TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
}

// GetRandomCipherSuites returns a shuffled random subset (3-6)
// of cipher suites. Matches PicoTun's getRandomCipherSuites.
func GetRandomCipherSuites() []uint16 {
	suites := make([]uint16, len(picotunCipherSuites))
	copy(suites, picotunCipherSuites)

	// Fisher-Yates shuffle (crypto/rand)
	for i := len(suites) - 1; i > 0; i-- {
		j := secureRandInt(i + 1)
		suites[i], suites[j] = suites[j], suites[i]
	}

	// Random count 3-6 (PicoTun: random % 3 + 3)
	count := secureRandInt(4) + 3
	if count > len(suites) {
		count = len(suites)
	}
	return suites[:count]
}

// ──────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────

// randomFragmentSize returns a random size in [64, 191] (PicoTun default).
func randomFragmentSize() int {
	b := make([]byte, 1)
	rand.Read(b)
	return int(b[0]&0x7f) + 64
}
