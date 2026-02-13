package httpmux

// PATCH FILE: Enhanced transport.go with Dagger-like multi-connection + decoy traffic
// این کد باید جایگزین transport.go موجود شود یا به آن merge شود

import (
	"bytes"
	"context"
	crand "crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	mrand "math/rand"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

// ========== NEW: Helper Functions ==========

// generateRandomSessionID creates a random session ID (like Dagger does)
func generateRandomSessionID() string {
	b := make([]byte, 16)
	_, _ = crand.Read(b)
	return hex.EncodeToString(b)
}

// GenerateFakeHTTPHeaders creates HTTP-like headers to embed in encrypted payload
func GenerateFakeHTTPHeaders(cfg *MimicConfig, sessionID string) []byte {
	if cfg == nil {
		return nil
	}

	headers := "POST /api/data HTTP/1.1\r\n"

	if cfg.FakeDomain != "" {
		headers += "Host: " + cfg.FakeDomain + "\r\n"
	}

	ua := cfg.UserAgent
	if ua == "" {
		ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	}
	headers += "User-Agent: " + ua + "\r\n"

	headers += "Content-Type: application/octet-stream\r\n"
	headers += "Accept-Encoding: gzip, deflate, br\r\n"
	headers += "Accept-Language: en-US,en;q=0.9\r\n"
	headers += "Connection: keep-alive\r\n"

	if sessionID != "" {
		headers += "Cookie: session=" + sessionID + "\r\n"
	}

	headers += "\r\n"
	return []byte(headers)
}

// stripFakeHeaders removes embedded HTTP headers from decrypted payload
func stripFakeHeaders(data []byte) []byte {
	marker := []byte("\r\n\r\n")
	idx := bytes.Index(data, marker)
	if idx == -1 {
		return data // No headers found
	}
	return data[idx+4:]
}

// ========== MODIFIED: HTTPConn with embedded headers ==========

type HTTPConn struct {
	CookieName string
	Client     *http.Client
	Mimic      *MimicConfig
	Obfs       *ObfsConfig
	PSK        string
	SessionID  string
	ServerURL  string

	RetryInterval time.Duration
	Aggressive    bool
	nextTryNS     int64

	// NEW: Enable fake header embedding
	EmbedFakeHeaders bool
}

func (hc *HTTPConn) canTry(now time.Time) bool {
	nt := atomic.LoadInt64(&hc.nextTryNS)
	return nt == 0 || now.UnixNano() >= nt
}

func (hc *HTTPConn) markFail(now time.Time) {
	ri := hc.RetryInterval
	if ri <= 0 {
		ri = 3 * time.Second
	}
	if hc.Aggressive {
		if ri > 500*time.Millisecond {
			ri = 500 * time.Millisecond
		}
	}
	atomic.StoreInt64(&hc.nextTryNS, now.Add(ri).UnixNano())
}

func (hc *HTTPConn) markOK() {
	atomic.StoreInt64(&hc.nextTryNS, 0)
}

func (hc *HTTPConn) RoundTrip(payload []byte) ([]byte, error) {
	if hc.Client == nil {
		hc.Client = &http.Client{Timeout: 25 * time.Second}
	}

	// NEW: Prepend fake HTTP headers to payload BEFORE encryption (Dagger-like)
	if hc.EmbedFakeHeaders && len(payload) > 0 {
		fakeHeaders := GenerateFakeHTTPHeaders(hc.Mimic, hc.SessionID)
		if len(fakeHeaders) > 0 {
			payload = append(fakeHeaders, payload...)
		}
	}

	// Encrypt -> Obfs
	enc, err := EncryptPSK(payload, hc.PSK)
	if err != nil {
		return nil, err
	}
	enc = ApplyObfuscation(enc, hc.Obfs)
	ApplyDelay(hc.Obfs)

	body := bytes.NewReader(enc)
	req, err := http.NewRequest("POST", hc.ServerURL, body)
	if err != nil {
		return nil, err
	}

	if hc.Mimic != nil {
		if hc.Mimic.FakeDomain != "" {
			req.Host = hc.Mimic.FakeDomain
		}
		if hc.Mimic.Chunked {
			req.ContentLength = -1
		}
	}
	ApplyMimicHeaders(req, hc.Mimic, hc.CookieName, hc.SessionID)

	resp, err := hc.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// FIX: unified cookie handling (no conflict markers)
	if hc.Mimic != nil && hc.Mimic.SessionCookie {
		for _, c := range resp.Cookies() {
			if c == nil || c.Value == "" {
				continue
			}

			// If cookie name is unknown, adopt first cookie we see
			if hc.CookieName == "" {
				hc.CookieName = c.Name
				hc.SessionID = c.Value
				break
			}

			// Otherwise only update if it's the expected cookie name
			if c.Name == hc.CookieName {
				hc.SessionID = c.Value
				break
			}
		}
	}

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// Deobfs -> Decrypt
	b = StripObfuscation(b, hc.Obfs)
	plain, err := DecryptPSK(b, hc.PSK)
	if err != nil {
		return nil, err
	}

	// NEW: Strip embedded fake headers if they exist
	if hc.EmbedFakeHeaders {
		plain = stripFakeHeaders(plain)
	}

	return plain, nil
}

// ========== MODIFIED: HTTPMuxConfig with new options ==========

type HTTPMuxConfig struct {
	FlushInterval time.Duration
	MaxBatch      int
	IdlePoll      time.Duration

	// NEW: Dagger-like features
	NumConnections   int           `yaml:"num_connections"`    // Number of parallel connections
	EnableDecoy      bool          `yaml:"enable_decoy"`       // Enable fake GET requests
	DecoyInterval    time.Duration `yaml:"decoy_interval"`     // Interval for decoy traffic
	EmbedFakeHeaders bool          `yaml:"embed_fake_headers"` // Embed HTTP headers in encrypted payload
}

// ========== MODIFIED: HTTPMuxTransport with decoy support ==========

type HTTPMuxTransport struct {
	conns []*HTTPConn
	cfg   HTTPMuxConfig

	out chan *Frame
	in  chan *Frame

	die chan struct{}
	wg  sync.WaitGroup

	rr uint32

	sem chan struct{}

	// NEW: Decoy traffic control
	decoyCancel context.CancelFunc
}

func NewHTTPMuxTransport(conns []*HTTPConn, cfg HTTPMuxConfig) *HTTPMuxTransport {
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = 20 * time.Millisecond
	}
	if cfg.MaxBatch <= 0 {
		cfg.MaxBatch = 128
	}
	if cfg.IdlePoll <= 0 {
		cfg.IdlePoll = 250 * time.Millisecond
	}

	// NEW: Default to 4 connections (like Dagger)
	numConns := cfg.NumConnections
	if numConns <= 0 {
		numConns = 4
	}

	// NEW: Expand connections array if needed
	if len(conns) > 0 && len(conns) < numConns {
		baseConn := conns[0]
		for i := len(conns); i < numConns; i++ {
			newConn := &HTTPConn{
				Client:           &http.Client{Timeout: 25 * time.Second},
				Mimic:            baseConn.Mimic,
				Obfs:             baseConn.Obfs,
				PSK:              baseConn.PSK,
				SessionID:        generateRandomSessionID(),
				ServerURL:        baseConn.ServerURL,
				RetryInterval:    baseConn.RetryInterval,
				Aggressive:       baseConn.Aggressive,
				EmbedFakeHeaders: cfg.EmbedFakeHeaders,
			}
			conns = append(conns, newConn)
		}
	}

	concurrencyLimit := len(conns) * 4
	if concurrencyLimit < 4 {
		concurrencyLimit = 4
	}

	return &HTTPMuxTransport{
		conns: conns,
		cfg:   cfg,
		out:   make(chan *Frame, 8192),
		in:    make(chan *Frame, 8192),
		die:   make(chan struct{}),
		sem:   make(chan struct{}, concurrencyLimit),
	}
}

func (t *HTTPMuxTransport) Start() error {
	if len(t.conns) == 0 {
		return errors.New("no conns")
	}

	t.wg.Add(1)
	go t.loop()

	// NEW: Start decoy traffic if enabled
	if t.cfg.EnableDecoy {
		// seed math/rand for decoy randomization
		mrand.Seed(time.Now().UnixNano())

		ctx, cancel := context.WithCancel(context.Background())
		t.decoyCancel = cancel
		t.startDecoyTraffic(ctx)
	}

	return nil
}

func (t *HTTPMuxTransport) Close() error {
	select {
	case <-t.die:
	default:
		close(t.die)
	}

	// NEW: Stop decoy traffic
	if t.decoyCancel != nil {
		t.decoyCancel()
	}

	t.wg.Wait()
	return nil
}

func (t *HTTPMuxTransport) Send(fr *Frame) error {
	select {
	case t.out <- fr:
		return nil
	case <-t.die:
		return io.EOF
	}
}

func (t *HTTPMuxTransport) Recv() (*Frame, error) {
	select {
	case fr := <-t.in:
		return fr, nil
	case <-t.die:
		return nil, io.EOF
	}
}

func (t *HTTPMuxTransport) pickConn() *HTTPConn {
	i := atomic.AddUint32(&t.rr, 1)
	return t.conns[int(i)%len(t.conns)]
}

// NEW: Decoy traffic generator (mimics Dagger's fake GET requests)
func (t *HTTPMuxTransport) startDecoyTraffic(ctx context.Context) {
	interval := t.cfg.DecoyInterval
	if interval <= 0 {
		interval = 5 * time.Second
	}

	fakePaths := []string{
		"/search",
		"/search?q=recipe+ideas",
		"/search?q=best+restaurants+near+me",
		"/search?q=news",
		"/api/trending",
	}

	t.wg.Add(1)
	go func() {
		defer t.wg.Done()

		// Random initial delay to avoid synchronization
		time.Sleep(time.Duration(mrand.Intn(3000)) * time.Millisecond)

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-t.die:
				return
			case <-ticker.C:
				conn := t.pickConn()
				fakePath := fakePaths[mrand.Intn(len(fakePaths))]

				req, err := http.NewRequest("GET", conn.ServerURL+fakePath, nil)
				if err != nil {
					continue
				}

				if conn.Mimic != nil && conn.Mimic.FakeDomain != "" {
					req.Host = conn.Mimic.FakeDomain
				}

				req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
				req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
				req.Header.Set("Accept-Language", "en-US,en;q=0.9")
				req.Header.Set("Accept-Encoding", "gzip, deflate, br")
				req.Header.Set("Connection", "keep-alive")

				resp, err := conn.Client.Do(req)
				if err == nil && resp != nil {
					_ = resp.Body.Close()
				}
			}
		}
	}()
}

func (t *HTTPMuxTransport) loop() {
	defer t.wg.Done()

	flushTick := time.NewTicker(t.cfg.FlushInterval)
	defer flushTick.Stop()

	var batch []*Frame

	doRequest := func(payload []byte) {
		defer func() { <-t.sem }()

		var conn *HTTPConn
		now := time.Now()

		for i := 0; i < len(t.conns); i++ {
			c := t.pickConn()
			if c.canTry(now) {
				conn = c
				break
			}
		}
		if conn == nil {
			conn = t.pickConn()
		}

		resp, err := conn.RoundTrip(payload)
		if err != nil {
			conn.markFail(now)
			return
		}
		conn.markOK()

		if len(resp) == 0 {
			return
		}

		r := bytes.NewReader(resp)
		for {
			fr, err := ReadFrame(r)
			if err != nil {
				break
			}
			select {
			case t.in <- fr:
			case <-t.die:
				return
			}
		}
	}

	flush := func() {
		if len(batch) == 0 {
			select {
			case t.sem <- struct{}{}:
				go doRequest(nil)
			default:
			}
			return
		}

		var buf bytes.Buffer
		for _, fr := range batch {
			_ = WriteFrame(&buf, fr)
		}
		batch = batch[:0]

		select {
		case t.sem <- struct{}{}:
			payload := make([]byte, buf.Len())
			copy(payload, buf.Bytes())
			go doRequest(payload)
		case <-t.die:
			return
		}
	}

	for {
		select {
		case <-t.die:
			return

		case fr := <-t.out:
			batch = append(batch, fr)
			if len(batch) >= t.cfg.MaxBatch {
				flush()
			}

		case <-flushTick.C:
			flush()
		}
	}
}
